extends Node
## First-run data setup (scripts/dat_extractor.gd): builds tiny synthetic FTL archives (PKG 1.6.x with deflated,
## stored and free entries; legacy 1.5.x index format), extracts them, checks every file, the marker that
## FtlData.data_problem() requires for the user:// folder, and that bad archives are refused without leaving files.
## Run:
##   godot --headless --path godot res://tests/test_dat_extract.tscn

const Harness := preload("res://tests/harness.gd")

var fails := 0
var tmp := ""

var FILES := {
	"data/blueprints.xml": "<blueprint name=\"X\"/>\n",
	"data/sounds.xml": "<sounds/>\n",
	"img/ship/a b.png": "",  # empty entry
	"audio/waves/x.ogg": "",  # replaced by binary below
	"fonts/c&c.font": "font",
}


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func payload(nm: String) -> PackedByteArray:
	if nm == "audio/waves/x.ogg":
		var b := PackedByteArray()
		for i in 70000:
			b.append((i * 7919) % 251)
		return b
	return String(FILES[nm]).to_utf8_buffer()


static func be32(b: PackedByteArray, v: int) -> void:
	b.append((v >> 24) & 255); b.append((v >> 16) & 255); b.append((v >> 8) & 255); b.append(v & 255)


static func le32(b: PackedByteArray, v: int) -> void:
	b.append(v & 255); b.append((v >> 8) & 255); b.append((v >> 16) & 255); b.append((v >> 24) & 255)


## PKG archive: one free slot first, every other entry deflated except fonts/.
func build_pkg(names: Array) -> PackedByteArray:
	var paths := PackedByteArray()
	var name_offs := []
	for nm in names:
		name_offs.append(paths.size())
		paths.append_array(String(nm).to_utf8_buffer())
		paths.append(0)
	var count := names.size() + 1
	var data_start := 16 + 20 * count + paths.size()
	var blobs := PackedByteArray()
	var table := PackedByteArray()
	be32(table, 0); be32(table, 0); be32(table, 0); be32(table, 0); be32(table, 0)  # free slot
	for i in names.size():
		var raw := payload(names[i])
		var deflate := not String(names[i]).begins_with("fonts/") and raw.size() > 0
		var stored := raw.compress(FileAccess.COMPRESSION_DEFLATE) if deflate else raw
		be32(table, 0x1234)
		be32(table, ((1 if deflate else 0) << 24) | name_offs[i])
		be32(table, data_start + blobs.size())
		be32(table, stored.size())
		be32(table, raw.size())
		blobs.append_array(stored)
	var out := "PKG\n".to_ascii_buffer()
	out.append(0); out.append(16); out.append(0); out.append(20)
	be32(out, count)
	be32(out, paths.size())
	out.append_array(table)
	out.append_array(paths)
	out.append_array(blobs)
	return out


## Legacy index archive with an unused (0) slot.
func build_legacy(names: Array) -> PackedByteArray:
	var n := names.size() + 1
	var body := PackedByteArray()
	var offsets := [0]
	var base := 4 + 4 * n
	for nm in names:
		offsets.append(base + body.size())
		var raw := payload(nm)
		var nb := String(nm).to_utf8_buffer()
		le32(body, raw.size())
		le32(body, nb.size())
		body.append_array(nb)
		body.append_array(raw)
	var out := PackedByteArray()
	le32(out, n)
	for o in offsets:
		le32(out, o)
	out.append_array(body)
	return out


func write(path: String, b: PackedByteArray) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(b)
	f.close()


func verify(dst: String, label: String) -> void:
	for nm in FILES:
		var p := dst.path_join(nm)
		check("%s: %s extracted" % [label, nm], FileAccess.file_exists(p), true)
		if FileAccess.file_exists(p):
			check("%s: %s bytes" % [label, nm], FileAccess.get_file_as_bytes(p) == payload(nm), true)
	check("%s: marker written" % label, FileAccess.file_exists(dst.path_join(DatExtractor.MARKER)), true)
	check("%s: no .part left" % label, DirAccess.dir_exists_absolute(dst + ".part"), false)
	check("%s: data_problem ok" % label, FtlData.data_problem(dst), "")


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	FtlData.muted = true
	tmp = OS.get_user_data_dir().path_join("test_dat_extract")
	DatExtractor._remove_tree(tmp)
	DirAccess.make_dir_recursive_absolute(tmp)
	var names := FILES.keys()

	print("PKG (1.6.x ftl.dat)")
	write(tmp.path_join("ftl.dat"), build_pkg(names))
	var ex := DatExtractor.new()
	check("pkg begin", ex.begin(tmp.path_join("ftl.dat"), tmp.path_join("out_pkg")), true)
	check("pkg format", ex.format, "pkg")
	check("pkg entries (free slot skipped)", ex.entries.size(), names.size())
	var steps := 0
	while not ex.step(0):  # budget 0: one entry per step, like a slow frame
		steps += 1
		if steps == 1:
			check("progress below 1 while running", ex.progress() < 1.0, true)
	check("pkg stepped through entries", steps >= names.size() - 1, true)
	check("pkg error", ex.error, "")
	check("pkg progress", ex.progress(), 1.0)
	verify(tmp.path_join("out_pkg"), "pkg")

	print("re-extract over an existing folder")
	var stale := tmp.path_join("out_pkg/stale.txt")
	write(stale, "old".to_utf8_buffer())
	check("re-run ok", DatExtractor.new().run(tmp.path_join("ftl.dat"), tmp.path_join("out_pkg")), true)
	check("old folder replaced", FileAccess.file_exists(stale), false)

	print("legacy index (1.5.x .dat)")
	write(tmp.path_join("data.dat"), build_legacy(names))
	var lx := DatExtractor.new()
	check("legacy run", lx.run(tmp.path_join("data.dat"), tmp.path_join("out_legacy")), true)
	check("legacy format", lx.format, "legacy")
	verify(tmp.path_join("out_legacy"), "legacy")

	print("refused archives")
	write(tmp.path_join("noblue.dat"), build_pkg(["data/sounds.xml", "fonts/c&c.font"]))
	var nb := DatExtractor.new()
	check("no blueprints.xml refused", nb.run(tmp.path_join("noblue.dat"), tmp.path_join("out_bad")), false)
	check("no blueprints.xml message", nb.error.contains("data/blueprints.xml"), true)
	check("nothing written", DirAccess.dir_exists_absolute(tmp.path_join("out_bad")), false)
	FILES["../evil.txt"] = "x"
	write(tmp.path_join("evil.dat"), build_pkg(names + ["../evil.txt"]))
	check("path traversal refused", DatExtractor.new().run(tmp.path_join("evil.dat"), tmp.path_join("out_bad")), false)
	FILES.erase("../evil.txt")
	write(tmp.path_join("junk.dat"), "not an archive at all".to_utf8_buffer())
	check("junk refused", DatExtractor.new().run(tmp.path_join("junk.dat"), tmp.path_join("out_bad")), false)
	var trunc := build_pkg(names)
	write(tmp.path_join("trunc.dat"), trunc.slice(0, trunc.size() - 1000))
	check("truncated refused", DatExtractor.new().run(tmp.path_join("trunc.dat"), tmp.path_join("out_bad")), false)
	check("missing file refused", DatExtractor.new().run(tmp.path_join("nope.dat"), tmp.path_join("out_bad")), false)

	print("data_problem")
	DirAccess.remove_absolute(tmp.path_join("out_legacy/data/blueprints.xml"))
	check("missing blueprints detected", FtlData.data_problem(tmp.path_join("out_legacy")).contains("blueprints"), true)
	check("desktop data folder ok", FtlData.data_problem(FtlData.root), "")

	DatExtractor._remove_tree(tmp)
