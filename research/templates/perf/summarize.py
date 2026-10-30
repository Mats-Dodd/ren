# Prints perf.md's tables from results/*.json (hyperfine 1.19+, which
# records wall time, cycles and instructions for every run).
# Per op = (run - the same binary at n=0) / 1e7. Ratio = median ns/op over
# the reference's median; the bracket is min..max of the variant's runs
# over the reference's median.
import json, os, statistics as st
R = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'results')
N = 1e7
def load(g):
    return {r['name']: r for r in json.load(open(f'{R}/{g}.json'))['results']}
def col(r, k): return [m[k]['value'] for m in r['measurements']]
base = load('base')
def b(name, k):
    return st.median(col(base['rust-n0' if name.startswith('rust') or name.startswith('ren-') else 'c-n0'], k))
ref = {'log': 'rust-log-write', 'sql': 'rust-sql-reuse', 'html': 'rust-html-write'}
allocs = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'allocs.json')))
for g in ['log', 'sql', 'html']:
    rs = load(g)
    rr = rs[ref[g]]
    rmed = (st.median(col(rr, 'time_wall_clock')) - b(ref[g], 'time_wall_clock')) * 1e9 / N
    print(f'\n### {g} (ratio against {ref[g]})\n')
    print('| variant | ns/op | runs min-max | ratio [min-max] | allocs/op | instr/op | cycles/op |')
    print('|---|---|---|---|---|---|---|')
    for name, r in rs.items():
        t = [(x - b(name, 'time_wall_clock')) * 1e9 / N for x in col(r, 'time_wall_clock')]
        med = st.median(t)
        ins = (st.median(col(r, 'instructions')) - b(name, 'instructions')) / N
        cyc = (st.median(col(r, 'cpu_cycles')) - b(name, 'cpu_cycles')) / N
        print(f'| {name} | {med:.1f} | {min(t):.1f}-{max(t):.1f} | {med/rmed:.2f} [{min(t)/rmed:.2f}-{max(t)/rmed:.2f}] | {allocs.get(name, "")} | {ins:.0f} | {cyc:.0f} |')
