import random, sys, os
random.seed(7)
d = sys.argv[1]
def w(name, keys):
    keys = list(dict.fromkeys(keys))
    with open(os.path.join(d, name + '.hex'), 'w') as f:
        for k in keys:
            b = k.encode() if isinstance(k, str) else k
            f.write((b.hex() if b else '.') + '\n')
P = 'application/vnd.ren.'
w('prefix', [P + s for s in ['a','b','ab','ba','abc','json','jsonl','xml','x','y','z','zz','zzz','csv','tsv','proto','protob','msgpack','cbor','bson']] + [P[:k] for k in (1,2,5,8,15,16,17)])
base20 = 'x' * 20
w('past16', [base20 + s for s in ['aaaa','aaab','aaba','abaa','baaa','zzzz','zzzy','0000']] + ['y' * 15 + c for c in 'abcdefgh'] + ['y'*16 + c for c in 'abcd'] + ['q'*17, 'q'*18, 'q'*19])
w('past16b', ['k' * 16 + s for s in ['', 'a', 'b', 'aa', 'ab', 'ba', 'bb', 'aaa', 'zzz', 'a'*10, 'b'*10]])
w('empty', ['', 'a', 'b', 'ab', 'ba', 'GET', 'PUT', 'x' * 16, 'x' * 17])
w('emptyonly', [''])
w('emptypair', ['', 'z'])
rnd = set()
al = 'abcdefghijklmnopqrstuvwxyz_0123456789'
while len(rnd) < 200:
    rnd.add(''.join(random.choice(al) for _ in range(random.randint(1, 24))))
w('k200', sorted(rnd))
w('k200prefix', ['user.settings.' + str(i) for i in range(200)])
w('k200short', sorted({''.join(random.choice('ab') for _ in range(random.randint(1,9))) for _ in range(5000)})[:200])
w('utf8', ['café', 'cafe', 'cafè', 'naïve', 'naive', '日本', '日本語', '日本人', '😀', '😁', 'Ünïcödé', 'é', 'è', 'ß', 'ss', 'Straße', 'Strasse', 'Привет', 'привет', 'ﬁ', 'fi', ' ', ' ', 'á', 'á', 'αβγδεζηθικλμνξο'])
w('lenonly', ['a', 'bb', 'ccc', 'dddd', 'eeeee', 'f'*16, 'g'*17, 'h'*40])
w('long300', ['L' * 300, 'L' * 44, 'short', 'L' * 299])
w('long255', ['M' * 255, 'abc', 'abd'])
