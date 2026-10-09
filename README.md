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
   and `heroku labs:enable runtime-dyno-build-metadata` (for `HEROKU_BUILD_COMMIT`,
   which replaces the deprecated `HEROKU_SLUG_COMMIT`); both take effect on the next deploy
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
9. a git checkout, for servers deployed by `git pull`, Fabric, or Ansible: the commit
   `HEAD` names, read from `.git` in the app root or up to 3 directories above it
   (worktrees and submodules included). The agent reads the files; it never runs `git`
10. ECS, including Fargate: the container's image, from the metadata endpoint ECS
    provides (one local request at boot). The image tag is the release when it's a
    commit or a version like `v1.4.2`; with a moving tag like `latest`, the image
    digest is
11. a fingerprint of the app's code, reported as `code:` and 12 hex characters: the
    hash of the [file digests](#what-it-sends) the agent already computes, so the
    same code is the same release. It needs file digests on, and is worked out in
    the background when the reporter starts, not at boot. Without a commit, the
    dashboard shows which files changed but not the commits and pull requests, so
    the agent logs a warning suggesting `DEPLOYANGEL_REVISION`

For other Docker deploys (compose, Swarm, Kubernetes), and on ECS to see each
release by its commit, bake the commit into the image, since `.dockerignore`
usually leaves `.git` out:

```bash
bundle exec deployangel install docker
```

adds this to the end of the Dockerfile's last stage, before its `CMD` (so the
layers above it stay cached):

```dockerfile
ARG GIT_SHA
ENV DEPLOYANGEL_REVISION=$GIT_SHA
```

Then build with `docker build --build-arg GIT_SHA=$(git rev-parse HEAD) .`
(`fly deploy --build-arg GIT_SHA=$(git rev-parse HEAD)` on Fly.io, or
`build-args: GIT_SHA=${{ github.sha }}` with GitHub's docker/build-push-action).
It changes nothing if the Dockerfile already sets `DEPLOYANGEL_REVISION`, and
never edits CI workflows. A build without the argument leaves the variable
empty, which counts as unset. On DigitalOcean App Platform, set
`DEPLOYANGEL_REVISION: ${_self.COMMIT_HASH}` in the app spec. On Elastic
Beanstalk, see [Deploying to Elastic Beanstalk](#deploying-to-elastic-beanstalk).
If the agent finds none of these, its telemetry can't be tied to a deploy, and
the dashboard says so.

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

- Exceptions: a stable fingerprint, the exception class, the first line of the
  message, and application frames only. In the message, numbers, IDs, emails,
  UUIDs, long hex strings, and quoted values are replaced with placeholders, and
  so are the request's host and, with ros-apartment, the tenants the request or
  job switched to. Other words are kept: `Payment failed for Jane Doe` is sent
  as it is. If your app's messages might hold personal or health data, [turn
  messages off](#exception-messages).
- Once per process: the route table, job classes, recurring schedules
  declared for Solid Queue, sidekiq-cron, or sidekiq-scheduler, critical
  flows, and file digests (relative paths and hashes, never file contents) so
  DeployAngel can tell which routes changed in a release.
  Disable digests with `DEPLOYANGEL_FILE_DIGESTS=false`.

It does not send request bodies, parameters, headers, cookies, SQL, logs, or
user data.

## Data and pricing

- Everything goes to DeployAngel's hosted service, which runs on DigitalOcean
  in the United States. There's no self-hosted version, and no choice of
  region.
- Telemetry is kept for 21 days, and release history for 7, 30, or 90 days
  depending on the plan. The [privacy policy](https://deployangel.com/privacy)
  has the details and the services DeployAngel uses.
- DeployAngel is free during the beta, with notice before paid plans start.
  See [pricing](https://deployangel.com/pricing).

## Safety

- Nothing runs on the network during a request. Requests only update
  in-memory counters.
- Payloads are sent from a background thread, once a minute, with short
  timeouts.
- When DeployAngel is unreachable, the buffer is bounded (10 payloads, kept as
  gzipped JSON) and the oldest are dropped. Your app is never blocked or failed.
- Safe across forks (Puma cluster mode and similar), and the minute in progress
  is flushed at shutdown.

`bundle exec rake bench` measures this: the time and allocations each request
adds, memory with every list at its cap, and the one-time file digest pass
(`APP_ROOT=path/to/app` to digest your own app). On an Apple M-series laptop
with Ruby 3.4, recording a request adds about 1.6 µs and 6 objects, and with
every route, job, checkpoint, and exception list at its cap the agent holds
about 3 MB, including 10 unsent minutes.

## Configuration

Environment variables are enough for most apps. To override in code:

```ruby
# config/initializers/deployangel.rb
DeployAngel.configure do |config|
  config.environments = %w[production] # default: every environment but development and test
end
```

Critical flows (for example sign-up or password reset) are always listed in
clearance reports:

```ruby
DeployAngel.configure do |config|
  config.critical_flows = { "password_reset" => [ "POST /password_resets", "job:PasswordsMailer" ] }
end
```

Health checks aren't recorded: load balancers and uptime monitors call them
all the time and they always answer fast, so they would make your app look
busier and healthier than its real pages. The agent recognizes Rails' own
(`/up`), OkComputer, health_check, and rails-healthcheck, wherever they're
mounted, and a lambda or Rack app at a conventional path (`/up`, `/health`,
`/healthz`, `/healthcheck`, `/health_check`, `/livez`, `/readyz`, `/statusz`,
`/ping`), such as `get "healthz", to: ->(_) { [200, {}, ["ok"]] }`. If your
health check is your own controller, list its route the way the dashboard
shows it. HEAD requests to it are left out too:

```ruby
DeployAngel.configure do |config|
  config.ignored_routes = [ "GET /healthz" ]
end
```

`DEPLOYANGEL_ENABLED=true|false` forces reporting on or off in any environment.
`DEPLOYANGEL_URL` overrides the API endpoint (default `https://api.deployangel.com`).

### Exception messages

To send exceptions without any message, only their class, fingerprint, and
application frames:

```ruby
DeployAngel.configure do |config|
  config.exception_messages = false # or DEPLOYANGEL_EXCEPTION_MESSAGES=false
end
```

Grouping, new-exception detection, and verdicts work the same, since the
fingerprint never uses the message. You lose the message text in the dashboard,
notifications, and AI investigation. With messages off, what leaves your app is
route patterns, counts, timings, job class names, exception classes, and
application file paths and method names, plus the route table, job classes,
schedules, and file digests described above.

### Recurring jobs

DeployAngel expects declared recurring jobs on schedule. It reads Solid Queue's
`config/recurring.yml`, sidekiq-scheduler's section of Sidekiq's config, and
sidekiq-cron's schedule file (`config/schedule.yml` unless sidekiq-cron is
configured otherwise), rendering ERB in each. If your app loads sidekiq-cron
jobs itself from another file, for example with `Sidekiq::Cron::Job.load_from_hash!`,
point the agent at that file:

```ruby
DeployAngel.configure do |config|
  config.sidekiq_cron_schedule_file = "config/sidekiq_schedule.yml.erb"
end
```

Jobs that exist only in Redis, such as ones created in code or in the
Sidekiq web UI, aren't read.

#### Cron, Heroku Scheduler, and whenever

Work that something outside the app starts on a schedule, such as cron,
Heroku Scheduler, or a Kubernetes CronJob, is invisible to those files.
Declare it by the name it runs under, with a cron line or words like
`"every day at 4am"`, in the server's time zone unless you add one
(`"0 3 * * * America/New_York"`):

```ruby
DeployAngel.configure do |config|
  config.recurring_jobs = {
    "NightlyInvoiceJob" => "0 3 * * *",            # bin/rails runner "NightlyInvoiceJob.perform_now"
    "rake invoices:send" => "every day at 4am",    # bin/rails invoices:send
    "nightly import" => "30 2 * * *"               # DeployAngel.task("nightly import") { ... }
  }
end
```

- **A job class** is recorded wherever it runs, a one-off `rails runner`
  included.
- **A rake task** named `"rake <task>"` is recorded with no code change, as
  long as it loads the app (depends on `:environment`).
- **Any other code** is recorded when you wrap it, which returns the block's
  value and re-raises what it raises:

  ```ruby
  DeployAngel.task("nightly import") { Importer.run }
  ```

The [whenever](https://github.com/javan/whenever) gem's `config/schedule.rb`
is read automatically when whenever is in the app's bundle (it's usually in
the Gemfile already, for deploys): its `rake` jobs, and `runner` jobs that
perform a job class (`"NightlyInvoiceJob.perform_later"`), are expected on
the schedule whenever writes to the crontab. Other `runner` code and
`command` jobs can't be matched to a run; wrap them in `DeployAngel.task`
and declare them as above.

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

The agent also records whether each checkpoint was counted during an HTTP
request or a background job, so DeployAngel compares it against the right
traffic: a checkpoint counted in jobs is judged against jobs, not requests.

It's safe to call anywhere: it never raises, never touches the network, and is
ignored outside reporting environments. Names use letters, numbers, and
`. _ : -` (up to 100 characters); keep them to a fixed set rather than
including IDs, since only 100 distinct names are counted per minute.

## Registering deploys

DeployAngel notices a new release when the agent first reports it, and
verifies it from there, with nothing to set up. The releases running when you
install the agent are the baseline. On Heroku, the add-on also registers every
release for you.

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

In GitHub Actions, `verify` also puts the verdict, its failing findings, and
new exceptions on the job's summary page.

### When a release never reports

A registered release must start reporting within 15 minutes of being
registered. If no instance reports it by then, the verdict is
**inconclusive** with reason `no_release_telemetry`, and the dashboard says
"Not cleared: this release never reported". The usual causes are a release
that never booted (a failed migration or a crash on start), an agent with no
token, or a release identity the agent can't find. If the app kept reporting
an earlier release instead, the verdict names it ("while v41 kept running").
`deployangel verify --wait` exits 2, so the CI step above fails the job.

If the release does start reporting within 24 hours, as after a slow rolling
deploy, DeployAngel withdraws that verdict and verifies the release from then,
unless a newer release has rolled out first. A CI job that already failed stays
failed; run `deployangel verify --wait` again to wait for the new verdict.

Only registered releases are caught this way. DeployAngel learns about an
unregistered release when the agent first reports it, so a release that never
boots is never seen. If a release that dies on boot is a risk for you, register
deploys from CI. The 15 minutes count from registration, so register when the
deploy finishes, not when it starts.

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

Kamal apps don't need `deployangel install docker`: `KAMAL_VERSION` already
identifies the release.

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

### Deploying to Elastic Beanstalk

Elastic Beanstalk doesn't tell the app which commit it's running. Set
`DEPLOYANGEL_REVISION` in the same `update-environment` call that deploys the
new version, so the two always change together. This works on every platform,
Docker included, with no build args. Then wait for the environment and register
the release:

```bash
aws elasticbeanstalk update-environment \
  --environment-name "$EB_ENV" \
  --version-label "$VERSION_LABEL" \
  --option-settings "Namespace=aws:elasticbeanstalk:application:environment,OptionName=DEPLOYANGEL_REVISION,Value=$GITHUB_SHA"
aws elasticbeanstalk wait environment-updated --environment-names "$EB_ENV"

bundle exec deployangel release --commit="$GITHUB_SHA" --version="$VERSION_LABEL"
bundle exec deployangel verify --wait --until=initial
```

`update-environment` returns as soon as the deploy starts, so don't skip the
wait: registering early starts the
[15-minute clock](#when-a-release-never-reports) before the new version is
running. If the deploy fails and Beanstalk rolls back, the environment still
returns to Ready, but the new commit never reports, so `verify` exits 2.

Leave `DEPLOYANGEL_RELEASE_VERSION` unset here. When the agent reports a
version, the release is matched by it, so it would have to equal `--version`
exactly. Matching by commit avoids that.

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
bundle exec deployangel plan                           # what to exercise so a release clears sooner
bundle exec deployangel exercise --url=https://example.com  # send the plan's read-only requests
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

To set up Claude Code, Cursor, and Codex for a project in one step, run this
in the project:

```bash
bundle exec deployangel install agents
```

It adds the MCP server to `.mcp.json` (Claude Code), `.cursor/mcp.json`
(Cursor), and `.codex/config.toml` (Codex, which reads it only in projects you
trust), and the instructions below to `AGENTS.md`, with a `CLAUDE.md` that
imports it. It never replaces an existing entry, and running it again updates
only its own instructions. Commit the files; the token stays in your
environment.

Or add the server yourself:

```bash
claude mcp add deployangel -- bundle exec deployangel mcp    # Claude Code
```

For Codex, in `~/.codex/config.toml`:

```toml
[mcp_servers.deployangel]
command = "bundle"
args = ["exec", "deployangel", "mcp"]
```

Any other MCP client (Cursor, VS Code, Zed, ...) runs the same command. The
server needs `DEPLOYANGEL_API_TOKEN` in the environment it starts in.

Tools: `get_verification`, `wait_for_verification` (up to 5 minutes per call),
`get_exercise_plan`, `list_deployments`, `get_exception`,
`list_late_regressions`, and `register_deployment` when the token allows it.
The tools are read-only with respect to production.

### Clearing quiet releases sooner

A quiet app can take hours to clear a release. `deployangel plan` (or the
`get_exercise_plan` MCP tool) says what stands between a release and
clearance, in the numbers of the rule it's judged by, and what to exercise
against production so it clears sooner: normally active routes short of
their runs, routes this release changed that haven't run, and critical
flows. It separates what clearance waits on from changed and rarely used
paths that are only worth running. Requests to them count like any traffic. Routes that change data
are marked; use a test account for them, or ask first. Report what you
ran with the `deployangel check` command the plan gives you. A passing
check labels what it covered; only the requests themselves count as
evidence. A release deployed during an app's first 24 hours can't clear,
so its plan lists nothing.

`deployangel exercise --url=<production URL>` does the read-only part for
you, from wherever it runs: it requests the plan's GET routes that have no
path parameters, spreading any request shortfall across them (at most 200
requests, about 5 a second, as `DeployAngel-Exercise`), then records what it
sent on the release, where the page lists it under "Exercised from your
side". It skips and names routes that change data or need a path
parameter, and stops requesting a page after its first 404, sending its
share to the pages that answered. A "CLI & coding agents" token can run
it. `--dry-run` shows what it would send.

### Suggested instructions for your coding agent

`deployangel install agents` adds instructions like these. To add them
yourself, put this in your `CLAUDE.md` or `AGENTS.md`:

```markdown
## Production verification (DeployAngel)

After deploying, or pushing a commit that deploys, wait for DeployAngel's
verdict: call the `wait_for_verification` MCP tool with the commit and
`until: "initial"`, calling again while it's in progress, or run
`bundle exec deployangel verify --commit=<sha> --wait --until=initial`.

- Exit 0 / verified: the release is cleared. Report the clearance line and
  anything DeployAngel is still watching, then move on.
- Exit 6: no problems so far, but NOT cleared. Report "no problems so far, not
  yet cleared" and the expected clearance time. DeployAngel keeps verifying and
  alerts on failure.
- Exit 7: warnings at the initial check. Report them and review the findings.
  The release is NOT cleared.
- Exit 2 / inconclusive: the release is NOT verified. Do not claim success.
- Exit 1 / failed: read the findings and exceptions (`get_exception`),
  investigate the likely cause, and propose a fix. Do not roll back or change
  production without explicit approval.
- Exit 3: still verifying; run the command again.
- Not cleared yet: call `get_exercise_plan` (or `bundle exec deployangel plan`).
  If its status is "exercisable" or "waiting_for_activity", run
  `bundle exec deployangel exercise --url=<production URL>`: it sends the
  plan's read-only requests and records them on the release. Offer to
  exercise what it skips: routes that change data only with a test account
  or after asking. If the status is "warm_up", nothing run can clear it.
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
