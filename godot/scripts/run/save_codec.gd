class_name SaveCodec
extends RefCounted
## Generic value codec for our save files (rules/save_and_profile.md "Format"). Turns run state into plain Variants
## that `FileAccess.store_var` writes as Godot binary (no objects inside: `full_objects` stays false, so a save
## file can never instantiate code), and back.
##
## - Builtins (int, float, String, Vector2/2i, Rect2/2i, Color, PackedArrays ...) pass through unchanged; Arrays and
##   Dictionaries are copied recursively (typed arrays become untyped; `decode_into` re-types them on assignment).
## - `RandomNumberGenerator` -> {"__rng": [seed, state]} (the stream continues exactly where it was).
## - A script object -> {"__cls": global class name, "p": {property: value}}: every script variable of the object
##   (PROPERTY_USAGE_SCRIPT_VARIABLE) except the names in `SKIP[class]`; a class may instead define
##   `to_save() -> Dictionary` / `from_save(d: Dictionary)` (instance method, called on a fresh `new()`), stored as
##   {"__cls", "d"}. Adding a plain-data field to such a class needs nothing else: it is saved and loaded by name, and
##   a field missing from an older save keeps its default.
## - Any other object (nodes, resources, script objects of classes not in ALLOWED) -> null, never followed: back
##   pointers between ships, crew targets etc. are rebuilt by the owner's restore code (ShipSave).

## Classes the generic object encoder may follow. Everything else is cut (null).
const ALLOWED := ["StarMap", "SectorTree", "RebelFleet", "RunStore", "HazardRule", "ScoreKeeper", "XmlNode",
	"ShipInventory", "UpgradeSession"]
## Per-class properties never saved (transient UI / caches / back pointers).
const SKIP := {
	"HazardRule": ["log", "ast_targets"],
	"ShipInventory": ["open_request"],
	"UpgradeSession": [],
}


static func encode(v: Variant) -> Variant:
	match typeof(v):
		TYPE_ARRAY:
			var out := []
			for x in v:
				out.append(encode(x))
			return out
		TYPE_DICTIONARY:
			var d := {}
			for k in v:
				d[encode(k)] = encode(v[k])
			return d
		TYPE_OBJECT:
			return encode_object(v)
		TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID:
			return null
	return v


static func encode_object(o: Object) -> Variant:
	if o == null or not is_instance_valid(o):
		return null
	if o is RandomNumberGenerator:
		return {"__rng": [o.seed, o.state]}
	var cls := class_of(o)
	if cls == "" or not cls in ALLOWED:
		return null
	if o.has_method("to_save"):
		return {"__cls": cls, "d": encode(o.to_save())}
	return {"__cls": cls, "p": props_of(o, SKIP.get(cls, []))}


## The script variables of `o` (minus `skip`) encoded.
static func props_of(o: Object, skip: Array = []) -> Dictionary:
	var p := {}
	for prop in o.get_property_list():
		if not (int(prop.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		var n := String(prop.name)
		if n in skip:
			continue
		p[n] = encode(o.get(n))
	return p


## The global class_name of an object's script (or "").
static func class_of(o: Object) -> String:
	var s: Script = o.get_script()
	while s != null:
		var g := String(s.get_global_name())
		if g != "":
			return g
		s = s.get_base_script()
	return ""


static func decode(v: Variant) -> Variant:
	match typeof(v):
		TYPE_ARRAY:
			var out := []
			for x in v:
				out.append(decode(x))
			return out
		TYPE_DICTIONARY:
			if v.has("__rng") and v.size() == 1:
				var r := RandomNumberGenerator.new()
				r.seed = int(v.__rng[0])
				r.state = int(v.__rng[1])
				return r
			if v.has("__cls") and (v.has("p") or v.has("d")):
				return decode_object(v)
			var d := {}
			for k in v:
				d[decode(k)] = decode(v[k])
			return d
	return v


static func decode_object(v: Dictionary) -> Variant:
	var cls := String(v.__cls)
	if not cls in ALLOWED:
		return null
	var script := script_of(cls)
	if script == null:
		return null
	var o: Object = script.new()
	if v.has("d"):
		o.from_save(decode(v.d))
	else:
		set_props(o, v.p)
	return o


## Assigns encoded properties onto an existing object (unknown names are ignored, typed arrays / dictionaries
## are filled in place, RNGs keep their object).
static func set_props(o: Object, p: Dictionary) -> void:
	var known := {}
	for prop in o.get_property_list():
		if int(prop.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE:
			known[String(prop.name)] = true
	for n in p:
		if not known.has(String(n)):
			continue
		decode_into(o, String(n), p[n])


static func decode_into(o: Object, n: String, enc: Variant) -> void:
	var val: Variant = decode(enc)
	var cur: Variant = o.get(n)
	if cur is Array and val is Array and (cur as Array).is_typed():
		var fresh: Array = (cur as Array).duplicate()
		fresh.clear()
		for x in val:
			fresh.append(x)
		o.set(n, fresh)
	elif cur is Dictionary and val is Dictionary and (cur as Dictionary).is_typed():
		var fd: Dictionary = (cur as Dictionary).duplicate()
		fd.clear()
		for k in val:
			fd[k] = val[k]
		o.set(n, fd)
	elif cur is RandomNumberGenerator and val is RandomNumberGenerator:
		(cur as RandomNumberGenerator).seed = val.seed
		(cur as RandomNumberGenerator).state = val.state
	elif cur is float and (val is int):
		o.set(n, float(val))
	elif cur is int and val is float:
		o.set(n, int(val))
	elif val == null and cur is Object and cur != null and not cur is RandomNumberGenerator:
		pass  # a cut object reference: keep what the constructor made
	else:
		o.set(n, val)


static var _scripts := {}


static func script_of(cls: String) -> Script:
	if _scripts.has(cls):
		return _scripts[cls]
	var found: Script = null
	for c in ProjectSettings.get_global_class_list():
		if String(c.class) == cls:
			found = load(String(c.path))
			break
	_scripts[cls] = found
	return found


## RNG helpers (a RandomNumberGenerator held by a static / an object not saved generically).
static func rng_state(r: RandomNumberGenerator) -> Array:
	return [r.seed, r.state]


static func set_rng(r: RandomNumberGenerator, s: Variant) -> void:
	if s is Array and s.size() == 2:
		r.seed = int(s[0])
		r.state = int(s[1])
