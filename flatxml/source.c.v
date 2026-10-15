module flatxml

import os

#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

// C's int is 32 bits; V3's int is 64, so C callbacks and returns are declared i32.
fn C.open(path &char, flags i32, mode i32) i32
fn C.close(fd i32) i32
fn C.madvise(addr voidptr, len usize, advice i32) i32
fn C.fchmod(fd i32, mode u32) i32

// Node and attribute offsets are stored as u32, so a document must be smaller than 4 GiB.
pub const max_src_len = int(u32(0xFFFF_FFFF))

// map_file maps the file at path read-only into memory.
fn map_file(path string) !(&u8, int) {
	if !os.is_file(path) {
		return error('${path}: not a file')
	}
	size := int(os.file_size(path))
	if size == 0 {
		return error('${path}: empty file')
	}
	if size > max_src_len {
		return error('${path}: files of 4 GiB or more are not supported (offsets are u32)')
	}
	fd := C.open(&char(path.str), C.O_RDONLY, 0)
	if fd < 0 {
		return error('${path}: cannot open file')
	}
	p := unsafe { C.mmap(nil, usize(size), C.PROT_READ, C.MAP_PRIVATE, fd, 0) }
	C.close(fd)
	if u64(p) == max_u64 { // MAP_FAILED
		return error('${path}: cannot map file')
	}
	// One forward pass reads the whole file; ask the kernel to read ahead.
	unsafe { C.madvise(p, usize(size), C.MADV_SEQUENTIAL) }
	return unsafe { &u8(p) }, size
}

fn unmap_file(p &u8, len int) {
	unsafe { C.munmap(voidptr(p), usize(len)) }
}

// FileOut is a file opened for writing, whose every write and close is checked.
struct FileOut {
	path string
mut:
	fd i32 = -1
}

// create_file creates path, which must not exist, with the permission bits of mode.
fn create_file(path string, mode u32) !FileOut {
	fd := C.open(&char(path.str), C.O_WRONLY | C.O_CREAT | C.O_EXCL, i32(mode & 0o7777))
	if fd < 0 {
		return error('${path}: cannot create file')
	}
	// the mode given at creation is narrowed by the umask
	C.fchmod(fd, mode & 0o7777)
	return FileOut{
		path: path
		fd:   fd
	}
}

// write writes buf, at most 1 GiB per call.
fn (mut f FileOut) write(buf []u8) !int {
	n := C.write(f.fd, buf.data, usize(if buf.len > 1 << 30 { 1 << 30 } else { buf.len }))
	if n <= 0 {
		return error('${f.path}: write failed')
	}
	return int(n)
}

fn (mut f FileOut) close() ! {
	if f.fd >= 0 && C.close(f.fd) != 0 {
		f.fd = -1
		return error('${f.path}: write failed')
	}
	f.fd = -1
}
