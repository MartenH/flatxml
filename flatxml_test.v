module flatxml

fn must(s string) &Doc {
	return parse_string(s) or { panic('${err}\n${s}') }
}

fn attr_of(d &Doc, i u32, name string) string {
	return d.attr(i, name) or { '<none>' }
}

fn id_of(d &Doc, name string) u32 {
	return d.name_id(name) or { 0 }
}

fn lc(pair_line int, pair_col int) string {
	return '${pair_line}:${pair_col}'
}

fn fails(s string) string {
	parse_string(s) or { return err.msg() }
	panic('parsed, expected an error: ${s}')
}

fn test_structure_is_preorder_with_end_links() {
	d := must('<a><b>x</b><c/><d><e/></d></a>')
	assert d.len() == 6 // document, a, b, c, d, e
	names := [u32(1), 2, 3, 4, 5].map(d.name(it))
	assert names == ['a', 'b', 'c', 'd', 'e']
	assert d.end[0] == 6
	assert d.end[1] == 6 // a holds everything
	assert d.end[2] == 3 // b is a leaf: its text lives on the element
	assert d.end[3] == 4
	assert d.end[4] == 6
	assert d.parent[5] == 4
	assert d.children(1) == [u32(2), 3, 4]
	assert d.first_child(3) == no_node
	assert d.next_sibling(4) == no_node
	assert d.child_named(1, 'd') == 4
	assert d.child_named(1, 'e') == no_node // a grandchild, not a child
	assert d.child_named(1, 'nope') == no_node
	assert d.text(2) == 'x'
	assert d.text_node_count() == 0
}

fn test_whitespace_between_tags_is_dropped() {
	d := must('<a>\n  <b>\n    x y \n  </b>\n</a>\n')
	assert d.len() == 3
	assert d.text(2) == '\n    x y \n  '
	assert d.text(1) == ''
}

fn test_mixed_content_gets_text_nodes_in_order() {
	d := must('<p>one <b>two</b> three<i/>four</p>')
	// p, #text, b, #text, i, #text
	assert d.len() == 7
	assert d.name(2) == '#text'
	assert d.text(2) == 'one '
	assert d.text(3) == 'two'
	assert d.text(4) == ' three'
	assert d.text(6) == 'four'
	assert d.text(1) == '' // mixed content: no text on the element itself
	assert d.text_content(1) == 'one two threefour'
	assert d.text_node_count() == 3
	assert d.children(1).map(d.name(it)) == ['#text', 'b', '#text', 'i', '#text']
}

fn test_text_split_by_a_comment_is_two_nodes() {
	d := must('<a>x<!-- c -->y</a>')
	assert d.children(1).map(d.text(it)) == ['x', 'y']
	assert d.text_content(1) == 'xy'
}

fn test_attributes() {
	d := must('<a  k="v"  q = \'it"s\' e="&lt;&#65;&#x42;&amp;" w="a\tb\nc\r\nd"/>')
	lo, hi := d.attr_range(1)
	assert hi - lo == 4
	assert d.attr_name(lo) == 'k'
	assert attr_of(d, 1, 'k') == 'v'
	assert attr_of(d, 1, 'q') == 'it"s'
	assert attr_of(d, 1, 'e') == '<AB&'
	assert d.attr_raw(lo + 2) == '&lt;&#65;&#x42;&amp;'
	assert attr_of(d, 1, 'w') == 'a b c d'
	assert attr_of(d, 1, 'missing') == '<none>'
}

fn test_attributes_belong_to_their_node() {
	d := must('<a x="1"><b/><c y="2" z="3">t</c><d/></a>')
	for i in 1 .. d.len() {
		lo, hi := d.attr_range(u32(i))
		mut got := []string{}
		for k := lo; k < hi; k++ {
			got << d.attr_name(k)
		}
		match d.name(u32(i)) {
			'a' {
				assert got == ['x']
			}
			'c' {
				assert got == ['y', 'z']
			}
			else {
				assert got.len == 0
			}
		}
	}
}

fn test_entities_and_line_endings_in_text() {
	d := must('<a>&lt;tag&gt; &quot;q&quot; &apos;s&apos; &#169; &#x1F600;\r\nend\rx</a>')
	assert d.text(1) == '<tag> "q" \'s\' © 😀\nend\nx'
	assert d.text_raw(1).starts_with('&lt;tag&gt;')
}

fn test_cdata_is_literal() {
	d := must('<a><![CDATA[x &amp; <y>]]></a>')
	assert d.text(1) == 'x &amp; <y>'
	assert d.is_cdata(1)
	d2 := must('<a>pre<![CDATA[  ]]>post</a>')
	assert d2.children(1).map(d2.text(it)) == ['pre', '  ', 'post']
	assert !d2.is_cdata(2)
	assert d2.is_cdata(3)
}

fn test_prolog_and_epilog_are_skipped() {
	d := must('\xEF\xBB\xBF<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE a [ <!ELEMENT a (#PCDATA)> ]>\n<!-- c --><a>x</a>\n<!-- after --><?pi tail?>\n')
	assert d.len() == 2
	assert d.name(1) == 'a'
	assert d.text(1) == 'x'
}

fn test_doctype_subset_may_hold_brackets_in_comments_and_quotes() {
	d := must('<!DOCTYPE r [ <!-- ] --> <?pi ]?> <!ATTLIST r a CDATA "]>"> ]><r/>')
	assert d.len() == 2
	assert d.name(1) == 'r'
}

fn test_comment_edge_cases() {
	assert must('<a><!----></a>').len() == 2
	assert must('<a><!-- -- > still in comment --></a>').len() == 2
	assert fails('<a><!--></a>').contains('comment is not closed')
	assert fails('<a><!---></a>').contains('comment is not closed')
}

fn test_names_are_interned_once() {
	d := must('<r><x/><x/><y x="1"/></r>')
	assert d.tag[2] == d.tag[3]
	assert d.names.len == 2 + 3 // #text, #document, r, x, y
	assert d.attr_tag[0] == d.tag[2] // the attribute x and the element x share an id
	assert id_of(d, 'y') == d.tag[4]
	assert id_of(d, 'z') == 0
}

fn test_many_names_grow_the_table() {
	mut s := '<r>'
	for k in 0 .. 3000 {
		s += '<n${k}/>'
	}
	s += '</r>'
	d := must(s)
	assert d.names.len == 2 + 1 + 3000
	for k in 0 .. 3000 {
		assert d.name(u32(2 + k)) == 'n${k}'
		assert id_of(d, 'n${k}') == d.tag[2 + k]
	}
}

fn test_positions() {
	d := must('<a>\n  <b/>\n  <c\n x="1"/></a>')
	for i, want in ['1:1', '2:3', '3:3'] {
		l, c := d.line_col(u32(i + 1))
		assert lc(l, c) == want
	}
	li := d.line_index()
	l3, c3 := li.line_col(d.src_off[3])
	assert lc(l3, c3) == '3:3'
	l0, c0 := li.line_col(0)
	assert lc(l0, c0) == '1:1'
}

fn test_errors_name_the_position() {
	assert fails('<a><b></a>') == '<string>:1:7: end tag </a> does not match <b> at 1:4'
	assert fails('<a>\n<b>').contains('<string>:2:1: element <b> is not closed')
	assert fails('<a/><b/>').contains('more than one root element')
	assert fails('x<a/>').contains('text outside the root element')
	assert fails('<a/>x').contains('text outside the root element')
	assert fails('').contains('no root element')
	assert fails('  <!-- only -->  ').contains('no root element')
	assert fails('</a>').contains('without a start tag')
	assert fails('<a>&nope;</a>').contains('unknown entity')
	assert fails('<a>&#0;</a>').contains('invalid character reference')
	assert fails('<a>AT&T</a>').contains('does not start an entity reference')
	assert fails('<a x="1"y="2"/>').contains('expected whitespace')
	assert fails('<a x=1/>').contains('expected a quoted value')
	assert fails('<a x="<"/>').contains('`<` in the value')
	assert fails('<a x/>').contains('expected `=`')
	assert fails('<a><![CDATA[x</a>').contains('CDATA section is not closed')
	assert fails('<a><?pi </a>').contains('processing instruction is not closed')
	assert fails('<a><!x></a>').contains('expected `<!--`')
	assert fails('<a></ab>').contains('does not match <a>')
	assert fails('<ab></a>').contains('does not match <ab>')
	assert fails('<a></a').contains('expected `>`')
	assert fails('<>').contains('expected a name')
	assert fails('<a><').contains('unexpected end of input')
	assert fails('<a/><!DOCTYPE a>').contains('DOCTYPE after the root element')
}

const sample = '<?xml version="1.0"?>
<!-- header -->
<catalog xmlns="urn:example:catalog">
  <item-groups>
    <item-group id="1">
      <item-name>P</item-name>
      <items>
        <x><item-name>x</item-name><desc><l-2 lang="en">a &lt;b&gt; <![CDATA[c]]> d</l-2></desc></x>
        <y ref=\'x\'>/P/x</y>
      </items>
    </item-group>
  </item-groups>
</catalog>
'

// Every prefix of a document either parses or fails with a message; none may crash or read
// past the end. Prefixes that end after the root closed are complete documents.
fn test_every_prefix_is_handled() {
	full := must(sample)
	mut ok := 0
	for k in 0 .. sample.len {
		bytes := sample[..k].bytes()
		if d := parse_bytes(bytes, 'prefix') {
			assert d.len() == full.len()
			ok++
		}
	}
	assert ok == 1 // only the prefix that drops the final newline is still complete
}
