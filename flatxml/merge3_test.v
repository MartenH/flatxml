module flatxml

struct MRng {
mut:
	s u64
}

fn (mut r MRng) n(k int) int {
	r.s ^= r.s << 13
	r.s ^= r.s >> 7
	r.s ^= r.s << 17
	return int(r.s % u64(k))
}

fn mset(files map[string]string) &DocSet {
	mut s := DocSet.new()
	for name, xml in files {
		mut d := parse_bytes(xml.bytes(), name) or { panic('${err}\n${xml}') }
		s.add(mut d)
	}
	return s
}

fn mview(files map[string]string, rules string) &Merged {
	rs := parse_rules(rules) or { panic(err) }
	return mset(files).merge(rs) or { panic(err) }
}

// merged3 merges ours and theirs on base and writes the result, by path.
fn merged3(base map[string]string, ours map[string]string, theirs map[string]string, rules string) (map[string]string, Merge3) {
	b := mview(base, rules)
	mut m := merge3(b, mview(ours, rules), mview(theirs, rules)) or { panic(err) }
	mut out := map[string]string{}
	for k, d in b.set.docs {
		out[d.path] = if e := m.edit.edits[k] {
			e.xml()
		} else {
			unsafe { tos(d.src, d.src_len) }.clone()
		}
	}
	return out, m
}

const m3_rules = '
r s key=@id merge
s v single merge
s o key=@id ordered
o v single merge
'

fn test_changes_to_different_nodes_are_both_taken() {
	base := {
		'a.xml': '<r>\n  <s id="1" w="0"><v>a</v></s>\n  <s id="2" w="0"><v>b</v><o id="x"><v>1</v></o></s>\n</r>'
	}
	out, m := merged3(base, {
		'a.xml': '<r><s id="1" w="5"><v>a</v></s><s id="2" w="0"><v>b</v><o id="x"><v>1</v></o></s></r>'
	}, {
		'a.xml': '<r><s id="1" w="0"><v>a</v></s><s id="2" w="0"><v>c</v><o id="x"><v>1</v></o><o id="y"><v>2</v></o></s></r>'
	}, m3_rules)
	assert m.clean() && m.taken == 2
	// both, and every other byte of the base as it was
	assert out['a.xml'] == '<r>\n  <s id="1" w="5"><v>a</v></s>\n  <s id="2" w="0"><v>c</v><o id="x"><v>1</v></o><o id="y"><v>2</v></o></s>\n</r>'
}

fn test_the_same_change_on_both_sides_is_taken_once() {
	base := {
		'a.xml': '<r><s id="1" w="0"><v>a</v><o id="x"/></s><s id="2"/></r>'
	}
	both := {
		'a.xml': '<r><s id="1" w="7"><v>b</v><o id="x"/><o id="n"/></s></r>'
	}
	out, m := merged3(base, both, both, m3_rules)
	assert m.clean() && m.taken == 0
	assert out['a.xml'] == '<r><s id="1" w="7"><v>b</v><o id="x"/><o id="n"/></s></r>'
}

fn test_conflicts_are_reported_and_ours_kept() {
	base := {
		'a.xml': '<r>\n<s id="1" w="0"><v>a</v></s>\n<s id="2"><o id="x"><v>1</v></o></s>\n<s id="3"/></r>'
	}
	out, mut m := merged3(base, {
		'a.xml': '<r>\n<s id="1" w="1"><v>ours</v></s>\n<s id="3"/></r>'
	}, {
		'a.xml': '<r>\n<s id="1" w="2"><v>theirs</v></s>\n<s id="2"><o id="x"><v>9</v></o></s>\n<s id="3" w="t"/></r>'
	}, m3_rules)
	assert m.conflicts.map(it.kind) == [.attr, .text, .removed]
	// theirs's change to s 3, which ours did not touch, is taken
	assert out['a.xml'] == '<r>\n<s id="1" w="1"><v>ours</v></s>\n<s id="3" w="t"/></r>'
	lines := m.conflicts.map(m.describe(it))
	assert lines[0] == '! /r/s[1]: @w "1" / "2"  base a.xml:2:1, ours a.xml:2:1, theirs a.xml:2:1'
	assert lines[2].starts_with('! /r/s[2]: removed on one side, changed on the other (removed / text)')
	assert lines[2].ends_with('ours -, theirs a.xml:3:21')
	// theirs removes what ours changed below: ours is kept
	kept, mk := merged3(base, {
		'a.xml': '<r>\n<s id="1" w="0"><v>a</v></s>\n<s id="2"><o id="x"><v>5</v></o></s>\n<s id="3"/></r>'
	}, {
		'a.xml': '<r>\n<s id="1" w="0"><v>a</v></s>\n<s id="3"/></r>'
	}, m3_rules)
	assert mk.conflicts.map(it.kind) == [.removed]
	assert kept['a.xml'].contains('<s id="2"><o id="x"><v>5</v></o></s>')
	// a node moved to two places
	moved_base := {
		'a.xml': '<r><s id="1"><o id="x"/><o id="y"/><o id="z"/></s></r>'
	}
	_, mm := merged3(moved_base, {
		'a.xml': '<r><s id="1"><o id="y"/><o id="z"/><o id="x"/></s></r>'
	}, {
		'a.xml': '<r><s id="1"><o id="y"/><o id="x"/><o id="z"/></s></r>'
	}, 'r s key=@id merge\ns o')
	assert mm.clean() // one parent: moved within it on both sides, ours's place taken
}

fn test_a_patch_is_a_merge() {
	// the change from A to B, made on C: C is ours, B theirs, A the base
	a := {
		'a.xml': '<r><s id="1"><v>a</v></s><s id="2"><v>b</v></s></r>'
	}
	b := {
		'a.xml': '<r><s id="1"><v>a</v></s><s id="2"><v>B</v></s></r>'
	}
	c := {
		'a.xml': '<r>\n  <s id="1"><v>c</v></s>\n  <s id="2"><v>b</v></s>\n</r>'
	}
	out, m := merged3(a, c, b, m3_rules)
	assert m.clean()
	assert diff(mview(out, m3_rules), mview({
		'a.xml': '<r><s id="1"><v>c</v></s><s id="2"><v>B</v></s></r>'
	}, m3_rules)).equal()
}

// --- random models, edited on two sides ----------------------------------------------------

struct MG {
mut:
	id string
	w  string
	v  string
	os []MO
}

struct MO {
	id string
	v  string
}

fn (g &MG) xml() string {
	mut x := '<s id="${g.id}" w="${g.w}">'
	if g.v != '' {
		x += '<v>${g.v}</v>'
	}
	for o in g.os {
		x += '<o id="${o.id}"><v>${o.v}</v></o>'
	}
	return x + '</s>'
}

fn model_xml(gs []MG) string {
	return '<r>' + gs.map(it.xml()).join('') + '</r>'
}

// edit_group makes one edit to g, chosen by seed, the same every time; false to remove it.
fn edit_group(mut g MG, seed u64, side string) bool {
	mut r := MRng{seed | 1}
	match r.n(6) {
		0 {
			g.v = '${side}${r.n(9)}'
		}
		1 {
			g.w = '${side}${r.n(9)}'
		}
		2 {
			if g.os.len > 0 {
				g.os.delete(r.n(g.os.len))
			}
		}
		3 {
			g.os.insert(r.n(g.os.len + 1), MO{'${side}${seed % 1000}', 'n'})
		}
		4 {
			if g.os.len > 2 {
				o := g.os[0]
				g.os.delete(0)
				g.os << o
			}
		}
		else {
			return false
		}
	}
	return true
}

fn test_random_edits_on_two_sides_merge() {
	rules := m3_rules
	mut r := MRng{0x2545F4914F6CDD1D}
	mut clean, mut conflicted, mut taken := 0, 0, 0
	for round in 0 .. 300 {
		mut base := []MG{}
		mut next := 0
		for i in 0 .. 3 + r.n(5) {
			mut g := MG{
				id: 's${i}'
				w:  '0'
				v:  'v${r.n(3)}'
			}
			for _ in 0 .. r.n(5) {
				g.os << MO{'o${next}', '${r.n(3)}'}
				next++
			}
			base << g
		}
		// each group edited by ours, theirs, both alike, both differently, or neither
		mut ours, mut theirs, mut want := base.clone(), base.clone(), base.clone()
		mut overlaps := 0
		for k in 0 .. base.len {
			seed := u64(round * 100 + k) * 0x9E3779B97F4A7C15
			who := r.n(5)
			mut gone_o, mut gone_t, mut gone_w := false, false, false
			if who == 0 || who == 2 {
				gone_o = !edit_group(mut ours[k], seed, 'o')
				gone_w = !edit_group(mut want[k], seed, 'o')
			}
			if who == 1 {
				gone_t = !edit_group(mut theirs[k], seed, 't')
				gone_w = !edit_group(mut want[k], seed, 't')
			}
			if who == 2 {
				gone_t = !edit_group(mut theirs[k], seed, 'o')
			}
			if who == 3 {
				// one text, two values: a conflict, and ours's value kept
				ours[k].v = 'ov'
				theirs[k].v = 'tv'
				want[k].v = 'ov'
				overlaps++
			}
			if gone_o {
				ours[k].id = ''
			}
			if gone_t {
				theirs[k].id = ''
			}
			if gone_w {
				want[k].id = ''
			}
		}
		// a new group on each side
		if r.n(3) == 0 {
			ours << MG{
				id: 'no${round}'
				v:  'x'
			}
			want << MG{
				id: 'no${round}'
				v:  'x'
			}
		}
		if r.n(3) == 0 {
			theirs << MG{
				id: 'nt${round}'
				v:  'y'
			}
			want << MG{
				id: 'nt${round}'
				v:  'y'
			}
		}
		live := fn (gs []MG) []MG {
			return gs.filter(it.id != '')
		}
		out, m := merged3({
			'a.xml': model_xml(base)
		}, {
			'a.xml': model_xml(live(ours))
		}, {
			'a.xml': model_xml(live(theirs))
		}, rules)
		taken += m.taken
		assert m.conflicts.len == overlaps && m.conflicts.all(it.kind == .text), 'round ${round}\n${model_xml(base)}\n${model_xml(live(ours))}\n${model_xml(live(theirs))}'
		got := mview(out, rules)
		mut d := diff(got, mview({
			'a.xml': model_xml(live(want))
		}, rules))
		assert d.equal(), 'round ${round}\n${model_xml(base)}\n${model_xml(live(ours))}\n${model_xml(live(theirs))}\n${out}\n${d.changes.map(d.describe(it))}'
		if overlaps > 0 {
			conflicted++
		} else {
			clean++
		}
	}
	assert clean > 100 && conflicted > 100 && taken > 250, '${clean} ${conflicted} ${taken}'
}
