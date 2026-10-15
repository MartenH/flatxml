module xsd

import flatxml
import os

const tns = 'urn:test'

const head = '<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:t="urn:test" targetNamespace="urn:test" elementFormDefault="qualified">'

fn tmp_dir() string {
	dir := os.join_path(os.vtmp_dir(), 'xsd_test_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	return dir
}

fn write_schema(name string, body string) string {
	path := os.join_path(tmp_dir(), name)
	os.write_file(path, body) or { panic(err) }
	return path
}

fn compile(body string) !&Schema {
	return load(write_schema('s.xsd', head + body + '</xs:schema>'))
}

fn fails(body string) string {
	compile(body) or { return err.msg() }
	return ''
}

fn local_of(s &Schema, q QName) string {
	return s.names[q.local]
}

const sample = '
  <xs:element name="root">
    <xs:annotation><xs:appinfo source="tags">kind=root</xs:appinfo></xs:annotation>
    <xs:complexType>
      <xs:sequence>
        <xs:element name="a" type="xs:string"/>
        <xs:choice minOccurs="0" maxOccurs="unbounded">
          <xs:element name="b" type="t:Level"/>
          <xs:group ref="t:G" maxOccurs="2"/>
        </xs:choice>
        <xs:element ref="t:shared" minOccurs="0"/>
        <xs:element name="v" type="t:Valued"/>
      </xs:sequence>
      <xs:attribute name="id" type="xs:NMTOKEN" use="required"/>
      <xs:attributeGroup ref="t:Common"/>
    </xs:complexType>
  </xs:element>
  <xs:element name="shared" type="xs:double"/>
  <xs:group name="G">
    <xs:sequence>
      <xs:element name="c" type="xs:unsignedInt"/>
      <xs:element name="d" form="unqualified" type="xs:string"/>
    </xs:sequence>
  </xs:group>
  <xs:attributeGroup name="Common">
    <xs:attribute name="note" type="xs:string"/>
    <xs:attributeGroup ref="t:More"/>
  </xs:attributeGroup>
  <xs:attributeGroup name="More">
    <xs:attribute ref="t:global"/>
  </xs:attributeGroup>
  <xs:attribute name="global" type="xs:string"/>
  <xs:simpleType name="Level">
    <xs:restriction base="xs:string">
      <xs:enumeration value="LOW"><xs:annotation><xs:appinfo source="v">low one</xs:appinfo></xs:annotation></xs:enumeration>
      <xs:enumeration value="HIGH"/>
      <xs:pattern value="[A-Z]+"/>
      <xs:whiteSpace value="collapse"/>
      <xs:maxLength value="8"/>
    </xs:restriction>
  </xs:simpleType>
  <xs:complexType name="Base">
    <xs:simpleContent>
      <xs:extension base="xs:string"><xs:attribute name="dest" type="xs:NMTOKEN"/></xs:extension>
    </xs:simpleContent>
  </xs:complexType>
  <xs:complexType name="Valued">
    <xs:simpleContent>
      <xs:extension base="t:Base"><xs:attribute name="unit" type="xs:string"/></xs:extension>
    </xs:simpleContent>
  </xs:complexType>
'

fn test_compiles_the_supported_constructs() {
	s := compile(sample)!
	root := s.element(tns, 'root')?
	assert s.elements[root].global
	ct := s.complex_types[s.elements[root].typ.idx]
	assert s.elements[root].typ.kind == .complex
	assert ct.content == .element_only
	// sequence(a, choice*(b, G{0..2}), shared?, v)
	seq := s.particles[ct.particle]
	assert seq.kind == .sequence && seq.min == 1 && seq.max == 1
	kids := s.particle_children(ct.particle)
	assert kids.len == 4
	a := s.particles[kids[0]]
	assert a.kind == .element && local_of(s, s.elements[a.term].name) == 'a'
	assert s.elements[a.term].typ == TypeRef{.builtin, u32(Builtin.string)}
	assert s.uris[s.elements[a.term].name.ns] == tns
	choice := s.particles[kids[1]]
	assert choice.kind == .choice && choice.min == 0 && choice.max == unbounded
	alts := s.particle_children(kids[1])
	assert s.elements[s.particles[alts[0]].term].typ.kind == .simple
	g := s.particles[alts[1]]
	assert g.kind == .sequence && g.max == 2
	gkids := s.particle_children(alts[1])
	assert s.elements[s.particles[gkids[1]].term].name.ns == 0 // form="unqualified"
	shared := s.particles[kids[2]]
	assert shared.min == 0 && shared.term == s.element(tns, 'shared')?
	// attributes: id, then the groups' note and global
	names := ct.attrs.map(local_of(s, s.attributes[it.decl].name))
	assert names == ['id', 'note', 'global']
	assert ct.attrs[0].required && !ct.attrs[1].required
	assert s.uris[s.attributes[ct.attrs[2].decl].name.ns] == tns // a global attribute
	assert s.attributes[ct.attrs[1].decl].name.ns == 0 // unqualified by default
}

fn test_simple_types_and_extension() {
	s := compile(sample)!
	level := s.simple_types[s.simple_type_named(tns, 'Level')?]
	assert level.base == TypeRef{.builtin, u32(Builtin.string)}
	assert level.enums == ['LOW', 'HIGH']
	assert level.patterns == ['[A-Z]+']
	assert level.white_space == .collapse
	assert level.max_length == 8
	valued := s.complex_types[s.complex_type_named(tns, 'Valued')?]
	assert valued.content == .simple
	assert valued.simple == TypeRef{.builtin, u32(Builtin.string)}
	assert valued.attrs.map(local_of(s, s.attributes[it.decl].name)) == ['dest', 'unit']
}

fn test_appinfo_is_kept_with_its_owner() {
	s := compile(sample)!
	root := s.element(tns, 'root')?
	level := s.simple_type_named(tns, 'Level')?
	assert s.appinfo.len == 2
	assert s.appinfo[0].owner == .element && s.appinfo[0].idx == root
	assert s.appinfo[0].source == 'tags' && s.appinfo[0].text == 'kind=root'
	assert s.appinfo[1].owner == .enumeration && s.appinfo[1].idx == level
	assert s.appinfo[1].sub == 0 && s.appinfo[1].text == 'low one'
}

fn test_import() {
	other := write_schema('other.xsd', '<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema" targetNamespace="urn:other"><xs:simpleType name="Code"><xs:restriction base="xs:token"/></xs:simpleType></xs:schema>')
	main := write_schema('main.xsd', head + '<xs:import namespace="urn:other" schemaLocation="other.xsd"/><xs:element name="r" type="o:Code" xmlns:o="urn:other"/></xs:schema>')
	s := load(main)!
	assert s.files.len == 2
	r := s.elements[s.element(tns, 'r')?]
	assert r.typ.kind == .simple
	assert s.simple_types[r.typ.idx].base == TypeRef{.builtin, u32(Builtin.token)}
	assert os.file_name(other) == 'other.xsd'
	wrong := write_schema('wrong.xsd', head + '<xs:import namespace="urn:else" schemaLocation="other.xsd"/></xs:schema>')
	load(wrong) or { assert err.msg().contains('has target namespace "urn:other", not "urn:else"') }
}

fn test_refuses_what_is_not_supported() {
	cases := {
		'<xs:complexType name="X"><xs:all><xs:element name="a" type="xs:string"/></xs:all></xs:complexType>':                             'xsd:all is not supported'
		'<xs:complexType name="X"><xs:sequence><xs:any/></xs:sequence></xs:complexType>':                                                 'xsd:any is not supported'
		'<xs:complexType name="X"><xs:anyAttribute/></xs:complexType>':                                                                   'xsd:anyAttribute is not supported'
		'<xs:complexType name="X"><xs:complexContent><xs:extension base="t:Y"/></xs:complexContent></xs:complexType>':                    'xsd:complexContent is not supported'
		'<xs:simpleType name="X"><xs:union memberTypes="xs:string"/></xs:simpleType>':                                                   'xsd:union is not supported'
		'<xs:simpleType name="X"><xs:list itemType="xs:string"/></xs:simpleType>':                                                       'xsd:list is not supported'
		'<xs:simpleType name="X"><xs:restriction base="xs:int"><xs:minInclusive value="1"/></xs:restriction></xs:simpleType>':           'xsd:minInclusive is not supported'
		'<xs:include schemaLocation="x.xsd"/>':                                                                                            'xsd:include is not supported'
		'<xs:element name="e" type="xs:string"><xs:unique name="u"><xs:selector xpath="."/><xs:field xpath="."/></xs:unique></xs:element>': 'xsd:unique is not supported'
		'<xs:element name="e" type="xs:string" nillable="true"/>':                                                                        'nillable on xsd:element is not supported'
		'<xs:element name="e" type="xs:string" substitutionGroup="t:f"/>':                                                                'substitutionGroup on xsd:element is not supported'
		'<xs:element name="e" type="xs:string" default="x"/>':                                                                            'default on xsd:element is not supported'
		'<xs:attribute name="a" type="xs:string" fixed="x"/>':                                                                            'fixed on xsd:attribute is not supported'
		'<xs:complexType name="X"><xs:attribute name="a" use="prohibited"/></xs:complexType>':                                           'use="prohibited" is not supported'
		'<xs:element name="e" type="xs:anyType"/>':                                                                                       'xsd:anyType is not supported'
		'<xs:element name="e"/>':                                                                                                          'xsd:anyType is not supported'
		'<xs:complexType name="X" block="extension"/>':                                                                                   'block on xsd:complexType is not supported'
	}
	for body, want in cases {
		got := fails(body)
		assert got.contains(want), '${body}\n  got: ${got}'
	}
}

fn test_compile_errors() {
	cases := {
		'<xs:element name="e" type="t:Missing"/>':                                                                    'type {urn:test}Missing is not declared'
		'<xs:complexType name="X"><xs:group ref="t:Missing"/></xs:complexType>':                                      'group {urn:test}Missing is not declared'
		'<xs:complexType name="X"><xs:sequence><xs:element ref="t:missing"/></xs:sequence></xs:complexType>':       'element {urn:test}missing is not declared'
		'<xs:complexType name="X"><xs:attribute ref="t:missing"/></xs:complexType>':                                  'attribute {urn:test}missing is not declared'
		'<xs:complexType name="X"><xs:attributeGroup ref="t:Missing"/></xs:complexType>':                             'attribute group {urn:test}Missing is not declared'
		'<xs:complexType name="X"/><xs:simpleType name="X"><xs:restriction base="xs:string"/></xs:simpleType>':     'type {urn:test}X is declared twice'
		'<xs:element name="e" type="xs:string"/><xs:element name="e" type="xs:string"/>':                            'element {urn:test}e is declared twice'
		'<xs:group name="G"><xs:sequence><xs:group ref="t:G"/></xs:sequence></xs:group>':                             'contains itself'
		'<xs:attributeGroup name="A"><xs:attributeGroup ref="t:A"/></xs:attributeGroup><xs:complexType name="X"><xs:attributeGroup ref="t:A"/></xs:complexType>': 'includes itself'
		'<xs:complexType name="X"><xs:simpleContent><xs:extension base="t:X"/></xs:simpleContent></xs:complexType>': 'extends itself'
		'<xs:complexType name="X"><xs:attribute name="a"/><xs:attribute name="a"/></xs:complexType>':                 'attribute a appears twice in type {urn:test}X'
		'<xs:complexType name="X"><xs:sequence minOccurs="2" maxOccurs="1"/></xs:complexType>':                       'minOccurs is greater than maxOccurs'
		'<xs:complexType name="X"><xs:sequence maxOccurs="many"/></xs:complexType>':                                  'maxOccurs must be a non-negative integer or unbounded'
		'<xs:element name="e" type="q:T"/>':                                                                          'the prefix of "q:T" is not bound'
		'<xs:element name="e" type="xs:nonsense"/>':                                                                  'xsd:nonsense is not a built-in type'
		'<xs:attribute name="a" type="t:X"/><xs:complexType name="X"/>':                                              'is a complex type; a simple type is needed here'
		'<xs:element name="e" type="xs:string">text</xs:element>':                                                    'text in xsd:element'
		'<xs:complexType name="X"><xs:simpleContent><xs:extension base="t:Y"/></xs:simpleContent></xs:complexType><xs:complexType name="Y"/>': 'which has no simple content'
	}
	for body, want in cases {
		got := fails(body)
		assert got.contains(want), '${body}\n  got: ${got}'
	}
}

fn test_errors_name_the_position() {
	got := fails('\n<xs:element name="e" type="t:Missing"/>')
	assert got.contains('s.xsd:2:1: '), got
}

fn test_not_a_schema() {
	load(write_schema('x.xsd', '<schema/>')) or { assert err.msg().contains('the root element is not xsd:schema') }
}

fn test_refuses_conditional_inclusion() {
	got := fails('<xs:element name="e" type="xs:string" vc:minVersion="1.1" xmlns:vc="http://www.w3.org/2007/XMLSchema-versioning"/>')
	assert got.contains('vc:minVersion (conditional inclusion) is not supported'), got
}

fn test_imports_that_are_not_there_are_skipped() {
	s := compile('<xs:import namespace="urn:x" schemaLocation="http://example.org/x.xsd"/><xs:import namespace="urn:y" schemaLocation="missing.xsd"/>')!
	assert s.notes.len == 2
	assert s.notes[0].contains('import of http://example.org/x.xsd skipped')
	assert fails('<xs:import namespace="urn:x" schemaLocation="missing.xsd"/><xs:element name="e" type="x:T" xmlns:x="urn:x"/>').contains('type {urn:x}T is not declared')
}

fn test_xml_attributes_are_built_in() {
	s := compile('<xs:complexType name="X"><xs:attribute ref="xml:space"/><xs:attribute ref="xml:lang"/></xs:complexType>')!
	ct := s.complex_types[s.complex_type_named(tns, 'X')?]
	space := s.attributes[ct.attrs[0].decl]
	assert s.uris[space.name.ns] == xml_ns_uri
	assert s.simple_types[space.typ.idx].enums == ['default', 'preserve']
	assert fails('<xs:complexType name="X"><xs:attribute ref="xml:other"/></xs:complexType>').contains('attribute {http://www.w3.org/XML/1998/namespace}other is not declared')
}

fn test_occurrence_counts_of_any_size() {
	s := compile('<xs:complexType name="X"><xs:sequence><xs:element name="a" type="xs:string" minOccurs="79228162514244337593543950335" maxOccurs="79228162514264337593543950335"/><xs:element name="b" type="xs:string" maxOccurs="+0099"/></xs:sequence></xs:complexType>')!
	kids := s.particle_children(s.complex_types[0].particle)
	assert s.particles[kids[0]].min == count_cap && s.particles[kids[0]].max == count_cap
	assert s.particles[kids[1]].max == 99
	assert fails('<xs:complexType name="X"><xs:sequence><xs:element name="a" type="xs:string" minOccurs="79228162514264337593543950336" maxOccurs="79228162514264337593543950335"/></xs:sequence></xs:complexType>').contains('minOccurs is greater than maxOccurs')
}

fn test_review_cases() {
	// simple types that derive from each other
	assert fails('<xs:simpleType name="A"><xs:restriction base="t:B"/></xs:simpleType><xs:simpleType name="B"><xs:restriction base="t:A"/></xs:simpleType>').contains('derives from itself')
	assert fails('<xs:simpleType name="A"><xs:restriction base="t:A"/></xs:simpleType>').contains('derives from itself')
	// a maxLength past 2^31 is clamped, not wrapped; one maxLength per restriction
	s := compile('<xs:simpleType name="L"><xs:restriction base="xs:string"><xs:maxLength value="2147483648"/></xs:restriction></xs:simpleType>')!
	assert s.simple_types[0].max_length == max_i32
	assert fails('<xs:simpleType name="L"><xs:restriction base="xs:string"><xs:maxLength value="++5"/></xs:restriction></xs:simpleType>').contains('maxLength must be a non-negative integer')
	assert fails('<xs:simpleType name="L"><xs:restriction base="xs:string"><xs:maxLength value="5"/><xs:maxLength value="6"/></xs:restriction></xs:simpleType>').contains('xsd:maxLength appears twice')
	// a shared attribute group reached through two others counts once
	d := compile('<xs:attributeGroup name="C"><xs:attribute name="c"/></xs:attributeGroup><xs:attributeGroup name="G1"><xs:attributeGroup ref="t:C"/></xs:attributeGroup><xs:attributeGroup name="G2"><xs:attributeGroup ref="t:C"/></xs:attributeGroup><xs:complexType name="T"><xs:attributeGroup ref="t:G1"/><xs:attributeGroup ref="t:G2"/></xs:complexType>')!
	assert d.complex_types[d.complex_type_named(tns, 'T')?].attrs.len == 1
	// order: the content model before attributes, an annotation first
	assert fails('<xs:complexType name="X"><xs:attribute name="a"/><xs:sequence/></xs:complexType>').contains('the content model comes before the attributes')
	assert fails('<xs:complexType name="X"><xs:sequence/><xs:annotation/></xs:complexType>').contains('xsd:annotation comes first')
	// an import with no location leaves a note
	n := compile('<xs:import namespace="urn:x"/>')!
	assert n.notes[0].contains('has no schemaLocation')
}

fn test_appinfo_owners_and_markup() {
	s := compile('<xs:element name="shared" type="xs:string"/><xs:attribute name="g" type="xs:string"/><xs:attributeGroup name="A"><xs:attribute name="a"/></xs:attributeGroup>
	<xs:complexType name="X">
	  <xs:sequence><xs:annotation><xs:appinfo>seq</xs:appinfo></xs:annotation>
	    <xs:element ref="t:shared"><xs:annotation><xs:appinfo>ref</xs:appinfo></xs:annotation></xs:element>
	  </xs:sequence>
	  <xs:attribute ref="t:g"><xs:annotation><xs:appinfo>use</xs:appinfo></xs:annotation></xs:attribute>
	  <xs:attributeGroup ref="t:A"><xs:annotation><xs:appinfo><tag k="v">x &amp; y</tag></xs:appinfo></xs:annotation></xs:attributeGroup>
	</xs:complexType>')!
	x := s.complex_type_named(tns, 'X')?
	seq := s.complex_types[x].particle
	assert s.appinfo.len == 4
	assert s.appinfo[0].owner == .particle && s.appinfo[0].idx == s.particle_children(seq)[0]
	assert s.appinfo[0].text == 'ref'
	assert s.appinfo[1].owner == .particle && s.appinfo[1].idx == seq
	assert s.appinfo[2].owner == .attribute_use && s.appinfo[2].idx == x && s.appinfo[2].sub == 0
	assert s.appinfo[3].owner == .attribute_group_ref && s.appinfo[3].idx == x
	assert s.appinfo[3].text == '<tag k="v">x &amp; y</tag>'
}

// The paths of imported documents are copies: they outlive the documents, which load releases.
fn test_file_paths_outlive_the_documents() {
	other := write_schema('abs.xsd', '<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema" targetNamespace="urn:abs"/>')
	s := load(write_schema('imp.xsd', head + '<xs:import namespace="urn:abs" schemaLocation="${other}"/></xs:schema>'))!
	assert s.files[1] == other
}

// --- the typing pass ---------------------------------------------------------------------

const vschema = '
  <xs:element name="order">
    <xs:complexType>
      <xs:sequence>
        <xs:element name="id" type="xs:string"/>
        <xs:element name="line" type="t:Line" maxOccurs="unbounded"/>
        <xs:element name="note" type="t:Note" minOccurs="0"/>
        <xs:element name="plain" form="unqualified" type="xs:string" minOccurs="0"/>
        <xs:element name="abstract" type="t:Abstract" minOccurs="0"/>
      </xs:sequence>
      <xs:attribute name="state" type="xs:string" use="required"/>
      <xs:attribute name="extra" type="xs:string"/>
    </xs:complexType>
  </xs:element>
  <xs:complexType name="Line">
    <xs:sequence><xs:element name="qty" type="xs:unsignedInt"/></xs:sequence>
    <xs:attribute name="sku" type="xs:string" use="required"/>
  </xs:complexType>
  <xs:complexType name="Note" mixed="true">
    <xs:sequence><xs:element name="b" type="xs:string" minOccurs="0"/></xs:sequence>
  </xs:complexType>
  <xs:complexType name="Abstract" abstract="true"/>
'

fn check(doc string) !Validation {
	s := compile(vschema)!
	mut d := flatxml.parse_string(doc)!
	return validate(mut d, s)
}

fn kinds(v Validation) []FindingKind {
	return v.findings.map(it.kind)
}

const ok_doc = '<order xmlns="urn:test" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="urn:test o.xsd" state="new">
  <id>A1</id>
  <line sku="x"><qty>2</qty></line>
  <line sku="y"><qty>3</qty></line>
  <note>some <b>bold</b> text</note>
  <plain xmlns="">p</plain>
</order>'

fn test_a_valid_document() {
	v := check(ok_doc)!
	assert v.valid(), v.findings.str()
	// every element has its declaration
	s := compile(vschema)!
	mut d := flatxml.parse_string(ok_doc)!
	w := validate(mut d, s)!
	assert w.declared(d.root())? == s.element(tns, 'order')?
	line := d.next_sibling(d.first_child(d.root()))
	assert s.names[s.elements[w.declared(line)?].name.local] == 'line'
}

fn test_undeclared_elements_are_reported_once_per_subtree() {
	v := check('<order xmlns="urn:test" state="s"><id>1</id><bogus><deep><deeper/></deep></bogus></order>')!
	assert kinds(v) == [.undeclared_element]
	assert v.findings[0].msg == '<bogus> is not allowed in <order>'
	r := check('<other xmlns="urn:test"/>')!
	assert r.findings[0].msg == '<other> is not declared as a root element'
	// the right name in the wrong namespace is another name
	n := check('<order xmlns="urn:test" state="s"><id xmlns="urn:else">1</id></order>')!
	assert kinds(n) == [.undeclared_element]
}

fn test_attributes() {
	v := check('<order xmlns="urn:test" bogus="1" extra="ok"><line/></order>')!
	assert kinds(v) == [.undeclared_attribute, .missing_attribute, .missing_attribute]
	assert v.findings[0].msg == 'attribute bogus is not allowed on <order>'
	assert v.findings[1].msg == '<order> needs attribute state'
	assert v.findings[2].msg == '<line> needs attribute sku'
	// an attribute on an element of simple type
	s := check('<order xmlns="urn:test" state="s"><id lang="en">1</id></order>')!
	assert kinds(s) == [.undeclared_attribute]
}

fn test_content_kinds() {
	// text in element-only content, child elements in simple content
	v := check('<order xmlns="urn:test" state="s">stray<id>1<x/></id></order>')!
	assert kinds(v) == [.text_not_allowed, .children_not_allowed]
	// text-only content of an element-only type
	w := check('<order xmlns="urn:test" state="s"><line sku="x">text</line></order>')!
	assert kinds(w) == [.text_not_allowed]
	// whitespace is not text here
	x := check('<order xmlns="urn:test" state="s"><line sku="x"> <![CDATA[ ]]> </line></order>')!
	assert x.valid(), x.findings.str()
	a := check('<order xmlns="urn:test" state="s"><abstract/></order>')!
	assert kinds(a) == [.abstract_type]
}

fn test_xsi_type_is_not_supported() {
	v := check('<order xmlns="urn:test" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" state="s"><id xsi:type="xs:string">1</id></order>')!
	assert kinds(v) == [.unsupported]
}

fn test_findings_are_capped_but_counted() {
	mut body := ''
	for _ in 0 .. 20 {
		body += '<bogus/>'
	}
	s := compile(vschema)!
	mut d := flatxml.parse_string('<order xmlns="urn:test" state="s">${body}</order>')!
	v := validate(mut d, s, max_findings: 5)!
	assert v.findings.len == 5 && v.total == 20
}

fn test_not_namespace_well_formed_is_an_error() {
	check('<p:order/>') or {
		assert err.msg().contains('not bound')
		return
	}
	assert false
}

fn test_a_schema_the_document_names_elsewhere_is_unsupported() {
	v := check('<o:order xmlns:o="urn:other" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="urn:other other.xsd"/>')!
	assert kinds(v) == [.unsupported]
	assert v.findings[0].msg.contains('named in the document (xsi:schemaLocation), which is not followed')
	// xsi:type anywhere: the subtree is not assessed
	w := check('<order xmlns="urn:test" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="t:X"><bogus/></order>')!
	assert kinds(w) == [.unsupported]
}

fn test_review_cases_for_validation() {
	sch := '<xs:element name="r"><xs:complexType><xs:sequence><xs:element name="p" type="t:P" minOccurs="0"/><xs:element name="q" type="xs:string" minOccurs="0"/></xs:sequence></xs:complexType></xs:element><xs:complexType name="P"><xs:simpleContent><xs:extension base="xs:string"><xs:attribute name="u"/></xs:extension></xs:simpleContent></xs:complexType>'
	s := compile(sch)!
	run := fn [s] (doc string) []FindingKind {
		mut d := flatxml.parse_string(doc) or { panic(err) }
		return kinds(validate(mut d, s) or { panic(err) })
	}
	// text split by a comment or CDATA is still the text of simple content
	assert run('<r xmlns="urn:test"><p u="a">10<!-- c -->0</p><q>x<![CDATA[y]]></q></r>') == []
	// xsi:nil false is valid anywhere; true is an error, since nothing is nillable
	assert run('<r xmlns="urn:test" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><q xsi:nil="false">x</q></r>') == []
	assert run('<r xmlns="urn:test" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><q xsi:nil="true"/></r>') == [.not_nillable]
	// a document in no namespace that names its own schema
	assert run('<other xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="o.xsd"/>') == [.unsupported]
}

fn test_values_not_the_documents_are_not_checked() {
	s := compile('<xs:element name="r"><xs:complexType><xs:sequence><xs:element name="c" type="t:Code" minOccurs="0"/></xs:sequence></xs:complexType></xs:element><xs:simpleType name="Code"><xs:restriction base="xs:string"><xs:pattern value="[A-Z]+"/></xs:restriction></xs:simpleType>') or {
		panic(err)
	}
	run := fn [s] (doc string) []FindingKind {
		mut d := flatxml.parse_string(doc) or { panic(err) }
		return kinds(validate(mut d, s) or { panic(err) })
	}
	assert run('<r xmlns="urn:test"><c>AB</c></r>') == []
	assert run('<r xmlns="urn:test"><c>ab</c></r>') == [.invalid_value]
	// children are one finding, not also a value made of their text
	assert run('<r xmlns="urn:test"><c>AB<x>12</x></c></r>') == [.children_not_allowed]
	// a nil element is one finding
	assert run('<r xmlns="urn:test" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><c xsi:nil="true"/></r>') == [.not_nillable]
}

fn test_long_values_are_shortened_at_a_character() {
	v := 'é'.repeat(40)
	short := shortened(v)
	assert short.ends_with('...') && short.len <= 60
	assert short[..short.len - 3].runes().all(it == `é`)
}

// --- step 4b: the facets and the built-in types --------------------------------------------

const facets = '
  <xs:element name="r">
    <xs:complexType>
      <xs:sequence>
        <xs:element name="n" type="xs:unsignedByte" minOccurs="0" maxOccurs="unbounded"/>
        <xs:element name="d" type="t:Num" minOccurs="0" maxOccurs="unbounded"/>
        <xs:element name="s" type="t:Short" minOccurs="0" maxOccurs="unbounded"/>
        <xs:element name="h" type="t:Hex" minOccurs="0" maxOccurs="unbounded"/>
        <xs:element name="l" type="t:List" minOccurs="0" maxOccurs="unbounded"/>
        <xs:element name="b" type="t:Flag" minOccurs="0" maxOccurs="unbounded"/>
        <xs:element name="q" type="xs:QName" minOccurs="0" maxOccurs="unbounded"/>
        <xs:element name="item" minOccurs="0" maxOccurs="unbounded">
          <xs:complexType>
            <xs:attribute name="id" type="xs:ID"/>
            <xs:attribute name="ref" type="xs:IDREF"/>
            <xs:attribute name="refs" type="xs:IDREFS"/>
          </xs:complexType>
        </xs:element>
      </xs:sequence>
    </xs:complexType>
  </xs:element>
  <xs:simpleType name="Num"><xs:restriction base="xs:decimal"><xs:enumeration value="1.50"/><xs:enumeration value="-2"/></xs:restriction></xs:simpleType>
  <xs:simpleType name="Short"><xs:restriction base="xs:string"><xs:maxLength value="3"/></xs:restriction></xs:simpleType>
  <xs:simpleType name="Hex"><xs:restriction base="xs:hexBinary"><xs:maxLength value="2"/></xs:restriction></xs:simpleType>
  <xs:simpleType name="List"><xs:restriction base="xs:NMTOKENS"><xs:maxLength value="2"/></xs:restriction></xs:simpleType>
  <xs:simpleType name="Flag"><xs:restriction base="xs:boolean"><xs:enumeration value="true"/></xs:restriction></xs:simpleType>
'

fn facet_kinds(body string) []FindingKind {
	s := compile(facets) or { panic(err) }
	mut d := flatxml.parse_string('<r xmlns="urn:test" xmlns:p="urn:p">${body}</r>') or { panic(err) }
	return kinds(validate(mut d, s) or { panic(err) })
}

fn test_built_in_types_and_facets() {
	assert facet_kinds('<n>255</n><n> 7 </n>') == [] // collapsed before it is read
	assert facet_kinds('<n>256</n>') == [.invalid_value]
	assert facet_kinds('<n>x</n>') == [.invalid_value]
	assert facet_kinds('<n></n>') == [.invalid_value] // the empty string is not a number
	// enumerations compare values, not spellings
	assert facet_kinds('<d>1.5</d><d>001.500</d><d>-2.0</d>') == []
	assert facet_kinds('<d>1.6</d>') == [.invalid_value]
	assert facet_kinds('<b>1</b>') == []
	assert facet_kinds('<b>0</b>') == [.invalid_value]
	// maxLength counts characters, octets, items
	assert facet_kinds('<s>éée</s>') == []
	assert facet_kinds('<s>abcd</s>') == [.invalid_value]
	assert facet_kinds('<h>0A0B</h>') == []
	assert facet_kinds('<h>0A0B0C</h>') == [.invalid_value]
	assert facet_kinds('<l>a b</l>') == []
	assert facet_kinds('<l>a b c</l>') == [.invalid_value]
}

fn test_ids_references_and_qnames() {
	assert facet_kinds('<item id="a"/><item ref="a" refs="a a"/>') == []
	assert facet_kinds('<item id="a"/><item id="a"/>') == [.duplicate_id]
	assert facet_kinds('<item ref="b"/>') == [.unknown_idref]
	assert facet_kinds('<item refs="a b"/><item id="a"/>') == [.unknown_idref] // b only
	assert facet_kinds('<q>p:x</q><q>x</q>') == []
	assert facet_kinds('<q>z:x</q>') == [.unbound_prefix]
}

fn test_facets_are_checked_when_the_schema_compiles() {
	assert fails('<xs:simpleType name="X"><xs:restriction base="xs:int"><xs:maxLength value="3"/></xs:restriction></xs:simpleType>').contains('maxLength does not apply to type {urn:test}X, a int')
	assert fails('<xs:simpleType name="A"><xs:restriction base="xs:string"><xs:maxLength value="3"/></xs:restriction></xs:simpleType><xs:simpleType name="B"><xs:restriction base="t:A"><xs:maxLength value="4"/></xs:restriction></xs:simpleType>').contains('is longer than its base allows (3)')
	assert fails('<xs:simpleType name="X"><xs:restriction base="xs:int"><xs:whiteSpace value="preserve"/></xs:restriction></xs:simpleType>').contains('can only be collapse')
	assert fails('<xs:simpleType name="A"><xs:restriction base="xs:token"/></xs:simpleType><xs:simpleType name="B"><xs:restriction base="t:A"><xs:whiteSpace value="replace"/></xs:restriction></xs:simpleType>').contains('is looser than its base')
	assert fails('<xs:simpleType name="X"><xs:restriction base="xs:unsignedByte"><xs:enumeration value="300"/></xs:restriction></xs:simpleType>').contains('enumeration value "300" of type {urn:test}X is outside the range of unsignedByte')
	assert fails('<xs:simpleType name="X"><xs:restriction base="xs:ENTITY"/></xs:simpleType>').contains('needs a DTD or notations: not supported')
}

fn test_review_cases_for_facets() {
	sch := '<xs:element name="r"><xs:complexType><xs:sequence>
	  <xs:element name="dt" type="t:When" minOccurs="0" maxOccurs="unbounded"/>
	  <xs:element name="tm" type="t:At" minOccurs="0" maxOccurs="unbounded"/>
	  <xs:element name="du" type="t:Span" minOccurs="0" maxOccurs="unbounded"/>
	  <xs:element name="gm" type="t:Month" minOccurs="0" maxOccurs="unbounded"/>
	  <xs:element name="qn" type="t:Q" minOccurs="0" maxOccurs="unbounded"/>
	</xs:sequence></xs:complexType></xs:element>
	<xs:simpleType name="When"><xs:restriction base="xs:dateTime"><xs:enumeration value="2000-01-01T12:00:00Z"/></xs:restriction></xs:simpleType>
	<xs:simpleType name="At"><xs:restriction base="xs:time"><xs:enumeration value="12:00:00.5"/></xs:restriction></xs:simpleType>
	<xs:simpleType name="Span"><xs:restriction base="xs:duration"><xs:enumeration value="P1Y"/><xs:enumeration value="PT24H"/></xs:restriction></xs:simpleType>
	<xs:simpleType name="Month"><xs:restriction base="xs:gMonth"><xs:enumeration value="--05"/></xs:restriction></xs:simpleType>
	<xs:simpleType name="Q"><xs:restriction base="xs:QName"><xs:enumeration value="t:x"/></xs:restriction></xs:simpleType>'
	s := compile(sch)!
	run := fn [s] (body string) []FindingKind {
		mut d := flatxml.parse_string('<r xmlns="urn:test" xmlns:o="urn:test" xmlns:z="urn:z">${body}</r>') or { panic(err) }
		return kinds(validate(mut d, s) or { panic(err) })
	}
	// the same instant, time, duration and month, written otherwise
	assert run('<dt>2000-01-01T13:00:00+01:00</dt><dt>2000-01-01T12:00:00.000Z</dt>') == []
	assert run('<dt>2000-01-01T12:00:00</dt>') == [.invalid_value] // no timezone: another value
	assert run('<tm>12:00:00.50</tm>') == []
	// a time with a timezone is never equal to one without
	assert run('<tm>13:00:00.5+01:00</tm>') == [.invalid_value]
	assert run('<du>P12M</du><du>P1D</du><du>PT1440M</du>') == []
	assert run('<du>P13M</du>') == [.invalid_value]
	assert run('<gm>--05--</gm>') == []
	// a QName enumeration compares namespaces, not prefixes
	assert run('<qn>o:x</qn><qn>x</qn>') == []
	assert run('<qn>z:x</qn>') == [.invalid_value]
	// a year too long for a number is a year all the same
	ok_long := lexical_problem(.g_year, '123456789012345678901') == none
	assert ok_long
	// a declaration may not use ENTITY directly either
	assert fails('<xs:attribute name="img" type="xs:ENTITY"/>').contains('needs a DTD or notations: not supported')
}
