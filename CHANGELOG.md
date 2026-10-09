# Changelog

All notable changes to this project are documented in this file.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) ·
[Semantic Versioning](https://semver.org/spec/v2.0.0.html)

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
