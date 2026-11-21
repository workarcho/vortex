class_name HudDraw
extends RefCounted
## Small drawing helpers shared by the HUD pieces (images from ftl-data/img, FTL fonts, warnings).


static func tex(rel: String) -> Texture2D:
	return FtlData.texture("img/" + rel)


## Draws an image at `pos` (1:1, nearest) if it exists. Returns its size (zero if missing).
static func img(ci: CanvasItem, rel: String, pos: Vector2, color := Color.WHITE) -> Vector2:
	var t := tex(rel)
	if t == null:
		return Vector2.ZERO
	ci.draw_texture(t, pos.round(), color)
	return t.get_size()


## Draws the left `w` pixels (full height) of an image (FTL width-cropped bars: hull, FTL charge).
static func img_cropped(ci: CanvasItem, rel: String, pos: Vector2, w: float, color := Color.WHITE) -> void:
	var t := tex(rel)
	if t == null or w <= 0.0:
		return
	var cw := minf(roundf(w), t.get_width())
	ci.draw_texture_rect_region(t, Rect2(pos.round(), Vector2(cw, t.get_height())),
		Rect2(0, 0, cw, t.get_height()), color)


## Horizontal 3-slice: the image's first `left` px, its middle stretched to fill, its last `right` px.
static func three_slice(ci: CanvasItem, rel: String, pos: Vector2, width: float, left: int, right: int,
		color := Color.WHITE) -> void:
	var t := tex(rel)
	if t == null:
		return
	var h := t.get_height()
	var tw := t.get_width()
	var mid := maxf(width - left - right, 0.0)
	ci.draw_texture_rect_region(t, Rect2(pos, Vector2(left, h)), Rect2(0, 0, left, h), color)
	ci.draw_texture_rect_region(t, Rect2(pos + Vector2(left, 0), Vector2(mid, h)),
		Rect2(left, 0, maxi(tw - left - right, 1), h), color)
	ci.draw_texture_rect_region(t, Rect2(pos + Vector2(left + mid, 0), Vector2(right, h)),
		Rect2(tw - right, 0, right, h), color)


## FTL text (easy_print). align 0 left, 1 centre, 2 right.
static func text(ci: CanvasItem, font_id: int, s: String, pos: Vector2, color := Color.WHITE, align := 0,
		wrap := 0) -> int:
	return FtlData.draw_ftl_text(ci, font_id, s, pos, color, align, wrap)


## Translated text by id (text_misc.xml), with the XML "\n" escapes turned into new lines.
static func txt(id: String) -> String:
	return FtlData.tr_id(id).replace("\\n", "\n")


## WarningMessage flash: true in the first half of the 0.66 s loop ("on" half: alpha 0.9, red images).
static func flash_on(t: float) -> bool:
	return fmod(t, HudLayout.WARNING_FLASH) <= HudLayout.WARNING_FLASH * 0.5


static func flash_alpha(t: float) -> float:
	return 0.9 if flash_on(t) else 0.4


## WarningWithLines::RenderWithAlpha: the 2 px polyline at anchor + points, then topText `warning_warning`
## ("WARNING!") at anchor + textOrigin and bottomText (`msg`) 23 px lower, both centred, font 59 with the red
## backglow (WarningMessage::DrawTextWithGlow), COLOR_RED_WARNING at the flash alpha (0.9 / 0.4). `top_msg`
## replaces the top text (CloneBox: `warning_clone_off_1` over `warning_clone_off_2`).
static func warning_with_lines(ci: CanvasItem, spec: Array, msg: String, t: float, top_msg := "") -> void:
	var anchor: Vector2 = spec[0]
	var pts := PackedVector2Array()
	for p in spec[1]:
		pts.append(anchor + p)
	var a := flash_alpha(t)
	var c := Color(HudLayout.RED_WARNING, a)
	ci.draw_polyline(pts, c, 2.0)
	var o: Vector2 = anchor + spec[2]
	text_with_glow(ci, top_msg if top_msg != "" else txt("warning_warning"), o, c)
	text_with_glow(ci, msg, o + Vector2(0, 23), c)


## WarningMessage::DrawTextWithGlow (centred): backglow_warning_red.png at (x − 4, y − 1, w + 8, h + 4), then the
## text in font 59.
static func text_with_glow(ci: CanvasItem, s: String, centre_top: Vector2, c: Color) -> void:
	var w := FtlData.ftl_text_width(59, s)
	var h := (s.count("
") + 1) * FtlData.ftl_line_height(59)
	var g := tex("warnings/backglow_warning_red.png")
	if g:
		ci.draw_texture_rect(g, Rect2(roundf(centre_top.x - w / 2.0) - 4, centre_top.y - 1, w + 8, h + 4), false,
			Color(1, 1, 1, c.a))
	text(ci, 59, s, centre_top, c, 1)
