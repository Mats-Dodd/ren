; The outline: every function, type, dependency and handler, and under a
; type its members, under a dependency its operations and members, and
; under a handler the operations it implements; and every test, group and
; group run, with a group's tests under it.

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

(handler_definition
  (visibility)? @context
  "handler" @context
  name: (identifier) @name) @item

(handler_arm
  name: (identifier) @name) @item

(associated_value
  (visibility)? @context
  "let" @context
  name: (identifier) @name) @item

(operator_definition
  name: (identifier) @name) @item

(test_definition
  "test" @context
  name: (string) @name) @item

(group_definition
  (visibility)? @context
  "group" @context
  name: (identifier) @name) @item

(group_run
  "group" @context
  label: (string) @name) @item

(comment) @annotation
