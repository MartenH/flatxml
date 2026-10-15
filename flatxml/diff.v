module flatxml

import hash

// The difference between two merged views (two document sets read by their rules, or two
// documents read as their own trees): what was removed, added, moved, and whose text or
// attributes changed, each change naming the node on both sides.
//
// The views are compared top down from their roots. Children that the rules identify (keyed by
// their key, single by their name) are matched by identity; the others are aligned in order, by
// the longest common subsequence of their subtrees (Myers' algorithm), and between the subtrees
// that align, paired by name. Each node's subtree has a hash, computed once, so a matched pair
// whose hashes agree is equal and is not entered. Matched children whose order changed, and a
// removed subtree equal to an added one, are moves.
//
// A change says enough to make the old view into the new one (see `Change`): apply every
// removal and lift every moved node out, then, parent by parent, put each added or moved node at
// its index, lowest first, and set the texts and attributes.

pub enum ChangeKind {
	removed // old: the node removed, with everything below it
	added   // new: the node added, with everything below it; parent and index: where it goes
	moved   // old: where it was; new: where it is; parent and index: where it goes
	text    // old and new: the node whose text changed
	attr    // old and new: the node; name: the attribute; old_value / new_value: none when absent
}

// Change is one difference. Nodes are of the old view (`old`, `parent`) or the new one (`new`).
pub struct Change {
pub:
	kind   ChangeKind
	old    MNode   // the node in the old view; empty for added
	new    MNode   // the node in the new view; empty for removed
	parent MNode   // added and moved: the node of the old view it goes under (empty for a root)
	index  int     // added and moved: its place among the children of new's parent
	name   string  // attr: the attribute's name
	before ?string // text: the old text; attr: the old value, none when it was absent
	after  ?string // text: the new text; attr: the new value, none when it is gone
}

// Diff is the changes from one view to another.
pub struct Diff {
pub:
	old &Merged = unsafe { nil }
	new &Merged = unsafe { nil }
pub mut:
	changes []Change
mut:
	ohash    []u64 // each node's subtree, hashed
	nhash    []u64
	tag_map  []u32 // a name id of the new view's table -> the same name's id in the old one
	compared int   // pairs of nodes entered
	max_d    int   // the most differences an alignment searches for before it pairs greedily
}

@[params]
pub struct DiffOptions {
pub:
	// the most differences one list of children is searched for (Myers' D) before the rest of it
	// is paired greedily, in order: a bound on the time and memory one alignment takes
	max_d int = 1000
}

// diff is the changes that make the view old into the view new. Both must be read by the same
// rules for their identities to agree.
pub fn diff(old &Merged, new &Merged, opts DiffOptions) Diff {
	mut d := Diff{
		old:   old
		new:   new
		max_d: opts.max_d
	}
	// the two views hashed at once, one of them on a thread of its own
	t := spawn subtree_hashes(new)
	d.ohash = subtree_hashes(old)
	d.nhash = t.wait()
	d.tag_map = []u32{len: new.set.tab.len(), init: if voidptr(new.set.tab) == voidptr(old.set.tab) {
		u32(index)
	} else {
		old.set.tab.id(new.set.tab.name(u32(index))) or { no_name }
	}}
	d.tag_map[0] = 0
	o, n := old.root(), new.root()
	if !o.ok() && !n.ok() {
		return d
	}
	if !o.ok() || !n.ok() || d.tag_map[n.tag()] != o.tag() {
		if o.ok() {
			d.changes << Change{
				kind: .removed
				old:  o
			}
		}
		if n.ok() {
			d.changes << Change{
				kind: .added
				new:  n
			}
		}
		return d
	}
	d.pair(o.i, n.i)
	d.moves()
	return d
}

// Doc.view is the document as a merged view by rules: with none, its own tree, one merged node
// per element. The view reads the document, which must outlive it.
pub fn (d &Doc) view(rules RuleSet) !&Merged {
	s := &DocSet{
		docs: [d]
		tab:  d.tab
	}
	return s.merge(rules)
}

// diff_docs is the changes that make document a into document b, read by rules (none: each as
// its own tree).
pub fn diff_docs(a &Doc, b &Doc, rules RuleSet, opts DiffOptions) !Diff {
	return diff(a.view(rules)!, b.view(rules)!, opts)
}

// equal reports whether there is no change.
pub fn (d &Diff) equal() bool {
	return d.changes.len == 0
}

// compared is how many pairs of nodes were entered: the rest were equal subtrees, skipped whole.
pub fn (d &Diff) compared() int {
	return d.compared
}

// --- hashing --------------------------------------------------------------------------------

@[inline]
fn mix(h u64, v u64) u64 {
	mut x := (h ^ v) * 0x9E37_79B9_7F4A_7C15
	x ^= x >> 31
	return x
}

fn text_hash(s string) u64 {
	return hash.wyhash_c(s.str, u64(s.len), name_seed)
}

// subtree_hashes hashes every node of m with what is below it: its name, text, attributes (in
// any order) and children (in order). Children come after their parent, so one pass from the
// end finds every child hashed before its parent.
fn subtree_hashes(m &Merged) []u64 {
	mut h := []u64{len: m.len()}
	t := m.set.tab
	for i := m.len() - 1; i >= 0; i-- {
		n := MNode{m, u32(i)}
		mut x := mix(t.hash[m.name[i]], text_hash(n.own_text()))
		x = mix(x, attrs_hash(n))
		for c := m.kid_lo[i]; c < m.kid_lo[i + 1]; c++ {
			x = mix(x, h[c])
		}
		put(h, i, x)
	}
	return h
}

// attrs_hash hashes the node's attributes as `attrs` has them, in any order: without making the
// list where there is one contribution.
fn attrs_hash(n MNode) u64 {
	t := n.m.set.tab
	mut h := u64(0)
	if n.fragment_count() == 1 {
		f := n.fragment(0)
		lo, hi := f.doc.attr_range(f.i)
		for a := lo; a < hi; a++ {
			h += mix(t.hash[f.doc.attr_tag[a]], text_hash(f.doc.attr_value(a)))
		}
		return h
	}
	for a in n.attrs() {
		h += mix(t.hash[a.tag], text_hash(a.value))
	}
	return h
}

// MAttr is an attribute of a merged node.
pub struct MAttr {
pub:
	tag   u32
	value string
}

// attrs are the node's attributes: each name once, from the first contribution that has it.
pub fn (n MNode) attrs() []MAttr {
	mut out := []MAttr{}
	for k in 0 .. n.fragment_count() {
		f := n.fragment(k)
		lo, hi := f.doc.attr_range(f.i)
		for a := lo; a < hi; a++ {
			t := f.doc.attr_tag[a]
			if k == 0 || !out.any(it.tag == t) {
				out << MAttr{t, f.doc.attr_value(a)}
			}
		}
	}
	return out
}

// --- comparing ------------------------------------------------------------------------------

// pair compares old node o with new node n, which match: their texts, attributes and children.
fn (mut d Diff) pair(o u32, n u32) {
	if d.ohash[o] == d.nhash[n] {
		return
	}
	d.compared++
	om, nm := d.old.node(o), d.new.node(n)
	ot, nt := om.own_text(), nm.own_text()
	if ot != nt {
		d.changes << Change{
			kind:   .text
			old:    om
			new:    nm
			before: ot
			after:  nt
		}
	}
	d.attrs(om, nm)
	d.children(o, n)
}

// attrs reports the attributes changed, added and removed from om to nm.
fn (mut d Diff) attrs(om MNode, nm MNode) {
	oa, na := om.attrs(), nm.attrs()
	for a in na {
		t := d.tag_map[a.tag]
		mut found := false
		for b in oa {
			if b.tag == t {
				found = true
				if b.value != a.value {
					d.changes << Change{
						kind:   .attr
						old:    om
						new:    nm
						name:   d.new.set.tab.name(a.tag)
						before: b.value
						after:  a.value
					}
				}
				break
			}
		}
		if !found {
			d.changes << Change{
				kind:   .attr
				old:    om
				new:    nm
				name:   d.new.set.tab.name(a.tag)
				before: none
				after:  a.value
			}
		}
	}
	for b in oa {
		if !na.any(d.tag_map[it.tag] == b.tag) {
			d.changes << Change{
				kind:   .attr
				old:    om
				new:    nm
				name:   d.old.set.tab.name(b.tag)
				before: b.value
				after:  none
			}
		}
	}
}

// identified reports whether a node is found by its identity: keyed, or single.
@[inline]
fn identified(m &Merged, i u32) bool {
	return m.kind[i] == .keyed || m.kind[i] == .single
}

// children matches the children of o (old) and n (new), reports what is removed, added and
// moved among them, and compares each matched pair.
fn (mut d Diff) children(o u32, n u32) {
	olo, ohi := d.old.kid_lo[o], d.old.kid_lo[o + 1]
	nlo, nhi := d.new.kid_lo[n], d.new.kid_lo[n + 1]
	// for each new child, its match among the old ones (no_mnode: none), and the other way
	mut to_old := []u32{len: int(nhi - nlo), init: no_mnode}
	mut to_new := []u32{len: int(ohi - olo), init: no_mnode}
	// identified children by identity
	on := d.old.node(o)
	for c := nlo; c < nhi; c++ {
		if !identified(d.new, c) {
			continue
		}
		t := d.tag_map[d.new.name[c]]
		if t == no_name {
			continue
		}
		m := on.child_id(t, d.new.key_of(c))
		if m.ok() && d.old.kind[m.i] == d.new.kind[c] && to_new[m.i - olo] == no_mnode {
			to_old[c - nlo] = m.i
			to_new[m.i - olo] = c
		}
	}
	// the others aligned in order: equal subtrees first, then by name between them
	mut xs := []u32{}
	mut ys := []u32{}
	for c := olo; c < ohi; c++ {
		if !identified(d.old, c) {
			xs << c
		}
	}
	for c := nlo; c < nhi; c++ {
		if !identified(d.new, c) {
			ys << c
		}
	}
	if xs.len > 0 && ys.len > 0 {
		a := xs.map(d.ohash[it])
		b := ys.map(d.nhash[it])
		pairs := align(a, b, d.max_d)
		mut px, mut py := 0, 0
		for p in pairs {
			d.pair_by_name(xs[px..p.x], ys[py..p.y], olo, nlo, mut to_old, mut to_new)
			to_old[ys[p.y] - nlo] = xs[p.x]
			to_new[xs[p.x] - olo] = ys[p.y]
			px, py = p.x + 1, p.y + 1
		}
		d.pair_by_name(xs[px..], ys[py..], olo, nlo, mut to_old, mut to_new)
	}
	// matched children out of order: the fewest moved, those off a longest increasing run
	mut seq := []int{}
	mut seq_at := []int{}
	for k, m in to_old {
		if m != no_mnode {
			seq << int(m)
			seq_at << k
		}
	}
	mut stays := []bool{len: seq.len}
	for k in increasing_run(seq) {
		stays[k] = true
	}
	for c := olo; c < ohi; c++ {
		if to_new[c - olo] == no_mnode {
			d.changes << Change{
				kind: .removed
				old:  d.old.node(c)
			}
		}
	}
	mut s := 0
	for k in 0 .. to_old.len {
		c := nlo + u32(k)
		m := to_old[k]
		if m == no_mnode {
			d.changes << Change{
				kind:   .added
				new:    d.new.node(c)
				parent: on
				index:  k
			}
			continue
		}
		if !stays[s] {
			d.changes << Change{
				kind:   .moved
				old:    d.old.node(m)
				new:    d.new.node(c)
				parent: on
				index:  k
			}
		}
		s++
		d.pair(m, c)
	}
}

// pair_by_name pairs, in order, the old and new children of one gap between aligned ones that
// have the same name.
fn (mut d Diff) pair_by_name(xs []u32, ys []u32, olo u32, nlo u32, mut to_old []u32, mut to_new []u32) {
	mut from := 0
	for y in ys {
		t := d.tag_map[d.new.name[y]]
		for k := from; k < xs.len; k++ {
			if d.old.name[xs[k]] == t {
				to_old[y - nlo] = xs[k]
				to_new[xs[k] - olo] = y
				from = k + 1
				break
			}
		}
	}
}

// moves makes each removed subtree that equals an added one (the same hash), in the order
// reported, a move.
fn (mut d Diff) moves() {
	mut removed := map[u64][]int{}
	for k, c in d.changes {
		if c.kind == .removed {
			removed[d.ohash[c.old.i]] << k
		}
	}
	if removed.len == 0 {
		return
	}
	mut drop := []bool{len: d.changes.len}
	for k, c in d.changes {
		if c.kind != .added {
			continue
		}
		h := d.nhash[c.new.i]
		mut ks := removed[h] or { continue }
		if ks.len == 0 {
			continue
		}
		r := ks[0]
		removed[h] = ks[1..].clone()
		drop[r] = true
		d.changes[k] = Change{
			kind:   .moved
			old:    d.changes[r].old
			new:    c.new
			parent: c.parent
			index:  c.index
		}
	}
	mut kept := []Change{cap: d.changes.len}
	for k, c in d.changes {
		if !drop[k] {
			kept << c
		}
	}
	d.changes = kept
}

// --- alignment ------------------------------------------------------------------------------

struct XY {
	x int
	y int
}

// align is a longest common subsequence of a and b, as index pairs in order: Myers' algorithm
// after the common start and end are taken off. Past max_d differences the rest is matched
// greedily, each element of b with the next equal one of a.
fn align(a []u64, b []u64, max_d int) []XY {
	mut out := []XY{}
	mut lo := 0
	for lo < a.len && lo < b.len && a[lo] == b[lo] {
		out << XY{lo, lo}
		lo++
	}
	mut ea, mut eb := a.len, b.len
	for ea > lo && eb > lo && a[ea - 1] == b[eb - 1] {
		ea--
		eb--
	}
	out << myers(a[lo..ea], b[lo..eb], lo, max_d)
	for k in 0 .. a.len - ea {
		out << XY{ea + k, eb + k}
	}
	return out
}

// myers is the pairs of a longest common subsequence of a and b (offset by base), or, past
// max_d differences, a greedy one.
fn myers(a []u64, b []u64, base int, max_d int) []XY {
	n, m := a.len, b.len
	if n == 0 || m == 0 {
		return []
	}
	off := n + m
	mut v := []int{len: 2 * off + 2}
	mut trace := [][]int{}
	mut end_d := -1
	for dd in 0 .. n + m + 1 {
		if dd > max_d {
			return greedy(a, b, base)
		}
		trace << v.clone()
		for k := -dd; k <= dd; k += 2 {
			mut x := if k == -dd || (k != dd && v[off + k - 1] < v[off + k + 1]) {
				v[off + k + 1]
			} else {
				v[off + k - 1] + 1
			}
			mut y := x - k
			for x < n && y < m && a[x] == b[y] {
				x++
				y++
			}
			v[off + k] = x
			if x >= n && y >= m {
				end_d = dd
				break
			}
		}
		if end_d >= 0 {
			break
		}
	}
	// back from the end: each round's snake, after its one step, is a run of matches
	mut out := []XY{}
	mut x, mut y := n, m
	for dd := end_d; dd >= 0; dd-- {
		vp := trace[dd]
		k := x - y
		pk := if k == -dd || (k != dd && vp[off + k - 1] < vp[off + k + 1]) { k + 1 } else { k - 1 }
		px := vp[off + pk]
		py := px - pk
		for x > px && y > py {
			x--
			y--
			out << XY{base + x, base + y}
		}
		x, y = px, py
	}
	out.reverse_in_place()
	return out
}

// greedy matches each element of b with the next equal element of a not yet passed.
fn greedy(a []u64, b []u64, base int) []XY {
	mut out := []XY{}
	mut from := 0
	for j, h in b {
		for i := from; i < a.len; i++ {
			if a[i] == h {
				out << XY{base + i, base + j}
				from = i + 1
				break
			}
		}
	}
	return out
}

// increasing_run is the positions of a longest strictly increasing subsequence of s.
fn increasing_run(s []int) []int {
	if s.len == 0 {
		return []
	}
	mut tails := []int{} // position in s of the smallest tail of a run of each length
	mut prev := []int{len: s.len, init: -1}
	for i, x in s {
		mut lo, mut hi := 0, tails.len
		for lo < hi {
			mid := (lo + hi) / 2
			if s[tails[mid]] < x {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
		if lo > 0 {
			prev[i] = tails[lo - 1]
		}
		if lo == tails.len {
			tails << i
		} else {
			tails[lo] = i
		}
	}
	mut out := []int{len: tails.len}
	mut k := tails.last()
	for j := tails.len - 1; j >= 0; j-- {
		out[j] = k
		k = prev[k]
	}
	return out
}

// --- describing -----------------------------------------------------------------------------

// path is where a merged node is, from the root: each step its name, with its key where it has
// one, or its place among the siblings of its name where there are several (`/r/item[pump]/x[2]`).
pub fn (n MNode) path() string {
	if !n.ok() {
		return ''
	}
	mut parts := []string{}
	mut c := n
	for c.ok() {
		mut step := c.name()
		if c.keyed() {
			step += '[${c.key().replace(key_sep, ',')}]'
		} else if c.m.kind[c.i] == .each {
			p := c.parent()
			mut nth, mut same := 0, 0
			for s in p.children() {
				if s.tag() == c.tag() {
					same++
					if s.i <= c.i {
						nth++
					}
				}
			}
			if same > 1 {
				step += '[${nth}]'
			}
		}
		parts << step
		c = c.parent()
	}
	parts.reverse_in_place()
	return '/' + parts.join('/')
}

// describe is a change in one line: what, where (the node's path), and its positions.
pub fn (c &Change) describe() string {
	return match c.kind {
		.removed {
			'- ${c.old.path()}  ${c.old.pos()}'
		}
		.added {
			'+ ${c.new.path()}  ${c.new.pos()}'
		}
		.moved {
			'> ${c.old.path()} -> ${c.new.path()}  ${c.old.pos()} -> ${c.new.pos()}'
		}
		.text {
			'~ ${c.new.path()}: ${quoted(c.before)} -> ${quoted(c.after)}  ${c.old.pos()} -> ${c.new.pos()}'
		}
		.attr {
			'@ ${c.new.path()}/@${c.name}: ${quoted(c.before)} -> ${quoted(c.after)}  ${c.old.pos()} -> ${c.new.pos()}'
		}
	}
}

fn quoted(s ?string) string {
	v := s or { return '(none)' }
	cut := if v.len > 60 { v[..57] + '...' } else { v }
	return '"' + cut.replace('\n', '\\n') + '"'
}
