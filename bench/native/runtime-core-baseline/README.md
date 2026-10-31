# Runtime-core step 0 records

- `97a1529/`: current sequential native baseline after the upstream bytes-runtime changes, 22 programs including `streams`, five rotated timed runs each. The current reference executable hash is in `build-metadata.json`; `kernels-metadata.json` hashes the copied executable actually used.
- `12da2291/`: unchanged historical records: the original 21-program native baseline, eleven interpreter workloads at 1,000 seeds, and X1/X5 measurements.
- `97a1529/retained-inputs.json`: matching tracked-source fingerprints justify retaining the original interpreter and frame references without rerunning unchanged inputs. It specifies the selected paths and digest method.

All timestamps are UTC. The client-facing measurement date is 2026-10-30 in America/Los_Angeles. Commands, stdout, exit status and load observations are stored in the JSONL files. See [RESULTS.md](../RESULTS.md#runtime-core-stage-step-0-baseline) for methods, tables and limitations.
