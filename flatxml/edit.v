module flatxml

import io

// Edits over one document: texts and attributes set, elements inserted, removed and moved. The
// document is never changed; an edit set keeps its changes beside it, keyed by node, and reads
// through them (`ENode` answers like a node of the edited document). Written, the document keeps
// every byte no edit touched: the bytes of untouched elements, and the comments, processing
// instructions and whitespace between them. A removed element takes with it the indentation
// before it, and an inserted one gets the indentation of its neighbours.
//
// Inserted content is a piece of its own: a fragment parsed from a string, or a node of any
// document (copied, so its document must outlive the edit set). A node of the edited document
// is the piece and its index there, so edits can go on inside inserted content too. A node
// copied or moved keeps its namespaces: where the bindings in scope at its new place differ from
// those at its old one, it is given declarations that restore them, `xmlns=""` included. A
// fragment is read in the namespaces in scope where it is first put, and keeps them when moved.

const no_key = u64(0xFFFF_FFFF_FFFF_FFFF)

@[inline]
fn ekey(piece u32, i u32) u64 {
	return u64(piece) << 32 | u64(i)
}

@[inline]
fn kpiece(k u64) u32 {
	return u32(k >> 32)
}

@[inline]
fn kindex(k u64) u32 {
	return u32(k)
}

// Piece is content an edit set holds: the edited document (piece 0), a parsed fragment, or a
// node copied from a document.
struct Piece {
	doc   &Doc
	root  u32
	owned bool // a fragment the edit set parsed, freed with it
	// a fragment's bindings: those in scope where it was put first, which it keeps
	scope map[string]string
}

// NodeEdit is what changed at one node.
struct NodeEdit {
mut:
	text     ?string
	attrs    []AttrChange
	ins      []Insert // elements put under this one, each before an original child or at the end
	lost     int      // original children removed or moved away
	detached bool     // not where it was: removed, or moved
	placed   bool     // put under `parent` by an insert or a move
	parent   u64 = no_key
}

struct AttrChange {
	name  string
	value ?string // none: removed
}

struct Insert {
	anchor u64 // the original child it goes before; no_key: after the last
	node   u64
}

// Edit is a set of edits over a document.
@[heap]
pub struct Edit {
pub:
	doc &Doc = unsafe { nil }
mut:
	pieces []Piece
	nodes  map[u64]NodeEdit
}

// edit starts an empty edit set over the document, which must outlive it.
pub fn (d &Doc) edit() &Edit {
	return &Edit{
		doc:    d
		pieces: [Piece{
			doc:  d
			root: 0
		}]
	}
}

// free releases the fragments the edit set parsed.
pub fn (mut e Edit) free() {
	for mut p in e.pieces {
		if p.owned {
			mut d := p.doc
			d.free()
		}
	}
	e.pieces = []
}

// ENode is a node of an edited document: an element, read with the edits applied.
pub struct ENode {
pub:
	e   &Edit = unsafe { nil }
	key u64   = no_key
}

// EAttr is an attribute of an edited element.
pub struct EAttr {
pub:
	name  string
	value string
}

// root is the root element.
pub fn (e &Edit) root() ENode {
	return ENode{e, ekey(0, 1)}
}

// node is element i of the document, as edited.
pub fn (e &Edit) node(i u32) ENode {
	return ENode{e, ekey(0, i)}
}

// ok reports whether the handle names a node.
pub fn (n ENode) ok() bool {
	return n.key != no_key
}

// source is the node this one reads: in the edited document, or in inserted content.
pub fn (n ENode) source() Node {
	if !n.ok() {
		return Node{}
	}
	return Node{n.e.pieces[kpiece(n.key)].doc, kindex(n.key)}
}

// name is the element's name.
pub fn (n ENode) name() string {
	if !n.ok() {
		return ''
	}
	src := n.source()
	return src.doc.name(src.i)
}

// text is the element's own text, decoded: beside child elements, the text beside them, joined.
pub fn (n ENode) text() string {
	if !n.ok() {
		return ''
	}
	if ne := n.e.nodes[n.key] {
		if t := ne.text {
			return t
		}
	}
	src := n.source()
	return src.doc.own_text_of(src.i)
}

// attr is the value of the attribute name; '' when there is none.
pub fn (n ENode) attr(name string) string {
	return n.attr_opt(name) or { '' }
}

// has_attr reports whether the element has the attribute name.
pub fn (n ENode) has_attr(name string) bool {
	return n.attr_opt(name) != none
}

fn (n ENode) attr_opt(name string) ?string {
	for a in n.attrs() {
		if a.name == name {
			return a.value
		}
	}
	return none
}

// attrs are the element's attributes, in order: the original ones as changed, then the new.
pub fn (n ENode) attrs() []EAttr {
	if !n.ok() {
		return []
	}
	src := n.source()
	ne := n.e.nodes[n.key] or { NodeEdit{} }
	return final_attrs(src.doc, src.i, ne.attrs).map(EAttr{it.name, it.value})
}

// FinalAttr is an attribute of an edited element: src is the original attribute it is (-1 for a
// new one), changed whether its value was set.
struct FinalAttr {
	name    string
	value   string
	src     int
	changed bool
}

// final_attrs applies changes, in order, to the attributes of element i: a value set replaces
// the one the element has, in its place, or comes after the others; a removed attribute set again
// is a new one.
fn final_attrs(d &Doc, i u32, changes []AttrChange) []FinalAttr {
	mut out := []FinalAttr{}
	lo, hi := d.attr_range(i)
	for a := lo; a < hi; a++ {
		out << FinalAttr{d.attr_name(a), d.attr_value(a), int(a), false}
	}
	for c in changes {
		k := out.map(it.name).index(c.name)
		if v := c.value {
			if k >= 0 {
				out[k] = FinalAttr{c.name, v, out[k].src, true}
			} else {
				out << FinalAttr{c.name, v, -1, true}
			}
		} else if k >= 0 {
			out.delete(k)
		}
	}
	return out
}

// children are the child elements, in order.
pub fn (n ENode) children() []ENode {
	if !n.ok() {
		return []
	}
	return n.e.kids(n.key).map(ENode{n.e, it})
}

// child is the first child element named name, or an empty handle.
pub fn (n ENode) child(name string) ENode {
	for c in n.children() {
		if c.name() == name {
			return c
		}
	}
	return ENode{n.e, no_key}
}

// parent is the parent element; an empty handle for the root and for a removed element.
pub fn (n ENode) parent() ENode {
	if !n.ok() {
		return n
	}
	return ENode{n.e, n.e.parent_of(n.key)}
}

// removed reports whether the element is not in the edited document.
pub fn (n ENode) removed() bool {
	return !n.ok() || !n.e.in_tree(n.key)
}

// own_text_of is element i's own text, decoded: its text, or beside child elements, the text
// beside them, joined.
fn (d &Doc) own_text_of(i u32) string {
	if d.text_len[i] != 0 {
		return d.text(i)
	}
	mut parts := []string{}
	mut c := d.first_child(i)
	for c != no_node {
		if d.is_text(c) {
			parts << d.text(c)
		}
		c = d.next_sibling(c)
	}
	return parts.join('')
}

// --- structure ------------------------------------------------------------------------------

fn (e &Edit) doc_of(k u64) &Doc {
	return e.pieces[kpiece(k)].doc
}

fn (e &Edit) is_element(k u64) bool {
	return e.doc_of(k).is_element(kindex(k))
}

// original_parent is the parent k has where it was read, within its piece; no_key for the root
// and for a piece's own root.
fn (e &Edit) original_parent(k u64) u64 {
	p := kpiece(k)
	i := kindex(k)
	if i == e.pieces[p].root {
		return no_key
	}
	up := e.pieces[p].doc.parent[i]
	if p == 0 && up == 0 {
		return no_key
	}
	return ekey(p, up)
}

fn (e &Edit) detached(k u64) bool {
	ne := e.nodes[k] or { return false }
	return ne.detached
}

// parent_of is k's parent in the edited document.
fn (e &Edit) parent_of(k u64) u64 {
	if ne := e.nodes[k] {
		if ne.placed {
			return ne.parent
		}
		if ne.detached {
			return no_key
		}
	}
	return e.original_parent(k)
}

// in_tree reports whether k is in the edited document: its chain of parents reaches the root.
fn (e &Edit) in_tree(k u64) bool {
	mut c := k
	for c != no_key {
		if c == ekey(0, 1) {
			return true
		}
		ne := e.nodes[c] or { NodeEdit{} }
		if ne.detached && !ne.placed {
			return false
		}
		c = e.parent_of(c)
	}
	return false
}

// kids are the child elements of p in the edited document: its original children that are still
// there, and before each, what was put before it; then what was put at the end.
fn (e &Edit) kids(p u64) []u64 {
	d := e.doc_of(p)
	pc := kpiece(p)
	ne := e.nodes[p] or { NodeEdit{} }
	mut out := []u64{}
	mut c := d.first_child(kindex(p))
	for c != no_node {
		ck := ekey(pc, c)
		for x in ne.ins {
			if x.anchor == ck {
				out << x.node
			}
		}
		if d.is_element(c) && !e.detached(ck) {
			out << ck
		}
		c = d.next_sibling(c)
	}
	for x in ne.ins {
		if x.anchor == no_key {
			out << x.node
		}
	}
	return out
}

// --- edits ----------------------------------------------------------------------------------

fn (e &Edit) check(n ENode, what string) ! {
	if !n.ok() || voidptr(n.e) != voidptr(e) {
		return error('${what}: not a node of this edit set')
	}
	if !e.is_element(n.key) {
		return error('${what}: not an element')
	}
	if !e.in_tree(n.key) {
		return error('${what}: <${n.name()}> is not in the document')
	}
}

// set_text replaces the element's own text. Beside child elements, the first run of text is
// replaced and the others removed; with none, the text goes first.
pub fn (mut e Edit) set_text(n ENode, text string) ! {
	e.check(n, 'set_text')!
	mut ne := e.nodes[n.key] or { NodeEdit{} }
	ne.text = text
	e.nodes[n.key] = ne
}

// set_attr gives the element the attribute name with value: in place of the one it has, or after
// its others.
pub fn (mut e Edit) set_attr(n ENode, name string, value string) ! {
	e.check(n, 'set_attr')!
	if name == '' || name.contains_any(' \t\r\n<>&=/"\'') {
		return error('set_attr: `${name}` is not an attribute name')
	}
	mut ne := e.nodes[n.key] or { NodeEdit{} }
	ne.attrs << AttrChange{name, value}
	e.nodes[n.key] = ne
}

// remove_attr removes the attribute name from the element, if it has it.
pub fn (mut e Edit) remove_attr(n ENode, name string) ! {
	e.check(n, 'remove_attr')!
	if !n.has_attr(name) {
		return
	}
	mut ne := e.nodes[n.key] or { NodeEdit{} }
	ne.attrs << AttrChange{name, none}
	e.nodes[n.key] = ne
}

// insert parses xml, an element (whitespace, comments and processing instructions around it are
// left out), and puts it under parent as its child element number index. It is read in the
// namespaces in scope where it is put.
pub fn (mut e Edit) insert(parent ENode, index int, xml string) !ENode {
	e.check(parent, 'insert')!
	d := parse_string(xml)!
	e.pieces << Piece{
		doc:   d
		root:  d.root()
		owned: true
		scope: e.scope_in(parent.key)
	}
	k := ekey(u32(e.pieces.len - 1), d.root())
	e.put(k, parent.key, index) or {
		e.drop_last_piece()
		return err
	}
	return ENode{e, k}
}

// insert_copy puts a copy of element src, from any document, under parent as its child element
// number index. It keeps the namespaces it has where it is; src's document must outlive the edit
// set.
pub fn (mut e Edit) insert_copy(parent ENode, index int, src Node) !ENode {
	e.check(parent, 'insert_copy')!
	if src.i == no_node || !src.doc.is_element(src.i) {
		return error('insert_copy: the source is not an element')
	}
	e.pieces << Piece{
		doc:  src.doc
		root: src.i
	}
	k := ekey(u32(e.pieces.len - 1), src.i)
	e.put(k, parent.key, index) or {
		e.pieces.delete_last()
		return err
	}
	return ENode{e, k}
}

fn (mut e Edit) drop_last_piece() {
	mut d := e.pieces.last().doc
	d.free()
	e.pieces.delete_last()
}

// remove takes the element out of the document. It can be put back with `place`.
pub fn (mut e Edit) remove(n ENode) ! {
	e.check(n, 'remove')!
	if n.key == ekey(0, 1) {
		return error('remove: the root element cannot be removed')
	}
	mut ne := e.nodes[n.key] or { NodeEdit{} }
	if ne.placed {
		mut pe := e.nodes[ne.parent] or { NodeEdit{} }
		at := pe.ins.map(it.node).index(n.key)
		pe.ins.delete(at)
		e.nodes[ne.parent] = pe
		ne.placed = false
		ne.parent = no_key
	} else {
		op := e.original_parent(n.key)
		mut pe := e.nodes[op] or { NodeEdit{} }
		pe.lost++
		e.nodes[op] = pe
	}
	ne.detached = true
	e.nodes[n.key] = ne
}

// place puts an element that was removed under parent, as its child element number index.
pub fn (mut e Edit) place(n ENode, parent ENode, index int) ! {
	if !n.ok() || voidptr(n.e) != voidptr(e) {
		return error('place: not a node of this edit set')
	}
	ne := e.nodes[n.key] or { NodeEdit{} }
	if !ne.detached || ne.placed {
		return error('place: <${n.name()}> is in the document; remove it first, or move it')
	}
	e.check(parent, 'place')!
	// an element cannot go under itself
	mut a := parent.key
	for a != no_key {
		if a == n.key {
			return error('place: <${n.name()}> cannot go inside itself')
		}
		a = e.parent_of(a)
	}
	e.put(n.key, parent.key, index)!
}

// move puts the element under parent as its child element number index: `remove`, then `place`.
pub fn (mut e Edit) move(n ENode, parent ENode, index int) ! {
	e.check(n, 'move')!
	e.check(parent, 'move')!
	mut a := parent.key
	for a != no_key {
		if a == n.key {
			return error('move: <${n.name()}> cannot go inside itself')
		}
		a = e.parent_of(a)
	}
	e.remove(n)!
	e.place(n, parent, index)!
}

// put files k under p before what is now its child element number index.
fn (mut e Edit) put(k u64, p u64, index int) ! {
	list := e.kids(p)
	if index < 0 || index > list.len {
		return error('index ${index} is out of range: <${e.doc_of(p).name(kindex(p))}> has ${list.len} child elements')
	}
	mut pe := e.nodes[p] or { NodeEdit{} }
	if index == list.len {
		pe.ins << Insert{no_key, k}
	} else {
		target := list[index]
		at := pe.ins.map(it.node).index(target)
		if at >= 0 {
			pe.ins.insert(at, Insert{pe.ins[at].anchor, k})
		} else {
			pe.ins << Insert{target, k}
		}
	}
	e.nodes[p] = pe
	mut ne := e.nodes[k] or { NodeEdit{} }
	ne.placed = true
	ne.parent = p
	e.nodes[k] = ne
}

// --- writing --------------------------------------------------------------------------------

// write writes the edited document as XML to w.
pub fn (e &Edit) write(mut w io.Writer) ! {
	mut em := emitter_to(e.doc, mut w, e.plan())
	em.walk(0)!
	em.flush()!
}

// write_file writes the edited document to path, as `Doc.write_file` does.
pub fn (e &Edit) write_file(path string) ! {
	write_file_with(e.doc, path, e.plan())!
}

// xml is the edited document as a string.
pub fn (e &Edit) xml() string {
	mut em := emitter_in(e.doc, e.plan(), e.doc.src_len + 64)
	em.walk(0) or { return '' }
	em.settle() or { return '' }
	return em.buf.str()
}

// EditPlan writes the edited document: what no edit touched is copied, an element whose own
// attributes, text or children changed is written by `write_element`, and the elements above
// one are walked.
struct EditPlan {
	e       &Edit
	touched map[u64]bool // elements whose own start tag or content changed
	dirty   map[u64]bool // those and every element above them, in their pieces
}

fn (e &Edit) plan() EditPlan {
	mut touched := map[u64]bool{}
	mut dirty := map[u64]bool{}
	for k, ne in e.nodes {
		if ne.text != none || ne.attrs.len > 0 || ne.ins.len > 0 || ne.lost > 0 {
			touched[k] = true
			mut a := k
			for a != no_key && a !in dirty {
				dirty[a] = true
				a = e.original_parent(a)
			}
		}
	}
	return EditPlan{
		e:       e
		touched: touched
		dirty:   dirty
	}
}

fn (p EditPlan) how(i u32) How {
	k := ekey(0, i)
	if k in p.touched {
		return .write
	}
	if k in p.dirty {
		return .content
	}
	return .whole
}

fn (p EditPlan) write(mut em Emitter, i u32) ! {
	em.write_element(p, ekey(0, i), []string{})!
}

// edited_child writes an original child c of an element being written.
fn (mut em Emitter) edited_child(p EditPlan, c u64) ! {
	if kpiece(c) == 0 {
		em.node(kindex(c))!
		return
	}
	d := p.e.doc_of(c)
	i := kindex(c)
	if d.is_element(i) && c in p.dirty {
		em.write_element(p, c, []string{})!
		return
	}
	a, b := d.span(i)
	em.copy_in(d, a, b)!
}

// placed writes k, put where it is by an insert or a move, with the namespace declarations that
// keep its names what they were.
fn (mut em Emitter) placed(p EditPlan, k u64) ! {
	decls := p.e.carried_decls(k)
	if k in p.dirty {
		em.write_element(p, k, decls)!
		return
	}
	d := p.e.doc_of(k)
	i := kindex(k)
	a, b := d.span(i)
	if decls.len == 0 {
		em.copy_in(d, a, b)!
		return
	}
	after_name := d.src_off[i] + 1 + u32(d.name(i).len)
	em.copy_in(d, a, after_name)!
	em.put(decls.join(''))!
	em.copy_in(d, after_name, b)!
}

// write_element writes element k with its edits: its start tag with the attribute changes (and
// decls, declarations to add), then its content: the bytes between its children kept, removed
// children left out with the indentation before them, inserted ones each after the indentation
// of the child they go before (or of the last child), and its text replaced.
fn (mut em Emitter) write_element(p EditPlan, k u64, decls []string) ! {
	e := p.e
	d := e.doc_of(k)
	i := kindex(k)
	ne := e.nodes[k] or { NodeEdit{} }
	ste := d.start_tag_end(i)
	if d.self_closing(ste) {
		// `<a/>`: content only from the edits, so whether there is any is known once written
		mut body := emitter_in(em.d, em.plan, 64)
		body.edited_content(p, k, ne, ste, ste)!
		body.settle()!
		if body.buf.len == 0 {
			em.start_tag(d, i, ne.attrs, decls, ste, true)!
			return
		}
		em.start_tag(d, i, ne.attrs, decls, ste, false)!
		em.put(body.buf.str())!
		em.put('</${d.name(i)}>')!
		return
	}
	em.start_tag(d, i, ne.attrs, decls, ste, false)!
	end_tag_lo := d.end_tag_at(d.content_end(i, ste))
	em.edited_content(p, k, ne, ste, end_tag_lo)!
	em.copy_in(d, end_tag_lo, d.close_after(i, end_tag_lo))!
}

// content_end is where the last child of i ends, or its text, or its start tag (ste): the end
// tag is the first one after it.
fn (d &Doc) content_end(i u32, ste u32) u32 {
	if i + 1 < d.end[i] {
		mut c := i + 1
		mut last := c
		for c < d.end[i] {
			last = c
			c = d.end[c]
		}
		return d.span_end(last)
	}
	if d.text_len[i] != 0 {
		return d.text_end(i)
	}
	return ste
}

// start_tag writes element i's start tag with the attribute changes, decls after its name, and
// `/>` or `>` as closed says. What no change touched is copied.
fn (mut em Emitter) start_tag(d &Doc, i u32, changes []AttrChange, decls []string, ste u32, closed bool) ! {
	after_name := d.src_off[i] + 1 + u32(d.name(i).len)
	final := final_attrs(d, i, changes)
	em.copy_in(d, d.src_off[i], after_name)!
	if decls.len > 0 {
		em.put(decls.join(''))!
	}
	mut pos := after_name // copied up to here
	lo, hi := d.attr_range(i)
	for a := lo; a < hi; a++ {
		vend := d.attr_off[a] + d.attr_len[a] + 1 // past the closing quote
		k := final.map(it.src).index(int(a))
		if k < 0 {
			// removed, with the whitespace before it
			em.copy_in(d, pos, d.attr_lead(a))!
			pos = vend
		} else if final[k].changed {
			// the value replaced, between the quote it had if it can be
			q := attr_quote(final[k].value, d.attr_source_quote(a))
			em.copy_in(d, pos, d.attr_off[a] - 1)!
			em.put(q.ascii_str() + escape_attr(final[k].value, q) + q.ascii_str())!
			pos = vend
		} else {
			em.copy_in(d, pos, vend)!
			pos = vend
		}
	}
	for f in final {
		if f.src < 0 {
			q := attr_quote(f.value, `"`)
			em.put(' ${f.name}=${q.ascii_str()}${escape_attr(f.value, q)}${q.ascii_str()}')!
		}
	}
	if !closed && d.self_closing(ste) {
		// `/>` becomes `>`: what was before the slash is kept
		em.copy_in(d, pos, ste - 2)!
		em.put('>')!
	} else {
		em.copy_in(d, pos, ste)!
	}
}

// attr_lead is where attribute a starts, with the whitespace before it.
fn (d &Doc) attr_lead(a u32) u32 {
	mut k := int(d.attr_off[a]) - 2 // before the opening quote
	for is_ws(unsafe { d.src[k] }) {
		k--
	}
	k-- // the `=`
	for is_ws(unsafe { d.src[k] }) {
		k--
	}
	k -= d.attr_name(a).len - 1 // the name's first byte
	for is_ws(unsafe { d.src[k - 1] }) {
		k--
	}
	return u32(k)
}

// edited_content writes the content of element k, lo .. hi of its document: see write_element.
// A new text replaces the first run of text and the others are left out; with none, it goes
// first.
fn (mut em Emitter) edited_content(p EditPlan, k u64, ne NodeEdit, lo u32, hi u32) ! {
	e := p.e
	d := e.doc_of(k)
	i := kindex(k)
	pc := kpiece(k)
	text_set := ne.text != none
	new_text := ne.text or { '' }
	mut has_text := d.text_len[i] != 0
	mut c := d.first_child(i)
	for c != no_node && !has_text {
		has_text = d.is_text(c)
		c = d.next_sibling(c)
	}
	mut pos := lo
	// Whitespace the parser left out stays out: none is written right after text, where it
	// would join it.
	mut text_last := false
	if text_set && !has_text && new_text != '' {
		em.text(new_text, false)!
		text_last = true
	}
	mut text_done := false // the first run of text replaced
	mut indent_last := ''
	// Each original child, after the bytes before it and what was put before it.
	c = d.first_child(i)
	for c != no_node {
		ck := ekey(pc, c)
		start := d.span_start(c)
		ind := ws_suffix_start(d, pos, start)
		indent := unsafe { tos(d.src + ind, int(start - ind)) }
		if d.is_element(c) {
			indent_last = indent
		}
		if text_last {
			pos = ws_prefix_end(d, pos, ind)
		}
		if pos < ind {
			em.copy_in(d, pos, ind)!
			text_last = false
		}
		for x in ne.ins {
			if x.anchor == ck {
				if !text_last {
					em.put(indent)!
				}
				em.placed(p, x.node)!
				text_last = false
			}
		}
		if d.is_text(c) {
			if !text_set {
				em.copy_in(d, ind, d.span_end(c))!
				text_last = true
			} else if !text_done {
				if new_text != '' {
					em.text(new_text, d.is_cdata(c))!
					text_last = true
				}
				text_done = true
			}
		} else if !e.detached(ck) {
			if !text_last {
				em.copy_in(d, ind, start)!
			}
			em.edited_child(p, ck)!
			text_last = false
		}
		pos = d.span_end(c)
		c = d.next_sibling(c)
	}
	// The rest: text that is the element's only content, comments, and the whitespace before the
	// end tag; what was put at the end goes before that whitespace.
	if text_last {
		pos = ws_prefix_end(d, pos, hi)
	}
	mut ws := ws_suffix_start(d, pos, hi)
	mut after_text := text_last && ws == pos
	if d.text_len[i] != 0 {
		tlo := d.text_off[i] - if d.is_cdata(i) { u32(9) } else { 0 }
		thi := d.text_end(i)
		if ws <= thi {
			ws = thi
			after_text = !text_set || new_text != ''
		}
		if text_set {
			em.copy_in(d, pos, tlo)!
			if new_text != '' {
				em.text(new_text, d.is_cdata(i))!
			}
			em.copy_in(d, thi, ws)!
		} else {
			em.copy_in(d, pos, ws)!
		}
	} else {
		em.copy_in(d, pos, ws)!
	}
	for x in ne.ins {
		if x.anchor == no_key {
			if !after_text {
				em.put(indent_last)!
			}
			em.placed(p, x.node)!
		}
	}
	em.copy_in(d, ws, hi)!
}

// last_child_node is the last child node of i, text or element.
fn (d &Doc) last_child_node(i u32) u32 {
	mut c := d.first_child(i)
	mut last := c
	for c != no_node {
		last = c
		c = d.next_sibling(c)
	}
	return last
}

// ws_prefix_end is where the whitespace that starts lo .. hi of d's source ends.
fn ws_prefix_end(d &Doc, lo u32, hi u32) u32 {
	mut k := lo
	for k < hi && is_ws(unsafe { d.src[k] }) {
		k++
	}
	return k
}

// ws_suffix_start is where the whitespace that ends lo .. hi of d's source starts.
fn ws_suffix_start(d &Doc, lo u32, hi u32) u32 {
	mut k := hi
	for k > lo && is_ws(unsafe { d.src[k - 1] }) {
		k--
	}
	return k
}

// --- namespaces -----------------------------------------------------------------------------

// carried_decls are the namespace declarations an inserted or moved element k needs where it is:
// for each prefix bound differently in the scope of its new parent than where it was read, its
// binding there (` xmlns:p="uri"`, or ` xmlns=""` for a default namespace it did not have).
fn (e &Edit) carried_decls(k u64) []string {
	ne := e.nodes[k] or { return [] }
	if !ne.placed {
		return []
	}
	src := e.source_scope(k)
	dst := e.scope_in(ne.parent)
	own := e.own_decls(k)
	mut prefixes := src.keys()
	for p in dst.keys() {
		if p !in src {
			prefixes << p
		}
	}
	prefixes.sort()
	mut out := []string{}
	for p in prefixes {
		if p in own {
			continue
		}
		have := src[p] or { '' }
		there := dst[p] or { '' }
		if have == there {
			continue
		}
		if p == '' {
			out << ' xmlns="${escape_attr(have, `"`)}"'
		} else if have != '' {
			out << ' xmlns:${p}="${escape_attr(have, `"`)}"'
		}
	}
	return out
}

// own_decls are the namespace declarations element k makes itself, as edited: prefix ('' for
// the default) -> URI.
fn (e &Edit) own_decls(k u64) map[string]string {
	mut out := map[string]string{}
	for a in ENode{e, k}.attrs() {
		if a.name == 'xmlns' {
			out[''] = a.value
		} else if a.name.starts_with('xmlns:') {
			out[a.name[6..]] = a.value
		}
	}
	return out
}

// source_scope is the bindings in scope where k was read: the declarations of the elements
// above it in its document as it was, and for a fragment, those where it was first put.
fn (e &Edit) source_scope(k u64) map[string]string {
	d := e.doc_of(k)
	mut out := e.pieces[kpiece(k)].scope.clone()
	mut seen := map[string]bool{}
	mut a := d.parent[kindex(k)]
	for a != no_node {
		lo, hi := d.attr_range(a)
		for x := lo; x < hi; x++ {
			name := d.attr_name(x)
			p := if name == 'xmlns' {
				''
			} else if name.starts_with('xmlns:') {
				name[6..]
			} else {
				continue
			}
			if p !in seen {
				seen[p] = true
				out[p] = d.attr_value(x)
			}
		}
		a = d.parent[a]
	}
	return out
}

// scope_in is the bindings in scope inside element k of the edited document: its own
// declarations, then those of where it was read if it was put where it is (inserted or moved),
// else its parent's.
fn (e &Edit) scope_in(k u64) map[string]string {
	mut out := e.own_decls(k)
	ne := e.nodes[k] or { NodeEdit{} }
	pc := kpiece(k)
	outer := if ne.placed {
		e.source_scope(k)
	} else {
		p := e.parent_of(k)
		if p == no_key {
			if pc != 0 && kindex(k) == e.pieces[pc].root {
				map[string]string{}
			} else {
				e.source_scope(k)
			}
		} else {
			e.scope_in(p)
		}
	}
	for p, u in outer {
		if p !in out {
			out[p] = u
		}
	}
	return out
}
