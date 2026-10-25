# Ren for Zed

Highlighting, an outline (each type's `ops` items under it), indentation,
vim text objects (`af`/`if` a function, `ac`/`ic` a type) and a ▶ beside
`fn main` that runs the program. The grammar is
[editors/tree-sitter-ren](../tree-sitter-ren), which mirrors the
compiler's parser.

## Install

In Zed, run **zed: install dev extension** from the command palette and
pick this folder, `editors/zed`. Zed builds the grammar from the commit
`extension.toml` names. After the grammar changes, update that `rev` and
run **zed: rebuild dev extension** (or reinstall it).

The ▶ and the `ren run`, `ren check` and `ren types` tasks use `ren` if
it's on your `PATH`, and `dune exec ren` from the project otherwise.

## Colours of Ren's own

Two captures say what Ren wants seen at a glance:

- `keyword.mutation`: `&` and `inout`, where something changes
- `type.dependency`: a dependency named in `uses`, like `Io`

A theme that doesn't know them shows them as `keyword` and `type`. To give
them their own colours, add this to your Zed `settings.json`:

```json
"experimental.theme_overrides": {
  "syntax": {
    "keyword.mutation": { "color": "#f0a04b", "font_weight": 700 },
    "type.dependency": { "color": "#4fc1a6", "font_style": "italic" }
  }
}
```
