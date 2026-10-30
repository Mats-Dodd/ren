### ns per lookup (hyperfine mean minus the empty loop, ± combined stddev)

| form | methods | headers | jsreserved | json8 | json24 | schemes | renkw |
|---|---:|---:|---:|---:|---:|---:|---:|
| Ren today (== chain) | 10.21 ± 0.13 | 11.30 ± 0.16 | 13.64 ± 0.49 | 9.93 ± 0.02 | 7.20 ± 0.22 | 5.33 ± 0.11 | 8.00 ± 0.30 |
| length switch + memcmp (C) | 10.07 ± 0.12 | 11.34 ± 0.24 | 12.27 ± 0.28 | 9.98 ± 0.09 | 6.97 ± 0.22 | 5.22 ± 0.06 | 7.66 ± 0.28 |
| Rust `match` (rustc) | 8.43 ± 0.34 | 10.69 ± 0.18 | 13.65 ± 0.41 | 6.74 ± 0.30 | 6.91 ± 0.15 | 3.43 ± 0.23 | 7.35 ± 0.32 |
| gperf 3.0.3 | 10.39 ± 0.16 | 11.75 ± 0.17 | 10.12 ± 0.12 | 9.87 ± 0.13 | 6.06 ± 0.15 | 5.37 ± 0.11 | 6.01 ± 0.14 |
| hash map (FNV-1a, open addr.) | 11.42 ± 0.16 | 15.42 ± 0.15 | 13.69 ± 0.24 | 11.22 ± 0.17 | 8.74 ± 0.14 | 6.69 ± 0.14 | 7.30 ± 0.20 |
| phash + memcmp | 8.06 ± 0.13 | 9.96 ± 0.12 | 8.80 ± 0.16 | 8.42 ± 0.05 | 5.44 ± 0.12 | 4.91 ± 0.12 | 5.50 ± 0.14 |
| phash + 2 words (padded) | 1.75 ± 0.02 | 1.62 ± 0.01 | 2.00 ± 0.02 | 1.79 ± 0.03 | 1.03 ± 0.02 | 1.07 ± 0.03 | 1.06 ± 0.02 |
| phash + NEON, page check | 1.55 ± 0.03 | 1.29 ± 0.02 | 1.52 ± 0.01 | 1.57 ± 0.01 | 0.90 ± 0.02 | 1.09 ± 0.01 | 1.04 ± 0.02 |
| phash + NEON, padded | 1.62 ± 0.04 | 1.27 ± 0.02 | 1.54 ± 0.03 | 1.54 ± 0.02 | 0.87 ± 0.02 | 1.08 ± 0.01 | 1.20 ± 0.03 |

### Time relative to phash + NEON (page check)

| form | methods | headers | jsreserved | json8 | json24 | schemes | renkw |
|---|---:|---:|---:|---:|---:|---:|---:|
| Ren today (== chain) | 6.6x ± 0.2 | 8.8x ± 0.2 | 9.0x ± 0.3 | 6.3x ± 0.0 | 8.0x ± 0.3 | 4.9x ± 0.1 | 7.7x ± 0.3 |
| length switch + memcmp (C) | 6.5x ± 0.2 | 8.8x ± 0.2 | 8.1x ± 0.2 | 6.4x ± 0.1 | 7.8x ± 0.3 | 4.8x ± 0.1 | 7.3x ± 0.3 |
| Rust `match` (rustc) | 5.4x ± 0.2 | 8.3x ± 0.2 | 9.0x ± 0.3 | 4.3x ± 0.2 | 7.7x ± 0.3 | 3.1x ± 0.2 | 7.0x ± 0.3 |
| gperf 3.0.3 | 6.7x ± 0.2 | 9.1x ± 0.2 | 6.6x ± 0.1 | 6.3x ± 0.1 | 6.7x ± 0.2 | 4.9x ± 0.1 | 5.8x ± 0.2 |
| hash map (FNV-1a, open addr.) | 7.4x ± 0.2 | 12.0x ± 0.2 | 9.0x ± 0.2 | 7.2x ± 0.1 | 9.7x ± 0.3 | 6.1x ± 0.1 | 7.0x ± 0.2 |
| phash + memcmp | 5.2x ± 0.1 | 7.7x ± 0.1 | 5.8x ± 0.1 | 5.4x ± 0.1 | 6.1x ± 0.2 | 4.5x ± 0.1 | 5.3x ± 0.2 |
| phash + 2 words (padded) | 1.1x ± 0.0 | 1.3x ± 0.0 | 1.3x ± 0.0 | 1.1x ± 0.0 | 1.1x ± 0.0 | 1.0x ± 0.0 | 1.0x ± 0.0 |
| phash + NEON, page check | 1.0x ± 0.0 | 1.0x ± 0.0 | 1.0x ± 0.0 | 1.0x ± 0.0 | 1.0x ± 0.0 | 1.0x ± 0.0 | 1.0x ± 0.0 |
| phash + NEON, padded | 1.0x ± 0.0 | 1.0x ± 0.0 | 1.0x ± 0.0 | 1.0x ± 0.0 | 1.0x ± 0.0 | 1.0x ± 0.0 | 1.1x ± 0.0 |

### Instructions per lookup (hyperfine counters, minus the empty loop)

| form | methods | headers | jsreserved | json8 | json24 | schemes | renkw |
|---|---:|---:|---:|---:|---:|---:|---:|
| Ren today (== chain) | 25.3 | 31.4 | 50.2 | 23.4 | 32.0 | 22.8 | 41.3 |
| length switch + memcmp (C) | 26.2 | 34.3 | 44.5 | 26.7 | 34.3 | 23.5 | 41.6 |
| Rust `match` (rustc) | 16.7 | 26.3 | 36.7 | 15.7 | 27.6 | 15.5 | 34.0 |
| gperf 3.0.3 | 53.0 | 54.7 | 54.9 | 53.2 | 55.2 | 53.3 | 55.7 |
| hash map (FNV-1a, open addr.) | 76.8 | 98.0 | 79.1 | 79.7 | 92.3 | 66.9 | 71.9 |
| phash + memcmp | 47.7 | 48.6 | 51.6 | 44.8 | 44.1 | 45.6 | 48.4 |
| phash + 2 words (padded) | 25.4 | 27.2 | 34.8 | 27.2 | 35.5 | 25.3 | 28.2 |
| phash + NEON, page check | 27.4 | 27.2 | 33.0 | 27.2 | 32.7 | 27.3 | 30.2 |
| phash + NEON, padded | 24.4 | 24.3 | 30.1 | 24.3 | 29.9 | 24.4 | 27.3 |

### Instructions per cycle

| form | methods | headers | jsreserved | json8 | json24 | schemes | renkw |
|---|---:|---:|---:|---:|---:|---:|---:|
| Ren today (== chain) | 1.0 | 1.1 | 1.4 | 0.9 | 1.0 | 1.0 | 1.2 |
| length switch + memcmp (C) | 1.0 | 1.2 | 1.4 | 1.0 | 1.1 | 1.0 | 1.3 |
| Rust `match` (rustc) | 0.8 | 0.9 | 1.0 | 0.9 | 1.0 | 1.0 | 1.2 |
| gperf 3.0.3 | 2.0 | 1.8 | 2.1 | 2.1 | 2.2 | 2.3 | 2.2 |
| hash map (FNV-1a, open addr.) | 2.6 | 2.4 | 2.2 | 2.7 | 2.5 | 2.3 | 2.3 |
| phash + memcmp | 2.3 | 1.9 | 2.3 | 2.0 | 1.9 | 2.1 | 2.1 |
| phash + 2 words (padded) | 5.6 | 6.4 | 6.7 | 5.8 | 8.7 | 5.9 | 6.6 |
| phash + NEON, page check | 6.8 | 8.1 | 8.3 | 6.6 | 9.1 | 6.3 | 7.2 |
| phash + NEON, padded | 5.8 | 7.3 | 7.5 | 6.0 | 8.7 | 5.7 | 5.7 |

### Cross-check: in-process min of 500 passes, ns per lookup (includes the loop)

| form | methods | headers | jsreserved | json8 | json24 | schemes | renkw |
|---|---:|---:|---:|---:|---:|---:|---:|
| Ren today (== chain) | 9.96 | 10.65 | 12.91 | 10.01 | 7.09 | 5.31 | 7.26 |
| length switch + memcmp (C) | 9.95 | 10.83 | 12.13 | 10.04 | 6.30 | 5.20 | 7.89 |
| Rust `match` (rustc) | 7.73 | 10.76 | 12.18 | 6.90 | 6.44 | 3.46 | 6.19 |
| gperf 3.0.3 | 10.21 | 11.40 | 9.81 | 9.89 | 5.66 | 5.20 | 6.30 |
| hash map (FNV-1a, open addr.) | 11.17 | 15.09 | 13.26 | 11.29 | 8.61 | 6.41 | 7.34 |
| phash + memcmp | 7.95 | 9.84 | 8.76 | 8.56 | 5.49 | 4.78 | 5.66 |
| phash + 2 words (padded) | 1.92 | 1.80 | 2.18 | 1.97 | 1.14 | 1.19 | 1.19 |
| phash + NEON, page check | 1.74 | 1.48 | 1.72 | 1.75 | 1.02 | 1.19 | 1.18 |
| phash + NEON, padded | 1.78 | 1.48 | 1.69 | 1.71 | 0.95 | 1.18 | 1.33 |

### Load (1-minute average) before and after each set

| set | before | after |
|---|---:|---:|
| methods | 3.86 | 3.49 |
| headers | 3.49 | 5.85 |
| jsreserved | 3.80 | 5.20 |
| json8 | 3.98 | 5.72 |
| json24 | 3.95 | 4.75 |
| schemes | 3.55 | 3.67 |
| renkw | 3.67 | 4.49 |
