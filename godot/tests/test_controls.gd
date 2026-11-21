extends Node
## Tests for rules/crew_controls.md and rules/weapon_controls.md: input events pushed through the real
## scene (main.tscn). Run:
##   godot --headless --path godot res://tests/test_controls.tscn

const Harness := preload("res://tests/harness.gd")

var fails := 0
var main: Node
var me: ShipState
var cc: CrewControl


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func _move(p: Vector2, shift := false) -> void:
	var e := InputEventMouseMotion.new()
	e.position = p
	e.global_position = p
	e.shift_pressed = shift
	get_viewport().push_input(e, true)  # canvas coordinates (headless window is 64×64)


func _button(p: Vector2, button: MouseButton, pressed: bool, shift := false) -> void:
	var e := InputEventMouseButton.new()
	e.position = p
	e.global_position = p
	e.button_index = button
	e.pressed = pressed
	e.shift_pressed = shift
	if pressed:
		e.button_mask = MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT
	get_viewport().push_input(e, true)  # canvas coordinates (headless window is 64×64)


func click(p: Vector2, button := MOUSE_BUTTON_LEFT, shift := false) -> void:
	_move(p, shift)
	_button(p, button, true, shift)
	_button(p, button, false, shift)


func drag(a: Vector2, b: Vector2) -> void:
	_move(a)
	_button(a, MOUSE_BUTTON_LEFT, true)
	for i in range(1, 6):
		_move(a.lerp(b, i / 5.0))
	_button(b, MOUSE_BUTTON_LEFT, false)


func key(code: Key, shift := false, unicode := 0) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.pressed = true
	e.shift_pressed = shift
	e.unicode = unicode
	get_viewport().push_input(e, true)  # canvas coordinates (headless window is 64×64)


func scr(c: CrewMember) -> Vector2:
	return main.world_to_screen(cc.ship_of(c), c.pos)


func room_scr(ship: ShipState, room: int) -> Vector2:
	return main.world_to_screen(ship, ship.room_rect(room).get_center())


## Screen point of a room with no crew standing within 20 px (a tile centre).
func empty_point(ship: ShipState, room: int) -> Vector2:
	var r := ship.room_rect(room)
	for x in range(int(r.position.x) + 17, int(r.end.x), 35):
		for y in range(int(r.position.y) + 17, int(r.end.y), 35):
			var p := Vector2(x, y)
			var free := true
			for c in ship.crew:
				if c.pos.distance_to(p) < 25:
					free = false
			if free:
				return main.world_to_screen(ship, p)
	return main.world_to_screen(ship, r.get_center())


func sel() -> Array:
	return cc.selected_crew().map(func(c): return cc.roster.find(c))


## A room with no crew assigned and a free slot (move target).
func free_room(ship: ShipState, avoid: Array = []) -> int:
	for r in ship.layout.rooms:
		if avoid.has(r.id):
			continue
		var used := false
		for c in ship.crew:
			if c.target_room == r.id or c.room == r.id:
				used = true
		if not used and ship.room_rect(r.id).size.x >= 70:
			return r.id
	return -1


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	FtlData.muted = true
	main = load("res://main.tscn").instantiate()
	add_child(main)
	for i in 6:
		await get_tree().process_frame
	main.combat.paused = true  # orders still work while paused (no pause check in CrewControl)
	me = main.player_space.ship
	cc = main.crew_control
	var crew := cc.roster
	print("viewport %s, player view %s" % [get_viewport().get_visible_rect(), main.player_space.get_global_rect()])
	check("crew list has the 3 Kestrel crew", crew.size(), 3)

	print("Selection: left release, replace / shift add / empty floor deselects")
	click(scr(crew[0]))
	check("click crew 0", sel(), [0])
	click(scr(crew[1]))
	check("click crew 1 replaces", sel(), [1])
	click(scr(crew[0]), MOUSE_BUTTON_LEFT, true)
	check("shift-click crew 0 adds", sel(), [0, 1])
	var before := [crew[0].target_room, crew[1].target_room]
	var target := free_room(me)
	click(empty_point(me, target))
	check("click empty floor deselects", sel(), [])
	check("left click never moves crew", [crew[0].target_room, crew[1].target_room], before)
	_move(scr(crew[2]))
	check("hover crew 2 -> potential", crew[2].hovered, true)
	check("  health bar shown while hovered", main.player_space.view.show_health_bar(crew[2]), true)
	_button(scr(crew[2]), MOUSE_BUTTON_LEFT, true)
	check("  press alone does not select", sel(), [])
	_button(scr(crew[2]), MOUSE_BUTTON_LEFT, false)
	check("  release selects", sel(), [2])
	_move(empty_point(me, target))
	check("  moved away: not hovered", crew[2].hovered, false)
	check("  health bar hidden (full hp, not selected/hovered)", main.player_space.view.show_health_bar(crew[0]), false)

	print("Drag box")
	var a := scr(crew[1])
	var b := scr(crew[2])
	var lo := Vector2(minf(a.x, b.x), minf(a.y, b.y)) - Vector2(12, 12)
	var hi := Vector2(maxf(a.x, b.x), maxf(a.y, b.y)) + Vector2(12, 12)
	_move(lo)
	_button(lo, MOUSE_BUTTON_LEFT, true)
	_move(lo + Vector2(5, 5))  # dist² 50: rectangle drawn, no drag selection yet
	check("drag 5,5: rectangle shown", cc.drag_rect().size, Vector2(5, 5))
	_move(hi)
	check("drag: potential = crew 1, 2", cc.potential.map(func(c): return crew.find(c)), [1, 2])
	_button(hi, MOUSE_BUTTON_LEFT, false)
	check("drag release selects crew 1, 2", sel(), [1, 2])
	check("crew 0 outside the box", crew[0].selected, false)

	print("Right click = move (own ship)")
	click(scr(crew[0]))
	_move(room_scr(me, target))
	main._process(0.0)
	check("room highlight while crew selected", main.player_space.move_highlight_room, -1 if target < 0 else target)
	_button(room_scr(me, target), MOUSE_BUTTON_RIGHT, true)
	_button(room_scr(me, target), MOUSE_BUTTON_RIGHT, false)
	check("crew 0 ordered to room", crew[0].target_room, target)
	main._process(0.0)
	check("  right click clears the highlight", main.player_space.move_highlight_room, -1)

	print("Right click with a weapon armed only disarms")
	key(KEY_F2)
	check("F2 selects crew 1 alone", sel(), [1])
	var c1_room: int = crew[1].target_room
	main.weapon_control.select(1)  # power
	main.weapon_control.select(1)  # arm
	check("weapon 2 armed", main.weapon_control.armed, 1)
	var t2 := free_room(me, [target])
	_move(room_scr(me, t2))
	_button(room_scr(me, t2), MOUSE_BUTTON_RIGHT, true)
	_button(room_scr(me, t2), MOUSE_BUTTON_RIGHT, false)
	check("  disarmed", main.weapon_control.armed, -1)
	check("  crew not moved", crew[1].target_room, c1_room)
	main.weapon_control.select(1)
	click(scr(crew[2]))
	check("  left click with weapon armed: selection unchanged", sel(), [1])
	_button(Vector2(5, 700), MOUSE_BUTTON_RIGHT, true)
	_button(Vector2(5, 700), MOUSE_BUTTON_RIGHT, false)

	print("Doors: clickable only with nobody selected")
	click(empty_point(me, target))
	check("deselected", sel(), [])
	var di := 0
	while di < me.env.doors.size() and me.env.doors[di].airlock:
		di += 1
	var dp: Vector2 = main.world_to_screen(me, ShipView.door_rect_of(me, me.env.doors[di]).get_center())
	var was_open: bool = me.env.doors[di].open
	click(dp)
	check("left click on a door toggles it", me.env.doors[di].open, not was_open)
	click(dp, MOUSE_BUTTON_RIGHT)
	check("right click on a door toggles it", me.env.doors[di].open, was_open)
	key(KEY_F1)
	_move(dp)
	check("door not hovered with crew selected", cc.hovered_door, -1)
	click(dp)
	check("  left click on the door: door unchanged", me.env.doors[di].open, was_open)

	print("Hotkeys")
	key(KEY_Q)
	check("Q selects all", sel(), [0, 1, 2])
	key(KEY_F3)
	check("F3", sel(), [2])
	key(KEY_F1, true)
	check("Shift+F1 adds crew 0", sel(), [0, 2])
	key(KEY_F1, true)
	check("Shift+F1 again removes it", sel(), [2])
	key(KEY_SLASH, false, 47)
	check("'/' saves stations", [crew[2].saved_room, crew[2].saved_slot], [crew[2].target_room, crew[2].slot])
	var station: int = crew[2].target_room
	var t3 := free_room(me, [target, t2])
	click(room_scr(me, t3), MOUSE_BUTTON_RIGHT)
	check("crew 2 moved away", crew[2].target_room, t3)
	key(KEY_ENTER)
	check("Enter returns to the station", crew[2].target_room, station)
	check("  message", cc.message, "Return to Stations!")
	key(KEY_SPACE)
	check("Space toggles pause", main.combat.paused, false)
	key(KEY_SPACE)
	check("Space again", main.combat.paused, true)

	print("Crew list boxes and stations buttons")
	click(cc.box_rect(1).get_center())
	check("click crew box 2 selects crew 1 alone", sel(), [1])
	check("  box state colour selected", main.crew_list.state_color(crew[1]), CrewList.COL_SELECTED)
	click(cc.box_rect(0).get_center(), MOUSE_BUTTON_LEFT, true)
	check("shift-click box 1 adds crew 0", sel(), [0, 1])
	_move(cc.box_rect(2).get_center())
	check("hovered box -> potential", crew[2].hovered, true)
	check("  box state colour hovered", main.crew_list.state_color(crew[2]), CrewList.COL_HOVER)
	drag(cc.box_rect(0).position + Vector2(-5, 5), cc.box_rect(2).position + Vector2(40, 5))
	check("drag over the boxes selects every touched box", sel(), [0, 1, 2])
	check("box 0 at (10, 155) 86x27", cc.box_rect(0), Rect2(10, 155, 86, 27))
	click(cc.button_rect(0).get_center())
	check("save stations button", cc.message, "Stations Saved!")
	check("  release over the button: empty potential deselects", sel(), [])
	click(room_scr(me, t3), MOUSE_BUTTON_RIGHT)
	key(KEY_F1)
	click(room_scr(me, t3), MOUSE_BUTTON_RIGHT)
	var st0: int = crew[0].saved_room
	check("crew 0 sent away", crew[0].target_room != st0, true)
	click(cc.button_rect(1).get_center())
	check("return stations button", crew[0].target_room, st0)

	print("Weapon boxes: click on release, right click, drag swap")
	var wc: WeaponControl = main.weapon_control
	for w in me.weapons:
		me.depower_weapon(w)
	var names := me.weapons.map(func(w): return w.bp.name)
	var box0: Vector2 = main.weapon_panel.boxes[0].get_global_rect().get_center()
	var box1: Vector2 = main.weapon_panel.boxes[1].get_global_rect().get_center()
	_move(box0)
	_button(box0, MOUSE_BUTTON_LEFT, true)
	check("press on box 1: not powered yet", me.weapons[0].powered, false)
	_button(box0, MOUSE_BUTTON_LEFT, false)
	check("release powers weapon 1", me.weapons[0].powered, true)
	click(box0)
	check("second click arms it", wc.armed, 0)
	click(box1, MOUSE_BUTTON_RIGHT)
	check("right click on box 2: disarms all", wc.armed, -1)
	click(box0, MOUSE_BUTTON_RIGHT)
	check("right click on box 1: depowers", me.weapons[0].powered, false)
	var mounts := me.weapons.map(func(w): return w.mount_index)
	drag(box0, box1)
	check("drag box 1 onto box 2 swaps", me.weapons.map(func(w): return w.bp.name), [names[1], names[0]])
	check("  mounts stay with the slot", me.weapons.map(func(w): return w.mount_index), mounts)
	check("  drag release is not a click", [me.weapons[0].powered, me.weapons[1].powered, wc.armed],
		[false, false, -1])
	main.weapon_panel._process(0.0)
	check("  box 1 weapon after refresh", main.weapon_panel.boxes[0].weapon.bp.name, names[1])
	key(KEY_1)
	key(KEY_2)
	check("keys 1, 2 power both", [me.weapons[0].powered, me.weapons[1].powered], [true, true])
	me.damage_system("weapons", me.sys("weapons").get_level() - 2)  # capacity 2: one weapon must go
	check("depower order follows the slots (last slot first)", [me.weapons[0].powered, me.weapons[1].powered],
		[true, false])
	me.repair_system("weapons", 10)
	key(KEY_2)
	key(KEY_2)
	check("key 2 twice arms weapon 2", wc.armed, 1)
	key(KEY_1, true)
	check("Shift+1 depowers weapon 1", me.weapons[0].powered, false)
	var auto: bool = me.autofire
	key(KEY_V)
	check("V toggles autofire (4 slots)", me.autofire, not auto)
	check("autofire button shown (> 2 slots)", main.weapon_panel.autofire_btn.visible, true)
	# Armed weapon follows a swap
	wc.select(1)
	check("weapon 2 armed", wc.armed, 1)
	wc.swap(0, 1)
	check("  swap: armed slot follows the weapon", wc.armed, 0)
	wc.disarm()

	print("Boarders on the enemy ship")
	var en: ShipState = main.enemy_space.ship
	main._board(en, 1)
	cc.update_roster()
	var boarder: CrewMember = cc.roster[cc.roster.size() - 1]
	check("boarder in the crew list", en.crew.has(boarder), true)
	click(scr(boarder))
	check("click the boarder on the enemy ship selects it", sel(), [cc.roster.size() - 1])
	var er := -1
	for r in en.layout.rooms:
		if r.id != boarder.room and en.graph.find_slot(r.id, boarder) >= 0 and \
				en.graph.find_path(boarder.pos, boarder.room, r.id, boarder) != null:
			er = r.id
			break
	click(room_scr(en, er), MOUSE_BUTTON_RIGHT)
	check("right click on an enemy room moves the boarder", boarder.target_room, er)
	# Drag box over both ships (CrewControl::MouseMove: own ship + CombatControl::GetSelectedCrew on the target).
	var home: CrewMember = crew[0]
	var pa := scr(home)
	var pb := scr(boarder)
	drag(Vector2(minf(pa.x, pb.x), minf(pa.y, pb.y)) - Vector2(20, 20),
		Vector2(maxf(pa.x, pb.x), maxf(pa.y, pb.y)) + Vector2(20, 20))
	check("drag box over both ships selects crew on both", [home.selected, boarder.selected], [true, true])
	# Right click on the enemy ship: only the selected crew aboard that ship move (CrewControl::RButton).
	var home_room := home.target_room
	var er2 := -1
	for r in en.layout.rooms:
		if r.id != er and en.graph.find_slot(r.id, boarder) >= 0 and \
				en.graph.find_path(boarder.pos, boarder.room, r.id, boarder) != null:
			er2 = r.id
			break
	click(room_scr(en, er2), MOUSE_BUTTON_RIGHT)
	check("  right click on an enemy room: the boarder moves, the crew at home does not",
		[boarder.target_room, home.target_room], [er2, home_room])
	# Non-hostile enemy (dead crew / surrender): orders still work (no hostile check in CrewControl).
	var ai: ShipAI = main.combat.ais[main.enemy_space]
	ai.hostile = false
	main.combat.paused = false
	main.combat._physics_process(1.0 / 60.0)
	main.combat.paused = true
	cc.deselect_all()
	click(scr(boarder))
	click(room_scr(en, er), MOUSE_BUTTON_RIGHT)
	check("non-hostile enemy ship: the boarder is selected and moved", [sel(), boarder.target_room],
		[[cc.roster.size() - 1], er])
	ai.hostile = true
	main.combat.paused = false
	main.combat._physics_process(1.0 / 60.0)
	main.combat.paused = true
	# A weapon armed: the left press targets, CrewControl ignores it (WeaponsArmed).
	cc.deselect_all()
	var wi := -1
	for i in me.weapons.size():
		if me.weapons[i].powered:
			wi = i
	if wi >= 0:
		wc.select(wi)
		click(scr(boarder))
		check("weapon armed: a click on the boarder aims at its room, no selection", [sel(),
			me.weapons[wi].target_ship == en], [[], true])
		wc.disarm()
		me.weapons[wi].clear_target()
	cc.deselect_all()

	print("Pause freezes every game-world animation (CommandGui::OnLoop skips the world while paused)")
	main.combat.paused = true
	await get_tree().process_frame
	var v: ShipView = main.player_space.view
	var t0: float = v._time
	for i in 10:
		await get_tree().process_frame
	check("paused: ship view animation clock frozen", v._time, t0)
	check("  Combat.world_delta = 0", Combat.world_delta(0.1), 0.0)
	main.combat.paused = false
	for i in 3:
		await get_tree().process_frame
	check("unpaused: animations run again", v._time > t0, true)
	main.combat.paused = true
	await get_tree().process_frame
	print("Breach frame follows the repair state only")
	check("breach frames 100 / 50 / 0 health", [ShipView.breach_frame(100.0), ShipView.breach_frame(50.0),
		ShipView.breach_frame(0.0)], [6, 3, 0])

	print("Door control box: Z opens all doors, X closes them (Settings hotkeys open / close)")
	check("doors button exists (DoorBox)", main.systems_bar.buttons.has("doors"), true)
	for d in me.env.doors:
		d.open = false
	key(KEY_Z)
	check("Z: interior doors open", me.env.doors.filter(func(d): return not d.airlock and not d.open).size(), 0)
	key(KEY_X)
	check("X: all doors closed", me.env.doors.filter(func(d): return d.open).size(), 0)
	var db: SystemButton = main.systems_bar.buttons["doors"]
	click(db.global_position + Vector2(20, 43))
	check("click the bottom button (open)", me.env.doors.filter(func(d): return not d.airlock and d.open).size() > 0,
		true)
	click(db.global_position + Vector2(20, 20))
	check("click the top button (close)", me.env.doors.filter(func(d): return d.open).size(), 0)
	me.sys("doors").ion = 2
	key(KEY_Z)
	check("ionized doors: Z does nothing", me.env.doors.filter(func(d): return d.open).size(), 0)
	me.sys("doors").ion = 0

