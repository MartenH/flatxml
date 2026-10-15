module xsd

// The lexical spaces of the built-in types (XSD 1.0 Part 2, section 3): what a value, its
// whitespace already normalised by the type's rule, may look like. Where XSD 1.0 cites an older
// rule than today's (the XML name characters of XML 1.0's second edition), the current one is
// used, which accepts a little more and never rejects a value the older one allows.

// lexical_problem says why v is not in the lexical space of built-in type b, or none. The checks
// run on every value of a document, so they scan v in place: a V substring is a copy.
@[direct_array_access]
fn lexical_problem(b Builtin, v string) ?string {
	ok := match b {
		.any_simple_type, .string, .normalized_string, .token, .any_uri { true }
		.boolean { v in ['true', 'false', '1', '0'] }
		.decimal { decimal_span(v) != none }
		.float, .double { is_float_literal(v) }
		.duration { is_duration(v) }
		.date_time { is_date_time(v) }
		.time { is_time(v) }
		.date { is_date(v) }
		.g_year_month { is_g_year_month(v) }
		.g_year { is_g_year(v) }
		.g_month_day { is_g_month_day(v) }
		.g_day { is_g_day(v) }
		.g_month { is_g_month(v) }
		.hex_binary { v.len % 2 == 0 && all_bytes(v, 0, v.len, fn (c u8) bool { return c.is_hex_digit() }) }
		.base64_binary { base64_octets(v) != none }
		.qname, .notation { is_qname(v) }
		.language { is_language(v) }
		.nmtoken { is_nmtoken(v) }
		.nmtokens { is_list(v, false) }
		.name { is_name(v, true) }
		.nc_name, .id, .idref, .entity { is_name(v, false) }
		.idrefs, .entities { is_list(v, true) }
		else { return integer_problem(b, v) }
	}
	return if ok { none } else { 'is not a valid ${builtin_name(b)}' }
}

// --- numbers -------------------------------------------------------------------------------

// The bounds of the integer types, as decimal digit strings; '' is unbounded.
struct IntRange {
	min string
	max string
}

fn int_range(b Builtin) IntRange {
	return match b {
		.non_positive_integer { IntRange{'', '0'} }
		.negative_integer { IntRange{'', '-1'} }
		.long { IntRange{'-9223372036854775808', '9223372036854775807'} }
		.int { IntRange{'-2147483648', '2147483647'} }
		.short { IntRange{'-32768', '32767'} }
		.byte { IntRange{'-128', '127'} }
		.non_negative_integer { IntRange{'0', ''} }
		.unsigned_long { IntRange{'0', '18446744073709551615'} }
		.unsigned_int { IntRange{'0', '4294967295'} }
		.unsigned_short { IntRange{'0', '65535'} }
		.unsigned_byte { IntRange{'0', '255'} }
		.positive_integer { IntRange{'1', ''} }
		else { IntRange{'', ''} }
	}
}

// DecimalSpan locates the parts of a decimal literal within it, without copying: its sign, its
// integer digits after any leading zeros (start, end), and whether it has a point.
struct DecimalSpan {
	neg   bool
	start int
	end   int
	point bool
}

// decimal_span reads (+|-)? digits (. digits)?, with digits on at least one side of the point.
@[direct_array_access]
fn decimal_span(v string) ?DecimalSpan {
	mut i := 0
	neg := v.len > 0 && v[0] == `-`
	if v.len > 0 && (v[0] == `-` || v[0] == `+`) {
		i = 1
	}
	whole_start := i
	for i < v.len && v[i].is_digit() {
		i++
	}
	whole_end := i
	mut point := false
	if i < v.len && v[i] == `.` {
		point = true
		i++
		frac_start := i
		for i < v.len && v[i].is_digit() {
			i++
		}
		if whole_end == whole_start && i == frac_start {
			return none
		}
	} else if whole_end == whole_start {
		return none
	}
	if i != v.len {
		return none
	}
	mut s := whole_start
	for s < whole_end && v[s] == `0` {
		s++
	}
	return DecimalSpan{neg, s, whole_end, point}
}

// integer_problem checks v against an integer type: (+|-)? digits, within the type's range.
fn integer_problem(b Builtin, v string) ?string {
	d := decimal_span(v) or { return 'is not a valid ${builtin_name(b)}' }
	if d.point {
		return 'is not a valid ${builtin_name(b)}'
	}
	r := int_range(b)
	if (r.min != '' && compare_to_bound(v, d, r.min) < 0)
		|| (r.max != '' && compare_to_bound(v, d, r.max) > 0) {
		return 'is outside the range of ${builtin_name(b)}'
	}
	return none
}

// compare_to_bound compares the integer v (located by d) with a bound written as an optional '-'
// and digits without leading zeros.
@[direct_array_access]
fn compare_to_bound(v string, d DecimalSpan, bound string) int {
	zero := d.end == d.start
	neg := d.neg && !zero
	bneg := bound[0] == `-`
	if neg != bneg {
		return if neg { -1 } else { 1 }
	}
	bstart := if bneg { 1 } else { 0 }
	n := d.end - d.start
	bn := if bound == '0' { 0 } else { bound.len - bstart }
	mut c := 0
	if n != bn {
		c = if n < bn { -1 } else { 1 }
	} else {
		for k in 0 .. n {
			if v[d.start + k] != bound[bstart + k] {
				c = if v[d.start + k] < bound[bstart + k] { -1 } else { 1 }
				break
			}
		}
	}
	return if neg { -c } else { c }
}

// decimal_digits reads a decimal literal as (negative, integer digits, fraction digits) without
// leading or trailing zeros, for comparing values.
fn decimal_digits(v string) ?(bool, string, string) {
	d := decimal_span(v)?
	dot := v.index_u8(`.`)
	frac := if dot < 0 { '' } else { v[dot + 1..].trim_right('0') }
	return d.neg, v[d.start..d.end], frac
}

fn all_bytes(v string, from int, to int, ok fn (u8) bool) bool {
	for k in from .. to {
		if !ok(v[k]) {
			return false
		}
	}
	return true
}

// is_float_literal: a decimal mantissa with an optional exponent, or INF, -INF or NaN.
fn is_float_literal(v string) bool {
	if v in ['INF', '-INF', 'NaN'] {
		return true
	}
	e := v.index_any('eE')
	mantissa := if e < 0 { v } else { v[..e] }
	if decimal_span(mantissa) == none {
		return false
	}
	if e < 0 {
		return true
	}
	mut x := e + 1
	if x < v.len && (v[x] == `-` || v[x] == `+`) {
		x++
	}
	return x < v.len && all_bytes(v, x, v.len, fn (c u8) bool { return c.is_digit() })
}

// --- dates, times, durations ---------------------------------------------------------------

// is_duration: -?P, then years, months, days, and after T hours, minutes, seconds, each a number
// with its designator; at least one, and T only with a time part after it.
fn is_duration(v string) bool {
	mut s := if v.starts_with('-') { v[1..] } else { v }
	if !s.starts_with('P') {
		return false
	}
	s = s[1..]
	t := s.index_u8(`T`)
	date := if t < 0 { s } else { s[..t] }
	time := if t < 0 { '' } else { s[t + 1..] }
	if t >= 0 && time == '' {
		return false
	}
	dn := designated(date, 'YMD', false) or { return false }
	tn := designated(time, 'HMS', true) or { return false }
	return dn + tn > 0
}

// designated reads numbers each followed by one of the designators, in order, each at most once;
// the last may have a fraction when allowed. It answers how many it read.
fn designated(s string, designators string, fraction_last bool) ?int {
	mut rest := s
	mut n := 0
	mut next := 0
	for rest.len > 0 {
		mut k := 0
		for k < rest.len && (rest[k].is_digit() || rest[k] == `.`) {
			k++
		}
		if k == 0 || k == rest.len {
			return none
		}
		d := designators.index_u8(rest[k])
		if d < next {
			return none
		}
		num := rest[..k]
		if num.contains('.') {
			if !(fraction_last && d == designators.len - 1) || num.count('.') > 1 || num.starts_with('.')
				|| num.ends_with('.') {
				return none
			}
		}
		next = d + 1
		n++
		rest = rest[k + 1..]
	}
	return n
}

// date_part checks -?yyyy-mm-dd (the year at least four digits, no leading zero past four, not
// 0000) and answers the rest.
fn year_part(s string) ?(i64, string) {
	mut t := s
	if t.starts_with('-') {
		t = t[1..]
	}
	mut k := 0
	for k < t.len && t[k].is_digit() {
		k++
	}
	if k < 4 || (k > 4 && t[0] == `0`) {
		return none
	}
	year := t[..k].i64()
	if year == 0 {
		return none
	}
	return year, t[k..]
}

fn two_digits(s string, lo int, hi int) ?int {
	if s.len < 2 || !s[0].is_digit() || !s[1].is_digit() {
		return none
	}
	n := int(s[0] - `0`) * 10 + int(s[1] - `0`)
	return if n < lo || n > hi { none } else { n }
}

fn days_in(year i64, month int) int {
	return match month {
		2 { if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 { 29 } else { 28 } }
		4, 6, 9, 11 { 30 }
		else { 31 }
	}
}

// is_timezone: empty, Z, or (+|-)hh:mm up to 14:00.
fn is_timezone(s string) bool {
	if s == '' || s == 'Z' {
		return true
	}
	if s.len != 6 || (s[0] != `+` && s[0] != `-`) || s[3] != `:` {
		return false
	}
	h := two_digits(s[1..3], 0, 14) or { return false }
	m := two_digits(s[4..], 0, 59) or { return false }
	return h < 14 || m == 0
}

// clock checks hh:mm:ss(.s+)? (24:00:00 allowed) and answers the rest.
fn clock(s string) ?string {
	if s.len < 8 || s[2] != `:` || s[5] != `:` {
		return none
	}
	h := two_digits(s, 0, 24)?
	m := two_digits(s[3..], 0, 59)?
	sec := two_digits(s[6..], 0, 59)?
	mut k := 8
	if k < s.len && s[k] == `.` {
		k++
		start := k
		for k < s.len && s[k].is_digit() {
			k++
		}
		if k == start {
			return none
		}
	}
	if h == 24 && (m != 0 || sec != 0 || s[8..k].trim_left('.').trim_right('0') != '') {
		return none
	}
	return s[k..]
}

// year_month_day checks -?yyyy-mm-dd and answers the rest.
fn year_month_day(s string) ?string {
	year, rest := year_part(s)?
	if rest.len < 6 || rest[0] != `-` || rest[3] != `-` {
		return none
	}
	month := two_digits(rest[1..], 1, 12)?
	day := two_digits(rest[4..], 1, 31)?
	if day > days_in(year, month) {
		return none
	}
	return rest[6..]
}

fn is_date_time(v string) bool {
	rest := year_month_day(v) or { return false }
	if !rest.starts_with('T') {
		return false
	}
	tz := clock(rest[1..]) or { return false }
	return is_timezone(tz)
}

fn is_time(v string) bool {
	tz := clock(v) or { return false }
	return is_timezone(tz)
}

fn is_date(v string) bool {
	tz := year_month_day(v) or { return false }
	return is_timezone(tz)
}

fn is_g_year_month(v string) bool {
	_, rest := year_part(v) or { return false }
	if rest.len < 3 || rest[0] != `-` {
		return false
	}
	two_digits(rest[1..], 1, 12) or { return false }
	return is_timezone(rest[3..])
}

fn is_g_year(v string) bool {
	_, rest := year_part(v) or { return false }
	return is_timezone(rest)
}

fn is_g_month_day(v string) bool {
	if v.len < 7 || !v.starts_with('--') || v[4] != `-` {
		return false
	}
	month := two_digits(v[2..], 1, 12) or { return false }
	day := two_digits(v[5..], 1, 31) or { return false }
	return day <= days_in(2000, month) && is_timezone(v[7..])
}

fn is_g_day(v string) bool {
	if v.len < 5 || !v.starts_with('---') {
		return false
	}
	two_digits(v[3..], 1, 31) or { return false }
	return is_timezone(v[5..])
}

// is_g_month: --mm, and the --mm-- of XSD 1.0's first edition, which documents still carry.
fn is_g_month(v string) bool {
	if v.len < 4 || !v.starts_with('--') {
		return false
	}
	two_digits(v[2..], 1, 12) or { return false }
	rest := if v[4..].starts_with('--') { v[6..] } else { v[4..] }
	return is_timezone(rest)
}

// --- binary --------------------------------------------------------------------------------

// base64_octets is the number of octets a base64Binary literal encodes: groups of four
// characters, spaces allowed between, `=` padding only at the end and only after a character
// whose unused bits are zero.
fn base64_octets(v string) ?int {
	s := v.replace(' ', '')
	if s.len % 4 != 0 {
		return none
	}
	pad := if s.ends_with('==') {
		2
	} else if s.ends_with('=') {
		1
	} else {
		0
	}
	body := s[..s.len - pad]
	if !body.bytes().all(it.is_alnum() || it == `+` || it == `/`) {
		return none
	}
	if pad == 2 && body.len > 0 && 'AQgw'.index_u8(body[body.len - 1]) < 0 {
		return none
	}
	if pad == 1 && body.len > 0 && 'AEIMQUYcgkosw048'.index_u8(body[body.len - 1]) < 0 {
		return none
	}
	return s.len / 4 * 3 - pad
}

// --- names ---------------------------------------------------------------------------------

// XML 1.0 (fifth edition) NameStartChar, ':' left to the caller.
fn is_name_start(c u32) bool {
	return (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || c == `_` || (c >= 0xC0 && c <= 0xD6)
		|| (c >= 0xD8 && c <= 0xF6) || (c >= 0xF8 && c <= 0x2FF) || (c >= 0x370 && c <= 0x37D)
		|| (c >= 0x37F && c <= 0x1FFF) || (c >= 0x200C && c <= 0x200D)
		|| (c >= 0x2070 && c <= 0x218F) || (c >= 0x2C00 && c <= 0x2FEF)
		|| (c >= 0x3001 && c <= 0xD7FF) || (c >= 0xF900 && c <= 0xFDCF)
		|| (c >= 0xFDF0 && c <= 0xFFFD) || (c >= 0x10000 && c <= 0xEFFFF)
}

fn is_name_char(c u32) bool {
	return is_name_start(c) || (c >= `0` && c <= `9`) || c == `-` || c == `.` || c == 0xB7
		|| (c >= 0x300 && c <= 0x36F) || (c >= 0x203F && c <= 0x2040)
}

// is_name: a Name (colons allowed) or an NCName.
fn is_name(v string, colon bool) bool {
	if v == '' {
		return false
	}
	mut i := 0
	mut first := true
	for i < v.len {
		c, w := decode_rune(v, i)
		i += w
		if c == `:` {
			if !colon {
				return false
			}
		} else if first && !is_name_start(c) {
			return false
		} else if !first && !is_name_char(c) {
			return false
		}
		first = false
	}
	return true
}

fn is_nmtoken(v string) bool {
	if v == '' {
		return false
	}
	mut i := 0
	for i < v.len {
		c, w := decode_rune(v, i)
		i += w
		if c != `:` && !is_name_char(c) {
			return false
		}
	}
	return true
}

fn is_qname(v string) bool {
	colon := v.index_u8(`:`)
	if colon < 0 {
		return is_name(v, false)
	}
	return is_name(v[..colon], false) && is_name(v[colon + 1..], false)
}

// is_language: ([a-zA-Z]{1,8})(-[a-zA-Z0-9]{1,8})*
fn is_language(v string) bool {
	parts := v.split('-')
	for k, p in parts {
		if p.len < 1 || p.len > 8 {
			return false
		}
		if !p.bytes().all(it.is_letter() || (k > 0 && it.is_digit())) {
			return false
		}
	}
	return true
}

// is_list: one or more items separated by single spaces (the value is already collapsed): NCNames
// when names, else NMTOKENs.
fn is_list(v string, names bool) bool {
	if v == '' {
		return false
	}
	for item in v.split(' ') {
		if !(if names { is_name(item, false) } else { is_nmtoken(item) }) {
			return false
		}
	}
	return true
}
