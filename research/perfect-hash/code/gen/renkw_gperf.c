/* ANSI-C code produced by gperf version 3.0.3 */
/* Command-line: /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/gperf --compare-lengths -L ANSI-C gen/renkw.gperf  */
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

#line 1 "gen/renkw.gperf"

#include <string.h>
#line 8 "gen/renkw.gperf"
struct renkw_g { const char *name; int idx; };

#define TOTAL_KEYWORDS 35
#define MIN_WORD_LENGTH 2
#define MAX_WORD_LENGTH 7
#define MIN_HASH_VALUE 2
#define MAX_HASH_VALUE 54
/* maximum key range = 53, duplicates = 0 */

#ifdef __GNUC__
__inline
#else
#ifdef __cplusplus
inline
#endif
#endif
static unsigned int
renkw_ghash (register const char *str, register unsigned int len)
{
  static unsigned char asso_values[] =
    {
      55, 55, 55, 55, 55, 55, 55, 55, 55, 55,
      55, 55, 55, 55, 55, 55, 55, 55, 55, 55,
      55, 55, 55, 55, 55, 55, 55, 55, 55, 55,
      55, 55, 55, 55, 55, 55, 55, 55, 55, 55,
      55, 55, 55, 55, 55, 55, 55, 55, 55, 55,
      55, 55, 55, 55, 55, 55, 55, 55, 55, 55,
      55, 55, 55, 55, 55, 55, 55, 55, 55, 55,
      55, 55, 55, 55, 55, 55, 55, 55, 55, 55,
      55, 55, 55, 55, 55, 55, 55, 55, 55, 55,
      55, 55, 55, 55, 55, 55, 55,  0, 25, 55,
       0, 30,  5, 15, 25, 10, 55, 55,  5, 15,
       0,  0, 10, 55,  5,  0, 20,  0, 15,  0,
      55, 20, 55, 55, 55, 55, 55, 55, 55, 55,
      55, 55, 55, 55, 55, 55, 55, 55, 55, 55,
      55, 55, 55, 55, 55, 55, 55, 55, 55, 55,
      55, 55, 55, 55, 55, 55, 55, 55, 55, 55,
      55, 55, 55, 55, 55, 55, 55, 55, 55, 55,
      55, 55, 55, 55, 55, 55, 55, 55, 55, 55,
      55, 55, 55, 55, 55, 55, 55, 55, 55, 55,
      55, 55, 55, 55, 55, 55, 55, 55, 55, 55,
      55, 55, 55, 55, 55, 55, 55, 55, 55, 55,
      55, 55, 55, 55, 55, 55, 55, 55, 55, 55,
      55, 55, 55, 55, 55, 55, 55, 55, 55, 55,
      55, 55, 55, 55, 55, 55, 55, 55, 55, 55,
      55, 55, 55, 55, 55, 55, 55, 55, 55, 55,
      55, 55, 55, 55, 55, 55
    };
  return len + asso_values[(unsigned char)str[1]] + asso_values[(unsigned char)str[0]];
}

struct renkw_g *
renkw_gperf_find (register const char *str, register unsigned int len)
{
  static unsigned char lengthtable[] =
    {
       0,  0,  2,  3,  4,  0,  6,  2,  3,  4,  5,  6,  2,  3,
       4,  5,  6,  2,  3,  4,  5,  0,  7,  0,  4,  5,  0,  7,
       3,  4,  5,  6,  7,  3,  4,  5,  0,  0,  3,  4,  0,  0,
       0,  0,  4,  0,  0,  0,  0,  4,  0,  0,  0,  0,  4
    };
  static struct renkw_g wordlist[] =
    {
      {""}, {""},
#line 29 "gen/renkw.gperf"
      {"as", 19},
#line 33 "gen/renkw.gperf"
      {"not", 23},
#line 30 "gen/renkw.gperf"
      {"uses", 20},
      {""},
#line 44 "gen/renkw.gperf"
      {"assert", 34},
#line 10 "gen/renkw.gperf"
      {"fn", 0},
#line 15 "gen/renkw.gperf"
      {"for", 5},
#line 34 "gen/renkw.gperf"
      {"fail", 24},
#line 24 "gen/renkw.gperf"
      {"false", 14},
#line 37 "gen/renkw.gperf"
      {"orelse", 27},
#line 19 "gen/renkw.gperf"
      {"in", 9},
#line 11 "gen/renkw.gperf"
      {"pub", 1},
#line 38 "gen/renkw.gperf"
      {"with", 28},
#line 14 "gen/renkw.gperf"
      {"inout", 4},
#line 31 "gen/renkw.gperf"
      {"opaque", 21},
#line 20 "gen/renkw.gperf"
      {"if", 10},
#line 13 "gen/renkw.gperf"
      {"var", 3},
#line 40 "gen/renkw.gperf"
      {"over", 30},
#line 27 "gen/renkw.gperf"
      {"match", 17},
      {""},
#line 41 "gen/renkw.gperf"
      {"finally", 31},
      {""},
#line 18 "gen/renkw.gperf"
      {"todo", 8},
#line 43 "gen/renkw.gperf"
      {"group", 33},
      {""},
#line 36 "gen/renkw.gperf"
      {"attempt", 26},
#line 35 "gen/renkw.gperf"
      {"try", 25},
#line 23 "gen/renkw.gperf"
      {"true", 13},
#line 16 "gen/renkw.gperf"
      {"while", 6},
#line 28 "gen/renkw.gperf"
      {"import", 18},
#line 39 "gen/renkw.gperf"
      {"handler", 29},
#line 26 "gen/renkw.gperf"
      {"dep", 16},
#line 32 "gen/renkw.gperf"
      {"self", 22},
#line 17 "gen/renkw.gperf"
      {"break", 7},
      {""}, {""},
#line 12 "gen/renkw.gperf"
      {"let", 2},
#line 22 "gen/renkw.gperf"
      {"else", 12},
      {""}, {""}, {""}, {""},
#line 25 "gen/renkw.gperf"
      {"type", 15},
      {""}, {""}, {""}, {""},
#line 21 "gen/renkw.gperf"
      {"then", 11},
      {""}, {""}, {""}, {""},
#line 42 "gen/renkw.gperf"
      {"test", 32}
    };

  if (len <= MAX_WORD_LENGTH && len >= MIN_WORD_LENGTH)
    {
      unsigned int key = renkw_ghash (str, len);

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
#line 45 "gen/renkw.gperf"

