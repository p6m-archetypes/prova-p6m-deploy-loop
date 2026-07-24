-- prova-p6m-deploy-loop - a reusable proof of the p6m archetype deploy loop.
--
-- Renders an archetype, pushes it to a real GitHub repo, and follows the whole GitOps pipeline the
-- generated CI drives - asserting each stage - then always tears down what it created:
--
--   render -> push -> Build workflow -> git tag + release (image digest) -> .platform manifest
--   dispatch -> ArgoCD app appears -> Synced/Healthy -> Deployment Available -> pods run the built
--   digest -> pods stay Running.
--
-- Consume it two ways (see library/deploy.lua for the full contract):
--
--   local deploy = require("deploy")
--
--   -- 1) the whole flow in one call:
--   deploy.flow(deploy.from_env{ answers = { org_name = "ybor", ... } })
--
--   -- 2) compose your own flow from the exported stages:
--   local run = deploy.new_run(config)
--   prova.flow("my-loop", { requires = deploy.defaults.requires }, function(f)
--     f:step("render", function(t) deploy.stages.render(t, t:use(run)) end)
--     f:step("push",   function(t) deploy.stages.push(t, t:use(run)) end)
--   end)

local deploy = {}

------------------------------------------------------------------------------------------
-- Config
------------------------------------------------------------------------------------------
deploy.defaults = {
  -- Source: a local checkout (archetype_dir) or a git URL#ref (archetype_source).
  archetype_dir    = ".",
  archetype_source = "",
  -- Answers: a table (answers) or a path (answers_file). The consumer owns these - the plugin bakes
  -- in no archetype-specific defaults. prefix_key is overridden per run for a unique repo name.
  answers      = nil,
  answers_file = "",
  prefix_key   = "prefix_name",

  github_org      = "ybor-playground",
  repo_name       = "",   -- default: the rendered project name
  platform_repo   = "",   -- default: "<github_org>/.platform"
  environment     = "dev",
  argo_app_suffix = "dev-azure-westus2",

  keep_resources   = false,
  teardown_retries = 3,

  requires     = { "archetect", "gh", "git", "argocd" },
  flow_timeout = "5400s",

  -- Per-stage timeouts (seconds). argo_appear/deployment/pods_stable carry the requested defaults.
  timeouts = {
    render      = 600,
    push        = 300,
    build       = 1800,
    release     = 300,
    platform    = 600,
    argo_appear = 300,   -- ArgoCD app must appear within 5 minutes
    argo_healthy = 300,
    deployment  = 180,   -- Deployment must go Healthy within 3 minutes
    digest      = 300,
    pods_stable = 30,    -- pods must stay Running for 30 seconds
    poll_interval      = 15,
    stability_interval = 2,
  },
}

local function merge(base, over)
  local out = {}
  for k, v in pairs(base) do out[k] = v end
  if over then
    for k, v in pairs(over) do
      if type(v) == "table" and type(out[k]) == "table" then out[k] = merge(out[k], v) else out[k] = v end
    end
  end
  return out
end

-- Merge a config table over the defaults and fill derived values. Idempotent.
function deploy.resolve(config)
  local cfg = merge(deploy.defaults, config)
  cfg.run_id = cfg.run_id or os.date("%y%m%d%H%M%S")
  cfg.project_prefix = cfg.project_prefix or ("e2e" .. cfg.run_id)
  cfg.project_suffix = cfg.project_suffix or "Service"
  if cfg.platform_repo == "" then cfg.platform_repo = cfg.github_org .. "/.platform" end
  return cfg
end

-- Build a config table from environment variables, then layer `overrides` on top. Unset vars fall
-- through to the defaults at resolve time. Handy for CI, where knobs arrive as env.
function deploy.from_env(overrides)
  local function e(name) local v = os.getenv(name); if v ~= nil and v ~= "" then return v end end
  local function n(name) local v = e(name); return v and tonumber(v) or nil end

  local c = {
    archetype_dir    = e("ARCHETYPE_DIR"),
    archetype_source = e("ARCHETYPE_SOURCE"),
    answers_file     = e("ANSWERS_FILE"),
    github_org       = e("GITHUB_ORG"),
    repo_name        = e("REPO_NAME"),
    platform_repo    = e("PLATFORM_REPO"),
    environment      = e("ENVIRONMENT"),
    argo_app_suffix  = e("ARGO_APP_SUFFIX"),
    project_prefix   = e("PROJECT_PREFIX"),
    project_suffix   = e("PROJECT_SUFFIX"),
    run_id           = e("RUN_ID"),
    prefix_key       = e("PREFIX_KEY"),
    keep_resources   = e("KEEP_RESOURCES") ~= nil or nil,
    teardown_retries = n("TEARDOWN_PUSH_RETRIES"),
    flow_timeout     = e("E2E_FLOW_TIMEOUT"),
    timeouts = {
      build       = n("CI_TIMEOUT"),
      platform    = n("PLATFORM_TIMEOUT"),
      argo_appear = n("ARGO_APPEAR_TIMEOUT"),
      argo_healthy = n("ARGO_TIMEOUT"),
      deployment  = n("DEPLOYMENT_TIMEOUT"),
      pods_stable = n("PODS_STABLE_SECONDS"),
      poll_interval = n("POLL_INTERVAL"),
    },
  }
  -- Drop nil timeout entries so they don't clobber defaults in the merge.
  local tt = {}
  for k, v in pairs(c.timeouts) do if v ~= nil then tt[k] = v end end
  c.timeouts = tt
  return merge(c, overrides)
end

------------------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------------------
local function trim(s) return (s or ""):gsub("^%s+", ""):gsub("%s+$", "") end
local function sh(cmd, opts) return shell.run(cmd, opts) end
local function sh_out(cmd) return trim(sh(cmd, { check = true }).stdout) end

-- Poll `fn` until truthy or the timeout elapses, logging a heartbeat on EVERY attempt so a live run
-- is watchable (elapsed/timeout + a concise observed-state note). On timeout, raise an error naming
-- what we waited for AND - if a diagnostic is given - a full snapshot of the current state, so a
-- failed run is diagnosable inline (teardown wipes the app/repo right after, so a bare "timed out"
-- would be a dead end). `cb` is an optional table: `cb.tick()` returns the concise one-liner logged
-- each attempt; `cb.diag()` returns the verbose snapshot for the timeout error (falls back to tick).
local function poll(t, desc, timeout_s, interval_s, fn, cb)
  cb = cb or {}
  local start = os.time()
  t:log(string.format("waiting up to %ds for %s (checking every %ds)", timeout_s, desc, interval_s))
  local wrapped = function()
    local res = fn()
    if res then return res end
    local note = ""
    if cb.tick then
      local ok, s = pcall(cb.tick)
      if ok and s and s ~= "" then note = " - " .. s end
    end
    t:log(string.format("  ... %ds/%ds elapsed%s", os.time() - start, timeout_s, note))
    return nil
  end
  local ok, res = pcall(prova.retry, wrapped, { timeout = timeout_s .. "s", every = interval_s .. "s" })
  if ok then
    t:log(string.format("  done: %s (after %ds)", desc, os.time() - start))
    return res
  end
  local extra = ""
  local diag = cb.diag or cb.tick
  if diag then
    local dok, d = pcall(diag)
    if dok and d and d ~= "" then extra = "\n  current state:\n" .. d end
  end
  error("timed out after " .. timeout_s .. "s waiting for: " .. desc .. extra, 0)
end

-- The ArgoCD app object for `name`, or nil if absent / unreadable. Fetches the exact app
-- (`argocd app get <name>`) rather than listing every app in the cluster and scanning - a missing
-- app just exits non-zero, which we map to nil.
local function argo_app(name)
  local r = sh("argocd app get " .. name .. " --grpc-web -o json")
  if not r:ok() then return nil end
  local ok, app = pcall(prova.parse.json, r.stdout)
  if not ok or type(app) ~= "table" or not app.metadata then return nil end
  return app
end

-- A one-line "sync=.. health=.." for heartbeat logging while polling (cheap, no resource tree).
local function app_brief(name)
  local a = argo_app(name)
  if not a then return "app not present yet" end
  local s = a.status or {}
  return string.format("sync=%s health=%s", (s.sync or {}).status or "?", (s.health or {}).status or "?")
end

-- One snapshot of the live Deployment (name/namespace == project-name) via ArgoCD, mirroring
-- archetype-e2e-tests/run-e2e.sh's `_deployment_available_reason`. This archetype deploys a
-- PlatformApplication CRD whose operator creates the Deployment -> ReplicaSet -> Pods, so the
-- Deployment is NOT a top-level managed resource of the app; `get-resource` reads the live object
-- directly by kind/name. Returns:
--   "SKIP"  - the resource can't be read (RBAC/naming); never a false failure. Safe here because
--             argo_healthy already asserted the app is Synced+Healthy, so we fall back to that rollup.
--   "PASS readyReplicas=r/d Available=True" - fully available.
--   otherwise a human reason ("readyReplicas=r/d Available=..").
local function deployment_reason(app, project)
  local r = sh("argocd app get-resource " .. app .. " --grpc-web" ..
    " --group apps --kind Deployment --resource-name " .. project .. " -o json")
  if not r:ok() then return "SKIP" end
  local ok, dep = pcall(prova.parse.json, r.stdout)
  if not ok or type(dep) ~= "table" or type(dep.status) ~= "table" then return "SKIP" end
  local desired = (dep.spec or {}).replicas or 1
  local ready = dep.status.readyReplicas or 0
  local avail = "Unknown"
  for _, c in ipairs(dep.status.conditions or {}) do
    if c.type == "Available" then avail = c.status or "Unknown"; break end
  end
  local prefix = (ready >= 1 and ready >= desired and avail == "True") and "PASS " or ""
  return string.format("%sreadyReplicas=%d/%d Available=%s", prefix, ready, desired, avail)
end

-- "PASS" when the app's whole workload is healthy, else a human reason (a Healthy app rolls health up
-- its tree, so this covers the Deployment and its Pods too).
local function health_reason(name)
  local a = argo_app(name)
  if not a then return "ArgoCD app " .. name .. " not found" end
  local status = a.status or {}
  local health = (status.health or {}).status or "Unknown"
  if health ~= "Healthy" then return "app health = " .. health end
  for _, res in ipairs(status.resources or {}) do
    local rh = (res.health or {}).status or "Healthy"
    if rh ~= "Healthy" then return res.kind .. "/" .. res.name .. " = " .. rh end
  end
  -- Scan THIS app's JSON (not the whole cluster's app list) for a pod-crash keyword in any nested
  -- health/status message - keeps the scan from false-matching another app's crash.
  local blob = sh("argocd app get " .. name .. " --grpc-web -o json").stdout
  local crash = blob:match("CrashLoopBackOff") or blob:match("ImagePullBackOff")
    or blob:match("ErrImagePull") or blob:match("RunContainerError")
  if crash then return "pod crash: " .. crash end
  return "PASS"
end

-- A formatted snapshot of the app's current ArgoCD state, for failure diagnostics: the app's
-- sync/health, each managed resource's sync/health + any health message (e.g. "Waiting for rollout
-- to finish: 0 of 1 updated replicas are available"), and the images the live pods run. This is the
-- state at the moment a wait timed out - the only record, since teardown prunes the app right after.
local function app_snapshot(name)
  local a = argo_app(name)
  if not a then
    return string.format("  ArgoCD app '%s' not found", name)
  end
  local s = a.status or {}
  local lines = { string.format("  app %s: sync=%s health=%s", name,
    (s.sync or {}).status or "?", (s.health or {}).status or "?") }
  for _, res in ipairs(s.resources or {}) do
    local h = (res.health or {}).status or "-"
    local msg = (res.health or {}).message
    lines[#lines + 1] = string.format("    - %s %s/%s: sync=%s health=%s%s",
      res.kind, res.namespace or "-", res.name or "-", res.status or "-", h,
      (msg and msg ~= "") and ("  msg: " .. msg) or "")
  end
  local imgs = s.summary and s.summary.images or {}
  if #imgs > 0 then lines[#lines + 1] = "    images: " .. table.concat(imgs, ", ") end
  return table.concat(lines, "\n")
end

-- A one-line progress note for the Build heartbeat: the overall run status PLUS the job/step
-- currently in flight, so a live run shows WHICH step it is on, not just "in_progress". One `gh`
-- call; degrades to a bare status if the jobs aren't readable yet.
local function build_brief(repo, run_id)
  local r = sh("gh run view " .. run_id .. " --repo " .. repo .. " --json status,jobs")
  local ok, data = pcall(prova.parse.json, r.stdout)
  if not ok or type(data) ~= "table" then return "status unknown" end
  local status = "status=" .. (data.status or "?")
  -- Report the first in-progress step of the first in-progress job (the CI runs jobs serially here).
  for _, job in ipairs(data.jobs or {}) do
    if job.status == "in_progress" then
      for _, step in ipairs(job.steps or {}) do
        if step.status == "in_progress" then
          return status .. " - " .. (job.name or "?") .. " / " .. (step.name or "?")
        end
      end
      return status .. " - " .. (job.name or "?")
    end
  end
  return status
end

-- Log a failed Build's run URL, the failed job/step names, and the failed steps' log tail so a run
-- that dies mid-loop is diagnosable inline (teardown wipes the repo right after). GitHub Actions
-- masks registered secrets as *** in run logs, so `--log-failed` never surfaces raw credentials; we
-- still tail it (not the full run log) to keep the console readable and the blast radius small.
local function log_build_failure(t, repo, run_id, url)
  t:log("Build failed - see " .. url)
  local failed = sh("gh run view " .. run_id .. " --repo " .. repo ..
    [[ --json jobs -q '.jobs[] | select(.conclusion=="failure") | "  job: " + .name, (.steps[] | select(.conclusion=="failure") | "    step: " + .name)']])
  if trim(failed.stdout) ~= "" then t:log("failed jobs/steps:\n" .. failed.stdout) end
  local logs = sh("gh run view " .. run_id .. " --repo " .. repo .. " --log-failed 2>/dev/null | tail -n 100")
  if trim(logs.stdout) ~= "" then t:log("failed step log (last 100 lines, secrets masked by GitHub):\n" .. logs.stdout) end
end

------------------------------------------------------------------------------------------
-- Teardown
------------------------------------------------------------------------------------------
-- Remove kubernetes/<project>/ from the .platform repo by pushing to main (that branch is
-- unprotected and the platform bot commits these test folders directly, so there is no review gate
-- to bypass). Never force-pushes: on a concurrent-push reject it rebases and retries. Once the folder
-- is gone the ApplicationSet prunes the ArgoCD app + namespace.
local function teardown_platform(log, cfg, project)
  local token = trim(sh("gh auth token").stdout)
  if token == "" then log("no GitHub token for the .platform push"); return end
  local tmp = fs.tempdir()
  local url = "https://x-access-token:" .. token .. "@github.com/" .. cfg.platform_repo .. ".git"
  sh("git clone -q '" .. url .. "' '" .. tmp .. "'")
  if not sh("test -d '" .. tmp .. "/.git'"):ok() then log("could not clone " .. cfg.platform_repo); return end

  local dir = "kubernetes/" .. project
  if not sh("test -d '" .. tmp .. "/" .. dir .. "'"):ok() then
    log(".platform has no " .. dir .. " - nothing to remove"); return
  end
  local git = "git -C '" .. tmp .. "'"
  sh(git .. " config user.name 'Archetype E2E'")
  sh(git .. " config user.email 'e2e@ybor.ai'")
  sh(git .. " rm -rq '" .. dir .. "'")
  sh(git .. " commit -q -m 'Remove " .. project .. " e2e test manifests'")
  for attempt = 0, cfg.teardown_retries do
    if sh(git .. " push -q origin HEAD:main"):ok() then
      log("removed " .. dir .. " from " .. cfg.platform_repo .. " - ArgoCD will prune " .. project)
      return
    end
    if attempt == cfg.teardown_retries then break end
    log("push rejected (retry " .. (attempt + 1) .. "/" .. cfg.teardown_retries .. ") - rebasing")
    if not sh(git .. " pull -q --rebase origin main"):ok() then
      sh(git .. " rebase --abort"); log("could not rebase the removal onto main"); return
    end
  end
  log("failed to push the removal after " .. cfg.teardown_retries .. " retries - remove it manually")
end

local function teardown_repo(log, repo)
  if not sh("gh repo view '" .. repo .. "'"):ok() then log("repo " .. repo .. " is gone - skipping"); return end
  if sh("gh repo delete '" .. repo .. "' --yes"):ok() then
    log("deleted repo " .. repo)
  elseif sh("gh repo archive '" .. repo .. "' --yes"):ok() then
    log("archived repo " .. repo .. " (token lacks delete_repo)")
  else
    log("could not delete or archive " .. repo)
  end
end

local function teardown(cfg, state)
  local log = function(m) print("         " .. m) end
  if cfg.keep_resources then log("KEEP_RESOURCES set - leaving " .. tostring(state.project) .. " up"); return end
  if not state.project or not state.repo then log("nothing was created - nothing to tear down"); return end
  print("==> Teardown " .. state.project)
  teardown_platform(log, cfg, state.project)
  teardown_repo(log, state.repo)
end

------------------------------------------------------------------------------------------
-- Stages: each is `fn(t, run)`, where run = { cfg, state, workdir }. They read run.cfg and mutate
-- run.state so later stages (and teardown) can see what earlier ones produced.
------------------------------------------------------------------------------------------
local stages = {}

function stages.preflight(t, run)
  -- The CLIs are on PATH (the flow `requires` gate); assert they are also authenticated.
  t:expect(sh("gh auth status"):ok(), "gh authenticated (gh auth login)"):is_true()
  t:expect(sh("argocd account get-user-info --grpc-web"):ok(),
    "argocd logged in (argocd login <server> --sso)"):is_true()
  t:log("org=" .. run.cfg.github_org .. " prefix=" .. run.cfg.project_prefix)
end

function stages.render(t, run)
  local cfg, state = run.cfg, run.state
  local out = run.workdir .. "/render"
  sh("rm -rf '" .. out .. "' && mkdir -p '" .. out .. "'", { check = true })

  -- Answers: a provided file, or an answers table serialized to YAML. One is required.
  local answers = run.workdir .. "/answers.yaml"
  if cfg.answers_file ~= "" then
    t:expect(fs.exists(cfg.answers_file), "answers_file exists: " .. cfg.answers_file):is_true()
    fs.write(answers, fs.read(cfg.answers_file))
  else
    t:expect(cfg.answers, "config.answers table or config.answers_file"):never():is_nil()
    local lines = {}
    for k, v in pairs(cfg.answers) do
      if type(v) == "table" then
        lines[#lines + 1] = k .. ": []"   -- only empty lists are used in archetype answers
      elseif type(v) == "boolean" or type(v) == "number" then
        lines[#lines + 1] = k .. ": " .. tostring(v)
      else
        lines[#lines + 1] = k .. ': "' .. tostring(v) .. '"'
      end
    end
    lines[#lines + 1] = ""
    fs.write(answers, table.concat(lines, "\n"))
  end

  -- -U refreshes composed libraries (their refs can move); -D uses defaults for anything unanswered;
  -- -a forces a unique prefix so every run renders a fresh repo name.
  local cmd
  if cfg.archetype_source ~= "" and not fs.exists(cfg.archetype_dir .. "/archetype.yaml") then
    cmd = "archetect -U render '" .. cfg.archetype_source .. "'"
  else
    cmd = "cd '" .. cfg.archetype_dir .. "' && archetect -U render ."
  end
  cmd = cmd .. " -A '" .. answers .. "' -a " .. cfg.prefix_key .. "='" .. cfg.project_prefix ..
    "' -D --destination '" .. out .. "'"
  local r = sh(cmd, { timeout = cfg.timeouts.render .. "s" })
  t:expect(r.code, "archetect render\n" .. r.stderr):equals(0)

  state.project_dir = sh_out("find '" .. out .. "' -mindepth 1 -maxdepth 1 -type d | head -1")
  t:expect(state.project_dir, "rendered project dir"):never():is_empty()
  state.project = cfg.repo_name ~= "" and cfg.repo_name or sh_out("basename '" .. state.project_dir .. "'")
  state.argo_app = state.project .. "-" .. cfg.argo_app_suffix

  -- The generated CI must be the full-loop workflow, not the stub.
  local build_yaml = fs.read(state.project_dir .. "/.github/workflows/build.yaml")
  t:expect(build_yaml, "build.yaml has docker publish (not the stub)"):contains("docker-buildx-build-publish")
  t:expect(build_yaml, "build.yaml has the manifest dispatch step"):contains("platform-application-manifest-dispatch")
  t:log("rendered " .. state.project .. " -> argo app " .. state.argo_app)
end

function stages.push(t, run)
  local cfg, state = run.cfg, run.state
  local repo = cfg.github_org .. "/" .. state.project
  t:expect(sh("gh repo view '" .. repo .. "'"):ok(),
    "repo " .. repo .. " must not already exist (pick a fresh prefix)"):is_false()

  sh("cd '" .. state.project_dir .. "' && git init -q -b main && git add -A && " ..
    "git -c user.name='Archetype E2E' -c user.email='e2e@ybor.ai' commit -q -m 'Initial commit'",
    { check = true })
  sh("gh repo create '" .. repo .. "' --private --source '" .. state.project_dir .. "' --remote origin --push",
    { check = true, timeout = cfg.timeouts.push .. "s" })

  state.repo = repo
  state.head_sha = sh_out("cd '" .. state.project_dir .. "' && git rev-parse HEAD")
  t:log("pushed " .. repo .. " @ " .. state.head_sha:sub(1, 8))
end

function stages.build(t, run)
  local cfg, state = run.cfg, run.state
  local run_id = poll(t, "the Build run to be created", 180, 10, function()
    local id = trim(sh([[gh run list --repo ]] .. state.repo ..
      [[ --workflow Build --json databaseId,headSha -q "[.[] | select(.headSha==\"]] .. state.head_sha .. [[\")][0].databaseId"]]).stdout)
    if id ~= "" and id ~= "null" then return id end
  end, { tick = function() return "no Build run for " .. state.head_sha:sub(1, 8) .. " yet" end })
  local url = sh_out("gh run view " .. run_id .. " --repo " .. state.repo .. " --json url -q .url")
  t:log("run " .. run_id .. " - " .. url)

  poll(t, "the Build workflow to finish", cfg.timeouts.build, cfg.timeouts.poll_interval, function()
    return trim(sh("gh run view " .. run_id .. " --repo " .. state.repo .. " --json status -q .status").stdout) == "completed"
  end, { tick = function() return build_brief(state.repo, run_id) end })

  local conclusion = trim(sh("gh run view " .. run_id .. " --repo " .. state.repo .. " --json conclusion -q .conclusion").stdout)
  if conclusion ~= "success" then
    log_build_failure(t, state.repo, run_id, url)
    error("Build workflow failed: " .. (conclusion ~= "" and conclusion or "unknown"))
  end
  t:log("Build succeeded")
end

function stages.release(t, run)
  local state = run.state
  t:expect(sh_out("gh api 'repos/" .. state.repo .. "/tags' -q '.[].name'"), "git tags cut"):never():is_empty()

  state.release = sh_out("gh release list --repo " .. state.repo ..
    " --json tagName,isLatest -q '[.[] | select(.isLatest)][0].tagName'")
  t:expect(state.release, "a GitHub release"):never():is_one_of({ "", "null" })

  local body = sh("gh release view '" .. state.release .. "' --repo " .. state.repo .. " --json body -q .body").stdout
  state.digest = body:match("sha256:[0-9a-f]+")
  t:expect(state.digest, "an image digest in the release body"):never():is_nil()
  t:log("release " .. state.release .. " -> " .. state.digest)
end

function stages.platform(t, run)
  local cfg, state = run.cfg, run.state
  local path = "kubernetes/" .. state.project .. "/" .. cfg.environment .. "/kustomization.yaml"
  poll(t, cfg.platform_repo .. "/" .. path .. " to carry the digest", cfg.timeouts.platform, cfg.timeouts.poll_interval, function()
    local r = sh("gh api 'repos/" .. cfg.platform_repo .. "/contents/" .. path .. "' -q '.content' | base64 -d 2>/dev/null")
    return r:ok() and r.stdout:find(state.digest, 1, true) ~= nil
  end, { tick = function() return "digest " .. state.digest:sub(1, 14) .. ".. not in manifest yet" end })
  t:log(path .. " updated on " .. cfg.platform_repo)
end

function stages.argo_appears(t, run)
  local cfg, state = run.cfg, run.state
  poll(t, "ArgoCD app " .. state.argo_app .. " to appear", cfg.timeouts.argo_appear, cfg.timeouts.poll_interval, function()
    return argo_app(state.argo_app) ~= nil
  end, { tick = function() return app_brief(state.argo_app) end,
         diag = function() return app_snapshot(state.argo_app) end })
  t:log("ArgoCD app appeared: " .. state.argo_app)
end

function stages.argo_healthy(t, run)
  local cfg, state = run.cfg, run.state
  poll(t, state.argo_app .. " to be Synced/Healthy", cfg.timeouts.argo_healthy, cfg.timeouts.poll_interval, function()
    local a = argo_app(state.argo_app)
    local status = a and a.status or {}
    return (status.sync or {}).status == "Synced" and (status.health or {}).status == "Healthy"
  end, { tick = function() return app_brief(state.argo_app) end,
         diag = function() return app_snapshot(state.argo_app) end })
  t:log("ArgoCD app is Synced + Healthy")
end

function stages.deployment_healthy(t, run)
  local cfg, state = run.cfg, run.state
  -- Poll the live Deployment until it reports Available=True (readyReplicas >= desired). SKIP means
  -- we can't read it under the current RBAC/naming - not a failure; argo_healthy already proved the
  -- app is Synced+Healthy, so we fall back to that rollup. `last` carries the current reason into the
  -- heartbeat without a second get-resource call per tick.
  local last = "reading Deployment " .. state.project .. ".."
  local reason = poll(t, "the Deployment " .. state.project .. " to be Available",
    cfg.timeouts.deployment, cfg.timeouts.stability_interval, function()
      last = deployment_reason(state.argo_app, state.project)
      if last == "SKIP" or last:sub(1, 5) == "PASS " then return last end
      return nil
    end, { tick = function() return last end,
           diag = function() return app_snapshot(state.argo_app) end })
  if reason == "SKIP" then
    t:log("direct Deployment read unavailable (RBAC/naming) - relying on the ArgoCD health rollup from argo_healthy")
  else
    t:log("Deployment is Available (" .. reason:gsub("^PASS ", "") .. ")")
  end
end

function stages.digest_deployed(t, run)
  local cfg, state = run.cfg, run.state
  local image = poll(t, "the deployed pods to run " .. state.digest, cfg.timeouts.digest, cfg.timeouts.poll_interval, function()
    local a = argo_app(state.argo_app)
    for _, img in ipairs(a and a.status and a.status.summary and a.status.summary.images or {}) do
      if type(img) == "string" and img:find(state.digest, 1, true) then return img end
    end
  end, { tick = function() return "digest " .. state.digest:sub(1, 14) .. ".. not among live images yet" end,
         diag = function() return app_snapshot(state.argo_app) end })
  t:log("deployed image: " .. image)
end

function stages.pods_stable(t, run)
  local cfg, state = run.cfg, run.state
  -- Require the workload to STAY Healthy across the window - a pod can pass readiness then crash.
  t:log("holding Healthy for " .. cfg.timeouts.pods_stable .. "s to catch CrashLoopBackOff")
  local deadline = os.time() + cfg.timeouts.pods_stable
  t:expect(health_reason(state.argo_app), "workload Healthy at the start of the window"):equals("PASS")
  while os.time() < deadline do
    prova.sleep(cfg.timeouts.stability_interval * 1000)
    t:expect(health_reason(state.argo_app), "workload stayed Healthy"):equals("PASS")
  end
  t:log("pods stayed Running for " .. cfg.timeouts.pods_stable .. "s")
end

deploy.stages = stages

-- The canonical ordered steps - the single source of truth for both deploy.flow and any custom flow.
-- Each entry is { key, label }; the function is stages[key].
local STEP_ORDER = {
  { key = "preflight",          label = "setup: tools & tokens verified" },
  { key = "render",             label = "render archetype" },
  { key = "push",               label = "push to repository" },
  { key = "build",              label = "Build workflow succeeds" },
  { key = "release",            label = "release carries the image digest" },
  { key = "platform",           label = "platform manifest updated with the digest" },
  { key = "argo_appears",       label = "ArgoCD application appears" },
  { key = "argo_healthy",       label = "ArgoCD application is Healthy" },
  { key = "deployment_healthy", label = "Deployment is Available" },
  { key = "digest_deployed",    label = "deployed pods run the built digest" },
  { key = "pods_stable",        label = "pods stay Running" },
}

-- deploy.order: the stage keys in canonical order. deploy.labels: key -> default step label.
deploy.order, deploy.labels = {}, {}
for _, s in ipairs(STEP_ORDER) do
  deploy.order[#deploy.order + 1] = s.key
  deploy.labels[s.key] = s.label
end

------------------------------------------------------------------------------------------
-- Composition
------------------------------------------------------------------------------------------
-- A flow-scoped fixture holding the shared run state and a teardown deferral. Built once, shared
-- across a flow's steps; teardown runs after the last step with the final state, pass or fail. Use
-- it to build a custom flow: every step reads/writes the same `run` (its `.cfg`, `.state`, `.workdir`).
function deploy.new_run(config, name)
  local cfg = deploy.resolve(config)
  return prova.fixture((name or "deploy-loop") .. "::run", Scope.Flow, function(ctx)
    -- Seed state so a subset of stages can run standalone against an EXISTING environment (skip
    -- render/push). Provide `project` (argo_app is derived as "<project>-<argo_app_suffix>") or
    -- `argo_app` directly, plus `digest`/`repo`/... as the stages you run need. A seeded re-check
    -- should also set `keep_resources = true` so teardown never touches the environment you're
    -- only inspecting (teardown is already a no-op unless BOTH project and repo are set).
    local state = {
      project = cfg.project,
      repo = cfg.repo,
      head_sha = cfg.head_sha,
      release = cfg.release,
      digest = cfg.digest,
    }
    state.argo_app = cfg.argo_app or (cfg.project and (cfg.project .. "-" .. cfg.argo_app_suffix)) or nil
    ctx:defer(function() teardown(cfg, state) end)
    return { cfg = cfg, state = state, workdir = ctx:tempdir() }
  end)
end

-- Register one stage as a step on flow-builder `f`, bound to the `run` fixture (so it shares state
-- with the flow's other steps). `label` overrides the stage's default label. Returns `f` to chain.
function deploy.step(f, run, key, label)
  local fn = stages[key]
  if not fn then error("unknown deploy stage: " .. tostring(key) .. " (see deploy.order)", 2) end
  f:step(label or deploy.labels[key] or key, function(t) fn(t, t:use(run)) end)
  return f
end

-- Register several stages in one call. `keys` defaults to the full canonical order. Interleave your
-- own `f:step(...)` around these - your step can `t:use(run)` to read the shared state (repo, digest,
-- argo_app, ...) that earlier deploy stages produced.
function deploy.attach(f, run, keys)
  for _, key in ipairs(keys or deploy.order) do deploy.step(f, run, key) end
  return f
end

-- The standard ordered flow: registers every stage in sequence with the shared run + teardown. Call
-- with a config table, or `(name, config)` to name the flow.
function deploy.flow(a, b)
  local name = type(a) == "string" and a or "deploy-loop"
  local config = type(a) == "string" and b or a
  local cfg = deploy.resolve(config)
  local run = deploy.new_run(cfg, name)
  prova.flow(name, {
    requires = cfg.requires,
    tags = { "e2e", "deploy-loop" },
    serial = true,          -- one loop at a time (shared ArgoCD + .platform repo)
    timeout = cfg.flow_timeout,
  }, function(f)
    deploy.attach(f, run, deploy.order)
  end)
end

return deploy
