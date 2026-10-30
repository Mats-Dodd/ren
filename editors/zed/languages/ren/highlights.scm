; Ren's highlighting.
;
; What Ren wants seen at a glance gets a colour of its own: `&` and `inout`
; share `keyword.mutation`, since both say something changes here; `try`,
; `fail`, `attempt`, `orelse` and the `!` of an error set share
; `keyword.failure`, since they say something can fail here; and a
; dependency named in `uses` is `type.dependency`. A theme without them
; falls back to `keyword` and `type`; editors/zed/README.md shows how to
; give them their own.
;
; No node is captured twice. Zed lets the last pattern that matches win,
; and tree-sitter's own highlighter (which the tests use) the first, so a
; node with two captures would be coloured differently by each.

(comment) @comment
(number) @number
(float) @number
(string) @string
(escape_sequence) @string.escape
(boolean) @boolean
(self) @variable.special
(wildcard) @variable.special
; in a handler over a dependency, the implementation under it: `next.get()`
; and `next(A).get()`. Only so: `N.next()` names an operation
((method_call_expression
  receiver: (identifier) @variable.special)
  (#eq? @variable.special "next"))
((call_expression
  function: (identifier) @variable.special)
  (#eq? @variable.special "next"))
; in a handler `over any`, the call its arm runs for: `call => ...`
(any_arm call: (identifier) @variable.special)

[
  "fn"
  "type"
  "dep"
  "let"
  "var"
  "for"
  "while"
  "in"
  "if"
  "then"
  "else"
  "match"
  "import"
  "as"
  "uses"
  "opaque"
  "not"
  "with"
  "handler"
  "over"
  "finally"
  "test"
  "group"
  "assert"
  "has"
] @keyword

(visibility) @keyword
(any) @keyword
(numeric) @keyword
(break) @keyword
(todo) @keyword
; how a block parameter's block runs: `concurrent`, `spawned`
(block_mode) @keyword

; something changes here
(reference "&" @keyword.mutation)
(inout) @keyword.mutation

; something can fail here
["try" "fail" "attempt" "orelse"] @keyword.failure
(error_set "!" @keyword.failure)
; the empty set, `Result<Int, !>`, is the `!` alone
((error_set) @keyword.failure (#eq? @keyword.failure "!"))

; a boundary the program crosses
(dependency (type_identifier) @type.dependency)
(dependency module: (identifier) @namespace)
(dependency_definition name: (type_identifier) @type.dependency)
; a named row stands for whatever a closure or an implementation uses, or
; fails with
(uses_clause row: (named_row) @type.dependency)
(error_set row: (named_row) @type)

; ---- declarations ----

(function_definition name: (identifier) @function)
(associated_value name: (identifier) @constant)
(type_definition name: (type_identifier) @type)
(operation name: (identifier) @function)
(handler_definition name: (identifier) @function)
(handler_arm name: (identifier) @function)
(handler_arm dependency: (type_identifier) @type.dependency)
(group_definition name: (identifier) @function)
(type_parameters (type_identifier) @type)
; <T has eq, ord>: what a type parameter needs
(constrained_type_parameter name: (type_identifier) @type)
(constrained_type_parameter requirement: (identifier) @type)
(variant name: (type_identifier) @constructor)
(payload name: (identifier) @property)
(field_declaration name: (identifier) @property)
(parameter name: (identifier) @variable.parameter)
(tuple_parameter (tuple_pattern (identifier) @variable.parameter))
(tuple_parameter
  (tuple_pattern (tuple_pattern (identifier) @variable.parameter)))
(tuple_parameter (constructor_pattern (identifier) @variable.parameter))
(tuple_parameter
  (parenthesized_pattern (as_pattern name: (identifier) @variable.parameter)))
(function_type_parameter name: (identifier) @variable.parameter)

; ---- modules ----

(module_path (identifier) @namespace)
(import alias: (identifier) @namespace)
(type_name module: (identifier) @namespace)
(import (type_identifier) @type)

; ---- types and constructors ----

(type_name name: (type_identifier) @type)
(constructor_ref name: (type_identifier) @constructor)
; a variant type, `Order.Placed`, is a type: its variant's name too
(variant_type variant: (type_identifier) @type)

; ---- errors ----

; a tag is written like a constructor. A bare name after `!` can also be a
; named error set, which only the compiler can tell
(error_tag name: (type_identifier) @constructor)
(fail_expression tag: (type_identifier) @constructor)
(fail_pattern tag: (type_identifier) @constructor)
; `fail on`, a parameter of `Tags`, and the tags one's given by name
(fail_pattern tags: (identifier) @variable.parameter)
(tag_set (error_tag) @constructor)
(error_set_name module: (identifier) @namespace)
(error_set_name name: (type_identifier) @type)

; ---- uses ----

((call_expression function: (identifier) @function)
  (#not-eq? @function "next"))
(method_call_expression name: (identifier) @function.method)
(item_expression name: (identifier) @function)
; a chain's step, a function from elsewhere (language.md §8)
(pipe_step function: (identifier) @function)
(step_path module: (identifier) @namespace)
(step_path name: (identifier) @function)
(field_expression field: (identifier) @property)
(field_initializer name: (identifier) @property)
; a record pattern's field, `{ id, lines: ls, .. }`
(field_pattern name: (identifier) @property)
(labeled_argument label: (identifier) @property)
(named_argument name: (identifier) @variable.parameter)

; ---- operators and punctuation ----

(binary_expression operator: _ @operator)
(assignment operator: _ @operator)
(unary_expression "-" @operator)
(negative_number "-" @operator)
(negative "-" @operator)
(range ".." @operator)
; "the rest": an update's, `{ ..order, paid: true }`, and a pattern's
(record_expression ".." @operator)
(constructor_expression ".." @operator)
(rest_pattern) @operator
["=" "=>" "->" "|" "|>"] @operator

["." "," ":"] @punctuation.delimiter
["(" ")" "[" "]" "{" "}"] @punctuation.bracket
(type_parameters ["<" ">"] @punctuation.bracket)
(type_arguments ["<" ">"] @punctuation.bracket)
