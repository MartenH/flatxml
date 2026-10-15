// flatxml — command-line access to the parser.
//
//   flatxml dump [--ns] <file>     one line per element and per run of text, for
//                                  tools/check_vs_expat.py; --ns resolves namespaces
//   flatxml stats <file>...        parse each file and print its size, node counts and parse time,
//                                  and the time namespace resolution adds
//   flatxml schema <xsd>...        compile an XML Schema and print what it holds
//   flatxml schema --batch         compile one schema per stdin line (tab-separated documents),
//                                  answering `ok` or `error<TAB>message` per line
module main

import flatxml
import flatxml.xsd
import os
import strings
import time

const usage = 'usage:
  flatxml dump [--ns] <file>    canonical element/text stream, for tools/check_vs_expat.py;
                                --ns names elements and attributes {uri}local
  flatxml stats <file>...       size, node counts, parse and namespace times of each file
  flatxml schema <xsd>...       compile an XML Schema (and what it imports), print what it holds
  flatxml schema --batch        one schema per stdin line (documents tab-separated): ok | error<TAB>why'

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
				schema_batch()
				return
			}
			print_schema(args[1..]) or {
				eprintln(err)
				exit(1)
			}
		}
		'stats' {
			mut failed := false
			for p in args[1..] {
				print_stats(p) or {
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
// start a process per schema.
fn schema_batch() {
	mut out := os.stdout()
	for {
		line := os.get_raw_line()
		if line == '' {
			break
		}
		paths := line.trim_right('\r\n').split('\t')
		answer := if _ := xsd.load(...paths) {
			'ok\n'
		} else {
			'error\t${err.msg().replace('\n', ' ')}\n'
		}
		write_or_exit(mut out, answer)
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
fn print_stats(path string) ! {
	sw := time.new_stopwatch()
	mut d := flatxml.parse_file(path)!
	took := sw.elapsed()
	used, reserved := d.node_bytes()
	texts := d.text_node_count()
	println('${path}')
	println('  ${mb(d.src_len)}, parsed in ${ms(took)} ${rate(d.src_len, took)}')
	println('  ${d.len() - 1 - texts} elements, ${texts} text nodes, ${d.attr_tag.len} attributes, ${d.names.len - 2} distinct names')
	println('  node arrays ${mb(used)} used, ${mb(reserved)} reserved')
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
