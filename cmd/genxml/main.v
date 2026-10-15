// genxml — write a synthetic XML document of about a given size, for benchmarks.
//
//   genxml <out.xml> <megabytes>
//
// An inventory of devices in sites of 1000: each device has attributes, a few text-only
// children, settings with a unit attribute, and a link to an earlier device; every 8th has a note
// with entities and mixed content, every 64th a CDATA section. 2-space indentation, as a tool
// would write it. Deterministic: the same size gives the same bytes.
module main

import os
import strings

const per_site = 1000
const header = '<?xml version="1.0" encoding="UTF-8"?>
<!-- Synthetic document written by flatxml cmd/genxml. -->
<inventory xmlns="urn:example:inventory" version="1">
'
const kinds = ['sensor', 'actuator', 'gateway', 'controller']
const units = ['ms', 'mV', 'rpm', 'percent']

fn main() {
	if os.args.len != 3 {
		eprintln('usage: genxml <out.xml> <megabytes>')
		exit(2)
	}
	want := os.args[2].i64() * 1024 * 1024
	if want <= 0 {
		eprintln('genxml: size must be a positive number of megabytes')
		exit(2)
	}
	mut f := os.create(os.args[1]) or {
		eprintln('genxml: ${err}')
		exit(1)
	}
	mut written := i64(0)
	mut sb := strings.new_builder(1 << 20)
	sb.write_string(header)
	mut n := 0
	// Write whole sites until the document reaches the requested size.
	for written + sb.len < want {
		sb.write_string('  <site id="s${n / per_site}">\n')
		for _ in 0 .. per_site {
			write_device(mut sb, n)
			n++
			if sb.len > 1 << 20 {
				// count before str(), which empties the builder
				written += i64(sb.len)
				f.write_string(sb.str()) or { exit(1) }
			}
		}
		sb.write_string('  </site>\n')
	}
	sb.write_string('</inventory>\n')
	written += i64(sb.len)
	f.write_string(sb.str()) or { exit(1) }
	f.close()
	println('${os.args[1]}: ${n} devices, ${written} bytes')
}

fn write_device(mut sb strings.Builder, n int) {
	sb.write_string('    <device id="d${n}" kind="${kinds[n % kinds.len]}">\n')
	sb.write_string('      <name>Device ${n}</name>\n')
	sb.write_string('      <serial>SN-${(n * 7919) % 1000003:07}</serial>\n')
	sb.write_string('      <enabled>${n % 3 != 0}</enabled>\n')
	sb.write_string('      <settings>\n')
	for k in 0 .. 3 {
		u := units[(n + k) % units.len]
		sb.write_string('        <setting key="p${k}" unit="${u}">${(n * 31 + k * 17) % 5000}</setting>\n')
	}
	sb.write_string('      </settings>\n')
	if n > 0 {
		sb.write_string('      <link ref="d${(n * 13) % n}"/>\n')
	}
	if n % 8 == 0 {
		sb.write_string('      <note>Checked &lt;${n}&gt; &amp; <em>passed</em>, see device ${n / 2}.</note>\n')
	}
	if n % 64 == 0 {
		sb.write_string('      <raw><![CDATA[<frame id="${n}"> & more]]></raw>\n')
	}
	sb.write_string('    </device>\n')
}
