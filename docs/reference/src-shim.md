# The `src` shim 🔗

`src` is a deprecated alias binary shipped alongside `repo-tender` (both
are gem executables — the gemspec lists
`spec.executables = ["repo-tender", "src"]`). It exists so invocations
written for the absorbed space-architect 8.x identity keep working during a
migration; see [the lineage story](../explanation/lineage-and-ecosystem.md)
for how `src` ended up being this engine's name.

## Exact behavior

(`exe/src`, repo-tender 1.0.0.) On **every** invocation, `src`:

1. Prints this warning on stderr:

   ```
   src is deprecated; use repo-tender instead
   ```

2. Forwards argv, stdout, and exit codes to the `repo-tender` binary
   unchanged — including help/usage output, which is rendered under the
   primary binary's name.

So `src` and `repo-tender` are byte-identical in behavior after the warning
line: `src --help` shows the `repo-tender` command table, `src --version`
prints the same version, `src sync` syncs.

## Verified this release

```
$ repo-tender --version
1.0.0
$ src --version
src is deprecated; use repo-tender instead
1.0.0
```

## Migrating off it

[The how-to guide](../how-to/migrate-from-space-src.md) walks through the
full identity migration — automatic config/state move, launchd relabel,
and moving scripts onto `repo-tender`.
