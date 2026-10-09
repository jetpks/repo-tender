# AGENTS.md — repo-tender builder context

Standing context for build agents. The architect's per-slice spec and its
frozen acceptance criteria are the contract; this file is the repo's stable
how-to.

## What this is

`repo-tender` keeps local git clones *evergreen* (clean · on default branch ·
fetched within `refresh_interval`) so a downstream tool can clone them from the
local filesystem instantly. A `dry-cli` binary plus a periodic launchd-invoked
`sync` sweep. macOS-only, GitHub-only (behind decoupled SCM/forge interfaces).
**Never** mutate a dirty/diverged repo.

## Identity & lineage

- Module namespace: `RepoTender` (the engine lived briefly as space-architect
  v8.0.0's `Space::Src`; restored standalone in 1.0.0).
- Binaries: `exe/repo-tender` (primary) and `exe/src` (deprecation shim — warns
  on stderr on every invocation, forwards argv/stdout/exit codes unchanged).
- The one-shot migration in `lib/repo_tender/migration.rb` moves the absorbed
  identity's `space-src` XDG dirs back to `repo-tender` and flags the stale
  launchd label. Data-safety-critical: moves only, never deletes, no-clobber.
  Do not weaken its tests.

## Toolchain

| Tool | Version | Notes |
|------|---------|-------|
| ruby | 4.0.5  | pinned in `.ruby-version` + `mise.toml`; ruby floor `>= 4.0.5` |
| mise | 2026.6+ | manages ruby |
| git  | 2.54+  | the only SCM |
| gh   | 2.93+  | GitHub forge listing |

## Build & test commands

```bash
bundle install
bundle exec rake test            # full suite (minitest)
bundle exec rake                 # same (default task)
bundle exec ruby -Itest test/path/to/foo_test.rb   # single file
bundle exec rake build           # build gem into pkg/
bundle exec rake mutant          # mutation testing on RepoTender::Cloner
bundle exec standardrb           # lint/format check
bundle exec standardrb --fix     # autofix
```

If you introduce a different test runner or linter, update this table and say so
in your lane report — the architect re-runs exactly these commands to judge gates.

## Conventions (non-negotiable)

- **Boundaries return `Result`** (`dry-monads`): `Shell`, `SCM::Git`,
  `Forge::GitHub`, `Config::Store`, `Sync::Engine`, `Launchd::Agent`.
  Exceptions are for programmer error only — a dirty repo or a network failure
  is a `Failure`, not a raise.
- **Tests use real temp git repos + a local bare remote. No mocks/stubs** of
  classes under test. Forge tests use a recorded `gh --json` fixture (offline,
  deterministic).
- **Async only where needed:** the sync engine wraps work in `Sync do … end`
  using `Async::Barrier` + `Async::Semaphore`; CRUD/status commands are plain
  synchronous Ruby. Subprocesses use **stdlib `Open3.capture3`** (non-blocking
  inside an Async task via the Fiber scheduler) — **do not** add `async-process`.
- **External binaries** (`git`, `gh`, `mise`, `launchctl`) resolved via PATH at
  runtime.
- Format every change with the linter before reporting done.
- Idiomatic, well-factored, DRY-ish Ruby. Write only the code the slice needs.

## Gotchas

- Default branch is **not** assumed `main` — resolve from the remote's HEAD
  (`git symbolic-ref --short refs/remotes/origin/HEAD`; a plain `fetch` does not
  update `origin/HEAD`).
- `git status --porcelain=v2` is the parse target; any `1`/`2`/`u`/`?` line ⇒ dirty.
- `gh` can silently fall back to unauthenticated (60 req/hr) — check
  `gh auth status` before bulk listing and surface a clear `Failure`.
- There is **no** dry-rb config *persistence* gem — write-back is a small
  hand-rolled YAML emitter you own (`dry-validation` validates, `dry-struct`
  models).
