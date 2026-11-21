extends Control
## Touch UI on screens that are not 16:9 (e.g. Galaxy Z Fold cover ≈ 2.45:1, inner ≈ 1.16:1): the 1280×720 menu
## screens are centred in the visible canvas (HudLayout.frame_offset) and this fills the bands around them with the
## current screen's background image mirrored at the frame edges (MirroredBackground.draw_mirrored), so no black
## bands remain. Drawn under the screens, in canvas coordinates (no parent transform), never hit (mouse ignored).
## `texture_fn` returns the background of the screen being shown (null = nothing; the clear colour shows): a
## Texture2D, or {"texture": Texture2D, "hide": [[Rect2 part, Rect2 clean], ...]} when the image has something
## baked in that must not appear mirrored (the title's FTL logo and copyright line; MirroredBackground.draw_mirrored
## covers it with the clean region in every mirrored copy).

const Mirrored := preload("res://scripts/ui/mirrored_background.gd")

var texture_fn: Callable


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	position = Vector2.ZERO
	size = HudLayout.FRAME


func _process(_d: float) -> void:
	queue_redraw()  # follows screen changes (menu ↔ hangar) and canvas resizes


func _draw() -> void:
	var bg: Variant = texture_fn.call() if texture_fn.is_valid() else null
	var tex: Texture2D = bg.get("texture") if bg is Dictionary else bg
	if tex == null:
		return
	var hide: Array = bg.get("hide", []) if bg is Dictionary else []
	var area := get_global_transform().affine_inverse() * get_viewport_rect()
	var frame := Rect2(HudLayout.frame_offset(self, true), HudLayout.FRAME)
	if area.encloses(frame) and frame.encloses(area):
		return  # 16:9: the screen draws its own background
	Mirrored.draw_mirrored(self, tex, frame, area, Color.WHITE, Mirrored.FADE, Rect2(), hide)
