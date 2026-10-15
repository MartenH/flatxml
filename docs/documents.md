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
   (or any child) of an element named (or any element). A child takes the rule for its parent's
   name and its own, else its parent's name and any child, else any parent and its own name,
   else any parent and any child. A rule is one of three kinds:
   - **keyed**: the key is the texts at one or more paths below the child (`NAME`, `ITEM/ID`,
     `@id`, `ITEM/@id`), or what a callback returns, where paths cannot say it. With `merge`,
     children of one key (from any files) are one child; without, the second is a collision.
     A child missing every part of its key is reported and kept, as a child of its own;
   - **single**: one child of each name, identified by its name, so the occurrences in every
     fragment of the parent are one child (with `merge`; without, the second is a collision);
   - **each**: every occurrence is a child of its own. A child no rule names is of this kind.

   A keyed or each rule can be **ordered** (all its children from one file, kept as written)
   and have a **max**. Keys are compared as written or, for the whole set, ignoring ASCII case,
   and the set can name attributes whose values may differ. Paths compile once to name ids.
   An element's identity is the path of keys from the root, the same in every file that holds
   it: a key is unique in its **scope**, the nearest ancestor that is not single (a keyed or
   each child, or the root), so a single child (a wrapper) is transparent to keys. The rules'
   order is the order of their aggregations among a node's children. `parse_rules` reads them
   from text, one per line (`ITEMS ITEM key=NAME merge`). A schema's annotations can be read
   into rules, by the caller that knows what they mean.
4. **Diff.** Two documents (or two sets) are compared top down: children with keys matched by
   key, the rest aligned in order (longest common subsequence over their names and contents). A
   hash per subtree, computed once, skips identical subtrees whole. The result is an edit set:
   added, removed, moved, text and attributes changed, each with both positions.
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
   line: a collision, an ordered aggregation in two files, too many children, two fragments
   whose text or an attribute differ, one key under two names (or roots named differently), a
   child without its key. The view keeps the first (in the set's order, then document order);
   a caller for whom a problem is an error refuses the view when there is one.
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
- **A diff applied to its old document gives the new one**, tree for tree: on pairs made by the
  mutation tools (random edits, swaps, removals, repeats), whose differences are known, and on
  real files against later versions of themselves.
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
   child, 820 single), merge in 0.23–0.33 s on one thread into 1.68M merged nodes; the view
   adds about 100 MB to the set's 250 MB. 144,467 nodes are found again by their key paths in
   about 0.4 µs each, and 1.37M children by name and key in about 17 ns each. The rules find
   540 problems, all values that differ: 534 in two attributes that differ from file to file
   (one names the schema, one is an identifier), which `ignore` leaves out, and 6 in the text
   of two copies of one definition.
4. **Diff** (design 4), and `flatxml diff`: two files or two directories, the changes with their
   positions.
5. **Edits** (design 6), the write of an edited document, and `flatxml apply`: a diff applied to
   its old document gives the new one; edits on a merged view, written back to their own files.
6. **Three-way merge**: two changed versions of one base.

## Techniques taken from other tools

- **Subtree hashes** (step 4), as git compares trees and X-Diff compares documents: an unchanged
  subtree is one hash comparison, so diffing two versions costs in proportion to what changed.
- **Keyed matching, then ordered alignment** (step 4), as XyDiff and DeltaXML match by
  identifying attributes first: keyed elements match exactly, and only the unkeyed rest needs a
  longest-common-subsequence alignment (Myers' algorithm, as `diff` uses).
- **Changes over an unchanged original** (step 5), as a text editor's piece table keeps the file
  and a list of edits: no array is rewritten, an edit costs what it changes, and undo is dropping
  one.
- **Lossless writing** (step 2), as format-preserving editors do: the original bytes are the
  default and only what changed is serialised, which is also the fastest way to write.
