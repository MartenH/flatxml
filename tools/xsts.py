#!/usr/bin/env python3
"""Run the W3C XML Schema test suite (w3c/xsdtests) against flatxml.

    tools/xsts.py [--show KIND] bin/flatxml <suite-dir>

Reads <suite-dir>/suite.xml and the test sets it lists and keeps the XSD 1.0 tests whose status
is accepted or stable and whose expected outcome is valid or invalid. A test set whose file is
missing (not fetched) is skipped and counted.

Schema tests compile each test's documents with `flatxml schema --batch`:

    valid, compiled           the schema is valid and flatxml compiled it
    invalid, rejected         the schema is invalid and flatxml rejected it
    refused                   the schema uses something outside the supported subset
    invalid, compiled         the schema is invalid by a rule flatxml does not check yet
    documented divergence     flatxml decides differently on purpose (DIVERGENCES, below)
    VALID, REJECTED           the schema is valid and flatxml rejected it: a failure

Instance tests validate a document against its group's schema with `flatxml validate --batch`,
when that schema is expected valid and compiles:

    valid, accepted           the document is valid and flatxml found nothing
    invalid, reported         the document is invalid and flatxml found something
    refused                   the document uses something unsupported (xsi:type, a schema it
                              names itself by xsi:schemaLocation, XML 1.1)
    invalid, accepted         the document is invalid by a rule flatxml does not check yet
    VALID, REPORTED           the document is valid and flatxml reported it: a failure

--show KIND lists the tests of one outcome with flatxml's answer; schema outcomes are named
`schema:valid-rejected`, `schema:invalid-compiled`, ..., instance outcomes `instance:...`. Exit
status 1 if a valid schema was rejected or a valid document reported.
"""
import os
import subprocess
import sys
import xml.etree.ElementTree as ET

TS = '{http://www.w3.org/XML/2004/xml-schema-test-suite/}'
XLINK = '{http://www.w3.org/1999/xlink}href'

SCHEMA_KINDS = {
    'valid-compiled': 'valid, compiled',
    'invalid-rejected': 'invalid, rejected',
    'refused': 'refused (outside the subset)',
    'invalid-compiled': 'invalid, compiled (not checked yet)',
    'divergence': 'documented divergence',
    'valid-rejected': 'VALID, REJECTED',
}
INSTANCE_KINDS = {
    'valid-accepted': 'valid, accepted',
    'invalid-reported': 'invalid, reported',
    'refused': 'refused (outside the subset)',
    'invalid-accepted': 'invalid, accepted (not checked yet)',
    'valid-reported': 'VALID, REPORTED',
}

# Tests flatxml decides differently on purpose, with the reason.
DIVERGENCES = {
    'Missing.testSet/missing001/missing001.xsd':
        'a reference to a missing type is an error when the schema is compiled; XSD 1.0 allows '
        'it until the declaration is used',
}

skipped = {'set not fetched': 0, 'XSD 1.1 only': 0, 'not accepted': 0, 'no 1.0 expectation': 0}
instances_skipped = {'no usable schema': 0}


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


def usable(test, counts):
    """The test's expected validity if it applies to XSD 1.0 and is accepted; else None, counted."""
    if not applies(test):
        counts['XSD 1.1 only'] = counts.get('XSD 1.1 only', 0) + 1
        return None
    cur = test.find(TS + 'current')
    if cur is not None and cur.get('status') not in ('accepted', 'stable'):
        counts['not accepted'] = counts.get('not accepted', 0) + 1
        return None
    want = expected(test)
    if want is None:
        counts['no 1.0 expectation'] = counts.get('no 1.0 expectation', 0) + 1
    return want


def read_suite(suite_dir):
    """The schema tests as (name, [documents], expected) and the instance tests as
    (name, document, schema test index, expected)."""
    schemas, instances = [], []
    suite = ET.parse(os.path.join(suite_dir, 'suite.xml')).getroot()
    for ref in suite.findall(TS + 'testSetRef'):
        path = os.path.join(suite_dir, ref.get(XLINK))
        if not os.path.exists(path):
            skipped['set not fetched'] += 1
            instances_skipped['set not fetched'] = instances_skipped.get('set not fetched', 0) + 1
            continue
        base = os.path.dirname(path)
        test_set = ET.parse(path).getroot()
        for group in test_set.findall(TS + 'testGroup'):
            if not applies(test_set) or not applies(group):
                skipped['XSD 1.1 only'] += len(group.findall(TS + 'schemaTest'))
                instances_skipped['XSD 1.1 only'] = (instances_skipped.get('XSD 1.1 only', 0)
                                                     + len(group.findall(TS + 'instanceTest')))
                continue
            schema_index = None
            # A group's schema test, then the instance tests that use its schema.
            for test in group.findall(TS + 'schemaTest'):
                want = usable(test, skipped)
                if want is None:
                    continue
                docs = [os.path.normpath(os.path.join(base, d.get(XLINK)))
                        for d in test.findall(TS + 'schemaDocument')]
                schema_index = len(schemas)
                schemas.append((f'{os.path.basename(path)}/{group.get("name")}/{test.get("name")}',
                                docs, want))
            for test in group.findall(TS + 'instanceTest'):
                want = usable(test, instances_skipped)
                if want is None:
                    continue
                if schema_index is None:
                    instances_skipped['no usable schema'] += 1
                    continue
                doc = os.path.normpath(os.path.join(base, test.find(TS + 'instanceDocument').get(XLINK)))
                instances.append((f'{os.path.basename(path)}/{group.get("name")}/{test.get("name")}',
                                  doc, schema_index, want))
    return schemas, instances


def xml_1_1(path):
    with open(path, 'rb') as f:
        head = f.read(100)
    return b'version="1.1"' in head or b"version='1.1'" in head


def batch(flatxml, command, lines):
    proc = subprocess.run([flatxml, command, '--batch'], capture_output=True, text=True,
                          encoding='utf-8', errors='replace', input=''.join(l + '\n' for l in lines))
    answers = proc.stdout.splitlines()
    if proc.returncode != 0 or len(answers) != len(lines):
        sys.exit(f'flatxml {command} --batch failed after {len(answers)} of {len(lines)} tests:\n'
                 + proc.stderr[-2000:])
    return answers


def main():
    args = sys.argv[1:]
    show = None
    if args[:1] == ['--show'] and len(args) > 1:
        show = args[1]
        args = args[2:]
    valid_show = [f'schema:{k}' for k in SCHEMA_KINDS] + [f'instance:{k}' for k in INSTANCE_KINDS]
    if len(args) != 2 or (show and show not in valid_show):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    flatxml, suite_dir = args
    schemas, instances = read_suite(suite_dir)

    answers = batch(flatxml, 'schema', ['\t'.join(docs) for _, docs, _ in schemas])
    tally = {k: 0 for k in SCHEMA_KINDS}
    compiled = []
    # Classify each schema test by the expected outcome and flatxml's answer.
    for (name, _, want), answer in zip(schemas, answers):
        ok = answer == 'ok'
        compiled.append(ok and want == 'valid')
        if name in DIVERGENCES:
            kind = 'divergence'
        elif not ok and 'not supported' in answer:
            kind = 'refused'
        elif want == 'valid':
            kind = 'valid-compiled' if ok else 'valid-rejected'
        else:
            kind = 'invalid-compiled' if ok else 'invalid-rejected'
        tally[kind] += 1
        if show == f'schema:{kind}':
            print(f'{name}\n  {answer}')
    print(f'{len(schemas)} schema tests run; skipped: '
          + ', '.join(f'{v} {k}' for k, v in skipped.items()))
    for k, label in SCHEMA_KINDS.items():
        print(f'  {label:38} {tally[k]:6}')

    runnable = [t for t in instances if compiled[t[2]]]
    instances_skipped['no usable schema'] += len(instances) - len(runnable)
    answers = batch(flatxml, 'validate', [doc + '\t' + '\t'.join(schemas[si][1])
                                          for _, doc, si, _ in runnable])
    itally = {k: 0 for k in INSTANCE_KINDS}
    # Classify each instance test the same way.
    for (name, doc, _, want), answer in zip(runnable, answers):
        verdict = answer.split('\t')
        if verdict[0] == 'invalid' and verdict[1] == 'unsupported':
            kind = 'refused'
        elif verdict[0] == 'error' and xml_1_1(doc):
            kind = 'refused'
        elif verdict[0] == 'valid':
            kind = 'valid-accepted' if want == 'valid' else 'invalid-accepted'
        else:
            kind = 'invalid-reported' if want == 'invalid' else 'valid-reported'
        itally[kind] += 1
        if show == f'instance:{kind}':
            print(f'{name}\n  {answer}')
    print(f'{len(runnable)} instance tests run; skipped: '
          + ', '.join(f'{v} {k}' for k, v in instances_skipped.items()))
    for k, label in INSTANCE_KINDS.items():
        print(f'  {label:38} {itally[k]:6}')
    return 1 if tally['valid-rejected'] or itally['valid-reported'] else 0


if __name__ == '__main__':
    sys.exit(main())
