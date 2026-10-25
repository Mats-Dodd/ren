; The outline: every function and type, and under a type its members.

(function_definition
  (visibility)? @context
  "fn" @context
  name: (identifier) @name) @item

(type_definition
  (visibility)? @context
  "type" @context
  name: (type_identifier) @name) @item

(associated_value
  (visibility)? @context
  "let" @context
  name: (identifier) @name) @item

(operator_definition
  name: (identifier) @name) @item

(comment) @annotation
