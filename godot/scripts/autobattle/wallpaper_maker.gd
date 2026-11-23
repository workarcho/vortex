class_name WallpaperMaker
extends RefCounted
## [ours] Builds the local Wallpaper Engine web wallpaper (the autobattle demo) from inside the PC game: the
## main menu's "CREATE HTML WALLPAPER" button (scripts/ui/wallpaper_button.gd).
##
## The game ships a data-less web template (tools/build_web_wallpaper.py: the Godot web export with the custom
## shell, index.html still holding the __FTL_DATA_PACK_SIZE__ placeholder, a project.json and a version stamp):
##   - exported Windows build: `web-wallpaper/` next to the exe;
##   - dev (godot --path godot): build/web-wallpaper-template/ in the repo.
## `run()` copies the template into the destination folder (default <user data dir>/wallpaper/Vortex Autobattle),
## packs the player's FTL data (FtlData.root) into ftl-data.pck with PCKPacker (files under res://ftl-data/, the
## same skip list as the build script), writes the pack size into index.html, re-writes project.json and a
## README.txt, and finally the version stamp (a folder without a matching stamp is incomplete and rebuilt).
## The work runs in a Thread; the owner calls `poll()` every frame until it returns true.
## When the folder is already complete and its stamp matches the template's, `run()` only opens it.
## The folder holds the player's own FTL data: it stays on this computer (README.txt says not to share it).

const TEMPLATE_DIR_EXPORTED := "web-wallpaper"  # next to the exe
const TEMPLATE_DIR_DEV := "build/web-wallpaper-template"  # relative to the repo (res://..)
const STAMP := "wallpaper-version.txt"
const PLACEHOLDER := "__FTL_DATA_PACK_SIZE__"
const DATA_PACK := "ftl-data.pck"
const PACK_PREFIX := "res://ftl-data/"
const README := "README.txt"
## What the muted, English wallpaper never reads (same list as tools/build_web_wallpaper.py).
const SKIP := ["audio", "fonts/ja", "fonts/zh-Hans", "img/ipad"]
const TEMPLATE_REQUIRED := ["index.html", "index.js", "index.wasm", "index.pck", "project.json", STAMP]
const OUTPUT_REQUIRED := ["index.html", "index.js", "index.wasm", "index.pck", DATA_PACK, "project.json", STAMP]
const FOLDER_NAME := "Vortex Autobattle"

## run() results
const NO_TEMPLATE := "no_template"
const NO_DATA := "no_data"
const OPENED := "opened"  # the folder was complete: only opened
const STARTED := "started"  # building in a thread; poll() until true
const BUSY := "busy"

var template_dir := ""
var dest_dir := ""
var data_root := ""
var skip: Array = SKIP.duplicate()
## Opens the finished folder (tests replace it). Receives the path of index.html.
var opener: Callable = func(path: String) -> void: OS.shell_show_in_file_manager(path, true)
## false: the work runs on the calling thread inside run() (tests that want no thread).
var threaded := true

var running := false
var ok := false
var error := ""
var _thread: Thread
var _mutex := Mutex.new()
var _phase := ""
var _done_files := 0
var _total_files := 0


## Template folder of this build ("" when there is none).
static func default_template_dir() -> String:
	var dirs: Array[String] = [OS.get_executable_path().get_base_dir().path_join(TEMPLATE_DIR_EXPORTED)]
	if not OS.has_feature("template"):  # not an exported build: the repo's build output
		dirs.push_front(ProjectSettings.globalize_path("res://").path_join("..").path_join(TEMPLATE_DIR_DEV)
			.simplify_path())
	for d in dirs:
		if is_complete(d, TEMPLATE_REQUIRED):
			return d
	return ""


static func default_dest_dir() -> String:
	return OS.get_user_data_dir().path_join("wallpaper").path_join(FOLDER_NAME)


static func is_complete(dir: String, required: Array) -> bool:
	if dir == "" or not DirAccess.dir_exists_absolute(dir):
		return false
	for f in required:
		if not FileAccess.file_exists(dir.path_join(f)):
			return false
	return true


static func read_text(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_as_text().strip_edges() if f else ""


func _init(template := "", dest := "", data := "") -> void:
	template_dir = template
	dest_dir = dest
	data_root = data


## True when dest_dir holds a complete wallpaper made from this template (or from any template when the build
## ships none: there is nothing newer to make it from).
func is_ready() -> bool:
	if not is_complete(dest_dir, OUTPUT_REQUIRED):
		return false
	if template_dir == "":
		return true
	return read_text(dest_dir.path_join(STAMP)) == read_text(template_dir.path_join(STAMP))


func index_path() -> String:
	return dest_dir.path_join("index.html")


## The button's action: open the folder when it is ready, else start building it.
func run() -> String:
	if running:
		return BUSY
	if is_ready():
		opener.call(index_path())
		return OPENED
	if not is_complete(template_dir, TEMPLATE_REQUIRED):
		return NO_TEMPLATE
	if data_root == "" or not FileAccess.file_exists(data_root.path_join("data/blueprints.xml")):
		return NO_DATA
	running = true
	ok = false
	error = ""
	_set_progress("start", 0, 0)
	if threaded:
		_thread = Thread.new()
		_thread.start(_build)
	else:
		_build()
	return STARTED


## Call every frame while running: true once the build ended (then `ok` / `error`; on success the folder was
## opened).
func poll() -> bool:
	if not running:
		return true
	if _thread != null:
		if _thread.is_alive():
			return false
		_thread.wait_to_finish()
		_thread = null
	running = false
	if ok:
		opener.call(index_path())
	return true


## 0..1 (packing files is most of it).
func progress() -> float:
	_mutex.lock()
	var p := 0.0
	match _phase:
		"copy":
			p = 0.02
		"pack":
			p = 0.05 + 0.85 * (float(_done_files) / maxf(1.0, _total_files))
		"flush":
			p = 0.9
		"finish":
			p = 0.98
	_mutex.unlock()
	return p


func phase() -> String:
	_mutex.lock()
	var s := _phase
	_mutex.unlock()
	return s


func _set_progress(ph: String, done: int, total: int) -> void:
	_mutex.lock()
	_phase = ph
	_done_files = done
	_total_files = total
	_mutex.unlock()


## Worker: everything that touches the disk.
func _build() -> void:
	var err := _build_steps()
	if err != "":
		error = err
		ok = false
	else:
		ok = true


func _build_steps() -> String:
	if DirAccess.make_dir_recursive_absolute(dest_dir) != OK:
		return "cannot create " + dest_dir
	# The stamp goes first: an interrupted build leaves a folder that is rebuilt next time.
	if FileAccess.file_exists(dest_dir.path_join(STAMP)):
		DirAccess.remove_absolute(dest_dir.path_join(STAMP))
	_set_progress("copy", 0, 0)
	for f in DirAccess.get_files_at(template_dir):
		if f == STAMP or f == "index.html" or f == "project.json" or f == README:
			continue
		if DirAccess.copy_absolute(template_dir.path_join(f), dest_dir.path_join(f)) != OK:
			return "cannot copy " + f
	# The data pack.
	var files: Array = []
	collect_files(data_root, "", skip, files)
	if files.is_empty():
		return "no files in " + data_root
	var part := dest_dir.path_join(DATA_PACK + ".part")
	var pk := PCKPacker.new()
	if pk.pck_start(part) != OK:
		return "cannot write " + part
	for i in files.size():
		_set_progress("pack", i, files.size())
		if pk.add_file(PACK_PREFIX + files[i], data_root.path_join(files[i])) != OK:
			return "cannot pack " + String(files[i])
	_set_progress("flush", files.size(), files.size())
	if pk.flush(false) != OK:
		return "cannot write the data pack"
	pk = null
	var pck := dest_dir.path_join(DATA_PACK)
	if FileAccess.file_exists(pck) and DirAccess.remove_absolute(pck) != OK:
		return "cannot replace " + pck + " (is the wallpaper running?)"
	if DirAccess.rename_absolute(part, pck) != OK:
		return "cannot rename " + part
	_set_progress("finish", files.size(), files.size())
	# index.html with the pack size (the shell's loading bar).
	var html := FileAccess.get_file_as_string(template_dir.path_join("index.html"))
	if not html.contains(PLACEHOLDER):
		return "the template's index.html has no " + PLACEHOLDER
	var size := FileAccess.open(pck, FileAccess.READ).get_length()
	if not _write(dest_dir.path_join("index.html"), html.replace(PLACEHOLDER, str(size))):
		return "cannot write index.html"
	# project.json: the template's (sliders, title), checked and copied as is.
	var pj := FileAccess.get_file_as_string(template_dir.path_join("project.json"))
	var proj = JSON.parse_string(pj)
	if not proj is Dictionary or String(proj.get("file", "")) != "index.html" or String(proj.get("type", "")) != "web":
		return "the template's project.json is not valid"
	if not _write(dest_dir.path_join("project.json"), pj):
		return "cannot write project.json"
	if not _write(dest_dir.path_join(README), readme_text()):
		return "cannot write " + README
	# Last: the stamp marks the folder complete.
	if DirAccess.copy_absolute(template_dir.path_join(STAMP), dest_dir.path_join(STAMP)) != OK:
		return "cannot write " + STAMP
	return ""


static func _write(path: String, text: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	return true


## Files under root/rel (paths relative to root, "/"-separated), minus `skip` (files or folders).
static func collect_files(root: String, rel: String, skip_list: Array, out: Array) -> void:
	var dir := root.path_join(rel) if rel != "" else root
	for f in DirAccess.get_files_at(dir):
		var r := rel.path_join(f) if rel != "" else f
		if not skip_list.has(r):
			out.append(r)
	for d in DirAccess.get_directories_at(dir):
		var r := rel.path_join(d) if rel != "" else d
		if not skip_list.has(r):
			collect_files(root, r, skip_list, out)


static func readme_text() -> String:
	return "\r\n".join(PackedStringArray([
		"Vortex Autobattle - live wallpaper for Wallpaper Engine",
		"=======================================================",
		"",
		"Two AI ships fight each other forever (the Vortex autobattle demo), muted.",
		"This folder was created by Vortex (main menu -> CREATE HTML WALLPAPER).",
		"",
		"How to use it:",
		"  1. Open Wallpaper Engine and click \"Create Wallpaper\" (bottom left of the browser window,",
		"     or the Editor).",
		"  2. Choose the index.html file in this folder.",
		"  3. In the editor, File -> Apply wallpaper (or just close it: the wallpaper is in your list).",
		"",
		"Settings (Wallpaper Engine panel, right side):",
		"  - Left / Right / Top / Bottom margin: keep the battle clear of desktop icons and the taskbar.",
		"  - FPS: the wallpaper follows Wallpaper Engine's own FPS limit (Settings -> Performance;",
		"    30 FPS is plenty).",
		"",
		"Keep this folder where it is: Wallpaper Engine loads the wallpaper from here.",
		"Clicking the button again in Vortex just opens this folder; after a game update it rebuilds it.",
		"",
		"Do NOT share or publish this folder (no Workshop upload): ftl-data.pck contains your own copy of",
		"FTL: Faster Than Light's game data, which you may not redistribute.",
		"",
	]))
