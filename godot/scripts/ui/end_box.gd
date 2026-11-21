class_name EndBox
extends Control
## Placeholders for the end of a fight (rules/ship_destruction.md §6, §7), not the original windows:
## - VICTORY: the enemy ship's explosion is over -> the `destroyed` event box (default DESTROYED_DEFAULT text +
##   "Continue..."; rewards are not computed here, rules/events.md). Click = close.
## - GAME_OVER: the player ship's explosion is over (`gameover_blowup`) or no player crew is left
##   (`gameover_crew`) -> dimmed screen, "GAME OVER" + text. Click = `restart` callback.

enum Mode { VICTORY, GAME_OVER }

const BOX_W := 520
const PAD := 18
const TEXT_FONT := 10
const TITLE_FONT := 63
const BG := Color(0.07, 0.09, 0.12, 0.94)
const FRAME := Color8(235, 245, 229)
const DIM := Color(0, 0, 0, 0.55)

var mode := Mode.VICTORY
var body := ""
var restart: Callable


func open(m: Mode, text_id: String) -> void:
	mode = m
	body = FtlData.tr_id(text_id).replace("\\n", "\n")
	position = HudLayout.frame_offset(self, TooltipService.touch)  # touch UI: centred in the canvas
	size = HudLayout.FRAME
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = true
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	accept_event()
	if mode == Mode.GAME_OVER:
		if restart.is_valid():
			restart.call()
	else:
		visible = false


func _draw() -> void:
	var lines := FtlData.ftl_wrap(TEXT_FONT, body, BOX_W - 2 * PAD)
	var line_h := 20
	if mode == Mode.GAME_OVER:
		draw_rect(Rect2(Vector2.ZERO, size), DIM)
		var title := FtlData.tr_id("gameover_title_gameover")
		var top := 220.0
		FtlData.draw_ftl_text(self, TITLE_FONT, title, Vector2(size.x / 2, top), FtlColors.RED, 1)
		var y := top + 70
		for l in lines:
			FtlData.draw_ftl_text(self, TEXT_FONT, l, Vector2(size.x / 2, y), Color.WHITE, 1)
			y += line_h
		FtlData.draw_ftl_text(self, TEXT_FONT, FtlData.tr_id("gameover_button_restart") + " (click)",
			Vector2(size.x / 2, y + 30), FRAME, 1)
		return
	var h := PAD * 2 + lines.size() * line_h + 40
	var r := Rect2(Vector2((size.x - BOX_W) / 2, 200), Vector2(BOX_W, h))
	draw_rect(r, BG)
	draw_rect(r, FRAME, false, 3.0)
	var y2 := r.position.y + PAD
	for l in lines:
		FtlData.draw_ftl_text(self, TEXT_FONT, l, Vector2(r.position.x + PAD, y2), Color.WHITE)
		y2 += line_h
	FtlData.draw_ftl_text(self, TEXT_FONT, "1. " + FtlData.tr_id("continue"),
		Vector2(r.position.x + PAD, y2 + 16), FRAME)
