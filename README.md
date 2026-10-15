# flatxml

A flat, zero-copy XML parser in V (V3), with XML Schema support being built (`flatxml.xsd`):
see [`docs/plan.md`](docs/plan.md).

flatxml is generic: it knows nothing about any XML vocabulary.

```v
import flatxml

// One file, read through handles. A missing node is an empty handle, so lookups chain, and a
// typed read takes a default.
mut doc := flatxml.parse_file('model.xml')!
for item in doc.root_node().child('items').children_named('item') {
	println('${item.attr('id')}: ${item.child('price').f64(0)} at ${item.pos()}')
}
// Namespaces are resolved only when asked for; a document read without them costs nothing extra.
doc.resolve_namespaces()!
println('{${doc.ns_uri(doc.ns_of(doc.root()))}}${doc.local_name(doc.root())}')

// Many files as one set: read in parallel, sharing one name table, so a name has one id in all.
mut set := flatxml.DocSet.new()
for e in set.load(['a.xml', 'b.xml'], namespaces: true) {
	eprintln(e.msg) // names the file, and the line where there is one
}
items := set.tab.path('items/item') // compiled once, for every document of the set
for d in set.docs {
	println('${d.path}: ${d.root_node().find_all(items).len} items')
}
```

A model kept in many files reads as one through a merged view, by rules the caller gives: how
children are identified (by a key, by their name, or not at all) and whether those of one
identity from different files are one. Nothing is copied: a merged node is the list of nodes it
is made of, from any of the files.

```v
import flatxml

// An item is identified by its name child, and the items of one name in different files are
// one item; items is a wrapper, and every child of an item is single.
rules := flatxml.parse_rules('
model items single merge
items item key=name merge
item * single merge
') or { panic(err) }
mut set := flatxml.DocSet.new()
set.load(['part1.xml', 'part2.xml'])
mut m := set.merge(rules) or { panic(err) }
for p in m.problems {
	eprintln(m.describe(p)) // what the rules forbid, with every file and line involved
}
pump := m.at_path('/pump') // by its key path, which a wrapper is not part of
println('${pump.child('price', '').text()}, from ${pump.fragment_count()} files:')
for f in pump.fragments() {
	println('  ${f.pos()}')
}
```

Two versions compare as their merged views, so with rules the files a model is kept in do not
count, and without rules each document is its own tree. Each change names the node in both
versions, with its file and line.

```v
import flatxml

old := flatxml.parse_file('old.xml') or { panic(err) }
new := flatxml.parse_file('new.xml') or { panic(err) }
mut d := flatxml.diff_docs(old, new, flatxml.RuleSet{}) or { panic(err) }
for k in 0 .. d.changes.len {
	// `~ /model/items/item[2]/price: "12" -> "14"  old.xml:7:5 -> new.xml:7:5`
	println(d.describe(d.changes[k]))
}
```

The library is the `flatxml/` folder (`flatxml`, and `flatxml.xsd` below it); a project vendors
that folder at a stated commit.

## Design

**Nodes** are seven parallel `u32` arrays in document order: `tag` (an interned name id), `parent`,
`end`, `src_off`, `text_off`, `text_len` and `attr_lo`. Attributes use three more arrays. Because
the nodes are stored in preorder, the tree links come for free:

```
first child of i    i + 1, if i + 1 < end[i]
next sibling of i   end[i], if end[i] < end[parent[i]]
subtree of i        i .. end[i]
```

So there are no child or sibling pointers, skipping a subtree is a single read, and "every
element named X" is a linear scan of one array. A node takes 28 bytes and an attribute 12.

**Text** is never copied while parsing. Spans point into the memory-mapped file (on Windows, the file read into memory). Entities and line
endings are decoded only when `text()` or `attr_value()` is called, and only if the span needs it.
References are checked at parse time, so decoding can never fail. An element whose only content
is text keeps that text on the element. Text nodes exist only for mixed content.

**Parsing** is one forward pass. `memchr` jumps to the next `<`, names are interned through a
small hash table keyed on the source bytes, and the `parent` array is the stack of open elements.

**Names** are interned in a table (`Names`) the document points to. The documents of a set
(`DocSet`) share one: files are parsed on up to 16 threads, each into a table of its own, then
joined to the set's in the order given, its ids rewritten in one pass over its arrays. So across
any number of files a name is one integer, and the result does not depend on which thread
finished first. 560 real-world files, 169 MB, load in about 80 ms on 16 threads (230 ms on one),
with 491 distinct names among them.

**Handles** (`Node`) are a document and an index. A missing node is an empty handle: a lookup on
it gives another, a read gives `''` or the default asked for. Children and descendants iterate
without allocating (descendants are a scan of the `tag` array), and a path (`a/b`) compiles once
to name ids.

**Merged views** (`DocSet.merge`) are built top down over a set, one merged node at a time, so a
node's children are consecutive in its arrays and so are its fragments, the `(document, node)`
pairs it is made of. Children are grouped by rule, then by key, and ordered by key, or as written
where the rule says order matters. A rule names its parent by name, by a path of ancestor names,
or by a class a callback gives, the most specific winning, and the rules that apply are worked
out once per kind of parent. A key is unique in its scope, the nearest ancestor that is not a
single child, so a node is also found by its key path: one hash probe per key. 560 real-world
files (1.78M elements) merge in about 0.2 s on one thread. The rules, and the problems the view
reports, are in [docs/documents.md](docs/documents.md).

**Diffs** (`diff`) compare two merged views top down. Children the rules identify are matched
by identity, and the rest are aligned by a longest common subsequence (Myers). Every subtree is
hashed once, so an unchanged one is skipped whole, and comparing two versions of 1.78M nodes
costs the hashing (about 0.2 s, both sides at once) and then what changed. Each change says where it
goes in the old view, so a diff can be applied to it ([docs/documents.md](docs/documents.md)).

**Namespaces** are resolved on request, by `resolve_namespaces`, in a second linear pass: one
more array beside the nodes (each element's namespace id) and one beside the attributes. Names
are split into prefix and local name once per distinct name, not per node, and bindings are kept
in a table indexed by prefix, undone when the declaring element ends. It applies the errors of
Namespaces in XML 1.0: unbound prefixes, names that are not qualified names, misuse of the
reserved `xml` and `xmlns` prefixes and namespaces, undeclared prefixes, and attributes with the
same expanded name.

**Writing.** A document is written back by copying its source: a node's bytes run from its `<` to
the end of its end tag, and the bytes between nodes (comments, processing instructions, the
whitespace the tree drops, the prolog before the root and whatever follows it) are copied as they
are, so a document written unchanged is its file, byte for byte. Only a node's start is stored;
its end is found when it is asked for, by reading on from the end of its last descendant to its
end tag, so the parse and the 28 bytes a node takes are unchanged. What is not copied is written
from the tree's parts: names as interned, values decoded and escaped again for where they go
(text, with text that is only whitespace as character references so that it is still read as
text; an attribute value between the quote that needs fewer escapes; CDATA), and an element
written on its own (`outer_xml`) carries the namespace declarations in scope where it was. A
merged view is written as one document the same way (`Merged.write`, `flatxml merge -o OUT`): a
node from one file with nothing merged into it below is copied whole, and any other is written
from its first contribution with its merged children, each after the indentation and comments
that stood before it. A set of one document writes its file byte for byte unless the rules
reorder its children. `root_attrs` writes the root with attributes set, the rest unchanged
(`m.write_file(path, root_attrs: [flatxml.EAttr{'version', '2'}])`).

```v
import flatxml

mut doc := flatxml.parse_file('model.xml')!
doc.write_file('copy.xml')! // byte for byte; over its own file too
item := doc.root_node().child('items').child('item')
println(doc.subtree_bytes(item.i)) // the element as the file has it
println(doc.outer_xml(item.i)) // written from the tree, with its namespace declarations
println('<v>${flatxml.escape_text('a < b')}</v>')
```

**Editing.** An edit set (`Doc.edit`) keeps changes beside the document, keyed by node, and never
rewrites its arrays: set an element's text (or its runs of text, each after so many children), set
or remove an attribute, insert an element (parsed from a string, or copied from any node of any
document), remove one, move one. It reads through its changes (`ENode`: name, text, attributes,
children, parent, as edited), so a chain of edits can be made on what earlier ones did, and inside
inserted content too. Written, it copies every byte no edit touched; an element with a changed
attribute keeps its other attributes as written, a removed element takes the indentation before it,
and an inserted one gets its neighbours'. An element moved or copied keeps the namespaces of where
it was read: where they differ at its new place, it is given the declarations that restore them,
`xmlns=""` included. A fragment is read in the namespaces in scope where it is first put, and
refused if a prefix it uses is bound neither there nor in it. `flatxml edit` applies a script of
edits from the command line. A merged view is edited the same way (`Merged.edit`): a value in
every file that holds it, structure in the file the caller names, each changed file written back
to its own path; and a diff is applied to its old view so (`Diff.apply`, `flatxml apply`). Two
changed versions of one base merge the same way (`merge3`, `flatxml merge3`): what only one side
changes is taken, the same change on both once, and where they disagree ours is kept and the
conflict listed, with its place in all three.

```v
import flatxml

mut doc := flatxml.parse_file('model.xml')!
mut ed := doc.edit()
items := ed.root().child('items')
ed.set_attr(items.children()[0], 'price', '9.50')!
ed.insert(items, 0, '<item id="new"/>')!
ed.remove(items.child('obsolete'))!
ed.write_file('model.xml')! // every byte no edit touched stays as it was
```

**XML Schema.** `flatxml.xsd` compiles schema documents into flat tables the same way: components
in arrays, referring to each other by index. `xsd.load(paths...)` reads the documents and what
they import, resolves every reference, expands groups and attribute groups, and gives a type
that extends another its base's content and attributes. It supports the subset of XSD 1.0 in
the plan and refuses everything else by name and position (`xsd:all at s.xsd:12:5: ... not
supported`), because a validator that skips a constraint calls invalid documents valid. Each
`xsd:appinfo` is kept for the consumer, its content written back as XML, with its owner, where
it is written (`appinfo_pos`), and for an attribute or a reference to one, the attribute
declaration it is about; `appinfo_of` finds an owner's entries. Expanding a group keeps its
identity: a group reference becomes the group's sequence or choice and names the group it
includes (`Particle.group`), and the named model groups and attribute groups can be read
(`groups`, `attribute_groups`; these and `appinfo` are read-only).

`xsd.validate(mut doc, schema)` checks a document against a compiled schema. It gives each
element the declaration its context names (one more array beside the nodes) and reports what the
schema does not allow, with positions: an element not declared where it is, an undeclared or
missing attribute, text in element-only content, children in simple content, an abstract type,
`xsi:nil="true"` (no declaration can be nillable here). `xsi:type`, and a schema the document
names itself (`xsi:schemaLocation`, `xsi:noNamespaceSchemaLocation`), are reported as not
supported rather than guessed at. A value (an element's text, an attribute's value) is checked
against its type after its whitespace is normalised by the type's rule: first the built-in type's
lexical form (numbers within their type's range, booleans, dates, times and durations with their
calendar, names, binaries), then each derivation step's facets: patterns, enumerations (compared
by value: `1.0` equals `1`, `true` equals `1`) and `maxLength` (characters, octets or list items).
IDs must be unique in a document and every IDREF must name one; a QName value's prefix must be
declared where it is written. The children's order and number are checked against the type's
content model: a child where the model does not expect it, one too many, one missing. A model
whose counts are all 0, 1 or unbounded (nearly all of them) is decided by its Glushkov automaton,
one table read per child, built on first use; other counts by a walker that keeps a counter per
group, so `maxOccurs="5000"` is a number, not 5,000 states. The walker also explains whatever the
automaton refuses.

When a schema compiles, its facets are checked too: an enumeration value must be valid for its base
type, `maxLength` must apply to the type and not exceed its base's, and `whiteSpace` must not
loosen its base's. So are its content models: deterministic (Unique Particle Attribution: a child
is matched by one particle, without looking ahead), and one type for elements of one name
(Element Declarations Consistent). An attribute group may not include itself, whether a type
uses it or not.

**Patterns** (`xsd.compile_pattern`) are XSD regular expressions run by a linear-time engine:
a pattern compiles to an NFA, which validation runs as a DFA built lazily as values meet it (a
table step per byte), and which falls back to a Pike VM past 2,000 states, so no pattern and no
input can make it backtrack. `\d`, `\w` and `\p{...}` follow the Unicode 15.0 categories. An
invalid pattern is a compile error of its schema, at its position.

```v
import flatxml
import flatxml.xsd

s := xsd.load('model.xsd')!
mut doc := flatxml.parse_file('model.xml')!
v := xsd.validate(mut doc, s)!
for f in v.findings {
	println('${doc.pos(f.node)}: ${f.msg}')
}
```

## Verified

Results marked *earlier* predate this repository; the parser has not changed since.

- **Unit tests** (`v test .`) cover structure, mixed content, entities, CDATA, namespaces, every
  error message, and every prefix of a document (each one parses or fails cleanly).
- **Against expat**, element for element, attribute for attribute, text for text, with namespaces
  resolved and without: identical on 697 real-world configuration files (not included), on
  `testdata/` and on generated documents. `testdata/` holds `tricky.xml` (BOM, CRLF, DOCTYPE with
  an internal subset, CDATA, numeric references, UTF-8 names, mixed content, attribute
  whitespace), `namespaces.xml` (scopes, redeclaration, an undeclared default, reserved prefixes)
  and one file per namespace error, each rejected by both. *Earlier:* identical on generated
  files of 20 MB and 100 MB and on a 142 MB merged one.
- **Writing back**: written unchanged, every file is itself byte for byte, both copied whole and
  node by node (each node located on its own, the bytes between nodes copied), and written from
  the tree it parses to the same tree (every run of text compared, whitespace included), on
  `testdata/`, generated documents up to 500 MB, 560 real-world configuration files (169 MB) and
  34,187 other XML files found on one machine (224 MB). A unit test covers each construct that
  has to survive (CDATA, comments and processing instructions between and inside elements, a
  DOCTYPE with an internal subset, CRLF, references, whitespace written as references, `<a/>`
  beside `<a></a>`, both quotes, whitespace the tree drops, what follows the root, a byte order
  mark).
- **Edits**: 30,000 random edit sets (every kind of edit, on random documents with comments, mixed
  content, CDATA and namespaces), written and read back, give the tree a model of the same edits
  gives, every name in its namespace, and every element no edit reached byte for byte what it was.
  Diffs between random documents and random edits of them, applied through an edit set, give the
  new document (18,000 pairs). The same random edits made by lxml (`tools/edits_vs_lxml.py`) give
  the same tree on 560 real-world configuration files (28,000 edits) and 33,377 other XML files
  (333,770 edits).
- **Mutation fuzzing** against expat (`tools/fuzz_vs_expat.py`): random edits, plus namespace
  edits that keep a document well-formed (renaming a prefix, dropping a declaration); 24,000 cases
  over six seeds, with and without namespaces. No crash, no valid document refused, no tree
  different. The cases only expat rejects are the limitations below. Removing either
  unbound-prefix check from the resolver makes the fuzzer fail within 500 cases.
- **Past 2 GiB** (*earlier*): a 3 GB file (32.8M nodes, offsets beyond 2³¹) parses in 2.8 s.
- **Schemas**: four large real-world schemas (5–10 MB each, up to 9,021 element declarations and
  5,318 complex types) compile with nothing refused, in 27–53 ms. Their counts of elements,
  types, enumeration values, patterns and appinfo match an independent count of the files.
- **The W3C XML Schema test suite** (`tools/xsts.py`, 14,367 XSD 1.0 schema tests): no valid
  schema rejected. 3,519 valid schemas compile and 1,025 invalid ones are rejected; 9,788 use
  constructs outside the subset and are refused (505 of them for a pattern using a Unicode block
  or `\i`/`\c`); 34 invalid ones compile because the rule they break is not checked (attribute
  defaults and fixed values, among others); one is a documented divergence (a missing type is an
  error at once). Of 5,811 instance tests whose schema compiles, no valid document is reported
  and no invalid one passes: 3,347 valid documents pass, 2,444 invalid ones are reported, and 20
  use something unsupported (`xsi:type`, a schema the document names itself, XML 1.1).
- **Patterns against libxml2** (`tools/patterns_vs_lxml.py`): the 43 patterns of the real-world
  schemas and `testdata`, on 7,190 strings made to probe them, agree on every verdict. Over the
  suite's 1,240 patterns they disagree on 22 patterns libxml2 compiles and flatxml rejects, and
  on 112 of 37,591 strings; the suite expects flatxml's answer for 21 of the 22 (the 22nd was a
  flatxml bug, fixed), and the strings are libxml2's automaton going wrong (it rejects
  `foo7777baz` for `foo\w*\d{4}baz`) or treating `^` as an anchor.
- **Validation of real-world files**: 463 of the 697 files, against the schema each declares,
  agree with libxml2 on every verdict (461 valid; 2 invalid, reported at the same line).
- **Content models against libxml2** (`tools/content_vs_lxml.py`): copies of the 461 valid files,
  each with one edit where a content model decides (two neighbouring children swapped, one removed,
  one repeated), 11,500 copies over four schemas, and 300 copies of a generated 8 MB document:
  the same verdict as libxml2 on every one. A unit test also runs every sequence of up to four
  children, and random longer ones, through both the automaton and the walker, which must agree.

## How it compares

Each tool below does different work, so the tables say what each one builds and checks. What
each is good at, and what it is not:

- **flatxml** builds a read-only tree of the whole document, navigable in every direction, in
  28 bytes a node, with every name interned and text left in the file until it is read, and
  validates against a schema in a fraction of the parse. Namespaces and XSD validation are layers
  over that tree, each opt-in. It writes a document back byte for byte, and edits are a layer
  over the tree that writes only what they change. It is not good at: changing a document in place
  (the tree is read-only; an edit set reads through its changes, which costs a little per read),
  documents that do not fit in memory or exceed 4 GiB (it maps the
  whole file; there is no streaming mode), XML 1.1, DTDs (skipped), and names and UTF-8 (not
  checked). Its XSD support is a measured subset. It is a V library.
- **quick-xml** (Rust) is a pull parser: it hands out events and keeps no tree, so it streams a
  document of any size in a small buffer, and it also writes XML. Navigating a document (up,
  sideways, back) is left to the caller. It does not validate.
- **pugixml** (C++) builds a mutable tree in place, with XPath 1.0, and saves it again. It does
  not process namespaces and does not validate.
- **lxml** (libxml2, Python) is the complete one: XSD, DTD, RELAX NG, XPath, XSLT, namespaces,
  HTML. Its XSD verdicts on the W3C suite are right 97% of the time for schemas and 99.6% for
  documents. On large documents it is slow and very large.
- **xmlschema** (Python) is the most conformant XSD 1.0 and 1.1 validator here, and decodes
  documents into data. Being pure Python, it is the slowest by far.
- **ElementTree** (Python's standard library) is always there. It is slow and does not validate.

All numbers: an Intel Core Ultra 9 285H under WSL2, files warm in the page cache, flatxml built
with `-prod` (GCC 13.3, `-O3 -flto`).

**Parsing a large document.** A 500 MB document from `cmd/genxml`: 12.6M elements and 12.3M
attributes, an element every 41 bytes. Speed per byte depends on that density, so compare files
of the same shape. Every harness reads the file into memory first and times the parse of those
bytes alone; native code is built with full optimisation (`-O3 -flto`, or Rust's release with
LTO). The time is the median of 7 runs (the range of two sets of runs in brackets); the peak is
the whole process, the file's 500 MB included.

| parser | parse | peak memory |
|---|---|---|
| quick-xml 0.42.0 | 0.90 s (0.86–0.90) | 0.5 GB |
| pugixml 1.16 | 0.94 s (0.94–1.08) | 2.3 GB |
| **flatxml** | 1.19 s (1.19–1.25) | 1.3 GB |
| lxml 5.3.1 (libxml2 2.12.9) | 7.1 s | 7.8 GB |
| ElementTree (Python 3.12) | 15.1 s | 6.8 GB |

They do not do the same work, and the differences explain most of the order:

| | keeps a tree | interns names | text and references | checks while parsing |
|---|---|---|---|---|
| quick-xml | no: events only | no | left as written | end tags match; attribute syntax and duplicates, as the harness reads every attribute |
| pugixml | yes, mutable, linked by pointers | no: names point into the buffer | decoded in place | end tags match; duplicate attributes are not checked |
| **flatxml** | yes, read-only, as arrays | yes, every element and attribute name | left as written; references checked, decoded when read | end tags match, one root, attribute and reference syntax; names, UTF-8 and duplicate attributes are not checked |
| lxml | yes | yes | decoded | all of well-formedness, UTF-8 included |
| ElementTree | yes, a Python object per element | — | decoded into Python strings | all of well-formedness (expat) |

quick-xml is fastest partly because it keeps nothing. pugixml is the like-for-like comparison, a
whole tree built in place: about a fifth faster than flatxml, in nearly twice the memory. It
decodes all text while flatxml decodes none, but flatxml hashes every name (25M of them here),
which is what makes finding every element of a kind, or translating names for a schema, cheap
afterwards.

Resolving namespaces on the same document takes about 105 ms more, roughly a tenth of the parse.

**Validating a large document** against `testdata/inventory.xsd`, start to finish: the whole
process's wall time and peak memory (parse, namespaces, validation), every value and the order
and number of every element's children checked.

| validator | 8 MB | 500 MB |
|---|---|---|
| **flatxml** | 0.05 s, 30 MB | 2.5 s, 1.3 GB (validation itself 1.0–1.4 s, about as long as the parse) |
| lxml | 0.26 s, 142 MB | 16.8 s, 7.5 GB (parse 8.3 s, validation 2.9 s) |
| xmlschema 4.3.2 | 3.6 s, 152 MB | not run |

**The W3C XML Schema test suite**: thousands of small files, each compiled or validated once.
The fair rows are "the same work": the 4,579 schemas flatxml does not refuse, and the 5,807
documents of those schemas that every engine compiled, the same files for each. Times are the work
alone (compiling the schemas; reading and validating the documents, not compiling their schemas
again). "Right" counts verdicts that match the suite's expected ones; flatxml declines 20 of the
documents (`xsi:type`, XML 1.1).

| engine | tests | schemas: time | right | documents: time | right |
|---|---|---|---|---|---|
| **flatxml** | the same work | 0.13 s | 4,544 of 4,579 | 0.16 s | 5,787 of 5,787 |
| lxml | the same work | 0.11–0.15 s | 4,516 of 4,579 | 0.09–0.12 s | 5,775 of 5,807 |
| xmlschema 4.3.2 | the same work | 12–18 s | 4,573 of 4,579 | 1.9–2.8 s | 5,781 of 5,807 |
| lxml | all XSD 1.0 tests | 0.98–1.33 s | 13,913 of 14,367 | 1.22–2.04 s | 24,721 of 24,832 |
| xmlschema 4.3.2 | all XSD 1.0 tests | 36–48 s | 14,346 of 14,367 | 22–30 s | 24,864 of 24,946 |

On files this small, flatxml and lxml are level. Within flatxml's subset its verdicts are right
about as often as the others': on schemas 99.2% (lxml 98.6%, xmlschema 99.9%), on documents
every one it judges (lxml 99.4%, xmlschema 99.6%). Outside the subset it gives no verdict at all,
which is the price of never skipping a construct.

Reproduce with `tools/compare/run.sh <file>` (all five parsers; it fetches and builds quick-xml
and pugixml at pinned versions) and `unshare -rn tools/xsts_bench.py bin/flatxml <suite>`. These
are the baseline for performance work: rerun them on a quiet machine before and after a change,
since a shared CI runner is too noisy to time. The suite comparison must run without a network:
some tests import schemas by URL, and libxml2 fetches them, so where a connection hangs (it does
under WSL) its time becomes the network's. Measured with the network up, lxml took 121 s on the
schema tests instead of 1.00 s.

## Limitations

Non-validating, and lenient where that does not change how a well-formed file reads:

- Names, the XML declaration, the DTD internal subset and UTF-8 are not validated. A document
  expat rejects for these reasons may parse. Duplicate attributes and `--` inside comments are
  accepted.
- The DTD is skipped: entities it declares are unknown (an error on use), and default attribute
  values it declares are not applied.
- Text is returned as the document's bytes. A document in an encoding other than UTF-8 (or
  ASCII), such as ISO-8859-1 or UTF-16, is not converted.
- XML 1.1 is not supported. A document that declares it is read as XML 1.0, as expat reads it.
- Patterns: Unicode block escapes (`\p{IsLatin-1Supplement}`) and the XML name classes (`\i`,
  `\c`) are refused. Categories follow Unicode 15.0, where XSD 1.0 cites Unicode 3.1, so a
  character assigned since is in its category here.
- Values are checked more leniently than XSD in a few places, never more strictly: `anyURI`
  accepts any string; `float` and `double` are checked for their form, not their range; names
  follow XML 1.0's fifth edition, which allows more characters than the second edition XSD 1.0
  cites; enumerations of dates and times treat `Z`, `+00:00` and `-00:00` alike but do not
  normalise other timezones; a QName enumeration is compared as written; and `maxLength` on a
  QName is ignored, as XSD 1.0's errata deprecate it. `ENTITY` and `NOTATION` types are refused,
  since they need a DTD's declarations.
- With namespaces resolved, the parts of a qualified name are not validated either (`p:1a` is
  accepted), and colons in processing-instruction targets and in DTD declarations, which the
  parser skips, are not checked.
- Whitespace-only text between tags is dropped, except in CDATA. In mixed content, this includes a
  whitespace-only run between two comments.
- A document must be smaller than 4 GiB, because offsets are `u32`.
- Edits: values are written as UTF-8, so a document in another encoding is not edited correctly.
  Text set on an element replaces all of its own text (`set_text` puts it before the first child
  element, `set_text_runs` run by run); two runs in one slot are written as one. A moved or copied
  element is given every binding that differs at its new place, used in its names or not, since a
  value such as `xsi:type="p:T"` may use one; they are not among the attributes the edit set reads
  (`ENode.attrs`).

## Build and test

V3 only. `.v-version` pins the V commit this is tested with. `V_MACOS_V3_NO_FALLBACK=1` makes a V3
failure fail instead of being retried with the old compiler (despite the name, this applies on
Linux too):

```sh
export V_MACOS_V3_NO_FALLBACK=1
v test .                                       # unit tests
scripts/check_readme_examples.sh               # the README's examples type-check
mkdir -p bin && v -o bin/flatxml cmd/cli       # flatxml dump | stats | set | write | roundtrip | merge | schema | validate
v -prod -o bin/genxml cmd/genxml               # genxml <out.xml> <megabytes>
bin/flatxml roundtrip testdata                 # written back, each file is itself (--nodes, --rewrite)
tools/check_vs_expat.py bin/flatxml testdata   # identical to expat, element for element
tools/check_vs_expat.py --ns bin/flatxml testdata            # ... with namespaces resolved
tools/fuzz_vs_expat.py --ns --count 4000 bin/flatxml testdata/*.xml   # random edits
tools/bench.sh 500                             # against ElementTree and lxml
tools/compare/run.sh <file>                    # against quick-xml, pugixml, lxml, ElementTree
bin/flatxml merge --rules rules.txt parts/      # many files read as one by rules: size, time, problems
bin/flatxml merge --rules rules.txt -o all.xml parts/   # ... and written as one document
bin/flatxml diff [--rules rules.txt] old/ new/  # what changed: removed, added, moved, texts, attributes
bin/flatxml apply --check old/ new/ out/       # that diff applied to old's files, written to out/
bin/flatxml merge3 base/ ours/ theirs/ out/   # both changes made on base, conflicts listed
tools/diff_vs_edits.py bin/flatxml *.xml       # known edits, each reported as exactly that change
bin/flatxml schema model.xsd                   # compile a schema, print what it holds
bin/flatxml validate model.xsd model.xml       # check a document against it
tools/patterns_vs_lxml.py bin/flatxml model.xsd   # its patterns against libxml2's, string by string
tools/content_vs_lxml.py bin/flatxml model.xsd *.xml   # edited documents against libxml2's verdicts
tools/edits_vs_lxml.py bin/flatxml *.xml       # random edits, made by flatxml and by lxml
scripts/fetch_xsts.sh /tmp/xsts && tools/xsts.py bin/flatxml /tmp/xsts   # W3C schema tests
```

CI (`.github/workflows/ci.yml`) builds the pinned V (`.v-version`, and its C bootstrap at
`.vc-version`), runs the unit tests, checks `testdata/` and an 8 MB generated document against
expat in both modes and writes them back (each is itself, in every write mode), fuzzes 500 mutations in each, validates the generated document against
`testdata/inventory.xsd`, and runs the W3C schema and instance tests (fetched at the commit
`.xsts-version` names, without the NIST datatype set).

## Licence

MIT. No third-party schema or document is included.
