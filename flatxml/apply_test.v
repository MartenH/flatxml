module flatxml

import os

struct ARng {
mut:
	s u64
}

fn (mut r ARng) n(k int) int {
	r.s ^= r.s << 13
	r.s ^= r.s >> 7
	r.s ^= r.s << 17
	return int(r.s % u64(k))
}

fn doc_named(name string, xml string) &Doc {
	return parse_bytes(xml.bytes(), name) or { panic('${err}\n${xml}') }
}

fn set_from(files map[string]string) &DocSet {
	mut s := DocSet.new()
	for name, xml in files {
		mut d := doc_named(name, xml)
		s.add(mut d)
	}
	return s
}

fn view_of(files map[string]string, rules string) &Merged {
	rs := parse_rules(rules) or { panic(err) }
	return set_from(files).merge(rs) or { panic(err) }
}

// written is each document of the edited set as XML, by its path.
fn written(mut me MEdit) map[string]string {
	mut out := map[string]string{}
	for k, d in me.view.set.docs {
		out[d.path] = if e := me.edits[k] { e.xml() } else { d.src_str() }
	}
	return out
}

fn (d &Doc) src_str() string {
	return unsafe { tos(d.src, d.src_len) }.clone()
}

const set_rules = '
r s key=@id merge
s v single merge
s o key=@id ordered
o v single merge
'

fn test_a_value_held_in_several_files_changes_in_each() {
	m := view_of({
		'a.xml': '<r>\n  <s id="x" w="1"><v>1</v></s>\n</r>'
		'b.xml': '<r>\n  <s id="x" w="1"><o id="p"/></s>\n  <s id="y"/>\n</r>'
		'c.xml': '<r><!-- untouched --></r>'
	}, set_rules)
	assert m.problems.len == 0
	mut me := m.edit()
	x := m.at_path('/x')
	me.set_attr(x, 'w', '2')!
	me.set_text(x.child('v', ''), '9')!
	assert me.edited() == [0, 1]
	out := written(mut me)
	assert out['a.xml'] == '<r>\n  <s id="x" w="2"><v>9</v></s>\n</r>'
	assert out['b.xml'] == '<r>\n  <s id="x" w="2"><o id="p"/></s>\n  <s id="y"/>\n</r>'
	assert out['c.xml'] == '<r><!-- untouched --></r>'
	// a merged node removed from every file that holds part of it
	mut me2 := m.edit()
	me2.remove(x)!
	out2 := written(mut me2)
	assert out2['a.xml'] == '<r>\n</r>'
	assert out2['b.xml'] == '<r>\n  <s id="y"/>\n</r>'
	// a new element under one fragment, in the document named
	mut me3 := m.edit()
	t := me3.fragment(x, 1)
	mut e := t.e
	e.insert(t, 0, '<o id="n"/>')!
	assert written(mut me3)['b.xml'].contains('<s id="x" w="1"><o id="n"/><o id="p"/></s>')
	assert !me3.fragment(m.at_path('/y'), 0).ok()
}

fn test_files_are_written_back_to_their_paths() {
	dir := os.join_path(os.vtmp_dir(), 'flatxml_apply_test_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	for name, xml in {
		'a.xml': '<r><s id="x"><v>1</v></s></r>'
		'b.xml': '<r>\n<s id="y"><v>2</v></s></r>'
	} {
		os.write_file(os.join_path(dir, name), xml)!
	}
	mut s := DocSet.new()
	assert s.load([os.join_path(dir, 'a.xml'), os.join_path(dir, 'b.xml')]).len == 0
	m := s.merge(parse_rules(set_rules)!)!
	mut me := m.edit()
	me.set_text(m.at_path('/y').child('v', ''), '3')!
	before := os.file_last_mod_unix(os.join_path(dir, 'a.xml'))
	me.write_files()!
	assert os.read_file(os.join_path(dir, 'b.xml'))! == '<r>\n<s id="y"><v>3</v></s></r>'
	assert os.read_file(os.join_path(dir, 'a.xml'))! == '<r><s id="x"><v>1</v></s></r>'
	assert os.file_last_mod_unix(os.join_path(dir, 'a.xml')) == before
	out := os.join_path(dir, 'out')
	me.write_to(fn [dir, out] (d &Doc) string {
		return os.join_path(out, d.path.all_after(dir + os.path_separator))
	})!
	assert os.read_file(os.join_path(out, 'a.xml'))! == '<r><s id="x"><v>1</v></s></r>'
	assert os.read_file(os.join_path(out, 'b.xml'))! == '<r>\n<s id="y"><v>3</v></s></r>'
}

fn test_a_diff_applied_to_a_set() {
	old := view_of({
		'a.xml': '<r><s id="x" w="1"><v>1</v></s></r>'
		'b.xml': '<r><s id="x" w="1"><o id="p"/><o id="q"/></s><s id="y"><o id="z"/></s></r>'
	}, set_rules)
	new := view_of({
		'n.xml': '<r><s id="x" w="2"><v>2</v><o id="q"/><o id="n"/><o id="p"/></s><s id="y"/><s id="t"><v>t</v></s></r>'
	}, set_rules)
	d := diff(old, new)
	mut me := d.apply()!
	out := written(mut me)
	// a new element goes to the file of its nearest sibling (t before x, the o with the others),
	// after the nearest sibling before it there
	assert out['a.xml'] == '<r><s id="t"><v>t</v></s><s id="x" w="2"><v>2</v></s></r>'
	assert out['b.xml'] == '<r><s id="x" w="2"><o id="q"/><o id="n"/><o id="p"/></s><s id="y"></s></r>'
	assert diff(view_of(out, set_rules), new).equal()
	// or where into says, when its parent has a fragment there
	mut me2 := d.apply(
		into: fn (f Node, p MNode) int {
			return if p.name() == 'r' { 1 } else { -1 }
		}
	)!
	assert written(mut me2)['b.xml'].starts_with('<r><s id="t"><v>t</v></s><s id="x" w="2">')
	// a diff of documents applies to the first
	a := doc_named('a.xml', '<r><a>1</a><b/></r>')
	b := doc_named('b.xml', '<r><b/><a>2</a></r>')
	e := apply(diff_docs(a, b, RuleSet{})!, a)!
	assert e.xml() == '<r><b/><a>2</a></r>'
	apply(diff_docs(a, b, RuleSet{})!, b) or { assert err.msg().contains('not made from') }
}

fn test_names_are_compared_by_namespace_when_resolved() {
	mut a := doc_named('a.xml', '<r xmlns:p="urn:x"><p:a k="1"/><b/></r>')
	mut b := doc_named('b.xml', '<r xmlns:q="urn:x"><q:a k="1"/><b xmlns="urn:d"/></r>')
	// as written, the prefixes differ
	assert !diff_docs(a, b, RuleSet{})!.equal()
	a.resolve_namespaces()!
	b.resolve_namespaces()!
	d := diff_docs(a, b, RuleSet{})!
	// by namespace: p:a and q:a are one element; b in no namespace is not b in urn:d
	assert d.changes.map('${it.kind}') == ['removed', 'added']
	assert d.changes[0].old.name() == 'b' && d.changes[1].new.name() == 'b'
}

// --- a set's files, edited, diffed and the diff applied, are the edited model ---------------

struct GS {
mut:
	id    string
	w     string
	v     string
	os    []GO
	v_in  int // the file the s and its v are in
	os_in int // the file its o children are in (the s is there too)
}

struct GO {
mut:
	id string
	v  string
}

fn (s &GS) xml_in(f int) string {
	if s.v_in != f && s.os_in != f {
		return ''
	}
	mut x := '<s id="${s.id}" w="${s.w}">'
	if s.v_in == f && s.v != '' {
		x += '<v>${s.v}</v>'
	}
	if s.os_in == f {
		for o in s.os {
			x += '<o id="${o.id}"><v>${o.v}</v></o>'
		}
	}
	return x + '</s>'
}

fn (s &GS) xml() string {
	mut x := '<s id="${s.id}" w="${s.w}">'
	if s.v != '' {
		x += '<v>${s.v}</v>'
	}
	for o in s.os {
		x += '<o id="${o.id}"><v>${o.v}</v></o>'
	}
	return x + '</s>'
}

fn test_a_set_diffed_against_its_edited_model_and_patched_is_the_model() {
	rules := parse_rules(set_rules) or { panic(err) }
	mut r := ARng{0x9E3779B97F4A7C15}
	mut edited_files, mut untouched_files, mut changes := 0, 0, 0
	for round in 0 .. 300 {
		files := 1 + r.n(4)
		mut ss := []GS{}
		mut next := 0
		for i in 0 .. 2 + r.n(5) {
			mut g := GS{
				id:    's${i}'
				w:     '${r.n(3)}'
				v:     if r.n(3) > 0 { 'v${r.n(5)}' } else { '' }
				v_in:  r.n(files)
				os_in: r.n(files)
			}
			for _ in 0 .. r.n(5) {
				g.os << GO{'o${next}', 'v${r.n(3)}'}
				next++
			}
			ss << g
		}
		mut parts := map[string]string{}
		for f in 0 .. files {
			parts['f${f}.xml'] = '<r>' + ss.map(it.xml_in(f)).join('') + '</r>'
		}
		old_set := set_from(parts)
		old := old_set.merge(rules) or { panic(err) }
		assert old.problems.len == 0, '${parts}'
		// random edits of the model
		for _ in 0 .. 1 + r.n(5) {
			k := r.n(ss.len)
			match r.n(8) {
				0 {
					ss[k].v = 'e${r.n(9)}'
				}
				1 {
					ss[k].w = 'e${r.n(9)}'
				}
				2 {
					if ss[k].os.len > 0 {
						ss[k].os.delete(r.n(ss[k].os.len))
					}
				}
				3 {
					ss[k].os.insert(r.n(ss[k].os.len + 1), GO{'n${next}', 'x'})
					next++
				}
				4 {
					if ss[k].os.len > 1 {
						o := ss[k].os[r.n(ss[k].os.len)]
						ss[k].os = ss[k].os.filter(it.id != o.id)
						ss[k].os.insert(r.n(ss[k].os.len + 1), o)
					}
				}
				5 {
					if ss[k].os.len > 0 {
						// to another s, perhaps in another file, changed on the way or not
						mut o := ss[k].os.pop()
						if r.n(2) == 0 {
							o.v = 'm${r.n(9)}'
						}
						t := r.n(ss.len)
						ss[t].os.insert(r.n(ss[t].os.len + 1), o)
					}
				}
				6 {
					ss << GS{
						id: 'new${next}'
						w:  '0'
						v:  'nv'
					}
					next++
				}
				else {
					if ss.len > 1 {
						ss.delete(k)
					}
				}
			}
		}
		new_xml := '<r>' + ss.map(it.xml()).join('') + '</r>'
		new_set := set_from({
			'new.xml': new_xml
		})
		new := new_set.merge(rules) or { panic(err) }
		d := diff(old, new)
		changes += d.changes.len
		mut me := d.apply() or { panic('round ${round}: ${err}\n${parts}\n${new_xml}') }
		out := written(mut me)
		after := set_from(out).merge(rules) or { panic(err) }
		mut again := diff(after, new)
		assert after.problems.len == 0 && again.equal(), 'round ${round}\n${parts}\n${new_xml}\n${out}\n${again.changes.map(again.describe(it))}'
		// a file no edit reached is written as it was, byte for byte
		edited := me.edited()
		for k, doc in old_set.docs {
			if k !in edited {
				assert out[doc.path] == parts[doc.path]
				untouched_files++
			} else {
				edited_files++
			}
		}
	}
	assert changes > 600 && edited_files > 300 && untouched_files > 100, '${changes} ${edited_files} ${untouched_files}'
}
