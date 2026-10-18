module flatxml

import os
import strings

fn parsed(s string) &Doc {
	return parse_string(s) or { panic('${err}\n${s}') }
}

fn attr_or(d &Doc, i u32, name string) string {
	return d.attr(i, name) or { '<none>' }
}

// written is the document written in mode, as a string.
fn written_as(d &Doc, mode WriteMode) string {
	mut sb := strings.new_builder(d.src_len)
	d.write(mut sb, mode: mode) or { panic(err) }
	return sb.str()
}

// canonical is the tree as text, one line per element and per run of text (the runs of one
// parent joined), as `flatxml dump` writes it: what a re-serialised document must keep.
fn canonical(d &Doc) string {
	mut sb := strings.new_builder(256)
	mut depth := []int{len: d.len()}
	mut run := ''
	mut run_depth := 0
	for k in 1 .. d.len() {
		i := u32(k)
		depth[k] = depth[d.parent[i]] + 1
		if d.is_text(i) {
			if run != '' && run_depth != depth[k] - 1 {
				sb.writeln('T ${run_depth} ${run}')
				run = ''
			}
			run += d.text(i)
			run_depth = depth[k] - 1
			continue
		}
		if run != '' {
			sb.writeln('T ${run_depth} ${run}')
			run = ''
		}
		sb.write_string('E ${depth[k]} ${d.name(i)}')
		lo, hi := d.attr_range(i)
		for a := lo; a < hi; a++ {
			sb.write_string(' ${d.attr_name(a)}=${d.attr_value(a)}')
		}
		sb.writeln('')
		if d.text_len[i] != 0 {
			sb.writeln('T ${depth[k]} ${d.text(i)}')
		}
	}
	if run != '' {
		sb.writeln('T ${run_depth} ${run}')
	}
	return sb.str()
}

// round_trips checks the three ways of writing s: verbatim and node by node give s, and the
// rewrite parses to the same tree.
fn round_trips(s string) {
	d := parsed(s)
	assert written_as(d, .verbatim) == s
	assert written_as(d, .nodes) == s
	again := parsed(written_as(d, .rewrite))
	if canonical(again) != canonical(d) {
		panic('rewrite differs:\n${written_as(d, .rewrite)}\n--- from\n${s}')
	}
	// every element's span is a whole element
	for k in 1 .. d.len() {
		lo, hi := d.span(u32(k))
		assert lo < hi
		if d.is_element(u32(k)) {
			assert s[lo] == `<` && s[hi - 1] == `>`
			// read on its own, an element's bytes are the same element
			alone := parsed(d.subtree_bytes(u32(k)))
			assert alone.name(1) == d.name(u32(k))
			assert alone.inner_xml(1) == d.inner_xml(u32(k))
		}
	}
}

fn test_round_trip_constructs() {
	cases := [
		'<a/>',
		'<a></a>',
		'<a ></a >',
		'<a/ >'.replace('/ >', '/>'),
		'<a>text</a>',
		'<a><![CDATA[<x>&y;]]></a>',
		'<a><![CDATA[]]></a>',
		'<a><![CDATA[   ]]></a>',
		'<a>one<![CDATA[ two ]]>three<!-- c -->four<?pi mid?>five</a>',
		'<a><!-- before -->text<!-- after --></a>',
		'<a><!-- only --></a>',
		'<a><?pi ?></a>',
		'<a> <b/> <!-- c --> <c>x</c>\n</a>',
		'<a>x<b/>y<c/>z</a>',
		'<a><b>bold</b> tail</a>',
		'<a k="1" j=\'2\' l = "3"  m=\'"\' n="\'"/>',
		'<a k="&lt;&amp;&quot;&#9;&#10;&#13;" v="tab\there\nnl"/>',
		'<a>&#65;&#x42;&lt;&gt;&amp;&apos;&quot;&#169;</a>',
		'<a>x]]&gt;y</a>',
		'<a>\r\nline\rtwo\r\n</a>\r\n',
		'\xEF\xBB\xBF<a/>',
		'<?xml version="1.0"?>\n<!DOCTYPE a [\n  <!ELEMENT a ANY>\n  <!-- a ] in a comment -->\n  <!ATTLIST a k CDATA "x>y">\n]>\n<!-- lead -->\n<?pi x?>\n<a/>\n<!-- trail -->\n<?pi y?>\n',
		'<a><b><c><d>deep</d></c><!-- c --></b>  </a>',
		'<a xmlns="urn:d" xmlns:p="urn:p"><p:b p:k="1"><c/></p:b></a>',
		'<a><b/><b></b><b>t</b><b><!-- x --></b></a>',
		'<a>\n  <b/>\n</a>\n\n',
		'<élément å="ä">ö</élément>',
		'<a><b k="/"/><c k=">"/></a>',
		'<a  >  </a  >',
		'<r><a>&#x20;</a><b>x<c/>&#10;</b></r>',
		'<a>&#9;&#32;<b/>&#13;&#10;<!-- c -->&#32;<c/>\t</a>',
	]
	for s in cases {
		round_trips(s)
	}
}

fn test_round_trip_testdata() {
	for f in os.walk_ext(os.join_path(@VMODROOT, 'testdata'), '.xml') {
		s := os.read_file(f) or { panic(err) }
		d := parse_string(s) or { continue } // the namespace error files parse; a non-XML file would not
		assert written_as(d, .verbatim) == s, f
		assert written_as(d, .nodes) == s, f
		again := parsed(written_as(d, .rewrite))
		assert canonical(again) == canonical(d), f
	}
}

fn test_spans_and_subtree_bytes() {
	s := '<?xml version="1.0"?>\n<r a="1">\n  <b>x</b>\n  <c><![CDATA[y]]></c>\n  <d/>\n  t<!-- c --></r >\n'
	d := parsed(s)
	assert d.subtree_bytes(0) == s
	assert d.subtree_bytes(1) == '<r a="1">\n  <b>x</b>\n  <c><![CDATA[y]]></c>\n  <d/>\n  t<!-- c --></r >'
	assert d.subtree_bytes(d.child_named(1, 'b')) == '<b>x</b>'
	assert d.subtree_bytes(d.child_named(1, 'c')) == '<c><![CDATA[y]]></c>'
	assert d.subtree_bytes(d.child_named(1, 'd')) == '<d/>'
	// the text after <d/> is a text node, its leading whitespace included
	t := d.next_sibling(d.child_named(1, 'd'))
	assert d.is_text(t)
	assert d.subtree_bytes(t) == '\n  t'
	m := parsed('<m>a<![CDATA[b]]>c</m>')
	assert m.children(1).map(m.subtree_bytes(it)) == ['a', '<![CDATA[b]]>', 'c']
}

fn test_write_file_replaces_its_own_source() {
	path := os.join_path(os.temp_dir(), 'flatxml_write_${os.getpid()}.xml')
	src := '<?xml version="1.0"?>\r\n<a k=\'1\'><!-- c --><b/></a>\r\n'
	os.write_file(path, src) or { panic(err) }
	defer {
		os.rm(path) or {}
	}
	os.chmod(path, 0o600) or { panic(err) }
	mut d := parse_file(path) or { panic(err) }
	d.write_file(path) or { panic(err) }
	d.write_file(path, mode: .nodes) or { panic(err) }
	// a new file, and one that cannot be made
	other := path + '.new'
	d.write_file(other) or { panic(err) }
	defer {
		os.rm(other) or {}
	}
	if _ := d.write_file(os.join_path(path + '.missing', 'x.xml')) {
		assert false, 'wrote into a directory that does not exist'
	}
	d.free()
	assert os.read_file(path) or { '' } == src
	assert os.read_file(other) or { '' } == src
	$if !windows {
		assert (os.stat(path) or { panic(err) }).mode & 0o777 == 0o600
	}
	assert os.ls(os.dir(path)) or { [] }.filter(it.starts_with(os.file_name(path)) && it.ends_with('.tmp')) == []
	// a new file gets the mode any new file gets
	plain := path + '.plain'
	os.write_file(plain, src) or { panic(err) }
	defer {
		os.rm(plain) or {}
	}
	$if !windows {
		assert (os.stat(other) or { panic(err) }).mode & 0o7777 == (os.stat(plain) or { panic(err) }).mode & 0o7777
	}
}

// Windows: a replaced file keeps its attributes (ReplaceFileW), and a read-only one is refused
// rather than replaced.
fn test_write_file_refuses_a_read_only_file_on_windows() {
	$if !windows {
		return
	}
	path := os.join_path(os.temp_dir(), 'flatxml_ro_${os.getpid()}.xml')
	os.write_file(path, '<a/>') or { panic(err) }
	defer {
		os.chmod(path, 0o666) or {}
		os.rm(path) or {}
	}
	os.chmod(path, 0o444) or { panic(err) }
	d := parsed('<b/>')
	d.write_file(path) or {
		assert err.msg().contains('read-only')
		assert os.read_file(path) or { '' } == '<a/>'
		return
	}
	assert false, 'replaced a read-only file'
}

fn test_write_file_through_a_link_writes_its_target() {
	$if windows {
		// a symbolic link needs a privilege a Windows account does not have by default
		return
	}
	dir := os.join_path(os.temp_dir(), 'flatxml_link_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	target := os.join_path(dir, 'target.xml')
	link := os.join_path(dir, 'link.xml')
	os.write_file(target, '<a/>') or { panic(err) }
	os.symlink(target, link) or { panic(err) }
	d := parsed('<b>new</b>')
	d.write_file(link) or { panic(err) }
	assert os.is_link(link)
	assert os.read_file(target) or { '' } == '<b>new</b>'
	assert os.ls(dir) or { [] }.len == 2
}

fn test_escaping() {
	assert escape_text('plain') == 'plain'
	assert escape_text('a < b && c > d\r\n') == 'a &lt; b &amp;&amp; c &gt; d&#13;\n'
	assert escape_attr('plain', `"`) == 'plain'
	assert escape_attr('say "hi" & \'bye\'', `"`) == "say &quot;hi&quot; &amp; 'bye'"
	assert escape_attr('say "hi" & \'bye\'', `'`) == 'say "hi" &amp; &apos;bye&apos;'
	assert escape_attr('t\tn\nr\r<', `"`) == 't&#9;n&#10;r&#13;&lt;'
	assert attr_quote('plain', `'`) == `'`
	assert attr_quote('has "', `"`) == `'`
	assert attr_quote("has '", `'`) == `"`
	assert attr_quote('both " \'', `"`) == `"`
	assert cdata_section('<x>&y;') == '<![CDATA[<x>&y;]]>'
	assert cdata_section('a]]>b') == '<![CDATA[a]]]]><![CDATA[>b]]>'
	assert cdata_section('a\rb') == '<![CDATA[a]]>&#13;<![CDATA[b]]>'
	// each reads back as what was escaped
	for v in ['a < b & "c" \'d\' \t\n\r e]]>', ']]>', '\r\n', ''] {
		d := parsed('<r a="${escape_attr(v, `"`)}" b=\'${escape_attr(v, `'`)}\'>${escape_text(v)}<c>${cdata_section(v)}</c></r>')
		assert attr_or(d, 1, 'a') == v
		assert attr_or(d, 1, 'b') == v
		if v != '' {
			assert d.text(d.first_child(1)) == v
		}
		c := d.child_named(1, 'c')
		assert d.text_content(c) == v
	}
}

fn test_outer_xml_carries_namespaces() {
	d := parsed('<a xmlns="urn:d" xmlns:p="urn:p" xmlns:q="urn:q"><b xmlns:q="urn:q2" k="1"><p:c q:x=\'say "hi"\'>t<![CDATA[<]]></p:c><e/></b></a>')
	b := d.child_named(1, 'b')
	assert d.outer_xml(b) == '<b xmlns="urn:d" xmlns:p="urn:p" xmlns:q="urn:q2" k="1"><p:c q:x=\'say "hi"\'>t<![CDATA[<]]></p:c><e/></b>'
	// read on its own, it has the namespaces it had in place
	mut alone := parsed(d.outer_xml(b))
	alone.resolve_namespaces() or { panic(err) }
	assert alone.ns_uri(alone.ns_of(1)) == 'urn:d'
	c := alone.child_named(1, 'p:c')
	assert alone.ns_uri(alone.ns_of(c)) == 'urn:p'
	lo, _ := alone.attr_range(c)
	assert alone.ns_uri(alone.attr_ns_of(lo)) == 'urn:q2'
	// the document node is the whole document
	whole := '<?xml version="1.0"?>\n<!-- c -->\n<r><!-- c --><a k="1"/></r>\n'
	w := parsed(whole)
	assert w.outer_xml(0) == written_as(w, .rewrite)
	assert w.outer_xml(0) == '<?xml version="1.0"?>\n<!-- c -->\n<r><a k="1"/></r>\n'
	// a text node is its text
	m := parsed('<m>a<x/>b &amp; c</m>')
	assert m.outer_xml(m.next_sibling(m.child_named(1, 'x'))) == 'b &amp; c'
}

// OnePlan writes one element anew and copies everything else, as an edit's plan would.
struct OnePlan {
	d       &Doc
	changed u32
}

fn (p OnePlan) how(i u32) How {
	if i == p.changed {
		return .write
	}
	// an ancestor of the changed element is walked, everything else copied
	if i < p.changed && p.changed < p.d.end[i] {
		return .content
	}
	return .whole
}

fn (p OnePlan) write(mut e Emitter, i u32) ! {
	e.put('<new k="${escape_attr('<&>', `"`)}">')!
	e.node_from_parts(i)!
	e.put('</new>')!
}

fn test_a_plan_writes_one_node_and_copies_the_rest() {
	s := '<?xml version="1.0"?>\n<r>\n  <!-- one -->\n  <a k=\'1\'>x</a>\n  <b>\n    <c  k = "2" >y &amp; z</c>\n    <d/>\n  </b>\n</r>\n'
	d := parsed(s)
	b := d.child_named(1, 'b')
	c := d.child_named(b, 'c')
	mut e := emitter_in(d, OnePlan{ d: d, changed: c }, 64)
	e.walk(0) or { panic(err) }
	e.settle() or { panic(err) }
	assert e.buf.str() == s.replace('<c  k = "2" >y &amp; z</c>', '<new k="&lt;&amp;&gt;"><c k="2">y &amp; z</c></new>')
}
