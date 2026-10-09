# Track repos and orgs 🐙🌐

**Goal:** tell repo-tender which git repos to keep evergreen — a handful by
name, or every repo in a GitHub org, with per-org filtering.

Everything here edits `$XDG_CONFIG_HOME/repo-tender/config.yaml` (via
`repo-tender repo` / `repo-tender org`) — never the file by hand while also
using the CLI, since a CLI write regenerates it. Nothing is cloned until the
next [sync pass](schedule-background-sync.md#run-a-sync-pass-by-hand).

## Track a single repo

```bash
repo-tender repo add github.com/ruby/ruby
```

```
added: github.com/ruby/ruby
```

The reference must be the full `host/owner/name` form. Adding an already-
tracked repo is a no-op (idempotent on `host/owner/name`).

List and remove:

```bash
repo-tender repo list
repo-tender repo remove github.com/ruby/ruby
```

## Track a whole org 🌐

```bash
repo-tender org add socketry              # host defaults to github.com
repo-tender org add github.com/socketry   # equivalent, explicit host
```

Orgs are stored as intents and expanded to their member repos at sync time
via `gh` — so a repo created in the org tomorrow is tracked automatically.

By default, expansion **skips archived repos and forks**. Include them:

```bash
repo-tender org add socketry --include-archived
repo-tender org add socketry --include-forks
```

Both flags are recorded per-org in the config.

### Ignore specific repos ✋

Big org, few monsters you never want on disk? Exclude them at expansion
time with a comma-separated list (bare `name` or `owner/name`):

```bash
repo-tender org add bigco --ignored-repos monorepo,huge
```

```
added: github.com/bigco (… ignored_repos=["monorepo", "huge"])
```

The ignore list is authoritative: an ignored repo never enters a sync sweep,
even if it's already on disk.

List and remove:

```bash
repo-tender org list
repo-tender org remove github.com/bigco
```

## See the result

```bash
repo-tender sync                # one pass; clones what's missing, updates the rest
repo-tender status              # the per-repo health table
repo-tender config show         # the effective, validated config as YAML
```

## Related

- [Schedule background syncs](schedule-background-sync.md) — stop running
  sync by hand
- [CLI reference: `repo`](../reference/cli.md#repo-tender-repo)
  / [`org`](../reference/cli.md#repo-tender-org)
