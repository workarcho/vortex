class_name ModContext
extends RefCounted
## What a mod's entry script receives in `_mod_init(ctx)` (rules/hooks.md "Mod loader"). Everything registered
## through it is tagged with the mod id, so `Mods.unload(id)` removes it again.

var id := ""
var name := ""
var version := ""
var dir := ""  # the mod folder (res://mods/<id> or user://mods/<id>)
var manifest := {}
var hooks: Node  # the Hooks autoload
var settings: Node  # the Settings autoload


func listen(hook: StringName, cb: Callable, priority := 0) -> Callable:
	return hooks.listen(hook, cb, priority, id)


func add_filter(hook: StringName, cb: Callable, priority := 0) -> Callable:
	return hooks.add_filter(hook, cb, priority, id)


func set_rule(hook: StringName, cb: Callable) -> void:
	hooks.set_rule(hook, cb, id)


func declare_group(group: String, label: String, desc := "") -> void:
	settings.declare_group(group, label, desc, id)


func declare(group: String, spec: Dictionary) -> void:
	settings.declare(group, spec)


## Maps a hyperspace.xml switch to one of this mod's settings (applied as a mod-recommended default when a
## hyperspace.xml is found). `convert(attrs: Dictionary) -> Variant` returns the value, or null to skip.
func map_hyperspace(tag: String, setting_id: String, convert: Callable) -> void:
	Mods.hs_map.append({"tag": tag, "id": setting_id, "convert": convert, "owner": id})
