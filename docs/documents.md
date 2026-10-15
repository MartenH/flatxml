# Plan: working with documents

The first consumers of flatxml read many files at once and work on the whole: compare two
versions, merge files that each hold part of one model, change a value and write the file back.
This plan adds that, on the read-only tree: many documents read together, navigation by handle,
a merged view, diff, edits and writing. It comes before typed values and parse speed (steps 6
and 7 of [plan.md](plan.md)), which it does not depend on.

Everything here is generic. How elements are identified and which ones merge are rules the caller
gives, per element name; nothing here knows a vocabulary. A schema can supply them (its
annotations are kept for that), but none is needed.

## Principles

- **The originals never change.** A document stays the read-only tree over its mapped file.
  Edits, merges and diffs are layers over documents, never rewrites of them.
- **Everything points back.** A node in a merged view, a change in a diff, an edited value: each
  names the file, line and column it came from.
- **Untouched bytes are written back as they were.** Writing an edited document copies every
  unchanged range of the original file verbatim, comments, whitespace and quoting included, so
  changing one value changes one line on disk.
- **One representation of change.** An edit set is what an editing caller builds, what a diff
  produces and what a merge applies. A diff applied to its old document gives its new one.
- **The rules are the caller's.** What identifies an element (an attribute, a child's text, its
  position), what merges and what conflicts: given per element name, nothing built in.

## Design

1. **Document sets.** A `DocSet` reads many files, in parallel, into documents that share one
   name table, so a name is the same id in every file and comparing names across files is
   comparing integers. A node is a handle, `(document, index)`.
2. **Handles and navigation.** A missing node is a valid empty handle, so a chain of lookups needs
   no check at every step; typed reads take a default. Children and descendants are iterated
   without allocating. Paths (`find('a/b')`, `iter('item')`) compile once into name ids.
3. **Rules** (built). A `RuleSet` is a list of `Rule`s, one per aggregation: the children named
   (or any child) of a parent the rule names. A parent is named by its element name (`b`), by the
   names of its nearest ancestors too (`a/b`: a `b` whose parent is an `a`), by a class the set's
   classifier gives it (`%c`), or as any parent. The classifier is a callback for what names
   cannot say; it reads a `Parent`, all of which is complete while the view is built: the node's
   name and key, the nodes of the set it is made of, and its ancestors' names and keys. The most
   specific wins: the class, then the longest path, then the name alone, then any parent; for
   each, the rule for the child's own name before the rule for any child. So one wrapper name can
   hold children keyed and merged under one kind of holder and each its own under another. Which
   rules apply to a parent is worked out once per parent name, class and set of matching paths,
   and the classifier is asked only when a rule names a class, so the rules cost nothing per child
   that the names alone did not. A rule is one of three kinds:
   - **keyed**: the key is the texts at one or more paths below the child (`NAME`, `ITEM/ID`,
     `@id`, `ITEM/@id`, or the child's own text: `.`, its text beside its children without the
     indentation, absent when it has none), or what a callback returns, where paths cannot say it.
     A part ending in `+` reads every element at its path, in order, its text or attribute (''
     where the attribute is absent, so the number and order of the elements count), joined with a
     separator text cannot hold (`REFS/REF+`); a key is shown with its parts joined by `,` and the
     occurrences of a part by `|`. With `merge`, children of one key (from any files) are one
     child; without, the second is a collision. A child missing every part of its key is, per rule
     (`keyless`), reported and kept as a child of its own, or the one child of its name with the
     empty key, which merges like a single child and, like one, is transparent to keys below it;
     there, a key with no text in any part is the empty key too, as an absent one is;
   - **single**: one child of each name, identified by its name, so the occurrences in every
     fragment of the parent are one child (with `merge`; without, the second is a collision);
   - **each**: every occurrence is a child of its own. A child no rule names is of this kind.

   A keyed or each rule can be **ordered** (all its children from one file, kept as written) and
   have a **max**, both over all the names it holds together. Keys are compared as written or, for
   the whole set, ignoring ASCII case, and the set can name attributes whose values may differ.
   Paths compile once to name ids. An element's identity is the path of keys from the root, the
   same in every file that holds it: a key is unique in its **scope**, the nearest ancestor that is
   not single (a keyed or each child, or the root), so a single child (a wrapper) is transparent to
   keys. The rules' order is the order of their aggregations among a node's children. `parse_rules`
   reads them from text, one per line (`ITEMS ITEM key=NAME merge`), with the set's settings on
   lines that start with `!`, which no element name can (`!fold`, `!ignore ID`); a key part `.` is
   the child's own text (`key=.,@kind`), which no element name can spell either. `format_rules`
   writes a rule set back as that text. Read back, it is the same set, but for spellings that
   compile alike, each written as one: the parent '' as `*`, no child names or [''] as `*` (read
   back as [`*`]), and the key part '' as `.`. A key function cannot be written and is refused; the
   classifier is not written, and is given to the set read back. A schema's annotations can be read
   into rules, by the caller that knows what they mean.

   *Not expressed: items with no element of their own*, such as a wrapper holding, per item, a
   run of elements of a group (`<NAME/><VALUE/><NAME/><VALUE/>`, an item starting at each
   `NAME`). Every merged node is a list of `(document, element)` fragments, and everything
   built on the view relies on that: positions, the subtree hash and the order of a node's
   children (diff), the bytes an edit copies or replaces (edits, writing). A run-item could be
   anchored at its first element, with its other elements as its children; but then the
   anchor would be both the item and its own first member, an edit removing the item would
   have to remove the run, and the writer would have to copy runs rather than subtrees. That is
   a change to every layer, so it waits for a consumer that needs it; until then such a wrapper
   is merged by the rules of its run's elements (each element of the run keyed or single by
   its own name), which keeps what the files say but not which elements made one item.
4. **Diff** (built). `diff(old, new)` compares two merged views: two sets, each read by the
   same rules, or two documents (`diff_docs`, `Doc.view`), which with no rules are each their own
   tree. So the files a model is kept in, and the order the rules impose, are not changes. The
   views are compared top down from the roots. Children the rules identify are matched by
   identity: keyed ones by key, single ones by name. The rest are aligned in order: a longest
   common subsequence of their subtrees (Myers' algorithm, after the common start and end are
   taken off), then, between the subtrees that align, children of one name paired in order.
   Myers keeps, round by round, only the diagonals that round can reach (memory in the square
   of the differences, not their product with the list), and past a bound on the differences
   in one list (1,000) the rest of it is matched greedily, each value's places in a queue, and
   names are paired the same way, so no list costs quadratic time. Every node's subtree is
   hashed once (its name, its own text run by run with each run's place among the children,
   its attributes, each name with its value and in any order, and its children's hashes in
   order, each part from a seed of its own so no part can stand in for another; the two views
   on two threads), and a pair whose hashes agree is equal and not entered. Of the matched children, those off
   a longest increasing run of their old places are moved, and a removed subtree equal to an
   added one, anywhere, is moved too. A `Change` is removed, added, moved, text or attribute
   changed, naming the node in each view (every fragment of it, so every file and line).
   Text compared is a node's own text, run by run (`text_runs`: beside child elements, each run
   with the number of children before it; a child's text is the child's), so text that moves
   among the children is a change. Names are compared as written.

   A change carries what applying it needs: an added or moved node names the node of the old
   view it goes under and its index among the new parent's children. Applied to the old view,
   remove every removed node and lift out every moved one, then, parent by parent, put each
   added or moved node at its index, lowest first: the nodes that stay are already in their
   new order, so each index is right when it is used. Then set the attributes, and each changed
   text's runs, which a text change carries, in their slots among the new children. A
   test applies diffs this way to a tree model and gets the new document every time. Step 5
   does it with edits over the document's bytes, written back to the files.
5. **Merged view** (built). `DocSet.merge(rules)` reads every document of a set as one: the
   merged root is the documents' roots, and a merged node's children are its fragments'
   children put together by the rules, then ordered: by aggregation in the rules' order (those
   no rule names last); within one, by key, or as written (the set's order, then document
   order) for each and ordered aggregations. A merged node (`MNode`) is a handle like `Node`: its
   name, key, key path, parent, children, its child by name and key, and its fragments, the
   `(document, node)` pairs it is made of, which is all it keeps: nothing is copied. Built top
   down, so a node's children are consecutive and so are its fragments; a child by name and
   key is a read of up to 16 children or one hash probe, and a node by its key path one probe
   per key. What the rules forbid is a `Problem` with every node involved, so every file and
   line: a collision, a key used in its scope already (under another parent or name), an
   ordered aggregation in two files, too many children, two fragments whose text (all of it,
   where it is mixed with elements) or an attribute differ, one key under two names in one
   aggregation (or roots named differently), a child without its key. The view keeps the
   first (in the set's order, then document order), and what it leaves out is in the problem,
   every contribution of it; a caller for whom a problem is an error refuses the view when
   there is one.
6. **Edits.** An edit set over a document or a merged view: set text, set or remove an attribute,
   insert an element (written as a fragment, or copied from any node), remove one, move one. Kept
   as changes keyed by node, so the tree's arrays are never rewritten, and read through: an
   edited view answers like a document. An edit on a merged view lands in the files it came
   from: a value held in several files changes in each, and a new element goes to the file the
   caller names, so a model kept in many files stays in many files. A three-way merge is two diffs from a common base,
   applied together where they change different nodes and reported where they change the same.
7. **Writing.** A document, an edited document (each changed file of a set, back to its own
   path) or a merged view (as one document) is written as XML: unchanged
   subtrees as their original bytes, changed ones serialised with the escaping their place needs
   (text, attribute, CDATA), and the namespace declarations a moved or inserted node needs
   carried with it.

## Verification

Round trips, which need no oracle:

- **Writing an unedited document gives its file, byte for byte**: `testdata/`, generated
  documents, and locally the real-world files.
- **A diff applied to its old document gives the new one**, tree for tree: on pairs made by
  random edits (removals, additions, moves, texts and attributes changed), and on files edited
  where the edits are known (`tools/diff_vs_edits.py`: a removal, a repeat, a swap, a text or an
  attribute changed, each reported as exactly that one change).
- **A file split into parts and merged back is the file**: a document divided among several files
  by its keys, merged, compares equal to the original as a tree.
- **An edit written and read back is the edit**, and the same edit made by lxml gives the same
  tree.

## Steps

1. **Document sets, handles and navigation** (design 1, 2, done). `DocSet` parses in parallel and
   joins each document to one table in the order given: 560 real-world files (169 MB) load in
   about 80 ms on 16 threads, 230 ms on one. Handles cost what raw index loops cost: on the
   500 MB benchmark, visiting the children of every element (12.6M) takes 34–37 ms either way,
   and every element of one name 8–10 ms. The README's examples type-check in CI
   (`scripts/check_readme_examples.sh`). The library moved into `flatxml/`, so the checkout no
   longer has to be named `flatxml`.
2. **Writing** (design 7, unedited; done): the byte-for-byte round trip, which every later step
   relies on. A node's bytes run from its `<` to the end of its end tag, and the bytes between
   nodes are copied as they are. The end is found when asked for (from the end of the node's last
   descendant, read on to its end tag) rather than stored: on the 500 MB benchmark an array
   filled at parse time made the parse no faster or slower than the noise (best of 15, 1,060 ms
   against 1,027 ms) but cost 4 bytes a node (52 MB, 28 to 32 bytes a node), while finding the end
   of every one of its 13M nodes on demand takes 150–290 ms, and a write asks it only of the nodes
   it copies or walks. Written into memory, the 500 MB document takes 0.35–0.41 s whole; 0.62–0.85
   s node by node (each node located on its own, adjacent copies joined into one); 1.9–2.4 s with
   every node from the tree. To a file, synced to disk before it replaces the old one: 1.1 s whole.
   Written unchanged, every file is itself, byte for byte, both whole and node by node, and written
   from the tree it reads as the same tree, every run of text compared whitespace included:
   `testdata/`, generated documents up to 500 MB, 560 real-world files (169 MB), 34,187 other XML
   files (224 MB), and 10,809 mutations of the test documents that parse. (Text that is only
   whitespace, written as references in the source, must be written as references again, or a
   parser drops it: 31 of the 34,187 files hold such text.) The emitter takes a plan that says, node by node, whether to
   copy it whole, copy its tags and walk its children, or write it anew, which is where edits
   plug in; escaping (text, attribute values with the quote that needs fewer escapes, CDATA) and
   an element written from the tree's parts with the namespace declarations in scope are in
   place for them. `flatxml write` and `flatxml roundtrip` run it from the command line.
3. **Rules and the merged view** (design 3, 5, done), and `flatxml merge`: many files read as
   one, the problems listed with their positions. A document split into one to six files by
   its keys (200 random documents) merges back to the document, node for node. The 560
   real-world files (1.78M elements), with a rule per aggregation (116 keyed by the text of a
   child, 820 single), merge in about 0.19 s on one thread into 1.68M merged nodes; the view
   adds about 105 MB to the set's 250 MB. 144,467 nodes are found again by their key paths in
   about 0.25 µs each, and 1.37M children by name and key in about 12 ns each. The rules find
   540 problems, all values that differ: 534 in two attributes that differ from file to file
   (one names the schema, one is an identifier), which `!ignore` leaves out, and 6 in the text
   of two copies of one definition. Rules by ancestor path and by class, keys of every
   occurrence and an empty key for children without one came next, at no cost to a set that
   does not use them: on a loaded machine, six runs each took 246–296 ms against 248–287 ms
   before, and 265–309 ms with a path rule beside every rule of the set (1,873 rules), so that
   every parent's ancestors are read.
4. **Diff** (design 4, done), and `flatxml diff [--rules FILE] A B`: two files, directories or
   lists, the changes with their paths and positions, exit 0 when there are none and 1 when
   there are. Diffs of 400 random documents, each changed by one to four random edits, applied
   to the old document as design 4 says, give the new one (with full alignment and with the
   greedy one). With rules, 300 documents with known edits get exactly those changes, no more.
   On 510 of the 560 real-world files (the other 50 lxml does not write back as the same tree),
   5,090 copies each with one known edit (a removal, a repeat, a swap, a text or an attribute)
   are each reported as exactly that one change. Two versions of 108 of the files (16 MB; 4
   files differ, 431 lines by `diff -r`) compare as 131 changes with the rules (3 removed, 3
   added, 5 texts, 120 attributes), read and merged in 60 ms and compared in 15 ms. The 560
   files against a copy with 267 texts changed: 268 changes without rules (266 texts; one, in a
   list of equal values, aligned as a removal and an addition), compared in about 0.2 s, of
   which hashing both sides' 1.78M nodes is 0.18–0.2 s; with the rules, a changed key is a
   removal and an addition, and a key shared by fragments of one node in several files splits
   it. Lists that defeat the alignment stay linear: 50,000 siblings, none equal on the other
   side, compare in 40–75 ms, and 15,000 changes among 30,000 siblings print in 50 ms in all.
5. **Edits** (design 6) on one document (done), the write of an edited document, and `flatxml
   edit`. An edit set (`Doc.edit`) keeps its changes in a map keyed by node: an element is a piece
   (0, the document; others, inserted content: a parsed fragment, or a node of any document) and
   its index there, so edits go on inside inserted content as on the document. Text is set as a
   string (before the first child) or as runs in slots, a diff's form. A child is put before an
   original child of its parent (or at the end), so no list of children is rewritten, and an index
   means the parent's child elements as edited (a diff's). Read through, an `ENode` answers name,
   text, attributes, children and parent as edited. Written through the emitter's plan: an
   untouched subtree is copied whole, the elements above a change are walked, and an element with
   changes of its own is written from its source with them: its start tag copied but for the
   attributes changed, the bytes between its children kept, a removed child taking the indentation
   before it, an inserted one given that of the child it goes before. An element moved or copied
   keeps the namespaces of where it was read (declarations restore those that differ, `xmlns=""`
   included); a fragment those where it is put first.

   Verified: a test per kind of edit and their combinations; 30,000 random edit sets (1 to 8 edits
   each, of every kind, on random documents with comments, mixed content, CDATA and namespaces)
   give, written and read back, the tree a model of the same edits gives, with every element and
   namespace as expected, the bytes before and after the root unchanged, and every element with no
   edit below it byte for byte what it was. Against lxml making the same edits
   (`tools/edits_vs_lxml.py`): on the 560 real-world files, three seeds of 10 to 20 edits each
   (28,000 edits), every tree the same; and on 33,377 other XML files found on one machine (333,770
   edits), every tree the same (543 skipped: not read by one of the two, or not UTF-8). Written,
   flatxml's files differ from the originals in 64,802 lines for the first seed on the 560 where
   lxml's serialisation of the same trees differs in 77,150, and in 359,038 on the others where
   lxml's differs in 1,015,501. An edited 500 MB document writes in the time an unedited one does
   (0.66–0.83 s against 0.70–0.87 s to a file).

   Applying a diff (`flatxml apply`, next) is a thin layer on this, and a test does it
   (`apply_diff` in `edit_test.v`): a removed node is `remove`d, a moved one `remove`d and later
   `place`d, an added one `insert_copy`d from the new document, at its index, lowest first, and
   then texts (`set_text_runs`, run by run in their slots among the children) and attributes set.
   One rule comes with it: a diff places text by slot and reports a text change only where the runs
   differ, so an element whose children change (a child removed, added, or moved out or in) must
   have its runs set again at their old slots, unless it has a text change of its own. Diffs
   between 18,000 random documents and random edits of them (six seeds), applied this way, give the
   new document (as a diff compares it). Edits on a merged view are edit sets on the documents its
   nodes come from, one per document: a value held in several is set in each, and a new element
   goes to the document the caller names.
6. **Three-way merge**: two changed versions of one base.

## Techniques taken from other tools

- **Subtree hashes** (step 4, built), as git compares trees and X-Diff compares documents: an
  unchanged subtree is one hash comparison, so comparing two versions costs the hashing, once,
  and then in proportion to what changed.
- **Keyed matching, then ordered alignment** (step 4, built), as XyDiff and DeltaXML match by
  identifying attributes first: keyed elements match exactly, and only the unkeyed rest needs a
  longest-common-subsequence alignment (Myers' algorithm, as `diff` uses).
- **Changes over an unchanged original** (step 5), as a text editor's piece table keeps the file
  and a list of edits: no array is rewritten, an edit costs what it changes, and undo is dropping
  one.
- **Lossless writing** (step 2), as format-preserving editors do: the original bytes are the
  default and only what changed is serialised, which is also the fastest way to write.
