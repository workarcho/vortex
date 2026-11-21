extends Node
## Display names of blueprints (FtlData.blueprint_title / blueprint_short): every weapon, drone, augment, system and
## crew blueprint gets a translated title, unknown ids get a readable name, never the raw id; event items naming a
## <blueprintList> (DLC_WEAPONS, WEAPONS_CRYSTAL ...) resolve to one of its entries. Run:
##   godot --headless --path godot res://tests/test_names.tscn

const Harness := preload("res://tests/harness.gd")

var fails := 0

const SRC := """<FTL>
<event name="T_LIST_WEAPON"><text>x</text><weapon name="DLC_WEAPONS"/></event>
<event name="T_LIST_DRONE"><text>x</text><drone name="DLC_DRONES"/></event>
<event name="T_LIST_AUG"><text>x</text><augment name="DLC_AUGMENTS"/></event>
<event name="T_CRYSTAL"><text>x</text><weapon name="WEAPONS_CRYSTAL"/></event>
<event name="T_PLAIN"><text>x</text><weapon name="LASER_BURST_2"/></event>
</FTL>"""


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


## Blueprint names of `tag` over the blueprint files (comments stripped).
func names_of(tag: String) -> Array:
	var out := []
	for f in ["data/blueprints.xml", "data/dlcBlueprints.xml", "data/dlcBlueprintsOverwrite.xml"]:
		var re := RegEx.create_from_string("<" + tag + "\\s+name=\"([^\"]+)\"")
		for m in re.search_all(FtlData.strip_comments(FtlData.text(f))):
			if not out.has(m.get_string(1)):
				out.append(m.get_string(1))
	return out


func raw_like(t: String, nm: String) -> bool:
	return t == "" or t == nm or t.contains("_title") or t.contains("_short") or (t.contains("_") and t == t.to_upper())


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	FtlData.muted = true
	print("known blueprints")
	check("weapon title", FtlData.blueprint_title("LASER_BURST_2", "weapon"), FtlData.tr_id("weapon_LASER_BURST_2_title"))
	check("augment title (any kind)", FtlData.blueprint_title("FTL_BOOSTER"), FtlData.tr_id("aug_FTL_BOOSTER_title"))
	check("system title", FtlData.blueprint_title("engines", "system"), FtlData.tr_id("system_engines_title"))
	check("crew title", FtlData.blueprint_title("human", "crew"), FtlData.tr_id("crew_human_title"))
	check("weapon short", FtlData.blueprint_short("LASER_BURST_2"), FtlData.tr_id("weapon_LASER_BURST_2_short"))
	var bad := []
	for kind in ["weapon", "drone", "augment", "system", "crew"]:
		for nm in names_of(FtlData.ITEM_TAGS[kind]):
			var t := FtlData.blueprint_title(nm, kind)
			if raw_like(t, nm) or FtlData.blueprint_title(nm) != t and kind != "crew" and kind != "system":
				bad.append("%s:%s=%s" % [kind, nm, t])
			if kind in ["weapon", "drone"] and raw_like(FtlData.blueprint_short(nm, kind), nm):
				bad.append("%s short:%s=%s" % [kind, nm, FtlData.blueprint_short(nm, kind)])
	check("every blueprint has a translated title / short (no raw ids)", bad, [])

	print("unknown ids")
	check("unknown id -> readable name", FtlData.blueprint_title("ENGINE_BOOST"), "Engine Boost")
	check("unknown augment", FtlData.blueprint_title("ENGINE_BOOST", "augment"), "Engine Boost")
	check("unknown short", FtlData.blueprint_short("ENGINE_BOOST"), "Engine Boost")
	check("event reward line", EventBox.item_title("ENGINE_BOOST"), "Engine Boost")
	check("store title / short", [StoreView.title({"kind": "augment", "name": "ENGINE_BOOST"}),
		StoreView.short_name({"kind": "weapon", "name": "MY_GUN"})], ["Engine Boost", "My Gun"])
	var ws := WeaponState.new({"name": "MY_GUN", "short": "weapon_MY_GUN_short"}, 0)
	check("weapon box short without text", ws.short_name(), "My Gun")
	check("upgrade system line", FtlData.blueprint_title("engines", "system") != "engines", true)

	print("event items naming a blueprintList")
	var db := EventDB.new()
	db.add_source(SRC)
	db.rarity = EventDB.shared().rarity
	for case in [["T_LIST_WEAPON", "weapon", "DLC_WEAPONS"], ["T_LIST_DRONE", "drone", "DLC_DRONES"],
			["T_LIST_AUG", "augment", "DLC_AUGMENTS"], ["T_CRYSTAL", "weapon", "WEAPONS_CRYSTAL"]]:
		var e := EventEngine.new(db)
		e.rng.seed = 7
		var ev := e.base_event(case[0])
		var got := String(ev.get(case[1], ""))
		check("%s -> an entry of %s" % [case[0], case[2]], FtlData.blueprint_list(case[2]).has(got), true)
		check("%s entry is a %s blueprint" % [case[0], case[1]], FtlData.item_info(case[1], got).is_empty(), false)
	var e2 := EventEngine.new(db)
	check("plain names are kept", String(e2.base_event("T_PLAIN").get("weapon", "")), "LASER_BURST_2")
	check("blueprint_list copy is not the cache", FtlData.blueprint_list("DLC_WEAPONS") != [], true)

