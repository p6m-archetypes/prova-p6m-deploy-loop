--- Covers `deploy.redact` - the layer that keeps credentials in a relayed workflow log off the
--- console. Two properties matter and both are asserted for every case: the secret is GONE, and the
--- surrounding line is still readable (over-redaction would make the failed-log tail useless, which is
--- the whole reason it is printed).

local deploy = require("deploy")

-- { name, input, secret that must not survive, a fragment that must }
local CASES = {
  { "a token embedded in a clone URL",
    "+ git push https://x-access-token:ghs_16C7e42F292c6912E7710c838347Ae178B4a@github.com/acme/svc.git",
    "ghs_16C7e42F292c6912E7710c838347Ae178B4a", "github.com/acme/svc.git" },
  { "a bare GitHub server token",
    "Setting up token ghs_16C7e42F292c6912E7710c838347Ae178B4a for the run",
    "ghs_16C7e42F292c6912E7710c838347Ae178B4a", "Setting up token" },
  { "a fine-grained PAT",
    "remote: token github_pat_11ABCDEFG0aBcDeFgHiJkL_mNoPqRsTuVwXyZ rejected",
    "github_pat_11ABCDEFG0aBcDeFgHiJkL_mNoPqRsTuVwXyZ", "rejected" },
  { "a JWT (JFrog access token / OIDC / k8s SA token)",
    "curl -H 'x-jfrog: eyJ2ZXIiOiIyIn0.eyJzdWIiOiJhZG1pbiJ9.SflKxwRJSMeKKF2QT4fwpM' https://ybor.jfrog.io",
    "eyJ2ZXIiOiIyIn0.eyJzdWIiOiJhZG1pbiJ9.SflKxwRJSMeKKF2QT4fwpM", "ybor.jfrog.io" },
  { "a JFrog reference token",
    "ARTIFACTORY_IDENTITY_TOKEN=cmVmdGtuOjAxOmFiY2RlZmdoaWprbG1ub3A",
    "cmVmdGtuOjAxOmFiY2RlZmdoaWprbG1ub3A", "ARTIFACTORY_IDENTITY_TOKEN" },
  { "an Authorization header (whole value, not just the scheme)",
    "> Authorization: Bearer AbCdEf0123456789ZyXwVu",
    "AbCdEf0123456789ZyXwVu", "Authorization" },
  { "a basic-auth header",
    "> authorization: Basic eDphY2Nlc3MtdG9rZW46c2VjcmV0",
    "eDphY2Nlc3MtdG9rZW46c2VjcmV0", "authorization" },
  { "a docker config auth blob",
    '{"auths":{"ybor.jfrog.io":{"auth":"eW91OnN1cGVyLXNlY3JldA=="}}}',
    "eW91OnN1cGVyLXNlY3JldA==", "ybor.jfrog.io" },
  { "an opaque secret, recognizable only by its key",
    "env: AZURE_CLIENT_SECRET=sUp3r0paqueRand0mNothingToMatchOn",
    "sUp3r0paqueRand0mNothingToMatchOn", "AZURE_CLIENT_SECRET" },
  { "a YAML-style password",
    "  registry_password: hunter2-not-very-good",
    "hunter2-not-very-good", "registry_password" },
  { "a space-separated credential flag",
    "+ helm registry login ybor.jfrog.io --password hunter2-not-very-good --username ci",
    "hunter2-not-very-good", "--username ci" },
  { "an AWS access key id",
    "aws_access_key_id = AKIAIOSFODNN7EXAMPLE",
    "AKIAIOSFODNN7EXAMPLE", "aws_access_key_id" },
  { "an npm token",
    "//registry.npmjs.org/:_authToken=npm_aBcDeFgHiJkLmNoPqRsTuVwXyZ012345",
    "npm_aBcDeFgHiJkLmNoPqRsTuVwXyZ012345", "registry.npmjs.org" },
  -- The token segment here is deliberately shorter than a real Slack webhook's 24 characters: at full
  -- length this fixture matches GitHub's secret-scanning pattern and push protection rejects the
  -- commit. Keep test fixtures clearly non-live rather than working around the scanner.
  { "a Slack webhook",
    "notify: https://hooks.slack.com/services/T00000000/B00000000/NotARealToken",
    "T00000000/B00000000", "notify" },
}

prova.test("redacts every credential shape a workflow log carries", function(t)
  for _, case in ipairs(CASES) do
    local out = deploy.redact(case[2])
    t:expect(out, case[1] .. ": secret is gone"):never():contains(case[3])
    t:expect(out, case[1] .. ": line is still readable"):contains(case[4])
    t:expect(out, case[1] .. ": something was masked"):contains("***")
  end
end)

prova.test("redacts a private key block, which spans lines", function(t)
  local out = deploy.redact(table.concat({
    "writing deploy key",
    "-----BEGIN RSA PRIVATE KEY-----",
    "MIIEowIBAAKCAQEAxHfQ0v0oVnHhZ0Wn8mQKk0Nn1zZ",
    "9mQKk0Nn1zZMIIEowIBAAKCAQEAxHfQ0v0oVnHhZ0Wn",
    "-----END RSA PRIVATE KEY-----",
    "done",
  }, "\n"))
  t:expect(out, "no key material survives"):never():contains("MIIEowIBAAKCAQEA")
  t:expect(out, "the block is called out"):contains("REDACTED PRIVATE KEY")
  t:expect(out, "surrounding lines survive"):contains("writing deploy key")
end)

prova.test("registered values are masked even with no telltale shape or key", function(t)
  -- The strongest layer: a value this plugin holds (e.g. the token teardown pushes with) is masked
  -- wherever it turns up, including bare in a message no pattern would flag.
  local token = "aG9sZC10aGlzLXZhbHVlLWV4YWN0bHk"
  t:expect(deploy.redact("remote rejected " .. token), "not masked before registering"):contains(token)
  deploy.register_secret(token)
  t:expect(deploy.redact("remote rejected " .. token), "masked after registering"):never():contains(token)
  t:expect(deploy.register_secret("returns-its-argument"), "returns the value so it can wrap a fetch")
    :equals("returns-its-argument")
  t:expect(deploy.redact("short one: abc"), "too-short values are not registered"):contains("abc")
end)

prova.test("leaves ordinary build output alone", function(t)
  -- Over-redaction is a real cost here: this text is the only diagnostic a failed run leaves behind.
  local lines = {
    "##[group]Run docker/build-push-action@v5",
    "Author: Maksym Mukhanov <e2e@ybor.ai>",
    "Successfully tagged ybor.jfrog.io/acme/svc:1.0.0",
    "digest: sha256:9b2c8f1e0d7a6b5c4e3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b2c1d",
    "authenticated successfully as ci-bot",
    "Cloning into 'https://github.com/p6m-archetypes/prova-p6m-deploy-loop'...",
    "##[error]Process completed with exit code 1.",
  }
  for _, line in ipairs(lines) do
    t:expect(deploy.redact(line), "untouched: " .. line):equals(line)
  end
end)

prova.test("redaction is idempotent and total-function", function(t)
  local once = deploy.redact("password: hunter2-not-very-good")
  t:expect(deploy.redact(once), "re-redacting changes nothing"):equals(once)
  t:expect(deploy.redact(""), "empty string"):equals("")
  t:expect(deploy.redact(nil), "nil passes through"):is_nil()
end)
