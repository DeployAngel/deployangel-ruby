# DeployAngel for Rails

The DeployAngel agent. It watches what your Rails app does in production and
reports one small aggregated payload per process per minute. DeployAngel uses
that to verify every deployment, and to tell you (or your coding agent) when a
release is **cleared** and you can stop watching it.

## Install

Requires Ruby 3.1 or later and Rails 7.1 or later.

```ruby
# Gemfile
gem "deployangel"
```

Set these in production:

```bash
DEPLOYANGEL_TOKEN=da_live_...           # an ingestion token with the telemetry scope
```

The agent must know which release it is running. It finds it in this order:

1. `DEPLOYANGEL_REVISION` (the commit SHA) and `DEPLOYANGEL_RELEASE_VERSION`, if you set them
2. Heroku dyno metadata. Enable it with `heroku labs:enable runtime-dyno-metadata`
3. Kamal: `KAMAL_VERSION`, which Kamal sets in every container
4. Render: `RENDER_GIT_COMMIT`
5. Fly.io: the deploy's image tag, from `FLY_IMAGE_REF`. Fly.io sets no commit, so
   pass one in for commit-level change tracking:
   `fly deploy --build-arg GIT_SHA=$(git rev-parse HEAD)`, with `ARG GIT_SHA` and
   `ENV DEPLOYANGEL_REVISION=$GIT_SHA` in the Dockerfile
6. Railway: `RAILWAY_GIT_COMMIT_SHA`, or `RAILWAY_DEPLOYMENT_ID` for deploys that
   didn't come from GitHub
7. Coolify: `SOURCE_COMMIT`. Dokku: `GIT_REV`
8. a `REVISION` file in the app root, which Capistrano writes and any build step can

For other Docker deploys (compose, Swarm, ECS, Kubernetes), bake the commit into
the image, since `.dockerignore` usually leaves `.git` out:

```dockerfile
ARG GIT_SHA
ENV DEPLOYANGEL_REVISION=$GIT_SHA
```

and build with `docker build --build-arg GIT_SHA=$(git rev-parse HEAD) .`. On
DigitalOcean App Platform, set `DEPLOYANGEL_REVISION: ${_self.COMMIT_HASH}` in
the app spec. If the agent finds none of these, its telemetry can't be tied to a
deploy, and the dashboard says so.

## What it sends

- HTTP request counts, 4xx/5xx counts by status code, unhandled exceptions,
  and a latency histogram, both per app and per route.
- Routes are recorded as the matched pattern (`GET /users/:id`), never the raw
  path. At most 100 routes are sent per payload; the rest are folded into
  `__other__`.
- Background jobs: attempts, failed attempts, discarded jobs, duration, and
  queue latency, per job class. Works with every ActiveJob adapter (Solid
  Queue, Sidekiq, GoodJob, ...) and with native Sidekiq jobs through a server
  middleware. Failures that `retry_on` or `discard_on` handle still count.
- Release identity, runtime versions, and a per-process instance ID.

- Exceptions: a stable fingerprint, the exception class, a sanitized message
  (numbers, IDs, emails, and quoted values removed), and application frames
  only.
- Once per process: the route table, job classes, Solid Queue recurring
  schedules, critical flows, and file digests (relative paths and hashes, never
  file contents) so DeployAngel can tell which routes changed in a release.
  Disable digests with `DEPLOYANGEL_FILE_DIGESTS=false`.

It does not send request bodies, parameters, headers, cookies, SQL, logs, or
user data.

## Safety

- Nothing runs on the network during a request. Requests only update
  in-memory counters.
- Payloads are sent from a background thread, once a minute, with short
  timeouts.
- When DeployAngel is unreachable, the buffer is bounded (10 payloads) and the
  oldest are dropped. Your app is never blocked or failed.
- Safe across forks (Puma cluster mode and similar), and the minute in progress
  is flushed at shutdown.

## Configuration

Environment variables are enough for most apps. To override in code:

```ruby
# config/initializers/deployangel.rb
DeployAngel.configure do |config|
  config.environments = %w[production staging] # default: production only
end
```

Critical flows (for example sign-up or password reset) are always listed in
clearance reports:

```ruby
DeployAngel.configure do |config|
  config.critical_flows = { "password_reset" => [ "POST /password_resets", "job:PasswordsMailer" ] }
end
```

`DEPLOYANGEL_ENABLED=true|false` forces reporting on or off in any environment.
`DEPLOYANGEL_URL` overrides the API endpoint (default `https://api.deployangel.com`).

## Checkpoints

Errors and latency don't catch work that silently stops happening. Count the
business events that matter with one line:

```ruby
DeployAngel.checkpoint("order.created")
DeployAngel.checkpoint("receipt.sent")
DeployAngel.checkpoint("webhook.stripe.processed", count: events.size)
```

DeployAngel learns each checkpoint's normal rate relative to your traffic and
fails a release after which it drops sharply or stops, even when every request
and job still succeeds. Only drops are flagged, and a checkpoint without enough
traffic never blocks a release from being cleared. Checkpoints can also be part
of a critical flow (`checkpoint:order.created`).

It's safe to call anywhere: it never raises, never touches the network, and is
ignored outside reporting environments. Names use letters, numbers, and
`. _ : -` (up to 100 characters); keep them to a fixed set rather than
including IDs, since only 100 distinct names are counted per minute.

## Registering deploys

On Heroku, the add-on registers every release for you. Anywhere else,
DeployAngel notices a new release when the agent first reports it, and verifies
it from there. The releases running when you install the agent are the baseline.

Registering deploys yourself adds a link to the CI run and a label of your
choice, and starts verification as soon as the deploy finishes. Use an API
token created for **CI deploys** in the dashboard (`DEPLOYANGEL_API_TOKEN`):

```bash
bundle exec deployangel release --commit=$GIT_SHA [--version=LABEL]
```

`--version` is an optional label for the dashboard (a tag, build number, or
date). Without it, releases are labelled by their short commit.

In GitHub Actions, GitLab CI, CircleCI, and Buildkite, `deployangel release`
needs no arguments: it uses the CI's commit, labels the release with the build
number (`run-123`, `pipeline-45`, `build-67`), and links the release page back
to the run. Explicit options still win.

```yaml
# .github/workflows/deploy.yml, after the deploy step
- run: bundle exec deployangel release
  env:
    DEPLOYANGEL_API_TOKEN: ${{ secrets.DEPLOYANGEL_API_TOKEN }}
- run: bundle exec deployangel verify --wait --until=initial   # optional: fail the job on a bad release
  env:
    DEPLOYANGEL_API_TOKEN: ${{ secrets.DEPLOYANGEL_API_TOKEN }}
```

### Deploying with Kamal

The agent reads `KAMAL_VERSION`, so it knows its release with no setup. Pass
the agent's token to the app through Kamal's secrets:

```yaml
# config/deploy.yml
env:
  secret:
    - DEPLOYANGEL_TOKEN
```

with `DEPLOYANGEL_TOKEN=$DEPLOYANGEL_TOKEN` in `.kamal/secrets`. To register each
deploy, add a post-deploy hook:

```bash
bundle exec deployangel install kamal
```

It writes `.kamal/hooks/post-deploy`, which runs `deployangel release` after each
`kamal deploy` (or adds nothing if you already have a hook, and prints the line
to add). Set `DEPLOYANGEL_API_TOKEN` (a CI deploys token) wherever you run
`kamal deploy`. The hook never fails a deploy.

### Deploying with Capistrano

Capistrano writes a `REVISION` file into each release, so the agent already
knows which commit it's running. Add one line to the `Capfile` to register
each deploy:

```ruby
# Capfile
require "deployangel/capistrano"
```

and set `DEPLOYANGEL_API_TOKEN` (a CI deploys token) wherever you run
`cap production deploy`. After each deploy is published, the release is
registered with its commit, labelled with Capistrano's release timestamp.
If DeployAngel can't be reached, the deploy continues with a warning.

Optional settings in `config/deploy.rb`:

```ruby
set :deployangel_wait, "initial"      # wait for the initial check after deploying
set :deployangel_wait_timeout, "15m"
set :deployangel_version, nil         # label releases by commit instead of timestamp
set :deployangel_register, false      # turn it off, e.g. for a stage without DeployAngel
```

With `:deployangel_wait`, `cap` exits with an error if the release fails
verification, which CI can act on. It never rolls anything back.

## CLI and coding agents

The gem ships a `deployangel` command. It doesn't boot Rails. Give it a token
with the `verifications:read` scope (plus `deployments` to register deploys or
report checks). Never use the production telemetry token on a developer
machine.

```bash
export DEPLOYANGEL_API_TOKEN=da_live_...

bundle exec deployangel verify --wait                  # current git HEAD, until a verdict
bundle exec deployangel verify --wait --until=initial  # return at the 15-minute initial check
bundle exec deployangel status                         # latest deployment
bundle exec deployangel release --commit=$SHA          # register a deploy (manual or CI)
bundle exec deployangel check --name="smoke: signup" --status=pass --covers=registration
bundle exec deployangel exception <fingerprint>
```

Output is text on a terminal and JSON (the verdict document) when piped, or
choose with `--format=text|json`. Exit codes:

| Code | Meaning |
|---|---|
| 0 | verified (cleared) |
| 1 | failed |
| 2 | inconclusive (not verified) |
| 3 | still in progress, or timed out |
| 4 | deployment not found |
| 5 | usage, authentication, or network error |
| 6 | initial check: no problems so far, **not cleared** |
| 7 | initial check: warnings, **not cleared** |

### MCP server

```bash
claude mcp add deployangel -- bundle exec deployangel mcp
```

Tools: `get_verification`, `wait_for_verification` (up to 5 minutes per call),
`list_deployments`, `get_exception`, `list_late_regressions`, and
`register_deployment` when the token allows it. The tools are read-only with
respect to production.

### Suggested instructions for your coding agent

Add this to your `CLAUDE.md` or `AGENTS.md`:

```markdown
## Production verification

After deploying, run `bundle exec deployangel verify --wait --until initial`
(or call the `wait_for_verification` MCP tool with `until: "initial"`).

- Exit 0 / verified: the release is cleared. Report the clearance line and
  anything DeployAngel is still watching, then move on.
- Exit 6: no problems so far, but NOT cleared. Report "no problems so far, not
  yet cleared" and the expected clearance time. DeployAngel keeps verifying and
  alerts on failure.
- Exit 7: warnings at the initial check. Report them and review the findings.
  The release is NOT cleared.
- Exit 2 / inconclusive: the release is NOT verified. Do not claim success.
- Exit 1 / failed: read the findings and exceptions, investigate the likely
  cause, and propose a fix. Do not roll back or change production without
  explicit approval.
- Exit 3: still verifying; run the command again.
```

## Development

```bash
bundle install
bundle exec rspec
```

The agent speaks DeployAngel Agent Protocol v1: one gzipped JSON payload per
process per minute to `POST /api/v1/telemetry`, and the application's metadata
once per process to `POST /api/v1/application_metadata`.
`lib/deployangel/core/protocol.rb` and `lib/deployangel/rails/metadata.rb`
build them.
