# Explanation 🤔

Understanding-oriented background: the design decisions, the trade-offs,
the history — the "why" behind the tool. No instructions, no recipes; for
those, see the [how-to](../how-to/README.md) and
[reference](../reference/README.md) quadrants.

- [What "evergreen" means](evergreen.md) — the three-part invariant at the
  heart of the tool, and what a sync pass actually promises
- [Design: how repo-tender works](design.md) — the cardinal rule,
  local-first/network-last, config vs. state, launchd instead of a daemon,
  the fuzzy-nav shell contract
- [Why APFS copy-on-write clones](apfs-cow-clones.md) — why a working copy
  takes seconds and almost no disk
- [Lineage and ecosystem](lineage-and-ecosystem.md) — 0.x repo-tender →
  space-architect's `src` → standalone again, and how the pieces fit with
  space-cadet and space-architect
