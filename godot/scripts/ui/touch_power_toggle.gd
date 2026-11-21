class_name TouchPowerToggle
extends Control
## Touch combat power mode toggle (+ / −) (touch input profile only; rules/ui_layout_strategy.md "Touch gestures
## (combat)", "Power mode"). [ours] — FTL has no such control: on PC removing power is the right click, which a
## finger does not have. Two buttons, one lit at a time:
##   + (default)  system column / power row tap = +1; weapon / drone box tap = power it (a powered weapon arms, an
##                armed one keeps the normal click); a powered drone box tap does nothing (+ never removes power).
##   −            system column tap = −1; power row tap = depower the last powered weapon / drone; weapon / drone
##                box tap = depower that item completely (an armed weapon is disarmed too).
## Held finger (TouchGestures `held_minus`): while one finger rests ≥ TouchGestures.HOLD_MS, − is shown lit and a
## second finger's tap acts in − mode (`held_fn`; desktop stand-in: Ctrl held). Long press = the
## tooltip only (no hold-to-depower in the touch column). Tooltip of this box: `tooltip_power_mode` (our text,
## godot/data/text_ours.xml).
##
## Look: a second crew-buttons box (CrewList.draw_tailless_box: button_door_base.png without its pointer tail) with
## two 20 × 20 station-style buttons in the doors slots (10, 10) = +, (10, 33) = −: lit = filled green / red with the
## dark station glyph colour, unlit = dark slot, glyph in the dimmed colour, 1 px grey outline. No FTL sprite fits
## (numbers/Text_plus.png / Text_minus.png are damage-number glyphs, white with a black outline; nothing green / red).
##
## Placement (main.gd `_touch_layout`): position = canvas top-left of the image, scale = the crew list's
## (TOUCH_TOPLEFT_SCALE); BELOW art px under the crew buttons box image (2 px between the solid art). Hit testing is
## local (`button_at` maps the screen point through this node's canvas transform); main.gd `_touch_buttons_input`
## routes the press (acts on the press, like PAUSE / CANCEL). This control ignores the mouse itself.
##
## Taps are routed by the panels / columns through `removing()` / `adding()` / `route()` (static: the one live
## toggle, `current`). Without a live toggle (PC profile) both are false and every route is the plain click.

const SIZE := Vector2(40, 63)  # CrewList.BOX_BODY_H + its mirrored glow
const SLOT_PLUS := Rect2(10, 10, 20, 20)
const SLOT_MINUS := Rect2(10, 33, 20, 20)
## Tap areas (local): each half of the solid box (x 4..36, y 4..59), so a finger needs no 20 px precision.
const HIT_PLUS := Rect2(4, 4, 32, 27.5)
const HIT_MINUS := Rect2(4, 31.5, 32, 27.5)
const BELOW := 53.0  # art px from the crew box image top: its solid bottom (57) + 2 − this box's solid top (6)
const GLYPH := Color8(53, 75, 89)  # statusUI/button_station_*: glyph colour (354b59)
const SLOT_DARK := Color8(32, 44, 52)
const OUTLINE := Color8(164, 171, 160)  # button_station_*_off fill (a4aba0)

static var current: TouchPowerToggle = null
static var forced := false  # main.gd `_touch_minus_tap`: a second finger's tap is being dispatched in − mode

var minus := false  # the sticky mode (the buttons)
var held_fn: Callable  # () -> bool: a finger is held (TouchGestures.held_minus): − for now


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size = SIZE


func _enter_tree() -> void:
	current = self


func _exit_tree() -> void:
	if current == self:
		current = null


static func _live() -> TouchPowerToggle:
	return current if current != null and is_instance_valid(current) and current.is_inside_tree() else null


## A touch toggle exists (touch combat layout); false on PC.
static func live() -> bool:
	return _live() != null


## − is in effect (a live touch toggle): the sticky − mode, a held finger, or a second finger's tap being dispatched.
## A held finger only lights − (shows_minus); its own lift is never a − tap (a long press for a tooltip must not
## remove power) — only a second finger's tap (`forced`) or Ctrl (desktop stand-in) is.
static func removing() -> bool:
	var t := _live()
	return t != null and (t.minus or forced or Input.is_key_pressed(KEY_CTRL))


## + is in effect on a live touch toggle (false on PC: no toggle).
static func adding() -> bool:
	return live() and not removing()


func shows_minus() -> bool:
	return minus or forced or (held_fn.is_valid() and bool(held_fn.call()))


## A slot click callable (i) that calls `remove` instead of `add` in − mode.
static func route(add: Callable, remove: Callable) -> Callable:
	return func(i: int) -> void: (remove if removing() else add).call(i)


## Same for a no-argument action (the touch column power rows).
static func route0(add: Callable, remove: Callable) -> Callable:
	return func() -> void: (remove if removing() else add).call()


## "plus" / "minus" / "" at a screen (canvas) point, through this node's canvas transform.
func button_at(screen: Vector2) -> String:
	if not is_visible_in_tree():
		return ""
	var p := get_global_transform().affine_inverse() * screen
	if HIT_PLUS.has_point(p):
		return "plus"
	if HIT_MINUS.has_point(p):
		return "minus"
	return ""


func press(id: String) -> void:
	var m := id == "minus"
	if m != minus:
		minus = m
		FtlData.play("powerDownSystem" if m else "powerUpSystem")
	queue_redraw()


func _process(_delta: float) -> void:
	if TooltipService.over(self, Rect2(HIT_PLUS.position, HIT_PLUS.size + Vector2(0, HIT_MINUS.size.y))):
		TooltipService.request(TooltipText.simple("button", "tooltip_power_mode"), {"width": TooltipService.WRAP_BOX,
			"kind": &"button", "source": self})
	queue_redraw()


func _draw() -> void:
	CrewList.draw_tailless_box(self, Vector2.ZERO)
	var m := shows_minus()
	_button(SLOT_PLUS, FtlColors.GREEN, not m, false)
	_button(SLOT_MINUS, FtlColors.RED, m, true)


func _button(r: Rect2, col: Color, lit: bool, is_minus: bool) -> void:
	if lit:
		draw_rect(r, col)
	else:
		draw_rect(r, SLOT_DARK)
		draw_rect(Rect2(r.position + Vector2(0.5, 0.5), r.size - Vector2.ONE), OUTLINE, false, 1.0)
	# Station-style corners: the two outer pixels of each corner dark.
	for c in [r.position, Vector2(r.end.x - 1, r.position.y), Vector2(r.position.x, r.end.y - 1), r.end - Vector2.ONE]:
		draw_rect(Rect2(c, Vector2.ONE), GLYPH)
	var g := GLYPH if lit else col.darkened(0.15)
	var c := r.position + Vector2(10, 10)
	draw_rect(Rect2(c - Vector2(6, 2), Vector2(12, 4)), g)  # bar 12 × 4
	if not is_minus:
		draw_rect(Rect2(c - Vector2(2, 6), Vector2(4, 12)), g)
