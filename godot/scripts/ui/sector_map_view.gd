class_name SectorMapView
extends Control
## Sector map in choice mode (rules/starmap.md "Sector map rendering", StarMap::OnRender bChoosingNewSector branch /
## RenderSectorMap / RenderSectorName) [exe]: `map/sector_box.png` at (358, 211), `sector_title` (font 63,
## COLOR_BUTTON_TEXT) at (378, 219), the tree translated by (415, 300) (sectorMapOffset (415, 285) + 15): links 2 px,
## sectors = ring r 7 (state colour) + disc r 6 (class colour, ×0.25 when unreachable), the ship marker orbiting the
## current sector, `N. name` labels (font 7) on the neighbours, the pulsing sector target boxes, the legend boxes
## and the CLOSE button (closeSectorButton 103×32 at (800, 552), store_close_base.png at (−23, −7)). Presentation
## only: PC hover selects a neighbour and click goes at once; touch taps select and the JUMP button confirms.
## Touch JUMP [ours]: TouchCombatButtons look (FTL_base.png + JUMP text rect) ×JUMP_SCALE right of the sector box,
## bottom on the CLOSE plate's bottom; dim until a neighbour is selected, lit then (held = hot text). No info panel:
## the sector tooltip is only the name, already printed on each choice's label.

const BOX_POS := Vector2(358, 211)
const BOX := Rect2(358, 211, 581, 341)
const ORIGIN := Vector2(415, 300)
const PICK := 10.0
const PICK_TOUCH := 22.0
const COL_TEXT := Color8(235, 245, 229)
const COL_HOT := Color8(255, 230, 94)
const COL_BTN_TEXT := Color8(25, 49, 51)
const COL_YELLOW := Color8(255, 255, 50)
const COL_GREEN := Color8(100, 255, 100)
const COL_GRAY := Color8(125, 125, 125)
## STARMAP_GREEN / RED / PURPLE (runtime-initialised in the exe; sampled from the vanilla screenshot).
const CLASS_COLOR := {"CIVILIAN": Color8(138, 199, 76), "HOSTILE": Color8(214, 51, 53), "NEBULA": Color8(127, 53, 210)}
const CLOSE_RECT := Rect2(800, 552, 103, 32)
const JUMP_SCALE := 1.2  # touch JUMP: same look / size as the beacon map's (StarMapView.JUMP_SCALE) [ours]
const TOUCH_GAP := 4.0

var run: RunState
var profile: InputProfile
var _hover := -1
var _press := ""
var _ship_angle := 360.0
var _box_t := 0.0  # targetBoxTimer (1 s loop)


func setup(r: RunState, p: InputProfile) -> void:
	run = r
	profile = p
	position = Vector2.ZERO
	size = HudLayout.FRAME
	mouse_filter = Control.MOUSE_FILTER_STOP


func _process(_d: float) -> void:
	visible = run != null and run.choosing_sector and run.over == ""
	mouse_filter = Control.MOUSE_FILTER_STOP if visible else Control.MOUSE_FILTER_IGNORE
	if visible:
		_ship_angle = StarMap.marker_step(_ship_angle, _d, false)
		_box_t = fmod(_box_t + _d, 1.0)
		# StarMap::OnLoop: GetPotentialSectorChoiceName of the hovered choice, instant tooltip.
		var pot := _potential()
		if pot >= 0 and sector_at(TooltipService.local_pointer(self)) == pot:
			var sct: Dictionary = run.tree.sectors[pot]
			TooltipService.request(TooltipText.rule("sector", func(n: String) -> String: return n,
				[String(sct.name)]), {"instant": true, "kind": &"sector", "source": self, "ctx": {"sector": pot}})
		queue_redraw()


func screen_pos(id: int) -> Vector2:
	return ORIGIN + run.tree.sectors[id].pos


func sector_at(p: Vector2) -> int:
	var lim := PICK_TOUCH if profile.is_touch() else PICK
	var best := -1
	var bd := lim * lim
	for s in run.tree.sectors:
		var d := screen_pos(s.id).distance_squared_to(p)
		if d < bd:
			bd = d
			best = s.id
	return best


## Touch JUMP base rect: right of the sector box, bottom on the CLOSE plate's (store_close_base.png) bottom.
func jump_rect() -> Rect2:
	var sz := TouchCombatButtons.BASE_SIZE * JUMP_SCALE
	var cb := FtlData.texture("img/storeUI/store_close_base.png")
	var bottom: float = CLOSE_RECT.position.y - 7 + (float(cb.get_height()) if cb else CLOSE_RECT.size.y + 14)
	return Rect2(Vector2(BOX.end.x + TOUCH_GAP, bottom - sz.y).round(), sz.round())


## Touch JUMP state: "" (PC), "off" (no sector selected), "on" (lit), "hot" (lit, held).
func jump_state() -> String:
	if not profile.is_touch():
		return ""
	if run.selected_sector < 0:
		return "off"
	return "hot" if _hit(TooltipService.local_mouse(self)) == "jump" else "on"


func _hit(p: Vector2) -> String:
	if CLOSE_RECT.has_point(p):
		return "close"
	if profile.is_touch() and run.selected_sector >= 0 and jump_rect().has_point(p):
		return "jump"
	var s := sector_at(p)
	return "s%d" % s if s >= 0 else ""


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var s := sector_at(event.position)
		if s != _hover:
			_hover = s
			profile.sector_hover(s)
		accept_event()
		return
	var mb := event as InputEventMouseButton
	if mb == null:
		return
	accept_event()
	if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
		profile.close_sector_map()
		return
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	var h := _hit(mb.position)
	if mb.pressed:
		_press = h
		return
	if h != _press or h == "":
		_press = ""
		return
	_press = ""
	match h:
		"close":
			profile.close_sector_map()
		"jump":
			profile.sector_jump_button()
		_:
			profile.sector_click(int(h.substr(1)))


func _img(rel: String, center: Vector2, color := Color.WHITE) -> void:
	var t := FtlData.texture("img/" + rel)
	if t:
		draw_texture(t, (center - t.get_size() / 2.0).round(), color)


## Sectors reachable (forward links) from the potential choice when one is set, else from the current sector.
func _reachable(root: int) -> Dictionary:
	var out := {root: true}
	var todo := [root]
	while not todo.is_empty():
		var id: int = todo.pop_back()
		for n in run.tree.sectors[id].links:
			if not out.has(n):
				out[n] = true
				todo.append(n)
	return out


func _potential() -> int:
	var nb: Array = run.tree.neighbours(run.sector_id)
	var pot := run.selected_sector
	if pot < 0 and not profile.is_touch():
		pot = _hover
	return pot if pot in nb else -1


func _draw() -> void:
	if run == null or not run.choosing_sector:
		return
	var box := FtlData.texture("img/map/sector_box.png")
	if box:
		draw_texture(box, BOX_POS)
	else:
		WindowFrame.draw(self, BOX)
	FtlData.draw_ftl_text(self, 63, FtlData.tr_id("sector_title"), BOX_POS + Vector2(20, 8), COL_BTN_TEXT)
	_draw_legend()
	var cb := FtlData.texture("img/storeUI/store_close_base.png")
	if cb:
		draw_texture(cb, CLOSE_RECT.position + Vector2(-23, -7))
	ShipScreen.text_button(self, CLOSE_RECT, FtlData.tr_id("button_close"), "hot" if _hit(TooltipService.local_mouse(self))
		== "close" and not profile.is_touch() else "on")
	var t := run.tree
	var cur := run.sector_id
	var nb: Array = t.neighbours(cur)
	var pot := _potential()
	var reach := _reachable(pot if pot >= 0 else cur)
	# Links (2 px): from the current sector white / green to the potential choice / gray to the other choice;
	# elsewhere yellow between visited sectors, white between reachable ones, else gray.
	for sct in t.sectors:
		for n in sct.links:
			var col := COL_GRAY
			if sct.id == cur:
				col = Color.WHITE if pot < 0 else (COL_GREEN if n == pot else COL_GRAY)
			elif sct.visited and t.sectors[n].visited:
				col = COL_YELLOW
			elif reach.has(sct.id) and reach.has(n):
				col = Color.WHITE
			draw_line(screen_pos(sct.id), screen_pos(n), col, 2.0)
	for sct in t.sectors:
		var p := screen_pos(sct.id)
		var ring := COL_GRAY
		if sct.id == pot:
			ring = COL_GREEN
		elif sct.visited:
			ring = COL_YELLOW
		elif reach.has(sct.id):
			ring = Color.WHITE
		draw_circle(p, 7.0, ring)
		var fill: Color = CLASS_COLOR.get(String(sct.cls), Color.WHITE)
		if not reach.has(sct.id) and not sct.visited:
			fill = Color(fill.r * 0.25, fill.g * 0.25, fill.b * 0.25)
		draw_circle(p, 6.0, fill)
	# Ship marker: the beacon map's orbiting sprite (−10, −32) on the current sector.
	var ship := FtlData.texture("img/map/map_icon_ship.png")
	if ship:
		draw_set_transform(screen_pos(cur), deg_to_rad(_ship_angle))
		draw_texture(ship, Vector2(-10, -32))
		draw_set_transform(Vector2.ZERO)
	# Labels + target boxes on the choices: all of them with no potential choice (yellow boxes), else only the
	# potential one (green box, yellow label; the other label gray).
	var o := roundi((1.0 - cos(TAU * _box_t)) * 0.5 * 5.0)
	for i in nb.size():
		var id: int = nb[i]
		var p := screen_pos(id)
		var lc := Color.WHITE if pot < 0 else (COL_YELLOW if id == pot else COL_GRAY)
		_label(i, nb.size(), t.sectors[id], p, lc)
		if pot >= 0 and id != pot:
			continue
		var tb := FtlData.texture("img/map/map_targetbox_sector_%s.png" % ("g" if id == pot else "y"))
		if tb:
			for sx in [1, -1]:
				for sy in [1, -1]:
					draw_set_transform(p, 0.0, Vector2(sx, sy))
					draw_texture(tb, Vector2(o - 20, o - 20))
			draw_set_transform(Vector2.ZERO)
	if profile.is_touch():
		var st := jump_state()
		TouchCombatButtons.draw_jump_look(self, jump_rect().position, JUMP_SCALE,
			TouchCombatButtons.label("button_jump", "JUMP"), "off" if st == "off" else "lit", st == "hot")
		draw_set_transform(Vector2.ZERO)


## RenderSectorName: "N. name" in font 7 inside a black (α 0.8) box with a 1 px outline in the label colour;
## box w = text + 7, h = text + 3, at (x − (text − 35), y − 40) for the first choice (above), y + 20 for the second.
func _label(i: int, count: int, sct: Dictionary, p: Vector2, col: Color) -> void:
	var nm := String(sct.get("short", "")) if String(sct.get("short", "")) != "" else String(sct.name)
	var text := "%d. %s" % [i + 1, nm]
	var tw := FtlData.ftl_text_width(7, text)
	var th := FtlData.ftl_line_height(7)
	var dy := 40 if (count == 1 or i == 0) else -20
	var r := Rect2(p.x - (tw - 35), p.y - dy, tw + 7, th + 3)
	draw_rect(r, Color(0, 0, 0, 0.8))
	draw_rect(r.grow(-0.5), col, false, 1.0)
	FtlData.draw_ftl_text(self, 7, text, r.position + Vector2(5, 1), col)


## Legend [exe]: dark boxes (0.122, 0.075, 0.075) 23 px tall at y 517 (3 px stepped corners), class dots
## `sector_legend_*.png` and the `sector_legend_*` texts (font 52, COLOR_BUTTON_ON) at y 519.
func _draw_legend() -> void:
	var x := BOX_POS.x + 17
	for cls in ["civilian", "hostile", "nebula"]:
		var text := FtlData.tr_id("sector_legend_" + cls)
		var w := FtlData.ftl_text_width(52, text) + 30
		var c := Color(0.12156863, 0.07450981, 0.07450981)
		var y := BOX_POS.y + 306
		for k in 3:
			var d := 3 - k
			draw_rect(Rect2(x + d, y + k, w - 2 * d, 1), c)
			draw_rect(Rect2(x + d, y + 23 - k - 1, w - 2 * d, 1), c)
		draw_rect(Rect2(x, y + 3, w, 17), c)
		var li := FtlData.texture("img/map/sector_legend_%s.png" % cls)
		if li:
			draw_texture(li, Vector2(x + 6, BOX_POS.y + 310))
		FtlData.draw_ftl_text(self, 52, text, Vector2(x + 27, BOX_POS.y + 308), COL_TEXT)
		x += w + 6
