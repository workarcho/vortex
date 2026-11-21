class_name ShipListView
extends Control
## The ship list (ShipSelect, rules/main_menu.md §2.5), opened by LIST in the hangar and on the stats screen's
## SHIP BEST page. `customizeUI/ship_list_main_2.png` at position (112,110); title `shiplist_title` (font 63,
## COLOR_BUTTON_TEXT) followed by TYPE A / B / C TextButtons (font 62); one ShipButton per ship of the shown
## type at its grid slot (position + 24 + 205·col, position + 51 + 177·row) in SHIP_BLUEPRINT_ORDER — row 1
## left→right (order 0..3), row 2 right→left (4..7), a fifth column for order 8 / 9 at x + 864 [exe].
## ShipButton (ctor / OnInit / OnRender / MouseMove) [exe]:
## - `bShipLocked` = layout A locked, `bLayoutLocked` = the shown layout locked, `bNoExist` = type C of the
##   crystal / lanius. A ship-locked or non-existent button sits 20 px lower; a ship-unlocked one has its hit box
##   40 px taller (it covers the lower box).
## - Ship unlocked (and existing): `ship_list_button_lower_{on,select2}` at +107 (select2 while hovered /
##   selected) with the ship achievements as mini icons (CAchievement::OnRender style 2 hovered / 3, no "New!")
##   from button + (6, 123), 37 px apart; they answer the hover with AchievementTracker::SetTooltip
##   (x + 6 + 37·i .. + 32, y + 123 .. y + 155, strict).
## - The frame `ship_list_button_{on,select2,off}` (off = inactive = non-existent only; locked ships keep the
##   on / select2 frame), then `miniship_<img>.png`; a locked layout draws it again in black (silhouette) and the
##   lock `box_lock_on.png` (`box_lock_selected.png` while hovered) at + (90, 50). Non-existent: text `no_type_c`
##   (font 12) centred at the frame centre − 10 px.
## UnlockArrows (ShipSelect::Open, UnlockArrow) [exe]: one per display index 0..6 towards the next ship of the
## order — 0..2 right of the button (+191, +66, pointing right), 3 down under it (+87, +160; −20 when that ship is
## locked), 4..6 left of it (−43, +66, pointing left) — at the grid slot (not the 20 px shifted button). Status from
## layout A unlocks only, so every page shows the same arrows: next ship unlocked → none; this ship locked →
## `arrow_lock_{left,down}` (status 0); else the Kestrel → `arrow_5_right` (status 2, sector 5), the others →
## `arrow_v_{left,down}` (status 1, victory). Left images are mirrored to point right. Hover (strict, 43×28 or
## 30×85): instant tooltip `ship_unlock_sector5` (Kestrel) / `ship_unlock_victory` (\1 = this ship's class,
## \2 = the next ship's class), also on a lock arrow. Click a ship → `picked(id, type)`; outside the panel /
## Esc → `closed`. Touch [ours]: the tooltips show while a finger is held (TooltipService); buttons act on release
## and a release after a held tooltip picks nothing.

signal picked(ship_id: int, ship_type: int)
signal closed

const POS := Vector2(112, 110)  # ShipSelect::position
const PANEL_SIZE := Vector2(1080, 412)
const BUTTON_SIZE := Vector2(191, 121)
const LOCKED_DROP := 20  # ShipButton::OnInit: y + 20 when ship-locked or non-existent
const HIT_EXTRA := 40  # ShipButton::OnInit: hit box h + 40 when the ship is unlocked
const LOWER_Y := 107  # lower box offset under a ship button
const MINI_AT := Vector2(6, 123)  # first mini achievement inside a button (lower box + (6, 16))
const MINI_STEP := 37
const LOCK_AT := Vector2(90, 50)

var title: TitleState
var shown_type := 0
var selected := -1  # ship id drawn with the select2 frame (the hangar's current ship)
var hover := ""
var buttons := {}
var ach_hover := Vector2i(-1, -1)  # (ship id, achievement index) of the hovered mini icon (iSelectedAch)
var arrow_hover := -1  # display index of the hovered unlock arrow (-1 = none)


func setup(t: TitleState) -> void:
	title = t
	position = Vector2.ZERO
	size = HudLayout.FRAME
	mouse_filter = Control.MOUSE_FILTER_STOP


func open(_ship_id: int, ship_type: int) -> void:
	selected = -1  # ShipSelect::Open: selectedShip = -1 (select2 frame only on hover)
	shown_type = ship_type
	visible = true
	hover = ""
	ach_hover = Vector2i(-1, -1)
	arrow_hover = -1
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


## ShipButton::bNoExist: the crystal / lanius have no type C.
static func no_exist(id: int, type: int) -> bool:
	return type == 2 and (id == PlayerProfile.CRYSTAL or id == PlayerProfile.LANIUS)


## ShipButton hit box (= frame position): slot, 20 px lower when ship-locked / non-existent, 40 px taller when the
## ship is unlocked.
static func button_rect(i: int, ship_locked_a: bool, noexist: bool) -> Rect2:
	var p := slot_pos(i) + Vector2(0, LOCKED_DROP if ship_locked_a or noexist else 0)
	return Rect2(p, BUTTON_SIZE + Vector2(0, 0 if ship_locked_a else HIT_EXTRA))


## ShipSelect::Open UnlockArrows for a layout-A unlock test `unlocked_a(id) -> bool`: [{i, from, to, status, dir,
## rect}] for display indices 0..6 (status 3 = none, kept so the indices line up). dir 0 = down, 1 = right
## (mirrored left image / arrow_5_right), 2 = left.
static func unlock_arrows(unlocked_a: Callable) -> Array:
	var out := []
	for i in 7:
		var id: int = TitleState.SHIP_ORDER[i]
		var nxt: int = TitleState.SHIP_ORDER[i + 1]
		var s := slot_pos(i)
		var dir := 1 if i < 3 else (0 if i == 3 else 2)
		var at := s + Vector2(191, 66)
		if i == 3:
			at = s + Vector2(87, 160 - (0 if unlocked_a.call(id) else 20))
		elif i > 3:
			at = s + Vector2(-43, 66)
		var status := 3
		if not unlocked_a.call(nxt):
			status = (2 if id == 0 else 1) if unlocked_a.call(id) else 0
		var sz := Vector2(30, 85) if dir == 0 else Vector2(43, 28)
		out.append({"i": i, "from": id, "to": nxt, "status": status, "dir": dir, "rect": Rect2(at, sz)})
	return out


## UnlockArrow::OnRender image for an arrow ("" = nothing drawn: status 3, or status 2 pointing down).
static func arrow_image(a: Dictionary) -> String:
	var st := int(a.status)
	if st == 3 or (int(a.dir) == 0 and st > 1):
		return ""
	if st == 2:
		return "customizeUI/arrow_5_right.png"
	return "customizeUI/arrow_%s_%s.png" % ["lock" if st == 0 else "v", "down" if int(a.dir) == 0 else "left"]


## ShipSelect::MouseMove arrow tooltip: `ship_unlock_sector5` from the Kestrel, else `ship_unlock_victory`;
## \1 = this ship's class, \2 = the next one's (layout A blueprints).
static func arrow_text(a: Dictionary) -> String:
	var id := "ship_unlock_sector5" if int(a.i) == 0 else "ship_unlock_victory"
	return TooltipText.f(id, TitleState.ship_class(TitleState.SHIP_BLUEPRINTS[int(a.from)]),
		TitleState.ship_class(TitleState.SHIP_BLUEPRINTS[int(a.to)]))


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
		buttons["ship%d" % id] = {"rect": button_rect(i, ship_locked_a(id), no_exist(id, shown_type)), "id": id,
			"i": i}


## ShipButton::bLayoutLocked: the shown layout of ship `id` is locked (or does not exist).
func ship_locked(id: int) -> bool:
	return title == null or not title.unlocked(id, shown_type)


## ShipButton::bShipLocked: layout A of ship `id` is locked.
func ship_locked_a(id: int) -> bool:
	return title == null or not title.unlocked(id, 0)


func arrows() -> Array:
	return unlock_arrows(func(id: int) -> bool: return not ship_locked_a(id))


## Mini achievement rects of an unlocked ship's button (ShipSelect::MouseMove hit area: 32 wide, y + 123..155).
func mini_rects(b: Dictionary) -> Array:
	var p: Vector2 = (b.rect as Rect2).position
	var out := []
	for k in MenuDraw.ship_achievements(int(b.id)).size():
		out.append(Rect2(p + MINI_AT + Vector2(MINI_STEP * k, 0), Vector2(32, 32)))
	return out


func button_name_at(p: Vector2) -> String:
	for nm in buttons:
		if nm == "title":
			continue
		var r: Rect2 = buttons[nm].rect
		if p.x > r.position.x and p.x < r.end.x and p.y > r.position.y and p.y < r.end.y:
			return nm
	return ""


var _press := ""  # touch: the button under the finger (acts on release)
var _held := false  # touch: a tooltip showed while the finger was down (the release picks nothing)


func _process(_d: float) -> void:
	if is_visible_in_tree():
		hover_tooltips(TooltipService.local_pointer(self))
		if TooltipService.touch and _press != "" and not TooltipService.shown.is_empty():
			_held = true


## ShipSelect::MouseMove tooltips: the unlock arrows (instant, no title), then the mini achievements of the shown
## page's ship-unlocked, existing buttons (AchievementTracker::SetTooltip). Touch: the same while the finger is
## held (TooltipService). Returns the tooltip text requested ("" none).
func hover_tooltips(m: Vector2) -> String:
	var ah := -1
	for a in arrows():
		var r: Rect2 = a.rect
		if int(a.status) != 3 and m.x > r.position.x and m.x < r.end.x and m.y > r.position.y and m.y < r.end.y:
			ah = int(a.i)
			TooltipService.request(arrow_text(a), {"kind": &"unlock_arrow", "source": self, "instant": true,
				"ctx": {"from": a.from, "to": a.to}})
			break  # the exe moves the point off-screen after the first hit
	var sel := Vector2i(-1, -1)
	for nm in buttons:
		if not String(nm).begins_with("ship"):
			continue
		var b: Dictionary = buttons[nm]
		var id: int = b.id
		if ship_locked_a(id) or no_exist(id, shown_type):
			continue
		var k := MenuDraw.achievement_hover(self, MenuDraw.ship_achievements(id), mini_rects(b), m,
			TitleState.blueprint_of(id, shown_type))
		if k >= 0:
			sel = Vector2i(id, k)
	if ah != arrow_hover or sel != ach_hover:
		arrow_hover = ah
		ach_hover = sel
		queue_redraw()
	return TooltipService.text


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		var h := button_name_at(e.position)
		if h != hover and h != "":
			FtlData.play("hoverBeep")
		hover = h
		queue_redraw()
	elif e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if not TooltipService.touch:
			if e.pressed:
				click(e.position)
		elif e.pressed:  # touch [ours]: buttons act on release, so a finger held for a tooltip picks nothing
			_press = button_name_at(e.position)
			_held = false
			if _press == "":
				click(e.position)
		else:
			if not _held and _press != "" and button_name_at(e.position) == _press:
				click(e.position)
			_press = ""
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
		if not ship_locked(id) and not no_exist(id, shown_type):
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
	for nm in buttons:
		if not nm.begins_with("ship"):
			continue
		_draw_ship(buttons[nm], hover == nm)
	for a in arrows():  # ShipSelect::OnRender: every UnlockArrow after the buttons
		var im := arrow_image(a)
		if im == "":
			continue
		var t := FtlData.texture("img/" + im)
		if t == null:
			continue
		var r: Rect2 = a.rect
		if int(a.dir) == 1 and int(a.status) != 2:  # mirrored left image (points right)
			draw_set_transform(Vector2(r.position.x + t.get_width(), r.position.y), 0.0, Vector2(-1, 1))
			draw_texture(t, Vector2.ZERO)
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		else:
			draw_texture(t, r.position)
	for k in 3:
		var b: Dictionary = buttons["type%d" % k]
		MenuDraw.text_button(self, b, hover == "type%d" % k)


## ShipButton::OnRender: lower achievement box + mini achievements (ship unlocked), the frame, then the mini ship
## (+ black silhouette and lock when the layout is locked), or `no_type_c`.
func _draw_ship(b: Dictionary, hot: bool) -> void:
	var id: int = b.id
	var p: Vector2 = (b.rect as Rect2).position
	var noexist := no_exist(id, shown_type)
	if not ship_locked_a(id) and not noexist:
		var lower := "select2" if hot or id == selected else "on"
		MenuDraw.img(self, "customizeUI/ship_list_button_lower_%s.png" % lower, p + Vector2(0, LOWER_Y))
		var achs := MenuDraw.ship_achievements(id)
		for k in achs.size():
			MenuDraw.draw_mini(self, achs[k], p + MINI_AT + Vector2(MINI_STEP * k, 0), ach_hover == Vector2i(id, k))
	var st := "off" if noexist else ("select2" if hot or id == selected else "on")
	MenuDraw.img(self, "customizeUI/ship_list_button_%s.png" % st, p)
	if noexist:
		FtlData.draw_ftl_text(self, 12, FtlData.tr_id("no_type_c"), p + BUTTON_SIZE / 2 - Vector2(0, 10),
			Color.WHITE, FtlFont.Align.CENTER)
		return
	var mini := mini_texture(id, shown_type)
	if mini:
		draw_texture(mini, p)
	if ship_locked(id):
		if mini:
			draw_texture(mini, p, Color.BLACK)
		MenuDraw.img(self, "customizeUI/box_lock_%s.png" % ("selected" if hot else "on"), p + LOCK_AT)


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
