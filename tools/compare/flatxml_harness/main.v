// The flatxml harness for tools/compare/run.sh: read the file, then time the parse of the bytes,
// as the other harnesses do.
module main

import flatxml
import os
import time

fn main() {
	data := os.read_bytes(os.args[1]) or { panic(err) }
	sw := time.new_stopwatch()
	mut d := flatxml.parse_bytes(data, os.args[1]) or {
		println('error: ${err}')
		exit(1)
	}
	took := sw.elapsed()
	s := f64(took.microseconds()) / 1e6
	println('flatxml: ${s * 1e3:.1f} ms, ${f64(data.len) / 1048576.0 / s:.0f} MB/s, ${d.len()} nodes')
	d.free()
}
