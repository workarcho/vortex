class_name ConfirmWindow
extends Control
## FTL ConfirmWindow (rules/ftl_drive.md §4.4; ConfirmWindow::SetText / UpdateSize / Open / OnRender / MouseClick):
## a yes / no window built from `confirm_window.png` (140×90) sliced into 3 × 3 + 9 pieces, the message in font 52
## (COLOR_BUTTON_ON, centred lines, wrap width − 40) and two TextButtons (font 62, `confirm_yes` / `confirm_no`).
## - UpdateSize: button size = (text width + 6, 24); width = yesW + noW + 112 (text widths), at least `min_width`;
##   textHeight = the message's wrapped height.
## - autoCenter (Open): position ((1280 − W) / 2, (720 − (90 − 22 + textHeight)) / 2).
## - Buttons at y = pos.y + textHeight + 28; yes at x = pos.x + W/2 − (yesW + 14 + noW)/2, no 14 px right of it.
## Used by the leave-crew window (`confirm_leave_crew`, min width 300). `answered(yes)` is emitted by `click`.

signal answered(yes: bool)

const IMG := "confirm_window.png"
const TEXT_FONT := 52
const BUTTON_FONT := 62

var text_id := ""
var min_width := 300
var yes_id := "confirm_yes"
var no_id := "confirm_no"
var touch := false  # touch UI: centred in the visible canvas (HudLayout.frame_offset)


func _init(id := "", min_w := 300) -> void:
	text_id = id
	min_width = min_w
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(_d: float) -> void:
	if visible:
		position = HudLayout.frame_offset(self, touch)
		queue_redraw()


func _btn_size(id: String) -> Vector2:
	return Vector2(FtlData.ftl_text_width(BUTTON_FONT, FtlData.tr_id(id)) + 6, 24)


func _lines() -> PackedStringArray:
	var out := PackedStringArray()
	for para in FtlData.tr_id(text_id).replace("\\n", "\n").split("\n"):
		out.append_array(FtlData.ftl_wrap(TEXT_FONT, para, window_width() - 40))
	return out


func window_width() -> int:
	return maxi(int(_btn_size(yes_id).x + _btn_size(no_id).x) + 100, min_width)


func text_height() -> int:
	return _lines().size() * FtlData.ftl_line_height(TEXT_FONT)


## Window top-left (frame coordinates, autoCenter).
func window_pos() -> Vector2:
	return Vector2(int((1280 - window_width()) / 2.0), int((720 - (90 - 22 + text_height())) / 2.0))


## [yes rect, no rect] in this node's coordinates.
func button_rects() -> Array:
	var p := window_pos()
	var ys := _btn_size(yes_id)
	var ns := _btn_size(no_id)
	var x := floorf(p.x + window_width() / 2.0 - (ys.x + 14 + ns.x) / 2.0)
	var y := p.y + text_height() + 28
	return [Rect2(Vector2(x, y), ys), Rect2(Vector2(x + ys.x + 14, y), ns)]


## A press at `p` (this node's coordinates): 1 yes, 0 no, −1 elsewhere (ConfirmWindow::MouseClick). Emits answered.
func click(p: Vector2) -> int:
	var r := button_rects()
	for i in 2:
		if (r[i] as Rect2).has_point(p):
			answered.emit(i == 0)
			return 1 - i
	return -1


func _draw() -> void:
	var t := HudDraw.tex(IMG)
	var p := window_pos()
	var w := float(window_width())
	var h := float(text_height())
	var br := button_rects()
	var yb: Rect2 = br[0]
	var nb: Rect2 = br[1]
	if t != null:
		# Rows: top (26, src 0..26), stretched middle (h − 21, src 26..27), lower (17, src 27..44), button row (46, 44..90).
		var cols := [[p.x, 70.0, 0.0, 70.0], [p.x + 70, w - 139, 70.0, 71.0], [p.x + w - 69, 69.0, 71.0, 140.0]]
		var rows := [[p.y, 26.0, 0.0, 26.0], [p.y + 26, h - 21, 26.0, 27.0], [p.y + h + 5, 17.0, 27.0, 44.0]]
		for r in rows:
			for c in cols:
				_piece(t, Rect2(c[0], r[0], c[1], r[1]), Rect2(c[2], r[2], c[3] - c[2], r[3] - r[2]))
		var by := p.y + h + 22
		var bx := [  # [dest x, dest w, src x0, src x1]: frame, yes button socket, gap, no button socket, frame
			[p.x, 20.0, 0.0, 20.0], [p.x + 20, yb.position.x - p.x - 41, 20.0, 21.0],
			[yb.position.x - 21, 31.0, 21.0, 52.0], [yb.position.x + 10, yb.size.x - 20, 52.0, 53.0],
			[yb.end.x - 10, 34.0, 53.0, 87.0], [nb.position.x + 10, nb.size.x - 20, 87.0, 88.0],
			[nb.end.x - 10, 31.0, 88.0, 119.0], [nb.end.x + 21, (p.x + w - 20) - (nb.end.x + 21), 119.0, 120.0],
			[p.x + w - 20, 20.0, 120.0, 140.0]]
		for c in bx:
			_piece(t, Rect2(c[0], by, c[1], 46.0), Rect2(c[2], 44.0, c[3] - c[2], 46.0))
	var y := p.y + 17
	for l in _lines():
		FtlData.draw_ftl_text(self, TEXT_FONT, l, Vector2(p.x + w / 2.0, y), HudLayout.BUTTON_ON, 1)
		y += FtlData.ftl_line_height(TEXT_FONT)
	var m := TooltipService.local_mouse(self)
	ShipScreen.text_button(self, yb, FtlData.tr_id(yes_id), "hot" if yb.has_point(m) else "on", BUTTON_FONT, 2)
	ShipScreen.text_button(self, nb, FtlData.tr_id(no_id), "hot" if nb.has_point(m) else "on", BUTTON_FONT, 2)


func _piece(t: Texture2D, dst: Rect2, src: Rect2) -> void:
	if dst.size.x > 0 and dst.size.y > 0:
		draw_texture_rect_region(t, dst, src)
