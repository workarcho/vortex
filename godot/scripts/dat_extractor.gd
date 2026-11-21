class_name DatExtractor
extends RefCounted
## Extracts the player's own FTL data archive into a folder at runtime (first-run setup, scripts/ui/data_setup.gd).
## Nothing from FTL ships with the project: the player picks their `ftl.dat` and we unpack it to user://ftl-data.
##
## Two archive formats are recognised:
## - PKG (FTL 1.6.x `ftl.dat`), big-endian: "PKG\n", u16 header_size, u16 entry_size, u32 entry_count,
##   u32 path_region_size; then entry_count entries of entry_size bytes (u32 path_hash, u32 flags<<24 | path_offset,
##   u32 data_offset, u32 data_size, u32 unpacked_size; data_offset = data_size = 0 is a free slot); then the path
##   region (\0-terminated relative paths). Data is zlib-deflated when flags & 1. Same as tools/extract_pkg.py.
## - Legacy index (FTL 1.5.x `data.dat` / `resource.dat`), little-endian: u32 N, N u32 entry offsets (0 = unused);
##   at each offset u32 data_size, u32 name_length, the name bytes, then the data.
##
## Usage: `begin(src, dst)` (reads the index), then `step(budget_ms)` every frame until it returns true; `error` is
## "" on success. Files go to `dst + ".part"` first and are renamed to `dst` only once every entry was written and
## the archive validated, plus a marker file (MARKER) that FtlData.data_problem() checks. `run()` does it all at once.

const MARKER := ".ftlproto_extracted"
## Entries every FTL archive we can use must contain (also checked on the extracted folder at startup).
const REQUIRED := ["data/blueprints.xml", "data/sounds.xml"]
const MAX_ENTRIES := 200000

var src := ""
var dst := ""
var format := ""  # "pkg" | "legacy"
var entries: Array = []  # [{name, off, size, unpacked, deflate}]
var total_bytes := 0  # sum of unpacked sizes
var done_bytes := 0
var done_files := 0
var error := ""
var finished := false

var _f: FileAccess
var _next := 0
var _made_dirs := {}


func progress() -> float:
	if finished:
		return 1.0
	return float(done_bytes) / float(total_bytes) if total_bytes > 0 else 0.0


func part_dir() -> String:
	return dst + ".part"


## Opens `src_path` (a filesystem path, or an Android content:// URI from the system picker: Godot's FileAccess
## reads both) and reads the archive index. Returns false (and sets `error`) when it is not a usable FTL archive.
func begin(src_path: String, dst_dir: String) -> bool:
	src = src_path
	dst = dst_dir.simplify_path()
	_f = FileAccess.open(src, FileAccess.READ)
	if _f == null:
		return _fail("Can't open the selected file (%s)." % error_string(FileAccess.get_open_error()))
	var length := _f.get_length()
	if length < 16:
		return _fail("The selected file is too small to be FTL's data file.")
	var magic := _f.get_buffer(4)
	_f.seek(0)
	var ok := _read_pkg(length) if magic == "PKG\n".to_ascii_buffer() else _read_legacy(length)
	if not ok:
		return false
	var names := {}
	for e in entries:
		names[e.name] = true
	for r in REQUIRED:
		if not names.has(r):
			return _fail("This file doesn't look like FTL's data (no %s inside). Pick FTL's ftl.dat." % r)
	var space := DirAccess.open(dst.get_base_dir())
	if space != null and space.get_space_left() > 0 and space.get_space_left() < total_bytes + 16 * 1024 * 1024:
		return _fail("Not enough free space: %d MB needed." % (total_bytes / 1048576 + 16))
	_remove_tree(part_dir())
	if DirAccess.make_dir_recursive_absolute(part_dir()) != OK:
		return _fail("Can't create %s." % part_dir())
	return true


func _read_pkg(length: int) -> bool:
	format = "pkg"
	_f.big_endian = true
	_f.seek(4)
	var header_size := _f.get_16()
	var entry_size := _f.get_16()
	var count := _f.get_32()
	var path_size := _f.get_32()
	if entry_size < 20 or count > MAX_ENTRIES or header_size + entry_size * count + path_size > length:
		return _fail("Corrupt ftl.dat header.")
	_f.seek(header_size)
	var raw := _f.get_buffer(entry_size * count)
	var paths := _f.get_buffer(path_size)
	if raw.size() != entry_size * count or paths.size() != path_size:
		return _fail("Couldn't read the ftl.dat index.")
	for i in count:
		var b := i * entry_size
		var fo := _be32(raw, b + 4)
		var off := _be32(raw, b + 8)
		var size := _be32(raw, b + 12)
		var unpacked := _be32(raw, b + 16)
		if off == 0 and size == 0:
			continue  # free slot
		var name_off := fo & 0xFFFFFF
		var end := name_off
		while end < path_size and paths[end] != 0:
			end += 1
		if end >= path_size:
			return _fail("Corrupt ftl.dat path table.")
		var nm := paths.slice(name_off, end).get_string_from_utf8()
		var deflate := ((fo >> 24) & 1) == 1
		if off + size > length or not _safe_name(nm):
			return _fail("Corrupt ftl.dat entry (%s)." % nm)
		entries.append({name = nm, off = off, size = size, unpacked = unpacked if deflate else size, deflate = deflate})
		total_bytes += unpacked if deflate else size
	return true


func _read_legacy(length: int) -> bool:
	format = "legacy"
	_f.big_endian = false
	var n := _f.get_32()
	if n == 0 or n > MAX_ENTRIES or 4 + 4 * n > length:
		return _fail("The selected file is not an FTL data archive.")
	var offsets := []
	for i in n:
		offsets.append(_f.get_32())
	for off in offsets:
		if off == 0:
			continue
		if off + 8 > length:
			return _fail("Corrupt data archive (entry outside the file).")
		_f.seek(off)
		var size := _f.get_32()
		var name_len := _f.get_32()
		if name_len == 0 or name_len > 4096 or off + 8 + name_len + size > length:
			return _fail("Corrupt data archive entry.")
		var nm := _f.get_buffer(name_len).get_string_from_utf8()
		if not _safe_name(nm):
			return _fail("Corrupt data archive entry (%s)." % nm)
		entries.append({name = nm, off = off + 8 + name_len, size = size, unpacked = size, deflate = false})
		total_bytes += size
	return true


## Writes entries for about `budget_ms`; returns true when finished (check `error`).
func step(budget_ms := 30) -> bool:
	if finished or error != "":
		return true
	var t0 := Time.get_ticks_msec()
	while _next < entries.size():
		if not _extract(entries[_next]):
			_cleanup()
			return true
		_next += 1
		if Time.get_ticks_msec() - t0 >= budget_ms:
			return false
	_finish()
	return true


## Extracts everything in one call (tests, tools). Returns true on success.
func run(src_path: String, dst_dir: String) -> bool:
	if not begin(src_path, dst_dir):
		return false
	while not step(1000):
		pass
	return error == ""


func _extract(e: Dictionary) -> bool:
	_f.seek(e.off)
	var data := _f.get_buffer(e.size)
	if data.size() != e.size:
		return _fail("Read error in %s." % e.name)
	if e.deflate and e.unpacked > 0:
		data = data.decompress(e.unpacked, FileAccess.COMPRESSION_DEFLATE)
		if data.size() != e.unpacked:
			return _fail("Couldn't decompress %s." % e.name)
	var out_path: String = part_dir().path_join(e.name)
	var dir := out_path.get_base_dir()
	if not _made_dirs.has(dir):
		DirAccess.make_dir_recursive_absolute(dir)
		_made_dirs[dir] = true
	var o := FileAccess.open(out_path, FileAccess.WRITE)
	if o == null:
		return _fail("Can't write %s (%s)." % [e.name, error_string(FileAccess.get_open_error())])
	o.store_buffer(data)
	o.close()
	done_bytes += data.size()
	done_files += 1
	return true


func _finish() -> void:
	_f = null
	for r in REQUIRED:
		if not FileAccess.file_exists(part_dir().path_join(r)):
			_fail("%s missing after extraction." % r)
			_cleanup()
			return
	var m := FileAccess.open(part_dir().path_join(MARKER), FileAccess.WRITE)
	if m == null:
		_fail("Can't write the extraction marker.")
		_cleanup()
		return
	m.store_string(JSON.stringify({files = done_files, bytes = done_bytes, format = format}))
	m.close()
	_remove_tree(dst)
	if DirAccess.rename_absolute(part_dir(), dst) != OK:
		_fail("Can't move the extracted data to %s." % dst)
		_cleanup()
		return
	finished = true


func _cleanup() -> void:
	_f = null
	_remove_tree(part_dir())


func _fail(msg: String) -> bool:
	if error == "":
		error = msg
	return false


## Relative path without "..", drive letters or a leading slash (never writes outside `dst`).
static func _safe_name(nm: String) -> bool:
	if nm == "" or nm.begins_with("/") or nm.begins_with("\\") or nm.contains(":"):
		return false
	for part in nm.replace("\\", "/").split("/"):
		if part == ".." or part == "":
			return false
	return true


static func _be32(b: PackedByteArray, i: int) -> int:
	return (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]


## Deletes a folder and everything in it (no-op when missing).
static func _remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	var d := DirAccess.open(path)
	if d == null:
		return
	d.include_hidden = true
	for sub in d.get_directories():
		_remove_tree(path.path_join(sub))
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)
