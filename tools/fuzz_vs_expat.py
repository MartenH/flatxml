#!/usr/bin/env python3
"""Mutation fuzzing against expat: edit seed documents at random and compare the two parsers.

    tools/fuzz_vs_expat.py [--ns] [--count N] [--seed S] [--keep DIR] bin/flatxml <seed.xml>...

Each case applies one to three random edits to a seed (delete a span, duplicate a span, insert a
markup token, replace a byte, rename a namespace prefix, drop a namespace declaration) and runs `flatxml dump` and expat over the result, as
tools/check_vs_expat.py does. With --ns, both resolve namespaces. Outcomes:

    same       both accept with identical output, or both reject
    lenient    flatxml accepts what expat rejects: one of the documented leniencies (names,
               UTF-8 and the XML declaration are not validated, duplicate attributes are accepted)
    ns-lenient with --ns: flatxml accepts a document expat accepts without namespaces and
               rejects with them, for one of the documented reasons: a part of a qualified name
               that is not a name (`p:1a`), or a colon in a processing-instruction target or a
               DTD declaration, which flatxml skips
    REFUSED    flatxml rejects a document expat accepts
    DIFFERENT  both accept, with different output
    NS-MISSED  as ns-lenient, but expat rejects it for another reason: a namespace rule not applied
    CRASH      flatxml died (a signal or a V panic) instead of accepting or rejecting

The capitalised outcomes are written to --keep (default: fuzz-failures/) and make the exit
status 1. The same seed gives the same cases.
"""
import os
import random
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_vs_expat import REJECTED, expat_dump  # noqa: E402
import xml.parsers.expat  # noqa: E402

TOKENS = [b'<', b'>', b'/', b'"', b"'", b'=', b':', b'&', b';', b'&amp;', b'&#65;', b'<a>', b'</a>',
          b'<a/>', b'<!-- c -->', b'<![CDATA[x]]>', b'<?pi x?>', b' xmlns="urn:m"',
          b' xmlns:p="urn:p"', b' xmlns:q=""', b' p:k="1"', b' q:k="1"', b'p:', b'xmlns:',
          b' xml:lang="en"', b' k="1"', b'\n', b' ', b'\xc3\xa9', b'\xff']


def expat_error(path):
    try:
        expat_dump(path, True)
        return None
    except REJECTED as e:
        return e


def documented_ns_leniency(doc, path):
    """Whether expat's namespace-mode error is one flatxml documents not checking: it lies in a
    processing instruction or a DTD declaration, or in a qualified name with a part that does
    not start like a name."""
    e = expat_error(path)
    if not isinstance(e, xml.parsers.expat.ExpatError):
        return False
    lines = doc.split(b'\n')
    if e.lineno < 1 or e.lineno > len(lines):
        return False
    pos = sum(len(line) + 1 for line in lines[:e.lineno - 1]) + e.offset
    lt = doc.rfind(b'<', 0, pos + 1)
    if lt >= 0 and (doc.startswith(b'<?', lt) or (doc.startswith(b'<!', lt)
                                                 and not doc.startswith(b'<!--', lt)
                                                 and not doc.startswith(b'<![CDATA[', lt))):
        return True
    # the name around the error position
    stop = b' \t\r\n<>/="\''
    a = pos
    while a > 0 and doc[a - 1:a] not in (b'',) and doc[a - 1] not in stop:
        a -= 1
    b = pos
    while b < len(doc) and doc[b] not in stop:
        b += 1
    name = doc[a:b]
    return b':' in name and any(part[:1] and part[:1] in b'0123456789-.' for part in name.split(b':'))


def expat_accepts(path):
    try:
        expat_dump(path, False)
        return True
    except REJECTED:
        return False


PREFIXED = re.compile(rb'(?<=[<\s/:])[A-Za-z_][\w.-]*:(?=[A-Za-z_])')
DECLARATION = re.compile(rb'\s+xmlns(?::[\w.-]+)?\s*=\s*("[^"]*"|\'[^\']*\')')
PREFIXES = [b'p:', b'q:', b'b:', b'z:', b'xml:', b'xmlns:']


def mutate(rng, doc):
    b = bytearray(doc)
    for _ in range(rng.randint(1, 3)):
        if not b:
            b += rng.choice(TOKENS)
            continue
        # namespace edits keep the document well-formed, so they reach the namespace rules
        op = rng.randrange(6)
        if op == 4:
            # rename one prefix at every use, so start and end tags still match
            found = PREFIXED.findall(bytes(b))
            if found:
                old, new = rng.choice(found), rng.choice(PREFIXES)
                b = bytearray(PREFIXED.sub(lambda m: new if m.group() == old else m.group(), bytes(b)))
                continue
            op = rng.randrange(4)
        elif op == 5:
            found = list(DECLARATION.finditer(bytes(b)))
            if found:
                m = rng.choice(found)
                del b[m.start():m.end()]
                continue
            op = rng.randrange(4)
        i = rng.randrange(len(b) + 1)
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
    tally = {'same': 0, 'lenient': 0, 'ns-lenient': 0, 'REFUSED': 0, 'DIFFERENT': 0,
             'NS-MISSED': 0, 'CRASH': 0}
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
        if r.returncode not in (0, 1) or 'panic' in r.stderr:
            kind = 'CRASH'
        elif got == want:
            kind = 'same'
        elif want is None and ns and expat_accepts(tmp):
            kind = 'ns-lenient' if documented_ns_leniency(doc, tmp) else 'NS-MISSED'
        elif want is None:
            kind = 'lenient'
        elif got is None:
            kind = 'REFUSED'
        else:
            kind = 'DIFFERENT'
        tally[kind] += 1
        if kind.isupper():
            path = os.path.join(keep, f'{kind.lower()}-{seed}-{n}.xml')
            with open(path, 'wb') as f:
                f.write(doc)
            why = f'\n  flatxml: {r.stderr.strip()[:300]}' if got is None else ''
            if kind == 'NS-MISSED':
                why = f'\n  expat: {expat_error(tmp)}'
            print(f'{kind}  {path}{why}')
    os.remove(tmp)
    print(f'{count} cases (seed {seed}{", namespaces" if ns else ""}): '
          + ', '.join(f'{v} {k}' for k, v in tally.items()))
    return 1 if any(v for k, v in tally.items() if k.isupper()) else 0


if __name__ == '__main__':
    sys.exit(main())
