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
	id   string
	w    string
	v    string
	os   []MO
	file int    // the file of the base the group is in
	y    bool   // its mixed text has a <y/> before the <x/>
	tail string // the text after the <x/> in it
}

struct MO {
mut:
	id string
	v  string
}

fn (g &MG) xml() string {
	mut x := '<s id="${g.id}" w="${g.w}">'
	if g.v != '' {
		x += '<v>${g.v}</v>'
	}
	x += '<p>a' + if g.y { '<y/>' } else { '' } + '<x/>${g.tail}</p>'
	for o in g.os {
		x += '<o id="${o.id}"><v>${o.v}</v></o>'
	}
	return x + '</s>'
}

// deep is a copy of gs that shares no list with it.
fn deep(gs []MG) []MG {
	return gs.map(MG{
		...it
		os: it.os.clone()
	})
}

fn model_xml(gs []MG) string {
	return '<r>' + gs.filter(it.id != '').map(it.xml()).join('') + '</r>'
}

// model_files is the base: each group in its file of two.
fn model_files(gs []MG) map[string]string {
	mut out := map[string]string{}
	for f in 0 .. 2 {
		out['f${f}.xml'] = '<r>' + gs.filter(it.file == f).map(it.xml()).join('') + '</r>'
	}
	return out
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

const m3p_rules = '
r s key=@id merge
s v single merge
s p single merge
s o key=@id ordered
o v single merge
'

fn test_random_edits_on_two_sides_merge() {
	rules := m3p_rules
	mut r := MRng{0x2545F4914F6CDD1D}
	mut clean, mut conflicted, mut taken := 0, 0, 0
	mut moves, mut across, mut mixed := 0, 0, 0
	for round in 0 .. 300 {
		mut base := []MG{}
		mut next := 0
		for i in 0 .. 4 + r.n(5) {
			mut g := MG{
				id:   's${i}'
				w:    '0'
				v:    'v${r.n(3)}'
				file: r.n(2)
				tail: 'b'
			}
			for _ in 0 .. r.n(5) {
				g.os << MO{'o${next}', '${r.n(3)}'}
				next++
			}
			base << g
		}
		// each group edited by ours, theirs, both alike, both differently (one text), in its mixed
		// text by both (a <y/> on one side, the text after <x/> on the other), or neither
		mut ours, mut theirs, mut want := deep(base), deep(base), deep(base)
		mut expected := 0
		mut free := []int{}
		for k in 0 .. base.len {
			seed := u64(round * 100 + k) * 0x9E3779B97F4A7C15
			who := r.n(7)
			if who == 0 || who == 2 {
				if !edit_group(mut ours[k], seed, 'o') {
					ours[k].id = ''
				}
				if !edit_group(mut want[k], seed, 'o') {
					want[k].id = ''
				}
			}
			if who == 1 {
				if !edit_group(mut theirs[k], seed, 't') {
					theirs[k].id = ''
				}
				if !edit_group(mut want[k], seed, 't') {
					want[k].id = ''
				}
			}
			if who == 2 {
				if !edit_group(mut theirs[k], seed, 'o') {
					theirs[k].id = ''
				}
			}
			if who == 3 {
				ours[k].v = 'ov'
				theirs[k].v = 'tv'
				want[k].v = 'ov'
				expected++
			}
			if who == 4 {
				ours[k].y = true
				theirs[k].tail = 'c'
				want[k].y = true
				want[k].tail = 'c'
				mixed++
			}
			if who >= 5 {
				free << k
			}
		}
		// a child moved from one group no other edit touches to another, by one side, perhaps
		// changed by the other; into another file where the groups are in two
		if free.len >= 2 && free.any(base[it].os.len > 0) {
			mut from := free.filter(base[it].os.len > 0)[r.n(free.filter(base[it].os.len > 0).len)]
			mut to := free[r.n(free.len)]
			if to == from {
				to = free.filter(it != from)[0]
			}
			x := base[from].os.len - 1
			o := base[from].os[x]
			mover_ours := r.n(2) == 0
			other_edits := r.n(2) == 0
			cross := base[from].file != base[to].file
			moves++
			if cross {
				across++
			}
			mut moved := o
			mut changed := o
			changed.v = 'e'
			// the side that moves, and the other
			if mover_ours {
				ours[from].os.delete(x)
				ours[to].os << moved
				if other_edits {
					theirs[from].os[x] = changed
				}
			} else {
				theirs[from].os.delete(x)
				theirs[to].os << moved
				if other_edits {
					ours[from].os[x] = changed
				}
			}
			if cross && other_edits {
				expected++
				if mover_ours {
					// ours's copy is made, theirs's change is the conflict
					want[from].os.delete(x)
					want[to].os << moved
				} else {
					// the move is not made, ours's change is kept
					want[from].os[x] = changed
				}
			} else {
				want[from].os.delete(x)
				want[to].os << if other_edits { changed } else { moved }
			}
		}
		// a new group on each side
		if r.n(3) == 0 {
			ours << MG{
				id:   'no${round}'
				v:    'x'
				tail: 'b'
			}
			want << MG{
				id:   'no${round}'
				v:    'x'
				tail: 'b'
			}
		}
		if r.n(3) == 0 {
			theirs << MG{
				id:   'nt${round}'
				v:    'y'
				tail: 'b'
			}
			want << MG{
				id:   'nt${round}'
				v:    'y'
				tail: 'b'
			}
		}
		parts := model_files(base)
		out, m := merged3(parts, one(model_xml(ours)), one(model_xml(theirs)), rules)
		taken += m.taken
		what := 'round ${round}\n${parts}\n${model_xml(ours)}\n${model_xml(theirs)}\n${out}'
		assert m.conflicts.len == expected, '${what}\n${m.conflicts.map(it.kind)}'
		got := mview(out, rules)
		assert got.problems.len == 0, what
		mut d := diff(got, mview(one(model_xml(want)), rules))
		assert d.equal(), '${what}\n${d.changes.map(d.describe(it))}'
		if expected > 0 {
			conflicted++
		} else {
			clean++
		}
	}
	assert clean > 50 && conflicted > 100 && taken > 250 && across > 30 && mixed > 100, '${clean} ${conflicted} ${taken} ${moves} ${across} ${mixed}'
}

// --- the cases a review reproduced -------------------------------------------------------------

fn one(xml string) map[string]string {
	return {
		'a.xml': xml
	}
}

fn test_two_moves_into_each_other_are_a_conflict() {
	out, m := merged3(one('<r><a/><b/></r>'), one('<r><b><a/></b></r>'), one('<r><a><b/></a></r>'),
		'')
	assert m.conflicts.map(it.kind) == [.moved]
	assert out['a.xml'] == '<r><b><a/></b></r>'
}

const split_rules = 'r s key=@id merge\ns o key=@id merge\no v single merge'

fn test_a_node_one_side_moves_to_another_file_keeps_the_other_sides_changes_or_says_so() {
	base := {
		'a.xml': '<r><s id="1"><o id="x"><v>1</v></o></s></r>'
		'b.xml': '<r><s id="2"><o id="y"/></s></r>'
	}
	moved := one('<r><s id="1"/><s id="2"><o id="y"/><o id="x"><v>1</v></o></s></r>')
	changed := one('<r><s id="1"><o id="x"><v>2</v></o></s><s id="2"><o id="y"/></s></r>')
	// ours moves x into b.xml, theirs changes it: ours's copy is made, theirs's change is a conflict
	out, m := merged3(base, moved, changed, split_rules)
	assert m.conflicts.map(it.kind) == [.moved]
	assert out['a.xml'] == '<r><s id="1"></s></r>'
	// (o is ordered by key: x before y)
	assert out['b.xml'] == '<r><s id="2"><o id="x"><v>1</v></o><o id="y"/></s></r>'
	// theirs moves it, ours changed it: it stays, with ours's change, and that is a conflict
	out2, m2 := merged3(base, changed, moved, split_rules)
	assert m2.conflicts.map(it.kind) == [.moved]
	assert out2['a.xml'] == '<r><s id="1"><o id="x"><v>2</v></o></s></r>'
	assert out2['b.xml'] == '<r><s id="2"><o id="y"/></s></r>'
}

fn test_two_different_children_of_one_identity_added_are_a_conflict() {
	out, m := merged3(one('<r><s id="1"/></r>'), one('<r><s id="1"><o id="n"><v>1</v></o></s></r>'),
		one('<r><s id="1"><o id="n"><v>2</v></o></s></r>'), split_rules)
	assert m.conflicts.map(it.kind) == [.added]
	assert out['a.xml'] == '<r><s id="1"><o id="n"><v>1</v></o></s></r>'
}

fn test_a_text_only_moved_among_children_is_not_a_text_change() {
	out, m := merged3(one('<r><p>a<x/>b</p></r>'), one('<r><p>a<y/><x/>b</p></r>'), one('<r><p>a<x/>c</p></r>'),
		'')
	assert m.clean()
	assert out['a.xml'] == '<r><p>a<y/><x/>c</p></r>'
}

fn test_a_removal_against_a_move_into_it_names_the_move() {
	_, m := merged3(one('<r><x/><y><z/></y></r>'), one('<r><x><z/></x><y/></r>'), one('<r><y><z/></y></r>'),
		'')
	assert m.conflicts.len == 1 && m.conflicts[0].kind == .removed
	assert m.conflicts[0].ours.kind == .moved && m.conflicts[0].ours.old.name() == 'z'
}

fn test_equal_additions_are_matched_one_to_one() {
	out, m := merged3(one('<r><s/></r>'), one('<r><s><x/></s></r>'), one('<r><s><x/><x/></s></r>'),
		'')
	assert m.clean()
	assert out['a.xml'] == '<r><s><x/><x/></s></r>'
}

fn test_an_ignored_attribute_is_nothing_for_a_removal_to_lose() {
	rules := '!ignore u\n' + m3_rules
	base := {
		'a.xml': '<r>\n<s id="1" u="a"><v>x</v></s>\n<s id="2"/></r>'
	}
	changed := {
		'a.xml': '<r>\n<s id="1" u="b"><v>x</v></s>\n<s id="2"/></r>'
	}
	removed := {
		'a.xml': '<r>\n<s id="2"/></r>'
	}
	// ours changed it, theirs removed it
	gone, m := merged3(base, changed, removed, rules)
	assert m.clean()
	assert gone['a.xml'] == '<r>\n<s id="2"/></r>'
	// ours removed it, theirs changed it
	gone2, m2 := merged3(base, removed, changed, rules)
	assert m2.clean()
	assert gone2['a.xml'] == '<r>\n<s id="2"/></r>'
	// any other attribute, or the same one when the rules do not ignore it, is still a change
	_, kept := merged3(base, changed, removed, m3_rules)
	assert kept.conflicts.map(it.kind) == [.removed]
	other := {
		'a.xml': '<r>\n<s id="1" u="a" w="1"><v>x</v></s>\n<s id="2"/></r>'
	}
	_, kept2 := merged3(base, other, removed, rules)
	assert kept2.conflicts.map(it.kind) == [.removed]
}
