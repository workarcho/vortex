class_name PanArrows
extends Control
## Open-Fold "pan" combat layout (main.gd `_touch_layout_pan`, `--fold-layout=pan`; first visual draft): the two
## arrow buttons at the canvas's left / right edges, vertically centred, that pan the shared ship scene to the
## player ship (left) or to the enemy ship (right). [ours] — FTL has no such control; the look borrows the HUD's
## boxes: a dark translucent box with a 2 px light outline (COLOR_BUTTON_ON) and a chevron in it. An arrow is
## drawn dimmed when the scene cannot pan further that way. Input is routed by main.gd (`_pan_input` →
## `arrow_at`); this control itself ignores the mouse. Drawn in HUD-layer (canvas) coordinates.

const SIZE := Vector2(40, 112)  # box size at scale 1
const EDGE := 6.0  # px from the canvas edge (× scale)
const FILL := Color(0.03, 0.06, 0.08, 0.72)
const LINE := Color8(235, 245, 229)  # HudLayout.BUTTON_ON
const LINE_DIM := Color(0.92, 0.96, 0.9, 0.3)

var art_scale := 1.0
var canvas_w := 1280.0
var mid_y := 550.0  # canvas y of the arrows' centres
var pan := 0.0  # 0 = player ship ... 1 = enemy ship (set by main)
var can_pan := true  # false when the scene fits the canvas (both arrows hidden)
## Per-side overrides ({"left": v, "right": v}; missing = mid_y / art_scale): `--hud-scale` pan layouts put each
## arrow in the free gap of its own canvas edge (main.gd `_pan_arrow_spots`).
var side_y := {}
var side_scale := {}
## Per-side x of the box's left edge (the phone pan layout may put the left arrow beside the right one); missing =
## at its own canvas edge.
var side_x := {}


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## Canvas rect of the "left" / "right" arrow box.
func rect_of(id: String) -> Rect2:
	var sc: float = side_scale.get(id, art_scale)
	var s := SIZE * sc
	var x: float = side_x[id] if side_x.has(id) else (EDGE * sc if id == "left" else canvas_w - EDGE * sc - s.x)
	return Rect2(Vector2(x, float(side_y.get(id, mid_y)) - s.y / 2).round(), s.round())


## "left" / "right" / "" at a canvas point.
func arrow_at(p: Vector2) -> String:
	if not is_visible_in_tree() or not can_pan:
		return ""
	for id in ["left", "right"]:
		if rect_of(id).has_point(p):
			return id
	return ""


func _draw() -> void:
	if not can_pan:
		return
	for id in ["left", "right"]:
		var r := rect_of(id)
		var live := pan > 0.001 if id == "left" else pan < 0.999
		var c := LINE if live else LINE_DIM
		draw_rect(r, FILL)
		var sc: float = side_scale.get(id, art_scale)
		draw_rect(r.grow(-sc), c, false, 2.0 * sc)
		# Chevron: a filled triangle pointing outwards, 18 × 36 at scale 1.
		var cx := r.get_center().x
		var cy := r.get_center().y
		var w := 9.0 * sc
		var hh := 18.0 * sc
		var d := -1.0 if id == "left" else 1.0
		draw_colored_polygon(PackedVector2Array([Vector2(cx + d * w, cy), Vector2(cx - d * w, cy - hh),
			Vector2(cx - d * w, cy + hh)]), c)
