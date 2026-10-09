# Schedule background syncs 🤖

**Goal:** your tracked repos stay evergreen without you ever typing
`repo-tender sync` again — or, if you'd rather stay in control, run sync
passes deliberately. Both models are first-class; pick one (or mix).

repo-tender is *not* a resident daemon: there's no socket, no IPC, no
in-process scheduler. macOS launchd wakes a short-lived `sync` every
`refresh_interval` and it exits when done. (Why: [design](../explanation/design.md).)

## Let launchd do it

```bash
repo-tender daemon install
```

```
installed: /Users/you/Library/LaunchAgents/io.github.jetpks.repo-tender.sync.plist
```

This writes a per-user plist (`StartInterval` from your config's
`refresh_interval`, plus `RunAtLoad`, so a sync also fires at login) and
bootstraps it. Check on it anytime:

```bash
repo-tender daemon status
```

```
label: io.github.jetpks.repo-tender.sync
loaded: true
running: false
pid: nil
last_exit: 0
```

Stop it (bootout + disable) without deleting anything:

```bash
repo-tender daemon stop
```

```
stopped: io.github.jetpks.repo-tender.sync
```

Or tear it down completely (bootout + remove the plist):

```bash
repo-tender daemon uninstall
```

```
removed plist: /Users/you/Library/LaunchAgents/io.github.jetpks.repo-tender.sync.plist
```

`restart` kickstarts the agent (`launchctl kickstart -k`): it runs a sync
now and keeps the schedule — handy right after editing `refresh_interval`:

```bash
repo-tender daemon restart
```

```
restarted: io.github.jetpks.repo-tender.sync
```

## Run a sync pass by hand

```bash
repo-tender sync
```

One pass, then exit: clones what's missing, fast-forwards what's clean-and-
behind, reports anything dirty or diverged. Cheap and idempotent — syncs
check local facts first (is the path present? clean? `.git/FETCH_HEAD`
younger than the interval?) and only hit the network when they must.

Scope it to one repo:

```bash
repo-tender sync --repo github.com/ruby/ruby
```

## Which should I use?

| You want | Do |
|----------|----|
| Set-and-forget freshness | `daemon install`, walk away |
| A one-off refresh before a demo | `sync` |
| A background schedule *and* an immediate refresh | `daemon install`, then `sync` or `daemon restart` whenever |
| CI / scripts | plain `sync --plain` or `sync --json` on a cron/CI schedule |

## Related

- [`daemon` CLI reference](../reference/cli.md#repo-tender-daemon)
- [What "evergreen" means](../explanation/evergreen.md) — what a sync pass
  actually promises
