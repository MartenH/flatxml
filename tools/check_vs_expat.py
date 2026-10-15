#!/usr/bin/env python3
"""Check flatxml against expat: every element, attribute and text run, in order.

    tools/check_vs_expat.py [--ext xml,cfg] bin/flatxml <file|dir>...

For each file, `flatxml dump` and an expat walk below print the same canonical stream:

    E <depth> <name> <attr>=<value>...    per element, attributes in document order
    T <depth> <text>                      per run of text, decoded and trimmed; depth is the
                                          containing element's; empty runs are left out

Values are escaped (backslash, newline, tab, CR). expat runs without namespace processing, so
names and xmlns attributes are compared as written. A directory means every file below it whose
extension is in --ext (default: xml). Exit status 1 if any file differs.
"""
import os
import subprocess
import sys
import xml.parsers.expat


def esc(s):
    return s.replace('\\', '\\\\').replace('\n', '\\n').replace('\t', '\\t').replace('\r', '\\r')


def expat_dump(path):
    out = []
    buf = []
    depth = 0

    def flush():
        t = ''.join(buf).strip(' \t\n\r')
        buf.clear()
        if t:
            out.append(f'T {depth} {esc(t)}')

    def start(name, attrs):
        nonlocal depth
        flush()
        depth += 1
        a = ''.join(f' {attrs[i]}={esc(attrs[i + 1])}' for i in range(0, len(attrs), 2))
        out.append(f'E {depth} {name}{a}')

    def end(name):
        nonlocal depth
        flush()
        depth -= 1

    p = xml.parsers.expat.ParserCreate()
    p.ordered_attributes = True
    p.buffer_text = True
    p.StartElementHandler = start
    p.EndElementHandler = end
    p.CharacterDataHandler = buf.append
    with open(path, 'rb') as f:
        p.ParseFile(f)
    return out


def files_of(paths, exts):
    for p in paths:
        if os.path.isdir(p):
            for root, _, names in os.walk(p):
                for n in sorted(names):
                    if os.path.splitext(n)[1].lower().lstrip('.') in exts:
                        yield os.path.join(root, n)
        else:
            yield p


def main():
    args = sys.argv[1:]
    exts = {'xml'}
    if args[:1] == ['--ext'] and len(args) > 1:
        exts = {e.strip().lower().lstrip('.') for e in args[1].split(',') if e.strip()}
        args = args[2:]
    if len(args) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    flatxml = args[0]
    bad = 0
    n = 0
    for f in files_of(args[1:], exts):
        n += 1
        try:
            want = expat_dump(f)
        except xml.parsers.expat.ExpatError as e:
            want = [f'error: {e}']
        r = subprocess.run([flatxml, 'dump', f], capture_output=True, text=True)
        got = r.stdout.splitlines() if r.returncode == 0 else [f'error: {r.stderr.strip()}']
        if got[:1] and want[:1] and got[0].startswith('error:') and want[0].startswith('error:'):
            print(f'ok    both reject  {f}\n  flatxml: {got[0]}\n  expat:   {want[0]}')
            continue
        if got == want:
            print(f'ok    {len(want):8} lines  {f}')
            continue
        bad += 1
        k = next((i for i, (a, b) in enumerate(zip(got, want)) if a != b), min(len(got), len(want)))
        print(f'DIFF  {f}: first difference at line {k + 1} ({len(got)} vs {len(want)} lines)')
        print(f'  flatxml: {got[k] if k < len(got) else "<end>"}')
        print(f'  expat:   {want[k] if k < len(want) else "<end>"}')
    print(f'{n - bad} of {n} files identical')
    return 1 if bad or n == 0 else 0


if __name__ == '__main__':
    sys.exit(main())
