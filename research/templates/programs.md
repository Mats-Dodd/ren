# Six programs in each candidate

The candidates are in designs.md. Each program is written in full in C
(passed down, no prefix). A and B are then shown where they differ.
The library side is sketched once, for C, where it says something new.

Shared setup:

```ren
// app/db.ren
let DB: sql.Schema = try sql.parse_schema(try Fs.read("db/schema.sql"))   // build time

type Job = { id: JobId, owner: OwnerId, state: JobState, created: Time }
type JobId = opaque Int
  pub fn parse(n: Int) -> JobId = JobId(n)
  pub fn repr(self) -> Int = self.0
```

---

## 1. SQL: parameters, and a dynamic table name refused

### C

```ren
fn jobs_for(o: OwnerId, since: Time) -> Array<Job> uses Sql ! DbDown =
  DB.rows<Job>(t"select id, owner, state, created from jobs where owner = \{o} and created > \{since}")

fn archived(kind: Archive, o: OwnerId) -> Array<Job> uses Sql ! DbDown =
  DB.rows<Job>(t"select * from \{kind} where owner = \{o}")     // refused, below
```

```
error: this query failed its check while building
  --> jobs.ren:5:33
   |
 5 |   DB.rows<Job>(t"select * from \{kind} where owner = \{o}")
   |                                ^^^^^^^ an `Archive` where a table name goes
   = help: a table name must be `sql.Table`: `\{sql.table(kind)}`
   = note: checked by `sql.plan`, from `Schema.rows` (sql/query.ren:40)
```

The fix names the identifier explicitly. `sql.table` takes a
payload-free sum, so its plan can check every case against the schema
while building:

```ren
type Archive = | Jobs2024 | Jobs2025       // each case names a table: jobs_2024, jobs_2025

DB.rows<Job>(t"select * from \{sql.table(kind)} where owner = \{o}")
```

```
error: this query failed its check while building
   |                                ^^^^^^^^^^^^^^^^ `Archive.Jobs2025` names `jobs_2025`, which isn't in db/schema.sql
```

A `Str` table name is refused at every position, with no escape hatch
in a template. A program that truly builds SQL from strings calls
`Sql.rows_unchecked(text, params)`, by name.

Dynamic `where` clauses are fragments, converted to data explicitly:

```ren
fn search(f: Filter) -> Array<Job> uses Sql ! DbDown =
  var w = sql.frag(DB, t"true")
  if f.owner is Some(o) then w = w.and(sql.frag(DB, t"owner = \{o}"))
  if f.state is Some(s) then w = w.and(sql.frag(DB, t"state = \{s}"))
  DB.rows<Job>(t"select * from jobs where \{w} order by created desc")
```

The outer plan sees a hole of type `sql.Frag` in expression position
and splices it. Each fragment was checked where it was written, against
the columns of every table (it doesn't know which yet). The outer check
can't see the fragments' text, so a fragment naming a column of another
table fails at run time with `SqlError`, not at build. That's the price
of dynamic SQL, and it's stated.

**Library side (sketch):**

```ren
// sql/query.ren
pub fn rows<T, H>(self: Schema, q: Template<H>) -> Array<T> uses Sql ! DbDown
  let plan = try plan(self, q.site(), T.shape)
=
  let params = plan.bind(q)                  // one array per call, crosses the dep
  Sql.rows(Query { text: plan.text, params, site: q.site().id })
    |> try decode_all<T>(plan.columns)

pub fn plan(s: Schema, site: Site, row: Shape) -> Plan ! BadSql(at: Int, why: Str) =
  // parse parts with `?` where each hole is; for each hole, its position
  // (value, identifier, fragment) and its shape:
  //   value position: a scalar, an Option of one, or an opaque type whose repr is one
  //   identifier position: only sql.Table / sql.Column
  //   expression position: only sql.Frag
  // then check selected columns against `row`, by name.
  ...
```

### A

Identical call sites. Fragments could stay templates:

```ren
let w = if admin then t"true" else t"owner = \{me}"     // type error: (,) against (OwnerId,)
```

The branches' hole tuples differ, so they need `sql.frag` anyway. A
helper `fn by_owner(o) -> Template<(OwnerId,)>` can return one, but
then `rows`'s plan can't see it (it isn't the literal), so it must go
in as a `sql.Frag` hole too. A gains nothing in this program, and the
template may allocate: `(Site, OwnerId, Time)` fits in a tag and three
words only if `Time` is one word, and a third hole wouldn't fit.

### B

```ren
fn jobs_for(o: OwnerId, since: Time) -> Array<Job> uses Sql ! DbDown =
  Sql.rows(DB"select id, owner, state, created from jobs where owner = \{o} and created > \{since}")
    |> try sql.decode_all<Job>
```

- The prefix returns a `Query`, so the row type is checked at decode,
  at run time, unless `decode_all<Job>` gets its own signature `let`
  over the query's plan. That's a second check for one call.
- The table refusal reads the same.

---

## 2. HTML: escaping by hole type, and a raw hole

### C

```ren
fn job_row(out: &Str, j: Job, badge: html.Html) =
  html.write(out, t"<tr class=\"\{j.state}\"><td><a href=\"\{url.job(j.id)}\">\{j.id}</a></td><td>\{badge}</td></tr>")

fn jobs_page(jobs: Array<Job>, user: User) -> html.Html =
  var body = ""
  for j in jobs
    job_row(&body, j, html.of(t"<span>\{j.state}</span>"))
  html.of(t"<h1>Jobs for \{user.name}</h1><table>\{html.raw_trusted(body)}</table>")
```

`html.plan` parses the literal while building. Each hole gets a context
from where it sits, and the hole's type must suit that context:

| Context | Allowed | Written as |
|---|---|---|
| text | any type with `show`; `html.Html` | escaped `& < >`; `Html` as is |
| quoted attribute value | any type with `show` | escaped `& " '` |
| URL attribute (`href`, `src`) | `url.Url` only | its `repr`, attribute-escaped |
| attribute name, tag name | refused | |
| `<script>`, `<style>`, comment | refused | |
| unquoted attribute | refused | |

```
error: this HTML failed its check while building
  --> page.ren:2:61
   |
 2 |   html.write(out, t"<a href=\"\{j.link}\">...")
   |                               ^^^^^^^^^ a `Str` in `href`
   = help: an `href` takes `url.Url`, so `javascript:` can't get in: `url.parse(j.link)`
```

**The raw hole** is a value of type `html.Html`. There are three ways
to get one: `html.of(t)` (checked and escaped), the `Html` an earlier
`write` produced, and `html.raw_trusted(s)`, the named escape hatch. A
plain `Str` is always escaped, so forgetting is safe.

In the page above, `body` was built by `write` and is safe, but it's a
`Str`, so it goes back in through `raw_trusted`. A cleaner API types the
buffer: `var body = html.buffer()`, an `Html` that `write` appends to,
so no `raw_trusted` is needed. That's an API detail, not a template
rule.

**Allocation:** `job_row` allocates nothing; it appends chunks and
escaped holes into `out`. Each `html.of` allocates the `Html` it
returns, which is its point.

**A list without a loop:** `xs.map(fn(x) => t"<li>\{x}</li>")` is the
"a template can't be stored" error, whose help suggests
`html.of(t"...")` per item or a loop with `write`.

### A

`xs.map(fn(x) => t"<li>\{x}</li>")` is allowed, giving
`Array<Template<(Str,)>>`, and `html.of(t"<ul>\{items}</ul>")` can walk
nested templates. But the inner literal's plan never ran, because it
didn't reach `html.of` as a literal at a call. So either nested
templates are planned at run time (a parse per render, the cost
lit-html caches away), or they're refused. A buys nesting and loses the
build-time check on exactly the nested ones.

### B

```ren
let H = html.ctx()                       // a value only to hang the prefix on
html.write(out, H"<tr class=\"\{j.state}\">...")
```

HTML has no schema, so the prefix is a value made up to carry the
prefix. JS's `` html`...` `` works because the tag is a function; here
it adds a name with nothing in it. B's editor gain is real, though:
tree-sitter injects HTML into `H"..."` with no language server.

---

## 3. A log line with structured fields

### C

```ren
fn compact(level: Int, files: Array<Path>) uses Fs, Log, Clock ! IoError =
  let started = Clock.instant()
  ...
  log.info(t"compacted level \{level}: \{files.len()} files, \{bytes} bytes in \{took}")
```

```
error: this log line failed its check while building
   |                                    ^^^^^^^^^^^^^ a field needs a name; this hole isn't a name or a path
   = help: `let n_files = files.len()`, then `\{n_files}`
```

After the fix:

```ren
  let n_files = files.len()
  let took = Clock.instant() - started
  log.info(t"compacted level \{level}: \{n_files} files, \{bytes} bytes in \{took}")
```

- **Fields are the holes, named by their source text:** `level`,
  `n_files`, `bytes`, `took`. `log.json()` writes
  `{"msg":"compacted level {level}: {n_files} files, ...","level":3,"n_files":12,...}`;
  `log.text()` writes the rendered line plus nothing else.
- **The message template is static per site.** That's G1's static call
  site metadata, with no compiler-built `Event`: `log.plan` makes it
  from the site while building.
- **A secret hole** (`Secret<T>`) shows as `<redacted>`, decided by its
  shape. A metric label hole must have a finite shape, as G1 says,
  checked by `metrics.plan`.
- **Allocation:** `log.info` encodes the hole tuple in binary into the
  task's log buffer, NanoLog-style, then calls `Log.event(site_id,
  bytes)`. The handler formats later, or never (`log.off()`).
- **Expensive fields:**

  ```ren
  if log.on(Debug) then log.debug(t"memtable \{dump}")   // let dump = memtable.dump() inside the if
  ```

  Holes are eager, so the `if` is what skips the work.

Today's form, `log.info("compacted", level: n, bytes: b)`, gives
structure without prose. The template gives both from one literal.
Keep one form; I'd keep the template.

### A

Same call. The tuple `(Site, Int, Int, Int, Duration)` is boxed: one
allocation per log line, even when the level is off, because the
template is built before `log.info` checks the level. The lazy form
works:

```ren
log.debug fn() => t"memtable \{memtable.dump()}"
```

### B

```ren
log"compacted level \{level}: \{n_files} files"
```

There's no level in the prefix, so it's `log.info"..."`. Is that a
member access followed by a prefix, or a prefix named `log.info`? It
needs a rule, and it's the JS confusion in a new place. B is worst
here.

---

## 4. A shell command with safe argv splitting

### C

```ren
fn history(dir: Path, since: Time, paths: Array<Path>) -> Str uses Proc ! ProcFailed =
  let out = try proc.run(t"git -C \{dir} log --since=\{since} --format=%H -- \{paths}")
  out.stdout_str()
```

`proc.plan` splits the **literal** text on ASCII spaces while building.
Holes never split:

| In the literal | argv |
|---|---|
| `git`, `log`, `--format=%H`, `--` | one argument each |
| `\{dir}` alone, a `Path` | exactly one argument, its bytes, even if it has spaces or is empty |
| `--since=\{since}` | one argument: the literal, then the hole's `show` |
| `\{paths}` alone, an `Array<Path>` | one argument per element, none if empty |
| an `Option<T>` hole alone | zero or one argument |

The plan refuses, while building:
- `| ; & < > $ ` and backquotes, and `*` or `?`, in the literal: there's
  no shell. Pipes are `proc.pipe`.
- Quotes in the literal: argv is already split, so quoting has no
  meaning.
- An `Array` hole glued to text (`-I\{dirs}`), which is ambiguous.
- A record or sum hole: no obvious argv for it.

```
error: this command failed its check while building
   |   proc.run(t"grep \{pat} \{file} | wc -l")
   |                                  ^ there's no shell, so `|` would be an argument
   = help: run two commands with `proc.pipe(t"grep \{pat} \{file}", t"wc -l")`
```

The plan doesn't prevent a value starting with `-` from being read as
an option. That's the program's job: write `--` in the literal, as
above. Julia's backtick commands and Bun's `$` make the same choice.

**Allocation:** the argv array, which `exec` needs anyway.

### A and B

A: the same. B: `Proc"git -C \{dir} ..."` returns a `Cmd`, and running it
is `try Proc.run(Proc"...")`, which repeats the name. Neither gains
anything.

---

## 5. Building a JSON snippet

The usual answer is a record and `json.encode`. A template is for a
fixed shape written once, such as an error body or a request to someone
else's API:

### C

```ren
fn slack_alert(ch: Str, job: JobId, err: Str) -> Bytes =
  json.of(t"{\"channel\": \{ch}, \"text\": \"job failed\", \"fields\": {\"job\": \{job}, \"error\": \{err}}}")
```

`json.plan` parses the literal as JSON while building, with each hole
standing for one value:

- A hole must sit where a value goes. A hole as a key, or inside a
  string literal (`"job \{job}"`), is refused: the help offers
  `\{"job " + show(job)}` as one value.
- Each hole is encoded by `json.encode`'s shape walk, so a `Str` is
  quoted and escaped, `JobId` goes through its `repr`, and an `Option`
  is `null` or the value.
- Malformed JSON in the literal (a trailing comma, a missing quote) is
  a build error at its byte.
- **Allocation:** the output `Bytes`, sized from `literal_len` plus a
  guess per hole.

The escaped quotes are the real cost here. `t"""{"channel": \{ch}}"""`
would read far better. That's open question 4 in designs.md, a raw
literal, which this program argues for.

### A and B

A: the same. B: `J"{...}"` with `let J = json.ctx()`, the same made-up
value as HTML.

---

## 6. An i18n message

The source language's text is the key, as gettext does. Holes are named
by their source text, so translators can reorder them.

### C

```ren
// build time: every catalog in the package
let MSG: i18n.Catalogs = try i18n.load(try Fs.list("i18n"))

fn inbox_line(lang: Lang, user: User, count: Int) -> Str =
  MSG.say(lang, t"\{user.name} has \{count} new messages")
```

```
# i18n/fr.ftl
"{user.name} has {count} new messages" =
  { $count ->
      [one] {user.name} a un nouveau message
     *[other] {user.name} a {count} nouveaux messages
  }
```

`i18n.plan(MSG, site)`, while building:
- finds the message in every catalog, and fails the build for a
  catalog missing it (or warns, as the package chooses in `ren.toml`)
- checks every catalog's placeholders against the hole names: a
  translation using `{name}` when the hole is `user.name` fails
- checks that a plural selector hole is an `Int`
- returns, per language, the translated parts and the hole order, so
  `say` at run time is an array index and appends

**Allocation:** the result `Str`. `MSG.write(&out, lang, t"...")`
allocates nothing beyond `out`.

This is the program where build-time checks pay most: a missing or
broken translation is normally found by a user in that language.

### A

The same, but a stored message template (`let m = t"..."` kept in a
table) would lose its check. Message tables are what i18n tends to grow,
so A invites the unchecked path.

### B

```ren
MSG"\{user.name} has \{count} new messages"
```

The language is missing. It would have to be ambient, which Ren doesn't
do, or a prefix with an argument, which doesn't exist. So
`MSG.say(lang, t"...")`, as in C.

---

## What the programs showed

1. **Every consumer wanted a plan built while building,** not only a
   pass/fail check: SQL text with `?`s, HTML chunks with contexts, argv
   slots, JSON chunks, per-language parts. So the signature `let` should
   return a value, which is the main new idea here.
2. **No program needed to keep a template.** Every one that wanted to
   keep something wanted the consumer's own data (`sql.Frag`,
   `html.Html`, a rendered `Str`). That supports C.
3. **A's keeping is worse than useless in two places** (nested HTML, i18n
   tables): a kept template has lost its build-time check.
4. **B helped only the editor.** In sql it lost the verb and the row
   type, in log and i18n it had nowhere to put an argument, and in html
   and json it needed a made-up value to hang on.
5. **Holes named by source text** worked for logs and i18n, with one
   check: a log field or a message placeholder must be a name or a path.
6. **Escaped quotes** in json and html argue for a raw literal.
7. **Laziness came up once** (the debug log), and the guard was enough.
