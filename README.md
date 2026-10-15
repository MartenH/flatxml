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
supported rather than guessed at. Values, and the order and number of children, are the next
steps of the plan.

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
  schema rejected. 4,020 valid schemas compile and 307 invalid ones are rejected; 9,295 use
  constructs outside the subset and are refused; 744 invalid ones compile because the rule they
  break is not checked yet (617 of them an invalid pattern, which the pattern engine of step 4
  will catch); one is a documented divergence (a missing type is an error at once). Of 6,461
  instance tests whose schema compiles, no valid document is reported: 3,714 valid documents
  pass, 47 invalid ones are reported, 22 use something unsupported (`xsi:type`, a schema the
  document names itself, XML 1.1), and 2,678 invalid ones pass because their error is in a value
  or in the order or number of children (steps 4 and 5).
- **Validation of real-world files**: 463 of the 697 files, against the schema each declares,
  agree with libxml2 on every verdict (461 valid; 2 invalid, reported at the same line).

## How it compares

Each tool below does different work, so the tables say what each one builds and checks. What
each is good at, and what it is not:

- **flatxml** builds a tree of the whole document, navigable in every direction, about as fast
  as a pull parser reads events, in 28 bytes a node, with text left in the file until it is
  read. Namespaces and XSD validation are layers over that tree, each opt-in. It is not good at:
  changing a document (the tree is read-only; editing is a later layer), documents that do not
  fit in memory or exceed 4 GiB (it maps the whole file; there is no streaming mode), XML 1.1,
  DTDs (skipped), names and UTF-8 (not checked), and many small files, where its fixed cost per
  file shows. Its XSD support is a measured subset, and it does not yet check values or the order
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
with `-prod` (GCC 13.3, `-O3 -flto`), medians where runs vary.

**Parsing a large document.** A 500 MB document from `cmd/genxml`: 12.6M elements and 12.3M
attributes, an element every 41 bytes. Speed per byte depends on that density, so compare files
of the same shape. Every parser reads the file first and times the parse alone; the peak is the
whole process, the file included. A range is the spread of separate sets of runs.

| parser | builds | parse | peak memory |
|---|---|---|---|
| **flatxml** | a read-only tree, attributes indexed | 1.11–1.16 s | 1.1 GB (500 MB of it the mapped file) |
| quick-xml 0.42.0 | nothing: every event and attribute visited | 1.07–1.09 s | 0.5 GB (the file read into memory) |
| pugixml 1.16 | a mutable tree, in place | 1.32–1.65 s | 2.3 GB |
| lxml 5.3.1 (libxml2 2.12.9) | a libxml2 tree | 7.1–9.0 s | 7.1 GB |
| ElementTree (Python 3.12) | a tree of Python objects | 12.3–13.5 s | 5.7 GB |

Resolving namespaces on the same document takes about 105 ms more, roughly a tenth of the parse.

**Validating a large document** against `testdata/inventory.xsd`, start to finish (parse,
namespaces, validation). flatxml does not yet check values or the order of children, which lxml
and xmlschema do (steps 4 and 5 of the plan).

| validator | 8 MB | 500 MB |
|---|---|---|
| **flatxml** | 0.03 s, 30 MB | 1.5 s, 1.2 GB (validation itself 0.34 s) |
| lxml | 0.26 s, 142 MB | 16.8 s, 7.5 GB (parse 8.3 s, validation 2.9 s) |
| xmlschema 4.3.2 | 3.6 s, 152 MB | not run |

**The W3C XML Schema test suite**: thousands of small files, each compiled or validated once. The
fair rows are the ones in flatxml's subset (the schemas it does not refuse, and the documents of
those schemas): the same work for every engine. flatxml runs as two batch processes; the others
run in-process. "Right" counts verdicts that match the suite's expected ones.

| engine | tests | schemas: time | right | documents: time | right |
|---|---|---|---|---|---|
| **flatxml** | in the subset | 0.12 s | 4,327 of 5,072 | 0.27 s | 3,762 of 6,443 |
| lxml | in the subset | 0.11 s | 5,006 of 5,072 | 0.16 s | 6,410 of 6,457 |
| xmlschema | in the subset | 15.3 s | 5,066 of 5,072 | 3.0 s | 6,424 of 6,460 |
| lxml | all XSD 1.0 tests | 1.07 s | 13,913 of 14,367 | 1.28 s | 24,721 of 24,832 |
| xmlschema | all XSD 1.0 tests | 36.9 s | 14,346 of 14,367 | 21.6 s | 24,864 of 24,946 |

On files this small, a fixed cost per file dominates: per schema both flatxml and lxml take about
23 µs, per document flatxml takes about 42 µs and lxml 25. Its verdicts are right less
often until steps 4 and 5: 744 invalid schemas compile because their error is in a pattern or
an enumeration value, and 2,678 invalid documents pass because their error is in a value or the
order of children.

Reproduce with `tools/compare/run.sh <file>` (fetches and builds quick-xml and pugixml at pinned
versions), `tools/bench.sh 500` (ElementTree and lxml), and
`unshare -rn tools/xsts_bench.py bin/flatxml <suite>`. The suite comparison must run without a
network: some tests import schemas by URL, and libxml2 fetches them, so where a connection hangs
(it does under WSL) its time becomes the network's. Measured with the network up, lxml took 121 s
on the schema tests instead of 1.07 s.

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
tools/compare/run.sh /tmp/flatxml_bench/gen_500.xml       # against quick-xml and pugixml
bin/flatxml schema model.xsd                   # compile a schema, print what it holds
bin/flatxml validate model.xsd model.xml       # check a document against it
scripts/fetch_xsts.sh /tmp/xsts && tools/xsts.py bin/flatxml /tmp/xsts   # W3C schema tests
```

CI (`.github/workflows/ci.yml`) builds the pinned V (`.v-version`, and its C bootstrap at
`.vc-version`), runs the unit tests, checks `testdata/` and an 8 MB generated document against
expat in both modes, fuzzes 500 mutations in each, validates the generated document against
`testdata/inventory.xsd`, and runs the W3C schema and instance tests (fetched at the commit
`.xsts-version` names, without the NIST datatype set).

## Licence

MIT. No third-party schema or document is included.
