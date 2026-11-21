extends Node
## Mod loader (autoload `Mods`; rules/hooks.md "Mod loader"). Internal mods live in res://mods/<id>/, user mods in
## user://mods/<id>/. Each folder has a mod.json {id, name, version, entry} and the entry .gd script, whose
## `_mod_init(ctx: ModContext)` registers settings and hooks. Mods load in folder-name order (deterministic).
## `--no-mods` (user argument) skips loading.
##
## Optional: after loading, a Hyperspace `hyperspace.xml` (ftl-data/data/hyperspace.xml, or `--hyperspace=PATH`)
## is read and its switches become mod-recommended setting defaults through the mods' `map_hyperspace` tables.

const DIRS := ["res://mods", "user://mods"]

var loaded := {}  # id -> {manifest, dir, entry, ctx}
var order: Array[String] = []
var errors: Array[String] = []
var hs_map: Array = []  # [{tag, id, convert, owner}] registered through ModContext.map_hyperspace
var hs_applied := {}  # setting id -> value taken from hyperspace.xml


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.has("--no-mods"):
		return
	load_all()
	var hs_path := ""
	for a in args:
		if a.begins_with("--hyperspace="):
			hs_path = a.trim_prefix("--hyperspace=")
	if hs_path == "":
		_apply_data_hyperspace()
		FtlData.data_reloaded.connect(_apply_data_hyperspace)  # first-run setup: the data folder appears later
	elif FileAccess.file_exists(hs_path):
		apply_hyperspace_xml(FileAccess.get_file_as_string(hs_path))


## Applies the data folder's data/hyperspace.xml (when there is one) to the registered settings.
func _apply_data_hyperspace() -> void:
	var hs_path := FtlData.root.path_join("data/hyperspace.xml") if FtlData.root != "" else ""
	if hs_path != "" and FileAccess.file_exists(hs_path):
		apply_hyperspace_xml(FileAccess.get_file_as_string(hs_path))


func load_all() -> void:
	for base in DIRS:
		var d := DirAccess.open(base)
		if d == null:
			continue
		var names := Array(d.get_directories())
		names.sort()
		for n in names:
			load_mod(base.path_join(n))
	Hooks.emit(&"mods_loaded", order.duplicate())


## Loads one mod folder. Returns true on success (errors are collected in `errors`).
func load_mod(dir: String) -> bool:
	var mpath := dir.path_join("mod.json")
	if not FileAccess.file_exists(mpath):
		return false
	var m: Variant = JSON.parse_string(FileAccess.get_file_as_string(mpath))
	if not m is Dictionary:
		return _fail("%s: mod.json is not a JSON object" % dir)
	for k in ["id", "name", "version", "entry"]:
		if not (m as Dictionary).has(k):
			return _fail("%s: mod.json lacks \"%s\"" % [dir, k])
	var id := String(m.id)
	if loaded.has(id):
		return _fail("%s: mod id \"%s\" already loaded" % [dir, id])
	var script: Variant = load(dir.path_join(String(m.entry)))
	if not script is GDScript:
		return _fail("%s: entry script %s not found" % [dir, m.entry])
	var entry: Object = (script as GDScript).new()
	var ctx := ModContext.new()
	ctx.id = id
	ctx.name = String(m.name)
	ctx.version = String(m.version)
	ctx.dir = dir
	ctx.manifest = m
	ctx.hooks = Hooks
	ctx.settings = Settings
	loaded[id] = {"manifest": m, "dir": dir, "entry": entry, "ctx": ctx}
	order.append(id)
	if entry.has_method("_mod_init"):
		entry.call("_mod_init", ctx)
	print("mod loaded: %s %s (%s)" % [id, ctx.version, dir])
	return true


## Removes a mod's hooks, rules, settings and hyperspace mappings (its entry gets `_mod_unload()` first).
func unload(id: String) -> void:
	if not loaded.has(id):
		return
	var entry: Object = loaded[id].entry
	if entry and entry.has_method("_mod_unload"):
		entry.call("_mod_unload")
	Hooks.remove_owner(id)
	Settings.undeclare_owner(id)
	hs_map = hs_map.filter(func(e): return e.owner != id)
	loaded.erase(id)
	order.erase(id)


func entry(id: String) -> Object:
	return loaded[id].entry if loaded.has(id) else null


func _fail(msg: String) -> bool:
	errors.append(msg)
	push_warning("mod: " + msg)
	return false


## Reads `<tag attr="..."/>` switches of a hyperspace.xml text and sets the mapped settings' mod-recommended
## defaults (rules/hooks.md "hyperspace.xml mapping"). Returns {setting id: value} applied.
func apply_hyperspace_xml(text: String) -> Dictionary:
	var src := FtlData.strip_comments(text)
	var out := {}
	for e in hs_map:
		var re := RegEx.create_from_string("<" + String(e.tag) + "\\b([^>]*?)/?>")
		var m := re.search(src)
		if m == null:
			continue
		var v: Variant = (e.convert as Callable).call(FtlData.attrs(m.get_string(1)))
		if v == null:
			continue
		if String(e.id).begins_with("group:") and bool(out.get(e.id, false)):
			continue  # several switches map to one master: any ON keeps it ON
		Settings.set_mod_default(String(e.id), v)
		out[e.id] = v
	hs_applied = out
	return out
