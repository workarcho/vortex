class_name FtlTooltip
extends RefCounted
## FTL tooltip box renderer (MouseControl::MeasureTooltip / RenderTooltip; rules/tooltips.md §2): black rect at α 0.95
## with a white 2 px outline, size = text + (27, 18) (+ title height + 5 with a title); title in font 13 at (15, 13),
## body in MouseControl::tooltipFont = 12 at (15, 11 + title height), white, word-wrapped at the given width.
## Drawn only by the TooltipService autoload (no Godot tooltips anywhere).

const FONT := 12
const TITLE_FONT := 13
const PAD := Vector2(27, 18)


static func _title_h(title: String) -> int:
	return FtlData.ftl_line_height(TITLE_FONT) + 5 if title != "" else 0


static func lines(body: String, wrap: int) -> PackedStringArray:
	return FtlData.ftl_wrap(FONT, body, wrap)


static func box_size(title: String, body: String, wrap: int) -> Vector2:
	var ls := lines(body, wrap)
	var w := 0
	for l in ls:
		w = maxi(w, FtlData.ftl_text_width(FONT, l))
	if title != "":
		w = maxi(w, FtlData.ftl_text_width(TITLE_FONT, title))
	return Vector2(w + PAD.x, ls.size() * FtlData.ftl_line_height(FONT) + PAD.y + _title_h(title))


static func draw_box(ci: CanvasItem, pos: Vector2, title: String, body: String, wrap: int) -> void:
	var r := Rect2(pos, box_size(title, body, wrap))
	ci.draw_rect(r, Color(0, 0, 0, 0.95))
	ci.draw_rect(r.grow(-1), Color.WHITE, false, 2.0)
	if title != "":
		FtlData.draw_ftl_text(ci, TITLE_FONT, title, pos + Vector2(15, 13 - 4), Color.WHITE)
	FtlData.draw_ftl_text(ci, FONT, body, pos + Vector2(15, 11 + _title_h(title) - 4), Color.WHITE, 0, wrap)
