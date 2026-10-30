// K1b memory: what one cache line (128 B) per instance costs at n small
// actors. Three layouts of one instance (header = lock 4 + pin word 4 +
// key 8 + use stamp 8 = 24 B, then the state):
//   packed       header and state, natural 8-byte alignment, no padding
//   line         header and state inline, the instance padded to whole lines
//   line_header  the header alone on its line, the state in a separate packed
//                array (what you'd do if the state were large)
// Prints sizeof, the bytes the layout should take, and the phys_footprint
// growth when n are allocated and written (macOS: mach task_info
// phys_footprint; Linux: resident set size from /proc/self/statm, so it moves
// in whole 4 KiB pages), plus the family table's bytes per instance at the
// default parts. One line per run.
#include "common.h"
#if defined(__APPLE__)
#include <mach/mach.h>
#define FOOTPRINT_SRC "phys_footprint"
#else
#include <unistd.h>
#define FOOTPRINT_SRC "rss"
#endif

#define LINE 128

static uint64_t footprint(void) {
#if defined(__APPLE__)
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return info.phys_footprint;
#else
    FILE *f = fopen("/proc/self/statm", "r");
    unsigned long size = 0, res = 0;
    if (!f) return 0;
    if (fscanf(f, "%lu %lu", &size, &res) != 2) res = 0;
    fclose(f);
    return (uint64_t)res * (uint64_t)sysconf(_SC_PAGESIZE);
#endif
}

static size_t round_up(size_t x, size_t a) { return (x + a - 1) / a * a; }

int main(int argc, char **argv) {
    long n = 50000, state = 32;
    const char *layout = "line";
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : "";
        if (!strcmp(a, "--n")) { n = atol(v); i++; }
        else if (!strcmp(a, "--state")) { state = atol(v); i++; }
        else if (!strcmp(a, "--layout")) { layout = v; i++; }
        else { fprintf(stderr, "unknown arg %s\n", a); return 2; }
    }
    const size_t header = 24;
    size_t per, side = 0, align;
    if (!strcmp(layout, "packed")) { per = round_up(header + state, 8); align = 8; }
    else if (!strcmp(layout, "line")) { per = round_up(header + state, LINE); align = LINE; }
    else if (!strcmp(layout, "line_header")) { per = LINE; side = round_up(state, 8); align = LINE; }
    else { fprintf(stderr, "unknown layout %s\n", layout); return 2; }

    uint64_t before = footprint();
    uint8_t *inst = aligned_alloc(align, round_up(per * n, align));
    uint8_t *st = side ? malloc(side * n) : NULL;
    // Write every byte, as setup would, so the pages are resident.
    for (long i = 0; i < n; i++) {
        memset(inst + per * i, (int)(i & 0xff), per);
        if (st) memset(st + side * i, (int)(i & 0xff), side);
    }
    uint64_t after = footprint();
    // Check: the layout is aligned as claimed and the writes stuck.
    int ok = ((uintptr_t)inst % align) == 0;
    for (long i = 0; i < n; i += 997) ok &= inst[per * i + per - 1] == (uint8_t)(i & 0xff);
    size_t want = per * n + side * n;
    size_t packed = round_up(header + state, 8) * n;
    // The family's table at the default parts (see k1b.c's build).
    uint32_t parts = default_parts((uint32_t)n);
    size_t tab = (size_t)parts * pow2_at_least((uint32_t)(n / parts) * 2 + 256) * (8 + 4);
    printf("k1b_mem lang=c layout=%s n=%ld state=%ld sizeof=%zu side=%zu bytes=%zu per_instance=%.1f "
           "over_packed_bytes=%zu over_packed_pct=%.1f footprint_delta=%llu footprint_src=%s table_bytes=%zu "
           "table_per_instance=%.1f ok=%d\n",
           layout, n, state, per, side, want, (double)want / n, want - packed, 100.0 * (double)(want - packed) / packed,
           (unsigned long long)(after - before), FOOTPRINT_SRC, tab, (double)tab / n, ok);
    free(inst);
    free(st);
    return ok ? 0 : 1;
}
