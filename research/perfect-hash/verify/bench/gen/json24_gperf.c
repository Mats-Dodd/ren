/* ANSI-C code produced by gperf version 3.0.3 */
/* Command-line: /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/gperf --compare-lengths -L ANSI-C json24.gperf  */
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

#line 1 "json24.gperf"

#include <string.h>
#line 8 "json24.gperf"
struct json24_g { const char *name; int idx; };

#define TOTAL_KEYWORDS 24
#define MIN_WORD_LENGTH 2
#define MAX_WORD_LENGTH 21
#define MIN_HASH_VALUE 2
#define MAX_HASH_VALUE 41
/* maximum key range = 40, duplicates = 0 */

#ifdef __GNUC__
__inline
#else
#ifdef __cplusplus
inline
#endif
#endif
static unsigned int
json24_ghash (register const char *str, register unsigned int len)
{
  static unsigned char asso_values[] =
    {
      42, 42, 42, 42, 42, 42, 42, 42, 42, 42,
      42, 42, 42, 42, 42, 42, 42, 42, 42, 42,
      42, 42, 42, 42, 42, 42, 42, 42, 42, 42,
      42, 42, 42, 42, 42, 42, 42, 42, 42, 42,
      42, 42, 42, 42, 42, 42, 42, 42, 42, 42,
      42, 42, 42, 42, 42, 42, 42, 42, 42, 42,
      42, 42, 42, 42, 42, 42, 42, 42, 42, 42,
      42, 42, 42, 42, 42, 42, 42, 42, 42, 42,
      42, 42, 42, 42, 42, 42, 42, 42, 42, 42,
      42, 42, 42, 42, 42, 42, 42, 30, 42, 20,
       5, 15, 42, 42, 42,  0, 42, 42, 20, 10,
      10, 15,  0, 42, 42,  0,  0, 15,  0, 42,
      42, 42, 42, 42, 42, 42, 42, 42, 42, 42,
      42, 42, 42, 42, 42, 42, 42, 42, 42, 42,
      42, 42, 42, 42, 42, 42, 42, 42, 42, 42,
      42, 42, 42, 42, 42, 42, 42, 42, 42, 42,
      42, 42, 42, 42, 42, 42, 42, 42, 42, 42,
      42, 42, 42, 42, 42, 42, 42, 42, 42, 42,
      42, 42, 42, 42, 42, 42, 42, 42, 42, 42,
      42, 42, 42, 42, 42, 42, 42, 42, 42, 42,
      42, 42, 42, 42, 42, 42, 42, 42, 42, 42,
      42, 42, 42, 42, 42, 42, 42, 42, 42, 42,
      42, 42, 42, 42, 42, 42, 42, 42, 42, 42,
      42, 42, 42, 42, 42, 42, 42, 42, 42, 42,
      42, 42, 42, 42, 42, 42, 42, 42, 42, 42,
      42, 42, 42, 42, 42, 42
    };
  return len + asso_values[(unsigned char)str[0]];
}

struct json24_g *
json24_gperf_find (register const char *str, register unsigned int len)
{
  static unsigned char lengthtable[] =
    {
       0,  0,  2,  0,  4,  5,  6,  7,  8,  9, 10,  0,  0,  8,
       4, 10, 11,  0,  8,  4,  5,  6,  0,  8,  0, 10,  6,  0,
       0,  0, 10, 21,  0,  0,  0,  0, 16,  0,  8,  0,  0, 11
    };
  static struct json24_g wordlist[] =
    {
      {""}, {""},
#line 10 "json24.gperf"
      {"id", 0},
      {""},
#line 19 "json24.gperf"
      {"tags", 9},
#line 20 "json24.gperf"
      {"title", 10},
#line 16 "json24.gperf"
      {"status", 6},
#line 26 "json24.gperf"
      {"version", 16},
#line 22 "json24.gperf"
      {"priority", 12},
#line 28 "json24.gperf"
      {"parent_id", 18},
#line 30 "json24.gperf"
      {"visibility", 20},
      {""}, {""},
#line 23 "json24.gperf"
      {"due_date", 13},
#line 11 "json24.gperf"
      {"name", 1},
#line 15 "json24.gperf"
      {"deleted_at", 5},
#line 21 "json24.gperf"
      {"description", 11},
      {""},
#line 29 "json24.gperf"
      {"metadata", 19},
#line 27 "json24.gperf"
      {"etag", 17},
#line 12 "json24.gperf"
      {"email", 2},
#line 18 "json24.gperf"
      {"org_id", 8},
      {""},
#line 17 "json24.gperf"
      {"owner_id", 7},
      {""},
#line 14 "json24.gperf"
      {"updated_at", 4},
#line 25 "json24.gperf"
      {"labels", 15},
      {""}, {""}, {""},
#line 13 "json24.gperf"
      {"created_at", 3},
#line 33 "json24.gperf"
      {"notification_settings", 23},
      {""}, {""}, {""}, {""},
#line 32 "json24.gperf"
      {"last_modified_by", 22},
      {""},
#line 31 "json24.gperf"
      {"archived", 21},
      {""}, {""},
#line 24 "json24.gperf"
      {"assignee_id", 14}
    };

  if (len <= MAX_WORD_LENGTH && len >= MIN_WORD_LENGTH)
    {
      unsigned int key = json24_ghash (str, len);

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
#line 34 "json24.gperf"

