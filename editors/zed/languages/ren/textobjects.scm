; vim mode's text objects: `af`/`if` a function, `ac`/`ic` a type with its
; ops block, `gc` a comment.

(function_definition
  body: (_) @function.inside) @function.around

(associated_value
  value: (_) @function.inside) @function.around

(lambda
  body: (_) @function.inside) @function.around

(type_definition
  body: (_) @class.inside) @class.around

(comment)+ @comment.around
