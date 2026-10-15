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
`xsd:appinfo` is kept as text for the consumer. Validating documents against a schema is the
next step of the plan.

```v
import flatxml.xsd

s := xsd.load('model.xsd')!
root := s.element('urn:example', 'model')?
println(s.qname(s.elements[root].name))
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
  will catch); one is a documented divergence (a missing type is an error at once).

## Benchmark

`tools/bench.sh 500`: a 500 MB document from `cmd/genxml`, warm in the page cache, on an Intel
Core Ultra 9 285H under WSL2. It is dense: 12.6M elements and 12.3M attributes, an element every
41 bytes. Speed per byte depends on that density, so compare files of the same shape.

| parse only | wall | peak RSS |
|---|---|---|
| **flatxml** | 1.2–1.9 s (the parse itself 1.1–1.3 s: about 400 MB/s, 10M elements/s) | 1.1 GB, of which 500 MB is the mapped file |
| Python `xml.etree.ElementTree` | 13.5 s | 5.7 GB |
| lxml 5.3.1 (libxml2 2.12.9) | 12.2 s | 7.1 GB |

Resolving namespaces on the same document takes about 105 ms more, roughly a tenth of the parse.

## Limitations

Non-validating, and lenient where that does not change how a well-formed file reads:

- Names, the XML declaration, the DTD internal subset and UTF-8 are not validated. A document
  expat rejects for these reasons may parse. Duplicate attributes and `--` inside comments are
  accepted.
- The DTD is skipped: entities it declares are unknown (an error on use), and default attribute
  values it declares are not applied.
- Text is returned as the document's bytes. A document in an encoding other than UTF-8 (or
  ASCII), such as ISO-8859-1 or UTF-16, is not converted.
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
bin/flatxml schema model.xsd                   # compile a schema, print what it holds
scripts/fetch_xsts.sh /tmp/xsts && tools/xsts.py bin/flatxml /tmp/xsts   # W3C schema tests
```

CI (`.github/workflows/ci.yml`) builds the pinned V (`.v-version`, and its C bootstrap at
`.vc-version`), runs the unit tests, checks `testdata/` and an 8 MB generated document against
expat in both modes, fuzzes 500 mutations in each, and runs the W3C schema tests (fetched at the
commit `.xsts-version` names, without the NIST datatype set).

## Licence

MIT. No third-party schema or document is included.
