; vim mode's text objects: `af`/`if` a function or a test, `ac`/`ic` a
; type with its members (`ac` a dependency, a handler or a group), `gc` a
; comment.

(function_definition
  body: (_) @function.inside) @function.around

(associated_value
  value: (_) @function.inside) @function.around

(lambda
  body: (_) @function.inside) @function.around

(type_definition
  body: (_) @class.inside) @class.around

; a dependency, with its operations and members
(dependency_definition) @class.around

; a handler, with its state and arms; an arm is a function, and so is
; its `finally`
(handler_definition) @class.around

(handler_arm
  body: (_) @function.inside) @function.around

(finally_arm
  body: (_) @function.inside) @function.around

(test_definition
  body: (_) @function.inside) @function.around

; a group, with its tests
(group_definition) @class.around

(comment)+ @comment.around
