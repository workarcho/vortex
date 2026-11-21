extends Node
## Tests for the mod hook architecture (rules/hooks.md): the Hooks bus (notifications, filters, cancel, priority
## order, rules), the Settings registry (master switches, persistence, run freeze), the mod loader (mod.json,
## entry script, unload, hyperspace.xml mapping) and a sample of the engine hook points. Run:
##   godot --headless --path godot res://tests/test_hooks.tscn

const Harness := preload("res://tests/harness.gd")

var fails := 0
var log: Array = []


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
	_bus()
	_settings()
	_mods()
	_engine_points()
	await _run_points()


# ------------------------------------------------------------------ bus semantics

func _bus() -> void:
	print("Hooks bus: notifications")
	var H: Node = Hooks
	log.clear()
	var a := func(x, y): log.append("a%s%s" % [x, y])
	var b := func(x, y): log.append("b%s%s" % [x, y])
	var c := func(x, y): log.append("c%s%s" % [x, y])
	H.listen(&"t.n", a, 0, "test")
	H.listen(&"t.n", b, -5, "test")
	H.listen(&"t.n", c, 0, "test")
	H.emit(&"t.n", 1, 2)
	check("priority first, then registration order", log, ["b12", "a12", "c12"])
	H.unlisten(&"t.n", b)
	log.clear()
	H.emit(&"t.n", 3, 4)
	check("unlisten", log, ["a34", "c34"])
	log.clear()
	var adder := func(_x, _y): H.listen(&"t.n", func(_p, _q): log.append("late"), 0, "test")
	H.listen(&"t.n", adder, 10, "test")
	H.emit(&"t.n", 0, 0)
	check("a listener added during an emit runs from the next emit", log, ["a00", "c00"])
	log.clear()
	H.emit(&"t.n", 0, 0)
	check("  next emit", log.has("late"), true)
	H.remove_owner("test")
	check("remove_owner clears every listener", H.has_listeners(&"t.n"), false)
	var calls_before: int = H.calls
	H.emit(&"t.nobody", 1)
	check("emit with no listener: no call counted", H.calls, calls_before)

	print("Hooks bus: filters, null, cancel")
	H.add_filter(&"t.f", func(v, k): return v + k, 0, "test")
	H.add_filter(&"t.f", func(v, _k): return v * 10, 5, "test")
	H.add_filter(&"t.f", func(_v, _k): return null, 1, "test")
	check("filters chain in priority order ((1 + 2) * 10; null = unchanged)", H.filter(&"t.f", 1, 2), 30)
	log.clear()
	H.add_filter(&"t.c", func(v):
		log.append("first")
		return v, 0, "test")
	H.add_filter(&"t.c", func(_v): return Hooks.CANCEL, 1, "test")
	H.add_filter(&"t.c", func(v):
		log.append("after cancel")
		return v, 2, "test")
	var r: Variant = H.filter(&"t.c", 7)
	check("CANCEL returned to the caller", Hooks.is_cancel(r), true)
	check("  later filters do not run", log, ["first"])
	check("no filter: value unchanged", H.filter(&"t.none", "x"), "x")
	H.remove_owner("test")

	print("Hooks bus: rules (replaceable functions)")
	var dflt := func(x): return x + 1
	check("no override: the default", H.rule(&"t.r", dflt, 4), 5)
	H.set_rule(&"t.r", func(d: Callable, x): return d.call(x) * 2, "test")
	check("override wraps the default", H.rule(&"t.r", dflt, 4), 10)
	H.remove_owner("test")
	check("remove_owner clears the rule", H.has_rule(&"t.r"), false)


# ------------------------------------------------------------------ settings

func _settings() -> void:
	print("Settings: groups, master switch, values")
	var S: Node = load("res://scripts/mod/settings.gd").new()
	S.path = "user://test_hooks_settings.cfg"
	if FileAccess.file_exists(S.path):
		DirAccess.remove_absolute(S.path)
	S.declare_group("g", "Group", "", "test")
	S.declare("g", {"id": "g.b", "label": "B", "default": true})
	S.declare("g", {"id": "g.e", "type": "enum", "options": ["x", "y"], "default": "y"})
	S.declare("g", {"id": "g.f", "type": "float", "min": 0.0, "max": 2.0, "default": 1.5})
	S.declare("g", {"id": "g.play", "default": true, "gameplay": true})
	check("master OFF by default -> items at their off value", [S.value("g.b"), S.value("g.e"), S.value("g.f")],
		[false, "x", 1.5])
	S.set_group_enabled("g", true)
	check("master ON -> item defaults", [S.value("g.b"), S.value("g.e")], [true, "y"])
	S.set_value("g.b", false)
	S.set_value("g.f", 9.0)
	S.set_value("g.e", "nope")
	check("set_value (float clamped, unknown enum ignored)", [S.value("g.b"), S.value("g.f"), S.value("g.e")],
		[false, 2.0, "y"])
	S.set_value("g.e", "y")
	S.set_mod_default("g.e", "x")
	check("mod default below the user's choice", S.value("g.e"), "y")
	S.set_mod_default("g.play", false)
	check("mod default above the item default", S.value("g.play"), false)
	S.clear_mod_defaults()

	print("Settings: persistence")
	var S2: Node = load("res://scripts/mod/settings.gd").new()
	S2.path = S.path
	S2.load_file()
	S2.declare_group("g", "Group")
	S2.declare("g", {"id": "g.b", "default": true})
	S2.declare("g", {"id": "g.f", "type": "float", "min": 0.0, "max": 2.0, "default": 1.5})
	check("reloaded from user://", [S2.group_enabled("g"), S2.value("g.b"), S2.value("g.f")], [true, false, 2.0])
	S2.free()

	print("Settings: gameplay items frozen into the run")
	S.set_value("g.play", true)
	var snap: Dictionary = S.freeze_run()
	check("snapshot has the gameplay item and its master", [snap.get("g.play"), snap.get("group:g")], [true, true])
	S.set_value("g.play", false)
	S.set_value("g.b", true)
	check("gameplay change during the run: frozen value kept", S.value("g.play"), true)
	check("  is_frozen", [S.is_frozen("g.play"), S.is_frozen("g.b")], [true, false])
	check("non-gameplay change applies at once", S.value("g.b"), true)
	S.set_group_enabled("g", false)
	check("master switched off mid-run: gameplay item still frozen ON", S.value("g.play"), true)
	check("  non-gameplay item follows the master", S.value("g.b"), false)
	S.thaw()
	check("thaw: the new value applies (next run)", S.value("g.play"), false)
	S.free()
	DirAccess.remove_absolute("user://test_hooks_settings.cfg")
	check("test runs never use the user's settings file", Settings.path, "")


# ------------------------------------------------------------------ mod loader

func _mods() -> void:
	print("Mod loader")
	check("internal qol mod loaded from res://mods/qol", Mods.loaded.has("qol"), true)
	check("  its groups declared", Settings.groups.has("qol_cooldown"), true)
	var dir := "user://test_hook_mods/hello"
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join("mod.json"), FileAccess.WRITE)
	f.store_string('{"id": "hello", "name": "Hello", "version": "1.0", "entry": "hello.gd"}')
	f.close()
	f = FileAccess.open(dir.path_join("hello.gd"), FileAccess.WRITE)
	f.store_string("extends RefCounted\nvar seen := []\nfunc _mod_init(ctx):\n" +
		"\tctx.declare_group(\"hello_g\", \"Hello\")\n" +
		"\tctx.declare(\"hello_g\", {\"id\": \"hello.x\", \"default\": true})\n" +
		"\tctx.listen(&\"t.hello\", func(v): seen.append(v))\n" +
		"\tctx.add_filter(&\"t.hellof\", func(v): return v + \"!\")\n")
	f.close()
	check("load_mod", Mods.load_mod(dir), true)
	Hooks.emit(&"t.hello", 42)
	check("  entry got the hook", Mods.entry("hello").seen, [42])
	check("  filter registered", Hooks.filter(&"t.hellof", "hi"), "hi!")
	check("  setting declared", Settings.items.has("hello.x"), true)
	check("same id twice is refused", Mods.load_mod(dir), false)
	Mods.unload("hello")
	check("unload: hooks removed", [Hooks.has_listeners(&"t.hello"), Hooks.has_filters(&"t.hellof")], [false, false])
	check("  settings removed", Settings.groups.has("hello_g"), false)
	f = FileAccess.open(dir.path_join("mod.json"), FileAccess.WRITE)
	f.store_string('{"id": "broken"}')
	f.close()
	var nerr := Mods.errors.size()
	check("mod.json without name/version/entry is refused", [Mods.load_mod(dir), Mods.errors.size() > nerr],
		[false, true])
	DirAccess.remove_absolute(dir.path_join("mod.json"))
	DirAccess.remove_absolute(dir.path_join("hello.gd"))

	print("hyperspace.xml mapping -> mod-recommended defaults")
	var xml := """<FTL>
	<!-- <hullNumbers enabled="false"/> -->
	<showNumericalWeaponCooldown enabled="true"/>
	<hullNumbers enabled="true"><playerText x="77" y="13"/></hullNumbers>
	<hullBars enabled="true" type="2" maxHull="22" maxHullBoss="32"/>
	<playerHpColorFix enabled="false"/>
</FTL>"""
	var got: Dictionary = Mods.apply_hyperspace_xml(xml)
	check("cooldown group ON", Settings.group_raw("qol_cooldown"), true)
	check("health group ON, hull numbers, capped bar, no colour fix",
		[Settings.group_raw("qol_health"), Settings.raw("qol.health.hull_numbers"), Settings.raw("qol.health.hull_cap"),
		Settings.raw("qol.health.thirds")], [true, true, true, false])
	check("unmapped groups untouched", Settings.group_raw("qol_pause"), false)
	check("applied table (a master already ON is not re-applied)", got.size(), 5)
	Settings.clear_mod_defaults()
	check("cleared", Settings.group_raw("qol_cooldown"), false)


# ------------------------------------------------------------------ engine hook points (sample)

func _engine_points() -> void:
	print("Engine hook points: damage filters, power, rules, data")
	var s := ShipState.new("PLAYER_SHIP_HARD", true)
	Hooks.add_filter(&"damage_hull", func(a, _sh): return a / 2, 0, "test")
	var h := s.hull
	s.take_hull_damage(4)
	check("damage_hull filter halves", h - s.hull, 2)
	Hooks.add_filter(&"damage_system", func(_a, _sh, id): return Hooks.CANCEL if id == "shields" else null, 0, "test")
	s.damage_system("shields", 2)
	s.damage_system("oxygen", 1)
	check("damage_system cancel (shields) / pass (oxygen)", [s.sys("shields").damage, s.sys("oxygen").damage], [0, 1])
	log.clear()
	Hooks.listen(&"system_damaged", func(_sh, id, n): log.append("dmg %s %d" % [id, n]), 0, "test")
	Hooks.listen(&"system_repaired", func(_sh, id, left): log.append("rep %s %d" % [id, left]), 0, "test")
	Hooks.listen(&"power_up_failed", func(_sh, id, why): log.append("fail %s %s" % [id, why]), 0, "test")
	Hooks.listen(&"repower_failed", func(_sh, id, why): log.append("repower %s %s" % [id, why]), 0, "test")
	s.sys("engines").override_level = 2
	s.damage_system("engines", 2)
	s.reactor_max = s.reactor_used()
	s.repair_system("engines", 1)
	s.increase_power("medbay")
	check("system_damaged / repaired / repower_failed / power_up_failed",
		log, ["dmg engines 2", "rep engines 1", "fail engines reactor", "repower engines reactor",
		"fail medbay max"])
	Hooks.remove_owner("test")

	var v := s.dodge_factor()
	Hooks.set_rule(&"evasion", func(d: Callable, sh: ShipState): return d.call(sh) + 7, "test")
	check("evasion rule wraps the vanilla value", s.dodge_factor(), v + 7)
	Hooks.remove_owner("test")
	var crew0 := s.crew[0]
	Hooks.set_rule(&"crew_move_destination", func(_d, _sh, movers, _room): return movers.map(func(c): return [c, 0]),
		"test")
	s.order_crew_move([crew0], 3)
	check("crew_move_destination rule redirects the order", crew0.target_room, 0)
	Hooks.remove_owner("test")

	Hooks.add_filter(&"data_text_loaded", func(t, rel): return t + "<!--patched-->" if rel == "res://data/test_ships.xml" else null,
		0, "test")
	FtlData.clear_data_cache()
	check("data_text_loaded filter patches a data file", FtlData.text("res://data/test_ships.xml").ends_with("<!--patched-->"), true)
	Hooks.remove_owner("test")
	FtlData.clear_data_cache()
	Hooks.add_filter(&"ship_blueprint_loaded", func(bp, nm):
		if nm == "PLAYER_SHIP_HARD":
			bp.hull = 99
		return bp, 0, "test")
	check("ship_blueprint_loaded filter", ShipState.new("PLAYER_SHIP_HARD", true).max_hull, 99)
	Hooks.remove_owner("test")
	Hooks.add_filter(&"tooltip", func(t, _src, _kind, _ctx): return t + " (mod)", 0, "test")
	TooltipService.manual = true
	TooltipService.begin_frame(0.0, Vector2(10, 10))
	TooltipService.request("Hello", {"instant": true})
	check("tooltip filter", TooltipService.resolve().get("text", ""), "Hello (mod)")
	TooltipService.manual = false
	Hooks.remove_owner("test")

	log.clear()
	var w := s.weapons[0]
	s.reactor_max = 20
	s.try_power_weapon(w)
	Hooks.listen(&"weapon_charged", func(_sh, ww): log.append(ww.bp.name), 0, "test")
	for i in 60 * 20:
		s.tick(GameClock.factor(1.0 / 60.0))
		if not log.is_empty():
			break
	check("weapon_charged once the charge completes", log, [w.bp.name])
	Hooks.remove_owner("test")


func _run_points() -> void:
	print("Engine hook points: run layer")
	log.clear()
	Hooks.listen(&"run_started", func(_r): log.append("run_started"), 0, "test")
	Hooks.listen(&"sector_entered", func(_r, _l, _d): log.append("sector_entered"), 0, "test")
	Hooks.listen(&"beacon_arrived", func(_r, _b): log.append("beacon_arrived"), 0, "test")
	Hooks.add_filter(&"map_generated", func(m, _r, _lvl):
		log.append("map_generated")
		return m, 0, "test")
	Hooks.add_filter(&"event_resolved", func(ev, _r):
		log.append("event_resolved")
		return ev, 0, "test")
	var r := RunState.new_run(7)
	check("new run: map_generated, sector_entered, beacon_arrived, event_resolved, run_started",
		log, ["map_generated", "sector_entered", "beacon_arrived", "event_resolved", "run_started"])
	Hooks.remove_owner("test")
	var target: int = r.map.links_of(r.current_beacon)[0]
	Hooks.add_filter(&"before_jump", func(_id, _r): return Hooks.CANCEL, 0, "test")
	var at := r.current_beacon
	r.jump_to(target)
	check("before_jump cancel keeps the ship at its beacon", r.current_beacon, at)
	Hooks.remove_owner("test")
	r.jump_to(target)
	check("  without the filter it jumps", r.current_beacon, target)
	RunState.current = null
	Settings.thaw()

	print("Engine hook points: combat (sim_tick, weapon_fired, projectile hits, combat start in main)")
	FtlData.muted = true
	log.clear()
	Hooks.listen(&"combat_started", func(me, e, _c): log.append("start %s" % e.blueprint.name), 0, "test")
	Hooks.listen(&"sim_tick", func(_c, _s): _once("tick"), 0, "test")
	Hooks.listen(&"weapon_fired", func(_a, _w, _b): _once("fired"), 0, "test")
	Hooks.listen(&"hud_ready", func(region, _n, _sh): _once(region), 0, "test")
	var main: Node = load("res://main.tscn").instantiate()
	add_child(main)
	for i in 6:
		await get_tree().process_frame
	check("hud_ready regions", [log.has("weapon_panel"), log.has("hud")], [true, true])
	check("combat_started (sandbox: on the first frame)", log.has("start REBEL_FAT"), true)
	main.combat.paused = false
	var e: ShipState = main.enemy_space.ship
	for i in 20 * 60:
		main.combat._physics_process(1.0 / 60.0)
		if log.has("fired"):
			break
	check("sim_tick", log.has("tick"), true)
	check("weapon_fired (enemy AI)", log.has("fired"), true)
	Hooks.remove_owner("test")
	log.clear()
	Hooks.listen(&"combat_ended", func(_me, _e, why): log.append(why), 0, "test")
	e.hull = 0
	for i in 3:
		main.combat._physics_process(1.0 / 60.0)
		await get_tree().process_frame
	check("combat_ended when the enemy is destroyed", log, ["destroyed"])
	Hooks.remove_owner("test")
	main.queue_free()
	await get_tree().process_frame


func _once(x: String) -> void:
	if not log.has(x):
		log.append(x)
