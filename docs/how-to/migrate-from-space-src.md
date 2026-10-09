# Migrate from the `src` identity 🧬

**Goal:** you used this engine as space-architect 8.x (binary `src`, state
under `~/.local/state/space-src`), and you're moving to the standalone
repo-tender 1.0.0 — with zero data loss, and your scripts still working
while you update them.

Background if you want it: [the lineage story](../explanation/lineage-and-ecosystem.md).

## 1. Upgrade the gem

```bash
gem install repo-tender
```

That's the whole upgrade — there is no separate migration step to remember.
On the **first run of any `repo-tender` command**, a one-shot, data-
preserving migration runs automatically:

- `$XDG_CONFIG_HOME/space-src/` → `$XDG_CONFIG_HOME/repo-tender/`
- `$XDG_STATE_HOME/space-src/` → `$XDG_STATE_HOME/repo-tender/`

and you'll see one line on stderr:

```
repo-tender: migrated config/state from space-src
```

The move is **no-clobber**: if a `repo-tender` directory already exists
(e.g. you ran the standalone gem before), your existing repo-tender files
are never touched — the old dirs stay put. Moves only, never deletes.

## 2. Refresh the launchd agent

The old identity's plist used the label
`io.github.jetpks.space-src.sync`. Migration flags it if it's still
installed:

```
repo-tender: stale launchd agent found (io.github.jetpks.space-src.sync); run `repo-tender daemon install` to upgrade
```

Do what it says:

```bash
repo-tender daemon install
```

This bootstraps the new-label agent
(`io.github.jetpks.repo-tender.sync`) and removes the stale old-label
plist as part of installing. Then `daemon stop` + `daemon uninstall` the
old identity if anything of it remains.

## 3. Move your scripts off `src` (at your pace) 🔁

The `src` binary still ships and still works — as a deprecation shim. Every
invocation prints this on stderr, then forwards argv, stdout, and exit
codes to `repo-tender` unchanged:

```
src is deprecated; use repo-tender instead
```

So the upgrade order can be: install first, run everything, fix scripts
when convenient. Search your scripts, shell rc files, and crontabs:

```bash
rg -l '\bsrc\b' ~/bin ~/.config/fish 2>/dev/null   # your own spots
```

and replace `src <args>` with `repo-tender <args>`. The surfaces are
identical — run `src --help` and `repo-tender --help` and compare; they
render the same text (see the [shim reference](../reference/src-shim.md)).
When nothing calls `src` anymore, uninstall the old gem identity if you
still have it (`gem uninstall space-architect` only if you don't use
space-architect itself — see its docs for the 9.x story).
