# What "evergreen" means 🌿

"Evergreen" is not a vibe — it's a checkable invariant. A mirror under
`base_dir` is evergreen when all three of these hold at once:

1. **Clean** — `git status --porcelain` reports nothing: no modified,
   staged, untracked, or deleted files
2. **On the default branch** — whatever the remote calls it (`main`,
   `trunk`, `master`…). repo-tender resolves the default branch from the
   remote's `origin/HEAD` (refreshed from the remote via
   `git remote set-head origin -a` when missing or stale) and never
   assumes
3. **Fresh** — fast-forwarded to the remote within your `refresh_interval`
   (default 6 hours)

## What a sync pass promises

Each sync pass, per tracked repo:

- **Missing?** Clone it.
- **Clean and strictly behind?** Fast-forward it. Strictly — a fast-forward
  never discards anything by definition.
- **Dirty, diverged, detached, or on a non-default branch?** *Report it and
  leave it byte-for-byte alone.* There is no code path that resets,
  discards, or force-updates a checkout. No `reset --hard`, ever.

That asymmetry is the whole design: progress is only ever made through
operations that cannot lose work. Everything else surfaces as a status —
one of `clean`, `dirty`, `diverged`, `detached`, `wrong_branch`,
`missing`, `error` in [state.yaml](../reference/config-and-paths.md#stateyaml)
— because a mirror that needs a human decision should *ask* for one, not
guess.

## Why a mirror at all?

Because the expensive part of cloning is the network round-trip, and most
developers re-purchase the same repos from the network over and over. A
tended local mirror turns "clone ruby/ruby" into a local-disk copy —
[instant, and nearly free](apfs-cow-clones.md) — for anything downstream:
your own ad-hoc work, a workspace tool like space-cadet's `space`, a
review, an experiment you'd never risk in your main checkout.

## Why the freshness window is a *window*

`refresh_interval` makes re-syncs cheap and idempotent: each pass checks
local facts first (path present? clean? `.git/FETCH_HEAD` younger than the
window?) and only touches the network when it must. "Evergreen" therefore
means "never *meaningfully* stale" — at most one interval behind, and
usually zero.
