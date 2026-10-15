module flatxml

import os

fn write_files(files map[string]string) []string {
	dir := os.join_path(os.vtmp_dir(), 'flatxml_set_test_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	mut paths := []string{}
	for name, body in files {
		p := os.join_path(dir, name)
		os.write_file(p, body) or { panic(err) }
		paths << p
	}
	return paths
}

fn test_a_set_shares_one_name_table() {
	paths := write_files({
		'a.xml': '<r><x/><y k="1"/></r>'
		'b.xml': '<r><y k="2"/><z/></r>'
		'c.xml': '<q><z/><x/></q>'
	})
	for jobs in [1, 3] {
		mut s := DocSet.new()
		errs := s.load(paths, jobs: jobs)
		assert errs.len == 0
		assert s.docs.len == 3
		x := s.name_id('x') or { panic('no x') }
		z := s.name_id('z') or { panic('no z') }
		// the same name has one id in every document, and the documents keep the order given
		assert s.docs[0].tag[2] == x && s.docs[2].tag[3] == x
		assert s.docs[1].tag[3] == z && s.docs[2].tag[2] == z
		assert s.docs[0].attr_tag[0] == s.docs[1].attr_tag[0]
		assert s.docs[2].root_node().name() == 'q'
		assert s.docs[1].root_node().child('y').attr('k') == '2'
		s.free()
	}
}

fn test_a_file_that_fails_is_reported_and_the_rest_load() {
	paths := write_files({
		'good.xml': '<r/>'
		'bad.xml':  '<r><x></r>'
	})
	mut s := DocSet.new()
	errs := s.load(paths)
	assert s.docs.len == 1
	assert errs.len == 1
	assert errs[0].path.ends_with('bad.xml')
	missing := s.load(['/nonexistent/flatxml.xml'])
	assert missing.len == 1
}

fn test_namespaces_are_shared_too() {
	paths := write_files({
		'n1.xml': '<a:r xmlns:a="urn:one" xmlns:b="urn:two"><b:x/></a:r>'
		'n2.xml': '<r xmlns="urn:two"><x/></r>'
	})
	mut s := DocSet.new()
	assert s.load(paths, namespaces: true, jobs: 2).len == 0
	d1, d2 := s.docs[0], s.docs[1]
	two := d1.ns_id('urn:two') or { panic('no urn:two') }
	assert d1.ns_of(2) == two && d2.ns_of(1) == two && d2.ns_of(2) == two
	// a local name has one id too, prefixed or not
	assert d1.local_id(2) == d2.local_id(2)
	assert d1.local_name(1) == 'r'
}

fn test_a_document_parsed_alone_joins_a_set() {
	mut s := DocSet.new()
	mut a := parse_string('<r><x/></r>') or { panic(err) }
	mut b := parse_string('<s><x/></s>') or { panic(err) }
	s.add(mut a)
	s.add(mut b)
	assert a.tag[2] == b.tag[2]
	assert a.name(2) == 'x' && b.name(1) == 's'
	// a name only one document uses is known to the set
	assert s.name_id('s') or { 0 } == b.tag[1]
}

fn test_handles() {
	d := parse_string('<r><a n="1">7</a><!-- c --><b on="true"> 2.5 </b><a n="2"><c>deep</c></a></r>') or {
		panic(err)
	}
	r := d.root_node()
	assert r.name() == 'r' && r.ok()
	assert r.child('a').attr('n') == '1'
	assert r.child('a').int(0) == 7
	assert r.child('b').f64(0) == 2.5
	assert r.child('b').attr_bool('on', false)
	assert r.child('a').next().name() == 'b'
	assert r.first().next().next().attr_int('n', 0) == 2
	// a missing node is an empty handle all the way down
	none_ := r.child('nope').child('x').child('y')
	assert !none_.ok() && none_.name() == '' && none_.attr('k') == '' && none_.int(-1) == -1
	assert r.child('b').int(-1) == -1 // 2.5 is not an integer
	assert r.parent().ok() == false
	assert r.child('a').parent().name() == 'r'
	mut names := []string{}
	for c in r.children() {
		names << c.name()
	}
	assert names == ['a', 'b', 'a']
	mut ns := []string{}
	for c in r.children_named('a') {
		ns << c.attr('n')
	}
	assert ns == ['1', '2']
	mut deep := 0
	for _ in r.descendants('c') {
		deep++
	}
	assert deep == 1
	for _ in r.children_named('nope') {
		assert false
	}
}

fn test_paths() {
	d := parse_string('<r><a><b>1</b></a><a><b>2</b><b>3</b></a><c><b>x</b></c></r>') or { panic(err) }
	r := d.root_node()
	assert r.at('a/b').text() == '1'
	assert r.at('c/b').text() == 'x'
	assert !r.at('a/z').ok() && !r.at('nope/b').ok()
	p := d.tab.path('a/b')
	assert r.find_all(p).map(it.text()) == ['1', '2', '3']
	// a later a is searched when the first has no match
	d2 := parse_string('<r><a/><a><b>found</b></a></r>') or { panic(err) }
	assert d2.root_node().at('a/b').text() == 'found'
}

fn test_review_cases() {
	// a path compiled against one table finds by name in a document with another
	d1 := parse_string('<r><a><b>1</b></a></r>') or { panic(err) }
	d2 := parse_string('<r><x/><y/><b/><a><b>2</b></a></r>') or { panic(err) }
	p := d1.tab.path('a/b')
	assert d2.root_node().find(p).text() == '2'
	// ... and one compiled before the names it needs were loaded finds them after
	mut s := DocSet.new()
	early := s.tab.path('a/b')
	mut d3 := parse_string('<r><a><b>3</b></a></r>') or { panic(err) }
	s.add(mut d3)
	assert d3.root_node().find(early).text() == '3'
	// adding a member again gives its number, not a second entry
	assert s.add(mut d3) == 0 && s.docs.len == 1
	// numbers in XML's forms only
	d := parse_string('<r><a>1_000</a><b>nan</b><c> -1.5e3 </c><d>.5</d><e>1e</e></r>') or { panic(err) }
	r := d.root_node()
	assert r.child('a').f64(-1) == -1 && r.child('b').f64(-1) == -1 && r.child('e').f64(-1) == -1
	assert r.child('c').f64(0) == -1500 && r.child('d').f64(0) == 0.5
	// text_tag means any element, never a text node
	m := parse_string('<r>t<b k="&amp;"/>u</r>') or { panic(err) }
	assert m.root_node().child_id(text_tag).name() == 'b'
	mut all := 0
	for _ in m.root_node().descendants_id(text_tag) {
		all++
	}
	assert all == 1
	assert m.root_node().child('b').has_attr('k') && !m.root_node().child('b').has_attr('z')
}
