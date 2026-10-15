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
   second linear pass that only maintains a scope where an element declares `xmlns`. An
   unprefixed attribute has no namespace (XML Names). Budget: at most 10% on parse time, measured
   on the 500 MB benchmark.
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
   - `xsi:type` or `xsi:nil`, which are reported as not supported rather than ignored.
7. **Values.** `Typed` reads a value by its built-in base type (`xsd:double` → `f64`,
   `xsd:unsignedInt` → `u32`, `xsd:string` → `string`). It also exposes which simple type the
   element has, so a consumer can attach its own decoder to a derived type. flatxml does not guess
   what a pattern-restricted string means: a vocabulary that writes integers as strings with
   octal, hex or binary forms decodes them itself.
8. **Annotations.** Each `xsd:appinfo` is kept as raw text, keyed by the schema component and its
   `source` attribute, and is not interpreted here. Vocabularies keep their own metadata there,
   and their consumers read it through this API.
9. **Schema location.** A schema is passed in explicitly: one or more paths, or a directory that
   maps namespace and file name to a path. A document's `xsi:schemaLocation` is reported to the
   caller and never fetched.

## Verification

- **Oracle: the W3C XML Schema test suite** (`w3c/xsdtests`), from step 2 on. Its expected
  verdicts were written by the specification's authors, so they are independent of this code and
  of libxml2. It is fetched at a pinned commit in CI and never committed. It ships no driver: a
  small runner reads its index, runs every XSD 1.0 test whose schema compiles, and counts the
  rest as out of scope, not as failures.
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
  it (about 1.2 s), since it is one more linear pass of table lookups with a regex on some leaves. Peak
  memory is recorded with it.

## Steps

Each step is one PR with its own tests. Steps 1–3 are what consumers need first. Order checking
(5) comes last because it costs the most and is needed least: a consumer usually needs "what is
this element" before "is it in the right place".

0. **Setup** (done). CI on Linux with the pinned V. An expat cross-check
   (`tools/check_vs_expat.py`) driven by `cmd/cli` (`flatxml dump`, `flatxml stats`), and a
   generator of synthetic documents for the benchmark (`cmd/genxml`, `tools/bench.sh`).
1. **Namespaces** (design 1). Done when the namespace mode of the expat check is identical on
   `testdata/` and on the local real files, and parse time is within budget.
2. **Schema reader** (design 2, 8, 9). Compile the subset, refuse everything else, resolve groups,
   attribute groups, extensions and anonymous types, and keep the appinfo. A synthetic schema per
   construct, and one test per refusal. Done when the real-world schemas compile locally with
   nothing refused, with counts printed by `flatxml schema <xsd>`.
3. **Typing pass** (design 3). Give each element its declaration by context (parent type and
   child name), without checking order. Report undeclared elements and attributes. On its own
   this already answers "is this element allowed here", and "what kind of element is this".
4. **Simple types** (design 5). Whitespace, enumeration, `maxLength`, the five base types, and the
   pattern engine. The engine is tested pattern by pattern against lxml, with a one-element schema
   per pattern.
5. **Content models** (design 4). Order and occurrence, compared with lxml on the generated
   mutations.
6. **Typed values** (design 7).

## How consumers take this repository

A consumer vendors a stated commit rather than fetching one: a clone builds offline, and the
version is stated in one place. A vendored copy is never edited. A fix lands here first and is
vendored again.

## Open questions

- Is XSD 1.1 (assertions, open content) needed? Nothing measured uses it, so it stays out until
  something does.
- Is a schema's appinfo needed per element of a document, or only per declaration? Decide in
  step 2, against the first consumer that reads it.
