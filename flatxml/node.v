module flatxml

import strconv

// Node is a handle on an element of a document. A missing node is a valid, empty handle: every
// lookup on it gives another empty one, and every read gives the empty value or the default
// asked for, so a chain of lookups needs no check at every step:
//
//   port := doc.root_node().child('ports').child('port')
//   speed := port.attr_int('speed', 100)
//
// A handle is a pointer and an index; it allocates nothing, and neither do the iterators.
pub struct Node {
pub:
	doc &Doc = unsafe { nil }
	i   u32 // the node's index in doc; no_node for an empty handle
}

// node is a handle on node i of d.
@[inline]
pub fn (d &Doc) node(i u32) Node {
	return Node{d, i}
}

// root_node is the root element.
@[inline]
pub fn (d &Doc) root_node() Node {
	return Node{d, d.root()}
}

// ok reports whether the handle names a node.
@[inline]
pub fn (n Node) ok() bool {
	return n.i != no_node
}

// tag is the element's name id; text_tag for none.
@[inline]
pub fn (n Node) tag() u32 {
	return if n.i == no_node { text_tag } else { n.doc.tag[n.i] }
}

// name is the element's name; '' for none.
pub fn (n Node) name() string {
	return if n.i == no_node { '' } else { n.doc.name(n.i) }
}

// is reports whether the element is named name.
pub fn (n Node) is(name string) bool {
	return n.i != no_node && n.doc.name(n.i) == name
}

// text is the element's text, decoded; '' for none. An element with child elements has the text
// beside them, joined (`Doc.text_content`).
pub fn (n Node) text() string {
	if n.i == no_node {
		return ''
	}
	return if n.doc.has_text_children(n.i) { n.doc.text_content(n.i) } else { n.doc.text(n.i) }
}

// attr is the value of the attribute name, decoded; '' when there is none.
pub fn (n Node) attr(name string) string {
	if n.i == no_node {
		return ''
	}
	return n.doc.attr(n.i, name) or { '' }
}

// has_attr reports whether the element has the attribute name.
pub fn (n Node) has_attr(name string) bool {
	if n.i == no_node {
		return false
	}
	_ := n.doc.attr(n.i, name) or { return false }
	return true
}

// parent is the parent element; empty for the root.
pub fn (n Node) parent() Node {
	if n.i == no_node {
		return n
	}
	p := n.doc.parent[n.i]
	return Node{n.doc, if p == 0 { no_node } else { p }}
}

// first is the first child element.
pub fn (n Node) first() Node {
	if n.i == no_node {
		return n
	}
	mut c := n.doc.first_child(n.i)
	for c != no_node && !n.doc.is_element(c) {
		c = n.doc.next_sibling(c)
	}
	return Node{n.doc, c}
}

// next is the next sibling element.
pub fn (n Node) next() Node {
	if n.i == no_node {
		return n
	}
	mut c := n.doc.next_sibling(n.i)
	for c != no_node && !n.doc.is_element(c) {
		c = n.doc.next_sibling(c)
	}
	return Node{n.doc, c}
}

// child is the first child element named name.
pub fn (n Node) child(name string) Node {
	if n.i == no_node {
		return n
	}
	id := n.doc.tab.id(name) or { return Node{n.doc, no_node} }
	return n.child_id(id)
}

// child_id is the first child element with name id tag: child without the name lookup, for loops.
pub fn (n Node) child_id(tag u32) Node {
	if n.i == no_node {
		return n
	}
	return Node{n.doc, n.doc.child(n.i, tag)}
}

// pos is the node's position, `path:line:column`.
pub fn (n Node) pos() string {
	return if n.i == no_node { '' } else { n.doc.pos(n.i) }
}

// --- typed reads ------------------------------------------------------------------------------
// Each reads the trimmed text (or attribute value) and gives def when there is none or it does
// not read as the type.

// int is the element's text as an integer.
pub fn (n Node) int(def i64) i64 {
	return read_int(n.text(), def)
}

// f64 is the element's text as a number.
pub fn (n Node) f64(def f64) f64 {
	return read_f64(n.text(), def)
}

// bool is the element's text as a boolean: true or 1, false or 0.
pub fn (n Node) bool(def bool) bool {
	return read_bool(n.text(), def)
}

// attr_int is the attribute name as an integer.
pub fn (n Node) attr_int(name string, def i64) i64 {
	return read_int(n.attr(name), def)
}

// attr_f64 is the attribute name as a number.
pub fn (n Node) attr_f64(name string, def f64) f64 {
	return read_f64(n.attr(name), def)
}

// attr_bool is the attribute name as a boolean.
pub fn (n Node) attr_bool(name string, def bool) bool {
	return read_bool(n.attr(name), def)
}

fn read_int(s string, def i64) i64 {
	t := s.trim_space()
	if t == '' {
		return def
	}
	mut k := 0
	if t[0] == `-` || t[0] == `+` {
		k = 1
	}
	if k == t.len {
		return def
	}
	for c in t[k..] {
		if !c.is_digit() {
			return def
		}
	}
	return t.parse_int(10, 64) or { def }
}

fn read_f64(s string, def f64) f64 {
	t := s.trim_space()
	if t == '' {
		return def
	}
	return strconv.atof64(t) or { def }
}

fn read_bool(s string, def bool) bool {
	return match s.trim_space() {
		'true', '1' { true }
		'false', '0' { false }
		else { def }
	}
}

// --- iteration --------------------------------------------------------------------------------

// Children iterates over child elements, all of them or those with one name id.
pub struct Children {
	doc &Doc = unsafe { nil }
	tag u32 // text_tag for every element
mut:
	cur u32
}

// children are the child elements: `for c in n.children() { ... }`.
pub fn (n Node) children() Children {
	return Children{
		doc: n.doc
		tag: text_tag
		cur: if n.i == no_node { no_node } else { n.doc.first_child(n.i) }
	}
}

// children_named are the child elements named name.
pub fn (n Node) children_named(name string) Children {
	id := if n.i == no_node { u32(0) } else { n.doc.tab.id(name) or { u32(0) } }
	if id == 0 {
		return Children{
			doc: n.doc
		}
	}
	return n.children_id(id)
}

// children_id are the child elements with name id tag.
pub fn (n Node) children_id(tag u32) Children {
	return Children{
		doc: n.doc
		tag: tag
		cur: if n.i == no_node { no_node } else { n.doc.first_child(n.i) }
	}
}

pub fn (mut it Children) next() ?Node {
	for it.cur != no_node {
		c := it.cur
		it.cur = it.doc.next_sibling(c)
		t := it.doc.tag[c]
		if t != text_tag && (it.tag == text_tag || t == it.tag) {
			return Node{it.doc, c}
		}
	}
	return none
}

// Descendants iterates over the elements below a node with one name id, in document order: a
// scan of one array.
pub struct Descendants {
	doc &Doc = unsafe { nil }
	tag u32
	end u32
mut:
	cur u32
}

// descendants are the elements below n named name, at any depth.
pub fn (n Node) descendants(name string) Descendants {
	id := if n.i == no_node { u32(0) } else { n.doc.tab.id(name) or { u32(0) } }
	if id == 0 {
		return Descendants{
			doc: n.doc
		}
	}
	return n.descendants_id(id)
}

// descendants_id are the elements below n with name id tag.
pub fn (n Node) descendants_id(tag u32) Descendants {
	if n.i == no_node {
		return Descendants{
			doc: n.doc
		}
	}
	return Descendants{
		doc: n.doc
		tag: tag
		cur: n.i + 1
		end: n.doc.end[n.i]
	}
}

@[direct_array_access]
pub fn (mut it Descendants) next() ?Node {
	for it.cur < it.end {
		c := it.cur
		it.cur++
		if it.doc.tag[c] == it.tag {
			return Node{it.doc, c}
		}
	}
	return none
}

// --- paths ------------------------------------------------------------------------------------

// Path is a path of child element names, `a/b/c`, compiled once to name ids so finding it costs
// no hashing. A name the table does not have matches nothing.
pub struct Path {
	ids []u32
}

const no_name = u32(0xFFFF_FFFF)

// path compiles p (names separated by `/`) against the table: a set's table serves every
// document of the set.
pub fn (t &Names) path(p string) Path {
	return Path{
		ids: p.split('/').filter(it != '').map(t.id(it) or { no_name })
	}
}

// find is the first element, in document order, at path p below n.
pub fn (n Node) find(p Path) Node {
	if n.i == no_node || p.ids.len == 0 {
		return Node{n.doc, no_node}
	}
	return Node{n.doc, n.doc.find_from(n.i, p.ids, 0)}
}

// at is find with the path compiled on the spot: for a one-off lookup.
pub fn (n Node) at(p string) Node {
	if n.i == no_node {
		return n
	}
	return n.find(n.doc.tab.path(p))
}

// find_all is every element at path p below n, in document order.
pub fn (n Node) find_all(p Path) []Node {
	mut out := []Node{}
	if n.i != no_node && p.ids.len > 0 {
		n.doc.collect(n.i, p.ids, 0, mut out)
	}
	return out
}

fn (d &Doc) find_from(i u32, ids []u32, k int) u32 {
	mut c := d.first_child(i)
	for c != no_node {
		if d.tag[c] == ids[k] {
			if k == ids.len - 1 {
				return c
			}
			found := d.find_from(c, ids, k + 1)
			if found != no_node {
				return found
			}
		}
		c = d.next_sibling(c)
	}
	return no_node
}

fn (d &Doc) collect(i u32, ids []u32, k int, mut out []Node) {
	mut c := d.first_child(i)
	for c != no_node {
		if d.tag[c] == ids[k] {
			if k == ids.len - 1 {
				out << Node{d, c}
			} else {
				d.collect(c, ids, k + 1, mut out)
			}
		}
		c = d.next_sibling(c)
	}
}
