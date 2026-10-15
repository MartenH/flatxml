# flatxml

A flat, zero-copy XML parser in V (V3), with XML Schema support being built (`flatxml.xsd`):
see [`docs/plan.md`](docs/plan.md).

flatxml is generic: it knows nothing about any XML vocabulary.

```v
import flatxml

mut doc := flatxml.parse_file('model.xml')!
for c in doc.children(doc.root()) {
	println('${doc.name(c)} ${doc.text(c)} at ${doc.pos(c)}')
}
// Namespaces are resolved only when asked for; a document read without them costs nothing extra.
doc.resolve_namespaces()!
println('{${doc.ns_uri(doc.ns_of(doc.root()))}}${doc.local_name(doc.root())}')
```

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

**Text** is never copied while parsing. Spans point into the memory-mapped file. Entities and line
endings are decoded only when `text()` or `attr_value()` is called, and only if the span needs it.
References are checked at parse time, so decoding can never fail. An element whose only content
is text keeps that text on the element. Text nodes exist only for mixed content.

**Parsing** is one forward pass. `memchr` jumps to the next `<`, names are interned through a
small hash table keyed on the source bytes, and the `parent` array is the stack of open elements.

**Namespaces** are resolved on request, by `resolve_namespaces`, in a second linear pass: one
more array beside the nodes (each element's namespace id) and one beside the attributes. Names
are split into prefix and local name once per distinct name, not per node, and bindings are kept
in a table indexed by prefix, undone when the declaring element ends. It applies the errors of
Namespaces in XML 1.0: unbound prefixes, names that are not qualified names, misuse of the
reserved `xml` and `xmlns` prefixes and namespaces, undeclared prefixes, and attributes with the
same expanded name.

**XML Schema.** `flatxml.xsd` compiles schema documents into flat tables the same way: components
in arrays, referring to each other by index. `xsd.load(paths...)` reads the documents and what
they import, resolves every reference, expands groups and attribute groups, and gives a type
that extends another its base's content and attributes. It supports the subset of XSD 1.0 in
the plan and refuses everything else by name and position (`xsd:all at s.xsd:12:5: ... not
supported`), because a validator that skips a constraint calls invalid documents valid. Each
`xsd:appinfo` is kept for the consumer, its content written back as XML.

`xsd.validate(mut doc, schema)` checks a document against a compiled schema. It gives each
element the declaration its context names (one more array beside the nodes) and reports what the
schema does not allow, with positions: an element not declared where it is, an undeclared or
missing attribute, text in element-only content, children in simple content, an abstract type,
`xsi:nil="true"` (no declaration can be nillable here). `xsi:type`, and a schema the document
names itself (`xsi:schemaLocation`, `xsi:noNamespaceSchemaLocation`), are reported as not
supported rather than guessed at. A value is checked against the patterns of its type, after its
whitespace is normalised by the type's rule. The other value checks (enumerations, the built-in
types, lengths) and the order and number of children are the next steps of the plan.

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
  schema rejected. 3,521 valid schemas compile and 920 invalid ones are rejected; 9,798 use
  constructs outside the subset and are refused (505 of them for a pattern using a Unicode block
  or `\i`/`\c`); 127 invalid ones compile because the rule they break is not checked yet; one is
  a documented divergence (a missing type is an error at once). Of 5,811 instance tests whose
  schema compiles, no valid document is reported: 3,347 valid documents pass, 1,253 invalid ones
  are reported, 20 use something unsupported (`xsi:type`, a schema the document names itself,
  XML 1.1), and 1,191 invalid ones pass because their error is in an enumeration, a built-in
  type, a length or the order of children (steps 4 and 5).
- **Patterns against libxml2** (`tools/patterns_vs_lxml.py`): the 43 patterns of the real-world
  schemas and `testdata`, on 7,190 strings made to probe them, agree on every verdict. Over the
  suite's 1,240 patterns they disagree on 22 patterns libxml2 compiles and flatxml rejects, and
  on 112 of 37,591 strings; the suite expects flatxml's answer for 21 of the 22 (the 22nd was a
  flatxml bug, fixed), and the strings are libxml2's automaton going wrong (it rejects
  `foo7777baz` for `foo\w*\d{4}baz`) or treating `^` as an anchor.
- **Validation of real-world files**: 463 of the 697 files, against the schema each declares,
  agree with libxml2 on every verdict (461 valid; 2 invalid, reported at the same line).

## How it compares

Each tool below does different work, so the tables say what each one builds and checks. What
each is good at, and what it is not:

- **flatxml** builds a read-only tree of the whole document, navigable in every direction, in
  28 bytes a node, with every name interned and text left in the file until it is read, and
  validates against a schema in a fraction of the parse. Namespaces and XSD validation are layers
  over that tree, each opt-in. It is not good at: changing a document (the tree is read-only;
  editing is a later layer), documents that do not fit in memory or exceed 4 GiB (it maps the
  whole file; there is no streaming mode), XML 1.1, DTDs (skipped), and names and UTF-8 (not
  checked). Its XSD support is a measured subset, and it does not yet check values or the order
  of children. It is a V library.
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
process's wall time and peak memory (parse, namespaces, validation). flatxml checks patterns but
not yet enumerations, built-in types, lengths or the order of children, which lxml and xmlschema
do (steps 4 and 5 of the plan).

| validator | 8 MB | 500 MB |
|---|---|---|
| **flatxml** | 0.03 s, 30 MB | 1.5 s, 1.2 GB (validation itself 0.53 s) |
| lxml | 0.26 s, 142 MB | 16.8 s, 7.5 GB (parse 8.3 s, validation 2.9 s) |
| xmlschema 4.3.2 | 3.6 s, 152 MB | not run |

**The W3C XML Schema test suite**: thousands of small files, each compiled or validated once.
The fair rows are "the same work": the 4,569 schemas flatxml does not refuse, and the 5,807
documents of those schemas that every engine compiled, the same files for each. Times are the work
alone (compiling the schemas; reading and validating the documents, not compiling their schemas
again), the range of three runs. "Right" counts verdicts that match the suite's expected ones.

| engine | tests | schemas: time | right | documents: time | right |
|---|---|---|---|---|---|
| **flatxml** | the same work | 0.10 s | 4,441 of 4,569 | 0.13 s | 4,596 of 5,787 |
| lxml | the same work | 0.11–0.13 s | 4,506 of 4,569 | 0.09–0.11 s | 5,775 of 5,807 |
| xmlschema 4.3.2 | the same work | 12.3 s | 4,563 of 4,569 | 1.9 s | 5,781 of 5,807 |
| lxml | all XSD 1.0 tests | 0.98–1.07 s | 13,913 of 14,367 | 1.22–1.30 s | 24,721 of 24,832 |
| xmlschema 4.3.2 | all XSD 1.0 tests | 35.9 s | 14,346 of 14,367 | 22.2 s | 24,864 of 24,946 |

On files this small, flatxml and lxml are level. flatxml's verdicts on schemas are right nearly as
often as lxml's (97% against 99%); on documents less often (79% against 99%) until the rest of
step 4 and step 5, since invalid documents pass when their error is in an enumeration, a
built-in type, a length or the order of children.

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
- With namespaces resolved, the parts of a qualified name are not validated either (`p:1a` is
  accepted), and colons in processing-instruction targets and in DTD declarations, which the
  parser skips, are not checked.
- Whitespace-only text between tags is dropped, except in CDATA. In mixed content, this includes a
  whitespace-only run between two comments.
- A document must be smaller than 4 GiB, because offsets are `u32`.

## Build and test

V3 only. `.v-version` pins the V commit this is tested with. `V_MACOS_V3_NO_FALLBACK=1` makes a V3
failure fail instead of being retried with the old compiler (despite the name, this applies on
Linux too):

```sh
export V_MACOS_V3_NO_FALLBACK=1
v test .                                       # unit tests
mkdir -p bin && v -o bin/flatxml cmd/cli       # flatxml dump | stats
v -prod -o bin/genxml cmd/genxml               # genxml <out.xml> <megabytes>
tools/check_vs_expat.py bin/flatxml testdata   # identical to expat, element for element
tools/check_vs_expat.py --ns bin/flatxml testdata            # ... with namespaces resolved
tools/fuzz_vs_expat.py --ns --count 4000 bin/flatxml testdata/*.xml   # random edits
tools/bench.sh 500                             # against ElementTree and lxml
tools/compare/run.sh <file>                    # against quick-xml, pugixml, lxml, ElementTree
bin/flatxml schema model.xsd                   # compile a schema, print what it holds
bin/flatxml validate model.xsd model.xml       # check a document against it
tools/patterns_vs_lxml.py bin/flatxml model.xsd   # its patterns against libxml2's, string by string
scripts/fetch_xsts.sh /tmp/xsts && tools/xsts.py bin/flatxml /tmp/xsts   # W3C schema tests
```

CI (`.github/workflows/ci.yml`) builds the pinned V (`.v-version`, and its C bootstrap at
`.vc-version`), runs the unit tests, checks `testdata/` and an 8 MB generated document against
expat in both modes, fuzzes 500 mutations in each, validates the generated document against
`testdata/inventory.xsd`, and runs the W3C schema and instance tests (fetched at the commit
`.xsts-version` names, without the NIST datatype set).

## Licence

MIT. No third-party schema or document is included.
