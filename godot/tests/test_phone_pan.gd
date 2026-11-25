extends Node

const Harness := preload("res://tests/harness.gd")
## Phone "pan" layout (main.gd `_touch_layout_phone_pan`, `phone_layout()`, GameOptions.phone_layout, Options
## "Phone Screen Layout"; NOTES.md "Phone pan layout") on the 1600 × 720 phone canvas, touch, `--device` sandbox
## (TEST_SHIP_MAX, combat+defense drones, harmless enemy), no `--phone-layout` / `--hud-scale` (the option drives
## the layout). Checks the layout (one bottom row, subsystems top right, stacked PAUSE / CANCEL in the right strip,
## TARGET at pan 1 clear of the HUD, player rooms clear of the HUD at pan 0), then taps at the DRAWN positions:
## weapons box power / arm / drag-swap / AUTOFIRE, drones box, systems column, doors, crew box, stations, + / −,
## PAUSE / CANCEL, crew select + move, pan arrows, enemy room targeting after panning, two-finger drag. Then
## runtime switching pan -> column -> pan (option) with leftover checks, the CLI override (`_phone_layout_cli`),
## and a tall (Fold) canvas, which ignores the phone option. Run:
##   godot --headless --path godot res://tests/test_phone_pan.tscn

const MAIN := preload("res://scripts/main.gd")
const PHONE := Vector2i(1600, 720)
const FOLD := Vector2i(1280, 1100)

var fails := 0
var main: Node
var me: ShipState
var en: ShipState
var cc: CrewControl


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func _push(e: InputEvent) -> void:
	get_viewport().push_input(e, true)


func _move(p: Vector2, mask := MOUSE_BUTTON_MASK_LEFT) -> void:
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


func tap(p: Vector2) -> void:
	_move(p)
	_button(p, MOUSE_BUTTON_LEFT, true)
	_button(p, MOUSE_BUTTON_LEFT, false)
	_move(p, 0)


func at(ci: CanvasItem, local: Vector2) -> Vector2:
	return ci.get_global_transform() * local


func frames(n := 4) -> void:
	for i in n:
		await get_tree().process_frame


func wait(s: float) -> void:
	await get_tree().create_timer(s).timeout
	await frames(2)


## A finger held at `p` for 0.7 s (past the old 0.5 s hold-to-depower), then lifted. Returns the tooltip kind
## shown while the finger rests (the CLI pointer: pushed events do not move the headless mouse).
func hold(p: Vector2) -> String:
	TooltipService.debug_pointer = p
	_move(p)
	_button(p, MOUSE_BUTTON_LEFT, true)
	await get_tree().create_timer(0.7).timeout
	await get_tree().process_frame
	var k := String(TooltipService.shown.get("kind", ""))
	_button(p, MOUSE_BUTTON_LEFT, false)
	_move(p, 0)
	TooltipService.debug_pointer = null
	await get_tree().process_frame
	return k


## Long press on the PC-style weapon and drone boxes (pan layouts): tooltip only, still powered (touch never
## depowers on a hold; the lift is the normal click: a powered weapon arms, a powered drone stays as it is).
func _long_press(title: String) -> void:
	print("Long press on the PC-style boxes (%s)" % title)
	var wp: WeaponPanel = main.weapon_panel
	var wc: WeaponControl = main.weapon_control
	var dp: DronePanel = main.drone_panel
	check("  PC-style boxes", [wp.vertical, dp.vertical], [false, false])
	var b0: WeaponBox = wp.boxes[0]
	if not me.weapons[0].powered:
		wc.select(0)
	var pw := me.weapons.filter(func(w): return w != null and w.powered).size()
	var k := await hold(at(b0, b0.size / 2))
	check("  hold weapon slot 1: still powered, tooltip shown", [me.weapons[0].powered,
		me.weapons.filter(func(w): return w != null and w.powered).size(), k], [true, pw, "weapon"])
	wc.disarm()
	main._touch_selection_tick()
	var db: DroneBox = dp.boxes[1]
	if not me.drones[1].powered:
		dp.toggle(1)
	var pd := powered_drones()
	k = await hold(at(db, db.size / 2))
	check("  hold drone slot 2: still powered, tooltip shown", [me.drones[1].powered, powered_drones(), k],
		[true, pd, "drone"])


func powered_drones() -> int:
	return me.drones.filter(func(d): return d != null and d.powered).size()


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	FtlData.muted = true
	get_tree().root.size = PHONE
	MAIN.input_mode = InputProfile.TOUCH
	MAIN._scenario_cli_done = true
	MAIN.player_ship_name = "TEST_SHIP_MAX"
	MAIN.harmless_enemy = true
	MAIN._set_drone_preset("combat+defense")
	MAIN._fold_layout_cli = ""
	MAIN._phone_layout_cli = ""
	MAIN.hud_scale_override = 0.0
	GameOptions.persist = false
	var saved_phone: String = GameOptions.phone_layout
	var saved_fold: String = GameOptions.fold_layout
	GameOptions.phone_layout = "pan"
	GameOptions.fold_layout = "split"
	main = load("res://main.tscn").instantiate()
	add_child(main)
	await frames(6)
	main.combat.paused = true
	me = main.player_space.ship
	en = main.enemy_space.ship
	cc = main.crew_control
	check("no CLI override: the option drives the phone layout", MAIN.phone_layout(), "pan")
	await _state("phone pan (option)", "phone_pan")
	await _pan_layout()
	await _weapons()
	await _drones()
	await _long_press("phone pan")
	await _systems()
	await _crew_hud()
	await _power_mode()
	await _pause_cancel()
	await _crew_move()
	await _panning()
	await _switch("column")
	await _state("column", "band")
	await _crew_move()
	await _enemy_target("band")
	await _switch("pan")
	await _state("phone pan again", "phone_pan")
	await _pan_layout()
	await _weapons()
	await _crew_move()
	await _enemy_target("phone_pan")
	print("\nCLI override: --phone-layout=column while the option says pan")
	main._pan_set(0.5)
	MAIN._phone_layout_cli = "column"
	await frames()
	await _state("CLI column", "band")
	MAIN._phone_layout_cli = ""
	await frames()
	await _state("CLI dropped: option pan", "phone_pan")
	print("\nFold canvas 1280 × 1100: the phone option does not apply (fold option split)")
	main._pan_set(0.5)
	get_tree().root.size = FOLD
	await frames()
	check("layout kind", main._touch_kind, "split")
	check("pan arrows hidden", main.pan_arrows.visible, false)
	check("box backing hidden", main._ppan_backing.visible, false)
	check("pan offset reset", main.pan_pos, 0.0)
	print("
Fold pan (option pan on the Fold canvas)")
	GameOptions.fold_layout = "pan"
	await frames()
	check("layout kind", main._touch_kind, "pan")
	await _long_press("fold pan")
	main._pan_set(0.5)
	GameOptions.fold_layout = "split"
	await frames()
	check("layout kind back", main._touch_kind, "split")
	get_tree().root.size = PHONE
	await frames()
	await _state("back to the phone canvas", "phone_pan")
	await _enemy_target("phone_pan")
	print("\n%s" % ("test_phone_pan: ALL OK" if fails == 0 else "%d FAILURES" % fails))
	GameOptions.phone_layout = saved_phone
	GameOptions.fold_layout = saved_fold
	MAIN.input_mode = InputProfile.PC
	MAIN._phone_layout_cli = ""


## Changes the option during combat (as the Options window does); the per-frame layout tick re-lays out. The pan
## position is moved first so the test sees it reset.
func _switch(to: String) -> void:
	print("\nOption -> %s" % to)
	if main._touch_kind == "phone_pan":
		main._pan_set(0.6)
	GameOptions.phone_layout = to
	await frames()


func _state(title: String, kind: String) -> void:
	print("\n== %s" % title)
	var vis: Vector2 = get_viewport().get_visible_rect().size
	check("canvas", vis, Vector2(PHONE))
	check("layout kind", main._touch_kind, kind)
	check("HUD ×1.2", [main.TOUCH_TOPLEFT_SCALE, main.TOUCH_SYSBAR_SCALE], [1.2, 1.2])
	check("player view not turned", main.player_space.fixed_rotation, 0.0)
	check("pan offset at the scene's left end", main.pan_pos, 0.0)
	check("backdrop parallax undone", main.space_backdrop.position.x, 0.0)
	check("no band offset", (main.hud_root.get_parent() as CanvasLayer).offset, Vector2.ZERO)
	var pan := kind == "phone_pan"
	check("pan arrows shown only in pan", main.pan_arrows != null and main.pan_arrows.visible, pan)
	check("box backing shown only in pan", main._ppan_backing != null and main._ppan_backing.visible, pan)
	var wp: WeaponPanel = main.weapon_panel
	var dp: DronePanel = main.drone_panel
	check("panel kinds (weapons, drones vertical)", [wp.vertical, dp.vertical], [not pan, not pan])
	check("bar's drones power column shown with the PC drones box", main.systems_bar.columns["drones"].visible, pan)
	var ew: EnemyWindow = main.enemy_window
	var s: float = ew.scale.x
	var art := Rect2(ew.position + (HudLayout.ENEMY_FRAME.position + MAIN.TOUCH_ENEMY_ART.position) * s,
		MAIN.TOUCH_ENEMY_ART.size * s)
	check("TARGET window shown", ew.visible, true)
	var sub := snappedf(main.systems_bar.sub_group.get_global_transform().get_scale().x, 0.001)
	if pan:
		var xf: Transform2D = main._pan_scene.xf
		check("TARGET window = the scene's window at pan 0", [s, ew.position], [xf.get_scale().x, xf.origin])
		check("subsystems ×1 (k × 5/6)", sub, 1.0)
		check("enemy space inside its window", ew.get_global_rect().encloses(main.enemy_space.get_global_rect()
			.grow(-1.0)), true)
	else:
		check("TARGET art flush with the right edge", roundf(art.end.x), vis.x)
		check("subsystems back to the bar's scale", sub, 1.2)
		check("pause text at its frame place", [main.pause_overlay.scale, main.pause_overlay.position],
			[Vector2.ONE, Vector2.ZERO])
		check("top buttons at the frame origin", main.command_hud.position, Vector2.ZERO)
		check("systems bar at the frame (pivot bottom-left)", [main.systems_bar.position,
			main.systems_bar.pivot_offset], [Vector2.ZERO, Vector2(0, HudLayout.FRAME.y)])
	await _weapon_tap()
	await _pause_tap()


func _weapon_tap() -> void:
	var wp: WeaponPanel = main.weapon_panel
	var wc: WeaponControl = main.weapon_control
	var b0: WeaponBox = wp.boxes[0]
	for i in me.weapons.size():
		wc.depower(i)
	tap(at(b0, b0.size / 2))
	check("tap weapon slot 1: powered", me.weapons[0].powered, true)
	tap(at(b0, b0.size / 2))
	check("tap again: armed", wc.armed, 0)
	wc.disarm()
	main._touch_selection_tick()


func _pause_tap() -> void:
	var tb: TouchCombatButtons = main.touch_buttons
	main.combat.paused = false
	main._touch_selection_tick()
	var pr: Rect2 = tb.rect_of("pause")
	check("PAUSE inside the layout's rect", main._touch_pause_at.grow(1.0).encloses(pr), true)
	tap(pr.get_center())
	check("tap PAUSE: paused", main.combat.paused, true)
	main.combat.paused = true
	main._touch_selection_tick()


## Holder solid rect (the PC holder image: border x 10 .. w − 7, y 10 .. 60) of a PC box, canvas.
func _holder(p: Control) -> Rect2:
	var k := p.scale.x
	return Rect2(p.position + Vector2(10, 10) * k, Vector2(p.size.x - 17, 50) * k)


func _pan_layout() -> void:
	print("Phone pan layout")
	var vis: Vector2 = get_viewport().get_visible_rect().size
	var screen := Rect2(Vector2.ZERO, vis)
	var wp: WeaponPanel = main.weapon_panel
	var dp: DronePanel = main.drone_panel
	var wh := _holder(wp)
	var dh := _holder(dp)
	check("weapons + drones boxes ×1.2", [snappedf(wp.scale.x, 0.001), snappedf(dp.scale.x, 0.001)], [1.2, 1.2])
	check("one bottom row: drones right of the weapons", dh.position.x > wh.end.x, true)
	check("  both on the canvas", [screen.encloses(wp.get_global_rect()), screen.encloses(dp.get_global_rect())],
		[true, true])
	var bar_xf: Transform2D = main.systems_bar.get_global_transform()
	check("  weapons right of the reactor", wp.position.x > (bar_xf * Vector2(HudLayout.REACTOR_X, 0)).x, true)
	var tb: TouchCombatButtons = main.touch_buttons
	check("PAUSE / CANCEL stacked", tb.stacked, true)
	# (×1.5 it reaches over the drones box's right end: glued on it, above its solid border.)
	check("  pair on the canvas, not over the drones box", [screen.encloses(main._touch_pause_at),
		main._touch_pause_at.end.x <= dh.end.x or main._touch_pause_at.end.y <= dh.position.y + 1.0], [true, true])
	check("  ×1.5 the HUD scale (TOUCH_PAUSE_BASE)", absf(main._touch_pause_at.size.x
		- TouchCombatButtons.BASE_SIZE.x * MAIN.TOUCH_PAUSE_BASE * main.command_hud.scale.x) <= 0.5, true)
	var cl: CrewList = main.crew_list
	check("two stations buttons", cl.touch_station_rects.size(), 2)
	for i in cl.touch_station_rects.size():
		var r: Rect2 = cl.touch_station_rects[i]
		var cr := Rect2(at(cl, r.position), r.size * cl.scale.x)
		check("  station %d: 60 × 60 in the bottom-right corner" % i, [cr.size.round(), cr.end.y <= vis.y,
			cr.position.x > dh.end.x], [Vector2(60, 60), true, true])
	var arrows: Control = main.pan_arrows
	var ar: Rect2 = arrows.rect_of("right")
	var al: Rect2 = arrows.rect_of("left")
	check("arrows on the canvas, not overlapping", [screen.encloses(ar), screen.encloses(al), ar.intersects(al)],
		[true, true, false])
	check("  arrows clear of PAUSE / CANCEL", ar.intersects(main._touch_pause_at) or al.intersects(main._touch_pause_at),
		false)
	# Player rooms at pan 0 clear of every HUD piece: a finger on the room's centre / corners reaches the ship view
	# (the GUI control under it is the Space; _over_hud_panel is not used: ShipStatusHud's tooltip zone is the whole
	# PC frame corner, wider than its art).
	var covered := []
	for r in me.layout.rooms:
		var rr := me.room_rect(r.id)
		for c in [rr.get_center(), rr.position + Vector2(4, 4), rr.end - Vector2(4, 4)]:
			var p: Vector2 = main.world_to_screen(me, c)
			_move(p)
			var hov := get_viewport().gui_get_hovered_control()
			if not screen.has_point(p) or not hov is Space or main._touch_pause_at.has_point(p) 					or ar.has_point(p) or al.has_point(p):
				print("    room %d point %s: hovered %s" % [r.id, p, hov])
				covered.append(r.id)
				break
	_move(Vector2(-10, -10), 0)
	check("pan 0: every player room on the canvas and clear of the HUD", covered, [])
	check("ship ×1.75 (column layout: ×1.375)", main.touch_ship_zoom, 1.75)
	# TARGET at pan 1: on the canvas, clear of the top buttons / subsystems / boxes / PAUSE.
	main._pan_set(1.0)
	var ew: EnemyWindow = main.enemy_window
	var s: float = ew.scale.x
	var art := Rect2(ew.position + (HudLayout.ENEMY_FRAME.position + MAIN.TOUCH_ENEMY_ART.position) * s,
		MAIN.TOUCH_ENEMY_ART.size * s)
	check("pan 1: TARGET art on the canvas", screen.encloses(art), true)
	check("  ×1 for TEST_SHIP_MAX", s, 1.0)
	check("  clear of PAUSE / CANCEL, arrows and the boxes", [art.intersects(main._touch_pause_at),
		art.intersects(ar), art.intersects(wh), art.intersects(dh)], [false, false, false, false])
	var menu_r: float = (main.command_hud.menu_rect().position.x + 47.0) * 1.2
	check("  right of the MENU wrench (top row free there)", art.position.x > menu_r, true)
	var sub_r: Rect2 = main.systems_bar.sub_group.get_global_rect()
	var sb_l := INF
	for id in main.systems_bar.sub_ids:
		sb_l = minf(sb_l, (main.systems_bar.columns[id] as Control).get_global_rect().position.x)
	check("  left of the subsystems", art.end.x <= sb_l, true)
	main._pan_set(0.0)


func _weapons() -> void:
	print("Weapons PC box (×1.2)")
	var wp: WeaponPanel = main.weapon_panel
	var wc: WeaponControl = main.weapon_control
	var b0: WeaponBox = wp.boxes[0]
	var b1: WeaponBox = wp.boxes[1]
	var w0 := me.weapons[0]
	var w1 := me.weapons[1]
	var p := at(b0, Vector2(20, 20))
	var q := at(b1, Vector2(20, 20))
	_move(p)
	_button(p, MOUSE_BUTTON_LEFT, true)
	_move(p + Vector2(15, 3))
	_move(q)
	check("drag slot 1 onto slot 2: swapped", [me.weapons[0], me.weapons[1]], [w1, w0])
	_button(q, MOUSE_BUTTON_LEFT, false)
	_move(q, 0)
	wc.swap(0, 1)
	wc.disarm()
	main._touch_selection_tick()
	var af: Control = wp.autofire_btn
	var auto := me.autofire
	tap(at(af, af.size / 2))
	check("AUTOFIRE tap toggles", me.autofire, not auto)
	me.autofire = auto


func _drones() -> void:
	print("Drones PC box (×1.2)")
	var dp: DronePanel = main.drone_panel
	for i in me.drones.size():
		dp.depower(i)
	var b: DroneBox = dp.boxes[1]
	tap(at(b, b.size / 2))
	check("tap drone slot 2: powered", me.drones[1].powered, true)
	check("one drone powered", powered_drones(), 1)
	var col: SystemPowerColumn = main.systems_bar.columns["drones"]
	check("drones power column drawn left of its box", at(col, col.hit_rect().get_center()).x
		< dp.get_global_rect().position.x + 12, true)


func _systems() -> void:
	print("Systems bar (×1.2) and subsystems (×1, top right)")
	var sb: SystemsBar = main.systems_bar
	var col: SystemPowerColumn = sb.columns["shields"]
	while me.sys("shields").power > 0:
		me.decrease_power("shields")
	tap(at(col, col.click_rect().get_center()))
	check("tap shields column: powered", me.sys("shields").power > 0, true)
	var pc: SystemPowerColumn = sb.columns["pilot"]
	var pp := at(pc, pc.hit_rect().get_center())
	check("pilot column in the top-right corner", [pp.x > 1300, pp.y < 140], [true, true])
	check("_over_hud_panel on the subsystem", main._over_hud_panel(pp), true)
	var db: Control = sb.buttons["doors"]
	me.manipulate_all_doors(false)
	tap(at(db, Vector2(20, 43)))
	check("doors button lower half: doors open", me.env.doors.any(func(d): return d.open), true)
	tap(at(db, Vector2(20, 20)))
	check("doors button upper half: closed", me.env.doors.any(func(d): return d.open and not d.airlock), false)


func _crew_hud() -> void:
	print("Crew list and the stations buttons")
	var cl: CrewList = main.crew_list
	cc.deselect_all()
	tap(at(cl, cc.box_rect(1).get_center()))
	check("tap crew box 2: selected", cc.selected_crew(), [cc.roster[1]])
	cc.deselect_all()
	main._touch_selection_tick()
	cc.message_time = 0.0
	tap(at(cl, (cl.touch_station_rects[0] as Rect2).get_center()))
	check("tap SAVE stations (bottom-right corner)", cc.message_time > 0.0, true)


func _power_mode() -> void:
	print("Power toggle (+ / −, by the subsystems)")
	var tp: TouchPowerToggle = main.touch_power
	check("toggle shown", tp != null and tp.is_visible_in_tree(), true)
	if tp == null:
		return
	var col: SystemPowerColumn = main.systems_bar.columns["engines"]
	var sc := at(col, col.click_rect().get_center())
	tap(at(tp, TouchPowerToggle.SLOT_MINUS.get_center()))
	check("tap −: − mode", tp.minus, true)
	while me.sys("engines").power < 2:
		me.increase_power("engines")
	var e := me.sys("engines").power
	tap(sc)
	check("− mode: engines −1", me.sys("engines").power, e - 1)
	tap(at(tp, TouchPowerToggle.SLOT_PLUS.get_center()))
	check("tap +: + mode", tp.minus, false)


func _pause_cancel() -> void:
	print("PAUSE / CANCEL (stacked) and the pause text")
	var tb: TouchCombatButtons = main.touch_buttons
	var wc: WeaponControl = main.weapon_control
	if not me.weapons[0].powered:
		wc.select(0)
	wc.select(0)
	main._touch_selection_tick()
	check("weapon armed: CANCEL shown", [wc.armed, tb.cancel_shown], [0, true])
	var pr: Rect2 = tb.rect_of("pause")
	var cr: Rect2 = tb.rect_of("cancel")
	check("CANCEL right above PAUSE", [cr.position.x == pr.position.x, cr.end.y < pr.position.y], [true, true])
	check("pause text ×1.2, above the weapons box", [snappedf(main.pause_overlay.scale.x, 0.001),
		main.pause_overlay.position.y < main.weapon_panel.position.y], [1.2, true])
	tap(cr.get_center())
	check("tap CANCEL: disarmed", wc.armed, -1)
	main.combat.paused = true
	main._touch_selection_tick()


func _crew_move() -> void:
	cc.deselect_all()
	var c: CrewMember = null
	for m in cc.roster:
		if not main._over_hud_panel(main.world_to_screen(me, m.pos)):
			c = m
			break
	check("a crew member clear of the HUD", c != null, true)
	if c == null:
		return
	tap(main.world_to_screen(me, c.pos))
	check("tap crew sprite: selected", cc.selected_crew(), [c])
	var target := -1
	var rp := Vector2.ZERO
	for r in me.layout.rooms:
		var used := false
		for m in me.crew:
			if m.room == r.id or m.target_room == r.id:
				used = true
		var p: Vector2 = main.world_to_screen(me, me.room_rect(r.id).get_center())
		var w: Variant = cc.locate(me, p)
		if not used and not main._over_hud_panel(p) and w != null and me.room_at(w) == r.id:
			target = r.id
			rp = p
			break
	check("a free room clear of the HUD", target >= 0, true)
	if target < 0:
		cc.deselect_all()
		return
	tap(rp)
	check("tap a room: move order", c.target_room, target)
	cc.deselect_all()
	main._touch_selection_tick()


## Right arrow -> animated pan to the enemy end; target an enemy room; two-finger drag back; left arrow -> pan 0.
func _panning() -> void:
	print("Panning: arrows, targeting after the pan, two-finger drag")
	var arrows: Control = main.pan_arrows
	check("scene wider than the canvas", main._pan_range > 0.0, true)
	tap(arrows.rect_of("right").get_center())
	await wait(0.5)
	check("tap the right arrow: pan 1", main.pan_pos, 1.0)
	await _enemy_target("phone_pan", false)
	var r: float = main._pan_range
	var p0 := Vector2(700, 300)
	var p1 := Vector2(800, 330)
	for i in 2:
		var t := InputEventScreenTouch.new()
		t.index = i
		t.pressed = true
		t.position = p0 if i == 0 else p1
		_push(t)
	for i in 2:
		var d := InputEventScreenDrag.new()
		d.index = i
		d.position = (p0 if i == 0 else p1) + Vector2(100, 0)
		d.relative = Vector2(100, 0)
		_push(d)
	for i in 2:
		var t := InputEventScreenTouch.new()
		t.index = i
		t.pressed = false
		t.position = (p0 if i == 0 else p1) + Vector2(100, 0)
		_push(t)
	await frames(2)
	check("two-finger drag 100 px right: pan back by 100 px", snappedf(main.pan_pos, 0.001),
		snappedf(1.0 - 100.0 / r, 0.001))
	check("  no crew order / selection from the fingers", cc.selected_crew(), [])
	tap(arrows.rect_of("left").get_center())
	await wait(0.5)
	check("tap the left arrow: pan 0", main.pan_pos, 0.0)
	main.combat.paused = true
	main._touch_selection_tick()


func _enemy_target(kind: String, pan_first := true) -> void:
	var wc: WeaponControl = main.weapon_control
	var wi := -1
	for i in me.weapons.size():
		var w := me.weapons[i]
		if w != null and not w.is_beam() and int(w.bp.get("radius", 0)) == 0:
			wi = i
			break
	if kind == "phone_pan" and pan_first:
		tap(main.pan_arrows.rect_of("right").get_center())
		await wait(0.5)
		check("arrow tap: pan 1", main.pan_pos, 1.0)
	me.weapons[wi].clear_target()
	if not me.weapons[wi].powered:
		wc.select(wi)
	wc.select(wi)
	check("weapon armed", wc.armed, wi)
	var room: int = en.sys("shields").room
	var p: Vector2 = main.world_to_screen(en, en.room_rect(room).get_center())
	check("enemy room inside the TARGET view", main.enemy_space.get_global_rect().has_point(p), true)
	check("  on the canvas", Rect2(Vector2.ZERO, get_viewport().get_visible_rect().size).has_point(p), true)
	tap(p)
	check("tap enemy shields room: targeted", [me.weapons[wi].target_ship == en, me.weapons[wi].target_room],
		[true, room])
	wc.disarm()
	main.combat.paused = true
	main._touch_selection_tick()
	if kind == "phone_pan" and pan_first:
		main._pan_set(0.0)
