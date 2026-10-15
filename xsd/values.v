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
	if ws == .preserve || ws == .unset || !v.contains_any('\t\n\r' + (if ws == .collapse { ' ' } else { '' })) {
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
// is. m runs the patterns.
fn (s &Schema) value_problem(t TypeRef, v string, mut m Matcher) ?string {
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
		cur = st.base
	}
	return none
}

// patterned is, per simple type, whether it or a type it derives from has a pattern: the only
// check so far.
fn (s &Schema) patterned() []bool {
	mut out := []bool{len: s.simple_types.len}
	for k in 0 .. s.simple_types.len {
		mut cur := TypeRef{.simple, u32(k)}
		for cur.kind == .simple {
			if s.simple_types[cur.idx].compiled.len > 0 {
				out[k] = true
				break
			}
			cur = s.simple_types[cur.idx].base
		}
	}
	return out
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
	return t.kind == .simple && vr.patterned[t.idx]
}

// check_value checks a value written in the document against type t: element i's text, or with
// attr set, the value of attribute attr of element i. A problem is a finding at i.
fn (mut vr Validator) check_value(i u32, attr i64, t TypeRef, raw string) {
	v := normalized(raw, vr.s.white_space(t))
	problem := vr.s.value_problem(t, v, mut vr.matcher) or {
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
