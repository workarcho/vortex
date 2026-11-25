extends Node

const Harness := preload("res://tests/harness.gd")
## Touch HUD calibration (Options window CALIBRATE HUD; main.gd `calibrate_hud` / `_hud_calibration`,
## scripts/ui/hud_calibration_panel.gd, GameOptions.hud_calibration):
## - the calibration sandbox: TEST_SHIP_CALIBRATE with its systems, four ion weapons, three drones, harmless enemy
##   with shields and hull, kept paused, no run;
## - each slider re-lays the HUD out at once: Top -> ship status / crew list / top buttons, Bottom -> systems bar /
##   subsystems / + − toggle, Weapons & drones -> the weapons / drones panels;
## - SAVE per form factor (phone 1600 × 720 vs open Fold 1280 × 1100, separate keys), reload from the file, RESET;
## - a normal (non-calibration) touch combat applies the saved values; `--hud-scale` (hud_scale_override) wins;
## - the Options window's CALIBRATE HUD button (touch, main menu only).
## The options file is a test path (never user://ftl_options.cfg). Run:
##   godot --headless --path godot res://tests/test_hud_calibration.tscn

const MAIN := preload("res://scripts/main.gd")
const PHONE := Vector2i(1600, 720)
const FOLD := Vector2i(1280, 1100)
const TEST_PATH := "user://test_hud_calibration_options.cfg"

var fails := 0
var main: Node
var panel: Control
var finished_with: Array = []


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func near(name: String, got: float, want: float) -> void:
	check(name, snappedf(got, 0.001), snappedf(want, 0.001))


func frames(n := 4) -> void:
	for i in n:
		await get_tree().process_frame


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	FtlData.muted = true
	get_tree().root.size = PHONE
	MAIN._scenario_cli_done = true
	MAIN._calib_cli_done = true
	MAIN.hud_scale_override = 0.0
	MAIN._fold_layout_cli = ""
	MAIN._phone_layout_cli = ""
	var saved_opts := [GameOptions.persist, GameOptions.path, GameOptions.hud_calibration, GameOptions.fold_layout,
		GameOptions.phone_layout]
	GameOptions.persist = true
	GameOptions.path = TEST_PATH
	GameOptions.hud_calibration = {}
	GameOptions.fold_layout = "split"
	GameOptions.phone_layout = "column"
	DirAccess.remove_absolute(TEST_PATH)
	await _sandbox()
	await _sliders()
	await _save_and_forms()
	await _reset()
	main.queue_free()
	await frames(2)
	await _applied_outside()
	_options_button()
	print("\n%s" % ("test_hud_calibration: ALL OK" if fails == 0 else "%d FAILURES" % fails))
	DirAccess.remove_absolute(TEST_PATH)
	GameOptions.persist = saved_opts[0]
	GameOptions.path = saved_opts[1]
	GameOptions.hud_calibration = saved_opts[2]
	GameOptions.fold_layout = saved_opts[3]
	GameOptions.phone_layout = saved_opts[4]
	MAIN.input_mode = InputProfile.PC
	MAIN.hud_scale_override = 0.0


func _sandbox() -> void:
	print("\n== Calibration sandbox (phone canvas)")
	MAIN.input_mode = InputProfile.PC  # the calibration forces touch itself
	MAIN.calibrate_hud = true
	main = load("res://main.tscn").instantiate()
	add_child(main)
	await frames(6)
	check("calibrating", main.calibrating, true)
	check("static flag consumed", MAIN.calibrate_hud, false)
	check("touch input", MAIN.input_mode, InputProfile.TOUCH)
	check("no run", [main.run == null, MAIN.run_mode], [true, false])
	check("kept paused", main.combat.paused, true)
	# CANCEL is always shown while calibrating (its place can be judged), and a tap on it does nothing.
	main._touch_selection_tick()
	var tb: TouchCombatButtons = main.touch_buttons
	check("CANCEL shown without a selection mode", [tb != null and tb.cancel_shown, main.touch_selecting], [true, false])
	if tb != null:
		var cv := InputEventMouseButton.new()
		cv.button_index = MOUSE_BUTTON_LEFT
		cv.pressed = true
		cv.position = tb.rect_of("cancel").get_center()
		check("  tap CANCEL: taken by the button", main._touch_buttons_input(cv), true)
		cv = cv.duplicate()
		cv.pressed = false
		main._touch_buttons_input(cv)
		check("  … and nothing changed (still paused, no selection)", [main.combat.paused, main.touch_selecting],
			[true, false])
		check("  PAUSE and CANCEL apart", tb.rect_of("cancel").intersects(tb.rect_of("pause")), false)
	var me: ShipState = main.player_space.ship
	var en: ShipState = main.enemy_space.ship
	check("player ship", me.blueprint.name, MAIN.CALIB_PLAYER_SHIP)
	check("weapons: four ion weapons", me.weapons.map(func(w): return w.bp.name), MAIN.CALIB_WEAPONS)
	var ion_only := me.weapons.all(func(w): return int(w.bp.get("damage", 0)) == 0 and int(w.bp.get("ion", 0)) > 0)
	check("no weapon does hull damage", ion_only, true)
	check("drones installed", me.drones.map(func(d): return d.bp.name), MAIN.CALIB_DRONES)
	check("drone panel shown", main.drone_panel != null and main.drone_panel.visible, true)
	var ids := []
	for id in ["shields", "engines", "oxygen", "weapons", "drones", "pilot", "sensors", "doors", "cloaking", "battery",
			"mind", "hacking"]:
		if me.sys(id) != null:
			ids.append(id)
	check("12 systems installed (8 main + 4 sub)", ids.size(), 12)
	var lv_ok := ids.all(func(id): return me.sys(id).get_level() >= 1 and me.sys(id).get_level() <= 4)
	check("levels 1..4 (not maxed)", lv_ok, true)
	check("several crew", me.own_crew().size() >= 6, true)
	check("enemy unarmed", [en.weapons.size(), en.drone_parts], [0, 0])
	check("enemy shield layers", en.shield_layers, MAIN.CALIB_ENEMY_SHIELDS)
	check("enemy hull", en.hull >= MAIN.CALIB_ENEMY_HULL, true)
	var ai: ShipAI = main.combat.ais[main.enemy_space]
	check("enemy never escapes / surrenders", [ai.escape_threshold, ai.surrender_threshold], [-100, -100])
	panel = main.calib_panel
	check("panel shown", panel != null and panel.visible, true)
	check("form factor", panel.form_factor, "phone")
	# SAVE / BACK must not leave this test scene: the test listens instead of main.
	panel.finished.disconnect(main._close_calibration)
	panel.finished.connect(func(saved: bool) -> void: finished_with.append(saved))
	var r: Rect2 = panel.get_global_rect()
	check("panel on the canvas", Rect2(Vector2.ZERO, Vector2(PHONE)).encloses(r), true)
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = r.get_center()
	check("main leaves presses on the panel to it", panel.captures(ev), true)
	var rel := ev.duplicate()
	rel.pressed = false
	panel.captures(rel)
	ev.position = Vector2(5, PHONE.y - 5)
	check("presses elsewhere are the game's", panel.captures(ev), false)
	check("auto: top / bottom ×1.2", [main.TOUCH_TOPLEFT_SCALE, main.TOUCH_SYSBAR_SCALE], [1.2, 1.2])


func _sliders() -> void:
	print("\n== Sliders re-lay the HUD out live")
	_slide("top", 1.5)
	near("top: ship status ×", main.ship_status.scale.x, 1.5)
	near("top: crew list ×", main.crew_list.scale.x, 1.5)
	near("top: top buttons ×", main.command_hud.scale.x, 1.5)
	near("bottom unchanged", main.systems_bar.scale.x, 1.2)
	_slide("bottom", 0.9)
	near("bottom: systems bar ×", main.systems_bar.scale.x, 0.9)
	near("bottom: power toggle ×", main.touch_power.scale.x, 0.9)
	near("top unchanged", main.ship_status.scale.x, 1.5)
	_slide("weapons", 1.0)
	near("weapons: weapons column ×", main.weapon_panel.scale.x, 1.0)
	near("weapons: drones column ×", main.drone_panel.scale.x, 1.0)
	panel.tap("plus:weapons")
	near("+ button: one step", main.weapon_panel.scale.x, 1.05)
	panel.tap("minus:weapons")
	near("− button: one step back", main.weapon_panel.scale.x, 1.0)
	_slide("top", 3.0)
	near("slider range max", float(panel.live.top), GameOptions.HUD_SCALE_MAX)
	_slide("top", 0.1)
	near("slider range min", float(panel.live.top), GameOptions.HUD_SCALE_MIN)
	# A drag: press on the marker, move, release.
	panel.press(panel.slider_point("top", 0.75))
	panel.move(panel.slider_point("top", 1.25))
	panel.release(panel.slider_point("top", 1.25))
	check("live values", panel.live, {"top": 1.25, "bottom": 0.9, "weapons": 1.0})
	check("value text", panel.value_text("bottom"), "x0.90")
	check("nothing hovered after release", panel.hover, "")
	panel.tap("toggle")
	check("HIDE collapses", panel.collapsed, true)
	check("collapsed: only the toggle answers", panel.item_at(panel.slider_point("top", 1.0)), "")
	panel.tap("toggle")
	check("SHOW expands", panel.collapsed, false)
	var held: Vector2 = (panel.items["plus:top"] as Rect2).get_center()
	panel.press(held)
	panel.release(held + Vector2(0, 200))
	near("released off the button: nothing", float(panel.live.top), 1.25)
	check("nothing saved yet", GameOptions.hud_calibration, {})


## A tap on `group`'s slider where its marker sits at `v` (the panel's own pointer path, local FTL px).
func _slide(group: String, v: float) -> void:
	var p: Vector2 = panel.slider_point(group, v)
	panel.press(p)
	panel.release(p)


func _save_and_forms() -> void:
	print("\n== SAVE per form factor")
	panel.save()
	check("SAVE finishes (saved)", finished_with, [true])
	check("phone saved", GameOptions.hud_scales("phone"), {"top": 1.25, "bottom": 0.9, "weapons": 1.0})
	check("written to the test path only", FileAccess.file_exists(TEST_PATH), true)
	GameOptions.hud_calibration = {}
	GameOptions.load_file()
	check("reloaded from the file", GameOptions.hud_scales("phone"), {"top": 1.25, "bottom": 0.9, "weapons": 1.0})
	print("\n-- unfolded (1280 × 1100): its own calibration")
	get_tree().root.size = FOLD
	await frames(4)
	check("form factor", panel.form_factor, "fold_inner")
	check("fold starts automatic", panel.live, {})
	check("layout", main._touch_kind, "split")
	near("fold auto ×1.5", main.TOUCH_TOPLEFT_SCALE, 1.5)
	_slide("top", 1.2)
	_slide("weapons", 1.25)
	near("fold top ×", main.ship_status.scale.x, 1.2)
	near("fold weapons box ×", main.weapon_panel.scale.x, 1.25)
	near("fold bottom stays auto", main.systems_bar.scale.x, 1.5)
	panel.save()
	check("fold saved (set groups only)", GameOptions.hud_scales("fold_inner"), {"top": 1.2, "weapons": 1.25})
	check("phone kept", GameOptions.hud_scales("phone"), {"top": 1.25, "bottom": 0.9, "weapons": 1.0})
	GameOptions.hud_calibration = {}
	GameOptions.load_file()
	check("both reloaded", [GameOptions.hud_scales("phone").size(), GameOptions.hud_scales("fold_inner").size()],
		[3, 2])
	print("\n-- folded again: the phone values")
	get_tree().root.size = PHONE
	await frames(4)
	check("phone live from the save", panel.live, {"top": 1.25, "bottom": 0.9, "weapons": 1.0})
	near("phone top ×", main.ship_status.scale.x, 1.25)
	check("form factor of a 1766 × 720 canvas", GameOptions.hud_form_factor(Vector2(1766, 720)), "fold_cover")


func _reset() -> void:
	print("\n== RESET")
	panel.reset()
	check("phone removed", GameOptions.hud_scales("phone"), {})
	check("fold kept", GameOptions.hud_scales("fold_inner"), {"top": 1.2, "weapons": 1.25})
	GameOptions.hud_calibration = {}
	GameOptions.load_file()
	check("removed in the file", GameOptions.hud_scales("phone"), {})
	near("back to auto top", main.ship_status.scale.x, 1.2)
	near("back to auto bottom", main.systems_bar.scale.x, 1.2)
	check("values say AUTO", panel.value_text("top").ends_with(" AUTO"), true)
	panel.back()
	check("BACK finishes (not saved)", finished_with, [true, true, false])


func _applied_outside() -> void:
	print("\n== Saved values in a normal touch combat; --hud-scale wins")
	GameOptions.set_hud_scales("phone", {"top": 1.0, "bottom": 1.4})
	MAIN.input_mode = InputProfile.TOUCH
	MAIN.player_ship_name = "TEST_SHIP_MAX"
	MAIN.harmless_enemy = true
	MAIN.calibrate_hud = false
	main = load("res://main.tscn").instantiate()
	add_child(main)
	await frames(6)
	check("not calibrating", [main.calibrating, main.calib_panel == null], [false, true])
	near("calibrated top", main.ship_status.scale.x, 1.0)
	near("calibrated bottom", main.systems_bar.scale.x, 1.4)
	MAIN.hud_scale_override = 1.3
	await frames(3)
	near("override: top", main.ship_status.scale.x, 1.3)
	near("override: bottom", main.systems_bar.scale.x, 1.3)
	# (Phone column layout: the column may be smaller when 1.3 does not fit above PAUSE ×1.5: the layout's scale.)
	check("override: weapons (at most 1.3)", [main.weapon_panel.scale.x <= 1.3 + 0.001,
		is_equal_approx(main.weapon_panel.scale.x, main.touch_weapon_scale)], [true, true])
	MAIN.hud_scale_override = 0.0
	await frames(3)
	near("override gone: calibration again", main.systems_bar.scale.x, 1.4)
	print("\n-- phone pan")
	MAIN._phone_layout_cli = "pan"
	await frames(4)
	check("layout", main._touch_kind, "phone_pan")
	near("pan: top", main.command_hud.scale.x, 1.0)
	near("pan: bottom", main.systems_bar.scale.x, 1.4)
	GameOptions.set_hud_scales("phone", {"weapons": 1.25})
	await frames(4)
	near("pan: weapons box exact", main.weapon_panel.scale.x, 1.25)
	MAIN._phone_layout_cli = ""
	print("\n-- fold pan")
	MAIN._fold_layout_cli = "pan"
	GameOptions.set_hud_scales("fold_inner", {"top": 1.25, "bottom": 1.0, "weapons": 1.15})
	get_tree().root.size = FOLD
	await frames(4)
	check("layout", main._touch_kind, "pan")
	near("fold pan: top", main.command_hud.scale.x, 1.25)
	near("fold pan: bottom", main.systems_bar.scale.x, 1.0)
	near("fold pan: weapons", main.weapon_panel.scale.x, 1.15)
	near("fold pan: drones", main.drone_panel.scale.x, 1.15)
	MAIN._fold_layout_cli = ""
	get_tree().root.size = PHONE
	main.queue_free()
	await frames(2)


func _options_button() -> void:
	print("\n== Options window CALIBRATE HUD")
	var was: bool = TooltipService.touch
	for touch in [false, true]:
		TooltipService.touch = touch
		var v := VanillaOptionsView.new()
		add_child(v)
		check("button shown (touch %s)" % touch, v.buttons.has("calibrate_hud"), touch)
		if touch:
			var got := []
			v.calibrate.connect(func() -> void: got.append(1))
			var at: Vector2 = (v.buttons["calibrate_hud"].rect as Rect2).get_center()
			v.click(at)
			check("main menu: opens the calibration", got.size(), 1)
			v.in_run = true
			v.click(at)
			check("in a run: only a message", [got.size(), v.message != ""], [1, true])
		v.queue_free()
	TooltipService.touch = was
