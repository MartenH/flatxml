module flatxml

// A three-way merge: two changed versions of one base, put together on the base.
//
// Each version is compared with the base (`diff`), so both diffs name the base's nodes. Their
// changes are put together node by node: a change only one side makes is taken; the same change
// made on both sides is taken once; where the two change one node differently, that is a
// conflict, and ours is taken. The changes taken are applied to the base, ours first, then
// theirs read through ours (`Diff.apply_to`), so every byte no change touched stays as the base
// has it. A conflict is reported with the node's place in all three versions, and the result is
// still made, holding ours: a caller for whom a conflict is an error refuses it when there is one.
//
// The same is a patch: the changes from A to B, made on C, are the merge of C (ours) and B
// (theirs) on the base A.

// What two sides can disagree about.
pub enum ConflictKind {
	text    // the own text of one node, changed to two different texts
	attr    // one attribute of one node, set to two values, or set on one side and removed on the other
	removed // a node removed on one side and changed, or something below it changed, on the other
	moved   // a node moved to two different parents
}

// Conflict is a node both sides change differently: the base's node, and each side's change.
pub struct Conflict {
pub:
	kind   ConflictKind
	node   MNode  // the node of the base
	ours   Change // ours's change (from the base to ours)
	theirs Change // theirs's
	name   string // attr: the attribute's name
}

// Merge3 is a three-way merge: the two diffs from the base, the conflicts, and the edits on the
// base that make the result.
pub struct Merge3 {
pub:
	base      &Merged = unsafe { nil }
	ours      Diff
	theirs    Diff
	conflicts []Conflict
	taken     int // changes of theirs taken, besides all of ours
pub mut:
	edit &MEdit = unsafe { nil }
}

// merge3 merges ours and theirs, two changed versions of base, all read by the same rules: the
// result is edits on the base's documents (`edit`), written as `MEdit` writes them.
pub fn merge3(base &Merged, ours &Merged, theirs &Merged, opts ApplyOptions) !Merge3 {
	d1 := diff(base, ours)
	d2 := diff(base, theirs)
	mut m := Merge3{
		base:   base
		ours:   d1
		theirs: d2
	}
	keep, conflicts := combine(&m.ours, &m.theirs)
	mut me := m.ours.apply(opts)!
	mut rest := m.theirs
	rest.changes = keep
	rest.apply_to(mut me, opts)!
	return Merge3{
		...m
		conflicts: conflicts
		taken:     keep.len
		edit:      me
	}
}

// clean reports whether there is no conflict.
pub fn (m &Merge3) clean() bool {
	return m.conflicts.len == 0
}

// Side is what one side's diff does to the base's nodes.
struct Side {
mut:
	removed map[u32]int   // a base node removed -> its change
	moved   map[u32]int   // a base node moved -> its change
	text    map[u32]int   // a base node whose text changed -> its change
	attrs   map[u64]int   // (base node, attribute key) -> its change
	added   map[u32][]int // a base node -> the changes adding under it
	// a base node something is changed at (itself, or a child it gains), or above one
	touched map[u32]bool
}

fn side_of(d &Diff) Side {
	mut s := Side{}
	for k, c in d.changes {
		match c.kind {
			.removed {
				// a removal is not a change below for the other side: both removing is one
				s.removed[c.old.i] = k
			}
			.moved {
				s.moved[c.old.i] = k
				s.touched[c.old.i] = true
				s.touched[c.parent.i] = true
			}
			.text {
				s.text[c.old.i] = k
				s.touched[c.old.i] = true
			}
			.attr {
				s.attrs[mix(u64(c.old.i), c.akey)] = k
				s.touched[c.old.i] = true
			}
			.added {
				s.added[c.parent.i] << k
				s.touched[c.parent.i] = true
			}
		}
	}
	// and what is above each
	for t in s.touched.keys() {
		mut c := d.old.node(t).parent()
		for c.ok() && c.i !in s.touched {
			s.touched[c.i] = true
			c = c.parent()
		}
	}
	return s
}

// anchor is the base node change c is made at: the node it changes, or the one it puts a node
// under.
fn anchor_of(c Change) MNode {
	return if c.kind == .added { c.parent } else { c.old }
}

// removed_above is the change of side s that removes n or a node above it, if one does.
fn removed_above(s &Side, n MNode) ?int {
	mut c := n
	for c.ok() {
		if k := s.removed[c.i] {
			return k
		}
		c = c.parent()
	}
	return none
}

// combine is the changes of theirs to take after ours, and the conflicts: a change theirs alone
// makes is taken; one ours makes too, the same, is not taken again; one that disagrees with ours
// is a conflict, and not taken.
fn combine(d1 &Diff, d2 &Diff) ([]Change, []Conflict) {
	ours := side_of(d1)
	mut keep := []Change{}
	mut conflicts := []Conflict{}
	// nodes ours removes and theirs changes below, once each
	mut said := map[u32]bool{}
	for c in d2.changes {
		at := anchor_of(c)
		// below a node ours removes: theirs changes something that is gone
		if k := removed_above(&ours, at) {
			if c.kind == .removed {
				continue // removed by ours already, or with a node above it
			}
			r := d1.changes[k]
			if !said[r.old.i] {
				said[r.old.i] = true
				conflicts << Conflict{
					kind:   .removed
					node:   r.old
					ours:   r
					theirs: c
				}
			}
			continue
		}
		match c.kind {
			.removed {
				// theirs removes what ours changes: ours is kept
				if k := ours.moved[c.old.i] {
					conflicts << Conflict{
						kind:   .removed
						node:   c.old
						ours:   d1.changes[k]
						theirs: c
					}
					continue
				}
				if ours.touched[c.old.i] {
					mut first := d1.changes[0]
					for o in d1.changes {
						if anchor_of(o).ok() && is_below(anchor_of(o), c.old) {
							first = o
							break
						}
					}
					conflicts << Conflict{
						kind:   .removed
						node:   c.old
						ours:   first
						theirs: c
					}
					continue
				}
			}
			.moved {
				if k := ours.moved[c.old.i] {
					o := d1.changes[k]
					if o.parent.i != c.parent.i {
						conflicts << Conflict{
							kind:   .moved
							node:   c.old
							ours:   o
							theirs: c
						}
					}
					continue
				}
				if k := removed_above(&ours, c.parent) {
					conflicts << Conflict{
						kind:   .removed
						node:   d1.changes[k].old
						ours:   d1.changes[k]
						theirs: c
					}
					continue
				}
			}
			.text {
				if k := ours.text[c.old.i] {
					o := d1.changes[k]
					if o.runs != c.runs {
						conflicts << Conflict{
							kind:   .text
							node:   c.old
							ours:   o
							theirs: c
						}
					}
					continue
				}
			}
			.attr {
				key := mix(u64(c.old.i), c.akey)
				if k := ours.attrs[key] {
					o := d1.changes[k]
					if o.after != c.after {
						conflicts << Conflict{
							kind:   .attr
							node:   c.old
							ours:   o
							theirs: c
							name:   c.name
						}
					}
					continue
				}
			}
			.added {
				// the same subtree added under one node on both sides is one addition
				mut same := false
				for k in ours.added[c.parent.i] or { []int{} } {
					o := d1.changes[k]
					if d1.nhash[o.new.i] == d2.nhash[c.new.i] {
						same = true
						break
					}
				}
				if same {
					continue
				}
			}
		}
		keep << c
	}
	return keep, conflicts
}

// is_below reports whether n is m or below it.
fn is_below(n MNode, m MNode) bool {
	mut c := n
	for c.ok() {
		if c.i == m.i {
			return true
		}
		c = c.parent()
	}
	return false
}

// describe is a conflict in one line: what, where, and the node's place in the base and each
// side (`-` where a side removed it).
pub fn (mut m Merge3) describe(c Conflict) string {
	mut d1, mut d2 := m.ours, m.theirs
	what := match c.kind {
		.text {
			'text ${quoted(c.ours.after)} / ${quoted(c.theirs.after)}'
		}
		.attr {
			'@${c.name} ${quoted(c.ours.after)} / ${quoted(c.theirs.after)}'
		}
		.removed {
			'removed on one side, changed on the other (${c.ours.kind} / ${c.theirs.kind})'
		}
		.moved {
			'moved under ${d1.path(c.ours.parent)} / ${d2.path(c.theirs.parent)}'
		}
	}
	return '! ${d1.path(c.node)}: ${what}  base ${d1.pos(c.node)}, ours ${side_pos(mut d1, c.ours)}, theirs ${side_pos(mut d2, c.theirs)}'
}

// side_pos is where a side's change puts the node: its new node's position, or `-`.
fn side_pos(mut d Diff, c Change) string {
	return if c.new.ok() { d.pos(c.new) } else { '-' }
}
