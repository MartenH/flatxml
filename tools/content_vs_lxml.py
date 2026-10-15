#!/usr/bin/env python3
"""Compare flatxml's content-model checks with libxml2's, on documents edited where they decide.

    tools/content_vs_lxml.py [--per N] [--seed S] [--show N] bin/flatxml <schema.xsd> <document>...

For each document that libxml2 finds valid against the schema, makes up to N copies (default 20),
each with one edit to the children of one element: two neighbouring element children of different
names swapped (order), one removed (the minimum), or one repeated (the maximum). Each copy is
validated by `flatxml validate --batch` and by lxml, and their verdicts are compared.

Prints how many copies both accept, both reject, and each accepts alone; the disagreements are
listed (--show, default 20) with both answers. libxml2 is a second opinion, not the truth: a
disagreement is a question to settle against the specification (XSD 1.0 Part 1, 3.8 and 3.9).
"""
import copy
import os
import random
import subprocess
import sys
import tempfile

from lxml import etree


def element_children(el):
    return [c for c in el if isinstance(c.tag, str)]


def edits_of(tree):
    """Every edit that can be made to the document: (kind, parent, index)."""
    out = []
    for el in tree.iter():
        if not isinstance(el.tag, str):
            continue
        kids = element_children(el)
        for k, c in enumerate(kids):
            out.append(('remove', el, k))
            out.append(('repeat', el, k))
            if k + 1 < len(kids) and kids[k + 1].tag != c.tag:
                out.append(('swap', el, k))
    return out


def apply(kind, el, k):
    """Makes the edit, and returns what undoes it."""
    kids = element_children(el)
    c = kids[k]
    if kind == 'remove':
        at = list(el).index(c)
        tail = c.tail
        el.remove(c)
        return lambda: (el.insert(at, c), setattr(c, 'tail', tail))
    if kind == 'repeat':
        twin = copy.deepcopy(c)
        c.addnext(twin)
        return lambda: el.remove(twin)
    nxt = kids[k + 1]
    nxt.addprevious(c)  # c moves after its neighbour
    return lambda: nxt.addnext(c)


def where(el):
    return f'{el.getroottree().getpath(el)} (line {el.sourceline})'


def main(argv):
    per, seed, show = 20, 1, 20
    args = argv[1:]
    while args and args[0].startswith('--'):
        opt = args.pop(0)
        val = int(args.pop(0))
        if opt == '--per':
            per = val
        elif opt == '--seed':
            seed = val
        elif opt == '--show':
            show = val
        else:
            sys.exit(f'unknown option {opt}')
    if len(args) < 3:
        sys.exit(__doc__)
    flatxml, schema_path, docs = args[0], os.path.abspath(args[1]), args[2:]
    schema = etree.XMLSchema(etree.parse(schema_path))
    rng = random.Random(seed)
    proc = subprocess.Popen([flatxml, 'validate', '--batch'], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, text=True)
    work = tempfile.mkdtemp(prefix='content_vs_lxml_')
    copy_path = os.path.join(work, 'copy.xml')
    counts = {'both accept': 0, 'both reject': 0, 'only flatxml accepts': 0,
              'only libxml2 accepts': 0, 'flatxml error': 0}
    skipped = 0
    disagreements = []
    for doc in docs:
        tree = etree.parse(doc)
        if not schema.validate(tree):
            skipped += 1
            continue
        edits = edits_of(tree)
        for kind, el, k in rng.sample(edits, min(per, len(edits))):
            name = element_children(el)[k].tag
            undo = apply(kind, el, k)
            tree.write(copy_path, xml_declaration=True, encoding='UTF-8')
            lx = schema.validate(tree)
            lx_why = '' if lx else str(schema.error_log.last_error.message)
            undo()
            proc.stdin.write(f'{copy_path}\t{schema_path}\n')
            proc.stdin.flush()
            answer = proc.stdout.readline().rstrip('\n')
            if answer.startswith('error'):
                counts['flatxml error'] += 1
                disagreements.append((doc, kind, name, where(el), answer, lx_why or 'valid'))
                continue
            fx = answer == 'valid'
            if fx and lx:
                counts['both accept'] += 1
            elif not fx and not lx:
                counts['both reject'] += 1
            else:
                counts['only flatxml accepts' if fx else 'only libxml2 accepts'] += 1
                disagreements.append((doc, kind, name, where(el), answer, lx_why or 'valid'))
    proc.stdin.close()
    proc.wait()
    os.remove(copy_path) if os.path.exists(copy_path) else None
    os.rmdir(work)
    print(f'{len(docs) - skipped} documents edited ({skipped} skipped: libxml2 rejects them as they are)')
    for k, n in counts.items():
        print(f'  {k:<24}{n:>8}')
    for doc, kind, name, at, fx, lx in disagreements[:show]:
        print(f'\n{doc}: {kind} {name} in {at}\n  flatxml: {fx}\n  libxml2: {lx}')
    return 1 if disagreements else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
