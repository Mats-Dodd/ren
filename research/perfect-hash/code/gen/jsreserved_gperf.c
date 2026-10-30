/* ANSI-C code produced by gperf version 3.0.3 */
/* Command-line: /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/gperf --compare-lengths -L ANSI-C gen/jsreserved.gperf  */
/* Computed positions: -k'1-2' */

#if !((' ' == 32) && ('!' == 33) && ('"' == 34) && ('#' == 35) \
      && ('%' == 37) && ('&' == 38) && ('\'' == 39) && ('(' == 40) \
      && (')' == 41) && ('*' == 42) && ('+' == 43) && (',' == 44) \
      && ('-' == 45) && ('.' == 46) && ('/' == 47) && ('0' == 48) \
      && ('1' == 49) && ('2' == 50) && ('3' == 51) && ('4' == 52) \
      && ('5' == 53) && ('6' == 54) && ('7' == 55) && ('8' == 56) \
      && ('9' == 57) && (':' == 58) && (';' == 59) && ('<' == 60) \
      && ('=' == 61) && ('>' == 62) && ('?' == 63) && ('A' == 65) \
      && ('B' == 66) && ('C' == 67) && ('D' == 68) && ('E' == 69) \
      && ('F' == 70) && ('G' == 71) && ('H' == 72) && ('I' == 73) \
      && ('J' == 74) && ('K' == 75) && ('L' == 76) && ('M' == 77) \
      && ('N' == 78) && ('O' == 79) && ('P' == 80) && ('Q' == 81) \
      && ('R' == 82) && ('S' == 83) && ('T' == 84) && ('U' == 85) \
      && ('V' == 86) && ('W' == 87) && ('X' == 88) && ('Y' == 89) \
      && ('Z' == 90) && ('[' == 91) && ('\\' == 92) && (']' == 93) \
      && ('^' == 94) && ('_' == 95) && ('a' == 97) && ('b' == 98) \
      && ('c' == 99) && ('d' == 100) && ('e' == 101) && ('f' == 102) \
      && ('g' == 103) && ('h' == 104) && ('i' == 105) && ('j' == 106) \
      && ('k' == 107) && ('l' == 108) && ('m' == 109) && ('n' == 110) \
      && ('o' == 111) && ('p' == 112) && ('q' == 113) && ('r' == 114) \
      && ('s' == 115) && ('t' == 116) && ('u' == 117) && ('v' == 118) \
      && ('w' == 119) && ('x' == 120) && ('y' == 121) && ('z' == 122) \
      && ('{' == 123) && ('|' == 124) && ('}' == 125) && ('~' == 126))
/* The character set is not based on ISO-646.  */
#error "gperf generated tables don't work with this execution character set. Please report a bug to <bug-gnu-gperf@gnu.org>."
#endif

#line 1 "gen/jsreserved.gperf"

#include <string.h>
#line 8 "gen/jsreserved.gperf"
struct jsreserved_g { const char *name; int idx; };

#define TOTAL_KEYWORDS 45
#define MIN_WORD_LENGTH 2
#define MAX_WORD_LENGTH 10
#define MIN_HASH_VALUE 2
#define MAX_HASH_VALUE 65
/* maximum key range = 64, duplicates = 0 */

#ifdef __GNUC__
__inline
#else
#ifdef __cplusplus
inline
#endif
#endif
static unsigned int
jsreserved_ghash (register const char *str, register unsigned int len)
{
  static unsigned char asso_values[] =
    {
      66, 66, 66, 66, 66, 66, 66, 66, 66, 66,
      66, 66, 66, 66, 66, 66, 66, 66, 66, 66,
      66, 66, 66, 66, 66, 66, 66, 66, 66, 66,
      66, 66, 66, 66, 66, 66, 66, 66, 66, 66,
      66, 66, 66, 66, 66, 66, 66, 66, 66, 66,
      66, 66, 66, 66, 66, 66, 66, 66, 66, 66,
      66, 66, 66, 66, 66, 66, 66, 66, 66, 66,
      66, 66, 66, 66, 66, 66, 66, 66, 66, 66,
      66, 66, 66, 66, 66, 66, 66, 66, 66, 66,
      66, 66, 66, 66, 66, 66, 66, 15, 40,  0,
       0,  0, 10, 66, 25,  0, 66, 66, 55,  5,
       0, 20,  5, 66, 20, 10, 20, 20, 30, 25,
      40, 35, 66, 66, 66, 66, 66, 66, 66, 66,
      66, 66, 66, 66, 66, 66, 66, 66, 66, 66,
      66, 66, 66, 66, 66, 66, 66, 66, 66, 66,
      66, 66, 66, 66, 66, 66, 66, 66, 66, 66,
      66, 66, 66, 66, 66, 66, 66, 66, 66, 66,
      66, 66, 66, 66, 66, 66, 66, 66, 66, 66,
      66, 66, 66, 66, 66, 66, 66, 66, 66, 66,
      66, 66, 66, 66, 66, 66, 66, 66, 66, 66,
      66, 66, 66, 66, 66, 66, 66, 66, 66, 66,
      66, 66, 66, 66, 66, 66, 66, 66, 66, 66,
      66, 66, 66, 66, 66, 66, 66, 66, 66, 66,
      66, 66, 66, 66, 66, 66, 66, 66, 66, 66,
      66, 66, 66, 66, 66, 66, 66, 66, 66, 66,
      66, 66, 66, 66, 66, 66
    };
  return len + asso_values[(unsigned char)str[1]] + asso_values[(unsigned char)str[0]];
}

struct jsreserved_g *
jsreserved_gperf_find (register const char *str, register unsigned int len)
{
  static unsigned char lengthtable[] =
    {
       0,  0,  2,  3,  4,  0,  6,  7,  8,  9, 10,  6,  2,  0,
       0, 10,  0,  7,  0,  4,  5,  0,  2,  0,  4,  5,  6,  7,
       8,  4,  5,  6,  7,  3,  9,  5,  6,  0,  8,  0,  5,  6,
       0,  3,  4,  5,  6,  7,  3,  4,  5,  0,  0,  0,  4,  5,
       0,  0,  0,  4,  5,  6,  0,  0,  0,  5
    };
  static struct jsreserved_g wordlist[] =
    {
      {""}, {""},
#line 31 "gen/jsreserved.gperf"
      {"in", 21},
#line 33 "gen/jsreserved.gperf"
      {"new", 23},
#line 22 "gen/jsreserved.gperf"
      {"enum", 12},
      {""},
#line 19 "gen/jsreserved.gperf"
      {"delete", 9},
#line 18 "gen/jsreserved.gperf"
      {"default", 8},
#line 17 "gen/jsreserved.gperf"
      {"debugger", 7},
#line 49 "gen/jsreserved.gperf"
      {"interface", 39},
#line 32 "gen/jsreserved.gperf"
      {"instanceof", 22},
#line 30 "gen/jsreserved.gperf"
      {"import", 20},
#line 29 "gen/jsreserved.gperf"
      {"if", 19},
      {""}, {""},
#line 48 "gen/jsreserved.gperf"
      {"implements", 38},
      {""},
#line 26 "gen/jsreserved.gperf"
      {"finally", 16},
      {""},
#line 12 "gen/jsreserved.gperf"
      {"case", 2},
#line 13 "gen/jsreserved.gperf"
      {"catch", 3},
      {""},
#line 20 "gen/jsreserved.gperf"
      {"do", 10},
      {""},
#line 34 "gen/jsreserved.gperf"
      {"null", 24},
#line 15 "gen/jsreserved.gperf"
      {"const", 5},
#line 35 "gen/jsreserved.gperf"
      {"return", 25},
#line 50 "gen/jsreserved.gperf"
      {"package", 40},
#line 16 "gen/jsreserved.gperf"
      {"continue", 6},
#line 46 "gen/jsreserved.gperf"
      {"with", 36},
#line 25 "gen/jsreserved.gperf"
      {"false", 15},
#line 53 "gen/jsreserved.gperf"
      {"public", 43},
#line 51 "gen/jsreserved.gperf"
      {"private", 41},
#line 27 "gen/jsreserved.gperf"
      {"for", 17},
#line 52 "gen/jsreserved.gperf"
      {"protected", 42},
#line 36 "gen/jsreserved.gperf"
      {"super", 26},
#line 54 "gen/jsreserved.gperf"
      {"static", 44},
      {""},
#line 28 "gen/jsreserved.gperf"
      {"function", 18},
      {""},
#line 47 "gen/jsreserved.gperf"
      {"yield", 37},
#line 37 "gen/jsreserved.gperf"
      {"switch", 27},
      {""},
#line 41 "gen/jsreserved.gperf"
      {"try", 31},
#line 40 "gen/jsreserved.gperf"
      {"true", 30},
#line 10 "gen/jsreserved.gperf"
      {"await", 0},
#line 23 "gen/jsreserved.gperf"
      {"export", 13},
#line 24 "gen/jsreserved.gperf"
      {"extends", 14},
#line 43 "gen/jsreserved.gperf"
      {"var", 33},
#line 38 "gen/jsreserved.gperf"
      {"this", 28},
#line 39 "gen/jsreserved.gperf"
      {"throw", 29},
      {""}, {""}, {""},
#line 44 "gen/jsreserved.gperf"
      {"void", 34},
#line 45 "gen/jsreserved.gperf"
      {"while", 35},
      {""}, {""}, {""},
#line 21 "gen/jsreserved.gperf"
      {"else", 11},
#line 14 "gen/jsreserved.gperf"
      {"class", 4},
#line 42 "gen/jsreserved.gperf"
      {"typeof", 32},
      {""}, {""}, {""},
#line 11 "gen/jsreserved.gperf"
      {"break", 1}
    };

  if (len <= MAX_WORD_LENGTH && len >= MIN_WORD_LENGTH)
    {
      unsigned int key = jsreserved_ghash (str, len);

      if (key <= MAX_HASH_VALUE)
        if (len == lengthtable[key])
          {
            register const char *s = wordlist[key].name;

            if (*str == *s && !memcmp (str + 1, s + 1, len - 1))
              return &wordlist[key];
          }
    }
  return 0;
}
#line 55 "gen/jsreserved.gperf"

