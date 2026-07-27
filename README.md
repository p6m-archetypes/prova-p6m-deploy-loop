# prova-p6m-deploy-loop

A reusable [Prova](https://github.com/prova-rs/prova) plugin that proves the **p6m archetype deploy
loop** end to end: render an archetype, push it to a real GitHub repo, and follow the whole GitOps
pipeline the generated CI drives, asserting each stage - then always tear down what it created.

```
render -> push to main -> Build workflow (lint/test/build + docker publish) -> git tag + release
(image digest) -> CI dispatches a .platform manifest update -> ApplicationSet creates an ArgoCD app
-> Synced/Healthy -> Deployment Available -> pods run the built digest -> pods stay Running
```

It only **triggers and verifies**: the platform's own automation creates every cluster-side object.
The only things it creates are the GitHub test repo and, on teardown, a commit that removes the
manifest folder from the `.platform` repo. Every fact is read from ArgoCD (`argocd app list/…`), so
no direct cluster RBAC is required.

## Use it

Declare the plugin in the consumer's `prova.toml` (a path pin while incubating; a git tag once
published):

```toml
[plugins]
deploy = { path = "../prova-p6m-deploy-loop" }
# deploy = "p6m-archetypes/prova-p6m-deploy-loop@v1"
```

Put the suite in a directory that is **not** in the default `proofs` (so it never runs with the
acceptance suite), e.g. `e2e/deploy_loop_test.lua`, and add a profile:

```toml
[profiles.e2e]
proofs = ["e2e"]
jobs = 1
```

### The whole flow in one call

```lua
local deploy = require("deploy")

deploy.flow(deploy.from_env{
  archetype_dir = ".",                       -- render the consumer's current code
  answers = {                                -- the consumer owns its archetype's answers
    org_name = "ybor", solution_name = "playground",
    prefix_name = "Example",                 -- overridden per run for a unique repo name
    suffix_name = "Service", persistence = "None",
    -- ...archetype-specific answers...
  },
})
```

`deploy.flow` registers a `prova.flow` (serial, `requires` the live CLIs) with these ordered steps:

| Step | Verifies |
|---|---|
| `setup` | `gh` + `argocd` are authenticated |
| `render` | `archetect` renders; the generated CI is the full loop (not the stub) |
| `push` | the repo is created and pushed |
| `build` | the Build workflow is kicked off and succeeds (a failed run is re-run in place, up to `build_retries` = **3** times) |
| `release` | a git tag + release exist; **captures the image digest** |
| `platform` | the `.platform` manifest was updated with that digest |
| `argo_appears` | the ArgoCD app appears (default **5 min**) |
| `argo_healthy` | the app is Synced + Healthy |
| `deployment_healthy` | the live Deployment reports Available=True, readyReplicas >= desired (default **3 min**) |
| `digest_deployed` | the deployed pods run the built digest |
| `pods_stable` | the workload stays Healthy through a window (default **30 s**) |

A Build that succeeds on the first attempt just continues. A failed one is **re-run in place**
(`gh run rerun` - a new attempt on the same run) before the step gives up, because a fresh repo's first
build fails on infrastructure flake (runner, registry, dependency mirror) often enough that one failure
isn't yet a verdict on the archetype. Every failure is
logged in full - run URL, failed jobs/steps, log tail - so a run that only passed on a retry says so.
Total attempts are `1 + build_retries` (default `1 + 3`), each with the full `timeouts.build` budget;
if you expect to use them all, raise `flow_timeout` to match (4 x 1800 s exceeds the default `5400s`).
Set `build_retries = 0` for fail-on-first-failure.

The step only needs `gh run view --json status,conclusion` to decide anything; `updatedAt` and `attempt`
sharpen the re-run bookkeeping and are dropped automatically on a `gh` that doesn't expose them. If the
run cannot be read at all, the step fails immediately with `gh`'s own message rather than polling to a
timeout on a Build that may well have succeeded.

### Credentials never reach the console

When a Build fails, the step tails the failed steps' log so the run is diagnosable inline - teardown
wipes the repo moments later. GitHub Actions masks *registered* secrets as `***`, but that only matches
a secret's exact value, so a workflow log still carries credentials in the clear:

- tokens minted during the run - `GITHUB_TOKEN`, an OIDC exchange, a JFrog access token,
- a secret transformed before it was printed - base64'd into a docker/npm config, URL-encoded, or
  embedded in a clone/registry URL as `user:token@host`,
- a tool echoing its own auth - `set -x` traces, `curl -v` headers, config dumps.

Every external output this plugin echoes therefore goes through `deploy.redact` first, which masks by
registered value, by credential shape (GitHub/JFrog/AWS/npm/Slack tokens, JWTs, PEM blocks,
`Authorization` headers, URL userinfo), and by key name (`*_TOKEN=`, `"auth":`, `--password`, …).
Ordinary build output is left intact - the log is the only diagnostic a failed run leaves behind, so
over-redaction is treated as a real cost.

Call it on anything your own steps log:

```lua
local out = shell.run("some-tool --verbose")
t:log(deploy.redact(out.stdout))
deploy.register_secret(my_token)   -- also mask this exact value from here on
```

Redaction is for output only - nothing parsed for control flow passes through it.

Teardown runs at the end - whether the flow passed, failed, or skipped - unless `keep_resources`
is set: it removes `kubernetes/<project>/` from the `.platform` repo (rebase-and-retry push to the
unprotected `main`, never force) and archives/deletes the test repo.

### Compose your own flow

Every step is reusable. `deploy.new_run(config)` gives you the shared, flow-scoped run state +
teardown; `deploy.step(f, run, key)` registers one stage as a step (default label, or pass your
own); `deploy.attach(f, run, keys)` registers several. `deploy.order` is the canonical key list and
`deploy.labels` maps each key to its default label.

```lua
local deploy = require("deploy")
local cfg = deploy.resolve(config)       -- so you can reuse cfg.requires / cfg.flow_timeout
local run = deploy.new_run(cfg)

prova.flow("smoke", { requires = cfg.requires, serial = true, timeout = cfg.flow_timeout }, function(f)
  deploy.attach(f, run, { "preflight", "render", "push", "build" })   -- a subset, in any order
end)
```

Interleave your own steps - they share the same `run`, so a custom step can read the state earlier
stages produced (`repo`, `head_sha`, `release`, `digest`, `argo_app`, `project`, `project_dir`):

```lua
prova.flow("deploy-and-smoke", { requires = cfg.requires, serial = true, timeout = cfg.flow_timeout }, function(f)
  deploy.attach(f, run, deploy.order)                    -- the full standard loop...
  f:step("hit /health", function(t)                      -- ...then your own step on top
    local st = t:use(run).state
    t:log("smoke-testing " .. st.repo .. " @ " .. st.digest)
    -- ... resolve the app's URL and probe it ...
  end)
end)
```

Or drive stages directly - each is `fn(t, run)`:

```lua
f:step("render", function(t) deploy.stages.render(t, t:use(run)) end)
```

The exported keys, in order: `preflight`, `render`, `push`, `build`, `release`, `platform`,
`argo_appears`, `argo_healthy`, `deployment_healthy`, `digest_deployed`, `pods_stable`.

## Re-check a stage against an existing environment

Run a single stage (or a subset) against an **already-deployed** app, skipping render/push - useful
when a run failed late and you want to re-probe just that check. Seed the identity via config and set
`keep_resources = true` so the re-check never tears anything down.

One-off, no test file - drive the stage from `prova eval` (the ArgoCD-observing stages use only
`t:log` + polling, so an `eval` `ctx` works as the `t`):

```sh
prova eval 'local d = require("deploy")
d.stages.deployment_healthy(ctx, { cfg = d.resolve{ timeouts = { deployment = 120 } },
                                   state = { argo_app = "my-svc-dev-azure-westus2", project = "my-svc" } })
return "Deployment is Available"'
```

Repeatable - a tiny composed flow, selectable by name/keyword (`prova -k recheck`):

```lua
local deploy = require("deploy")
local run = deploy.new_run{ project = "my-svc", keep_resources = true }  -- derives argo_app; add digest = "sha256:..." for platform/digest_deployed
prova.flow("recheck", { requires = { "argocd" } }, function(f)
  deploy.step(f, run, "deployment_healthy")
end)
```

## Configuration

`deploy.flow(config)` and `deploy.new_run(config)` take a `deploy.Config`; read `deploy.defaults`
for every knob. `deploy.from_env(overrides)` builds one from environment variables (then layers
`overrides` on top) - handy in CI:

| Env | Config field | Default |
|---|---|---|
| `ARCHETYPE_DIR` / `ARCHETYPE_SOURCE` | `archetype_dir` / `archetype_source` | `.` / _(unset)_ |
| `ANSWERS_FILE` | `answers_file` | _(unset; or pass `answers`)_ |
| `GITHUB_ORG` | `github_org` | `ybor-playground` |
| `REPO_NAME` | `repo_name` | _(rendered project name)_ |
| `PLATFORM_REPO` | `platform_repo` | `<github_org>/.platform` |
| `ENVIRONMENT` | `environment` | `dev` |
| `ARGO_APP_SUFFIX` | `argo_app_suffix` | `dev-azure-westus2` |
| `PROJECT_PREFIX` / `PROJECT_SUFFIX` / `RUN_ID` | `project_prefix` / `project_suffix` / `run_id` | `E2e<timestamp>` / `Service` / _(timestamp)_ |
| `PREFIX_KEY` | `prefix_key` | `prefix_name` |
| `KEEP_RESOURCES` | `keep_resources` | `false` |
| `TEARDOWN_PUSH_RETRIES` | `teardown_retries` | `3` |
| `BUILD_RETRIES` | `build_retries` | `3` |
| `E2E_FLOW_TIMEOUT` | `flow_timeout` | `5400s` |
| `CI_TIMEOUT` | `timeouts.build` | `1800` |
| `PLATFORM_TIMEOUT` | `timeouts.platform` | `600` |
| `ARGO_APPEAR_TIMEOUT` | `timeouts.argo_appear` | `300` (5 min) |
| `ARGO_TIMEOUT` | `timeouts.argo_healthy` | `300` |
| `DEPLOYMENT_TIMEOUT` | `timeouts.deployment` | `180` (3 min) |
| `PODS_STABLE_SECONDS` | `timeouts.pods_stable` | `30` |
| `POLL_INTERVAL` | `timeouts.poll_interval` | `15` |

Answers (`answers` / `answers_file`) are archetype-specific and always supplied by the consumer -
the plugin bakes in none.

## Develop

```sh
prova                     # self-test (pure config/API-shape checks; no live infra)
prova plugin lint deploy.lua
```

The live flow is proven by consumers (an archetype repo's `e2e` suite), not here.
