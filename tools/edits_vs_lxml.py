#!/usr/bin/env python3
"""Check flatxml's edits against lxml making the same edits: the trees must agree.

    tools/edits_vs_lxml.py [--seed S] [--edits N] [--ext xml,cfg] bin/flatxml <file|dir>...

For each file, N random edits (default 10) are made with lxml, one after the other, and written
as a script for `flatxml edit`: set an element's text, set or remove an attribute, insert a new
element, insert a copy of an element of the file, remove an element, move one. flatxml applies the
script and writes the file; its output is read with lxml and compared with lxml's edited tree,
element by element: the name with its namespace, the attributes in order, and the element's own
text (the runs of text beside its children, whitespace-only runs left out, since one side
indents and the other does not). A file lxml or flatxml cannot read is skipped, and so is one in
an encoding other than UTF-8, since flatxml writes the values it is given as UTF-8.

It also counts the lines that differ from the original file: in flatxml's output, and in lxml's
serialisation of the same tree. Exit status 1 if any tree differs.
"""
import copy
import difflib
import os
import random
import subprocess
import sys
import tempfile

from lxml import etree


def esc(s):
    return s.replace('\\', '\\\\').replace('\t', '\\t').replace('\n', '\\n').replace('\r', '\\r')


def elements(e):
    return [c for c in e if isinstance(c.tag, str)]


def own_text(e):
    runs = [e.text or ''] + [c.tail or '' for c in e]
    return ''.join(r for r in runs if r.strip())


def shape(e, out):
    out.append((e.tag, list(e.attrib.items()), own_text(e)))
    for c in elements(e):
        shape(c, out)
    out.append(None)


def path_of(e):
    p = []
    while e.getparent() is not None:
        p.append(elements(e.getparent()).index(e))
        e = e.getparent()
    return '/' + '/'.join(str(i) for i in reversed(p))


def detach(e):
    """Remove e as flatxml does: the whitespace before it (its indentation) goes with it, the text
    after it stays, and whitespace after it that would join text before it is left out."""
    parent = e.getparent()
    prev = e.getprevious()
    before = (prev.tail if prev is not None else parent.text) or ''
    tail = e.tail or ''
    if not before.strip():
        before = tail
    elif tail.strip():
        before += tail
    if prev is not None:
        prev.tail = before
    else:
        parent.text = before
    e.tail = None
    parent.remove(e)


def put(parent, index, e):
    """Put e under parent as its child element number index."""
    kids = elements(parent)
    if index < len(kids):
        parent.insert(parent.index(kids[index]), e)
    else:
        parent.append(e)


def random_edit(rng, root, original, dflt):
    """One random edit to root, which was read from original, as a line of an edit script.

    dflt maps each element to the default namespace flatxml reads a fragment put under it in: an
    element keeps the bindings of where it was read (flatxml declares them on it when it is moved
    or copied), and a fragment those of where it is put first."""
    els = list(root.iter(etree.Element))
    e = rng.choice(els)
    kind = rng.choice(['text', 'attr', 'noattr', 'insert', 'copy', 'remove', 'move'])
    p = path_of(e)
    if kind == 'text':
        v = rng.choice(['new', 'a < b & "c"', 'été', 'x]]>y', ' padded '])
        e.text = v
        for c in e:
            c.tail = None
        return f'text\t{p}\t{esc(v)}'
    if kind == 'attr':
        name = rng.choice(list(e.attrib.keys()) + ['flatxml-new']) if e.attrib else 'flatxml-new'
        if name.startswith('{'):
            return None
        v = rng.choice(['1', 'say "hi"', "it's", 'a\tb', ''])
        e.set(name, v)
        return f'attr\t{p}\t{name}\t{esc(v)}'
    if kind == 'noattr':
        names = [n for n in e.attrib.keys() if not n.startswith('{')]
        if not names:
            return None
        name = rng.choice(names)
        del e.attrib[name]
        return f'noattr\t{p}\t{name}'
    if kind == 'insert':
        index = rng.randrange(len(elements(e)) + 1)
        default = dflt[e]
        new = etree.Element(f'{{{default}}}added' if default else 'added', k='v')
        new.text = 't'
        dflt[new] = default
        put(e, index, new)
        return f'insert\t{p}\t{index}\t<added k="v">t</added>'
    if kind == 'copy':
        src = rng.choice(list(original.iter(etree.Element)))
        index = rng.randrange(len(elements(e)) + 1)
        c = copy.deepcopy(src)
        c.tail = None
        for a, b in zip(src.iter(etree.Element), c.iter(etree.Element)):
            dflt[b] = a.nsmap.get(None)
        put(e, index, c)
        return f'copy\t{p}\t{index}\t{path_of(src)}'
    if e.getparent() is None:
        return None
    if kind == 'remove':
        detach(e)
        return f'remove\t{p}'
    # move: under an element outside e
    targets = [t for t in els if not any(a is e for a in t.iterancestors()) and t is not e]
    to = rng.choice(targets)
    to_path = path_of(to)  # both paths name elements before the move
    detach(e)
    index = rng.randrange(len(elements(to)) + 1)
    put(to, index, e)
    return f'move\t{to_path}\t{index}\t{p}'


def changed_lines(a, b):
    return sum(1 for l in difflib.unified_diff(a.splitlines(), b.splitlines(), n=0, lineterm='')
               if l[:1] in '+-' and not l.startswith(('+++', '---')))


def main():
    args = sys.argv[1:]
    seed, count, exts = 1, 10, ['xml']
    while args and args[0].startswith('--'):
        flag = args.pop(0)
        if flag == '--seed':
            seed = int(args.pop(0))
        elif flag == '--edits':
            count = int(args.pop(0))
        elif flag == '--ext':
            exts = args.pop(0).split(',')
        else:
            print(__doc__.strip(), file=sys.stderr)
            return 2
    if len(args) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    flatxml, paths = args[0], []
    for a in args[1:]:
        if os.path.isdir(a):
            for d, _, fs in sorted(os.walk(a)):
                paths += [os.path.join(d, f) for f in sorted(fs) if f.rsplit('.', 1)[-1] in exts]
        else:
            paths.append(a)
    rng = random.Random(seed)
    same = differ = skipped = edits = 0
    ours = theirs = 0
    with tempfile.TemporaryDirectory() as tmp:
        script, out = os.path.join(tmp, 'edits.tsv'), os.path.join(tmp, 'out.xml')
        for path in paths:
            parser = etree.XMLParser(remove_blank_text=False, resolve_entities=False, huge_tree=True)
            try:
                doc = etree.parse(path, parser)
            except (etree.XMLSyntaxError, OSError):
                skipped += 1
                continue
            if (doc.docinfo.encoding or 'UTF-8').upper() not in ('UTF-8', 'UTF8', 'US-ASCII', 'ASCII'):
                skipped += 1  # flatxml writes what it is given as UTF-8
                continue
            original = doc.getroot()
            tree = copy.deepcopy(original)
            dflt = {b: a.nsmap.get(None) for a, b in zip(original.iter(etree.Element),
                                                         tree.iter(etree.Element))}
            lines = []
            while len(lines) < count:
                line = random_edit(rng, tree, original, dflt)
                if line is not None:
                    lines.append(line)
            with open(script, 'w', encoding='utf-8') as f:
                f.write('\n'.join(lines) + '\n')
            r = subprocess.run([flatxml, 'edit', path, out, script], capture_output=True, text=True)
            if r.returncode != 0:
                if script not in r.stderr:
                    skipped += 1  # flatxml does not read the file
                    continue
                print(f'FAILED {path}: {r.stderr.strip()}')
                print('  script:\n    ' + '\n    '.join(lines))
                differ += 1
                continue
            edits += len(lines)
            got = etree.parse(out, parser).getroot()
            a, b = [], []
            shape(tree, a)
            shape(got, b)
            if a == b:
                same += 1
            else:
                differ += 1
                k = next(i for i in range(min(len(a), len(b))) if a[i] != b[i]) if a[:len(b)] != b[:len(a)] else min(len(a), len(b))
                print(f'DIFFERENT {path}: lxml {a[k] if k < len(a) else None!r}, flatxml {b[k] if k < len(b) else None!r}')
                print('  script:\n    ' + '\n    '.join(lines))
                continue
            with open(path, 'rb') as f:
                src = f.read().decode('utf-8', 'replace')
            with open(out, 'rb') as f:
                ours += changed_lines(src, f.read().decode('utf-8', 'replace'))
            theirs += changed_lines(src, etree.tostring(tree.getroottree(), xml_declaration=True,
                                                         encoding='UTF-8').decode('utf-8', 'replace'))
    print(f'{same + differ} files, {edits} edits: {same} the same tree as lxml, {differ} different, '
          f'{skipped} skipped; lines changed: flatxml {ours}, lxml serialised {theirs}')
    return 1 if differ else 0


if __name__ == '__main__':
    sys.exit(main())
