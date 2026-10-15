#!/usr/bin/env python3
"""Check that `flatxml diff` reports exactly the edits made to a document.

    tools/diff_vs_edits.py [--per N] [--seed S] [--show N] bin/flatxml <document>...

For each document, makes up to N copies (default 20) with lxml, each with one known edit: an
element removed, one repeated (a copy put after it), two neighbouring elements of different
names swapped (each only where no text follows it, since in lxml that text goes with it), the text of an element that holds only text changed, or the value of an
attribute changed. Each copy is compared with its document by `flatxml diff` (no rules), which
must report that one change and nothing else: one removal, one addition, one move, one text
change or one attribute change. The removal, text and attribute changes must also name the
edited element's line in the document (for a removal, the line of any sibling equal to it), up
to line 65535: past it, libxml2 numbers lines only approximately.

A document that lxml does not write back as the same tree (one that uses the entities of its
DTD, which flatxml does not read) is skipped. Prints how many copies were checked and how many were reported wrongly, with the first few
(--show, default 20).
"""
import copy
import os
import random
import subprocess
import sys
import tempfile

from lxml import etree

SIGN = {'remove': '-', 'repeat': '+', 'swap': '>', 'text': '~', 'attr': '@'}


def element_children(el):
    return [c for c in el if isinstance(c.tag, str)]


def blank(text):
    return text is None or not text.strip()


def edits_of(tree):
    """Every edit that can be made to the document: (kind, element, index)."""
    out = []
    for el in tree.iter():
        if not isinstance(el.tag, str):
            continue
        kids = element_children(el)
        for k, c in enumerate(kids):
            # text after an element goes with it in lxml: only elements with none are moved
            if not blank(c.tail):
                continue
            out.append(('remove', el, k))
            out.append(('repeat', el, k))
            if k + 1 < len(kids) and kids[k + 1].tag != c.tag and blank(kids[k + 1].tail):
                out.append(('swap', el, k))
            if len(c) == 0 and c.text and c.text.strip():
                out.append(('text', el, k))
            if c.attrib:
                out.append(('attr', el, k))
    return out


def apply(kind, el, k):
    """Makes the edit, and returns what undoes it."""
    c = element_children(el)[k]
    if kind == 'remove':
        at = list(el).index(c)
        tail = c.tail
        el.remove(c)
        return lambda: (el.insert(at, c), setattr(c, 'tail', tail))
    if kind == 'repeat':
        twin = copy.deepcopy(c)
        c.addnext(twin)
        return lambda: el.remove(twin)
    if kind == 'text':
        old = c.text
        c.text = old + 'x'
        return lambda: setattr(c, 'text', old)
    if kind == 'attr':
        name = sorted(c.attrib)[0]
        old = c.attrib[name]
        c.attrib[name] = old + 'x'
        return lambda: c.attrib.__setitem__(name, old)
    nxt = element_children(el)[k + 1]
    nxt.addnext(c)
    return lambda: nxt.addprevious(c)


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
    if len(args) < 2:
        sys.exit(__doc__)
    flatxml, docs = args[0], args[1:]
    rng = random.Random(seed)
    work = tempfile.mkdtemp(prefix='diff_vs_edits_')
    copy_path = os.path.join(work, 'copy.xml')
    checked, wrong, by_kind = 0, [], {}
    skipped = 0
    for doc in docs:
        tree = etree.parse(doc)
        # a document lxml does not write back as the same tree (one using its DTD's entities)
        tree.write(copy_path, xml_declaration=True, encoding='UTF-8')
        if subprocess.run([flatxml, 'diff', doc, copy_path], capture_output=True).returncode != 0:
            skipped += 1
            continue
        edits = edits_of(tree)
        for kind, el, k in rng.sample(edits, min(per, len(edits))):
            target = element_children(el)[k]
            # the lines a removal may name: any sibling equal to the one removed
            lines = {target.sourceline}
            if kind == 'remove':
                same = etree.tostring(target, with_tail=False)
                lines = {c.sourceline for c in element_children(el)
                         if etree.tostring(c, with_tail=False) == same}
            line = target.sourceline
            undo = apply(kind, el, k)
            tree.write(copy_path, xml_declaration=True, encoding='UTF-8')
            undo()
            run = subprocess.run([flatxml, 'diff', doc, copy_path], capture_output=True, text=True)
            changes = run.stdout.splitlines()[:-1]
            ok = run.returncode == 1 and len(changes) == 1 and changes[0].startswith(SIGN[kind])
            # libxml2 numbers lines past 65535 only approximately
            if ok and kind in ('remove', 'text', 'attr') and line <= 65535:
                ok = any(f'{doc}:{n}:' in changes[0] for n in lines)
            checked += 1
            by_kind[kind] = by_kind.get(kind, 0) + 1
            if not ok:
                wrong.append((doc, kind, line, run.stdout + run.stderr))
    os.remove(copy_path) if os.path.exists(copy_path) else None
    os.rmdir(work)
    kinds = ', '.join(f'{n} {k}' for k, n in sorted(by_kind.items()))
    print(f'{checked} edited copies of {len(docs) - skipped} documents ({kinds}): {len(wrong)} reported wrongly')
    if skipped:
        print(f'{skipped} documents skipped: written back by lxml, they differ already')
    for doc, kind, line, out in wrong[:show]:
        print(f'\n{doc}: {kind} at line {line}\n{out}')
    return 1 if wrong else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
