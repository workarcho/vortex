extends Node

const Harness := preload("res://tests/harness.gd")
## Open-Fold "split" layout, frozen form (`--fold-layout=split --hud-scale=1.5`, canvas 1280 × 1100; main.gd
## `_touch_layout_split`, `TOUCH_SPLIT_FROZEN`, NOTES.md "Fold layout variants"): every piece takes its taps /
## tooltips where it is drawn, and the player ship, turned to face up (camera PI / 2), hit-tests its rooms, crew
## and doors through the rotation. Synthetic mouse events at the DRAWN positions (each component's canvas
## transform / Space.viewport canvas transform). `--device` sandbox (TEST_SHIP_MAX, combat+defense drones, harmless
## enemy). Run:
##   godot --headless --path godot res://tests/test_fold_split.tscn

const MAIN := preload("res://scripts/main.gd")
const CANVAS := Vector2i(1280, 1100)

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


## A finger held at `p` for 0.7 s (past the old 0.5 s hold-to-depower), then lifted. Returns the tooltip kind
## shown while the finger rests (touch: the long press is the tooltip only). The pointer is the CLI pointer (pushed
## events do not move the headless mouse; see tip_at).
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


func tip_at(p: Vector2) -> Array:
	TooltipService.debug_pointer = p
	await get_tree().process_frame
	await get_tree().process_frame
	var r := [String(TooltipService.kind), TooltipService.ctx.duplicate()]
	TooltipService.debug_pointer = null
	await get_tree().process_frame
	return r


func at(ci: CanvasItem, local: Vector2) -> Vector2:
	return ci.get_global_transform() * local


func powered_weapons() -> int:
	return me.weapons.filter(func(w): return w != null and w.powered).size()


func powered_drones() -> int:
	return me.drones.filter(func(d): return d != null and d.powered).size()


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	FtlData.muted = true
	get_tree().root.size = CANVAS
	MAIN.input_mode = InputProfile.TOUCH
	MAIN._scenario_cli_done = true
	MAIN.player_ship_name = "TEST_SHIP_MAX"
	MAIN.harmless_enemy = true
	MAIN._set_drone_preset("combat+defense")
	MAIN._fold_layout_cli = "split"
	MAIN.hud_scale_override = 1.5
	main = load("res://main.tscn").instantiate()
	add_child(main)
	for i in 6:
		await get_tree().process_frame
	main.combat.paused = true
	me = main.player_space.ship
	en = main.enemy_space.ship
	cc = main.crew_control
	await _layout()
	await _weapons()
	await _drones()
	await _systems()
	await _crew_hud()
	await _power_mode()
	await _pause_cancel()
	await _top_left()
	await _enemy()
	await _player_ship()
	await _intruder_msg()
	await _rebuild_toggle()
	await _no_enemy_corner()
	print("\n%s" % ("test_fold_split: ALL OK" if fails == 0 else "%d FAILURES" % fails))
	MAIN.input_mode = InputProfile.PC
	MAIN._fold_layout_cli = ""
	MAIN.hud_scale_override = 0.0


## No enemy (TARGET window hidden): the crew stations buttons stay in the TARGET window's corner.
func _no_enemy_corner() -> void:
	print("No enemy: stations buttons stay")
	var cl: CrewList = main.crew_list
	var before: Array = cl.touch_station_rects.duplicate()
	main.victory_shown = true
	main.enemy_window.visible = false
	main.enemy_space.visible = false
	await get_tree().process_frame
	await get_tree().process_frame
	check("layout without the TARGET window", main._touch_enemy_present(), false)
	check("stations buttons at the same place", cl.touch_station_rects, before)
	main.victory_shown = false
	main.enemy_window.visible = true
	main.enemy_space.visible = true
	await get_tree().process_frame
	await get_tree().process_frame
	check("enemy back: same place", cl.touch_station_rects, before)


## INTRUDERS DETECTED (CommandHud, PC frame (730, 210)) follows the player ship: centred over its rooms, clear of
## the crew list and left of the TARGET art (the PC place ×1.5 would be on the TARGET window).
func _intruder_msg() -> void:
	print("Intruder warning over the player ship")
	await get_tree().process_frame
	var ch: CommandHud = main.command_hud
	check("touch: moved off the PC place", ch.intruder_msg_at != Vector2.INF, true)
	var c: Vector2 = ch.get_global_transform() * ch.intruder_msg_at
	var half: float = FtlData.ftl_text_width(52, HudDraw.txt("warning_intruders")) * main.TOUCH_TOPLEFT_SCALE / 2.0
	var art_l: float = (main.enemy_window.get_global_transform() * (HudLayout.ENEMY_FRAME.position
		+ MAIN.TOUCH_ENEMY_ART.position)).x
	check("text right edge left of the TARGET art", c.x + half <= art_l, true)
	var n := cc.roster.size()
	var crew_r: float = (main.crew_list.get_global_transform() * cc.box_rect(0).merge(cc.box_rect(n - 1))).end.x
	check("text left edge right of the crew list", c.x - half >= crew_r, true)
	var pc: float = (ch.get_global_transform() * HudLayout.INTRUDER_MSG).x
	check("the PC place ×1.5 is on the TARGET art (why it moved)", pc > art_l, true)


## A location rebuild (run mode: every arrival, every new event ship) replaces the HUD: the + / − toggle must be
## the new HUD's (it used to keep the queued-for-deletion one and vanish until the next relayout).
func _rebuild_toggle() -> void:
	print("Power toggle after a scene rebuild")
	main._rebuild()
	for i in 3:
		await get_tree().process_frame
	var tp: TouchPowerToggle = main.touch_power
	check("toggle alive, in the tree, shown", [is_instance_valid(tp), is_instance_valid(tp) and tp.is_inside_tree(),
		is_instance_valid(tp) and tp.visible, TouchPowerToggle.live()], [true, true, true, true])


func _layout() -> void:
	print("Frozen split layout")
	check("canvas", get_viewport().get_visible_rect().size, Vector2(CANVAS))
	check("split + frozen", [main._touch_split(), main._touch_split_frozen()], [true, true])
	check("HUD ×1.5", [main.TOUCH_TOPLEFT_SCALE, main.TOUCH_SYSBAR_SCALE], [1.5, 1.5])
	check("player view turned PI / 2", main.player_space.fixed_rotation, PI / 2)
	check("ShipView upright = the rotation", main.player_space.view.upright, PI / 2)
	check("TARGET ×21/16", main.enemy_window.scale.x, 21.0 / 16.0)
	check("PC weapons box, vertical drones column", [main.weapon_panel.vertical, main.drone_panel.vertical],
		[false, true])
	check("weapons box ×1.5 at its frozen slot", [main.weapon_panel.scale.x, main.weapon_panel.position],
		[1.5, Vector2(652, 962)])
	check("drones column at its frozen slot", main.drone_panel.position, Vector2(613, 249))
	var tb: TouchCombatButtons = main.touch_buttons
	check("PAUSE / CANCEL stacked", tb != null and tb.stacked, true)


func _weapons() -> void:
	print("Weapons PC box (×1.5)")
	var wp: WeaponPanel = main.weapon_panel
	var wc: WeaponControl = main.weapon_control
	var b0: WeaponBox = wp.boxes[0]
	var b1: WeaponBox = wp.boxes[1]
	for i in me.weapons.size():
		wc.depower(i)
	tap(at(b0, b0.size / 2))
	check("tap slot 1: powered", me.weapons[0].powered, true)
	tap(at(b0, b0.size / 2))
	check("tap again: armed", wc.armed, 0)
	wc.disarm()
	check("slot tooltip", (await tip_at(at(b1, b1.size / 2)))[0], "weapon")
	check("_over_hud_panel on the box", main._over_hud_panel(at(b1, b1.size / 2)), true)
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
	var af: Control = wp.autofire_btn
	var auto := me.autofire
	tap(at(af, af.size / 2))
	check("AUTOFIRE tap toggles", me.autofire, not auto)
	me.autofire = auto
	var col: SystemPowerColumn = wp.column
	check("weapons power column tooltip", (await tip_at(at(col, col.hit_rect().get_center())))[0], "system")
	# Long press on the PC-style box: tooltip only, never a depower (touch); the lift is the normal click (arm).
	if not me.weapons[0].powered:
		wc.select(0)
	var pw := powered_weapons()
	var k := await hold(at(b0, b0.size / 2))
	check("long press slot 1: still powered, tooltip shown (lift = click: armed)", [me.weapons[0].powered,
		powered_weapons(), k, wc.armed], [true, pw, "weapon", 0])
	wc.disarm()
	# PC (no touch power toggle in the tree): no hold-to-depower either (vanilla has none); the lift clicks (arm).
	var tp: TouchPowerToggle = main.touch_power
	check("touch power toggle live", TouchPowerToggle.live(), true)
	var tp_parent := tp.get_parent()
	var tp_at := tp.get_index()
	tp_parent.remove_child(tp)
	await hold(at(b0, b0.size / 2))
	check("no touch toggle (PC rule): hold slot 1 = still powered (lift = click: armed)", [me.weapons[0].powered,
		powered_weapons(), wc.armed], [true, pw, 0])
	tp_parent.add_child(tp)
	tp_parent.move_child(tp, tp_at)
	wc.disarm()


func _drones() -> void:
	print("Drones column (vertical, ×1.5)")
	var dp: DronePanel = main.drone_panel
	for i in me.drones.size():
		dp.depower(i)
	var b: DroneBox = dp.boxes[1]
	tap(at(b, b.size / 2))
	check("tap drone slot 2: powered", me.drones[1].powered, true)
	check("drone slot tooltip", (await tip_at(at(b, b.size / 2)))[0], "drone")
	var k := await hold(at(b, b.size / 2))
	check("long press drone slot 2: still powered, tooltip shown", [me.drones[1].powered, powered_drones(), k],
		[true, 1, "drone"])
	var rc := at(dp.power_hit, dp.power_hit.size / 2)
	tap(rc)
	check("tap power row: one more drone", powered_drones(), 2)
	check("power row tooltip", (await tip_at(rc))[0], "system")


func _systems() -> void:
	print("Systems bar (×1.5) and subsystems (×1.25)")
	var sb: SystemsBar = main.systems_bar
	var col: SystemPowerColumn = sb.columns["shields"]
	while me.sys("shields").power > 0:
		me.decrease_power("shields")
	var c := at(col, col.click_rect().get_center())
	tap(c)
	check("tap shields column: powered", me.sys("shields").power > 0, true)
	check("shields column tooltip", (await tip_at(c))[0], "system")
	var rr := Vector2(HudLayout.REACTOR_X + HudLayout.REACTOR_BAR.x / 2, HudLayout.REACTOR_BOTTOM - 4)
	check("reactor tooltip", (await tip_at(at(sb, rr)))[0], "reactor")
	check("subsystems ×1.25", snappedf(sb.sub_group.get_global_transform().get_scale().x, 0.001), 1.25)
	var pc: SystemPowerColumn = sb.columns["pilot"]
	var pp := at(pc, pc.hit_rect().get_center())
	check("pilot tooltip at its drawn place", (await tip_at(pp))[0], "system")
	check("_over_hud_panel on the subsystem", main._over_hud_panel(pp), true)
	check("subsystems box tooltip", (await tip_at(at(sb.sub_group, HudLayout.SUBSYSTEMS + Vector2(80, 64))))[0],
		"subsystems")
	var db: Control = sb.buttons["doors"]
	me.manipulate_all_doors(false)
	tap(at(db, Vector2(20, 43)))
	check("doors button lower half: doors open", me.env.doors.any(func(d): return d.open), true)
	tap(at(db, Vector2(20, 20)))
	check("doors button upper half: closed", me.env.doors.any(func(d): return d.open and not d.airlock), false)


func _crew_hud() -> void:
	print("Crew list (×1.5) and the stations buttons")
	var cl: CrewList = main.crew_list
	cc.deselect_all()
	var p := at(cl, cc.box_rect(1).get_center())
	tap(p)
	check("tap crew box 2: selected", cc.selected_crew(), [cc.roster[1]])
	check("crew box tooltip", (await tip_at(p))[0], "crew_box")
	cc.deselect_all()
	check("stations buttons in the TARGET corner", cl.touch_station_rects.size(), 2)
	var sr: Rect2 = cl.touch_station_rects[0]
	var sp := at(cl, sr.get_center())
	var art: Rect2 = main.enemy_window.get_global_rect()
	check("  inside the TARGET window", art.has_point(sp), true)
	cc.message_time = 0.0
	tap(sp)
	check("tap SAVE stations", cc.message_time > 0.0, true)
	check("stations tooltip", (await tip_at(at(cl, (cl.touch_station_rects[1] as Rect2).get_center())))[0],
		"button")


func _power_mode() -> void:
	print("Power toggle (+ / −, ×1.25)")
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
	check("toggle tooltip", (await tip_at(at(tp, TouchPowerToggle.SLOT_PLUS.get_center())))[0], "button")


func _pause_cancel() -> void:
	print("PAUSE / CANCEL (stacked)")
	var tb: TouchCombatButtons = main.touch_buttons
	main._touch_selection_tick()
	var pr: Rect2 = tb.rect_of("pause")
	var cr: Rect2 = tb.rect_of("cancel")
	check("CANCEL right above PAUSE", [cr.position.x == pr.position.x, cr.end.y < pr.position.y], [true, true])
	check("pair inside the layout's PAUSE rect", main._touch_pause_at.grow(1.0).encloses(pr.merge(cr)), true)
	check("×1.5 the top group's scale (TOUCH_PAUSE_BASE)", pr.size.round(),
		(TouchCombatButtons.BASE_SIZE * MAIN.TOUCH_PAUSE_BASE * main.TOUCH_TOPLEFT_SCALE).round())
	var was: bool = main.combat.paused
	tap(pr.get_center())
	check("tap PAUSE toggles the pause", main.combat.paused, not was)
	main.combat.paused = true
	var wc: WeaponControl = main.weapon_control
	if not me.weapons[0].powered:
		wc.select(0)
	wc.select(0)
	main._touch_selection_tick()
	check("weapon armed: CANCEL shown", [wc.armed, tb.cancel_shown], [0, true])
	tap(tb.rect_of("cancel").get_center())
	check("tap CANCEL: disarmed", wc.armed, -1)
	main.combat.paused = true
	main._touch_selection_tick()


func _top_left() -> void:
	print("Top-left block (×1.5) and top buttons")
	var st: ShipStatusHud = main.ship_status
	check("hull tooltip", (await tip_at(at(st, Vector2(150, 25))))[1].get("id", ""), "tooltip_hull")
	check("evade tooltip", (await tip_at(at(st, Vector2(50, 106) + st.evade_offset)))[1].get("id", ""),
		"tooltip_evadeDisplay")
	var ch: CommandHud = main.command_hud
	check("FTL JUMP: drawn point maps into FTL_JUMP_HIT", MAIN.FTL_JUMP_HIT.has_point(
		ch.hud_point(at(ch, MAIN.FTL_JUMP_HIT.get_center()))), true)
	check("MENU tooltip", (await tip_at(at(ch, ch.menu_rect().get_center())))[0], "button")
	tap(at(ch, ch.menu_rect().get_center()))
	check("tap MENU: menu open", main.pause_menu.visible, true)
	main.pause_menu.visible = false
	main._menu_paused = false
	main.combat.paused = true


func _enemy() -> void:
	print("TARGET window (×21/16)")
	var wc: WeaponControl = main.weapon_control
	var wi := -1
	for i in me.weapons.size():
		var w := me.weapons[i]
		if w != null and not w.is_beam() and int(w.bp.get("radius", 0)) == 0:
			wi = i
			break
	if not me.weapons[wi].powered:
		wc.select(wi)
	wc.select(wi)
	var room: int = en.sys("shields").room
	var p: Vector2 = main.world_to_screen(en, en.room_rect(room).get_center())
	check("enemy room inside the TARGET view", main.enemy_space.get_global_rect().has_point(p), true)
	tap(p)
	check("tap enemy shields room: targeted", [me.weapons[wi].target_ship == en, me.weapons[wi].target_room],
		[true, room])
	wc.disarm()
	if me.sys("hacking") != null:
		me.hack_armed = true
		check("hacking aim over the enemy system room: hack_potential", (await tip_at(p))[0], "aim_block")
		me.hack_armed = false
	var ew: EnemyWindow = main.enemy_window
	if not ew.system_boxes().is_empty():
		var e: Array = ew.system_boxes()[0]
		check("enemy system box tooltip", (await tip_at(at(ew, e[1] + Vector2(32, 24))))[0], "system_enemy")
	for m in en.crew:
		if m.is_alive():
			check("enemy crew tooltip", (await tip_at(main.world_to_screen(en, m.pos)))[0], "crew_room")
			break


func _player_ship() -> void:
	print("Player ship, turned to face up")
	var z: float = main.touch_ship_zoom
	var w0 := me.room_rect(me.layout.rooms[0].id).get_center()
	var a: Vector2 = main.world_to_screen(me, w0)
	var b: Vector2 = main.world_to_screen(me, w0 + Vector2(10, 0))
	var d: Vector2 = main.world_to_screen(me, w0 + Vector2(0, 10))
	check("world +x -> canvas up", (b - a).round(), Vector2(0, -10 * z).round())
	check("world +y -> canvas right", (d - a).round(), Vector2(10 * z, 0).round())
	check("Space.to_world inverts it", main._space_to_world(me, b).round(), (w0 + Vector2(10, 0)).round())
	var c := cc.roster[0]
	cc.deselect_all()
	tap(main.world_to_screen(me, c.pos))
	check("tap crew sprite (turned view): selected", cc.selected_crew(), [c])
	check("crew tooltip on the turned ship", (await tip_at(main.world_to_screen(me, c.pos)))[0], "crew_room")
	var target := -1
	for r in me.layout.rooms:
		var used := false
		for m in me.crew:
			if m.room == r.id or m.target_room == r.id:
				used = true
		if not used:
			target = r.id
			break
	var rp: Vector2 = main.world_to_screen(me, me.room_rect(target).get_center())
	var w: Variant = cc.locate(me, rp)
	check("room under the drawn room centre", w != null and me.room_at(w) == target, true)
	tap(rp)
	check("tap a room with crew selected: move order", c.target_room, target)
	cc.deselect_all()
	var dpos: Vector2 = main.world_to_screen(me, ShipView.door_rect_of(me, me.env.doors[0]).get_center())
	cc.pointer_moved(dpos)
	check("door hover at its drawn (turned) place", cc.hovered_door, 0)
	cc.pointer_moved(TooltipService.OFF_SCREEN)
	# Drag box (screen rectangle -> world corners through the rotation) around one crew member.
	var cp: Vector2 = main.world_to_screen(me, c.pos)
	cc.first_mouse = cp - Vector2(12, 12)
	cc.current_mouse = cp + Vector2(12, 12)
	cc.potential.clear()
	cc._drag_select()
	check("drag box around the drawn crew: in the set", cc.potential.has(c), true)
	cc.potential.clear()
	# Own room under a beam-free pointer: the room hover outline follows the turned room.
	var hp: Vector2 = main.world_to_screen(me, me.room_rect(target).get_center())
	check("room at the drawn centre (Space.to_world)", me.room_at(main._space_to_world(me, hp)), target)
