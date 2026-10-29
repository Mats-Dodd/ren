/* Inputs for every experiment, deterministic (splitmix64, fixed seed), so
   C, Rust and Go read the same bytes. `gen <dir> [big_chunks]`. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static uint64_t s = 0x2545F4914F6CDD1DULL;
static uint64_t rnd(void) {
  uint64_t z = (s += 0x9e3779b97f4a7c15ULL);
  z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
  z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
  return z ^ (z >> 31);
}
static uint64_t R(uint64_t n) { return rnd() % n; }
static int P(int pct) { return (int)R(100) < pct; }

static const char *W[] = {
    "user", "id", "get", "set", "count", "item", "list", "map", "node", "value",
    "buf", "len", "next", "prev", "data", "key", "index", "name", "path", "time",
    "size", "read", "write", "parse", "token", "state", "error", "result",
    "config", "server", "client", "request", "response", "handler", "cache",
    "queue", "event", "stream", "frame", "table", "pool", "array", "bytes",
    "string", "order", "account", "price", "total", "line", "file", "entry",
    "temp", "flag", "mode", "kind", "type", "ref", "ptr", "ctx", "cur", "pos",
    "off", "max", "min"};
#define NW (sizeof W / sizeof *W)
static const char *KW[] = {"let", "fn", "if", "else", "return", "for", "in",
                           "match", "var", "while"};

static char *ident(char *o) {
  int parts = 1 + (int)R(3);
  char *p = o;
  for (int i = 0; i < parts; i++) {
    if (i)
      *p++ = '_';
    p += sprintf(p, "%s", W[R(NW)]);
  }
  if (P(20))
    p += sprintf(p, "%d", (int)R(100));
  *p = 0;
  return o;
}

static FILE *fo(const char *dir, const char *name) {
  char path[512];
  snprintf(path, sizeof path, "%s/%s", dir, name);
  FILE *f = fopen(path, "w");
  if (!f) {
    perror(path);
    exit(1);
  }
  return f;
}

/* a key from the mixed distribution: short identifiers, dotted metric
   names, and URLs that share a long prefix */
static void key(char *o, int kind) {
  char a[128], b[128];
  if (kind < 60)
    sprintf(o, "%s", ident(a));
  else if (kind < 85)
    sprintf(o, "%s.%s.%s", W[R(NW)], ident(a), ident(b));
  else
    sprintf(o, "https://api.example.com/v%d/%s/%llu/%s?page=%d", 1 + (int)R(2),
            W[R(NW)], (unsigned long long)R(1000000), ident(a), (int)R(50));
}

static const char *SYL[] = {"san", "por", "ber", "lin", "mad", "rid", "tok",
                            "yo", "lon", "don", "par", "is", "osa", "ka",
                            "new", "york", "chi", "ca", "go", "sao", "pau",
                            "lo", "rio", "mel", "bour", "ne", "syd", "ney"};

int main(int argc, char **argv) {
  const char *dir = argc > 1 ? argv[1] : "data";
  int chunks = argc > 2 ? atoi(argv[2]) : 64;
  mkdir(dir, 0755);
  char a[256], b[256], k[512];

  /* tok.txt: code-like statements, ~1M tokens */
  {
    FILE *f = fo(dir, "tok.txt");
    long toks = 0;
    while (toks < 1000000) {
      int form = (int)R(4);
      if (form == 0) {
        fprintf(f, "let %s = %s(%s, %d) + %s;\n", ident(a), ident(b), ident(k),
                (int)R(100000), ident(a));
        toks += 12;
      } else if (form == 1) {
        fprintf(f, "if %s.%s >= %d {\n  return %s;\n}\n", ident(a), ident(b),
                (int)R(1000), ident(k));
        toks += 11;
      } else if (form == 2) {
        const char *lit[] = {"hello, world", "caf\xc3\xa9 au lait",
                             "\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e",
                             "a longer string literal with several words in it",
                             "ok"};
        fprintf(f, "%s += \"%s\";\n", ident(a), lit[R(5)]);
        toks += 4;
      } else {
        fprintf(f, "%s %s = %s -> %s;\n", KW[R(10)], ident(a), ident(b),
                ident(k));
        toks += 6;
      }
    }
    fclose(f);
  }
  /* keys.txt: 4M lookups over a pool of 200k keys, skewed (80% of draws
     from the hottest 10%) */
  {
    int pool = 200000;
    char **ks = malloc(sizeof(char *) * pool);
    for (int i = 0; i < pool; i++) {
      key(k, (int)R(100));
      ks[i] = strdup(k);
    }
    FILE *f = fo(dir, "keys.txt");
    for (int i = 0; i < 4000000; i++) {
      int j = P(80) ? (int)R(pool / 10) : (int)R(pool);
      fprintf(f, "%s\n", ks[j]);
    }
    fclose(f);
  }
  /* sort.txt: 1M keys, mostly distinct */
  {
    FILE *f = fo(dir, "sort.txt");
    for (int i = 0; i < 1000000; i++) {
      key(k, (int)R(100));
      fprintf(f, "%s\n", k);
    }
    fclose(f);
  }
  /* rows.csv: 5M rows, 2000 cities, 20 departments */
  {
    int nc = 2000;
    char **cs = malloc(sizeof(char *) * nc);
    for (int i = 0; i < nc; i++) {
      char *p = a;
      int n = 2 + (int)R(4);
      for (int j = 0; j < n; j++) {
        p += sprintf(p, "%s", SYL[R(sizeof SYL / sizeof *SYL)]);
        if (j == 1 && P(40))
          *p++ = ' ';
      }
      *p = 0;
      a[0] = (char)(a[0] - 32);
      if (P(5))
        sprintf(p, " \xc3\xa9"); /* a few non-ASCII names */
      sprintf(b, "%s%d", a, i % 7); /* distinct */
      cs[i] = strdup(b);
    }
    FILE *f = fo(dir, "rows.csv");
    for (int i = 0; i < 5000000; i++)
      fprintf(f, "%s,%s,%d\n", cs[R(nc)], W[R(20)], (int)R(100000));
    fclose(f);
  }
  /* logs.txt: 1M log lines */
  {
    const char *svc[] = {"api-gateway", "auth", "billing", "search", "orders",
                         "inventory", "notify", "users"};
    const char *lv[] = {"INFO", "WARN", "ERROR", "DEBUG"};
    const char *meth[] = {"GET", "POST", "PUT", "DELETE"};
    FILE *f = fo(dir, "logs.txt");
    for (int i = 0; i < 1000000; i++) {
      int r = (int)R(100);
      int l = r < 85 ? 0 : r < 95 ? 1 : r < 99 ? 2 : 3;
      int pk = (int)R(5);
      char path[256];
      if (pk == 0)
        sprintf(path, "/v1/users/%d/orders", (int)R(100000));
      else if (pk == 1)
        sprintf(path, "/v2/items/%d", (int)R(1000000));
      else if (pk == 2)
        sprintf(path, "/health");
      else if (pk == 3)
        sprintf(path, "/v1/search?q=%s", W[R(NW)]);
      else
        sprintf(path, "/v1/users/%d", (int)R(100000));
      int status = P(2) ? 500 : P(5) ? 404 : 200;
      fprintf(f, "2026-10-29T09:%02d:%02d.%03dZ %s %s %s %s %d %dms req_id=%016llx\n",
              (int)R(60), (int)R(60), (int)R(1000), lv[l], svc[R(8)],
              meth[R(4)], path, status, 1 + (int)R(2000),
              (unsigned long long)rnd());
    }
    fclose(f);
  }
  /* people.csv: 1M records for the JSON emitter; some names need
     escaping, some are not ASCII */
  {
    FILE *f = fo(dir, "people.csv");
    for (int i = 0; i < 1000000; i++) {
      char nm[128];
      sprintf(nm, "%s %s", W[R(NW)], W[R(NW)]);
      nm[0] = (char)(nm[0] - 32);
      if (P(3))
        strcat(nm, " \\\"jr\\\""); /* stored with the escape marker below */
      if (P(5))
        strcat(nm, " Mu\xc3\xb1oz");
      /* fields: id,name,email,score,tags (';'-separated, 0-3) */
      fprintf(f, "%d\t", i);
      for (char *p = nm; *p; p++)
        if (*p != '\\')
          fputc(*p, f);
      fprintf(f, "\t%s.%s%d@example.com\t%d\t", W[R(NW)], W[R(NW)], (int)R(1000),
              (int)R(1000000));
      int nt = (int)R(4);
      for (int t = 0; t < nt; t++)
        fprintf(f, "%s%s", t ? ";" : "", W[R(NW)]);
      fputc('\n', f);
    }
    fclose(f);
  }
  /* body.html: 1 MiB of HTML-ish text, bodies are 1 KiB slices of it */
  {
    FILE *f = fo(dir, "body.html");
    long n = 0;
    while (n < (1 << 20)) {
      n += fprintf(f, "<p class=\"%s\">%s %s %s caf\xc3\xa9</p>\n", W[R(NW)],
                   W[R(NW)], W[R(NW)], W[R(NW)]);
    }
    fclose(f);
  }
  /* big/: [chunks] files of 8 MiB, lines of a key and a payload */
  {
    char path[512];
    snprintf(path, sizeof path, "%s/big", dir);
    mkdir(path, 0755);
    for (int c = 0; c < chunks; c++) {
      snprintf(path, sizeof path, "%s/big/%03d.txt", dir, c);
      FILE *f = fopen(path, "w");
      long n = 0;
      while (n < (8L << 20) - 400) {
        int r = (int)R(100);
        int len = r < 50 ? 8 + (int)R(9) : r < 85 ? 17 + (int)R(16) : 33 + (int)R(48);
        char kk[96];
        for (int i = 0; i < len; i++)
          kk[i] = "abcdefghijklmnopqrstuvwxyz0123456789_-"[R(38)];
        kk[len] = 0;
        char pay[256];
        int pl = 100 + (int)R(150);
        for (int i = 0; i < pl; i++)
          pay[i] = (char)('a' + R(26));
        pay[pl] = 0;
        n += fprintf(f, "%s %s\n", kk, pay);
      }
      fclose(f);
    }
  }
  return 0;
}
