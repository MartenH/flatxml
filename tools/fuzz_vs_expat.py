#!/usr/bin/env python3
"""Mutation fuzzing against expat: edit seed documents at random and compare the two parsers.

    tools/fuzz_vs_expat.py [--ns] [--count N] [--seed S] [--keep DIR] bin/flatxml <seed.xml>...

Each case applies one to three random edits to a seed (delete a span, duplicate a span, insert a
markup token, replace a byte) and runs `flatxml dump` and expat over the result, as
tools/check_vs_expat.py does. With --ns, both resolve namespaces. Outcomes:

    same       both accept with identical output, or both reject
    lenient    flatxml accepts what expat rejects: one of the documented leniencies (names,
               UTF-8 and the XML declaration are not validated, duplicate attributes are accepted)
    REFUSED    flatxml rejects a document expat accepts
    DIFFERENT  both accept, with different output
    ns-lenient with --ns: flatxml accepts a document expat accepts without namespaces and
               rejects with them. Printed with expat's reason, for review: the known causes are
               the parts of a qualified name not being validated (`p:1a`), and colons in a
               processing-instruction target or a DTD declaration, which flatxml skips.

REFUSED and DIFFERENT cases are written to --keep (default: fuzz-failures/) and make the exit
status 1; ns-lenient cases are written there too. The same seed gives the same cases.
"""
import os
import random
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_vs_expat import REJECTED, expat_dump  # noqa: E402

TOKENS = [b'<', b'>', b'/', b'"', b"'", b'=', b':', b'&', b';', b'&amp;', b'&#65;', b'<a>', b'</a>',
          b'<a/>', b'<!-- c -->', b'<![CDATA[x]]>', b'<?pi x?>', b' xmlns="urn:m"',
          b' xmlns:p="urn:p"', b' xmlns:q=""', b' p:k="1"', b' q:k="1"', b'p:', b'xmlns:',
          b' xml:lang="en"', b' k="1"', b'\n', b' ', b'\xc3\xa9', b'\xff']


def expat_reason(path):
    try:
        expat_dump(path, True)
        return ''
    except REJECTED as e:
        return str(e)


def expat_accepts(path):
    try:
        expat_dump(path, False)
        return True
    except REJECTED:
        return False


def mutate(rng, doc):
    b = bytearray(doc)
    for _ in range(rng.randint(1, 3)):
        if not b:
            b += rng.choice(TOKENS)
            continue
        i = rng.randrange(len(b) + 1)
        op = rng.randrange(4)
        if op == 0:
            del b[i:i + rng.randint(1, 8)]
        elif op == 1:
            j = min(len(b), i + rng.randint(1, 24))
            b[i:i] = b[i:j]
        elif op == 2:
            b[i:i] = rng.choice(TOKENS)
        elif i < len(b):
            b[i] = rng.randrange(256)
    return bytes(b)


def main():
    args = sys.argv[1:]
    ns, count, seed, keep = False, 1000, 1, 'fuzz-failures'
    while args and args[0].startswith('--'):
        flag = args.pop(0)
        if flag == '--ns':
            ns = True
        elif flag == '--count':
            count = int(args.pop(0))
        elif flag == '--seed':
            seed = int(args.pop(0))
        elif flag == '--keep':
            keep = args.pop(0)
        else:
            print(__doc__.strip(), file=sys.stderr)
            return 2
    if len(args) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    flatxml, seeds = args[0], [open(p, 'rb').read() for p in args[1:]]
    rng = random.Random(seed)
    tally = {'same': 0, 'lenient': 0, 'ns-lenient': 0, 'REFUSED': 0, 'DIFFERENT': 0}
    tmp = os.path.join(keep, 'case.xml')
    os.makedirs(keep, exist_ok=True)
    # Run every case through both parsers and classify the outcome.
    for n in range(count):
        doc = mutate(rng, rng.choice(seeds))
        with open(tmp, 'wb') as f:
            f.write(doc)
        try:
            want = expat_dump(tmp, ns)
        except REJECTED:
            want = None
        r = subprocess.run([flatxml, 'dump'] + (['--ns'] if ns else []) + [tmp], capture_output=True,
                           text=True, encoding='utf-8', errors='replace')
        out = r.stdout[:-1] if r.stdout.endswith('\n') else r.stdout
        got = (out.split('\n') if out else []) if r.returncode == 0 else None
        if got == want or (got is None and want is None):
            kind = 'same'
        elif want is None:
            kind = 'ns-lenient' if ns and expat_accepts(tmp) else 'lenient'
        elif got is None:
            kind = 'REFUSED'
        else:
            kind = 'DIFFERENT'
        tally[kind] += 1
        if kind in ('REFUSED', 'DIFFERENT', 'ns-lenient'):
            path = os.path.join(keep, f'{kind.lower()}-{seed}-{n}.xml')
            with open(path, 'wb') as f:
                f.write(doc)
            why = f'\n  flatxml: {r.stderr.strip()}' if got is None else ''
            if kind == 'ns-lenient':
                why = f'\n  expat: {expat_reason(tmp)}'
            print(f'{kind}  {path}{why}')
    os.remove(tmp)
    print(f'{count} cases (seed {seed}{", namespaces" if ns else ""}): '
          + ', '.join(f'{v} {k}' for k, v in tally.items()))
    return 1 if tally['REFUSED'] or tally['DIFFERENT'] else 0


if __name__ == '__main__':
    sys.exit(main())
