// flatxml — command-line access to the parser.
//
//   flatxml dump [--ns] <file>     one line per element and per run of text, for
//                                  tools/check_vs_expat.py; --ns resolves namespaces
//   flatxml stats [--parse-only] <file>...   parse each file and print its size, node counts and
//                                  parse time, and (unless --parse-only) the time namespace
//                                  resolution adds
//   flatxml schema <xsd>...        compile an XML Schema and print what it holds
//   flatxml schema --batch [--times]   compile one schema per stdin line (tab-separated
//                                  documents), answering `ok` or `error<TAB>message` per line;
//                                  --times writes the time spent compiling to stderr
//   flatxml validate <xsd> <doc>...   check documents against a schema, one line per finding
//   flatxml match --batch          one `pattern<TAB>string` per stdin line: does the XSD pattern
//                                  match the whole string (`yes`, `no`, `error<TAB>message`)
//   flatxml validate --batch [--times]   one `document<TAB>schema documents...` per stdin line,
//                                  answering `valid`, `invalid<TAB>kind<TAB>first finding`, or
//                                  `error<TAB>message`; --times writes the time spent on the
//                                  documents (not their schemas) to stderr
module main

import flatxml
import flatxml.xsd
import os
import strings
import time

const usage = 'usage:
  flatxml dump [--ns] <file>    canonical element/text stream, for tools/check_vs_expat.py;
                                --ns names elements and attributes {uri}local
  flatxml stats [--parse-only] <file>...   size, node counts, parse and namespace times
  flatxml schema <xsd>...       compile an XML Schema (and what it imports), print what it holds
  flatxml schema --batch        one schema per stdin line (documents tab-separated): ok | error<TAB>why
  flatxml validate <xsd> <doc>...  check documents against a schema
  flatxml validate --batch      one `document<TAB>schema...` per stdin line
  flatxml match --batch         one `pattern<TAB>string` per stdin line: yes | no | error<TAB>why'

fn main() {
	args := os.args[1..]
	if args.len < 2 {
		eprintln(usage)
		exit(2)
	}
	match args[0] {
		'dump' {
			ns := args[1] == '--ns'
			if args.len != (if ns { 3 } else { 2 }) {
				eprintln(usage)
				exit(2)
			}
			dump_events(args[args.len - 1], ns)
		}
		'schema' {
			if args[1] == '--batch' {
				schema_batch(args.len > 2 && args[2] == '--times')
				return
			}
			print_schema(args[1..]) or {
				eprintln(err)
				exit(1)
			}
		}
		'validate' {
			if args[1] == '--batch' {
				validate_batch(args.len > 2 && args[2] == '--times')
				return
			}
			if args.len < 3 {
				eprintln(usage)
				exit(2)
			}
			if !validate_files(args[1], args[2..]) {
				exit(1)
			}
		}
		'match' {
			if args[1] != '--batch' {
				eprintln(usage)
				exit(2)
			}
			match_batch()
		}
		'stats' {
			parse_only := args[1] == '--parse-only'
			mut failed := false
			for p in args[if parse_only { 2 } else { 1 }..] {
				print_stats(p, parse_only) or {
					eprintln(err)
					failed = true
				}
			}
			if failed {
				exit(1)
			}
		}
		else {
			eprintln(usage)
			exit(2)
		}
	}
}

// schema_batch compiles one schema per line of stdin, for test runners that would otherwise
// start a process per schema. With times, the time spent compiling (and nothing else: not
// reading stdin, not answering) is written to stderr at the end, as `time <microseconds>`.
fn schema_batch(times bool) {
	mut out := os.stdout()
	mut spent := time.Duration(0)
	for {
		line := os.get_raw_line()
		if line == '' {
			break
		}
		paths := line.trim_right('\r\n').split('\t')
		sw := time.new_stopwatch()
		mut answer := 'ok\n'
		xsd.load(...paths) or { answer = 'error\t${one_line(err.msg())}\n' }
		spent += sw.elapsed()
		write_or_exit(mut out, answer)
		out.flush()
	}
	if times {
		eprintln('time ${spent.microseconds()}')
	}
}

// validate_files checks each document against the schema and prints its findings; false when
// any document is invalid or cannot be read.
fn validate_files(schema string, docs []string) bool {
	s := xsd.load(schema) or {
		eprintln(err)
		return false
	}
	mut all_valid := true
	for path in docs {
		mut d := flatxml.parse_file(path) or {
			eprintln(err)
			all_valid = false
			continue
		}
		sw := time.new_stopwatch()
		v := xsd.validate(mut d, s) or {
			eprintln(err)
			all_valid = false
			d.free()
			continue
		}
		took := sw.elapsed()
		if v.valid() {
			println('${path}: valid (${ms(took)})')
		} else {
			all_valid = false
			lines := d.line_index()
			for f in v.findings {
				line, col := lines.line_col(d.src_off[f.node])
				println('${path}:${line}:${col}: ${f.msg}')
			}
			more := if v.total > v.findings.len { ', ${v.findings.len} shown' } else { '' }
			noun := if v.total == 1 { 'finding' } else { 'findings' }
			println('${path}: ${v.total} ${noun}${more} (${ms(took)})')
		}
		d.free()
	}
	return all_valid
}

// validate_batch checks one document per stdin line against the schema documents after it,
// keeping each compiled schema for the lines that name it again. With times, the time spent
// reading and validating documents (not compiling their schemas) is written to stderr at the
// end, as `time <microseconds>`.
fn validate_batch(times bool) {
	mut out := os.stdout()
	mut schemas := map[string]&xsd.Schema{}
	mut spent := time.Duration(0)
	for {
		line := os.get_raw_line()
		if line == '' {
			break
		}
		fields := line.trim_right('\r\n').split('\t')
		if fields.len < 2 || fields.any(it == '') {
			write_or_exit(mut out, 'error\ta line is a document, then its schema documents\n')
			out.flush()
			continue
		}
		key := fields[1..].join('\t')
		if key !in schemas {
			schemas[key] = xsd.load(...fields[1..]) or {
				write_or_exit(mut out, 'error\tschema: ${one_line(err.msg())}\n')
				out.flush()
				continue
			}
		}
		s := schemas[key] or { continue }
		sw := time.new_stopwatch()
		answer := check_one(fields[0], s)
		spent += sw.elapsed()
		write_or_exit(mut out, answer + '\n')
		out.flush()
	}
	if times {
		eprintln('time ${spent.microseconds()}')
	}
}

fn check_one(path string, s &xsd.Schema) string {
	mut d := flatxml.parse_file(path) or { return 'error\t${one_line(err.msg())}' }
	defer {
		d.free()
	}
	v := xsd.validate(mut d, s, max_findings: 1) or {
		return 'error\t${one_line(err.msg())}'
	}
	if v.valid() {
		return 'valid'
	}
	f := v.findings[0]
	return 'invalid\t${f.kind}\t${one_line(f.msg)}'
}

// match_batch answers, for each `pattern<TAB>string` line of stdin, whether the XSD pattern
// matches the whole string, keeping each compiled pattern for the lines that repeat it.
fn match_batch() {
	mut out := os.stdout()
	mut compiled := map[string]xsd.Pattern{}
	mut failed := map[string]string{}
	mut sc := xsd.Scratch{}
	for {
		line := os.get_raw_line()
		if line == '' {
			break
		}
		fields := line.trim_right('\r\n').split_nth('\t', 2)
		if fields.len != 2 {
			write_or_exit(mut out, 'error\ta line is a pattern, a tab, then the string\n')
			out.flush()
			continue
		}
		pattern, text := fields[0], fields[1]
		if pattern in failed {
			write_or_exit(mut out, 'error\t${failed[pattern]}\n')
			out.flush()
			continue
		}
		if pattern !in compiled {
			compiled[pattern] = xsd.compile_pattern(pattern) or {
				failed[pattern] = one_line(err.msg())
				write_or_exit(mut out, 'error\t${failed[pattern]}\n')
				out.flush()
				continue
			}
		}
		pat := compiled[pattern] or { continue }
		write_or_exit(mut out, if pat.matches_in(mut sc, text) { 'yes\n' } else { 'no\n' })
		out.flush()
	}
}

// print_schema compiles the schema documents at paths and counts what they declare.
fn print_schema(paths []string) ! {
	sw := time.new_stopwatch()
	s := xsd.load(...paths)!
	took := sw.elapsed()
	mut named_ct, mut named_st := 0, 0
	for ct in s.complex_types {
		if ct.name.local != 0 {
			named_ct++
		}
	}
	for st in s.simple_types {
		if st.name.local != 0 {
			named_st++
		}
	}
	mut enums, mut patterns := 0, map[string]bool{}
	for st in s.simple_types {
		enums += st.enums.len
		for p in st.patterns {
			patterns[p] = true
		}
	}
	println('${s.files.len} schema documents, compiled in ${ms(took)}')
	println('  ${s.global_elements().len} global elements, ${s.elements.len} element declarations')
	println('  ${s.complex_types.len} complex types (${named_ct} named), ${s.simple_types.len} simple types (${named_st} named)')
	println('  ${s.attributes.len} attribute declarations, ${s.particles.len - 1} particles')
	println('  ${enums} enumeration values, ${patterns.len} distinct patterns, ${s.appinfo.len} appinfo')
	for n in s.notes {
		println('  note: ${n}')
	}
}

// print_stats parses one file and prints what it holds and how long the parse took.
fn print_stats(path string, parse_only bool) ! {
	sw := time.new_stopwatch()
	mut d := flatxml.parse_file(path)!
	took := sw.elapsed()
	used, reserved := d.node_bytes()
	texts := d.text_node_count()
	println('${path}')
	println('  ${mb(d.src_len)}, parsed in ${ms(took)} ${rate(d.src_len, took)}')
	println('  ${d.len() - 1 - texts} elements, ${texts} text nodes, ${d.attr_tag.len} attributes, ${d.names.len - 2} distinct names')
	println('  node arrays ${mb(used)} used, ${mb(reserved)} reserved')
	if parse_only {
		d.free()
		return
	}
	ns_sw := time.new_stopwatch()
	if _ := d.resolve_namespaces() {
		ns_took := ns_sw.elapsed()
		println('  namespaces resolved in ${ms(ns_took)} (${f64(ns_took) * 100 / f64(took):.1f}% of the parse), ${d.ns_uris.len - 3} declared')
	} else {
		println('  namespaces: ${err}')
	}
	d.free()
}

// dump_events writes `E depth name attr=value...` per element and `T depth text` per run of text,
// the text decoded and trimmed, and empty runs left out; depth is the containing element's. With
// ns, names are `{uri}local` (or `local` in no namespace) and namespace declarations are left out.
fn dump_events(path string, ns bool) {
	mut d := flatxml.parse_file(path) or {
		eprintln(err)
		exit(1)
	}
	if ns {
		d.resolve_namespaces() or {
			eprintln(err)
			exit(1)
		}
	}
	mut out := os.stdout()
	mut sb := strings.new_builder(1 << 20)
	mut depth := []u32{len: d.len()}
	mut run := strings.new_builder(256)
	mut run_parent := u32(0)
	// Walk the nodes in document order; a run of text nodes under one parent is joined into one line.
	for k in 1 .. d.len() {
		i := u32(k)
		p := d.parent[i]
		depth[k] = depth[p] + 1
		if d.is_text(i) {
			if run.len > 0 && run_parent != p {
				flush_run(mut sb, mut run, depth[run_parent])
			}
			run.write_string(d.text(i))
			run_parent = p
			continue
		}
		if run.len > 0 {
			flush_run(mut sb, mut run, depth[run_parent])
		}
		if ns {
			sb.write_string('E ${depth[k]} ${expanded(d.ns_uri(d.ns_of(i)), d.local_name(i))}')
		} else {
			sb.write_string('E ${depth[k]} ${d.name(i)}')
		}
		lo, hi := d.attr_range(i)
		for a := lo; a < hi; a++ {
			if !ns {
				sb.write_string(' ${d.attr_name(a)}=${esc(d.attr_value(a))}')
			} else if !d.is_ns_decl(a) {
				name := expanded(d.ns_uri(d.attr_ns_of(a)), d.attr_local_name(a))
				sb.write_string(' ${name}=${esc(d.attr_value(a))}')
			}
		}
		sb.write_u8(`\n`)
		if d.text_len[i] != 0 {
			run.write_string(d.text(i))
			flush_run(mut sb, mut run, depth[k])
		}
		if sb.len > 1 << 20 {
			write_or_exit(mut out, sb.str())
		}
	}
	if run.len > 0 {
		flush_run(mut sb, mut run, depth[run_parent])
	}
	write_or_exit(mut out, sb.str())
}

// one_line is s as one line of a batch answer: every control character a space, so a quoted value
// cannot split the answer.
fn one_line(s string) string {
	if !s.bytes().any(it < 0x20) {
		return s
	}
	return s.bytes().map(if it < 0x20 { u8(` `) } else { it }).bytestr()
}

// write_or_exit writes s, or exits with status 1: a truncated dump must not look like a whole one.
fn write_or_exit(mut out os.File, s string) {
	out.write_string(s) or {
		eprintln('flatxml: ${err}')
		exit(1)
	}
}

fn expanded(uri string, local string) string {
	return if uri == '' { local } else { '{${uri}}${local}' }
}

fn flush_run(mut sb strings.Builder, mut run strings.Builder, depth u32) {
	t := run.str().trim(' \t\n\r')
	if t.len > 0 {
		sb.write_string('T ${depth} ${esc(t)}\n')
	}
}

fn esc(s string) string {
	return s.replace('\\', '\\\\').replace('\n', '\\n').replace('\t', '\\t').replace('\r', '\\r')
}

fn mb(b i64) string {
	return '${f64(b) / (1024 * 1024):.1f} MB'
}

fn ms(d time.Duration) string {
	return '${f64(d.microseconds()) / 1000:.1f} ms'
}

fn rate(b i64, d time.Duration) string {
	s := f64(d.microseconds()) / 1e6
	if s <= 0 {
		return ''
	}
	return '(${f64(b) / (1024 * 1024) / s:.1f} MB/s)'
}
