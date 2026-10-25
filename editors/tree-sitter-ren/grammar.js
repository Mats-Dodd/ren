/**
 * Ren's grammar for tree-sitter: what editors use to highlight, outline,
 * indent and select Ren code.
 *
 * It mirrors the compiler's parser (lib/syntax/parser.ml) rule for rule,
 * and follows the language the compiler accepts today, not the one the
 * README sketches: it grows with each stage. `make -C editors/tree-sitter-ren
 * check` holds the two together: every program the compiler parses has to
 * parse here without an error (differential.py), and the corpus pins the
 * trees.
 *
 * Layout works as in the compiler's lexer (lib/syntax/lexer.ml): the
 * external scanner (src/scanner.c) turns indentation into INDENT, DEDENT
 * and NEWLINE, ignores line breaks inside brackets, and lets an indented
 * line starting with `uses` continue the signature above it.
 *
 * Capitalization tells names apart without looking anything up, as in the
 * compiler: types and constructors are capitalized, and variables,
 * functions and modules aren't. One thing the parser leaves to Resolve is
 * decided here instead: `Stack.of` is an item of a type's `ops` block,
 * though it could be a method of a constructor, `Admin.rank`. The first is
 * far more common, and it's only a colour.
 */

const PREC = {
  compare: 1,
  add: 2,
  mul: 3,
  unary: 4,
  postfix: 5,
};

// `a, b, c`, with a trailing comma allowed, and possibly empty
const commaSep = (rule) => optional(commaSep1(rule));
const commaSep1 = (rule) => seq(rule, repeat(seq(',', rule)), optional(','));
const sep1 = (rule, separator) => seq(rule, repeat(seq(separator, rule)));

module.exports = grammar({
  name: 'ren',

  externals: ($) => [
    $._newline,
    $._indent,
    $._dedent,
    '(',
    ')',
    '[',
    ']',
    '{',
    '}',
    // never in the grammar: valid only while tree-sitter recovers from an
    // error, which is how the scanner knows it is
    $._error_sentinel,
  ],

  extras: ($) => [/[ \t\r\n]/, $.comment],

  word: ($) => $.identifier,

  conflicts: ($) => [
    // `billing.Plan` is a module's type, and `user.plan` a field: the token
    // after the dot decides
    [$._primary, $.type_name],
    // the next line of an indented sum type may start with `|`
    [$.sum_type],
  ],

  supertypes: ($) => [$._expression, $._pattern, $._type],

  rules: {
    // program := item { NEWLINE item } EOF
    source_file: ($) =>
      optional(seq(sep1($._item, $._newline), optional($._newline))),

    _item: ($) => choice($.import, $.function_definition, $.type_definition),

    comment: (_) => token(seq('//', /[^\n]*/)),

    // ---- imports ----

    // import billing/stripe.{Client} as pay
    import: ($) =>
      seq(
        'import',
        field('path', $.module_path),
        optional(seq('.', '{', commaSep($.type_identifier), '}')),
        optional(seq('as', field('alias', $.identifier))),
      ),

    module_path: ($) => sep1($.identifier, '/'),

    // ---- functions ----

    function_definition: ($) =>
      seq(
        optional($.visibility),
        'fn',
        field('name', $.identifier),
        optional(field('type_parameters', $.type_parameters)),
        field('parameters', $.parameters),
        optional(seq('->', field('return_type', $._type))),
        optional(field('uses', $.uses_clause)),
        '=',
        field('body', $._body),
      ),

    visibility: (_) => 'pub',

    type_parameters: ($) => seq('<', commaSep($.type_identifier), '>'),

    parameters: ($) => seq('(', commaSep($.parameter), ')'),

    parameter: ($) =>
      seq(
        optional($.inout),
        field('name', choice($.identifier, $.self)),
        optional(seq(':', field('type', $._type))),
      ),

    inout: (_) => 'inout',

    // uses Io, Clock: the dependencies a function's body may call
    uses_clause: ($) => seq('uses', commaSep1Strict($.dependency)),

    dependency: ($) => $.type_identifier,

    // ---- types ----

    type_definition: ($) =>
      seq(
        optional($.visibility),
        'type',
        field('name', $.type_identifier),
        optional(field('type_parameters', $.type_parameters)),
        '=',
        choice(
          // type Cart = { ... }, with its ops block indented below
          seq(
            field('body', $._type_body),
            optional(seq($._indent, field('ops', $.ops_block), $._dedent)),
          ),
          // the body indented under `type X =`, and the ops block on a
          // line of its own after it
          seq(
            $._indent,
            field('body', $._type_body),
            optional(seq($._newline, field('ops', $.ops_block))),
            $._dedent,
          ),
        ),
      ),

    _type_body: ($) => choice($.record_type, $.opaque_type, $.sum_type),

    record_type: ($) => seq('{', commaSep($.field_declaration), '}'),

    opaque_type: ($) => seq('opaque', field('representation', $._type)),

    // | Free | Pro(seats: Int), and indented, one `|` per line
    sum_type: ($) =>
      seq(
        optional('|'),
        sep1($.variant, seq(optional($._newline), '|')),
      ),

    variant: ($) =>
      seq(
        field('name', $.type_identifier),
        optional(seq('(', commaSep($.field_declaration), ')')),
      ),

    field_declaration: ($) =>
      seq(field('name', $.identifier), ':', field('type', $._type)),

    // ---- ops ----

    // `ops` is a keyword only here
    ops_block: ($) =>
      seq('ops', '=', $._indent, sep1($._op, $._newline), $._dedent),

    _op: ($) =>
      choice($.function_definition, $.associated_value, $.operator_definition),

    // pub let empty: Stack<T> = Stack { items: [] }
    associated_value: ($) =>
      seq(
        optional($.visibility),
        'let',
        field('name', $.identifier),
        optional(seq(':', field('type', $._type))),
        '=',
        field('value', $._body),
      ),

    // add(other) => ...: parsed by the compiler, but reported until stage 9
    operator_definition: ($) =>
      seq(
        field('name', $.identifier),
        optional(field('parameters', $.parameters)),
        '=>',
        field('body', $._body),
      ),

    // ---- written types ----

    _type: ($) => choice($.named_type, $.function_type),

    // Int, Option<Int>, stripe.Client
    named_type: ($) =>
      seq(
        field('name', $.type_name),
        optional(field('arguments', $.type_arguments)),
      ),

    type_arguments: ($) => seq('<', commaSep($._type), '>'),

    // fn(inout Array<Int>, id: UserId) -> User
    function_type: ($) =>
      seq(
        'fn',
        '(',
        commaSep($.function_type_parameter),
        ')',
        optional(seq('->', field('return_type', $._type))),
      ),

    function_type_parameter: ($) =>
      seq(
        optional($.inout),
        optional(seq(field('name', $.identifier), ':')),
        field('type', $._type),
      ),

    // Plan, or another module's, billing.Plan. A capitalized name followed
    // by a dot is always a type's: `Plan.Free`, `Stack.of`.
    type_name: ($) =>
      choice(
        prec(1, field('name', $.type_identifier)),
        seq(field('module', $.identifier), '.', field('name', $.type_identifier)),
      ),

    // ---- bodies and statements ----

    _body: ($) => choice($.block, $._line),

    block: ($) => seq($._indent, sep1($._statement, $._newline), $._dedent),

    _statement: ($) => choice($.let_statement, $.for_statement, $._line),

    let_statement: ($) =>
      seq(
        choice('let', 'var'),
        field('name', $.identifier),
        optional(seq(':', field('type', $._type))),
        '=',
        field('value', $._body),
      ),

    for_statement: ($) =>
      seq(
        'for',
        field('variable', $.identifier),
        'in',
        field('iterable', $._expression),
        field('body', $.block),
      ),

    // a lambda's body takes an assignment after it, as the parser does
    _line: ($) => prec.right(choice($._expression, $.assignment)),

    // x = 1, xs[i] += 1
    assignment: ($) =>
      seq(
        field('target', $._expression),
        field('operator', choice('=', '+=', '-=', '*=')),
        field('value', $._body),
      ),

    // ---- expressions ----

    _expression: ($) =>
      choice(
        $.binary_expression,
        $.unary_expression,
        $.reference,
        $._postfix,
      ),

    binary_expression: ($) =>
      choice(
        ...[
          [PREC.compare, choice('==', '!=', '<', '<=', '>', '>=')],
          [PREC.add, choice('+', '-')],
          [PREC.mul, choice('*', '/', '%')],
        ].map(([p, op]) =>
          prec.left(
            p,
            seq(
              field('left', $._expression),
              field('operator', op),
              field('right', $._expression),
            ),
          ),
        ),
      ),

    unary_expression: ($) =>
      prec(PREC.unary, seq('-', field('operand', $._expression))),

    // &xs, &xs.push(x): the value the call changes
    reference: ($) =>
      prec(PREC.unary, seq('&', field('place', $._expression))),

    _postfix: ($) =>
      choice(
        $.field_expression,
        $.index_expression,
        $.call_expression,
        $.method_call_expression,
        $._primary,
      ),

    field_expression: ($) =>
      prec(
        PREC.postfix,
        seq(field('value', $._postfix), '.', field('field', $.identifier)),
      ),

    index_expression: ($) =>
      prec(
        PREC.postfix,
        seq(field('value', $._postfix), '[', field('index', $._expression), ']'),
      ),

    // f(x), s.push(x), and with a trailing lambda, twice() fn() => ...
    call_expression: ($) =>
      prec(
        PREC.postfix,
        seq(
          field('function', $._postfix),
          field('arguments', $.arguments),
          optional(field('trailing', $.lambda)),
        ),
      ),

    // s.push(x), x.m(args) meaning Type.m(x, args); `util.double(2)`, a
    // module's function, reads the same, and only Resolve can tell them apart
    method_call_expression: ($) =>
      prec(
        PREC.postfix + 1,
        seq(
          field('receiver', $._postfix),
          '.',
          field('name', $.identifier),
          field('arguments', $.arguments),
          optional(field('trailing', $.lambda)),
        ),
      ),

    arguments: ($) => seq('(', commaSep($._expression), ')'),

    _primary: ($) =>
      choice(
        $.number,
        $.boolean,
        $.unit,
        $.identifier,
        $.self,
        $.lambda,
        $.constructor_expression,
        $.record_expression,
        $.item_expression,
        $.array_expression,
        $.parenthesized_expression,
        $.if_expression,
        $.match_expression,
      ),

    number: (_) => /[0-9][0-9_]*/,
    boolean: (_) => choice('true', 'false'),
    unit: (_) => seq('(', ')'),
    self: (_) => 'self',

    lambda: ($) =>
      prec.right(
        seq(
          'fn',
          field('parameters', $.parameters),
          '=>',
          field('body', $._body),
        ),
      ),

    // Free, Pro(5), Pro(seats: 5), Plan.Free, billing.Plan.Free
    constructor_expression: ($) =>
      prec.right(
        seq(
          field('constructor', $.constructor_ref),
          optional(field('arguments', $.constructor_arguments)),
        ),
      ),

    constructor_ref: ($) =>
      seq(
        optional(seq(field('type', $.type_name), '.')),
        field('name', $.type_identifier),
      ),

    constructor_arguments: ($) =>
      seq('(', commaSep(choice($.labeled_argument, $._expression)), ')'),

    labeled_argument: ($) =>
      seq(field('label', $.identifier), ':', field('value', $._expression)),

    // Plan { id: 1, plan }, and without its type, { id: 1 }
    record_expression: ($) =>
      seq(
        optional(field('type', $.type_name)),
        '{',
        commaSep($.field_initializer),
        '}',
      ),

    // `id: 1`, or just `id`, meaning `id: id`
    field_initializer: ($) =>
      seq(
        field('name', $.identifier),
        optional(seq(':', field('value', $._expression))),
      ),

    // Stack.of, stack.Stack.empty: an item of a type's ops block
    item_expression: ($) =>
      seq(field('type', $.type_name), '.', field('name', $.identifier)),

    array_expression: ($) => seq('[', commaSep($._expression), ']'),

    parenthesized_expression: ($) => seq('(', $._expression, ')'),

    if_expression: ($) =>
      prec.right(
        seq(
          'if',
          field('condition', $._expression),
          'then',
          field('consequence', $._body),
          optional(
            seq(optional($._newline), 'else', field('alternative', $._body)),
          ),
        ),
      ),

    match_expression: ($) =>
      seq(
        'match',
        field('subject', $._expression),
        $._indent,
        sep1($.match_arm, $._newline),
        $._dedent,
      ),

    match_arm: ($) =>
      seq(
        field('pattern', $._pattern),
        optional(seq('if', field('guard', $._expression))),
        '=>',
        field('body', $._body),
      ),

    // ---- patterns ----

    _pattern: ($) =>
      choice(
        $.wildcard,
        $.identifier,
        $.number,
        $.negative_number,
        $.boolean,
        $.constructor_pattern,
      ),

    wildcard: (_) => '_',

    negative_number: ($) => seq('-', $.number),

    constructor_pattern: ($) =>
      seq(
        field('constructor', $.constructor_ref),
        optional(seq('(', commaSep($._pattern), ')')),
      ),

    // ---- names ----

    identifier: (_) => /[a-z_][A-Za-z0-9_]*/,
    type_identifier: (_) => /[A-Z][A-Za-z0-9_]*/,
  },
});

// `a, b`, with no trailing comma: a `uses` list ends at `=`
function commaSep1Strict(rule) {
  return seq(rule, repeat(seq(',', rule)));
}
