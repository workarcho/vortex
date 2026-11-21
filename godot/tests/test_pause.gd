extends Node
## Tests for rules/pause.md: what every player action does while the game is paused (CApp::OnLoop runs
## WorldManager::PauseLoop instead of OnLoop; input is never gated by the pause). State changes apply at once,
## simulation effects (air, walking, charging, firing, queued teleport / hack / mind control) wait for the unpause.
## Input goes through the real scene (main.tscn). Run:
##   godot --headless --path godot res://tests/test_pause.tscn

const Harness := preload("res://tests/harness.gd")

const MAIN := preload("res://scripts/main.gd")

var fails := 0
var main: Node
var me: ShipState
var en: ShipState


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func _move(p: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = p
	e.global_position = p
	get_viewport().push_input(e, true)  # canvas coordinates (headless window is 64×64)


func _button(p: Vector2, button: MouseButton, pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	e.position = p
	e.global_position = p
	e.button_index = button
	e.pressed = pressed
	if pressed:
		e.button_mask = MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT
	get_viewport().push_input(e, true)


func click(p: Vector2, button := MOUSE_BUTTON_LEFT) -> void:
	_move(p)
	_button(p, button, true)
	_button(p, button, false)


func key(code: Key, shift := false) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.pressed = true
	e.shift_pressed = shift
	get_viewport().push_input(e, true)


func frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame
		await get_tree().process_frame


func room_scr(ship: ShipState, room: int) -> Vector2:
	return main.world_to_screen(ship, ship.room_rect(room).get_center())


func _start(ship_name: String) -> void:
	if main != null:
		main.queue_free()
		await get_tree().process_frame
	MAIN._scenario_cli_done = true
	MAIN.player_ship_name = ship_name
	MAIN.harmless_enemy = true
	main = load("res://main.tscn").instantiate()
	add_child(main)
	await frames(6)
	me = main.player_space.ship
	en = main.enemy_space.ship


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	FtlData.muted = true
	await _start("PLAYER_SHIP_HARD")
	await _doors()
	await _crew()
	await _power_and_weapons()
	MAIN.player_drone_names = ["DEFENSE_1", "COMBAT_1"]
	await _start("TEST_SHIP_ALL")
	MAIN.player_drone_names = []
	await _systems()
	await _hud()
	await _jump()
	MAIN.harmless_enemy = false
	MAIN.player_drone_names = []
	MAIN.player_ship_name = "PLAYER_SHIP_HARD"


func _doors() -> void:
	print("Doors while paused: state, animation and sound at once; no venting until unpause")
	main.combat.paused = true
	var view: ShipView = main.player_space.view
	var di := 0
	while me.env.doors[di].airlock:
		di += 1
	var d: Dictionary = me.env.doors[di]
	check("interior door starts closed", d.open, false)
	me.env.sound_log.clear()
	click(main.world_to_screen(me, ShipView.door_rect_of(me, d).get_center()))
	check("click while paused: door open at once (Door::Manipulate)", d.open, true)
	check("  doorOpen sound at once (Animation::Start)", me.env.sound_log.has("doorOpen"), true)
	var p0: float = view._doors_anim[di].p
	await frames(20)  # 20 frames >= 0.2 s door animation in the headless loop
	check("  door sprite animates while paused (Ship::PauseLoop)", view._doors_anim[di].p > p0, true)
	check("  ship animation clock still frozen", Combat.world_delta(0.1), 0.0)
	click(main.world_to_screen(me, ShipView.door_rect_of(me, d).get_center()))
	check("second click: closed at once", d.open, false)
	check("  doorClose sound", me.env.sound_log.back(), "doorClose")
	# Enemy doors get no PauseLoop: their sprite holds its frame while paused.
	var ev: ShipView = main.enemy_space.view
	var edi := 0
	while en.env.doors[edi].airlock:
		edi += 1
	var ep0: float = ev._doors_anim[edi].p
	en.env.set_door(edi, not en.env.doors[edi].open)
	await frames(10)
	check("enemy door sprite frozen while paused", ev._doors_anim[edi].p, ep0)
	en.env.set_door(edi, not en.env.doors[edi].open)

	# Vent: Z twice opens interior doors, then the airlocks. Oxygen does not move while paused.
	key(KEY_Z)
	key(KEY_Z)
	check("Z, Z while paused: airlocks open", me.env.doors.filter(func(x): return x.airlock and not x.open).size(), 0)
	var o2_before: Dictionary = me.env.oxygen.duplicate()
	await frames(30)
	check("  no air lost while paused", me.env.oxygen, o2_before)
	check("  airLeak loop off while paused", me.env.leaking_o2 and not main.combat.paused, false)
	main.combat.paused = false
	await frames(30)
	var lost := false
	for r in o2_before:
		if me.env.oxygen[r] < o2_before[r] - 0.01:
			lost = true
	check("unpaused: the open airlocks vent", lost, true)
	main.combat.paused = true
	key(KEY_X)
	check("X while paused: every door closed at once", me.env.doors.filter(func(x): return x.open).size(), 0)
	for r in o2_before:
		me.env.oxygen[r] = 100.0

	print("Airlocks keep their Door::OnLoop while paused (Ship::PauseLoop: vOuterAirlocks)")
	var ai := -1
	for i in me.env.doors.size():
		if me.env.doors[i].airlock:
			ai = i
			break
	var inner := di
	me.env.doors[ai].forced = 1.0
	me.env.doors[inner].forced = 1.0
	await frames(10)
	check("  airlock forced-open timer runs while paused", me.env.doors[ai].forced < 1.0, true)
	check("  interior door forced-open timer frozen", me.env.doors[inner].forced, 1.0)
	me.env.doors[ai].forced = 0.0
	me.env.doors[inner].forced = 0.0
	me.env.doors[ai].open = false
	me.env.doors[inner].open = false


func _crew() -> void:
	print("Crew orders while paused: path set at once, walking only after unpause")
	main.combat.paused = true
	var cc: CrewControl = main.crew_control
	var c: CrewMember = cc.roster[0]
	key(KEY_F1)
	check("F1 selects while paused", c.selected, true)
	var target := -1
	for r in me.layout.rooms:
		if r.id != c.room and me.room_rect(r.id).size.x >= 70:
			var used := false
			for o in me.crew:
				if o.target_room == r.id or o.room == r.id:
					used = true
			if not used:
				target = r.id
				break
	var pos0: Vector2 = c.pos
	click(room_scr(me, target), MOUSE_BUTTON_RIGHT)
	check("right click: destination set at once (CommandCrewMoveRoom)", c.target_room, target)
	await frames(20)
	check("  crew does not move while paused", c.pos, pos0)
	key(KEY_SLASH)
	check("'/' saves stations while paused", [c.saved_room, c.saved_slot], [c.target_room, c.slot])
	main.combat.paused = false
	await frames(20)
	check("unpaused: the crew walks", c.pos != pos0, true)
	main.combat.paused = true
	await frames(2)
	var pos1: Vector2 = c.pos
	key(KEY_ENTER)
	check("Enter (return to stations) while paused: destination at once", c.target_room, c.saved_room)
	await frames(10)
	check("  still standing while paused", c.pos, pos1)
	cc.deselect_all()


func _power_and_weapons() -> void:
	print("Power and weapons while paused")
	main.combat.paused = true
	var shields := me.sys("engines")
	var free_before := me.reactor_free()
	var p0 := shields.power
	main.systems_bar._decrease("engines")
	check("system power -1 at once", shields.power, p0 - 1)
	main.systems_bar._increase("engines")
	check("system power +1 at once", shields.power, p0)
	check("  reactor bars back", me.reactor_free(), free_before)
	var wc: WeaponControl = main.weapon_control
	for w in me.weapons:
		me.depower_weapon(w)
	var w0: WeaponState = me.weapons[0]
	key(KEY_1)
	check("key 1: weapon powered at once", w0.powered, true)
	var ch: float = w0.charge
	await frames(20)
	check("  no charge while paused", w0.charge, ch)
	key(KEY_1)
	check("key 1 again: armed", wc.armed, 0)
	var room: int = en.layout.rooms[0].id
	main._on_enemy_room_clicked(room, MOUSE_BUTTON_LEFT, false)
	check("enemy room click: target set at once (WeaponControl::Fire)", [w0.target_ship == en, w0.target_room],
		[true, room])
	check("  disarmed after aiming", wc.armed, -1)
	var auto0: bool = me.autofire
	key(KEY_V)
	check("V toggles autofire while paused", me.autofire, not auto0)
	key(KEY_V)
	var wl := me.crew_level_in("weapons")
	w0.charge = w0.max_charge(wl)
	var shots: int = main.combat.projectiles.size()
	await frames(10)
	check("charged + targeted while paused: no shot", main.combat.projectiles.size(), shots)
	check("  target kept, still charged", [w0.target_ship == en, w0.is_charged(wl)], [true, true])
	main.combat.paused = false
	await frames(30)
	check("unpaused: the weapon fires (charge spent)", w0.charge < w0.max_charge(wl), true)
	main.combat.paused = true


func _systems() -> void:
	print("Systems (TEST_SHIP_ALL): activations while paused")
	main.combat.paused = false
	for id in ["hacking", "mind", "teleporter", "cloaking", "battery"]:
		for i in 4:
			me.increase_power(id)
	await frames(10)
	main.combat.paused = true
	# Cloak: SetTurnedOn applies at once; the "cloak" sound waits for CloakingSystem::OnLoop.
	check("cloak turns on while paused", CloakRule.turn_on(me), true)
	check("  cloaked at once", me.is_cloaked(), true)
	check("  sound queued for the next OnLoop", me.sys("cloaking").sound_effect, "cloak")
	var fade: float = me.cloak_fade
	await frames(10)
	check("  cloak fade frozen while paused", me.cloak_fade, fade)
	main.combat.paused = false
	await frames(3)
	check("unpaused: the sound played", me.sys("cloaking").sound_effect, "")
	CloakRule.turn_off(me)
	await frames(2)
	main.combat.paused = true
	# Battery: SetTurnedOn applies the battery power at once.
	check("battery turns on while paused", BatteryRule.turn_on(me), true)
	check("  battery bars available at once", me.battery_cap > 0, true)

	# Hacking: StartHacking only queues (queuedSystem); HackingSystem::OnLoop launches it.
	var room := -1
	for r in en.layout.rooms:
		if en.system_in_room(r.id) != null:
			room = r.id
			break
	check("hacking arms while paused", HackingRule.arm(me), "ok")
	main._on_enemy_room_clicked(room, MOUSE_BUTTON_LEFT, false)
	check("  click: queued, disarmed", [me.hack_queued != null, me.hack_armed], [true, false])
	await frames(10)
	check("  not launched while paused", me.hack_target == null and not HackingRule.drone(me).deployed, true)
	main.combat.paused = false
	await frames(3)
	check("unpaused: drone launched", [me.hack_queued == null, HackingRule.drone(me).deployed], [true, true])
	main.combat.paused = true

	# Mind control: QueueMindControl; MindSystem::OnLoop takes control.
	var mroom := -1
	for c in en.crew:
		if c.is_alive() and not c.is_drone():
			mroom = c.room
			break
	main.combat.paused = false
	for i in 300:
		if MindRule.can_use(me) and MindRule.charged(me) and not me.mind_in_use:
			break
		await frames(1)
	main.combat.paused = true
	check("mind control arms while paused", MindRule.arm(me), "ok")
	main._on_enemy_room_clicked(mroom, MOUSE_BUTTON_LEFT, false)
	check("  click: queued, disarmed", [me.mind_queue.is_empty(), me.mind_armed], [false, false])
	await frames(10)
	check("  nobody controlled while paused", en.crew.filter(func(c): return c.mind_controlled).size(), 0)
	main.combat.paused = false
	await frames(3)
	check("unpaused: crew controlled", en.crew.filter(func(c): return c.mind_controlled).size() > 0, true)
	main.combat.paused = true

	# Teleporter: the command is stored (CombatControl::teleportCommand), run by CommandGui::OnLoop unpaused only.
	var tp := me.sys("teleporter")
	var c0: CrewMember = me.own_crew().filter(func(c): return not c.is_drone() and c.room != tp.room)[0]
	me.crew.erase(c0)
	TeleporterRule.place_arrival(me, c0, tp.room)
	main.combat.paused = false
	for i in 300:
		if TeleporterRule.can_send(me, en) and not tp.is_locked():
			break
		await frames(1)
	main.combat.paused = true
	check("teleporter arms (SEND) while paused", main.combat.arm_teleporter(me, TeleporterRule.SEND), true)
	main._on_enemy_room_clicked(en.layout.rooms[0].id, MOUSE_BUTTON_LEFT, false)
	check("  click: command stored, disarmed", [main.combat.player_tp_command.is_empty(),
		main.combat.player_tp_armed], [false, TeleporterRule.NONE])
	await frames(10)
	check("  nobody teleported while paused", main.combat.parties.get(me, []).size(), 0)
	main.combat.paused = false
	await frames(3)
	check("unpaused: party leaves", main.combat.parties.get(me, []).size() > 0, true)
	main.combat.paused = true

	print("Drones while paused")
	var d0: Drone = null
	for d in me.drones:
		if d != null and not d.powered:
			d0 = d
			break
	if d0 != null:
		var r := DroneSystemRule.player_toggle(me, d0)
		check("drone box click while paused: powered at once (ShipManager::PowerDrone)", [r, d0.powered],
			["ok", true])
	else:
		check("TEST_SHIP_ALL has an unpowered drone", d0 != null, true)


func _hud() -> void:
	print("Visuals while paused")
	main.combat.paused = true
	await frames(2)
	check("PAUSED overlay shown", main.pause_overlay.visible, true)


func _close_dialogs(r: RunState) -> void:
	for i in 10:
		if r.phase == RunState.Phase.DIALOG:
			var first := r.dialog_choices.find_custom(func(v): return v.enabled)
			r.choose(maxi(first, 0))
		elif r.phase == RunState.Phase.MESSAGE:
			r.apply(RunIntent.make(RunIntent.CONTINUE))


func _jump() -> void:
	print("FTL jump while the player paused: the jump ends the pause (CommandGui::OnLoop bPaused && !jumping)")
	main.queue_free()
	await get_tree().process_frame
	MAIN.harmless_enemy = false
	MAIN.player_ship_name = "PLAYER_SHIP_HARD"
	MAIN.run_mode = true
	var r := RunState.new_run(77)
	_close_dialogs(r)
	RunState.current = r
	main = load("res://main.tscn").instantiate()
	add_child(main)
	await frames(6)
	main._toggle_pause()
	check("player pause on", main.combat.paused, true)
	r.apply(RunIntent.make(RunIntent.OPEN_MAP))
	await frames(3)
	check("map opens while paused", r.map_open, true)
	var n0: int = r.map.links_of(r.current_beacon)[0]
	var pc := InputProfile.new(InputProfile.PC)
	pc.run = r
	pc.beacon_hover(n0)
	pc.beacon_click(n0)
	for i in 600:
		await frames(1)
		if main._jump_phase == "" and r.current_beacon == n0:
			break
	_close_dialogs(r)
	await frames(5)
	check("arrived", r.current_beacon, n0)
	check("after the jump (box closed) the game runs", main.combat.paused, false)
	print("Sector jump: the same JumpLeave / JumpArrive animation (StarMap::OnLoop -> dummyNewSector -> CommandGui::OnLoop)")
	r.jump_to(r.map.exit)  # debug jump (no map: no animation), then the sector choice through the intents
	_close_dialogs(r)
	r.enemy = {}
	r.ship.fuel = maxi(r.ship.fuel, 3)
	r.ship.ftl_charge = 1.0
	await frames(5)
	check("debug jump to the exit: no animation", main._jump_phase, "")
	var sector0: int = r.sector
	r.apply(RunIntent.make(RunIntent.OPEN_MAP))
	r.apply(RunIntent.make(RunIntent.NEXT_SECTOR))
	await frames(2)
	var dest: int = r.tree.neighbours(r.sector_id)[0]
	r.apply(RunIntent.make(RunIntent.SELECT_SECTOR, dest))
	check("sector chosen", r.apply(RunIntent.make(RunIntent.CONFIRM_SECTOR)), true)
	await frames(2)
	check("sector jump -> JumpLeave animation", [main._jump_phase, r.sector], ["leave", sector0 + 1])
	var phases := {}
	for i in 600:
		await frames(1)
		phases[main._jump_phase] = true
		if main._jump_phase == "":
			break
	check("leave -> arrive -> done", [phases.has("arrive"), main._jump_phase], [true, ""])
	check("new sector built", main._built_sector, main._sector_key())
	main.queue_free()
	await get_tree().process_frame
	main = null
	MAIN.run_mode = false
	RunState.current = null
