/* ANSI-C code produced by gperf version 3.0.3 */
/* Command-line: /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/gperf --compare-lengths -L ANSI-C gen/pair.gperf  */
/* Computed positions: -k'' */

#line 1 "gen/pair.gperf"

#include <string.h>
#line 8 "gen/pair.gperf"
struct pair_g { const char *name; int idx; };

#define TOTAL_KEYWORDS 2
#define MIN_WORD_LENGTH 4
#define MAX_WORD_LENGTH 6
#define MIN_HASH_VALUE 4
#define MAX_HASH_VALUE 6
/* maximum key range = 3, duplicates = 0 */

#ifdef __GNUC__
__inline
#else
#ifdef __cplusplus
inline
#endif
#endif
/*ARGSUSED*/
static unsigned int
pair_ghash (register const char *str, register unsigned int len)
{
  return len;
}

struct pair_g *
pair_gperf_find (register const char *str, register unsigned int len)
{
  static unsigned char lengthtable[] =
    {
       0,  0,  0,  0,  4,  0,  6
    };
  static struct pair_g wordlist[] =
    {
      {""}, {""}, {""}, {""},
#line 10 "gen/pair.gperf"
      {"keys", 0},
      {""},
#line 11 "gen/pair.gperf"
      {"health", 1}
    };

  if (len <= MAX_WORD_LENGTH && len >= MIN_WORD_LENGTH)
    {
      unsigned int key = pair_ghash (str, len);

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
#line 12 "gen/pair.gperf"

