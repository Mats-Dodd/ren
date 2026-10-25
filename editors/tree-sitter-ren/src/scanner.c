// Ren's layout, for tree-sitter: the same rules as the compiler's lexer
// (lib/syntax/lexer.ml), which emits three layout tokens, as Python does:
//
//   INDENT   a line is indented further than the one before (a block opens)
//   DEDENT   a line is indented less (one DEDENT per block that closes)
//   NEWLINE  a new line at the same indentation (separates statements)
//
// Inside parentheses, brackets or braces, line breaks and indentation are
// ignored, so the scanner lexes the brackets itself to know how deep it
// is. Blank and comment-only lines are skipped. An indented line that
// starts with `uses` continues the signature above it, so it gets no
// layout token at all.
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
  ERROR_SENTINEL,
};

typedef struct {
  // the enclosing blocks' indentation; the file's own, 0, is implied
  Array(uint16_t) indents;
  // how many brackets are open
  uint8_t depth;
} Scanner;

static inline uint16_t current_indent(Scanner *s) {
  return s->indents.size == 0 ? 0 : *array_back(&s->indents);
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
  if (!valid[tok]) return false;
  advance(lexer);
  lexer->mark_end(lexer);
  if (delta > 0 && s->depth < UINT8_MAX) s->depth++;
  if (delta < 0 && s->depth > 0) s->depth--;
  lexer->result_symbol = tok;
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

  if (line_ended && s->depth == 0) {
    uint16_t current = current_indent(s);

    if (indent > current && lexer->lookahead == 'u' && at_uses(lexer))
      return false;

    if (indent > current && valid[INDENT]) {
      array_push(&s->indents, (uint16_t)indent);
      lexer->result_symbol = INDENT;
      return true;
    }
    if (indent < current && valid[DEDENT]) {
      array_pop(&s->indents);
      lexer->result_symbol = DEDENT;
      return true;
    }
    if (valid[NEWLINE] && !recovering) {
      lexer->result_symbol = NEWLINE;
      return true;
    }
  }

  // A comment is left to the grammar, so it shows up in the tree: the
  // next call starts after it.
  if (saw_comment || saw_slash) return false;

  return bracket(s, lexer, valid);
}

void *tree_sitter_ren_external_scanner_create(void) {
  Scanner *s = ts_calloc(1, sizeof(Scanner));
  array_init(&s->indents);
  return s;
}

void tree_sitter_ren_external_scanner_destroy(void *payload) {
  Scanner *s = payload;
  array_delete(&s->indents);
  ts_free(s);
}

unsigned tree_sitter_ren_external_scanner_serialize(void *payload,
                                                    char *buffer) {
  Scanner *s = payload;
  unsigned n = 0;
  buffer[n++] = (char)s->depth;
  for (uint32_t i = 0; i < s->indents.size &&
                       n + sizeof(uint16_t) <= TREE_SITTER_SERIALIZATION_BUFFER_SIZE;
       i++) {
    memcpy(&buffer[n], &s->indents.contents[i], sizeof(uint16_t));
    n += sizeof(uint16_t);
  }
  return n;
}

void tree_sitter_ren_external_scanner_deserialize(void *payload,
                                                  const char *buffer,
                                                  unsigned length) {
  Scanner *s = payload;
  array_clear(&s->indents);
  s->depth = 0;
  if (length == 0) return;
  unsigned n = 0;
  s->depth = (uint8_t)buffer[n++];
  while (n + sizeof(uint16_t) <= length) {
    uint16_t indent;
    memcpy(&indent, &buffer[n], sizeof(uint16_t));
    array_push(&s->indents, indent);
    n += sizeof(uint16_t);
  }
}
