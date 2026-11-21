class_name WindowFrame
extends RefCounted
## FTL's WindowFrame (WindowFrame::WindowFrame / Draw): a box of inner rect (x, y, w, h) drawn from
## (x − 7, y − 7, w + 14, h + 14): the `window_mask.png` octagon (corners = half the image) is the stencil, the
## 10×17 tile at (27, 28) of `window_base.png` is repeated inside it (white tint), then the 9-slice
## `window_outline.png` on top. The stencil is reproduced with a chamfered polygon (mask inset 11 px, 11 px
## corner cuts, measured from window_mask.png).

const PAD := 7
const MASK_INSET := 11
const CHAMFER := 11
static var _tile: Texture2D
static var _outline: StyleBoxTexture


static func _ensure() -> void:
	if _tile != null:
		return
	var base := FtlData.texture("img/window_base.png")
	if base:
		_tile = ImageTexture.create_from_image(base.get_image().get_region(Rect2i(27, 28, 10, 17)))
	var ol := FtlData.texture("img/window_outline.png")
	if ol:
		_outline = StyleBoxTexture.new()
		_outline.texture = ol
		var hw := ol.get_width() / 2 - 1
		var hh := ol.get_height() / 2 - 1
		_outline.texture_margin_left = hw
		_outline.texture_margin_right = ol.get_width() - (ol.get_width() / 2 + 1)
		_outline.texture_margin_top = hh
		_outline.texture_margin_bottom = ol.get_height() - (ol.get_height() / 2 + 1)
		_outline.draw_center = false


## Draws the frame around the inner rect `r` on `ci` (whose texture_repeat must be enabled for the pattern).
static func draw(ci: CanvasItem, r: Rect2) -> void:
	_ensure()
	var outer := r.grow(PAD)
	var inner := outer.grow(-MASK_INSET)
	var c := float(CHAMFER)
	var p := inner.position
	var e := inner.end
	var pts := PackedVector2Array([Vector2(p.x + c, p.y), Vector2(e.x - c, p.y), Vector2(e.x, p.y + c),
		Vector2(e.x, e.y - c), Vector2(e.x - c, e.y), Vector2(p.x + c, e.y), Vector2(p.x, e.y - c),
		Vector2(p.x, p.y + c)])
	if _tile:
		var uvs := PackedVector2Array()
		for q in pts:
			uvs.append((q - outer.position - Vector2(PAD, 0)) / Vector2(10, 17))
		ci.draw_colored_polygon(pts, Color.WHITE, uvs, _tile)
	else:
		ci.draw_colored_polygon(pts, Color8(40, 44, 50))
	if _outline:
		ci.draw_style_box(_outline, outer)
	else:
		ci.draw_polyline(pts + PackedVector2Array([pts[0]]), Color8(235, 245, 229), 3.0)


## WindowFrame::DrawOutline: only the 9-slice outline around the inner rect `r` (for windows that fill the
## inside themselves, e.g. the beacon map's zone image).
static func draw_outline(ci: CanvasItem, r: Rect2) -> void:
	_ensure()
	if _outline:
		ci.draw_style_box(_outline, r.grow(PAD))
	else:
		ci.draw_rect(r, Color8(235, 245, 229), false, 3.0)
