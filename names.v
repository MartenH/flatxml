module flatxml

import hash

const name_seed = u64(0x9E37_79B9_7F4A_7C15)

fn (mut d Doc) init_names() {
	d.names = ['#text', '#document']
	d.name_hash = [u64(0), 0]
	d.name_slots = []u32{len: 1024}
}

// intern returns the id of the name in p[..len], adding it the first time it is seen. The
// table is keyed by the bytes in the source, so a name is copied once per Doc, not per use.
@[direct_array_access]
fn (mut d Doc) intern(p &u8, len int) u32 {
	h := hash.wyhash_c(p, u64(len), name_seed)
	mask := u64(d.name_slots.len - 1)
	mut k := h & mask
	for {
		id := d.name_slots[k]
		if id == 0 {
			break
		}
		if d.name_hash[id] == h {
			s := d.names[id]
			if s.len == len && unsafe { C.memcmp(s.str, p, len) } == 0 {
				return id
			}
		}
		k = (k + 1) & mask
	}
	id := u32(d.names.len)
	d.names << unsafe { tos(p, len) }.clone()
	d.name_hash << h
	d.name_slots[k] = id
	if d.names.len * 2 > d.name_slots.len {
		d.grow_names()
	}
	return id
}

fn (mut d Doc) grow_names() {
	d.name_slots = []u32{len: d.name_slots.len * 2}
	mask := u64(d.name_slots.len - 1)
	for id in 2 .. d.names.len {
		mut k := d.name_hash[id] & mask
		for d.name_slots[k] != 0 {
			k = (k + 1) & mask
		}
		d.name_slots[k] = u32(id)
	}
}

// name_id is the id of an element or attribute name, if the document uses it.
pub fn (d &Doc) name_id(name string) ?u32 {
	h := hash.wyhash_c(name.str, u64(name.len), name_seed)
	mask := u64(d.name_slots.len - 1)
	mut k := h & mask
	for {
		id := d.name_slots[k]
		if id == 0 {
			return none
		}
		if d.name_hash[id] == h && d.names[id] == name {
			return id
		}
		k = (k + 1) & mask
	}
	return none
}
