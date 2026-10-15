#!/usr/bin/env python3
"""Run the W3C XML Schema test suite (w3c/xsdtests) against flatxml.

    tools/xsts.py [--show KIND] bin/flatxml <suite-dir>

Reads <suite-dir>/suite.xml and the test sets it lists, keeps the XSD 1.0 tests whose status is
accepted or stable and whose expected outcome is valid or invalid, and compiles each schema test's
documents with `flatxml schema --batch`. A test set whose file is missing (not fetched) is
skipped and counted. Outcomes:

    valid, compiled         the schema is valid and flatxml compiled it
    invalid, rejected       the schema is invalid and flatxml rejected it
    refused                 the schema uses something outside the supported subset
    invalid, compiled       the schema is invalid by a rule flatxml does not check yet
    documented divergence   flatxml decides differently on purpose (DIVERGENCES, below)
    VALID, REJECTED         the schema is valid and flatxml rejected it: a failure

--show KIND lists the tests of one outcome (`valid-rejected`, `invalid-compiled`, `refused`, ...)
with flatxml's answer. Exit status 1 if any valid schema was rejected.
"""
import os
import subprocess
import sys
import xml.etree.ElementTree as ET

TS = '{http://www.w3.org/XML/2004/xml-schema-test-suite/}'
XLINK = '{http://www.w3.org/1999/xlink}href'
KINDS = ['valid-compiled', 'invalid-rejected', 'refused', 'invalid-compiled', 'divergence',
         'valid-rejected']

# Tests flatxml decides differently on purpose, with the reason.
DIVERGENCES = {
    'Missing.testSet/missing001/missing001.xsd':
        'a reference to a missing type is an error when the schema is compiled; XSD 1.0 allows '
        'it until the declaration is used',
}
LABELS = {
    'valid-compiled': 'valid, compiled',
    'invalid-rejected': 'invalid, rejected',
    'refused': 'refused (outside the subset)',
    'invalid-compiled': 'invalid, compiled (not checked yet)',
    'divergence': 'documented divergence',
    'valid-rejected': 'VALID, REJECTED',
}


def applies(el):
    """Whether an element with an optional `version` attribute applies to XSD 1.0."""
    v = el.get('version')
    return v is None or '1.0' in v.split()


def expected(test):
    """The expected validity for XSD 1.0, or None when there is none to compare with."""
    chosen = None
    for e in test.findall(TS + 'expected'):
        v = e.get('version')
        if v is None and chosen is None:
            chosen = e.get('validity')
        elif v is not None and '1.0' in v.split():
            chosen = e.get('validity')
    return chosen if chosen in ('valid', 'invalid') else None


def accepted(test):
    cur = test.find(TS + 'current')
    return cur is None or cur.get('status') in ('accepted', 'stable')


def schema_tests(suite_dir):
    """Yield (name, [schema documents], expected) for every schema test that applies; count the
    rest in `skipped`."""
    suite = ET.parse(os.path.join(suite_dir, 'suite.xml')).getroot()
    for ref in suite.findall(TS + 'testSetRef'):
        path = os.path.join(suite_dir, ref.get(XLINK))
        if not os.path.exists(path):
            skipped['set not fetched'] += 1
            continue
        base = os.path.dirname(path)
        test_set = ET.parse(path).getroot()
        if not applies(test_set):
            skipped['XSD 1.1 only'] += sum(len(g.findall(TS + 'schemaTest'))
                                           for g in test_set.findall(TS + 'testGroup'))
            continue
        for group in test_set.findall(TS + 'testGroup'):
            for test in group.findall(TS + 'schemaTest'):
                if not applies(group) or not applies(test):
                    skipped['XSD 1.1 only'] += 1
                    continue
                if not accepted(test):
                    skipped['not accepted'] += 1
                    continue
                want = expected(test)
                if want is None:
                    skipped['no 1.0 expectation'] += 1
                    continue
                docs = [os.path.normpath(os.path.join(base, d.get(XLINK)))
                        for d in test.findall(TS + 'schemaDocument')]
                yield f'{os.path.basename(path)}/{group.get("name")}/{test.get("name")}', docs, want


skipped = {'set not fetched': 0, 'XSD 1.1 only': 0, 'not accepted': 0, 'no 1.0 expectation': 0}


def main():
    args = sys.argv[1:]
    show = None
    if args[:1] == ['--show'] and len(args) > 1:
        show = args[1]
        args = args[2:]
    if len(args) != 2 or (show and show not in KINDS):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    flatxml, suite_dir = args
    tests = list(schema_tests(suite_dir))
    proc = subprocess.run([flatxml, 'schema', '--batch'], capture_output=True, text=True,
                          encoding='utf-8', errors='replace',
                          input=''.join('\t'.join(docs) + '\n' for _, docs, _ in tests))
    answers = proc.stdout.splitlines()
    if proc.returncode != 0 or len(answers) != len(tests):
        print(f'flatxml schema --batch failed after {len(answers)} of {len(tests)} tests:\n'
              + proc.stderr[-2000:], file=sys.stderr)
        return 1
    tally = {k: 0 for k in KINDS}
    # Classify each test by the expected outcome and flatxml's answer.
    for (name, _, want), answer in zip(tests, answers):
        ok = answer == 'ok'
        if name in DIVERGENCES:
            kind = 'divergence'
        elif not ok and 'not supported' in answer:
            kind = 'refused'
        elif want == 'valid':
            kind = 'valid-compiled' if ok else 'valid-rejected'
        else:
            kind = 'invalid-compiled' if ok else 'invalid-rejected'
        tally[kind] += 1
        if kind == show:
            print(f'{name}\n  {answer}')
    print(f'{len(tests)} schema tests run; skipped: '
          + ', '.join(f'{v} {k}' for k, v in skipped.items()))
    for k in KINDS:
        print(f'  {LABELS[k]:38} {tally[k]:6}')
    return 1 if tally['valid-rejected'] else 0


if __name__ == '__main__':
    sys.exit(main())
