extends Node

const Harness := preload("res://tests/harness.gd")
## Touch combat layout hit testing (main.gd `_touch_layout`, NOTES.md "Touch combat layout"): every piece the
## layout moves / scales must take its clicks, hover and tooltips exactly where it is drawn. Synthetic mouse
## events at the DRAWN positions (computed from each component's canvas transform: what its _draw lands on) in a
## fixed 1600 × 720 canvas (the phone canvas) with the `--device` sandbox (TEST_SHIP_MAX, combat+defense drones,
## harmless enemy). Tooltips are probed with the CLI pointer (TooltipService.debug_pointer). Run:
##   godot --headless --path godot res://tests/test_touch_layout.tscn

const MAIN := preload("res://scripts/main.gd")
const CANVAS := Vector2i(1600, 720)

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


## A finger tap at canvas point `p` (lands, press, lift).
func tap(p: Vector2) -> void:
	_move(p)
	_button(p, MOUSE_BUTTON_LEFT, true)
	_button(p, MOUSE_BUTTON_LEFT, false)
	_move(p, 0)


## A finger held at `p` for 0.7 s (a long press: tooltip only, the lift is the click), then lifted. Returns the
## tooltip kind shown while the finger rests (the CLI pointer: pushed events do not move the headless mouse).
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


func right_click(p: Vector2) -> void:
	_button(p, MOUSE_BUTTON_RIGHT, true)
	_button(p, MOUSE_BUTTON_RIGHT, false)


## [tooltip kind, ctx] requested while the pointer rests at canvas point `p` (CLI pointer: no finger needed).
func tip_at(p: Vector2) -> Array:
	TooltipService.debug_pointer = p
	await get_tree().process_frame
	await get_tree().process_frame
	var r := [String(TooltipService.kind), TooltipService.ctx.duplicate()]
	TooltipService.debug_pointer = null
	await get_tree().process_frame
	return r


## Canvas point of local point `local` of canvas item `ci` (where its _draw puts it).
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
	get_tree().root.size = CANVAS  # stretch "expand": a 1600 × 720 canvas (the phone)
	MAIN.input_mode = InputProfile.TOUCH
	MAIN._scenario_cli_done = true
	MAIN.player_ship_name = "TEST_SHIP_MAX"
	MAIN.harmless_enemy = true
	MAIN._set_drone_preset("combat+defense")
	main = load("res://main.tscn").instantiate()
	add_child(main)
	for i in 6:
		await get_tree().process_frame
	main.combat.paused = true
	me = main.player_space.ship
	en = main.enemy_space.ship
	cc = main.crew_control
	check("canvas", get_viewport().get_visible_rect().size, Vector2(CANVAS))
	check("column ×1.5", main.touch_weapon_scale, 1.5)
	check("ship ×1.375", main.touch_ship_zoom, 1.375)
	await _weapons()
	await _drones()
	await _systems()
	await _crew_hud()
	await _power_mode()
	await _pause_vs_toggle()
	await _top_left()
	await _enemy()
	await _player_ship()
	await _tall_canvas()
	await _pc_unchanged()
	print("\n%s" % ("test_touch_layout: ALL OK" if fails == 0 else "%d FAILURES" % fails))
	MAIN.input_mode = InputProfile.PC


func _weapons() -> void:
	print("Weapons column (×1.5)")
	var wp: WeaponPanel = main.weapon_panel
	var wc: WeaponControl = main.weapon_control
	var b0: WeaponBox = wp.boxes[0]
	var b1: WeaponBox = wp.boxes[1]
	for i in me.weapons.size():
		wc.depower(i)
	check("all weapons off", powered_weapons(), 0)
	tap(at(b0, b0.size / 2))
	check("tap slot 1 (drawn centre): powered", me.weapons[0].powered, true)
	tap(at(b0, b0.size / 2))
	check("tap again: armed", wc.armed, 0)
	wc.disarm()
	check("slot tooltip", (await tip_at(at(b1, b1.size / 2)))[0], "weapon")
	check("_over_hud_panel on the drawn slot", main._over_hud_panel(at(b1, b1.size / 2)), true)
	# Drag: the ghost follows the finger 1:1 (drag_offset is box-local; the box is drawn ×1.5).
	var w0 := me.weapons[0]
	var w1 := me.weapons[1]
	var p := at(b0, Vector2(20, 20))
	_move(p)
	_button(p, MOUSE_BUTTON_LEFT, true)
	_move(p + Vector2(15, 3))
	check("drag 15 px: ghost drawn 15 px away", at(b0, Vector2(20, 20) + b0.drag_offset).round(),
		(p + Vector2(15, 3)).round())
	var q := at(b1, Vector2(20, 20))
	_move(q)
	check("drag onto slot 2: swapped", [me.weapons[0], me.weapons[1]], [w1, w0])
	var gb: WeaponBox = wp.boxes[maxi(wp.drag.slot, 0)]
	check("  ghost still under the finger", at(gb, Vector2(20, 20) + gb.drag_offset).round(), q.round())
	_button(q, MOUSE_BUTTON_LEFT, false)
	_move(q, 0)
	wc.swap(0, 1)
	# A long press no longer depowers (touch: tooltip only; the lift is the normal click).
	if not me.weapons[0].powered:
		wc.select(0)
	var pw := powered_weapons()
	await hold(at(b0, b0.size / 2))
	check("hold slot 1 0.7 s: still powered (lift = click: armed)", [me.weapons[0].powered, powered_weapons(),
		wc.armed], [true, pw, 0])
	wc.disarm()
	wc.depower(0)
	pw = powered_weapons()
	# Power row: tap = power the next item, right click = depower the last one; system tooltip.
	var row: Control = wp.get("power_hit")
	check("weapons power row hit area", row != null, true)
	if row != null:
		var rc := at(row, row.size / 2)
		check("  over the drawn row", Rect2(at(wp, wp.v_row), Vector2(wp.v_row_w, WeaponPanel.V_ROW_H) * wp.scale)
			.has_point(rc), true)
		tap(rc)
		check("  tap row: one more weapon powered", powered_weapons(), pw + 1)
		check("  row tooltip", (await tip_at(rc))[0], "system")
		await hold(rc)
		check("  hold row: no depower (the lift taps: +1)", powered_weapons(), pw + 2)
		right_click(rc)
		right_click(rc)
		check("  right click row: depowered", powered_weapons(), pw)
	# AUTOFIRE.
	var af: Control = wp.autofire_btn
	var auto := me.autofire
	tap(at(af, af.size / 2))
	check("AUTOFIRE tap toggles", me.autofire, not auto)
	me.autofire = auto
	check("AUTOFIRE tooltip", (await tip_at(at(af, af.size / 2)))[0], "button")


func _drones() -> void:
	print("Drones column (×1.5)")
	var dp: DronePanel = main.drone_panel
	check("drones column", dp != null, true)
	if dp == null:
		return
	for i in me.drones.size():
		dp.depower(i)
	var b: DroneBox = dp.boxes[1]
	tap(at(b, b.size / 2))
	check("tap drone slot 2: powered", me.drones[1].powered, true)
	check("drone slot tooltip", (await tip_at(at(b, b.size / 2)))[0], "drone")
	var row: Control = dp.get("power_hit")
	check("drones power row hit area", row != null, true)
	if row != null:
		var rc := at(row, row.size / 2)
		tap(rc)
		check("  tap row: drone 1 powered too", powered_drones(), 2)
		check("  row tooltip", (await tip_at(rc))[0], "system")
		right_click(rc)
		check("  right click row: one depowered", powered_drones(), 1)


func _systems() -> void:
	print("Systems bar (×1.2) and subsystems")
	var sb: SystemsBar = main.systems_bar
	var col: SystemPowerColumn = sb.columns["shields"]
	while me.sys("shields").power > 0:
		me.decrease_power("shields")
	var c := at(col, col.hit_rect().get_center())
	tap(c)
	check("tap shields column (drawn): powered", me.sys("shields").power > 0, true)
	check("shields column tooltip", (await tip_at(c))[0], "system")
	check("_over_hud_panel on the drawn column", main._over_hud_panel(c), true)
	var rr := Vector2(HudLayout.REACTOR_X + HudLayout.REACTOR_BAR.x / 2, HudLayout.REACTOR_BOTTOM - 4)
	check("reactor tooltip", (await tip_at(at(sb, rr)))[0], "reactor")
	var pc: SystemPowerColumn = sb.columns["pilot"]
	var pp := at(pc, pc.hit_rect().get_center())
	check("subsystem (pilot) tooltip at its drawn place", (await tip_at(pp))[0], "system")
	check("_over_hud_panel on the drawn subsystem", main._over_hud_panel(pp), true)
	check("subsystems box tooltip", (await tip_at(at(sb.sub_group, HudLayout.SUBSYSTEMS + Vector2(80, 64))))[0],
		"subsystems")
	var db: Control = sb.buttons["doors"]
	me.manipulate_all_doors(false)
	tap(at(db, Vector2(20, 43)))  # lower slot (10, 33, 20, 20): open all
	check("doors button (lower half, drawn): doors open", me.env.doors.any(func(d): return d.open), true)
	tap(at(db, Vector2(20, 20)))  # upper slot: close all
	check("doors button (upper half): doors closed", me.env.doors.any(func(d): return d.open and not d.airlock),
		false)


func _crew_hud() -> void:
	print("Crew list (×1.2, moved up) and its buttons box")
	var cl: CrewList = main.crew_list
	cc.deselect_all()
	var p := at(cl, cc.box_rect(1).get_center())
	tap(p)
	check("tap crew box 2 (drawn): selected", cc.selected_crew(), [cc.roster[1]])
	check("crew box tooltip", (await tip_at(p))[0], "crew_box")
	check("_over_hud_panel on the drawn crew box", main._over_hud_panel(p), true)
	# Stations buttons: enlarged in the TARGET window's bottom-right corner (main._touch_station_rects).
	var xf: Transform2D = main.touch_enemy_transform()
	var st: Array = main._touch_station_rects(xf)
	check("stations buttons in the TARGET corner", [cl.touch_button_box, cl.touch_station_rects.size()], [null, 2])
	var art_br: Vector2 = xf * (HudLayout.ENEMY_FRAME.position + main.TOUCH_ENEMY_ART.end)
	var icons_r := -INF
	for e in main.enemy_window.system_boxes():
		icons_r = maxf(icons_r, (xf * (e[1] + Vector2(45, 0))).x)
	check("  inside the frame art's bottom-right, right of the enemy system icons", [st[1].end.x <= art_br.x,
		st[1].end.y <= art_br.y, st[0].position.x > icons_r], [true, true, true])
	check("  60 × 60 each (the 20 px art ×3)", [st[0].size, st[1].size], [Vector2(60, 60), Vector2(60, 60)])
	for k in 2:
		check("  button %d drawn = hit box" % k, at(cl, cc.button_rect(k).position).distance_to(st[k].position) < 1.0,
			true)
	check("_over_hud_panel on a corner button", main._over_hud_panel(st[0].get_center()), true)
	# One tap = one button: with a weapon armed, SAVE wins over the TARGET window beneath.
	var wc: WeaponControl = main.weapon_control
	if not me.weapons[0].powered:
		wc.select(0)
	wc.select(0)
	check("weapon 1 armed", wc.armed, 0)
	cc.message_time = 0.0
	tap(st[0].get_center())
	check("tap SAVE stations (TARGET corner)", cc.message_time > 0.0, true)
	check("  the armed weapon got no target", me.weapons[0].has_target(), false)
	wc.disarm()
	check("stations button tooltip", (await tip_at(st[1].get_center()))[0], "button")
	cc.deselect_all()


## Power mode toggle (+ / −, TouchPowerToggle) under the crew buttons box: taps add or remove power.
func _power_mode() -> void:
	print("Power mode toggle (+ / −)")
	var tp: TouchPowerToggle = main.touch_power
	var cl: CrewList = main.crew_list
	check("toggle exists and is shown", tp != null and tp.is_visible_in_tree(), true)
	if tp == null:
		return
	check("same scale as the crew list", tp.get_global_transform().get_scale(), cl.get_global_transform().get_scale())
	# The crew buttons are in the TARGET corner: the toggle takes the crew box's spot, tight against SUBSYSTEMS.
	var sb: Control = main.systems_bar.sub_group
	var sub_b: Rect2 = main.systems_bar.subsystem_bounds()
	check("2 px (+ rounding) left of the subsystems' solid art", absf(at(sb, sub_b.position).x
		- at(tp, Vector2(34, 0)).x - 2.0) <= 1.5, true)
	check("solid bottom level with the subsystems'", absf(at(tp, Vector2(20, CrewList.BOX_BODY_H)).y
		- at(sb, sub_b.end).y) <= 1.0, true)
	check("inside the layout height", at(tp, Vector2(20, CrewList.BOX_BODY_H)).y <= main._touch_height(), true)
	check("default: + mode", tp.minus, false)
	check("_over_hud_panel on the toggle", main._over_hud_panel(at(tp, TouchPowerToggle.SLOT_MINUS.get_center())), true)
	var wp: WeaponPanel = main.weapon_panel
	var wc: WeaponControl = main.weapon_control
	var dp: DronePanel = main.drone_panel
	var col: SystemPowerColumn = main.systems_bar.columns["engines"]
	var sc := at(col, col.hit_rect().get_center())
	# − mode.
	tap(at(tp, TouchPowerToggle.SLOT_MINUS.get_center()))
	check("tap −: − mode", tp.minus, true)
	while me.sys("engines").power < 2:
		me.increase_power("engines")
	var sp := me.sys("engines").power
	tap(sc)
	check("− mode: tap engines column = −1", me.sys("engines").power, sp - 1)
	tap(sc)
	check("  again −1", me.sys("engines").power, sp - 2)
	var b0: WeaponBox = wp.boxes[0]
	if not me.weapons[0].powered:
		wc.select(0)
	wc.select(0)
	check("weapon 1 powered and armed", [me.weapons[0].powered, wc.armed], [true, 0])
	tap(at(b0, b0.size / 2))
	check("− mode: tap armed weapon = depowered + disarmed", [me.weapons[0].powered, wc.armed], [false, -1])
	tap(at(b0, b0.size / 2))
	check("− mode: tap unpowered weapon = stays off", me.weapons[0].powered, false)
	var b1: WeaponBox = wp.boxes[1]
	if not me.weapons[1].powered:
		wc.select(1)
	var pw := powered_weapons()
	tap(at(wp.power_hit, wp.power_hit.size / 2))
	check("− mode: tap weapons power row = one depowered", powered_weapons(), pw - 1)
	if dp != null:
		var db: DroneBox = dp.boxes[0]
		if not me.drones[0].powered:
			dp.toggle(0)
		check("drone 1 powered", me.drones[0].powered, true)
		tap(at(db, db.size / 2))
		check("− mode: tap drone box = depowered", me.drones[0].powered, false)
		dp.toggle(0)
		dp.toggle(1)
		var pd := powered_drones()
		tap(at(dp.power_hit, dp.power_hit.size / 2))
		check("− mode: tap drones power row = one depowered", powered_drones(), pd - 1)
	# + mode.
	tap(at(tp, TouchPowerToggle.SLOT_PLUS.get_center()))
	check("tap +: + mode", tp.minus, false)
	sp = me.sys("engines").power
	tap(sc)
	check("+ mode: tap engines column = +1", me.sys("engines").power, sp + 1)
	tap(at(b1, b1.size / 2))
	check("+ mode: tap unpowered weapon 2 = powered", me.weapons[1].powered, true)
	tap(at(b1, b1.size / 2))
	check("+ mode: tap powered weapon 2 = armed", wc.armed, 1)
	wc.disarm()
	if dp != null:
		var db: DroneBox = dp.boxes[0]
		if not me.drones[0].powered:
			tap(at(db, db.size / 2))
		check("+ mode: tap drone box = powered", me.drones[0].powered, true)
		tap(at(db, db.size / 2))
		check("+ mode: tap powered drone = stays powered", me.drones[0].powered, true)
	# No hold-to-depower any more: a long press is the tooltip, the lift the normal click.
	pw = powered_weapons()
	var hk := await hold(at(b1, b1.size / 2))
	check("+ mode: hold weapon 2 = still powered, tooltip shown", [me.weapons[1].powered, powered_weapons(), hk],
		[true, pw, "weapon"])
	wc.disarm()
	if dp != null:
		var db: DroneBox = dp.boxes[0]
		var pd := powered_drones()
		hk = await hold(at(db, db.size / 2))
		check("+ mode: hold drone 1 = still powered, tooltip shown", [me.drones[0].powered, powered_drones(), hk],
			[true, pd, "drone"])
	check("toggle tooltip", (await tip_at(at(tp, TouchPowerToggle.SLOT_PLUS.get_center())))[0], "button")
	check("toggle tooltip text", TooltipText.t("tooltip_power_mode").begins_with("Energy Tap:"), true)
	# Without a live toggle (PC: none is ever created) every route is the plain click.
	tp.minus = true
	main.hud_root.remove_child(tp)
	var got := []
	TouchPowerToggle.route(func(_i): got.append("add"), func(_i): got.append("remove")).call(0)
	check("no live toggle: route = plain click even with minus set", [got, TouchPowerToggle.removing(),
		TouchPowerToggle.adding()], [["add"], false, false])
	main.hud_root.add_child(tp)
	tp.minus = false


## PAUSE / CANCEL never overlap another HUD piece, and a tap on PAUSE reaches only PAUSE (even with PAUSE
## forced on top of the power toggle, as the narrow open-Fold layout once drew it).
func _pause_vs_toggle() -> void:
	print("PAUSE / CANCEL vs the power toggle")
	var tb: TouchCombatButtons = main.touch_buttons
	var tp: TouchPowerToggle = main.touch_power
	check("PAUSE / CANCEL shown", tb != null and tb.is_visible_in_tree(), true)
	if tb == null or tp == null:
		return
	var pair: Rect2 = main._touch_pause_at
	var toggle := Rect2(at(tp, Vector2.ZERO), TouchPowerToggle.SIZE * tp.get_global_transform().get_scale())
	check("PAUSE / CANCEL clear of the toggle", pair.intersects(toggle), false)
	var others := 0
	for r in main._touch_hud_rects(main._touch_height()):
		if pair.intersects(r):
			others += 1
	check("PAUSE / CANCEL clear of every HUD rect", others, 0)
	check("PAUSE base inside the pair", pair.encloses(tb.rect_of("pause")), true)
	# Force PAUSE over the toggle's − half and tap it there.
	tp.minus = false
	var was_paused: bool = main.combat.paused
	var minus_c := at(tp, TouchPowerToggle.SLOT_MINUS.get_center())
	tb.pause_pos = minus_c - TouchCombatButtons.BASE_SIZE * tb.art_scale / 2
	tap(minus_c)
	check("tap PAUSE over the toggle: toggle still +", tp.minus, false)
	check("  … and PAUSE acted", main.combat.paused, not was_paused)
	main.combat.paused = true
	main._touch_selection_tick()  # puts the buttons back
	tap(tb.rect_of("pause").get_center())
	check("tap PAUSE in place: toggle still +", tp.minus, false)
	main.combat.paused = true
	main._touch_selection_tick()


func _top_left() -> void:
	print("Top-left HUD (×1.2) and top buttons")
	var st: ShipStatusHud = main.ship_status
	var r := await tip_at(at(st, Vector2(150, 25)))
	check("hull tooltip", r[1].get("id", ""), "tooltip_hull")
	r = await tip_at(at(st, Vector2(440, 28)))
	check("scrap tooltip", r[1].get("id", ""), "tooltip_scrapCount")
	r = await tip_at(at(st, Vector2(50, 106) + st.evade_offset))
	check("evade tooltip at the moved box", r[1].get("id", ""), "tooltip_evadeDisplay")
	r = await tip_at(at(st, Vector2(50, 128) + st.evade_offset))
	check("O2 tooltip at the moved box", r[1].get("id", ""), "tooltip_oxygenDisplay")
	var ch: CommandHud = main.command_hud
	check("FTL JUMP: drawn point maps into FTL_JUMP_HIT", MAIN.FTL_JUMP_HIT.has_point(
		ch.hud_point(at(ch, MAIN.FTL_JUMP_HIT.get_center()))), true)
	check("_over_hud_panel on the drawn FTL button", main._over_hud_panel(at(ch, MAIN.FTL_JUMP_HIT.get_center())), true)
	check("MENU tooltip", (await tip_at(at(ch, ch.menu_rect().get_center())))[0], "button")
	check("SHIP button: drawn point maps into SHIP_HIT", HudLayout.SHIP_HIT.has_point(
		ch.hud_point(at(ch, HudLayout.SHIP_HIT.get_center()))), true)
	tap(at(ch, ch.menu_rect().get_center()))
	check("tap MENU (drawn ×1.2): menu open", main.pause_menu.visible, true)
	main.pause_menu.visible = false
	main._menu_paused = false
	main.combat.paused = true


func _enemy() -> void:
	print("TARGET window (×4/3)")
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
	check("weapon armed", wc.armed, wi)
	main._touch_pause_tick()
	check("pause overlay: iPad TARGETING text", [main.pause_overlay.pause_title, main.pause_overlay.pause_text],
		["paused_targeting", "paused_targeting_text"])
	var room: int = en.sys("shields").room
	var p: Vector2 = main.world_to_screen(en, en.room_rect(room).get_center())
	check("enemy room inside the TARGET view", main.enemy_space.get_global_rect().has_point(p), true)
	tap(p)
	check("tap enemy shields room: targeted", [me.weapons[wi].target_ship == en, me.weapons[wi].target_room],
		[true, room])
	wc.disarm()
	var ew: EnemyWindow = main.enemy_window
	if not ew.system_boxes().is_empty():
		var e: Array = ew.system_boxes()[0]
		check("enemy system box tooltip (drawn)", (await tip_at(at(ew, e[1] + Vector2(32, 24))))[0], "system_enemy")
	var v: Rect2 = main.enemy_space.get_global_rect()
	check("TARGET bottom is not a HUD panel (tooltips live)", main._over_hud_panel(
		Vector2(v.get_center().x, v.end.y - 20)), false)
	for m in en.crew:
		if m.is_alive():
			var cp: Vector2 = main.world_to_screen(en, m.pos)
			check("enemy crew tooltip in the TARGET window", (await tip_at(cp))[0], "crew_room")
			break


func _player_ship() -> void:
	print("Player ship (×1.375)")
	var c := cc.roster[0]
	cc.deselect_all()
	var p: Vector2 = main.world_to_screen(me, c.pos)
	tap(p)
	check("tap crew sprite (drawn ×1.375): selected", cc.selected_crew(), [c])
	main._touch_pause_tick()
	check("pause overlay: iPad ROOM SELECTION text", main.pause_overlay.pause_title, "paused_room")
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
	cc.right_press(rp)
	check("move order to the drawn room", c.target_room, target)
	cc.deselect_all()
	var dp: Vector2 = main.world_to_screen(me, ShipView.door_rect_of(me, me.env.doors[0]).get_center())
	cc.pointer_moved(dp)
	check("door hover at its drawn place", cc.hovered_door, 0)
	cc.pointer_moved(TooltipService.OFF_SCREEN)


## A canvas a little taller than 720 (1280 × 780, under main.TOUCH_TALL_MIN_H): the HUD band moves down by
## (780 − 720) / 2. Tall canvas (open Fold 1280 × 1100): no band (edge layout, main._touch_layout_tall); the centred
## windows (Esc menu on the debug layer, end box on the HUD layer) are centred on the canvas, not offset twice; a
## weapon dragged onto another (viewport coordinates) swaps them. Restores the 1600 × 720 canvas.
func _tall_canvas() -> void:
	print("Canvas 1280 × 780 (band)")
	get_tree().root.size = Vector2i(1280, 780)
	for i in 4:
		await get_tree().process_frame
	var layer := main.hud_root.get_parent() as CanvasLayer
	check("band offset", layer.offset, Vector2(0, 30))
	print("Tall canvas 1280 × 1100")
	MAIN._fold_layout_cli = "edges"  # the edge layout (as `--fold-layout=edges`; the player's option is split / pan)
	get_tree().root.size = Vector2i(1280, 1100)
	for i in 4:
		await get_tree().process_frame
	check("tall: no band offset", layer.offset, Vector2.ZERO)
	check("tall: layout height = canvas height", main._touch_height(), 1100.0)
	check("tall: systems bar on the canvas bottom", main.systems_bar.position, Vector2(0, 380))
	var want := Vector2(0, 190)
	check("Esc menu centred (canvas)", main.pause_menu.get_global_transform_with_canvas().origin, want)
	main.end_box.open(EndBox.Mode.VICTORY, "")
	check("end box centred (canvas)", main.end_box.get_global_transform_with_canvas().origin, want)
	main.end_box.visible = false
	var wp: WeaponPanel = main.weapon_panel
	var b0: WeaponBox = wp.boxes[0]
	var b1: WeaponBox = wp.boxes[1]
	var w0 := me.weapons[0]
	var w1 := me.weapons[1]
	var p := b0.get_global_transform_with_canvas() * Vector2(20, 20)
	var q := b1.get_global_transform_with_canvas() * Vector2(20, 20)
	_move(p)
	_button(p, MOUSE_BUTTON_LEFT, true)
	_move(p + Vector2(15, 3))
	_move(q)
	check("drag onto slot 2 (tall canvas): swapped", [me.weapons[0], me.weapons[1]], [w1, w0])
	_button(q, MOUSE_BUTTON_LEFT, false)
	_move(q, 0)
	main.weapon_control.swap(0, 1)
	MAIN._fold_layout_cli = ""
	get_tree().root.size = CANVAS
	for i in 4:
		await get_tree().process_frame
	check("back to 1600 × 720: no band", layer.offset, Vector2.ZERO)
	check("Esc menu back at the canvas origin", main.pause_menu.get_global_transform_with_canvas().origin,
		Vector2(160, 0))


## The PC profile keeps its identity transforms (crew list, HUD) and PC hit rects.
func _pc_unchanged() -> void:
	print("PC hit rects unchanged")
	var pc := CrewControl.new(me, en, main._space_to_world, main._space_rect)
	check("PC crew box 1 at its frame rect", pc.box_at(CrewControl.BOX_ORIGIN + Vector2(5, 5)), 0)
	check("PC save stations button", pc.button_at(pc.button_rect(0).get_center()), 0)
