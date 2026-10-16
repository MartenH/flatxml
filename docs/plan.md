# Plan: XML Schema support

flatxml parses fast and validates nothing. This plan adds XML Schema (XSD 1.0) support: read a
schema, give every element of a document its declaration, check the document against it, and
read values by their declared type.

Everything here is generic. Nothing in this repository knows about any particular vocabulary.
What a vocabulary's annotations and value conventions *mean* is for its consumer to decide.

## Principles

- **A schema is optional.** A document is read without one exactly as today, by the same calls at
  the same cost. Schema support is a layer a caller opts into; no step below makes the
  schemaless path slower, except the namespace ids of step 1, within its budget.
- **The flat tree is the representation.** Every later layer (namespaces, declarations, typed
  values) is one more array beside the node arrays, indexed by node. None adds pointers into the
  tree or builds a second one.

## Test data

- Every schema and document committed here is written here. No third-party schema or document is
  committed: not as test data, not in a doc, not in a comment.
- Runs against third-party schemas and documents happen locally, and only numbers are recorded
  (counts, timings, verdicts).

## Scope: the XSD subset

The target is a subset of XSD 1.0, chosen by measuring the large real-world schemas this has to
read. They use exactly these 20 XSD elements:

- `schema`, `import`
- `annotation`, `documentation`, `appinfo`
- `element`, `attribute`
- `complexType`, `simpleContent`, `extension`
- `sequence`, `choice`, `group` (definitions and references), `attributeGroup`
- `simpleType`, `restriction`, `enumeration`, `pattern`, `whiteSpace`, `maxLength`

Not used at all: `complexContent`, `all`, `any`, `anyAttribute`, `substitutionGroup`, `key`,
`keyref`, `unique`, `union`, `list`, `include`, `redefine`, `notation`.

Other details:

- **Element declarations:** `name`, `type`, `minOccurs` and `maxOccurs`. About a third have no
  `type` and carry an anonymous complex type inline.
- **Attribute declarations:** `name`, `type` and `use`, plus `ref`s to the `xml:` namespace.
- **Built-in base types:** `xsd:string`, `xsd:NMTOKEN`, `xsd:NMTOKENS`, `xsd:double` and
  `xsd:unsignedInt`.
- **Choice occurrence:** most choices are `minOccurs="0" maxOccurs="unbounded"`, which makes that
  content unordered. A few are bounded, at 1, 2 or 8.
- **Patterns:** 42 distinct patterns. They use character classes, alternation, groups, `?`, `*`,
  `+`, `{n}`, `{n,m}`, `\d` and escaped punctuation. None uses `\p{…}`, `\i`, `\c`, a negated
  class or class subtraction.

**The rule:** support that subset, and refuse everything else when the schema is compiled, by
name and position (`xsd:all at schema.xsd:120: not supported`). Never skip a construct silently: a
validator that ignores a constraint reports invalid documents as valid. A construct is added when
a real schema needs it, with its own tests.

## Design

1. **Namespaces in the parser.** Every element and attribute gets a namespace id and a local-name
   id. The prefix split is cached per interned name, not worked out per node. Resolution is a
   second linear pass, run on request (`resolve_namespaces`), that only maintains a scope where
   an element declares `xmlns`. An unprefixed attribute has no namespace (XML Names). Measured:
   about 105 ms on the 500 MB benchmark, roughly a tenth of the parse, and nothing for a caller
   that does not ask.
2. **A schema is a compiled object of its own**, read from XSD files with flatxml itself, since a
   schema is XML. It has its own name table. A document is bound to a schema through a
   translation array (the document's name id → the schema's qualified-name id), filled once per
   distinct name. Typing then costs an array lookup per node.
3. **Types live beside the tree, not in it.** A `Typed` view holds the document, the schema and
   one more parallel array: the declaration each element matched. A `Doc` parsed without a
   schema pays nothing.
4. **Content models compile to deterministic automata,** one per complex type. XSD's Unique
   Particle Attribution rule guarantees they are deterministic. A schema that breaks the rule is
   refused when it is compiled. Small occurrence bounds are unrolled; large ones are kept as
   counters.
5. **Simple types** are checked in XSD's order: normalise whitespace, check the base type's
   lexical space, then the facets (enumeration as a set, pattern, `maxLength` in characters, not
   bytes).
   - Patterns run on our own engine for the XSD regex dialect. A pattern is implicitly anchored,
     and the escapes differ from vlib's `regex`.
   - The engine is linear-time (Thompson/Pike), so no input can make it backtrack.
   - It supports what the scope above lists and refuses the rest, like the schema reader.
6. **Findings** are one per defect, with the line and column, the element's path and what was
   expected. The kinds:
   - an undeclared element in that context;
   - an element out of order, or too few or too many of it;
   - an undeclared attribute, or a required attribute missing;
   - a value outside its enumeration, not matching its pattern, too long, or not of its base type;
   - text in element-only content;
   - `xsi:type`, which is reported as not supported rather than ignored, and `xsi:nil="true"`,
     an error while no declaration can be nillable.
7. **Values.** `Typed` reads a value by its built-in base type (`xsd:double` → `f64`,
   `xsd:unsignedInt` → `u32`, `xsd:string` → `string`). It also exposes which simple type the
   element has, so a consumer can attach its own decoder to a derived type. flatxml does not guess
   what a pattern-restricted string means: a vocabulary that writes integers as strings with
   octal, hex or binary forms decodes them itself.
8. **Annotations.** Each `xsd:appinfo` is kept as raw text, keyed by the schema component and its
   `source` attribute, and is not interpreted here. Vocabularies keep their own metadata there,
   and their consumers read it through this API.
9. **Schema location.** A schema is passed in explicitly, as one or more paths. An import is read
   from its `schemaLocation` when that is a local file; otherwise it is skipped with a note (the
   location is a hint), and a reference into its namespace fails as undeclared. A document's
   `xsi:schemaLocation` is reported to the caller and never fetched. The attributes of the xml
   namespace and its attribute group `xml:specialAttrs` are built in, for schemas that refer to
   them without importing their schema.

## Verification

- **Oracle: the W3C XML Schema test suite** (`w3c/xsdtests`), from step 2 on. Its expected
  verdicts were written by the specification's authors, so they are independent of this code and
  of libxml2. It is fetched at a pinned commit (`.xsts-version`, `scripts/fetch_xsts.sh`) and
  never committed. It ships no driver: `tools/xsts.py` reads its index, runs every XSD 1.0 test,
  and counts a schema that uses something outside the subset as refused, not as a failure.
- **Second opinion: libxml2, through lxml** (`etree.XMLSchema`). It gets the same schema and
  document, and the two must agree on the verdict and on where each finding is (line and element).
  The wording may differ. This runs on the schemas written here and on generated mutations of valid
  documents, the way the parser was fuzzed against expat with 4,000 mutations.
- **Locally, on the real-world schemas** the scope was measured on: each compiles with nothing
  refused, and real documents are validated and compared with lxml. Only counts are recorded.
- **Parser oracle:** expat, as before. The expat checker comes here in step 0 and gains a
  namespace mode in step 1.
- **Performance:** `cmd/genxml` gains a schema for the documents it writes, so the validation
  benchmark is ours end to end. Validating the 500 MB document should take no longer than parsing
  it (about 1.2 s), since it is one more linear pass of table lookups with a regex on some leaves.
  Peak memory is recorded with it.

## Steps

Each step is one PR with its own tests. Steps 1–3 are what consumers need first. Order checking
(5) comes last because it costs the most and is needed least: a consumer usually needs "what is
this element" before "is it in the right place".

0. **Setup** (done). CI on Linux with the pinned V. An expat cross-check
   (`tools/check_vs_expat.py`) driven by `cmd/cli` (`flatxml dump`, `flatxml stats`), and a
   generator of synthetic documents for the benchmark (`cmd/genxml`, `tools/bench.sh`).
1. **Namespaces** (design 1, done). The namespace mode of the expat check is identical on
   `testdata/`, generated documents and the local real files, and `tools/fuzz_vs_expat.py` finds
   no refused document and no different tree in either mode.
2. **Schema reader** (design 2, 8, 9, done). Compile the subset, refuse everything else, resolve
   groups, attribute groups, extensions and anonymous types, and keep the appinfo. A synthetic
   schema per construct, and one test per refusal. The real-world schemas compile locally with
   nothing refused, and their counts match an independent count. On the W3C suite: no valid
   schema rejected; 744 invalid schemas compile because the rule they break is not checked yet,
   617 of them an invalid pattern (step 4) and 46 an enumeration value outside its base type
   (step 4). A missing type is an error when the schema is compiled, where XSD 1.0 allows it
   until the declaration is used: a documented divergence.
3. **Typing pass** (design 3, done). Give each element its declaration by context (parent type
   and child name), without checking order. Report undeclared elements and attributes. On its own
   this already answers "is this element allowed here", and "what kind of element is this".
   On the W3C suite no valid document is reported (6,461 instance tests); 2,678 invalid ones pass
   because their error is in a value or the order of children. 463 real-world files agree with
   libxml2 on every verdict. About 0.34 s on the 500 MB benchmark, namespaces included.
4. **Simple types** (design 5), in two parts.
   - **4a, patterns** (done): the pattern engine (`pattern.v`: a parser for XSD's regex syntax, a
     Pike VM and a lazily built DFA over it), patterns compiled with their schema, and values
     checked against them after whitespace normalisation. `tools/patterns_vs_lxml.py` compares it
     with libxml2 string by string. On the W3C suite, invalid schemas that compile fell from 744 to
     127 and invalid documents that pass from 2,678 to 1,191, with no valid schema or document
     rejected. Unicode blocks and `\i`/`\c` are refused (505 suite schemas, none real-world).
   - **4b, the rest of the facets** (done): the built-in types' lexical spaces (`lexical.v`, scanned
     in place: a V substring is a copy, and copies cost the most here), enumerations compared by
     value, `maxLength` in characters, octets or items, unique IDs and resolved IDREFs, QName
     prefixes declared where written; and when a schema compiles, enumeration values valid for
     their base, `maxLength` applicable and not growing, `whiteSpace` not loosening. On the W3C
     suite, invalid documents that pass fell from 1,191 to 20 and invalid schemas that compile from
     127 to 81, with no valid schema or document rejected; 463 real-world files still agree with
     libxml2. The 500 MB benchmark validates in about 1.0 s (the parse takes about 1.15 s).
5. **Content models** (design 4, done). Order and occurrence: a content model whose counts are
   all 0, 1 or unbounded is decided by its Glushkov automaton (`dfa.v`), built on first use, its
   states the classes of positions followed alike; other counts by a walker with a counter per
   group (`content.v`), which also explains every refusal. When a schema compiles, its content
   models must be deterministic (Unique Particle Attribution) and give elements of one name one
   type (Element Declarations Consistent), on the model with its group references expanded
   (`glushkov.v`): a group used twice is two places. On the W3C suite, invalid documents that pass
   fell from 20 to 0 and invalid schemas that compile from 81 to 34, with no valid schema or
   document rejected: right on 99.2% of the schemas it compiles (lxml 98.6%) and every document it
   judges (lxml 99.4%). `tools/content_vs_lxml.py` edits the 461 valid real-world files where
   content models decide, 11,500 copies, and agrees with libxml2 on every verdict. Validating a
   6.8 MB real-world file went from 7.8 ms to 8.8 ms (the parse takes about as long), the 500 MB
   benchmark is unchanged, and compiling the largest real-world schema still takes about 60 ms,
   since a model in which no name occurs twice cannot be ambiguous and skips the construction.
6. **Typed values** (design 7). Read values by type, findings with positions, a schema that
   cannot be changed from outside. Comes after [documents.md](documents.md), which gives the
   handles, navigation, diff, merge and editing these build on.
7. **Parse speed.** Close the gap to pugixml (0.94 s against flatxml's 1.19 s on the 500 MB
   benchmark) without giving up interned names: the techniques below, each kept only if
   `tools/compare/run.sh` shows it pays.

## Techniques taken from other engines

Each is adopted at a step, and kept only if the benchmark or the suite shows it pays.

- **Patterns: a linear-time engine** (step 4), after RE2 and Go's `regexp`: a pattern compiles to
  an NFA run as a Pike VM, so no input can make it backtrack, with DFA states built lazily and
  cached as they are met. Measured on a 6.8 MB real-world file, whose values are mostly
  identifiers and paths: validation 25 ms with the Pike VM, 7 ms with the DFA (the parse takes
  8 ms).
- **A verdict per distinct value** (step 4), tried and dropped: each simple type remembered the
  strings it had accepted, so a repeat cost a hash lookup instead of a pattern run. It paid
  against the Pike VM; against the lazy DFA, hashing a value costs as much as matching it, and
  validation measured the same with and without it.
- **Lexical checks by character table** (step 4): validating a built-in type needs to know that a
  value is well formed, not its number, so most checks are a table-driven scan with no conversion.
- **Counters, not unrolling** (step 5), as libxml2's automata do: expanding `maxOccurs="5000"` into
  5,000 states is a known denial of service (Xerces-J caps it at 5,000 under secure processing),
  and counts here are stored up to 2³²−2.
- **Glushkov automata** (step 5), as Xerces builds them: the construction that gives a content
  model's automaton also proves the Unique Particle Attribution rule. A position's follow set is
  kept as the particles whose first sets follow it, not their union, and positions followed by
  the same particles are one state, so a repeated choice of hundreds of elements is one state and
  one row of the table, not hundreds squared. Measured on the 6.8 MB real-world file: content
  checking cost about 8 ms with the walker alone and costs about 1 ms with the automata, most of
  it building the 96 tables the file needs.
- **Unordered content as a set** (step 5), tried and dropped: a fast path for a repeated choice
  of elements, which the real-world files did not measure faster; the automaton makes such a
  model one state anyway.
- **A null handle** (step 6), after pugixml: a missing node is a valid empty node, so
  `root.child('a').child('b').attr('x')` chains without a check at every step, with typed reads
  that take a default (`as_int(0)`).
- **Element paths** (step 6), after ElementTree and lxml: `find('a/b')` and `iter('item')`,
  compiled once into name ids.
- **Character-class tables and unrolled scans** (step 7), as pugixml scans: one table lookup
  classifies a byte, and the hot loops test several bytes per iteration.
- **Arrays sized once** (step 7): on dense input the node arrays double several times and copy
  hundreds of MB; a `memchr` count of `<` bounds the node count, so the arrays are allocated
  once.
- **Recent names before hashing** (step 7): siblings usually share a name, so a length and bytes
  check against the last few names skips most of the hashing.
- **SIMD structural indexing** (later, if ever): Parabix and icXML find every markup position in
  parallel, as simdjson does for JSON. A project of its own.

Not taken: validating schema documents against the schema for schemas, as xmlschema and Xerces
do to catch invalid schemas, because that schema uses constructs outside the subset.

## How consumers take this repository

A consumer vendors a stated commit rather than fetching one: a clone builds offline, and the
version is stated in one place. A vendored copy is never edited. A fix lands here first and is
vendored again.

## Open questions

- Is XSD 1.1 (assertions, open content) needed? Nothing measured uses it, so it stays out until
  something does.
- Is a schema's appinfo needed per element of a document, or only per declaration? Decide in
  step 2, against the first consumer that reads it.
