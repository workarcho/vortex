class_name StoreView
extends Control
## Store window (rules/store.md §2, §6 and "Store screen rendering (1280×720)") drawn with the original art at the
## exe position W = (340, 85) (rules/ship_management.md: 601 wide, centred). Scene behind tinted ×0.15; BUY window
## `store_buy_main.png` + SELL tab button, column titles, section headings, the bottom-left hull display, page tabs
## (one 237×31 image top-right, only with > 2 sections), equipment boxes (weapon / drone icon, 2× crew portrait, name
## in the dark bar font 6→9, price font 0), row boxes (system icon, title font 14, price font 0), item and repair
## boxes, the 323-wide info box right of the window, the CLOSE text button and the system confirmation.
## Presentation only: gestures go to the InputProfile (PC hover = info, click = buy; touch: first tap selects and
## shows the info, a second tap on the selected box buys — no BUY button, as in the exe).
##
## SELL tab: until the ship-management EquipmentView (store mode) replaces it, a simple click-to-sell list is drawn
## here. Hook point: `embed_sell_view(view)` puts any Control at W on the SELL tab (shown only there, gets the input
## first as our child); our own list and its input are then disabled.

const WPOS := Vector2(336, 85)  # 1.6.14 screenshots (= ShipScreen.P); 1.6.9 exe TabbedWindow loc (340, 85)
const WSIZE := Vector2(601, 471)
const RES_Y := {RunState.BOX_FUEL: 83, RunState.BOX_MISSILES: 133, RunState.BOX_DRONES: 182}
const RES_IMG := {RunState.BOX_FUEL: "fuel", RunState.BOX_MISSILES: "missiles", RunState.BOX_DRONES: "drones"}
const REPAIR_Y := {RunState.BOX_REPAIR_ONE: 291, RunState.BOX_REPAIR_ALL: 346}
const INFO_X := 600.0  # infoBox.location = W + (600, 0); WindowFrame(7, 7, 323, h) at location + (0, 67)
const INFO_W := 323.0
const INFO_H := {"weapon": 252, "drone": 162, "item": 121, "augment": 136, "crew": 242, "system": 170, "sell": 160}
const CLOSE_BASE := Vector2(445, 463)
const CLOSE_RECT := Rect2(468, 470, 103, 32)
const PAGE_POS := Vector2(352, 11)  # one 237×31 image
const PAGE_HIT := [Rect2(352, 11, 118, 32), Rect2(470, 11, 118, 32)]  # left half = page 1, right half = page 2
const SELL_TAB := Rect2(168, 7, 159, 36)  # buy_sell_* image at (163, 0) 179×46 (shown on BUY)
const BUY_TAB := Rect2(5, 7, 150, 36)  # sell_buy_* image at (0, 0) 170×46 (shown on SELL)
const CONFIRM := Rect2(440, 260, 400, 150)
const COL_ON := Color8(235, 245, 229)  # COLOR_BUTTON_ON
const COL_TEXT := Color8(25, 49, 51)  # COLOR_BUTTON_TEXT
const COL_OFF := Color8(164, 171, 160)  # COLOR_BUTTON_OFF
const COL_SELECT := Color8(255, 230, 94)  # COLOR_BUTTON_SELECT
const COL_HOVER := Color8(245, 238, 163)  # store box text, active and hovered / selected
const COL_BAD := Color8(255, 90, 80)
const ROW_KINDS := [RunStore.WEAPONS, RunStore.DRONES, RunStore.CREW]
const BG_TINT := 0.15  # CommandGui::RenderStatic with bFullFocus: scene × 0.15
const CREW_NO_PUSH := ["rock", "crystal", "mantis"]  # pushIcon (0, 0); others (0, 5)

var run: RunState
var profile: InputProfile
var sell_view: Control = null  # hook: an embedded Equipment (store mode) view for the SELL tab
var _rects: Array = []  # [Rect2, code]
var _hover := -1
var _press := -2
var debug_pointer := Vector2.INF  # --store-pointer=X,Y (screenshots): pushed as a mouse motion every frame


func setup(r: RunState, p: InputProfile) -> void:
	run = r
	profile = p
	position = Vector2.ZERO
	size = HudLayout.FRAME
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	mouse_filter = Control.MOUSE_FILTER_STOP
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--store-pointer="):  # screenshots: simulated mouse position (hover states, SELL tab too)
			var xy := a.trim_prefix("--store-pointer=").split(",")
			debug_pointer = Vector2(float(xy[0]), float(xy[1]))


## Hook for the ship-management agent: an Equipment view in store mode replaces our simple sell list. The view is
## added as a child at W (its own coordinates start at the window origin) and is visible only on the SELL tab.
func embed_sell_view(view: Control) -> void:
	if sell_view and sell_view != view and sell_view.get_parent() == self:
		remove_child(sell_view)
	sell_view = view
	if view and view.get_parent() != self:
		add_child(view)
	if view:
		view.position = WPOS


func _process(_d: float) -> void:
	visible = run != null and run.store_open and run.over == "" and run.store() != null
	mouse_filter = Control.MOUSE_FILTER_STOP if visible else Control.MOUSE_FILTER_IGNORE
	if sell_view:
		sell_view.visible = visible and run.store_tab == 1
	if visible and debug_pointer != Vector2.INF:  # screenshots: a simulated mouse position (hover states)
		var ev := InputEventMouseMotion.new()
		ev.position = debug_pointer
		ev.global_position = debug_pointer
		get_viewport().push_input(ev)
	if visible:
		if debug_pointer != Vector2.INF:
			TooltipService.debug_pointer = debug_pointer
		_tooltip()
		queue_redraw()


## PC: the disabled reason of the hovered box is the mouse tooltip (Weapon/Drone/...StoreBox::MouseMove →
## MouseControl::SetTooltip: max_weapons, max_drones, max_augments, have_…, max_crew, sys_full; augments instant).
func blocked_reason(at: Vector2) -> String:
	if run == null or profile == null or profile.is_touch() or run.store() == null or run.store_tab != 0:
		return ""
	var c := _code_at(at)
	if c < 0 or c >= 12:
		return ""
	var o := run.store().offer(c / 3, c % 3)
	if o.is_empty() or int(o.count) <= 0 or String(o.name) == "":
		return ""
	return RunStore.can_hold(o, run)


func _tooltip() -> void:
	var at := TooltipService.local_pointer(self)
	var why := blocked_reason(at)
	if why != "":
		var o := run.store().offer(_code_at(at) / 3, _code_at(at) % 3)
		TooltipService.request(TooltipText.rule("store_blocked", func(r: String) -> String: return _reason_text(r),
			[why]), {"instant": String(o.get("kind", "")) == "augment", "kind": &"store_blocked", "source": self,
			"ctx": {"offer": o}})


## Clickable rects of the current page / tab (codes: RunState box codes; 200+i sell rows; -10 close; -11/-12 the
## other page's half of the page tabs (-11 → page 1, -12 → page 2); -13/-14 BUY/SELL tab; -21/-22 confirm yes/no;
## -23 touch SELL button of the simple sell list).
func layout() -> Array:
	var out := []
	var st := run.store()
	if st == null:
		return out
	if not st.pending_confirm.is_empty():
		out.append([Rect2(CONFIRM.position + Vector2(40, 100), Vector2(120, 36)), -21])
		out.append([Rect2(CONFIRM.position + Vector2(240, 100), Vector2(120, 36)), -22])
		return out
	out.append([_w(CLOSE_RECT), -10])
	if run.store_tab == 1:
		out.append([_w(BUY_TAB), -13])
		if sell_view != null:
			return out
		var items := RunStore.sellable(run)
		for i in items.size():
			out.append([Rect2(WPOS + Vector2(203, 70 + 34 * i), Vector2(380, 30)), 200 + i])
		if profile.is_touch() and run.store_selected >= 200:
			out.append([Rect2(_info_rect("sell").position + Vector2(100, 110), Vector2(120, 40)), -23])
		return out
	out.append([_w(SELL_TAB), -14])
	if st.sections.size() > 2:
		var other := 1 - run.store_page
		out.append([_w(PAGE_HIT[other]), -11 - other])
	for code in RES_Y:
		out.append([Rect2(WPOS + Vector2(18, RES_Y[code]), Vector2(169, 40)), code])
	for code in REPAIR_Y:
		out.append([Rect2(WPOS + Vector2(18, REPAIR_Y[code]), Vector2(169, 44)), code])
	for half in 2:
		var si := run.store_page * 2 + half
		if si >= st.sections.size():
			continue
		var sec: Dictionary = st.sections[si]
		for b in 3:
			out.append([box_rect(int(sec.type), half, b), si * 3 + b])
	return out


static func _w(r: Rect2) -> Rect2:
	return Rect2(WPOS + r.position, r.size)


## Store::SetPositions: equipment boxes 109×110 in a row at x = 208 + 125·i, y 103 / 312; augment / system rows
## 380×40 at x = 203, y = 83 + 53·i (+209 for the bottom section).
static func box_rect(ty: int, half: int, b: int) -> Rect2:
	var dy := 209 * half
	if ty in ROW_KINDS:
		return Rect2(WPOS + Vector2(208 + 125 * b, 103 + dy), Vector2(109, 110))
	return Rect2(WPOS + Vector2(203, 83 + 53 * b + dy), Vector2(380, 40))


func _code_at(p: Vector2) -> int:
	for r in layout():
		if (r[0] as Rect2).has_point(p):
			return int(r[1])
	return -1


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var c := _code_at(event.position)
		if c != _hover:
			_hover = c
			if c >= 0 and c < 200:
				profile.store_hover(c)
			elif not profile.is_touch() and run.store_selected >= 0 and run.store_selected < 200:
				run.store_selected = -1  # PC: the info box follows the pointer
		accept_event()
		return
	var mb := event as InputEventMouseButton
	if mb == null:
		return
	accept_event()
	if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
		profile.store_close()
		return
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	var c := _code_at(mb.position)
	if mb.pressed:
		_press = c
		return
	if c != _press or c == -1:
		if c == -1 and profile.is_touch() and run.store_selected >= 0:
			run.store_selected = -1  # touching elsewhere deselects
		_press = -2
		return
	_press = -2
	click(c)


## A completed click / tap on a code (also used by tests and the CLI).
func click(c: int) -> void:
	match c:
		-10:
			profile.store_close()
		-11, -12:
			profile.store_page(-11 - c)
		-13:
			profile.store_tab(0)
		-14:
			profile.store_tab(1)
		-21, -22:
			profile.store_confirm(c == -21)
		-23:
			profile.sell_click(run.store_selected - 200)
		_:
			if c >= 200:
				profile.sell_click(c - 200)
			elif c >= 0:
				profile.store_click(c)


func _img(rel: String, p: Vector2) -> void:
	var t := FtlData.texture("img/" + rel)
	if t:
		draw_texture(t, p)


## Button::OnRender image: inactive → off; selected → select2; hovered (PC) → select2; else on.
func _state(code: int, active: bool) -> String:
	if not active:
		return "off"
	if code == run.store_selected or (code == _hover and not profile.is_touch()):
		return "select2"
	return "on"


## StoreBox::OnRender text colour: (245,238,163) when (active and hovered) or selected, else COLOR_BUTTON_ON.
func _text_col(code: int, active: bool) -> Color:
	if code == run.store_selected or (active and code == _hover and not profile.is_touch()):
		return COL_HOVER
	return COL_ON


func _draw() -> void:
	if run == null or not run.store_open or run.store() == null:
		return
	_rects = layout()
	var st := run.store()
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 1.0 - BG_TINT))  # scene × 0.15 (opaque scene)
	var sell := run.store_tab == 1
	# 1. TabbedWindow: the other tab's button.
	if sell:
		_img("upgradeUI/Equipment/tabButtons/sell_buy_%s.png" % ("select2" if _hover == -13 else "on"), WPOS)
	else:
		_img("upgradeUI/Equipment/tabButtons/buy_sell_%s.png" % ("select2" if _hover == -14 else "on"),
			WPOS + Vector2(163, 0))
	# 2. Window art, tab texts.
	_img("storeUI/store_%s_main.png" % ("sell" if sell else "buy"), WPOS)
	_tab_text(FtlData.tr_id("store_tab_buy"), 86, 110)
	_tab_text(FtlData.tr_id("store_tab_sell"), 248, 113)
	if sell:
		if sell_view == null:
			_draw_sell()
	else:
		_draw_buy(st)
	_draw_info(st)
	if not st.pending_confirm.is_empty():
		_draw_confirm(st)
	# 8. CLOSE TextButton on store_close_base.png.
	_img("storeUI/store_close_base.png", WPOS + CLOSE_BASE)
	var cr := _w(CLOSE_RECT)
	var hot := _hover == -10
	draw_rect(cr, COL_SELECT if hot else COL_ON)
	FtlData.draw_ftl_text(self, 63, FtlData.tr_id("button_close"), Vector2(cr.get_center().x, cr.position.y + 6),
		COL_TEXT, 1)


## Store::DrawBuySellTabText: font 63 at y 8, or font 62 at y 13 when wider than the limit.
func _tab_text(t: String, cx: float, limit: int) -> void:
	if FtlData.ftl_text_width(63, t) > limit:
		FtlData.draw_ftl_text(self, 62, t, WPOS + Vector2(cx, 13), COL_TEXT, 1)
	else:
		FtlData.draw_ftl_text(self, 63, t, WPOS + Vector2(cx, 8), COL_TEXT, 1)


func _draw_buy(st: RunStore) -> void:
	FtlData.draw_ftl_text(self, 62, FtlData.tr_id("store_title_items"), WPOS + Vector2(18, 45), COL_TEXT)
	FtlData.draw_ftl_text(self, 62, FtlData.tr_id("store_title_repair"), WPOS + Vector2(18, 254), COL_TEXT)
	var hl := HudDraw.txt("store_current_hull")
	FtlData.draw_ftl_text(self, 59, hl, WPOS + Vector2(73, 419 if "\n" in hl else 427), COL_ON, 1)
	for half in 2:
		var si := run.store_page * 2 + half
		if si >= st.sections.size():
			continue
		var sec: Dictionary = st.sections[si]
		var head := FtlData.tr_id("store_title_" + ["weapons", "drones", "augments", "crew", "systems"][int(sec.type)])
		FtlData.draw_ftl_text(self, 62, head, WPOS + Vector2(205, 45 + 209 * half), COL_TEXT)
	# 3. Page tabs (only with > 2 sections): one image for the current page, the other half hoverable.
	if st.sections.size() > 2:
		var other := 1 - run.store_page
		var ps := "select2" if _hover == -11 - other else "on"
		_img("upgradeUI/Equipment/tabButtons/store_page%d_%s.png" % [run.store_page + 1, ps], WPOS + PAGE_POS)
		FtlData.draw_ftl_text(self, 62, FtlData.tr_id("store_tab_page1"), WPOS + PAGE_POS + Vector2(65, 7), COL_TEXT, 1)
		FtlData.draw_ftl_text(self, 62, FtlData.tr_id("store_tab_page2"), WPOS + PAGE_POS + Vector2(171, 7), COL_TEXT, 1)
	# 4. Section boxes, then the resources and the repair boxes.
	for half in 2:
		var si := run.store_page * 2 + half
		if si >= st.sections.size():
			continue
		var sec: Dictionary = st.sections[si]
		for b in 3:
			_draw_box(st, int(sec.type), half, b, si * 3 + b)
	for code in RES_Y:
		var r: Dictionary = st.resources[RES_IMG[code]]
		var p := WPOS + Vector2(18, RES_Y[code])
		var on := int(r.count) > 0
		_img("storeUI/store_items_%s_%s.png" % [RES_IMG[code], _state(code, on)], p)
		if on:
			var col := _text_col(code, on)
			FtlData.draw_ftl_text(self, 0, "%d" % int(r.count), p + Vector2(70, 14), col)
			FtlData.draw_ftl_text(self, 0, "%d" % int(r.price), p + Vector2(130, 14), col)
	var hurt := run.ship.hull < run.ship.max_hull
	for code in REPAIR_Y:
		var p := WPOS + Vector2(18, REPAIR_Y[code])
		_img("storeUI/store_repair_%s.png" % _state(code, hurt), p)
		var label := HudDraw.txt("repair_one_button" if code == RunState.BOX_REPAIR_ONE else "repair_all_button")
		var lh := FtlData.ftl_line_height(59) * label.split("\n").size()
		var lc := COL_OFF if not hurt else (COL_SELECT if _state(code, hurt) == "select2" else COL_ON)
		FtlData.draw_ftl_text(self, 59, label, p + Vector2(52, 21 - lh / 2.0), lc, 1)
		if hurt:
			var price := st.repair_cost if code == RunState.BOX_REPAIR_ONE else st.repair_all_price(run)
			FtlData.draw_ftl_text(self, 0, "%d" % price, p + Vector2(130, 16), _text_col(code, true))
		else:
			var mx := HudDraw.txt("repair_max")
			FtlData.draw_ftl_text(self, 59, mx, p + Vector2(133, 21 - FtlData.ftl_line_height(59) / 2.0), COL_OFF, 1)
	# 5. Hull value.
	FtlData.draw_ftl_text(self, 0, "%d" % run.ship.hull, WPOS + Vector2(143, 432), COL_ON)


func _draw_box(st: RunStore, ty: int, half: int, b: int, code: int) -> void:
	var o := st.offer(code / 3, code % 3)
	var r := box_rect(ty, half, b)
	var real := not o.is_empty() and int(o.count) >= 0 and String(o.name) != ""
	var active := real and st.active(o, run)
	var s := _state(code, active)
	if ty in ROW_KINDS:
		var img: String = {RunStore.WEAPONS: "weapons", RunStore.DRONES: "drones", RunStore.CREW: "crew"}[ty]
		_img("storeUI/store_buy_%s_%s.png" % [img, s], r.position)
	else:
		var img := "systems" if ty == RunStore.SYSTEMS else "weapons"
		if ty == RunStore.SYSTEMS and real and String(o.name) in RunTuning.section("store").subsystems:
			img = "subsystems"
		if not real or int(o.count) == 0:
			img = "weapons"  # empty slot / sold system: store_weapons_off.png
		_img("storeUI/store_%s_%s.png" % [img, s if real and int(o.count) > 0 else "off"], r.position)
	if not real or int(o.count) < 1:
		return
	var col := _text_col(code, active)
	if ty in ROW_KINDS:
		_draw_icon(o, r.position + Vector2(60, 34))
		FtlData.draw_ftl_text(self, 6, short_name(o), r.position + Vector2(59, 58), col, 1)
		FtlData.draw_ftl_text(self, 0, "%d" % int(o.price), r.position + Vector2(42, 86), col)
	else:
		if ty == RunStore.SYSTEMS:
			_img("icons/s_%s_green1.png" % o.name, r.position + Vector2(-13, -12))
		FtlData.draw_ftl_text(self, 14, title(o), r.position + Vector2(48, 2), col)
		FtlData.draw_ftl_text(self, 0, "%d" % int(o.price), r.position + Vector2(345, 14), col)


## Equipment box icon centred on `at` (= box + (60, 34)): weapon art (charged frame, rotated 90°), drone image or
## crew-like drone, crew portrait ×2 (+5 y except rock / crystal / mantis).
func _draw_icon(o: Dictionary, at: Vector2) -> void:
	match String(o.kind):
		"crew":
			var id: Dictionary = o.extra.get("ident", {})
			var race := String(o.name)
			var push := Vector2.ZERO if race in CREW_NO_PUSH else Vector2(0, 5)
			CrewPortrait.draw_icon(self, CrewPortrait.look(race, bool(id.get("male", true)), id.get("colors", [])),
				at + push, 2.0)
		"weapon":
			WeaponIcon.draw_weapon(self, String(o.name), at)
		"drone":
			WeaponIcon.draw_drone(self, String(o.name), at)


## GetNameShort: weapon / drone short title; crew = the box's crew name (race title only if unnamed).
static func short_name(o: Dictionary) -> String:
	match String(o.kind):
		"crew":
			var nm := String(o.extra.get("ident", {}).get("name", ""))
			return nm if nm != "" else race_title(String(o.name))
		"weapon", "drone":
			return FtlData.blueprint_short(String(o.name), String(o.kind))
	return title(o)


static func race_title(race: String) -> String:
	var t := FtlData.tr_id("crew_%s_title" % race)
	return t if t != "crew_%s_title" % race else race.capitalize()


static func title(o: Dictionary) -> String:
	if String(o.kind) == "crew":
		return race_title(String(o.name))
	return FtlData.blueprint_title(String(o.name), String(o.kind))


func _draw_sell() -> void:
	var items := RunStore.sellable(run)
	FtlData.draw_ftl_text(self, 62, "SELL (half price)", WPOS + Vector2(208, 42), COL_TEXT)
	if items.is_empty():
		FtlData.draw_ftl_text(self, 10, "Nothing to sell.", WPOS + Vector2(215, 80), COL_ON)
	for i in items.size():
		var it: Dictionary = items[i]
		var r := Rect2(WPOS + Vector2(203, 70 + 34 * i), Vector2(380, 30))
		var hot: bool = run.store_selected == 200 + i or (_hover == 200 + i and not profile.is_touch())
		draw_rect(r, Color8(60, 70, 72, 230) if hot else Color8(30, 36, 38, 230))
		draw_rect(r, COL_SELECT if hot else COL_ON, false, 1.0)
		FtlData.draw_ftl_text(self, 61, "%s  (%s)" % [FtlData.blueprint_title(String(it.name), String(it.kind)), it.where], r.position + Vector2(10, 8),
			COL_ON)
		FtlData.draw_ftl_text(self, 62, "+%d" % int(it.value), Vector2(r.end.x - 10, r.position.y + 6), COL_SELECT, 2)


## Outer rect of the info WindowFrame: W + (607, 74) (location W + (600, 0), frame (7, 7) at y + 67), 323 wide.
static func _info_rect(kind: String) -> Rect2:
	return Rect2(WPOS + Vector2(INFO_X + 7, 67 + 7), Vector2(INFO_W, INFO_H.get(kind, 160)))


## The box code whose info box is shown: the selected box (touch) or the hovered one (PC).
func info_code() -> int:
	return run.store_selected if run.store_selected >= 0 else (_hover if not profile.is_touch() else -1)


## Info box content (StoreBox::SetInfoBox → ItemInfoBox.content) of a box code with stock, {} for none (repair boxes
## and sold-out boxes set nothing). Systems: title + description (+ the free drone) [the exe's SetSystem level
## table is not drawn]; crew: the crew member's name (race title) and skills.
func info_content(code: int) -> Dictionary:
	var st := run.store()
	if st == null:
		return {}
	if RunState.RES_BOXES.has(code):
		var r: Dictionary = st.resources[RunState.RES_BOXES[code]]
		if int(r.count) <= 0:
			return {}
		return ItemInfoBox.content("item", String(RunState.RES_BOXES[code]), false, run.engine.ae)
	if code < 0 or code >= 12:
		return {}
	var o := st.offer(code / 3, code % 3)
	if o.is_empty() or int(o.count) <= 0 or String(o.name) == "":
		return {}
	var kind := String(o.kind)
	var has_sys := run.ship.sys("weapons" if kind == "weapon" else "drones") != null
	var ctx := {"context": "store", "owned": false, "sell_price": int(FtlData.item_info(kind, String(o.name)).get(
		"cost", 0)) / 2, "offer": o}
	var d := {}
	match kind:
		"crew":  # CrewStoreBox::SetInfoBox -> InfoBox::SetBlueprint(crew, 0, detailed): crew panel (InfoPanels)
			d = InfoPanels.crew_content(String(o.name), String(o.extra.get("ident", {}).get("name", "")),
				InfoPanels.skills_from_levels(o.extra.get("skills", {})), ctx)
		"system":  # SystemStoreBox::SetInfoBox -> InfoBox::SetSystem: the per-level table (InfoPanels)
			d = InfoPanels.system_content(String(o.name), int(UpgradeSession.system_info(String(o.name)).start),
				String(o.extra.get("free_drone", "")), ctx)
		_:
			d = ItemInfoBox.content(kind, String(o.name), has_sys, run.engine.ae, ctx)
	if d.is_empty():
		return d
	# Touch: an inactive box can be selected (ours), its reason goes in the warning line; PC shows it as the mouse
	# tooltip like the exe (`blocked_reason`).
	if profile.is_touch():
		var why := RunStore.can_hold(o, run)
		if why != "":
			d.warning = _reason_text(why)
	return d


## Info box at infoBox.location = W + (600, 0): ItemInfoBox (primary frame + TIP frame); crew adds the skills.
func _draw_info(st: RunStore) -> void:
	var code := info_code()
	var d := info_content(code)
	if d.is_empty():
		return
	var kind := String(d.kind)
	var loc := WPOS + Vector2(INFO_X, 0)
	if kind == "crew":
		InfoPanels.draw_crew(self, loc, d, true)
	elif kind == "system":
		var sid := String(d.name)
		InfoPanels.draw_system(self, loc, d, UpgradeSession.max_level(run.ship, sid),
			int(UpgradeSession.system_info(sid).start))
	else:
		ItemInfoBox.draw(self, loc, d, INFO_H.get(kind, 160))
	for r in _rects:
		if int(r[1]) == -23:
			var br: Rect2 = r[0]
			draw_rect(br, Color8(20, 30, 36, 240))
			draw_rect(br, COL_SELECT, false, 2.0)
			FtlData.draw_ftl_text(self, 62, "SELL", br.get_center() - Vector2(0, 10), COL_SELECT, 1)


## Draws a wrapped text block, returns its height.
func _block(font: int, t: String, p: Vector2, col: Color, wrap: int) -> int:
	if t == "":
		return 0
	var lines := FtlData.ftl_wrap(font, t, wrap)
	FtlData.draw_ftl_text(self, font, t, p, col, 0, wrap)
	return lines.size() * FtlData.ftl_line_height(font)


func _reason_text(key: String) -> String:
	if key == "scrap" or key == "not enough scrap":
		return "Not enough scrap."
	var t := FtlData.tr_id(key)
	return t if t != key else key.replace("_", " ")


func _draw_confirm(st: RunStore) -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.5))  # store drawn at (0.5, 0.5, 0.5) behind the dialog
	WindowFrame.draw(self, CONFIRM)
	var lines := FtlData.ftl_wrap(10, FtlData.tr_id(String(st.pending_confirm.text_id)), int(CONFIRM.size.x) - 30)
	var y := CONFIRM.position.y + 14
	for l in lines:
		FtlData.draw_ftl_text(self, 10, l, Vector2(CONFIRM.position.x + 15, y), COL_ON)
		y += 18
	for r in _rects:
		if int(r[1]) == -21 or int(r[1]) == -22:
			var br: Rect2 = r[0]
			draw_rect(br, Color8(20, 30, 36, 240))
			draw_rect(br, COL_SELECT if _hover == int(r[1]) else COL_ON, false, 2.0)
			FtlData.draw_ftl_text(self, 62, FtlData.tr_id("yes" if int(r[1]) == -21 else "no"), br.get_center() -
				Vector2(0, 10), COL_SELECT, 1)
