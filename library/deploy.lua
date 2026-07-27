---@meta deploy
--- LuaCATS annotations for the `deploy` Prova plugin - the consumer-facing contract for
--- `local deploy = require("deploy")`. Keep in step with `../deploy.lua`.

------------------------------------------------------------------------------------------
-- Config
------------------------------------------------------------------------------------------

--- Per-stage timeouts, in seconds (except the poll intervals, also seconds).
---@class deploy.Timeouts
---@field render? integer         # archetect render (default 600)
---@field push? integer           # git init + gh repo create --push (default 300)
---@field build? integer          # Build workflow to completion (default 1800)
---@field release? integer        # tag/release/digest to appear (default 300)
---@field platform? integer       # .platform manifest to carry the digest (default 600)
---@field argo_appear? integer    # ArgoCD app to appear (default 300 = 5 min)
---@field argo_healthy? integer   # ArgoCD app to reach Synced/Healthy (default 300)
---@field deployment? integer     # live Deployment to report Available=True (default 180 = 3 min)
---@field digest? integer         # deployed pods to run the built digest (default 300)
---@field pods_stable? integer    # window the workload must STAY Healthy (default 30)
---@field poll_interval? integer  # gap between polls on the long waits (default 15)
---@field stability_interval? integer  # gap between re-samples in fast loops (default 2)

--- Deploy-loop configuration. Everything has a default (see `deploy.defaults`); supply at least the
--- archetype answers (a table or `answers_file`).
---@class deploy.Config
---@field archetype_dir? string       # local archetype checkout to render (default ".")
---@field archetype_source? string    # git URL#ref to render instead (used when archetype_dir has no archetype.yaml)
---@field answers? table<string,any>  # archetype answers as data
---@field answers_file? string        # path to an answers file (YAML/JSON); wins over `answers`
---@field prefix_key? string          # answer key overridden per run for a unique repo name (default "prefix_name")
---@field project_prefix? string      # the unique prefix value (default "E2e<timestamp>")
---@field project_suffix? string      # (default "Service")
---@field run_id? string              # per-run id folded into the default prefix (default timestamp)
---@field github_org? string          # org the test repo is created in (default "ybor-playground")
---@field repo_name? string           # target repo name (default: the rendered project name)
---@field platform_repo? string       # GitOps repo the CI dispatches into (default "<github_org>/.platform")
---@field environment? string         # environment folder/suffix (default "dev")
---@field argo_app_suffix? string     # app is "<project>-<suffix>" (default "dev-azure-westus2")
---@field keep_resources? boolean     # skip teardown (default false)
---@field teardown_retries? integer   # rebase-and-retry attempts for the .platform removal push (default 3)
---@field build_retries? integer      # re-runs of a FAILED Build workflow before giving up (default 3; total attempts = 1 + this, each with the full `timeouts.build` budget)
---@field requires? string[]          # capabilities gating the flow (default {"archetect","gh","git","argocd"})
---@field flow_timeout? string        # whole-flow timeout (default "5400s")
---@field timeouts? deploy.Timeouts
--- Seed fields - set these (instead of running render/push) to run a SUBSET of stages against an
--- existing environment. `project` derives argo_app as "<project>-<argo_app_suffix>"; or set
--- `argo_app` directly. Pair with `keep_resources = true` so a re-check never tears anything down.
---@field project? string             # existing project/repo name (seeds state.project + argo_app)
---@field argo_app? string            # existing ArgoCD app name (overrides the derived one)
---@field repo? string                # existing "<org>/<repo>"
---@field head_sha? string            # existing pushed commit
---@field release? string             # existing release tag
---@field digest? string              # existing image digest ("sha256:...") - needed by platform/digest_deployed

--- Resolved config: a `deploy.Config` merged over the defaults with derived fields filled in.
---@class deploy.ResolvedConfig : deploy.Config

--- The mutable state the stages build up (and teardown reads).
---@class deploy.State
---@field project? string       # rendered project / repo name
---@field project_dir? string   # rendered project directory on disk
---@field repo? string          # "<org>/<project>"
---@field head_sha? string      # pushed commit
---@field release? string       # latest GitHub release tag
---@field digest? string        # built image digest ("sha256:...")
---@field argo_app? string      # ArgoCD application name

--- The value a run fixture yields: the resolved config, the shared mutable state, and a flow-lived
--- scratch dir the render output survives in.
---@class deploy.Run
---@field cfg deploy.ResolvedConfig
---@field state deploy.State
---@field workdir string

------------------------------------------------------------------------------------------
-- Namespace
------------------------------------------------------------------------------------------

--- A deploy-loop stage: reads `run.cfg`, mutates `run.state`, asserts on `t`.
---@alias deploy.Stage fun(t: prova.TestContext, run: deploy.Run)

--- The exported stages, for composing a custom flow. Registration order in `deploy.flow` is:
--- preflight, render, push, build, release, platform, argo_appears, argo_healthy,
--- deployment_healthy, digest_deployed, pods_stable.
---@class deploy.Stages
---@field preflight deploy.Stage           # tools authenticated (gh + argocd)
---@field render deploy.Stage              # archetect render; asserts full-loop CI
---@field push deploy.Stage                # create GitHub repo + push
---@field build deploy.Stage               # Build workflow kicked off + succeeded (re-runs it on failure, up to `build_retries`)
---@field release deploy.Stage             # git tag + release; captures the image digest
---@field platform deploy.Stage            # .platform manifest updated with the digest
---@field argo_appears deploy.Stage        # ArgoCD app appears
---@field argo_healthy deploy.Stage        # ArgoCD app Synced + Healthy
---@field deployment_healthy deploy.Stage  # live Deployment reports Available=True
---@field digest_deployed deploy.Stage     # deployed pods run the built digest
---@field pods_stable deploy.Stage         # workload stays Healthy through the stability window

---@class deploy
local deploy = {}

--- The default configuration. Read it to see every knob; override per call.
---@type deploy.ResolvedConfig
deploy.defaults = {}

--- The exported stage functions (see `deploy.Stages`).
---@type deploy.Stages
deploy.stages = {}

--- The stage keys in canonical order: preflight, render, push, build, release, platform,
--- argo_appears, argo_healthy, deployment_healthy, digest_deployed, pods_stable.
---@type string[]
deploy.order = {}

--- Default step label for each stage key.
---@type table<string, string>
deploy.labels = {}

--- Merge a config table over the defaults and fill derived fields (`platform_repo`, `project_prefix`,
--- `run_id`). Idempotent.
---@param config? deploy.Config
---@return deploy.ResolvedConfig
function deploy.resolve(config) end

--- Build a config table from environment variables, then layer `overrides` on top. Reads
--- ARCHETYPE_DIR/ARCHETYPE_SOURCE/ANSWERS_FILE, GITHUB_ORG/REPO_NAME/PLATFORM_REPO, ENVIRONMENT,
--- ARGO_APP_SUFFIX, PROJECT_PREFIX/PROJECT_SUFFIX/RUN_ID/PREFIX_KEY, KEEP_RESOURCES,
--- TEARDOWN_PUSH_RETRIES, BUILD_RETRIES, E2E_FLOW_TIMEOUT, and CI_TIMEOUT/PLATFORM_TIMEOUT/ARGO_APPEAR_TIMEOUT/
--- ARGO_TIMEOUT/DEPLOYMENT_TIMEOUT/PODS_STABLE_SECONDS/POLL_INTERVAL.
---@param overrides? deploy.Config
---@return deploy.Config
function deploy.from_env(overrides) end

--- Declare a flow-scoped fixture holding the shared run state + a guaranteed teardown deferral. Use
--- it to compose a custom flow from `deploy.stages` / `deploy.step`. `name` disambiguates multiple
--- runs in one file. The fixture value is a `deploy.Run` - `t:use(run)` yields `{ cfg, state, workdir }`.
---@param config? deploy.Config
---@param name? string
---@return prova.Fixture   # a deploy.Run
function deploy.new_run(config, name) end

--- Register one stage as a step on flow-builder `f`, bound to the `run` fixture (so it shares state
--- with the flow's other steps). `label` overrides the stage's default label. Returns `f` to chain.
---@param f prova.FlowBuilder
---@param run prova.Fixture   # a deploy.Run, from deploy.new_run
---@param key string          # a stage key from deploy.order
---@param label? string
---@return prova.FlowBuilder f
function deploy.step(f, run, key, label) end

--- Register several stages on `f` in one call (`keys` defaults to the full `deploy.order`). Interleave
--- your own `f:step(...)` around these; a custom step can `t:use(run)` to read the shared state.
---@param f prova.FlowBuilder
---@param run prova.Fixture   # a deploy.Run, from deploy.new_run
---@param keys? string[]      # stage keys (default deploy.order)
---@return prova.FlowBuilder f
function deploy.attach(f, run, keys) end

--- Register the standard ordered deploy-loop as a `prova.flow` (shared run + teardown + all stages).
--- Call with a config table, or `(name, config)` to name the flow.
---@overload fun(config?: deploy.Config)
---@param name string
---@param config? deploy.Config
function deploy.flow(name, config) end

return deploy
