class_name OptionsScreen
extends Control
## Mod options (rules/hooks.md "Settings"; rules/main_menu.md §3 "Mod options page"): every Settings group (one per
## mod feature) with its master switch and items, drawn in FTL's own options look. Built from the Settings
## registry every frame, so every mod's settings appear here.
## Layout = the exe's OptionsScreen "customize controls" page (OptionsScreen::OnRender with bCustomizeControls,
## ControlsScreen::OnInit / OnRender): WindowFrame (130, 112, 1089, 500), the `box_options_configure_tab.png` tab
## titled MOD OPTIONS, DEFAULTS TextButton 165×32 font 63 at (160, 619) with `optionsUI/defaults_base.png`
## (−23, −7), CLOSE TextButton font 63 at (1190 − width, 619) with `storeUI/store_close_base.png` (−23, −7) [exe].
## Inside, two frames in the `optionsUI_new.png` style (MenuDraw.options_frame): the feature list on the left
## (one font-13 line per group "Label: On/Off"; click selects the group, a click on the selected one toggles it)
## and the selected group on the right ("Label: Enabled/Disabled" master line, its description, then one line per
## item: bool "Label: On/Off" and enum "Label: value" cycle on click (right click = back), float = SlideBar).
## Lines are white, hovered yellow (COLOR_BUTTON_SELECT), items of a disabled group grey; gameplay items carry
## "[gameplay]" / "[applies next run]" (frozen into the running run). Item tooltips go through TooltipService.
## Open: F10, MOD OPTIONS in FTL's options window (title Options / Esc menu OPTIONS), or "Options" in the debug
## overlay; Esc / F10 / CLOSE close it. Mouse and touch (touch is emulated as mouse; rows are 34 px apart).

signal closed

const FRAME := Rect2(130, 112, 1089, 500)  # ControlsScreen customBox (WindowFrame inner rect) [exe]
const LEFT := Rect2(150, 172, 400, 410)  # feature list frame [ours]
const RIGHT := Rect2(590, 172, 610, 410)  # selected group frame [ours]
const LINE_FONT := 13
const LINE_PAD := Vector2(17, 16)  # first line inside a frame (vanilla: 261 − 244, 224 − 208) [screenshot 36]
const LINE_STEP := 34  # [screenshot 36]
const DESC_FONT := 12
const TAG_FONT := 12
const TAG_COLOR := Color(1.0, 0.8, 0.4)
const DIM := Color(0.58, 0.58, 0.58)
const SLIDER := Vector2(200, 20)  # OptionsScreen SlideBar box size [exe]

var selected := ""  # selected group id
var expanded := {}  # group id -> true: rebuild() selects the first of them (main.gd --options sets it)
var page := 0  # feature list page (more groups than fit in the left frame)
var hover := ""  # key under the pointer (see item_at)
var buttons := {}
var _drag := ""  # float item whose SlideBar is being dragged
var _rows := []  # right frame rows of the last layout: [{key, rect, ...}]


func _ready() -> void:
	position = Vector2.ZERO
	size = HudLayout.FRAME  # under a CanvasLayer (no Control parent): the 1280×720 frame
	mouse_filter = Control.MOUSE_FILTER_STOP  # nothing under the screen gets the mouse
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED  # WindowFrame pattern
	_build_buttons()


func show_screen() -> void:
	visible = true
	hover = ""
	_drag = ""
	rebuild()


func hide_screen() -> void:
	if visible:
		visible = false
		_drag = ""
		closed.emit()


## Re-reads the registry (kept for callers of the old widget version; drawing reads the registry live).
func rebuild() -> void:
	var ids := Settings.group_ids()
	for g in ids:
		if expanded.get(g, false):
			selected = String(g)
			page = ids.find(g) / per_page()
			break
	expanded.clear()
	if not ids.has(selected):
		selected = String(ids[0]) if not ids.is_empty() else ""
	_build_buttons()
	queue_redraw()


func _build_buttons() -> void:
	buttons.clear()
	var close := FtlData.tr_id("button_close")
	var cw := maxi(103, FtlData.ftl_text_width(63, close) + 24)  # SetAutoWidth(true, false, 3, 0)
	buttons["close"] = {"rect": Rect2(1190 - cw, 619, cw, 32), "label": close, "font": 63,
		"base": "storeUI/store_close_base.png", "base_off": Vector2(-23, -7)}
	var dl := FtlData.tr_id("button_defaults")
	var dw := maxi(165, FtlData.ftl_text_width(63, dl) + 24)
	buttons["defaults"] = {"rect": Rect2(160, 619, dw, 32), "label": dl, "font": 63,
		"base": "optionsUI/defaults_base.png", "base_off": Vector2(-23, -7)}
	var n := pages()
	if n > 1:
		for i in n:
			buttons["page:%d" % i] = {"rect": Rect2(LEFT.position.x + 17 + 36 * i, LEFT.end.y - 34, 30, 24),
				"label": str(i + 1), "font": 62, "state": "selected" if i == page else "on"}


func _unhandled_key_input(e: InputEvent) -> void:
	if visible and e is InputEventKey and e.pressed and (e.keycode == KEY_ESCAPE or e.keycode == KEY_F10):
		hide_screen()
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------- layout

## Groups per page of the left frame (one row fewer when the page buttons are shown).
func per_page() -> int:
	var fit := int((LEFT.size.y - LINE_PAD.y) / LINE_STEP)
	return fit if Settings.group_ids().size() <= fit else fit - 1


func pages() -> int:
	return maxi(1, ceili(Settings.group_ids().size() / float(per_page())))


func page_groups() -> Array:
	var ids := Settings.group_ids()
	var n := per_page()
	return ids.slice(page * n, mini(ids.size(), (page + 1) * n))


static func on_off(b: bool) -> String:
	return FtlData.tr_id("on" if b else "off")


static func group_line(g: String) -> String:
	return "%s: %s" % [Settings.groups[g].label, on_off(Settings.group_raw(g))]


static func master_line(g: String) -> String:
	return "%s: %s" % [Settings.groups[g].label, FtlData.tr_id("enabled" if Settings.group_raw(g) else "disabled")]


static func item_line(id: String) -> String:
	var it: Dictionary = Settings.items[id]
	match String(it.type):
		"bool":
			return "%s: %s" % [it.label, on_off(bool(Settings.raw(id)))]
		"enum":
			return "%s: %s" % [it.label, str(Settings.raw(id))]
	return String(it.label)


static func _line_rect(text: String, at: Vector2) -> Rect2:
	return Rect2(at, Vector2(maxf(FtlData.ftl_text_width(LINE_FONT, text), 40), 22))


func group_rect(g: String) -> Rect2:
	var i := page_groups().find(g)
	if i < 0:
		return Rect2()
	return _line_rect(group_line(g), LEFT.position + LINE_PAD + Vector2(0, LINE_STEP * i))


## Rows of the right frame for the selected group: master line, description, items (keys "master", "i:<id>").
func layout_rows() -> Array:
	var rows := []
	if selected == "" or not Settings.groups.has(selected):
		return rows
	var x := RIGHT.position.x + LINE_PAD.x
	var y := RIGHT.position.y + LINE_PAD.y
	rows.append({"key": "master", "rect": _line_rect(master_line(selected), Vector2(x, y))})
	y += LINE_STEP
	var desc := String(Settings.groups[selected].desc)
	if desc != "":
		var lines := FtlData.ftl_wrap(DESC_FONT, desc, int(RIGHT.size.x - 2 * LINE_PAD.x))
		rows.append({"key": "desc", "rect": Rect2(x, y, RIGHT.size.x - 2 * LINE_PAD.x,
			lines.size() * FtlData.ftl_line_height(DESC_FONT)), "lines": lines})
		y += lines.size() * FtlData.ftl_line_height(DESC_FONT) + 16
	for id in Settings.groups[selected].items:
		if y + 22 > RIGHT.end.y:
			break
		var it: Dictionary = Settings.items[id]
		var r := _line_rect(item_line(id), Vector2(x, y))
		var row := {"key": "i:" + String(id), "rect": r}
		if String(it.type) == "float":
			var box := Rect2(RIGHT.end.x - LINE_PAD.x - 60 - SLIDER.x, y + 1, SLIDER.x, SLIDER.y)
			row["slider"] = box
		rows.append(row)
		y += LINE_STEP
	return rows


func _row(key: String) -> Dictionary:
	for r in layout_rows():
		if r.key == key:
			return r
	return {}


## What is under `p`: a button name, "g:<group>", "master", "i:<item>" (float items: their SlideBar too) or "".
func item_at(p: Vector2) -> String:
	var b := MenuDraw.button_at(buttons, p)
	if b != "":
		return b
	for g in page_groups():
		if group_rect(String(g)).grow(3).has_point(p):
			return "g:" + String(g)
	for r in layout_rows():
		if r.key == "desc":
			continue
		if (r.rect as Rect2).grow(3).has_point(p):
			return r.key
		if r.has("slider"):
			var box: Rect2 = r.slider
			var id := String(r.key).substr(2)
			if box.grow_individual(0, 6, 0, 6).has_point(p) or _marker(id, box).has_point(p):
				return r.key
	return ""


func _marker(id: String, box: Rect2) -> Rect2:
	var it: Dictionary = Settings.items[id]
	var span := float(it.max) - float(it.min)
	var v := (float(Settings.raw(id)) - float(it.min)) / span if span > 0.0 else 0.0
	return MenuDraw.slide_marker(box, v)


# ---------------------------------------------------------------- input

func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		if _drag != "":
			_set_slider(_drag, e.position.x)
		_set_hover(item_at(e.position))
	elif e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		click(e.position)
	elif e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_RIGHT:
		click(e.position, true)
	elif e is InputEventMouseButton and not e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		_drag = ""
	accept_event()


func _set_hover(h: String) -> void:
	if h != hover and h != "":
		FtlData.play("hoverBeep")
	hover = h
	queue_redraw()


## OptionsScreen::MouseClick-like: a group line selects it (a click on the selected group toggles it), the master
## line toggles the selected group, a bool item toggles, an enum item cycles (right click = back), a float item's
## SlideBar jumps to the pointer and drags; DEFAULTS forgets the user's choices; CLOSE closes. Returns the key.
func click(p: Vector2, back := false) -> String:
	var it := item_at(p)
	if it == "":
		return it
	if it == "close":
		hide_screen()
	elif it == "defaults":
		Settings.reset_user()
	elif it.begins_with("page:"):
		page = int(it.substr(5))
		var pg := page_groups()
		if not pg.is_empty():
			selected = String(pg[0])
		_build_buttons()
	elif it.begins_with("g:"):
		var g := it.substr(2)
		if g == selected:
			Settings.set_group_enabled(g, not Settings.group_raw(g))
		else:
			selected = g
	elif it == "master":
		Settings.set_group_enabled(selected, not Settings.group_raw(selected))
	elif it.begins_with("i:"):
		var id := it.substr(2)
		var d: Dictionary = Settings.items[id]
		match String(d.type):
			"bool":
				Settings.set_value(id, not bool(Settings.raw(id)))
			"enum":
				var opts: Array = d.options
				if not opts.is_empty():
					var k := maxi(opts.find(Settings.raw(id)), 0)
					Settings.set_value(id, opts[posmod(k + (-1 if back else 1), opts.size())])
			"float":
				if not back:
					_drag = id
					_set_slider(id, p.x)
	queue_redraw()
	return it


func _set_slider(id: String, x: float) -> void:
	var r := _row("i:" + id)
	if not r.has("slider"):
		return
	var d: Dictionary = Settings.items[id]
	var v := float(d.min) + MenuDraw.slide_value(r.slider, x) * (float(d.max) - float(d.min))
	if float(d.step) > 0.0:
		v = snappedf(v, float(d.step))
	Settings.set_value(id, v)
	queue_redraw()


func _process(_delta: float) -> void:
	if not visible:
		return
	if TooltipService.debug_pointer != null:  # CLI --pointer (screenshots)
		var h := item_at(TooltipService.debug_pointer)
		if h != hover:
			hover = h
			queue_redraw()
	if hover.begins_with("i:"):
		var tip := String(Settings.items.get(hover.substr(2), {}).get("tooltip", ""))
		if tip != "":
			TooltipService.request(tip, {"source": self})


# ---------------------------------------------------------------- drawing

func _draw() -> void:
	draw_rect(HudLayout.cover_rect(self, TooltipService.touch), Color(0, 0, 0, 0.75))  # tint over whatever opened it
	WindowFrame.draw(self, FRAME)
	MenuDraw.controls_tab(self, "MOD OPTIONS")
	MenuDraw.options_frame(self, LEFT, "FEATURES")
	var title := ""
	if Settings.groups.has(selected):
		title = String(Settings.groups[selected].label).to_upper()
	MenuDraw.options_frame(self, RIGHT, title)
	if Settings.groups.is_empty():
		FtlData.draw_ftl_text(self, LINE_FONT, "No settings (no mods loaded).", LEFT.position + LINE_PAD)
	for g in page_groups():
		var r := group_rect(String(g))
		if g == selected:
			draw_rect(Rect2(LEFT.position.x + 6, r.position.y - 6, LEFT.size.x - 12, 30), Color(1, 1, 1, 0.12))
		var col := MenuDraw.COL_SELECT if hover == "g:" + String(g) or g == selected else Color.WHITE
		FtlData.draw_ftl_text(self, LINE_FONT, group_line(String(g)), r.position, col)
		if Settings.group_gameplay(String(g)):
			_tag("gameplay", r)
	var group_on := Settings.group_raw(selected) if selected != "" else false
	for row in layout_rows():
		var r: Rect2 = row.rect
		match String(row.key):
			"master":
				FtlData.draw_ftl_text(self, LINE_FONT, master_line(selected), r.position,
					MenuDraw.COL_SELECT if hover == "master" else Color.WHITE)
			"desc":
				var y := r.position.y
				for line in row.lines:
					FtlData.draw_ftl_text(self, DESC_FONT, line, Vector2(r.position.x, y), MenuDraw.COL_ON)
					y += FtlData.ftl_line_height(DESC_FONT)
			_:
				var id := String(row.key).substr(2)
				var hot: bool = hover == String(row.key) or _drag == id
				var col := MenuDraw.COL_SELECT if hot else (Color.WHITE if group_on else DIM)
				FtlData.draw_ftl_text(self, LINE_FONT, item_line(id), r.position, col)
				var it: Dictionary = Settings.items[id]
				if row.has("slider"):
					var box: Rect2 = row.slider
					MenuDraw.slide_bar(self, box, _marker(id, box), hot)
					FtlData.draw_ftl_text(self, LINE_FONT, ("%.2f" % float(Settings.raw(id))).rstrip("0").rstrip("."),
						Vector2(box.end.x + 12, r.position.y), col)
				elif bool(it.gameplay):
					_tag("applies next run" if Settings.is_frozen(id) else "gameplay", r)
	for nm in buttons:
		var b: Dictionary = buttons[nm]
		if b.has("base"):
			MenuDraw.img(self, String(b.base), (b.rect as Rect2).position + (b.base_off as Vector2))
		MenuDraw.text_button(self, b, hover == nm)


func _tag(t: String, line: Rect2) -> void:
	FtlData.draw_ftl_text(self, TAG_FONT, "[%s]" % t, Vector2(line.end.x + 10, line.position.y + 2), TAG_COLOR)
