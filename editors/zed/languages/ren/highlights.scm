; Ren's highlighting.
;
; What Ren wants seen at a glance gets a colour of its own: `&` and `inout`
; share `keyword.mutation`, since both say something changes here, and a
; dependency named in `uses` is `type.dependency`. A theme without them
; falls back to `keyword` and `type`; editors/zed/README.md shows how to
; give them their own.
;
; No node is captured twice. Zed lets the last pattern that matches win,
; and tree-sitter's own highlighter (which the tests use) the first, so a
; node with two captures would be coloured differently by each.

(comment) @comment
(number) @number
(boolean) @boolean
(self) @variable.special
(wildcard) @variable.special

[
  "fn"
  "type"
  "let"
  "var"
  "for"
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
] @keyword

(visibility) @keyword

; something changes here
(reference "&" @keyword.mutation)
(inout) @keyword.mutation

; a boundary the program crosses
(dependency (type_identifier) @type.dependency)

; ---- declarations ----

(function_definition name: (identifier) @function)
(operator_definition name: (identifier) @function)
(associated_value name: (identifier) @constant)
(type_definition name: (type_identifier) @type)
(type_parameters (type_identifier) @type)
(variant name: (type_identifier) @constructor)
(field_declaration name: (identifier) @property)
(parameter name: (identifier) @variable.parameter)
(function_type_parameter name: (identifier) @variable.parameter)

; ---- modules ----

(module_path (identifier) @namespace)
(import alias: (identifier) @namespace)
(type_name module: (identifier) @namespace)
(import (type_identifier) @type)

; ---- types and constructors ----

(type_name name: (type_identifier) @type)
(constructor_ref name: (type_identifier) @constructor)

; ---- uses ----

(call_expression function: (identifier) @function)
(method_call_expression name: (identifier) @function.method)
(item_expression name: (identifier) @function)
(field_expression field: (identifier) @property)
(field_initializer name: (identifier) @property)
(labeled_argument label: (identifier) @property)

; ---- operators and punctuation ----

(binary_expression operator: _ @operator)
(assignment operator: _ @operator)
(unary_expression "-" @operator)
(negative_number "-" @operator)
["=" "=>" "->" "|"] @operator

["." "," ":"] @punctuation.delimiter
["(" ")" "[" "]" "{" "}"] @punctuation.bracket
(type_parameters ["<" ">"] @punctuation.bracket)
(type_arguments ["<" ">"] @punctuation.bracket)
