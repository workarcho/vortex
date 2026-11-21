class_name WarningMessage
extends RefCounted
## FTL WarningMessage with text (rules/power.md "Power-up failure warning"): InitText(text id, position, length,
## colour, centreText, flash) / Start / OnLoop / OnRender -> RenderWithAlpha -> DrawTextWithGlow.
## - `start()` is a no-op while the message is running (repeated triggers do not extend or restart it).
## - Flash messages use their own 0.66 s tracker from Start: alpha 0.9 while progress <= 0.5, 0.4 after.
##   Non-flash messages draw at alpha 1.
## - Text in font 59 (measured with the same font), behind it the backglow image at (x-4, y-1, w+8, h+4):
##   warnings/backglow_warning_red.png when the colour is COLOR_RED_WARNING, else backglow_warning_white.png.
## Timing runs on the frame time (it keeps running while the game is paused, like the other HUD trackers).

const FONT := 59
const FLASH := 0.66

var text_id := ""
var position := Vector2.ZERO  # top-left (or top-centre when `center`) in the owner's coordinates
var length := 2.0
var color := HudLayout.BUTTON_ON
var center := false
var flash := false
var t := -1.0  # s since Start; < 0 = not running


func _init(id := "", pos := Vector2.ZERO, len_s := 2.0, centred := false, flashing := false,
		col := HudLayout.BUTTON_ON) -> void:
	text_id = id
	position = pos
	length = len_s
	center = centred
	flash = flashing
	color = col


func running() -> bool:
	return t >= 0.0


## Starts the message unless it is already running.
func start() -> void:
	if t < 0.0:
		t = 0.0


func stop() -> void:
	t = -1.0


func update(delta: float) -> void:
	if t < 0.0:
		return
	t += delta
	if t >= length:
		t = -1.0


## True in the bright half of the flash loop (also drives the reactor bars' white flash).
func flash_on() -> bool:
	return t >= 0.0 and fmod(t, FLASH) <= FLASH * 0.5


func alpha() -> float:
	if not flash:
		return 1.0
	return 0.9 if flash_on() else 0.4


func text() -> String:
	return HudDraw.txt(text_id)


## Size of the text block (widest line, lines × line height).
func text_size() -> Vector2:
	var s := text()
	return Vector2(FtlData.ftl_text_width(FONT, s), (s.count("\n") + 1) * FtlData.ftl_line_height(FONT))


## Draws the message (glow + text) if running. `at` overrides `position`.
func draw(ci: CanvasItem, at: Variant = null) -> void:
	if t < 0.0:
		return
	var p: Vector2 = position if at == null else at
	var sz := text_size()
	var x := p.x - (sz.x / 2.0 if center else 0.0)
	var a := alpha()
	var glow := "warnings/backglow_warning_red.png" if color == HudLayout.RED_WARNING \
		else "warnings/backglow_warning_white.png"
	var g := HudDraw.tex(glow)
	if g:
		ci.draw_texture_rect(g, Rect2(roundf(x) - 4, p.y - 1, sz.x + 8, sz.y + 4), false, Color(1, 1, 1, a))
	HudDraw.text(ci, FONT, text(), Vector2(p.x, p.y), Color(color, a), 1 if center else 0)
