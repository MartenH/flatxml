# flatxml

A flat, zero-copy XML parser in V (V3). XML Schema support is planned: see
[`docs/plan.md`](docs/plan.md).

flatxml is generic: it knows nothing about any XML vocabulary.

```v
import flatxml

doc := flatxml.parse_file('model.xml')!
for c in doc.children(doc.root()) {
	println('${doc.name(c)} ${doc.text(c)} at ${doc.pos(c)}')
}
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

## Verified

These measurements predate this repository. The parser has not changed since.

- **Unit tests** (`v test .`) cover structure, mixed content, entities, CDATA, every error
  message, and every prefix of a document (each one parses or fails cleanly).
- **Against expat**, element for element, attribute for attribute, text for text: identical on
  583 real-world configuration files (not included), on `testdata/tricky.xml` (BOM, CRLF,
  DOCTYPE with an internal subset, CDATA, numeric references, UTF-8 names, mixed content,
  attribute whitespace), on generated files of 20 MB and 100 MB, and on a 142 MB merged one.
- **Mutation fuzzing** against expat (4,000 random edits): no crash, no valid document refused,
  and one tree difference, which is the DTD default attribute listed under limitations.
- **Past 2 GiB**: a 3 GB file (32.8M nodes, offsets beyond 2³¹) parses in 2.8 s.

## Benchmark

`tools/bench.sh 500`: a 500 MB document from `cmd/genxml`, warm in the page cache, on an Intel
Core Ultra 9 285H under WSL2. It is dense: 12.8M elements and 12.4M attributes, an element every
41 bytes. Speed per byte depends on that density, so compare files of the same shape.

| parse only | wall | peak RSS |
|---|---|---|
| **flatxml** | 1.47 s (parse 1.44 s, 347 MB/s, 8.9M elements/s) | 1.3 GB, of which 500 MB is the mapped file |
| Python `xml.etree.ElementTree` | 13.1 s | 5.8 GB |
| lxml 5.3.1 (libxml2 2.12.9) | 12.5 s | 7.2 GB |

## Limitations

Non-validating, and lenient where that does not change how a well-formed file reads:

- Names, the XML declaration, the DTD internal subset and UTF-8 are not validated. A document
  expat rejects for these reasons may parse. Duplicate attributes and `--` inside comments are
  accepted.
- The DTD is skipped: entities it declares are unknown (an error on use), and default attribute
  values it declares are not applied.
- No namespace processing yet. Names are compared as written. This is step 1 of the plan.
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
tools/bench.sh 500                             # against ElementTree and lxml
```

CI (`.github/workflows/ci.yml`) builds the pinned V (`.v-version`, and its C bootstrap at
`.vc-version`), runs the unit tests, and checks `testdata/` and an 8 MB generated document against
expat.

## Licence

MIT. No third-party schema or document is included.
