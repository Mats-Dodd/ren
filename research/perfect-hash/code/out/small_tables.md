### ns per lookup (hyperfine mean minus the empty loop, ± combined stddev)

| form | one | pair | trio | quad | methods_skew |
|---|---:|---:|---:|---:|---:|
| Ren today (== chain) | 0.34 ± 0.01 | 1.69 ± 0.07 | 2.85 ± 0.17 | 3.05 ± 0.11 | 3.49 ± 0.02 |
| length switch + memcmp (C) | 0.35 ± 0.01 | 1.52 ± 0.07 | 2.59 ± 0.07 | 2.81 ± 0.16 | 3.47 ± 0.02 |
| Rust `match` (rustc) | 0.37 ± 0.01 | 1.65 ± 0.10 | 2.79 ± 0.23 | 2.99 ± 0.23 | 1.49 ± 0.08 |
| gperf 3.0.3 | 0.57 ± 0.01 | 4.79 ± 0.04 | 4.55 ± 0.06 | 5.13 ± 0.05 | 4.47 ± 0.02 |
| hash map (FNV-1a, open addr.) | 3.54 ± 0.05 | 6.35 ± 0.07 | 6.28 ± 0.04 | 5.59 ± 0.09 | 5.44 ± 0.05 |
| phash + memcmp | 0.40 ± 0.01 | 3.96 ± 0.11 | 4.16 ± 0.08 | 4.13 ± 0.09 | 3.99 ± 0.06 |
| phash + 2 words (padded) | 0.40 ± 0.01 | 1.04 ± 0.02 | 1.09 ± 0.03 | 1.03 ± 0.02 | 1.03 ± 0.01 |
| phash + NEON, page check | 0.51 ± 0.01 | 0.87 ± 0.02 | 0.87 ± 0.02 | 0.92 ± 0.02 | 0.97 ± 0.01 |
| phash + NEON, padded | 0.41 ± 0.01 | 0.84 ± 0.01 | 0.85 ± 0.02 | 0.93 ± 0.09 | 0.96 ± 0.02 |

### Time relative to phash + NEON (page check)

| form | one | pair | trio | quad | methods_skew |
|---|---:|---:|---:|---:|---:|
| Ren today (== chain) | 0.7x ± 0.0 | 1.9x ± 0.1 | 3.3x ± 0.2 | 3.3x ± 0.1 | 3.6x ± 0.0 |
| length switch + memcmp (C) | 0.7x ± 0.0 | 1.8x ± 0.1 | 3.0x ± 0.1 | 3.1x ± 0.2 | 3.6x ± 0.0 |
| Rust `match` (rustc) | 0.7x ± 0.0 | 1.9x ± 0.1 | 3.2x ± 0.3 | 3.3x ± 0.3 | 1.5x ± 0.1 |
| gperf 3.0.3 | 1.1x ± 0.0 | 5.5x ± 0.2 | 5.2x ± 0.1 | 5.6x ± 0.2 | 4.6x ± 0.1 |
| hash map (FNV-1a, open addr.) | 6.9x ± 0.2 | 7.3x ± 0.2 | 7.2x ± 0.2 | 6.1x ± 0.2 | 5.6x ± 0.1 |
| phash + memcmp | 0.8x ± 0.0 | 4.6x ± 0.2 | 4.8x ± 0.1 | 4.5x ± 0.2 | 4.1x ± 0.1 |
| phash + 2 words (padded) | 0.8x ± 0.0 | 1.2x ± 0.0 | 1.2x ± 0.0 | 1.1x ± 0.0 | 1.1x ± 0.0 |
| phash + NEON, page check | 1.0x ± 0.0 | 1.0x ± 0.0 | 1.0x ± 0.0 | 1.0x ± 0.0 | 1.0x ± 0.0 |
| phash + NEON, padded | 0.8x ± 0.0 | 1.0x ± 0.0 | 1.0x ± 0.0 | 1.0x ± 0.1 | 1.0x ± 0.0 |

### Instructions per lookup (hyperfine counters, minus the empty loop)

| form | one | pair | trio | quad | methods_skew |
|---|---:|---:|---:|---:|---:|
| Ren today (== chain) | 10.5 | 11.5 | 14.5 | 13.6 | 22.7 |
| length switch + memcmp (C) | 8.7 | 11.1 | 14.9 | 13.7 | 22.8 |
| Rust `match` (rustc) | 8.1 | 10.6 | 13.6 | 12.7 | 14.2 |
| gperf 3.0.3 | 14.3 | 51.3 | 52.0 | 56.4 | 56.3 |
| hash map (FNV-1a, open addr.) | 63.2 | 73.6 | 79.1 | 67.9 | 73.3 |
| phash + memcmp | 8.7 | 41.2 | 49.4 | 43.7 | 50.6 |
| phash + 2 words (padded) | 8.7 | 25.0 | 25.1 | 25.3 | 25.7 |
| phash + NEON, page check | 16.3 | 26.9 | 27.0 | 27.2 | 27.7 |
| phash + NEON, padded | 12.5 | 24.0 | 24.1 | 24.3 | 24.7 |

### Instructions per cycle

| form | one | pair | trio | quad | methods_skew |
|---|---:|---:|---:|---:|---:|
| Ren today (== chain) | 7.6 | 1.6 | 1.2 | 1.0 | 1.6 |
| length switch + memcmp (C) | 6.1 | 1.7 | 1.5 | 1.1 | 1.6 |
| Rust `match` (rustc) | 5.4 | 1.5 | 1.2 | 1.0 | 2.4 |
| gperf 3.0.3 | 6.3 | 2.5 | 2.9 | 2.5 | 3.2 |
| hash map (FNV-1a, open addr.) | 4.4 | 2.8 | 3.2 | 2.8 | 3.4 |
| phash + memcmp | 5.4 | 2.4 | 3.0 | 2.4 | 3.2 |
| phash + 2 words (padded) | 5.4 | 6.0 | 5.9 | 6.2 | 6.3 |
| phash + NEON, page check | 7.9 | 7.8 | 7.9 | 7.5 | 7.1 |
| phash + NEON, padded | 7.7 | 7.2 | 7.3 | 6.7 | 6.4 |

### Cross-check: in-process min of 500 passes, ns per lookup (includes the loop)

| form | one | pair | trio | quad | methods_skew |
|---|---:|---:|---:|---:|---:|
| Ren today (== chain) | 0.44 | 1.65 | 2.88 | 2.82 | 3.46 |
| length switch + memcmp (C) | 0.44 | 1.53 | 2.50 | 2.94 | 3.30 |
| Rust `match` (rustc) | 0.48 | 1.62 | 2.89 | 3.12 | 1.60 |
| gperf 3.0.3 | 0.69 | 4.56 | 4.65 | 4.99 | 4.41 |
| hash map (FNV-1a, open addr.) | 3.33 | 6.01 | 6.39 | 5.33 | 5.40 |
| phash + memcmp | 0.49 | 3.83 | 4.26 | 4.04 | 4.09 |
| phash + 2 words (padded) | 0.49 | 1.11 | 1.18 | 1.08 | 1.18 |
| phash + NEON, page check | 0.63 | 1.01 | 0.99 | 0.95 | 1.11 |
| phash + NEON, padded | 0.50 | 0.92 | 0.96 | 0.96 | 1.05 |

### Load (1-minute average) before and after each set

| set | before | after |
|---|---:|---:|
| one | 3.93 | 4.41 |
| pair | 3.91 | 3.53 |
| trio | 3.53 | 4.21 |
| quad | 3.92 | 4.46 |
| methods_skew | 3.73 | 4.63 |
