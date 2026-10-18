module xsd

fn matches(p string, s string) bool {
	pat := compile_pattern(p) or { panic(err) }
	return pat.matches(s)
}

fn bad(p string) string {
	compile_pattern(p) or { return err.msg() }
	return ''
}

fn test_basics() {
	assert matches('abc', 'abc') && !matches('abc', 'ab') && !matches('abc', 'abcd')
	assert matches('a|bc', 'bc') && matches('a|bc', 'a') && !matches('a|bc', 'abc')
	assert matches('(ab)*', '') && matches('(ab)*', 'abab') && !matches('(ab)*', 'aba')
	assert matches('a+b?', 'aaa') && matches('a+b?', 'ab') && !matches('a+b?', 'b')
	assert matches('a{2,3}', 'aa') && matches('a{2,3}', 'aaa') && !matches('a{2,3}', 'a') && !matches('a{2,3}', 'aaaa')
	assert matches('a{2}', 'aa') && !matches('a{2}', 'aaa') && matches('a{2,}', 'aaaaa') && !matches('a{2,}', 'a')
	assert matches('^$', '^$') // no anchors in XSD
	assert matches('', '') && !matches('', 'a')
}

fn test_classes() {
	assert matches('[a-c]+', 'abcba') && !matches('[a-c]+', 'abd')
	assert matches('[^a-c]', 'd') && !matches('[^a-c]', 'a')
	assert matches('[a-z-[aeiou]]+', 'xyz') && !matches('[a-z-[aeiou]]+', 'xaz')
	assert matches('[-a]', '-') && matches('[a-]', '-') && matches('[\\-a]', '-')
	// a literal `-` last before a subtraction
	assert matches('[a-z--[b-z]]', '-') && matches('[a-z--[b-z]]', 'a') && !matches('[a-z--[b-z]]', 'b')
	assert matches('.', 'x') && !matches('.', '\n')
	assert matches('\\d+', '٣٤') && !matches('\\d', 'x') // \d is every decimal digit, not only 0-9
	assert matches('\\s', '\t') && !matches('\\S', ' ')
	assert matches('\\w', 'é') && !matches('\\w', '!')
	assert matches('\\p{Lu}', 'É') && !matches('\\p{Lu}', 'é') && matches('\\P{Lu}', 'é') && matches('\\p{L}', 'é')
	assert matches('[\\d\\s]+', '1 2') && matches('[\\D]', 'a') && !matches('[\\D]', '1')
	assert matches('\\.\\*\\{', '.*{')
}

fn test_the_patterns_of_a_generated_schema() {
	assert matches('SN-[0-9]{7}', 'SN-0007919') && !matches('SN-[0-9]{7}', 'SN-79')
	// the shapes the measured schemas use: identifiers, paths, numbers with alternatives
	assert matches('[a-zA-Z][a-zA-Z0-9_]{0,127}', 'Abc_1')
	assert matches('/?[a-zA-Z][a-zA-Z0-9_]{0,127}(/[a-zA-Z][a-zA-Z0-9_]{0,127})*', '/Pkg/Sub/Elem')
	assert matches('[+\\-]?[1-9][0-9]*|0x[0-9a-f]+|0[0-7]*|0b[0-1]+', '0x1f')
	assert !matches('[+\\-]?[1-9][0-9]*|0x[0-9a-f]+|0[0-7]*|0b[0-1]+', '0x')
}

fn test_errors() {
	assert bad('a{3,2}').contains('counts down')
	assert bad('a**').contains('a second quantifier')
	assert bad('(a').contains('`(` is not closed')
	assert bad('a)').contains('unexpected `)`')
	assert bad('[]').contains('an empty character class')
	assert bad('[b-a]').contains('runs backwards')
	assert bad('[a-c-x]').contains('`-` is a literal only first or last')
	assert bad('*a').contains('`*` must be escaped')
	assert bad('\\q').contains('unknown escape')
	assert bad('\\p{Xx}').contains('unknown category')
	assert bad('\\p{IsBasicLatin}').contains('not supported')
	assert bad('\\i').contains('not supported')
	assert bad('a{100000000}').contains('not supported')
}

fn test_linear_on_a_pathological_pattern() {
	// (a|a)*b against many a's: exponential for a backtracker, linear here
	mut s := ''
	for _ in 0 .. 5000 {
		s += 'a'
	}
	assert !matches('(a|a)*b', s)
	assert !matches('(a*)*b', s)
}

// The DFA answers exactly as the Pike VM does, on strings made to probe each pattern.
fn test_dfa_matches_the_pike_vm() {
	patterns := ['SN-[0-9]{7}', '[a-zA-Z][a-zA-Z0-9_]{0,127}',
		'/?[a-zA-Z][a-zA-Z0-9_]{0,127}(/[a-zA-Z][a-zA-Z0-9_]{0,127})*', '(a|b)*abb', '\\d+(\\.\\d+)?',
		'[\\p{L}-[a-z]]+', '(ab){2,4}|x*', '.*é.*']
	alphabet := 'abxzAZ09_/.-é٣ '.runes()
	for p in patterns {
		pat := compile_pattern(p) or { panic(err) }
		mut dfa := new_dfa(&pat)
		mut seed := u32(7)
		for _ in 0 .. 3000 {
			seed = seed * 1103515245 + 12345
			n := int((seed >> 16) % 12)
			mut s := []rune{}
			for _ in 0 .. n {
				seed = seed * 1103515245 + 12345
				s << alphabet[int((seed >> 16) % u32(alphabet.len))]
			}
			str := s.string()
			assert dfa.matches(str) == pat.matches(str), '${p} on ${str}'
		}
	}
}

fn test_review_cases() {
	// a repeat of something empty is bounded at compile time, not only by the program's size
	assert bad('((){99999}){99999}').contains('not supported')
	// an unescaped `-` cannot end a range
	assert bad('[!--]').contains('must be escaped in a range')
	assert matches('[!-\\-]', '-')
	// malformed UTF-8 reads as U+FFFD, one byte at a time
	for bytes in ['\xf8\x80\x80\x80', '\xc0\xaf', '\xed\xa0\x80', '\xf4\x90\x80\x80'] {
		c, w := decode_rune(bytes, 0)
		assert c == 0xFFFD && w == 1
	}
	c2, w2 := decode_rune('é', 0)
	assert c2 == 0xE9 && w2 == 2
	c4, w4 := decode_rune('\xf0\x9f\x98\x80', 0)
	assert c4 == 0x1F600 && w4 == 4
}
