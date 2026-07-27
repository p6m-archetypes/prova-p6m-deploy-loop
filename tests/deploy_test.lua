--- Self-test for the `deploy` plugin. The live flow needs real infra (archetect/gh/argocd + a
--- cluster), so this exercises the pure surface instead: config resolution, env layering, and the
--- exported API shape. The flow itself is proven by consumers (an archetype repo's e2e suite).

local deploy = require("deploy")

local ALL_STAGES = { "preflight", "render", "push", "build", "release", "platform",
  "argo_appears", "argo_healthy", "deployment_healthy", "digest_deployed", "pods_stable" }

prova.test("exports the documented surface", function(t)
  t:expect(type(deploy.flow), "deploy.flow"):equals("function")
  t:expect(type(deploy.new_run), "deploy.new_run"):equals("function")
  t:expect(type(deploy.step), "deploy.step"):equals("function")
  t:expect(type(deploy.attach), "deploy.attach"):equals("function")
  t:expect(type(deploy.resolve), "deploy.resolve"):equals("function")
  t:expect(type(deploy.from_env), "deploy.from_env"):equals("function")
  t:expect(type(deploy.defaults), "deploy.defaults"):equals("table")
  for _, name in ipairs(ALL_STAGES) do
    t:expect(type(deploy.stages[name]), "stage " .. name):equals("function")
  end
end)

prova.test("order + labels are complete and canonical", function(t)
  t:expect(deploy.order, "deploy.order lists every stage"):equals(ALL_STAGES)
  for _, key in ipairs(deploy.order) do
    t:expect(deploy.labels[key], "label for " .. key):never():is_nil()
    t:expect(type(deploy.stages[key]), "stages[" .. key .. "]"):equals("function")
  end
end)

prova.test("step + attach register onto a flow builder", function(t)
  -- A minimal fake flow builder records the (label) of each registered step.
  local registered = {}
  local fake_f = { step = function(self, label) registered[#registered + 1] = label end }
  local fake_run = {}   -- deploy.step only passes it through to t:use at run time

  deploy.step(fake_f, fake_run, "render")
  deploy.step(fake_f, fake_run, "push", "custom label")
  t:expect(registered, "step uses default then custom label"):equals({ "render archetype", "custom label" })

  registered = {}
  deploy.attach(fake_f, fake_run, { "preflight", "build" })
  t:expect(registered, "attach registers the given keys in order")
    :equals({ "setup: tools & tokens verified", "Build workflow succeeds" })

  local ok = pcall(deploy.step, fake_f, fake_run, "nope")
  t:expect(ok, "unknown stage key raises"):is_false()
end)

prova.test("carries the requested default timeouts", function(t)
  local d = deploy.defaults.timeouts
  t:expect(d.argo_appear, "ArgoCD appear default = 5 min"):equals(300)
  t:expect(d.deployment, "Deployment healthy default = 3 min"):equals(180)
  t:expect(d.pods_stable, "pods stable default = 30 s"):equals(30)
end)

prova.test("retries a failed Build by default", function(t)
  t:expect(deploy.defaults.build_retries, "Build re-runs on failure = 3"):equals(3)
  t:expect(deploy.resolve{ build_retries = 0 }.build_retries, "0 disables the retry"):equals(0)
end)

prova.test("resolve merges overrides and fills derived fields", function(t)
  local cfg = deploy.resolve{ github_org = "acme-playground", timeouts = { deployment = 240 } }
  t:expect(cfg.github_org, "override wins"):equals("acme-playground")
  t:expect(cfg.platform_repo, "platform_repo derived from org"):equals("acme-playground/.platform")
  t:expect(cfg.timeouts.deployment, "timeout override wins"):equals(240)
  t:expect(cfg.timeouts.argo_appear, "untouched timeout keeps its default"):equals(300)
  t:expect(cfg.project_prefix, "a project prefix is derived"):never():is_empty()
  t:expect(cfg.requires, "requires defaults through"):contains("argocd")
end)

prova.test("resolve honors an explicit platform_repo", function(t)
  local cfg = deploy.resolve{ github_org = "acme", platform_repo = "acme/gitops" }
  t:expect(cfg.platform_repo):equals("acme/gitops")
end)

-- Fixtures must be declared at file top-level; seed two runs to assert new_run's seeding.
local seeded = deploy.new_run{
  project = "acme-svc", argo_app_suffix = "dev-x", digest = "sha256:abc", keep_resources = true,
}
local seeded_explicit = deploy.new_run({ argo_app = "explicit-app", keep_resources = true }, "explicit")

-- A flow-scoped fixture is only usable inside a flow, so assert the seeding from one (keep_resources
-- is set, so teardown is a no-op and no infra is touched).
prova.flow("new_run seeds state for a standalone re-check", function(f)
  f:step("seeded identity", function(t)
    local run = t:use(seeded)
    t:expect(run.state.project, "project seeded"):equals("acme-svc")
    t:expect(run.state.argo_app, "argo_app derived from project + suffix"):equals("acme-svc-dev-x")
    t:expect(run.state.digest, "digest seeded"):equals("sha256:abc")
    t:expect(t:use(seeded_explicit).state.argo_app, "explicit argo_app wins"):equals("explicit-app")
  end)
end)

prova.test("from_env layers overrides over env and defaults", function(t)
  -- No env set here, so the result is defaults plus the explicit override.
  local cfg = deploy.resolve(deploy.from_env{ github_org = "from-override" })
  t:expect(cfg.github_org, "explicit override wins over env/defaults"):equals("from-override")
  t:expect(cfg.environment, "unset env falls through to the default"):equals("dev")
end)
