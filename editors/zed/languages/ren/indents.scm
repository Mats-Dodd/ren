; Brackets indent what's inside them. A block has no closing token, so a
; line that opens one, ending in `=`, `=>`, `then` or `else`, or starting a
; `for`, a `while` or a `match`, is indented by config.toml's
; increase_indent_pattern instead.
(_ "(" ")" @end) @indent
(_ "[" "]" @end) @indent
(_ "{" "}" @end) @indent
