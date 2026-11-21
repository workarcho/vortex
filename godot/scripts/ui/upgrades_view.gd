class_name UpgradesView
extends Control
## Upgrades tab (rules/ship_management.md §4.1): `upgrades_main.png` at P + (0, −7), ship name, frame labels, one
## `UpgradeBox` per system (top row = systems that need power at x = 39 + 66·k, y = 115; bottom row = subsystems at
## x = 16 + 66·k, y = 330; placeholders `*_bar_none`), the reactor button at (305, 327), Undo at (33, 471) and the
## info box at P + (600, 0). PC: click buys a level, right click refunds the last one; touch: first tap selects
## (info), second tap buys (no per-box refund, only Undo). Positions inside a box (symbol, bars) are [inferred].

const P := ShipScreen.P
const TOP_Y := 115
const BOTTOM_Y := 330
const REACTOR := Rect2(305, 327, 272, 113)
const UNDO := Rect2(33, 471, 97, 32)
const UNDO_BASE := Vector2(10, 464)
const BAR := Vector2(15, 6)
const BAR_GAP := 2
const COL_BOUGHT := Color8(100, 255, 100)
const COL_TEMP := Color(1, 1, 0.3921569)
const COL_EMPTY := Color(1, 1, 0.3921569, 0.25)
const COL_TEXT_HOT := Color8(245, 238, 163)

var run: RunState
var profile: InputProfile
var screen: ShipScreen
var _hover := ""  # system id, "reactor", "undo" or ""
var _selected := ""  # touch: first tap


func setup(r: RunState, p: InputProfile, s: ShipScreen) -> void:
	run = r
	profile = p
	screen = s
	position = Vector2.ZERO
	size = HudLayout.FRAME
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED


## [{id, top, rect}] in absolute coordinates.
func boxes() -> Array:
	var out := []
	var kt := 0
	var kb := 0
	for e in UpgradeSession.layout(run.ship):
		var r: Rect2
		if e.top:
			r = Rect2(P + Vector2(39 + 66 * kt, TOP_Y), Vector2(66, 150))
			kt += 1
		else:
			r = Rect2(P + Vector2(16 + 66 * kb, BOTTOM_Y), Vector2(66, 113))
			kb += 1
		out.append({"id": e.id, "top": e.top, "rect": r})
	return out


func hit(p: Vector2) -> String:
	for b in boxes():
		if String(b.id) != "" and (b.rect as Rect2).has_point(p):
			return String(b.id)
	if Rect2(P + REACTOR.position, REACTOR.size).has_point(p):
		return "reactor"
	if Rect2(P + UNDO.position, UNDO.size).has_point(p):
		return "undo"
	return ""


func _gui_input(event: InputEvent) -> void:
	accept_event()
	if event is InputEventMouseMotion:
		_hover = hit(event.position)
		return
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed:
		return
	click(mb.position, mb.button_index == MOUSE_BUTTON_RIGHT)


## A click / tap at `p` (tests and CLI use it too).
func click(p: Vector2, right := false) -> void:
	var h := hit(p)
	if h == "":
		if not right:
			screen.chrome_click(p)
		return
	if h == "undo":
		if not right:
			screen.send(RunIntent.UPGRADE_UNDO)
		return
	if right:
		if not profile.is_touch():
			screen.send(RunIntent.UPGRADE_REFUND, {"sys": h})
		return
	if profile.is_touch() and _selected != h:
		_selected = h  # touchSelectable: first tap selects (info box)
		return
	screen.send(RunIntent.UPGRADE_BUY, {"sys": h})


func _draw() -> void:
	if run == null or not run.mgmt.open:
		return
	var ses := run.mgmt.upgrades
	var ship := run.ship
	var mouse := TooltipService.local_pointer(self) if not profile.is_touch() else Vector2(-1, -1)
	var hot := hit(mouse) if not profile.is_touch() else _selected
	ShipScreen.img(self, "upgradeUI/Equipment/upgrades_main.png", P + Vector2(0, -7))
	FtlData.draw_ftl_text(self, 24, _ship_name(), P + Vector2(302, 39), ShipScreen.COL_TEXT, 1)
	FtlData.draw_ftl_text(self, 62, FtlData.tr_id("upgrade_frame_systems"), P + Vector2(18, 66), ShipScreen.COL_DARK)
	FtlData.draw_ftl_text(self, 62, FtlData.tr_id("upgrade_frame_subsystems"), P + Vector2(18, 290),
		ShipScreen.COL_DARK)
	FtlData.draw_ftl_text(self, 62, FtlData.tr_id("upgrade_frame_reactor"), P + Vector2(296, 290),
		ShipScreen.COL_DARK)
	for b in boxes():
		_draw_box(b, hot)
	_draw_reactor(hot == "reactor")
	ShipScreen.img(self, "upgradeUI/buttons_undo_base.png", P + UNDO_BASE)
	ShipScreen.text_button(self, Rect2(P + UNDO.position, UNDO.size), FtlData.tr_id("button_undo"),
		"off" if not ses.has_pending() else ("hot" if hot == "undo" else "on"))  # off = COLOR_BUTTON_OFF
	# Info box (hovered / selected box).
	if hot != "" and hot != "undo":
		_draw_info(hot)
	screen.draw_chrome(self, mouse)


func _ship_name() -> String:
	var text := FtlData.ship_blueprint_text(String(run.ship.blueprint.get("name", "")))
	var a := FtlData.tag_attrs(text, "name")
	if a.has("id"):
		return FtlData.tr_id(String(a.id))
	var v := FtlData.tag_value(text, "name").strip_edges()
	return v if v != "" else String(run.ship.blueprint.get("name", ""))


func _draw_box(b: Dictionary, hot: String) -> void:
	var r: Rect2 = b.rect
	var kind := "system" if b.top else "subsystem"
	var id := String(b.id)
	if id == "":
		ShipScreen.img(self, "upgradeUI/upgrade_%s_bar_none.png" % kind, r.position)
		return
	var ses := run.mgmt.upgrades
	var cost := ses.cost_next(run.ship, id)
	var maxed := cost < 0
	var st := "on"
	if maxed:
		st = "max_select2" if hot == id else "max_on"
	elif hot == id:
		st = "select2"
	ShipScreen.img(self, "upgradeUI/upgrade_%s_bar_%s.png" % [kind, st], r.position)
	# UpgradeBox::OnRender [exe]: symbol (64×64) at (x, y + 66) (subsystems y + 30); RenderPowerBoxesPlain
	# 15×6 bars, gap 2, from (x + 24, symbol y + 8) upward: bought COLOR_GREEN, pending (255, 255, 100),
	# not yet bought (255, 255, 100, α 0.25); cost in font 0 at (x + 30, y + 130 / 93), COLOR_BUTTON_ON or
	# (245, 238, 163) when hovered; maxed: `upgrade_max` font 52 centred at (x + 33, cost y − 5).
	var s := run.ship.sys(id)
	var mx := UpgradeSession.max_level(run.ship, id)
	var tmp := int(ses.temp.get(id, 0))
	var sym_y := r.position.y + (66.0 if b.top else 30.0)
	for i in mx:
		var br := Rect2(r.position.x + 24, sym_y + 8 - (BAR.y + BAR_GAP) * i, BAR.x, BAR.y)
		if i < s.level:
			draw_rect(br, COL_BOUGHT)
		elif i < s.level + tmp:
			draw_rect(br, COL_TEMP)
		else:
			draw_rect(br, COL_EMPTY)
	var sym := FtlData.first_texture(["img/icons/s_%s_green1.png" % id, "img/icons/s_%s_grey1.png" % id])
	if sym:
		draw_texture(sym, Vector2(r.position.x, sym_y))
	var cy := r.position.y + (130.0 if b.top else 93.0)
	var tc := COL_TEXT_HOT if hot == id else ShipScreen.COL_TEXT
	if maxed:
		FtlData.draw_ftl_text(self, 52, FtlData.tr_id("upgrade_max"), Vector2(r.position.x + 33, cy - 5), tc, 1)
	else:
		FtlData.draw_ftl_text(self, 0, "%d" % cost, Vector2(r.position.x + 30, cy), tc)


## ReactorButton::OnRender [exe]: 25 bars 32×8 in columns of 5 (x + 30 + 44·col, bottom row at image height − 47,
## 13 px up per bar): bought COLOR_GREEN, pending (255, 255, 100), rest (255, 255, 100, α 0.25); the
## `upgrade_reactor_power` text (font 52, number in font 0 right-aligned in an "88" slot) centred on x 103 at y 93;
## cost font 0 at (235, 93); maxed `upgrade_max` font 52 centred at (238, 88).
func _draw_reactor(hot: bool) -> void:
	var ses := run.mgmt.upgrades
	var at := P + REACTOR.position
	var n := ses.reactor_level(run.ship)
	var cost := ses.reactor_cost_next(run.ship)
	var st := "off" if cost < 0 else ("select2" if hot else "on")
	var sz := ShipScreen.img(self, "upgradeUI/Equipment/equipment_reactor_%s.png" % st, at)
	var bottom := at.y + (sz.y if sz.y > 0 else REACTOR.size.y) - 47
	for i in UpgradeSession.REACTOR_MAX:
		var cr := Rect2(at.x + 30 + 44 * (i / 5), bottom - 13 * (i % 5), 32, 8)
		if i < run.ship.reactor_max:
			draw_rect(cr, COL_BOUGHT)
		elif i < n:
			draw_rect(cr, COL_TEMP)
		else:
			draw_rect(cr, COL_EMPTY)
	var tc := COL_TEXT_HOT if hot else ShipScreen.COL_TEXT
	var parts := FtlData.tr_id("upgrade_reactor_power").split("\\1")
	var slot := FtlData.ftl_text_width(0, "88")
	var tw := 0
	for q in parts:
		tw += FtlData.ftl_text_width(52, q)
	var x := at.x + 103 - (tw + slot) / 2
	for k in parts.size():
		if k > 0:
			x += slot
			FtlData.draw_ftl_text(self, 0, str(n), Vector2(x, at.y + 93), tc, 2)
		FtlData.draw_ftl_text(self, 52, parts[k], Vector2(x, at.y + 92), tc)
		x += FtlData.ftl_text_width(52, parts[k])
	if cost >= 0:
		FtlData.draw_ftl_text(self, 0, "%d" % cost, at + Vector2(235, 93), tc)
	else:
		FtlData.draw_ftl_text(self, 52, FtlData.tr_id("upgrade_max"), at + Vector2(238, 88), tc, 1)


func _draw_info(id: String) -> void:
	var at := P + Vector2(600, 0)
	var ses := run.mgmt.upgrades
	if id == "reactor":
		var c := ses.reactor_cost_next(run.ship)
		ShipScreen.info_box(self, at, FtlData.tr_id("upgrade_reactor"),
			"Reactor power: %d bars." % ses.reactor_level(run.ship) + ("\n\nNext bar: %d scrap." % c if c >= 0 else ""),
			"Not enough scrap." if c > run.ship.scrap else "")
		return
	# Upgrades: InfoBox::SetSystem(system, tempUpgrade): the per-level table with the bought bars previewed.
	var s := run.ship.sys(id)
	if s == null:
		return
	var d := InfoPanels.system_content(id, s.level, "", {"context": "upgrades", "ship": run.ship})
	InfoPanels.draw_system(self, at, d, UpgradeSession.max_level(run.ship, id), s.level, int(ses.temp.get(id, 0)))
