; The outline: every function, type and dependency, and under a type its
; members, and under a dependency its operations and members.

(function_definition
  (visibility)? @context
  "fn" @context
  name: (identifier) @name) @item

(type_definition
  (visibility)? @context
  "type" @context
  name: (type_identifier) @name) @item

(dependency_definition
  (visibility)? @context
  "dep" @context
  name: (type_identifier) @name) @item

(operation
  name: (identifier) @name) @item

(associated_value
  (visibility)? @context
  "let" @context
  name: (identifier) @name) @item

(operator_definition
  name: (identifier) @name) @item

(comment) @annotation
