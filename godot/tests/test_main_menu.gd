extends Node
## Tests for rules/main_menu.md: the title flow. Continue disabled without a save (and its press ignored), New Game
## → hangar through the views + InputProfile (PC press / touch release), ship cycling in SHIP_BLUEPRINT_ORDER incl.
## A/B/C variants (no C for crystal / lanius; type C cycle skips them), the unlock setting, AE gate on START,
## difficulty / renames, touch swipe, the CLI skip rule, and START → a run of main.tscn with the chosen ship,
## difficulty, AE flag, ship name and crew names. Run:
##   godot --headless --path godot res://tests/test_main_menu.tscn

const Harness := preload("res://tests/harness.gd")

const Title := preload("res://scripts/title.gd")
const Main := preload("res://scripts/main.gd")

var fails := 0


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
	var keep_path := PlayerProfile.path
	var keep_save := SaveGame.path
	PlayerProfile.path = "user://test_menu_profile.sav"  # never the player's real profile / run save
	SaveGame.path = "user://test_menu_continue.sav"
	PlayerProfile.reset_current(PlayerProfile.new())
	await _run_all()
	PlayerProfile.path = keep_path
	SaveGame.path = keep_save
	PlayerProfile.reset_current()


func _run_all() -> void:
	_test_skip_rule()
	_test_menu()
	_test_cycling()
	_test_unlock_setting()
	_test_hangar_choices()
	_test_touch()
	_test_start_run()
	_test_options_window()
	_test_mod_options()
	_test_stats_screen()
	_test_ship_list()
	_test_hangar_extras()
	_test_pause_menu()


func _test_skip_rule() -> void:
	print("CLI skip rule")
	check("no args → menu", Title.skips_menu(PackedStringArray()), false)
	check("--run skips", Title.skips_menu(PackedStringArray(["--run", "--seed=1"])), true)
	check("--sandbox skips", Title.skips_menu(PackedStringArray(["--sandbox"])), true)
	check("--player-ship skips", Title.skips_menu(PackedStringArray(["--player-ship=TEST_SHIP_ALL"])), true)
	check("plain --screenshot = sandbox", Title.skips_menu(PackedStringArray(["--screenshot=a.png", "--wait=1"])), true)
	check("--menu --screenshot = menu", Title.skips_menu(PackedStringArray(["--menu", "--screenshot=a.png"])), false)
	check("--input/--mute keep the menu", Title.skips_menu(PackedStringArray(["--input=touch", "--mute"])), false)


func _scene() -> Node:
	var sc: Node = load("res://title.tscn").instantiate()
	add_child(sc)
	sc.title.unlock_all = true  # scene tests browse every ship (locks: _test_unlock_setting)
	return sc


func _centre(v: MainMenuView, intent: String) -> Vector2:
	for i in MainMenuView.BUTTONS.size():
		if MainMenuView.BUTTONS[i][1] == intent:
			return v.button_rect(i).get_center()
	return Vector2(-1, -1)


func _test_menu() -> void:
	print("main menu")
	if FileAccess.file_exists(SaveGame.path):
		DirAccess.remove_absolute(SaveGame.path)
	var sc := _scene()
	var t: TitleState = sc.title
	var v: MainMenuView = sc.menu_view
	check("starts on the menu", t.screen, TitleState.Screen.MENU)
	check("Continue disabled without a save", [t.continue_enabled(), v.button_active(0)], [false, false])
	check("New Game active", v.button_active(1), true)
	check("buttons right-aligned at x 1200 (1.6.14)", [v.button_rect(0).end.x, v.button_rect(6).end.x],
		[1200.0, 1200.0])
	check("Continue y 275, Quit y 623", [v.button_rect(0).position.y, v.button_rect(6).position.y], [275.0, 623.0])
	v.hover(_centre(v, TitleState.MENU_CONTINUE))
	check("disabled Continue tooltip = no_load", v.tooltip_text_now(), FtlData.tr_id("no_load"))
	v.press(_centre(v, TitleState.MENU_CONTINUE))
	v.release(_centre(v, TitleState.MENU_CONTINUE))
	check("Continue press ignored", [t.screen, t.pending], [TitleState.Screen.MENU, ""])
	check("Continue intent refused", t.apply(TitleState.make(TitleState.MENU_CONTINUE)), false)
	v.press(_centre(v, TitleState.MENU_TUTORIAL))
	check("Tutorial → toast", t.pending.begins_with("toast:"), true)
	t.pending = ""
	v.press(_centre(v, TitleState.MENU_OPTIONS))
	check("Options → options screen", t.pending, "options")
	sc._consume("options")
	t.pending = ""
	check("Options opens FTL's options window", sc.vanilla_options.visible, true)
	sc.vanilla_options.hide_screen()
	v.press(_centre(v, TitleState.MENU_STATS))
	check("Stats → stats screen", t.pending, "stats")
	sc._consume("stats")
	t.pending = ""
	check("stats screen open", sc.stats_view.visible, true)
	sc.stats_view.close()
	v.press(_centre(v, TitleState.MENU_NEW_GAME))
	check("New Game (PC press) → hangar", t.screen, TitleState.Screen.HANGAR)
	check("hangar opens on the Kestrel A", TitleState.blueprint_of(t.ship_id, t.ship_type), "PLAYER_SHIP_HARD")
	check("ship name = blueprint name", t.ship_name, "The Kestrel")
	check("crew from the blueprint", t.crew.map(func(c): return c.race), ["human", "human", "human"])
	# Hangar view buttons: RIGHT arrow cycles, START pressed sets pending start.
	var h: HangarView = sc.hangar_view
	h.refresh()
	h.press(h.buttons["right"].rect.get_center())
	check("right arrow → next ship (Engi)", TitleState.blueprint_of(t.ship_id, t.ship_type), "PLAYER_SHIP_CIRCLE")
	h.press(h.buttons["type1"].rect.get_center())
	check("B button → Engi B", TitleState.blueprint_of(t.ship_id, t.ship_type), "PLAYER_SHIP_CIRCLE_2")
	h.press(h.buttons["diff2"].rect.get_center())
	check("HARD button", t.difficulty, 2)
	h.press(h.buttons["start"].rect.get_center())
	check("START → pending start", t.pending, "start")
	t.pending = ""  # consumed here (the scene would load main.tscn)
	check("Esc → back to menu", sc.profile.hangar_key(KEY_ESCAPE), true)
	check("screen after back", t.screen, TitleState.Screen.MENU)
	sc.queue_free()


func _id(t: TitleState) -> String:
	return TitleState.blueprint_of(t.ship_id, t.ship_type)


func _test_cycling() -> void:
	print("ship cycling (SHIP_BLUEPRINT_ORDER) and variants")
	var t := TitleState.new()
	t.unlock_all = true
	t.open_hangar()
	var seen := [_id(t)]
	for i in 10:
		t.apply(TitleState.make(TitleState.NEXT_SHIP))
		seen.append(_id(t))
	check("next order (wraps)", seen, ["PLAYER_SHIP_HARD", "PLAYER_SHIP_CIRCLE", "PLAYER_SHIP_FED",
		"PLAYER_SHIP_ENERGY", "PLAYER_SHIP_MANTIS", "PLAYER_SHIP_JELLY", "PLAYER_SHIP_ROCK", "PLAYER_SHIP_STEALTH",
		"PLAYER_SHIP_ANAEROBIC", "PLAYER_SHIP_CRYSTAL", "PLAYER_SHIP_HARD"])
	t.apply(TitleState.make(TitleState.PREV_SHIP))
	check("prev from the Kestrel = crystal", _id(t), "PLAYER_SHIP_CRYSTAL")
	check("crystal has no type C", [t.has_type_c(), t.type_available(2)], [false, false])
	check("crystal B exists", t.apply(TitleState.make(TitleState.SET_TYPE, 1)), true)
	check("crystal B blueprint", _id(t), "PLAYER_SHIP_CRYSTAL_2")
	check("type C refused", t.apply(TitleState.make(TitleState.SET_TYPE, 2)), false)
	t.switch_ship(0, 2)
	check("Kestrel C", _id(t), "PLAYER_SHIP_HARD_3")
	var c_seen := []
	for i in 9:
		t.apply(TitleState.make(TitleState.NEXT_SHIP))
		c_seen.append(t.ship_id)
	check("type C cycle skips crystal (8) and lanius (9)", c_seen.has(8) or c_seen.has(9), false)
	check("type C cycle visits 8 ships", c_seen.slice(0, 8).size(), 8)
	t.switch_ship(5, 1)
	check("preview ship built from the variant", t.preview.blueprint.name, "PLAYER_SHIP_JELLY_2")
	check("ship name follows the variant", t.ship_name, TitleState.ship_title("PLAYER_SHIP_JELLY_2"))
	t.apply(TitleState.make(TitleState.RANDOM_SHIP))
	check("random ship is an unlocked layout", t.unlocked(t.ship_id, t.ship_type), true)


func _test_unlock_setting() -> void:
	print("unlock setting")
	check("project setting default OFF (profiles unlock)", ProjectSettings.get_setting(TitleState.UNLOCK_SETTING, true), false)
	var t := TitleState.new()
	t.unlock_all = false
	t.open_hangar()
	check("locked: only Kestrel A", [t.unlocked(0, 0), t.unlocked(0, 1), t.unlocked(3, 0)], [true, false, false])
	check("locked: cycling stays", t.apply(TitleState.make(TitleState.NEXT_SHIP)), false)
	check("locked: B refused", t.apply(TitleState.make(TitleState.SET_TYPE, 1)), false)


func _test_hangar_choices() -> void:
	print("hangar choices")
	var t := TitleState.new()
	t.unlock_all = true
	t.open_hangar()
	check("difficulty easy", t.apply(TitleState.make(TitleState.SET_DIFFICULTY, 0)), true)
	check("same difficulty refused", t.apply(TitleState.make(TitleState.SET_DIFFICULTY, 0)), false)
	check("rename ship (16 chars max)", [t.apply(TitleState.make(TitleState.RENAME_SHIP, -1,
		{"text": "A Very Long Ship Name Indeed"})), t.ship_name], [true, "A Very Long Ship"])
	check("empty rename refused", t.apply(TitleState.make(TitleState.RENAME_SHIP, -1, {"text": "  "})), false)
	check("rename crew 1", t.apply(TitleState.make(TitleState.RENAME_CREW, 1, {"text": "Ripley"})), true)
	check("preview crew renamed", t.preview.crew[1].name_long, "Ripley")
	var male: bool = t.crew[0].male
	var c0 := int(t.crew[0].colors[0])
	t.apply(TitleState.make(TitleState.CREW_LOOK, 0, {"dir": 1}))
	check("customize arrow changes the look", t.crew[0].male != male or int(t.crew[0].colors[0]) != c0, true)
	# AE gate: type C / lanius need AE content.
	t.switch_ship(9, 0)
	check("lanius needs AE", t.needs_ae(), true)
	t.apply(TitleState.make(TitleState.SET_AE, 0))
	check("AE off → START refused", [t.can_start(), t.apply(TitleState.make(TitleState.START))], [false, false])
	t.apply(TitleState.make(TitleState.SET_AE, 1))
	check("AE on → START ok", t.apply(TitleState.make(TitleState.START)), true)
	t.switch_ship(0, 0)
	t.apply(TitleState.make(TitleState.SET_AE, 0))
	check("Kestrel A starts without AE", t.can_start(), true)
	t.apply(TitleState.make(TitleState.TOGGLE_ROOMS))
	check("hide rooms", t.show_rooms, false)


func _test_touch() -> void:
	print("touch profile")
	var t := TitleState.new()
	var p := InputProfile.new(InputProfile.TOUCH)
	p.title = t
	check("touch: press does nothing", p.title_press(TitleState.make(TitleState.MENU_NEW_GAME)), false)
	check("touch: release acts", p.title_release(TitleState.make(TitleState.MENU_NEW_GAME)), true)
	t.unlock_all = true
	t.switch_ship(0, 0)
	check("short drag ignored", p.hangar_swipe(Vector2(6, 0)), false)
	check("swipe left → next ship", [p.hangar_swipe(Vector2(-60, 5)), _id(t)], [true, "PLAYER_SHIP_CIRCLE"])
	check("swipe right → previous ship", [p.hangar_swipe(Vector2(60, 0)), _id(t)], [true, "PLAYER_SHIP_HARD"])
	check("swipe up → next layout", [p.hangar_swipe(Vector2(0, -40)), t.ship_type], [true, 1])
	var pc := InputProfile.new(InputProfile.PC)
	pc.title = t
	check("PC: no swipe", pc.hangar_swipe(Vector2(-60, 0)), false)
	check("PC: release does nothing", pc.title_release(TitleState.make(TitleState.NEXT_SHIP)), false)


func _test_start_run() -> void:
	print("START → run with the chosen ship")
	var t := TitleState.new()
	t.unlock_all = true
	t.open_hangar()
	t.switch_ship(2, 1)  # Mantis B
	t.apply(TitleState.make(TitleState.SET_DIFFICULTY, 2))
	t.apply(TitleState.make(TitleState.SET_AE, 0))
	t.apply(TitleState.make(TitleState.RENAME_SHIP, -1, {"text": "Praying Hand"}))
	t.apply(TitleState.make(TitleState.RENAME_CREW, 0, {"text": "Kazzik"}))
	check("START", t.apply(TitleState.make(TitleState.START)), true)
	var cfg := t.run_config()
	Title.prepare_run(cfg)
	var main: Node = load("res://main.tscn").instantiate()
	add_child(main)
	var r: RunState = main.run
	check("run mode", Main.run_mode, true)
	check("run ship = Mantis B", r.ship.blueprint.name, "PLAYER_SHIP_MANTIS_2")
	check("difficulty hard (enemies + events)", [ShipAI.difficulty, r.engine.difficulty],
		[ShipAI.Difficulty.HARD, EventEngine.Difficulty.HARD])
	check("AE off in the run", r.engine.ae, false)
	check("ship name", r.ship.ship_title, "Praying Hand")
	check("crew 0 renamed", r.ship.crew[0].name_long, "Kazzik")
	check("crew names from the hangar", r.ship.crew.map(func(c): return c.name_long),
		cfg.crew.map(func(c): return c.name))
	main.queue_free()
	Main.run_mode = false
	Main.run_setup = {}
	Main.player_ship_name = "PLAYER_SHIP_HARD"
	ShipAI.difficulty = ShipAI.Difficulty.NORMAL
	RunState.current = null


func _test_options_window() -> void:
	print("FTL options window (VanillaOptionsView + GameOptions)")
	GameOptions.persist = false  # never write user files from tests
	var saved := {}
	for k in GameOptions.KEYS:
		saved[k] = GameOptions.get_value(k)
	var w := VanillaOptionsView.new()
	add_child(w)
	w.show_screen()
	check("lines from text_misc", [GameOptions.line("vsync"), GameOptions.line("colorblind")],
		["Vertical Sync: On", "Colorblind Mode: Disabled"])
	check("event choice default = brief delay", GameOptions.line("event_choice"), "Event choice selection: Brief delay")
	w.click(VanillaOptionsView.line_rect("vsync").get_center())
	check("click Vertical Sync toggles", GameOptions.vsync, false)
	w.click(VanillaOptionsView.line_rect("event_choice").get_center())
	check("event choice cycles to no delay", GameOptions.event_choice, 1)
	w.click(VanillaOptionsView.line_rect("show_paths").get_center())
	check("show beacon paths toggles", GameOptions.show_paths, false)
	w.click(VanillaOptionsView.line_rect("colorblind").get_center())
	check("colorblind flag stored", GameOptions.colorblind, true)
	var b := VanillaOptionsView.slider_box("sound")
	w.click(Vector2(b.position.x + 5, b.get_center().y))
	check("sound slider at the left = 0", GameOptions.sound_volume, 0.0)
	w.click(Vector2(b.end.x - 1, b.get_center().y))
	check("sound slider at the right = 1", GameOptions.sound_volume, 1.0)
	check("slider box (557,481) 200x20", b, Rect2(557, 481, 200, 20))
	var got_mods := [false]
	w.mod_options.connect(func(): got_mods[0] = true)
	w.click(w.buttons["mods"].rect.get_center())
	check("MOD OPTIONS button -> our options screen", got_mods[0], true)
	check("language line does not cycle", w.click(VanillaOptionsView.line_rect("language").get_center()), "language")
	check("touch-only line hidden on PC", VanillaOptionsView.gameplay_keys().has("fold_layout"), TooltipService.touch)
	var was_touch := TooltipService.touch
	TooltipService.touch = true
	check("touch: Unfolded Screen Layout line (default Split)", GameOptions.line("fold_layout"),
		"Unfolded Screen Layout: Split")
	check("  sixth GAMEPLAY line", VanillaOptionsView.line_rect("fold_layout").position, Vector2(661, 224 + 5 * 34))
	w.click(VanillaOptionsView.line_rect("fold_layout").get_center())
	check("  click cycles to Pan", [GameOptions.fold_layout, GameOptions.line("fold_layout")],
		["pan", "Unfolded Screen Layout: Pan"])
	w.click(VanillaOptionsView.line_rect("fold_layout").get_center())
	check("  and back to Split", GameOptions.fold_layout, "split")
	GameOptions.set_value("fold_layout", "edges")
	check("  unknown value -> split", GameOptions.fold_layout, "split")
	check("touch: Phone Screen Layout line (default Column)", GameOptions.line("phone_layout"),
		"Phone Screen Layout: Column")
	check("  fifth GAMEPLAY line (hotkeys hidden in touch)", [VanillaOptionsView.line_rect("phone_layout").position,
		VanillaOptionsView.gameplay_keys().has("hotkeys")], [Vector2(661, 224 + 4 * 34), false])
	w.click(VanillaOptionsView.line_rect("phone_layout").get_center())
	check("  click cycles to Pan", [GameOptions.phone_layout, GameOptions.line("phone_layout")],
		["pan", "Phone Screen Layout: Pan"])
	check("  stored with the options (get_value)", [GameOptions.get_value("phone_layout"),
		GameOptions.get_value("fold_layout")], ["pan", "split"])
	w.click(VanillaOptionsView.line_rect("phone_layout").get_center())
	check("  and back to Column", GameOptions.phone_layout, "column")
	GameOptions.set_value("phone_layout", "wide")
	check("  unknown value -> column", GameOptions.phone_layout, "column")
	TooltipService.touch = was_touch
	check("CLOSE right edge / y", [w.buttons["close"].rect.end.x, w.buttons["close"].rect.position.y], [1027.0, 441.0])
	w.click(w.buttons["close"].rect.get_center())
	check("CLOSE closes", w.visible, false)
	for k in saved:
		GameOptions.set_value(k, saved[k])
	GameOptions.apply()
	Engine.max_fps = 0
	w.queue_free()


func _test_mod_options() -> void:
	print("mod options page (OptionsScreen in the FTL options look)")
	Settings.declare_group("t_opt", "Test group", "Test description.", "test_main_menu")
	Settings.declare("t_opt", {"id": "t_opt_b", "label": "Bool item", "default": true})
	Settings.declare("t_opt", {"id": "t_opt_e", "label": "Enum item", "type": "enum", "options": ["a", "b", "c"],
		"default": "a"})
	Settings.declare("t_opt", {"id": "t_opt_f", "label": "Float item", "type": "float", "min": 0.0, "max": 2.0,
		"step": 0.5, "default": 1.0})
	var o := OptionsScreen.new()
	add_child(o)
	o.show_screen()
	check("close / defaults at the ControlsScreen positions", [o.buttons["close"].rect.end.x,
		o.buttons["close"].rect.position.y, o.buttons["defaults"].rect.position], [1190.0, 619.0, Vector2(160, 619)])
	check("group line from text_misc on/off", OptionsScreen.group_line("t_opt"), "Test group: Off")
	check("click a group selects it", [o.click(o.group_rect("t_opt").get_center()), o.selected], ["g:t_opt", "t_opt"])
	check("selecting does not toggle", Settings.group_raw("t_opt"), false)
	o.click(o.group_rect("t_opt").get_center())
	check("click on the selected group toggles it", Settings.group_raw("t_opt"), true)
	check("master line", OptionsScreen.master_line("t_opt"), "Test group: Enabled")
	o.click(o._row("master").rect.get_center())
	check("master line toggles", Settings.group_raw("t_opt"), false)
	o.click(o._row("i:t_opt_b").rect.get_center())
	check("bool item toggles", [Settings.raw("t_opt_b"), OptionsScreen.item_line("t_opt_b")], [false, "Bool item: Off"])
	o.click(o._row("i:t_opt_e").rect.get_center())
	check("enum item cycles", Settings.raw("t_opt_e"), "b")
	o.click(o._row("i:t_opt_e").rect.get_center(), true)
	check("right click cycles back", Settings.raw("t_opt_e"), "a")
	var box: Rect2 = o._row("i:t_opt_f").slider
	o.click(Vector2(box.end.x - 1, box.get_center().y))
	check("float SlideBar at the right = max", Settings.raw("t_opt_f"), 2.0)
	o.click(o.buttons["defaults"].rect.get_center())
	check("DEFAULTS forgets the user's choices", [Settings.raw("t_opt_b"), Settings.raw("t_opt_f")], [true, 1.0])
	o.click(o.buttons["close"].rect.get_center())
	check("CLOSE closes", o.visible, false)
	Settings.undeclare_owner("test_main_menu")
	o.queue_free()


func _test_stats_screen() -> void:
	print("stats screen (ScoreKeeper)")
	var t := TitleState.new()
	t.unlock_all = true
	var sv := StatsView.new()
	add_child(sv)
	sv.setup(t)
	sv.open()
	check("starts on TOP SCORES / ACHIEVEMENTS", [sv.left, sv.right], [0, 1])
	check("other tab button = SHIP BEST at (338,38)", sv.buttons["tab_left"].rect.position, Vector2(338, 38))
	sv.click(sv.buttons["tab_left"].rect.get_center())
	check("SHIP BEST page", sv.left, 1)
	check("TOP SCORES tab button at (43,38)", sv.buttons["tab_left"].rect.position, Vector2(43, 38))
	check("A/B/C at (250,155) +45", [sv.buttons["type0"].rect.position, sv.buttons["type2"].rect.position],
		[Vector2(250, 155), Vector2(340, 155)])
	sv.click(sv.buttons["next"].rect.get_center())
	check("LIST right arrow -> Engi", sv.ship_id, 3)
	sv.click(sv.buttons["prev"].rect.get_center())
	sv.click(sv.buttons["prev"].rect.get_center())
	check("left arrow wraps -> Crystal", sv.ship_id, 8)
	check("crystal: no C button", sv.buttons.has("type2"), false)
	sv.click(sv.buttons["list"].rect.get_center())
	check("LIST opens the ship list", sv.ship_list.visible, true)
	sv.ship_list.click(sv.ship_list.buttons["ship4"].rect.get_center())  # Fed
	check("pick in the list -> ship best of the Fed", [sv.ship_id, sv.ship_list.visible], [4, false])
	sv.click(sv.buttons["tab_right"].rect.get_center())
	check("STATS page", sv.right, 0)
	check("achievement rows resolve in achievements.xml",
		StatsView.ACH_ROWS.all(func(r): return r.all(func(id): return not MenuDraw.achievement(id).is_empty())), true)
	check("Kestrel ship achievements: 3 + victory", MenuDraw.ship_achievements(0).map(func(a): return a.img),
		["achievements/kestral_1.png", "achievements/kestral_2.png", "achievements/kestral_3.png",
		"achievements/S_V_off.png"])
	check("Fed has the quest marker", MenuDraw.ship_achievements(4).size(), 5)
	sv.click(sv.buttons["close"].rect.get_center())
	check("CLOSE", sv.visible, false)
	sv.queue_free()


func _test_ship_list() -> void:
	print("ship list (ShipSelect)")
	check("grid: order 0 at (136,161), 3 at (751,161)", [ShipListView.slot_pos(0), ShipListView.slot_pos(3)],
		[Vector2(136, 161), Vector2(751, 161)])
	check("grid: order 4 under 3, 7 under 0", [ShipListView.slot_pos(4), ShipListView.slot_pos(7)],
		[Vector2(751, 338), Vector2(136, 338)])
	check("grid: order 8 / 9 in the fifth column", [ShipListView.slot_pos(8), ShipListView.slot_pos(9)],
		[Vector2(976, 161), Vector2(976, 338)])
	var t := TitleState.new()
	t.unlock_all = false
	var l := ShipListView.new()
	add_child(l)
	l.setup(t)
	l.open(0, 0)
	check("locked profile: Engi locked, Kestrel A open", [l.ship_locked(3), l.ship_locked(0)], [true, false])
	var picked := [-1, -1]
	l.picked.connect(func(id, ty):
		picked[0] = id
		picked[1] = ty)
	l.click(l.buttons["ship3"].rect.get_center())
	check("locked ship not picked", picked[0], -1)
	t.unlock_all = true
	l.click(l.buttons["type1"].rect.get_center())
	check("TYPE B page", l.shown_type, 1)
	l.click(l.buttons["ship3"].rect.get_center())
	check("pick Engi B", picked, [3, 1])
	l.open(0, 0)
	l.click(Vector2(20, 700))
	check("click outside closes", l.visible, false)
	check("mini ship texture", ShipListView.mini_texture(0, 0) != null, true)
	l.queue_free()


func _test_hangar_extras() -> void:
	print("hangar: LIST, crew boxes")
	var sc := _scene()
	var t: TitleState = sc.title
	t.apply(TitleState.make(TitleState.MENU_NEW_GAME))
	var h: HangarView = sc.hangar_view
	h.refresh()
	check("LIST active", h.buttons["list"].state, "on")
	check("arrows beside LIST", [h.buttons["left"].rect.end.x < h.buttons["list"].rect.position.x,
		h.buttons["right"].rect.position.x > h.buttons["list"].rect.end.x,
		h.buttons["right"].rect.position.x - h.buttons["list"].rect.end.x < 10], [true, true, true])
	h.press(h.buttons["list"].rect.get_center())
	check("LIST opens the ship list", h.ship_list.visible, true)
	h.ship_list.click(h.ship_list.buttons["ship7"].rect.get_center())  # Zoltan
	check("pick -> hangar switches ship", TitleState.blueprint_of(t.ship_id, t.ship_type), "PLAYER_SHIP_ENERGY")
	check("CUSTOMIZE buttons per crew", h.buttons.has("custom0"), true)
	sc.queue_free()


func _test_pause_menu() -> void:
	print("in-game Esc menu (MenuScreen)")
	var m := PauseMenuView.new()
	add_child(m)
	m.open(2, true, "PLAYER_SHIP_HARD_2")
	check("seven buttons", m.buttons.size(), 7)
	check("labels", m.buttons.values().map(func(b): return b.label),
		["CONTINUE", "MAIN MENU", "HANGAR", "RESTART", "OPTIONS", "CONTROLS", "SAVE+QUIT"])
	check("CONTINUE / SAVE+QUIT rows 18 / 254 px into the menu",
		[m.buttons["continue"].rect.position.y - PauseMenuView.POS.y,
		m.buttons["save"].rect.position.y - PauseMenuView.POS.y], [18.0, 254.0])
	check("ship id from a layout B blueprint", m.ship_id, 0)
	var got := []
	m.command.connect(func(c): got.append(c))
	m.click(m.buttons["controls"].rect.get_center())
	check("CONTROLS = placeholder (no command)", [got, m.message != ""], [[], true])
	# HANGAR / RESTART: ConfirmWindow `confirm_end_game` first (MenuScreen::MouseClick commands 0 / 6).
	m.click(m.buttons["hangar"].rect.get_center())
	check("HANGAR -> confirm open, no command yet", [m.confirming(), m.confirm.text_id, got],
		[true, "confirm_end_game", []])
	check("menu tinted 0.5 under the confirm", m.self_modulate, Color(0.5, 0.5, 0.5, 1.0))
	check("menu buttons inert under the confirm", m.click(m.buttons["continue"].rect.get_center()), "")
	var br: Array = m.confirm.button_rects()
	check("NO -> closed, command dropped", [m.click((br[1] as Rect2).get_center()), m.confirming(), got],
		["confirm_no", false, []])
	m.click(m.buttons["reset"].rect.get_center())
	check("RESTART -> confirm", [m.confirming(), m.pending], [true, "reset"])
	m.open(2, true, "PLAYER_SHIP_HARD_2")
	check("reopening the menu closes the confirm", [m.confirming(), m.pending], [false, ""])
	m.click(m.buttons["hangar"].rect.get_center())
	check("YES -> the stored command", m.click((br[0] as Rect2).get_center()), "confirm_yes")
	m.click(m.buttons["continue"].rect.get_center())
	check("commands", got, ["hangar", "continue"])
	check("CONTINUE closes", m.visible, false)
	m.queue_free()
	# main.gd wiring: Esc opens the menu and pauses; CONTINUE unpauses.
	var main: Node = load("res://main.tscn").instantiate()
	add_child(main)
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	main._hotkey(ev)
	check("Esc -> Esc menu, game paused", [main.pause_menu.visible, main.combat.paused], [true, true])
	main.pause_menu.click(main.pause_menu.buttons["options"].rect.get_center())
	check("OPTIONS -> FTL options window", main.vanilla_options.visible, true)
	main.vanilla_options.hide_screen()
	main.pause_menu.click(main.pause_menu.buttons["continue"].rect.get_center())
	check("CONTINUE -> unpaused", [main.pause_menu.visible, main.combat.paused], [false, false])
	main.queue_free()
	var title_script: GDScript = load("res://scripts/title.gd")
	title_script.open_hangar_next = true
	var sc := _scene()
	check("HANGAR command -> title opens in the hangar", sc.title.screen, TitleState.Screen.HANGAR)
	check("flag consumed", title_script.open_hangar_next, false)
	sc.queue_free()
