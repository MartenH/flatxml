module flatxml

import os

// set_of reads documents from text into one set, each named as given, in the order given.
fn set_of(files map[string]string) &DocSet {
	mut s := DocSet.new()
	for name, body in files {
		mut d := parse_bytes(body.bytes(), name) or { panic('${err}\n${body}') }
		s.add(mut d)
	}
	return s
}

fn merged(files map[string]string, rules string) &Merged {
	s := set_of(files)
	rs := parse_rules(rules) or { panic(err) }
	return s.merge(rs) or { panic(err) }
}

fn kinds(m &Merged) []ProblemKind {
	return m.problems.map(it.kind)
}

fn names_of(n MNode) []string {
	mut out := []string{}
	for c in n.children() {
		out << if c.key() != '' { '${c.name()}:${c.key()}' } else { c.name() }
	}
	return out
}

fn (n MNode) kids() []MNode {
	mut out := []MNode{}
	for c in n.children() {
		out << c
	}
	return out
}

fn where(n Node) string {
	line, _ := n.doc.line_col(n.i)
	return '${n.doc.path}:${line}'
}

const pkg_rules = '
r pkg key=n merge
pkg n single merge
pkg x single merge
pkg y single merge
'

fn test_keyed_children_merge_across_documents() {
	mut m := merged({
		'a.xml': '<r><pkg><n>B</n><x>1</x></pkg></r>'
		'b.xml': '<r><pkg><n>B</n><y>2</y></pkg><pkg><n>A</n></pkg></r>'
	}, pkg_rules)
	assert m.problems.len == 0
	root := m.root()
	assert root.name() == 'r' && root.fragment_count() == 2
	// ordered by key, not as written
	assert names_of(root) == ['pkg:A', 'pkg:B']
	b := root.child('pkg', 'B')
	assert b.fragment_count() == 2
	assert b.fragments().map(where(it)) == ['a.xml:1', 'b.xml:1']
	assert names_of(b) == ['n', 'x', 'y']
	assert b.child('n', '').fragment_count() == 2
	assert b.child('x', '').text() == '1' && b.child('y', '').text() == '2'
	assert b.child('pkg', 'B').ok() == false
	assert m.at_path('/B').i == b.i && m.by_keys(['A']).name() == 'pkg'
	assert b.key_path() == ['B'] && b.keyed()
	assert m.at_path('/C').ok() == false
	assert m.len() == 7 // r, A, B, A's n, B's n, x, y
}

fn test_children_follow_the_rules_order_then_as_written() {
	m := merged({
		'a.xml': '<r><z/><pkg><n>a</n></pkg><w/><top/></r>'
		'b.xml': '<r><top/><q/></r>'
	}, '
r top single merge
r pkg key=n merge
')
	assert names_of(m.root()) == ['top', 'pkg:a', 'z', 'w', 'q']
	assert m.root().child('top', '').fragment_count() == 2
}

fn test_ordered_children_keep_their_order() {
	m := merged({
		'a.xml': '<r><s><k>c</k></s><s><k>a</k></s><s><k>b</k></s></r>'
	}, 'r s key=k ordered')
	assert names_of(m.root()) == ['s:c', 's:a', 's:b']
	u := merged({
		'a.xml': '<r><s><k>c</k></s><s><k>a</k></s><s><k>b</k></s></r>'
	}, 'r s key=k')
	assert names_of(u.root()) == ['s:a', 's:b', 's:c']
}

fn test_keys_compared_ignoring_case() {
	files := {
		'a.xml': '<r><s><k>Abc</k></s></r>'
		'b.xml': '<r><s><k>aBC</k></s></r>'
	}
	folded := merged(files, '!fold\nr s key=k merge')
	assert names_of(folded.root()) == ['s:Abc']
	assert folded.at_path('/ABC').fragment_count() == 2
	assert folded.root().child('s', 'abc').ok()
	exact := merged(files, 'r s key=k merge')
	assert names_of(exact.root()) == ['s:Abc', 's:aBC']
	assert exact.at_path('/ABC').ok() == false
}

fn test_keys_of_several_parts_attributes_and_callbacks() {
	files := {
		'a.xml': '<r><e id="1"><v><t>x</t></v></e><e id="1"><v><t>y</t></v></e></r>'
		'b.xml': '<r><e id="1"><v><t>x</t></v></e></r>'
	}
	two := merged(files, 'r e key=@id,v/t merge')
	assert names_of(two.root()) == ['e:1${key_sep}x', 'e:1${key_sep}y']
	assert two.root().child('e', '1${key_sep}x').fragment_count() == 2
	by_attr := merged(files, 'r e key=@id merge')
	assert names_of(by_attr.root()) == ['e:1']
	inner := merged({
		'a.xml': '<r><e><v k="p"/></e><e><v k="q"/></e></r>'
	}, 'r e key=v/@k')
	assert names_of(inner.root()) == ['e:p', 'e:q']
	s := set_of(files)
	m := s.merge(RuleSet{
		rules: [
			Rule{
				parent:   'r'
				children: ['e']
				key_fn:   fn (n Node) ?string {
					t := n.at('v/t').text()
					return if t == '' { none } else { t.to_upper() }
				}
				merge:    true
			},
		]
	}) or { panic(err) }
	assert names_of(m.root()) == ['e:X', 'e:Y']
}

fn test_children_no_rule_names_are_each_their_own() {
	m := merged({
		'a.xml': '<r><x>1</x><x>2</x></r>'
		'b.xml': '<r><x>1</x></r>'
	}, '')
	assert names_of(m.root()) == ['x', 'x', 'x']
	assert m.problems.len == 0
	assert m.root().child('x', '').ok() == false
}

fn test_a_single_child_with_two_values_is_reported() {
	mut m := merged({
		'a.xml': '<r><pkg><n>A</n><x>1</x></pkg></r>'
		'b.xml': '<r>\n<pkg><n>A</n><x>2</x></pkg></r>'
	}, pkg_rules)
	assert kinds(m) == [.value_differs]
	p := m.problems[0]
	assert p.what == 'x' && p.key == ''
	assert p.at.map(where(it)) == ['a.xml:1', 'b.xml:2']
	assert m.describe(p) == 'value_differs: x differs: a.xml:1:17, b.xml:2:14'
	// the view reads the first
	assert m.at_path('/A').child('x', '').text() == '1'
}

fn test_mixed_text_that_differs_is_reported() {
	m := merged({
		'a.xml': '<r><d>one <b/> two</d></r>'
		'b.xml': '<r><d>one <b/> three</d></r>'
		'c.xml': '<r><d>one <b/> two</d></r>'
	}, 'r d single merge\nd b single merge')
	assert kinds(m) == [.value_differs]
	assert m.problems[0].at.map(it.doc.path) == ['a.xml', 'b.xml']
	assert m.root().child('d', '').text() == 'one  two'
}

fn test_mixed_content_that_differs_inside_a_child_is_reported() {
	m := merged({
		'a.xml': '<r><desc>Hello <b>x</b></desc></r>'
		'b.xml': '<r><desc>Hello <b>y</b></desc></r>'
	}, 'r desc single merge')
	assert kinds(m) == [.value_differs]
	// the same text in another place among the children differs too
	p := merged({
		'a.xml': '<r><p>ab<i/></p></r>'
		'b.xml': '<r><p>a<i/>b</p></r>'
	}, 'r p single merge\np i single merge')
	assert kinds(p) == [.value_differs]
}

fn test_single_children_of_many_names() {
	mut a, mut b := '<r>', '<r>'
	for i in 0 .. 300 {
		a += '<c${i % 100}>${i % 100}</c${i % 100}>'
		b += '<c${i}>${i}</c${i}>'
	}
	m := merged({
		'a.xml': a + '</r>'
		'b.xml': b + '</r>'
	}, 'r * single merge')
	// three of each of the first hundred names in a: one child each, as first written
	assert m.root().child_count() == 300
	assert m.root().kids()[..3].map(it.name()) == ['c0', 'c1', 'c2']
	assert m.root().child('c7', '').fragment_count() == 4
	assert m.root().child('c250', '').fragment_count() == 1
	assert m.problems.len == 0
}

fn test_attributes_that_differ_are_reported() {
	m := merged({
		'a.xml': '<r><pkg u="1" v="same"><n>A</n></pkg></r>'
		'b.xml': '<r><pkg u="2" v="same" w="only"><n>A</n></pkg></r>'
	}, pkg_rules)
	assert kinds(m) == [.value_differs]
	assert m.problems[0].what == '@u' && m.problems[0].key == 'A'
	assert m.at_path('/A').attr('w') == 'only'
	ignored := merged({
		'a.xml': '<r><pkg u="1"><n>A</n></pkg></r>'
		'b.xml': '<r><pkg u="2"><n>A</n></pkg></r>'
	}, '!ignore u v\n' + pkg_rules)
	assert ignored.problems.len == 0
}

fn test_a_key_that_does_not_merge_collides() {
	m := merged({
		'a.xml': '<r><s><k>a</k><v>1</v></s></r>'
		'b.xml': '<r><s><k>a</k><v>2</v></s><s><k>b</k></s></r>'
	}, 'r s key=k')
	assert kinds(m) == [.collision]
	assert m.problems[0].key == 'a'
	assert m.problems[0].at.map(where(it)) == ['a.xml:1', 'b.xml:1']
	// the first wins
	assert names_of(m.root()) == ['s:a', 's:b']
	assert m.at_path('/a').fragment_count() == 1
	assert m.at_path('/a').fragment(0).doc.path == 'a.xml'
	single := merged({
		'a.xml': '<r><t/></r>'
		'b.xml': '<r><t/></r>'
	}, 'r t single')
	assert kinds(single) == [.collision]
	assert single.root().child('t', '').fragment_count() == 1
}

fn test_an_ordered_aggregation_in_two_documents() {
	m := merged({
		'a.xml': '<r><s>1</s><s>2</s></r>'
		'b.xml': '<r><s>3</s></r>'
		'c.xml': '<r><s>4</s></r>'
	}, 'r s ordered')
	assert kinds(m) == [.ordered_split]
	assert m.problems[0].at.map(where(it)) == ['a.xml:1', 'b.xml:1', 'c.xml:1']
	assert m.root().kids().map(it.text()) == ['1', '2']
}

fn test_more_children_than_allowed() {
	m := merged({
		'a.xml': '<r><s>1</s><s>2</s></r>'
		'b.xml': '<r><s>3</s></r>'
	}, 'r s max=2')
	assert kinds(m) == [.too_many]
	assert m.problems[0].at.len == 1 && m.problems[0].at[0].text() == '3'
	assert m.root().kids().map(it.text()) == ['1', '2']
	k := merged({
		'a.xml': '<r><s><k>z</k></s><s><k>y</k></s></r>'
		'b.xml': '<r><s><k>x</k></s><s><k>y</k></s></r>'
	}, 'r s key=k merge max=2')
	// the first two written are kept, then ordered by key
	assert kinds(k) == [.too_many]
	assert names_of(k.root()) == ['s:y', 's:z']
	assert k.problems[0].at[0].at('k').text() == 'x'
	// every contribution of a key left out is named
	every := merged({
		'a.xml': '<r><s><k>a</k></s><s><k>b</k></s></r>'
		'b.xml': '<r>\n<s><k>b</k></s></r>'
	}, 'r s key=k merge max=1')
	assert kinds(every) == [.too_many]
	assert every.problems[0].at.map(where(it)) == ['a.xml:1', 'b.xml:2']
	// children without their key count too
	keyless := merged({
		'a.xml': '<r><s><k>a</k></s><s/><s/></r>'
	}, 'r s key=k max=2')
	assert kinds(keyless) == [.missing_key, .missing_key, .too_many]
	assert keyless.problems[2].at.len == 1 && keyless.problems[2].at[0].i == 5
	assert names_of(keyless.root()) == ['s:a', 's']
}

fn test_one_key_under_two_names() {
	m := merged({
		'a.xml': '<r><s><k>a</k></s></r>'
		'b.xml': '<r><t><k>a</k></t></r>'
	}, 'r * key=k merge')
	assert kinds(m) == [.name_differs]
	assert names_of(m.root()) == ['s:a']
	// keys are unique in their scope, through single children: here, two wrappers of r
	w := merged({
		'a.xml': '<r><one><s><k>a</k></s></one><two><s><k>a</k></s></two></r>'
	}, '
r one,two single merge
* s key=k merge
')
	assert kinds(w) == [.key_reused]
	assert w.problems[0].at.map(it.parent().name()) == ['one', 'two']
	assert w.at_path('/a').parent().name() == 'one'
	n := merged({
		'a.xml': '<r><one><s><k>a</k></s></one><two><t><k>a</k></t></two></r>'
	}, '
r one,two single merge
* s,t key=k merge
')
	assert kinds(n) == [.key_reused]
	assert n.problems[0].at.map(it.name()) == ['s', 't']
	// a key used in its scope already leaves out every contribution, merging or not
	mut all := merged({
		'a.xml': '<r><w><i><n>k</n></i></w><v><i><n>k</n></i></v></r>'
		'b.xml': '<r>\n<v><i><n>k</n></i></v></r>'
	}, '
r w,v single merge
w i key=n merge
v i key=n merge
')
	assert kinds(all) == [.key_reused]
	assert all.problems[0].at.map(where(it)) == ['a.xml:1', 'a.xml:1', 'b.xml:2']
	assert all.problems[0].at.map(it.parent().name()) == ['w', 'v', 'v']
	assert all.describe(all.problems[0]).starts_with('key_reused: i `k`: the key is used in its scope already: a.xml:1:7, a.xml:1:29, b.xml:2:4')
	// below a child of its own a scope starts again
	e := merged({
		'a.xml': '<r><it><s><k>a</k></s></it><it><s><k>a</k></s></it></r>'
	}, 'it s key=k')
	assert e.problems.len == 0
	assert e.root().kids().map(it.child('s', 'a').ok()) == [true, true]
	assert e.root().kids().map(it.child('s', 'a').key_path()) == [[]string{}, []string{}]
}

fn test_many_children_are_found_by_name_and_key() {
	mut a, mut b := '<r>', '<r>'
	for i in 0 .. 100 {
		a += '<s><k>k${i}</k><v>${i}</v></s>'
		b += '<s><k>k${i * 2}</k><w>${i}</w></s><t${i}/>'
	}
	m := merged({
		'a.xml': a + '</r>'
		'b.xml': b + '</r>'
	}, '
r s key=k merge
r * single merge
s * single merge
')
	assert m.problems.len == 0
	root := m.root()
	assert root.child_count() == 150 + 100
	for i in 0 .. 200 {
		s := root.child('s', 'k${i}')
		if i >= 100 && i % 2 == 1 {
			assert !s.ok()
			continue
		}
		assert s.ok() && s.key() == 'k${i}'
		assert s.fragment_count() == if i < 100 && i % 2 == 0 { 2 } else { 1 }
		assert s.child('k', '').text() == 'k${i}'
	}
	assert root.child('t99', '').ok() && !root.child('t100', '').ok()
	assert !root.child('s', 'k200').ok() && !root.child('s', '').ok()
}

fn test_a_child_missing_its_key() {
	m := merged({
		'a.xml': '<r><s><k>b</k></s><s/><s><k>a</k></s></r>'
	}, 'r s key=k merge')
	assert kinds(m) == [.missing_key]
	assert names_of(m.root()) == ['s:a', 's:b', 's']
	o := merged({
		'a.xml': '<r><s><k>b</k></s><s/><s><k>a</k></s></r>'
	}, 'r s key=k ordered')
	assert names_of(o.root()) == ['s:b', 's', 's:a']
}

fn test_roots_named_differently() {
	m := merged({
		'a.xml': '<r><x/></r>'
		'b.xml': '<q><y/></q>'
	}, '')
	assert kinds(m) == [.name_differs]
	assert m.describe(m.problems[0]) == 'name_differs: roots named differently (r first): a.xml:1:1, b.xml:1:1'
	assert m.root().fragment_count() == 1
	assert names_of(m.root()) == ['x']
}

fn test_parent_matching() {
	files := {
		'a.xml': '<r><a n="1"><s><k>2</k></s><s><k>1</k></s></a><b n="2"><s><k>2</k></s><s><k>1</k></s></b></r>'
	}
	// the rule for a parent's name comes before the rule for any parent
	m := merged(files, '
r a,b key=@n
a s key=k ordered
* s key=k
')
	assert m.problems.len == 0
	assert names_of(m.at_path('/1')) == ['s:2', 's:1']
	assert names_of(m.at_path('/2')) == ['s:1', 's:2']
	assert m.at_path('/2/1').key_path() == ['2', '1']
}

fn test_rules_are_read_and_checked() {
	rs := parse_rules('
# comment
!fold
!ignore id x:y
r a,b key=n,x/@id merge ordered max=3 # trailing
* * single
') or { panic(err) }
	assert rs.fold && rs.ignore_attrs == ['id', 'x:y']
	assert rs.rules.len == 2
	r := rs.rules[0]
	assert r.parent == 'r' && r.children == ['a', 'b'] && r.key == ['n', 'x/@id']
	assert r.merge && r.ordered && !r.single && r.max == 3
	assert rs.rules[1].single
	// elements named like the settings have rules of their own
	named := parse_rules('fold ignore single\nignore x') or { panic(err) }
	assert !named.fold && named.ignore_attrs.len == 0
	assert named.rules.map(it.parent) == ['fold', 'ignore'] && named.rules[0].single
	for bad in ['r', 'r a nope', 'r a max=0', 'r a max=x', 'r a key=', '!fold x', '!nope'] {
		if _ := parse_rules(bad) {
			assert false, bad
		}
	}
	s := set_of({
		'a.xml': '<r><a/></r>'
	})
	for bad in ['r a\nr a single', 'r a key=n single', 'r a key=@x/y', 'r a key=b/@x/c', 'r *,a',
		'r a key=x@'] {
		rules := parse_rules(bad) or { panic(err) }
		if _ := s.merge(rules) {
			assert false, bad
		}
	}
}

fn test_an_empty_set() {
	s := DocSet.new()
	m := s.merge(RuleSet{}) or { panic(err) }
	assert m.len() == 0 && !m.root().ok() && !m.at_path('/a').ok()
	assert m.root().kids().map(it.name()) == []string{}
}

// --- a document split into files by its keys, merged back, is the document ---------------------

const split_rules = '
model group key=name merge
group name single merge
group note single merge
group tag
group groups single merge
groups group key=name merge
group items single merge
items item key=@id
item label single merge
group seq single merge
seq step ordered
'

struct Rng {
mut:
	s u64
}

fn (mut r Rng) intn(n int) int {
	r.s ^= r.s << 13
	r.s ^= r.s >> 7
	r.s ^= r.s << 17
	return int(r.s % u64(n))
}

struct GItem {
	id    string
	label string
mut:
	file int
}

struct GGroup {
	name  string
	v     int
	note  string
	tags  []string
	steps []string
mut:
	groups    []GGroup
	items     []GItem
	note_in   []int // the files the note is written to
	tag_files []int
	seq_file  int
	self_file int // for a group with nothing below it
}

// unique_keys is n distinct keys with prefix, in byte order.
fn unique_keys(mut r Rng, prefix string, n int) []string {
	mut seen := map[string]bool{}
	for seen.len < n {
		seen['${prefix}${r.intn(1000)}'] = true
	}
	mut out := seen.keys()
	out.sort()
	return out
}

fn gen_group(mut r Rng, name string, depth int, files int) GGroup {
	mut g := GGroup{
		name:      name
		v:         r.intn(3)
		note:      if r.intn(2) == 0 { 'note ${r.intn(9)}' } else { '' }
		tags:      []string{len: r.intn(4), init: 't${index}_${r.intn(9)}'}
		steps:     if r.intn(2) == 0 { []string{len: 1 + r.intn(3), init: 's${index}'} } else { [] }
		seq_file:  r.intn(files)
		self_file: r.intn(files)
	}
	g.note_in = [r.intn(files)]
	if r.intn(4) == 0 {
		g.note_in << r.intn(files)
	}
	mut tf := []int{len: g.tags.len, init: r.intn(files) + index * 0}
	tf.sort()
	g.tag_files = tf
	if depth < 3 {
		for k in unique_keys(mut r, 'g', r.intn(4)) {
			g.groups << gen_group(mut r, k, depth + 1, files)
		}
	}
	for k in unique_keys(mut r, 'i', r.intn(4)) {
		g.items << GItem{k, 'label ${r.intn(9)}', r.intn(files)}
	}
	return g
}

// files_of is every file a part of g is written to.
fn (g &GGroup) files_of() []int {
	mut out := []int{}
	if g.note != '' {
		out << g.note_in
	}
	out << g.tag_files
	if g.steps.len > 0 {
		out << g.seq_file
	}
	for it in g.items {
		out << it.file
	}
	for sub in g.groups {
		out << sub.files_of()
	}
	if out.len == 0 {
		out << g.self_file
	}
	return out
}

// write is g as XML, or only its parts in file f (all of it for f < 0).
fn (g &GGroup) write(f int) string {
	if f >= 0 && f !in g.files_of() {
		return ''
	}
	mut s := '<group v="${g.v}"><name>${g.name}</name>'
	if g.note != '' && (f < 0 || f in g.note_in) {
		s += '<note>${g.note}</note>'
	}
	for k, t in g.tags {
		if f < 0 || g.tag_files[k] == f {
			s += '<tag>${t}</tag>'
		}
	}
	subs := g.groups.map(it.write(f)).join('')
	if subs != '' {
		s += '<groups>${subs}</groups>'
	}
	items := g.items.filter(f < 0 || it.file == f).map('<item id="${it.id}"><label>${it.label}</label></item>').join('')
	if items != '' {
		s += '<items>${items}</items>'
	}
	if g.steps.len > 0 && (f < 0 || g.seq_file == f) {
		s += '<seq>' + g.steps.map('<step>${it}</step>').join('') + '</seq>'
	}
	return s + '</group>'
}

// same_tree compares a merged node with a node of a document: names, texts, attributes and
// children, in order.
fn same_tree(m MNode, n Node) ! {
	if m.name() != n.name() || m.text() != n.text() {
		return error('${m.name()} `${m.text()}` against ${n.name()} `${n.text()}` at ${n.pos()}')
	}
	lo, hi := n.doc.attr_range(n.i)
	for a := lo; a < hi; a++ {
		if m.attr(n.doc.attr_name(a)) != n.doc.attr_value(a) {
			return error('@${n.doc.attr_name(a)} at ${n.pos()}')
		}
	}
	mut want := []Node{}
	for c in n.children() {
		want << c
	}
	got := m.kids()
	if got.len != want.len {
		return error('${got.len} children against ${want.len} at ${n.pos()}: ${names_of(m)}')
	}
	for k, c in got {
		same_tree(c, want[k])!
	}
}

fn test_a_split_document_merges_back() {
	rules := parse_rules(split_rules) or { panic(err) }
	mut r := Rng{0x2545_F491_4F6C_DD1D}
	mut total_files, mut total_nodes := 0, 0
	for round in 0 .. 200 {
		files := 1 + r.intn(6)
		groups := unique_keys(mut r, 'g', 1 + r.intn(4)).map(gen_group(mut r, it, 0, files))
		whole := '<model>' + groups.map(it.write(-1)).join('') + '</model>'
		orig := parse_string(whole) or { panic(err) }
		mut parts := map[string]string{}
		for f in 0 .. files {
			parts['part${f}.xml'] = '<model>' + groups.map(it.write(f)).join('') + '</model>'
		}
		for name, s in {
			'split': set_of(parts)
			'whole': set_of({
				'whole.xml': whole
			})
		} {
			m := s.merge(rules) or { panic(err) }
			assert m.problems.len == 0, '${round} ${name}: ${m.problems}'
			same_tree(m.root(), orig.root_node()) or {
				panic('round ${round}, ${name}: ${err}\n${whole}\n${parts}')
			}
			// every group is found by its key path
			for g in orig.root_node().descendants('group') {
				mut keys := [g.child('name').text()]
				for a := g.parent(); a.ok(); a = a.parent() {
					if a.is('group') {
						keys.prepend(a.child('name').text())
					}
				}
				found := m.by_keys(keys)
				assert found.name() == 'group' && found.child('name', '').text() == keys.last()
				assert found.key_path() == keys
			}
			if name == 'split' {
				total_files += files
				total_nodes += m.len()
			}
		}
	}
	assert total_files > 400 && total_nodes > 5000
}

// --- rules scoped by context, keys of every occurrence, children without a key ----------------

fn test_a_parent_named_by_its_ancestors() {
	files := {
		'a.xml': '<r><h1 n="1"><w><i id="x"/></w></h1><h2 n="2"><w><i id="x"/></w></h2></r>'
		'b.xml': '<r><h1 n="1"><w><i id="x"/></w></h1><h2 n="2"><w><i id="x"/></w></h2></r>'
	}
	// one wrapper name under two holders: keyed and merged under one, each its own under the other
	m := merged(files, '
r h1,h2 key=@n merge
* w single merge
w i key=@id merge
h2/w i
')
	assert m.problems.len == 0
	assert names_of(m.at_path('/1').child('w', '')) == ['i:x']
	assert m.at_path('/1/x').fragment_count() == 2
	assert names_of(m.at_path('/2').child('w', '')) == ['i', 'i']
	// the longest path wins
	deep := merged({
		'a.xml': '<r><a><b><w><i id="x"/><i id="x"/></w></b></a><b><w><i id="x"/><i id="x"/></w></b></r>'
	}, '
r a,b single merge
a b single merge
* w single merge
b/w i key=@id merge
a/b/w i
')
	assert names_of(deep.root().child('a', '').child('b', '').child('w', '')) == ['i', 'i']
	assert names_of(deep.root().child('b', '').child('w', '')) == ['i:x']
}

fn test_a_parent_named_by_its_class() {
	s := set_of({
		'a.xml': '<r><h k="list"><w><i id="x"/><i id="x"/></w></h><h k="set"><w><i id="x"/><i id="x"/></w></h></r>'
	})
	rules := RuleSet{
		rules:    [
			Rule{
				parent:   'r'
				children: ['h']
				key:      ['@k']
				merge:    true
			},
			Rule{
				parent:   '*'
				children: ['w']
				single:   true
				merge:    true
			},
			Rule{
				parent:   'h/w'
				children: ['i']
				key:      ['@id']
				merge:    true
			},
			Rule{
				parent:   '%list'
				children: ['i']
			},
		]
		classify: fn (p Parent) string {
			// what a classifier reads is complete: the name, key, ancestors and source nodes
			assert p.fragments.len > 0 && p.fragments[0].name() == p.name
			assert p.name == 'r' || p.ancestors.last().name == 'r'
			return if p.name == 'w' && p.ancestors[0].key == 'list' { 'list' } else { '' }
		}
	}
	m := s.merge(rules) or { panic(err) }
	// the class wins over the path where the classifier gives one
	assert names_of(m.at_path('/list').child('w', '')) == ['i', 'i']
	assert names_of(m.at_path('/set').child('w', '')) == ['i:x']
	// read from text, the rules take their classifier after
	text := parse_rules('r h key=@k merge\n* w single merge\nh/w i key=@id merge\n%list i') or {
		panic(err)
	}
	t := s.merge(RuleSet{
		...text
		classify: rules.classify
	}) or { panic(err) }
	assert names_of(t.at_path('/list').child('w', '')) == ['i', 'i']
	// a class needs a classifier, and a path is of names
	for bad in ['%c i', 'a/*/b i', 'a//b i', 'a/%c i', '% i'] {
		rs := parse_rules(bad) or { panic(err) }
		if _ := s.merge(rs) {
			assert false, bad
		}
	}
}

fn test_a_key_of_every_occurrence() {
	m := merged({
		'a.xml': '<r><s><ref>a</ref><ref>b</ref></s><s><ref>a</ref><ref>c</ref></s></r>'
		'b.xml': '<r><s><ref>a</ref><ref>b</ref></s><s/></r>'
	}, 'r s key=ref+ merge')
	assert names_of(m.root()) == ['s:a${key_list_sep}b', 's:a${key_list_sep}c', 's']
	assert m.root().child('s', 'a${key_list_sep}b').fragment_count() == 2
	assert kinds(m) == [.missing_key]
	attrs := merged({
		'a.xml': '<r><s><v k="2"/><v/><v k="1"/></s></r>'
	}, 'r s key=v/@k+,@n')
	assert names_of(attrs.root()) == ['s:2${key_list_sep}${key_list_sep}1${key_sep}']
	// an occurrence without the attribute keeps its place
	places := merged({
		'a.xml': '<r><s><v k="1"/><v/></s></r>'
		'b.xml': '<r><s><v/><v k="1"/></s></r>'
	}, 'r s key=v/@k+ merge')
	assert places.root().child_count() == 2
	assert show_key(attrs.root().kids()[0].key()) == '2||1,'
	// `+` reads the elements at a path
	for bad in ['r s key=+', 'r s key=@id+'] {
		rs := parse_rules(bad) or { panic(err) }
		if _ := places.set.merge(rs) {
			assert false, bad
		}
	}
}

fn test_children_without_a_key_as_one_empty_key() {
	files := {
		'a.xml': '<r><s><v>1</v></s><s id="a"/><t/></r>'
		'b.xml': '<r><s><w>2</w></s><t/></r>'
	}
	m := merged(files, 'r s,t key=@id keyless=empty merge\n* v,w single merge')
	// one child of each name without a key, merged, and nothing reported
	assert m.problems.len == 0
	assert names_of(m.root()) == ['s:a', 's', 't']
	empty := m.root().child('s', '')
	assert empty.fragment_count() == 2 && names_of(empty) == ['v', 'w']
	assert m.root().child('t', '').fragment_count() == 2
	// a key with no text is the empty key, as an absent one is
	lit := merged({
		'a.xml': '<r><s id=""/><s/></r>'
	}, 'r s key=@id keyless=empty merge')
	assert lit.problems.len == 0 && names_of(lit.root()) == ['s']
	assert lit.root().child('s', '').fragment_count() == 2
	// keyless is for keyed rules
	for bad in ['r s keyless=empty', 'r s single keyless=empty'] {
		rs := parse_rules(bad) or { panic(err) }
		if _ := set_of({
			'a.xml': '<r><s/></r>'
		}).merge(rs) {
			assert false, bad
		}
	}
	// without merge, the second is a collision; by default, each is its own and reported
	assert kinds(merged(files, 'r s,t key=@id keyless=empty')) == [.collision, .collision]
	assert kinds(merged(files, 'r s,t key=@id merge')).filter(it == .missing_key).len == 4
	rs := parse_rules('r s key=@id keyless=empty') or { panic(err) }
	assert rs.rules[0].keyless == .empty
	if _ := parse_rules('r s key=@id keyless=one') {
		assert false
	}
}

fn test_one_rule_over_several_names_counts_them_together() {
	// order: every child of the aggregation, whatever its name, from one document
	o := merged({
		'a.xml': '<r><a>1</a></r>'
		'b.xml': '<r><b>2</b></r>'
	}, 'r a,b ordered')
	assert kinds(o) == [.ordered_split]
	assert o.root().kids().map(it.name()) == ['a']
	// the most there may be, of every name together, each and keyed alike
	e := merged({
		'a.xml': '<r><a/><b/><a/></r>'
	}, 'r a,b max=2')
	assert kinds(e) == [.too_many]
	assert e.root().kids().map(it.name()) == ['a', 'b']
	k := merged({
		'a.xml': '<r><a id="1"/><b id="2"/><a id="3"/></r>'
	}, 'r a,b key=@id max=2')
	assert kinds(k) == [.too_many]
	assert names_of(k.root()) == ['a:1', 'b:2']
}

fn test_a_key_part_can_be_the_own_text() {
	rs := parse_rules('r item key=.,@k merge') or { panic(err) }
	assert rs.rules[0].key == ['.', '@k']
	s := set_of({
		'a.xml': '<r><item k="1">x<sub>q</sub></item><item k="1">y</item></r>'
		'b.xml': '<r>\n  <item k="1">\n    x\n    <more>z</more>\n  </item>\n</r>'
	})
	m := s.merge(rs) or { panic(err) }
	// the own text, not the children's, and not the indentation beside them
	assert m.root().kids().map(show_key(it.key())) == ['x,1', 'y,1']
	assert m.root().kids()[0].kids().map(it.name()) == ['sub', 'more']
	// '' in a Rule is the same part
	m2 := s.merge(RuleSet{
		rules: [Rule{
			parent:   'r'
			children: ['item']
			key:      ['', '@k']
			merge:    true
		}]
	}) or { panic(err) }
	assert m2.root().kids().map(show_key(it.key())) == ['x,1', 'y,1']
}

fn test_no_own_text_is_an_absent_key_part() {
	s := set_of({
		'a.xml': '<r><item/><item></item><item>t</item></r>'
	})
	// keyless children are their own, and reported
	own := s.merge(parse_rules('r item key=.')!)!
	assert own.root().kids().len == 3
	assert own.problems.filter(it.kind == .missing_key).len == 2
	// or the one child with the empty key
	empty := s.merge(parse_rules('r item key=. keyless=empty merge')!)!
	assert empty.root().kids().map(show_key(it.key())) == ['t', '']
	assert empty.problems.len == 0
}

fn test_the_own_text_is_read_once() {
	s := set_of({
		'a.xml': '<r><item/></r>'
	})
	for rules in [parse_rules('r item key=.+')!, RuleSet{
		rules: [Rule{
			parent:   'r'
			children: ['item']
			key:      ['+']
		}]
	}] {
		if _ := s.merge(rules) {
			assert false
		} else {
			assert err.msg().contains('one text') || err.msg().contains('names none'), err.msg()
		}
	}
}

fn random_rule_set(mut seed &u64) RuleSet {
	next := fn [mut seed] (k int) int {
		unsafe {
			*seed ^= *seed << 13
			*seed ^= *seed >> 7
			*seed ^= *seed << 17
			return int(*seed % u64(k))
		}
	}
	pick := fn [next] (xs []string) string {
		return xs[next(xs.len)]
	}
	mut rules := []Rule{}
	for _ in 0 .. next(5) {
		mut children := []string{}
		if next(3) == 0 {
			children = ['*']
		} else {
			for _ in 0 .. 1 + next(3) {
				children << pick(['a', 'b', 'p:c', 'item', 'x-y', 'ü'])
			}
		}
		mut key := []string{}
		if next(2) == 0 {
			for _ in 0 .. 1 + next(3) {
				key << pick(['.', 'NAME', 'ITEM/ID', '@id', 'ITEM/@id', 'REFS/REF+', 'a/b/c'])
			}
		}
		rules << Rule{
			parent:   pick(['*', 'a', 'a/b', '%c', 'x/y/z', 'fold'])
			children: children
			key:      key
			keyless:  if key.len > 0 && next(2) == 0 { Keyless.empty } else { Keyless.own }
			single:   key.len == 0 && next(2) == 0
			merge:    next(2) == 0
			ordered:  next(2) == 0
			max:      next(4)
		}
	}
	mut ignore := []string{}
	for _ in 0 .. next(3) {
		ignore << pick(['id', 'x:y', 'uuid'])
	}
	return RuleSet{
		rules:        rules
		fold:         next(2) == 0
		ignore_attrs: ignore
	}
}

fn test_rule_sets_are_written_and_read_back() {
	mut seed := u64(0x9E3779B97F4A7C15)
	for _ in 0 .. 2000 {
		rs := random_rule_set(mut &seed)
		text := format_rules(rs) or { panic(err) }
		back := parse_rules(text) or { panic('${err}\n${text}') }
		assert back.fold == rs.fold && back.ignore_attrs == rs.ignore_attrs, text
		assert back.rules.len == rs.rules.len, text
		for k, r in rs.rules {
			b := back.rules[k]
			assert b.parent == r.parent && b.children == r.children && b.key == r.key, text
			assert b.keyless == r.keyless && b.single == r.single && b.merge == r.merge, text
			assert b.ordered == r.ordered && b.max == r.max && b.key_fn == none, text
		}
		// and written again, the same text
		assert format_rules(back) or { '' } == text
	}
	// what text cannot say
	f := fn (n Node) ?string {
		return none
	}
	for bad in [
		RuleSet{ rules: [Rule{ parent: 'r', children: ['a'], key_fn: f }] },
		RuleSet{ rules: [Rule{ parent: 'r s', children: ['a'] }] },
		RuleSet{ rules: [Rule{ parent: '!r', children: ['a'] }] },
		RuleSet{ rules: [Rule{ parent: 'r', children: ['a,b'] }] },
		RuleSet{ rules: [Rule{ parent: 'r', children: ['a', ''] }] },
		RuleSet{ rules: [Rule{ parent: 'r', children: ['a'], key: ['.+'] }] },
		RuleSet{ rules: [Rule{ parent: 'r', children: ['a'], key: ['+'] }] },
		RuleSet{ rules: [Rule{ parent: 'r\vs', children: ['a'] }] },
		RuleSet{ rules: [Rule{ parent: 'r', children: ['a\f'] }] },
		RuleSet{ ignore_attrs: ['x\ry'] },
		RuleSet{ rules: [Rule{ parent: 'r', children: ['a'], key: ['x#y'] }] },
		RuleSet{ rules: [Rule{ parent: 'r', children: ['a'], max: -1 }] },
		RuleSet{ ignore_attrs: [''] },
	] {
		if t := format_rules(bad) {
			assert false, t
		}
	}
	// spellings that compile alike are written as one: any parent or child `*`, the own text `.`
	assert format_rules(RuleSet{
		rules: [Rule{}, Rule{
			parent:   ''
			children: ['']
			key:      ['']
		}]
	})! == '* *\n* * key=.\n'
}

// --- a merged view written as one document --------------------------------------------------

fn test_a_set_of_one_document_writes_the_document() {
	for f in os.walk_ext(os.join_path(@VMODROOT, 'testdata'), '.xml') {
		src := os.read_file(f) or { panic(err) }
		mut s := DocSet.new()
		if s.load([f]).len > 0 {
			continue
		}
		m := s.merge(RuleSet{}) or { panic(err) }
		assert m.xml()! == src, f
	}
}

fn test_a_merged_view_written_as_one_document() {
	s := set_of({
		'a.xml': '<?xml version="1.0"?>\n<!-- head -->\n<r v="1">\n  <!-- items -->\n  <item id="1">one</item>\n  <group n="g">\n    <x/>\n  </group>\n</r>\n<!-- tail -->\n'
		'b.xml': '<r w="2">\n  <item id="2">two</item>\n  <group n="g" k="3">\n    <!-- y -->\n    <y/>\n  </group>\n</r>\n'
	})
	m := s.merge(parse_rules('r item key=@id merge\nr group key=@n merge')!)!
	assert m.xml()! == '<?xml version="1.0"?>\n<!-- head -->\n<r v="1" w="2">\n  <!-- items -->\n  <item id="1">one</item>\n  <item id="2">two</item>\n  <group n="g" k="3">\n    <x/>\n    <!-- y -->\n    <y/>\n  </group>\n</r>\n<!-- tail -->\n'
	// a self-closed element that gets children
	t := set_of({
		'a.xml': '<r><g n="1"/></r>'
		'b.xml': '<r><g n="1"><c/></g></r>'
	})
	assert t.merge(parse_rules('r g key=@n merge')!)!.xml()! == '<r><g n="1"><c/></g></r>'
	// text kept, whitespace beside it not joined to it
	u := set_of({
		'a.xml': '<r><p k="1">text</p></r>'
		'b.xml': '<r>\n  <p k="1">\n    <c/>\n  </p>\n</r>'
	})
	assert u.merge(parse_rules('r p key=@k merge')!)!.xml()! == '<r><p k="1">text<c/></p></r>'
}

fn test_a_merged_view_keeps_its_namespaces() {
	s := set_of({
		'a.xml': '<r xmlns="urn:a" xmlns:p="urn:p"><p:i id="1"/></r>'
		'b.xml': '<r xmlns="urn:b" xmlns:p="urn:q"><p:i id="2"><c/></p:i></r>'
	})
	m := s.merge(parse_rules('r p:i key=@id merge')!)!
	out := m.xml()!
	assert out == '<r xmlns="urn:a" xmlns:p="urn:p"><p:i id="1"/><p:i xmlns="urn:b" xmlns:p="urn:q" id="2"><c/></p:i></r>'
	mut d := parse_string(out)!
	d.resolve_namespaces()!
	for n in d.node(d.root()).descendants('c') {
		assert d.ns_uri(d.ns_of(n.i)) == 'urn:b'
	}
}

fn test_a_merged_view_written_with_root_attributes() {
	// one contribution: its start tag edited, the rest as written
	one := set_of({
		'a.xml': '<!-- c -->\n<r xmlns="urn:a" v=\'1\' w="2">\n  <i/>\n</r>\n'
	}).merge(RuleSet{})!
	assert one.xml(
		root_attrs: [EAttr{'v', '3'}, EAttr{'xmlns:x', 'urn:x'}, EAttr{'x:k', 'a&b'}]
	)! == '<!-- c -->\n<r xmlns="urn:a" v=\'3\' w="2" xmlns:x="urn:x" x:k="a&amp;b">\n  <i/>\n</r>\n'
	assert one.xml()! == '<!-- c -->\n<r xmlns="urn:a" v=\'1\' w="2">\n  <i/>\n</r>\n'
	// a self-closed root
	assert set_of({
		'a.xml': '<r/>'
	}).merge(RuleSet{})!.xml(root_attrs: [EAttr{'v', '1'}])! == '<r v="1"/>'
	// several: given over the attributes the others bring, a declaration taken as in scope
	s := set_of({
		'a.xml': '<r v="1"><i id="1"/></r>'
		'b.xml': '<r xmlns:p="urn:p" w="2" p:t="3"><i id="2" p:t="4"/></r>'
	})
	m := s.merge(parse_rules('r i key=@id merge')!)!
	assert m.xml(root_attrs: [EAttr{'w', '5'}, EAttr{'xmlns:p', 'urn:p'}])! == '<r v="1" p:t="3" w="5" xmlns:p="urn:p"><i id="1"/><i id="2" p:t="4"/></r>'
	// a declaration that would change what the document's prefixes mean is refused
	t := set_of({
		'a.xml': '<r xmlns:p="urn:p"><p:i/></r>'
	}).merge(RuleSet{})!
	path := os.join_path(os.temp_dir(), 'flatxml_root_attrs_${os.getpid()}.xml')
	defer {
		os.rm(path) or {}
	}
	t.write_file(path, root_attrs: [EAttr{'xmlns:p', 'urn:q'}]) or {
		assert err.msg().contains('rebinds')
		assert !os.exists(path)
		return
	}
	assert false
}

// root_refused is why writing the view of files with the root attributes given is refused; ''
// when it is not.
fn root_refused(files map[string]string, attrs []EAttr) string {
	m := set_of(files).merge(RuleSet{}) or { panic(err) }
	m.xml(root_attrs: attrs) or { return err.msg() }
	return ''
}

fn test_root_attributes_that_would_change_the_document_are_refused() {
	one := {
		'a.xml': '<r xmlns:p="urn:p" p:t="1"><i/></r>'
	}
	// not attribute names, or one given twice
	for name in ['', 'a b', ':a', 'a:', 'a:b:c', 'a"'] {
		assert root_refused(one, [EAttr{name, '1'}]).contains('not an attribute name'), name
	}
	assert root_refused(one, [EAttr{'v', '1'}, EAttr{'v', '2'}]).contains('given twice')
	assert root_refused(one, [EAttr{'xmlns:q', 'urn:p'}, EAttr{'p:u', '1'}, EAttr{'q:u', '2'}]).contains('given twice')
	// a default namespace where none is declared moves every unprefixed name
	assert root_refused(one, [EAttr{'xmlns', 'urn:x'}]).contains('rebinds')
	assert root_refused(one, [EAttr{'xmlns', ''}]) == ''
	assert root_refused(one, [EAttr{'xmlns:p', 'urn:other'}]).contains('rebinds')
	assert root_refused(one, [EAttr{'xmlns:p', 'urn:p'}]) == ''
	assert root_refused(one, [EAttr{'xmlns:q', ''}]).contains('no namespace')
	// the reserved prefixes
	for a in [EAttr{'xmlns:xml', 'urn:x'}, EAttr{'xmlns:xmlns', xmlns_ns_uri},
		EAttr{'xmlns:q', xml_ns_uri}, EAttr{'xmlns:q', xmlns_ns_uri}] {
		assert root_refused(one, [a]).contains('reserved'), a.name
	}
	assert root_refused(one, [EAttr{'xmlns:xml', xml_ns_uri}, EAttr{'xml:lang', 'en'}]) == ''
	// a prefix that is not bound, unless declared with it
	assert root_refused(one, [EAttr{'u:t', '1'}]).contains('`u` is not bound')
	assert root_refused(one, [EAttr{'u:t', '1'}, EAttr{'xmlns:u', 'urn:u'}]) == ''
	// an empty view
	empty := DocSet.new().merge(RuleSet{})!
	empty.xml() or {
		assert err.msg().contains('empty')
		return
	}
	assert false
}

fn test_a_root_attribute_replaces_the_one_of_its_expanded_name() {
	// the root's own, under another prefix
	one := set_of({
		'a.xml': '<r xmlns:p="urn:p" xmlns:q="urn:p" p:t="1"/>'
	}).merge(RuleSet{})!
	assert one.xml(root_attrs: [EAttr{'q:t', '2'}])! == '<r xmlns:p="urn:p" xmlns:q="urn:p" p:t="2"/>'
	// another contribution's
	two := set_of({
		'a.xml': '<r xmlns:p="urn:p"/>'
		'b.xml': '<r xmlns:q="urn:p" q:t="3" w="4"/>'
	}).merge(RuleSet{})!
	assert two.xml(root_attrs: [EAttr{'p:t', '5'}])! == '<r xmlns:p="urn:p" w="4" p:t="5"/>'
}

fn test_a_root_with_attributes_is_written_alike_whoever_contributed() {
	attrs := [EAttr{'xmlns:n', 'urn:n'}, EAttr{'n:v', '1'}]
	alone := set_of({
		'a.xml': '<r xmlns:p="urn:p">\n  <p:i k="1"><c/></p:i>\n</r>'
	}).merge(parse_rules('r p:i key=@k merge')!)!
	merged := set_of({
		'a.xml': '<r xmlns:p="urn:p">\n  <p:i k="1"><c/></p:i>\n</r>'
		'b.xml': '<r xmlns:p="urn:p" w="2"/>'
	}).merge(parse_rules('r p:i key=@k merge')!)!
	assert alone.xml(root_attrs: attrs)! == '<r xmlns:p="urn:p" xmlns:n="urn:n" n:v="1">\n  <p:i k="1"><c/></p:i>\n</r>'
	assert merged.xml(root_attrs: attrs)! == '<r xmlns:p="urn:p" w="2" xmlns:n="urn:n" n:v="1">\n  <p:i k="1"><c/></p:i>\n</r>'
}

fn test_a_split_document_merged_and_written_is_the_document() {
	rules := parse_rules(split_rules) or { panic(err) }
	mut r := Rng{0x9E37_79B9_7F4A_7C15}
	for round in 0 .. 200 {
		files := 1 + r.intn(6)
		groups := unique_keys(mut r, 'g', 1 + r.intn(4)).map(gen_group(mut r, it, 0, files))
		whole := '<model>' + groups.map(it.write(-1)).join('') + '</model>'
		orig := parse_string(whole) or { panic(err) }
		mut parts := map[string]string{}
		for f in 0 .. files {
			parts['part${f}.xml'] = '<model>' + groups.map(it.write(f)).join('') + '</model>'
		}
		m := set_of(parts).merge(rules) or { panic(err) }
		out := m.xml()!
		// read back, the document
		written := parse_string(out) or { panic('${err}\n${out}') }
		assert written.subtree_bytes(written.root()) == orig.subtree_bytes(orig.root()), 'round ${round}'
		// merged alone, the merged view
		again := set_of({
			'out.xml': out
		}).merge(rules) or { panic(err) }
		same_tree(again.root(), orig.root_node()) or { panic('round ${round}: ${err}') }
		same_tree(m.root(), written.root_node()) or { panic('round ${round}: ${err}') }
	}
}

fn test_a_merged_view_written_review_cases() {
	// a declaration from another contribution is not copied: the prefix is bound once
	a := set_of({
		'a.xml': '<r xmlns:p="urn:a"><g k="1" p:x="1"/></r>'
		'b.xml': '<r xmlns:p="urn:b"><g k="1" xmlns:p="urn:c" p:y="2"/></r>'
	})
	out := a.merge(parse_rules('r g key=@k merge')!)!.xml()!
	mut d := parse_string(out)!
	d.resolve_namespaces()!
	g := d.node(d.root()).first()
	mut got := map[string]string{}
	lo, hi := d.attr_range(g.i)
	for x := lo; x < hi; x++ {
		if !d.is_ns_decl(x) {
			got['{${d.ns_uri(d.attr_ns_of(x))}}${d.attr_local_name(x)}'] = d.attr_value(x)
		}
	}
	assert got == {
		'{}k':      '1'
		'{urn:a}x': '1'
		'{urn:c}y': '2'
	}, out
	// text stays beside the element it followed, whatever the order of the view
	b := set_of({
		'a.xml': '<r><p>x<a k="2"/>y<a k="1"/>z</p></r>'
	})
	assert b.merge(parse_rules('p a key=@k')!)!.xml()! == '<r><p>x<a k="1"/>z<a k="2"/>y</p></r>'
	// and so do the comments between an element and its text
	c := set_of({
		'a.xml': '<r><p><a/><!--c1-->text<b/></p></r>'
	})
	assert c.merge(parse_rules('r p single')!)!.xml()! == '<r><p><a/><!--c1-->text<b/></p></r>'
	// the `xml` prefix is bound everywhere: never declared again
	x := set_of({
		'a.xml': '<r><g k="1"/></r>'
		'b.xml': '<r xmlns:xml="http://www.w3.org/XML/1998/namespace"><g k="2" xml:lang="en"/></r>'
	})
	assert x.merge(parse_rules('r g key=@k merge')!)!.xml()! == '<r><g k="1"/><g k="2" xml:lang="en"/></r>'
	// a self-closed first contribution takes its end tag's indentation from another
	e := set_of({
		'a.xml': '<r>\n  <g k="1"/>\n</r>'
		'b.xml': '<r>\n  <g k="1">\n    <c/>\n  </g>\n</r>'
	})
	assert e.merge(parse_rules('r g key=@k merge')!)!.xml()! == '<r>\n  <g k="1">\n    <c/>\n  </g>\n</r>'
}

fn test_a_node_names_the_rule_that_put_it_together() {
	m := merged({
		'a.xml': '<r><pkg><n>A</n><x>1</x><z/></pkg></r>'
	}, pkg_rules)
	root := m.root()
	assert root.rule() == none && root.rule_number() == none
	pkg := root.kids()[0]
	assert pkg.rule_number()? == 0 && pkg.rule()?.key == ['n']
	kids := pkg.kids()
	assert kids.map(it.rule_number() or { -1 }) == [1, 2, -1]
	assert kids[0].rule()?.children == ['n'] && kids[2].rule() == none
	// an empty handle
	assert MNode{}.rule() == none && MNode{}.rule_number() == none
}

fn test_the_rule_by_path_class_and_any_parent() {
	// a/b: the path-scoped rule for b under a, the plain one elsewhere; `*` for any parent
	rules := '
r a,c single merge
a b single merge
c b single merge
a/b i key=@k merge
b i
* t single merge
'
	m := merged({
		'a.xml': '<r><a><b><i k="1"/><t/></b></a><c><b><i k="1"/><t/></b></c></r>'
	}, rules)
	a := m.root().child('a', '')
	c := m.root().child('c', '')
	ai := a.kids()[0].kids()
	ci := c.kids()[0].kids()
	assert ai[0].rule_number()? == 3 && ai[0].keyed()
	assert ci[0].rule_number()? == 4 && !ci[0].keyed()
	assert ai[1].rule_number()? == 5 && ci[1].rule_number()? == 5
	// a class: the classifier names b under c `%under_c`
	s := set_of({
		'a.xml': '<r><a><b><i/></b></a><c><b><i/></b></c></r>'
	})
	mut rs := parse_rules('
r a,c single merge
a b single merge
c b single merge
%under_c i single merge
b i
') or {
		panic(err)
	}
	classified := s.merge(RuleSet{
		...rs
		classify: fn (p Parent) string {
			return if p.name == 'b' && p.ancestors.len > 0 && p.ancestors[0].name == 'c' {
				'under_c'
			} else {
				''
			}
		}
	}) or { panic(err) }
	ca := classified.root().child('a', '').kids()[0].kids()[0]
	cc := classified.root().child('c', '').kids()[0].kids()[0]
	assert ca.rule_number()? == 4 && cc.rule_number()? == 3
}

fn test_a_child_missing_its_key_has_the_keyed_rule() {
	m := merged({
		'a.xml': '<r><pkg><n>A</n></pkg><pkg/></r>'
	}, pkg_rules)
	kids := m.root().kids()
	assert kids.all(it.rule_number()? == 0)
	assert kids[0].keyed() && !kids[1].keyed()
}
