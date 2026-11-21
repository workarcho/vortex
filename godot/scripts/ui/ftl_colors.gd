class_name FtlColors
extends RefCounted
## UI palette. The values named COLOR_* are the original game's
## (ShipSystem static initializer; see rules/power.md).

const GREEN := Color8(100, 255, 100)  # COLOR_GREEN
const RED := Color8(255, 50, 50)  # COLOR_RED
const BLUE := Color8(133, 231, 237)  # COLOR_BLUE_ION
const PURPLE_HACK := Color8(207, 70, 253)  # COLOR_PURPLE_HACKING
const YELLOW := Color8(255, 255, 50)  # COLOR_YELLOW
const ORANGE := Color8(255, 153, 76)  # COLOR_ORANGE
const GREY := Color8(125, 125, 125)  # COLOR_GRAY
const LOST := Color8(40, 210, 230)  # bar lost to an event (X)
const BATTERY := Color8(230, 110, 30)
const BONUS := Color8(255, 250, 90)

# Prototype-specific
const GREEN_DIM := Color8(40, 110, 40)
const WHITE := Color8(235, 235, 235)
const GREY_DARK := Color8(50, 55, 60)
const PANEL := Color8(24, 30, 38, 235)
const PANEL_EDGE := Color8(200, 210, 220)
const SELECTED := Color8(255, 230, 120)


## Draws a power bar according to its state (SystemState.bar_state), with the three primitives of
## SystemControl::GetPowerBars (rules/power.md "How the bars are drawn"): `normal` = filled rect, `empty` =
## 1 px outline (2 px when the bar is 12 px tall), `damaged` = the outline plus a 1-pixel "/" stair from the
## bottom-left to the top-right corner. Free bars = white outline; broken = red damaged; event-lost = (40,210,230)
## damaged; battery = green inset (`tiny`) inside an orange outline.
static func draw_power_bar(ci: CanvasItem, r: Rect2, state: String) -> void:
	match state:
		"on":
			ci.draw_rect(r, GREEN)
		"white":  # untinted bar: lock counter -1 (system in use)
			ci.draw_rect(r, Color.WHITE)
		"ion":
			ci.draw_rect(r, BLUE)
		"bonus":  # zoltan bonus bar
			ci.draw_rect(r, BONUS)
		"hack":
			ci.draw_rect(r, PURPLE_HACK)
		"battery":
			ci.draw_rect(r.grow(-2), GREEN)
			draw_bar_outline(ci, r, BATTERY)
		"free":
			draw_bar_outline(ci, r, Color.WHITE)
		"lost":
			draw_bar_damaged(ci, r, LOST)
		"broken":
			draw_bar_damaged(ci, r, RED)


## GetPowerBars `empty` texture: outline 1 px (2 px for 12 px tall bars), inside the rect.
static func draw_bar_outline(ci: CanvasItem, r: Rect2, c: Color, thickness := 0.0) -> void:
	var t := thickness if thickness > 0.0 else (2.0 if roundi(r.size.y) == 12 else 1.0)
	ci.draw_rect(Rect2(r.position, Vector2(r.size.x, t)), c)
	ci.draw_rect(Rect2(r.position.x, r.end.y - t, r.size.x, t), c)
	ci.draw_rect(Rect2(r.position.x, r.position.y + t, t, r.size.y - 2 * t), c)
	ci.draw_rect(Rect2(r.end.x - t, r.position.y + t, t, r.size.y - 2 * t), c)


## GetPowerBars `damaged` texture: the outline plus, for every column x of the bar, the pixel at
## y = round((1 − x / (w − 1)) · (h − 1)) (a "/" stair, bottom-left to top-right).
static func draw_bar_damaged(ci: CanvasItem, r: Rect2, c: Color) -> void:
	draw_bar_outline(ci, r, c)
	var w := roundi(r.size.x)
	var h := roundi(r.size.y)
	for x in w:
		var y := roundi((1.0 - float(x) / maxf(w - 1, 1)) * (h - 1))
		ci.draw_rect(Rect2(r.position.x + x, r.position.y + y, 1, 1), c)


## System outline color: hacking, ion / cooldown lock (blue), indefinite lock (white) or none.
static func lock_outline(s: SystemState) -> Color:
	if s.hacked:
		return PURPLE_HACK
	if s.is_ionized():
		return BLUE
	if s.is_locked():
		return Color.WHITE
	return Color(0, 0, 0, 0)
