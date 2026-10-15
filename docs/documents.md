# Plan: working with documents

The first consumers of flatxml read many files at once and work on the whole: compare two
versions, merge files that each hold part of one model, change a value and write the file back.
This plan adds that, on the read-only tree: many documents read together, navigation by handle,
diff, a merged view, edits and writing. It comes before typed values and parse speed (steps 6
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
3. **Rules.** The caller says, per parent element and child name, how such children are told
   apart and put together:
   - the **key**: the texts at one or more paths below the child (`NAME`, `ITEM/ID`), or an
     attribute, compared as written or ignoring case; or none, so each child is its own;
   - whether children of one key from different files **merge** into one, or are an error;
   - whether their **order** means something, so that they must all come from one file;
   - the most there may be.

   Paths compile once to name ids. An element's identity is the path of keys from the root, the
   same in every file that holds it. A schema's annotations can be read into rules, by the caller
   that knows what they mean.
4. **Diff.** Two documents (or two sets) are compared top down: children with keys matched by
   key, the rest aligned in order (longest common subsequence over their names and contents). A
   hash per subtree, computed once, skips identical subtrees whole. The result is an edit set:
   added, removed, moved, text and attributes changed, each with both positions.
5. **Merged view.** Over a set and its rules: a merged node is the list of nodes, from any files,
   with one identity; its children are their children grouped by the rules, ordered by key (or as
   written, where order means something). Nothing is copied. What the rules forbid (one key from
   two files where it may not merge, an ordered list in two files, more than the most, two
   contributions whose texts or attributes differ) is a problem reported with every position,
   and decided by the caller (first wins, or an error).
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
2. **Writing** (design 7, unedited): the byte-for-byte round trip, which every later step relies
   on.
3. **Rules and diff** (design 3, 4), and `flatxml diff`: two files or two directories, the changes
   with their positions.
4. **Edits** (design 6), the write of an edited document, and `flatxml apply`: a diff applied to
   its old document gives the new one.
5. **Merged view** (design 5) and `flatxml merge`: many files into one, problems listed; edits
   on a merged view, written back to their own files.
6. **Three-way merge**: two changed versions of one base.

## Techniques taken from other tools

- **Subtree hashes** (step 3), as git compares trees and X-Diff compares documents: an unchanged
  subtree is one hash comparison, so diffing two versions costs in proportion to what changed.
- **Keyed matching, then ordered alignment** (step 3), as XyDiff and DeltaXML match by
  identifying attributes first: keyed elements match exactly, and only the unkeyed rest needs a
  longest-common-subsequence alignment (Myers' algorithm, as `diff` uses).
- **Changes over an unchanged original** (step 4), as a text editor's piece table keeps the file
  and a list of edits: no array is rewritten, an edit costs what it changes, and undo is dropping
  one.
- **Lossless writing** (step 2), as format-preserving editors do: the original bytes are the
  default and only what changed is serialised, which is also the fastest way to write.
