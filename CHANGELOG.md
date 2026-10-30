# Changelog

All notable changes to this project are documented in this file.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) ·
[Semantic Versioning](https://semver.org/spec/v2.0.0.html)

## [1.1.0] - 2026-10-30

### Added

- **Store seam for the server half:** abstract `State::Backend`
  (`load` / `save(state)` / `with_exclusive_lock`) so a host app can
  back the sync engine with its own database of record instead of the
  YAML state file. `State::YamlFile` is the default implementation
  (delegating to the unchanged `State::Store` / `State::Lock`);
  `Sync::Engine` accepts `state_backend:` at construction and its
  `call`'s `paths:` is now optional — the CLI keeps its exact
  behavior via the default backend.
- **`Forge::HTTP` egress seam:** the gem's single network egress
  point — stdlib `net/http` GET returning `Success(Response)` (status,
  headers, body) on any completed exchange, `Failure` on transport
  errors. No new gem dependencies.
- **`Forge::GitHubToken`:** token-based GitHub REST client
  (`Authorization: Bearer`, `Link rel="next"` pagination, 1000-repo
  cap) alongside the gh-backed `Forge::GitHub`; selected by injection.
- **`Forge::GitLab`:** GitLab v4 API client (`PRIVATE-TOKEN`,
  `X-Next-Page` pagination, subgroup-safe project paths) behind the
  same `Forge::Client` interface.
- **`SCM::Mirror`:** bare-mirror git operations — `clone --mirror`,
  `remote update --prune`, fetch-freshness (`FETCH_HEAD` mtime) for
  bare repos, and a `mirror?` probe. The mirror invariant: all refs,
  all objects, nothing checked out.

## [1.0.0] - 2026-10-08

### Restored

- **Standalone again.** The evergreen engine was absorbed into
  [space-architect] v8.0.0 under that gem's namespace (`Space::Src`) and
  binary name (`src`); this release restores the `repo-tender` identity —
  same engine, home repo [jetpks/repo-tender] again.
  Lineage: 0.x repo-tender → absorbed as space-src in space-architect 8.0.0 →
  restored standalone 1.0.0.

[space-architect]: https://github.com/jetpks/space-architect
[jetpks/repo-tender]: https://github.com/jetpks/repo-tender

### Changed

- **Binaries:** `repo-tender` is the primary binary again. `src` ships as a
  deprecation shim — it still works, but prints
  `src is deprecated; use repo-tender instead` on stderr on every invocation,
  then forwards argv/stdout/exit codes to the primary binary unchanged.
- **State/config locations:** `repo-tender` is the app name for
  `$XDG_STATE_HOME` / `$XDG_CONFIG_HOME` dirs and the launchd label is
  `io.github.jetpks.repo-tender.sync` again.
- **Identity migration inverted:** a one-shot data-preserving migration moves
  `space-src`-named config/state dirs to their `repo-tender` locations and
  flags the stale `io.github.jetpks.space-src.sync` launchd agent. Moves only,
  never deletes; pre-existing `repo-tender` dirs are a clean no-op.
- **Module namespace:** `Space::Src` → `RepoTender` throughout.
- **Ruby floor:** `>= 4.0.5` (was `>= 3.3` in the 0.x gem).
- **Default clone home:** `~/src/evergreen` (was the absorbed identity's
  `~/architect/src`).

### Added

- Fish shell integration and completions, installed as
  `~/.config/fish/functions/repo-tender.fish` /
  `~/.config/fish/completions/repo-tender.fish` via
  `repo-tender shell fish install`.
