// flatxml — command-line access to the parser.
//
//   flatxml dump [--ns] <file>     one line per element and per run of text, for
//                                  tools/check_vs_expat.py; --ns resolves namespaces
//   flatxml stats [--parse-only] <file>...   parse each file and print its size, node counts and
//                                  parse time, and (unless --parse-only) the time namespace
//                                  resolution adds
//   flatxml set [--ns] [--jobs N] [--ext EXT] <file|dir>...   read many files as one set (a
//                                  directory: every file below it ending in EXT, default .xml)
//                                  and print what they hold and how long it took
//   flatxml write [--nodes|--rewrite] <in> <out>   write a document back as XML (to stdout for
//                                  `-`): its bytes (the default), node by node, or every node
//                                  from the tree
//   flatxml roundtrip [--nodes|--rewrite] [--ext EXT] <file|dir>...   write each document and
//                                  compare: the same bytes as the file, or with --rewrite the
//                                  same tree; prints the files that differ and a count
//   flatxml diff [--rules <file>] [--ns] [--jobs N] [--ext EXT] [--brief] <A> <B>   the changes
//                                  that make A into B, one a line, and their counts; A and B are
//                                  each a file, a directory or @list (a file naming one a line),
//                                  read as one set, merged by the rules (none: as written).
//                                  Exits 0 when they are the same, 1 when they differ, 2 on trouble
//   flatxml edit <in> <out|-> <script|->   apply a script of edits (see `edit_doc`) to a
//                                  document and write it, every byte no edit touched kept
//   flatxml apply [--rules <file>] [--ns] [--jobs N] [--ext EXT] [--check] <OLD> <NEW> <OUT>
//   flatxml apply ... --in-place <OLD> <NEW>   the diff from OLD to NEW (as `diff` makes it),
//                                  applied to OLD's files and written to OUT: a file for a file,
//                                  a directory for a set, each document at its place relative to
//                                  OLD (unchanged ones copied), or over OLD's own files. A new
//                                  element goes to the file of OLD named like the NEW file it
//                                  comes from, where its parent has a fragment there. --check
//                                  reads what was written and diffs it against NEW. Exits 0 when
//                                  it applied (and checked), 1 when the check finds a change, 2
//                                  on trouble
//   flatxml merge --rules <file> [--ns] [--jobs N] [--ext EXT] [--problems N] [--lookups]
//                 <file|dir>...    read many files as one set and merge them by the rules
//                                  (`flatxml.parse_rules`): the merged view's size, its time,
//                                  and what the rules forbid (the first N, default 10);
//                                  --lookups times finding every node again; -o OUT (--out)
//                                  writes the merged view to OUT as one document
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
import io
import os
import strings
import time

const usage = 'usage:
  flatxml dump [--ns] <file>    canonical element/text stream, for tools/check_vs_expat.py;
                                --ns names elements and attributes {uri}local
  flatxml stats [--parse-only] <file>...   size, node counts, parse and namespace times
  flatxml set [--ns] [--jobs N] [--ext EXT] <file|dir>...   many files as one set, timed
  flatxml write [--nodes|--rewrite] <in> <out|->   write a document back as XML
  flatxml roundtrip [--nodes|--rewrite] [--ext EXT] <file|dir>...   write and compare each
  flatxml edit <in> <out|-> <script|->   apply a script of edits and write the document
  flatxml apply [--rules <file>] [--ns] [--jobs N] [--ext EXT] [--check] <OLD> <NEW> <OUT>
  flatxml apply [...] --in-place <OLD> <NEW>
                                the diff from OLD to NEW applied to the files of OLD, written to OUT
  flatxml merge --rules <file> [--ns] [--jobs N] [--ext EXT] [--problems N] [--lookups] [-o OUT] <file|dir>...
                                many files merged by rules: the view, its time, the problems
  flatxml diff [--rules <file>] [--ns] [--jobs N] [--ext EXT] [--brief] <A> <B>
                                what changed from A to B (each a file, a directory or @list)
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
		'set' {
			load_set(args[1..])
		}
		'write' {
			write_doc(args[1..])
		}
		'roundtrip' {
			if !round_trip(args[1..]) {
				exit(1)
			}
		}
		'edit' {
			if args.len != 4 {
				eprintln(usage)
				exit(2)
			}
			edit_doc(args[1], args[2], args[3]) or {
				eprintln('flatxml: ${err}')
				exit(1)
			}
		}
		'merge' {
			merge_set(args[1..])
		}
		'diff' {
			diff_sets(args[1..])
		}
		'apply' {
			apply_sets(args[1..])
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
	println('  ${d.len() - 1 - texts} elements, ${texts} text nodes, ${d.attr_tag.len} attributes, ${d.tab.len() - 2} distinct names')
	println('  node arrays ${mb(used)} used, ${mb(reserved)} reserved')
	if parse_only {
		d.free()
		return
	}
	ns_sw := time.new_stopwatch()
	if _ := d.resolve_namespaces() {
		ns_took := ns_sw.elapsed()
		println('  namespaces resolved in ${ms(ns_took)} (${f64(ns_took) * 100 / f64(took):.1f}% of the parse), ${d.tab.uri_count() - 3} declared')
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
	dump_tree(d, ns, true, mut out) or {
		eprintln('flatxml: ${err}')
		exit(1)
	}
}

// dump_tree writes the lines of `flatxml dump` for d to out. With trim, a run of text is written
// without its leading and trailing whitespace, and not at all when that is all it holds, as
// tools/check_vs_expat.py compares it; without, every run as it reads.
fn dump_tree(d &flatxml.Doc, ns bool, trim bool, mut out io.Writer) ! {
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
				flush_run(mut sb, mut run, depth[run_parent], trim)
			}
			run.write_string(d.text(i))
			run_parent = p
			continue
		}
		if run.len > 0 {
			flush_run(mut sb, mut run, depth[run_parent], trim)
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
			flush_run(mut sb, mut run, depth[k], trim)
		}
		if sb.len > 1 << 20 {
			flatxml.write_all(mut out, sb)!
			sb.go_back_to(0)
		}
	}
	if run.len > 0 {
		flush_run(mut sb, mut run, depth[run_parent], trim)
	}
	flatxml.write_all(mut out, sb)!
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

fn flush_run(mut sb strings.Builder, mut run strings.Builder, depth u32, trim bool) {
	t := if trim { run.str().trim(' \t\n\r') } else { run.str() }
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

// SetArgs is what the commands that read a set take: files and directories, and how to read them.
struct SetArgs {
mut:
	ns       bool
	jobs     int
	ext      string = '.xml'
	paths    []string
	rules    string // merge: the rules file
	problems int = 10 // merge: how many problems to print
	lookups  bool // merge: time looking every node up
	brief    bool // diff: the counts only
	check    bool // apply: read what was written and diff it against the new version
	in_place bool // apply: write the edited files over the old ones
	out      string // merge: where to write the merged view as one document
}

// set_flags are the flags each command that reads a set takes.
const set_flags = {
	'set':   ['--ns', '--jobs', '--ext']
	'merge': ['--ns', '--jobs', '--ext', '--rules', '--problems', '--lookups', '--out']
	'diff':  ['--ns', '--jobs', '--ext', '--rules', '--brief']
	'apply': ['--ns', '--jobs', '--ext', '--rules', '--check', '--in-place']
}

// read_set_args reads the arguments of `set`, `merge` or `diff` (cmd), and exits with the usage on
// a flag the command does not take or a value it cannot use.
fn read_set_args(args []string, cmd string) SetArgs {
	mut a := SetArgs{}
	mut k := 0
	for k < args.len {
		if args[k].starts_with('--') && args[k] !in set_flags[cmd] {
			eprintln('flatxml ${cmd}: ${args[k]} is not one of its flags\n${usage}')
			exit(2)
		}
		if args[k] in ['--jobs', '--ext', '--rules', '--problems', '--out', '-o'] && k + 1 == args.len {
			eprintln('flatxml ${cmd}: ${args[k]} takes a value\n${usage}')
			exit(2)
		}
		match args[k] {
			'--ns' {
				a.ns = true
			}
			'--jobs' {
				k++
				a.jobs = if k < args.len { args[k].int() } else { 0 }
			}
			'--ext' {
				k++
				a.ext = if k < args.len { args[k] } else { a.ext }
			}
			'--rules' {
				k++
				a.rules = if k < args.len { args[k] } else { '' }
			}
			'--problems' {
				k++
				n := if k < args.len { args[k] } else { '' }
				a.problems = n.int()
				if '${a.problems}' != n || a.problems < 0 {
					eprintln('flatxml merge: --problems takes a count, not `${n}`\n${usage}')
					exit(2)
				}
			}
			'--lookups' {
				a.lookups = true
			}
			'--brief' {
				a.brief = true
			}
			'--check' {
				a.check = true
			}
			'--in-place' {
				a.in_place = true
			}
			'--out', '-o' {
				if cmd != 'merge' {
					eprintln('flatxml ${cmd}: ${args[k]} is not one of its flags\n${usage}')
					exit(2)
				}
				k++
				a.out = args[k]
			}
			else {
				a.paths << args[k]
			}
		}
		k++
	}
	return a
}

// files lists the files named and those below the directories named, ending in ext.
fn (a &SetArgs) files() []string {
	mut files := []string{}
	for p in a.paths {
		files << a.files_of(p)
	}
	return files
}

// files_of is the files one operand names: a file, every file below a directory ending in ext,
// or, for `@list`, the files and directories list names, one a line, a relative one from the
// list's directory. A list cannot name another.
fn (a &SetArgs) files_of(p string) []string {
	if p.starts_with('@') {
		list := p[1..]
		mut files := []string{}
		for line in os.read_lines(list) or {
			eprintln('flatxml: ${err}')
			exit(2)
		} {
			name := line.trim_space()
			if name == '' {
				continue
			}
			if name.starts_with('@') {
				eprintln('flatxml: ${list}: names another list, ${name}')
				exit(2)
			}
			files << a.files_of(if os.is_abs_path(name) {
				name
			} else {
				os.join_path(os.dir(list), name)
			})
		}
		return files
	}
	if os.is_dir(p) {
		mut found := os.walk_ext(p, a.ext)
		found.sort()
		return found
	}
	return [p]
}

// load_set reads files and directories as one document set and prints what it holds.
fn load_set(args []string) {
	a := read_set_args(args, 'set')
	sw := time.new_stopwatch()
	files := a.files()
	listed := sw.elapsed()
	mut s := flatxml.DocSet.new()
	errs := s.load(files, jobs: a.jobs, namespaces: a.ns)
	took := sw.elapsed() - listed
	mut bytes := i64(0)
	mut nodes := 0
	mut attrs := 0
	for d in s.docs {
		bytes += d.src_len
		nodes += d.len() - 1
		attrs += d.attr_tag.len
	}
	println('${s.docs.len} files, ${mb(bytes)}, listed in ${ms(listed)}, read in ${ms(took)} ${rate(bytes, took)}')
	println('  ${nodes} nodes, ${attrs} attributes, ${s.tab.len() - 2} distinct names')
	for e in errs {
		println('  failed: ${one_line(e.msg)}')
	}
	if errs.len > 0 {
		exit(1)
	}
}

// write_mode reads a leading `--nodes` or `--rewrite` off args.
fn write_mode(args []string) (flatxml.WriteMode, []string) {
	if args.len > 0 && args[0] == '--nodes' {
		return .nodes, args[1..]
	}
	if args.len > 0 && args[0] == '--rewrite' {
		return .rewrite, args[1..]
	}
	return .verbatim, args
}

fn write_doc(args []string) {
	mode, rest := write_mode(args)
	if rest.len != 2 {
		eprintln(usage)
		exit(2)
	}
	mut d := flatxml.parse_file(rest[0]) or {
		eprintln(err)
		exit(1)
	}
	if rest[1] == '-' {
		mut out := os.stdout()
		d.write(mut out, mode: mode) or {
			eprintln('flatxml: ${err}')
			exit(1)
		}
	} else {
		d.write_file(rest[1], mode: mode) or {
			eprintln('flatxml: ${rest[1]}: ${err}')
			exit(1)
		}
	}
	d.free()
}

// round_trip writes every document named (a directory: every file below it ending in EXT,
// default .xml) and compares the result with it, printing each one that differs or does not
// parse; false when there is one.
fn round_trip(args []string) bool {
	mode, mut rest := write_mode(args)
	mut ext := '.xml'
	if rest.len > 1 && rest[0] == '--ext' {
		ext = rest[1]
		rest = rest[2..].clone()
	}
	if rest.len == 0 {
		eprintln(usage)
		exit(2)
	}
	mut files := []string{}
	for p in rest {
		if os.is_dir(p) {
			mut found := os.walk_ext(p, ext)
			found.sort()
			files << found
		} else {
			files << p
		}
	}
	mut same := 0
	mut bytes := i64(0)
	mut bad := []string{}
	mut write_time := time.Duration(0)
	for f in files {
		mut d := flatxml.parse_file(f) or {
			bad << 'does not parse: ${one_line(err.msg())}'
			continue
		}
		mut out := strings.new_builder(d.src_len)
		sw := time.new_stopwatch()
		d.write(mut out, mode: mode) or {
			bad << '${f}: ${err}'
			d.free()
			continue
		}
		write_time += sw.elapsed()
		bytes += d.src_len
		if mode != .rewrite {
			if out.len == d.src_len && unsafe { C.memcmp(out.data, d.src, d.src_len) } == 0 {
				same++
			} else {
				bad << '${f}: different bytes'
			}
		} else if diff := tree_difference(d, out.str()) {
			bad << '${f}: ${diff}'
		} else {
			same++
		}
		d.free()
	}
	for b in bad {
		println(b)
	}
	what := if mode == .rewrite { 'the same tree' } else { 'identical' }
	println('${same} of ${files.len} files ${what} (${mb(bytes)} written in ${ms(write_time)})')
	return bad.len == 0
}

// tree_difference is why the document xml does not read as the same tree as d, if it does not:
// compared as `flatxml dump` writes them, with every run of text as it reads, whitespace included.
fn tree_difference(d &flatxml.Doc, xml string) ?string {
	mut again := flatxml.parse_string(xml) or { return 'written, it does not parse: ${err}' }
	mut a := strings.new_builder(1 << 20)
	mut b := strings.new_builder(1 << 20)
	dump_tree(d, false, false, mut a) or { return err.msg() }
	dump_tree(again, false, false, mut b) or { return err.msg() }
	ta := a.str()
	tb := b.str()
	again.free()
	if ta == tb {
		return none
	}
	la := ta.split_into_lines()
	lb := tb.split_into_lines()
	for k in 0 .. la.len {
		if k >= lb.len || la[k] != lb[k] {
			return 'a different tree at dump line ${k + 1}'
		}
	}
	return 'a different tree after dump line ${la.len}'
}

// merge_set reads files and directories as one set, merges them by a rules file
// (`flatxml.parse_rules`), and prints what the view holds and what the rules forbid. It exits 1
// when a file fails to read or the rules find a problem.
fn merge_set(args []string) {
	a := read_set_args(args, 'merge')
	if a.rules == '' || a.paths.len == 0 {
		eprintln(usage)
		exit(2)
	}
	rules := flatxml.parse_rules(os.read_file(a.rules) or {
		eprintln(err)
		exit(1)
	}) or {
		eprintln('${a.rules}: ${err}')
		exit(1)
	}
	sw := time.new_stopwatch()
	mut s := flatxml.DocSet.new()
	errs := s.load(a.files(), jobs: a.jobs, namespaces: a.ns)
	read := sw.elapsed()
	mut m := s.merge(rules) or {
		eprintln(err)
		exit(1)
	}
	merged := sw.elapsed() - read
	mut nodes := 0
	for d in s.docs {
		nodes += d.len() - 1 - d.text_node_count()
	}
	println('${s.docs.len} files, ${nodes} elements, read in ${ms(read)}')
	println('merged in ${ms(merged)}: ${m.len()} nodes from ${m.fragment_total()} contributions, ${m.problems.len} problems')
	mut by_kind := map[string]int{}
	for p in m.problems {
		by_kind['${p.kind}']++
	}
	for kind, n in by_kind {
		println('  ${kind}: ${n}')
	}
	for p in m.problems#[..a.problems] {
		println('  ${one_line(m.describe(p))}')
	}
	if a.lookups {
		time_lookups(m)
	}
	if a.out != '' {
		ws := time.new_stopwatch()
		m.write_file(a.out) or {
			eprintln('flatxml merge: ${a.out}: ${err}')
			exit(1)
		}
		println('written to ${a.out} in ${ms(ws.elapsed())}: ${mb(os.file_size(a.out))}')
	}
	for e in errs {
		println('  failed: ${one_line(e.msg)}')
	}
	if errs.len > 0 || m.problems.len > 0 {
		exit(1)
	}
}

// time_lookups finds every keyed node again by its key path, and every node identified by its
// name (and key) from its parent, and prints how long each took.
fn time_lookups(m &flatxml.Merged) {
	mut paths := [][]string{}
	mut named := []flatxml.MNode{}
	for i in 0 .. m.len() {
		n := m.node(u32(i))
		if n.keyed() {
			kp := n.key_path()
			if kp.len > 0 {
				paths << kp
			}
		}
		if n.parent().ok() && n.parent().child_id(n.tag(), n.key()).i == n.i {
			named << n
		}
	}
	mut sw := time.new_stopwatch()
	mut found := 0
	for p in paths {
		if m.by_keys(p).ok() {
			found++
		}
	}
	by_path := sw.elapsed()
	sw.restart()
	mut found_named := 0
	for n in named {
		if n.parent().child_id(n.tag(), n.key()).ok() {
			found_named++
		}
	}
	by_name := sw.elapsed()
	println('lookups: ${found} of ${paths.len} key paths in ${ms(by_path)}, ${found_named} children by name and key in ${ms(by_name)}')
}

// read_rules is the rules file named, read; none when none is named. It exits 2 when it cannot.
fn (a &SetArgs) read_rules() flatxml.RuleSet {
	if a.rules == '' {
		return flatxml.RuleSet{}
	}
	return flatxml.parse_rules(os.read_file(a.rules) or {
		eprintln(err)
		exit(2)
	}) or {
		eprintln('${a.rules}: ${err}')
		exit(2)
	}
}

// read_view reads the files operand p names as one set and merges it by the rules, saying how
// many problems the rules find. It exits 2 when a file cannot be read.
fn (a &SetArgs) read_view(p string, rules flatxml.RuleSet, cmd string) &flatxml.Merged {
	mut s := flatxml.DocSet.new()
	errs := s.load(a.files_of(p), jobs: a.jobs, namespaces: a.ns)
	for e in errs {
		eprintln('flatxml ${cmd}: ${one_line(e.msg)}')
	}
	if errs.len > 0 {
		exit(2)
	}
	v := s.merge(rules) or {
		eprintln(err)
		exit(2)
	}
	if v.problems.len > 0 {
		eprintln('flatxml ${cmd}: ${p}: the rules find ${v.problems.len} problems (see flatxml merge)')
	}
	return v
}

// diff_sets reads two sets, merges each by the rules (none: each as written), and prints the
// changes from the first to the second and their counts. It exits 0 when there are none, 1 when
// there are, and 2 when a file or the rules cannot be read.
fn diff_sets(args []string) {
	a := read_set_args(args, 'diff')
	if a.paths.len != 2 {
		eprintln(usage)
		exit(2)
	}
	rules := a.read_rules()
	sw := time.new_stopwatch()
	views := [a.read_view(a.paths[0], rules, 'diff'), a.read_view(a.paths[1], rules, 'diff')]
	read := sw.elapsed()
	mut d := flatxml.diff(views[0], views[1])
	compared := sw.elapsed() - read
	mut out := os.stdout()
	mut counts := map[string]int{}
	for k in 0 .. d.changes.len {
		c := d.changes[k]
		counts['${c.kind}']++
		if !a.brief {
			write_or_exit(mut out, d.describe(c) + '\n')
		}
	}
	mut parts := []string{}
	for kind in ['removed', 'added', 'moved', 'text', 'attr'] {
		if n := counts[kind] {
			parts << '${n} ${kind}'
		}
	}
	what := if parts.len == 0 {
		'no changes'
	} else {
		'${d.changes.len} changes: ${parts.join(', ')}'
	}
	println('${what} (${views[0].len()} and ${views[1].len()} nodes, ${d.compared()} pairs compared; read and merged in ${ms(read)}, compared in ${ms(compared)})')
	if d.changes.len > 0 {
		exit(1)
	}
}

// edit_doc applies the edit script at script ('-': stdin) to the document at path and writes it
// to out ('-': stdout). One edit per line, fields separated by tabs, values with `\\`, `\\t`,
// `\\n` and `\\r` for a backslash, tab, newline and carriage return. An element is named by its
// path of child element numbers from the root in the document as edited so far (`/` the root,
// `/0/2` the third child element of the root's first):
//
//   text PATH VALUE            set the element's own text
//   attr PATH NAME VALUE       set an attribute
//   noattr PATH NAME           remove an attribute
//   insert PATH INDEX XML      put the element XML under PATH as its child element INDEX
//   copy PATH INDEX FROM       put a copy of element FROM of the document as read there
//   remove PATH                remove the element
//   move PATH INDEX FROM       move element FROM there
fn edit_doc(path string, out string, script string) ! {
	mut d := flatxml.parse_file(path)!
	mut e := d.edit()
	lines := if script == '-' { os.get_lines() } else { os.read_lines(script)! }
	for n, line in lines {
		if line.trim_space() == '' {
			continue
		}
		f := line.split('\t').map(unescape_field(it))
		edit_line(mut e, d, f) or { return error('${script}:${n + 1}: ${err}') }
	}
	if out == '-' {
		mut o := os.stdout()
		e.write(mut o)!
	} else {
		e.write_file(out)!
	}
	e.free()
	d.free()
}

fn edit_line(mut e flatxml.Edit, d &flatxml.Doc, f []string) ! {
	want := match f[0] {
		'remove' { 2 }
		'text', 'noattr' { 3 }
		'attr', 'insert', 'copy', 'move' { 4 }
		else { return error('unknown edit `${f[0]}`') }
	}
	if f.len != want {
		return error('`${f[0]}` takes ${want - 1} fields')
	}
	n := edited_at(e, f[1])!
	match f[0] {
		'text' {
			e.set_text(n, f[2])!
		}
		'attr' {
			e.set_attr(n, f[2], f[3])!
		}
		'noattr' {
			e.remove_attr(n, f[2])!
		}
		'insert' {
			e.insert(n, field_index(f[2])!, f[3])!
		}
		'copy' {
			e.insert_copy(n, field_index(f[2])!, doc_at(d, f[3])!)!
		}
		'remove' {
			e.remove(n)!
		}
		else {
			e.move(edited_at(e, f[3])!, n, field_index(f[2])!)!
		}
	}
}

// edited_at is the element at path in the edited document.
fn edited_at(e &flatxml.Edit, path string) !flatxml.ENode {
	mut n := e.root()
	for part in path_parts(path)! {
		kids := n.children()
		k := part
		if k >= kids.len {
			return error('no element ${path}')
		}
		n = kids[k]
	}
	return n
}

// doc_at is the element at path in the document as read.
fn doc_at(d &flatxml.Doc, path string) !flatxml.Node {
	mut n := d.root_node()
	for part in path_parts(path)! {
		mut k := part
		mut found := flatxml.Node{}
		for c in n.children() {
			if k == 0 {
				found = c
				break
			}
			k--
		}
		if !found.ok() {
			return error('no element ${path}')
		}
		n = found
	}
	return n
}

// path_parts are the child element numbers of an element path: `/`, or `/` then numbers
// separated by `/`.
fn path_parts(path string) ![]int {
	if !path.starts_with('/') {
		return error('`${path}` is not a path: it starts with `/`')
	}
	if path == '/' {
		return []
	}
	return path[1..].split('/').map(field_index(it) or {
		return error('`${path}` is not a path: ${err}')
	})
}

// field_index reads a number: decimal digits and nothing else.
fn field_index(s string) !int {
	if s == '' || s.len > 9 || !s.bytes().all(it >= `0` && it <= `9`) {
		return error('`${s}` is not a number')
	}
	return s.int()
}

// unescape_field reads `\\`, `\\t`, `\\n` and `\\r` in an edit script's field.
fn unescape_field(s string) string {
	if !s.contains('\\') {
		return s
	}
	mut sb := strings.new_builder(s.len)
	mut k := 0
	for k < s.len {
		if s[k] == `\\` && k + 1 < s.len {
			sb.write_u8(match s[k + 1] {
				`t` { `\t` }
				`n` { `\n` }
				`r` { `\r` }
				else { s[k + 1] }
			})
			k += 2
			continue
		}
		sb.write_u8(s[k])
		k++
	}
	return sb.str()
}

// operand_root is the directory an operand's files are named relative to: a directory itself, a
// list's directory, or a file's.
fn operand_root(p string) string {
	if p.starts_with('@') {
		return os.dir(p[1..])
	}
	return if os.is_dir(p) { p } else { os.dir(p) }
}

// relative_to is path relative to root, where it is below it.
fn relative_to(path string, root string) ?string {
	prefix := os.real_path(root) + os.path_separator
	f := os.real_path(path)
	return if f.starts_with(prefix) { f[prefix.len..] } else { none }
}

// apply_sets reads OLD and NEW, diffs them as `diff` does, applies the diff to OLD's files, and
// writes them to OUT (or over OLD's files with --in-place), then, with --check, reads them back
// and diffs them against NEW.
fn apply_sets(args []string) {
	a := read_set_args(args, 'apply')
	if a.paths.len != if a.in_place { 2 } else { 3 } {
		eprintln(usage)
		exit(2)
	}
	rules := a.read_rules()
	sw := time.new_stopwatch()
	old := a.read_view(a.paths[0], rules, 'apply')
	new := a.read_view(a.paths[1], rules, 'apply')
	read := sw.elapsed()
	d := flatxml.diff(old, new)
	compared := sw.elapsed() - read
	// a new element goes to the file of OLD named like the file of NEW it comes from
	old_root, new_root := operand_root(a.paths[0]), operand_root(a.paths[1])
	// each document of OLD by its path relative to OLD, each of NEW to the one of OLD named alike
	mut old_names := []string{}
	mut by_name := map[string]int{}
	for k, doc in old.set.docs {
		name := relative_to(doc.path, old_root) or { '' }
		old_names << name
		if name != '' {
			by_name[name] = k
		}
	}
	mut to_old := map[u64]int{}
	for doc in new.set.docs {
		if name := relative_to(doc.path, new_root) {
			if k := by_name[name] {
				to_old[u64(voidptr(doc))] = k
			}
		}
	}
	into := fn [to_old] (f flatxml.Node, p flatxml.MNode) int {
		return to_old[u64(voidptr(f.doc))] or { -1 }
	}
	mut me := d.apply(into: into) or {
		eprintln('flatxml ${err}')
		exit(2)
	}
	applied := sw.elapsed() - read - compared
	mut out := ''
	if a.in_place {
		me.write_files() or {
			eprintln('flatxml apply: ${err}')
			exit(2)
		}
	} else {
		out = a.paths[2]
		single := old.set.docs.len == 1 && !os.is_dir(a.paths[0]) && !a.paths[0].starts_with('@')
		// a set's documents go to OUT at their places relative to OLD: one outside it has none
		if !single {
			for k, name in old_names {
				if name == '' {
					eprintln('flatxml apply: ${old.set.docs[k].path} is not below ${old_root}, so it has no place in ${out}')
					exit(2)
				}
			}
		}
		mut paths := map[u64]string{}
		for k, doc in old.set.docs {
			paths[u64(voidptr(doc))] = if single { out } else { os.join_path(out, old_names[k]) }
		}
		me.write_to(fn [paths] (doc &flatxml.Doc) string {
			return paths[u64(voidptr(doc))] or { '' }
		}) or {
			eprintln('flatxml apply: ${err}')
			exit(2)
		}
	}
	println('${d.changes.len} changes applied to ${me.edited().len} of ${old.set.docs.len} files (read and merged in ${ms(read)}, compared in ${ms(compared)}, applied in ${ms(applied)})')
	if !a.check {
		return
	}
	written := if a.in_place { a.paths[0] } else { out }
	back := a.read_view(written, rules, 'apply')
	again := flatxml.diff(back, new)
	if again.equal() {
		println('checked: ${written} and ${a.paths[1]} have no changes')
		return
	}
	println('checked: ${written} and ${a.paths[1]} still differ in ${again.changes.len} changes')
	exit(1)
}
