# Changelog

## 0.1.0 (unreleased)

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
