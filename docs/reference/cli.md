# CLI reference: `repo-tender` 📋

Derived verbatim from `repo-tender --help` and each subcommand's `--help`
(repo-tender 1.0.0). Exit codes: `0` on success, `1` on failure (a
per-command `Outcome` translated to the process exit code; see
[exit-code behavior](#exit-codes-and-outcomes)).

## Global flags

Accepted by every command that produces output:

| Flag | Effect |
|------|--------|
| `--plain` | Plain text output (one line per event, no color) |
| `--json` | JSON output (one object per event line, 12-factor) |
| `--no-color` | Disable color output |
| `--quiet`, `-q` | Suppress non-essential output |
| `--help`, `-h` | Print help (top-level `--help`, `-h`, or `help` → usage on stdout, exit 0) |
| `--version` | Print the version (`repo-tender --version` or `repo-tender version`), stdout, exit 0 |

Color auto-disables when stdout is not a TTY.

## Top-level commands

```
Commands:
  repo-tender clone NAMES                         # Clone evergreen repo(s) into a working directory (APFS COW copy)
  repo-tender config [SUBCOMMAND]
  repo-tender daemon [SUBCOMMAND]
  repo-tender org [SUBCOMMAND]
  repo-tender repo [SUBCOMMAND]
  repo-tender shell [SUBCOMMAND]
  repo-tender status                              # Show the per-repo evergreen status table (from $XDG_STATE_HOME/repo-tender/state.yaml)
  repo-tender sync                                # Run one sync pass (use --repo to scope to a single tracked repo)
```

A bare first argument that is none of these (e.g. `repo-tender rubyyyy`)
is treated as a fuzzy checkout query instead of an unknown command — see
[fuzzy nav](../how-to/navigate-checkouts-with-fish.md#use-it)
and the [shell integration](../how-to/navigate-checkouts-with-fish.md).

## repo-tender clone

```
Usage:
  repo-tender clone NAMES

Description:
  Clone evergreen repo(s) into a working directory (APFS COW copy)

Arguments:
  NAMES                             # REQUIRED Repo name(s): bare name, owner/name, or host/owner/name

Options:
  --plain                           # Plain text output (one line per event, no color)
  --json                            # JSON output (one object per event line, 12-factor)
  --no-color                        # Disable color output
  --quiet, -q                       # Suppress non-essential output
  --into=VALUE                      # Destination parent directory (default: current working directory), default: "."
  --help, -h                        # Print this help
```

Behavior: resolves each `NAMES` against the configured `base_dir` and
copies with `cp -Rc` (APFS copy-on-write) to `<into>/<leaf>`. Names may be
a bare name, `owner/name`, or `host/owner/name`; a bare name matching more
than one mirror fails with the candidate list. An existing destination is
never clobbered (failure for that name). Names are processed
independently; the exit code is `1` if any name failed, `0` otherwise.
Does not create the `--into` directory — it must exist.

## repo-tender config

```
Commands:
  repo-tender config path             # Print the resolved config file path (honors $XDG_CONFIG_HOME)
  repo-tender config show             # Print the effective (validated, defaults-applied) config as YAML
```

Both leaf commands accept the global flags (`--plain` `--json`
`--no-color` `--quiet, -q` `--help, -h`).

`config path` prints the resolved config file path, honoring
`$XDG_CONFIG_HOME` (default `$HOME/.config/repo-tender/config.yaml`).

`config show` prints the effective config — loaded, validated,
defaults-applied — as YAML, e.g.:

```yaml
---
base_dir: "/Users/you/src/evergreen"
refresh_interval: 21600
concurrency: 8
repos: []
orgs: []
```

## repo-tender daemon

```
Commands:
  repo-tender daemon install                  # Install the per-user launchd agent (writes the plist + bootstrap)
  repo-tender daemon restart                  # Restart the agent (kickstart -k)
  repo-tender daemon start                    # Start the agent (bootstrap + enable)
  repo-tender daemon status                   # Print the agent's loaded/running/last-exit state
  repo-tender daemon stop                     # Stop the agent (bootout + disable)
  repo-tender daemon uninstall                # Uninstall the per-user launchd agent (bootout + remove the plist)
```

All leaf commands accept the global flags. The agent's label is
`io.github.jetpks.repo-tender.sync`; the plist lives at
`~/Library/LaunchAgents/io.github.jetpks.repo-tender.sync.plist` (see
[config and paths](config-and-paths.md#launchd-agent)). If a stale
`io.github.jetpks.space-src.sync` plist is present, `install` replaces it
and `status` prints a warning naming the fix.

## repo-tender org

```
Commands:
  repo-tender org add NAME                  # Add a tracked org (idempotent on host/name)
  repo-tender org list                      # List tracked orgs
  repo-tender org remove NAME               # Remove a tracked org (host/name)
```

### repo-tender org add

```
Usage:
  repo-tender org add NAME

Description:
  Add a tracked org (idempotent on host/name)

Arguments:
  NAME                              # REQUIRED Org identity as <name> or <host>/<name> (host defaults to github.com)

Options:
  --plain                           # Plain text output (one line per event, no color)
  --json                            # JSON output (one object per event line, 12-factor)
  --no-color                        # Disable color output
  --quiet, -q                       # Suppress non-essential output
  --[no-]include-archived           # Include archived repos when expanding the org, default: false
  --[no-]include-forks              # Include forks when expanding the org, default: false
  --ignored-repos=VALUE1,VALUE2,..  # Repos to exclude from expansion (bare name or owner/name), default: []
  --help, -h                        # Print this help
```

`org list` and `org remove` accept the global flags only.

## repo-tender repo

```
Commands:
  repo-tender repo add REF                  # Add a tracked repo (idempotent on host/owner/name)
  repo-tender repo list                     # List tracked repos
  repo-tender repo remove REF               # Remove a tracked repo (host/owner/name)
```

### repo-tender repo add

```
Usage:
  repo-tender repo add REF

Description:
  Add a tracked repo (idempotent on host/owner/name)

Arguments:
  REF                               # REQUIRED Repo identity as host/owner/name (e.g. github.com/ruby/ruby)

Options:
  --plain                           # Plain text output (one line per event, no color)
  --json                            # JSON output (one object per event line, 12-factor)
  --no-color                        # Disable color output
  --quiet, -q                       # Suppress non-essential output
  --help, -h                        # Print this help
```

`repo list` and `repo remove` accept the global flags only.

## repo-tender shell

```
Commands:
  repo-tender shell complete KIND [EXTRA]                     # Print completion candidates
  repo-tender shell fish [SUBCOMMAND]                         # Manage fish shell integration: install, uninstall, path
  repo-tender shell init SHELL_NAME                           # Print shell integration script
```

### repo-tender shell complete

```
Usage:
  repo-tender shell complete KIND [EXTRA]

Description:
  Print completion candidates

Arguments:
  KIND                              # REQUIRED Completion kind
  EXTRA                             # Extra args for completion

Options:
  --help, -h                        # Print this help
```

`KIND` is `checkouts` (prints one `owner/name` per line for every depth-3
directory under `base_dir`) or `shells` (prints `fish`). Unknown kinds
print `Usage: repo-tender shell complete checkouts|shells` on stderr, exit
1. Completion calls never raise on missing/unparseable config.

### repo-tender shell fish

```
Usage:
  repo-tender shell fish [SUBCOMMAND]

Description:
  Manage fish shell integration: install, uninstall, path

Arguments:
  SUBCOMMAND                        # install, uninstall, or path (default: install)

Options:
  --[no-]force                      # Overwrite or remove existing shell files, default: false
  --help, -h                        # Print this help
```

(`SUBCOMMAND` is a positional argument, not a nested command group —
`repo-tender shell fish install` and `repo-tender shell fish` are the same
call.) Installs/removes `~/.config/fish/functions/repo-tender.fish` and
`~/.config/fish/completions/repo-tender.fish`; `path` prints where both
live or would live.

### repo-tender shell init

```
Usage:
  repo-tender shell init SHELL_NAME

Description:
  Print shell integration script

Arguments:
  SHELL_NAME                        # REQUIRED Shell name (e.g. fish)

Options:
  --help, -h                        # Print this help
```

## repo-tender status

```
Usage:
  repo-tender status

Description:
  Show the per-repo evergreen status table (from $XDG_STATE_HOME/repo-tender/state.yaml)

Options:
  --plain                           # Plain text output (one line per event, no color)
  --json                            # JSON output (one object per event line, 12-factor)
  --no-color                        # Disable color output
  --quiet, -q                       # Suppress non-essential output
  --help, -h                        # Print this help
```

Prints the columns `REPO  STATUS  DEFAULT_BRANCH  LAST_SYNCED_AT
LAST_FETCH_AT`. Reads local state only — no network. With an empty state
it prints `(no repos in state — run \`repo-tender sync\` to populate)`.
The `STATUS` column is one of the fixed states described in
[state.yaml](config-and-paths.md#stateyaml).

## repo-tender sync

```
Usage:
  repo-tender sync

Description:
  Run one sync pass (use --repo to scope to a single tracked repo)

Options:
  --plain                           # Plain text output (one line per event, no color)
  --json                            # JSON output (one object per event line, 12-factor)
  --no-color                        # Disable color output
  --quiet, -q                       # Suppress non-essential output
  --repo=VALUE                      # Scope to a single tracked repo (host/owner/name)
  --help, -h                        # Print this help
```

## Exit codes and outcomes

Every command records an outcome; the process exit code is `0` on success
and `1` on a failure the command reports. Observable exit-code facts:

- A failure message goes to stderr; success output to stdout
- `clone`: exit `1` if **any** name failed (others still process), `0` otherwise
- `shell complete` with an unknown kind: stderr usage line, exit `1`
- A bare fuzzy query with no match: `repo-tender: no match for '…'` on
  stderr, exit `1`; a match prints the absolute path on the last stdout
  line, exit `0`
- Top-level `--help` / `-h` / `help` / `--version` / `version`: stdout, exit 0

## Version history

See [CHANGELOG](../../CHANGELOG.md). 1.0.0 (2026-10-08) restored the
standalone `repo-tender` identity from space-architect's absorbed `src`
binary — [the full story](../explanation/lineage-and-ecosystem.md).
