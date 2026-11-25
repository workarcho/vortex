class_name HudCalibrationPanel
extends Control
## Ours (not FTL): the touch HUD calibration panel, shown over the calibration sandbox (main.gd `calibrating`,
## Options window CALIBRATE HUD). Three slider rows, each with big − / + buttons and its value:
##   Top               ship status, crew list, top buttons, PAUSE / CANCEL (main.gd TOUCH_TOPLEFT_SCALE)
##   Bottom            systems bar + reactor, subsystems, + / − power toggle (TOUCH_SYSBAR_SCALE)
##   Weapons & Drones  the weapons / drones column or boxes (TOUCH_WEAPON_SCALES / TOUCH_SPLIT_PANEL_SCALES)
## A slider moved sets that group (main.hud_calibration_live) and the HUD is laid out again at once; a group never
## moved shows the automatic scale with a dim "AUTO". SAVE stores the set groups for this canvas's form factor
## (GameOptions.set_hud_scales: phone / fold_cover / fold_inner) and leaves; RESET removes the saved values of this
## form factor at once and goes back to the automatic scales (stays open); BACK leaves without saving. The title
## strip drags the panel; its HIDE / SHOW button collapses it to the strip. Range GameOptions.HUD_SCALE_MIN ..
## HUD_SCALE_MAX, step HUD_SCALE_STEP. With `--hud-scale=` the command line wins (a note says so).
## Look: FTL's options window (MenuDraw.options_frame: glow, COLOR_BUTTON_ON band with the title strip, patterned
## panel), option lines in font 13, the options SlideBars (MenuDraw.slide_bar) and TextButtons (MenuDraw.text_button,
## font 63). Everything is laid out in FTL pixels and the node is scaled up (SCALE) for touch-sized targets.
## CLI (screenshots): --calibrate-set=GROUP:SCALE[,...] moves sliders, --calibrate-collapsed collapses it.
## Lives on its own CanvasLayer above the HUD; main._input leaves the pointer events over it to it (`captures`).

signal finished(saved: bool)

const GROUPS := ["top", "bottom", "weapons"]
const LABELS := {"top": "Top", "bottom": "Bottom", "weapons": "Weapons &
Drones"}
const SCALE := 2.0  # canvas px per FTL px (phone canvas ≈ 1.5 screen px each: a 32 px button ≈ 64 canvas px)
const EDGE := 8.0  # canvas px kept between the panel and the canvas edges
const GLOW := 14.0  # room left around the band for the options frame glow (10 px) [FTL px, as below]
const STRIP := 24.0  # options_frame title strip above the panel
const PAD := 8.0  # panel inside margin
const ROW_STEP := 40.0
const BTN := 32.0  # − / + and SAVE / RESET / BACK height (− / + square)
const GAP := 8.0
const SLIDER_W := 96.0
const SLIDER_H := 20.0  # vanilla SlideBar box height (marker 15 × 30)
const LINE_FONT := 13
const BUTTON_FONT := 62  # MOD OPTIONS / CALIBRATE HUD size: the panel fits beside the phone weapons column
const STEP_FONT := 63  # − / +
const TITLE := "HUD CALIBRATION"
const NOTE := "--hud-scale given: the command line overrides the calibration."

var main: Node  # main.gd
var form_factor := ""
var live := {}  # groups set in this session ({group: scale}); main.hud_calibration_live points at it
var collapsed := false
var placed := false  # first placement done (the canvas size is known)
var note_shown := false
## Layout in FTL px (local coordinates), rebuilt by _layout(): the panel rect, the title strip and the hit items
## {name: Rect2}: "toggle", "save", "reset", "back", "minus:G", "plus:G", "slider:G" (G = group).
var panel_rect := Rect2()
var strip_rect := Rect2()
var items := {}
var hover := ""  # item under the pointer (yellow)
var _pressed := ""  # item pressed (fires on release over it; a slider drags while held)
var _press_inside := false  # a press began over the panel: its drag / release belong to it
var _drag_from := Vector2.INF  # strip drag: pointer - panel position (canvas px)


func setup(m: Node) -> void:
	main = m
	form_factor = main.hud_form_factor()
	live = GameOptions.hud_scales(form_factor)
	main.hud_calibration_live = live
	main.relayout_touch_hud()
	_layout()  # the form factor's name sizes the title strip
	# Screenshots / checks: --calibrate-set=top:1.5,bottom:0.9,weapons:1 moves those sliders; --calibrate-collapsed.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--calibrate-set="):
			for kv in arg.trim_prefix("--calibrate-set=").split(","):
				if GROUPS.has(kv.get_slice(":", 0)):
					set_group(kv.get_slice(":", 0), kv.get_slice(":", 1).to_float())
		elif arg == "--calibrate-collapsed":
			set_collapsed.call_deferred(true)


func _ready() -> void:
	name = "HudCalibrationPanel"
	mouse_filter = Control.MOUSE_FILTER_STOP
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	scale = Vector2(SCALE, SCALE)
	_layout()


## Rects of the frame, rows and buttons from the label / value widths (FTL px).
func _layout() -> void:
	items.clear()
	var lab_w := 0
	for g in GROUPS:
		lab_w = maxi(lab_w, FtlData.ftl_text_width(LINE_FONT, LABELS[g]))
	var val_w := maxi(FtlData.ftl_text_width(LINE_FONT, "x0.00"), FtlData.ftl_text_width(LINE_FONT, "AUTO"))
	var row_w := lab_w + GAP + BTN + GAP + SLIDER_W + GAP + BTN + GAP + val_w
	var labels := {"save": "SAVE", "reset": "RESET", "back": "BACK"}
	var bws := {}
	var btn_w := 0.0
	for k in labels:
		bws[k] = maxf(70.0, FtlData.ftl_text_width(BUTTON_FONT, labels[k]) + 24)
		btn_w += bws[k] + GAP
	btn_w -= GAP
	var inner_w := maxf(row_w, btn_w)
	var tog_w := FtlData.ftl_text_width(62, "SHOW") + 16
	var title_w := FtlData.ftl_text_width(62, TITLE) + 8 + FtlData.ftl_text_width(LINE_FONT, _ff_text()) + 20 + tog_w
	inner_w = maxf(inner_w, title_w - 2 * PAD + 8)
	var p := Vector2(GLOW + 4, GLOW + STRIP)
	var y := p.y + PAD
	for g in GROUPS:
		var cy := y + ROW_STEP / 2.0
		var x := p.x + PAD + lab_w + GAP
		items["minus:" + g] = Rect2(x, cy - BTN / 2, BTN, BTN)
		x += BTN + GAP
		items["slider:" + g] = Rect2(x, cy - SLIDER_H / 2, SLIDER_W, SLIDER_H)
		x += SLIDER_W + GAP
		items["plus:" + g] = Rect2(x, cy - BTN / 2, BTN, BTN)
		y += ROW_STEP
	if note_shown:
		y += FtlData.ftl_line_height(LINE_FONT) * FtlData.ftl_wrap(LINE_FONT, NOTE, int(inner_w)).size() + 6
	y += 6
	var bx := p.x + PAD + inner_w - btn_w
	for k in labels:
		items[k] = Rect2(bx, y, bws[k], BTN)
		bx += bws[k] + GAP
	y += BTN + PAD
	panel_rect = Rect2(p, Vector2(inner_w + 2 * PAD, y - p.y))
	strip_rect = Rect2(p.x - 4, GLOW, panel_rect.size.x + 8, STRIP)
	items["toggle"] = Rect2(panel_rect.end.x - tog_w, GLOW + 3, tog_w, STRIP - 5)
	if collapsed:
		size = Vector2(strip_rect.end.x + GLOW, strip_rect.end.y + 4 + GLOW)
	else:
		size = panel_rect.end + Vector2(4 + GLOW, 4 + GLOW)
	queue_redraw()


func _ff_text() -> String:
	return form_factor.replace("_", " ").capitalize()


## The items usable now (collapsed: only the toggle).
func _active() -> Array:
	return ["toggle"] if collapsed else items.keys()


## Local (FTL px) point → item name ("" = none). − / + and the toggle answer a little outside their plates
## (touch), a slider over its whole row.
func item_at(p: Vector2) -> String:
	for k in _active():
		var r: Rect2 = items[k]
		if k.begins_with("slider:"):
			r = Rect2(r.position.x - 6, r.get_center().y - ROW_STEP / 2, r.size.x + 12, ROW_STEP)
		elif k == "toggle":
			r = r.grow_individual(4, 3, 4, 3)
		elif k.begins_with("minus:") or k.begins_with("plus:"):
			r = r.grow_individual(GAP / 2, 4, GAP / 2, 4)
		if r.has_point(p):
			return k
	return ""


## Centre of the slider marker of `group` at value `v` (local FTL px): pressing there sets `v`.
func slider_point(group: String, v: float) -> Vector2:
	var box: Rect2 = items["slider:" + group]
	var t := (v - GameOptions.HUD_SCALE_MIN) / (GameOptions.HUD_SCALE_MAX - GameOptions.HUD_SCALE_MIN)
	return MenuDraw.slide_marker(box, t).get_center()


func _slider_value(group: String, x: float) -> float:
	var t := MenuDraw.slide_value(items["slider:" + group], x)
	return lerpf(GameOptions.HUD_SCALE_MIN, GameOptions.HUD_SCALE_MAX, t)


## Pointer down at local `p`: a slider jumps there and drags, a button is held (fires on release over it), the
## title strip starts a panel drag.
func press(p: Vector2) -> void:
	_pressed = item_at(p)
	hover = _pressed
	if _pressed.begins_with("slider:"):
		set_group(_pressed.get_slice(":", 1), _slider_value(_pressed.get_slice(":", 1), p.x))
	elif _pressed == "" and strip_rect.has_point(p):
		_drag_from = get_global_mouse_position() - position
	queue_redraw()


func move(p: Vector2) -> void:
	if _drag_from != Vector2.INF:
		position = get_global_mouse_position() - _drag_from
		_clamp_on_canvas()
		return
	if _pressed.begins_with("slider:"):
		set_group(_pressed.get_slice(":", 1), _slider_value(_pressed.get_slice(":", 1), p.x))
		return
	var h := item_at(p)
	if _pressed != "" and h != _pressed:
		h = ""  # a held button shows hot only while the pointer stays on it
	if h != hover:
		hover = h
		queue_redraw()


func release(p: Vector2) -> void:
	var it := _pressed
	_pressed = ""
	_drag_from = Vector2.INF
	hover = ""  # touch: nothing stays hovered after the finger lifts
	queue_redraw()
	if it == "" or it.begins_with("slider:") or item_at(p) != it:
		return
	match it:
		"toggle":
			set_collapsed(not collapsed)
		"save":
			save()
		"reset":
			reset()
		"back":
			back()
		_:
			nudge(it.get_slice(":", 1), -1 if it.begins_with("minus:") else 1)


## A tap on an item (press + release at its centre; checks / scripted use).
func tap(item: String) -> void:
	var c: Vector2 = (items[item] as Rect2).get_center()
	press(c)
	release(c)


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed:
			press(e.position)
		else:
			release(e.position)
		accept_event()
	elif e is InputEventMouseMotion:
		move(e.position)
		accept_event()


## A slider value for `group` (live, laid out at once; not saved).
func set_group(group: String, v: float) -> void:
	live[group] = GameOptions.clamp_hud_scale(v)
	main.hud_calibration_live = live
	main.relayout_touch_hud()
	queue_redraw()


## − / + buttons: one slider step from the value shown.
func nudge(group: String, dir: int) -> void:
	set_group(group, value(group) + dir * GameOptions.HUD_SCALE_STEP)


## The scale shown for `group`: the live value, else the automatic scale in use.
func value(group: String) -> float:
	return live.get(group, main.touch_group_scales()[group])


## The value text of a row: "x1.20", with " AUTO" (drawn dim, under it) while the group was never set.
func value_text(group: String) -> String:
	return "x%.2f%s" % [value(group), "" if live.has(group) else " AUTO"]


## SAVE: the set groups for this form factor (none set = the saved values are removed), then leave.
func save() -> void:
	GameOptions.set_hud_scales(form_factor, live)
	finished.emit(true)


## RESET: removes this form factor's saved values now; the HUD goes back to the automatic scales.
func reset() -> void:
	GameOptions.set_hud_scales(form_factor, {})
	live.clear()
	main.hud_calibration_live = live
	main.relayout_touch_hud()
	queue_redraw()


## BACK: leave without saving.
func back() -> void:
	finished.emit(false)


func set_collapsed(on: bool) -> void:
	collapsed = on
	hover = ""
	_layout()
	_clamp_on_canvas()


func _process(_delta: float) -> void:
	if main == null:
		return
	var ff: String = main.hud_form_factor()
	if ff != form_factor:  # folded / unfolded while calibrating: that form factor's own saved values
		form_factor = ff
		live = GameOptions.hud_scales(ff)
		main.hud_calibration_live = live
		main.relayout_touch_hud()
		_layout()  # its name in the title strip
	if main._cli_hud_scale_set() != note_shown:
		note_shown = not note_shown
		_layout()
	if not placed and size.x > 0:
		placed = true
		position = _home()
	_clamp_on_canvas()
	queue_redraw()  # automatic values follow the HUD as laid out


func _draw() -> void:
	var title_at := strip_rect.position + Vector2(12, 1)
	if collapsed:
		MenuDraw.options_band(self, Rect2(strip_rect.position, strip_rect.size + Vector2(0, 4)))
	else:
		MenuDraw.options_frame(self, panel_rect, "")
	FtlData.draw_ftl_text(self, 62, TITLE, title_at, MenuDraw.COL_TEXT)
	var tog: Rect2 = items["toggle"]  # the form factor saved for, left of HIDE / SHOW
	FtlData.draw_ftl_text(self, LINE_FONT, _ff_text(), Vector2(tog.position.x - 10, title_at.y + 3), MenuDraw.COL_TEXT,
		FtlFont.Align.RIGHT)
	MenuDraw.text_button(self, {"rect": tog, "label": "SHOW" if collapsed else "HIDE", "font": 62}, hover == "toggle")
	if collapsed:
		return
	var lh := FtlData.ftl_line_height(LINE_FONT)
	for g in GROUPS:
		var box: Rect2 = items["slider:" + g]
		var cy := box.get_center().y
		var hot: bool = hover == "slider:" + g
		var lines: int = String(LABELS[g]).count("
") + 1
		FtlData.draw_ftl_text(self, LINE_FONT, LABELS[g], Vector2(panel_rect.position.x + PAD, cy - lh * lines / 2.0),
			MenuDraw.COL_SELECT if hot else Color.WHITE)
		var t := (value(g) - GameOptions.HUD_SCALE_MIN) / (GameOptions.HUD_SCALE_MAX - GameOptions.HUD_SCALE_MIN)
		MenuDraw.slide_bar(self, box, MenuDraw.slide_marker(box, t), hot)
		for k in ["minus:" + g, "plus:" + g]:
			MenuDraw.text_button(self, {"rect": items[k], "label": "-" if k.begins_with("minus") else "+",
				"font": STEP_FONT}, hover == k)
		var vx: float = (items["plus:" + g] as Rect2).end.x + GAP
		var auto := not live.has(g)  # automatic: "AUTO" (dim) under the value
		var vy: float = cy - (lh if auto else lh / 2.0)
		FtlData.draw_ftl_text(self, LINE_FONT, "x%.2f" % value(g), Vector2(vx, vy), Color.WHITE)
		if auto:
			FtlData.draw_ftl_text(self, LINE_FONT, "AUTO", Vector2(vx, vy + lh), MenuDraw.COL_OFF)
	if note_shown:
		FtlData.draw_ftl_text(self, LINE_FONT, NOTE, Vector2(panel_rect.position.x + PAD,
			panel_rect.position.y + PAD + ROW_STEP * GROUPS.size() + 2), MenuDraw.COL_SELECT, 0,
			int(panel_rect.size.x - 2 * PAD))
	for k in ["save", "reset", "back"]:
		MenuDraw.text_button(self, {"rect": items[k], "label": k.to_upper(), "font": BUTTON_FONT}, hover == k)


## First place: vertically centred, left of the weapons column when there is room for it there (phone column
## layout: over the player ship, clear of the crew list), else horizontally centred. Drag / collapse to see more.
func _home() -> Vector2:
	var vis := get_viewport().get_visible_rect().size
	var glow := GLOW * scale  # the glow margin may overlap the HUD / leave the canvas; the band may not
	var band := size * scale - 2 * glow
	var at := (vis - band) / 2 - glow
	var wp: Control = main.get("weapon_panel")
	if wp != null and wp.visible and wp.get("vertical"):
		var col_l := wp.get_global_transform_with_canvas().origin.x
		if col_l - EDGE - band.x >= 160.0:
			at.x = col_l - EDGE - band.x - glow.x
	return at.round()


func _clamp_on_canvas() -> void:
	if not is_inside_tree():
		return
	var vis := get_viewport().get_visible_rect().size
	var glow := GLOW * scale
	var band := size * scale - 2 * glow
	var lo := Vector2(EDGE, EDGE) - glow
	position = Vector2(clampf(position.x, lo.x, maxf(lo.x, vis.x - band.x - EDGE - glow.x)),
		clampf(position.y, lo.y, maxf(lo.y, vis.y - band.y - EDGE - glow.y))).round()


## The drawn band (frame without its glow margin) in canvas px.
func band_rect() -> Rect2:
	return Rect2(position + GLOW * scale, size * scale - 2 * GLOW * scale)


## main._input: pointer events over the panel (or continuing a press that began on it) are the panel's.
func captures(event: InputEvent) -> bool:
	var pos := Vector2.INF
	if event is InputEventMouse:
		pos = (event as InputEventMouse).position
	elif event is InputEventScreenTouch:
		pos = (event as InputEventScreenTouch).position
	elif event is InputEventScreenDrag:
		pos = (event as InputEventScreenDrag).position
	else:
		return false
	var inside := band_rect().has_point(pos)
	if event is InputEventMouseButton:
		if event.pressed:
			_press_inside = inside
			return inside
		var was := _press_inside
		_press_inside = false
		return was or inside
	return inside or _press_inside
