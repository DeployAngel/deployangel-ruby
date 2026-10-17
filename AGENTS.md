# DeployAngel agent: working rules

The `deployangel` gem runs inside customers' production Rails, Hanami, and
Sinatra apps. These rules
come before any feature.

## Never harm the customer's app

- No DeployAngel network calls during a request or job. Payloads go out from a
  background thread, once a minute, with short timeouts.
- Fail open: every public method rescues its own errors. Nothing may raise
  into, or block, the app.
- Keep buffers bounded, and drop telemetry rather than block or fail.
- Keep overhead very low: around 1% CPU or less, where practical.
- If DeployAngel is down, the customer's app must not notice.

## Send aggregates, never events

- One payload per process per minute, whatever the traffic.
- Only mergeable values: counts and histograms. Never percentiles or rates;
  the cloud computes those after merging processes.
- Bound every list in a payload (routes, exceptions, jobs, checkpoints).

## Send as little as possible

Never collect request bodies, parameters, cookies, authorization headers,
session contents, SQL parameters, email addresses, other personal data, or raw
logs. Record route patterns (`/users/:id`), never raw paths, and sanitize
exception messages. If a change would add a line to the README's "What it
sends" section, that's a decision for the maintainer, not an implementation
detail.

## Keep the protocol framework-neutral

The Agent Protocol speaks in HTTP, routes, exceptions, jobs, queues, and
scheduled tasks, never in ActiveJob, Sidekiq, or ActionController. The adapters
in `lib/deployangel/rails/`, `lib/deployangel/hanami/`, and
`lib/deployangel/sinatra/` translate their framework into those concepts, and the Python and .NET agents speak the same
protocol. Protocol changes must work for
them too, and the DeployAngel cloud has to accept them first.

## Compatibility and tests

- Supports Ruby 3.1, Rails 7.1, Hanami 2.2, and Sinatra 3.0 or later. CI
  runs the oldest and newest of each (`.github/workflows/ci.yml`), so don't
  use newer Ruby or framework APIs without a fallback. The Hanami and
  Sinatra specs run when `HANAMI_VERSION` or `SINATRA_VERSION` is set
  (`SINATRA_VERSION=4.2 bundle exec rspec`); Hanami before 2.3.2 needs
  Bundler 2.
- `bundle exec rspec` must pass. Test the failure paths too: network errors,
  timeouts, full buffers, and forks.
- Update the README and CHANGELOG when what the agent sends, or how it's
  configured, changes.
- For maintainers: DeployAngel's own cloud app runs this gem from RubyGems,
  so after a release, run `bundle update deployangel` in the `cloud`
  repository (Dependabot also opens a pull request for it).

## Releasing

Run `bin/release X.Y.Z --push` from an up-to-date `main` with the changes
under the CHANGELOG's "## Unreleased" heading. It checks X.Y.Z is newer
than RubyGems' latest, sets `lib/deployangel/version.rb`, dates the
CHANGELOG section, runs the tests, commits "Release X.Y.Z", tags `vX.Y.Z`,
and pushes. `.github/workflows/release.yml` builds the gem, waits for a
maintainer to approve the `rubygems` environment, publishes to RubyGems
through trusted publishing (no API key, and no MFA code: pushes from a
maintainer's machine still need one), and then creates the GitHub release.
Without `--push`, it stops after tagging. `rake release` points here.
