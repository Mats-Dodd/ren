/* ANSI-C code produced by gperf version 3.0.3 */
/* Command-line: /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/gperf --compare-lengths -L ANSI-C gen/headers.gperf  */
/* Computed positions: -k'1' */

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

#line 1 "gen/headers.gperf"

#include <string.h>
#line 8 "gen/headers.gperf"
struct headers_g { const char *name; int idx; };

#define TOTAL_KEYWORDS 20
#define MIN_WORD_LENGTH 3
#define MAX_WORD_LENGTH 15
#define MIN_HASH_VALUE 3
#define MAX_HASH_VALUE 30
/* maximum key range = 28, duplicates = 0 */

#ifdef __GNUC__
__inline
#else
#ifdef __cplusplus
inline
#endif
#endif
static unsigned int
headers_ghash (register const char *str, register unsigned int len)
{
  static unsigned char asso_values[] =
    {
      31, 31, 31, 31, 31, 31, 31, 31, 31, 31,
      31, 31, 31, 31, 31, 31, 31, 31, 31, 31,
      31, 31, 31, 31, 31, 31, 31, 31, 31, 31,
      31, 31, 31, 31, 31, 31, 31, 31, 31, 31,
      31, 31, 31, 31, 31, 31, 31, 31, 31, 31,
      31, 31, 31, 31, 31, 31, 31, 31, 31, 31,
      31, 31, 31, 31, 31,  5, 31,  0, 15, 31,
      31, 31,  5, 10, 31, 31,  0, 31, 31, 10,
      31, 31,  0, 15, 31, 20,  0, 31,  0, 31,
      31, 31, 31, 31, 31, 31, 31, 31, 31, 31,
      31, 31, 31, 31, 31, 31, 31, 31, 31, 31,
      31, 31, 31, 31, 31, 31, 31, 31, 31, 31,
      31, 31, 31, 31, 31, 31, 31, 31, 31, 31,
      31, 31, 31, 31, 31, 31, 31, 31, 31, 31,
      31, 31, 31, 31, 31, 31, 31, 31, 31, 31,
      31, 31, 31, 31, 31, 31, 31, 31, 31, 31,
      31, 31, 31, 31, 31, 31, 31, 31, 31, 31,
      31, 31, 31, 31, 31, 31, 31, 31, 31, 31,
      31, 31, 31, 31, 31, 31, 31, 31, 31, 31,
      31, 31, 31, 31, 31, 31, 31, 31, 31, 31,
      31, 31, 31, 31, 31, 31, 31, 31, 31, 31,
      31, 31, 31, 31, 31, 31, 31, 31, 31, 31,
      31, 31, 31, 31, 31, 31, 31, 31, 31, 31,
      31, 31, 31, 31, 31, 31, 31, 31, 31, 31,
      31, 31, 31, 31, 31, 31, 31, 31, 31, 31,
      31, 31, 31, 31, 31, 31
    };
  return len + asso_values[(unsigned char)str[0]];
}

struct headers_g *
headers_gperf_find (register const char *str, register unsigned int len)
{
  static unsigned char lengthtable[] =
    {
       0,  0,  0,  3,  4,  0,  6,  7,  8,  4, 10,  6, 12, 13,
      14, 15,  6,  0, 13,  4, 15,  6,  0, 13,  0, 10,  0,  0,
       0,  0, 10
    };
  static struct headers_g wordlist[] =
    {
      {""}, {""}, {""},
#line 28 "gen/headers.gperf"
      {"Via", 18},
#line 27 "gen/headers.gperf"
      {"Vary", 17},
      {""},
#line 17 "gen/headers.gperf"
      {"Cookie", 7},
#line 23 "gen/headers.gperf"
      {"Referer", 13},
#line 21 "gen/headers.gperf"
      {"Location", 11},
#line 19 "gen/headers.gperf"
      {"Host", 9},
#line 14 "gen/headers.gperf"
      {"Connection", 4},
#line 10 "gen/headers.gperf"
      {"Accept", 0},
#line 16 "gen/headers.gperf"
      {"Content-Type", 6},
#line 13 "gen/headers.gperf"
      {"Cache-Control", 3},
#line 15 "gen/headers.gperf"
      {"Content-Length", 5},
#line 29 "gen/headers.gperf"
      {"X-Forwarded-For", 19},
#line 22 "gen/headers.gperf"
      {"Origin", 12},
      {""},
#line 12 "gen/headers.gperf"
      {"Authorization", 2},
#line 18 "gen/headers.gperf"
      {"Date", 8},
#line 11 "gen/headers.gperf"
      {"Accept-Encoding", 1},
#line 24 "gen/headers.gperf"
      {"Server", 14},
      {""},
#line 20 "gen/headers.gperf"
      {"If-None-Match", 10},
      {""},
#line 25 "gen/headers.gperf"
      {"Set-Cookie", 15},
      {""}, {""}, {""}, {""},
#line 26 "gen/headers.gperf"
      {"User-Agent", 16}
    };

  if (len <= MAX_WORD_LENGTH && len >= MIN_WORD_LENGTH)
    {
      unsigned int key = headers_ghash (str, len);

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
#line 30 "gen/headers.gperf"

