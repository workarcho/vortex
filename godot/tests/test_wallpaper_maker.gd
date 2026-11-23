extends Node
## Tests for WallpaperMaker (scripts/autobattle/wallpaper_maker.gd) and the main menu's "CREATE HTML WALLPAPER"
## button (scripts/ui/wallpaper_button.gd): from a small fake template and a tiny fake ftl-data folder under
## user://test_wallpaper_<n>/ (removed afterwards) it builds the wallpaper in a thread, then checks the data pack
## (mounted with ProjectSettings.load_resource_pack: file list, contents, skip list), the size placeholder, the
## copied template files, project.json, README.txt and the version stamp; a second click only opens the folder (the
## open call is mocked); a stale stamp or a missing file rebuilds; no template / no data are refused. Run:
##   godot --headless --path godot res://tests/test_wallpaper_maker.tscn

const Harness := preload("res://tests/harness.gd")

var fails := 0
var tmp := ""
var opened: Array = []


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	FtlData.muted = true
	tmp = OS.get_user_data_dir().path_join("test_wallpaper_%d" % (Time.get_ticks_usec() % 1000000))
	_make_template(tmp.path_join("template"), "stamp 1")
	_make_data(tmp.path_join("data"))
	await _test_build()
	await _test_open_and_rebuild()
	_test_refusals()
	await _test_button()
	_rm(tmp)
	check("temp folder removed", DirAccess.dir_exists_absolute(tmp), false)


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)


func _make_template(dir: String, stamp: String) -> void:
	_write(dir.path_join("index.html"), "<script>const SIZE = Number('__FTL_DATA_PACK_SIZE__');</script>")
	_write(dir.path_join("index.js"), "// engine")
	_write(dir.path_join("index.wasm"), "wasm")
	_write(dir.path_join("index.pck"), "pck")
	_write(dir.path_join("index.audio.worklet.js"), "// worklet")
	_write(dir.path_join("index.icon.png"), "png")
	_write(dir.path_join("project.json"), JSON.stringify({"file": "index.html", "type": "web",
		"title": "Vortex Autobattle", "general": {"properties": {"marginleft": {"type": "slider", "value": 250}}}},
		"    "))
	_write(dir.path_join(WallpaperMaker.STAMP), stamp)


const DATA_FILES := {
	"data/blueprints.xml": "<blueprints/>",
	"data/text_misc.xml": "<FTL/>",
	"img/ship/kestrel.png": "PNGDATA",
	"fonts/c.font": "font",
	"audio/waves/x.ogg": "ogg",  # skipped
	"fonts/ja/j.font": "ja",  # skipped
	"fonts/zh-Hans/z.font": "zh",  # skipped
	"img/ipad/big.png": "ipad",  # skipped
}
const PACKED := ["data/blueprints.xml", "data/text_misc.xml", "fonts/c.font", "img/ship/kestrel.png"]


func _make_data(dir: String) -> void:
	for rel in DATA_FILES:
		_write(dir.path_join(rel), DATA_FILES[rel])


func _maker() -> WallpaperMaker:
	var m := WallpaperMaker.new(tmp.path_join("template"), tmp.path_join("out/Vortex Autobattle"),
		tmp.path_join("data"))
	m.opener = func(p: String) -> void: opened.append(p)
	return m


func _wait(m: WallpaperMaker) -> void:
	var t0 := Time.get_ticks_msec()
	while not m.poll():
		await get_tree().process_frame
		if Time.get_ticks_msec() - t0 > 30000:
			check("build finished within 30 s", false, true)
			return


func _test_build() -> void:
	print("build from the template + data")
	var m := _maker()
	check("not ready before", m.is_ready(), false)
	check("collect skips audio / CJK fonts / iPad art", _collected(), PACKED)
	check("run starts a thread", m.run(), WallpaperMaker.STARTED)
	check("second run while busy", m.run(), WallpaperMaker.BUSY)
	await _wait(m)
	check("ok", [m.ok, m.error], [true, ""])
	check("opened index.html once", opened, [m.index_path()])
	var out := m.dest_dir
	check("complete", WallpaperMaker.is_complete(out, WallpaperMaker.OUTPUT_REQUIRED), true)
	check("ready", m.is_ready(), true)
	for f in ["index.js", "index.wasm", "index.pck", "index.audio.worklet.js", "index.icon.png"]:
		check("copied " + f, FileAccess.get_file_as_string(out.path_join(f)),
			FileAccess.get_file_as_string(tmp.path_join("template").path_join(f)))
	check("no .part left", FileAccess.file_exists(out.path_join("ftl-data.pck.part")), false)
	var pck := out.path_join(WallpaperMaker.DATA_PACK)
	var size := FileAccess.open(pck, FileAccess.READ).get_length()
	var html := FileAccess.get_file_as_string(out.path_join("index.html"))
	check("placeholder replaced by the pack size", [html.contains("__FTL_DATA_PACK_SIZE__"),
		html.contains("Number('%d')" % size)], [false, true])
	var pj = JSON.parse_string(FileAccess.get_file_as_string(out.path_join("project.json")))
	check("project.json valid", [pj is Dictionary, pj.get("file") if pj is Dictionary else null,
		pj.get("type") if pj is Dictionary else null], [true, "index.html", "web"])
	check("project.json keeps the sliders", pj.general.properties.has("marginleft") if pj is Dictionary else false,
		true)
	var readme := FileAccess.get_file_as_string(out.path_join(WallpaperMaker.README))
	check("README: Create Wallpaper / index.html / do not share", [readme.contains("Create Wallpaper"),
		readme.contains("index.html"), readme.contains("Do NOT share")], [true, true, true])
	check("stamp = template's", FileAccess.get_file_as_string(out.path_join(WallpaperMaker.STAMP)), "stamp 1")
	# The pack: mounted like the web build does (res://ftl-data/...); a copy, so the rebuilds below can replace it.
	var mounted := tmp.path_join("mounted.pck")
	DirAccess.copy_absolute(pck, mounted)
	check("pack loads", ProjectSettings.load_resource_pack(mounted, false), true)
	var listed: Array = []
	WallpaperMaker.collect_files("res://ftl-data", "", [], listed)
	listed.sort()
	check("pack file list", listed, PACKED)
	check("pack contents", [FileAccess.get_file_as_string("res://ftl-data/data/blueprints.xml"),
		FileAccess.get_file_as_string("res://ftl-data/img/ship/kestrel.png")], ["<blueprints/>", "PNGDATA"])
	check("skipped files not in the pack", [FileAccess.file_exists("res://ftl-data/audio/waves/x.ogg"),
		FileAccess.file_exists("res://ftl-data/fonts/ja/j.font"), DirAccess.dir_exists_absolute("res://ftl-data/img/ipad")],
		[false, false, false])


func _collected() -> Array:
	var a: Array = []
	WallpaperMaker.collect_files(tmp.path_join("data"), "", WallpaperMaker.SKIP, a)
	a.sort()
	return a


func _test_open_and_rebuild() -> void:
	print("second click opens; stale / incomplete rebuilds")
	opened.clear()
	var m := _maker()
	check("complete + same stamp: opened", m.run(), WallpaperMaker.OPENED)
	check("open call", opened, [m.index_path()])
	check("nothing running", m.running, false)
	# A new game build ships a new template: the stamp differs -> rebuilt.
	_write(tmp.path_join("template").path_join(WallpaperMaker.STAMP), "stamp 2")
	opened.clear()
	check("stale stamp: rebuilt", m.run(), WallpaperMaker.STARTED)
	await _wait(m)
	check("rebuilt ok, opened", [m.ok, opened.size()], [true, 1])
	check("new stamp", FileAccess.get_file_as_string(m.dest_dir.path_join(WallpaperMaker.STAMP)), "stamp 2")
	# A file gone (e.g. deleted by hand): rebuilt, here without a thread.
	DirAccess.remove_absolute(m.dest_dir.path_join("index.wasm"))
	check("incomplete: not ready", m.is_ready(), false)
	m.threaded = false
	opened.clear()
	check("incomplete: rebuilt", m.run(), WallpaperMaker.STARTED)
	check("unthreaded poll done", m.poll(), true)
	check("rebuilt (unthreaded)", [m.ok, m.is_ready(), opened.size()], [true, true, 1])


func _test_refusals() -> void:
	print("no template / no data")
	opened.clear()
	var m := WallpaperMaker.new(tmp.path_join("no-template"), tmp.path_join("out2"), tmp.path_join("data"))
	m.opener = func(p: String) -> void: opened.append(p)
	check("no template", m.run(), WallpaperMaker.NO_TEMPLATE)
	m.template_dir = ""
	check("empty template path", m.run(), WallpaperMaker.NO_TEMPLATE)
	m.template_dir = tmp.path_join("template")
	m.data_root = tmp.path_join("no-data")
	check("no data", m.run(), WallpaperMaker.NO_DATA)
	check("nothing opened, nothing written", [opened, DirAccess.dir_exists_absolute(tmp.path_join("out2"))],
		[[], false])
	# A build without a template still opens a wallpaper made earlier.
	var old := WallpaperMaker.new("", tmp.path_join("out/Vortex Autobattle"), "")
	old.opener = func(p: String) -> void: opened.append(p)
	check("no template but a finished folder: opened", old.run(), WallpaperMaker.OPENED)
	check("default folder under the user data dir", WallpaperMaker.default_dest_dir(),
		OS.get_user_data_dir().path_join("wallpaper/Vortex Autobattle"))


func _test_button() -> void:
	print("main menu button")
	var toasts: Array = []
	var menu := Control.new()
	add_child(menu)
	var b := WallpaperButton.new()
	add_child(b)
	var m := WallpaperMaker.new(tmp.path_join("template"), tmp.path_join("out3"), tmp.path_join("data"))
	m.opener = func(p: String) -> void: opened.append(p)
	b.setup(menu, func(t: String) -> void: toasts.append(t), m)
	check("label", b.button.label, "CREATE HTML WALLPAPER")
	var r: Rect2 = b.button.rect
	check("bottom-left corner", [r.position.x, r.end.y], [14.0, 708.0])
	opened.clear()
	check("click builds", b.activate(), WallpaperMaker.STARTED)
	check("toast: creating", toasts.back(), FtlData.tr_id("wallpaper_creating"))
	check("busy: button off", b.button.state, "off")
	var t0 := Time.get_ticks_msec()
	while m.running and Time.get_ticks_msec() - t0 < 30000:
		await get_tree().process_frame
	check("finished through _process", [m.running, m.ok], [false, true])
	check("toast: created + path", toasts.back(), "Wallpaper created: " + m.dest_dir)
	check("opened", opened.size(), 1)
	check("second click opens", b.activate(), WallpaperMaker.OPENED)
	check("toast: folder", toasts.back(), "Wallpaper folder: " + m.dest_dir)
	m.dest_dir = tmp.path_join("out4")
	m.template_dir = tmp.path_join("no-template")
	check("no template", b.activate(), WallpaperMaker.NO_TEMPLATE)
	check("toast: no template", toasts.back(), FtlData.tr_id("wallpaper_no_template"))
	menu.visible = false
	await get_tree().process_frame
	check("hidden with the menu", b.visible, false)
	b.queue_free()
	menu.queue_free()


func _rm(dir: String) -> void:
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_rm(dir.path_join(d))
	DirAccess.remove_absolute(dir)
