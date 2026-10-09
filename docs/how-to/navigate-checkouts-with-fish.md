# Navigate checkouts with fish 🐟

**Goal:** in the fish shell, type `repo-tender clone <fuzzy>` (or any
command whose output ends in a checkout path) and land *inside* that
checkout — with tab completion over your evergreen mirrors.

repo-tender ships a fish wrapper function plus completions. The wrapper
runs every `repo-tender` subcommand unchanged (`repo`, `org`, `sync`,
`status`, `config`, `daemon`, `clone`, `shell`); for anything else, it
takes the binary's last stdout line and, if that line is a directory on
disk, `cd`s into it.

## Install it

```bash
repo-tender shell fish install
```

```
Installed function: /Users/you/.config/fish/functions/repo-tender.fish
Installed completions: /Users/you/.config/fish/completions/repo-tender.fish
Restart fish to load the integration in this terminal: exec fish
```

`exec fish` once, and you're done.

Install/update/remove variants:

```bash
repo-tender shell fish install --force   # overwrite existing files
repo-tender shell fish path              # print where files live/would live
repo-tender shell fish uninstall         # remove both files
```

## Use it

Because `clone`'s last output line is the destination path, the wrapper
drops you straight into the fresh copy:

```fish
~/wip> repo-tender clone Hello-World
cloned: Hello-World → /Users/you/wip/Hello-World
~/wip/Hello-World>
```

Fuzzy navigation rides on the same mechanism: type a case-insensitive
*fuzzy match* against `owner/name` — it doesn't have to be a prefix:

```fish
~/wip> repo-tender hello
/Users/you/src/evergreen/github.com/octocat/Hello-World
~/wip/Hello-World>
```

The matcher is subsequence-based with contiguity, word-boundary, and
earliness ranking; ambiguous queries resolve to the best single match.
(How it scores: [`Nav` module](../../lib/repo_tender/nav.rb).)

## Tab completion ⌨️

The installed completions suggest subcommands and repo candidates as you
type. They're powered by the same `shell complete` command scripts can use:

```bash
repo-tender shell complete checkouts   # one owner/name per line from base_dir
repo-tender shell complete shells      # supported shells: fish
```

Not on fish? `repo-tender shell init fish` prints the integration script to
stdout so another shim can consume it — other shells have no installer yet.

## Related

- [`shell` CLI reference](../reference/cli.md#repo-tender-shell)
- [Fuzzy nav explanation](../explanation/design.md#fuzzy-navigation-is-a-shell-contract)
