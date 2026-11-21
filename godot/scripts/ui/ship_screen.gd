class_name ShipScreen
extends Control
## The ship management TabbedWindow (rules/ship_management.md §1): window at P = (340, 85), tabs Upgrades / Crew /
## Equipment (`upgradeUI/Equipment/tabButtons/<current>_<button>_*`, the current tab's button is not drawn: it is
## baked into the page image), the Accept button (closes = commits) and Esc. The pages are child Controls
## (`UpgradesView`, `CrewManifestView`, `EquipmentView`) that draw their page and then the window chrome through
## `draw_chrome`, and forward unhandled clicks to `chrome_click`. State and rules live in `RunState.mgmt`
## (ShipManagement); gestures become intents.

## The exe sets (340, 85) (CommandGui ctor → TabbedWindow); the vanilla 1280×720 screenshots (work/refs/vanilla
## 42–44, FTL 1.6.14) show every tab page, button and frame 4 px further left — matched here (StoreView.WPOS too).
const P := Vector2(336, 85)
const TAB_NAMES := ["upgrades", "crew", "equipment"]
## Tab buttons relative to P: [image rect, hit rect] (CommandGui::LinkShip).
const TAB_RECTS := [
	[Rect2(0, -7, 109, 48), Rect2(5, 0, 89, 38)],
	[Rect2(82, -7, 127, 48), Rect2(97, 0, 97, 38)],
	[Rect2(182, -7, 123, 48), Rect2(197, 0, 103, 38)],
]
const DONE_RECT := Rect2(436, 471, 132, 32)
const DONE_BASE := Vector2(413, 464)
const INFO_W := 320.0
const COL_TEXT := Color8(235, 245, 229)  # COLOR_BUTTON_ON
const COL_DARK := Color8(25, 49, 51)  # COLOR_BUTTON_TEXT
const COL_HOT := Color8(255, 230, 94)
const COL_OFF := Color8(164, 171, 160)  # COLOR_BUTTON_OFF
const COL_RED := Color8(255, 50, 50)

var run: RunState
var profile: InputProfile
var views: Array[Control] = []
var upgrades_view: UpgradesView
var crew_view: CrewManifestView
var equip_view: EquipmentView


func setup(r: RunState, p: InputProfile) -> void:
	run = r
	profile = p
	position = Vector2.ZERO
	size = HudLayout.FRAME
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	upgrades_view = UpgradesView.new()
	crew_view = CrewManifestView.new()
	equip_view = EquipmentView.new()
	views = [upgrades_view, crew_view, equip_view]
	for v in views:
		v.call("setup", r, p, self)
		add_child(v)


func _process(_d: float) -> void:
	if run == null:
		return
	run.mgmt.update(run)
	visible = run.mgmt.open and run.over == ""
	for i in views.size():
		var on := visible and run.mgmt.tab == i
		views[i].visible = on
		views[i].mouse_filter = Control.MOUSE_FILTER_STOP if on else Control.MOUSE_FILTER_IGNORE
		if on:
			views[i].queue_redraw()


func send(type: String, extra := {}) -> bool:
	return run.apply(ShipManagement.make(type, extra))


## Keys while the window is open (main.gd routes them here first). Returns true when consumed.
func key(k: InputEventKey) -> bool:
	if not run.mgmt.open:
		return false
	if run.mgmt.tab == ShipManagement.CREW and crew_view.key(k):
		return true
	match k.keycode:
		KEY_ESCAPE:
			send(RunIntent.CLOSE_SHIP_SCREEN)
		KEY_U:
			_hotkey_tab(ShipManagement.UPGRADES)
		KEY_C:
			_hotkey_tab(ShipManagement.CREW)
		KEY_I:
			_hotkey_tab(ShipManagement.EQUIPMENT)
	return true  # nothing else reaches the ship while the window is open


## The hotkey of the open tab closes the window [inferred], another tab's switches to it.
func _hotkey_tab(t: int) -> void:
	if run.mgmt.tab == t:
		send(RunIntent.CLOSE_SHIP_SCREEN)
	else:
		send(RunIntent.SET_TAB, {"arg": t})


# ------------------------------------------------------------------ chrome (tabs + Accept)

## "tab0".."tab2", "done" or "".
func chrome_hit(p: Vector2) -> String:
	if not run.mgmt.locked(run):
		for i in 3:
			if i != run.mgmt.tab and Rect2(P + TAB_RECTS[i][1].position, TAB_RECTS[i][1].size).has_point(p):
				return "tab%d" % i
		if Rect2(P + DONE_RECT.position, DONE_RECT.size).has_point(p):
			return "done"
	return ""


func chrome_click(p: Vector2) -> bool:
	var h := chrome_hit(p)
	if h == "done":
		send(RunIntent.CLOSE_SHIP_SCREEN)
		return true
	if h.begins_with("tab"):
		send(RunIntent.SET_TAB, {"arg": int(h.substr(3))})
		return true
	return false


func draw_chrome(ci: CanvasItem, mouse: Vector2) -> void:
	var cur: String = TAB_NAMES[run.mgmt.tab]
	var lock := run.mgmt.locked(run)
	var hot := chrome_hit(mouse) if not profile.is_touch() else ""
	for i in 3:
		if i == run.mgmt.tab:
			continue
		var st := "off" if lock else ("select2" if hot == "tab%d" % i else "on")
		img(ci, "upgradeUI/Equipment/tabButtons/%s_%s_%s.png" % [cur, TAB_NAMES[i], st], P + TAB_RECTS[i][0].position)
	img(ci, "upgradeUI/buttons_accept_base.png", P + DONE_BASE)
	text_button(ci, Rect2(P + DONE_RECT.position, DONE_RECT.size), FtlData.tr_id("button_accept"),
		"off" if lock else ("hot" if hot == "done" else "on"))


# ------------------------------------------------------------------ drawing helpers (shared by the pages)

static func img(ci: CanvasItem, rel: String, p: Vector2, col := Color.WHITE) -> Vector2:
	var t := FtlData.texture("img/" + rel)
	if t:
		ci.draw_texture(t, p, col)
		return t.get_size()
	return Vector2.ZERO


## TextButton (TextButton::InitPrimitives / OnRender) [exe]: a plate with stepped corners of `inset` px in
## COLOR_BUTTON_ON (active), COLOR_BUTTON_SELECT (hovered) or COLOR_BUTTON_OFF (inactive), label in
## COLOR_BUTTON_TEXT, centred (font 63 by default).
static func text_button(ci: CanvasItem, r: Rect2, label: String, state: String, font := 63, inset := 3) -> void:
	var fill := COL_TEXT
	if state == "hot":
		fill = COL_HOT
	elif state == "off":
		fill = COL_OFF
	for k in inset:  # stepped corners: one rect per corner row
		var d := float(inset - k)
		ci.draw_rect(Rect2(r.position.x + d, r.position.y + k, r.size.x - 2 * d, 1), fill)
		ci.draw_rect(Rect2(r.position.x + d, r.end.y - k - 1, r.size.x - 2 * d, 1), fill)
	ci.draw_rect(Rect2(r.position.x, r.position.y + inset, r.size.x, r.size.y - 2 * inset), fill)
	var lh := FtlData.ftl_line_height(font)
	var ty := r.position.y + 3 if font == 63 else r.position.y + (r.size.y - lh) / 2.0
	FtlData.draw_ftl_text(ci, font, label, Vector2(r.get_center().x, ty), COL_DARK, 1)


## InfoBox [inferred layout]: title (font 62), wrapped body (font 10), optional red line at the bottom.
static func info_box(ci: CanvasItem, at: Vector2, title: String, body: String, warn := "") -> void:
	if title == "":
		return
	var lines := FtlData.ftl_wrap(10, body, int(INFO_W) - 24)
	var h := 44.0 + 18.0 * lines.size() + (24.0 if warn != "" else 0.0)
	var r := Rect2(at + Vector2(10, 7), Vector2(INFO_W - 20, maxf(h, 80.0)))
	WindowFrame.draw(ci, r)
	FtlData.draw_ftl_text(ci, 62, title, r.position + Vector2(10, 8), COL_HOT)
	var y := r.position.y + 36
	for l in lines:
		FtlData.draw_ftl_text(ci, 10, l, Vector2(r.position.x + 10, y), COL_TEXT)
		y += 18
	if warn != "":
		FtlData.draw_ftl_text(ci, 10, warn, Vector2(r.position.x + 10, y + 4), COL_RED)


## DropBox [inferred composition]: the `dropbox[_sell]_<on|select2>.png` art is cut at its dark band (found from the
## image) and rebuilt for the content: light part with the title (font 24) and text1 lines (dark text), the dark
## body band (`body_h`: the over-capacity item box / the sell value), then text2 lines on light. Returns
## {rect, body: Rect2}.
static var _bands := {}


static func _band(t: Texture2D) -> Vector2i:
	if _bands.has(t):
		return _bands[t]
	var im := t.get_image()
	var top := -1
	var bot := -1
	for y in im.get_height():
		if im.get_pixel(im.get_width() / 2, y).get_luminance() < 0.3:
			if top < 0:
				top = y
			bot = y
	var b := Vector2i(top, bot) if top >= 0 else Vector2i(im.get_height() / 2, im.get_height() / 2)
	_bands[t] = b
	return b


static func _title_lines(title: String) -> PackedStringArray:
	return title.replace("\\n", "\n").split("\n")


static func _title_lh() -> float:
	return 28.0  # font 24 line step [inferred]


static func drop_box_height(title: String, lines1: Array, body_h: float, lines2: Array) -> float:
	var h := 12.0 + _title_lh() * _title_lines(title).size() + 14.0 + 17.0 * lines1.size() + 6.0
	h += body_h
	if not lines2.is_empty():
		h += 6.0 + 17.0 * lines2.size()
	return h + 10.0


static func drop_box(ci: CanvasItem, at: Vector2, sell: bool, hot: bool, title: String, lines1: Array,
		body_h: float, lines2: Array = []) -> Dictionary:
	var base := "dropbox_sell" if sell else "dropbox"
	var t := FtlData.texture("img/%s_%s.png" % [base, "select2" if hot else "on"])
	var w := 272.0
	var tl := _title_lines(title)
	var light1 := 12.0 + _title_lh() * tl.size() + 14.0 + 17.0 * lines1.size() + 6.0
	var total := drop_box_height(title, lines1, body_h, lines2)
	var body := Rect2(at + Vector2(0, light1), Vector2(w, body_h))
	if t:
		var band := _band(t)
		var th := t.get_size().y
		var cap := 10.0
		var fill := Rect2(0, cap, w, 2)  # a light row under the top cap
		ci.draw_texture_rect_region(t, Rect2(at, Vector2(w, cap)), Rect2(0, 0, w, cap))
		ci.draw_texture_rect_region(t, Rect2(at + Vector2(0, cap), Vector2(w, total - 2 * cap)), fill)
		if body_h > 0:
			ci.draw_texture_rect_region(t, body, Rect2(0, band.x - 2, w, band.y - band.x + 5))
		ci.draw_texture_rect_region(t, Rect2(at + Vector2(0, total - cap), Vector2(w, cap)),
			Rect2(0, th - cap, w, cap))
	else:
		WindowFrame.draw(ci, Rect2(at, Vector2(w, total)))
	var y := at.y + 12
	for l in tl:
		FtlData.draw_ftl_text(ci, 24, l, Vector2(at.x + w / 2, y), COL_DARK, 1)
		y += _title_lh()
	y += 14.0
	for l in lines1:
		FtlData.draw_ftl_text(ci, 10, String(l), Vector2(at.x + w / 2, y), COL_DARK, 1)
		y += 17
	y = body.end.y + 6
	for l in lines2:
		FtlData.draw_ftl_text(ci, 10, String(l), Vector2(at.x + w / 2, y), COL_DARK, 1)
		y += 17
	return {"rect": Rect2(at, Vector2(w, total)), "body": body}


static func text_lines(id: String, width := 220) -> Array:
	var out := []
	for part in FtlData.tr_id(id).replace("\\n", " ").split("\n"):
		for l in FtlData.ftl_wrap(10, part, width):
			out.append(l)
	return out
