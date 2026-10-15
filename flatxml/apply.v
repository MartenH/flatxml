module flatxml

import os

// Edits on a merged view, and a diff applied with them.
//
// A merged view's nodes are lists of nodes of its documents, so an edit on the view is edits on
// those documents: one edit set per document (`Edit`), made the first time that document is
// edited. A value held in several fragments is set in each, and a removed merged node is removed
// from every document that holds part of it. Structure is edited per document: a new element goes
// under one fragment of its parent, in the document the caller names. Written, each changed
// document goes back to its own file, every byte no edit touched kept.

// MEdit is a set of edits on a merged view: an edit set per document of its set.
@[heap]
pub struct MEdit {
pub:
	view &Merged = unsafe { nil }
mut:
	edits map[int]&Edit // a document's number in the set -> its edit set, once edited
}

// edit starts an empty set of edits on the view, whose documents must outlive it.
pub fn (m &Merged) edit() &MEdit {
	return &MEdit{
		view: m
	}
}

// doc_edit is the edit set of document k of the view's set, made the first time it is asked for.
pub fn (mut me MEdit) doc_edit(k int) &Edit {
	if e := me.edits[k] {
		return e
	}
	e := me.view.set.docs[k].edit()
	me.edits[k] = e
	return e
}

// edited are the numbers of the documents with an edit, in order.
pub fn (me &MEdit) edited() []int {
	mut ks := []int{}
	for k, e in me.edits {
		if e.nodes.len > 0 {
			ks << k
		}
	}
	ks.sort()
	return ks
}

// fragment is the fragment of n in document k as that document's edit set reads it; an empty
// handle when n has none there.
pub fn (mut me MEdit) fragment(n MNode, k int) ENode {
	for j in 0 .. n.fragment_count() {
		f := n.m.frags[n.m.frag_lo[n.i] + u32(j)]
		if int(f.doc) == k {
			return me.doc_edit(k).node(f.i)
		}
	}
	return ENode{}
}

// fragments are n's fragments as their documents' edit sets read them, in the set's order.
pub fn (mut me MEdit) fragments(n MNode) []ENode {
	mut out := []ENode{}
	for j in 0 .. n.fragment_count() {
		f := n.m.frags[n.m.frag_lo[n.i] + u32(j)]
		out << me.doc_edit(int(f.doc)).node(f.i)
	}
	return out
}

// set_text_runs sets the own text of every fragment of n (see `Edit.set_text_runs`).
pub fn (mut me MEdit) set_text_runs(n MNode, runs []TextRun) ! {
	for f in me.fragments(n) {
		mut e := f.e
		e.set_text_runs(f, runs)!
	}
}

// set_text sets the own text of every fragment of n (see `Edit.set_text`).
pub fn (mut me MEdit) set_text(n MNode, text string) ! {
	me.set_text_runs(n, if text == '' { []TextRun{} } else { [TextRun{0, text}] })!
}

// set_attr sets the attribute name of every fragment of n.
pub fn (mut me MEdit) set_attr(n MNode, name string, value string) ! {
	for f in me.fragments(n) {
		mut e := f.e
		e.set_attr(f, name, value)!
	}
}

// remove_attr removes the attribute name from every fragment of n that has it.
pub fn (mut me MEdit) remove_attr(n MNode, name string) ! {
	for f in me.fragments(n) {
		mut e := f.e
		e.remove_attr(f, name)!
	}
}

// remove removes every fragment of n from its document.
pub fn (mut me MEdit) remove(n MNode) ! {
	for f in me.fragments(n) {
		if !f.removed() {
			mut e := f.e
			e.remove(f)!
		}
	}
}

// write_files writes each edited document back to its own path (`Edit.write_file`); the others
// are not touched.
pub fn (mut me MEdit) write_files() ! {
	for k in me.edited() {
		e := me.edits[k] or { continue }
		e.write_file(me.view.set.docs[k].path)!
	}
}

// write_to writes every document of the set to the path to gives it: an edited one as edited,
// the others as they are, byte for byte.
pub fn (mut me MEdit) write_to(to fn (d &Doc) string) ! {
	for k, d in me.view.set.docs {
		path := to(d)
		os.mkdir_all(os.dir(path))!
		if e := me.edits[k] {
			e.write_file(path)!
		} else {
			d.write_file(path)!
		}
	}
}

// --- applying a diff ------------------------------------------------------------------------

// IntoFn names the document of the old view a new element goes to: given a fragment of the
// element in the new view and the old node it goes under, the number of a document of the old
// set that holds part of that node; -1 for the default, the document of its first fragment.
pub type IntoFn = fn (fragment Node, parent MNode) int

@[params]
pub struct ApplyOptions {
pub:
	// where a new element goes, among the documents its parent is in; by default, the document of
	// its nearest sibling, before it or else after it, or of its parent's first fragment
	into ?IntoFn
}

// apply makes the changes of the diff on its old view, as edits on the old view's documents: the
// documents the diff was made from, so that, written, they read as the new view. Removed nodes
// are removed from every document that holds part of them; moved ones lifted out and put back
// where they go; added ones copied from the new view's documents, each fragment into the document
// `into` names (by default, the document of its nearest sibling); texts and attribute values set
// in the fragments that hold the old ones (a fragment that disagreed already keeps its own), and
// a removed attribute removed from all. Each element is put after the nearest
// of its new siblings before it that the document holds, so a document keeps its own order.
//
// A diff places text by slot and reports a text change only where the runs differ, so an element
// whose children change (a child removed, added, or moved out or in) has its runs set again at
// their old slots, unless it has a text change of its own.
pub fn (d &Diff) apply(opts ApplyOptions) !&MEdit {
	mut me := d.old.edit()
	mut a := Applier{
		d:    d
		me:   me
		into: opts.into
	}
	a.run()!
	return me
}

// apply makes the changes of a diff between two documents on the first, as edits: the diff
// must have been made from old (`diff_docs`), and the edit set is old's.
pub fn apply(diff Diff, old &Doc) !&Edit {
	if diff.old.set.docs.len != 1 || voidptr(diff.old.set.docs[0]) != voidptr(old) {
		return error('apply: the diff was not made from this document')
	}
	mut me := diff.apply()!
	return me.doc_edit(0)
}

struct Applier {
	d    &Diff = unsafe { nil }
	into ?IntoFn
mut:
	me &MEdit = unsafe { nil }
	// where an added or moved node went: its new view index, document -> the element made
	present map[u64]ENode
	// old nodes whose subtrees were copied whole into another document: what is below them is in
	// the copy as the new view has it
	copied map[u32]bool
}

@[inline]
fn present_key(n u32, k int) u64 {
	return (u64(n) << 32) | u64(k)
}

fn (mut a Applier) run() ! {
	d := a.d
	if d.changes.any(it.kind in [.added, .removed] && !(if it.kind == .added {
		it.parent.ok()
	} else {
		it.old.parent().ok()
	})) {
		return error('apply: the roots differ, so there is nothing to apply the diff to')
	}
	// the parents whose children change, their runs as they were
	mut slots := map[u64][]TextRun{} // an edit-set node, by key and document -> its runs
	mut slot_nodes := map[u64]ENode{}
	for c in d.changes {
		if c.kind in [.removed, .moved] {
			a.keep_runs(c.old.parent(), mut slots, mut slot_nodes)
		}
		if c.kind in [.added, .moved] {
			a.keep_runs(c.parent, mut slots, mut slot_nodes)
		}
	}
	for c in d.changes {
		if c.kind == .text {
			for f in a.me.fragments(c.old) {
				slots.delete(node_key(f))
			}
		}
	}
	// out: the removed, and the moved, to be put back
	for c in d.changes {
		if c.kind in [.removed, .moved] {
			a.me.remove(c.old)!
		}
	}
	// in: parent by parent, lowest index first
	mut ins := d.changes.filter(it.kind in [.added, .moved])
	ins.sort_with_compare(fn (x &Change, y &Change) int {
		if x.parent.i != y.parent.i {
			return if x.parent.i < y.parent.i { -1 } else { 1 }
		}
		return x.index - y.index
	})
	for c in ins {
		if a.inside_copy(c.parent) {
			continue
		}
		if c.kind == .added {
			a.add(c)!
		} else {
			a.move(c)!
		}
	}
	for k, runs in slots {
		n := slot_nodes[k] or { continue }
		if n.text_runs() != runs {
			mut e := n.e
			e.set_text_runs(n, runs)!
		}
	}
	for c in d.changes {
		if c.kind !in [.text, .attr] || a.inside_copy(c.old) {
			continue
		}
		// a value changes in the fragments that hold the old one, a fragment that disagreed
		// already (a value the rules report as differing) keeping its own; a value the node did
		// not have goes to one fragment, as a new element would
		name := if c.old_name != '' { c.old_name } else { c.name }
		old_runs := c.old.text_runs()
		fresh := if c.kind == .text { old_runs.len == 0 } else { c.before == none }
		only := if fresh && c.old.fragment_count() > 1 { a.value_target(c) } else { ENode{} }
		for f in a.me.fragments(c.old) {
			if only.ok() && (only.key != f.key || voidptr(only.e) != voidptr(f.e)) {
				continue
			}
			mut e := f.e
			if c.kind == .text {
				if only.ok() || c.old.fragment_count() == 1 || f.text_runs() == old_runs {
					e.set_text_runs(f, c.runs)!
				}
			} else if v := c.after {
				cur := f.attr_opt(name)
				held := if b := c.before {
					cur or { '\x00' } == b
				} else {
					cur == none
				}
				if held || c.old.fragment_count() == 1 {
					e.set_attr(f, name, v)!
				}
			} else {
				e.remove_attr(f, name)!
			}
		}
	}
}

// value_target is the fragment of c.old a value it did not have goes to: in the document `into`
// names for the new node's fragment that holds it, else the old node's first fragment.
fn (mut a Applier) value_target(c Change) ENode {
	if into := a.into {
		for j in 0 .. c.new.fragment_count() {
			f := c.new.fragment(j)
			holds := if c.kind == .text { f.text_runs().len > 0 } else { f.has_attr(c.name) }
			if holds {
				k := into(f, c.old)
				t := if k >= 0 { a.me.fragment(c.old, k) } else { ENode{} }
				if t.ok() {
					return t
				}
				break
			}
		}
	}
	return a.me.fragments(c.old)[0]
}

fn node_key(n ENode) u64 {
	return n.key ^ (u64(voidptr(n.e)) << 16)
}

// keep_runs notes the runs of every fragment of p, as they are before its children change.
fn (mut a Applier) keep_runs(p MNode, mut slots map[u64][]TextRun, mut nodes map[u64]ENode) {
	if !p.ok() || a.inside_copy(p) {
		return
	}
	for f in a.me.fragments(p) {
		k := node_key(f)
		if k !in slots {
			slots[k] = f.text_runs()
			nodes[k] = f
		}
	}
}

// inside_copy reports whether old node n is in a subtree copied whole to another document.
fn (a &Applier) inside_copy(n MNode) bool {
	if a.copied.len == 0 {
		return false
	}
	mut c := n
	for c.ok() {
		if a.copied[c.i] {
			return true
		}
		c = c.parent()
	}
	return false
}

// target is the fragment of parent p in the document a new element's fragment f goes to: the one
// `into` names, else the document of its nearest new sibling that one of p's fragments holds
// (of its own aggregation first; before it, else after it), else p's first fragment's.
fn (mut a Applier) target(f Node, p MNode, np MNode, index int) ENode {
	if into := a.into {
		k := into(f, p)
		if k >= 0 {
			t := a.me.fragment(p, k)
			if t.ok() {
				return t
			}
		}
	}
	frags := a.me.fragments(p)
	if frags.len > 1 {
		d := a.d
		lo, hi := int(d.new.kid_lo[np.i]), int(d.new.kid_lo[np.i + 1])
		rule := d.new.rule[lo + index]
		// the siblings of its own aggregation first, then any
		mut order := sibling_order(index, hi - lo).filter(d.new.rule[lo + it] == rule)
		order << sibling_order(index, hi - lo).filter(d.new.rule[lo + it] != rule)
		for s in order {
			sib := u32(lo + s)
			for t in frags {
				k := doc_number(a.me, t.e)
				if present_key(sib, k) in a.present {
					return t
				}
				if old := d.matched[sib] {
					o := a.me.fragment(d.old.node(old), k)
					if o.ok() && o.parent().key == t.key {
						return t
					}
				}
			}
		}
	}
	return frags[0]
}

// sibling_order is the places of a child's siblings, nearest first: those before it, then those
// after it.
fn sibling_order(index int, count int) []int {
	mut out := []int{cap: count}
	for s := index - 1; s >= 0; s-- {
		out << s
	}
	for s in index + 1 .. count {
		out << s
	}
	return out
}

// position is where, among the children of parent fragment t, the new node at index in the new
// view's children of np goes: after the nearest sibling before it that t holds; first if none.
fn (mut a Applier) position(t ENode, np MNode, index int) int {
	d := a.d
	k := doc_number(a.me, t.e)
	kids := t.children()
	lo := d.new.kid_lo[np.i]
	for s := index - 1; s >= 0; s-- {
		sib := lo + u32(s)
		mut there := ENode{}
		if p := a.present[present_key(sib, k)] {
			there = p
		} else if old := d.matched[sib] {
			for f in a.me.fragments(d.old.node(old)) {
				if voidptr(f.e) == voidptr(t.e) && f.parent().key == t.key {
					there = f
				}
			}
		}
		if there.ok() {
			for x, c in kids {
				if c.key == there.key {
					return x + 1
				}
			}
		}
	}
	return 0
}

fn doc_number(me &MEdit, e &Edit) int {
	for k, x in me.edits {
		if voidptr(x) == voidptr(e) {
			return k
		}
	}
	return -1
}

// add copies every fragment of the added node c.new into its parent's fragment in the document
// each goes to.
fn (mut a Applier) add(c Change) ! {
	np := c.new.parent()
	for j in 0 .. c.new.fragment_count() {
		f := c.new.fragment(j)
		t := a.target(f, c.parent, np, c.index)
		mut e := t.e
		made := e.insert_copy(t, a.position(t, np, c.index), f)!
		a.present[present_key(c.new.i, doc_number(a.me, e))] = made
	}
}

// move puts each fragment of the moved node back under its parent's fragment in the same
// document. Where the parent has none in one of them, or a node of one fragment would go to
// another document (its new siblings are there), it copies the new view's node instead, each
// fragment into the document it goes to, what is below it as the new view has it.
fn (mut a Applier) move(c Change) ! {
	np := c.new.parent()
	frags := a.me.fragments(c.old)
	// one fragment goes where an added element would; several, each in its own document
	mut across := frags.any(!a.me.fragment(c.parent, doc_number(a.me, it.e)).ok())
	if frags.len == 1 && !across {
		t := a.target(c.old.fragment(0), c.parent, np, c.index)
		across = voidptr(t.e) != voidptr(frags[0].e)
	}
	if !across {
		for f in frags {
			t := a.me.fragment(c.parent, doc_number(a.me, f.e))
			mut e := f.e
			e.place(f, t, a.position(t, np, c.index))!
			a.present[present_key(c.new.i, doc_number(a.me, e))] = f
		}
	} else {
		a.copied[c.old.i] = true
		for j in 0 .. c.new.fragment_count() {
			g := c.new.fragment(j)
			t := a.target(g, c.parent, np, c.index)
			mut e := t.e
			made := e.insert_copy(t, a.position(t, np, c.index), g)!
			a.present[present_key(c.new.i, doc_number(a.me, e))] = made
		}
	}
}
