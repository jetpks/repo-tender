# Why APFS copy-on-write clones 🐄

`repo-tender clone` doesn't `git clone` — it copies the evergreen mirror
with `cp -Rc`, macOS APFS's **clonefile** path. A clonefile is a
copy-on-write clone: the two directories share every block on disk until
one of them modifies a file, and only the modified blocks are then
duplicated.

The user-visible consequences:

- **Near-instant.** No network, no packing, no checkout-from-nothing —
  the kernel clones the file tree's metadata and block references. A
  working copy of ruby/ruby appears in about as long as it takes to write
  the directory entries.
- **Barely any disk.** Until you start editing, the "copy" costs
  kilobytes, not the gigabytes a second full checkout would.
- **Fully independent afterward.** A COW clone is a real, writable repo —
  not a git worktree or symlink. It has its own `.git`; commits, branches,
  and rebases behave exactly as usual, and diverging costs disk only as
  fast as you actually diverge.

The catch is platform: clonefile is APFS-only, which is one reason
repo-tender is [macOS-only](../reference/config-and-paths.md#requirements).
On other filesystems `cp -Rc` degrades to a regular deep copy — slower and
space-consuming — so the platform assumption is load-bearing, not
decorative.

And because the source is always the evergreen mirror, the copy starts
[as evergreen as the mirror is](evergreen.md#what-a-sync-pass-promises) —
freshness is guaranteed by the sync pass, not by the copy itself. A
not-yet-synced name simply doesn't resolve: `clone` reports
`"name" not found under base_dir …` and touches nothing.
