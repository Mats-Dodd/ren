import json, math, sys, os
V = os.path.dirname(os.path.abspath(__file__))
L = 500 * 65536
forms = ['chain','lenswitch','rust','gperf','hmap','ph_memcmp','ph_word','ph_neon','ph_pad']
def load(d, k):
    p = f'{d}/{k}.json'
    if not os.path.exists(p): return None
    r = {x['name']: x for x in json.load(open(p))['results']}
    nul = r['null']; out = {}
    for f in forms:
        m = (r[f]['summary']['time_wall_clock']['mean'] - nul['summary']['time_wall_clock']['mean']) / L * 1e9
        sd = math.sqrt(r[f]['summary']['time_wall_clock']['stddev']**2 + nul['summary']['time_wall_clock']['stddev']**2) / L * 1e9
        out[f] = (m, sd)
    return out
sets = sys.argv[1].split(',')
print('| set | form | theirs ns | mine ns | mine/theirs | theirs x vs ph_neon | mine x vs ph_neon |')
print('|---|---|---:|---:|---:|---:|---:|')
for k in sets:
    t = load(V + '/../code/out', k); m = load(V + '/bench/out', k)
    if not m: continue
    for f in forms:
        (a, sa), (b, sb) = t[f], m[f]
        rt = a / t['ph_neon'][0]; rm = b / m['ph_neon'][0]
        rms = rm * math.sqrt((sb/b)**2 + (m['ph_neon'][1]/m['ph_neon'][0])**2)
        print(f'| {k} | {f} | {a:.2f} ± {sa:.2f} | {b:.2f} ± {sb:.2f} | {b/a:.2f} | {rt:.1f}x | {rm:.1f}x ± {rms:.1f} |')
