/* ANSI-C code produced by gperf version 3.0.3 */
/* Command-line: /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/gperf --compare-lengths -L ANSI-C gen/one.gperf  */
/* Computed positions: -k'' */

#line 1 "gen/one.gperf"

#include <string.h>
#line 8 "gen/one.gperf"
struct one_g { const char *name; int idx; };

#define TOTAL_KEYWORDS 1
#define MIN_WORD_LENGTH 2
#define MAX_WORD_LENGTH 2
#define MIN_HASH_VALUE 2
#define MAX_HASH_VALUE 2
/* maximum key range = 1, duplicates = 0 */

#ifdef __GNUC__
__inline
#else
#ifdef __cplusplus
inline
#endif
#endif
/*ARGSUSED*/
static unsigned int
one_ghash (register const char *str, register unsigned int len)
{
  return len;
}

struct one_g *
one_gperf_find (register const char *str, register unsigned int len)
{
  static unsigned char lengthtable[] =
    {
       0,  0,  2
    };
  static struct one_g wordlist[] =
    {
      {""}, {""},
#line 10 "gen/one.gperf"
      {"v1", 0}
    };

  if (len <= MAX_WORD_LENGTH && len >= MIN_WORD_LENGTH)
    {
      unsigned int key = one_ghash (str, len);

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
#line 11 "gen/one.gperf"

