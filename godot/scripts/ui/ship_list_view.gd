class_name ShipListView
extends Control
## The ship list (ShipSelect, rules/main_menu.md §2.5), opened by LIST in the hangar and on the stats screen's
## SHIP BEST page. `customizeUI/ship_list_main_2.png` at position (112,110); title `shiplist_title` (font 63,
## COLOR_BUTTON_TEXT) followed by TYPE A / B / C TextButtons (font 62); one ShipButton per ship of the shown
## type: `ship_list_button_{on,select2,off}` frame + `miniship_<img>.png` at (position + 24 + 205·col,
## position + 51 + 177·row) in SHIP_BLUEPRINT_ORDER — row 1 left→right (order 0..3), row 2 right→left (4..7),
## a fifth column for order 8 / 9 at x + 864 [exe]. Under each: `ship_list_button_lower` (+107) with the
## mini achievement markers `achievements/S_1..3`, `S_V` and (quest ships) `S_Q`, 37 px apart [exe; offsets
## from screenshot 39]. Locked ships: black silhouette + `box_lock_on.png`. The current hangar ship uses the
## `select2` frame. Click a ship → `picked(id, type)`; click outside the panel / Esc → `closed`.

signal picked(ship_id: int, ship_type: int)
signal closed

const POS := Vector2(112, 110)  # ShipSelect::position
const PANEL_SIZE := Vector2(1080, 412)
const BUTTON_SIZE := Vector2(191, 121)
const LOWER_Y := 107  # lower box offset under a ship button
const MINI_AT := Vector2(5, 123)  # first mini marker inside a button [screenshot 39]
const MINI_STEP := 37

var title: TitleState
var shown_type := 0
var selected := -1  # ship id drawn with the select2 frame (the hangar's current ship)
var hover := ""
var buttons := {}


func setup(t: TitleState) -> void:
	title = t
	position = Vector2.ZERO
	size = HudLayout.FRAME
	mouse_filter = Control.MOUSE_FILTER_STOP


func open(ship_id: int, ship_type: int) -> void:
	selected = -1  # ShipSelect::Open: selectedShip = -1 (select2 frame only on hover)
	shown_type = ship_type
	visible = true
	hover = ""
	_build()
	queue_redraw()


func close() -> void:
	if visible:
		visible = false
		closed.emit()


## ShipSelect::Open grid: slot of display index i (0..9).
static func slot_pos(i: int) -> Vector2:
	if i >= 8:
		return POS + Vector2(864, 51 + 177 * (i - 8))
	if i < 4:
		return POS + Vector2(24 + 205 * i, 51)
	return POS + Vector2(24 + 205 * (7 - i), 228)


func _build() -> void:
	buttons.clear()
	var tw := FtlData.ftl_text_width(63, FtlData.tr_id("shiplist_title"))
	var labels := []
	var bw := 0
	for k in 3:
		var l := FtlData.tr_id("typebutton_type_" + "abc"[k])
		if l == "typebutton_type_" + "abc"[k]:
			l = "TYPE " + "ABC"[k]
		labels.append(l)
		bw = maxi(bw, FtlData.ftl_text_width(62, l) + 12)
	var total := tw + 30 + 3 * bw + 8
	var x := POS.x + PANEL_SIZE.x / 2 - total / 2.0
	buttons["title"] = {"rect": Rect2(x, 120, tw, 0)}
	x += tw + 30
	for k in 3:
		var st := "selected" if k == shown_type else "on"
		buttons["type%d" % k] = {"rect": Rect2(x, 120, bw, 26), "label": labels[k], "font": 62, "state": st}
		x += bw + 4
	for i in 10:
		var id: int = TitleState.SHIP_ORDER[i]
		var p := slot_pos(i)
		buttons["ship%d" % id] = {"rect": Rect2(p, BUTTON_SIZE), "id": id, "i": i}


func ship_locked(id: int) -> bool:
	return title == null or not title.unlocked(id, shown_type)


func button_name_at(p: Vector2) -> String:
	for nm in buttons:
		if nm == "title":
			continue
		var r: Rect2 = buttons[nm].rect
		if p.x > r.position.x and p.x < r.end.x and p.y > r.position.y and p.y < r.end.y:
			return nm
	return ""


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		var h := button_name_at(e.position)
		if h != hover and h != "":
			FtlData.play("hoverBeep")
		hover = h
		queue_redraw()
	elif e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT and e.pressed:
		click(e.position)
	accept_event()


func _unhandled_key_input(e: InputEvent) -> void:
	if visible and e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()


## ShipSelect::MouseClick: a type button switches the page; an unlocked ship is picked (and the list closes);
## outside the panel closes.
func click(p: Vector2) -> void:
	var nm := button_name_at(p)
	if nm.begins_with("type"):
		shown_type = int(nm.trim_prefix("type"))
		_build()
	elif nm.begins_with("ship"):
		var id: int = buttons[nm].id
		if not ship_locked(id):
			visible = false
			picked.emit(id, shown_type)
	elif not Rect2(POS, PANEL_SIZE).has_point(p):
		close()
	queue_redraw()


func _draw() -> void:
	draw_rect(HudLayout.cover_rect(self, TooltipService.touch), Color(0, 0, 0, 0.5))  # GL_SetColorTint 0.5 behind
	MenuDraw.img(self, "customizeUI/ship_list_main_2.png", POS)
	var tr: Rect2 = buttons.title.rect
	FtlData.draw_ftl_text(self, 63, FtlData.tr_id("shiplist_title"), Vector2(tr.position.x, 119), MenuDraw.COL_TEXT)
	for k in 3:
		var b: Dictionary = buttons["type%d" % k]
		MenuDraw.text_button(self, b, hover == "type%d" % k)
	for nm in buttons:
		if not nm.begins_with("ship"):
			continue
		_draw_ship(buttons[nm], hover == nm)


## ShipButton::OnRender: lower achievement box + markers, the frame, then the mini ship (or its silhouette + lock).
func _draw_ship(b: Dictionary, hot: bool) -> void:
	var id: int = b.id
	var p: Vector2 = (b.rect as Rect2).position
	var locked := ship_locked(id)
	if not locked:
		var lower := "select2" if hot else "on"
		MenuDraw.img(self, "customizeUI/ship_list_button_lower_%s.png" % lower, p + Vector2(0, LOWER_Y))
		var x := p.x + MINI_AT.x
		for m in MenuDraw.mini_markers(id):
			MenuDraw.img(self, "achievements/%s.png" % m, Vector2(x, p.y + MINI_AT.y))
			x += MINI_STEP
	var st := "off" if locked else ("select2" if hot or id == selected else "on")
	MenuDraw.img(self, "customizeUI/ship_list_button_%s.png" % st, p)
	var mini := mini_texture(id, shown_type)
	if mini:
		draw_texture(mini, p, Color.BLACK if locked else Color.WHITE)
	if locked:
		MenuDraw.img(self, "customizeUI/box_lock_on.png", p + BUTTON_SIZE / 2 - Vector2(8, 11))


static var _mini_cache := {}


## `customizeUI/miniship_<blueprint img>.png` (falls back to layout A's image for a missing variant).
static func mini_texture(id: int, type: int) -> Texture2D:
	var key := id * 3 + type
	if not _mini_cache.has(key):
		var names := []
		for t in [type, 0]:
			var bp := TitleState.blueprint_of(id, t)
			if FtlData.has_ship_blueprint(bp):
				names.append("img/customizeUI/miniship_%s.png" % String(FtlData.ship_blueprint(bp).get("img", "")))
		_mini_cache[key] = FtlData.first_texture(names) if not names.is_empty() else null
	return _mini_cache[key]
