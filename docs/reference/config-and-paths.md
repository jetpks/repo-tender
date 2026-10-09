# Config, state, and paths 🗂️

Every path below is resolved through XDG conventions at runtime —
`$XDG_CONFIG_HOME` / `$XDG_STATE_HOME` overrides are honored, falling back
to `~/.config` and `~/.local/state` (`lib/repo_tender/paths.rb`). All
values verified against repo-tender 1.0.0's source.

## Requirements

| Tool | Version | Why |
|------|---------|-----|
| macOS | — | launchd scheduling, `~/Library/LaunchAgents` |
| [mise] | 2026.6+ | pins and provides Ruby |
| Ruby | 4.0.5 | runtime (`required_ruby_version` in the gemspec) |
| git | 2.54+ | the only SCM |
| [gh] | 2.93+ | GitHub org listing (must be authenticated) |

[mise]: https://mise.jdx.dev/
[gh]: https://cli.github.com/

## Paths

| What | Path | Notes |
|------|------|-------|
| Config file | `$XDG_CONFIG_HOME/repo-tender/config.yaml` | your durable intent; safe to hand-edit (but not while also using the CLI — CLI writes regenerate the file) |
| State file | `$XDG_STATE_HOME/repo-tender/state.yaml` | machine-managed; never hand-edit |
| Logs | `$XDG_STATE_HOME/repo-tender/logs/` | the launchd agent's stdout/stderr land here |
| Evergreen clones | `base_dir` from config; default `~/src/evergreen` | layout `<host>/<owner>/<repo>` |
| launchd plist | `~/Library/LaunchAgents/io.github.jetpks.repo-tender.sync.plist` | written by `daemon install` |

`repo-tender config path` prints the resolved config file path — the
authoritative answer under whatever env you're in.

## config.yaml

Validated by a dry-validation contract; unknown keys are dropped, known
keys are type-checked. Written in a stable key order (`base_dir`,
`refresh_interval`, `concurrency`, `repos`, `orgs`); defaults are omitted
from the file; YAML comments are not preserved on CLI write.

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `base_dir` | string | `~/src/evergreen` | home of the evergreen clones |
| `refresh_interval` | integer seconds (`"6h"`, `"90m"`, `"45s"`, `"30d"`, or bare seconds are accepted and normalized on load) | `21600` (6h) | freshness window and the launchd agent's `StartInterval` |
| `concurrency` | positive integer | `8` | max parallel git/gh operations per sync pass |
| `repos` | array of `{host, owner, name}` | `[]` | individually tracked repos (`host` optional, defaults `github.com`) |
| `orgs` | array of `{host, name, include_archived, include_forks, ignored_repos}` | `[]` | tracked orgs; expansion filters |

Inspect the effective result with `repo-tender config show`.

## state.yaml

Written and read only by the tool (`repo-tender status` renders it; sync
passes update it). Per-repo records under `repos:` keyed by
`host/owner/name`, e.g.:

```yaml
repos:
  github.com/octocat/Hello-World:
    default_branch: master
    last_fetch_at: '2026-10-09T10:56:52-06:00'
    last_synced_at: '2026-10-09T10:56:51-06:00'
    status: clean
orgs: {}
```

The per-repo `status` is one of a fixed enum —
`clean`, `dirty`, `diverged`, `detached`, `wrong_branch`, `missing`,
`error` (`lib/repo_tender/state/store.rb`). Only `clean` means the mirror
is fully evergreen; the others are repo-tender asking for your attention.
See [what "evergreen" means](../explanation/evergreen.md).

## Launchd agent

- Label: `io.github.jetpks.repo-tender.sync` (`lib/repo_tender/launchd/agent.rb`)
- Schedule: `StartInterval` = your `refresh_interval`, plus `RunAtLoad`
  (one sync at login); no `KeepAlive` — the agent is a short-lived `sync`,
  not a resident process
- Logs: the plist points stdout/stderr at
  `$XDG_STATE_HOME/repo-tender/logs/`

## The `src` shim, path-wise

The gem ships two executables (`spec.executables = ["repo-tender", "src"]`
in the gemspec): the primary `repo-tender` and the deprecated `src` alias —
[its own reference page](src-shim.md).
