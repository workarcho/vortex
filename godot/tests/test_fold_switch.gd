extends Node

const Harness := preload("res://tests/harness.gd")
## Open-Fold layouts switched at runtime by the player's option (GameOptions.fold_layout, Options window GAMEPLAY
## "Unfolded Screen Layout"; main.gd `fold_layout()`, `_touch_layout_kind`, `_pan_reset`, `_armament_vertical`,
## `_touch_hud_refresh`; NOTES.md "Fold layout variants"). Canvas 1280 × 1100, touch, no `--fold-layout` /
## `--hud-scale` (the option drives the layout, HUD ×1.5). During combat: split -> pan -> split -> pan -> phone
## canvas (1600 × 720) -> back to the Fold (pan) -> split. After each switch: the expected layout, ship rotation
## (split PI / 2, else 0), pan offset reset, panel kinds, TARGET window placement, nothing left over from the other
## layout (pan arrows, pause text, subsystems scale), and taps: weapon box arms, PAUSE pauses, enemy room targets,
## crew select + move. `--device` sandbox (TEST_SHIP_MAX, combat+defense drones, harmless enemy). Run:
##   godot --headless --path godot res://tests/test_fold_switch.tscn

const MAIN := preload("res://scripts/main.gd")
const CANVAS := Vector2i(1280, 1100)
const PHONE := Vector2i(1600, 720)

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
	MAIN._fold_layout_cli = ""  # the option decides
	MAIN.hud_scale_override = 0.0
	GameOptions.persist = false
	var saved: String = GameOptions.fold_layout
	GameOptions.fold_layout = "split"
	main = load("res://main.tscn").instantiate()
	add_child(main)
	await frames(6)
	main.combat.paused = true
	me = main.player_space.ship
	en = main.enemy_space.ship
	cc = main.crew_control
	check("no CLI override: the option drives the layout", MAIN.fold_layout_from_option(), true)
	await _state("split (option default)", "split")
	await _switch("pan")
	await _state("pan", "pan")
	await _switch("split")
	await _state("split again", "split")
	await _switch("pan")
	await _state("pan again", "pan")
	print("\nPhone canvas 1600 × 720 (from pan)")
	get_tree().root.size = PHONE
	await frames()
	await _state("phone", "band")
	print("\nBack to the Fold canvas (option: pan)")
	get_tree().root.size = CANVAS
	await frames()
	await _state("pan after the phone", "pan")
	await _switch("split")
	await _state("split after the phone", "split")
	print("\n%s" % ("test_fold_switch: ALL OK" if fails == 0 else "%d FAILURES" % fails))
	GameOptions.fold_layout = saved
	MAIN.input_mode = InputProfile.PC
	MAIN._fold_layout_cli = ""


## Changes the option during combat (as the Options window does) and lets the per-frame layout tick re-lay out.
## The pan position is moved first so the test sees it reset.
func _switch(to: String) -> void:
	print("\nOption -> %s" % to)
	if main._touch_kind == "pan":
		main._pan_set(0.6)
	GameOptions.fold_layout = to
	await frames()


func _state(title: String, kind: String) -> void:
	print("\n== %s" % title)
	var vis: Vector2 = get_viewport().get_visible_rect().size
	check("layout kind", main._touch_kind, kind)
	var tall := kind != "band"
	check("HUD scale (Fold ×1.5 from the option, phone ×1.2)", [main.TOUCH_TOPLEFT_SCALE, main.TOUCH_SYSBAR_SCALE],
		[1.5, 1.5] if tall else [1.2, 1.2])
	var rot := PI / 2 if kind == "split" else 0.0
	check("player view rotation", main.player_space.fixed_rotation, rot)
	check("ShipView upright = rotation", main.player_space.view.upright, rot)
	check("camera rotation", is_equal_approx(main.player_space.cam.rotation, rot), true)
	check("pan offset at the scene's left end", main.pan_pos, 0.0)
	check("backdrop parallax undone", main.space_backdrop.position.x, 0.0)
	var arrows: Control = main.pan_arrows
	check("pan arrows shown only in pan", arrows != null and arrows.visible, kind == "pan")
	var wp: WeaponPanel = main.weapon_panel
	var dp: DronePanel = main.drone_panel
	var want_w := kind == "band"
	var want_d := kind != "pan"
	check("panel kinds (weapons, drones vertical)", [wp.vertical, dp.vertical], [want_w, want_d])
	check("bar's drones power column shown with a PC drones box", main.systems_bar.columns["drones"].visible, not want_d)
	if kind != "pan":
		check("pause text at its frame place", [main.pause_overlay.scale, main.pause_overlay.position],
			[Vector2.ONE, Vector2.ZERO])
		check("top buttons at the frame origin", main.command_hud.position, Vector2.ZERO)
	var ew: EnemyWindow = main.enemy_window
	var s: float = ew.scale.x
	var art := Rect2(ew.position + (HudLayout.ENEMY_FRAME.position + MAIN.TOUCH_ENEMY_ART.position) * s,
		MAIN.TOUCH_ENEMY_ART.size * s)
	check("TARGET window shown", ew.visible, true)
	match kind:
		"split":
			check("frozen split", main._touch_split_frozen(), true)
			check("TARGET ×21/16, art at its frozen slot", [s, art.position.round()],
				[21.0 / 16.0, Vector2(vis.x - 509, 249)])
			check("subsystems ×1.25", snappedf(main.systems_bar.sub_group.get_global_transform().get_scale().x, 0.001),
				1.25)
			check("weapons box at its frozen slot", wp.position, Vector2(652, 962))
		"pan":
			var xf: Transform2D = main._pan_scene.xf
			check("TARGET window = the scene's window at pan 0", [s, ew.position], [xf.get_scale().x, xf.origin])
			check("  right of the player ship (in the scene)", art.position.x > 600.0, true)
			check("subsystems ×1.25", snappedf(main.systems_bar.sub_group.get_global_transform().get_scale().x, 0.001),
				1.25)
			check("enemy space inside its window", ew.get_global_rect().encloses(main.enemy_space.get_global_rect()
				.grow(-1.0)), true)
		"band":
			check("no band offset at 1600 × 720", (main.hud_root.get_parent() as CanvasLayer).offset, Vector2.ZERO)
			check("TARGET art flush with the right edge", roundf(art.end.x), vis.x)
			check("subsystems back to the bar's scale", snappedf(main.systems_bar.sub_group.get_global_transform()
				.get_scale().x, 0.001), 1.2)
	await _weapon_tap()
	await _pause_tap()
	await _crew_move()
	await _enemy_target(kind)


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
	check("PAUSE ×1.5 the HUD scale (TOUCH_PAUSE_BASE)", tb.art_scale, main.command_hud.scale.x * MAIN.TOUCH_PAUSE_BASE)
	tap(pr.get_center())
	check("tap PAUSE: paused", main.combat.paused, true)
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


func _enemy_target(kind: String) -> void:
	var wc: WeaponControl = main.weapon_control
	var wi := -1
	for i in me.weapons.size():
		var w := me.weapons[i]
		if w != null and not w.is_beam() and int(w.bp.get("radius", 0)) == 0:
			wi = i
			break
	if kind == "pan":
		main._pan_set(1.0)  # the enemy end of the scene
	me.weapons[wi].clear_target()
	if not me.weapons[wi].powered:
		wc.select(wi)
	wc.select(wi)
	check("weapon armed", wc.armed, wi)
	var room: int = en.sys("shields").room
	var p: Vector2 = main.world_to_screen(en, en.room_rect(room).get_center())
	check("enemy room inside the TARGET view", main.enemy_space.get_global_rect().has_point(p), true)
	tap(p)
	check("tap enemy shields room: targeted", [me.weapons[wi].target_ship == en, me.weapons[wi].target_room],
		[true, room])
	wc.disarm()
	main.combat.paused = true
	main._touch_selection_tick()
	if kind == "pan":
		var ew: EnemyWindow = main.enemy_window
		var s: float = ew.scale.x
		var art_r: float = ew.position.x + (HudLayout.ENEMY_FRAME.position.x + MAIN.TOUCH_ENEMY_ART.end.x) * s
		check("pan 1: TARGET art inside the canvas", art_r <= get_viewport().get_visible_rect().size.x, true)
