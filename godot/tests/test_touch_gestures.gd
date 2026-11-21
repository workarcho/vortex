extends Node

const Harness := preload("res://tests/harness.gd")
## Tests for the combat touch scheme (scripts/ui/touch_gestures.gd, scripts/ui/touch_combat_buttons.gd, main.gd
## `_touch_selection_tick`; rules/ui_layout_strategy.md "Touch gestures (combat)"): synthetic events pushed through
## the real scene (main.tscn sandbox). The finger is sent like Godot's emulate_mouse_from_touch does: its emulated
## mouse event first (with a motion at the landing point), then its ScreenTouch. Run:
##   godot --headless --path godot res://tests/test_touch_gestures.tscn

const MAIN := preload("res://scripts/main.gd")
const CANVAS := Vector2i(1600, 720)  # the phone canvas of test_touch_layout (the default 1280² headless canvas
# stacks the pinned subsystems / crew buttons / power toggle over PAUSE)

var fails := 0
var main: Node
var me: ShipState
var cc: CrewControl
var g: TouchGestures


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func _push(e: InputEvent) -> void:
	get_viewport().push_input(e, true)  # canvas coordinates (headless window is 64×64)


func _move(p: Vector2, mask := 0) -> void:
	var e := InputEventMouseMotion.new()
	e.position = p
	e.global_position = p
	e.button_mask = mask
	_push(e)


func _button(p: Vector2, button: MouseButton, pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	e.position = p
	e.global_position = p
	e.button_index = button
	e.pressed = pressed
	if pressed:
		e.button_mask = MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT
	_push(e)


## Finger `i` lands / lifts (finger 0 also sends its emulated left-mouse event first).
func _touch(i: int, p: Vector2, pressed: bool) -> void:
	if i == 0:
		if pressed:
			_move(p, MOUSE_BUTTON_MASK_LEFT)  # TooltipService: the finger lands, hover moves there first
		_button(p, MOUSE_BUTTON_LEFT, pressed)
	var e := InputEventScreenTouch.new()
	e.index = i
	e.position = p
	e.pressed = pressed
	_push(e)


## A whole tap, then one selection tick (main._process runs it every frame).
func tap(p: Vector2) -> void:
	_touch(0, p, true)
	_touch(0, p, false)
	_move(TooltipService.OFF_SCREEN)  # TooltipService._lift: the finger lifted
	main._touch_selection_tick()


func scr(c: CrewMember) -> Vector2:
	return main.world_to_screen(cc.ship_of(c), c.pos)


func room_scr(ship: ShipState, room: int) -> Vector2:
	return main.world_to_screen(ship, ship.room_rect(room).get_center())


## Screen point of a room with no crew standing within 25 px.
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


func free_room(ship: ShipState, not_room := -1) -> int:
	for r in ship.layout.rooms:
		var used := false
		for c in ship.crew:
			if c.target_room == r.id or c.room == r.id:
				used = true
		if not used and r.id != not_room and ship.room_rect(r.id).size.x >= 70:
			return r.id
	return -1


## A point over neither ship's rooms, no crew, no HUD control: "empty space".
func space_point() -> Vector2:
	for y in range(300, 700, 20):
		for x in range(20, 1260, 20):
			var p := Vector2(x, y)
			if not g.room_at(p).is_empty() or cc.box_at(p) >= 0 or main.touch_buttons.button_at(p) != "":
				continue
			_move(p, MOUSE_BUTTON_MASK_LEFT)
			var hud: bool = main._touch_over_hud(p)
			_move(TooltipService.OFF_SCREEN)
			if not hud:
				return p
	return Vector2(-1, -1)


func sel() -> Array:
	return cc.selected_crew().map(func(c): return cc.roster.find(c))


func state() -> Array:  # [paused, selection mode, CANCEL shown]
	return [main.combat.paused, main.touch_selecting, main.touch_buttons.cancel_shown]


## Finger 1 (no emulated mouse: Godot emulates only finger 0) lands / lifts at `p`.
func finger1(p: Vector2, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = 1
	e.position = p
	e.pressed = pressed
	_push(e)


## Finger 1 moves to `p` (ScreenDrag, no emulated mouse).
func drag1(p: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = 1
	e.position = p
	_push(e)


func ctrl(down: bool) -> void:
	var k := InputEventKey.new()
	k.keycode = KEY_CTRL
	k.pressed = down
	Input.parse_input_event(k)


## Box corners around crew 1 and 2 (screen), 12 px outside their positions.
func box_12() -> Array:
	var a := scr(cc.roster[1])
	var b := scr(cc.roster[2])
	return [Vector2(minf(a.x, b.x), minf(a.y, b.y)) - Vector2(12, 12),
		Vector2(maxf(a.x, b.x), maxf(a.y, b.y)) + Vector2(12, 12)]


## Held finger (or Ctrl) + second finger drag = crew drag box; + tap on a crew = toggle (TouchGestures header).
func _multi_select(crew: Array) -> void:
	print("Multi-select: held finger + drag = box, held finger + tap crew = toggle")
	main.combat.paused = false
	cc.deselect_all()
	main._touch_selection_tick()
	var box := box_12()
	var lo: Vector2 = box[0]
	var hi: Vector2 = box[1]
	check("box start over the player ship", main._touch_box_start(lo), true)
	var wb: WeaponBox = main.weapon_panel.boxes[0]
	var wpt := wb.get_global_transform() * (wb.size / 2)
	check("  over a weapon box: not a box start", main._touch_box_start(wpt), false)
	var enemy: ShipState = main.enemy_space.ship
	check("  over the enemy ship view (targeting): not a box start",
		main._touch_box_start(room_scr(enemy, enemy.layout.rooms[0].id)), false)
	var sb: SystemsBar = main.systems_bar
	var reactor_pt: Vector2 = sb.get_global_transform() * Vector2(HudLayout.REACTOR_X + 14, HudLayout.REACTOR_BAR_TOP + 3)
	check("  over the reactor (tooltip only): box start OK", main._touch_box_start(reactor_pt), true)
	var label_pt: Vector2 = sb.sub_group.get_global_transform() * (HudLayout.SUBSYSTEM_LABEL
		+ Vector2(1.5 * sb.sub_spacing, 4))
	check("  over the SUBSYSTEMS label: box start OK", main._touch_box_start(label_pt), true)
	var ecol: SystemPowerColumn = sb.columns["engines"]
	check("  over a system power column: not a box start",
		main._touch_box_start(ecol.get_global_transform() * ecol.hit_rect().get_center()), false)
	var tp: TouchPowerToggle = main.touch_power
	check("  over the + / − toggle: not a box start", main._touch_box_start(tp.get_global_transform()
		* (TouchPowerToggle.SIZE / 2)), false)
	check("  over a crew box: not a box start", main._touch_box_start(cc.list_xf * cc.box_rect(0).get_center()), false)
	check("  over PAUSE: not a box start", main._touch_box_start(main.touch_buttons.rect_of("pause").get_center()),
		false)
	var hull_pt: Vector2 = main.ship_status.get_global_transform() * Vector2(60, 30)
	check("  over the ship status (hull, tooltip only): box start OK", main._touch_box_start(hull_pt), true)
	var rest := empty_point(me, free_room(me))
	_touch(0, rest, true)
	await wait(0.25)
	finger1(lo, true)
	drag1(lo + Vector2(5, 5))
	check("held + second finger drag 5,5: rectangle shown", cc.drag_rect().size, Vector2(5, 5))
	_move(rest + Vector2(1, 1), MOUSE_BUTTON_MASK_LEFT)  # the held finger jitters: the box ignores it
	drag1(hi)
	check("  drag on: rectangle to the second finger", cc.drag_rect(), Rect2(lo, hi - lo))
	finger1(hi, false)
	await get_tree().process_frame
	check("  lift: box selects crew 1, 2", sel(), [1, 2])
	check("  result", g.last_result, "box")
	check("  rectangle gone", cc.drag_rect(), Rect2())
	_touch(0, rest, false)
	_move(TooltipService.OFF_SCREEN)
	main._touch_selection_tick()
	check("  held finger's lift: nothing else (selection kept)", sel(), [1, 2])
	check("  selection mode: paused + CANCEL", state(), [true, true, true])
	var room := free_room(me)
	tap(empty_point(me, room))
	check("normal tap on a room: both selected crew ordered there", [crew[1].target_room, crew[2].target_room],
		[room, room])
	check("  selection ended, unpaused", [sel(), state()], [[], [false, false, false]])

	print("Held finger + drag starting on a weapon box: no box (its lift is the − tap)")
	var wc: WeaponControl = main.weapon_control
	if not me.weapons[0].powered:
		wc.select(0)
	_touch(0, rest, true)
	await wait(0.25)
	finger1(wpt, true)
	drag1(wpt + Vector2(0, 6))
	drag1(wpt + Vector2(0, 10))
	check("  no rectangle", cc.drag_rect(), Rect2())
	finger1(wpt + Vector2(0, 10), false)
	await get_tree().process_frame
	check("  no box selection; weapon 1 depowered by the − tap", [sel(), me.weapons[0].powered], [[], false])
	_touch(0, rest, false)
	_move(TooltipService.OFF_SCREEN)
	main._touch_selection_tick()

	print("Held finger + tap on a crew = toggle")
	tap(cc.list_xf * cc.box_rect(0).get_center())  # its box (the sprite may stand on a door)
	check("crew 0 selected (mode)", [sel(), state()], [[0], [true, true, true]])
	_touch(0, rest, true)
	await wait(0.25)
	for step in [[scr(crew[1]), [0, 1], "sprite crew 1 added"],
			[cc.list_xf * cc.box_rect(2).get_center(), [0, 1, 2], "crew box 3 added"],
			[scr(crew[0]), [1, 2], "crew 0 removed"]]:
		finger1(step[0], true)
		finger1(step[0], false)
		await get_tree().process_frame
		check("  held + tap: " + step[2], sel(), step[1])
	check("  result", g.last_result, "toggle")
	while me.sys("engines").power < 2:
		me.increase_power("engines")
	var pw := me.sys("engines").power
	var col: SystemPowerColumn = main.systems_bar.columns["engines"]
	var ec: Vector2 = col.get_global_transform() * col.hit_rect().get_center()
	finger1(ec, true)
	finger1(ec, false)
	await get_tree().process_frame
	check("  held + tap on the engines column: still −1, selection kept", [me.sys("engines").power, sel()],
		[pw - 1, [1, 2]])
	for c in [crew[1], crew[2]]:
		finger1(scr(c), true)
		finger1(scr(c), false)
		await get_tree().process_frame
	_touch(0, rest, false)
	_move(TooltipService.OFF_SCREEN)
	main._touch_selection_tick()
	check("  all toggled off: mode ends, unpaused", [sel(), state()], [[], [false, false, false]])
	if not me.weapons[0].powered:
		wc.select(0)  # powers it
	wc.select(0)  # weapon 1 armed: a held + crew tap disarms and selects
	main._touch_selection_tick()
	check("  weapon 1 armed (mode)", [wc.armed, state()], [0, [true, true, true]])
	_touch(0, rest, true)
	await wait(0.25)
	finger1(scr(crew[1]), true)
	finger1(scr(crew[1]), false)
	await get_tree().process_frame
	_touch(0, rest, false)
	_move(TooltipService.OFF_SCREEN)
	main._touch_selection_tick()
	check("  held + tap crew 1 while armed: disarmed, crew 1 selected", [wc.armed, sel(), state()],
		[-1, [1], [true, true, true]])
	main.touch_cancel()

	print("Desktop stand-ins: Ctrl + left drag = box, Ctrl + click crew = toggle")
	box = box_12()  # crew 1, 2 walked meanwhile
	lo = box[0]
	hi = box[1]
	ctrl(true)
	await get_tree().process_frame
	_move(lo, MOUSE_BUTTON_MASK_LEFT)
	_button(lo, MOUSE_BUTTON_LEFT, true)
	_move(lo + Vector2(5, 5), MOUSE_BUTTON_MASK_LEFT)
	check("Ctrl + left drag 5,5: rectangle shown", cc.drag_rect().size, Vector2(5, 5))
	_move(hi, MOUSE_BUTTON_MASK_LEFT)
	_button(hi, MOUSE_BUTTON_LEFT, false)
	_move(TooltipService.OFF_SCREEN)
	main._touch_selection_tick()
	check("  release: box selects crew 1, 2 -> mode", [sel(), state()], [[1, 2], [true, true, true]])
	tap(scr(crew[0]))
	check("  Ctrl + click crew 0: added", sel(), [0, 1, 2])
	tap(scr(crew[1]))
	check("  Ctrl + click crew 1: removed", sel(), [0, 2])
	ctrl(false)
	await get_tree().process_frame
	tap(scr(crew[1]))
	check("  plain click crew 1 (no Ctrl): selection switches to it", sel(), [1])
	main.touch_cancel()
	check("  cancelled", [sel(), state()], [[], [false, false, false]])


## Waits `s` seconds of real time (headless frames may run faster than the clock; TouchGestures uses real time).
func wait(s: float) -> void:
	var end := Time.get_ticks_msec() + int(s * 1000.0)
	while Time.get_ticks_msec() < end:
		await get_tree().process_frame


## Held finger = − (TouchGestures.held_minus): one finger resting ≥ HOLD_MS, a second finger's tap removes power and
## the held finger's lift does nothing; a near-simultaneous two-finger tap is nothing special.
func _held_finger(crew: Array) -> void:
	print("Held finger + second finger tap = − (TouchPowerToggle)")
	var tp: TouchPowerToggle = main.touch_power
	check("power toggle exists", tp != null, true)
	if tp == null:
		return
	tp.minus = false
	main.combat.paused = true
	cc.deselect_all()
	main._touch_selection_tick()
	var col: SystemPowerColumn = main.systems_bar.columns["engines"]
	while me.sys("engines").power < 2:
		me.increase_power("engines")
	var ec: Vector2 = col.get_global_transform() * col.hit_rect().get_center()
	var cp := scr(crew[0])
	# Finger 0 rests on a crew sprite, finger 1 taps the engines column.
	_touch(0, cp, true)
	check("  just landed: + still shown", tp.shows_minus(), false)
	await wait(0.25)
	check("  held ≥ %d ms: − shown" % TouchGestures.HOLD_MS, [g.held_minus(), tp.shows_minus()], [true, true])
	var pw := me.sys("engines").power
	finger1(ec, true)
	finger1(ec, false)
	await get_tree().process_frame
	check("  second finger taps the engines column: −1", me.sys("engines").power, pw - 1)
	_touch(0, cp, false)
	_move(TooltipService.OFF_SCREEN)
	main._touch_selection_tick()
	check("  held finger lifts on a crew sprite: no click (nothing selected)", sel(), [])
	check("  lifted: + shown again, sticky mode still +", [tp.shows_minus(), tp.minus], [false, false])
	# Weapon box: depowered by the second finger.
	var wc: WeaponControl = main.weapon_control
	var b0: WeaponBox = main.weapon_panel.boxes[0]
	if not me.weapons[0].powered:
		wc.select(0)
	check("  weapon 1 powered", me.weapons[0].powered, true)
	_touch(0, cp, true)
	await wait(0.25)
	finger1(b0.get_global_transform() * (b0.size / 2), true)
	finger1(b0.get_global_transform() * (b0.size / 2), false)
	await get_tree().process_frame
	check("  second finger taps weapon 1: depowered, not armed", [me.weapons[0].powered, wc.armed], [false, -1])
	_touch(0, cp, false)
	_move(TooltipService.OFF_SCREEN)
	main._touch_selection_tick()
	check("  held finger lift: still nothing selected", sel(), [])
	# Near-simultaneous two-finger tap: nothing special; the first finger's lift is the normal click.
	pw = me.sys("engines").power
	_touch(0, cp, true)
	finger1(ec, true)
	finger1(ec, false)
	await get_tree().process_frame
	check("  simultaneous two-finger tap: engines unchanged", me.sys("engines").power, pw)
	_touch(0, cp, false)
	_move(TooltipService.OFF_SCREEN)
	main._touch_selection_tick()
	check("  first finger's lift = normal click: crew 1 selected", sel(), [0])
	cc.deselect_all()
	main._touch_selection_tick()
	# A long press no longer depowers a weapon box (tooltip only; the lift is the normal click = arm).
	wc.select(0)
	_touch(0, b0.get_global_transform() * (b0.size / 2), true)
	await wait(0.7)
	check("  long press on weapon 1: still powered", me.weapons[0].powered, true)
	_touch(0, b0.get_global_transform() * (b0.size / 2), false)
	_move(TooltipService.OFF_SCREEN)
	wc.disarm()
	main._touch_selection_tick()
	# Desktop stand-in: Ctrl held = the resting finger; the left click is the second finger's tap.
	pw = me.sys("engines").power
	var k := InputEventKey.new()
	k.keycode = KEY_CTRL
	k.pressed = true
	Input.parse_input_event(k)
	await get_tree().process_frame
	check("  desktop: Ctrl held → − shown", tp.shows_minus(), true)
	tap(ec)
	check("  desktop: Ctrl + tap on engines = −1", me.sys("engines").power, pw - 1)
	k = k.duplicate()
	k.pressed = false
	Input.parse_input_event(k)
	await get_tree().process_frame
	check("  Ctrl up: + shown", tp.shows_minus(), false)
	main.combat.paused = false
	main._touch_selection_tick()


func _ready() -> void:
	Harness.run(self, _run)


## Own crew aboard the enemy ship (CombatControl::GetSelectedCrew on the TARGET view; CrewControl::RButton =
## the tap on a room): tap the boarder in the (touch-enlarged) TARGET window -> selection mode; tap another enemy
## room -> it walks there; also aboard a non-hostile ship (no hostile check in the exe). A tap on the boarder
## while a weapon is armed is a target click, not a selection (WeaponsArmed: CrewControl ignores the press).
func _boarders_on_enemy(enemy: ShipState) -> void:
	print("Own boarders on the enemy ship (TARGET window, touch scale): tap = select, tap a room = move")
	main.touch_cancel()
	main._board(enemy, 1)
	cc.update_roster()
	var boarder: CrewMember = cc.roster[cc.roster.size() - 1]
	check("boarder aboard the enemy, in the crew list", [enemy.crew.has(boarder), boarder.player_owned], [true, true])
	var er := -1
	for r in enemy.layout.rooms:
		if r.id != boarder.room and enemy.graph.find_slot(r.id, boarder) >= 0 \
				and enemy.graph.find_path(boarder.pos, boarder.room, r.id, boarder) != null:
			er = r.id
			break
	check("found a reachable enemy room", er >= 0, true)
	tap(scr(boarder))
	check("tap the boarder on the TARGET view selects it", sel(), [cc.roster.size() - 1])
	check("  selection mode (paused + CANCEL)", state(), [true, true, true])
	tap(empty_point(enemy, er))
	check("tap an enemy room: the boarder is ordered there", boarder.target_room, er)
	check("  result move, selection ended", [g.last_result, sel()], ["move", []])
	var ai: ShipAI = main.combat.ais[main.enemy_space]
	var was_hostile := ai.hostile
	ai.hostile = false
	main.combat._physics_process(1.0 / 60.0)  # ShipState.hostile follows the AI flag
	await get_tree().process_frame
	tap(scr(boarder))
	var back := boarder.room if boarder.room != er else -1
	if back < 0:
		for r in enemy.layout.rooms:
			if r.id != er and enemy.graph.find_slot(r.id, boarder) >= 0 \
					and enemy.graph.find_path(boarder.pos, boarder.room, r.id, boarder) != null:
				back = r.id
				break
	tap(empty_point(enemy, back))
	check("non-hostile enemy: the boarder still takes orders", [boarder.target_room, g.last_result], [back, "move"])
	ai.hostile = was_hostile
	main.combat._physics_process(1.0 / 60.0)
	# Weapon armed: the tap on the boarder targets (weapon priority), no crew selection.
	var w := -1
	for i in me.weapons.size():
		if me.weapons[i].powered:
			w = i
	if w >= 0:
		main.weapon_control.select(w)
		main._touch_selection_tick()
		tap(scr(boarder))
		check("weapon armed: tapping the boarder's room aims, does not select it",
			[sel(), me.weapons[w].target_ship == enemy], [[], true])
		main.touch_cancel()
		me.weapons[w].clear_target()
	main.touch_cancel()


func _run() -> void:
	FtlData.muted = true
	MAIN.input_mode = InputProfile.TOUCH
	get_tree().root.size = CANVAS  # stretch "expand": the phone canvas, as test_touch_layout
	main = load("res://main.tscn").instantiate()
	add_child(main)
	for i in 6:
		await get_tree().process_frame
	main.combat.paused = false
	me = main.player_space.ship
	cc = main.crew_control
	g = main._gestures()
	var crew := cc.roster
	var enemy: ShipState = main.enemy_space.ship
	main._touch_selection_tick()
	check("touch profile active", main._touch(), true)
	check("TooltipService in touch mode", TooltipService.touch, true)
	var tb: TouchCombatButtons = main.touch_buttons
	check("PAUSE / CANCEL buttons exist and are shown", tb != null and tb.visible, true)
	check("  idle: running, no selection mode, no CANCEL", state(), [false, false, false])
	var jump_x: float = main.command_hud.position.x + HudLayout.FTL_BASE.x * main.command_hud.scale.x
	check("  CANCEL at the JUMP button's x", tb.rect_of("cancel").position.x, roundf(jump_x))
	check("  bottom edge on the layout bottom", tb.rect_of("cancel").end.y, main._touch_height())
	check("  PAUSE left of CANCEL, same row", [tb.rect_of("pause").end.x < tb.rect_of("cancel").position.x,
		tb.rect_of("pause").position.y], [true, tb.rect_of("cancel").position.y])
	var target := free_room(me)
	var floor_pt := empty_point(me, target)
	var space_pt := space_point()
	check("found an empty-space point", space_pt.x >= 0, true)

	print("One finger: hover follows, no drag box; extra fingers ignored")
	var a := scr(crew[1])
	var b := scr(crew[2])
	_touch(0, a + Vector2(-12, -12), true)
	_move(b, MOUSE_BUTTON_MASK_LEFT)
	check("one-finger drag: no rectangle", cc.drag_rect(), Rect2())
	check("  hover follows the finger: crew 2 hovered", crew[2].hovered, true)
	var e1 := InputEventScreenTouch.new()
	e1.index = 1
	e1.position = a
	e1.pressed = true
	_push(e1)
	e1 = e1.duplicate()
	e1.pressed = false
	_push(e1)
	check("  second finger tap: nothing selected", sel(), [])
	_touch(0, b, false)
	check("  lift on crew 2 selects it", sel(), [2])
	main._touch_selection_tick()
	cc.deselect_all()
	main._touch_selection_tick()
	check("  deselected: mode over, running again", state(), [false, false, false])

	print("Crew: tap selects -> paused + CANCEL; tap a room moves -> unpaused")
	tap(scr(crew[0]))
	check("tap crew 0 selects it", sel(), [0])
	check("  auto-paused, selection mode, CANCEL shown", state(), [true, true, true])
	tap(scr(crew[1]))
	check("tap crew 1: selection switches", sel(), [1])
	check("  still in the mode", state(), [true, true, true])
	tap(floor_pt)
	check("tap a room: crew 1 ordered there", crew[1].target_room, target)
	check("  selection ended", sel(), [])
	check("  unpaused, CANCEL hidden", state(), [false, false, false])
	check("  result", g.last_result, "move")

	print("Crew: tap the selection again / empty space = cancel")
	tap(scr(crew[0]))
	tap(scr(crew[0]))
	check("tap the selected crew again: cancelled", [sel(), state()], [[], [false, false, false]])
	tap(scr(crew[0]))
	tap(space_pt)
	check("tap empty space: cancelled", [sel(), state(), g.last_result], [[], [false, false, false], "cancel"])

	print("CANCEL button")
	tap(scr(crew[0]))
	check("crew 0 selected, paused", [sel(), state()], [[0], [true, true, true]])
	var t0 := crew[0].target_room
	tap(tb.rect_of("cancel").get_center())
	check("CANCEL: selection dropped, unpaused, CANCEL hidden", [sel(), state()], [[], [false, false, false]])
	check("  no move order", crew[0].target_room, t0)
	tap(tb.rect_of("cancel").get_center())
	check("hidden CANCEL slot: a tap there is no button", main.combat.paused, false)

	print("PAUSE button; the player's pause is respected")
	tap(tb.rect_of("pause").get_center())
	check("PAUSE pauses (no selection mode)", state(), [true, false, false])
	check("  PAUSE drawn lit", tb.paused, true)
	tap(scr(crew[0]))
	check("select while player-paused: mode, still paused", state(), [true, true, true])
	var target2 := free_room(me, target)
	tap(empty_point(me, target2))
	check("move: crew 0 ordered", crew[0].target_room, target2)
	check("  mode over but the player's pause stays", state(), [true, false, false])
	tap(tb.rect_of("pause").get_center())
	check("PAUSE again resumes", state(), [false, false, false])
	tap(scr(crew[0]))
	check("auto-paused selection", state(), [true, true, true])
	tap(tb.rect_of("pause").get_center())
	check("PAUSE during the auto-pause: runs, mode kept", state(), [false, true, true])
	tap(space_pt)
	check("  cancel: stays running", state(), [false, false, false])

	print("Weapons: tap a powered weapon -> armed + paused; tap an enemy room -> targeted + unpaused")
	var wi := -1
	for i in me.weapons.size():
		if not me.weapons[i].is_beam():
			wi = i
			break
	check("a non-beam weapon", wi >= 0, true)
	var wc: WeaponControl = main.weapon_control
	var box: Control = main.weapon_panel.boxes[wi]
	var box_pt := box.get_global_rect().get_center()
	if not me.weapons[wi].powered:
		tap(box_pt)
		check("tap an unpowered weapon box powers it (no mode)", [me.weapons[wi].powered, state()],
			[true, [false, false, false]])
	tap(scr(crew[0]))
	tap(box_pt)
	check("tap the powered weapon box arms it", wc.armed, wi)
	check("  arming replaced the crew selection", sel(), [])
	check("  paused, mode, CANCEL", state(), [true, true, true])
	var er := -1
	for r in enemy.layout.rooms:
		er = r.id
		break
	tap(room_scr(enemy, er))
	check("tap an enemy room: weapon targets it", [me.weapons[wi].has_target(), me.weapons[wi].target_room],
		[true, er])
	check("  disarmed", wc.armed, -1)
	check("  unpaused", state(), [false, false, false])
	tap(box_pt)
	check("armed again", [wc.armed, state()], [wi, [true, true, true]])
	tap(room_scr(me, target))
	check("tap an own room: still armed (PC rule)", [wc.armed, state()], [wi, [true, true, true]])
	tap(space_pt)
	check("tap empty space: disarmed, unpaused", [wc.armed, state()], [-1, [false, false, false]])
	tap(box_pt)
	tap(tb.rect_of("cancel").get_center())
	check("CANCEL disarms", [wc.armed, state()], [-1, [false, false, false]])
	tap(box_pt)
	tap(cc.list_xf * cc.box_rect(0).get_center())  # crew list coordinates -> screen
	check("crew box tap while armed: disarm + select that crew", [wc.armed, sel(), state()],
		[-1, [0], [true, true, true]])
	main.touch_cancel()

	print("Systems armed (mind control flag) = selection mode too")
	me.mind_armed = true
	main._touch_selection_tick()
	check("mind armed: paused + CANCEL", state(), [true, true, true])
	tap(tb.rect_of("cancel").get_center())
	check("  CANCEL disarms it", [me.mind_armed, state()], [false, [false, false, false]])

	await _held_finger(crew)
	await _multi_select(crew)
	await _boarders_on_enemy(enemy)

	print("PC profile unchanged: left drag = box, right press = move order, no buttons")
	MAIN.input_mode = InputProfile.PC
	main._process(0.0)
	check("PC profile", main._touch(), false)
	a = scr(crew[1])
	b = scr(crew[2])
	var lo := Vector2(minf(a.x, b.x), minf(a.y, b.y)) - Vector2(12, 12)
	var hi := Vector2(maxf(a.x, b.x), maxf(a.y, b.y)) + Vector2(12, 12)
	_move(lo)
	_button(lo, MOUSE_BUTTON_LEFT, true)
	_move(lo + Vector2(5, 5))
	check("left drag 5,5: rectangle shown", cc.drag_rect().size, Vector2(5, 5))
	_move(hi)
	_button(hi, MOUSE_BUTTON_LEFT, false)
	check("  release: box selects crew 1, 2", sel(), [1, 2])
	main._process(0.0)
	check("  PC: selecting does not pause", main.combat.paused, false)
	var target3 := free_room(me)
	_move(room_scr(me, target3))
	_button(room_scr(me, target3), MOUSE_BUTTON_RIGHT, true)
	check("  right press = immediate move order", crew[1].target_room, target3)
	ctrl(true)
	await get_tree().process_frame
	_move(scr(crew[2]))
	_button(scr(crew[2]), MOUSE_BUTTON_LEFT, true)
	_button(scr(crew[2]), MOUSE_BUTTON_LEFT, false)
	check("  PC Ctrl + click crew 2: plain select (no toggle)", sel(), [2])
	ctrl(false)

	print("\n%s" % ("test_touch_gestures: ALL OK" if fails == 0 else "%d FAILURES" % fails))
