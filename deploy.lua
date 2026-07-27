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
  -- Re-runs of a FAILED Build workflow before the stage gives up (total attempts = 1 + this). Each
  -- attempt gets the full timeouts.build budget, so raise flow_timeout if you expect to use them all.
  build_retries    = 3,

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
    build_retries    = n("BUILD_RETRIES"),
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

------------------------------------------------------------------------------------------
-- Redaction
------------------------------------------------------------------------------------------
-- GitHub Actions masks REGISTERED secrets as *** in run logs, but that only covers a secret's exact
-- value. Workflow logs routinely carry credentials it cannot know to mask:
--   * tokens minted during the run - GITHUB_TOKEN, an OIDC exchange, a JFrog access token,
--   * a secret transformed before it is printed - base64'd into a docker/npm config, URL-encoded,
--     or embedded in a clone/registry URL as userinfo,
--   * a tool echoing its own auth - `set -x` traces, `curl -v` headers, config dumps.
-- Since this plugin tails a failed run's log to the console, it must not relay any of that. Every
-- external output it echoes goes through `deploy.redact` first, which masks in two layers: exact
-- values registered at runtime (the strongest match), then the shape/context patterns below.
--
-- Redaction is for OUTPUT ONLY - nothing parsed for control flow (digests, conclusions, run ids) is
-- passed through it.

local registered_secrets = {}

local function pattern_escape(s) return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")) end

-- A key or flag name whose value is a credential. Substring match, case-insensitive, so it catches
-- ARTIFACTORY_IDENTITY_TOKEN, AZURE_CLIENT_SECRET, AccountKey, --registry-password, "auth", ...
local SECRET_KEY_WORDS = {
  "secret", "token", "password", "passwd", "passphrase", "credential", "apikey", "api_key",
  "accesskey", "access_key", "privatekey", "private_key", "accountkey", "account_key",
  "connectionstring", "connection_string", "signature", "sas",
}

local function is_secret_key(key)
  local k = key:lower()
  if k == "auth" or k == "authorization" then return true end
  for _, word in ipairs(SECRET_KEY_WORDS) do
    if k:find(word, 1, true) then return true end
  end
  return false
end

-- Mask a value but keep the quoting/JSON punctuation around it, so a redacted line still reads as the
-- structure it was ("auth": "***" rather than "auth": ***). Already-masked values are left alone.
local function mask_value(v)
  local lead = v:match('^[%[{%("\']*') or ""
  local trail = v:match('[%]}%)"\',;]*$') or ""
  local core = v:sub(#lead + 1, #v - #trail)
  if core == "" or core == "***" then return v end
  return lead .. "***" .. trail
end

-- Mask the value of every `key=value` / `key: value` / `"key": "value"` pair whose key names a secret.
--
-- Hand-rolled rather than a `gsub` because gsub consumes a whole match even when the key turns out to
-- be harmless - which hides any pair NESTED inside that span, and both variants of that bug leak a real
-- credential:
--   * {"auths":{"ybor.jfrog.io":{"auth":"<secret>"}}} - the outer key "auths" matches with everything
--     up to the first } as its value, so the inner "auth" is never examined;
--   * env: AZURE_CLIENT_SECRET=<secret> - the harmless key "env" swallows the whole rest of the line.
-- Declining a key here advances the cursor past the KEY AND SEPARATOR only, leaving the value region
-- open to the scan, so nested pairs are always reached. (Both cases are covered in redact_test.lua.)
--
-- The separator tolerates only spaces/tabs, never a newline: `%s*` would let a bare `password:` at the
-- end of a line mask the first word of the NEXT line.
local function mask_pairs(text)
  local out, pos = {}, 1
  while pos <= #text do
    local s, e, key = text:find('([%w_%-%.]+)["\']?[ \t]*[=:][ \t]*', pos)
    if not s then break end

    local masked
    -- A quoted value: mask inside the quotes, keeping them.
    local _, q_end, open, value, close = text:find('^(["\'])([^"\']*)(["\'])', e + 1)
    if q_end then
      if value ~= "" and is_secret_key(key) then masked = open .. "***" .. close end
    else
      -- A bare value: stops at whitespace and JSON/shell separators, so it never spans lines or
      -- crosses into a nested object.
      local _, v_end, bare = text:find('^([^%s,;{}%[%]"\']+)', e + 1)
      if v_end and is_secret_key(key) then masked, q_end = mask_value(bare), v_end end
    end

    out[#out + 1] = text:sub(pos, e)
    pos = e + 1
    if masked then
      out[#out + 1] = masked
      pos = q_end + 1
    end
  end
  out[#out + 1] = text:sub(pos)
  return table.concat(out)
end

-- Credential shapes worth masking wherever they appear, with no key to go on. Ordered: the header
-- rules run before the token shapes so they swallow a whole header value rather than one word of it.
local SECRET_PATTERNS = {
  { "([Aa]uthorization%s*:%s*)[^\r\n]+", "%1***" },      -- header, incl. the scheme + token
  { "([Bb]earer%s+)[%w%-%._~%+/=]+", "%1***" },
  { "([Bb]asic%s+)[%w%+/=]+", "%1***" },
  { "(%a[%w%+%-%.]*://)[^/@%s]+@", "%1***:***@" },       -- URL userinfo (x-access-token:ghs_..@)
  { "%f[%w]gh[pousr]_[%w]+", "***" },                    -- GitHub PAT / OAuth / user / server / refresh
  { "%f[%w]github_pat_[%w_]+", "***" },
  { "%f[%w]eyJ[%w%-_]*%.[%w%-_]+%.[%w%-_]+", "***" },    -- JWT: JFrog access, OIDC, k8s SA tokens
  { "%f[%w]cmVmdGtu[%w%+/=]+", "***" },                  -- JFrog reference token (base64 "reftkn")
  { "%f[%w]A[KS]IA[%u%d]+", "***" },                     -- AWS access key id (long-lived / temporary)
  { "%f[%w]npm_[%w]+", "***" },
  { "%f[%w]xox[abprs]%-[%w%-]+", "***" },                -- Slack
  { "https://hooks%.slack%.com/services/[%w%-/]+", "***" },
}

-- Mask every credential this can recognize in `text`. Safe to call on anything - non-strings and the
-- empty string pass through untouched.
function deploy.redact(text)
  if type(text) ~= "string" or text == "" then return text end

  -- Whole PEM blocks first: they are the only secret that spans lines.
  text = text:gsub("%-%-%-%-%-BEGIN[^\n]*PRIVATE KEY%-%-%-%-%-.-%-%-%-%-%-END[^\n]*%-%-%-%-%-",
    "***** REDACTED PRIVATE KEY *****")

  -- Exact values we hold (see deploy.register_secret) - the only layer that catches an opaque
  -- random with no telltale shape or key.
  for value in pairs(registered_secrets) do
    text = text:gsub(pattern_escape(value), "***")
  end

  for _, rule in ipairs(SECRET_PATTERNS) do
    text = text:gsub(rule[1], rule[2])
  end

  -- key=value / key: value / "key": "value" - the workhorse for opaque secrets, which are only
  -- recognizable by what they are assigned to.
  text = mask_pairs(text)

  -- The space-separated flag form: --token abc123, --registry-password hunter2. The value must not
  -- itself start with "-", so a declined flag can never consume the NEXT flag as its value and hide it
  -- (`--debug --password <secret>`). A single-letter flag (-p) is unknowable and stays in the clear.
  text = text:gsub("(%-%-?[%w%-]+)([ \t]+)([^%s%-][^%s]*)", function(flag, sep, value)
    if is_secret_key((flag:gsub("^%-+", ""))) then return flag .. sep .. mask_value(value) end
  end)

  return text
end

-- Register an exact value that must never reach the console, and return it unchanged so it can wrap
-- the fetch itself: `local token = deploy.register_secret(trim(sh("gh auth token").stdout))`. Values
-- under 8 characters are ignored - too short to be a credential, and masking them would shred the log.
function deploy.register_secret(value)
  if type(value) == "string" and #value >= 8 then registered_secrets[value] = true end
  return value
end

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
      if ok and s and s ~= "" then note = " - " .. deploy.redact(s) end
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
    if dok and d and d ~= "" then extra = "\n  current state:\n" .. deploy.redact(d) end
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

-- Fields every `gh` release exposes on `gh run view --json`, plus the ones only newer ones do. `attempt`
-- is NOT universal: an older gh rejects the whole query with `Unknown JSON field: "attempt"` and exits
-- 1. Asking for it unconditionally is what made a SUCCESSFUL Build time out - the state read failed on
-- every poll, so the wait ran to `timeouts.build` and reported a timeout on a run that had passed. So
-- the optional fields are dropped for the rest of the process the first time gh refuses them.
-- The base pair is what the stage actually needs to decide anything; `updatedAt`/`attempt` only sharpen
-- the re-run bookkeeping, and the code degrades cleanly without them.
local BUILD_FIELDS_BASE = "status,conclusion"
local build_fields = BUILD_FIELDS_BASE .. ",updatedAt,attempt"

-- A short, redacted, single-line excerpt of command output, for a diagnostic that names what actually
-- came back instead of leaving the next reader to guess.
local function excerpt(s, limit)
  local one_line = deploy.redact(trim(s or "")):gsub("%s+", " ")
  limit = limit or 160
  if #one_line > limit then one_line = one_line:sub(1, limit) .. "..." end
  return one_line
end

-- The Build run's state in one `gh` call. Returns the parsed object, or nil + a human reason + whether
-- the failure looks PERMANENT.
--
-- That last distinction is the whole point. `gh` exiting non-zero means gh itself rejected the request
-- (an unsupported --json field, a repo the token cannot see) - that will not fix itself, so the caller
-- should say so immediately. Output that merely fails to parse while gh exited 0 is NOT permanent: it
-- may be a blip, and failing the stage on one odd read fails Builds that went on to succeed. The reason
-- carries an excerpt of what gh printed, so a recurrence is diagnosable instead of mysterious.
local function build_run_state(repo, run_id)
  local function view(fields)
    return sh("gh run view " .. run_id .. " --repo " .. repo .. " --json " .. fields)
  end
  local r = view(build_fields)
  if not r:ok() and build_fields ~= BUILD_FIELDS_BASE then
    local base = view(BUILD_FIELDS_BASE)
    if base:ok() then build_fields = BUILD_FIELDS_BASE; r = base end
  end
  if not r:ok() then
    local why = trim(r.stderr) ~= "" and r.stderr or r.stdout
    why = excerpt(why)
    return nil, (why ~= "" and why or ("gh run view exited " .. tostring(r.code))), true
  end
  -- Pull the JSON object out rather than parsing the whole stream, so a notice line printed alongside it
  -- doesn't make the read fail.
  local body = r.stdout:match("%b{}")
  if not body then
    return nil, string.format("gh run view exited 0 with no JSON (%d bytes: %s)",
      #r.stdout, excerpt(r.stdout, 80))
  end
  local ok, data = pcall(prova.parse.json, body)
  if not ok or type(data) ~= "table" then
    return nil, "gh run view returned unparseable JSON: " .. excerpt(body, 80)
  end
  return data
end

-- Identify the FINISHED attempt we just consumed the result of, so a later wait can tell a genuinely
-- new attempt from the one already seen. Returns nil when neither field is available - callers then
-- skip the check rather than gate on a constant, which would wait forever.
local function finished_signature(s)
  if not s.attempt and not s.updatedAt then return nil end
  return tostring(s.attempt or "?") .. "@" .. tostring(s.updatedAt or "?")
end

-- A one-line progress note for the Build heartbeat: the overall status PLUS the job/step currently in
-- flight, so a live run shows WHICH step it is on, not just "in_progress". One `gh` call, asking only
-- for fields every gh release has (the wait's own label already carries the attempt number); degrades
-- to a bare status if the jobs aren't readable yet.
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
-- that dies mid-loop is diagnosable inline (teardown wipes the repo right after). The log tail is the
-- one place this plugin relays third-party output verbatim, so it goes through `deploy.redact`: a
-- workflow log carries credentials GitHub's own *** masking misses whenever the printed form isn't the
-- registered value (runtime-minted tokens, base64'd configs, tokens embedded in URLs). We tail it
-- rather than dumping the whole run log, which keeps both the console and the blast radius small.
local function log_build_failure(t, repo, run_id, url, what)
  t:log((what or "Build") .. " failed - see " .. url)
  local failed = sh("gh run view " .. run_id .. " --repo " .. repo ..
    [[ --json jobs -q '.jobs[] | select(.conclusion=="failure") | "  job: " + .name, (.steps[] | select(.conclusion=="failure") | "    step: " + .name)']])
  if trim(failed.stdout) ~= "" then t:log("failed jobs/steps:\n" .. deploy.redact(failed.stdout)) end
  local logs = sh("gh run view " .. run_id .. " --repo " .. repo .. " --log-failed 2>/dev/null | tail -n 100")
  if trim(logs.stdout) ~= "" then
    t:log("failed step log (last 100 lines, credentials redacted):\n" .. deploy.redact(logs.stdout))
  end
end

-- How many consecutive unreadable state reads mean a real problem rather than a blip. At the default
-- 15s poll interval that is about 75 seconds of nothing readable before the stage gives up.
local UNREADABLE_STRIKES = 5

-- Wait for the Build run to finish and return its state. `already_seen` is the signature of an attempt
-- whose result a previous wait already consumed: while gh still reports THAT attempt as completed, the
-- re-run has not registered yet and we keep waiting. It is nil on the first wait - there is nothing to
-- disambiguate, so the first `completed` is the answer and a Build that passes first time continues
-- immediately, with no dependence on any optional field.
local function await_build(t, cfg, repo, run_id, desc, already_seen)
  local reason, strikes = nil, 0
  local final = poll(t, desc, cfg.timeouts.build, cfg.timeouts.poll_interval, function()
    local s; s, reason = build_run_state(repo, run_id)
    if not s then
      -- An unreadable run must never masquerade as a long wait (the YP6M-3183 failure), but one odd read
      -- must not fail a Build either (the YP6M-3185 failure). So: ride out a few, then stop and report.
      -- Reported by returning a sentinel rather than raising - prova.retry SWALLOWS an error from the
      -- predicate and retries to the timeout, which is the very failure mode being guarded here.
      strikes = strikes + 1
      if strikes >= UNREADABLE_STRIKES then return { unreadable = reason } end
      return nil
    end
    strikes, reason = 0, nil
    if s.status ~= "completed" then return nil end
    if already_seen and finished_signature(s) == already_seen then return nil end
    return s
  end, { tick = function() return reason or build_brief(repo, run_id) end })
  if final and final.unreadable then
    error(string.format("cannot read Build run %s - %d consecutive attempts failed: %s",
      run_id, UNREADABLE_STRIKES, final.unreadable), 0)
  end
  return final
end

------------------------------------------------------------------------------------------
-- Teardown
------------------------------------------------------------------------------------------
-- Remove kubernetes/<project>/ from the .platform repo by pushing to main (that branch is
-- unprotected and the platform bot commits these test folders directly, so there is no review gate
-- to bypass). Never force-pushes: on a concurrent-push reject it rebases and retries. Once the folder
-- is gone the ApplicationSet prunes the ArgoCD app + namespace.
local function teardown_platform(log, cfg, project)
  -- The token is embedded in the push URL below, so register it: from here on `deploy.redact` masks it
  -- out of anything this run echoes, including a git error that quotes the remote back at us.
  local token = deploy.register_secret(trim(sh("gh auth token").stdout))
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
  -- archetect's stderr can echo the registry credentials a composed library injects, so it is
  -- redacted before it becomes an assertion message.
  local r = sh(cmd, { timeout = cfg.timeouts.render .. "s" })
  t:expect(r.code, "archetect render\n" .. deploy.redact(r.stderr)):equals(0)

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

  -- Prove the state read works before settling in to wait on it, but fail up front ONLY when gh itself
  -- rejected the request - an unsupported --json field on an older gh, a repo the token cannot see. That
  -- will not fix itself, and polling through it turns it into a silent `timeouts.build` timeout on a
  -- Build that had SUCCEEDED. Anything else (gh exited 0, output just wasn't parseable) is left to the
  -- wait, which rides out a few and then reports: one odd read must not fail a Build that is fine.
  local blocked, permanent
  for probe = 1, 3 do
    local s, why, fatal = build_run_state(state.repo, run_id)
    blocked, permanent = (not s) and why or nil, fatal
    if s or not fatal then break end
    if probe < 3 and cfg.timeouts.stability_interval > 0 then
      prova.sleep(cfg.timeouts.stability_interval * 1000)
    end
  end
  if blocked and permanent then error("cannot read Build run " .. run_id .. ": " .. blocked, 0) end
  if blocked then t:log("Build run not readable yet (" .. blocked .. ") - waiting anyway") end

  -- A failed Build is re-run in place (`gh run rerun` = a new attempt on the SAME run) up to
  -- cfg.build_retries times, since a fresh repo's first build fails on infrastructure flake often
  -- enough - runner/registry/dependency-mirror hiccups - that one failure is not yet a verdict on the
  -- archetype. A Build that passes first time just continues. Every failure is still logged in full, so
  -- a run that only passed on a retry says so.
  local attempts = 1 + cfg.build_retries
  local seen   -- signature of the finished attempt we already have a verdict for (nil until we do)
  for attempt = 1, attempts do
    local desc = attempts > 1
      and string.format("Build attempt %d/%d to finish", attempt, attempts)
      or "the Build workflow to finish"
    local finished = await_build(t, cfg, state.repo, run_id, desc, seen) or {}
    seen = finished_signature(finished)
    local conclusion = (finished.conclusion or "") ~= "" and finished.conclusion or "unknown"
    if conclusion == "success" then
      t:log(attempt == 1 and "Build succeeded"
        or string.format("Build succeeded on attempt %d/%d", attempt, attempts))
      return
    end

    local what = attempts > 1 and string.format("Build attempt %d/%d", attempt, attempts) or "Build"
    log_build_failure(t, state.repo, run_id, url, what)
    if attempt == attempts then
      error(string.format("Build workflow failed: %s (after %d attempt%s)",
        conclusion, attempts, attempts == 1 and "" or "s"), 0)
    end

    t:log(string.format("re-running Build run %s (attempt %d/%d)", run_id, attempt + 1, attempts))
    local r = sh("gh run rerun " .. run_id .. " --repo " .. state.repo)
    if not r:ok() then
      local why = trim(r.stderr) ~= "" and trim(r.stderr) or trim(r.stdout)
      error("could not re-run Build run " .. run_id .. ": " .. why, 0)
    end
  end
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
