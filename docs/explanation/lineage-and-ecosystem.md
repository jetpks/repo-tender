# Lineage and ecosystem 🧬

Where repo-tender came from, and how it fits with its sibling gems.

## The story so far

1. **0.x — standalone repo-tender.** The evergreen engine began as the
   `repo-tender` gem, minding local mirrors under its own name.
2. **8.x — absorbed.** space-architect v8.0.0 absorbed the engine into its
   own namespace: module `Space::Src`, binary `src`, state under
   `$XDG_STATE_HOME/space-src`, launchd label
   `io.github.jetpks.space-src.sync`.
3. **1.0.0 — standalone again (2026-10-08).** The 2026 split of the
   monolith back into focused gems restored the engine to this repo:
   module `RepoTender`, binary `repo-tender` (with `src` kept as a
   [deprecation shim](../reference/src-shim.md)), XDG dirs and launchd
   label back under the `repo-tender` name, and a no-clobber one-shot
   migration that moves `space-src` data forward (see
   [the migration how-to](../how-to/migrate-from-space-src.md)).

The gem is small on purpose: macOS-only, GitHub-only (both behind
decoupled SCM/forge interfaces, but those are today's implementations),
built on dry-rb — validated YAML config, `Result`-typed boundaries, and
concurrency on socketry/async fibers.

## The three gems, and who ships what

The architect loop's tooling is now three gems with exact responsibilities
(each ships its own binary, from its own repo):

| Gem | Ships | Role |
|-----|-------|------|
| [space-cadet] | `space` | task-scoped workspaces: date-prefixed space dirs with a YAML identity file, provisioned at copy-on-write speed **from evergreen checkouts** |
| **repo-tender** (this gem) | `repo-tender` (and the deprecated `src`) | the evergreen engine: the local mirrors and the launchd sync rail |
| [space-architect] | `architect` | the Architect Loop: iterations, briefs, freezes, verdicts, dispatch |

[space-cadet]: https://github.com/jetpks/space-cadet
[space-architect]: https://github.com/jetpks/space-architect

The dependency arrows all point one way — nothing here knows about them:

- **space-cadet → repo-tender (soft, pairing).** `space` provisions a new
  workspace by cloning from local disk instead of the network, exactly
  because a tended mirror makes that instant. Without repo-tender,
  space-cadet still works; it just clones the slow way.
- **space-architect → space-cadet (hard dep) and → repo-tender (soft
  dep).** space-architect runs inside space-cadet's workspaces, and drives
  repo-tender's launchd agent for its session-sync rail — `gem install
  repo-tender` is optional; everything else in space-architect works
  without it.

So the layering reads bottom-up: **repo-tender tends the mirrors →
space-cadet carves instant workspaces from them → space-architect runs the
loop inside those workspaces.** This gem is the foundation that doesn't
know it's a foundation — which is why its only job is staying evergreen.
