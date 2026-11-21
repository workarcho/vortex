class_name AchievementPopup
extends CanvasLayer
## The "Achievement Unlocked!" popup (AchievementTracker::OnLoop / OnRender, drawn by CApp::OnRender over every
## screen; rules/save_and_profile.md §4.3). Created on demand by `ensure()` (node "AchievementPopup" under the root)
## and fed by AchievementTracker.popups (recentlyUnlocked):
## - OnLoop: when the queue is not empty and no popup runs, the first one starts (achievementPopup tracker, 3.0 s)
##   with the sound "achievement" ("unlock" for a ship / layout unlock, i.e. an entry with a header); when the
##   tracker is done the entry is removed and the next one starts.
## - OnRender: `achievements/popup_box.png` at (970, 0); the icon (CAchievement::OnRender style 0) centred on
##   (1024, 51); the header (`ach_unlocked`, or the entry's own: `ship_unlocked` / `layout_unlocked`) font 11 at
##   (1075, 20); the name font 13 wrapped at 195 px at (1075, 41), or (1075, 50) when it fits in 25 px; white.
## Coordinates of the 1280x720 frame (like TooltipService).

const DURATION := 3.0  # achievementPopup AnimationTracker time
const BOX_AT := Vector2(970, 0)
const ICON_CENTRE := Vector2(1024, 51)
const HEADER_AT := Vector2(1075, 20)
const NAME_X := 1075.0
const NAME_WRAP := 195
const NAME_TALL := 25.0  # measured height above which the name starts at y 41 instead of 50

var t := -1.0  # s into the current popup (-1 = none running)
var _canvas: Control


static func ensure() -> void:
	var tree := Engine.get_main_loop()
	if not tree is SceneTree:
		return
	var root: Window = (tree as SceneTree).root
	if root.get_node_or_null("AchievementPopup") != null or root.has_meta(&"achievement_popup_pending"):
		return
	var n := AchievementPopup.new()
	n.name = "AchievementPopup"
	root.set_meta(&"achievement_popup_pending", true)
	root.add_child.call_deferred(n)


func _ready() -> void:
	get_tree().root.remove_meta(&"achievement_popup_pending")
	layer = 110  # under the tooltip (120)
	process_mode = Node.PROCESS_MODE_ALWAYS
	_canvas = Control.new()
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.size = Vector2(1280, 720)
	_canvas.draw.connect(_on_draw)
	add_child(_canvas)


func _process(delta: float) -> void:
	step(delta)
	_canvas.queue_redraw()


## OnLoop: start the first queued popup, advance it, drop it when done. Returns the entry shown ({} = none).
func step(delta: float) -> Dictionary:
	var q := AchievementTracker.popups
	if q.is_empty():
		t = -1.0
		return {}
	if t < 0.0:
		t = 0.0
		FtlData.play(String(q[0].get("sound", "achievement")))
	else:
		t += delta
	if t >= DURATION:
		q.pop_front()
		t = -1.0
		return step(0.0) if not q.is_empty() else {}
	return q[0]


func _on_draw() -> void:
	var q := AchievementTracker.popups
	if q.is_empty() or t < 0.0:
		return
	var e: Dictionary = q[0]
	MenuDraw.img(_canvas, "achievements/popup_box.png", BOX_AT)
	var dim := int(e.get("dim", 64))
	var icon := {"img": e.get("img", ""), "dim": dim, "unlocked": true}
	MenuDraw.draw_achievement(_canvas, icon, ICON_CENTRE - Vector2(dim / 2, dim / 2), true)
	var header := String(e.get("header", ""))
	var htext := FtlData.tr_id(header if header != "" else "ach_unlocked")
	FtlData.draw_ftl_text(_canvas, 11, htext, HEADER_AT, Color.WHITE)
	var nm := String(e.get("name", ""))
	var lines := FtlData.ftl_wrap(13, nm, NAME_WRAP).size()
	var y := 41.0 if lines * FtlData.ftl_line_height(13) > NAME_TALL else 50.0
	FtlData.draw_ftl_text(_canvas, 13, nm, Vector2(NAME_X, y), Color.WHITE, 0, NAME_WRAP)
