module flatxml

struct XRng {
mut:
	s u64
}

fn (mut r XRng) intn(n int) int {
	r.s ^= r.s << 13
	r.s ^= r.s >> 7
	r.s ^= r.s << 17
	return int(r.s % u64(n))
}

fn doc_of(name string, xml string) &Doc {
	return parse_bytes(xml.bytes(), name) or { panic('${err}\n${xml}') }
}

fn diff_of(a string, b string, rules string) Diff {
	rs := parse_rules(rules) or { panic(err) }
	return diff_docs(doc_of('a.xml', a), doc_of('b.xml', b), rs) or { panic(err) }
}

fn lines_of(d Diff) []string {
	return d.changes.map(it.describe())
}

// short is a change as kind, the old node's path and the new node's path.
fn short(c Change) string {
	return '${c.kind} ${c.old.path()} ${c.new.path()}'
}

fn shorts(d Diff) []string {
	return d.changes.map(short(it))
}

fn test_equal_documents_have_no_changes() {
	d := diff_of('<r><a x="1">t</a><b/></r>', '<r>\n  <a x="1">t</a>\n  <b></b>\n</r>', '')
	assert d.equal() && d.compared() == 0
}

fn test_text_changes() {
	d := diff_of('<r><a>one</a><b>two</b></r>', '<r><a>one</a><b>three</b></r>', '')
	assert lines_of(d) == ['~ /r/b: "two" -> "three"  a.xml:1:14 -> b.xml:1:14']
	assert d.changes[0].before or { '' } == 'two'
	// the text of mixed content is compared whole
	m := diff_of('<r><p>a <i/> b</p></r>', '<r><p>a <i/> c</p></r>', '')
	assert shorts(m) == ['text /r/p /r/p']
}

fn test_attribute_changes() {
	d := diff_of('<r><a x="1" y="2" z="3"/></r>', '<r><a x="1" y="5" w="4"/></r>', '')
	assert lines_of(d) == [
		'@ /r/a/@y: "2" -> "5"  a.xml:1:4 -> b.xml:1:4',
		'@ /r/a/@w: (none) -> "4"  a.xml:1:4 -> b.xml:1:4',
		'@ /r/a/@z: "3" -> (none)  a.xml:1:4 -> b.xml:1:4',
	]
}

fn test_removed_and_added() {
	d := diff_of('<r><a/><b/><c/></r>', '<r><a/><c/><d/></r>', '')
	assert shorts(d) == ['removed /r/b ', 'added  /r/d']
	add := d.changes[1]
	assert add.parent.path() == '/r' && add.index == 2
	// a repeated child: one of the two is added
	rep := diff_of('<r><a>1</a><b/></r>', '<r><a>1</a><a>1</a><b/></r>', '')
	assert rep.changes.len == 1 && rep.changes[0].kind == .added
}

fn test_children_paired_by_name_between_equal_ones() {
	// b changed in place: compared, not removed and added
	d := diff_of('<r><a/><b><c>1</c></b><d/></r>', '<r><a/><b><c>2</c></b><d/></r>', '')
	assert shorts(d) == ['text /r/b/c /r/b/c']
}

fn test_moves() {
	// two neighbours swapped: one of them moved
	s := diff_of('<r><a>1</a><b>2</b><c>3</c></r>', '<r><b>2</b><a>1</a><c>3</c></r>', '')
	assert s.changes.len == 1 && s.changes[0].kind == .moved
	// a subtree moved to another parent
	p := diff_of('<r><p><x>1</x></p><q/></r>', '<r><p/><q><x>1</x></q></r>', '')
	assert shorts(p) == ['moved /r/p/x /r/q/x']
	assert p.changes[0].parent.path() == '/r/q' && p.changes[0].index == 0
}

const keyed_rules = '
r s key=@id merge
s o key=@id ordered
s v single merge
'

fn test_keyed_children_are_matched_by_key() {
	// written in another order, keyed children of an unordered aggregation are the same
	same := diff_of('<r><s id="a"><v>1</v></s><s id="b"/></r>', '<r><s id="b"/><s id="a"><v>1</v></s></r>',
		keyed_rules)
	assert same.equal()
	// without rules the order counts
	assert !diff_of('<r><s id="a"><v>1</v></s><s id="b"/></r>', '<r><s id="b"/><s id="a"><v>1</v></s></r>',
		'').equal()
	d := diff_of('<r><s id="a"><v>1</v></s><s id="b"/></r>', '<r><s id="c"/><s id="a"><v>2</v></s></r>',
		keyed_rules)
	assert shorts(d) == ['removed /r/s[b] ', 'text /r/s[a]/v /r/s[a]/v', 'added  /r/s[c]']
	// order counts in an ordered aggregation
	o := diff_of('<r><s id="a"><o id="1"/><o id="2"/><o id="3"/></s></r>', '<r><s id="a"><o id="3"/><o id="1"/><o id="2"/></s></r>',
		keyed_rules)
	assert shorts(o) == ['moved /r/s[a]/o[3] /r/s[a]/o[3]']
	assert o.changes[0].index == 0
}

fn test_roots_named_differently() {
	d := diff_of('<r><a/></r>', '<q><a/></q>', '')
	assert shorts(d) == ['removed /r ', 'added  /q']
}

fn test_sets_compare_as_their_merged_views() {
	rs := parse_rules(keyed_rules) or { panic(err) }
	mut a := DocSet.new()
	for name, xml in {
		'a1.xml': '<r><s id="x"><v>1</v></s></r>'
		'a2.xml': '<r><s id="y"><o id="1"/></s></r>'
	} {
		mut d := doc_of(name, xml)
		a.add(mut d)
	}
	mut b := DocSet.new()
	mut one := doc_of('b.xml', '<r><s id="y"><o id="1"/></s><s id="x"><v>1</v></s></r>')
	b.add(mut one)
	ma := a.merge(rs) or { panic(err) }
	mb := b.merge(rs) or { panic(err) }
	// the files a model is kept in, and the order the rules impose, are not changes
	assert diff(ma, mb).equal()
	mut c := DocSet.new()
	mut two := doc_of('c.xml', '<r><s id="y"><o id="1"/><o id="2"/></s><s id="x"><v>1</v></s></r>')
	c.add(mut two)
	mc := c.merge(rs) or { panic(err) }
	d := diff(ma, mc)
	assert shorts(d) == ['added  /r/s[y]/o[2]']
	assert d.changes[0].parent.fragment(0).doc.path == 'a2.xml'
}

fn test_alignment() {
	assert align([u64(1), 2, 3, 4], [u64(1), 3, 4, 5], 100).map('${it.x}:${it.y}') == [
		'0:0',
		'2:1',
		'3:2',
	]
	assert align([u64(1), 2, 3], [u64(4), 5], 100).len == 0
	assert align([u64(7), 1, 2, 3, 7], [u64(7), 3, 2, 1, 7], 100).len == 3
	// past the bound, a greedy match: still in order
	g := align([u64(1), 2, 3, 4, 5, 6], [u64(6), 5, 4, 3, 2, 1, 1], 1)
	for k in 1 .. g.len {
		assert g[k].x > g[k - 1].x && g[k].y > g[k - 1].y
	}
	assert increasing_run([3, 1, 2, 5, 4]).map([3, 1, 2, 5, 4][it]) in [[1, 2, 5], [1, 2, 4]]
	assert increasing_run([]int{}).len == 0
}

// --- applied to the old view, a diff gives the new one -------------------------------------

@[heap]
struct TN {
mut:
	name  string
	text  string
	attrs map[string]string
	kids  []&TN
}

fn tn_of(n MNode, mut idx map[u32]&TN) &TN {
	mut t := &TN{
		name: n.name()
		text: n.own_text()
	}
	for a in n.attrs() {
		t.attrs[n.m.set.tab.name(a.tag)] = a.value
	}
	for c in n.children() {
		t.kids << tn_of(c, mut idx)
	}
	idx[n.i] = t
	return t
}

// apply makes the old view's tree into the new one's with the changes, as the comment at the top
// of diff.v says.
fn apply(d Diff) &TN {
	mut idx := map[u32]&TN{}
	mut root := tn_of(d.old.root(), mut idx)
	for c in d.changes {
		if c.kind == .added && !c.parent.ok() {
			mut none_ := map[u32]&TN{}
			return tn_of(c.new, mut none_)
		}
	}
	for c in d.changes {
		if c.kind in [.removed, .moved] {
			mut p := idx[c.old.parent().i] or { panic('no parent') }
			gone := idx[c.old.i] or { panic('no node') }
			p.kids = p.kids.filter(voidptr(it) != voidptr(gone))
		}
	}
	mut ins := d.changes.filter(it.kind in [.added, .moved])
	ins.sort(a.index < b.index)
	for c in ins {
		mut p := idx[c.parent.i] or { panic('no parent') }
		mut none_ := map[u32]&TN{}
		node := if c.kind == .added {
			tn_of(c.new, mut none_)
		} else {
			idx[c.old.i] or {
				panic('no node')
			}
		}
		p.kids.insert(c.index, node)
	}
	for c in d.changes {
		mut t := idx[c.old.i] or { continue }
		if c.kind == .text {
			t.text = c.after or { '' }
		} else if c.kind == .attr {
			if v := c.after {
				t.attrs[c.name] = v
			} else {
				t.attrs.delete(c.name)
			}
		}
	}
	return root
}

fn same_tn(a &TN, b &TN) bool {
	if a.name != b.name || a.text != b.text || a.kids.len != b.kids.len || a.attrs.len != b.attrs.len {
		return false
	}
	for k, v in a.attrs {
		if b.attrs[k] or { return false } != v {
			return false
		}
	}
	for i in 0 .. a.kids.len {
		if !same_tn(a.kids[i], b.kids[i]) {
			return false
		}
	}
	return true
}

fn (t &TN) xml() string {
	mut s := '<${t.name}'
	mut names := t.attrs.keys()
	names.sort()
	for k in names {
		s += ' ${k}="${t.attrs[k]}"'
	}
	s += '>' + t.text
	for c in t.kids {
		s += c.xml()
	}
	return s + '</${t.name}>'
}

fn (t &TN) copy() &TN {
	return &TN{
		name:  t.name
		text:  t.text
		attrs: t.attrs.clone()
		kids:  t.kids.map(it.copy())
	}
}

const gen_names = ['a', 'b', 'c', 'd']

fn gen_tree(mut r XRng, depth int) &TN {
	mut t := &TN{
		name: gen_names[r.intn(gen_names.len)]
	}
	if r.intn(3) == 0 {
		t.attrs['x'] = '${r.intn(3)}'
	}
	if r.intn(4) == 0 {
		t.attrs['y'] = '${r.intn(3)}'
	}
	n := if depth < 3 { r.intn(5) } else { 0 }
	if n == 0 && r.intn(2) == 0 {
		t.text = 't${r.intn(4)}'
	}
	for _ in 0 .. n {
		t.kids << gen_tree(mut r, depth + 1)
	}
	return t
}

// all_nodes is every node of t below it, with its parent.
fn all_nodes(t &TN, mut out []&TN, mut parents []&TN) {
	for c in t.kids {
		out << c
		parents << t
		all_nodes(c, mut out, mut parents)
	}
}

fn contains(t &TN, x &TN) bool {
	if voidptr(t) == voidptr(x) {
		return true
	}
	return t.kids.any(contains(it, x))
}

// mutate makes one random edit to t: a text or an attribute changed, a child removed, added or
// moved (within its parent or to another).
fn mutate(mut r XRng, mut t TN) {
	mut nodes := []&TN{}
	mut parents := []&TN{}
	all_nodes(t, mut nodes, mut parents)
	if nodes.len == 0 {
		t.kids << gen_tree(mut r, 2)
		return
	}
	k := r.intn(nodes.len)
	mut n := nodes[k]
	mut p := parents[k]
	match r.intn(6) {
		0 {
			if n.kids.len == 0 {
				n.text = 'e${r.intn(9)}'
			}
		}
		1 {
			n.attrs['x'] = 'e${r.intn(9)}'
		}
		2 {
			n.attrs.delete('y')
			n.attrs.delete('x')
		}
		3 {
			p.kids = p.kids.filter(voidptr(it) != voidptr(n))
		}
		4 {
			p.kids.insert(r.intn(p.kids.len + 1), gen_tree(mut r, 2))
		}
		else {
			mut to := if r.intn(2) == 0 { p } else { nodes[r.intn(nodes.len)] }
			if contains(n, to) {
				return
			}
			p.kids = p.kids.filter(voidptr(it) != voidptr(n))
			to.kids.insert(r.intn(to.kids.len + 1), n)
		}
	}
}

fn test_a_diff_applied_to_the_old_document_gives_the_new_one() {
	mut r := XRng{0x9E37_79B9_7F4A_7C15}
	mut changes := 0
	for round in 0 .. 400 {
		mut a := &TN{
			name: 'r'
		}
		for _ in 0 .. 1 + r.intn(5) {
			a.kids << gen_tree(mut r, 0)
		}
		mut b := a.copy()
		for _ in 0 .. 1 + r.intn(4) {
			mutate(mut r, mut b)
		}
		for max_d in [1000, 1] {
			d := diff_docs(doc_of('a.xml', a.xml()), doc_of('b.xml', b.xml()), RuleSet{},
				max_d: max_d
			) or { panic(err) }
			got := apply(d)
			assert same_tn(got, b), 'round ${round}, max_d ${max_d}\n${a.xml()}\n${b.xml()}\n${got.xml()}\n${lines_of(d).join('\n')}'
			changes += d.changes.len
		}
	}
	assert changes > 1000
}

// --- with rules, known edits are reported exactly ------------------------------------------

struct KS {
mut:
	id   string
	v    string
	w    string
	kids []&KS // ordered
}

fn (s &KS) xml() string {
	mut x := '<s id="${s.id}" w="${s.w}">'
	if s.v != '' {
		x += '<v>${s.v}</v>'
	}
	for o in s.kids {
		x += o.oxml()
	}
	return x + '</s>'
}

fn (o &KS) oxml() string {
	mut x := '<o id="${o.id}" w="${o.w}">'
	if o.v != '' {
		x += '<v>${o.v}</v>'
	}
	return x + '</o>'
}

fn (s &KS) copy() &KS {
	return &KS{
		id:   s.id
		v:    s.v
		w:    s.w
		kids: s.kids.map(it.copy())
	}
}

const exact_rules = '
r s key=@id merge
s v single merge
s o key=@id ordered
o v single merge
'

fn test_known_edits_are_reported_exactly() {
	rules := parse_rules(exact_rules) or { panic(err) }
	mut r := XRng{0x2545_F491_4F6C_DD1D}
	mut seen := map[string]int{}
	for round in 0 .. 300 {
		mut ss := []&KS{}
		mut next := 0
		for i in 0 .. 3 + r.intn(4) {
			mut s := &KS{
				id: 's${i}'
				v:  'v${r.intn(3)}'
				w:  '${r.intn(3)}'
			}
			for _ in 0 .. r.intn(5) {
				s.kids << &KS{
					id: 'o${next}'
					v:  'v${r.intn(3)}'
					w:  '${r.intn(3)}'
				}
				next++
			}
			ss << s
		}
		old := '<r>' + ss.map(it.xml()).join('') + '</r>'
		// one edit to each of a few groups, so no two touch one node
		mut want := []string{}
		for g in 0 .. ss.len {
			if r.intn(2) == 0 {
				continue
			}
			mut s := ss[g]
			match r.intn(6) {
				0 {
					s.v = 'changed'
					want << 'text /r/s[${s.id}]/v /r/s[${s.id}]/v'
				}
				1 {
					s.w = 'changed'
					want << 'attr /r/s[${s.id}] /r/s[${s.id}]'
				}
				2 {
					if s.kids.len == 0 {
						continue
					}
					o := s.kids[r.intn(s.kids.len)]
					s.kids = s.kids.filter(voidptr(it) != voidptr(o))
					want << 'removed /r/s[${s.id}]/o[${o.id}] '
				}
				3 {
					s.kids.insert(r.intn(s.kids.len + 1), &KS{
						id: 'new${g}'
						v:  'n'
						w:  '0'
					})
					want << 'added  /r/s[${s.id}]/o[new${g}]'
				}
				4 {
					// by two places or more, or moving a neighbour would do as well
					if s.kids.len < 3 {
						continue
					}
					n := s.kids.len
					k := r.intn(n)
					if k < 2 && n - k - 2 < 1 {
						continue
					}
					to := if k >= 2 { r.intn(k - 1) } else { k + 2 + r.intn(n - k - 2) }
					o := s.kids[k]
					s.kids.delete(k)
					s.kids.insert(to, o)
					want << 'moved /r/s[${s.id}]/o[${o.id}] /r/s[${s.id}]/o[${o.id}]'
				}
				else {
					if s.kids.len == 0 || g + 1 >= ss.len {
						continue
					}
					// to the next group, which is then left alone
					o := s.kids.pop()
					ss[g + 1].kids.insert(0, o)
					want << 'moved /r/s[${s.id}]/o[${o.id}] /r/s[${ss[g + 1].id}]/o[${o.id}]'
					break
				}
			}
		}
		new := '<r>' + ss.map(it.xml()).join('') + '</r>'
		d := diff_docs(doc_of('a.xml', old), doc_of('b.xml', new), rules) or { panic(err) }
		mut got := shorts(d)
		got.sort()
		want.sort()
		assert got == want, 'round ${round}\n${old}\n${new}'
		for w in want {
			seen[w.all_before(' ')]++
		}
	}
	assert seen.len == 5 && seen.values().all(it > 20), '${seen}'
}
