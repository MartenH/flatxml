module xsd

// Checking a value against its simple type (XSD 1.0 Part 2, 4.3): normalise its whitespace by
// the type's rule, then check every facet along the type's derivation chain. Patterns are
// alternatives within one derivation step (several xsd:pattern in one restriction) and all apply
// across steps.

// white_space is the whitespace rule of type t: the nearest whiteSpace facet up its derivation
// chain, else its built-in's (string keeps whitespace, normalizedString replaces it, every other
// built-in collapses it).
pub fn (s &Schema) white_space(t TypeRef) WhiteSpace {
	mut cur := t
	for cur.kind == .simple {
		st := s.simple_types[cur.idx]
		if st.white_space != .unset {
			return st.white_space
		}
		cur = st.base
	}
	if cur.kind != .builtin {
		return .preserve
	}
	return match unsafe { Builtin(cur.idx) } {
		.string, .any_simple_type { .preserve }
		.normalized_string { .replace }
		else { .collapse }
	}
}

// normalized is v with whitespace treated by rule ws: replace turns each tab, newline and carriage
// return into a space; collapse also trims, and turns each run of spaces into one.
pub fn normalized(v string, ws WhiteSpace) string {
	if ws == .preserve || ws == .unset {
		return v
	}
	// most values need nothing done: no tab, newline or return, and for collapse no space
	if !v.contains_any(if ws == .collapse { '\t\n\r ' } else { '\t\n\r' }) {
		return v
	}
	replaced := v.replace_each(['\t', ' ', '\n', ' ', '\r', ' '])
	if ws == .replace {
		return replaced
	}
	return replaced.fields().join(' ')
}

// Matcher runs a schema's patterns: with a DFA per pattern, built as values meet it (for
// validating a document, where most values are matched), or with the Pike VM (for a few values).
struct Matcher {
mut:
	use_dfa bool
	dfas    [][]Dfa // per simple type and pattern, made on first use
	scratch Scratch
}

fn (mut m Matcher) matches(s &Schema, st u32, k int, v string) bool {
	if !m.use_dfa {
		return s.simple_types[st].compiled[k].matches_in(mut m.scratch, v)
	}
	if m.dfas.len == 0 {
		m.dfas = [][]Dfa{len: s.simple_types.len}
	}
	if m.dfas[st].len == 0 {
		for j in 0 .. s.simple_types[st].compiled.len {
			m.dfas[st] << new_dfa(unsafe { &s.simple_types[st].compiled[j] })
		}
	}
	return m.dfas[st][k].matches(v)
}

// value_problem says why the normalised value v is not a valid value of type t, or none when it
// is: the built-in type's lexical space, then each derivation step's facets (patterns, as
// alternatives within a step; enumeration, by value; maxLength). m runs the patterns.
fn (s &Schema) value_problem(t TypeRef, v string, mut m Matcher) ?string {
	root := s.root_of(t)
	if p := lexical_problem(root, v) {
		return p
	}
	mut cur := t
	// Each derivation step's facets, up to the built-in type.
	for cur.kind == .simple {
		st := s.simple_types[cur.idx]
		mut matched := st.compiled.len == 0
		for k in 0 .. st.compiled.len {
			if m.matches(s, cur.idx, k, v) {
				matched = true
				break
			}
		}
		if !matched {
			what := if st.compiled.len == 1 {
				'the pattern ${st.patterns[0]}'
			} else {
				'any of the patterns ${st.patterns.join(', ')}'
			}
			return 'does not match ${what}'
		}
		if st.enum_keys.len > 0 && value_key(root, v) !in st.enum_keys {
			if st.enums.len <= 8 {
				return 'is not one of ${st.enums.join(', ')}'
			}
			return 'is not one of the ${st.enums.len} values its type allows'
		}
		// on QName and NOTATION the length facets are deprecated (XSD 1.0 errata) and ignored
		if st.max_length >= 0 && length_applies(root) && root !in [.qname, .notation]
			&& value_length(root, v) > st.max_length {
			return 'is longer than ${st.max_length}'
		}
		cur = st.base
	}
	return none
}

// checked is, per simple type, whether its values have anything to be checked against: a facet
// up its derivation chain, or a built-in whose lexical space is not every string.
fn (s &Schema) checked() []bool {
	mut out := []bool{len: s.simple_types.len}
	for k in 0 .. s.simple_types.len {
		if builtin_checked(s.simple_types[k].root) {
			out[k] = true
			continue
		}
		mut cur := TypeRef{.simple, u32(k)}
		for cur.kind == .simple {
			st := s.simple_types[cur.idx]
			if st.compiled.len > 0 || st.enums.len > 0 || st.max_length >= 0 {
				out[k] = true
				break
			}
			cur = st.base
		}
	}
	return out
}

// builtin_checked reports whether a value of built-in b can be invalid, or must be recorded
// (IDs and references to them).
fn builtin_checked(b Builtin) bool {
	return b !in [.any_simple_type, .string, .normalized_string, .token, .any_uri]
}

// shortened is v cut to fit a message, at a character boundary.
fn shortened(v string) string {
	if v.len <= 60 {
		return v
	}
	mut k := 57
	for k > 0 && v[k] & 0xC0 == 0x80 {
		k--
	}
	return v[..k] + '...'
}

// checks reports whether values of type t have anything to be checked against, so a caller can
// skip reading a value that would not be.
@[inline]
fn (vr &Validator) checks(t TypeRef) bool {
	return match t.kind {
		.simple { vr.checked[t.idx] }
		.builtin { builtin_checked(unsafe { Builtin(t.idx) }) }
		.complex { false }
	}
}

// check_value checks a value written in the document against type t: element i's text, or with
// attr set, the value of attribute attr of element i. A problem is a finding at i.
fn (mut vr Validator) check_value(i u32, attr i64, t TypeRef, raw string) {
	v := normalized(raw, vr.s.white_space(t))
	problem := vr.s.value_problem(t, v, mut vr.matcher) or {
		vr.record_reference(i, vr.s.root_of(t), v)
		return
	}
	if vr.keep() {
		shown := shortened(v)
		owner := if attr < 0 {
			'<${vr.d.name(i)}>'
		} else {
			'attribute ${vr.d.attr_name(u32(attr))} on <${vr.d.name(i)}>'
		}
		vr.add(i, .invalid_value, '${owner} "${shown}" ${problem}')
	}
}

// --- facets beyond patterns ----------------------------------------------------------------

// root_of is the built-in type at the end of t's derivation chain.
pub fn (s &Schema) root_of(t TypeRef) Builtin {
	return match t.kind {
		.builtin { unsafe { Builtin(t.idx) } }
		.simple { s.simple_types[t.idx].root }
		.complex { Builtin.any_simple_type }
	}
}

// value_key is v (in the lexical space of built-in root) as a key equal for equal values: numbers
// by their decimal value, booleans by truth, floats by their double, timezones Z and +00:00 alike,
// hex binary in upper case, base64 without spaces; the rest as written.
fn value_key(root Builtin, v string) string {
	match root {
		.decimal, .integer, .non_positive_integer, .negative_integer, .long, .int, .short, .byte,
		.non_negative_integer, .unsigned_long, .unsigned_int, .unsigned_short, .unsigned_byte,
		.positive_integer {
			neg, whole, frac := decimal_digits(v) or { return v }
			w := if whole == '' { '0' } else { whole }
			key := if frac == '' { w } else { '${w}.${frac}' }
			return if neg && key != '0' { '-' + key } else { key }
		}
		.boolean {
			return if v in ['true', '1'] { 'true' } else { 'false' }
		}
		.float, .double {
			if v in ['INF', '-INF', 'NaN'] {
				return v
			}
			f := v.f64()
			return if root == .float { f32(f).str() } else { f.str() }
		}
		.date_time, .time, .date, .g_year_month, .g_year, .g_month_day, .g_day, .g_month {
			for tz in ['+00:00', '-00:00'] {
				if v.ends_with(tz) {
					return v[..v.len - tz.len] + 'Z'
				}
			}
			return v
		}
		.hex_binary {
			return v.to_upper()
		}
		.base64_binary {
			return v.replace(' ', '')
		}
		else {
			return v
		}
	}
}

// value_length is the length of v as the length facets count it: octets for the binary types,
// items for the list types, characters otherwise.
fn value_length(root Builtin, v string) int {
	return match root {
		.hex_binary { v.len / 2 }
		.base64_binary { base64_octets(v) or { 0 } }
		.nmtokens, .idrefs, .entities { if v == '' { 0 } else { v.count(' ') + 1 } }
		else { v.runes().len }
	}
}

// length_applies reports whether the length facets apply to values of root.
fn length_applies(root Builtin) bool {
	return root in [.string, .normalized_string, .token, .language, .nmtoken, .nmtokens, .name,
		.nc_name, .id, .idref, .idrefs, .entity, .entities, .any_uri, .qname, .notation, .hex_binary,
		.base64_binary, .any_simple_type]
}

// string_like reports whether root derives from string, the only family whose whiteSpace can be
// other than collapse.
fn string_like(root Builtin) bool {
	return root in [.string, .normalized_string, .token, .language, .nmtoken, .nmtokens, .name,
		.nc_name, .id, .idref, .idrefs, .entity, .entities, .any_simple_type]
}

// max_length_of is the nearest maxLength up t's derivation chain, if any.
fn (s &Schema) max_length_of(t TypeRef) ?int {
	mut cur := t
	for cur.kind == .simple {
		st := s.simple_types[cur.idx]
		if st.max_length >= 0 {
			return st.max_length
		}
		cur = st.base
	}
	return none
}
