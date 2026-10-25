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
 * decided here instead: `Stack.of` is one of a type's members,
 * though it could be a method of a constructor, `Admin.rank`. The first is
 * far more common, and it's only a colour.
 */

// `not` binds below the comparisons, so `not a == b` is `not (a == b)`,
// and above `&&`, so `not a && b` is `(not a) && b`. `orelse` binds below
// `||`. `try` and `attempt` take everything to their right, so they bind
// loosest of all.
const PREC = {
  prefix: -1,
  orelse: 0,
  or: 1,
  and: 2,
  not: 3,
  compare: 4,
  add: 5,
  mul: 6,
  unary: 7,
  postfix: 8,
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
    // so may the next line after an `if`'s indented `then` block, with
    // `else`: the token after the line break decides
    [$.if_expression],
    // and the next line of a named error set indented under its name
    [$._error_set_body],
  ],

  supertypes: ($) => [$._expression, $._pattern, $._type],

  rules: {
    // program := item { NEWLINE item } EOF
    source_file: ($) =>
      optional(seq(sep1($._item, $._newline), optional($._newline))),

    _item: ($) =>
      choice(
        $.import,
        $.function_definition,
        $.type_definition,
        $.dependency_definition,
      ),

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
        optional(field('errors', $.error_set)),
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

    // uses Console, store.Users: the dependencies a function's body may call
    uses_clause: ($) => seq('uses', commaSep1Strict($.dependency)),

    dependency: ($) =>
      choice(
        $.type_identifier,
        seq(field('module', $.identifier), '.', $.type_identifier),
      ),

    // ! Short(account: AccountId, by: Money) | Frozen | bank.Refusal: what
    // a function can fail with. A bare name may be a tag or a named error
    // set, which only the compiler can tell apart; it's read as a tag
    error_set: ($) => seq('!', sep1($._error, '|')),

    // in a named error set's body, indented under `type X =`, each `|` may
    // start a line
    _error_set_body: ($) =>
      seq('!', sep1($._error, seq(optional($._newline), '|'))),

    _error: ($) => choice($.error_tag, $.error_set_name),

    error_tag: ($) =>
      seq(
        field('name', $.type_identifier),
        optional(seq('(', commaSep1($.payload), ')')),
      ),

    // a payload's field, its name only documentation: `by: Money`, `Money`
    payload: ($) =>
      seq(
        optional(seq(field('name', $.identifier), ':')),
        field('type', $._type),
      ),

    // bank.Refusal: another module's named error set
    error_set_name: ($) =>
      seq(field('module', $.identifier), '.', field('name', $.type_identifier)),

    // ---- types ----

    type_definition: ($) =>
      seq(
        optional($.visibility),
        'type',
        field('name', $.type_identifier),
        optional(field('type_parameters', $.type_parameters)),
        '=',
        choice(
          // type Cart = { ... }, with its members indented below
          seq(
            field('body', $._type_body),
            optional(
              seq($._indent, field('members', $.type_members), $._dedent),
            ),
          ),
          // the body indented under `type X =`, and its members on the
          // lines after it: the first line not starting with `|` ends a
          // sum type's variants
          seq(
            $._indent,
            field('body', $._type_body),
            optional(seq($._newline, field('members', $.type_members))),
            $._dedent,
          ),
        ),
      ),

    _type_body: ($) =>
      choice(
        $.record_type,
        $.opaque_type,
        $.sum_type,
        alias($._error_set_body, $.error_set),
      ),

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

    // ---- dependencies ----

    // pub dep Clock = now: fn() -> Time ..., then its members: its
    // operations, indented under it, come first, which the compiler checks
    dependency_definition: ($) =>
      seq(
        optional($.visibility),
        'dep',
        field('name', $.type_identifier),
        '=',
        $._indent,
        sep1(
          choice(field('operation', $.operation), field('member', $._member)),
          $._newline,
        ),
        $._dedent,
      ),

    // now: fn() -> Time
    operation: ($) =>
      seq(field('name', $.identifier), ':', field('type', $.function_type)),

    // ---- a type's members ----

    // its methods, associated functions and values, and operators, one
    // per line
    type_members: ($) => sep1($._member, $._newline),

    _member: ($) =>
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

    // an error set is a type only as `Result`'s second argument, which the
    // compiler checks; a lone `!` is the empty set, `Result<Int, !>`
    _type: ($) =>
      choice(
        $.named_type,
        $.function_type,
        $.error_set,
        alias('!', $.error_set),
      ),

    // Int, Option<Int>, stripe.Client
    named_type: ($) =>
      seq(
        field('name', $.type_name),
        optional(field('arguments', $.type_arguments)),
      ),

    type_arguments: ($) => seq('<', commaSep($._type), '>'),

    // fn(inout Array<Int>, id: UserId) -> User ! NotFound. The `! ...`
    // belongs to the innermost function type that can take it
    function_type: ($) =>
      prec.right(
        seq(
          'fn',
          '(',
          commaSep($.function_type_parameter),
          ')',
          optional(seq('->', field('return_type', $._type))),
          optional(field('errors', $.error_set)),
        ),
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
        $.orelse_expression,
        $.unary_expression,
        $.reference,
        $.try_expression,
        $.attempt_expression,
        $._postfix,
      ),

    binary_expression: ($) =>
      choice(
        ...[
          [PREC.or, '||'],
          [PREC.and, '&&'],
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

    // x orelse fail Missing: the value in an Option, or else the right
    // side. `a orelse b orelse c` is `a orelse (b orelse c)`
    orelse_expression: ($) =>
      prec.right(
        PREC.orelse,
        seq(
          field('left', $._expression),
          'orelse',
          field('right', $._expression),
        ),
      ),

    // try f(), and try match f(): passes on the errors of every call to its
    // right
    try_expression: ($) =>
      prec.right(PREC.prefix, seq('try', field('operand', $._expression))),

    // attempt f(): its outcome, as a Result
    attempt_expression: ($) =>
      prec.right(
        PREC.prefix,
        seq('attempt', field('operand', $._expression)),
      ),

    // -x, not b
    unary_expression: ($) =>
      choice(
        prec(PREC.unary, seq('-', field('operand', $._expression))),
        prec(PREC.not, seq('not', field('operand', $._expression))),
      ),

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
        $.string,
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
        $.fail_expression,
      ),

    number: (_) => /[0-9][0-9_]*/,

    // "Ren\n": it ends on the line it starts on, and its escapes are
    // `\n`, `\t`, `\"` and `\\`
    string: ($) =>
      seq(
        '"',
        repeat(choice($.escape_sequence, token.immediate(prec(1, /[^"\\\n]+/)))),
        token.immediate('"'),
      ),

    escape_sequence: (_) => token.immediate(seq('\\', /[nt"\\]/)),
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

    // fail Short(self.id, by: m): stop with that error
    fail_expression: ($) =>
      prec.right(
        seq(
          'fail',
          field('tag', $.type_identifier),
          optional(field('arguments', $.constructor_arguments)),
        ),
      ),

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

    // Stack.of, stack.Stack.empty: one of a type's members
    item_expression: ($) =>
      seq(field('type', $.type_name), '.', field('name', $.identifier)),

    array_expression: ($) => seq('[', commaSep($._expression), ']'),

    parenthesized_expression: ($) => seq('(', $._expression, ')'),

    // `if c then x = 1` assigns inside the `then`, as the parser does,
    // rather than to the whole `if`
    if_expression: ($) =>
      prec(
        -1,
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
        field('pattern', choice($._pattern, $.fail_pattern, $.or_pattern)),
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

    // fail Short(_, by), fail _: an error, which only a whole arm matches
    fail_pattern: ($) =>
      seq(
        'fail',
        choice(
          $.wildcard,
          seq(
            field('tag', $.type_identifier),
            optional(seq('(', commaSep($._pattern), ')')),
          ),
        ),
      ),

    // fail NoSuchAccount(_) | fail SameAccount: so far, only of fail patterns
    or_pattern: ($) => seq($.fail_pattern, repeat1(seq('|', $.fail_pattern))),

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
