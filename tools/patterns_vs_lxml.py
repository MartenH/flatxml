#!/usr/bin/env python3
"""Compare flatxml's pattern engine with libxml2's, string by string.

    tools/patterns_vs_lxml.py [--per N] [--seed S] [--show N] bin/flatxml <xsd file|dir>...

Collects every xsd:pattern in the given schema documents (a directory means every .xsd below it)
and, for each pattern, builds strings to try: ones made to match (from Python's parse of the
pattern, where its syntax allows: no \\p{...}, no class subtraction), near misses of those (a
character deleted, inserted or changed), and random ones. Each string is matched by
`flatxml match --batch` and validated by lxml against a one-element schema with the pattern.

Prints, per outcome, how many patterns or strings: both compile or both refuse the pattern, and
for strings, both match or both reject; the disagreements are listed (--show, default 20).
libxml2 is a second opinion, not the truth: a disagreement is a question to settle against the
specification (XSD 1.0 Part 2, appendix F).
"""
import os
import random
import re
import subprocess
import sys
import warnings
import xml.etree.ElementTree as ET

# Python warns about `[` and `--` in classes, which are XSD's syntax, not mistakes
warnings.simplefilter('ignore', FutureWarning)

try:
    import re._parser as sre_parse  # Python 3.11+
    import re._constants as sre_c
except ImportError:  # pragma: no cover
    import sre_parse
    import sre_constants as sre_c

XS = '{http://www.w3.org/2001/XMLSchema}'
ALPHABET = 'aAbBzZ09_-.:/ +éÉ٣Ⅷ!?*()[]{}|\\^$€中'


def patterns_in(paths):
    found = []
    seen = set()
    for p in paths:
        files = [p]
        if os.path.isdir(p):
            files = [os.path.join(r, n) for r, _, ns in os.walk(p) for n in sorted(ns)
                     if n.endswith('.xsd')]
        for f in files:
            try:
                root = ET.parse(f).getroot()
            except Exception:
                continue
            for el in root.iter(XS + 'pattern'):
                v = el.get('value')
                if v is not None and v not in seen:
                    seen.add(v)
                    found.append(v)
    return found


def xml_safe(s):
    return all((c >= ' ' or False) and c not in '￾￿' and not ('\ud800' <= c <= '\udfff')
               for c in s) and '\t' not in s


def esc(s, attr=False):
    s = s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
    return s.replace('"', '&quot;') if attr else s


def as_python(pattern):
    """The pattern in Python's syntax, where the two agree; None where they do not."""
    if '\\p' in pattern or '\\P' in pattern or re.search(r'-\[', pattern) or '\\i' in pattern \
            or '\\c' in pattern:
        return None
    out, in_class = [], False
    i = 0
    while i < len(pattern):
        c = pattern[i]
        if c == '\\' and i + 1 < len(pattern):
            out.append(pattern[i:i + 2])
            i += 2
            continue
        if c == '[' and not in_class:
            in_class = True
        elif c == ']' and in_class:
            in_class = False
        elif c in '^$' and not in_class:
            out.append('\\' + c)  # literals in XSD, anchors in Python
            i += 1
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def generate(rng, tree, depth=0):
    """A random string matching a parsed Python pattern."""
    out = []
    for op, av in tree:
        if op == sre_c.LITERAL:
            out.append(chr(av))
        elif op == sre_c.NOT_LITERAL:
            out.append(rng.choice([c for c in ALPHABET if ord(c) != av]))
        elif op == sre_c.ANY:
            out.append(rng.choice(ALPHABET.replace('\n', '')))
        elif op == sre_c.IN:
            out.append(pick_in(rng, av))
        elif op in (sre_c.MAX_REPEAT, sre_c.MIN_REPEAT):
            lo, hi, sub = av
            hi = min(hi, lo + 3) if hi != sre_c.MAXREPEAT else lo + 3
            for _ in range(rng.randint(lo, hi)):
                out.append(generate(rng, sub, depth + 1))
        elif op == sre_c.SUBPATTERN:
            out.append(generate(rng, av[-1], depth + 1))
        elif op == sre_c.BRANCH:
            out.append(generate(rng, rng.choice(av[1]), depth + 1))
        else:
            raise ValueError(f'cannot generate {op}')
    return ''.join(out)


def pick_in(rng, items):
    negate = items and items[0][0] == sre_c.NEGATE
    if negate:
        cands = [c for c in ALPHABET if not in_items(c, items[1:])]
        return rng.choice(cands) if cands else 'a'
    op, av = rng.choice(items)
    if op == sre_c.LITERAL:
        return chr(av)
    if op == sre_c.RANGE:
        return chr(rng.randint(av[0], min(av[1], av[0] + 200)))
    if op == sre_c.CATEGORY:
        return {sre_c.CATEGORY_DIGIT: '7', sre_c.CATEGORY_SPACE: ' ', sre_c.CATEGORY_WORD: 'w',
                sre_c.CATEGORY_NOT_DIGIT: 'x', sre_c.CATEGORY_NOT_SPACE: 's',
                sre_c.CATEGORY_NOT_WORD: '!'}.get(av, 'a')
    return 'a'


def in_items(c, items):
    for op, av in items:
        if op == sre_c.LITERAL and ord(c) == av:
            return True
        if op == sre_c.RANGE and av[0] <= ord(c) <= av[1]:
            return True
    return False


def candidates(rng, pattern, per):
    found = set()
    py = as_python(pattern)
    tree = None
    if py is not None:
        try:
            tree = sre_parse.parse(py)
        except Exception:
            tree = None
    for _ in range(per):
        if tree is not None:
            try:
                s = generate(rng, tree)
                found.add(s)
                if s:
                    k = rng.randrange(len(s))
                    found.add(s[:k] + s[k + 1:])
                    found.add(s[:k] + rng.choice(ALPHABET) + s[k:])
                    found.add(s[:k] + rng.choice(ALPHABET) + s[k + 1:])
            except (ValueError, RecursionError):
                tree = None
        found.add(''.join(rng.choice(ALPHABET) for _ in range(rng.randint(0, 6))))
    return sorted(s for s in found if xml_safe(s) and '\n' not in s and '\r' not in s)


def lxml_schema(pattern):
    from lxml import etree
    xsd = ('<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"><xs:element name="v">'
           '<xs:simpleType><xs:restriction base="xs:string">'
           f'<xs:pattern value="{esc(pattern, True)}"/></xs:restriction></xs:simpleType>'
           '</xs:element></xs:schema>')
    try:
        return etree.XMLSchema(etree.fromstring(xsd.encode()))
    except Exception:
        return None


def main():
    args = sys.argv[1:]
    per, seed, show = 25, 1, 20
    while args and args[0].startswith('--'):
        flag = args.pop(0)
        value = int(args.pop(0))
        per, seed, show = (value, seed, show) if flag == '--per' else \
            (per, value, show) if flag == '--seed' else (per, seed, value)
    if len(args) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    from lxml import etree
    flatxml, paths = args[0], args[1:]
    rng = random.Random(seed)
    pats = [p for p in patterns_in(paths) if '\t' not in p and '\n' not in p and '\r' not in p]
    work = []  # (pattern index, string)
    for k, p in enumerate(pats):
        work.append((k, ''))  # the empty string: also how flatxml says whether it compiles
        work.extend((k, s) for s in candidates(rng, p, per))
    proc = subprocess.run([flatxml, 'match', '--batch'], capture_output=True, text=True,
                          encoding='utf-8', errors='replace',
                          input=''.join(f'{pats[k]}\t{s}\n' for k, s in work))
    # newlines only: a quoted value may hold characters splitlines() also breaks on
    answers = proc.stdout.split('\n')[:-1] if proc.stdout else []
    if proc.returncode != 0 or len(answers) != len(work):
        sys.exit(f'flatxml match --batch failed after {len(answers)} of {len(work)} lines\n'
                 + proc.stderr[-2000:])
    schemas = [lxml_schema(p) for p in pats]
    tally = {'both compile': 0, 'both refuse': 0, 'only lxml compiles': 0,
             'only flatxml compiles': 0, 'flatxml refuses as unsupported': 0}
    strings = {'agree': 0, 'lxml failed': 0, 'DISAGREE': 0}
    diffs = []
    fx_compiles = {}
    # Each pattern's compile verdicts, then each string's match verdicts where both compile.
    for (k, s), a in zip(work, answers):
        if k not in fx_compiles:
            fx_compiles[k] = not a.startswith('error')
            lx = schemas[k] is not None
            if not fx_compiles[k] and 'not supported' in a:
                tally['flatxml refuses as unsupported'] += 1
            elif fx_compiles[k] and lx:
                tally['both compile'] += 1
            elif not fx_compiles[k] and not lx:
                tally['both refuse'] += 1
            elif lx:
                tally['only lxml compiles'] += 1
                diffs.append(f'only lxml compiles  {pats[k]!r}\n    flatxml: {a}')
            else:
                tally['only flatxml compiles'] += 1
                diffs.append(f'only flatxml compiles  {pats[k]!r}')
        if not fx_compiles[k] or schemas[k] is None:
            continue
        mine = a == 'yes'
        try:
            theirs = schemas[k].validate(etree.fromstring(f'<v>{esc(s)}</v>'.encode()))
        except etree.LxmlError as e:
            strings['lxml failed'] += 1
            diffs.append(f'lxml failed on {pats[k]!r} with {s!r}: {e}')
            continue
        if mine == theirs:
            strings['agree'] += 1
        else:
            strings['DISAGREE'] += 1
            diffs.append(f'{pats[k]!r} on {s!r}: flatxml {"matches" if mine else "rejects"}, '
                         f'lxml {"accepts" if theirs else "rejects"}')
    print(f'{len(pats)} patterns: ' + ', '.join(f'{v} {k}' for k, v in tally.items()))
    print(f'{sum(strings.values())} strings where both compile: '
          + ', '.join(f'{v} {k}' for k, v in strings.items()))
    for d in diffs[:show]:
        print('  ' + d)
    return 1 if strings['DISAGREE'] else 0


if __name__ == '__main__':
    sys.exit(main())
