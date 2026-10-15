#!/usr/bin/env python3
"""Time flatxml, lxml and xmlschema on the W3C XML Schema test suite, and count their verdicts.

    unshare -rn tools/xsts_bench.py [--engines flatxml,lxml,xmlschema] bin/flatxml <suite-dir>

Run it without a network (`unshare -rn` gives the process an empty network namespace, with no
root needed). Some tests import schemas by http URL: flatxml skips such an import, xmlschema is
told to read local files only, but libxml2 (lxml) fetches it, and where a connection hangs rather
than failing (it does under WSL), each fetch waits out a timeout and lxml's time becomes the
network's. Without a network the fetch fails at once and libxml2 skips the import too.

Runs every engine over the same XSD 1.0 tests that tools/xsts.py runs: compile each schema test,
then validate each instance test against its group's schema when that engine compiled it.
Reports, per engine, the time and how many verdicts match the suite's expected ones, twice:

    all tests        every XSD 1.0 test; flatxml refuses what is outside its subset, which counts
                     as no verdict (and costs almost nothing, so its time here is not comparable)
    in the subset    only the tests whose schema flatxml does not refuse: the same work for every
                     engine, and the fair comparison of time

flatxml runs as two batch processes (schema, then validate); lxml and xmlschema run in this
process. A schema test with several documents is given to lxml and xmlschema as its first
document, which imports the rest. None of them reads anything but local files. Engines that are
not installed are skipped.
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from xsts import read_suite  # noqa: E402


def run_flatxml(flatxml, schemas, instances):
    """Verdicts (True valid / False invalid / None refused) for the schemas and the instances."""
    t0 = time.perf_counter()
    out = subprocess.run([flatxml, 'schema', '--batch'], capture_output=True, text=True,
                         input=''.join('\t'.join(d) + '\n' for _, d, _ in schemas)).stdout.splitlines()
    t1 = time.perf_counter()
    sv = [True if a == 'ok' else (None if 'not supported' in a else False) for a in out]
    todo = [k for k, (_, _, si, _) in enumerate(instances) if sv[si]]
    lines = [instances[k][1] + '\t' + '\t'.join(schemas[instances[k][2]][1]) for k in todo]
    out = subprocess.run([flatxml, 'validate', '--batch'], capture_output=True, text=True,
                         input=''.join(l + '\n' for l in lines)).stdout.splitlines()
    t2 = time.perf_counter()
    iv = [None] * len(instances)
    for k, a in zip(todo, out):
        f = a.split('\t')
        iv[k] = None if (f[0] == 'invalid' and f[1] == 'unsupported') else f[0] == 'valid'
    return sv, iv, t1 - t0, t2 - t1


def run_lxml(schemas, instances):
    from lxml import etree
    compiled = []
    t0 = time.perf_counter()
    for _, docs, _ in schemas:
        try:
            compiled.append(etree.XMLSchema(etree.parse(docs[0])))
        except Exception:
            compiled.append(None)
    t1 = time.perf_counter()
    iv = [None] * len(instances)
    for k, (_, doc, si, _) in enumerate(instances):
        if compiled[si] is None:
            continue
        try:
            iv[k] = compiled[si].validate(etree.parse(doc))
        except Exception:
            iv[k] = False
    t2 = time.perf_counter()
    return [c is not None for c in compiled], iv, t1 - t0, t2 - t1


def run_xmlschema(schemas, instances):
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
    iv = [None] * len(instances)
    for k, (_, doc, si, _) in enumerate(instances):
        if compiled[si] is None:
            continue
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
    if len(args) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    flatxml, suite_dir = args
    schemas, instances = read_suite(suite_dir)
    s_expected = [w for _, _, w in schemas]
    i_expected = [w for _, _, _, w in instances]
    # flatxml first: its refusals define the subset every engine is also timed on
    fx = run_flatxml(flatxml, schemas, instances)
    s_subset = [k for k, v in enumerate(fx[0]) if v is not None]
    subset_schemas = set(s_subset)
    i_subset = [k for k, (_, _, si, _) in enumerate(instances) if si in subset_schemas]
    # and again over the subset alone, for a time the other engines' subset runs compare with
    sub_schemas = [schemas[k] for k in s_subset]
    sub_instances = [(n, d, s_subset.index(si), w) for n, d, si, w in (instances[k] for k in i_subset)]
    fx_sub = run_flatxml(flatxml, sub_schemas, sub_instances)
    results = {'flatxml': fx}
    for name, run in (('lxml', run_lxml), ('xmlschema', run_xmlschema)):
        if name not in engines:
            continue
        try:
            # each engine runs twice: once over everything, once over the subset, for its times
            print(f'{name}: running', file=sys.stderr, flush=True)
            everything = run(schemas, instances)
            sub = run(sub_schemas, sub_instances)
            results[name] = (everything, sub)
        except ImportError:
            print(f'{name}: not installed, skipped', file=sys.stderr)
    print(f'{len(schemas)} schema tests and {len(instances)} instance tests (XSD 1.0); '
          f'{len(s_subset)} and {len(i_subset)} in flatxml\'s subset\n')
    print('| engine | workload | schema tests: time | right / verdicts | instance tests: time | right / verdicts |')
    print('|---|---|---|---|---|---|')
    for name in engines:
        if name not in results:
            continue
        if name == 'flatxml':
            (sv, iv, ts, ti), (ssv, siv, sts, sti) = fx, fx_sub
        else:
            (sv, iv, ts, ti), (ssv, siv, sts, sti) = results[name]
        # the subset run's verdicts, mapped back to the full numbering
        sv_sub = [None] * len(schemas)
        for j, k in enumerate(s_subset):
            sv_sub[k] = ssv[j]
        iv_sub = [None] * len(instances)
        for j, k in enumerate(i_subset):
            iv_sub[k] = siv[j]
        rows = [('all tests', sv, iv, ts, ti, range(len(schemas)), range(len(instances))),
                ('in the subset', sv_sub, iv_sub, sts, sti, s_subset, i_subset)]
        for label, sv, iv, ts, ti, sk, ik in rows:
            sn, sg, sr = score(sv, s_expected, sk)
            inn, ig, ir = score(iv, i_expected, ik)
            timing = '(not comparable)' if name == 'flatxml' and label == 'all tests' else ''
            print(f'| {name} | {label} | {ts:.2f} s {timing}| {sr:,} / {sg:,} of {sn:,} '
                  f'| {ti:.2f} s | {ir:,} / {ig:,} of {inn:,} |')
    return 0


if __name__ == '__main__':
    sys.exit(main())
