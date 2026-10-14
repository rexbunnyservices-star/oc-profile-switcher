## What does this change?

<!-- A short summary of the change and why it is needed. Link the issue it closes, e.g. "Closes #123". -->

## Screenshots

<!--
For visual changes, add before and after images in both modes, for example:
  node scripts/preview.ts --card <id> --theme aurora
  node scripts/preview.ts --card <id> --theme aurora --data empty
PNGs land in preview/<id>/<theme>/. Delete this section if nothing visual changed.
-->

## Checklist

- [ ] `npm run check` passes (typecheck, tests and build).
- [ ] `dist/` is rebuilt and committed (`npm run build`); CI fails when it is stale.
- [ ] If card output changed, the docs images are refreshed (`npm run gallery`); CI fails when they are stale.
- [ ] Visual changes look right in **dark and light**, with demo **and** empty data, and nothing overlaps or clips.
- [ ] Code under `src/cards` and `src/core` stays browser-safe (no `node:` imports, `process` or `Buffer`) and deterministic (`ctx.now`, no `Math.random()`).
- [ ] User-provided text is escaped with `esc()` and long text is truncated with `fit()` or `wrap()`.
- [ ] Tests cover the change, and docs or option tables are updated if behaviour changed (`npm run gen:actions` after editing `actions/manifest.json`).
- [ ] Commit messages follow [Conventional Commits](https://www.conventionalcommits.org) (`feat:`, `fix:`, `docs:`, ...).
