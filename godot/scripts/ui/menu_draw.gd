class_name MenuDraw
extends RefCounted
## Shared drawing for the menu screens (rules/main_menu.md §3–§6): FTL TextButtons, image buttons, horizontal
## box slices and achievement icons (CAchievement::OnRender), plus the achievement list of achievements.xml.
## Static helpers only; every screen keeps its own button table {name: {rect, label, font, state, ...}}.

const COL_ON := Color8(235, 245, 229)  # COLOR_BUTTON_ON
const COL_SELECT := Color8(255, 230, 94)  # COLOR_BUTTON_SELECT (hover; rendered-selected)
const COL_TEXT := Color8(25, 49, 51)  # COLOR_BUTTON_TEXT
const COL_OFF := Color8(110, 110, 110)  # inactive TextButton [inferred]
const COL_OUTLINE := Color(0.784, 0.784, 0.784)  # CAchievement outline, style 0
## Ship ids (TitleState.SHIP_BLUEPRINTS order) whose ship list entry has the quest "!" marker [screenshot 39].
const QUEST_SHIPS := [1, 2, 4, 5, 6, 7, 8]


## TextButton::OnRender: chamfered plate (light; yellow when hovered or rendered selected; grey when inactive)
## with a dark rim, label centred (y = centre − lineHeight / 2) in COLOR_BUTTON_TEXT.
static func text_button(ci: CanvasItem, b: Dictionary, hot: bool) -> void:
	var r: Rect2 = b.rect
	var st := String(b.get("state", "on"))
	var fill := COL_ON
	if st == "off":
		fill = COL_OFF
	elif hot or st == "selected":
		fill = COL_SELECT
	fill = b.get("fill", fill)  # per-button colours (SetActiveColor / SetSelectedColor)
	var c := 4.0
	ci.draw_colored_polygon(_chamfer(r, c), COL_TEXT)
	ci.draw_colored_polygon(_chamfer(r.grow(-2), c - 1), fill)
	var f := int(b.get("font", 62))
	var label := String(b.get("label", ""))
	var lines := label.count("\n") + 1
	var lh := int(b.get("line_h", FtlData.ftl_line_height(f)))  # TextButton::lineHeight
	var y := r.position.y + r.size.y / 2.0 - lines * lh / 2.0 + float(b.get("y_off", 1))
	for line in label.split("\n"):
		FtlData.draw_ftl_text(ci, f, line, Vector2(r.get_center().x, y), COL_TEXT, FtlFont.Align.CENTER)
		y += lh


static func _chamfer(r: Rect2, c: float) -> PackedVector2Array:
	return PackedVector2Array([r.position + Vector2(c, 0), Vector2(r.end.x - c, r.position.y),
		Vector2(r.end.x, r.position.y + c), r.end - Vector2(0, c), r.end - Vector2(c, 0),
		Vector2(r.position.x + c, r.end.y), Vector2(r.position.x, r.end.y - c), r.position + Vector2(0, c)])


## Button::OnRender for `<base>_{off,on,select2}.png` images (off = inactive, select2 = hovered / selected).
static func image_button(ci: CanvasItem, base: String, r: Rect2, state: String, hot: bool, mirror := false) -> void:
	var st := "off" if state == "off" else ("select2" if hot or state == "selected" else "on")
	var t := FtlData.texture("img/%s_%s.png" % [base, st])
	if t == null:
		return
	var sz := t.get_size()
	if mirror:
		ci.draw_set_transform(Vector2(r.position.x + sz.x, r.position.y), 0.0, Vector2(-1, 1))
		ci.draw_texture(t, Vector2.ZERO)
		ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	else:
		ci.draw_texture(t, r.position)


## Draws `img/<rel>` at `p`; returns its size (zero when missing).
static func img(ci: CanvasItem, rel: String, p: Vector2, col := Color.WHITE) -> Vector2:
	var t := FtlData.texture("img/" + rel)
	if t:
		ci.draw_texture(t, p, col)
		return t.get_size()
	return Vector2.ZERO


## Horizontal slices of a texture: each [src x, src width, drawn width] placed left to right from `at`.
static func slices(ci: CanvasItem, tex: Texture2D, at: Vector2, parts: Array) -> void:
	var x := at.x
	var h := tex.get_height()
	for p in parts:
		if int(p[2]) <= 0:
			continue
		ci.draw_texture_rect_region(tex, Rect2(x, at.y, p[2], h), Rect2(p[0], 0, p[1], h))
		x += p[2]


## SlideBar::OnRender: box filled black α 0.5, white 2 px outline, then the marker (white; COLOR_YELLOW_PLAIN
## while hovered / dragged). `marker` is the marker rect (SlideBar keeps it 5 px above the box, 15×30).
static func slide_bar(ci: CanvasItem, box: Rect2, marker: Rect2, hot: bool) -> void:
	ci.draw_rect(box, Color(0, 0, 0, 0.5))
	ci.draw_rect(box.grow(-1), Color.WHITE, false, 2.0)
	ci.draw_rect(marker, COL_SELECT if hot else Color.WHITE)


## SlideBar marker for value v in 0..1: x between box.x + 5 and box.end − 5 − 15 (SlideBar::SetPosition).
static func slide_marker(box: Rect2, v: float) -> Rect2:
	var lo := box.position.x + 5
	var hi := box.end.x - 5 - 15
	return Rect2(lo + (hi - lo) * clampf(v, 0.0, 1.0), box.position.y - 5, 15, 30)


## SlideBar pointer → value in 0..1 (the marker centre follows the pointer).
static func slide_value(box: Rect2, x: float) -> float:
	var lo := box.position.x + 5 + 7.5
	var hi := box.end.x - 5 - 7.5
	return clampf((x - lo) / (hi - lo), 0.0, 1.0)


static var _panel_box: StyleBoxTexture


## One frame of the options window look (`optionsUI_new.png`, for frames of any size): cyan outer glow, the
## COLOR_BUTTON_ON band with a 24 px title strip above the panel (title font 62 COLOR_BUTTON_TEXT at
## panel + (8, −23)), and the patterned translucent panel (9-slice of the AUDIO panel of optionsUI_new.png,
## 8 px chamfered corners, tiled centre). Geometry measured on optionsUI_new.png / screenshot 36.
static func options_frame(ci: CanvasItem, panel: Rect2, title: String) -> void:
	options_band(ci, panel.grow_individual(4, 24, 4, 4))
	if _panel_box == null:
		var t := FtlData.texture("img/optionsUI_new.png")
		if t:
			_panel_box = StyleBoxTexture.new()
			_panel_box.texture = t
			_panel_box.region_rect = Rect2(181, 315, 388, 121)
			_panel_box.set_texture_margin_all(10)
			_panel_box.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT
			_panel_box.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT
	if _panel_box:
		ci.draw_style_box(_panel_box, panel)
	else:
		ci.draw_colored_polygon(_chamfer(panel, 6.0), Color8(133, 116, 116, 224))
	if title != "":
		FtlData.draw_ftl_text(ci, 62, title, panel.position + Vector2(8, -23), COL_TEXT)


## The outer part of `options_frame` alone: the cyan glow and the chamfered COLOR_BUTTON_ON band `band` (also a
## frame collapsed to its title strip).
static func options_band(ci: CanvasItem, band: Rect2) -> void:
	for i in range(10, 0, -2):  # glow: #79f2fd, α 0.23 at the band edge fading to 0 over 10 px
		ci.draw_colored_polygon(_chamfer(band.grow(i), 8.0 + i * 0.6), Color8(121, 242, 253, int(6 + (10 - i) * 3)))
	ci.draw_colored_polygon(_chamfer(band, 8.0), COL_ON)


## The ControlsScreen tab (`box_options_configure_tab.png`, 91×63): left 39 px at (123, 70), the 1 px column 39
## stretched to text width − 16 at x 162, the right 51 px at x text width + 146; title font 63 COLOR_BUTTON_TEXT at
## (154, 81) [ControlsScreen::OnRender].
static func controls_tab(ci: CanvasItem, title: String) -> void:
	var t := FtlData.texture("img/box_options_configure_tab.png")
	var tw := FtlData.ftl_text_width(63, title)
	if t:
		var h := t.get_height()
		ci.draw_texture_rect_region(t, Rect2(123, 70, 39, h), Rect2(0, 0, 39, h))
		ci.draw_texture_rect_region(t, Rect2(162, 70, maxi(tw - 16, 0), h), Rect2(39, 0, 1, h))
		ci.draw_texture_rect_region(t, Rect2(146 + tw, 70, 51, h), Rect2(40, 0, 51, h))
	FtlData.draw_ftl_text(ci, 63, title, Vector2(154, 81), COL_TEXT)


## Hit test "strictly inside" (GenericButton::MouseMove) over a button table; returns the name or "".
static func button_at(buttons: Dictionary, p: Vector2) -> String:
	for nm in buttons:
		var r: Rect2 = buttons[nm].rect
		if p.x > r.position.x and p.x < r.end.x and p.y > r.position.y and p.y < r.end.y:
			return nm
	return ""


# ------------------------------------------------------------------ achievements

static var _ach: Array = []  # [{id, img, ship, multi}] in achievements.xml order


## achievements.xml entries (AchievementTracker::LoadAchievementDescriptions).
static func achievements() -> Array:
	if _ach.is_empty():
		var src := FtlData.strip_comments(FtlData.text("data/achievements.xml"))
		var re := RegEx.create_from_string("<achievement\\s+id=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</achievement>")
		for m in re.search_all(src):
			var body := m.get_string(2)
			_ach.append({"id": m.get_string(1), "img": FtlData.tag_value(body, "img").strip_edges(),
				"ship": FtlData.tag_value(body, "ship").strip_edges(),
				"multi": FtlData.tag_value(body, "multiDifficulty").strip_edges() == "1"})
	return _ach


static func achievement(id: String) -> Dictionary:
	for a in achievements():
		if a.id == id:
			return a
	return {}


## AchievementTracker::GetShipAchievements: the three ship achievements of a ship (layout A blueprint), then the
## victory marker and, for ships with an unlock quest, the quest marker (32 px, `S_V` / `S_Q`).
static func ship_achievements(ship_id: int) -> Array:
	var bp: String = TitleState.SHIP_BLUEPRINTS[ship_id]
	var prof := PlayerProfile.current()
	var out := []
	for a in achievements():
		if a.ship == bp:
			out.append({"img": a.img, "dim": 64, "id": a.id, "unlocked": prof.has_achievement(String(a.id)),
				"mini": "S_%d" % mini(out.size() + 1, 3)})
	var won := prof.ship_victory(ship_id) >= 0  # PlayerProfile: victory marker / quest marker earned
	var dots := []  # CAchievement shipDifficulties: a victory per layout (3 dots, 2 for the crystal / lanius)
	for t in (2 if ship_id == PlayerProfile.CRYSTAL or ship_id == PlayerProfile.LANIUS else 3):
		dots.append(prof.ship_victory(ship_id, t) >= 0)
	out.append({"img": "achievements/S_V_%s.png" % ("on" if won else "off"), "dim": 32, "id": bp + "_VICTORY",
		"unlocked": won, "dots": dots, "mini": "S_V"})
	if ship_id in QUEST_SHIPS:
		var q := prof.quests.has(ship_id)
		out.append({"img": "achievements/S_Q_%s.png" % ("on" if q else "off"), "dim": 32, "id": bp + "_QUEST",
			"unlocked": q, "mini": "S_Q"})
	return out


## CAchievement::OnRender(pos, style, showNew). Styles 0 / 1: the icon; when locked (PlayerProfile: `a.unlocked`
## false) a dark overlay and `customizeUI/box_lock_on.png` at (dim/2 − 8, dim/2 − 11); styles 2 / 3: the mini icon
## (32 px victory / quest markers: their `_on` / `_off` image, no lock) [screenshot 38]. `show_new` and an
## achievement earned since the last new game (PlayerProfile.fresh): "New!" (`new_achievement`, font 12, COLOR_YELLOW)
## centred at (dim/2, 47), 30 px higher on a 32 px marker. An earned victory marker gets its layout dots
## (`S_V_dot_on` / `_off`, one per layout, 10 px apart from (1, 24); (6, 24) for two layouts). Outline: style 0 grey
## 0.78 and style 1 COLOR_BUTTON_SELECT on 64 px icons; style 2 a COLOR_BUTTON_SELECT outline on a 32 px marker
## (hovered in the hangar); style 3 none.
static func draw_achievement(ci: CanvasItem, a: Dictionary, p: Vector2, unlocked := false, style := 0,
		show_new := false) -> void:
	unlocked = unlocked or bool(a.get("unlocked", false))
	var dim := int(a.get("dim", 64))
	var t := FtlData.texture("img/" + String(a.img))
	if t:
		ci.draw_texture_rect(t, Rect2(p, Vector2(dim, dim)), false)
	if dim != 32 and not unlocked:
		ci.draw_rect(Rect2(p, Vector2(dim, dim)), Color(0, 0, 0, 0.72))
		img(ci, "customizeUI/box_lock_on.png", p + Vector2(dim / 2 - 8, dim / 2 - 11))
	if show_new and PlayerProfile.current().fresh.has(String(a.get("id", ""))):
		FtlData.draw_ftl_text(ci, 12, FtlData.tr_id("new_achievement"),
			p + Vector2(dim / 2, 47 - (30 if dim == 32 else 0)), FtlColors.YELLOW, FtlFont.Align.CENTER)
	var dots: Array = a.get("dots", [])
	if unlocked and not dots.is_empty():
		var x := 1.0 if dots.size() > 2 else 6.0
		for won in dots:
			img(ci, "achievements/S_V_dot_%s.png" % ("on" if won else "off"), p + Vector2(x, 24))
			x += 10.0
	if dim == 32:
		if style == 2:
			ci.draw_rect(Rect2(p + Vector2(1, 1), Vector2(dim - 2, dim - 2)), COL_SELECT, false, 2.0)
		return
	if style <= 1:
		var oc := COL_OUTLINE if style == 0 else COL_SELECT
		ci.draw_rect(Rect2(p + Vector2(1, 1), Vector2(dim - 2, dim - 2)), oc, false, 2.0)


## Ship list mini markers (`achievements/S_1..3`, `S_V`, `S_Q`; `_on` = earned in the PlayerProfile), as image
## names with their suffix ("S_1_on").
static func mini_markers(ship_id: int) -> Array:
	var out := []
	for a in ship_achievements(ship_id).slice(0, 5):
		out.append("%s_%s" % [a.mini, "on" if a.get("unlocked", false) else "off"])
	return out


## CAchievement::OnRender with style 2 / 3 (the ship list's ShipButton): the 32 px mini icon (`miniIcon` /
## `miniIconLocked` = `achievements/<mini>_on|off.png`), the victory dots of an earned `_VICTORY` (drawn for every
## style), and with style 2 the COLOR_BUTTON_SELECT mini outline. No "New!" (ShipButton passes showNew false).
static func draw_mini(ci: CanvasItem, a: Dictionary, p: Vector2, hot: bool) -> void:
	var m := a.duplicate()
	m.img = "achievements/%s_%s.png" % [a.get("mini", "S_1"), "on" if a.get("unlocked", false) else "off"]
	m.dim = 32
	draw_achievement(ci, m, p, false, 2 if hot else 3, false)


## The hover half of the achievement screens' MouseMove (ShipBuilder / ShipSelect / ScoreKeeper / MenuScreen):
## every entry of `achs` whose rect (in `ci`'s local coordinates) strictly contains `m` gets
## AchievementTracker::SetTooltip (title + body, InstantTooltip; the last hit wins, as in the exe loops). `bp` = the
## ship blueprint whose class fills the victory / quest marker texts. Returns the hovered index (-1 = none).
static func achievement_hover(ci: CanvasItem, achs: Array, rects: Array, m: Vector2, bp := "") -> int:
	var hit := -1
	for i in mini(achs.size(), rects.size()):
		var r: Rect2 = rects[i]
		if m.x > r.position.x and m.x < r.end.x and m.y > r.position.y and m.y < r.end.y:
			hit = i
			var t := HangarView.achievement_text(String(achs[i].id), null, bp)
			if t[1] != "":
				TooltipService.request(t[1], {"title": t[0], "kind": &"achievement", "source": ci,
					"instant": true, "ctx": {"id": achs[i].id}})
	return hit
