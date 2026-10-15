#!/usr/bin/env python3
"""Time flatxml, lxml and xmlschema on the W3C XML Schema test suite, and count their verdicts.

    unshare -rn tools/xsts_bench.py [--engines flatxml,lxml,xmlschema] bin/flatxml <suite-dir>

Run it without a network (`unshare -rn` gives the process an empty network namespace, with no
root needed). Some tests import schemas by http URL: flatxml skips such an import, xmlschema is
told to read local files only, but libxml2 (lxml) fetches it, and where a connection hangs rather
than failing (it does under WSL), each fetch waits out a timeout and lxml's time becomes the
network's. Without a network the fetch fails at once and libxml2 skips the import too.

Each engine compiles schema tests, then validates instance tests against the schemas it compiled.
Reported twice:

    all tests        every XSD 1.0 test that tools/xsts.py runs; flatxml refuses what is outside
                     its subset, which is no verdict (and costs almost nothing, so its time there
                     is not comparable)
    same work        the schemas flatxml does not refuse, and the documents of those schemas that
                     every engine compiled: exactly the same files for every engine, the fair
                     comparison of time

Times are the work alone: compiling the schemas, then reading and validating the documents (not
compiling their schemas again). flatxml reports its own (`--times`); lxml and xmlschema are timed
in this process. A schema test with several documents is given to lxml and xmlschema as its first
document, which imports the rest. Engines that are not installed are skipped. A flatxml answer is
read as tools/xsts.py reads it: a refusal, an XML 1.1 document or an uncompiled schema is no
verdict.
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from xsts import read_suite, xml_1_1  # noqa: E402


def flatxml_batch(flatxml, command, lines):
    """The answers to a batch, and the time flatxml spent on the work (--times)."""
    proc = subprocess.run([flatxml, command, '--batch', '--times'], capture_output=True, text=True,
                          encoding='utf-8', errors='replace', input=''.join(l + '\n' for l in lines))
    answers = proc.stdout.splitlines()
    spent = [l for l in proc.stderr.splitlines() if l.startswith('time ')]
    if proc.returncode != 0 or len(answers) != len(lines) or not spent:
        sys.exit(f'flatxml {command} --batch failed after {len(answers)} of {len(lines)} lines:\n'
                 + proc.stderr[-2000:])
    return answers, int(spent[-1].split()[1]) / 1e6


def run_flatxml(flatxml, schemas, instances, todo=None):
    """Verdicts (True valid, False invalid, None none) for the schemas and for the instances in
    todo (default: those whose schema flatxml compiled), and the two times."""
    answers, ts = flatxml_batch(flatxml, 'schema', ['\t'.join(d) for _, d, _ in schemas])
    sv = [True if a == 'ok' else (None if 'not supported' in a else False) for a in answers]
    if todo is None:
        todo = [k for k, (_, _, si, _) in enumerate(instances) if sv[si]]
    lines = [instances[k][1] + '\t' + '\t'.join(schemas[instances[k][2]][1]) for k in todo]
    answers, ti = flatxml_batch(flatxml, 'validate', lines)
    iv = [None] * len(instances)
    for k, a in zip(todo, answers):
        f = a.split('\t')
        if f[0] == 'valid':
            iv[k] = True
        elif f[0] == 'invalid':
            iv[k] = None if f[1] == 'unsupported' else False
        elif not (xml_1_1(instances[k][1]) or a.startswith('error\tschema:')):
            iv[k] = False
    return sv, iv, ts, ti


def run_lxml(schemas, instances, todo=None):
    from lxml import etree
    compiled = []
    t0 = time.perf_counter()
    for _, docs, _ in schemas:
        try:
            compiled.append(etree.XMLSchema(etree.parse(docs[0])))
        except Exception:
            compiled.append(None)
    t1 = time.perf_counter()
    if todo is None:
        todo = [k for k, (_, _, si, _) in enumerate(instances) if compiled[si] is not None]
    iv = [None] * len(instances)
    for k in todo:
        _, doc, si, _ = instances[k]
        try:
            iv[k] = compiled[si].validate(etree.parse(doc))
        except Exception:
            iv[k] = False
    t2 = time.perf_counter()
    return [c is not None for c in compiled], iv, t1 - t0, t2 - t1


def run_xmlschema(schemas, instances, todo=None):
    import xmlschema
    compiled = []
    t0 = time.perf_counter()
    for _, docs, _ in schemas:
        try:
            # local files only, as flatxml and lxml: some tests import by URL
            compiled.append(xmlschema.XMLSchema10(docs[0], allow='local', timeout=1))
        except Exception:
            compiled.append(None)
    t1 = time.perf_counter()
    if todo is None:
        todo = [k for k, (_, _, si, _) in enumerate(instances) if compiled[si] is not None]
    iv = [None] * len(instances)
    for k in todo:
        _, doc, si, _ = instances[k]
        try:
            iv[k] = compiled[si].is_valid(doc)
        except Exception:
            iv[k] = False
    t2 = time.perf_counter()
    return [c is not None for c in compiled], iv, t1 - t0, t2 - t1


def score(verdicts, expected, keep):
    """(tests, verdicts given, verdicts matching expected) over the tests in keep."""
    n = given = right = 0
    for k in keep:
        n += 1
        if verdicts[k] is None:
            continue
        given += 1
        right += verdicts[k] == (expected[k] == 'valid')
    return n, given, right


def main():
    args = sys.argv[1:]
    engines = ['flatxml', 'lxml', 'xmlschema']
    if args[:1] == ['--engines'] and len(args) > 1:
        engines = args[1].split(',')
        args = args[2:]
    if len(args) != 2 or 'flatxml' not in engines:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    flatxml, suite_dir = args
    schemas, instances = read_suite(suite_dir)
    s_expected = [w for _, _, w in schemas]
    i_expected = [w for _, _, _, w in instances]
    runners = {
        'flatxml': lambda s, i, todo=None: run_flatxml(flatxml, s, i, todo),
        'lxml': run_lxml,
        'xmlschema': run_xmlschema,
    }
    full = {}
    # every engine over every test first: its verdicts, and which schemas it compiles
    for name in engines:
        print(f'{name}: all tests', file=sys.stderr, flush=True)
        try:
            full[name] = runners[name](schemas, instances)
        except ImportError:
            print(f'{name}: not installed, skipped', file=sys.stderr)
    # the same work: flatxml's subset of schemas, and the documents every engine can validate
    s_subset = [k for k, v in enumerate(full['flatxml'][0]) if v is not None]
    common = set(s_subset)
    for sv, _, _, _ in full.values():
        common &= {k for k, v in enumerate(sv) if v}
    i_same = [k for k, (_, _, si, _) in enumerate(instances) if si in common]
    position = {k: j for j, k in enumerate(s_subset)}
    sub_schemas = [schemas[k] for k in s_subset]
    sub_instances = [(n, d, position.get(si), w) for n, d, si, w in instances]
    same = {}
    for name in full:
        print(f'{name}: the same work', file=sys.stderr, flush=True)
        sv, iv, ts, ti = runners[name](sub_schemas, sub_instances, i_same)
        full_sv = [None] * len(schemas)
        for j, k in enumerate(s_subset):
            full_sv[k] = sv[j]
        same[name] = (full_sv, iv, ts, ti)
    print(f'{len(schemas)} schema tests and {len(instances)} instance tests (XSD 1.0); the same '
          f'work: {len(s_subset)} schemas and {len(i_same)} documents\n')
    print('| engine | tests | schemas: time | right / verdicts | documents: time | right / verdicts |')
    print('|---|---|---|---|---|---|')
    for name in full:
        for label, (sv, iv, ts, ti), sk, ik in (
                ('all tests', full[name], range(len(schemas)), range(len(instances))),
                ('the same work', same[name], s_subset, i_same)):
            sn, sg, sr = score(sv, s_expected, sk)
            inn, ig, ir = score(iv, i_expected, ik)
            note = ' (not comparable)' if name == 'flatxml' and label == 'all tests' else ''
            print(f'| {name} | {label} | {ts:.2f} s{note} | {sr:,} / {sg:,} of {sn:,} '
                  f'| {ti:.2f} s | {ir:,} / {ig:,} of {inn:,} |')
    return 0


if __name__ == '__main__':
    sys.exit(main())
