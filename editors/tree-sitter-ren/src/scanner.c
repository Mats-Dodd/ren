// Ren's layout, for tree-sitter: the same rules as the compiler's lexer
// (lib/syntax/lexer.ml), which emits three layout tokens, as Python does:
//
//   INDENT   a line is indented further than the one before (a block opens)
//   DEDENT   a line is indented less (one DEDENT per block that closes)
//   NEWLINE  a new line at the same indentation (separates statements)
//
// Inside parentheses, brackets or braces, line breaks and indentation are
// ignored, so the scanner lexes the brackets itself to know where it is,
// except in a lambda's body: a lambda's `=>` that ends a line inside
// brackets, followed by a line indented further than the block around
// them, opens a block, which ends at a line indented less, at a `,` that
// goes on to the next argument or field, or at the closing bracket. The
// scanner lexes that `=>` too, as ARROW_BLOCK, which opens the block
// itself, since it's the only one to see the line break after it. Blank and comment-only lines are skipped. An indented line
// that starts with `uses`, or with an error set's `!` (not `!=`),
// continues the signature above it, so it gets no layout token at all,
// unless a block can open there (after `type E =`, a named error set one
// `|` per line). Neither does one after a line ending in `,`, where no
// layout token is valid. Nor does an indented line that starts with
// `|>`, a chain's next step, or with `.` and a name, the next stage over
// a cursor.
//
// Each layout token is empty and sits at the end of the line before it.
// So each call starts there again, before the line break: after a DEDENT
// it finds the same next line, and closes another block, or separates it
// with a NEWLINE. The grammar asks for at most one NEWLINE in a row, so
// nothing repeats.
//
// Strings whose ends need counting are the scanner's too (strings.md,
// "Literals"): a raw string, `#"..."#`, which ends at a quote with as
// many `#`s after it and whose escapes are `\` and as many `#`s, `\#n`
// and the hole `\#{x}`; a multi-line one, `"""`, which ends at a `"""`
// that starts its own line, after its indentation; and either, or a plain
// one, after `b`, a `Bytes` literal. A string's start pushes what it is
// on a stack of its own, since a hole can hold another string, and its
// end pops it. Its text is one token to the next escape, hole or end, so
// no layout token is ever made inside it. Which lines are indented too
// little is the compiler's to say.

#include "tree_sitter/array.h"
#include "tree_sitter/parser.h"

#include <ctype.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

enum TokenType {
  NEWLINE,
  INDENT,
  DEDENT,
  LPAREN,
  RPAREN,
  LBRACKET,
  RBRACKET,
  LBRACE,
  RBRACE,
  ARROW_BLOCK,
  ERROR_SENTINEL,
  STRING_START,
  BYTES_START,
  STRING_CONTENT,
  STRING_ESCAPE,
  HOLE_START,
  STRING_END,
  TYPE_APPLICATION_START,
};

// a string on the string stack: its `#`s, and whether it's `"""` and `b`
#define STR_HASHES 63
#define STR_MULTI 64
#define STR_BYTES 128

// on the stack, an open bracket rather than a block's indentation
#define BRACKET UINT16_MAX

typedef struct {
  // what the scanner is inside, innermost last: the enclosing blocks'
  // indentation, and BRACKET for each open bracket; the file's own
  // block, indented 0, is implied
  Array(uint16_t) stack;
  // the strings open, innermost last, each its `#`s and flags (STR_*)
  Array(uint8_t) strings;
} Scanner;

// How far the innermost block is indented.
static uint16_t current_indent(Scanner *s) {
  for (uint32_t i = s->stack.size; i > 0; i--) {
    uint16_t top = s->stack.contents[i - 1];
    if (top != BRACKET) return top;
  }
  return 0;
}

// Are line breaks layout here: outside brackets, or in a lambda's block
// inside them?
static bool in_block(Scanner *s) {
  return s->stack.size == 0 || *array_back(&s->stack) != BRACKET;
}

static bool in_bracket(Scanner *s) {
  for (uint32_t i = 0; i < s->stack.size; i++)
    if (s->stack.contents[i] == BRACKET) return true;
  return false;
}

static inline void skip(TSLexer *lexer) { lexer->advance(lexer, true); }
static inline void advance(TSLexer *lexer) { lexer->advance(lexer, false); }

static bool is_ident_char(int32_t c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
         (c >= '0' && c <= '9') || c == '_';
}

static bool is_space(int32_t c) {
  return c == ' ' || c == '\t' || c == '\r' || c == '\n';
}

static bool at_word(TSLexer *lexer, const char *word) {
  for (unsigned i = 0; word[i]; i++) {
    if (lexer->lookahead != word[i]) return false;
    advance(lexer);
  }
  return !is_ident_char(lexer->lookahead);
}

// A value's `<...>` must be complete before it becomes a postfix. Leave
// the contents to the grammar, but find its end without mistaking a
// function type's `->` for a closing angle. Only the opening `<` is the
// token: everything inspected after mark_end is read again by the parser.
static bool type_application_start(TSLexer *lexer, bool adjacent, bool layout) {
  if (lexer->lookahead != '<') return false;
  advance(lexer);
  lexer->mark_end(lexer);
  unsigned depth = 1;
  while (!lexer->eof(lexer)) {
    int32_t c = lexer->lookahead;
    advance(lexer);
    if (c == '<') {
      depth++;
    } else if (c == '>') {
      if (--depth == 0) break;
    } else if (c == '-') {
      if (lexer->lookahead != '>') return false;
      advance(lexer);
    } else if (c == '/') {
      if (lexer->lookahead != '/') return false;
      while (lexer->lookahead != '\n' && !lexer->eof(lexer)) advance(lexer);
    } else if (!(is_ident_char(c) || is_space(c) || c == '.' || c == ',' ||
                 c == '(' || c == ')' || c == ':' || c == '&' || c == '!' ||
                 c == '|')) {
      return false;
    }
  }
  if (depth != 0) return false;
  bool line_ended = false;
  for (;;) {
    if (is_space(lexer->lookahead)) {
      if (lexer->lookahead == '\n') line_ended = true;
      advance(lexer);
    } else if (lexer->lookahead == '/') {
      advance(lexer);
      if (lexer->lookahead != '/') return false;
      while (lexer->lookahead != '\n' && !lexer->eof(lexer)) advance(lexer);
    } else {
      break;
    }
  }
  // Whitespace is allowed before a call. A standalone application needs
  // the `<` touching its head and an expression boundary after its `>`.
  bool boundary = (line_ended && layout) || lexer->eof(lexer) ||
                  lexer->lookahead == ',' || lexer->lookahead == ')' ||
                  lexer->lookahead == ']' || lexer->lookahead == '}' ||
                  lexer->lookahead == '.';
  if (lexer->lookahead != '(' && !(adjacent && boundary)) {
    if (!adjacent) return false;
    if (lexer->lookahead == '=') {
      advance(lexer);
      if (lexer->lookahead != '>') return false;
    } else if (lexer->lookahead == 't') {
      if (!at_word(lexer, "then")) return false;
    } else if (lexer->lookahead == 'e') {
      if (!at_word(lexer, "else")) return false;
    } else {
      return false;
    }
  }
  lexer->result_symbol = TYPE_APPLICATION_START;
  return true;
}

// Is the next word `uses`? Moves past what it reads, which is fine: the
// caller then returns no token, and tree-sitter lexes from where it was.
static bool at_uses(TSLexer *lexer) {
  const char *word = "uses";
  for (int i = 0; word[i]; i++) {
    if (lexer->lookahead != word[i]) return false;
    advance(lexer);
  }
  return !is_ident_char(lexer->lookahead);
}

// Is the next token an error set's `!`, not `!=`? Moves past the `!`, as
// at_uses does.
static bool at_bang(TSLexer *lexer) {
  if (lexer->lookahead != '!') return false;
  advance(lexer);
  return lexer->lookahead != '=';
}

// Does the line go on with a chain's next step, `|>`, or a stage, `.`
// and a name (not `..`)? Moves past what it reads, as at_uses does.
static bool at_step(TSLexer *lexer) {
  if (lexer->lookahead == '|') {
    advance(lexer);
    return lexer->lookahead == '>';
  }
  if (lexer->lookahead == '.') {
    advance(lexer);
    int32_t c = lexer->lookahead;
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
  }
  return false;
}

// An opening bracket, or a closing one, which first closes the lambdas'
// blocks still open inside it, one DEDENT a call.
static bool bracket(Scanner *s, TSLexer *lexer, const bool *valid) {
  enum TokenType tok;
  int delta;
  switch (lexer->lookahead) {
    case '(': tok = LPAREN; delta = 1; break;
    case ')': tok = RPAREN; delta = -1; break;
    case '[': tok = LBRACKET; delta = 1; break;
    case ']': tok = RBRACKET; delta = -1; break;
    case '{': tok = LBRACE; delta = 1; break;
    case '}': tok = RBRACE; delta = -1; break;
    default: return false;
  }
  if (delta < 0 && in_bracket(s)) {
    if (in_block(s) && valid[DEDENT]) {
      array_pop(&s->stack);
      lexer->result_symbol = DEDENT;
      return true;
    }
    if (!valid[tok]) return false;
    while (*array_back(&s->stack) != BRACKET) array_pop(&s->stack);
    array_pop(&s->stack);
  } else {
    if (!valid[tok]) return false;
    if (delta > 0 && s->stack.size < UINT16_MAX) array_push(&s->stack, BRACKET);
  }
  advance(lexer);
  lexer->mark_end(lexer);
  lexer->result_symbol = tok;
  return true;
}

// A lambda's `=>` inside brackets that ends its line, before a line
// indented further than the innermost block: it opens the lambda's body
// as a block. Anything else is left to the grammar's own `=>`.
static bool arrow_block(Scanner *s, TSLexer *lexer) {
  if (lexer->lookahead != '=') return false;
  advance(lexer);
  if (lexer->lookahead != '>') return false;
  advance(lexer);
  lexer->mark_end(lexer);
  // the rest of the line, then any blank or comment-only lines
  bool line_ended = false;
  uint32_t indent = 0;
  for (;;) {
    if (lexer->lookahead == '\n') {
      line_ended = true;
      indent = 0;
      advance(lexer);
    } else if (lexer->lookahead == ' ' || lexer->lookahead == '\t') {
      indent++;
      advance(lexer);
    } else if (lexer->lookahead == '\r') {
      advance(lexer);
    } else if (lexer->lookahead == '/') {
      advance(lexer);
      if (lexer->lookahead != '/') return false;
      while (lexer->lookahead != '\n' && !lexer->eof(lexer)) advance(lexer);
    } else {
      break;
    }
  }
  if (!line_ended || lexer->eof(lexer) || indent <= current_indent(s) ||
      indent >= BRACKET)
    return false;
  array_push(&s->stack, (uint16_t)indent);
  lexer->result_symbol = ARROW_BLOCK;
  return true;
}

// Are the next [n] characters `#`? Moves past them.
static bool hashes(TSLexer *lexer, unsigned n) {
  for (unsigned i = 0; i < n; i++) {
    if (lexer->lookahead != '#') return false;
    advance(lexer);
  }
  return true;
}

// A string's start the grammar lexes no other way: `#`s and a quote, or
// `"""`, with a `b` before either, or before a plain quote.
static bool string_start(Scanner *s, TSLexer *lexer, const bool *valid) {
  bool bytes = false;
  if (lexer->lookahead == 'b') {
    advance(lexer);
    if (lexer->lookahead != '"' && lexer->lookahead != '#') return false;
    bytes = true;
  }
  unsigned n = 0;
  while (lexer->lookahead == '#') {
    advance(lexer);
    n++;
  }
  if (lexer->lookahead != '"' || n > STR_HASHES) return false;
  advance(lexer);
  lexer->mark_end(lexer);
  // `""` is an empty string, unless a third quote makes it `"""`
  bool multi = false;
  if (lexer->lookahead == '"') {
    advance(lexer);
    if (lexer->lookahead == '"') {
      advance(lexer);
      lexer->mark_end(lexer);
      multi = true;
    }
  }
  if (!bytes && !multi && n == 0) return false;
  enum TokenType tok = bytes ? BYTES_START : STRING_START;
  if (!valid[tok] || s->strings.size >= UINT8_MAX) return false;
  array_push(&s->strings, (uint8_t)(n | (multi ? STR_MULTI : 0) |
                                    (bytes ? STR_BYTES : 0)));
  lexer->result_symbol = tok;
  return true;
}

// The innermost string's text, up to its next escape, hole or end; or
// that escape, hole or end.
static bool string_body(Scanner *s, TSLexer *lexer) {
  uint8_t top = *array_back(&s->strings);
  unsigned n = top & STR_HASHES;
  bool multi = top & STR_MULTI, bytes = top & STR_BYTES;
  bool text = false;
  // at a line's start in a `"""`, where its closing `"""` may be
  bool line_start = multi && lexer->get_column(lexer) == 0;
  for (;;) {
    if (lexer->eof(lexer)) {
      lexer->result_symbol = STRING_CONTENT;
      return text;
    }
    if (line_start) {
      line_start = false;
      while (lexer->lookahead == ' ' || lexer->lookahead == '\t') advance(lexer);
      if (lexer->lookahead == '"') {
        // the text before the indentation first, then the end
        if (text) {
          lexer->result_symbol = STRING_CONTENT;
          return true;
        }
        advance(lexer);
        if (lexer->lookahead == '"') {
          advance(lexer);
          if (lexer->lookahead == '"') {
            advance(lexer);
            if (hashes(lexer, n)) {
              lexer->mark_end(lexer);
              array_pop(&s->strings);
              lexer->result_symbol = STRING_END;
              return true;
            }
          }
        }
      }
      lexer->mark_end(lexer);
      text = true;
      continue;
    }
    int32_t c = lexer->lookahead;
    if (c == '\\') {
      advance(lexer);
      if (!hashes(lexer, n)) {
        // a `\` without its `#`s is text in a raw string
        lexer->mark_end(lexer);
        text = true;
        continue;
      }
      if (text) {
        lexer->result_symbol = STRING_CONTENT;
        return true;
      }
      if (lexer->lookahead == '{' && !bytes) {
        advance(lexer);
        lexer->mark_end(lexer);
        // a hole is code, in braces of its own, as a bracket is
        if (s->stack.size < UINT16_MAX) array_push(&s->stack, BRACKET);
        lexer->result_symbol = HOLE_START;
        return true;
      }
      if (lexer->lookahead == 'u') {
        advance(lexer);
        if (lexer->lookahead == '{') {
          advance(lexer);
          while (isxdigit(lexer->lookahead)) advance(lexer);
          if (lexer->lookahead == '}') advance(lexer);
        }
      } else if (lexer->lookahead == 'x') {
        advance(lexer);
        for (int i = 0; i < 2 && isxdigit(lexer->lookahead); i++) advance(lexer);
      } else if (lexer->lookahead == '\r') {
        // `\` at a line's end joins it to the next
        advance(lexer);
        if (lexer->lookahead == '\n') advance(lexer);
      } else if (lexer->lookahead == '\n') {
        advance(lexer);
      } else if (!lexer->eof(lexer)) {
        advance(lexer);
      }
      lexer->mark_end(lexer);
      lexer->result_symbol = STRING_ESCAPE;
      return true;
    }
    if (c == '"' && !multi) {
      if (text) {
        lexer->result_symbol = STRING_CONTENT;
        return true;
      }
      advance(lexer);
      if (hashes(lexer, n)) {
        lexer->mark_end(lexer);
        array_pop(&s->strings);
        lexer->result_symbol = STRING_END;
        return true;
      }
      lexer->mark_end(lexer);
      text = true;
      continue;
    }
    if (c == '\n') {
      // a one-line string isn't closed
      if (!multi) {
        lexer->result_symbol = STRING_CONTENT;
        return text;
      }
      advance(lexer);
      lexer->mark_end(lexer);
      text = true;
      line_start = true;
      continue;
    }
    advance(lexer);
    lexer->mark_end(lexer);
    text = true;
  }
}

bool tree_sitter_ren_external_scanner_scan(void *payload, TSLexer *lexer,
                                           const bool *valid) {
  Scanner *s = payload;
  bool recovering = valid[ERROR_SENTINEL];
  bool adjacent = lexer->lookahead == '<';

  lexer->mark_end(lexer);

  // inside a string, where nothing is skipped
  if (s->strings.size > 0 && !recovering &&
      (valid[STRING_CONTENT] || valid[STRING_END]))
    return string_body(s, lexer);

  // Skip to the next token, noting whether a line ended on the way, and
  // how far that token is indented if so.
  bool line_ended = false;
  bool saw_comment = false;
  bool saw_slash = false;
  uint32_t indent = 0;
  for (;;) {
    if (lexer->lookahead == '\n') {
      line_ended = true;
      indent = 0;
      skip(lexer);
    } else if (lexer->lookahead == ' ' || lexer->lookahead == '\t') {
      indent++;
      skip(lexer);
    } else if (lexer->lookahead == '\r') {
      skip(lexer);
    } else if (lexer->lookahead == '/') {
      skip(lexer);
      if (lexer->lookahead != '/') {
        // a `/` that divides: past it now, so only a layout token is safe
        saw_slash = true;
        break;
      }
      saw_comment = true;
      while (lexer->lookahead != '\n' && !lexer->eof(lexer)) skip(lexer);
    } else if (lexer->eof(lexer)) {
      // the end of the file closes every block
      line_ended = true;
      indent = 0;
      break;
    } else {
      break;
    }
  }

  if (line_ended && in_block(s)) {
    uint16_t current = current_indent(s);

    if (indent > current && lexer->lookahead == 'u' && at_uses(lexer))
      return false;
    // a chain's next step, or a stage over a cursor, continues the line
    // above (language.md §8, "Grammar and layout")
    if (indent > current &&
        (lexer->lookahead == '|' || lexer->lookahead == '.') &&
        at_step(lexer))
      return false;
    // after `=`, where a block can open, a `!` starts a named error set
    // written one `|` per line instead (the compiler checks for the `=`)
    if (indent > current && !valid[INDENT] && lexer->lookahead == '!' &&
        at_bang(lexer))
      return false;

    if (indent > current && valid[INDENT]) {
      array_push(&s->stack, (uint16_t)indent);
      lexer->result_symbol = INDENT;
      return true;
    }
    if (indent < current && valid[DEDENT]) {
      array_pop(&s->stack);
      lexer->result_symbol = DEDENT;
      return true;
    }
    // a line indented less than a lambda's block inside brackets closes
    // it, above, and goes on inside the brackets
    if (valid[NEWLINE] && !recovering && in_block(s)) {
      lexer->result_symbol = NEWLINE;
      return true;
    }
  }

  // A comment is left to the grammar, so it shows up in the tree: the
  // next call starts after it.
  if (saw_comment || saw_slash) return false;

  if (lexer->lookahead == '<' && valid[TYPE_APPLICATION_START] && !recovering)
    return type_application_start(lexer, adjacent, in_block(s));

  // a `,` after a lambda's block inside brackets closes it, as a closing
  // bracket does; one in a list of `with` items or dependencies inside it
  // can't, since no DEDENT is valid there
  if (lexer->lookahead == ',' && valid[DEDENT] && !recovering &&
      in_block(s) && in_bracket(s)) {
    array_pop(&s->stack);
    lexer->result_symbol = DEDENT;
    return true;
  }

  if (lexer->lookahead == '=' && valid[ARROW_BLOCK] && !recovering &&
      !in_block(s))
    return arrow_block(s, lexer);
  if ((lexer->lookahead == '"' || lexer->lookahead == '#' ||
       lexer->lookahead == 'b') &&
      (valid[STRING_START] || valid[BYTES_START]) && !recovering)
    return string_start(s, lexer, valid);
  return bracket(s, lexer, valid);
}

void *tree_sitter_ren_external_scanner_create(void) {
  Scanner *s = ts_calloc(1, sizeof(Scanner));
  array_init(&s->stack);
  array_init(&s->strings);
  return s;
}

void tree_sitter_ren_external_scanner_destroy(void *payload) {
  Scanner *s = payload;
  array_delete(&s->stack);
  array_delete(&s->strings);
  ts_free(s);
}

unsigned tree_sitter_ren_external_scanner_serialize(void *payload,
                                                    char *buffer) {
  Scanner *s = payload;
  // the strings first, their count then each, then the blocks and
  // brackets
  unsigned n = 0;
  buffer[n++] = (char)s->strings.size;
  for (uint32_t i = 0; i < s->strings.size; i++) buffer[n++] = (char)s->strings.contents[i];
  for (uint32_t i = 0; i < s->stack.size &&
                       n + sizeof(uint16_t) <= TREE_SITTER_SERIALIZATION_BUFFER_SIZE;
       i++) {
    memcpy(&buffer[n], &s->stack.contents[i], sizeof(uint16_t));
    n += sizeof(uint16_t);
  }
  return n;
}

void tree_sitter_ren_external_scanner_deserialize(void *payload,
                                                  const char *buffer,
                                                  unsigned length) {
  Scanner *s = payload;
  array_clear(&s->stack);
  array_clear(&s->strings);
  unsigned n = 0;
  if (length > 0) {
    unsigned k = (uint8_t)buffer[n++];
    for (unsigned i = 0; i < k && n < length; i++)
      array_push(&s->strings, (uint8_t)buffer[n++]);
  }
  while (n + sizeof(uint16_t) <= length) {
    uint16_t top;
    memcpy(&top, &buffer[n], sizeof(uint16_t));
    array_push(&s->stack, top);
    n += sizeof(uint16_t);
  }
}
