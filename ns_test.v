module flatxml

fn resolved(src string) &Doc {
	mut d := parse_string(src) or { panic(err) }
	d.resolve_namespaces() or { panic(err) }
	return d
}

fn ns_fails(src string) string {
	mut d := parse_string(src) or { return 'parse: ${err}' }
	d.resolve_namespaces() or { return err.msg() }
	return ''
}

// expanded_names lists every element as `{uri}local`, in document order.
fn expanded_names(d &Doc) []string {
	mut out := []string{}
	for k in 1 .. d.len() {
		i := u32(k)
		if d.is_element(i) {
			out << '{${d.ns_uri(d.ns_of(i))}}${d.local_name(i)}'
		}
	}
	return out
}

fn test_scopes_and_defaults() {
	d := resolved('<r xmlns="urn:a" xmlns:b="urn:b"><x/><b:y/><s xmlns="urn:c" xmlns:b="urn:b2"><x/><b:y/><t xmlns=""><x/></t></s><x/></r>')
	assert expanded_names(d) == ['{urn:a}r', '{urn:a}x', '{urn:b}y', '{urn:c}s', '{urn:c}x',
		'{urn:b2}y', '{}t', '{}x', '{urn:a}x']
}

fn test_attributes_take_no_default_namespace() {
	d := resolved('<r xmlns="urn:a" xmlns:p="urn:p" k="1" p:k="2"/>')
	lo, hi := d.attr_range(d.root())
	mut got := []string{}
	for a := lo; a < hi; a++ {
		if !d.is_ns_decl(a) {
			got << '{${d.ns_uri(d.attr_ns_of(a))}}${d.attr_local_name(a)}=${d.attr_value(a)}'
		}
	}
	assert got == ['{}k=1', '{urn:p}k=2']
	assert d.attr_ns_of(lo) == xmlns_ns
	assert d.attr_ns_of(lo + 1) == xmlns_ns
}

fn test_reserved_and_decoded() {
	d := resolved('<r xml:lang="en" xmlns:xml="http://www.w3.org/XML/1998/namespace" xmlns:e="urn:&amp;e"><e:x/></r>')
	lo, _ := d.attr_range(d.root())
	assert d.attr_ns_of(lo) == xml_ns
	assert d.attr_local_name(lo) == 'lang'
	assert d.ns_uri(d.ns_of(d.first_child(d.root()))) == 'urn:&e'
	assert d.ns_id('urn:&e')? == d.ns_of(d.first_child(d.root()))
	assert d.ns_id('urn:undeclared') == none
}

fn test_local_names_share_ids() {
	d := resolved('<a:x xmlns:a="urn:a" xmlns:b="urn:b"><b:x/><x/></a:x>')
	c := d.first_child(d.root())
	assert d.local_id(d.root()) == d.local_id(c)
	assert d.local_id(c) == d.local_id(d.next_sibling(c))
	assert d.ns_of(d.root()) != d.ns_of(c)
	assert d.ns_of(d.next_sibling(c)) == no_ns
}

// A document read without resolving namespaces is read exactly as before: prefixed names as
// written, and no namespace ids.
fn test_resolution_is_optional() {
	d := parse_string('<p:r xmlns:p="urn:p" p:k="1"/>') or { panic(err) }
	assert d.name(d.root()) == 'p:r'
	assert d.ns_of(d.root()) == no_ns
	assert d.ns.len == 0
	assert d.attr(d.root(), 'p:k')? == '1'
	// an unbound prefix is no error until namespaces are asked for
	u := parse_string('<p:r/>') or { panic(err) }
	assert u.name(u.root()) == 'p:r'
}

fn test_resolving_twice_is_harmless() {
	mut d := parse_string('<r xmlns="urn:a"/>') or { panic(err) }
	d.resolve_namespaces()!
	d.resolve_namespaces()!
	assert d.ns_uri(d.ns_of(d.root())) == 'urn:a'
}

fn test_errors() {
	assert ns_fails('<p:r/>').contains('the prefix of <p:r> is not bound to a namespace')
	assert ns_fails('<r p:x="1"/>').contains('the prefix of attribute p:x is not bound')
	assert ns_fails('<r xmlns:a="urn:a"><a:b:c/></r>').contains('<a:b:c> is not a qualified name')
	assert ns_fails('<r xmlns:a="urn:a"><a:/></r>').contains('<a:> is not a qualified name')
	assert ns_fails('<r :k="1"/>').contains('attribute :k is not a qualified name')
	assert ns_fails('<r xmlns:a:b="urn:x"/>').contains('attribute xmlns:a:b is not a qualified name')
	assert ns_fails('<r xmlns:xml="urn:x"/>').contains('the prefix xml must not be bound to another namespace')
	assert ns_fails('<r xmlns:a="http://www.w3.org/XML/1998/namespace"/>').contains('must not be bound to the prefix a')
	assert ns_fails('<r xmlns="http://www.w3.org/2000/xmlns/"/>').contains('must not be bound to the default namespace')
	assert ns_fails('<r xmlns:xmlns="urn:x"/>').contains('the prefix xmlns must not be declared')
	assert ns_fails('<r xmlns:a="urn:a"><s xmlns:a=""/></r>').contains('the prefix a must not be undeclared')
	assert ns_fails('<r xmlns:a="urn:x" xmlns:b="urn:x" a:k="1" b:k="2"/>').contains('attributes a:k and b:k have the same expanded name')
	assert ns_fails('<r><s xmlns:a="urn:a"/><a:u/></r>').contains('the prefix of <a:u> is not bound')
	// the position is the element's
	assert ns_fails('<r>\n  <p:x/></r>').starts_with('<string>:2:3: ')
}
