; A ▶ beside `fn main`: it runs the program the file is the entry of.

((function_definition
   name: (identifier) @run @_name)
 (#eq? @_name "main")
 (#set! tag ren-main))

; A ▶ beside a test, and beside a group's run: it runs that test, or the
; run's tests, with `ren test --only <name> --exact`, so not every test
; whose name has it in it. The name, in its quotes and with its escapes as
; written, is in $ZED_CUSTOM_name, which the task (tasks.json) unquotes and
; unescapes (`\"` and `\\`; a `\n` or `\t` in a test's name isn't). A
; test inside a group runs only in a run of it.

((source_file
   (test_definition
     "test" @run
     name: (string) @name))
 (#set! tag ren-test))

((group_run
   "group" @run
   label: (string) @name)
 (#set! tag ren-test))
