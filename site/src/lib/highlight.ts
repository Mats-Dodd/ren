// Monochrome highlighter for Ren listings. Weight and slant carry meaning, not color.
// Keywords follow the compiler's lexer; editors/tree-sitter-ren is the full grammar.
export type Tok = { t: 'kw' | 'com' | 'str' | 'num' | 'type' | 'mark' | 'plain'; v: string };

// The lexer's keyword table (lib/syntax/lexer.ml). Keep in step with it.
const KW = new Set([
  'fn', 'pub', 'let', 'var', 'inout', 'for', 'while', 'break', 'todo', 'in', 'if', 'then', 'else', 'true', 'false', 'type', 'dep', 'match', 'import', 'as',
  'uses', 'opaque', 'self', 'not', 'fail', 'try', 'attempt', 'orelse', 'with', 'handler', 'over', 'finally', 'test', 'group', 'assert',
]);
const RE = /(\/\/.*$)|("(?:[^"\\]|\\.)*")|(\b\d[\d_]*(?:\.\d+)?\b)|([A-Za-z_][A-Za-z0-9_]*)|([!&])|(\s+|.)/gm;

export function highlightLine(line: string): Tok[] {
  const out: Tok[] = [];
  for (const m of line.matchAll(RE)) {
    const [v, com, str, num, word, mark] = m;
    if (com) out.push({ t: 'com', v });
    else if (str) out.push({ t: 'str', v });
    else if (num) out.push({ t: 'num', v });
    else if (word) out.push({ t: KW.has(word) ? 'kw' : /^[A-Z]/.test(word) ? 'type' : 'plain', v });
    else if (mark) out.push({ t: 'mark', v });
    else out.push({ t: 'plain', v });
  }
  return out;
}
