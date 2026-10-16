module flatxml

// own_of is element i's own text, its runs joined.
fn (d &Doc) own_of(i u32) string {
	return d.node(i).text_runs().map(it.text).join('')
}

fn doc_of(s string) &Doc {
	return parse_string(s) or { panic('${err}\n${s}') }
}

// edited applies f to an edit set over s and gives the document it writes, checking that the
// written document reads back as the edit set says it does.
fn edited(s string, f fn (mut e Edit) !) string {
	d := doc_of(s)
	mut e := d.edit()
	f(mut e) or { panic(err) }
	out := e.xml()
	again := parse_string(out) or { panic('${err}\n${out}') }
	assert shape(again.node(again.root())) == eshape(e.root()), out
	return out
}

// shape and eshape write a tree as one line: names, attributes, own text, children. Namespace
// declarations are left out: a copied or moved element gets them where it is written.
fn shape(n Node) string {
	mut s := '<${n.name()}'
	lo, hi := n.doc.attr_range(n.i)
	for a := lo; a < hi; a++ {
		if !is_ns_decl_name(n.doc.attr_name(a)) {
			s += ' ${n.doc.attr_name(a)}=${n.doc.attr_value(a)}'
		}
	}
	s += '>' + n.doc.own_of(n.i)
	for c in n.children() {
		s += shape(c)
	}
	return s + '</>'
}

fn eshape(n ENode) string {
	mut s := '<${n.name()}'
	for a in n.attrs() {
		if !is_ns_decl_name(a.name) {
			s += ' ${a.name}=${a.value}'
		}
	}
	s += '>' + n.text()
	for c in n.children() {
		s += eshape(c)
	}
	return s + '</>'
}

const pretty = '<?xml version="1.0"?>
<!-- head -->
<r a="1" b=\'2\'>
  <x>one</x>
  <!-- about y -->
  <y k="v"/>
  <z>
    <w>deep</w>
  </z>
</r>
'

fn test_unedited_is_the_file() {
	assert edited(pretty, fn (mut e Edit) ! {}) == pretty
}

fn test_set_text() {
	assert edited(pretty, fn (mut e Edit) ! {
		e.set_text(e.root().child('x'), 'a < b & c')!
	}) == pretty.replace('<x>one</x>', '<x>a &lt; b &amp; c</x>')
	// an empty element gets text, an element with children gets it first
	assert edited('<r><a/><b></b><c><d/></c></r>', fn (mut e Edit) ! {
		r := e.root()
		e.set_text(r.child('a'), 'A')!
		e.set_text(r.child('b'), 'B')!
		e.set_text(r.child('c'), 'C')!
	}) == '<r><a>A</a><b>B</b><c>C<d/></c></r>'
	// in mixed content the first run is replaced and the others go; CDATA stays CDATA
	assert edited('<p>one <b>x</b> two<!-- c --> three</p>', fn (mut e Edit) ! {
		e.set_text(e.root(), 'new')!
	}) == '<p>new<b>x</b><!-- c --></p>'
	assert edited('<r><c><![CDATA[<old>]]></c></r>', fn (mut e Edit) ! {
		e.set_text(e.root().child('c'), 'a]]>b')!
	}) == '<r><c><![CDATA[a]]]]><![CDATA[>b]]></c></r>'
	// emptied, and whitespace that has to stay text
	assert edited('<r><a>x</a><b>y</b></r>', fn (mut e Edit) ! {
		e.set_text(e.root().child('a'), '')!
		e.set_text(e.root().child('b'), ' \n')!
	}) == '<r><a></a><b>&#32;&#10;</b></r>'
	// comments around the text are kept
	assert edited('<r><!-- a -->old<!-- b --></r>', fn (mut e Edit) ! {
		e.set_text(e.root(), 'new')!
	}) == '<r><!-- a -->new<!-- b --></r>'
}

fn test_attributes() {
	assert edited(pretty, fn (mut e Edit) ! {
		r := e.root()
		e.set_attr(r, 'a', 'say "hi"')!
		e.set_attr(r, 'b', 'x')!
		e.set_attr(r, 'c', 'new & <')!
		e.remove_attr(r.child('y'), 'k')!
	}) == pretty.replace('<r a="1" b=\'2\'>', '<r a=\'say "hi"\' b=\'x\' c="new &amp; &lt;">').replace('<y k="v"/>',
		'<y/>')
	// removal takes the whitespace before it; a removed name set again is new
	assert edited('<r  a = "1"  b="2"   c="3" />', fn (mut e Edit) ! {
		r := e.root()
		e.remove_attr(r, 'b')!
		e.remove_attr(r, 'a')!
		e.set_attr(r, 'd', '4')!
		e.remove_attr(r, 'nope')!
	}) == '<r   c="3" d="4" />'
	assert edited('<r a="1"/>', fn (mut e Edit) ! {
		e.remove_attr(e.root(), 'a')!
		e.set_attr(e.root(), 'a', '2')!
	}) == '<r a="2"/>'
	// values that need references
	assert edited('<r/>', fn (mut e Edit) ! {
		e.set_attr(e.root(), 'v', 't\tn\n')!
	}) == '<r v="t&#9;n&#10;"/>'
}

fn test_insert() {
	assert edited(pretty, fn (mut e Edit) ! {
		r := e.root()
		e.insert(r, 0, '<first/>')!
		e.insert(r, 4, '<last a="1">t</last>')!
		e.insert(r, 2, '<mid/>')!
	}) == pretty.replace('<r a="1" b=\'2\'>\n', '<r a="1" b=\'2\'>\n  <first/>\n').replace('  <!-- about y -->\n',
		'  <!-- about y -->\n  <mid/>\n').replace('  </z>\n</r>', '  </z>\n  <last a="1">t</last>\n</r>')
	// into an empty element, a text-only one, and before an inserted one
	assert edited('<r><a/><b>t</b></r>', fn (mut e Edit) ! {
		r := e.root()
		e.insert(r.child('a'), 0, '<x/>')!
		e.insert(r.child('b'), 0, '<y/>')!
		n := e.insert(r, 1, '<n/>')!
		e.insert(r, 1, '<m/>')!
		e.set_attr(n, 'k', 'v')!
		e.insert(n, 0, '<inside/>')!
	}) == '<r><a><x/></a><m/><n k="v"><inside/></n><b>t<y/></b></r>'
	// out of range, and into what is not in the document
	d := doc_of('<r><a/></r>')
	mut e := d.edit()
	e.insert(e.root(), 2, '<x/>') or { assert err.msg().contains('out of range') }
	a := e.root().child('a')
	e.remove(a)!
	e.insert(a, 0, '<x/>') or { assert err.msg().contains('not in the document') }
	e.insert(e.root(), 0, 'not xml') or { assert err.msg() != '' }
	assert e.xml() == '<r></r>'
}

fn test_remove() {
	assert edited(pretty, fn (mut e Edit) ! {
		r := e.root()
		e.remove(r.child('x'))!
		e.remove(r.child('z').child('w'))!
	}) == pretty.replace('  <x>one</x>\n', '').replace('\n    <w>deep</w>', '')
	// the comment before a removed element stays
	assert edited(pretty, fn (mut e Edit) ! {
		e.remove(e.root().child('y'))!
	}) == pretty.replace('\n  <y k="v"/>', '')
	assert edited('<r><a/>t<b/></r>', fn (mut e Edit) ! {
		e.remove(e.root().child('a'))!
		e.remove(e.root().child('b'))!
	}) == '<r>t</r>'
	d := doc_of('<r/>')
	mut e := d.edit()
	e.remove(e.root()) or { assert err.msg().contains('root') }
}

fn test_move() {
	assert edited(pretty, fn (mut e Edit) ! {
		r := e.root()
		e.move(r.child('z').child('w'), r, 0)!
		e.move(r.child('x'), r.child('z'), 0)!
	}) == pretty.replace('  <x>one</x>\n', '  <w>deep</w>\n').replace('<z>\n    <w>deep</w>',
		'<z>\n    <x>one</x>')
	// a moved element keeps its edits, and moves again
	assert edited('<r><a><b/></a><c/></r>', fn (mut e Edit) ! {
		r := e.root()
		b := r.child('a').child('b')
		e.set_attr(b, 'k', '1')!
		e.move(b, r, 2)!
		e.move(b, r.child('c'), 0)!
		e.move(r.child('a'), r.child('c'), 1)!
	}) == '<r><c><b k="1"/><a></a></c></r>'
	// not into itself
	d := doc_of('<r><a><b/></a></r>')
	mut e := d.edit()
	a := e.root().child('a')
	e.move(a, a.child('b'), 0) or { assert err.msg().contains('inside itself') }
	e.move(a, a, 0) or { assert err.msg().contains('inside itself') }
	assert e.xml() == '<r><a><b/></a></r>'
	// removed, then put back
	e.remove(a)!
	e.place(a, e.root(), 0)!
	e.place(a, e.root(), 0) or { assert err.msg().contains('remove it first') }
	assert e.xml() == '<r><a><b/></a></r>'
}

fn test_insert_copy() {
	src := doc_of('<s xmlns="urn:s" xmlns:p="urn:p"><p:item k="1"><sub>t</sub></p:item></s>')
	item := src.node(src.root()).first()
	// into a document with other bindings: what it had is declared on it
	assert edited('<r xmlns="urn:r" xmlns:p="urn:other"><a/></r>', fn [item] (mut e Edit) ! {
		e.insert_copy(e.root(), 1, item)!
	}) == '<r xmlns="urn:r" xmlns:p="urn:other"><a/><p:item xmlns="urn:s" xmlns:p="urn:p" k="1"><sub>t</sub></p:item></r>'
	// into one with the same bindings: nothing is added
	assert edited('<r xmlns="urn:s" xmlns:p="urn:p"/>', fn [item] (mut e Edit) ! {
		e.insert_copy(e.root(), 0, item)!
	}) == '<r xmlns="urn:s" xmlns:p="urn:p"><p:item k="1"><sub>t</sub></p:item></r>'
	// edits inside a copy
	assert edited('<r xmlns="urn:s" xmlns:p="urn:p"/>', fn [item] (mut e Edit) ! {
		c := e.insert_copy(e.root(), 0, item)!
		e.set_text(c.children()[0], 'changed')!
		e.set_attr(c, 'k', '2')!
	}) == '<r xmlns="urn:s" xmlns:p="urn:p"><p:item k="2"><sub>changed</sub></p:item></r>'
}

fn test_namespaces_of_moved_and_inserted_elements() {
	s := '<r xmlns="urn:d"><a xmlns="urn:a"><b/></a><c xmlns=""><e/></c></r>'
	// b (in urn:a) moved under c (no default): xmlns="urn:a" goes with it; e (in no namespace)
	// moved under a (urn:a): xmlns="" goes with it
	out := edited(s, fn (mut e Edit) ! {
		r := e.root()
		b := r.child('a').child('b')
		c := r.child('c')
		e.move(b, c, 0)!
		e.move(c.child('e'), r.child('a'), 0)!
	})
	assert out == '<r xmlns="urn:d"><a xmlns="urn:a"><e xmlns=""/></a><c xmlns=""><b xmlns="urn:a"/></c></r>'
	mut d := doc_of(out)
	d.resolve_namespaces()!
	for n in d.node(d.root()).descendants('b') {
		assert d.ns_uri(d.ns_of(n.i)) == 'urn:a'
	}
	for n in d.node(d.root()).descendants('e') {
		assert d.ns_uri(d.ns_of(n.i)) == ''
	}
	// a fragment is read where it is put
	assert edited(s, fn (mut e Edit) ! {
		e.insert(e.root(), 0, '<f/>')!
	}) == '<r xmlns="urn:d"><f/><a xmlns="urn:a"><b/></a><c xmlns=""><e/></c></r>'
}

fn test_read_through() {
	d := doc_of('<r a="1"><x>t</x><y/></r>')
	mut e := d.edit()
	r := e.root()
	e.set_attr(r, 'b', '2')!
	e.remove_attr(r, 'a')!
	n := e.insert(r, 1, '<n k="v">nt</n>')!
	e.remove(r.child('y'))!
	assert r.attrs() == [EAttr{'b', '2'}]
	assert r.attr('a') == '' && !r.has_attr('a')
	assert r.children().map(it.name()) == ['x', 'n']
	assert n.parent().key == r.key && n.text() == 'nt' && n.attr('k') == 'v'
	assert n.source().doc.name(n.source().i) == 'n'
	y := d.node(d.root()).child('y')
	assert e.node(y.i).removed()
	assert !n.removed()
	assert r.child('x').text() == 't'
}

// --- random edit sets against a tree model -----------------------------------------------------

// Rng is a small deterministic generator (xorshift64*).
struct Rng {
mut:
	s u64
}

fn (mut r Rng) n(k int) int {
	r.s ^= r.s >> 12
	r.s ^= r.s << 25
	r.s ^= r.s >> 27
	return int((r.s * 0x2545F4914F6CDD1D) >> 33) % k
}

fn (mut r Rng) pick(xs []string) string {
	return xs[r.n(xs.len)]
}

// TM is the model: the tree an edit set should give, kept apart from the edit set's own
// bookkeeping. key is the edited element it stands for; orig, the element of the edited document
// it was read from (0 for inserted content); uri, the namespace its name must keep (for a fragment,
// the default namespace where it was put first).
@[heap]
struct TM {
mut:
	name    string
	attrs   []EAttr
	text    string
	kids    []&TM
	key     u64
	orig    u32
	uri     string
	dflt    string // the default namespace in scope at it
	touched bool   // its own text, attributes or children changed
	moved   bool   // copied or moved here, so it may carry declarations
}

fn tm_of(d &Doc, i u32, key_piece u32, orig bool) &TM {
	mut t := &TM{
		name: d.name(i)
		text: d.own_of(i)
		key:  ekey(key_piece, i)
		orig: if orig { i } else { 0 }
		uri:  d.ns_uri(d.ns_of(i))
		dflt: if d.ns.len == d.tag.len { d.ns_uri(d.ns_for_prefix(i, '') or { no_ns }) } else { '' }
	}
	lo, hi := d.attr_range(i)
	for a := lo; a < hi; a++ {
		t.attrs << EAttr{d.attr_name(a), d.attr_value(a)}
	}
	for c in d.node(i).children() {
		t.kids << tm_of(d, c.i, key_piece, orig)
	}
	return t
}

fn (t &TM) all(mut out []&TM) {
	out << t
	for c in t.kids {
		c.all(mut out)
	}
}

fn (t &TM) contains(x &TM) bool {
	if voidptr(t) == voidptr(x) {
		return true
	}
	return t.kids.any(it.contains(x))
}

fn (t &TM) parent_of(x &TM) ?&TM {
	for c in t.kids {
		if voidptr(c) == voidptr(x) {
			return t
		}
		if p := c.parent_of(x) {
			return p
		}
	}
	return none
}

// clean reports whether t is an element of the edited document with nothing below it changed.
fn (t &TM) clean() bool {
	return t.orig != 0 && !t.touched && t.kids.all(it.clean())
}

fn (n Node) attr_names() []string {
	lo, hi := n.doc.attr_range(n.i)
	mut out := []string{}
	for a := lo; a < hi; a++ {
		out << n.doc.attr_name(a)
	}
	return out
}

fn random_text(mut r Rng) string {
	return r.pick(['a', 'b c', 'x &amp; y', '&lt;tag&gt;', '&#x20;', 'été', '  padded  ', '1',
		'<![CDATA[c <d>]]>'])
}

fn random_element(mut r Rng, depth int, indent string) string {
	name := r.pick(['a', 'b', 'p:c', 'd', 'e'])
	mut s := '<${name}'
	if r.n(4) == 0 {
		s += r.pick([' xmlns="urn:x"', ' xmlns=""', ' xmlns:p="urn:p2"'])
	}
	for k in 0 .. r.n(3) {
		q := if r.n(2) == 0 { '"' } else { "'" }
		s += r.pick([' ', '  ']) + r.pick(['k', 'm', 'p:n']) + '${k}=${q}' + r.pick([
			'v',
			'1 &amp; 2',
			'x',
			'',
		]) + q
	}
	kids := if depth > 3 { 0 } else { r.n(4) }
	if kids == 0 && r.n(3) == 0 {
		return s + r.pick(['/>', ' />'])
	}
	s += '>'
	mixed := r.n(5) == 0
	if kids == 0 || mixed || r.n(4) == 0 {
		s += random_text(mut r)
	}
	for _ in 0 .. kids {
		s += '\n${indent}  '
		if r.n(6) == 0 {
			s += '<!-- note -->\n${indent}  '
		}
		if r.n(10) == 0 {
			s += '<?pi x?>'
		}
		s += random_element(mut r, depth + 1, indent + '  ')
		if mixed {
			s += random_text(mut r)
		}
	}
	if kids > 0 {
		s += '\n${indent}'
	}
	return s + '</${name}>'
}

fn random_doc(mut r Rng) string {
	mut s := r.pick(['', '<?xml version="1.0"?>\n', '<?xml version="1.0"?>\n<!-- head -->\n'])
	s += '<root xmlns="urn:d" xmlns:p="urn:p">'
	for _ in 0 .. 1 + r.n(4) {
		s += '\n  ' + random_element(mut r, 1, '  ')
	}
	return s + '\n</root>' + r.pick(['', '\n', '\n<!-- tail -->\n'])
}

// apply_random makes one random edit to both the edit set and the model; gone holds the
// elements removed, with what is inside them.
fn apply_random(mut r Rng, mut e Edit, mut root TM, mut gone []&TM, other &Doc) ! {
	mut all := []&TM{}
	root.all(mut all)
	mut t := all[r.n(all.len)]
	n := ENode{e, t.key}
	match r.n(9) {
		0 {
			v := r.pick(['new', '', 'a < b & "c"', ' ', 'été', 'x]]>y'])
			e.set_text(n, v)!
			t.text = v
			t.touched = true
		}
		1 {
			name := r.pick(['k0', 'k1', 'new', 'p:n0'])
			v := r.pick(['1', '', 'say "hi"', "it's", 'a\tb'])
			e.set_attr(n, name, v)!
			k := t.attrs.map(it.name).index(name)
			if k >= 0 {
				t.attrs[k] = EAttr{name, v}
			} else {
				t.attrs << EAttr{name, v}
			}
			t.touched = true
		}
		2 {
			name := r.pick(['k0', 'k1', 'm1', 'xmlns'])
			if name == 'xmlns' {
				return
			}
			e.remove_attr(n, name)!
			k := t.attrs.map(it.name).index(name)
			if k >= 0 {
				t.attrs.delete(k)
				t.touched = true
			}
		}
		3 {
			at := r.n(t.kids.len + 1)
			frag := r.pick(['<f/>', '<f k="1">t</f>', '<g>\n<h>x</h>\n</g>'])
			x := e.insert(n, at, frag)!
			d := x.source().doc
			mut m := tm_of(d, d.root(), kpiece(x.key), false)
			// read in the namespaces where it is put first
			mut inside := []&TM{}
			m.all(mut inside)
			for mut f in inside {
				f.uri = t.dflt
				f.dflt = t.dflt
			}
			t.kids.insert(at, m)
			t.touched = true
		}
		4 {
			// a copy of an element of another document, or of this one as it was
			src := if r.n(2) == 0 { other } else { e.doc }
			mut els := []u32{}
			for k in 1 .. src.len() {
				if src.is_element(u32(k)) {
					els << u32(k)
				}
			}
			s := els[r.n(els.len)]
			at := r.n(t.kids.len + 1)
			x := e.insert_copy(n, at, src.node(s))!
			mut m := tm_of(src, s, kpiece(x.key), false)
			m.moved = true
			t.kids.insert(at, m)
			t.touched = true
		}
		5 {
			if voidptr(t) == voidptr(root) {
				return
			}
			mut p := root.parent_of(t) or { return }
			e.remove(n)!
			p.kids.delete(p.kids.map(voidptr(it)).index(voidptr(t)))
			p.touched = true
			gone << t
		}
		8 {
			// an element removed, or inside one removed, put back under t
			if gone.len == 0 {
				return
			}
			g := gone[r.n(gone.len)]
			mut inside := []&TM{}
			g.all(mut inside)
			mut x := inside[r.n(inside.len)]
			if voidptr(x) == voidptr(g) {
				gone.delete(gone.map(voidptr(it)).index(voidptr(g)))
			} else {
				mut from := g.parent_of(x) or { return }
				from.kids.delete(from.kids.map(voidptr(it)).index(voidptr(x)))
				from.touched = true
			}
			at := r.n(t.kids.len + 1)
			if r.n(2) == 0 {
				e.place(ENode{e, x.key}, n, at)!
			} else {
				e.move(ENode{e, x.key}, n, at)!
			}
			t.kids.insert(at, x)
			t.touched = true
			x.moved = true
		}
		else {
			// move t under an element outside it
			if voidptr(t) == voidptr(root) {
				return
			}
			targets := all.filter(!t.contains(it))
			mut to := targets[r.n(targets.len)]
			mut p := root.parent_of(t) or { return }
			p.kids.delete(p.kids.map(voidptr(it)).index(voidptr(t)))
			p.touched = true
			at := r.n(to.kids.len + 1)
			e.move(n, ENode{e, to.key}, at)!
			to.kids.insert(at, t)
			to.touched = true
			t.moved = true
		}
	}
}

// same checks the written document's element w against the model, and that what no edit touched
// is byte for byte what it was.
fn same(mut w Doc, wi u32, t &TM, src &Doc) ! {
	if w.name(wi) != t.name {
		return error('name ${w.name(wi)}, expected ${t.name}')
	}
	mut attrs := []EAttr{}
	lo, hi := w.attr_range(wi)
	for a := lo; a < hi; a++ {
		if !is_ns_decl_name(w.attr_name(a)) {
			attrs << EAttr{w.attr_name(a), w.attr_value(a)}
		}
	}
	want := t.attrs.filter(!is_ns_decl_name(it.name))
	if attrs != want {
		return error('<${t.name}> attributes ${attrs}, expected ${want}')
	}
	if w.own_of(wi) != t.text {
		return error('<${t.name}> text `${w.own_of(wi)}`, expected `${t.text}`')
	}
	// its namespace is the one it was read in
	uri := w.ns_uri(w.ns_of(wi))
	if uri != t.uri {
		return error('<${t.name}> in `${uri}`, expected `${t.uri}`')
	}
	if t.clean() {
		mut got := w.subtree_bytes(wi)
		if t.moved {
			// declarations it was given where it is
			own := src.node(t.orig).attr_names()
			for a := lo; a < hi; a++ {
				if is_ns_decl_name(w.attr_name(a)) && w.attr_name(a) !in own {
					got = got.replace_once(' ${w.attr_name(a)}="${w.attr_raw(a)}"', '')
				}
			}
		}
		if got != src.subtree_bytes(t.orig) {
			return error('<${t.name}> changed: `${got}`, was `${src.subtree_bytes(t.orig)}`')
		}
	}
	mut kids := []Node{}
	for c in w.node(wi).children() {
		kids << c
	}
	if kids.len != t.kids.len {
		return error('<${t.name}> has ${kids.len} children, expected ${t.kids.len}')
	}
	for k, c in kids {
		same(mut w, c.i, t.kids[k], src)!
	}
}

// kept_lists_hold checks that every child list the edit set keeps is the one `kids` builds.
fn kept_lists_hold(e &Edit) {
	for p, l in e.kid_lists {
		assert l == e.kids(p), 'the kept child list of ${p}'
	}
}

fn test_random_edit_sets() {
	mut r := Rng{0x9E3779B97F4A7C15}
	mut cases := 0
	mut ops := 0
	for _ in 0 .. 400 {
		s := random_doc(mut r)
		mut d := doc_of(s)
		d.resolve_namespaces()!
		mut other := doc_of(random_doc(mut r))
		other.resolve_namespaces()!
		mut e := d.edit()
		mut root := tm_of(d, d.root(), 0, true)
		mut gone := []&TM{}
		count := 1 + r.n(8)
		for _ in 0 .. count {
			apply_random(mut r, mut e, mut root, mut gone, other)!
			kept_lists_hold(e)
			ops++
		}
		out := e.xml()
		mut w := parse_string(out) or { panic('${err}\n${out}\n--- from\n${s}') }
		w.resolve_namespaces() or { panic('${err}\n${out}\n--- from\n${s}') }
		same(mut w, w.root(), root, d) or { panic('${err}\n${out}\n--- from\n${s}') }
		// the bytes before and after the root are the file's
		lo, hi := d.span(d.root())
		assert out.starts_with(s[..lo]) && out.ends_with(s[hi..])
		// the edit set reads as what it writes
		assert eshape(e.root()) == shape(w.node(w.root()))
		cases++
	}
	assert cases == 400 && ops > 1000
}

fn test_set_text_runs() {
	assert edited('<p>one <b>x</b> two<!-- c --> three<i/></p>', fn (mut e Edit) ! {
		e.set_text_runs(e.root(), [TextRun{0, 'a'}, TextRun{1, 'b'}, TextRun{2, 'c'}])!
	}) == '<p>a<b>x</b><!-- c -->b<i/>c</p>'
	// slots count the children as edited
	assert edited('<p>\n  <b/>\n  <i/>\n</p>', fn (mut e Edit) ! {
		r := e.root()
		e.remove(r.child('b'))!
		e.insert(r, 1, '<n/>')!
		e.set_text_runs(r, [TextRun{1, 'mid'}, TextRun{5, 'end'}])!
	}) == '<p>\n  <i/>mid<n/>end</p>'
	d := doc_of('<p>a<b/>c</p>')
	mut e := d.edit()
	e.set_text_runs(e.root(), [TextRun{1, 'x'}, TextRun{0, 'y'}]) or {
		assert err.msg().contains('decrease')
	}
	// read through: the original runs, after the children now before them
	e.insert(e.root(), 0, '<n/>')!
	assert e.root().text_runs() == [TextRun{0, 'a'}, TextRun{2, 'c'}]
}

// diff_shape writes a tree as one line, as a diff of documents with their namespaces resolved
// compares it: names by namespace and local name, attributes in any order (declarations left
// out), and the own text at each slot among the children (the runs of one slot joined: a comment
// between two is not kept).
fn diff_shape(d &Doc, i u32) string {
	mut slots := map[int]string{}
	for r in d.node(i).text_runs() {
		slots[r.slot] += r.text
	}
	mut attrs := []string{}
	lo, hi := d.attr_range(i)
	for a := lo; a < hi; a++ {
		if !d.is_ns_decl(a) {
			attrs << '{${d.ns_uri(d.attr_ns_of(a))}}${d.attr_local_name(a)}=${d.attr_value(a)}'
		}
	}
	attrs.sort()
	mut s := '{${d.ns_uri(d.ns_of(i))}}${d.local_name(i)}${attrs}${slots}'
	for c in d.node(i).children() {
		s += diff_shape(d, c.i)
	}
	return s + '/'
}

fn test_a_diff_applied_by_an_edit_set_gives_the_new_document() {
	mut r := Rng{0x2545F4914F6CDD1D}
	mut applied := 0
	for _ in 0 .. 300 {
		// a document, and another made from it by random edits
		s := random_doc(mut r)
		mut a := doc_of(s)
		a.resolve_namespaces()!
		mut other := doc_of(random_doc(mut r))
		other.resolve_namespaces()!
		mut e0 := a.edit()
		mut model := tm_of(a, a.root(), 0, true)
		mut gone := []&TM{}
		for _ in 0 .. 1 + r.n(6) {
			apply_random(mut r, mut e0, mut model, mut gone, other)!
			kept_lists_hold(e0)
		}
		mut b := doc_of(e0.xml())
		b.resolve_namespaces()!
		diff := diff_docs(a, b, RuleSet{}, DiffOptions{})!
		if diff.changes.any(it.kind == .added && !it.parent.ok()) {
			continue // the root replaced
		}
		e := apply(diff, a)!
		kept_lists_hold(e)
		out := e.xml()
		mut w := doc_of(out)
		w.resolve_namespaces()!
		assert diff_shape(w, w.root()) == diff_shape(b, b.root()), out
		applied++
	}
	assert applied > 250
}

fn test_a_move_that_fails_changes_nothing() {
	d := doc_of('<r><a/><b/></r>')
	mut e := d.edit()
	a := e.root().child('a')
	// two children, a among them: without it there is one, so 2 is out of range
	e.move(a, e.root(), 2) or { assert err.msg().contains('out of range') }
	assert !a.removed()
	assert e.root().children().map(it.name()) == ['a', 'b']
	assert e.xml() == '<r><a/><b/></r>'
	e.move(a, e.root(), 1)!
	assert e.xml() == '<r><b/><a/></r>'
	e.move(e.root(), a, 0) or { assert err.msg().contains('root') }
}

fn test_an_element_inside_a_removed_one_can_be_put_back() {
	d := doc_of('<r><a><b/><c/></a><z/></r>')
	mut e := d.edit()
	a := e.root().child('a')
	b := a.child('b')
	c := a.child('c')
	e.remove(a)!
	assert b.removed()
	e.remove(b) or { assert err.msg().contains('not in the document') }
	e.place(b, e.root(), 0)!
	e.move(c, e.root(), 2)!
	assert e.xml() == '<r><b/><z/><c/></r>'
	// and what it was taken from no longer holds it
	e.place(a, e.root(), 0)!
	assert e.xml() == '<r><a></a><b/><z/><c/></r>'
	assert a.children().len == 0 && b.parent().key == e.root().key
}

fn test_a_fragment_must_have_its_prefixes_bound() {
	d := doc_of('<r xmlns:q="urn:q"><a/></r>')
	mut e := d.edit()
	e.insert(e.root(), 0, '<p:n/>') or { assert err.msg().contains('prefix `p`') }
	e.insert(e.root(), 0, '<n p:k="1"/>') or { assert err.msg().contains('prefix `p`') }
	e.insert(e.root(), 0, '<q:n/>')!
	e.insert(e.root(), 0, '<p:n xmlns:p="urn:p"><p:m xml:lang="en"/></p:n>')!
	assert e.xml() == '<r xmlns:q="urn:q"><p:n xmlns:p="urn:p"><p:m xml:lang="en"/></p:n><q:n/><a/></r>'
}

fn test_free_leaves_an_empty_edit_set() {
	d := doc_of('<r><a/></r>')
	mut e := d.edit()
	n := e.insert(e.root(), 0, '<n/>')!
	e.set_attr(e.root(), 'k', 'v')!
	e.free()
	assert !n.ok() && n.name() == '' && n.children().len == 0
	assert e.xml() == '<r><a/></r>'
	e.set_attr(n, 'k', 'v') or { assert err.msg().contains('not a node') }
	e.insert(e.root(), 1, '<m/>')!
	assert e.xml() == '<r><a/><m/></r>'
}

fn test_many_inserts_and_attributes() {
	mut s := '<r>'
	for k in 0 .. 2000 {
		s += '<c n="${k}"/>'
	}
	d := doc_of(s + '</r>')
	mut e := d.edit()
	r := e.root()
	// before every other original child, in the order of the children
	for k in 0 .. 2000 {
		e.insert(r, 2 * k, '<i n="${k}"/>')!
	}
	kids := r.children()
	assert kids.len == 4000
	for k in 0 .. 2000 {
		assert kids[2 * k].attr('n') == '${k}' && kids[2 * k].name() == 'i'
		assert kids[2 * k + 1].name() == 'c'
	}
	// an element with many attributes, changed and removed
	mut t := '<r'
	for k in 0 .. 500 {
		t += ' a${k}="${k}"'
	}
	d2 := doc_of(t + '/>')
	mut e2 := d2.edit()
	for k in 0 .. 500 {
		if k % 2 == 0 {
			e2.remove_attr(e2.root(), 'a${k}')!
		} else {
			e2.set_attr(e2.root(), 'a${k}', 'x')!
		}
	}
	out := e2.xml()
	assert out.starts_with('<r a1="x" a3="x"') && !out.contains('a0=') && out.ends_with(' a499="x"/>')
}

fn test_an_element_put_back_where_it_was_is_in_the_kept_list() {
	d := doc_of('<r><a/><b/></r>')
	mut e := d.edit()
	r := e.root()
	e.insert(r, 2, '<c/>')!
	a := r.children()[0]
	e.remove(a)!
	kept_lists_hold(e)
	e.unlift(a.key)
	kept_lists_hold(e)
	e.insert(r, 3, '<d/>')!
	assert e.xml() == '<r><a/><b/><c/><d/></r>'
}
