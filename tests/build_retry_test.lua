--- Covers `stages.build`'s retry loop against a fake `gh`. The stage's only contact with GitHub is
--- `shell.run`, so a per-attempt script of conclusions drives every path - passes first try, passes on
--- a re-run, exhausts the retries, cannot re-run - with no repo, no runner, and no waiting.

local deploy = require("deploy")

local RUN_ID = "999"
local SHA = "0123456789abcdef0123456789abcdef01234567"

-- A failed-step log tail shaped like the real leaks. GitHub masks *registered* secrets as ***, so what
-- actually reaches the console is what it cannot match: a token minted during the run, the same token
-- embedded in a remote URL, and a credential printed by a tool as a plain assignment.
local LEAKED_TOKEN = "ghs_16C7e42F292c6912E7710c838347Ae178B4a"
local LEAKED_JFROG = "cmVmdGtuOjAxOmFiY2RlZmdoaWprbG1ub3A"
local LEAKY_LOG = table.concat({
  "build\tPublish image\t2026-07-27T10:00:01Z ##[group]Run docker/login-action@v3",
  "build\tPublish image\t2026-07-27T10:00:02Z   password: " .. LEAKED_TOKEN,
  "build\tPublish image\t2026-07-27T10:00:03Z + git remote add origin https://x-access-token:" ..
    LEAKED_TOKEN .. "@github.com/acme/svc.git",
  "build\tPublish image\t2026-07-27T10:00:04Z env: ARTIFACTORY_IDENTITY_TOKEN=" .. LEAKED_JFROG,
  "build\tPublish image\t2026-07-27T10:00:05Z ##[error]Process completed with exit code 1.",
}, "\n")

-- Answer the handful of `gh` commands stages.build issues. `conclusions[n]` is attempt n's outcome and
-- `gh run rerun` advances the attempt - as a real re-run does, in place on the same run.
local function fake_gh(conclusions, rerun_fails)
  local calls, attempt, real = { reruns = 0, failures_logged = 0 }, 1, shell.run
  local function res(code, stdout)
    return { code = code, stdout = stdout or "", stderr = "", ok = function() return code == 0 end }
  end
  ---@diagnostic disable-next-line: duplicate-set-field
  shell.run = function(command)
    local cmd = type(command) == "table" and table.concat(command, " ") or tostring(command)
    if cmd:find("run list", 1, true) then return res(0, RUN_ID .. "\n") end
    if cmd:find("--json url", 1, true) then return res(0, "https://github.test/run/" .. RUN_ID .. "\n") end
    if cmd:find("--json status,conclusion,attempt", 1, true) then
      return res(0, string.format('{"attempt":%d,"conclusion":%q,"status":"completed"}',
        attempt, conclusions[attempt] or "failure"))
    end
    if cmd:find("--log-failed", 1, true) then
      calls.failures_logged = calls.failures_logged + 1
      return res(0, LEAKY_LOG)
    end
    if cmd:find("run rerun", 1, true) then
      calls.reruns = calls.reruns + 1
      if rerun_fails then return res(1) end
      attempt = attempt + 1
      return res(0)
    end
    return res(0)
  end
  return calls, function() shell.run = real end
end

-- Drive stages.build over a scripted set of attempt conclusions; returns pcall's (ok, err) + the calls.
local function build(t, conclusions, retries, rerun_fails)
  local calls, restore = fake_gh(conclusions, rerun_fails)
  local run = {
    cfg = deploy.resolve{ build_retries = retries, timeouts = { poll_interval = 1 } },
    state = { repo = "acme/svc", head_sha = SHA },
  }
  local ok, err = pcall(deploy.stages.build, t, run)
  restore()
  return ok, tostring(err), calls
end

prova.test("build passes on the first attempt without re-running", function(t)
  local ok, err, calls = build(t, { "success" }, 3)
  t:expect(ok, "stage passed: " .. err):is_true()
  t:expect(calls.reruns, "no re-run when the first attempt succeeds"):equals(0)
  t:expect(calls.failures_logged, "nothing logged as failed"):equals(0)
end)

prova.test("build re-runs a failed workflow and passes on the retry", function(t)
  local ok, err, calls = build(t, { "failure", "success" }, 3)
  t:expect(ok, "stage passed on attempt 2: " .. err):is_true()
  t:expect(calls.reruns, "one re-run of the same run"):equals(1)
  t:expect(calls.failures_logged, "the failed attempt was still logged in full"):equals(1)
end)

prova.test("build survives a cancelled attempt too", function(t)
  local ok, _, calls = build(t, { "cancelled", "failure", "success" }, 3)
  t:expect(ok, "any non-success conclusion is retried"):is_true()
  t:expect(calls.reruns, "two re-runs"):equals(2)
end)

prova.test("build fails after exhausting the retries", function(t)
  local ok, err, calls = build(t, {}, 3)   -- every attempt fails
  t:expect(ok, "stage failed"):is_false()
  t:expect(err, "the error names the attempt count"):contains("after 4 attempts")
  t:expect(calls.reruns, "3 retries = 3 re-runs, then it gives up"):equals(3)
  t:expect(calls.failures_logged, "every attempt's failure was logged"):equals(4)
end)

prova.test("build_retries = 0 fails on the first failure", function(t)
  local ok, err, calls = build(t, {}, 0)
  t:expect(ok, "stage failed"):is_false()
  t:expect(err, "single-attempt wording"):contains("after 1 attempt")
  t:expect(calls.reruns, "no re-run attempted"):equals(0)
end)

prova.test("the failed-step log it echoes carries no credentials", function(t)
  -- The end of the leak path: a real workflow log goes in, and what the stage actually writes to the
  -- console comes out. A recording `t` captures it (the stage only ever calls t:log).
  local logged = {}
  local recorder = { log = function(_, message) logged[#logged + 1] = tostring(message) end }
  local ok = build(recorder, {}, 0)
  local console = table.concat(logged, "\n")

  t:expect(ok, "the stage still failed the build"):is_false()
  t:expect(console, "the log tail was echoed at all"):contains("Process completed with exit code 1")
  t:expect(console, "the runtime-minted token is gone"):never():contains(LEAKED_TOKEN)
  t:expect(console, "the token embedded in the remote URL is gone too"):never():contains(LEAKED_TOKEN)
  t:expect(console, "the Artifactory token is gone"):never():contains(LEAKED_JFROG)
  t:expect(console, "the run URL is still there to click"):contains("https://github.test/run/999")
end)

prova.test("build surfaces a re-run that GitHub rejects", function(t)
  local ok, err, calls = build(t, {}, 3, true)
  t:expect(ok, "stage failed"):is_false()
  t:expect(err, "the error says the re-run itself failed"):contains("could not re-run Build run")
  t:expect(calls.reruns, "it stops at the first rejected re-run"):equals(1)
end)
