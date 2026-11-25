class_name HudCalibrationPanel
extends PanelContainer
## Ours (not FTL): the touch HUD calibration panel, shown over the calibration sandbox (main.gd `calibrating`,
## Options window CALIBRATE HUD). Three sliders, each with big − / + buttons and its value:
##   Top               ship status, crew list, top buttons, PAUSE / CANCEL (main.gd TOUCH_TOPLEFT_SCALE)
##   Bottom            systems bar + reactor, subsystems, + / − power toggle (TOUCH_SYSBAR_SCALE)
##   Weapons & drones  the weapons / drones column or boxes (TOUCH_WEAPON_SCALES / TOUCH_SPLIT_PANEL_SCALES)
## A slider moved sets that group (main.hud_calibration_live) and the HUD is laid out again at once; a group never
## moved shows the automatic scale with "auto". SAVE stores the set groups for this canvas's form factor
## (GameOptions.set_hud_scales: phone / fold_cover / fold_inner) and leaves; RESET removes the saved values of this
## form factor at once and goes back to the automatic scales (stays open); BACK leaves without saving. The header
## (title + form factor) drags the panel; its ▾ / ▸ button collapses it to the header. Range GameOptions.HUD_SCALE_MIN
## .. HUD_SCALE_MAX, step HUD_SCALE_STEP. With `--hud-scale=` the command line wins (the sliders show a note).
## CLI (screenshots): --calibrate-set=GROUP:SCALE[,...] moves sliders, --calibrate-collapsed collapses it.
## Lives on its own CanvasLayer above the HUD; main._input leaves the pointer events over it to it (`captures`).

signal finished(saved: bool)

const GROUPS := ["top", "bottom", "weapons"]
const LABELS := {"top": "Top", "bottom": "Bottom", "weapons": "Weapons & drones"}
const TOUCH := 72.0  # canvas px of every touch target (phone canvas ≈ 1.5 screen px each: ~41 dp)
const FONT := 24
const EDGE := 8.0  # canvas px kept between the panel and the canvas edges

var main: Node  # main.gd
var form_factor := ""
var live := {}  # groups set in this session ({group: scale}); main.hud_calibration_live points at it
var sliders := {}
var values := {}  # group -> value Label
var body: VBoxContainer
var title_label: Label
var collapse_btn: Button
var note: Label
var collapsed := false
var placed := false  # first placement done (the canvas size is known)
var _press_inside := false  # a press began over the panel: its drag / release belong to it
var _drag_from := Vector2.INF  # header drag: pointer - panel position
var _syncing := false


func setup(m: Node) -> void:
	main = m
	form_factor = main.hud_form_factor()
	live = GameOptions.hud_scales(form_factor)
	main.hud_calibration_live = live
	main.relayout_touch_hud()
	_refresh()
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
	theme = _make_theme()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.06, 0.08, 0.88)
	sb.border_color = Color(0.55, 0.85, 0.75)
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(12)
	add_theme_stylebox_override("panel", sb)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	add_child(v)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	v.add_child(head)
	title_label = Label.new()
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.custom_minimum_size.y = TOUCH * 0.8
	title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title_label.mouse_filter = Control.MOUSE_FILTER_STOP
	title_label.mouse_default_cursor_shape = Control.CURSOR_MOVE
	title_label.gui_input.connect(_on_header_input)
	head.add_child(title_label)
	collapse_btn = _button("▾", func() -> void: set_collapsed(not collapsed))
	collapse_btn.custom_minimum_size = Vector2(TOUCH, TOUCH * 0.8)
	head.add_child(collapse_btn)
	body = VBoxContainer.new()
	body.add_theme_constant_override("separation", 8)
	v.add_child(body)
	for g in GROUPS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		body.add_child(row)
		var lab := Label.new()
		lab.text = LABELS[g]
		lab.custom_minimum_size = Vector2(170, TOUCH)
		lab.size = lab.custom_minimum_size
		lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lab.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART  # "Weapons & drones" on two lines
		lab.add_theme_font_size_override("font_size", 21)
		row.add_child(lab)
		row.add_child(_button("−", func() -> void: nudge(g, -1)))
		var sl := HSlider.new()
		sl.min_value = GameOptions.HUD_SCALE_MIN
		sl.max_value = GameOptions.HUD_SCALE_MAX
		sl.step = GameOptions.HUD_SCALE_STEP
		sl.custom_minimum_size = Vector2(240, TOUCH)
		sl.focus_mode = Control.FOCUS_NONE
		sl.value_changed.connect(func(val: float) -> void: set_group(g, val))
		row.add_child(sl)
		sliders[g] = sl
		row.add_child(_button("+", func() -> void: nudge(g, 1)))
		var val_lab := Label.new()
		val_lab.custom_minimum_size = Vector2(135, TOUCH)
		val_lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(val_lab)
		values[g] = val_lab
	note = Label.new()
	note.text = "--hud-scale given: the command line overrides the calibration."
	note.add_theme_color_override("font_color", Color(1, 0.75, 0.3))
	note.visible = false
	body.add_child(note)
	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 16)
	btns.alignment = BoxContainer.ALIGNMENT_END
	body.add_child(btns)
	for b in [["SAVE", save], ["RESET", reset], ["BACK", back]]:
		var bt := _button(b[0], b[1])
		bt.custom_minimum_size = Vector2(170, TOUCH)
		btns.add_child(bt)
	_refresh()


func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(TOUCH, TOUCH)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b


## Big readable controls: the default font at FONT, a round 44 px slider grabber, a thick track.
func _make_theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = FONT
	var d := 44
	var img := Image.create(d, d, false, Image.FORMAT_RGBA8)
	for y in d:
		for x in d:
			var r := Vector2(x + 0.5 - d / 2.0, y + 0.5 - d / 2.0).length()
			if r <= d / 2.0 - 1:
				img.set_pixel(x, y, Color(0.85, 1, 0.92) if r < d / 2.0 - 5 else Color(0.2, 0.45, 0.4))
	var tex := ImageTexture.create_from_image(img)
	t.set_icon("grabber", "HSlider", tex)
	t.set_icon("grabber_highlight", "HSlider", tex)
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.2, 0.3, 0.32)
	track.set_corner_radius_all(6)
	track.content_margin_top = 6
	track.content_margin_bottom = 6
	t.set_stylebox("slider", "HSlider", track)
	var fill := track.duplicate() as StyleBoxFlat
	fill.bg_color = Color(0.4, 0.75, 0.65)
	t.set_stylebox("grabber_area", "HSlider", fill)
	t.set_stylebox("grabber_area_highlight", "HSlider", fill)
	for st in [["normal", Color(0.12, 0.22, 0.24)], ["hover", Color(0.18, 0.32, 0.34)],
			["pressed", Color(0.3, 0.55, 0.5)], ["focus", Color(0, 0, 0, 0)]]:
		var b := StyleBoxFlat.new()
		b.bg_color = st[1]
		b.border_color = Color(0.55, 0.85, 0.75)
		b.set_border_width_all(0 if st[0] == "focus" else 2)
		b.set_corner_radius_all(6)
		b.set_content_margin_all(6)
		t.set_stylebox(st[0], "Button", b)
	return t


## A slider value for `group` (live, laid out at once; not saved).
func set_group(group: String, v: float) -> void:
	if _syncing:
		return
	live[group] = GameOptions.clamp_hud_scale(v)
	main.hud_calibration_live = live
	main.relayout_touch_hud()
	_refresh()


## − / + buttons: one slider step from the value shown.
func nudge(group: String, dir: int) -> void:
	var cur: float = live.get(group, main.touch_group_scales()[group])
	set_group(group, cur + dir * GameOptions.HUD_SCALE_STEP)


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
	_refresh()


## BACK: leave without saving.
func back() -> void:
	finished.emit(false)


func set_collapsed(on: bool) -> void:
	collapsed = on
	if body != null:
		body.visible = not on
		collapse_btn.text = "▸" if on else "▾"
	reset_size()
	_clamp_on_canvas()


## Sliders, values and title from `live` and the HUD as laid out (automatic groups show the scale in use).
func _refresh() -> void:
	if body == null or main == null:
		return
	var eff: Dictionary = main.touch_group_scales()
	_syncing = true
	for g in GROUPS:
		var v: float = live.get(g, eff[g])
		(sliders[g] as HSlider).set_value_no_signal(v)
		(values[g] as Label).text = "×%.2f%s" % [v, "" if live.has(g) else " auto"]
	_syncing = false
	title_label.text = "HUD CALIBRATION · %s" % form_factor.replace("_", " ")
	note.visible = main._cli_hud_scale_set()


func _process(_delta: float) -> void:
	if main == null:
		return
	var ff: String = main.hud_form_factor()
	if ff != form_factor:  # folded / unfolded while calibrating: that form factor's own saved values
		form_factor = ff
		live = GameOptions.hud_scales(ff)
		main.hud_calibration_live = live
		main.relayout_touch_hud()
	if not placed and size.x > 0:
		placed = true
		position = _home()
	_clamp_on_canvas()
	_refresh()


## First place: vertically centred, left of the weapons column when there is room for it there (phone column
## layout: over the player ship, clear of the crew list), else horizontally centred. Drag / collapse to see more.
func _home() -> Vector2:
	var vis := get_viewport().get_visible_rect().size
	var at := (vis - size) / 2
	var wp: Control = main.get("weapon_panel")
	if wp != null and wp.visible and wp.get("vertical"):
		var col_l := wp.get_global_transform_with_canvas().origin.x
		if col_l - EDGE - size.x >= 160.0:
			at.x = col_l - EDGE - size.x
	return at.round()


func _clamp_on_canvas() -> void:
	if not is_inside_tree():
		return
	var vis := get_viewport().get_visible_rect().size
	position = Vector2(clampf(position.x, EDGE, maxf(EDGE, vis.x - size.x - EDGE)),
		clampf(position.y, EDGE, maxf(EDGE, vis.y - size.y - EDGE))).round()


func _on_header_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		_drag_from = (get_global_mouse_position() - position) if e.pressed else Vector2.INF
	elif e is InputEventMouseMotion and _drag_from != Vector2.INF:
		position = get_global_mouse_position() - _drag_from
		_clamp_on_canvas()


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
	var inside := get_global_rect().has_point(pos)
	if event is InputEventMouseButton:
		if event.pressed:
			_press_inside = inside
			return inside
		var was := _press_inside
		_press_inside = false
		return was or inside
	return inside or _press_inside
