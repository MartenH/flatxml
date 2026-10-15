module xsd

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
