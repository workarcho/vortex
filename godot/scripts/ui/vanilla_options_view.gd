class_name VanillaOptionsView
extends Control
## FTL's own options window (OptionsScreen, rules/main_menu.md §3): `optionsUI_new.png` with the OPTIONS tab,
## VIDEO / GAMEPLAY / AUDIO frames, one clickable line per option (font 13; hovered = yellow), the sound / music
## SlideBars, DELETE PROFILE and CLOSE. Values live in `GameOptions`. Not FTL: a separate MOD OPTIONS button
## under the window opens our QoL / mod `OptionsScreen` (signal `mod_options`).
## Positions: OptionsScreen position (327,140), SlideBars at position + (230, 341 / 391) 200×20 (marker 15×30),
## labels font 13 centred at position + (156, 344 / 394), CLOSE right edge at position.x + 692 (+8 to match the
## screenshot), y + 301 [exe];
## window image, frame titles and line positions measured on the vanilla screenshot [screenshot 36].

signal closed
signal mod_options
signal calibrate  # touch: CALIBRATE HUD clicked (main menu only)

const POS := Vector2(327, 140)  # OptionsScreen::position
const WINDOW_AT := Vector2(230, 140)  # optionsUI_new.png [screenshot]
const VIDEO := ["fullscreen", "vsync", "frame_limit", "dynamic_bg", "colorblind", "language"]
const GAMEPLAY := ["event_choice", "show_paths", "achievement_popups", "focus_pause", "hotkeys"]
## Ours (not FTL), touch mode only: the open-Fold (tall canvas) combat layout, Split / Pan (GameOptions.fold_layout),
## a sixth GAMEPLAY line, and the phone (720-high canvas) combat layout, Column / Pan (GameOptions.phone_layout), the
## fifth line in place of "Configure Keyboard Hotkeys" (no keyboard in touch mode). Changing either in combat
## re-lays the HUD out at once (main.gd `_touch_layout_tick`).
## Ours, touch only: a CALIBRATE HUD button under MOD OPTIONS (a seventh GAMEPLAY line would overflow the frame)
## opens the HUD calibration screen (signal `calibrate`; title.gd -> main.gd calibration sandbox); in a run
## (`in_run`) it only says to use the main menu's Options.
const TOUCH_GAMEPLAY := ["phone_layout", "fold_layout"]
const PC_GAMEPLAY := ["window_size"]  # ours, PC only: GameOptions.window_size (sixth GAMEPLAY line)
const LINE_FONT := 13
const LINE_X := [261, 661]  # VIDEO / GAMEPLAY text left edges [screenshot]
const LINE_Y := 224  # first line top; step 34 [screenshot]
const LINE_STEP := 34
const SLIDER_W := 200
const SLIDER_H := 20
const MARKER := Vector2(15, 30)

var hover := ""  # option key, button name or slider ("sound" / "music")
var buttons := {}
var message := ""
var _msg_t := 0.0
var _drag := ""  # slider being dragged
var in_run := false  # opened from the in-run Esc menu (main.gd): no HUD calibration from here


func _ready() -> void:
	position = Vector2.ZERO
	size = HudLayout.FRAME
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_buttons()


func show_screen() -> void:
	visible = true
	hover = ""
	message = ""
	_build_buttons()
	queue_redraw()


func hide_screen() -> void:
	if not visible:
		return
	visible = false
	_drag = ""
	closed.emit()


func _build_buttons() -> void:
	buttons.clear()
	var close := FtlData.tr_id("button_close")
	var cw := maxi(103, FtlData.ftl_text_width(63, close) + 24)  # SetAutoWidth(true, false, 3, 0) on 103×32
	buttons["close"] = {"rect": Rect2(POS.x + 700 - cw, POS.y + 301, cw, 32), "label": close, "font": 63,
		"base": "storeUI/store_close_base.png", "base_off": Vector2(-23, -7)}
	buttons["wipe"] = {"rect": Rect2(258, 480, 131, 60), "label": FtlData.tr_id("button_delete_profile").replace("\\n", "\n"),
		"font": 63, "line_h": 26, "y_off": -2, "base": "optionsUI/button_deleteprofile_base.png", "base_off": Vector2(-15, -15)}
	var mw := FtlData.ftl_text_width(62, "MOD OPTIONS") + 24
	buttons["mods"] = {"rect": Rect2(POS.x + 692 - mw, 498, mw, 28), "label": "MOD OPTIONS", "font": 62}
	if TooltipService.touch:
		var cal := FtlData.tr_id("calibrate_hud").to_upper()
		var kw := FtlData.ftl_text_width(62, cal) + 24
		buttons["calibrate_hud"] = {"rect": Rect2(POS.x + 692 - kw, 536, kw, 28), "label": cal, "font": 62}


static func slider_box(which: String) -> Rect2:
	return Rect2(POS.x + 230, POS.y + (341 if which == "sound" else 391), SLIDER_W, SLIDER_H)


## SlideBar: marker x between box.x + 5 and box.end − 5 − marker width (minMax), proportional to the volume.
static func marker_rect(which: String) -> Rect2:
	var v := GameOptions.sound_volume if which == "sound" else GameOptions.music_volume
	return MenuDraw.slide_marker(slider_box(which), v)


## The GAMEPLAY lines shown: FTL's, plus TOUCH_GAMEPLAY in touch mode (TooltipService.touch; hotkeys hidden there).
static func gameplay_keys() -> Array:
	if not TooltipService.touch:
		return GAMEPLAY + PC_GAMEPLAY
	return GAMEPLAY.filter(func(k: String) -> bool: return k != "hotkeys") + TOUCH_GAMEPLAY


static func line_rect(k: String) -> Rect2:
	var col := 0 if k in VIDEO else 1
	var i: int = (VIDEO if col == 0 else gameplay_keys()).find(k)
	var w := FtlData.ftl_text_width(LINE_FONT, GameOptions.line(k))
	return Rect2(LINE_X[col], LINE_Y + LINE_STEP * i, maxf(w, 40), 22)


func item_at(p: Vector2) -> String:
	var b := MenuDraw.button_at(buttons, p)
	if b != "":
		return b
	for k in VIDEO + gameplay_keys():
		if line_rect(k).grow(3).has_point(p):
			return k
	for s in ["sound", "music"]:
		if slider_box(s).grow_individual(0, 6, 0, 6).has_point(p) or marker_rect(s).has_point(p):
			return s
	return ""


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		if _drag != "":
			_set_slider(_drag, e.position.x)
		var h := item_at(e.position)
		if h != hover and h != "":
			FtlData.play("hoverBeep")
		hover = h
		queue_redraw()
	elif e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed:
			click(e.position)
		else:
			if _drag != "":
				GameOptions.save()
			_drag = ""
	accept_event()


func _unhandled_key_input(e: InputEvent) -> void:
	if visible and e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE:
		hide_screen()
		get_viewport().set_input_as_handled()


## OptionsScreen::MouseClick: a line cycles its value; CLOSE closes; the sliders jump to the pointer and drag.
func click(p: Vector2) -> String:
	var it := item_at(p)
	match it:
		"":
			pass
		"close":
			hide_screen()
		"mods":
			mod_options.emit()
		"wipe":
			_say("No profile yet: nothing to delete.")
		"language":
			_say("Only English is available.")
		"hotkeys":
			_say("Hotkey configuration is not implemented yet.")
		"calibrate_hud":
			if in_run:
				_say(FtlData.tr_id("calibrate_hud_in_run"))
			else:
				calibrate.emit()
		"sound", "music":
			_drag = it
			_set_slider(it, p.x)
		_:
			GameOptions.cycle(it)
	queue_redraw()
	return it


func _set_slider(which: String, x: float) -> void:
	var v := MenuDraw.slide_value(slider_box(which), x)
	GameOptions.set_value("sound_volume" if which == "sound" else "music_volume", v)
	GameOptions.apply()
	queue_redraw()


func _say(t: String) -> void:
	message = t
	_msg_t = 2.5


func _process(delta: float) -> void:
	if _msg_t > 0.0:
		_msg_t -= delta
		if _msg_t <= 0.0:
			message = ""
			queue_redraw()


func _draw() -> void:
	draw_rect(HudLayout.cover_rect(self, TooltipService.touch), Color(0, 0, 0, 0.72))  # MainMenu tint behind the dialog
	MenuDraw.img(self, "optionsUI_new.png", WINDOW_AT)
	FtlData.draw_ftl_text(self, 63, FtlData.tr_id("options_tab"), Vector2(353, 150), MenuDraw.COL_TEXT,
		FtlFont.Align.CENTER)
	FtlData.draw_ftl_text(self, 62, FtlData.tr_id("options_frame_video"), Vector2(252, 185), MenuDraw.COL_TEXT)
	FtlData.draw_ftl_text(self, 62, FtlData.tr_id("options_frame_gameplay"), Vector2(650, 185), MenuDraw.COL_TEXT)
	FtlData.draw_ftl_text(self, 62, FtlData.tr_id("options_frame_audio"), Vector2(413, 433), MenuDraw.COL_TEXT)
	for k in VIDEO + gameplay_keys():
		var r := line_rect(k)
		FtlData.draw_ftl_text(self, LINE_FONT, GameOptions.line(k), r.position,
			MenuDraw.COL_SELECT if hover == k else Color.WHITE)
	for s in ["sound", "music"]:
		var lab := FtlData.tr_id("sound_volume" if s == "sound" else "music_volume")
		FtlData.draw_ftl_text(self, 13, lab, Vector2(POS.x + 156, POS.y + (344 if s == "sound" else 394)),
			Color.WHITE, FtlFont.Align.CENTER)
		MenuDraw.slide_bar(self, slider_box(s), marker_rect(s), hover == s or _drag == s)
	for nm in buttons:
		var b: Dictionary = buttons[nm]
		if b.has("base"):
			MenuDraw.img(self, String(b.base), (b.rect as Rect2).position + (b.base_off as Vector2))
		MenuDraw.text_button(self, b, hover == nm)
	if message != "":
		FtlData.draw_ftl_text(self, 13, message, Vector2(640, 600), MenuDraw.COL_SELECT, FtlFont.Align.CENTER)
