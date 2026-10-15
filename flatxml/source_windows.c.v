module flatxml

import os

#include <io.h>
#include <fcntl.h>
#include <sys/stat.h>

// C's int is 32 bits; V3's int is 64, so C returns are declared i32.
fn C._write(fd i32, buf voidptr, n u32) i32
fn C._close(fd i32) i32
fn C._commit(fd i32) i32
fn C.MoveFileExW(src &u16, dst &u16, flags u32) i32

// Node and attribute offsets are stored as u32, so a document must be smaller than 4 GiB.
pub const max_src_len = int(u32(0xFFFF_FFFF))

// map_file reads the file at path into memory that unmap_file releases (Windows has no mmap of
// the POSIX kind; a mapping through the Windows API would keep the file locked while it is
// open).
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
	mut f := os.open(path) or { return error('${path}: cannot open file') }
	defer {
		f.close()
	}
	p := unsafe { &u8(C.malloc(usize(size))) }
	if p == unsafe { nil } {
		return error('${path}: out of memory')
	}
	mut got := 0
	for got < size {
		n := f.read_into_ptr(unsafe { p + got }, size - got) or {
			unsafe { C.free(p) }
			return error('${path}: cannot read file')
		}
		if n <= 0 {
			unsafe { C.free(p) }
			return error('${path}: cannot read file')
		}
		got += n
	}
	return p, size
}

fn unmap_file(p &u8, _ int) {
	unsafe { C.free(voidptr(p)) }
}

// FileOut is a file opened for writing, whose every write and close is checked.
struct FileOut {
	path string
mut:
	fd i32 = -1
}

// create_file creates path, which must not exist, for binary writing. Windows has no permission
// bits to keep: the mode given is not used.
fn create_file(path string, _ ?u32) !FileOut {
	fd := C._wopen(path.replace('/', '\\').to_wide(),
		C._O_WRONLY | C._O_CREAT | C._O_EXCL | C._O_BINARY, C._S_IREAD | C._S_IWRITE)
	if fd < 0 {
		return error('${path}: cannot create file')
	}
	return FileOut{
		path: path
		fd:   i32(fd)
	}
}

// write writes buf, at most 1 GiB per call.
fn (mut f FileOut) write(buf []u8) !int {
	n := C._write(f.fd, buf.data, u32(if buf.len > 1 << 30 { 1 << 30 } else { buf.len }))
	if n <= 0 {
		return error('${f.path}: write failed')
	}
	return int(n)
}

fn (mut f FileOut) close() ! {
	if f.fd >= 0 && C._close(f.fd) != 0 {
		f.fd = -1
		return error('${f.path}: write failed')
	}
	f.fd = -1
}

// sync_and_close puts the file's contents on disk, then closes it.
fn (mut f FileOut) sync_and_close() ! {
	if C._commit(f.fd) != 0 {
		f.close() or {}
		return error('${f.path}: write failed')
	}
	f.close()!
}

// replace_file renames tmp to target, replacing target if it exists.
fn replace_file(tmp string, target string) ! {
	// MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH
	if C.MoveFileExW(tmp.replace('/', '\\').to_wide(), target.replace('/', '\\').to_wide(),
		u32(0x1 | 0x8)) == 0 {
		return error('${target}: cannot replace it with ${tmp}')
	}
}

// sync_dir has nothing to do on Windows: MoveFileExW with MOVEFILE_WRITE_THROUGH returns once the
// rename is on disk.
fn sync_dir(_ string) ! {
}
