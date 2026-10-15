module flatxml

import io
import os
import strings

// Writing a document back as XML. Every node keeps its place in the source, so what is not
// rewritten is copied: a node's bytes (`span`) and the bytes between nodes, where the comments,
// processing instructions and whitespace the tree does not hold are. Written unchanged, a
// document gives its file byte for byte.
//
// Only the start of a node is stored (`src_off`); its end is found when asked for, by reading
// forward from the end of its last descendant to the end tag. That costs nothing at parse time
// and nothing per node, and a write asks it only of the nodes it copies or walks.

// WriteMode says how `write` produces a document.
pub enum WriteMode {
	// the source's bytes, copied as one range
	verbatim
	// node by node: each element's tags and the bytes between nodes copied, each node located on
	// its own. The output is the source's bytes; this is how an edited document is written around
	// its changes.
	nodes
	// every node written from the tree's parts (names, decoded values escaped again), and only
	// the bytes before and after the root element copied. Comments, processing instructions and
	// whitespace between tags inside the root are not kept; the result parses to the same tree.
	rewrite
}

@[params]
pub struct WriteOptions {
pub:
	mode WriteMode
}

// write writes the document as XML to w.
pub fn (d &Doc) write(mut w io.Writer, opts WriteOptions) ! {
	mut e := new_emitter(d, mut w, ModePlan{ mode: opts.mode })
	e.walk(0)!
	e.flush()!
}

// write_file writes the document as XML to path, through a temporary file in the same directory
// that replaces path once it is complete, so the document may be written over its own file. A
// file that is replaced keeps its permissions.
pub fn (d &Doc) write_file(path string, opts WriteOptions) ! {
	mode := if st := os.stat(path) { st.mode } else { u32(0o644) }
	tmp := '${path}.${os.getpid()}.tmp'
	mut f := create_file(tmp, mode)!
	d.write(mut f, opts) or {
		f.close() or {}
		os.rm(tmp) or {}
		return err
	}
	f.close() or {
		os.rm(tmp) or {}
		return err
	}
	os.rename(tmp, path) or {
		os.rm(tmp) or {}
		return err
	}
}

// span is the bytes of node i in the source, `lo .. hi`: an element from its `<` to the end of
// its end tag (or of `/>`), a text node with its CDATA delimiters, node 0 the whole file.
pub fn (d &Doc) span(i u32) (u32, u32) {
	if i == 0 {
		return 0, u32(d.src_len)
	}
	return d.span_start(i), d.span_end(i)
}

// subtree_bytes is the source of node i and everything inside it, as `span` gives it. Zero-copy.
pub fn (d &Doc) subtree_bytes(i u32) string {
	lo, hi := d.span(i)
	return unsafe { tos(d.src + lo, int(hi - lo)) }
}

fn (d &Doc) span_start(i u32) u32 {
	if d.tag[i] == text_tag && d.is_cdata(i) {
		return d.text_off[i] - 9
	}
	return d.src_off[i]
}

// span_end is the offset just past node i. The last node of i's subtree, in document order, is
// the bottom of its chain of last children; its end is found directly, then each ancestor's end
// tag after it, up to i.
@[direct_array_access]
fn (d &Doc) span_end(i u32) u32 {
	if i == 0 {
		return u32(d.src_len)
	}
	mut k := d.end[i] - 1
	mut p := d.leaf_end(k)
	for k != i {
		k = d.parent[k]
		p = d.close_after(k, p)
	}
	return p
}

// leaf_end is the offset just past node i, which has no child nodes.
@[direct_array_access]
fn (d &Doc) leaf_end(i u32) u32 {
	if d.tag[i] == text_tag {
		return d.text_end(i)
	}
	ste := d.start_tag_end(i)
	if d.self_closing(ste) {
		return ste
	}
	mut p := ste
	if d.text_len[i] != 0 {
		p = d.text_end(i)
	}
	return d.close_after(i, p)
}

// text_end is the offset just past node i's text, CDATA delimiter included.
@[inline]
fn (d &Doc) text_end(i u32) u32 {
	e := d.text_off[i] + d.text_len[i]
	return if d.is_cdata(i) { e + 3 } else { e }
}

// start_tag_end is the offset just past element i's start tag (`>` or `/>`). The tag ends after
// its last attribute's closing quote, or after its name.
@[direct_array_access]
fn (d &Doc) start_tag_end(i u32) u32 {
	lo, hi := d.attr_range(i)
	from := if hi > lo {
		d.attr_off[hi - 1] + d.attr_len[hi - 1] + 1
	} else {
		d.src_off[i] + 1 + u32(d.tab.names[d.tag[i]].len)
	}
	return u32(find_byte(d.src, int(from), d.src_len, `>`)) + 1
}

// self_closing reports whether the start tag that ends at start_tag_end is an empty-element tag.
@[inline]
fn (d &Doc) self_closing(start_tag_end u32) bool {
	return unsafe { d.src[start_tag_end - 2] } == `/`
}

// close_after is the offset just past element i's end tag, the first one at or after p: between
// p and it there are only text, comments, processing instructions and empty CDATA sections.
@[direct_array_access]
fn (d &Doc) close_after(i u32, p u32) u32 {
	q := d.end_tag_at(p)
	mut k := int(q) + 2 + d.tab.names[d.tag[i]].len
	for is_ws(unsafe { d.src[k] }) {
		k++
	}
	return u32(k + 1)
}

// end_tag_at is the offset of the first end tag (`</`) at or after p that is not inside a
// comment, processing instruction or CDATA section.
fn (d &Doc) end_tag_at(p u32) u32 {
	mut k := int(p)
	for {
		q := find_byte(d.src, k, d.src_len, `<`)
		if q < 0 || q + 1 >= d.src_len {
			return u32(d.src_len)
		}
		c := unsafe { d.src[q + 1] }
		if c == `/` {
			return u32(q)
		}
		k = if c == `?` {
			d.skip_pi(q) or { d.src_len }
		} else if d.starts_at(q, '<!--') {
			d.comment_end(q)
		} else if d.starts_at(q, '<![CDATA[') {
			d.cdata_end(q)
		} else {
			q + 1
		}
		if k < 0 {
			return u32(d.src_len)
		}
	}
	return u32(d.src_len)
}

// --- the emitter ---------------------------------------------------------------------------

// How says what the emitter does with a node.
enum How {
	whole   // copy its bytes
	content // copy its tags and the bytes between its child nodes; each child as the plan says
	write   // let the plan write it
}

// Plan decides, node by node, what the emitter copies and what is written anew. An edited
// document's plan copies what no edit touched and writes what one did.
interface Plan {
	how(i u32) How
	write(mut e Emitter, i u32) !
}

// ModePlan is the plan of each `WriteMode`.
struct ModePlan {
	mode WriteMode
}

fn (p ModePlan) how(_ u32) How {
	return match p.mode {
		.verbatim { .whole }
		.nodes { .content }
		.rewrite { .write }
	}
}

fn (p ModePlan) write(mut e Emitter, i u32) ! {
	e.node_from_parts(i)!
}

const out_buf_size = 1 << 16

// Emitter writes XML to an io.Writer: ranges of the source, and text it is given. Adjacent
// ranges are joined into one before they are written, so copying a document node by node
// writes what copying it whole does. Small pieces are gathered in a buffer; a large range goes to
// the writer directly. Whatever writes to `buf` settles the pending range first.
struct Emitter {
	d    &Doc
	plan Plan
mut:
	w   io.Writer
	buf strings.Builder
	// the source range copied but not yet written
	lo u32
	hi u32
}

fn new_emitter(d &Doc, mut w io.Writer, plan Plan) Emitter {
	return Emitter{
		d:    d
		w:    w
		plan: plan
		buf:  strings.new_builder(out_buf_size)
	}
}

// copy writes the source bytes a .. b.
fn (mut e Emitter) copy(a u32, b u32) ! {
	if b <= a {
		return
	}
	if a != e.hi {
		e.settle()!
		e.lo = a
	}
	e.hi = b
}

// settle writes the pending source range.
fn (mut e Emitter) settle() ! {
	n := int(e.hi - e.lo)
	if n <= 0 {
		return
	}
	if n >= out_buf_size {
		e.flush_buf()!
		write_all(mut e.w, unsafe { (e.d.src + e.lo).vbytes(n) })!
	} else {
		unsafe { e.buf.write_ptr(e.d.src + e.lo, n) }
		e.spill()!
	}
	e.lo = e.hi
}

// put writes s.
fn (mut e Emitter) put(s string) ! {
	e.settle()!
	e.buf.write_string(s)
	e.spill()!
}

// spill passes the buffer on once it is full.
@[inline]
fn (mut e Emitter) spill() ! {
	if e.buf.len >= out_buf_size {
		e.flush_buf()!
	}
}

// flush writes everything held back.
fn (mut e Emitter) flush() ! {
	e.settle()!
	e.flush_buf()!
}

fn (mut e Emitter) flush_buf() ! {
	if e.buf.len > 0 {
		write_all(mut e.w, []u8(e.buf))!
		e.buf.go_back_to(0)
	}
}

fn write_all(mut w io.Writer, b []u8) ! {
	mut done := 0
	for done < b.len {
		n := w.write(b[done..])!
		if n <= 0 {
			return error('write failed')
		}
		done += n
	}
}

// node writes node i as the plan says.
fn (mut e Emitter) node(i u32) ! {
	match e.plan.how(i) {
		.whole {
			a, b := e.d.span(i)
			e.copy(a, b)!
		}
		.content {
			e.walk(i)!
		}
		.write {
			e.plan.write(mut e, i)!
		}
	}
}

// walk writes element i (or node 0, the document) with its tags and the bytes between its child
// nodes copied, and each child as the plan says. It returns the offset just past i.
fn (mut e Emitter) walk(i u32) !u32 {
	d := e.d
	if d.tag[i] == text_tag {
		a, b := d.span(i)
		e.copy(a, b)!
		return b
	}
	mut p := u32(0)
	if i != 0 {
		p = d.start_tag_end(i)
		e.copy(d.src_off[i], p)!
		if d.self_closing(p) {
			return p
		}
	}
	// Each child, after the bytes that lead up to it.
	mut c := d.first_child(i)
	for c != no_node {
		e.copy(p, d.span_start(c))!
		p = match e.plan.how(c) {
			.content {
				e.walk(c)!
			}
			else {
				e.node(c)!
				d.span_end(c)
			}
		}
		c = d.next_sibling(c)
	}
	if i == 0 {
		e.copy(p, u32(d.src_len))!
		return u32(d.src_len)
	}
	// What is left: text that is i's only content, if there is any, and what surrounds it
	from := if d.text_len[i] != 0 { d.text_end(i) } else { p }
	end := d.close_after(i, from)
	e.copy(p, end)!
	return end
}
