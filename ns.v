module flatxml

// Namespaces (Namespaces in XML 1.0), resolved on request by `resolve_namespaces`, so a document
// read without them costs nothing extra. Resolution gives every element and attribute a
// namespace id and a local name; names are split once per distinct name, not per node.

pub const xml_ns_uri = 'http://www.w3.org/XML/1998/namespace'
pub const xmlns_ns_uri = 'http://www.w3.org/2000/xmlns/'

// Namespace ids. 0 is no namespace; 1 and 2 are the two reserved namespaces.
pub const no_ns = u32(0)
pub const xml_ns = u32(1)
pub const xmlns_ns = u32(2)

// The prefix recorded for a name that is not a qualified name.
const not_qname = u32(0xFFFF_FFFF)

// resolve_namespaces fills `ns` (per node) and `attr_ns` (per attribute) and the URI table, and
// fails on what the Namespaces recommendation makes an error: an unbound prefix, a name that is
// not a qualified name (`a:b:c`, `:a`, `a:`), a misuse of the reserved prefixes or namespaces,
// undeclaring a prefix, and two attributes of one element with the same expanded name.
// A namespace declaration (`xmlns`, `xmlns:p`) is itself in the xmlns namespace.
@[direct_array_access]
pub fn (mut d Doc) resolve_namespaces() ! {
	if d.ns.len == d.tag.len {
		return
	}
	d.split_names()
	xml_id := d.intern_str('xml')
	xmlns_id := d.intern_str('xmlns')
	d.ns_uris = ['', xml_ns_uri, xmlns_ns_uri]
	d.ns_ids = {
		'':           no_ns
		xml_ns_uri:   xml_ns
		xmlns_ns_uri: xmlns_ns
	}
	mut ns := []u32{len: d.tag.len}
	mut attr_ns := []u32{len: d.attr_tag.len}
	// bind[p] is the namespace prefix name p is bound to; slot 0 is the default namespace.
	// 0 means unbound for a prefix and no namespace for the default.
	mut bind := []u32{len: d.names.len}
	bind[xml_id] = xml_ns
	// The declaring elements still open (their `end`), and for each the undo log of the
	// bindings it changed, so a binding ends with the element that made it.
	mut open_end := []u32{}
	mut open_undo := []int{}
	mut undo_slot := []u32{}
	mut undo_old := []u32{}
	// Walk the elements in document order, keeping `bind` to the declarations in scope.
	for k in 1 .. d.tag.len {
		i := u32(k)
		for open_end.len > 0 && i >= open_end[open_end.len - 1] {
			lo := open_undo.pop()
			open_end.delete_last()
			for undo_slot.len > lo {
				bind[undo_slot.pop()] = undo_old.pop()
			}
		}
		tag := d.tag[i]
		if tag == text_tag {
			continue
		}
		lo, hi := d.attr_range(i)
		mut declared := false
		mut prefixed := false
		// Apply this element's declarations first: they are in scope for its own name and its
		// attributes. Note whether any other attribute has a prefix to resolve after them.
		for a := lo; a < hi; a++ {
			an := d.attr_tag[a]
			ap := d.name_prefix[an]
			slot := if ap == 0 {
				if an != xmlns_id {
					continue
				}
				u32(0)
			} else if ap == xmlns_id {
				d.name_local[an]
			} else {
				prefixed = true
				continue
			}
			attr_ns[a] = xmlns_ns
			uri := d.attr_value(a)
			id := d.ns_intern(uri)
			if slot == xmlns_id {
				return d.err_at(int(d.src_off[i]), 'the prefix xmlns must not be declared')
			}
			if slot == xml_id && id != xml_ns {
				return d.err_at(int(d.src_off[i]), 'the prefix xml must not be bound to another namespace')
			}
			if slot != xml_id && (id == xml_ns || id == xmlns_ns) {
				return d.err_at(int(d.src_off[i]), '${uri} is reserved and must not be bound to ${d.decl_target(slot)}')
			}
			if slot != 0 && id == no_ns {
				return d.err_at(int(d.src_off[i]), 'the prefix ${d.names[slot]} must not be undeclared')
			}
			if !declared {
				open_end << d.end[i]
				open_undo << undo_slot.len
				declared = true
			}
			undo_slot << slot
			undo_old << bind[slot]
			bind[slot] = id
		}
		p := d.name_prefix[tag]
		if p == not_qname {
			return d.err_at(int(d.src_off[i]), '<${d.names[tag]}> is not a qualified name')
		}
		ns[i] = bind[p]
		if p != 0 && ns[i] == 0 {
			return d.err_at(int(d.src_off[i]), 'the prefix of <${d.names[tag]}> is not bound to a namespace')
		}
		if !prefixed {
			continue
		}
		// The prefixed attributes; unprefixed ones are in no namespace.
		for a := lo; a < hi; a++ {
			an := d.attr_tag[a]
			ap := d.name_prefix[an]
			if ap == 0 || ap == xmlns_id {
				continue
			}
			if ap == not_qname {
				return d.err_at(int(d.src_off[i]), 'attribute ${d.names[an]} is not a qualified name')
			}
			attr_ns[a] = bind[ap]
			if attr_ns[a] == 0 {
				return d.err_at(int(d.src_off[i]), 'the prefix of attribute ${d.names[an]} is not bound to a namespace')
			}
		}
		d.check_expanded_attrs(i, lo, hi, attr_ns)!
	}
	d.ns = ns
	d.attr_ns = attr_ns
}

// check_expanded_attrs fails when two attributes of element i, one of them prefixed, have the
// same namespace and local name. Two unprefixed duplicates are the parser's to judge.
fn (d &Doc) check_expanded_attrs(i u32, lo u32, hi u32, attr_ns []u32) ! {
	for a := lo; a < hi; a++ {
		if attr_ns[a] == no_ns || attr_ns[a] == xmlns_ns {
			continue
		}
		for b := lo; b < hi; b++ {
			if b != a && attr_ns[b] == attr_ns[a]
				&& d.name_local[d.attr_tag[b]] == d.name_local[d.attr_tag[a]] {
				return d.err_at(int(d.src_off[i]), 'attributes ${d.names[d.attr_tag[a]]} and ${d.names[d.attr_tag[b]]} have the same expanded name')
			}
		}
	}
}

fn (d &Doc) decl_target(slot u32) string {
	return if slot == 0 { 'the default namespace' } else { 'the prefix ${d.names[slot]}' }
}

// split_names records, for every interned name, its prefix (`not_qname` when it is not a
// qualified name) and local name ids. Prefixes and local names are interned too.
fn (mut d Doc) split_names() {
	n := d.names.len
	mut prefix := []u32{len: n}
	mut local := []u32{len: n}
	// Split each name at its colon; a name with none is its own local name.
	for id in 0 .. n {
		name := d.names[id]
		c := name.index_u8(`:`)
		if c < 0 {
			local[id] = u32(id)
			continue
		}
		if c == 0 || c == name.len - 1 || name.last_index_u8(`:`) != c {
			prefix[id] = not_qname
			local[id] = u32(id)
			continue
		}
		prefix[id] = d.intern(name.str, c)
		local[id] = d.intern(unsafe { name.str + c + 1 }, name.len - c - 1)
	}
	// The prefixes and local names interned above have no colon: each is its own local name.
	for id in n .. d.names.len {
		prefix << 0
		local << u32(id)
	}
	d.name_prefix = prefix
	d.name_local = local
}

fn (mut d Doc) intern_str(s string) u32 {
	id := d.intern(s.str, s.len)
	// a name interned after split_names: no colon, its own local name
	for d.name_prefix.len < d.names.len {
		d.name_prefix << 0
		d.name_local << u32(d.name_prefix.len - 1)
	}
	return id
}

fn (mut d Doc) ns_intern(uri string) u32 {
	if id := d.ns_ids[uri] {
		return id
	}
	id := u32(d.ns_uris.len)
	d.ns_uris << uri
	d.ns_ids[uri] = id
	return id
}

// --- reading resolved names ------------------------------------------------------------------
// These need `resolve_namespaces` to have run; before it, ns_of and attr_ns_of answer 0.

// ns_of is the namespace id of element i.
@[inline]
pub fn (d &Doc) ns_of(i u32) u32 {
	return if int(i) < d.ns.len { d.ns[i] } else { no_ns }
}

// local_id is the name id of element i's local name.
@[inline]
pub fn (d &Doc) local_id(i u32) u32 {
	return d.name_local[d.tag[i]]
}

// local_name is element i's name without its prefix.
pub fn (d &Doc) local_name(i u32) string {
	return d.names[d.name_local[d.tag[i]]]
}

// attr_ns_of is the namespace id of attribute a.
@[inline]
pub fn (d &Doc) attr_ns_of(a u32) u32 {
	return if int(a) < d.attr_ns.len { d.attr_ns[a] } else { no_ns }
}

// attr_local_id is the name id of attribute a's local name.
@[inline]
pub fn (d &Doc) attr_local_id(a u32) u32 {
	return d.name_local[d.attr_tag[a]]
}

// attr_local_name is attribute a's name without its prefix.
pub fn (d &Doc) attr_local_name(a u32) string {
	return d.names[d.name_local[d.attr_tag[a]]]
}

// is_ns_decl reports whether attribute a declares a namespace (`xmlns` or `xmlns:p`).
@[inline]
pub fn (d &Doc) is_ns_decl(a u32) bool {
	return d.attr_ns_of(a) == xmlns_ns
}

// ns_uri is the URI of namespace id; '' for no namespace.
pub fn (d &Doc) ns_uri(id u32) string {
	return d.ns_uris[id]
}

// ns_id is the id of a namespace URI, if the document declares it (or it is reserved).
pub fn (d &Doc) ns_id(uri string) ?u32 {
	return d.ns_ids[uri] or { return none }
}
