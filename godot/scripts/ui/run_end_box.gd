class_name RunEndBox
extends Control
## The game over / victory window (FTL's GameOver, rules/score_and_game_over.md §4–6): the whole HUD tinted × 0.15
## (black α 0.85 over everything below, ShipStatus and PAUSED included), the `scoreUI/gameover_main.png` box
## stretched to the computed width, the title (GAME OVER / VICTORY!), the cause text, "SCORE: N"
## (ScoreKeeper formula), a STATS button (opens the stats screen in game-over mode) and RESTART / HANGAR /
## MAIN MENU / QUIT. Button presses go to `on_command` as "restart" / "hangar" / "mainmenu" / "quit".

const ART := "img/scoreUI/gameover_main.png"
const BUTTONS := ["stats", "restart", "hangar", "mainmenu", "quit"]
const FONT_BUTTON := 62
const TOP_H := 276
const BOTTOM_H := 47

var run: RunState
var on_command: Callable
var stats_view: StatsView
var layout := {}  # ScoreKeeper.button_layout result for the open window
var labels := {}
var hover := ""
var _built_for := ""


func setup(r: RunState, cb: Callable) -> void:
	run = r
	on_command = cb
	position = Vector2.ZERO
	size = HudLayout.FRAME
	mouse_filter = Control.MOUSE_FILTER_STOP
	stats_view = StatsView.new()
	stats_view.visible = false
	add_child(stats_view)
	stats_view.setup(null)


## GameOver::OpenText: labels, auto widths (TextButton::UpdateAutoWidth: text width + 2 × margin 3) and the geometry.
func build() -> void:
	var widths := {}
	for b in BUTTONS:
		labels[b] = FtlData.tr_id("gameover_button_" + b)
		widths[b] = FtlData.ftl_text_width(FONT_BUTTON, labels[b]) + 6
	labels["title"] = FtlData.tr_id("gameover_title_victory" if run.over == "victory" else "gameover_title_gameover")
	layout = ScoreKeeper.button_layout(widths, FtlData.ftl_text_width(64, labels.title))
	_built_for = run.over


func _process(_d: float) -> void:
	visible = run != null and run.over != ""
	mouse_filter = Control.MOUSE_FILTER_STOP if visible else Control.MOUSE_FILTER_IGNORE
	if not visible:
		stats_view.visible = false
		return
	if _built_for != run.over or layout.is_empty():
		build()
	var h := "" if stats_view.visible else button_at(TooltipService.local_mouse(self))
	if h != hover and h != "":
		FtlData.play("hoverBeep")
	hover = h
	queue_redraw()


func button_at(p: Vector2) -> String:
	if layout.is_empty():
		return ""
	for b in BUTTONS:
		if (layout.buttons[b] as Rect2).has_point(p):
			return b
	return ""


func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	accept_event()
	if mb.pressed:
		press(button_at(mb.position))


## GameOver::MouseClick: STATS opens the stats screen, any other button is a command for main.gd.
func press(b: String) -> void:
	if b == "":
		return
	if b == "stats":
		var s := run.score
		stats_view.open_session({"ships": s.ships(), "beacons": s.beacons(), "scrap": s.scrap(), "crew": s.crew(),
			"score": s.score()})
		return
	if on_command.is_valid():
		on_command.call(b)


func _draw() -> void:
	if run == null or run.over == "" or layout.is_empty():
		return
	draw_rect(HudLayout.cover_rect(self, TooltipService.touch), Color(0, 0, 0, 0.85))  # RenderStatic tint × 0.15
	var x := float(layout.x)
	var y := float(layout.y)
	var w := int(layout.width)
	_draw_box(x, y)
	var cx := x + floorf(w / 2.0)
	FtlData.draw_ftl_text(self, 64, labels.title, Vector2(cx + 1, y + 15), MenuDraw.COL_TEXT, FtlFont.Align.CENTER)
	for b in BUTTONS:
		MenuDraw.text_button(self, {"rect": layout.buttons[b], "label": labels[b], "font": FONT_BUTTON}, hover == b)
	var ty := y + 75
	for line in FtlData.ftl_wrap(14, run.over_text, w - 81):
		FtlData.draw_ftl_text(self, 14, line, Vector2(cx, ty), Color.WHITE, FtlFont.Align.CENTER)
		ty += FtlData.ftl_line_height(14)
	var score_text := FtlData.tr_id("gameover_score").replace("\\1", str(run.score.score()))
	FtlData.draw_ftl_text(self, 24, score_text, Vector2(cx, y + 179), Color.WHITE, FtlFont.Align.CENTER)


## The box quads (rules §4 "Art"): top band left / n middle copies / right, bottom band caps, stretched columns
## under the buttons and the down / up pieces around each gap.
func _draw_box(x: float, y: float) -> void:
	var t := FtlData.texture(ART)
	if t == null:
		WindowFrame.draw(self, Rect2(x, y, layout.width, TOP_H + BOTTOM_H))
		return
	_quad(t, x, y, 230, TOP_H, 0, 0, 230)
	var px := x + 230
	for i in int(layout.middle):
		_quad(t, px, y, 10, TOP_H, 230, 0, 10)
		px += 10
	_quad(t, px, y, 241, TOP_H, 240, 0, 241)
	var by := y + TOP_H
	px = x
	_quad(t, px, by, 26, BOTTOM_H, 0, TOP_H, 26)
	px += 26
	var bottom := ["restart", "hangar", "mainmenu", "quit"]
	for i in bottom.size():
		var bw := (layout.buttons[bottom[i]] as Rect2).size.x - 20
		_quad(t, px, by, bw, BOTTOM_H, 26, TOP_H, 1)
		px += bw
		if i == 3:
			break
		_quad(t, px, by, 21, BOTTOM_H, 107, TOP_H, 21)
		px += 21
		var g := float(layout.gaps[i])
		_quad(t, px, by, g, BOTTOM_H, 128, TOP_H, 1)
		px += g
		_quad(t, px, by, 21, BOTTOM_H, 128, TOP_H, 21)
		px += 21
	_quad(t, px, by, 26, BOTTOM_H, 455, TOP_H, 26)


func _quad(t: Texture2D, x: float, y: float, w: float, h: float, u: float, v: float, uw: float) -> void:
	if w <= 0:
		return
	draw_texture_rect_region(t, Rect2(x, y, w, h), Rect2(u, v, uw, h))
