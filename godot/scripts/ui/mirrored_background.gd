extends Control
## Beacon background for the touch (mobile) UI on screens wider or taller than the 1280×720 frame
## (rules/ui_layout_strategy.md). The image (made for 16:9) is drawn at its normal place; the extra width to the
## right (and, on a tall screen, the extra height below) is filled with the image mirrored at the shared edge
## (seamless join; the focus of FTL backgrounds is on the left, so the strip reads as more stars), darkened
## slightly towards the far edge. The PC UI does not use this (SpaceBackdrop draws the image).
## The beacon's background is fed by SpaceBackdrop (`texture` / `tint`, rules/backgrounds.md "Touch UI"); a change
## redraws. `texture` null (nebula) draws nothing.
## `draw_mirrored` is the shared helper (also the title scene's frame fill, scripts/ui/frame_fill.gd).

const FADE := 0.25  # extra darkening at the far edge of a mirrored strip

var texture: Texture2D:
	set(v):
		texture = v
		queue_redraw()
var tint := Color.WHITE:
	set(v):
		tint = v
		queue_redraw()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	get_viewport().size_changed.connect(queue_redraw)


func _draw() -> void:
	if texture == null:
		return
	# Visible size in frame units (canvas_items stretch with aspect "expand" widens / heightens the canvas).
	var seen := get_viewport_rect().size / maxf(get_global_transform().get_scale().x, 0.001)
	draw_mirrored(self, texture, Rect2(Vector2.ZERO, HudLayout.FRAME), Rect2(Vector2.ZERO, seen), tint)


## Draws `tex` stretched over `frame` and fills the rest of `area` (both in `ci`'s local coordinates) with copies
## of it mirrored at every shared edge (tile (i, j) next to the frame is flipped horizontally for odd i and
## vertically for odd j, so every join is seamless), then darkens each band beyond the frame towards its far edge
## (FADE). A frame covering `area` draws just the image. `src` (texture pixels; empty = the whole texture) draws
## only that part of the image as the frame tile (e.g. a clean strip of stars to fill one band from).
## `hide`: [[Rect2 part, Rect2 clean], ...] in texture pixels: in every mirrored copy (never in the frame itself)
## `part` (something that must not appear mirrored, e.g. a logo or text baked into the image) is covered with the
## `clean` region of the image (e.g. plain stars) stretched over it, feathered over its outer 15 texture px (so
## `part` = the thing + ~15 px of margin / glow).
static func draw_mirrored(ci: CanvasItem, tex: Texture2D, frame: Rect2, area: Rect2, tint := Color.WHITE,
		fade := FADE, src := Rect2(), hide := []) -> void:
	if tex == null or frame.size.x < 1.0 or frame.size.y < 1.0:
		return
	var ts := tex.get_size()
	var s0 := Vector2.ZERO
	if src.has_area():
		s0 = src.position
		ts = src.size
	var i0 := floori((area.position.x - frame.position.x) / frame.size.x)
	var i1 := ceili((area.end.x - frame.position.x) / frame.size.x)
	var j0 := floori((area.position.y - frame.position.y) / frame.size.y)
	var j1 := ceili((area.end.y - frame.position.y) / frame.size.y)
	for j in range(j0, j1):
		for i in range(i0, i1):
			var tile := Rect2(frame.position + Vector2(i, j) * frame.size, frame.size)
			var vis := tile.intersection(area)
			if vis.size.x < 0.5 or vis.size.y < 0.5:
				continue
			var fx := posmod(i, 2) == 1
			var fy := posmod(j, 2) == 1
			var u0 := (vis.position - tile.position) / frame.size
			var u1 := (vis.end - tile.position) / frame.size
			if fx:
				var a := u0.x
				u0.x = 1.0 - u1.x
				u1.x = 1.0 - a
			if fy:
				var b := u0.y
				u0.y = 1.0 - u1.y
				u1.y = 1.0 - b
			var part := Rect2(s0 + u0 * ts, (u1 - u0) * ts)
			if not fx and not fy:
				ci.draw_texture_rect_region(tex, vis, part, tint)
				continue
			# A negative rect size is culled, so mirror through the draw transform (about the strip's centre).
			var c := vis.get_center()
			ci.draw_set_transform(c, 0.0, Vector2(-1.0 if fx else 1.0, -1.0 if fy else 1.0))
			ci.draw_texture_rect_region(tex, Rect2(vis.position - c, vis.size), part, tint)
			ci.draw_set_transform(Vector2.ZERO)
			for h in hide:  # feathered: rings 5 px apart, the core opaque
				for ring in [[0.0, 0.3], [5.0, 0.4], [10.0, 0.5], [15.0, 1.0]]:
					_cover(ci, tex, tile, vis, ts, s0, fx, fy, (h[0] as Rect2).grow(-ring[0]),
						(h[1] as Rect2).grow(-ring[0]), Color(tint, tint.a * ring[1]))
	if fade <= 0.0:
		return
	# Gentle fade so a mirrored feature near the edge draws less attention: per band, transparent at the frame
	# edge, `fade` black at the far edge.
	var clear := Color(0, 0, 0, 0)
	var dark := Color(0, 0, 0, fade)
	var fr := frame.intersection(area)
	if area.end.x > frame.end.x + 0.5:  # right
		_gradient(ci, Rect2(frame.end.x, area.position.y, area.end.x - frame.end.x, area.size.y), clear, dark, true)
	if area.position.x < frame.position.x - 0.5:  # left
		_gradient(ci, Rect2(area.position.x, area.position.y, frame.position.x - area.position.x, area.size.y),
			dark, clear, true)
	if area.end.y > frame.end.y + 0.5:  # below (between the side bands)
		_gradient(ci, Rect2(fr.position.x, frame.end.y, fr.size.x, area.end.y - frame.end.y), clear, dark, false)
	if area.position.y < frame.position.y - 0.5:  # above
		_gradient(ci, Rect2(fr.position.x, area.position.y, fr.size.x, frame.position.y - area.position.y),
			dark, clear, false)


## One `hide` entry in a mirrored tile: `part` (texture px) lands where the flips put it; the clean region is drawn
## there (unflipped: stars), cropped to the visible part of the tile.
static func _cover(ci: CanvasItem, tex: Texture2D, tile: Rect2, vis: Rect2, ts: Vector2, s0: Vector2, fx: bool,
		fy: bool, part: Rect2, clean: Rect2, tint: Color) -> void:
	var u0 := (part.position - s0) / ts
	var u1 := (part.end - s0) / ts
	if fx:
		var a := u0.x
		u0.x = 1.0 - u1.x
		u1.x = 1.0 - a
	if fy:
		var b := u0.y
		u0.y = 1.0 - u1.y
		u1.y = 1.0 - b
	var dest := Rect2(tile.position + u0 * tile.size, (u1 - u0) * tile.size)
	var shown := dest.intersection(vis)
	if shown.size.x < 0.5 or shown.size.y < 0.5:
		return
	var v0 := (shown.position - dest.position) / dest.size
	var v1 := (shown.end - dest.position) / dest.size
	ci.draw_texture_rect_region(tex, shown, Rect2(clean.position + v0 * clean.size, (v1 - v0) * clean.size), tint)


static func _gradient(ci: CanvasItem, r: Rect2, from: Color, to: Color, horizontal: bool) -> void:
	var pts := PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])
	var cols := PackedColorArray([from, to, to, from]) if horizontal else PackedColorArray([from, from, to, to])
	ci.draw_polygon(pts, cols)
