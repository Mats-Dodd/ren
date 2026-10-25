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
// layout token is valid.
//
// Each layout token is empty and sits at the end of the line before it.
// So each call starts there again, before the line break: after a DEDENT
// it finds the same next line, and closes another block, or separates it
// with a NEWLINE. The grammar asks for at most one NEWLINE in a row, so
// nothing repeats.

#include "tree_sitter/array.h"
#include "tree_sitter/parser.h"

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
};

// on the stack, an open bracket rather than a block's indentation
#define BRACKET UINT16_MAX

typedef struct {
  // what the scanner is inside, innermost last: the enclosing blocks'
  // indentation, and BRACKET for each open bracket; the file's own
  // block, indented 0, is implied
  Array(uint16_t) stack;
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

bool tree_sitter_ren_external_scanner_scan(void *payload, TSLexer *lexer,
                                           const bool *valid) {
  Scanner *s = payload;
  bool recovering = valid[ERROR_SENTINEL];

  lexer->mark_end(lexer);

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
  return bracket(s, lexer, valid);
}

void *tree_sitter_ren_external_scanner_create(void) {
  Scanner *s = ts_calloc(1, sizeof(Scanner));
  array_init(&s->stack);
  return s;
}

void tree_sitter_ren_external_scanner_destroy(void *payload) {
  Scanner *s = payload;
  array_delete(&s->stack);
  ts_free(s);
}

unsigned tree_sitter_ren_external_scanner_serialize(void *payload,
                                                    char *buffer) {
  Scanner *s = payload;
  unsigned n = 0;
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
  unsigned n = 0;
  while (n + sizeof(uint16_t) <= length) {
    uint16_t top;
    memcpy(&top, &buffer[n], sizeof(uint16_t));
    array_push(&s->stack, top);
    n += sizeof(uint16_t);
  }
}
