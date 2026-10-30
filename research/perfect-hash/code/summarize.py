import json, re, sys, math, os
os.chdir(os.path.dirname(os.path.abspath(__file__)))
REPS, NQ = 500, 65536
L = REPS * NQ
sets = sys.argv[1].split(',')
forms = ['chain','lenswitch','rust','gperf','hmap','ph_memcmp','ph_word','ph_neon','ph_pad']
names = {'chain':'Ren today (== chain)','lenswitch':'length switch + memcmp (C)','rust':'Rust `match` (rustc)','gperf':'gperf 3.0.3','hmap':'hash map (FNV-1a, open addr.)','ph_memcmp':'phash + memcmp','ph_word':'phash + 2 words (padded)','ph_neon':'phash + NEON, page check','ph_pad':'phash + NEON, padded'}
internal = {}
for line in open('out/internal.txt'):
    m = re.match(r'(\S+) (\S+) .*? ([\d.]+) ns/lookup.*?(\d+)\s+instructions retired\s+(\d+)\s+cycles elapsed', line)
    if m: internal[(m[1], m[2])] = (float(m[3]), int(m[4]), int(m[5]))
loads = {}
for line in open('out/loads.txt'):
    k, kv = line.split(); loads.setdefault(k, []).append(kv.split('=')[1])
res = {}
for k in sets:
    d = {r['name']: r['summary'] for r in json.load(open(f'out/{k}.json'))['results']}
    null = d['null']
    for f in forms:
        r = d[f]
        w, nw = r['time_wall_clock'], null['time_wall_clock']
        ns = (w['mean'] - nw['mean']) / L * 1e9
        sd = math.sqrt(w['stddev']**2 + nw['stddev']**2) / L * 1e9
        ins = (r['instructions']['mean'] - null['instructions']['mean']) / L
        cyc = (r['cpu_cycles']['mean'] - null['cpu_cycles']['mean']) / L
        res[(k, f)] = (ns, sd, ins, internal.get((k, f), (float('nan'),))[0], cyc)
def table(metric):
    out = '| form | ' + ' | '.join(sets) + ' |\n|---|' + '---:|' * len(sets) + '\n'
    for f in forms:
        cells = []
        for k in sets:
            ns, sd, ins, inn, cyc = res[(k, f)]
            base = res[(k, 'ph_neon')]
            if metric == 'ns': cells.append(f'{ns:.2f} ± {sd:.2f}')
            elif metric == 'ratio':
                rt = ns / base[0]; rsd = rt * math.sqrt((sd/ns)**2 + (base[1]/base[0])**2)
                cells.append(f'{rt:.1f}x ± {rsd:.1f}')
            elif metric == 'ins': cells.append(f'{ins:.1f}')
            elif metric == 'ipc': cells.append(f'{ins/cyc:.1f}')
            elif metric == 'int': cells.append(f'{inn:.2f}')
        out += f'| {names[f]} | ' + ' | '.join(cells) + ' |\n'
    return out
print('### ns per lookup (hyperfine mean minus the empty loop, ± combined stddev)\n'); print(table('ns'))
print('### Time relative to phash + NEON (page check)\n'); print(table('ratio'))
print('### Instructions per lookup (hyperfine counters, minus the empty loop)\n'); print(table('ins'))
print('### Instructions per cycle\n'); print(table('ipc'))
print('### Cross-check: in-process min of 500 passes, ns per lookup (includes the loop)\n'); print(table('int'))
print('### Load (1-minute average) before and after each set\n')
print('| set | before | after |\n|---|---:|---:|')
for k in sets: print(f'| {k} | ' + ' | '.join(loads.get(k, ['?','?'])) + ' |')
