# Changelog

## Unreleased

- `config.exception_messages = false` (or `DEPLOYANGEL_EXCEPTION_MESSAGES=false`)
  sends exceptions with their class, fingerprint, and application frames, and
  no message. Grouping and verdicts work the same.
- The request's host is replaced with `<host>` in exception messages, and with
  ros-apartment, so are the tenants the request or job switched to
  (`<tenant>`), including one that turned out not to exist. The default tenant
  is left alone.
- ECS, including Fargate: the release comes from the container's image, read
  once at boot from `ECS_CONTAINER_METADATA_URI_V4`. A tag that's a commit is
  the commit, another tag is the version, and a moving tag such as `latest` uses
  the image digest. `DEPLOYANGEL_REVISION` and a `REVISION` file still win.

## 0.1.9 (2026-10-04)

- A 4xx response to a request no route matched, such as a bot probing
  `/wp-admin` or `.env`, or middleware turning a request away before
  routing, is still recorded under `GET unmatched` but no longer counts in
  the app's request count, status counts, or latency. It made apps look
  busier than their real pages, and fast 404s diluted their latency. An
  unrouted 5xx still counts.

## 0.1.8 (2026-10-04)

- Health checks served by a lambda or a mounted Rack app at a conventional
  path (`/up`, `/health`, `/healthz`, `/healthcheck`, `/health_check`,
  `/livez`, `/readyz`, `/statusz`, `/ping`) are left out, like the health-check
  gems'. A controller at one of these paths is still recorded, since it may be
  a real page.
- `config.sidekiq_cron_schedule_file` reads sidekiq-cron jobs from the file an
  app loads them from itself, such as `config/sidekiq_schedule.yml.erb` passed
  to `Sidekiq::Cron::Job.load_from_hash!`. ERB is rendered, as in the default
  file.

## 0.1.7 (2026-10-04)

- Health checks from OkComputer, health_check, and rails-healthcheck are left
  out like Rails' own, wherever they're mounted.
- `config.ignored_routes` leaves out other routes, such as a health check
  served by your own controller: `[ "GET /healthz" ]`. HEAD requests to a
  listed GET route are left out too, and listed routes aren't sent in the
  route table, so DeployAngel never expects them to run.

## 0.1.6 (2026-10-04)

- Requests to Rails' health check (`rails/health#show`, at `/up` by default)
  are no longer recorded, wherever it's mounted. Load balancers and uptime
  monitors call it all the time and it always answers fast, so it made apps
  look busier and healthier than their real pages. DeployAngel already
  leaves out `/up` from older agents.

## 0.1.5 (2026-10-03)

- Declared recurring jobs from sidekiq-cron and sidekiq-scheduler, alongside
  Solid Queue's. sidekiq-cron jobs come from its schedule file
  (`config/schedule.yml` unless configured otherwise); sidekiq-scheduler jobs
  from the `:scheduler: :schedule:` section of Sidekiq's config file (the
  `-C` file in the Procfile's sidekiq command, else `config/sidekiq.yml`),
  with that environment's section applied. A repeating `every` or `interval`
  is sent as `every`. Both carry the process's local time zone, which the
  schedulers read a schedule in when it names none. Disabled jobs, jobs for
  other environments, and one-off `at` and `in` jobs are left out. Jobs that
  exist only in Redis aren't read.

## 0.1.4 (2026-10-03)

- A Solid Queue recurring task that runs a `command:` instead of a job class
  reports the job class it runs as (`runs_as`, `SolidQueue::RecurringJob`
  unless the app changes Solid Queue's default). DeployAngel can then expect
  it on schedule and show it by its name in `config/recurring.yml`, instead
  of guessing an interval from history and showing Solid Queue's wrapper.

## 0.1.3 (2026-10-02)

- Each process sends its minute of telemetry 1 to 50 seconds after the
  minute ends, chosen once per process, instead of within the first 10
  seconds. Apps' batches reach DeployAngel spread across the minute rather
  than all at once.

## 0.1.2 (2026-10-02)

- Unsent minutes wait in the buffer as gzipped JSON rather than Ruby objects.
  With every list at its cap, 10 minutes queued while DeployAngel was
  unreachable took about 20 MB; they now take well under 1 MB.
- `rake bench` measures the agent's overhead: time and allocations per
  request, memory with every list at its cap, and the file digest pass.

## 0.1.1 (2026-10-02)

- Declared Solid Queue schedules carry the time zone Solid Queue reads them
  in (`SolidQueue.time_zone`, which defaults to `config.time_zone`), so
  DeployAngel expects a job scheduled "at 4am every day" at the right hour.
  Without it, a release could fail for a recurring job that wasn't due yet
  when the app's time zone in the dashboard differed from the app's own.
- `deployangel verify` prints a missing recurring job as "didn't run" and
  when it was expected, instead of its interval as a percentage.
- The README describes registering deploys on every host before the Heroku
  add-on.

## 0.1.0 (2026-10-01)

- Release identity on Kamal (`KAMAL_VERSION`), Render (`RENDER_GIT_COMMIT`),
  Fly.io (the deploy's image tag), Railway (`RAILWAY_GIT_COMMIT_SHA`, or the
  deployment ID), Coolify (`SOURCE_COMMIT`), and Dokku (`GIT_REV`), with no
  configuration. Kamal versions with
  uncommitted changes report the version and the commit it starts with.
- `deployangel release` registers Kamal's release inside a Kamal hook, and
  `deployangel install kamal` adds a `post-deploy` hook that does it.

- HTTP request telemetry for Rails: request counts, 4xx/5xx status counts,
  unhandled exceptions, and mergeable latency histograms, per route.
- Release identity from configuration, Heroku dyno metadata, or a REVISION file.
- One payload per process per minute (heartbeats included), sent from a
  background thread; fails open, bounded buffering, fork-safe.
- Background jobs: attempts, failures, discards, duration, and queue latency
  per job class, for every ActiveJob adapter (Solid Queue, Sidekiq, GoodJob,
  ...) and for native Sidekiq jobs. Failures handled by `retry_on` and
  `discard_on` are counted exactly once.
- Exceptions: stable fingerprints (algorithm v1: class plus top application
  frame, with no line numbers, messages, or gem versions), sanitized messages,
  and application-only representative backtraces, tagged with the route or
  job class they came from. Handled `Rails.error` reports are included for
  context.
- Application metadata, once per process: route table, job classes, Solid
  Queue recurring schedules, critical flows, and file digests (paths and
  short hashes only; uploaded only when the cloud has not seen the manifest).
- Defaults to `https://api.deployangel.com`.
- `deployangel` CLI (`verify`, `status`, `release`, `check`, `exception`) with
  stable exit codes for coding agents and CI, and `deployangel mcp`, a stdio
  MCP server.
