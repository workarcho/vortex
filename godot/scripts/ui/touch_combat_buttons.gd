class_name TouchCombatButtons
extends Control
## Touch combat PAUSE / CANCEL buttons (touch input profile only; rules/ui_layout_strategy.md "Touch gestures
## (combat)"). [ours] — FTL PC has no pause button; FTL iPad's own button art was not reverse-engineered, so both
## use the PC FTL drive JUMP button look: `buttons/FTL/FTL_base.png` (98×55) with the JUMP text rect (12, 13) 74×29
## inside it (rules/hud_layout.md: base (524, 22), text rect (536, 35)), text font 62 centred, the lit state = the
## ready JUMP (TextButton active fill (235, 245, 0), text (37, 74, 77) / held (62, 125, 131)).
## Texts: `button_pause` ("PAUSE", text_misc.xml: "Only used on iPad") and `button_cancel` ("CANCEL").
##
## Placement (main.gd `_touch_selection_tick` → `place`): drawn at the CommandHud's scale; CANCEL at the JUMP
## button's x, bottom edge on the layout bottom; PAUSE immediately left of it (GAP). Both slots are fixed: PAUSE is
## always shown in touch combat, CANCEL only in selection mode (its slot stays empty otherwise), so nothing moves.
## PAUSE is lit while the game is paused (toggle on); CANCEL is always lit. Input is routed by main.gd `_input`
## (`button_at`), before the crew / ship taps; this control itself ignores the mouse.

const BASE := "buttons/FTL/FTL_base.png"
const BASE_SIZE := Vector2(98, 55)
const TEXT_RECT := Rect2(12, 13, 74, 29)  # JUMP text rect relative to the base
const GAP := 2.0  # px (× scale) between the two bases [ours]
const READY_FILL := Color(0.92156863, 0.9607843, 0.0)
const READY_TEXT := Color8(37, 74, 77)
const READY_TEXT_HOT := Color8(62, 125, 131)

var art_scale := 1.0
var cancel_pos := Vector2.ZERO  # base top-left (this control's coordinates = the HUD frame)
var pause_pos := Vector2.ZERO
var cancel_shown := false
var paused := false  # the game is paused (PAUSE drawn lit)
var pressed_button := ""  # "pause" / "cancel" while a finger holds it
## Stacked placement (main.gd open-Fold "split" layout): PAUSE at `jump_x` with its bottom on `bottom`, CANCEL GAP
## above it, same x (instead of side by side).
var stacked := false
## Mirrored side-by-side placement (main.gd phone column layout: PAUSE under the weapons column): PAUSE's base at
## `jump_x`, CANCEL GAP left of it.
var cancel_left := false


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## CANCEL's (`cancel_left`: PAUSE's) base left edge at `jump_x`, the bases' bottom on `bottom`, both at `s` (the CommandHud scale).
func place(jump_x: float, bottom: float, s: float) -> void:
	art_scale = s
	if stacked:
		pause_pos = Vector2(jump_x, bottom - BASE_SIZE.y * s).round()
		cancel_pos = (pause_pos - Vector2(0, (BASE_SIZE.y + GAP) * s)).round()
		return
	if cancel_left:
		pause_pos = Vector2(jump_x, bottom - BASE_SIZE.y * s).round()
		cancel_pos = (pause_pos - Vector2((BASE_SIZE.x + GAP) * s, 0)).round()
		return
	cancel_pos = Vector2(jump_x, bottom - BASE_SIZE.y * s).round()
	pause_pos = (cancel_pos - Vector2((BASE_SIZE.x + GAP) * s, 0)).round()


func rect_of(id: String) -> Rect2:
	return Rect2(cancel_pos if id == "cancel" else pause_pos, BASE_SIZE * art_scale)


## "pause" / "cancel" / "" at a HUD-frame point (only shown buttons).
func button_at(p: Vector2) -> String:
	if not is_visible_in_tree():
		return ""
	if cancel_shown and rect_of("cancel").has_point(p):
		return "cancel"
	if rect_of("pause").has_point(p):
		return "pause"
	return ""


func _process(_d: float) -> void:
	queue_redraw()


func _draw() -> void:
	_draw_button(pause_pos, label("button_pause", "PAUSE"), paused, pressed_button == "pause")
	if cancel_shown:
		_draw_button(cancel_pos, label("button_cancel", "CANCEL"), true, pressed_button == "cancel")


func _draw_button(at: Vector2, text: String, lit: bool, hot: bool) -> void:
	draw_jump_look(self, at, art_scale, text, "lit" if lit else "on", hot)
	draw_set_transform(Vector2.ZERO)


## Shared touch button look (also the beacon / sector map JUMP buttons): FTL_base.png at `at` scaled by `s` with
## the JUMP text rect; `state` "lit" = the ready JUMP (yellow fill, dark text, `hot` = held text colour), "on" =
## unlit with COLOR_BUTTON_ON text (`hot` = yellow text), "off" = disabled (text COLOR_BUTTON_ON at α 0.35, the
## charging JUMP). Leaves the canvas transform set; callers reset it.
static func draw_jump_look(ci: CanvasItem, at: Vector2, s: float, text: String, state: String, hot := false) -> void:
	ci.draw_set_transform(at, 0.0, Vector2(s, s))
	HudDraw.img(ci, BASE, Vector2.ZERO)
	var r := TEXT_RECT
	var c := HudLayout.BUTTON_ON
	if state == "lit":
		ci.draw_rect(Rect2(r.position.x + 2, r.position.y, r.size.x - 4, r.size.y), READY_FILL)
		ci.draw_rect(Rect2(r.position.x, r.position.y + 2, r.size.x, r.size.y - 4), READY_FILL)
		ci.draw_rect(Rect2(r.position.x + 1, r.position.y + 1, r.size.x - 2, r.size.y - 2), READY_FILL)
		c = READY_TEXT_HOT if hot else READY_TEXT
	elif state == "off":
		c = Color(HudLayout.BUTTON_ON, 0.35)
	elif hot:
		c = READY_FILL
	HudDraw.text(ci, 62, text, Vector2(r.get_center().x, r.position.y + 4), c, 1)


## A text id's translation, `fallback` when the id is missing.
static func label(id: String, fallback: String) -> String:
	var s := HudDraw.txt(id)
	return fallback if s == "" or s == id else s
