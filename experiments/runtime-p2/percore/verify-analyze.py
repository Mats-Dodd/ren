import sys,re,statistics as st
from collections import defaultdict,OrderedDict
reps=OrderedDict(); loads=defaultdict(list); ok=defaultdict(set); sus=defaultdict(list)
M=['mops','p50_ns','p99_ns','p999_ns','light_p50_ns','light_p99_ns','light_p999_ns','heavy_p50_ns','heavy_p99_ns','work_us_mean']
for f in sys.argv[1:]:
  for l in open(f):
    m=re.match(r'LOAD tag=(\S+) load1_(\w+)=(\S+)',l)
    if m: loads[m[1]].append(m[2]+'='+m[3]); continue
    m=re.match(r'REP tag=(\S+) (.*)',l)
    if not m: continue
    t=m[1]; d=dict(re.findall(r' (\w+)=([^ ]+)',' '+m[2]))
    reps.setdefault(t,[]).append(d); ok[t].add(d.get('ok')); sus[t].append(d.get('sustained'))
for t,rs in reps.items():
  print(f'== {t} n={len(rs)} ok={ok[t]} sustained={"".join(x or "?" for x in sus[t])} load={" ".join(loads[t])}')
  for k in M:
    v=[float(r[k]) for r in rs if k in r]
    if not v: continue
    md=st.median(v); sp=(max(v)-min(v))/md if md else 0
    print(f'   {k:14s} med={md:.4g} min={min(v):.4g} max={max(v):.4g} spread={sp:.3f}{" NOISY" if sp>0.10 else ""}')
