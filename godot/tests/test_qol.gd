extends Node
## Tests for the internal QoL mod (godot/mods/qol, rules/qol_plan.md): every group / item ON and OFF, through the
## public hooks only. Run:
##   godot --headless --path godot res://tests/test_qol.tscn

const Harness := preload("res://tests/harness.gd")

var fails := 0
var qol: Object


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func group(g: String, on: bool) -> void:
	Settings.set_group_enabled(g, on)


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	FtlData.muted = true
	qol = Mods.entry("qol")
	check("qol mod loaded", qol != null, true)
	if qol == null:
		return
	Settings.reset_user()
	_cooldown()
	_health()
	await _pause()
	_drones()
	await _drone_button()
	_scanners()
	await _speed()
	await _cards()
	Settings.reset_user()


func _cooldown() -> void:
	print("Weapon cooldown numbers (A1)")
	var s := ShipState.new("PLAYER_SHIP_HARD", true)
	var w := s.weapons[0]
	s.reactor_max = 20
	s.try_power_weapon(w)
	w.charge = 1.25
	var mx := w.max_charge(0)
	check("group OFF: nothing drawn", qol.cooldown_text(w, 0), "")
	group("qol_cooldown", true)
	check("ON: seconds left, one decimal", qol.cooldown_text(w, 0), "%.1f" % (mx - 1.25))
	Settings.set_value("qol.cooldown.format", "whole seconds")
	check("  whole seconds (ceil)", qol.cooldown_text(w, 0), str(ceili(mx - 1.25)))
	w.charge = mx
	check("  charged: hidden", qol.cooldown_text(w, 0), "")
	w.charge = 0.0
	s.depower_weapon(w)
	check("  unpowered: hidden", qol.cooldown_text(w, 0), "")
	Settings.set_value("qol.cooldown.numbers", false)
	s.try_power_weapon(w)
	check("item OFF inside an ON group", qol.cooldown_text(w, 0), "")
	group("qol_cooldown", false)


func _health() -> void:
	print("Better health bars (A2-A4)")
	var me := ShipState.new("PLAYER_SHIP_HARD", true)
	var big := ShipState.new("REBEL_FAT", false)
	big.max_hull = 40
	big.hull = 20
	me.hull = 15  # half of 30: vanilla yellow (10..19), thirds: yellow too; 21 -> vanilla green, thirds green
	check("OFF: no hull numbers", qol.hull_text(me), "")
	check("OFF: enemy bar hull/22 (vanilla)", Hooks.filter(&"hud_hull_fraction", minf(20 / 22.0, 1.0), big, "enemy"),
		minf(20 / 22.0, 1.0))
	me.hull = 9
	var vanilla_col := HudLayout.HULL_RED
	check("OFF: colour unchanged", Hooks.filter(&"hud_hull_color", vanilla_col, me, "player"), vanilla_col)
	group("qol_health", true)
	check("ON: hull numbers", [qol.hull_text(me), qol.hull_text(big)], ["9/30", "20/40"])
	check("ON: enemy bar proportional above 22 hull", Hooks.filter(&"hud_hull_fraction", 1.0, big, "enemy"), 0.5)
	big.max_hull = 10
	big.hull = 5
	check("  not above 22: vanilla", Hooks.filter(&"hud_hull_fraction", 5 / 22.0, big, "enemy"), 5 / 22.0)
	me.max_hull = 12
	me.hull = 9  # 75 %: vanilla red (< 10), thirds green
	check("ON: player colour by thirds (9/12 -> green)", Hooks.filter(&"hud_hull_color", HudLayout.HULL_RED, me,
		"player"), HudLayout.HULL_GREEN)
	me.hull = 5
	check("  5/12 -> yellow", Hooks.filter(&"hud_hull_color", HudLayout.HULL_RED, me, "player"), HudLayout.HULL_YELLOW)
	me.hull = 3
	check("  3/12 -> red", Hooks.filter(&"hud_hull_color", HudLayout.HULL_GREEN, me, "player"), HudLayout.HULL_RED)
	Settings.set_value("qol.health.thirds", false)
	Settings.set_value("qol.health.hull_cap", false)
	Settings.set_value("qol.health.hull_numbers", false)
	big.max_hull = 40
	check("items OFF in an ON group", [qol.hull_text(me), Hooks.filter(&"hud_hull_fraction", 1.0, big, "enemy"),
		Hooks.filter(&"hud_hull_color", HudLayout.HULL_GREEN, me, "player")], ["", 1.0, HudLayout.HULL_GREEN])
	group("qol_health", false)


func _pause() -> void:
	print("Pause on combat start")
	var cb := Combat.new()
	var me := ShipState.new("PLAYER_SHIP_HARD", true)
	var e := ShipState.new("REBEL_FAT", false)
	Hooks.emit(&"combat_started", me, e, cb)
	check("OFF: not paused", cb.paused, false)
	group("qol_pause", true)
	Hooks.emit(&"combat_started", me, e, cb)
	check("ON: paused", cb.paused, true)
	cb.free()
	# Through the real scene: the sandbox fight starts on the first frame.
	var main: Node = load("res://main.tscn").instantiate()
	add_child(main)
	for i in 4:
		await get_tree().process_frame
	check("ON, main scene: the game is paused when the fight starts", main.combat.paused, true)
	main.queue_free()
	await get_tree().process_frame
	group("qol_pause", false)
	main = load("res://main.tscn").instantiate()
	add_child(main)
	for i in 4:
		await get_tree().process_frame
	check("OFF, main scene: running", main.combat.paused, false)
	main.queue_free()
	await get_tree().process_frame


func _drone_ship() -> ShipState:
	var s := ShipState.new("TEST_SHIP_ALL", true)
	s.reactor_max = 40
	DroneSystemRule.set_drones(s, ["DEFENSE_1", "COMBAT_1"])
	s.drone_parts = 5
	var e := ShipState.new("REBEL_FAT", false)
	s.opponent = e
	e.opponent = s
	return s


func _drones() -> void:
	print("Drone autodeploy")
	var s := _drone_ship()
	qol.set_auto(s, true)
	var cb := Combat.new()
	var sp := Space.new()
	add_child(sp)
	sp.setup(s)
	cb.spaces.append(sp)
	Hooks.emit(&"sim_tick", cb, 0.016)
	check("group OFF: AUTO does nothing", s.drones.map(func(d): return d.powered), [false, false])
	group("qol_drones", true)
	Hooks.emit(&"sim_tick", cb, 0.016)
	check("ON + AUTO: every drone deployed and powered", s.drones.map(func(d): return d.powered), [true, true])
	check("  one part each", s.drone_parts, 3)
	DroneSystemRule.player_depower(s, s.drones[0])
	Hooks.emit(&"sim_tick", cb, 0.016)
	check("a drone the player switched off stays off", s.drones[0].powered, false)
	DroneSystemRule.player_toggle(s, s.drones[0])
	DroneSystemRule.depower_drone(s, s.drones[0])  # e.g. ion / reactor loss: not the player
	Hooks.emit(&"sim_tick", cb, 0.016)
	check("re-powered when lost by other causes", s.drones[0].powered, true)
	s.drones[1].dead = true
	DroneSystemRule.tick(s, 0.016)  # destroyed: undeployed, rebuild timer
	Hooks.emit(&"sim_tick", cb, 0.016)
	check("destroyed drone waits for its rebuild", s.drones[1].powered, false)
	s.drones[1].destroyed_timer = 0.0
	Hooks.emit(&"sim_tick", cb, 0.016)
	check("  then redeploys (one more part)", [s.drones[1].powered, s.drone_parts], [true, 2])
	DroneSystemRule.player_depower(s, s.drones[1])
	s.drones[1].remove_meta("qol_manual_off")
	s.reactor_max = s.reactor_used()
	s.take_failed_powerup()
	Hooks.emit(&"sim_tick", cb, 0.016)
	check("reactor full: AUTO waits silently (no NOT ENOUGH POWER flag)", [s.drones[1].powered, s.failed_powerup],
		[false, false])
	s.reactor_max = 40
	s.opponent.hostile = false
	Hooks.emit(&"sim_tick", cb, 0.016)
	check("no hostile enemy: nothing deployed", s.drones[1].powered, false)
	s.opponent.hostile = true
	qol.set_auto(s, false)
	Hooks.emit(&"sim_tick", cb, 0.016)
	check("AUTO off: nothing", s.drones[1].powered, false)
	group("qol_drones", false)
	sp.queue_free()
	cb.free()


func _drone_button() -> void:
	print("Drone autodeploy: AUTO button on the drone panel")
	var main: Node = load("res://main.tscn").instantiate()
	add_child(main)
	for i in 3:
		await get_tree().process_frame
	check("drone panel without drones on the Kestrel: no panel", main.drone_panel == null, true)
	main.queue_free()
	await get_tree().process_frame
	var s := _drone_ship()
	var panel := DronePanel.new()
	panel.setup(s)
	add_child(panel)
	await get_tree().process_frame
	var b: Control = panel.get_node_or_null("QolDroneAuto")
	check("button added through hud_ready", b != null, true)
	check("group OFF: hidden", b.visible, false)
	group("qol_drones", true)
	await get_tree().process_frame
	check("group ON: visible", b.visible, true)
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = true
	b._gui_input(e)
	check("click toggles AUTO", bool(s.get_meta("qol_drone_auto", false)), true)
	Settings.set_value("qol.drones.auto_button", false)
	await get_tree().process_frame
	check("item OFF: hidden", b.visible, false)
	group("qol_drones", false)
	panel.queue_free()


func _scanners() -> void:
	print("Start with scanners (data patch)")
	FtlData.clear_data_cache()
	check("OFF: Kestrel without ADV_SCANNERS", ShipState.new("PLAYER_SHIP_HARD", true).has_augment("ADV_SCANNERS"), false)
	group("qol_scanners", true)
	var k := ShipState.new("PLAYER_SHIP_HARD", true)
	check("ON: Kestrel starts with ADV_SCANNERS", k.has_augment("ADV_SCANNERS"), true)
	check("  enemy blueprints untouched", ShipState.new("REBEL_FAT", false).has_augment("ADV_SCANNERS"), false)
	var patched: String = qol.add_scanners('<shipBlueprint name="PLAYER_SHIP_X" layout="a"><aug name="A"/><aug name="B"/>' +
		'<aug name="C"/></shipBlueprint><shipBlueprint name="PLAYER_SHIP_Y"><aug name="ADV_SCANNERS"/></shipBlueprint>')
	check("  full augment slots / already present: unchanged", patched.count("ADV_SCANNERS"), 1)
	var run := RunState.new_run(3)
	check("gameplay setting frozen into the run", Settings.is_frozen("qol.scanners.augment"), true)
	check("  run ship has scanners", run.ship.has_augment("ADV_SCANNERS"), true)
	group("qol_scanners", false)
	check("  switched off mid-run: still ON for this run", Settings.on("qol.scanners.augment"), true)
	check("  new ships in this run keep it", ShipState.new("PLAYER_SHIP_HARD", true).has_augment("ADV_SCANNERS"), true)
	RunState.current = null
	Settings.thaw()
	FtlData.clear_data_cache()
	check("after the run: OFF", ShipState.new("PLAYER_SHIP_HARD", true).has_augment("ADV_SCANNERS"), false)


func _speed() -> void:
	print("Game speed")
	var ticks := Engine.physics_ticks_per_second
	check("OFF: 1x", qol.speed(), 1.0)
	check("OFF: + does nothing", qol.speed_step(1), false)
	check("labels", [qol.speed_label(0.5), qol.speed_label(1.0), qol.speed_label(1.25), qol.speed_label(3.0)],
		["0.5x", "1x", "1.25x", "3x"])
	group("qol_speed", true)
	check("ON: starts at 1x", qol.speed(), 1.0)
	check("+ steps to 1.25x", [qol.speed_step(1), qol.speed()], [true, 1.25])
	for i in 10:
		qol.speed_step(1)
	check("+ stops at 3x", [qol.speed(), qol.speed_step(1)], [3.0, false])
	qol.apply_speed(true)
	check("running at 3x: time scale", Engine.time_scale, 3.0)
	check("  physics ticks x3 (each step keeps the 1x delta)", Engine.physics_ticks_per_second, ticks * 3)
	check("  step delta = 1x step delta", Engine.time_scale / Engine.physics_ticks_per_second, 1.0 / ticks)
	qol.apply_speed(false)
	check("paused / box open: 1x", [Engine.time_scale, Engine.physics_ticks_per_second], [1.0, ticks])
	for i in 10:
		qol.speed_step(-1)
	check("- stops at 0.5x", qol.speed(), 0.5)
	qol.apply_speed(true)
	check("0.5x: time scale 0.5, ticks unchanged", [Engine.time_scale, Engine.physics_ticks_per_second], [0.5, ticks])
	group("qol_speed", false)
	check("group OFF: back to 1x at once", [Engine.time_scale, Engine.physics_ticks_per_second, qol.speed()],
		[1.0, ticks, 1.0])
	group("qol_speed", true)
	check("group ON again: 1x (the choice was reset)", qol.speed(), 1.0)

	# Through the real scene: the control on the ship status, clicks through the input_event filter.
	var main: Node = load("res://main.tscn").instantiate()
	add_child(main)
	for i in 3:
		await get_tree().process_frame
	var sc: Control = main.ship_status.get_node_or_null("QolGameSpeed")
	check("control added on the ship status (hud_ready)", sc != null, true)
	if sc == null:
		main.queue_free()
		group("qol_speed", false)
		return
	check("visible with the group ON", sc.visible, true)
	check("under the scrap box", sc.position.y >= 45.0 and sc.position.x > 380.0, true)
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = true
	e.position = sc.get_global_transform_with_canvas() * sc.plus_rect().get_center()
	check("click on + is consumed", Hooks.is_cancel(Hooks.filter(&"input_event", e, main)), true)
	check("  1.25x", qol.speed(), 1.25)
	var up := e.duplicate()
	up.pressed = false
	check("  its release too", Hooks.is_cancel(Hooks.filter(&"input_event", up, main)), true)
	e.position = sc.get_global_transform_with_canvas() * (sc.size / 2)
	check("click on the label: not consumed", Hooks.is_cancel(Hooks.filter(&"input_event", e, main)), false)
	main.combat.paused = false
	await get_tree().process_frame
	check("world running: time scale 1.25", Engine.time_scale, 1.25)
	main.combat.paused = true
	await get_tree().process_frame
	check("paused: time scale 1", Engine.time_scale, 1.0)
	main.combat.paused = false
	var k := InputEventKey.new()
	k.keycode = KEY_MINUS
	k.pressed = true
	check("- key consumed", Hooks.is_cancel(Hooks.filter(&"input_event", k, main)), true)
	check("  back to 1x", qol.speed(), 1.0)
	qol.speed_step(1)
	await get_tree().process_frame
	# Touch layout: scaled ship status; the hit test runs in the control's local coordinates.
	main.ship_status.scale = Vector2(1.5, 1.5)
	main.ship_status.evade_offset = Vector2(391, -49)
	sc.touch = true
	await get_tree().process_frame
	check("touch: under the moved evade / O2 box", sc.position.y >= 96.0, true)
	e.pressed = true
	e.position = sc.get_global_transform_with_canvas() * sc.minus_rect().get_center()
	check("touch: tap on - (scaled) consumed", Hooks.is_cancel(Hooks.filter(&"input_event", e, main)), true)
	check("  1x", qol.speed(), 1.0)
	qol.speed_step(1)
	main.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	check("scene left: time scale 1", [Engine.time_scale, Engine.physics_ticks_per_second], [1.0, ticks])
	group("qol_speed", false)


# ---------------------------------------------------------------- card drag & reorder

## A run with 4 weapons on the open equipment tab: [run, ShipScreen, EquipmentView].
func _card_setup(touch := false) -> Array:
	var r := RunState.new_run(5)
	for i in 10:
		if r.phase == RunState.Phase.DIALOG:
			r.choose(0)
		elif r.phase == RunState.Phase.MESSAGE:
			r.apply(RunIntent.make(RunIntent.CONTINUE))
	r.enemy = {}
	r.give_item("weapon", "LASER_HEAVY_1")
	r.give_item("weapon", "LASER_BURST_1")
	var prof := InputProfile.new(InputProfile.TOUCH if touch else InputProfile.PC)
	prof.run = r
	var scr := ShipScreen.new()
	scr.setup(r, prof)
	add_child(scr)
	r.apply(ShipManagement.make(RunIntent.OPEN_SHIP_SCREEN, {"arg": 2}))
	return [r, scr, scr.equip_view]


func _wnames(r: RunState) -> Array:
	return r.ship.weapons.map(func(w): return String(w.bp.name))


func _wbox(i: int) -> Vector2i:
	return Vector2i(ShipInventory.WEAPON, i)


## Drag slot `a` to slot `b` with real input events (mouse: press, move, release; touch: past the 9 px threshold).
func _card_drag(ev: EquipmentView, a: int, b: int) -> void:
	var p := ev.box_rect(_wbox(a)).get_center()
	var q := ev.box_rect(_wbox(b)).get_center()
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = p
	ev._gui_input(down)
	for t in [p + Vector2(12, 0), q]:
		var m := InputEventMouseMotion.new()
		m.position = t
		m.button_mask = MOUSE_BUTTON_MASK_LEFT
		ev._gui_input(m)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.position = q
	ev._gui_input(up)


func _cards() -> void:
	print("Card drag & reorder")
	# group OFF: vanilla swap
	var k := _card_setup()
	var r: RunState = k[0]
	var w: Array = _wnames(r)
	check("4 weapons", w.size(), 4)
	_card_drag(k[2], 0, 3)
	check("OFF: slot 1 -> 4 swaps (vanilla)", _wnames(r), [w[3], w[1], w[2], w[0]])
	k[1].queue_free()
	group("qol_cards", true)
	var cases := [[2, 1, [0, 2, 1, 3]], [0, 3, [1, 2, 3, 0]], [3, 0, [3, 0, 1, 2]], [1, 2, [0, 2, 1, 3]]]
	for c in cases:
		k = _card_setup()
		r = k[0]
		w = _wnames(r)
		_card_drag(k[2], c[0], c[1])
		check("ON: slot %d -> %d reorders like a list" % [c[0] + 1, c[1] + 1], _wnames(r), c[2].map(func(i): return w[i]))
		k[1].queue_free()
	# Power, targets and mounts follow the weapons as with vanilla swaps.
	k = _card_setup()
	r = k[0]
	var ship := r.ship
	ship.reactor_max = 20
	ship.sys("weapons").level = 8
	for x in ship.weapons:
		if String(x.bp.name) != "LASER_HEAVY_1":
			ship.try_power_weapon(x)
	ship.weapons[1].target_room = 2
	ship.weapons[1].autofire = true
	var before := {}
	for x in ship.weapons:
		before[String(x.bp.name)] = [x.powered, x.target_room, x.autofire]
	var used := ship.weapons_power_used()
	var objs: Array = ship.weapons.duplicate()
	_card_drag(k[2], 0, 3)
	var after := {}
	for x in ship.weapons:
		after[String(x.bp.name)] = [x.powered, x.target_room, x.autofire]
	check("ON: power / target / autofire stay with each weapon", after, before)
	check("  weapon system power unchanged", ship.weapons_power_used(), used)
	check("  same weapon objects, moved", ship.weapons, [objs[1], objs[2], objs[3], objs[0]])
	check("  mount = slot", ship.weapons.map(func(x): return x.mount_index), [0, 1, 2, 3])
	k[1].queue_free()
	# Touch drag.
	k = _card_setup(true)
	r = k[0]
	w = _wnames(r)
	_card_drag(k[2], 2, 1)
	check("ON, touch: slot 3 -> 2", _wnames(r), [w[0], w[2], w[1], w[3]])
	k[1].queue_free()
	# Preview while dragging: whole card at the pointer, the others slide to their preview slots.
	Settings.set_value("qol.cards.slide", false)
	k = _card_setup()
	var ev: EquipmentView = k[2]
	var first: String = _wnames(k[0])[0]
	ev.press(ev.box_rect(_wbox(0)).get_center())
	TooltipService.debug_pointer = ev.get_global_transform() * ev.box_rect(_wbox(2)).get_center()
	for i in 3:
		await get_tree().process_frame
	var at := func(i): return ev.box_rect(_wbox(i)).position
	check("preview 1 -> 3: cards at [3, 1, 2, 4] (no slide)", [qol.card_pos(ev, _wbox(0)), qol.card_pos(ev,
		_wbox(1)), qol.card_pos(ev, _wbox(2)), qol.card_pos(ev, _wbox(3))], [at.call(2), at.call(0), at.call(1),
		at.call(3)])
	check("  whole card follows the pointer, its slot draws no item", [ev.drawn_dragged.get("card", false),
		ev.drawn_items.map(func(e): return e[0]).has(_wbox(0))], [true, false])
	check("  the landing gap glows, shifted cards do not", [qol._equipment_box_draw({"pos": Vector2.ZERO,
		"look": {}}, ev, _wbox(0), _wbox(2), true).look.img, qol._equipment_box_draw({"pos": Vector2.ZERO,
		"look": {}}, ev, _wbox(1), _wbox(2), true).look.img], ["upgradeUI/Equipment/box_weapons_off_selected.png",
		"upgradeUI/Equipment/box_weapons_on.png"])
	TooltipService.debug_pointer = ev.get_global_transform() * ev.box_rect(Vector2i(ShipInventory.CARGO, 1)).get_center()
	for i in 3:
		await get_tree().process_frame
	check("  over cargo: no preview (own slots)", [qol.card_pos(ev, _wbox(1)), qol.card_pos(ev, _wbox(0))],
		[at.call(1), at.call(0)])
	# Slide animation: part of the way on the next frame, there after a short time.
	Settings.set_value("qol.cards.slide", true)
	TooltipService.debug_pointer = ev.get_global_transform() * ev.box_rect(_wbox(3)).get_center()
	await get_tree().create_timer(0.02).timeout
	var mid: Vector2 = qol.card_pos(ev, _wbox(3))
	check("slide: on its way left", mid.x < at.call(3).x and mid.x > at.call(2).x, true)
	await get_tree().create_timer(0.6).timeout
	check("  settled in its preview slot", qol.card_pos(ev, _wbox(3)), at.call(2))
	ev.release(ev.box_rect(Vector2i(ShipInventory.CARGO, 1)).get_center())
	await get_tree().process_frame
	await get_tree().process_frame
	check("drop on cargo: vanilla move, preview cleared", [ev.inv().item_at(k[0], Vector2i(ShipInventory.CARGO,
		1)).get("name", ""), qol.card_pos(ev, _wbox(1))], [first, null])
	TooltipService.debug_pointer = null
	k[1].queue_free()
	group("qol_cards", false)
	k = _card_setup()
	ev = k[2]
	ev.press(ev.box_rect(_wbox(0)).get_center())
	await get_tree().process_frame
	await get_tree().process_frame
	check("OFF: icon only at the pointer, no card positions", [ev.drawn_dragged.get("card", false),
		qol.card_pos(ev, _wbox(1))], [false, null])
	ev.release(Vector2(5, 5))
	k[1].queue_free()
	await get_tree().process_frame
