extends Node2D
## Startup scene (rules/main_menu.md): the FTL main menu and the hangar. Running the project shows the menu;
## any game / sandbox CLI flag (--run, --sandbox, --player-ship=, --screenshot= without --menu, ...) skips it and
## loads main.tscn directly, so every existing command line keeps working. New Game → hangar → START sets main.gd's
## run statics (ship, difficulty, AE, names) and loads main.tscn in run mode. The combat sandbox stays reachable
## from the debug overlay (F12 / DEBUG corner button → "Sandbox") and with `--sandbox`.
##
## CLI (menu): --menu (force the menu), --hangar (open the hangar), --hangar-ship=N|BLUEPRINT (shipId 0..9 or a
## blueprint name of the hangar list), --hangar-type=0|1|2, --hangar-difficulty=easy|normal|hard, --hangar-ae=0|1,
## --hangar-hide-rooms (HIDE ROOMS), --hangar-start (press START), --hangar-list[=TYPE] (open the ship list), --menu-options (FTL options window),
## --menu-stats[=L,R] (stats screen pages), --demo-profile (in-memory PlayerProfile.demo(), nothing saved),
## --input=pc|touch, --screenshot=<png> [--wait=s], --mute, --debug,
## --data-setup (open the first-run "Select ftl.dat" screen even with data; also shown whenever FtlData has none).

const MAIN_SCENE := "res://main.tscn"
## First-run data setup: shown instead of everything else while FtlData has no usable data folder.
const DATA_SETUP_SCENE := "res://data_setup.tscn"
## `--autobattle`: the AI-vs-AI screensaver demo (scripts/autobattle/autobattle.gd), straight from the command line.
const AUTOBATTLE_SCENE := "res://autobattle.tscn"
const Main := preload("res://scripts/main.gd")
## Touch UI, non-16:9 screens: parts of main_base2.png that must not show mirrored in the bands around the centred
## title frame (FrameFill / MirroredBackground.draw_mirrored `hide`): [part, clean stars drawn over it]. The FTL
## logo (with its glow) and the copyright line.
const TITLE_HIDE := [[Rect2(825, 55, 410, 200), Rect2(840, 320, 410, 200)],
	[Rect2(560, 668, 280, 60), Rect2(860, 600, 280, 60)]]
## Flags that do not, by themselves, ask for the sandbox / a run (the menu still shows).
const NEUTRAL_FLAGS := ["--input=", "--mute", "--no-mods", "--set=", "--log", "--debug", "--device-scale=",
	"--device-dpi=", "--data-setup", "--ftl-dat="]

var title: TitleState
var profile: InputProfile
var hud_root: Control
var menu_view: MainMenuView
var profile_view: ProfileView
var wallpaper_button: WallpaperButton  # [ours] PC only (null on touch / mobile / web)
var credits: CreditScreen  # main menu CREDITS (same screen as the victory credits)
var hangar_view: HangarView
var options: OptionsScreen  # our QoL / mod options (MOD OPTIONS button of the vanilla window)
var vanilla_options: VanillaOptionsView  # FTL's options window (Options button)
var stats_view: StatsView  # ScoreKeeper (Stats button)
var confirm_layer: Control  # ConfirmWindow `confirm_new_game` (New Game with a save present) + its click catcher
var confirm: ConfirmWindow
var toast: Label
var _toast_t := 0.0
var debug_layer: CanvasLayer
var debug_panel: PanelContainer
var debug_button: Button
var started := false  # START pressed (main.tscn requested)
var touch := false  # touch input profile: screens centred in the canvas, bands filled (FrameFill)
var frame_fill: Control  # touch only: mirrored background around the centred frame (scripts/ui/frame_fill.gd)
## Set by the in-game Esc menu's HANGAR command: the next title scene opens straight in the hangar.
static var open_hangar_next := false
## Set by the HUD calibration screen (main.gd) when it closes: the next title scene reopens the options window.
static var open_options_next := false
static var _setup_forced := false  # --data-setup already honoured (once per process)


## True when the command line asks for the game / sandbox directly (the menu is skipped).
static func skips_menu(args: PackedStringArray) -> bool:
	var menu := false
	var other := false
	for a in args:
		if a == "--menu" or a.begins_with("--menu-") or a.begins_with("--hangar"):
			menu = true
		elif a.begins_with("--screenshot=") or a.begins_with("--wait="):
			pass  # screenshots of the menu with --menu / --hangar; of the sandbox otherwise
		elif not NEUTRAL_FLAGS.any(func(f): return a == f or (f.ends_with("=") and a.begins_with(f))):
			other = true
	if menu:
		return false
	return other or Array(args).any(func(a): return a.begins_with("--screenshot="))


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var force_setup := args.has("--data-setup") and not _setup_forced and FrameHost.top_scene(get_tree()) == self
	if FtlData.root == "" or force_setup:  # no ftl-data: ask for the player's ftl.dat first (scripts/ui/data_setup.gd)
		_setup_forced = true
		FrameHost.change_scene(get_tree(), DATA_SETUP_SCENE)
		return
	# --autobattle, or the project setting ftl/autobattle/start (an override.cfg next to the exported exe: the
	# wallpaper build, which cannot pass command-line arguments everywhere; or its `wallpaper` feature tag override
	# in project.godot: the web wallpaper build).
	if args.has("--autobattle") or ProjectSettings.get_setting_with_override("ftl/autobattle/start") == true:
		FrameHost.change_scene(get_tree(), AUTOBATTLE_SCENE)
		return
	if skips_menu(args):
		FrameHost.change_scene(get_tree(), MAIN_SCENE)
		return
	RenderingServer.set_default_clear_color(Color.BLACK)
	var mode := InputProfile.TOUCH if DevicePreview.touch_default() else InputProfile.PC  # --device: the mouse is a finger
	for a in args:
		if a.begins_with("--input="):
			mode = a.trim_prefix("--input=")
		elif a == "--mute":
			FtlData.muted = true
	Main.input_mode = mode
	touch = mode == InputProfile.TOUCH
	Music.open_main_menu()  # MainMenu::Open: title music (rules/music.md §4); the hangar keeps it
	# The real game (not a test scene, not `--demo-profile` screenshots): load / apply the vanilla options.
	if FrameHost.top_scene(get_tree()) == self and not args.has("--demo-profile"):
		GameOptions.persist = true
		GameOptions.apply()
		SaveGame.persist = true  # continue.sav / profile.sav are written (rules/save_and_profile.md)
		PlayerProfile.persist = true
		ProfileSlots.start()  # [ours] three profiles: point the save / profile paths at the active slot
	title = TitleState.new()
	profile = InputProfile.new(mode)
	TooltipService.touch = mode == InputProfile.TOUCH
	TooltipService.hud_blocked = false
	profile.title = title
	_build()
	if open_hangar_next:
		open_hangar_next = false
		title.open_hangar()
	if open_options_next:
		open_options_next = false
		vanilla_options.show_screen()
	_handle_cli(args)


func _build() -> void:
	if touch:  # wide / tall phone screens: the bands around the centred 1280×720 frame show the screen's background
		frame_fill = preload("res://scripts/ui/frame_fill.gd").new()
		frame_fill.texture_fn = _screen_background
		add_child(frame_fill)
	hud_root = Control.new()
	hud_root.size = HudLayout.FRAME
	hud_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hud_root)
	menu_view = MainMenuView.new()
	menu_view.setup(title, profile)
	hud_root.add_child(menu_view)
	# [ours] local Wallpaper Engine wallpaper, bottom-left corner; PC only, under the profile window
	if not touch and not OS.has_feature("mobile") and not OS.has_feature("web"):
		wallpaper_button = WallpaperButton.new()
		hud_root.add_child(wallpaper_button)
		wallpaper_button.setup(menu_view, func(t: String) -> void: show_toast(t, 6.0))
	profile_view = ProfileView.new()  # [ours] three profiles, corner button at the top left
	hud_root.add_child(profile_view)
	profile_view.setup(title, menu_view)
	hangar_view = HangarView.new()
	hangar_view.visible = false
	hud_root.add_child(hangar_view)
	hangar_view.setup(title, profile)
	stats_view = StatsView.new()
	stats_view.visible = false
	hud_root.add_child(stats_view)
	stats_view.setup(title)
	_build_confirm()
	credits = CreditScreen.new()
	credits.visible = false
	hud_root.add_child(credits)
	vanilla_options = VanillaOptionsView.new()
	vanilla_options.visible = false
	hud_root.add_child(vanilla_options)
	vanilla_options.mod_options.connect(func(): options.show_screen())
	vanilla_options.calibrate.connect(open_hud_calibration)
	toast = Label.new()
	toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast.position = Vector2(190, 640)  # bottom line at y ~690 (a long one wraps upwards)
	toast.size = Vector2(900, 50)
	toast.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	toast.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	toast.add_theme_font_size_override("font_size", 18)
	toast.add_theme_color_override("font_outline_color", Color.BLACK)
	toast.add_theme_constant_override("outline_size", 6)
	toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast.visible = false
	hud_root.add_child(toast)
	_build_debug()
	if touch:
		get_viewport().size_changed.connect(_center_frame)
		_center_frame()


## MainMenu save confirm (ConfirmWindow, text `confirm_new_game`, buttons CONFIRM / CANCEL): every click goes to it;
## YES deletes the save and opens the hangar (TitleState NEW_GAME_CONFIRM), Esc = no.
func _build_confirm() -> void:
	confirm_layer = Control.new()
	confirm_layer.size = HudLayout.FRAME
	confirm_layer.mouse_filter = Control.MOUSE_FILTER_STOP
	confirm_layer.visible = false
	hud_root.add_child(confirm_layer)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.size = HudLayout.FRAME
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	confirm_layer.add_child(dim)
	confirm = ConfirmWindow.new("confirm_new_game", 300)
	confirm.yes_id = "button_confirm"
	confirm.no_id = "button_cancel"
	confirm_layer.add_child(confirm)
	confirm.answered.connect(func(yes: bool):
		confirm_layer.visible = false
		title.apply(TitleState.make(TitleState.NEW_GAME_CONFIRM, 1 if yes else 0)))
	confirm_layer.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			confirm.click(e.position))


## Touch UI: every screen keeps its 1280×720 layout, centred in the visible canvas (HudLayout.frame_offset; the
## views hit-test in local coordinates, so moving them is enough). PC: never called (frame at the origin).
func _center_frame() -> void:
	var at := HudLayout.frame_offset(hud_root, true)
	hud_root.position = at
	if options != null:
		options.position = at


## The background image of the screen shown (FrameFill mirrors it into the bands around the frame).
func _screen_background() -> Variant:
	if hangar_view != null and hangar_view.visible:
		return FtlData.texture("img/customizeUI/custom_background.png")  # HangarView._draw
	# MainMenuView._draw (stats / options are over it). The logo / copyright baked into main_base2.png are covered
	# with stars in the mirrored copies.
	return {"texture": FtlData.texture("img/main_menus/main_base2.png"), "hide": TITLE_HIDE}


## Debug overlay (not FTL): hidden; F12 / the DEBUG corner button / --debug. "Sandbox" opens the combat sandbox.
func _build_debug() -> void:
	debug_layer = CanvasLayer.new()
	debug_layer.layer = 10
	add_child(debug_layer)
	debug_panel = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.8)
	style.set_content_margin_all(4)
	debug_panel.add_theme_stylebox_override("panel", style)
	debug_layer.add_child(debug_panel)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	debug_panel.add_child(top)
	for pair in [["Sandbox", open_sandbox], ["Quick run (Kestrel)", func(): _start_run(_quick_config())]]:
		var b := Button.new()
		b.text = pair[0]
		b.custom_minimum_size = Vector2(130, 44)
		b.add_theme_font_size_override("font_size", 18)
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(pair[1])
		top.add_child(b)
	debug_panel.visible = Main.debug_visible
	debug_button = Button.new()
	debug_button.text = "DEBUG"
	debug_button.focus_mode = Control.FOCUS_NONE
	debug_button.add_theme_font_size_override("font_size", 10)
	debug_button.position = Vector2(1226, 2)
	debug_button.size = Vector2(50, 18)
	debug_button.modulate = Color(1, 1, 1, 0.45)
	debug_button.pressed.connect(toggle_debug)
	debug_layer.add_child(debug_button)
	options = OptionsScreen.new()
	options.visible = false
	debug_layer.add_child(options)


func toggle_debug() -> void:
	Main.debug_visible = not Main.debug_visible
	debug_panel.visible = Main.debug_visible


func _unhandled_key_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE and confirm_layer != null 			and confirm_layer.visible:
		confirm_layer.visible = false
		title.apply(TitleState.make(TitleState.NEW_GAME_CONFIRM, 0))
		get_viewport().set_input_as_handled()
		return
	if e is InputEventKey and e.pressed and e.keycode == KEY_F12:
		toggle_debug()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if title == null:
		return
	if credits != null and credits.showing:
		credits.step(delta)
		if credits.done():
			credits.skip()
	if title.pending != "":
		var p := title.pending
		title.pending = ""
		_consume(p)
	menu_view.visible = title.screen == TitleState.Screen.MENU
	if title.screen == TitleState.Screen.HANGAR and not hangar_view.visible:
		hangar_view.visible = true
		hangar_view.refresh()
	elif title.screen != TitleState.Screen.HANGAR:
		hangar_view.visible = false
	if _toast_t > 0.0:
		_toast_t -= delta
		toast.modulate.a = clampf(_toast_t, 0.0, 1.0)
		toast.visible = _toast_t > 0.0


func _consume(p: String) -> void:
	if p == "quit":
		get_tree().quit()
	elif p == "options":
		vanilla_options.show_screen()
	elif p == "stats":
		stats_view.open()
	elif p == "credits":
		credits.start("", [])
	elif p == "continue":
		continue_run()
	elif p == "confirm_new_game":
		confirm_layer.visible = true
	elif p == "delete_save":
		SaveGame.delete()
	elif p.begins_with("toast:"):
		show_toast(p.trim_prefix("toast:"))
	elif p == "start":
		_start_run(title.run_config())


func show_toast(t: String, secs := 2.5) -> void:
	toast.text = t
	toast.visible = true
	toast.modulate.a = 1.0
	_toast_t = secs


## Continue (finalChoice 9 → WorldManager::LoadGame): the saved run becomes RunState.current and main.tscn
## resumes it. The save file is deleted once read, as vanilla (WorldManager::LoadGame); the next save point rewrites it.
func continue_run() -> bool:
	var d := SaveGame.read()
	if d.is_empty():
		show_toast(FtlData.tr_id("no_load"))
		return false
	var run := SaveGame.restore(d)
	SaveGame.delete()  # WorldManager::LoadGame deletes the file once read; the next save point (or the app
	# going to the background on Android) writes it again
	started = true
	Main.run_mode = true
	Main.player_ship_name = String(run.ship.blueprint.get("name", "PLAYER_SHIP_HARD"))
	Main.run_setup = SaveGame.setup_of(d)
	ShipAI.difficulty = int(run.engine.difficulty)
	RunState.current = run
	Music.resume_run(run)
	FrameHost.change_scene(get_tree(), MAIN_SCENE)
	return true


func _quick_config() -> Dictionary:
	return {"ship": "PLAYER_SHIP_HARD", "difficulty": 1, "ae": true}


## START: main.gd run statics from the hangar, then main.tscn in run mode (the existing `--run` flow).
func _start_run(cfg: Dictionary) -> void:
	started = true
	prepare_run(cfg)
	FrameHost.change_scene(get_tree(), MAIN_SCENE)


## main.gd statics for a new run from the hangar (read by main.gd `_ensure_run`).
static func prepare_run(cfg: Dictionary) -> void:
	Main.run_mode = true
	Main.player_ship_name = String(cfg.ship)
	Main.run_setup = cfg
	ShipAI.difficulty = int(cfg.get("difficulty", 1))
	RunState.current = null


func open_sandbox() -> void:
	Main.run_mode = false
	Main.run_setup = {}
	RunState.current = null
	FrameHost.change_scene(get_tree(), MAIN_SCENE)


## Options window CALIBRATE HUD (touch): main.tscn as the HUD calibration sandbox (main.gd `calibrate_hud`; no run,
## nothing saved but the calibration); closing it comes back here with the options window open.
func open_hud_calibration() -> void:
	started = true
	Main.calibrate_hud = true
	Main.run_mode = false
	Main.run_setup = {}
	RunState.current = null
	FrameHost.change_scene(get_tree(), MAIN_SCENE)


func _handle_cli(args: PackedStringArray) -> void:
	var shot := ""
	var wait := 1.0
	var start := false
	for a in args:
		var v := a.get_slice("=", 1)
		if a == "--hangar":
			title.open_hangar()
		elif a.begins_with("--pointer="):  # screenshots: simulated pointer for tooltips / hover info
			var xy := a.trim_prefix("--pointer=").split(",")
			TooltipService.debug_pointer = Vector2(float(xy[0]), float(xy[1]))
		elif a.begins_with("--hangar-ship="):
			if title.screen != TitleState.Screen.HANGAR:
				title.open_hangar()
			var id := TitleState.SHIP_BLUEPRINTS.find(v) if not v.is_valid_int() else int(v)
			if id >= 0 and id < TitleState.SHIP_BLUEPRINTS.size():
				title.switch_ship(id, title.ship_type)
		elif a.begins_with("--hangar-type="):
			title.apply(TitleState.make(TitleState.SET_TYPE, int(v)))
		elif a.begins_with("--hangar-difficulty="):
			title.apply(TitleState.make(TitleState.SET_DIFFICULTY, ["easy", "normal", "hard"].find(v)))
		elif a.begins_with("--hangar-ae="):
			title.apply(TitleState.make(TitleState.SET_AE, int(v)))
		elif a == "--hangar-hide-rooms":  # HIDE ROOMS pressed (ShipBuilder::bShowRooms off)
			title.apply(TitleState.make(TitleState.TOGGLE_ROOMS))
		elif a == "--hangar-start":
			start = true
		elif a.begins_with("--screenshot="):
			shot = v
		elif a.begins_with("--wait="):
			wait = float(v)
		elif a == "--debug":
			Main.debug_visible = true
			debug_panel.visible = true
		elif a == "--menu-profiles" or a.begins_with("--menu-profiles="):  # [ours] profile window (=unlock:N / =delete:N: confirm)
			profile_view.activate("corner")
			if a.begins_with("--menu-profiles="):
				profile_view.activate(v)
		elif a == "--menu-options":
			vanilla_options.show_screen()
		elif a == "--menu-stats" or a.begins_with("--menu-stats="):
			stats_view.open()
			if a.begins_with("--menu-stats="):  # --menu-stats=L,R: left page 0/1, right page 0/1
				stats_view.left = int(v.get_slice(",", 0))
				stats_view.right = int(v.get_slice(",", 1))
				stats_view.open()
		elif a.begins_with("--hangar-list"):
			hangar_view.open_list()
			if a.begins_with("--hangar-list="):
				hangar_view.ship_list.open(title.ship_id, int(v))
	if shot != "" and not start:  # with --hangar-start the run scene takes the screenshot
		await get_tree().create_timer(wait).timeout
		await RenderingServer.frame_post_draw
		FrameHost.window_image(get_tree()).save_png(shot)
		print("screenshot: %s  screen=%s ship=%s type=%d name=%s crew=%s" % [shot,
			"hangar" if title.screen == TitleState.Screen.HANGAR else "menu",
			TitleState.blueprint_of(title.ship_id, title.ship_type), title.ship_type, title.ship_name,
			str(title.crew.map(func(c): return [c.race, c.name]))])
		get_tree().quit()
		return
	if start:
		title.apply(TitleState.make(TitleState.START))
