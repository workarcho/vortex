class_name HangarView
extends Control
## The hangar (ShipBuilder; rules/main_menu.md §2). Layers as ShipBuilder::OnRender: `customizeUI/custom_background
## .png`, the equipment box (0,478), the ship-select box (0,106), achievement box (−1,355), AE box (~975,384),
## frame titles; then the ship (ShipView child at (365 + horizontal, 30 + vertical)); then, in the `_over` child, the
## start box (top right), name box (6,8), equipment / crew / system boxes and every button. Positions from the
## ShipBuilder static initialiser; [inferred] marks what the exe computes from art / text sizes we approximate.
## Gestures go to the InputProfile (press on PC, release on touch, swipe over the ship on touch).

const COL_ON := Color8(235, 245, 229)  # COLOR_BUTTON_ON
const COL_SELECT := Color8(255, 230, 94)  # COLOR_BUTTON_SELECT (hover; selected difficulty / layout)
const COL_TEXT := Color8(25, 49, 51)  # COLOR_BUTTON_TEXT (button labels, frame titles)
const COL_OFF := Color8(110, 110, 110)  # inactive button [inferred]
const SHIP_AT := Vector2(365, 30)  # GL_Translate(horizontal_shift + 365, vertical_shift + 30)

# Frame titles (font 62, COLOR_BUTTON_TEXT)
const TITLES := [["hangar_frame_ship", Vector2(19, 117)], ["hangar_frame_layout", Vector2(19, 219)],
	["hangar_frame_crew", Vector2(19, 489)], ["equipment_frame_weapons", Vector2(388, 489)],
	["equipment_frame_drones", Vector2(388, 599)], ["equipment_frame_augments", Vector2(954, 489)]]
const CREW_BOXES := [Vector2(70, 519), Vector2(230, 519), Vector2(70, 612), Vector2(230, 612)]
const CUSTOMIZE_AT := Vector2(100, 542)  # SetCustomizeMode(Point(100, 542))
const WEAPON_Y := 514
const DRONE_Y := 624
const AUG_AT := Vector2(988, 529)  # + 60 per augment
const SYS_X := 360  # CreateSystemBoxes: x 360 + 38 i, y 425
const SYS_Y := 425

var title: TitleState
var profile: InputProfile
var ship_view: ShipView
var _over: Control
var _view_for: ShipState = null
var hover := ""
var buttons := {}  # name -> {rect, intent, label, font, state}
var renaming := -2  # −2 none, −1 ship name, ≥ 0 crew index (typing)
var rename_text := ""
var customizing := -1  # crew box in customize mode
var _press_name := ""
var _press_pos := Vector2.ZERO
var _press_on_ship := false
var ship_list: ShipListView  # LIST → ShipSelect overlay


func setup(t: TitleState, p: InputProfile) -> void:
	title = t
	profile = p
	position = Vector2.ZERO
	size = HudLayout.FRAME
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	_over = Control.new()
	_over.size = HudLayout.FRAME
	_over.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_over.draw.connect(_draw_over)
	add_child(_over)
	ship_list = ShipListView.new()
	ship_list.visible = false
	add_child(ship_list)
	ship_list.setup(t)
	ship_list.picked.connect(func(id, ty):
		title.switch_ship(id, ty)
		refresh())
	refresh()


## LIST: the ship list over the hangar, on the current ship's layout page.
func open_list() -> void:
	ship_list.open(title.ship_id, title.ship_type)


## Rebuilds the ship view when the hangar switched ships, and the button table.
func refresh() -> void:
	if title.preview != _view_for and title.preview != null:
		_view_for = title.preview
		if ship_view != null:
			ship_view.queue_free()
		ship_view = ShipView.new()  # a fresh view per ship (ShipView keeps per-ship animation state)
		add_child(ship_view)
		move_child(ship_view, 0)  # under `_over` (and the ship list)
		ship_view.setup(title.preview)
		customizing = -1
		renaming = -2
	if title.preview != null and ship_view != null:
		var lay: Dictionary = title.preview.layout
		ship_view.position = SHIP_AT + Vector2(lay.get("horizontal", 0), lay.get("vertical", 0))
		ship_view.hide_interior = not title.show_rooms
		# AE-only layout with AE disabled: ship tinted 0.5 (GL_SetColorTint) + advanced_warning, START off.
		ship_view.modulate = Color(0.5, 0.5, 0.5) if title.needs_ae() and not title.ae else Color.WHITE
	_build_buttons()
	queue_redraw()
	_over.queue_redraw()


func _process(_d: float) -> void:
	if title.preview != _view_for:
		refresh()
	if title.preview != null:
		# ShipBuilder::OnLoop -> ShipManager::OnLoop: the crew man their stations (typing animation).
		title.preview.tick_crew_only(GameClock.factor(_d) / GameClock.BASE)
	_hover_info()
	_over.queue_redraw()


# ------------------------------------------------------------------ hover info (ShipBuilder::MouseMove)

const INFO_LOC := Vector2(945, 30)  # ShipBuilder infoBoxLoc
var info := {}  # what the InfoBox shows this frame: {type: item|crew|system|text, d, loc, ...} or {}


func _tex_size(rel: String, fallback: Vector2) -> Vector2:
	var t := FtlData.texture("img/" + rel)
	return t.get_size() if t else fallback


## ShipBuilder::MouseMove: InfoBox::Clear, then the hovered equipment box (weapon / drone / augment / crew) sets the
## blueprint, a hovered system box SetSystem (box at x 1282 − its width), EASY / NORMAL / HARD and the AE buttons
## SetDescription(<x>_title, <x>_text); achievement icons set the tooltip (AchievementTracker::SetTooltip).
func _hover_info() -> void:
	info = {}
	var s := title.preview
	if s == null or ship_list.visible or not is_visible_in_tree():
		return
	var m := TooltipService.local_pointer(self)
	var ae := title.ae
	if s.systems.has("weapons"):
		var x := (4 - s.weapon_slots) * 58 + 435
		for i in s.weapon_slots:
			if i < s.weapons.size() and Rect2(x, WEAPON_Y, 109, 76).has_point(m):
				info = {"type": "item", "loc": INFO_LOC, "d": ItemInfoBox.content("weapon", String(s.weapons[i].bp.name),
					true, ae, {"context": "hangar"})}
			x += 117
	if s.systems.has("drones"):
		var x := (4 - s.drone_slots) * 58 + 435
		for i in s.drone_slots:
			if i < s.drones.size() and Rect2(x, DRONE_Y, 109, 76).has_point(m):
				info = {"type": "item", "loc": INFO_LOC, "d": ItemInfoBox.content("drone", String(s.drones[i].bp.name),
					true, ae, {"context": "hangar"})}
			x += 117
	var asz := _tex_size("upgradeUI/Equipment/box_augment_on.png", Vector2(234, 46))
	for i in mini(3, s.augments.size()):
		if Rect2(AUG_AT + Vector2(0, 60 * i), asz).has_point(m):
			info = {"type": "item", "loc": INFO_LOC, "d": ItemInfoBox.content("augment", String(s.augments[i]), true, ae,
				{"context": "hangar"})}
	var csz := _tex_size("upgradeUI/Equipment/box_crew_on.png", Vector2(100, 62))
	for i in mini(title.crew.size(), CREW_BOXES.size()):
		if customizing < 0 and Rect2(CREW_BOXES[i], Vector2(csz.x, 62)).has_point(m):
			var id: Dictionary = title.crew[i]
			info = {"type": "crew", "loc": INFO_LOC, "d": InfoPanels.crew_content(String(id.race), String(id.name),
				InfoPanels.skills_from_levels({}), {"context": "hangar"})}
	var x := SYS_X
	var ssz := _tex_size("customizeUI/box_system_on.png", Vector2(38, 100))
	for sid in SYSTEM_IDS:
		var st: SystemState = s.systems.get(sid)
		if st == null:
			continue
		if Rect2(Vector2(x + 13, SYS_Y - 45), ssz).has_point(m):
			var mx := UpgradeSession.max_level(s, sid)
			info = {"type": "system", "loc": Vector2(1282 - InfoPanels.system_width(sid, mx), INFO_LOC.y),
				"d": InfoPanels.system_content(sid, st.level, "", {"context": "hangar"}), "max": mx, "level": st.level}
		x += 38
	for k in ["diff0", "diff1", "diff2", "ae_on", "ae_off"]:
		if buttons.has(k) and (buttons[k].rect as Rect2).has_point(m):
			var base: String = {"diff0": "easy", "diff1": "normal", "diff2": "hard", "ae_on": "advanced_on",
				"ae_off": "advanced_off"}[k]
			var d := ItemInfoBox.finish({"kind": "text", "name": base, "title": TooltipText.t(base + "_title"),
				"description": TooltipText.t(base + "_text"), "stats": [], "price": "", "warning": "", "tip": "",
				"tip_warning": ""}, {"context": "hangar"})
			info = {"type": "item", "loc": INFO_LOC, "d": d}
	if info.has("d") and (info.d as Dictionary).is_empty():
		info = {}
	_achievement_tooltip(m)


var ach_hover := -1  # ShipBuilder selectedAch: index of the hovered ship achievement icon (-1 = none)


## Top-left corners of the ship achievement icons (ShipBuilder::SetupShipAchievements: (21 + pad·2/10, 404); 64 px
## icons +70 (+ pad·3/10); then x + 83 (+ pad·2/10) for the 32 px victory marker at y + 34 and the quest marker at
## y [exe]).
func achievement_positions(achs: Array) -> Array:
	var ach := FtlData.tr_id("hangar_achievements_title")
	var pad := maxi(0, (FtlData.ftl_text_width(13, ach) - 208) / 10) * 10
	var ap := Vector2(21 + pad * 2 / 10, 404)
	var out := []
	for i in achs.size():
		var p := ap + Vector2((70 + pad * 3 / 10) * i, 0)
		if i >= 3:
			p = Vector2(ap.x + 2 * (70 + pad * 3 / 10) + 83 + pad * 2 / 10, ap.y + (34 if i == 3 else 0))
		out.append(p)
	return out


## ShipBuilder::MouseMove: selectedAch = the icon strictly under the pointer, which gets
## AchievementTracker::SetTooltip: title = the name, body = the description (+ the "Unlocked on ..." line, or on the
## victory marker one "Achieved with Type X (difficulty)" line per layout won), shown at once (InstantTooltip).
## Every icon of the shown ship answers, earned or not (the hangar only shows unlocked ships). Touch: the same
## tooltip while the finger is held on the icon (vanilla mobile: ShipBuilder::OnTouch -> SetInfoBox).
func _achievement_tooltip(m: Vector2) -> void:
	var achs := MenuDraw.ship_achievements(title.ship_id)
	var pos := achievement_positions(achs)
	var hover := -1
	for i in achs.size():
		var dim := int(achs[i].get("dim", 64))
		var p: Vector2 = pos[i]
		if m.x > p.x and m.x < p.x + dim and m.y > p.y and m.y < p.y + dim:
			hover = i
			var t := achievement_text(String(achs[i].id), title.preview)
			if t[1] != "":
				TooltipService.request(t[1], {"title": t[0], "kind": &"achievement", "source": self,
					"instant": true, "ctx": {"id": achs[i].id}})
	if hover != ach_hover:
		ach_hover = hover
		queue_redraw()


## [title, body] of an achievement tooltip (rule `tooltip.achievement`; AchievementTracker::SetTooltip).
static func achievement_text(id: String, ship: ShipState) -> Array:
	var r: Variant = Hooks.rule(&"tooltip.achievement", func(aid: String, sh: ShipState) -> Array:
		var cls := ""
		if sh:
			var m := RegEx.create_from_string("<class\\s+id=\"([^\"]+)\"").search(
				FtlData.ship_blueprint_text(String(sh.blueprint.get("name", ""))))
			cls = FtlData.tr_id(m.get_string(1)) if m else ""
		return achievement_tooltip_text(aid, cls), id, ship)
	return r


## AchievementTracker::SetTooltip text from the player profile: [title, body]. Victory marker: victory_ach_title /
## victory_ach (\1 = ship class), then " \n\n" + one `achieved_with` line per layout won (\1 type_a / type_b /
## type_c, \2 easy / normal / hard); quest marker: quest_ach_title / quest_ach; the others: <id>_name / <id>_desc,
## then " \n\n" + ach_easy / ach_normal / ach_hard when earned and multiDifficulty.
static func achievement_tooltip_text(aid: String, cls: String) -> Array:
	var prof := PlayerProfile.current()
	if aid.ends_with("_VICTORY"):
		var body := TooltipText.f("victory_ach", cls)
		var sid := TitleState.SHIP_BLUEPRINTS.find(aid.trim_suffix("_VICTORY"))
		var lines := []
		for t in 3:
			var d := prof.ship_victory(sid, t) if sid >= 0 else -1
			if d >= 0:
				lines.append(TooltipText.f("achieved_with", TooltipText.t(["type_a", "type_b", "type_c"][t]),
					TooltipText.t(["easy", "normal", "hard"][clampi(d, 0, 2)])))
		if not lines.is_empty():
			body += " \n\n" + "\n".join(lines)
		return [TooltipText.f("victory_ach_title", cls), body]
	if aid.ends_with("_QUEST"):
		return [TooltipText.f("quest_ach_title", cls), TooltipText.f("quest_ach", cls)]
	var desc := TooltipText.t(aid + "_desc")
	if prof.has_achievement(aid) and bool(MenuDraw.achievement(aid).get("multi", false)):
		desc += " \n\n" + TooltipText.t(["ach_easy", "ach_normal", "ach_hard"][clampi(int(prof.achievements[aid]), 0, 2)])
	return [TooltipText.t(aid + "_name"), desc]


func _draw_info(ci: CanvasItem) -> void:
	if info.is_empty():
		return
	match String(info.type):
		"crew":
			InfoPanels.draw_crew(ci, info.loc, info.d, false)  # EquipmentBox::SetBlueprint(.., detailed = false)
		"system":
			InfoPanels.draw_system(ci, info.loc, info.d, int(info.max), int(info.level))
		_:
			ItemInfoBox.draw(ci, info.loc, info.d)


# ------------------------------------------------------------------ buttons

func _btn(nm: String, r: Rect2, intent: Dictionary, label: String, font := 62, state := "on") -> void:
	buttons[nm] = {"rect": r, "intent": intent, "label": label, "font": font, "state": state}


func _build_buttons() -> void:
	buttons.clear()
	var T := TitleState
	# Start box (top right): START (1082,28) 152×48 font 64; EASY / NORMAL / HARD 95×24 at x 977, y 14 / 40 / 66.
	_btn("start", Rect2(1082, 28, 152, 48), T.make(T.START), FtlData.tr_id("start_button"), 64,
		"on" if title.can_start() else "off")
	var diffs := ["easy_button", "normal_button", "hard_button"]
	for i in 3:
		_btn("diff%d" % i, Rect2(977, 14 + 26 * i, 95, 24), T.make(T.SET_DIFFICULTY, i), FtlData.tr_id(diffs[i]), 62,
			"selected" if title.difficulty == i else "on")
	# AE box: DISABLED / ENABLED (y 425), auto width, laid into the box (see ae_geometry).
	var g := ae_geometry()
	_btn("ae_off", g.off, T.make(T.SET_AE, 0), FtlData.tr_id("advanced_off_button"), 62,
		"selected" if not title.ae else "on")
	_btn("ae_on", g.on, T.make(T.SET_AE, 1), FtlData.tr_id("advanced_on_button"), 62,
		"selected" if title.ae else "on")
	# Name box: RENAME (14,16) 94×32.
	_btn("rename", Rect2(14, 16, 94, 32), {}, FtlData.tr_id("ship_rename_button"), 62)
	# Ship select box: LIST centred at x 95 (y 145), arrows 37 px left / 13 px right of it, RANDOM SHIP (y 178).
	var lw := FtlData.ftl_text_width(62, FtlData.tr_id("ship_list_button")) + 8
	var lx := 95 - lw / 2
	_btn("list", Rect2(lx, 145, lw, 28), {}, FtlData.tr_id("ship_list_button"), 62)
	_btn("left", Rect2(lx - 37, 145, 32, 28), T.make(T.PREV_SHIP), "", 0)
	_btn("right", Rect2(lx + lw + 5, 145, 32, 28), T.make(T.NEXT_SHIP), "", 0)
	var rw := FtlData.ftl_text_width(62, FtlData.tr_id("ship_random_button")) + 16
	_btn("random", Rect2(95 - rw / 2, 178, rw, 32), T.make(T.RANDOM_SHIP), FtlData.tr_id("ship_random_button"), 62)
	# Layout: A (32,248) B (77,248) C (122,248) 36×34 font 63; crystal / lanius: A, B shifted +22, no C.
	var shift := 0 if title.has_type_c() else 22
	for k in 3:
		if k == 2 and not title.has_type_c():
			continue
		var st := "selected" if title.ship_type == k else ("on" if title.type_available(k) else "off")
		_btn("type%d" % k, Rect2(32 + 45 * k + shift, 248, 36, 34), T.make(T.SET_TYPE, k),
			FtlData.tr_id("typebutton_" + "abc"[k]), 63, st)
	_btn("rooms", Rect2(20, 301, 151, 28), T.make(T.TOGGLE_ROOMS),
		FtlData.tr_id("ship_hiderooms_button" if title.show_rooms else "ship_showrooms_button"), 62)
	# Crew boxes: CUSTOMIZE (x + 4, y + 70) 92×12; customize panel RENAME / ACCEPT and look arrows.
	for i in mini(title.crew.size(), CREW_BOXES.size()):
		_btn("custom%d" % i, Rect2(CREW_BOXES[i] + Vector2(4, 70), Vector2(92, 12)), {},
			FtlData.tr_id("crewbox_customize"), 51, "selected" if customizing == i else "on")
	if customizing >= 0:
		var c := CUSTOMIZE_AT
		_btn("crew_rename", Rect2(c + Vector2(5, 93), Vector2(94, 24)), {}, FtlData.tr_id("crewbox_rename"), 62)
		_btn("crew_accept", Rect2(c + Vector2(106, 93), Vector2(94, 24)), {}, FtlData.tr_id("crewbox_accept"), 62)
		_btn("look_prev", Rect2(c + Vector2(10, 40), Vector2(32, 28)),
			T.make(T.CREW_LOOK, customizing, {"dir": -1}), "", 0)
		_btn("look_next", Rect2(c + Vector2(163, 40), Vector2(32, 28)),
			T.make(T.CREW_LOOK, customizing, {"dir": 1}), "", 0)
	if profile.is_touch():
		# ShipBuilder::backButton exists only in the touch build's OnTouch (position not in the PC exe) [inferred].
		_btn("back", Rect2(963, 112, 110, 32), T.make(T.HANGAR_BACK), "BACK", 62)


const AE_PAD := 18  # AE button width = text + 18 [inferred; matches screenshot 38]


## ShipBuilder::Open AE box: buttons auto-sized (text + AE_PAD) and widened (half each) until the title
## (font 13) + 34 fits; box = 24 | off − 18 | 43 | on − 18 | 24 px slices of box_advanced.png, right edge at
## 975 + 267; each button starts 9 px left of its slice; title centred over the box at y 400.
func ae_geometry() -> Dictionary:
	var offw := FtlData.ftl_text_width(62, FtlData.tr_id("advanced_off_button")) + AE_PAD
	var onw := FtlData.ftl_text_width(62, FtlData.tr_id("advanced_on_button")) + AE_PAD
	var total := offw + onw + 55
	var extra := maxi(0, FtlData.ftl_text_width(13, FtlData.tr_id("hangar_advanced_title")) + 34 - total)
	offw += extra / 2
	onw += extra - extra / 2
	total = offw + onw + 55
	var x0 := 975 + 267 - total
	return {"x": x0, "total": total, "offw": offw, "onw": onw,
		"off": Rect2(x0 + 24 - 9, 425, offw, 22), "on": Rect2(x0 + 24 + offw - 18 + 43 - 9, 425, onw, 22),
		"title_x": 1109 + (267 - total) / 2.0}


func button_at(p: Vector2) -> String:
	for nm in buttons:
		var r: Rect2 = buttons[nm].rect
		if p.x > r.position.x and p.x < r.end.x and p.y > r.position.y and p.y < r.end.y:
			return nm
	return ""


func ship_rect() -> Rect2:
	if title.preview == null:
		return Rect2()
	var b := title.preview.rooms_bounds()
	return Rect2(b.position + (ship_view.position if ship_view else SHIP_AT), b.size)


# ------------------------------------------------------------------ input

func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		var h := button_at(e.position) if not profile.is_touch() else ""
		if h != hover:
			if h != "" and buttons[h].state != "off" and buttons[h].state != "selected":
				FtlData.play("hoverBeep")
			hover = h
	elif e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed:
			press(e.position)
		else:
			release(e.position)
		accept_event()


func _unhandled_key_input(e: InputEvent) -> void:
	if not visible or ship_list.visible or not (e is InputEventKey) or not e.pressed:
		return
	if renaming != -2:
		_type_key(e)
		get_viewport().set_input_as_handled()
		return
	if profile.hangar_key(e.keycode):
		refresh()
		get_viewport().set_input_as_handled()


func press(p: Vector2) -> void:
	if renaming != -2:
		_finish_rename()
	_press_name = button_at(p)
	_press_pos = p
	_press_on_ship = _press_name == "" and ship_rect().has_point(p)
	if _press_name != "" and not profile.is_touch():
		_activate(_press_name)


func release(p: Vector2) -> void:
	var nm := button_at(p)
	if profile.is_touch():
		if nm != "" and nm == _press_name:
			_activate(nm)
		elif _press_on_ship and profile.hangar_swipe(p - _press_pos):
			refresh()
	_press_name = ""
	_press_on_ship = false


## A button gesture: hangar intents go through the profile; rename / customize are view-local editing states.
func _activate(nm: String) -> void:
	var b: Dictionary = buttons.get(nm, {})
	if b.is_empty() or b.state == "off":
		return
	match nm:
		"rename":
			_start_rename(-1)
		"crew_rename":
			_start_rename(customizing)
		"crew_accept":
			customizing = -1
		"list":
			open_list()
		_:
			if nm.begins_with("custom"):
				customizing = int(nm.trim_prefix("custom"))
			elif not b.intent.is_empty():
				if profile.is_touch():
					profile.title_release(b.intent)
				else:
					profile.title_press(b.intent)
	refresh()


func _start_rename(i: int) -> void:
	renaming = i
	rename_text = ""


func _type_key(e: InputEventKey) -> void:
	match e.keycode:
		KEY_ENTER, KEY_KP_ENTER, KEY_ESCAPE:  # "Hit ENTER or ESCAPE to confirm name."
			_finish_rename()
			return
		KEY_BACKSPACE:
			rename_text = rename_text.left(rename_text.length() - 1)
			return
	var limit := TitleState.SHIP_NAME_MAX if renaming == -1 else TitleState.CREW_NAME_MAX
	if e.unicode >= 32 and rename_text.length() < limit:
		rename_text += char(e.unicode)


## Typed text is committed as an intent (empty keeps the old name).
func _finish_rename() -> void:
	if renaming == -1:
		title.apply(TitleState.make(TitleState.RENAME_SHIP, -1, {"text": rename_text}))
	elif renaming >= 0:
		title.apply(TitleState.make(TitleState.RENAME_CREW, renaming, {"text": rename_text}))
	renaming = -2
	refresh()


# ------------------------------------------------------------------ drawing

func _img(ci: CanvasItem, rel: String, p: Vector2, col := Color.WHITE) -> Vector2:
	var t := FtlData.texture("img/" + rel)
	if t:
		ci.draw_texture(t, p, col)
		return t.get_size()
	return Vector2.ZERO


## TextButton (MenuDraw.text_button).
func _text_button(ci: CanvasItem, b: Dictionary, hot: bool) -> void:
	MenuDraw.text_button(ci, b, hot)


## Image button (`customizeUI/button_arrow_{off,on,select2}`; the right one mirrored in place).
func _arrow(ci: CanvasItem, b: Dictionary, hot: bool, mirror: bool) -> void:
	MenuDraw.image_button(ci, "customizeUI/button_arrow", b.rect, "off" if b.state == "off" else "on", hot, mirror)


func _draw() -> void:
	var bg := FtlData.texture("img/customizeUI/custom_background.png")
	if bg:
		draw_texture(bg, Vector2.ZERO)
	else:
		draw_rect(Rect2(Vector2.ZERO, HudLayout.FRAME), Color(0.2, 0.2, 0.2))
	_img(self, "customizeUI/box_shipequip.png", Vector2(0, 478))
	_img(self, "customizeUI/box_shipselect.png", Vector2(0, 106))
	# Achievement box: 120 px | 10 px slice repeated per 10 px of title beyond 208 | the rest (x −1, y 355).
	var ach := FtlData.tr_id("hangar_achievements_title")
	var pad := maxi(0, (FtlData.ftl_text_width(13, ach) - 208) / 10) * 10
	var tex := FtlData.texture("img/customizeUI/box_shipach.png")
	if tex:
		_slices(tex, Vector2(-1, 355), [[0, 120, 120], [120, 10, pad], [120, tex.get_width() - 120, tex.get_width() - 120]])
	FtlData.draw_ftl_text(self, 13, ach, Vector2(124 + pad / 2.0, 374), COL_ON, FtlFont.Align.CENTER)
	# ShipBuilder::OnRender: CAchievement::OnRender(pos, style, showNew = true) per icon (achievement_positions);
	# style 1 (yellow outline) on the hovered 64 px icon, else 0; the markers style 2 when hovered, else 3.
	var achs := MenuDraw.ship_achievements(title.ship_id)
	var apos := achievement_positions(achs)
	for i in achs.size():
		var style := (1 if ach_hover == i else 0) if i < 3 else (2 if ach_hover == i else 3)
		MenuDraw.draw_achievement(self, achs[i], apos[i], false, style, true)
	var g := ae_geometry()
	tex = FtlData.texture("img/customizeUI/box_advanced.png")
	if tex:
		var w := tex.get_width()
		_slices(tex, Vector2(g.x, 384), [[0, 24, 24], [24, 1, g.offw - 18], [115, 43, 43], [158, 1, g.onw - 18],
			[243, w - 243, w - 243]])
	FtlData.draw_ftl_text(self, 13, FtlData.tr_id("hangar_advanced_title"), Vector2(g.title_x, 400), COL_ON,
		FtlFont.Align.CENTER)
	for tt in TITLES:
		FtlData.draw_ftl_text(self, 62, FtlData.tr_id(tt[0]), tt[1], COL_TEXT)


## Horizontal slices of a box texture: each [src x, src width, drawn width] placed left to right from `at`.
func _slices(tex: Texture2D, at: Vector2, parts: Array) -> void:
	var x := at.x
	var h := tex.get_height()
	for p in parts:
		if int(p[2]) <= 0:
			continue
		draw_texture_rect_region(tex, Rect2(x, at.y, p[2], h), Rect2(p[0], 0, p[1], h))
		x += p[2]


func _draw_over() -> void:
	var ci := _over
	var start_box := FtlData.texture("img/customizeUI/box_start.png")
	if start_box:
		ci.draw_texture(start_box, Vector2(1249 - start_box.get_width(), 0))
	if title.needs_ae() and not title.ae:
		var w := FtlData.texture("img/customizeUI/advanced_warning.png")
		if w:
			ci.draw_texture(w, Vector2(630, 213) - w.get_size() / 2)  # centred on enableAdvancedLoc
	# Name box + ship name (TextInput font 24 centred at x 273, y 7).
	_img(ci, "customizeUI/box_shipname.png", Vector2(6, 8))
	var nm := title.ship_name
	if renaming == -1:
		nm = rename_text + ("_" if fmod(Time.get_ticks_msec() / 500.0, 2.0) < 1.0 else " ")
		FtlData.draw_ftl_text(ci, 12, FtlData.tr_id("rename"), Vector2(227, 65), COL_ON, FtlFont.Align.CENTER)
	FtlData.draw_ftl_text(ci, 24, nm, Vector2(273, 7), COL_SELECT if renaming == -1 else Color.WHITE,
		FtlFont.Align.CENTER)
	if title.preview != null:
		_draw_equipment(ci)
		_draw_crew(ci)
		_draw_systems(ci)
	for k in buttons:
		var b: Dictionary = buttons[k]
		if k.begins_with("custom"):
			_customize_button(ci, b, hover == k)
		elif k == "left" or k == "look_prev":
			_arrow(ci, b, hover == k, false)
		elif k == "right" or k == "look_next":
			_arrow(ci, b, hover == k, true)
		else:
			_text_button(ci, b, hover == k and b.state == "on")
	_draw_info(ci)


## CrewCustomizeBox CUSTOMIZE: `customizeUI/box_crewcustom_{on,selected}.png` (100×24 frame) around the 92×12
## light plate with a dark rim, label font 51 in COLOR_BUTTON_TEXT (yellow when hovered / customizing).
func _customize_button(ci: CanvasItem, b: Dictionary, hot: bool) -> void:
	var r: Rect2 = b.rect
	var st := "selected" if hot or b.state == "selected" else "on"
	MenuDraw.img(ci, "customizeUI/box_crewcustom_%s.png" % st, r.position - Vector2(4, 6))
	ci.draw_rect(r, MenuDraw.COL_SELECT if st == "selected" else MenuDraw.COL_ON)
	ci.draw_rect(r.grow(-1), MenuDraw.COL_TEXT, false, 1.0)
	FtlData.draw_ftl_text(ci, 51, String(b.label), Vector2(r.get_center().x, r.position.y + 2), MenuDraw.COL_TEXT,
		FtlFont.Align.CENTER)


func _draw_equipment(ci: CanvasItem) -> void:
	var s := title.preview
	if not s.systems.has("weapons"):
		FtlData.draw_ftl_text(ci, 63, FtlData.tr_id("equipment_no_system"), Vector2(662, 539), COL_ON,
			FtlFont.Align.CENTER)
	else:
		var x := (4 - s.weapon_slots) * 58 + 435
		for i in s.weapon_slots:
			var w: WeaponState = s.weapons[i] if i < s.weapons.size() else null
			_img(ci, "upgradeUI/Equipment/box_weapons_%s.png" % ("on" if w else "off"), Vector2(x, WEAPON_Y))
			if w:
				_item_label(ci, FtlData.blueprint_short(String(w.bp.get("name", "")), "weapon"), Rect2(x, WEAPON_Y, 109, 76))
				_weapon_art(ci, w, Vector2(x, WEAPON_Y) + EquipmentView.WEAPON_ICON_AT)
			x += 117
	if not s.systems.has("drones"):
		FtlData.draw_ftl_text(ci, 63, FtlData.tr_id("equipment_no_system"), Vector2(662, 649), COL_ON,
			FtlFont.Align.CENTER)
	else:
		var x := (4 - s.drone_slots) * 58 + 435
		for i in s.drone_slots:
			var d: Drone = s.drones[i] if i < s.drones.size() else null
			_img(ci, "upgradeUI/Equipment/box_drones_%s.png" % ("on" if d else "off"), Vector2(x, DRONE_Y))
			if d:
				WeaponIcon.draw_drone(ci, String(d.bp.get("name", "")), Vector2(x, DRONE_Y) + EquipmentView.DRONE_ICON_AT)
				_item_label(ci, FtlData.blueprint_short(String(d.bp.get("name", "")), "drone"), Rect2(x, DRONE_Y, 109, 76))
			x += 117
	for i in 3:
		var p := AUG_AT + Vector2(0, 60 * i)
		var has := i < s.augments.size()
		_img(ci, "upgradeUI/Equipment/box_augment_%s.png" % ("on" if has else "off"), p)
		if has:
			EquipmentView.augment_label(ci, FtlData.blueprint_title(String(s.augments[i]), "augment"), p)


func _item_label(ci: CanvasItem, text: String, r: Rect2) -> void:
	EquipmentView.item_label(ci, text, r.position)  # ShipBuilder's boxes are EquipmentBoxes (RenderLabels)


func _weapon_art(ci: CanvasItem, w: WeaponState, centre: Vector2) -> void:
	var sheet: Dictionary = w.anim.get("sheet", {}) if w.anim is Dictionary else {}
	if not sheet.has("texture") or (sheet.get("frames", []) as Array).is_empty():
		return
	var fr: Array = sheet.frames
	var src: Rect2 = fr[clampi(int(w.anim.get("charged_frame", 0)), 0, fr.size() - 1)]  # charged look [screenshot 38]
	WeaponIcon.draw(ci, sheet.texture, src, centre)  # rotate 90° + mirror (weapon_icon.gd)


func _draw_crew(ci: CanvasItem) -> void:
	for i in CREW_BOXES.size():
		var p: Vector2 = CREW_BOXES[i]
		var has := i < title.crew.size()
		_img(ci, "upgradeUI/Equipment/box_crew_%s.png" % ("on" if has else "off"), p)
		if not has:
			continue
		var id: Dictionary = title.crew[i]
		var lk := CrewPortrait.look(String(id.race), bool(id.male), id.colors)
		CrewPortrait.draw_icon(ci, lk, p + Vector2(50, 23), 2.0)  # CrewEquipBox portrait ×2 [screenshot 38]
		var nm := CrewIdentity.shorten(String(id.name))
		if renaming == i:
			nm = rename_text + ("_" if fmod(Time.get_ticks_msec() / 500.0, 2.0) < 1.0 else " ")
		FtlData.draw_ftl_text(ci, 6, nm, p + Vector2(50, 49), COL_SELECT if renaming == i else Color.WHITE,
			FtlFont.Align.CENTER)
	if customizing >= 0 and customizing < title.crew.size():
		var c := CUSTOMIZE_AT
		_img(ci, "customizeUI/box_crew_details.png", c)
		var id: Dictionary = title.crew[customizing]
		# SetCustomizeMode: icon ×3 at customizeLocation + (105, 37) [exe]
		CrewPortrait.draw_icon(ci, CrewPortrait.look(String(id.race), bool(id.male), id.colors), c + Vector2(105, 37), 3.0)
		var nm := String(id.name) if renaming != customizing else rename_text + "_"
		FtlData.draw_ftl_text(ci, 10, nm, c + Vector2(102, 8), Color.WHITE, FtlFont.Align.CENTER)


## SystemCustomBox: `customizeUI/box_system_on.png` at (x + 13, 380), the system icon and its level bars
## [inferred inner placement].
func _draw_systems(ci: CanvasItem) -> void:
	var x := SYS_X
	for id in SYSTEM_IDS:
		var s: SystemState = title.preview.systems.get(id)
		if s == null:
			continue
		_img(ci, "customizeUI/box_system_on.png", Vector2(x + 13, SYS_Y - 45))
		var icon := FtlData.texture("img/icons/s_%s_green1.png" % id)
		if icon:
			ci.draw_texture(icon, Vector2(x + 32, SYS_Y + 30) - icon.get_size() / 2)
		for k in s.level:
			ci.draw_rect(Rect2(x + 22, SYS_Y + 8 - 8 * k, 20, 6), Color8(100, 255, 100))
		x += 38


## System ids 0..15 (CreateSystemBoxes walks them in this order, skipping systems the ship lacks).
const SYSTEM_IDS := ["shields", "engines", "oxygen", "weapons", "drones", "medbay", "pilot", "sensors", "doors",
	"teleporter", "cloaking", "artillery", "battery", "clonebay", "mind", "hacking"]
