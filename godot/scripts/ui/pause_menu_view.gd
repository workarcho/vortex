class_name PauseMenuView
extends Control
## The in-game Esc menu (MenuScreen, rules/main_menu.md §6). `optionsUI/escape_main.png` (162×295) centred on
## (490,360) → position (409,213); seven TextButtons 128×24 font 62 at position + (17, 18 / 69 / 106 / 143 / 180 /
## 217 / 254): CONTINUE, MAIN MENU, HANGAR, RESTART, OPTIONS, CONTROLS, SAVE+QUIT [exe]. Status boxes
## (`info_difficulty.png`, `info_dlc.png` 3 px apart, `info_achievements.png` below): labels font 13 COLOR_BUTTON_ON
## at +16, values font 62 COLOR_BUTTON_TEXT at +40, "Current Ship Achievements" at +90, ship achievements in
## the box (64 px ×3, then the 32 px victory / quest markers) [exe]; status position (614,244) and the icon
## offsets from screenshot 45. Commands go out through `command(name)`; the owner (main.gd) acts on them.
## Save+Quit quits to the main menu (no save system yet); Controls shows a placeholder line.
## HANGAR / RESTART ask first (MenuScreen::MouseClick / OnTouch: commands 0, 2 and 6 store `tempCommand` and open
## `confirmDialog`, a ConfirmWindow with `confirm_end_game` "Are you sure? All progress will be lost.", min width 300,
## auto-centred, YES / NO; while it is open every click / hover goes to it, YES sends the stored command, NO drops it;
## MenuScreen::Open closes it, and Esc closes the whole menu [exe]).

signal command(name: String)

const CONFIRM_COMMANDS := ["hangar", "reset"]  # MenuScreen commands 6 / 0 (2 has no button in this menu)

const POS := Vector2(418, 216)  # exe (409,213); 1.6.14 draws it 9 px right, 3 px down [screenshot 45]
const BUTTON_Y := [18, 69, 106, 143, 180, 217, 254]
const NAMES := ["continue", "mainmenu", "hangar", "reset", "options", "controls", "save"]
const STATUS := Vector2(614, 244)
const ACH_AT := Vector2(636, 362)  # first ship achievement icon [screenshot 45]

var difficulty := 1
var ae := true
var ship_id := 0
var ship_bp := ""  # the run's ship blueprint (its class fills the victory / quest marker tooltips)
var hover := ""
var buttons := {}
var message := ""
var confirm: ConfirmWindow  # confirmDialog (`confirm_end_game`), drawn over the menu in its frame coordinates
var pending := ""  # tempCommand: the command waiting for the confirm's YES ("" = none)


func _ready() -> void:
	position = Vector2.ZERO
	size = HudLayout.FRAME
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()
	_ensure_confirm()


func _ensure_confirm() -> void:
	if confirm != null:
		return
	confirm = ConfirmWindow.new("confirm_end_game", 300)
	confirm.visible = false
	add_child(confirm)


## Opens / closes the confirm. While it is open MenuScreen::OnRender draws the menu under GL_SetColorTint
## (0.5, 0.5, 0.5, 1) (consts 0x830010..1c) and the confirm untinted (GL_RemoveColorTint first).
func _show_confirm(on: bool) -> void:
	_ensure_confirm()
	confirm.visible = on
	self_modulate = Color(0.5, 0.5, 0.5, 1.0) if on else Color.WHITE
	queue_redraw()


## The end-game confirm is open (HANGAR / RESTART pressed, not answered yet).
func confirming() -> bool:
	return confirm != null and confirm.visible


func open(diff: int, ae_on: bool, ship_blueprint: String) -> void:
	difficulty = diff
	ae = ae_on
	ship_id = maxi(0, TitleState.SHIP_BLUEPRINTS.find(ship_blueprint.trim_suffix("_2").trim_suffix("_3")))
	ship_bp = ship_blueprint
	visible = true
	hover = ""
	message = ""
	_build()
	_show_confirm(false)  # MenuScreen::Open: ConfirmWindow::Close, tempCommand = -1
	pending = ""
	queue_redraw()


func _build() -> void:
	buttons.clear()
	for i in NAMES.size():
		buttons[NAMES[i]] = {"rect": Rect2(POS + Vector2(17, BUTTON_Y[i]), Vector2(128, 24)),
			"label": FtlData.tr_id("escape_" + NAMES[i]), "font": 62}


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		var h := "" if confirming() else MenuDraw.button_at(buttons, e.position)  # the confirm takes the hover
		if h != hover and h != "":
			FtlData.play("hoverBeep")
		hover = h
		queue_redraw()
	elif e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT and e.pressed:
		click(e.position)
	accept_event()


func _unhandled_key_input(e: InputEvent) -> void:
	if visible and e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		_send("continue")


## A press at `p` (frame coordinates). Returns the menu button hit ("" none); with the confirm open, "confirm_yes" /
## "confirm_no" for its buttons ("" elsewhere: it stays open).
func click(p: Vector2) -> String:
	if confirming():
		var r := confirm.click(p)
		if r < 0:
			return ""
		_show_confirm(false)
		var c := pending
		pending = ""
		if r == 1:
			_send(c)
		queue_redraw()
		return "confirm_yes" if r == 1 else "confirm_no"
	var nm := MenuDraw.button_at(buttons, p)
	if nm == "controls":
		message = "Controls screen is not implemented yet."
		queue_redraw()
	elif CONFIRM_COMMANDS.has(nm):
		_ensure_confirm()
		pending = nm
		_show_confirm(true)
		hover = ""
		queue_redraw()
	elif nm != "":
		_send(nm)
	return nm


## MenuScreen::OnLanguageChange icon places (64 px ×3 70 apart, then the 32 px victory marker 34 px lower and the
## quest marker above it; offsets fitted to screenshot 45) with their `dimension` (64 / 32) as hit rects.
func achievement_rects(achs: Array) -> Array:
	var out := []
	for i in achs.size():
		var p := ACH_AT + Vector2(70 * i, 0) if i < 3 else ACH_AT + Vector2(222, 34 if i == 3 else 0)
		var d := float(achs[i].get("dim", 64))
		out.append(Rect2(p, Vector2(d, d)))
	return out


var ach_hover := -1  # MenuScreen::selectedAch


func _process(_d: float) -> void:
	if is_visible_in_tree():
		hover_tooltips(TooltipService.local_pointer(self))


## MenuScreen::MouseMove (not while the end-game confirm is open): the current ship's achievement icon strictly
## under the pointer gets AchievementTracker::SetTooltip (instant). Touch: while the finger is held
## (TooltipService). Returns the requested tooltip text ("" none).
func hover_tooltips(m: Vector2) -> String:
	var h := -1
	if not confirming():
		var achs := MenuDraw.ship_achievements(ship_id)
		h = MenuDraw.achievement_hover(self, achs, achievement_rects(achs), m,
			ship_bp if ship_bp != "" else String(TitleState.SHIP_BLUEPRINTS[ship_id]))
	if h != ach_hover:
		ach_hover = h
		queue_redraw()
	return TooltipService.text


func _send(nm: String) -> void:
	if nm == "continue":
		visible = false
		if confirm != null:
			_show_confirm(false)  # Esc closes the whole menu, the confirm with it
		pending = ""
	command.emit(nm)


func _draw() -> void:
	draw_rect(HudLayout.cover_rect(self, TooltipService.touch), Color(0, 0, 0, 0.6))
	MenuDraw.img(self, "optionsUI/escape_main.png", POS)
	for nm in buttons:
		MenuDraw.text_button(self, buttons[nm], hover == nm)
	# Status boxes: difficulty | AE content, then the current ship's achievements.
	var dw := MenuDraw.img(self, "optionsUI/info_difficulty.png", STATUS).x
	var aw := MenuDraw.img(self, "optionsUI/info_dlc.png", STATUS + Vector2(dw + 3, 0)).x
	var achw := MenuDraw.img(self, "optionsUI/info_achievements.png", STATUS + Vector2(0, 74)).x
	var on := MenuDraw.COL_ON
	FtlData.draw_ftl_text(self, 13, FtlData.tr_id("menu_status_difficulty"), STATUS + Vector2((dw + 1) / 2, 16), on,
		FtlFont.Align.CENTER)
	FtlData.draw_ftl_text(self, 13, FtlData.tr_id("menu_status_ae_content"),
		STATUS + Vector2(dw + 3 + (aw + 1) / 2, 16), on, FtlFont.Align.CENTER)
	FtlData.draw_ftl_text(self, 13, FtlData.tr_id("menu_status_achievements"), STATUS + Vector2((achw + 1) / 2, 90),
		on, FtlFont.Align.CENTER)
	var diff_id: String = ["easy_button", "normal_button", "hard_button"][clampi(difficulty, 0, 2)]
	FtlData.draw_ftl_text(self, 62, FtlData.tr_id(diff_id), STATUS + Vector2((dw + 1) / 2, 40), MenuDraw.COL_TEXT,
		FtlFont.Align.CENTER)
	FtlData.draw_ftl_text(self, 62, FtlData.tr_id("advanced_on_button" if ae else "advanced_off_button"),
		STATUS + Vector2(dw + 3 + (aw + 1) / 2, 40), MenuDraw.COL_TEXT, FtlFont.Align.CENTER)
	# MenuScreen::OnRender: CAchievement::OnRender(pos, style, showNew = true); style 1 / 0 for the 64 px icons,
	# 2 / 3 for the markers (hovered / not).
	var achs := MenuDraw.ship_achievements(ship_id)
	var rects := achievement_rects(achs)
	for i in achs.size():
		var style := (1 if ach_hover == i else 0) if i < 3 else (2 if ach_hover == i else 3)
		MenuDraw.draw_achievement(self, achs[i], rects[i].position, false, style, true)
	if message != "":
		FtlData.draw_ftl_text(self, 13, message, Vector2(490, 520), MenuDraw.COL_SELECT, FtlFont.Align.CENTER)
