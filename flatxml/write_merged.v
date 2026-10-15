module flatxml

import io

// Writing a merged view as one document. Each merged node is written once. A node made of one
// contribution whose children are its contribution's own, unchanged all the way down, is copied
// byte for byte. Any other node is written from its first contribution: its start tag as written
// there, with the attributes only other contributions have after its own (first wins, as the
// view reads them); its text; and its merged children in the view's order, each after the bytes
// that stood before it where it was read (its indentation, and the comments before it), then the
// bytes before its first contribution's end tag. The bytes before and after the root are the
// first contribution's document's. An element read where other namespace bindings were in scope
// than where it is written is given the declarations that restore them, as an edit's is.

// write writes the merged view as one XML document to w.
pub fn (m &Merged) write(mut w io.Writer) ! {
	root := m.root()
	if !root.ok() {
		return error('the merged view is empty')
	}
	mut em := emitter_to(root.fragment(0).doc, mut w, ModePlan{})
	m.emit(mut em)!
	em.flush()!
}

// write_file writes the merged view as one XML document to path, as `Doc.write_file` does.
pub fn (m &Merged) write_file(path string) ! {
	write_through_temp(path, fn [m] (mut f FileOut) ! {
		m.write(mut f)!
	})!
}

// xml is the merged view as one XML document; '' when it is empty.
pub fn (m &Merged) xml() string {
	root := m.root()
	if !root.ok() {
		return ''
	}
	mut em := emitter_in(root.fragment(0).doc, ModePlan{}, 4096)
	m.emit(mut em) or { return '' }
	em.settle() or { return '' }
	return em.buf.str()
}

fn (m &Merged) emit(mut em Emitter) ! {
	root := m.root()
	f := root.fragment(0)
	lo, hi := f.doc.span(f.i)
	em.copy_in(f.doc, 0, lo)!
	mut w := MergedWriter{
		m:    m
		pure: m.pure_nodes()
	}
	w.element(mut em, root.i, map[string]string{})!
	em.copy_in(f.doc, hi, u32(f.doc.src_len))!
}

// pure_nodes says, per merged node, whether it is its one contribution unchanged: one
// contribution, whose child elements are, in order, the contributions of its merged children,
// each pure too. Children come after their parent, so one pass from the end decides them all.
fn (m &Merged) pure_nodes() []bool {
	mut pure := []bool{len: m.len()}
	for n := m.len() - 1; n >= 0; n-- {
		if m.frag_lo[n + 1] - m.frag_lo[n] != 1 {
			continue
		}
		f := m.frags[m.frag_lo[n]]
		d := m.set.docs[f.doc]
		mut ok := true
		mut k := m.kid_lo[n]
		mut c := d.first_child(f.i)
		for c != no_node && ok {
			if d.is_element(c) {
				if k >= m.kid_lo[n + 1] || !pure[k] {
					ok = false
				} else {
					kf := m.frags[m.frag_lo[k]]
					ok = kf.doc == f.doc && kf.i == c
				}
				k++
			}
			c = d.next_sibling(c)
		}
		pure[n] = ok && k == m.kid_lo[n + 1]
	}
	return pure
}

struct MergedWriter {
	m    &Merged
	pure []bool
}

// element writes merged node n where the bindings scope are in scope.
fn (w &MergedWriter) element(mut em Emitter, n u32, scope map[string]string) ! {
	m := w.m
	f := m.frag_node(m.frags[m.frag_lo[n]])
	d := f.doc
	i := f.i
	after_name := d.src_off[i] + 1 + u32(d.name(i).len)
	own := own_decls_of(d, i)
	src := source_bindings(d, i)
	decls := scope_decls(src, scope, own)
	if w.pure[n] {
		a, b := d.span(i)
		em.copy_in(d, a, after_name)!
		if decls.len > 0 {
			em.put(decls.join(''))!
		}
		em.copy_in(d, after_name, b)!
		return
	}
	// the start tag: its first contribution's, then what only the others have
	em.copy_in(d, d.src_off[i], after_name)!
	if decls.len > 0 {
		em.put(decls.join(''))!
	}
	lo, hi := d.attr_range(i)
	attrs_end := if hi > lo { d.attr_off[hi - 1] + d.attr_len[hi - 1] + 1 } else { after_name }
	em.copy_in(d, after_name, attrs_end)!
	// in scope inside it: what was where it was read (which decls restore), and its own
	mut inner := scope.clone()
	if '' !in src {
		inner.delete('')
	}
	for p, u in src {
		inner[p] = u
	}
	for p, u in own {
		inner[p] = u
	}
	mut have := map[u32]bool{}
	for a := lo; a < hi; a++ {
		have[d.attr_tag[a]] = true
	}
	for a in MNode{m, n}.attrs() {
		if a.tag in have {
			continue
		}
		name := m.set.tab.name(a.tag)
		q := attr_quote(a.value, `"`)
		em.put(' ${name}=${q.ascii_str()}${escape_attr(a.value, q)}${q.ascii_str()}')!
		if is_ns_decl_name(name) && decl_prefix(name) !in own {
			inner[decl_prefix(name)] = a.value
		}
	}
	ste := d.start_tag_end(i)
	closed := d.self_closing(ste)
	kids := m.kid_lo[n + 1] - m.kid_lo[n]
	if closed && kids == 0 {
		em.copy_in(d, attrs_end, ste)!
		return
	}
	if closed {
		em.copy_in(d, attrs_end, ste - 2)!
		em.put('>')!
	} else {
		em.copy_in(d, attrs_end, ste)!
	}
	w.content(mut em, n, d, i, ste, closed, inner)!
	if closed {
		em.put('</${d.name(i)}>')!
	} else {
		ets := d.end_tag_at(d.content_end(i, ste))
		em.copy_in(d, ets, d.close_after(i, ets))!
	}
}

// content writes the content of merged node n, whose first contribution is element i of d: its
// text, from that contribution, each run after as many of the merged children as there were
// child elements before it there; the merged children, each after the bytes before it where it
// was read; then what stood before the contribution's end tag. Whitespace is not written next to
// text, where it would join it.
fn (w &MergedWriter) content(mut em Emitter, n u32, d &Doc, i u32, ste u32, closed bool, scope map[string]string) ! {
	m := w.m
	mut text_last := false
	// text that is the contribution's only content: with the comments around it, first
	if d.text_len[i] != 0 {
		ets := d.end_tag_at(d.text_end(i))
		em.copy_in(d, ste, ets)!
		text_last = ets == d.text_end(i)
	}
	// the contribution's text nodes, by the number of child elements before each
	mut runs := [][]u32{}
	mut slot := 0
	mut c := d.first_child(i)
	for c != no_node {
		if d.is_text(c) {
			for runs.len <= slot {
				runs << []u32{}
			}
			runs[slot] << c
		} else {
			slot++
		}
		c = d.next_sibling(c)
	}
	for k := m.kid_lo[n]; k < m.kid_lo[n + 1]; k++ {
		idx := int(k - m.kid_lo[n])
		if idx < runs.len {
			for t in runs[idx] {
				a, b := d.span(t)
				em.copy_in(d, a, b)!
				text_last = true
			}
		}
		kf := m.frag_node(m.frags[m.frag_lo[k]])
		mut lead := lead_start(kf.doc, kf.i)
		start := kf.doc.span_start(kf.i)
		if text_last {
			lead = ws_prefix_end(kf.doc, lead, start)
		}
		em.copy_in(kf.doc, lead, start)!
		w.element(mut em, k, scope)!
		text_last = false
	}
	nkids := int(m.kid_lo[n + 1] - m.kid_lo[n])
	for k in nkids .. runs.len {
		for t in runs[k] {
			a, b := d.span(t)
			em.copy_in(d, a, b)!
			text_last = true
		}
	}
	if closed || d.text_len[i] != 0 {
		return
	}
	// what stood after the contribution's last child, before its end tag
	mut tail := ste
	if i + 1 < d.end[i] {
		tail = d.span_end(d.last_child_of(i))
	}
	ets := d.end_tag_at(tail)
	if text_last {
		tail = ws_prefix_end(d, tail, ets)
	}
	em.copy_in(d, tail, ets)!
}

// lead_start is where the bytes before node i start: the end of its previous sibling, or of its
// parent's start tag. A text node before it ends where it starts.
fn lead_start(d &Doc, i u32) u32 {
	p := d.parent[i]
	mut prev := i - 1
	if prev == p {
		return if p == 0 { 0 } else { d.start_tag_end(p) }
	}
	for d.parent[prev] != p {
		prev = d.parent[prev]
	}
	return d.span_end(prev)
}

// last_child_of is element i's last child node, text or element; i has one.
fn (d &Doc) last_child_of(i u32) u32 {
	mut c := i + 1
	mut last := c
	for c < d.end[i] {
		last = c
		c = d.end[c]
	}
	return last
}

// source_bindings are the namespace bindings in scope where element i was read, from the
// declarations of the elements above it.
fn source_bindings(d &Doc, i u32) map[string]string {
	mut out := map[string]string{}
	for x in d.inherited_ns_decls(i) {
		out[decl_prefix(d.attr_name(x))] = d.attr_value(x)
	}
	return out
}

// own_decls_of are the namespace declarations element i makes: prefix ('' for the default) ->
// URI.
fn own_decls_of(d &Doc, i u32) map[string]string {
	mut out := map[string]string{}
	lo, hi := d.attr_range(i)
	for a := lo; a < hi; a++ {
		if is_ns_decl_name(d.attr_name(a)) {
			out[decl_prefix(d.attr_name(a))] = d.attr_value(a)
		}
	}
	return out
}
