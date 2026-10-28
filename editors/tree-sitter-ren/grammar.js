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
 * and NEWLINE, ignores line breaks inside brackets except in a lambda's
 * block, and lets an indented line starting with `uses` continue the
 * signature above it.
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
// `||`. `try` takes everything to its right, so it binds loosest of all,
// and so does `assert`. `attempt` stops at a comparison, so `attempt f()
// == x` is `(attempt f()) == x`, but `attempt a() + b()` is
// `attempt (a() + b())`.
const PREC = {
  prefix: -1,
  orelse: 0,
  or: 1,
  and: 2,
  not: 3,
  compare: 4,
  attempt: 5,
  add: 6,
  mul: 7,
  unary: 8,
  postfix: 9,
};

// `a, b, c`, with a trailing comma allowed, and possibly empty
const commaSep = (rule) => optional(commaSep1(rule));
const commaSep1 = (rule) => seq(rule, repeat(seq(',', rule)), optional(','));
// a tuple's parts, `(a, b)` or `(a, b, c)`: two or three, as the compiler
// allows, with a trailing comma
const tupleOf = (rule) =>
  seq('(', rule, ',', rule, optional(seq(',', rule)), optional(','), ')');
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
    // a lambda's `=>` inside brackets that opens its body as a block
    $._arrow_block,
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
    // and after `on:`, `bank.Refusal` may be a named error set among tags,
    // which the `|` after it decides
    [$._primary, $.type_name, $.error_set_name],
    // the next line of an indented sum type may start with `|`
    [$.sum_type],
    // so may the next line after an `if`'s indented `then` block, with
    // `else`: the token after the line break decides
    [$.if_expression],
    // and the next line of a named error set indented under its name
    [$._error_set_body],
    // in a type, `uses Clock, n: Int` ends at the comma, and
    // `uses Clock, store.Users` doesn't: the token after the name decides
    [$.uses_clause],
    // and in a type argument, `uses Clock, ..d` doesn't, which the token
    // after the comma decides
    [$._argument_uses],
    // after `over` in a `with`, `Prices` is the one installed outside it,
    // and `Prices.fixed(1)` a link: the token after the name decides
    [$.dependency, $.constructor_ref],
    [$.dependency, $.type_name, $._primary],
    // in `<T has eq, ord, U>`, the token after a comma decides whether it
    // goes on with a requirement or starts the next type parameter
    [$.constrained_type_parameter],
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
        $.handler_definition,
        $.test_definition,
        $.group_definition,
        $.group_run,
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

    // `test fn` is a test item, which only tests see; the compiler
    // refuses one among a type's members, with a better message than a
    // parse error would give
    function_definition: ($) =>
      seq(
        optional($.visibility),
        optional(field('test', 'test')),
        'fn',
        field('name', $.identifier),
        optional(field('type_parameters', $.type_parameters)),
        field('parameters', $.parameters),
        optional(seq('->', field('return_type', $._return_type))),
        optional(field('errors', $.error_set)),
        optional(field('uses', $.uses_clause)),
        '=',
        field('body', $._body),
      ),

    visibility: (_) => 'pub',

    // <T, U>, and what each needs, <T has eq, ord, U>: a comma goes on
    // with another requirement, unless a type parameter's name follows it
    type_parameters: ($) =>
      seq(
        '<',
        commaSep(choice($.type_identifier, $.constrained_type_parameter)),
        '>',
      ),

    constrained_type_parameter: ($) =>
      seq(
        field('name', $.type_identifier),
        'has',
        sep1(field('requirement', $.identifier), ','),
      ),

    parameters: ($) => seq('(', commaSep($.parameter), ')'),

    parameter: ($) =>
      seq(
        optional($.inout),
        field('name', choice($.identifier, $.self)),
        optional(seq(':', field('type', $._type))),
      ),

    inout: (_) => 'inout',

    // uses Console, store.Users: the dependencies a function's body may
    // call, or a function type or an implementation uses, and last, a
    // named row, `uses Clock, ..d`. In a type, a `,` goes on with the list
    // only to a dependency or a row, which the token after it decides
    uses_clause: ($) =>
      seq(
        'uses',
        choice(
          seq(
            commaSep1Strict($.dependency),
            optional(seq(',', field('row', $.named_row))),
          ),
          field('row', $.named_row),
        ),
      ),

    // ..d: whatever the closure or implementation it's written on uses, or
    // fails with, the same wherever the signature names it
    named_row: ($) => seq('..', field('name', $.identifier)),

    // Clock, store.Users, and a generic one at its types, Chan<Job>
    // (deps.md, "Generic dependencies")
    dependency: ($) =>
      seq(
        choice(
          $.type_identifier,
          seq(field('module', $.identifier), '.', $.type_identifier),
        ),
        optional(field('arguments', $.type_arguments)),
      ),

    // ! Short(account: AccountId, by: Money) | Frozen | bank.Refusal: what
    // a function can fail with. A bare name may be a tag or a named error
    // set, which only the compiler can tell apart; it's read as a tag
    error_set: ($) =>
      seq(
        '!',
        choice(
          seq(
            sep1($._error, '|'),
            optional(seq('|', field('row', $.named_row))),
          ),
          field('row', $.named_row),
        ),
      ),

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

    // opaque Int, and opaque Int with numeric, which gives an opaque number
    // its arithmetic; the compiler checks it's an `Int` or a `Float`. Or
    // opaque { id: Int, ... }, a record only its own module sees as one
    opaque_type: ($) =>
      seq(
        'opaque',
        choice(
          field('fields', $.record_type),
          seq(
            field('representation', $._type),
            optional(seq('with', field('numeric', $.numeric))),
          ),
        ),
      ),

    numeric: (_) => 'numeric',

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
    // operations, indented under it, come first, which the compiler checks.
    // A generic one, dep Chan<T> = ...; or an alias of one at its types,
    // dep Jobs = Chan<Job>, a dependency of its own with its operations
    dependency_definition: ($) =>
      seq(
        optional($.visibility),
        'dep',
        field('name', $.type_identifier),
        optional(field('type_parameters', $.type_parameters)),
        '=',
        choice(
          seq(
            $._indent,
            sep1(
              choice(
                field('operation', $.operation),
                field('member', $._member),
              ),
              $._newline,
            ),
            $._dedent,
          ),
          field('names', $.dependency),
        ),
      ),

    // now: fn() -> Time
    operation: ($) =>
      seq(field('name', $.identifier), ':', field('type', $.function_type)),

    // ---- handlers ----

    // handler counting_rates(rate: Int) for Rates, RateCalls = ...: its
    // state, `var`s, `let`s and `finally`s, indented under it, then an arm
    // for each operation; the compiler checks the order. `over Users` goes
    // over another implementation, `over A & B` of several, `over any`
    // over whichever one it's installed over, with one arm, `call => ...`,
    // for every operation; and `! DbDown` is what its state and
    // `finally`s can fail with
    handler_definition: ($) =>
      seq(
        optional($.visibility),
        optional(field('test', 'test')),
        'handler',
        field('name', $.identifier),
        optional(field('type_parameters', $.type_parameters)),
        field('parameters', $.parameters),
        choice(
          seq('for', sep1(field('implements', $.dependency), ',')),
          seq('over', sep1(field('implements', $.dependency), '&')),
          seq('over', field('any', alias('any', $.any))),
        ),
        optional(field('errors', $.error_set)),
        optional(field('uses', $.uses_clause)),
        '=',
        $._indent,
        sep1(
          choice(
            field('state', $.let_statement),
            field('finally', $.finally_statement),
            field('arm', $.handler_arm),
            field('arm', $.any_arm),
          ),
          $._newline,
        ),
        $._dedent,
      ),

    // call => ...: the one arm of a handler `over any`, which runs for
    // every operation and names the call it runs for; the compiler checks
    // it's in one
    any_arm: ($) =>
      seq(field('call', $.identifier), '=>', field('body', $._body)),

    // usd_to(c) => ...: the implementation of an operation; with its
    // dependency in front, Console.write(line) => ..., when two the
    // handler implements both have one of that name
    handler_arm: ($) =>
      seq(
        optional(seq(field('dependency', $.type_identifier), '.')),
        field('name', $.identifier),
        field('parameters', $.parameters),
        '=>',
        field('body', $._body),
      ),

    // finally(r) => ...: it covers what comes after it, the state below
    // it and the `with`'s body, or the rest of an operation's arm, and is
    // given what that ends in; the compiler checks it's in a handler
    finally_statement: ($) =>
      seq(
        'finally',
        field('parameters', $.parameters),
        '=>',
        field('body', $._body),
      ),

    // ---- tests ----

    // test "a deposit is stamped" uses Clock = ...: its `uses` asks for
    // the real implementation of a built-in dependency
    test_definition: ($) =>
      seq(
        'test',
        field('name', $.string),
        optional(field('uses', $.uses_clause)),
        '=',
        field('body', $._body),
      ),

    // pub group clock_conforms(c: Clock) with c = ...: its tests, indented
    // under it, each run inside its `with`
    group_definition: ($) =>
      seq(
        optional($.visibility),
        'group',
        field('name', $.identifier),
        field('parameters', $.parameters),
        optional(seq('with', commaSep1Strict(field('item', $._with_item)))),
        '=',
        $._indent,
        sep1(field('test', $.test_definition), $._newline),
        $._dedent,
      ),

    // group "frozen" = clock_conforms(Clock.frozen(Time.epoch)): a run of
    // a group's tests, with these arguments; the compiler checks it's a call
    group_run: ($) =>
      seq(
        'group',
        field('label', $.string),
        '=',
        field('call', $._expression),
      ),

    // ---- a type's members ----

    // its methods, associated functions and values, one per line: an
    // operator is a method with a reserved name, `add` for `+`
    type_members: ($) => sep1($._member, $._newline),

    _member: ($) => choice($.function_definition, $.associated_value),

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

    // ---- written types ----

    // an error set is a type only as `Result`'s second argument, which the
    // compiler checks; a lone `!` is the empty set, `Result<Int, !>`
    _type: ($) => choice($._return_type, $.implementation_type),

    // after `->`, a `uses` is the function's, never what an implementation
    // it returns needs, which is written in parentheses
    _return_type: ($) =>
      choice(
        $.named_type,
        $.function_type,
        $.parenthesized_type,
        $.tuple_type,
        $.error_set,
        alias('!', $.error_set),
        alias($._joined, $.implementation_type),
        alias($._over, $.implementation_type),
      ),

    // Clock uses Os: an implementation of a dependency, and what it needs;
    // or of several, Clock & TestClock uses Os; one that can fail to be
    // installed, Sql ! DbDown; and one that goes over another, over Users
    implementation_type: ($) =>
      choice(
        seq($._implemented, $._implementation_rest),
        seq($._joined, $._implementation_rest),
        seq($._over, $._implementation_rest),
      ),

    _implementation_rest: ($) =>
      choice(
        seq(
          field('errors', $.error_set),
          optional(field('uses', $.uses_clause)),
        ),
        field('uses', $.uses_clause),
      ),

    // over Users, over A & B: an implementation that goes over another
    _over: ($) => seq('over', sep1($._implemented, '&')),

    // a dependency an implementation implements, at its types if it's
    // generic, Chan<Int>
    _implemented: ($) =>
      seq(
        field('name', $.type_name),
        optional(field('arguments', $.type_arguments)),
      ),

    // Clock & TestClock: an implementation of each, sharing one state. As
    // a function's result its `uses` is the function's, as above
    _joined: ($) => seq($._implemented, repeat1(seq('&', $._implemented))),

    parenthesized_type: ($) => seq('(', $._type, ')'),

    // (Str, Int): a tuple's type, of two parts or three
    tuple_type: ($) => tupleOf($._type),

    // Int, Option<Int>, stripe.Client
    named_type: ($) =>
      seq(
        field('name', $.type_name),
        optional(field('arguments', $.type_arguments)),
      ),

    // in a type argument, a `uses` list ends at a comma unless a named row
    // follows it: `Pair<fn() uses Clock, Int>` has two arguments, and
    // several dependencies are written in parentheses
    type_arguments: ($) => seq('<', commaSep($._type_argument), '>'),

    _type_argument: ($) =>
      choice(
        $.named_type,
        $.parenthesized_type,
        $.tuple_type,
        $.error_set,
        alias('!', $.error_set),
        alias($._argument_function_type, $.function_type),
        alias($._argument_implementation_type, $.implementation_type),
        alias($._joined, $.implementation_type),
        alias($._over, $.implementation_type),
      ),

    _argument_return_type: ($) =>
      choice(
        $.named_type,
        alias($._argument_function_type, $.function_type),
        $.parenthesized_type,
        $.tuple_type,
        $.error_set,
        alias('!', $.error_set),
        alias($._joined, $.implementation_type),
        alias($._over, $.implementation_type),
      ),

    _argument_implementation_type: ($) =>
      choice(
        seq($._implemented, $._argument_implementation_rest),
        seq($._joined, $._argument_implementation_rest),
        seq($._over, $._argument_implementation_rest),
      ),

    _argument_implementation_rest: ($) =>
      choice(
        seq(
          field('errors', $.error_set),
          optional(field('uses', alias($._argument_uses, $.uses_clause))),
        ),
        field('uses', alias($._argument_uses, $.uses_clause)),
      ),

    _argument_function_type: ($) =>
      prec.right(
        seq(
          'fn',
          '(',
          commaSep($.function_type_parameter),
          ')',
          optional(seq('->', field('return_type', $._argument_return_type))),
          optional(field('errors', $.error_set)),
          optional(field('uses', alias($._argument_uses, $.uses_clause))),
        ),
      ),

    _argument_uses: ($) =>
      seq(
        'uses',
        choice(
          seq($.dependency, optional(seq(',', field('row', $.named_row)))),
          field('row', $.named_row),
        ),
      ),

    // fn(&Array<Int>, id: UserId) -> User ! NotFound uses Clock. The
    // `! ...` and `uses ...` belong to the innermost function type that can
    // take them
    function_type: ($) =>
      prec.right(
        seq(
          'fn',
          '(',
          commaSep($.function_type_parameter),
          ')',
          optional(seq('->', field('return_type', $._return_type))),
          optional(field('errors', $.error_set)),
          optional(field('uses', $.uses_clause)),
        ),
      ),

    // a parameter the function changes is written as a call passes it,
    // `&Int`
    function_type_parameter: ($) =>
      seq(
        optional(alias('&', $.inout)),
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

    _statement: ($) =>
      choice(
        $.let_statement,
        $.for_statement,
        $.while_statement,
        $.finally_statement,
        $._line,
      ),

    // and `let (k, v) = pair`, a tuple taken apart, whose pattern the
    // compiler checks always matches: names, `_` and tuples
    let_statement: ($) =>
      choice(
        seq(
          choice('let', 'var'),
          field('name', $.identifier),
          optional(seq(':', field('type', $._type))),
          '=',
          field('value', $._body),
        ),
        seq(
          'let',
          field('pattern', $.tuple_pattern),
          '=',
          field('value', $._body),
        ),
      ),

    // for x in xs, for (k, v) in m, for i in 0..n, and for i, x in &xs
    // with each element's index first
    for_statement: ($) =>
      seq(
        'for',
        optional(
          seq(field('index', choice($.identifier, $.wildcard)), ','),
        ),
        field('variable', choice($.identifier, $.wildcard, $.tuple_pattern)),
        'in',
        field('iterable', choice($._expression, $.range)),
        field('body', $.block),
      ),

    // while n < 10, its body indented below
    while_statement: ($) =>
      seq(
        'while',
        field('condition', $._expression),
        field('body', $.block),
      ),

    // 0..n: the `Int`s from the first up to, but not including, the
    // second; only a `for` goes over one, and an index slices with one
    range: ($) =>
      prec.left(
        PREC.prefix - 1,
        seq(field('start', $._expression), '..', field('end', $._expression)),
      ),

    // a lambda's body takes an assignment after it, as the parser does
    _line: ($) => prec.right(choice($._expression, $.assignment)),

    // x = 1, xs[i] += 1, h *%= 16777619
    assignment: ($) =>
      seq(
        field('target', $._expression),
        field(
          'operator',
          choice('=', '+=', '-=', '*=', '+%=', '-%=', '*%='),
        ),
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
        $.assert_expression,
        $._postfix,
      ),

    binary_expression: ($) =>
      choice(
        ...[
          [PREC.or, '||'],
          [PREC.and, '&&'],
          [PREC.compare, choice('==', '!=', '<', '<=', '>', '>=')],
          // `+%`, `-%` and `*%` wrap, at the precedence of what they wrap
          [PREC.add, choice('+', '-', '+%', '-%')],
          [PREC.mul, choice('*', '/', '%', '*%')],
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

    // attempt f(): its outcome, as a Result, up to a comparison
    attempt_expression: ($) =>
      prec.right(
        PREC.attempt,
        seq('attempt', field('operand', $._expression)),
      ),

    // assert a == b: a panic if it's false
    assert_expression: ($) =>
      prec.right(
        PREC.prefix,
        seq('assert', field('operand', $._expression)),
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

    // xs[i], and a slice, xs[a..b]
    index_expression: ($) =>
      prec(
        PREC.postfix,
        seq(
          field('value', $._postfix),
          '[',
          field('index', choice($._expression, $.range)),
          ']',
        ),
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
          // `call.fail(e)`, in a handler `over any`
          field('name', choice($.identifier, alias('fail', $.identifier))),
          field('arguments', $.arguments),
          optional(field('trailing', $.lambda)),
        ),
      ),

    arguments: ($) =>
      seq('(', commaSep(choice($._expression, $.named_argument)), ')'),

    // on: DbDown | Timeout, on: on: what a parameter of `Tags` is given,
    // the only one passed by its name; the compiler checks it's one
    named_argument: ($) =>
      seq(
        field('name', $.identifier),
        ':',
        field('value', choice($.tag_set, $._expression)),
      ),

    // DbDown | Timeout, bank.Refusal: tags, without payloads, or named
    // error sets; one alone reads as an expression
    tag_set: ($) =>
      seq(
        $._tag,
        repeat1(seq('|', $._tag)),
      ),

    _tag: ($) => choice(alias($.type_identifier, $.error_tag), $.error_set_name),

    _primary: ($) =>
      choice(
        $.number,
        $.float,
        $.string,
        $.boolean,
        $.unit,
        $.identifier,
        $.self,
        $.lambda,
        $.inline_handler,
        $.constructor_expression,
        $.record_expression,
        $.item_expression,
        $.array_expression,
        $.tuple_expression,
        $.parenthesized_expression,
        $.if_expression,
        $.match_expression,
        $.fail_expression,
        $.with_expression,
        $.break,
      ),

    // leaves the innermost `while` or `for`
    break: (_) => 'break',

    // 1_000_000, hex 0x82F6_3B78 or binary 0b1010: the prefix in lower
    // case, underscores anywhere after the first digit. Always an `Int`
    number: (_) =>
      token(choice(/0x[0-9a-fA-F][0-9a-fA-F_]*/, /0b[01][01_]*/, /[0-9][0-9_]*/)),

    // 1.5: a digit after the `.`, so `1..3` and `1.show()` are an `Int`
    // and what follows it. Never a pattern
    float: (_) => /[0-9][0-9_]*\.[0-9][0-9_]*/,

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

    // inside brackets, a body indented under the `=>` that ends its line
    // is a block too, which the scanner opens with the `=>`
    lambda: ($) =>
      prec.right(
        seq(
          'fn',
          field('parameters', alias($.lambda_parameters, $.parameters)),
          choice(
            seq('=>', field('body', $._body)),
            seq(
              alias($._arrow_block, '=>'),
              field('body', alias($._bracket_block, $.block)),
            ),
          ),
        ),
      ),

    // handler fn(req) => respond(req, body): a handler of a dependency
    // with one operation, written where a description of it is wanted,
    // its parameters the operation's; what it reads from here is copied
    inline_handler: ($) => seq('handler', field('lambda', $.lambda)),

    // a lambda's parameter can take a tuple apart, fn((k, v)) => ..., and
    // one it changes is written as a call passes it, fn(&lo, &hi) => ...
    lambda_parameters: ($) =>
      seq(
        '(',
        commaSep(
          choice(alias($._lambda_parameter, $.parameter), $.tuple_parameter),
        ),
        ')',
      ),

    _lambda_parameter: ($) =>
      seq(
        optional(alias('&', $.inout)),
        field('name', choice($.identifier, $.self)),
        optional(seq(':', field('type', $._type))),
      ),

    tuple_parameter: ($) =>
      seq(
        field('pattern', $.tuple_pattern),
        optional(seq(':', field('type', $._type))),
      ),

    _bracket_block: ($) => seq(sep1($._statement, $._newline), $._dedent),

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

    // (k, v): two or three values passed together, taken apart only by
    // patterns
    tuple_expression: ($) => tupleOf($._expression),

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

    // with Clock.frozen(t), retry(3) in body: each item installed, or
    // wrapped, around the body; the compiler finds the order
    with_expression: ($) =>
      prec.right(
        seq(
          'with',
          commaSep1Strict(field('item', $._with_item)),
          'in',
          field('body', $._body),
        ),
      ),

    _with_item: ($) => choice($._expression, $.with_chain, $.with_as),

    // queue() as Jobs: installed as an alias of what it implements, or at
    // the types it names
    with_as: ($) =>
      seq(
        choice(field('link', $._expression), $.with_chain),
        'as',
        field('as', $.dependency),
      ),

    // cached(ttl) over limited() over catalogue(), or over Prices, the one
    // installed outside the `with`: each link goes over the one after it
    with_chain: ($) =>
      seq(
        field('link', $._expression),
        choice(
          seq(
            repeat1(seq('over', field('link', $._expression))),
            optional(seq('over', $._with_under)),
          ),
          seq('over', $._with_under),
        ),
      ),

    _with_under: ($) =>
      prec.dynamic(1, sep1(field('under', $.dependency), '&')),

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
        $.tuple_pattern,
      ),

    wildcard: (_) => '_',

    // fail Short(_, by), fail _: an error, which only a whole arm matches;
    // fail on, an error whose tag a parameter of `Tags` was given
    fail_pattern: ($) =>
      seq(
        'fail',
        choice(
          $.wildcard,
          field('tags', $.identifier),
          seq(
            field('tag', $.type_identifier),
            optional(seq('(', commaSep($._pattern), ')')),
          ),
        ),
      ),

    // fail NoSuchAccount(_) | fail SameAccount: so far, only of fail patterns
    or_pattern: ($) => seq($.fail_pattern, repeat1(seq('|', $.fail_pattern))),

    negative_number: ($) => seq('-', $.number),

    // (k, v), (_, Some(x))
    tuple_pattern: ($) => tupleOf($._pattern),

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
