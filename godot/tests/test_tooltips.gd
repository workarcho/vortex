extends Node
## Tooltip system tests (rules/tooltips.md): TooltipService delay / persistence / instant, placement at the 670 / 1260
## edges, wrap widths, content builders (weapon = screenshot 57, system box line order, crew box / skill rows,
## drones, level descriptions), the `tooltip` filter and `tooltip.<kind>` rules, `infobox_content`, and the QoL
## "Better info" redesign on / off. Run:
##   godot --headless --path godot res://tests/test_tooltips.tscn

const Harness := preload("res://tests/harness.gd")

var fails := 0
var TS: Node


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
	TS = TooltipService
	TS.manual = true
	Settings.reset_user()
	_delay()
	_placement()
	_widths()
	_weapon()
	_system()
	_crew()
	_misc_builders()
	_qol()  # before _hooks: a test rule replaces the mod's `tooltip.weapon` override (one override per rule)
	_hooks()
	Settings.reset_user()
	TS.manual = false


func _frame(dt: float, p: Vector2, text := "", opts := {}) -> Dictionary:
	TS.begin_frame(dt, p)
	if text != "":
		TS.request(text, opts)
	return TS.resolve()


## Visible lines of a tooltip text (each line trimmed; " " lines are blank lines).
func _lines(t: String) -> Array:
	return Array(t.split("\n")).map(func(l): return String(l).strip_edges())


func _delay() -> void:
	print("Service: 0.15 s delay, persistence, instant")
	var p := Vector2(400, 300)
	_frame(0.0, Vector2(1, 1))
	check("first still frame: hidden", _frame(0.016, p, "Alpha").is_empty(), true)
	check("0.1 s still: hidden", _frame(0.1, p, "Alpha").is_empty(), true)
	check("0.116 s still: hidden (needs > 0.15)", _frame(0.0, p, "Alpha").is_empty(), true)
	check("0.216 s still: shown", _frame(0.1, p, "Alpha").get("text", ""), "Alpha")
	check("cursor moves, same text: stays shown", _frame(0.016, p + Vector2(5, 0), "Alpha").get("text", ""), "Alpha")
	check("cursor moves to another text: hidden", _frame(0.016, p + Vector2(10, 0), "Beta").is_empty(), true)
	check("still on it again: hidden < 0.15", _frame(0.1, p + Vector2(10, 0), "Beta").is_empty(), true)
	check("instant: shown at once while moving", _frame(0.016, p + Vector2(20, 0), "Gamma", {"instant": true}).get(
		"text", ""), "Gamma")
	check("nothing requested: hidden", _frame(0.5, p + Vector2(20, 0)).is_empty(), true)
	check("last text cleared when hidden", TS.last_text, "")
	var d := _frame(0.016, p, "Static", {"instant": true, "anchor": Vector2(191, 155)})
	check("static anchor", (d.get("rect", Rect2()) as Rect2).position, Vector2(191, 155))
	check("cursor anchor = cursor + (0, 22)", (_frame(0.0, p, "Delta", {"instant": true}).rect as Rect2).position,
		p + Vector2(0, 22))
	check("delay rule (pure)", [TS.visible_for("x", false, 0.15), TS.visible_for("x", false, 0.151),
		TS.visible_for("", true, 1.0)], [false, true, false])


func _placement() -> void:
	print("Placement (RenderTooltip edges)")
	var sz := Vector2(200, 80)
	check("free: at the anchor", TS.place(Vector2(100, 122), Vector2(100, 100), sz), Vector2(100, 122))
	check("bottom: box above the cursor, x + 16", TS.place(Vector2(100, 672), Vector2(100, 650), sz),
		Vector2(116, 560))
	check("right: right edge at 1240", TS.place(Vector2(1200, 122), Vector2(1200, 100), sz), Vector2(1040, 122))
	check("aim armed: 10 px lower", TS.place(Vector2(100, 122), Vector2(100, 100), sz, true), Vector2(100, 132))
	check("no clamp at the left / top", TS.place(Vector2(-20, -5), Vector2(-20, -27), sz), Vector2(-20, -5))


func _widths() -> void:
	print("Box size and wrap widths")
	check("wrap 275 / 350 with a title / override", [TS.wrap_width(-1, false), TS.wrap_width(-1, true),
		TS.wrap_width(300, false)], [275, 350, 300])
	var long := "word ".repeat(80).strip_edges()
	var b275 := FtlTooltip.box_size("", long, 275)
	var b300 := FtlTooltip.box_size("", long, 300)
	check("box width = widest line + 27 <= wrap + 27", [b275.x <= 275 + 27, b300.x <= 300 + 27, b300.x > 275 + 27],
		[true, true, true])
	check("box height = lines × 12-font step + 18", b275.y, FtlTooltip.lines(long, 275).size()
		* FtlData.ftl_line_height(12) + 18)
	check("width used by the service for a box request", _frame(0.0, Vector2(50, 50), long, {"instant": true,
		"width": 300}).get("width", 0), 300)


func _weapon() -> void:
	print("Weapon builders (screenshot 57: Artemis in slot 2)")
	var bp := FtlData.weapon_blueprint("MISSILES_2_PLAYER")
	var w := WeaponState.new(bp, 0)
	TooltipText.ae = true
	var t := TooltipText.weapon_box(w, 1)
	check("Artemis lines", _lines(t), ["Type: Missile", "Ignores Shields", "Requires Missile", "", "Normal Damage: 2",
		"Possible Effect: Breach, Fire, Stun", "", "Hotkey: 2", "Click and drag to rearrange"])
	TooltipText.ae = false
	check("no stun without AE", _lines(TooltipText.weapon(bp))[5], "Possible Effect: Breach, Fire")
	TooltipText.ae = true
	var burst := _lines(TooltipText.weapon(FtlData.weapon_blueprint("LASER_BURST_2")))
	check("burst laser: type + shots + damage", burst.slice(0, 4), ["Type: Laser", "", "Shots Per Charge: %d" %
		int(FtlData.weapon_blueprint("LASER_BURST_2").shots), "Normal Damage: 1"])
	var ion := _lines(TooltipText.weapon(FtlData.weapon_blueprint("ION_1")))
	check("Ion Blast: ion type + effect + ion damage", [ion[0], ion[1], ion.has("Ion Damage: 1")],
		["Type: Ion", "Drains and Locks Systems", true])
	var beam := _lines(TooltipText.weapon(FtlData.weapon_blueprint("BEAM_1")))
	check("beam: damage per room, no shots line", [beam[0], beam.has("Damage Per Room Hit: 1"),
		beam.any(func(l): return l.begins_with("Shots"))], ["Type: Beam", true, false])
	check("crew damage x15", TooltipText.weapon(FtlData.weapon_blueprint("BEAM_BIO")).contains("Crew Damage: 60"),
		true)


func _system() -> void:
	print("System box builder (§5.1)")
	var s := ShipState.new("PLAYER_SHIP_HARD", true)
	s.reactor_max = 20
	for id in ["shields", "engines", "oxygen", "medbay"]:
		while s.sys(id).power < s.sys(id).get_level():
			if s.increase_power(id) != "ok":
				break
	var t := TooltipText.system(s, "shields")
	var L := _lines(t)
	check("shields: base text first", L[0], FtlData.tr_id("tooltip_shields"))
	check("shields level 2: one layer", L.has("Level 2: One Shield Barrier"), true)
	check("status header then bullets", L.slice(L.find("Status:"), L.find("Status:") + 2),
		["Status:", "-Fully Powered"])
	check("no hotkey block (no system keys bound)", t.contains("Add Power"), false)
	check("last character trimmed", t.ends_with(" "), true)
	var e := s.sys("engines")
	e.damage = 1
	e.power = 1
	var te := _lines(TooltipText.system(s, "engines"))
	check("damaged engines: partial + damaged", [te.has("-Partially Powered"), te.has("-Damaged")], [true, true])
	e.damage = e.get_level()
	e.power = 0
	te = _lines(TooltipText.system(s, "engines"))
	check("destroyed engines: OFF text, unpowered, destroyed", [te.has(FtlData.tr_id("engine_off")),
		te.has("-Unpowered"), te.has("-Destroyed")], [true, true, true])
	check("level descriptions", [TooltipText.level_description("engines", 0), TooltipText.level_description(
		"engines", 2), TooltipText.level_description("shields", 2), TooltipText.level_description("oxygen", 1),
		TooltipText.level_description("clonebay", 0, false), TooltipText.level_description("teleporter", 0)],
		["Dodge: 5 / FTL: 1x", "Dodge: 15 / FTL: 1.5x", "", "O2 Refill Boost: 3x", "12 sec clone + 8 hp/jump",
		"20 sec cooldown"])
	check("manned descriptions", [TooltipText.manned_description(0, 2), TooltipText.manned_description(2, 3),
		TooltipText.manned_description(3, 1)], ["Evasion +7", "30% faster recharge", "10% faster charge"])
	check("enemy system box", TooltipText.system_enemy("weapons"), FtlData.tr_id("tooltip_weapons_enemy"))


func _crew() -> void:
	print("Crew builders (screenshot 56, §5.4, §5.5)")
	var c := CrewMember.new("human", true)
	c.set_name("Oni")
	check("crew box: health + hotkey", _lines(TooltipText.crew_box(c, 0)), ["Health: 100/100", "Hotkey: F1"])
	c.hp = 0.0
	check("dead crew box: cloning", TooltipText.crew_box(c, 0), FtlData.tr_id("cloning"))
	c.hp = 42.6
	check("crew in room", _lines(TooltipText.crew_room([c])), ["Oni", "Health: 42/100"])
	c.skills["pilot"] = 20
	check("skill progress past half (human cap 26)", TooltipText.skill_progress(c, "pilot"), Vector2i(7, 13))
	check("skill row tooltip", _lines(TooltipText.crew_skill(c, 0)), ["Piloting Skill:", "Evasion +7",
		"Next Level: 7/13"])
	check("repair skill level 1 text", _lines(TooltipText.crew_skill(c, 4))[1], FtlData.tr_id("repair_0"))
	check("infobox skill text", TooltipText.skill_tooltip(2, 3, Vector2i(110, 110), true),
		FtlData.tr_id("shields_skill_infobox").replace("\\1", "30% faster recharge"))
	check("skill row geometry: panel right of the box", CrewList.skill_rect(Rect2(10, 155, 86, 27)),
		Rect2(94, 155, 85, 146))
	var d := InfoPanels.crew_content("engi", "Localresources", InfoPanels.skills_from_levels({"pilot": 1}))
	check("crew panel title", d.title, "Localresources (Engi)")
	check("crew panel powers as bullets", (d.stats as Array).size() >= 1 and String(d.stats[0]).begins_with("-"),
		true)
	check("store skill levels -> progress", d.skills[0], Vector2i(15, 30))


func _misc_builders() -> void:
	print("Other builders")
	check("ship status hit test", [ShipStatusHud.status_tooltip(Vector2(20, 20)), ShipStatusHud.status_tooltip(
		Vector2(150, 60)), ShipStatusHud.status_tooltip(Vector2(200, 60)), ShipStatusHud.status_tooltip(
		Vector2(280, 60)), ShipStatusHud.status_tooltip(Vector2(400, 20)), ShipStatusHud.status_tooltip(
		Vector2(20, 100)), ShipStatusHud.status_tooltip(Vector2(40, 80), false), ShipStatusHud.status_tooltip(
		Vector2(40, 80), true)], ["tooltip_hull", "tooltip_fuelCount", "tooltip_missileCount", "tooltip_droneCount",
		"tooltip_scrapCount", "tooltip_evadeDisplay", "", "tooltip_energyShieldDisplay"])
	var s := ShipState.new("PLAYER_SHIP_HARD", true)
	s.fuel = 0
	check("FTL button without fuel", TooltipText.ftl_button(s), FtlData.tr_id("tooltip_jump_noFuel"))
	check("jump hotkey J (Settings::ResetHotkeys 'j')", TooltipText.with_key("jump_button", "jump").ends_with("J"),
		true)
	check("key line dropped when unbound", TooltipText.with_key("jump_button", "no_such_binding"),
		FtlData.tr_id("jump_button").replace("\\n", "\n").split("\n")[0])
	check("doors close key", TooltipText.simple("button", "close_doors", {"key": "close"}).contains("X"), true)
	var w := InfoPanels.system_width("engines", 8)
	check("system info width = 327 + 10·count", (w - 327) % 10 == 0 and w >= 337, true)


func _hooks() -> void:
	print("Hooks: tooltip filter (text, source, kind, ctx), tooltip.<kind> rules, infobox_content")
	var bp := FtlData.weapon_blueprint("MISSILES_2_PLAYER")
	var w := WeaponState.new(bp, 0)
	Hooks.set_rule(&"tooltip.weapon", func(_def: Callable, b: Dictionary, _c := {}) -> String:
		return "Custom " + String(b.name), "test")
	check("rule replaces the whole builder (box lines kept)", _lines(TooltipText.weapon_box(w, 0)),
		["Custom MISSILES_2_PLAYER", "", "Hotkey: 1", "Click and drag to rearrange"])
	Hooks.set_rule(&"tooltip.weapon", func(def: Callable, b: Dictionary, c := {}) -> String:
		return String(def.call(b, c)).to_upper(), "test")
	check("rule may wrap the default", TooltipText.weapon(bp).begins_with("TYPE: MISSILE"), true)
	Hooks.set_rule(&"tooltip.crew_box", func(_d: Callable, c: CrewMember, n: int) -> String:
		return "%s #%d" % [c.race, n], "test")
	check("crew_box rule", TooltipText.crew_box(CrewMember.new("engi"), 2), "engi #2")
	Hooks.remove_owner("test")
	var seen := []
	Hooks.add_filter(&"tooltip", func(t, _src, kind, ctx):
		seen.append([kind, ctx.get("slot", -1)])
		return t + "!", 0, "test")
	var d := _frame(0.0, Vector2(9, 9), "Hi", {"instant": true, "kind": &"weapon", "ctx": {"slot": 3}})
	check("filter sees kind + ctx and changes the text", [d.get("text", ""), seen], ["Hi!", [[&"weapon", 3]]])
	Hooks.remove_owner("test")
	Hooks.add_filter(&"tooltip", func(_t, _s, _k, _c): return Hooks.CANCEL, 0, "test")
	check("filter cancel = no tooltip", _frame(0.0, Vector2(9, 9), "Hi", {"instant": true}).is_empty(), true)
	Hooks.remove_owner("test")
	Hooks.add_filter(&"infobox_content", func(dd: Dictionary, kind: String, _n: String, _c: Dictionary):
		if kind != "weapon":
			return null
		dd.stats = ["Only line"]
		return dd, 0, "test")
	var ib := ItemInfoBox.content("weapon", "MISSILES_2_PLAYER", true, true, {"context": "store"})
	check("infobox_content changes the stats", String(ib.desc).ends_with(" \n\nOnly line"), true)
	Hooks.remove_owner("test")
	var van := ItemInfoBox.content("weapon", "MISSILES_2_PLAYER", true, true)
	check("vanilla info text unchanged", van.desc, ItemInfoBox.weapon_description("MISSILES_2_PLAYER", true))


func _qol() -> void:
	print("QoL Better info (A6 / A7)")
	var qol: Object = Mods.entry("qol")
	check("qol mod loaded", qol != null, true)
	if qol == null:
		return
	var vanilla := TooltipText.weapon(FtlData.weapon_blueprint("MISSILES_2_PLAYER"))
	check("group OFF: vanilla weapon tooltip", vanilla.begins_with("Type: Missile"), true)
	var ib := ItemInfoBox.content("weapon", "MISSILES_2_PLAYER", true, true, {"sell_price": 30})
	check("group OFF: no price, vanilla stats", [ib.price, ib.desc], ["",
		ItemInfoBox.weapon_description("MISSILES_2_PLAYER", true)])
	Settings.set_group_enabled("qol_info", true)
	var t := _lines(TooltipText.weapon(FtlData.weapon_blueprint("MISSILES_2_PLAYER")))
	check("ON: numeric groups (screenshot 70 style)", t, ["Required Power: 1", "Charge Time: 11 seconds",
		"Requires Missile", "", "Shots Per Charge: 1", "", "Base Hull Damage: 2", "Shield Piercing: 5", "",
		"Fire Chance: 10%", "Breach Chance: 10%", "Stun Chance: 10%"])
	var box := _lines(TooltipText.weapon_box(WeaponState.new(FtlData.weapon_blueprint("MISSILES_2_PLAYER"), 0), 0))
	check("ON: box lines still appended", box.slice(-3), ["", "Hotkey: 1", "Click and drag to rearrange"])
	ib = ItemInfoBox.content("weapon", "MISSILES_2_PLAYER", true, true, {"sell_price": 30})
	check("ON: Stats block + price", [ib.stats[0], ib.price.begins_with("Default Price: "),
		ib.price.contains("Selling Price: 30")], ["Stats:", true, true])
	var dr := ItemInfoBox.content("drone", "COMBAT_1", true, true, {})
	check("ON: drone keeps vanilla stats, gets a price", [dr.stats.size(), dr.price != ""], [2, true])
	Settings.set_value("qol.info.weapon_tooltip", false)
	check("item OFF: vanilla tooltip again", TooltipText.weapon(FtlData.weapon_blueprint("MISSILES_2_PLAYER")),
		vanilla)
	Settings.set_group_enabled("qol_info", false)
	check("group OFF again: vanilla info", ItemInfoBox.content("weapon", "MISSILES_2_PLAYER", true, true).price, "")
