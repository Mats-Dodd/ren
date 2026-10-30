# verify/results -> tables. Per op = (run - same binary at n=0)/1e7.
# Ratio = median over reference median; bracket = (min,max) of variant over ref median.
# Also a cycles ratio, which survives clock changes under load.
import json, os, sys, statistics as st
R = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'results')
N = 1e7
def load(g): return {r['name']: r for r in json.load(open(f'{R}/{g}.json'))['results']}
def col(r, k): return [m[k]['value'] for m in r['measurements']]
base = load('base')
def b(name, k): return st.median(col(base['rust-n0' if name.startswith(('rust', 'ren-')) else 'c-n0'], k))
ref = {'log2': 'rust-log-write', 'log': 'rust-log-write', 'sql': 'rust-sql-reuse', 'html': 'rust-html-write'}
for g in sys.argv[1:] or ['log', 'sql', 'html']:
    rs = load(g); rr = rs[ref[g]]
    rmed = (st.median(col(rr, 'time_wall_clock')) - b(ref[g], 'time_wall_clock')) * 1e9 / N
    rcyc = (st.median(col(rr, 'cpu_cycles')) - b(ref[g], 'cpu_cycles')) / N
    print(f'\n### {g} (against {ref[g]})\n')
    print('| variant | ns/op | ratio [min-max] | cycles/op | cycle ratio | instr/op |')
    print('|---|---|---|---|---|---|')
    for name, r in rs.items():
        t = [(x - b(name, 'time_wall_clock')) * 1e9 / N for x in col(r, 'time_wall_clock')]
        med = st.median(t)
        ins = (st.median(col(r, 'instructions')) - b(name, 'instructions')) / N
        cyc = (st.median(col(r, 'cpu_cycles')) - b(name, 'cpu_cycles')) / N
        print(f'| {name} | {med:.1f} | {med/rmed:.2f} [{min(t)/rmed:.2f}-{max(t)/rmed:.2f}] | {cyc:.0f} | {cyc/rcyc:.2f} | {ins:.0f} |')
