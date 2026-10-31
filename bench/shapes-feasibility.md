# Stage 12a: feasibility rerun and evaluator-step calibration

Before implementation, against main at `cced5a2`, on the shared Linux
x86-64 host `5c9b45aa54f3`, Intel Xeon Platinum 8573C (five visible CPUs).
The compiler uses OCaml 5.5.2 and Dune 3.24.2. These are measurements of
the existing compiler, not claims that stage 12a is implemented.

Reproduce in the toolchain shell, from the repository root:

```sh
dune build
python3 bench/native/shape-steps.py prepare /tmp/ren-shape-steps
python3 bench/native/shape-steps.py measure /tmp/ren-shape-steps --runs 7 --iterations 5000000
python3 bench/native/shape-steps.py probes /tmp/ren-shape-steps
```

`prepare` copies the compiler to the output directory and adds a counter
there. It changes no compiler source in the checkout. Build that temporary
compiler before timing, and leave other compiler/benchmark jobs idle while
measuring. Raw metadata, diagnostic output, counts, samples and host load are
in [native/shape-steps-baseline](native/shape-steps-baseline/).

## Research probes

The 13 original programs in `research/looks/feas/` were run unchanged.
Companion probes in the temporary output make only the corrections named
below; they do not replace an original result. Declaring `uses Console` in
old `main` signatures changed no result. The complete original and companion
diagnostics are in `probes.json`.

| Probe | Original result | Interpretation / companion result |
|---|---|---|
| `a_default.ren` | success, `hi` | Dependency operation defaults now parse; this probe declares them but does not call the operation. |
| `b_format.ren` | top-level parser rejects `format` | Looks remain absent. |
| `c_let.ren` | top-level parser rejects `let` | Build-time top-level values remain absent. |
| `d_shape.ren` | `P` has no member named `shape` | Type shapes remain absent. |
| `e_generic.ren` | success, `hi` | Generic dependency declarations remain accepted. |
| `f_blockop.ren` | success, `hi` | Dependency operations taking blocks remain accepted; this is not a `D.Call` test. |
| `g_assoc.ren` | success, `x` | Associated values remain accepted; this is not a top-level build-time value. |
| `h_fielddef.ren` | expected comma or closing brace at `=` | Record field defaults remain absent. |
| `i_named.ren` | `Keys.get` can fail and nothing handles it | Adding `try` to the call exposes the intended refusal: `key` isn't passed by name. |
| `j_depparam.ren` | comparisons can't be chained | Explicit dependency type arguments at a call remain absent. |
| `k_tyapp.ren` | comparisons can't be chained | Explicit type arguments at a call remain absent. |
| `v1.ren` | `Str` has no `len` | Replacing `key.len()` with `key.byte_len()` exposes `key` isn't passed by name. |
| `v2.ren` | comparisons can't be chained | The additional explicit-type-argument probe remains refused. |

The `i_named` and `v1` failures show why only reporting the first diagnostic
would overstate the services-stage changes. No research probe was edited.

## Fixed step default

Choose **64,100,000 steps per value and per signature-let site**. This
number is fixed in the specification, not recomputed while building.
It is calibrated to about one second of ordinary interpreted arithmetic on
this machine; it is not a wall-time deadline for arbitrary builtin work.

The counter charges one step immediately before evaluating each Core
expression. `tail` charges for the branches it handles itself (`If`, `Let`,
`Seq`, `Match` and a tail-eligible `Call`). Its fallback delegates to `eval`
and is charged there once. Unselected branches cost nothing; a loop's
condition and body are evaluated and charged each time. In the eventual
budgeted evaluator the first attempted step past the limit must fail.

The calibration program is an arithmetic loop accumulating `(total + i) %
65521`, then printing its checksum. The zero-iteration control is the same
program. Seven rotated/interleaved pairs ran after both paths warmed, with no
other local compiler or benchmark job active. Each full run evaluated
**65,000,059 steps** and each control **59**, identically in every run.

| Quantity | Median | Minimum–maximum |
|---|---:|---:|
| Full 5,000,000-iteration process, seconds | 1.095292 | 1.073738–1.183472 |
| Zero-iteration process, seconds | 0.081712 | 0.077341–0.098528 |
| Steps/second after paired startup subtraction | 64,129,137 | 59,910,944–65,347,377 |

Rounding the measured median to 100,000 steps gives the chosen fixed default.
The one-minute host load was 1.593 at the start and 1.501 at the end; every
before/after sample is recorded in `measurement.json`. A preliminary
500,000-iteration run was too short relative to command startup; it is kept
in `measurement-pilot.json` but does not determine the default.

The temporary instrumentation is not the build-time implementation. Step 2
must install the per-root budget and demonstrate deterministic limit failures;
that condition remains pending.
