# Ren for Zed

Highlighting, an outline (each type's members under it, a service's
functions under it, wirings beside functions, and each group's tests),
indentation, vim text objects (`af`/`if` a function or a test,
`ac`/`ic` a type), a ▶ beside `fn main` that runs the program, and one
beside each test and group run that runs it. The grammar is
[editors/tree-sitter-ren](../tree-sitter-ren), which mirrors the
compiler's parser.

## Install

In Zed, run **zed: install dev extension** from the command palette and
pick this folder, `editors/zed`. Zed builds the grammar from the commit
`extension.toml` names. After the grammar changes, update that `rev` and
run **zed: rebuild dev extension** (or reinstall it).

The ▶s and the `ren run`, `ren test`, `ren check` and `ren types` tasks
(`ren test` runs the tests of the file's folder) use `ren` if
it's on your `PATH`, and `dune exec ren` from the project otherwise.

## Colours of Ren's own

Three captures say what Ren wants seen at a glance:

- `keyword.mutation`: `&` and `inout`, where something changes
- `keyword.failure`: `try`, `fail`, `attempt`, `orelse` and the `!` of an
  error set, where something can fail
- `type.dependency`: a dependency, declared with `dep` or named in `uses`,
  like `Clock`

A theme that doesn't know them shows them as `keyword` and `type`. To give
them their own colours, add this to your Zed `settings.json`:

```json
"experimental.theme_overrides": {
  "syntax": {
    "keyword.mutation": { "color": "#f0a04b", "font_weight": 700 },
    "keyword.failure": { "color": "#e06c75", "font_weight": 700 },
    "type.dependency": { "color": "#4fc1a6", "font_style": "italic" }
  }
}
```

## What the colours can't tell

- **`Name { ... }` with a bare name** is a record or a by-name
  constructor, whichever is in scope, which only the compiler knows. The
  grammar parses it as the compiler's parser does, as a record, so
  `Rect` in `Rect { w: 2, h: 3 }` and `Placed` in `Placed { .. } as p`
  are coloured as types, not constructors. `Shape.Rect { ... }` is
  always a constructor, and coloured as one.
- **A punned field in a pattern,** `{ id, .. }`, is both the field and
  the name it binds; it's coloured as a field (`property`), in a block's
  parameter and a `for` too, where a parameter's name is
  `variable.parameter`.
