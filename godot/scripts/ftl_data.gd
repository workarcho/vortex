extends Node
## Reads the data extracted from ftl.dat (ftl-data folder) at runtime.
## Nothing from FTL is copied into the project: everything is loaded from the user's folder.

const TILE := 35

var root := ""  # ftl-data folder (absolute)
var _tex_cache := {}
var _text_cache := {}


## Emitted by reload() once a new data folder is in use (first-run setup extracted ftl.dat).
signal data_reloaded
## Why no data folder is usable ("" when `root` is set, or when nothing was found at all). Shown by the setup screen.
var data_problem_text := ""


func _ready() -> void:
	if "--sound-log" in OS.get_cmdline_user_args():
		record_plays = true
		_print_plays = true
	root = _find_root()
	if root == "":
		push_warning("ftl-data not found (FTL_DATA, ../ftl-data, user://ftl-data): the first-run setup asks for ftl.dat.")
	else:
		print("ftl-data: ", root)


## Where the first-run setup extracts the player's ftl.dat (scripts/ui/data_setup.gd).
static func user_data_dir() -> String:
	return OS.get_user_data_dir().path_join("ftl-data")


## Web build (the local wallpaper, tools/build_web_wallpaper.py): the HTML shell preloads this resource pack into
## the browser's in-memory file system; it holds the player's ftl-data under res://ftl-data/ (raw files, read
## through FileAccess / Image.load_from_file like the folder on disk).
const WEB_PACK := "/ftl-data.pck"
const WEB_PACK_ROOT := "res://ftl-data"


## res://ftl-data once the web data pack is mounted (loaded on first call), else "".
static func _web_pack_root() -> String:
	if not OS.has_feature("web"):
		return ""
	if not DirAccess.dir_exists_absolute(WEB_PACK_ROOT):
		if not FileAccess.file_exists(WEB_PACK) or not ProjectSettings.load_resource_pack(WEB_PACK, false):
			return ""
	return WEB_PACK_ROOT


func _find_root() -> String:
	data_problem_text = ""
	var candidates := [
		_web_pack_root(),
		OS.get_environment("FTL_DATA"),
		ProjectSettings.globalize_path("res://").path_join("../ftl-data"),
		OS.get_executable_path().get_base_dir().path_join("ftl-data"),  # exported PC build: next to the exe
		OS.get_executable_path().get_base_dir().path_join("../../ftl-data"),  # build/windows/ in the repo
		user_data_dir(),  # first-run setup (the only location on Android)
	]
	for c in candidates:
		if c == "" or not DirAccess.dir_exists_absolute(c):
			continue
		var problem := data_problem(c)
		if problem == "":
			return c.simplify_path()
		push_warning("ftl-data at %s unusable: %s" % [c, problem])
		if data_problem_text == "":
			data_problem_text = problem
	return ""


## "" when `dir` looks like a usable ftl-data folder, else why not. A folder made by the first-run setup (user://)
## must also hold the extraction marker (written last, so an interrupted extraction never counts).
static func data_problem(dir: String) -> String:
	for r in DatExtractor.REQUIRED:
		var p := dir.path_join(r)
		if not FileAccess.file_exists(p):
			return "%s is missing" % r
		var f := FileAccess.open(p, FileAccess.READ)
		if f == null or f.get_length() == 0:
			return "%s is empty or unreadable" % r
	if dir.simplify_path() == user_data_dir().simplify_path() \
			and not FileAccess.file_exists(dir.path_join(DatExtractor.MARKER)):
		return "the extraction did not finish"
	return ""


## Looks for the data folder again and drops every cache built from the old one (after the first-run setup).
## Returns true when a usable folder is now in use.
func reload() -> bool:
	for cache in [_tex_cache, _text_cache, _texts, _blueprint_lists, _item_info_cache, _stripped_cache,
			_crew_colors_cache, _crew_names, _sound_map, _loop_max, _stream_cache, _anim_cache, _font_files,
			_room_layouts]:
		(cache as Dictionary).clear()
	root = _find_root()
	if root != "":
		print("ftl-data: ", root)
		data_reloaded.emit()
	return root != ""


# ---------------------------------------------------------------- files

## A file of ftl-data (relative path), or a project file ("res://...", e.g. PROJECT_SHIPS).
## Mods see every file once through the `data_text_loaded` filter (data patches, rules/hooks.md).
func text(rel: String) -> String:
	if not _text_cache.has(rel):
		var path := rel if rel.begins_with("res://") else root.path_join(rel)
		var raw := FileAccess.get_file_as_string(path)
		var t: Variant = Hooks.filter(&"data_text_loaded", raw, rel)
		_text_cache[rel] = raw if Hooks.is_cancel(t) else String(t)
	return _text_cache[rel]


## Drops every cached data text and the caches derived from it (a data patch was switched on / off). Ships
## created afterwards read the re-filtered text.
func clear_data_cache() -> void:
	_text_cache.clear()
	_stripped_cache.clear()
	_item_info_cache.clear()


func texture(rel: String) -> Texture2D:
	if _tex_cache.has(rel):
		return _tex_cache[rel]
	var path := root.path_join(rel)
	var tex: Texture2D = null
	if FileAccess.file_exists(path):
		var img := Image.load_from_file(path)
		if img:
			tex = ImageTexture.create_from_image(img)
	_tex_cache[rel] = tex
	return tex


func first_texture(rels: Array) -> Texture2D:
	for r in rels:
		var t := texture(r)
		if t:
			return t
	return null


# ---------------------------------------------------------------- FTL-style "XML"
# FTL's XML files are not valid XML (multiple roots, malformed comments),
# so they are processed with regular expressions instead of a strict parser.

static func strip_comments(s: String) -> String:
	var re := RegEx.create_from_string("<!--[\\s\\S]*?-->")
	return re.sub(s, "", true)


static func attrs(tag_body: String) -> Dictionary:
	var out := {}
	var re := RegEx.create_from_string("(\\w+)\\s*=\\s*\"([^\"]*)\"")
	for m in re.search_all(tag_body):
		out[m.get_string(1)] = m.get_string(2)
	return out


static func tag_value(block: String, tag: String) -> String:
	var re := RegEx.create_from_string("<" + tag + "\\b[^>]*>([\\s\\S]*?)</" + tag + ">")
	var m := re.search(block)
	return m.get_string(1).strip_edges() if m else ""


static func tag_attrs(block: String, tag: String) -> Dictionary:
	var re := RegEx.create_from_string("<" + tag + "\\b([^>]*?)/?>")
	var m := re.search(block)
	return attrs(m.get_string(1)) if m else {}


# ---------------------------------------------------------------- ships

## Project-owned ship blueprints (test ships; same shape as FTL's <shipBlueprint>). Searched first;
## FTL's own data is never modified.
const PROJECT_SHIPS := "res://data/test_ships.xml"
## dlcBlueprintsOverwrite.xml last: it only adds the type C player ships (PLAYER_SHIP_*_3) not defined earlier.
## dlcPirateBlueprints.xml: the AE pirate variants (e.g. JELLY_BUTTON_P_DLC "Pirate Scout").
## bosses.xml: the flagship stages BOSS_<1-3>_<EASY|NORMAL|HARD>[_DLC] (BossShip::StartStage, rules/flagship.md).
const SHIP_FILES := [PROJECT_SHIPS, "data/blueprints.xml", "data/autoBlueprints.xml", "data/dlcBlueprints.xml",
	"data/dlcBlueprintsOverwrite.xml", "data/bosses.xml", "data/dlcPirateBlueprints.xml"]


## Raw match of <shipBlueprint name="..."> (group 1 = attributes, 2 = body), or null.
func _ship_blueprint_match(bp_name: String) -> RegExMatch:
	for file in SHIP_FILES:
		var src := strip_comments(text(file))
		var re := RegEx.create_from_string(
			"<shipBlueprint\\s+([^>]*name=\"" + bp_name + "\"[^>]*)>([\\s\\S]*?)</shipBlueprint>")
		var m := re.search(src)
		if m:
			return m
	return null


func has_ship_blueprint(bp_name: String) -> bool:
	return _ship_blueprint_match(bp_name) != null


## Body of a <shipBlueprint> (between the tags), or "".
func ship_blueprint_text(bp_name: String) -> String:
	var m := _ship_blueprint_match(bp_name)
	return m.get_string(2) if m else ""


## Finds a <shipBlueprint name="..."> in the blueprint files (project test ships first).
func ship_blueprint(bp_name: String) -> Dictionary:
	var m := _ship_blueprint_match(bp_name)
	if m:
		var bp := _parse_ship_blueprint(attrs(m.get_string(1)), m.get_string(2))
		var f: Variant = Hooks.filter(&"ship_blueprint_loaded", bp, bp_name)
		return bp if Hooks.is_cancel(f) else f
	push_error("Blueprint not found: " + bp_name)
	return {}


func _parse_ship_blueprint(head: Dictionary, body: String) -> Dictionary:
	var bp := {
		"name": head.get("name", ""),
		"layout": head.get("layout", ""),
		"img": head.get("img", ""),
		# <cloakImage> overrides the cloak image base name (default: img) — BlueprintManager::ProcessShipBlueprint
		"cloak_img": tag_value(body, "cloakImage") if tag_value(body, "cloakImage") != "" else head.get("img", ""),
		# <shieldImage> / <floorImage> override the shield / floor base names the same way (shieldFile, floorFile;
		# B/C layouts reuse the A ship's art: Kestrel B "kestral_2" -> kestral_shields1.png). Shields::Shields
		# 0x0060b230 loads "ship/<shieldFile>_shields1.png" for the player (rules/hud_layout.md).
		"shield_img": tag_value(body, "shieldImage") if tag_value(body, "shieldImage") != "" else head.get("img", ""),
		"floor_img": tag_value(body, "floorImage") if tag_value(body, "floorImage") != "" else head.get("img", ""),
		"systems": [],
		"hull": int(tag_attrs(body, "health").get("amount", "0")),
		"max_power": int(tag_attrs(body, "maxPower").get("amount", "0")),
		"weapon_slots": int(tag_value(body, "weaponSlots")) if tag_value(body, "weaponSlots") != "" else 4,
		"drone_slots": int(tag_value(body, "droneSlots")) if tag_value(body, "droneSlots") != "" else 0,
		"missiles": int(tag_attrs(body, "weaponList").get("missiles", "0")),
		"crew": [],
	}
	var sys_block := tag_value(body, "systemList")
	var re := RegEx.create_from_string("<(\\w+)\\s+([^>]*?)/?>")
	for m in re.search_all(sys_block):
		var a := attrs(m.get_string(2))
		if not a.has("room"):
			continue
		# Optional <slot><direction/><number/></slot> child: console slot (medbay/clonebay: blocked slot).
		var slot := -1
		var slot_dir := ""
		if not m.get_string(0).ends_with("/>"):
			var close := sys_block.find("</" + m.get_string(1) + ">", m.get_end())
			if close >= 0:
				var inner := sys_block.substr(m.get_end(), close - m.get_end())
				var slot_block := tag_value(inner, "slot")
				if tag_value(slot_block, "number") != "":
					slot = int(tag_value(slot_block, "number"))
				slot_dir = tag_value(slot_block, "direction")
		bp.systems.append({
			"id": m.get_string(1),
			"power": int(a.get("power", "0")),
			"room": int(a.room),
			"start": a.get("start", "true") == "true",
			"img": a.get("img", ""),
			"slot": slot,  # -1 = not given in the blueprint
			"slot_dir": slot_dir,
			"weapon": a.get("weapon", ""),  # artillery: weapon blueprint of its ProjectileFactory
		})
	var re_crew := RegEx.create_from_string("<crewCount\\s+([^>]*?)/?>")
	for m in re_crew.search_all(body):
		var a := attrs(m.get_string(1))
		for i in int(a.get("amount", "0")):
			bp.crew.append(a.get("class", "human"))
	return bp


## Reads data/<layout>.txt (rooms and doors) and data/<layout>.xml (image offsets).
func ship_layout(layout: String) -> Dictionary:
	var lines := text("data/" + layout + ".txt").split("\n", false)
	var tok: Array[String] = []
	for l in lines:
		var t := l.strip_edges()
		if t != "":
			tok.append(t)
	var lay := {"x_offset": 0, "y_offset": 0, "rooms": [], "doors": [], "vertical": 0, "horizontal": 0}
	var i := 0
	while i < tok.size():
		match tok[i]:
			"X_OFFSET":
				lay.x_offset = int(tok[i + 1]); i += 2
			"Y_OFFSET":
				lay.y_offset = int(tok[i + 1]); i += 2
			"VERTICAL":  # Ship::vertical_shift: screen placement (rules/hud_layout.md)
				lay.vertical = int(tok[i + 1]); i += 2
			"HORIZONTAL":
				lay.horizontal = int(tok[i + 1]); i += 2
			"ELLIPSE":
				lay.ellipse = Vector4(int(tok[i + 1]), int(tok[i + 2]), int(tok[i + 3]), int(tok[i + 4]))
				i += 5
			"ROOM":
				lay.rooms.append({"id": int(tok[i + 1]),
					"rect": Rect2i(int(tok[i + 2]), int(tok[i + 3]), int(tok[i + 4]), int(tok[i + 5]))})
				i += 6
			"DOOR":
				lay.doors.append({"x": int(tok[i + 1]), "y": int(tok[i + 2]),
					"left": int(tok[i + 3]), "right": int(tok[i + 4]), "vertical": int(tok[i + 5]) == 1})
				i += 6
			_:
				i += 1
	var xml := strip_comments(text("data/" + layout + ".xml"))
	var img := tag_attrs(xml, "img")
	lay.img_rect = Rect2(float(img.get("x", "0")), float(img.get("y", "0")),
		float(img.get("w", "0")), float(img.get("h", "0")))
	var floor_off := tag_attrs(xml, "floor")
	lay.floor_offset = Vector2(float(floor_off.get("x", "0")), float(floor_off.get("y", "0")))
	var cloak_off := tag_attrs(xml, "cloak")  # <offsets><cloak x y/>: cloak image relative to the hull image
	lay.cloak_offset = Vector2(float(cloak_off.get("x", "0")), float(cloak_off.get("y", "0")))
	return lay


var _texts := {}

## Translatable text by id (English, from data/text_*.xml). Returns the id if missing.
func tr_id(id: String) -> String:
	if _texts.is_empty():
		for f in ["data/text_blueprints.xml", "data/text_misc.xml", "data/text_events.xml",
				"data/text_sectorname.xml", "data/text_tooltips.xml", "data/text_achievements.xml"]:
			var re := RegEx.create_from_string("<text\\s+name=\"([^\"]+)\"[^>]*>([^<]*)</text>")
			for m in re.search_all(strip_comments(text(f))):
				_texts[m.get_string(1)] = m.get_string(2)
		# Our own engine texts (English, [ours]; ids not in vanilla): res://data/text_ours.xml.
		var ours := FileAccess.get_file_as_string("res://data/text_ours.xml")
		var ro := RegEx.create_from_string("<text\\s+name=\"([^\"]+)\"[^>]*>([^<]*)</text>")
		for m in ro.search_all(strip_comments(ours)):
			if not _texts.has(m.get_string(1)):
				_texts[m.get_string(1)] = m.get_string(2)
	return _texts.get(id, id)


## Ship explosion gibs of a layout (rules/ship_destruction.md Â§3.1): the children of `<explosion>` in document
## order except `<glowOffset>` (always ignored in 1.6.9) -> [{velocity: Vector2(min, max), direction, angular,
## pos: Vector2 (top-left relative to the hull image)}].
func ship_explosion(layout: String) -> Array:
	var xml := strip_comments(text("data/" + layout + ".xml"))
	var block := tag_value(xml, "explosion")
	var out := []
	var re := RegEx.create_from_string("<(\\w+)\\s*>([\\s\\S]*?)</\\1>")
	for m in re.search_all(block):
		if m.get_string(1) == "glowOffset":
			continue
		var body := m.get_string(2)
		var rng := func(tag: String) -> Vector2:
			var a := tag_attrs(body, tag)
			return Vector2(float(a.get("min", "0")), float(a.get("max", "0")))
		out.append({"velocity": rng.call("velocity"), "direction": rng.call("direction"),
			"angular": rng.call("angular"),
			"pos": Vector2(float(tag_value(body, "x")), float(tag_value(body, "y")))})
	return out


## Weapon mounts of a layout (positions relative to the hull image).
func weapon_mounts(layout: String) -> Array:
	var xml := strip_comments(text("data/" + layout + ".xml"))
	var block := tag_value(xml, "weaponMounts")
	var out := []
	var re := RegEx.create_from_string("<mount\\s+([^>]*?)/?>")
	for m in re.search_all(block):
		var a := attrs(m.get_string(1))
		out.append({"pos": Vector2(float(a.get("x", "0")), float(a.get("y", "0"))),
			"rotate": a.get("rotate", "false") == "true", "mirror": a.get("mirror", "false") == "true",
			"slide": slide_direction(a.get("slide", "")), "gib": int(a.get("gib", "-1"))})
	return out


## Globals::GetDirection: "up" 2, "down" 0, "left" 3, "right" 1, anything else (none, "no") 4 = no slide.
static func slide_direction(dir: String) -> int:
	match dir:
		"up":
			return 2
		"down":
			return 0
		"left":
			return 3
		"right":
			return 1
	return 4


var _blueprint_lists := {}


## <blueprintList name="..."> -> list of names ([] if there is no such list). Cached; callers get a copy.
## dlcBlueprintsOverwrite.xml is searched last (its OVERRIDE_* lists and WEAPONS_MISSILES_EVENTS live only there).
func blueprint_list(list_name: String) -> Array:
	if _blueprint_lists.has(list_name):
		return (_blueprint_lists[list_name] as Array).duplicate()
	var out := []
	for file in ["data/blueprints.xml", "data/autoBlueprints.xml", "data/dlcBlueprints.xml",
			"data/dlcBlueprintsOverwrite.xml"]:
		var re := RegEx.create_from_string(
			"<blueprintList\\s+name=\"" + list_name + "\"[^>]*>([\\s\\S]*?)</blueprintList>")
		var m := re.search(_stripped(file))
		if m:
			for n in RegEx.create_from_string("<name>([^<]+)</name>").search_all(m.get_string(1)):
				out.append(n.get_string(1).strip_edges())
			break
	_blueprint_lists[list_name] = out
	return out.duplicate()


## BlueprintManager::GetBlueprintList(name): with Advanced Edition content on (Settings::GetDlcEnabled) a list
## named "OVERRIDE_" + name replaces `name` when it exists [exe 0x5e5a60]. Used by the ship generator's weapon /
## drone pools (ShipGenerator::GetPossibleWeaponList / GetPossibleDroneList).
func blueprint_list_ae(list_name: String, ae: bool) -> Array:
	if ae and not list_name.begins_with("OVERRIDE_"):
		var ov := blueprint_list("OVERRIDE_" + list_name)
		if not ov.is_empty():
			return ov
	return blueprint_list(list_name)


var _item_info_cache := {}
const ITEM_TAGS := {"weapon": "weaponBlueprint", "drone": "droneBlueprint", "augment": "augBlueprint",
	"crew": "crewBlueprint", "system": "systemBlueprint", "item": "itemBlueprint"}


## Store / reward view of a blueprint (kind: weapon, drone, augment, crew, system, item = fuel / missiles / drones):
## {name, kind, cost, rarity, power, title, desc, stackable, value, tip (text id of <tip>, "" if none)}; {} if not
## found. Later files win (dlcBlueprintsOverwrite).
func item_info(kind: String, iname: String) -> Dictionary:
	var key := kind + ":" + iname
	if _item_info_cache.has(key):
		return _item_info_cache[key]
	var out := {}
	var tag: String = ITEM_TAGS.get(kind, "")
	for file in ["data/blueprints.xml", "data/dlcBlueprints.xml", "data/dlcBlueprintsOverwrite.xml"]:
		if tag == "":
			break
		var src := _stripped(file)
		var re := RegEx.create_from_string("<" + tag + "\\s+name=\"" + iname + "\"[^>]*>([\\s\\S]*?)</" + tag + ">")
		var m := re.search(src)
		if not m:
			continue
		var b := m.get_string(1)
		out = {"name": iname, "kind": kind, "cost": int(tag_value(b, "cost")),
			"rarity": int(tag_value(b, "rarity")) if tag_value(b, "rarity") != "" else 0,
			"power": int(tag_value(b, "power")), "title": _text_field(b, "title"), "desc": _text_field(b, "desc"),
			"stackable": tag_value(b, "stackable").strip_edges() == "true",
			"value": float(tag_value(b, "value")) if tag_value(b, "value") != "" else 0.0,
			"tip": tag_value(b, "tip").strip_edges()}
	if not out.is_empty() and out.title == "":
		out.title = _fallback_title(kind, iname)
	_item_info_cache[key] = out
	return out


const TITLE_PREFIXES := {"weapon": ["weapon_"], "drone": ["drone_"], "augment": ["aug_"], "crew": ["crew_"],
	"system": ["system_"], "": ["weapon_", "drone_", "aug_", "system_", "crew_"]}


## Display title of a blueprint name (what the exe shows: Blueprint::desc.title). Never the raw id: the blueprint's
## <title> (text id or literal) of the given kind, or of any kind when `kind` is "" (weapon, drone, augment,
## system, crew, item), else the conventional `<prefix><NAME>_title` text, else a readable form of the name
## ("ENGINE_BOOST" -> "Engine Boost").
func blueprint_title(bp_name: String, kind := "") -> String:
	if bp_name == "":
		return ""
	for k in ([kind] if kind != "" else ["weapon", "drone", "augment", "system", "crew", "item"]):
		var info := item_info(String(k), bp_name)
		if not info.is_empty():
			return String(info.title)
	return _fallback_title(kind, bp_name)


## Short name of a weapon / drone (GetNameShort: the `<short>` text, "\n" as a space), else the title.
func blueprint_short(bp_name: String, kind := "") -> String:
	for k in (["weapon", "drone"] if kind == "" else [kind]):
		if not k in ["weapon", "drone"]:
			continue
		var b := _blueprint_body("weaponBlueprint" if k == "weapon" else "droneBlueprint", bp_name)
		if b != "":
			var t := _text_field(b, "short").replace("\\n", " ").replace("\n", " ")
			return t if t != "" else blueprint_title(bp_name, k)
	return blueprint_title(bp_name, kind)


## Body of the last `<tag name="bp_name">` over the blueprint files ("" if none).
func _blueprint_body(tag: String, bp_name: String) -> String:
	var out := ""
	for file in ["data/blueprints.xml", "data/dlcBlueprints.xml", "data/dlcBlueprintsOverwrite.xml"]:
		var re := RegEx.create_from_string("<" + tag + "\\s+name=\"" + bp_name + "\"[^>]*>([\\s\\S]*?)</" + tag + ">")
		var m := re.search(_stripped(file))
		if m:
			out = m.get_string(1)
	return out


## Title for a name without a usable <title>: the conventional text ids of its kind, else a readable name.
func _fallback_title(kind: String, bp_name: String) -> String:
	for p in TITLE_PREFIXES.get(kind, TITLE_PREFIXES[""]):
		for nm in [bp_name, bp_name.to_lower()]:
			var id := "%s%s_title" % [p, nm]
			var t := tr_id(id)
			if t != id:
				return t
	return readable_name(bp_name)


## "ENGINE_BOOST" -> "Engine Boost", "engines" -> "Engines" (last resort so raw ids never reach the UI).
static func readable_name(id: String) -> String:
	return id.replace("_", " ").strip_edges().to_lower().capitalize()


var _stripped_cache := {}


func _stripped(file: String) -> String:
	if not _stripped_cache.has(file):
		_stripped_cache[file] = strip_comments(text(file))
	return _stripped_cache[file]


## <tag id="x"/> (text id) or <tag>literal</tag>.
func _text_field(b: String, tag: String) -> String:
	var id := String(tag_attrs(b, tag).get("id", ""))
	if id != "":
		var t := tr_id(id)
		return t.replace("\\n", "\n") if t != id else ""  # a missing text id is never shown raw
	return tag_value(b, tag).strip_edges()


var _crew_colors_cache := {}


## <crewBlueprint><colorList> (rules/crew_appearance.md §1): one Array[Color] per non-empty <layer>, r/g/b / 255,
## a as-is; commented-out colours ignored; later blueprint files win. [] for races without layers (engi, drones).
func crew_colors(race: String) -> Array:
	if _crew_colors_cache.has(race):
		return _crew_colors_cache[race]
	var out := []
	for file in ["data/blueprints.xml", "data/dlcBlueprints.xml", "data/dlcBlueprintsOverwrite.xml"]:
		var re := RegEx.create_from_string("<crewBlueprint\\s+name=\"" + race + "\"[^>]*>([\\s\\S]*?)</crewBlueprint>")
		var m := re.search(_stripped(file))
		if not m:
			continue
		out = []
		var cl := tag_value(m.get_string(1), "colorList")
		for lm in RegEx.create_from_string("<layer\\b[^>]*>([\\s\\S]*?)</layer>").search_all(cl):
			var cols: Array[Color] = []
			for cm in RegEx.create_from_string("<color\\b([^>]*?)/?>").search_all(lm.get_string(1)):
				var a := attrs(cm.get_string(1))
				cols.append(Color(float(a.get("r", "255")) / 255.0, float(a.get("g", "255")) / 255.0,
					float(a.get("b", "255")) / 255.0, float(a.get("a", "1"))))
			if not cols.is_empty():
				out.append(cols)
	_crew_colors_cache[race] = out
	return out


var _crew_names := {}


## data/names.xml (rules/crew_appearance.md §1): {names: {name: is_male} (lists without `language`, sorted
## unique keys, last list wins the gender), keys: sorted Array, short: {full name: preset short}}.
func crew_names() -> Dictionary:
	if not _crew_names.is_empty():
		return _crew_names
	var names := {}
	var shorts := {}
	var src := strip_comments(text("data/names.xml"))
	for lm in RegEx.create_from_string("<nameList\\b([^>]*)>([\\s\\S]*?)</nameList>").search_all(src):
		var la := attrs(lm.get_string(1))
		if la.has("language"):
			continue
		var male := String(la.get("sex", "male")) == "male"
		for nm in RegEx.create_from_string("<name\\b([^>]*)>([^<]*)</name>").search_all(lm.get_string(2)):
			var full := nm.get_string(2).strip_edges()
			if full == "":
				continue
			names[full] = male
			var na := attrs(nm.get_string(1))
			if na.has("short"):
				shorts[full] = String(na.short)
	var keys := names.keys()
	keys.sort()
	_crew_names = {"names": names, "keys": keys, "short": shorts}
	return _crew_names


## True when a <weaponBlueprint name="..."> exists (no error). BlueprintManager::GetWeaponBlueprint (0x5e6580)
## returns a static default blueprint for unknown names (e.g. BOMB_BREACH in WEAPONS_JELLY), which
## ShipGenerator::GetPossibleWeaponList never picks (power 0).
func has_weapon_blueprint(wname: String) -> bool:
	for file in ["data/blueprints.xml", "data/dlcBlueprints.xml", "data/dlcBlueprintsOverwrite.xml"]:
		if strip_comments(text(file)).contains("<weaponBlueprint name=\"" + wname + "\""):
			return true
	return false


## <weaponBlueprint name="..."> -> numeric weapon data.
func weapon_blueprint(wname: String) -> Dictionary:
	for file in ["data/blueprints.xml", "data/dlcBlueprints.xml", "data/dlcBlueprintsOverwrite.xml"]:
		var src := strip_comments(text(file))
		var re := RegEx.create_from_string(
			"<weaponBlueprint\\s+name=\"" + wname + "\"[^>]*>([\\s\\S]*?)</weaponBlueprint>")
		var m := re.search(src)
		if m:
			var b := m.get_string(1)
			return {
				"name": wname,
				"type": tag_value(b, "type"),
				"damage": int(tag_value(b, "damage")),
				"shots": maxi(1, int(tag_value(b, "shots"))),
				"sp": int(tag_value(b, "sp")),
				"cooldown": float(tag_value(b, "cooldown")),
				"power": int(tag_value(b, "power")),
				"missiles": int(tag_value(b, "missiles")),
				"speed": float(tag_value(b, "speed")),
				"image": tag_value(b, "image"),
				"title": _text_field(b, "title") if _text_field(b, "title") != "" else _fallback_title("weapon", wname),
				"short": tag_attrs(b, "short").get("id", ""),
				"weapon_art": tag_value(b, "weaponArt"),
				"ion": int(tag_value(b, "ion")),
				"sys_damage": int(tag_value(b, "sysDamage")),
				"pers_damage": int(tag_value(b, "persDamage")),
				"hull_bust": int(tag_value(b, "hullBust")),
				"fire_chance": int(tag_value(b, "fireChance")),
				"breach_chance": int(tag_value(b, "breachChance")),
				"stun_chance": int(tag_value(b, "stunChance")),
				"stun": float(tag_value(b, "stun")),
				"flavor_type": _text_field(b, "flavorType"),
				"tooltip_text": _text_field(b, "tooltip"),
				"lockdown": tag_value(b, "lockdown") == "1" or tag_value(b, "lockdown") == "true",
				"charge_levels": maxi(1, int(tag_value(b, "chargeLevels"))),
				# Beam / flak / chain / visuals (rules/weapons.md)
				"length": int(tag_value(b, "length")),
				"radius": int(tag_value(b, "radius")),
				"spin": float(tag_value(b, "spin")),
				"explosion": tag_value(b, "explosion"),
				"color": _weapon_color(b),
				"boost": _weapon_boost(b),
				"mini_projectiles": _mini_projectiles(b),
				"launch_sounds": _sound_list(b, "launchSounds"),
				"hit_ship_sounds": _sound_list(b, "hitShipSounds"),
				"hit_shield_sounds": _sound_list(b, "hitShieldSounds"),
				"miss_sounds": _sound_list(b, "missSounds"),
				# <drone_targetable>1</drone_targetable>: defence drones may shoot it (rules/drones.md Â§6)
				"drone_targetable": tag_value(b, "drone_targetable").strip_edges() == "1",
			}
	push_error("Weapon not found: " + wname)
	return {}


## <droneBlueprint name="..."> (BlueprintManager::ProcessDroneBlueprint, rules/drones.md Â§1):
## cooldown in seconds (ms / 1000), target type 1 MISSILES (default) / 4 LASERS (also level 2) / 3 DRONES.
func drone_blueprint(dname: String) -> Dictionary:
	for file in ["data/blueprints.xml", "data/dlcBlueprints.xml", "data/dlcBlueprintsOverwrite.xml"]:
		var src := strip_comments(text(file))
		var re := RegEx.create_from_string(
			"<droneBlueprint\\s+name=\"" + dname + "\"[^>]*>([\\s\\S]*?)</droneBlueprint>")
		var m := re.search(src)
		if not m:
			continue
		var b := m.get_string(1)
		var level := int(tag_value(b, "level")) if tag_value(b, "level") != "" else 1
		var target := 4 if level == 2 else 1
		match tag_value(b, "target").strip_edges():
			"LASERS":
				target = 4
			"MISSILES":
				target = 1
			"DRONES":
				target = 3
		var title_id := String(tag_attrs(b, "title").get("id", ""))
		var short_id := String(tag_attrs(b, "short").get("id", ""))
		var short := tag_value(b, "short")
		return {
			"name": dname,
			"type": tag_value(b, "type").strip_edges(),
			"power": int(tag_value(b, "power")),
			"cooldown": float(tag_value(b, "cooldown")) / 1000.0,
			"speed": float(tag_value(b, "speed")),
			"dodge": int(tag_value(b, "dodge")),
			"level": level,
			"target_type": target,
			"weapon": tag_value(b, "weaponBlueprint").strip_edges(),
			"drone_image": tag_value(b, "droneImage").strip_edges(),
			"icon": tag_value(b, "iconImage").strip_edges(),
			"title": _text_field(b, "title") if _text_field(b, "title") != "" else _fallback_title("drone", dname),
			"short": _text_field(b, "short") if _text_field(b, "short") != "" else blueprint_title(dname, "drone"),
		}
	push_error("Drone not found: " + dname)
	return {}


## Beam colour: <color><r/><g/><b/></color>, default (227, 39, 39) as in the WeaponBlueprint constructor.
static func _weapon_color(b: String) -> Color:
	var c := tag_value(b, "color")
	if c == "":
		return Color8(227, 39, 39)
	return Color8(int(tag_value(c, "r")), int(tag_value(c, "g")), int(tag_value(c, "b")))


## <boost><type>cooldown|damage</type><amount/><count/></boost> -> {type, amount, count} ({} = none).
static func _weapon_boost(b: String) -> Dictionary:
	var s := tag_value(b, "boost")
	if s == "":
		return {}
	return {"type": tag_value(s, "type"), "amount": float(tag_value(s, "amount")),
		"count": int(tag_value(s, "count"))}


## Flak <projectiles>: one entry per projectile (each <projectile count="N"> expanded), in order.
static func _mini_projectiles(b: String) -> Array:
	var out := []
	var block := tag_value(b, "projectiles")
	var re := RegEx.create_from_string("<projectile\\b([^>]*)>([^<]*)</projectile>")
	for m in re.search_all(block):
		var a := attrs(m.get_string(1))
		for i in int(a.get("count", "1")):
			out.append({"image": m.get_string(2).strip_edges(), "fake": a.get("fake", "false") == "true"})
	return out


## <weaponAnim name="..."> -> {length, charged_frame, fire_frame, fire_point, mount_point, charge_image,
## sheet: {texture, frames: Array[Rect2], fw, fh}} (rules/weapon_visuals.md "Weapon mounts").
func weapon_anim(anim_name: String) -> Dictionary:
	var src := strip_comments(text("data/animations.xml") + text("data/dlcAnimations.xml"))
	var re := RegEx.create_from_string("<weaponAnim\\s+name=\"" + anim_name + "\"\\s*>([\\s\\S]*?)</weaponAnim>")
	var m := re.search(src)
	if not m:
		return {"length": 1, "charged_frame": 0, "fire_frame": 0, "fire_point": Vector2.ZERO,
			"mount_point": Vector2.ZERO, "charge_image": "", "sheet": {}}
	var b := m.get_string(1)
	var d := tag_attrs(b, "desc")
	var fp := tag_attrs(b, "firePoint")
	var mp := tag_attrs(b, "mountPoint")
	var out := {
		"length": int(d.get("length", "1")),
		"charged_frame": int(tag_value(b, "chargedFrame")),
		"fire_frame": int(tag_value(b, "fireFrame")),
		"fire_point": Vector2(float(fp.get("x", "0")), float(fp.get("y", "0"))),
		"mount_point": Vector2(float(mp.get("x", "0")), float(mp.get("y", "0"))),
		"charge_image": tag_value(b, "chargeImage").strip_edges(),
		"sheet": {},
	}
	var sheet := anim_sheet(tag_value(b, "sheet").strip_edges(), m.get_start())
	if not sheet.is_empty() and sheet.texture != null:
		var rows: int = maxi(int(sheet.h) / maxi(int(sheet.fh), 1), 1)
		var row_top: int = rows - 1 - int(d.get("y", "0"))
		var frames: Array[Rect2] = []
		for i in int(out.length):
			frames.append(Rect2((int(d.get("x", "0")) + i) * sheet.fw, row_top * sheet.fh, sheet.fw, sheet.fh))
		out.sheet = {"texture": sheet.texture, "frames": frames, "fw": int(sheet.fw), "fh": int(sheet.fh)}
	return out


static func _sound_list(block: String, tag: String) -> Array:
	var out := []
	for m in RegEx.create_from_string("<sound>([^<]+)</sound>").search_all(tag_value(block, tag)):
		out.append(m.get_string(1).strip_edges())
	return out


# ---------------------------------------------------------------- sound

var _sound_map := {}  # name -> {file, volume}
var _loop_max := {}  # loop="true" sounds: name -> maxCount (the count attribute, at least 1)
var _stream_cache := {}
var muted := false
## Debug / tests: every `play` call (also while muted) is appended to `play_log` as {name, t (s since start),
## found (the name is in sounds.xml and its file loads)}; the `--sound-log` command-line flag also prints each one.
var record_plays := false
var play_log: Array = []
var _print_plays := false


## sounds.xml + dlcSounds.xml entries `<name volume=".." ...>dir/file.ogg</name>`. The closing tag may carry
## whitespace (vanilla sounds.xml has `</environWarning >`, which FTL's XML parser accepts).
func _load_sound_map() -> void:
	if not _sound_map.is_empty() or root == "":
		return
	var re := RegEx.create_from_string("<(\\w+)\\s*([^>]*)>([^<]+\\.(?:wav|ogg))</\\1\\s*>")
	for m in re.search_all(strip_comments(text("data/sounds.xml") + text("data/dlcSounds.xml"))):
		var a := attrs(m.get_string(2))
		_sound_map[m.get_string(1)] = {"file": m.get_string(3).strip_edges(),
			"volume": float(a.get("volume", "5"))}
		# loop="true" entries are also SoundControl::LoopableSound (maxCount = the count attribute). A later
		# plain entry of the same name (vanilla sounds.xml repeats `brawling` without loop) keeps the loop.
		if a.get("loop", "") == "true":
			_loop_max[m.get_string(1)] = maxf(float(a.get("count", "1")), 1.0)


## True when `sound_name` is a sounds.xml entry whose audio file loads.
func has_sound(sound_name: String) -> bool:
	_load_sound_map()
	var entry: Dictionary = _sound_map.get(sound_name, {})
	return not entry.is_empty() and _stream(entry.file) != null


func _record_play(sound_name: String) -> void:
	var rec := {"name": sound_name, "t": Time.get_ticks_msec() / 1000.0, "found": has_sound(sound_name)}
	play_log.append(rec)
	if play_log.size() > 512:
		play_log.remove_at(0)
	if _print_plays:
		print("SOUND %.2f %s%s" % [rec.t, sound_name, "" if rec.found else " (NOT FOUND)"])


## Plays a sound by its name in data/sounds.xml (e.g. "powerUpSystem").
## `volume_scale` multiplies the sounds.xml volume (SoundControl::PlaySoundMix volume, e.g. 0.25).
func play(sound_name: String, volume_scale := 1.0) -> void:
	if record_plays and sound_name != "":
		_record_play(sound_name)
	if muted or sound_name == "" or root == "":
		return
	_load_sound_map()
	var entry: Dictionary = _sound_map.get(sound_name, {})
	if entry.is_empty():
		return
	var stream := _stream(entry.file)
	if stream == null:
		return
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.volume_db = linear_to_db(clampf(entry.volume / 10.0, 0.05, 1.0)) - 6.0 + linear_to_db(maxf(volume_scale, 0.01))
	p.bus = &"SFX"  # sound volume option (GameOptions.apply_volumes); music has its own bus
	add_child(p)
	p.finished.connect(p.queue_free)
	p.play()


var _loops := {}  # sound name -> AudioStreamPlayer (looping sounds, e.g. hackLoop)


## Starts / stops a looping sound (sounds.xml loop="true", e.g. hackLoop). `fade_out` > 0: stopping slides the
## volume down over that many seconds first (SoundControl::UpdateSoundLoop: BASS_ChannelSlideAttribute 500 ms).
func set_loop(sound_name: String, on: bool, fade_out := 0.0) -> void:
	var p: AudioStreamPlayer = _loops.get(sound_name)
	if not on or muted or root == "":
		if p:
			_loops.erase(sound_name)
			if fade_out > 0.0 and p.is_inside_tree():
				p.finished.disconnect(p.play)
				p.finished.connect(p.queue_free)
				var tw := p.create_tween()
				tw.tween_property(p, "volume_db", -60.0, fade_out)
				tw.tween_callback(p.queue_free)
			else:
				p.queue_free()
		return
	if p:
		return
	_load_sound_map()
	var entry: Dictionary = _sound_map.get(sound_name, {})
	if entry.is_empty():
		return
	var stream := _stream(entry.file)
	if stream == null:
		return
	if stream is AudioStreamOggVorbis:
		stream.loop = true
	p = AudioStreamPlayer.new()
	p.stream = stream
	p.volume_db = linear_to_db(clampf(entry.volume / 10.0, 0.05, 1.0)) - 6.0
	p.bus = &"SFX"
	add_child(p)
	p.finished.connect(p.play)
	p.play()
	_loops[sound_name] = p


var _loop_counts := {}  # update_sound_loop: name -> current count (> 0 only; kept while muted too)
## Loops PauseLoops leaves running while the game is paused: SoundControl::ParseSoundFile clears the pausable
## flag of `distress` only (the star map, open = menu pause, plays it).
const UNPAUSABLE_LOOPS := ["distress"]


## SoundControl::UpdateSoundLoop(name, count): count is clamped to the loop's maxCount (sounds.xml count). count > 0
## starts the loop if it is not playing (PlaySoundMix, logged in `play_log` like `play`) and sets its volume to
## sounds.xml volume × count / maxCount; count ≤ 0 fades a playing loop out over 500 ms
## (BASS_ChannelSlideAttribute to -1 = stop).
func update_sound_loop(sound_name: String, count: float) -> void:
	_load_sound_map()
	var mx: float = _loop_max.get(sound_name, 1.0)
	var c := minf(count, mx)
	var was: float = _loop_counts.get(sound_name, 0.0)
	if c <= 0.0:
		if was > 0.0:
			_loop_counts.erase(sound_name)
			set_loop(sound_name, false, 0.5)
		return
	if was <= 0.0 and record_plays:
		_record_play(sound_name)
	_loop_counts[sound_name] = c
	set_loop(sound_name, true)
	var p: AudioStreamPlayer = _loops.get(sound_name)
	if p:
		var entry: Dictionary = _sound_map.get(sound_name, {})
		p.volume_db = linear_to_db(clampf(float(entry.get("volume", 5.0)) / 10.0, 0.05, 1.0)) - 6.0 \
			+ linear_to_db(c / mx)
		if _loops_paused and not sound_name in UNPAUSABLE_LOOPS:
			p.stream_paused = true


## Current update_sound_loop count of a loop (0 = stopped). For tests and debugging.
func loop_count(sound_name: String) -> float:
	return _loop_counts.get(sound_name, 0.0)


## Stops an update_sound_loop loop at once (no fade), e.g. when the game scene goes away.
func stop_sound_loop(sound_name: String) -> void:
	_loop_counts.erase(sound_name)
	set_loop(sound_name, false)


var _loops_paused := false


## SoundControl::PauseLoops(gamePaused), every frame from SoundControl::OnLoop(CommandGui::IsPaused): every playing
## loop is paused while the game is paused and resumed after, except UNPAUSABLE_LOOPS.
func pause_loops(paused: bool) -> void:
	_loops_paused = paused
	for n in _loops:
		var p: AudioStreamPlayer = _loops[n]
		if is_instance_valid(p):
			p.stream_paused = paused and not n in UNPAUSABLE_LOOPS


func play_random(names: Array) -> void:
	if not names.is_empty():
		play(names[randi() % names.size()])


func _stream(rel: String) -> AudioStream:
	if _stream_cache.has(rel):
		return _stream_cache[rel]
	var path := root.path_join("audio/waves").path_join(rel)
	var s: AudioStream = null
	if FileAccess.file_exists(path):
		if rel.ends_with(".ogg"):
			s = AudioStreamOggVorbis.load_from_file(path)
		elif rel.ends_with(".wav"):
			s = AudioStreamWAV.load_from_buffer(_wav_trimmed(FileAccess.get_file_as_bytes(path)))
	_stream_cache[rel] = s
	return s


## The RIFF data up to the last chunk that fits: ui/bp_door_open.wav (doorOpen / doorClose) ends with 24 bytes of
## junk whose chunk header claims 64 KB, which makes Godot's WAV loader print seek errors on every load.
static func _wav_trimmed(b: PackedByteArray) -> PackedByteArray:
	var i := 12
	while i + 8 <= b.size():
		var sz := b.decode_u32(i + 4)
		if i + 8 + sz > b.size():
			break
		i += 8 + sz + (sz & 1)
	if i >= b.size():
		return b
	var out := b.slice(0, mini(i, b.size()))
	out.encode_u32(4, out.size() - 8)
	return out


var _anim_cache := {}


## <anim name="..."> -> {texture, frames: Array[Rect2], time}. "explosion_random" picks explosion_big2..4
## at random on every call (AnimationControl::GetAnimation).
func anim(anim_name: String) -> Dictionary:
	if anim_name == "explosion_random":
		return anim("explosion_big%d" % (randi() % 3 + 2))
	if not _anim_cache.has(anim_name):
		_anim_cache[anim_name] = _load_anim(anim_name)
	return _anim_cache[anim_name]


func _load_anim(anim_name: String) -> Dictionary:
	var src := strip_comments(text("data/animations.xml") + text("data/dlcAnimations.xml"))
	var re := RegEx.create_from_string("<anim\\s+name=\"" + anim_name + "\"\\s*>([\\s\\S]*?)</anim>")
	var m := re.search(src)
	if not m:
		return {}
	var body := m.get_string(1)
	var sheet := anim_sheet(tag_value(body, "sheet").strip_edges(), m.get_start())
	if sheet.is_empty() or sheet.texture == null:
		return {}
	var d := tag_attrs(body, "desc")
	var rows: int = int(sheet.h) / int(sheet.fh)
	var row_top: int = rows - 1 - int(d.get("y", "0"))  # FTL counts rows from the bottom
	var frames: Array[Rect2] = []
	for i in int(d.get("length", "1")):
		frames.append(Rect2((int(d.get("x", "0")) + i) * sheet.fw, row_top * sheet.fh, sheet.fw, sheet.fh))
	return {"texture": sheet.texture, "frames": frames, "time": float(tag_value(body, "time"))}


## Animation sheet (animations.xml): returns texture and frame size.
## Sheet names are not unique: "bomb_heal" names both the launcher strip (weaponAnim) and, further down,
## the bomb strip (anim). AnimationControl::ImportAnimations reads the files in order and builds each
## <anim>/<weaponAnim> at once from the sheet defined so far, so a later <animSheet> of the same name
## replaces it for the elements after it (rules/weapon_visuals.md "Projectiles"). `before` = offset of the
## referencing element in the combined animations.xml + dlcAnimations.xml source: the last sheet of that
## name defined before it wins (-1, or none before it: the first one).
func anim_sheet(sheet_name: String, before := -1) -> Dictionary:
	var src := strip_comments(text("data/animations.xml") + text("data/dlcAnimations.xml"))
	var re := RegEx.create_from_string(
		"<animSheet\\s+([^>]*name=\"" + sheet_name + "\"[^>]*)>([^<]*)</animSheet>")
	var m: RegExMatch = null
	for c in re.search_all(src):
		if m == null or (before >= 0 and c.get_start() < before):
			m = c
	if not m:
		return {}
	var a := attrs(m.get_string(1))
	return {"texture": texture("img/" + m.get_string(2).strip_edges()),
		"fw": int(a.fw), "fh": int(a.fh), "w": int(a.w), "h": int(a.h)}


# ---------------------------------------------------------------- bitmap fonts (rules/fonts.md)

var _font_files := {}  # file name -> FtlFont


## The FtlFont for a font id (GetFontData remaps applied), or null when ftl-data/fonts is missing.
func ftl_font(font_id: int) -> FtlFont:
	var e: Array = FtlFont.IDS[FtlFont.resolve_id(font_id)]
	var file: String = e[0]
	if not _font_files.has(file):
		var path := root.path_join("fonts/%s.font" % file)
		var f: FtlFont = FtlFont.load_file(path) if FileAccess.file_exists(path) else null
		_font_files[file] = f if f and f.ok else null
	return _font_files[file]


## [scale, baseline, lineHeight] of a font id.
func ftl_font_metrics(font_id: int) -> Array:
	var e: Array = FtlFont.IDS[FtlFont.resolve_id(font_id)]
	var f := ftl_font(font_id)
	var s := float(e[1]) / float(f.height) if f and f.height > 0 else 1.0
	return [s, int(e[2]), int(e[3])]


## Width in pixels of the widest line (easy_measureWidth / text_advance).
func ftl_text_width(font_id: int, text: String) -> int:
	var f := ftl_font(font_id)
	if f == null:
		return text.length() * 6
	var s: float = ftl_font_metrics(font_id)[0]
	var w := 0
	for line in text.split("\n"):
		w = maxi(w, f.line_width(line, s))
	return w


## Line height of a font id (freetype::print line step).
func ftl_line_height(font_id: int) -> int:
	return ftl_font_metrics(font_id)[2]


## Splits `text` into lines no wider than `wrap` px (word wrap on spaces; explicit \n kept).
func ftl_wrap(font_id: int, text: String, wrap: int) -> PackedStringArray:
	var out := PackedStringArray()
	for para in text.split("\n"):
		if wrap <= 0:
			out.append(para)
			continue
		var line := ""
		for word in para.split(" "):
			var cand := word if line == "" else line + " " + word
			if line != "" and ftl_text_width(font_id, cand) > wrap:
				out.append(line)
				line = word
			else:
				line = cand
		out.append(line)
	return out


## easy_print: draws `text` with FTL font `font_id` on `ci`. `pos` = top-left of the first line (first
## baseline at pos.y + baseline); align 0 left / 1 centre (ink bounds) / 2 right (text advance) about pos.x.
## Every glyph is placed at a rounded pen position (pixel-exact, nearest filtering). Returns the width.
func draw_ftl_text(ci: CanvasItem, font_id: int, text: String, pos: Vector2, color := Color.WHITE,
		align := 0, wrap := 0) -> int:
	var f := ftl_font(font_id)
	var m := ftl_font_metrics(font_id)
	if f == null:  # no ftl-data fonts: fall back to Godot's default font so the HUD stays readable
		ci.draw_string(ThemeDB.fallback_font, pos + Vector2(0, m[1]), text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			int(m[2]), color)
		return text.length() * 6
	var s: float = m[0]
	var widest := 0
	var y := FtlFont.rnd(pos.y) + int(m[1])
	for line in ftl_wrap(font_id, text, wrap):
		var x0 := FtlFont.rnd(pos.x)
		var lay := f.layout_line(line, s)
		var w := FtlFont.rnd(lay[1])
		widest = maxi(widest, w)
		if align == FtlFont.Align.RIGHT:
			x0 -= w
		elif align == FtlFont.Align.CENTER:
			var b := f.ink_bounds(line, s)
			x0 -= FtlFont.rnd((b.x + b.y) / 2.0)
		for q in lay[0]:
			var g: PackedInt32Array = q[0]
			if g[2] == 0 or g[3] == 0:
				continue
			var dst := Rect2(x0 + q[1], y - FtlFont.rnd(g[4] * s), FtlFont.rnd(g[2] * s), FtlFont.rnd(g[3] * s))
			ci.draw_texture_rect_region(f.texture, dst, Rect2(g[0], g[1], g[2], g[3]), color)
		y += int(m[2])
	return widest


var _room_layouts := {}


## data/rooms.xml <roomLayout name="N"><computerGlow name? x y dir/>, keyed "room_" + N (= the interior image
## name). Returns {name (glow base, default "glow"), pos: Vector2, dir: "UP"/"DOWN"/"LEFT"/"RIGHT"} or {}.
func room_layout(img_name: String) -> Dictionary:
	if _room_layouts.is_empty():
		_room_layouts["__loaded"] = {}
		var src := strip_comments(text("data/rooms.xml"))
		var re := RegEx.create_from_string("<roomLayout\\s+name=\"([^\"]+)\"\\s*>([\\s\\S]*?)</roomLayout>")
		for m in re.search_all(src):
			var g := tag_attrs(m.get_string(2), "computerGlow")
			if g.is_empty():
				continue
			_room_layouts["room_" + m.get_string(1)] = {"name": g.get("name", "glow"),
				"pos": Vector2(float(g.get("x", "0")), float(g.get("y", "0"))), "dir": g.get("dir", "UP")}
	return _room_layouts.get(img_name, {})
