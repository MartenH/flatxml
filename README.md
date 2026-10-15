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

The expat checker and the benchmark generator are not in this repository yet. Adding them is step
0 of the plan.

## Benchmark

A 500 MB generated file, warm in the page cache, on an Intel Core Ultra 9 285H under WSL2:

| | wall | peak RSS |
|---|---|---|
| **flatxml**, parse only | 378 ms (1.3 GB/s) | not measured alone |
| Python `xml.etree.ElementTree`, parse only | 6.6 s | 2.5 GB |
| lxml 5.3, parse only | 5.5 s | 2.6 GB |

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
v test .
```

## Licence

MIT. No third-party schema or document is included.
