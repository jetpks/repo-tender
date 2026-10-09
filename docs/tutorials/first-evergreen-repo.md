# Your first evergreen repo 🌱

In this tutorial you'll take one GitHub repo from "a URL I clone a lot" to "a
fresh local mirror I can copy instantly" — the whole repo-tender loop. It
takes about five minutes and works on a fresh machine with only the gem
installed.

> Everything you do here is reversible and nothing can lose your work:
> repo-tender never touches a repo that isn't clean. See
> [the cardinal rule](../explanation/design.md#the-cardinal-rule-never-lose-your-work)
> if you want the why.

## What you need ✅

- macOS (repo-tender schedules background syncs via launchd)
- Ruby 4.0.5 or newer — [mise](https://mise.jdx.dev/) is the easiest way
- git 2.54+
- `gh` (the GitHub CLI), logged in — only needed for org tracking, but
  install it now so you never think about it again: `gh auth status`

## 1. Install 📦

```bash
gem install repo-tender
repo-tender --version
```

You should see `1.0.0` (or newer).

## 2. Track a repo 🐙

Pick a small repo to practice on — we'll use `octocat/Hello-World`:

```bash
repo-tender repo add github.com/octocat/Hello-World
```

```
added: github.com/octocat/Hello-World
```

Repos are named `host/owner/name` so two forges never collide. Confirm it's
tracked:

```bash
repo-tender repo list
```

```
github.com/octocat/Hello-World
```

You haven't cloned anything yet — you've written intent to
`$XDG_CONFIG_HOME/repo-tender/config.yaml`. Next you make it real.

## 3. Sync it locally ⚡

```bash
repo-tender sync --plain
```

```
listing: 0 org(s)
starting: 1 repo(s)
github.com/octocat/Hello-World	clean
synced 1 repo(s)
```

A full clone now lives under `~/src/evergreen/github.com/octocat/Hello-World`
(you can change that home later — see [config reference](../reference/config-and-paths.md)).
`clean` is the evergreen verdict: the mirror is clean, on its default branch
(`master` here — resolved from the remote's `origin/HEAD`, refreshed
from the remote when stale, never assumed), and freshly
fetched.

Check the health table:

```bash
repo-tender status --plain
```

```
REPO	STATUS	DEFAULT_BRANCH	LAST_SYNCED_AT	LAST_FETCH_AT
github.com/octocat/Hello-World	clean	master	2026-10-09T10:56:49-06:00
```

`status` reads local state only — no network.

## 4. Grab an instant working copy 🐄

The mirror is for reading *from*, not working *in*. Get a working copy with
`clone` — a near-instant APFS copy-on-write copy from local disk, no network:

```bash
mkdir -p ~/wip
repo-tender clone Hello-World --into ~/wip
```

```
cloned: Hello-World → /Users/you/wip/Hello-World
```

That's a real repo — `cd` in and start working. The copy took barely any
disk; see [why that's possible](../explanation/apfs-cow-clones.md).

## 5. See the safety net in action 🔒

Dirty the **mirror** (not your copy) and sync again:

```bash
echo dirt >> ~/src/evergreen/github.com/octocat/Hello-World/dirty-file
repo-tender sync --plain
```

```
listing: 0 org(s)
starting: 1 repo(s)
github.com/octocat/Hello-World	dirty
synced 1 repo(s)
```

The mirror is reported `dirty` — and left exactly as it is. No fetch, no
reset, no lost file. Remove the file and `status` returns to `clean` on the
next sync.

## 6. Clean up (optional) 🧹

```bash
repo-tender repo remove github.com/octocat/Hello-World
rm -rf ~/src/evergreen/github.com/octocat/Hello-World
```

## Where next? 🧭

- Keep the mirror fresh forever: [schedule background syncs](../how-to/schedule-background-sync.md)
- Track whole orgs and filter them: [track repos and orgs](../how-to/track-repos-and-orgs.md)
- What "evergreen" really promises: [the explanation](../explanation/evergreen.md)
- Every command and flag: [CLI reference](../reference/cli.md)
