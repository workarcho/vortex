extends Node
## Settings registry (autoload `Settings`; rules/hooks.md "Settings"). Mods declare groups and items; the
## Options screen (OptionsScreen) shows them; values persist to user://settings.cfg.
##
## - A group has a master switch (default OFF). An item's *effective* value (`value(id)`) is its stored value
##   while the master is ON, and its `off` value (false / first option / `off`) while the master is OFF. So with
##   every master OFF the game is vanilla.
## - Stored value resolution, lowest to highest: the item's `default` < a mod-recommended default
##   (`set_mod_default`, e.g. read from hyperspace.xml) < the user's choice (`set_value`).
## - Items with `gameplay: true` (and their group master) are frozen when a run starts (`freeze_run`): during the
##   run `value()` returns the snapshot; changes are saved and apply to the next run.
## - Test scenes (res://tests/ on the command line) never read or write the user's file.

const TYPES := ["bool", "enum", "float"]

var path := "user://settings.cfg"
var groups := {}  # group id -> {id, label, desc, owner, items: [ids], order}
var items := {}  # setting id -> {id, group, label, tooltip, type, default, off, options, min, max, step, gameplay}
var _user := {}  # id (or "group:<id>") -> value chosen by the user (persisted)
var _mod_defaults := {}  # same keys -> mod-recommended value
var _cli := {}  # --set= overrides (session only, never saved; above the user's choice)
var _frozen := {}  # same keys -> value while a run is active (gameplay items and their masters)
var frozen := false
var _order := 0


func _ready() -> void:
	for a in OS.get_cmdline_args():
		if String(a).begins_with("res://tests/"):
			path = ""  # tests: in-memory only, vanilla defaults
	load_file()
	# --set=ID=VALUE (repeatable; ID = an item id or group:<group>): session-only overrides for screenshots.
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--set=") and a.count("=") >= 2:
			var kv := a.trim_prefix("--set=").split("=", true, 1)
			var v: Variant = kv[1]
			if kv[1] in ["true", "false"]:
				v = kv[1] == "true"
			elif kv[1].is_valid_float():
				v = float(kv[1])
			_cli[kv[0]] = v


# ---------------------------------------------------------------- declaration

## Declares a group (master switch). Re-declaring updates the label.
func declare_group(id: String, label: String, desc := "", owner := "") -> void:
	if not groups.has(id):
		_order += 1
		groups[id] = {"id": id, "label": label, "desc": desc, "owner": owner, "items": [], "order": _order}
	else:
		groups[id].label = label
		groups[id].desc = desc


## Declares one item of `group` (declared first). `spec`: {id, label, type ("bool"|"enum"|"float"), default,
## off?, options? (enum: Array of String), min/max/step? (float), gameplay? (bool), tooltip?}.
func declare(group: String, spec: Dictionary) -> void:
	assert(groups.has(group), "declare_group first: " + group)
	var t := String(spec.get("type", "bool"))
	var it := {
		"id": String(spec.id), "group": group, "label": String(spec.get("label", spec.id)),
		"tooltip": String(spec.get("tooltip", "")), "type": t, "default": spec.get("default", true),
		"options": spec.get("options", []), "min": float(spec.get("min", 0.0)), "max": float(spec.get("max", 1.0)),
		"step": float(spec.get("step", 0.1)), "gameplay": bool(spec.get("gameplay", false)),
	}
	var off: Variant = spec.get("off")
	if off == null:
		match t:
			"bool":
				off = false
			"enum":
				off = it.options[0] if not (it.options as Array).is_empty() else ""
			_:
				off = it.default
	it["off"] = off
	items[it.id] = it
	if not (groups[group].items as Array).has(it.id):
		groups[group].items.append(it.id)


## Removes every group / item declared by `owner` (mod unload, tests).
func undeclare_owner(owner: String) -> void:
	for g in groups.keys():
		if groups[g].owner == owner:
			for id in groups[g].items:
				items.erase(id)
			groups.erase(g)


func group_ids() -> Array:
	var ids := groups.keys()
	ids.sort_custom(func(a, b): return groups[a].order < groups[b].order)
	return ids


func group_gameplay(group: String) -> bool:
	for id in groups.get(group, {}).get("items", []):
		if items[id].gameplay:
			return true
	return false


# ---------------------------------------------------------------- values

static func _gkey(group: String) -> String:
	return "group:" + group


## Stored value of an item (ignores the master switch and the run freeze).
func raw(id: String) -> Variant:
	if _cli.has(id):
		return _cli[id]
	if _user.has(id):
		return _user[id]
	if _mod_defaults.has(id):
		return _mod_defaults[id]
	var it: Dictionary = items.get(id, {})
	return it.get("default")


## Master switch as stored (ignores the freeze).
func group_raw(group: String) -> bool:
	var k := _gkey(group)
	return bool(_cli.get(k, _user.get(k, _mod_defaults.get(k, false))))


## Effective master switch (frozen during a run for groups with gameplay items).
func group_enabled(group: String) -> bool:
	var k := _gkey(group)
	if frozen and _frozen.has(k):
		return bool(_frozen[k])
	return group_raw(group)


## Effective value: the run snapshot for frozen items, else the stored value with the master ON, else `off`.
func value(id: String) -> Variant:
	if frozen and _frozen.has(id):
		return _frozen[id]
	return _effective(id)


func _effective(id: String) -> Variant:
	var it: Dictionary = items.get(id, {})
	if it.is_empty():
		return null
	return raw(id) if group_raw(it.group) else it.off


## Shortcut for bool items.
func on(id: String) -> bool:
	return bool(value(id))


func set_value(id: String, v: Variant) -> void:
	if not items.has(id):
		return
	var it: Dictionary = items[id]
	match String(it.type):
		"bool":
			v = bool(v)
		"float":
			v = clampf(float(v), it.min, it.max)
		"enum":
			if not (it.options as Array).has(v):
				return
	_user[id] = v
	save()
	Hooks.emit(&"settings_changed", id, value(id))


func set_group_enabled(group: String, on_: bool) -> void:
	if not groups.has(group):
		return
	_user[_gkey(group)] = on_
	save()
	Hooks.emit(&"settings_changed", _gkey(group), group_enabled(group))


## Mod-recommended default (below the user's choice). `id` = an item id or "group:<group>".
func set_mod_default(id: String, v: Variant) -> void:
	_mod_defaults[id] = v


func clear_mod_defaults() -> void:
	_mod_defaults.clear()


## Forgets the user's choices (tests, "reset").
func reset_user() -> void:
	_user.clear()
	save()


## True while `id` is frozen into the running run (Options greys it out: "applies next run").
func is_frozen(id: String) -> bool:
	return frozen and _frozen.has(id)


# ---------------------------------------------------------------- run freeze

## Snapshot of every gameplay item (and the masters of their groups); `value()` returns it until `thaw()`.
## Returns the snapshot (kept on RunState for a future save).
func freeze_run() -> Dictionary:
	_frozen.clear()
	frozen = false
	for id in items:
		var it: Dictionary = items[id]
		if it.gameplay:
			_frozen[id] = _effective(id)
			_frozen[_gkey(it.group)] = group_raw(it.group)
	frozen = true
	return _frozen.duplicate()


## Restores a snapshot (a loaded run).
func freeze_from(snapshot: Dictionary) -> void:
	_frozen = snapshot.duplicate()
	frozen = true


func thaw() -> void:
	_frozen.clear()
	frozen = false


# ---------------------------------------------------------------- persistence

func save() -> void:
	if path == "":
		return
	var cf := ConfigFile.new()
	for k in _user:
		cf.set_value("settings", k, _user[k])
	cf.save(path)


func load_file() -> void:
	_user.clear()
	if path == "" or not FileAccess.file_exists(path):
		return
	var cf := ConfigFile.new()
	if cf.load(path) != OK:
		return
	for k in cf.get_section_keys("settings") if cf.has_section("settings") else []:
		_user[k] = cf.get_value("settings", k)
