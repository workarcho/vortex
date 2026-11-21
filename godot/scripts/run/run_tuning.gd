class_name RunTuning
extends RefCounted
## Project-owned tunables of the game loop (`res://data/run_tuning.json`): map grid, reward tables, special
## event names, the [placeholder] FTL charge rate. Loaded once; mods can edit the JSON.

const PATH := "res://data/run_tuning.json"
static var _data := {}


static func data() -> Dictionary:
	if _data.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
		_data = parsed if parsed is Dictionary else {}
		if _data.is_empty():
			push_error("run_tuning.json missing or invalid")
	return _data


static func section(name: String) -> Dictionary:
	return data().get(name, {})


static func num(sec: String, key: String, default := 0.0) -> float:
	return float(section(sec).get(key, default))


static func i(sec: String, key: String, default := 0) -> int:
	return int(section(sec).get(key, default))


static func name_of(key: String) -> String:
	return String(section("names").get(key, key))
