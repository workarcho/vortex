class_name InfoPanels
extends RefCounted
## The InfoBox variants that are not blueprint text boxes (rules/tooltips.md §6b, "Implementation notes"):
## - crew panel (`InfoBox::SetBlueprint(CrewBlueprint)` + OnRender crew branch): store hire box, hangar crew boxes,
##   crew manifest. Primary frame with "Name (Race)" + race description + power bullets, and with `detailed` the
##   Crew Skills frame (six RenderSkill cells with the infobox skill texts).
## - system panel (`InfoBox::SetSystem` + OnRender system branch): store system boxes, hangar system boxes, upgrade
##   screen. Title / warning / description frame and the per-level table (details_base_A/B/C art, eight rows, cost
##   per level, level description, power bars with the upgrade preview).
## Both go through the `infobox_content` filter (kind "crew" / "system").

const CREW_DESC := Vector2(305, 182)
const SYS_ROW_ON := Color8(127, 104, 107)  # detailsBarOn
const SYS_ROW_OFF := Color8(53, 43, 45)  # detailsBarOff
const UPGRADE_COL := Color8(255, 255, 100)
const WARN_COL := Color8(255, 120, 120)


static func _h(font: int, t: String, wrap: int) -> int:
	if t == "":
		return 0
	return FtlData.ftl_wrap(font, t, wrap).size() * FtlData.ftl_line_height(font)


# ---------------------------------------------------------------- crew

## <crewBlueprint><powerList><power id=.../> texts of a race.
static func crew_powers(race: String) -> Array:
	var out := []
	for file in ["data/blueprints.xml", "data/dlcBlueprints.xml", "data/dlcBlueprintsOverwrite.xml"]:
		var re := RegEx.create_from_string("<crewBlueprint\\s+name=\"" + race + "\"[^>]*>([\\s\\S]*?)</crewBlueprint>")
		var m := re.search(FtlData.strip_comments(FtlData.text(file)))
		if m == null:
			continue
		out = []
		for pm in RegEx.create_from_string("<power\\s+id=\"([^\"]+)\"").search_all(m.get_string(1)):
			out.append(FtlData.tr_id(pm.get_string(1)).replace("\\n", "\n"))
	return out


## Crew panel content: {kind "crew", name (race), title, description, stats (power bullets), skills: Array of
## Vector2i(xp, max) per skill (pilot, engines, shields, weapons, repair, combat)}.
static func crew_content(race: String, crew_name: String, skills: Array, ctx := {}) -> Dictionary:
	var info := FtlData.item_info("crew", race)
	var rt := FtlData.blueprint_title(race, "crew")
	var d := {"kind": "crew", "name": race, "title": "%s (%s)" % [crew_name, rt] if crew_name != "" else rt,
		"description": String(info.get("desc", "")), "stats": [], "price": "", "warning": "", "tip": "",
		"tip_warning": "", "skills": skills}
	for p in crew_powers(race):
		d.stats.append(TooltipText.f("bullet", p))
	var f: Variant = Hooks.filter(&"infobox_content", d, "crew", race, ctx)
	if Hooks.is_cancel(f):
		return {}
	d = f
	# Race description, a blank line, one bullet line per power [layout matched to screenshot 72].
	d["desc"] = String(d.description) + ((" \n\n" + "\n".join(PackedStringArray(d.stats))) if not (d.stats as Array)
		.is_empty() else "")
	return d


## Skill progress pairs of a live crew member.
static func crew_skills(c: CrewMember) -> Array:
	var out := []
	for sk in CrewMember.SKILLS:
		out.append(Vector2i(int(c.skills.get(sk, 0)), c.skill_cap(sk)))
	return out


## Skill progress pairs from 0..2 skill levels (store / hangar crew: level n = n halves of the maximum).
static func skills_from_levels(levels: Dictionary) -> Array:
	var out := []
	for sk in CrewMember.SKILLS:
		var mx := int(CrewMember.SKILL_CAPS.get(sk, 2))
		out.append(Vector2i(mx / 2 * clampi(int(levels.get(sk, 0)), 0, 2), mx))
	return out


## InfoBox::OnRender, crew: `loc` = InfoBox location. Detailed boxes are drawn 40 px higher. Returns the bottom y.
static func draw_crew(ci: CanvasItem, loc: Vector2, d: Dictionary, detailed := true, y_shift := 0) -> float:
	if d.is_empty():
		return loc.y
	var top := loc.y - 40 if detailed else loc.y
	var x := loc.x
	var dy := maxi(int(CREW_DESC.y), _h(10, String(d.desc), int(CREW_DESC.x)) + 63)
	WindowFrame.draw(ci, Rect2(x + 7, top + 67 + 7, 323, dy - 14))
	var y := top + 67 + 13
	FtlData.draw_ftl_text(ci, 16, String(d.title), Vector2(x + 18, y), Color.WHITE, 0, int(CREW_DESC.x))
	y += _h(16, String(d.title), int(CREW_DESC.x)) + 15
	FtlData.draw_ftl_text(ci, 10, String(d.desc), Vector2(x + 18, y), Color.WHITE, 0, int(CREW_DESC.x))
	var bottom := top + 67 + dy
	if not detailed:
		return bottom
	var y2 := top + y_shift + 77 + dy
	WindowFrame.draw(ci, Rect2(x + 7, y2 + 7, 323, 242))
	FtlData.draw_ftl_text(ci, 14, FtlData.tr_id("crew_skills"), Vector2(x + 35, y2 + 15), Color.WHITE)
	var skills: Array = d.get("skills", [])
	for s in mini(skills.size(), 6):
		var p: Vector2i = skills[s]
		var cx := x + 16 + 155 * (s & 1)
		var cy := y2 + 53 + 66 * (s >> 1)
		var r := clampf(float(p.x) / maxf(p.y, 1), 0.0, 1.0)
		CrewList.render_skill_ratio(ci, r, s, Vector2(cx, cy), 110, 9)
		var lvl := 3 if p.x == p.y else (2 if p.x >= p.y / 2 else 1)
		var t := TooltipText.skill_tooltip(s, lvl, p, true)
		var ly := cy + 20
		for line in FtlData.ftl_wrap(9, t, 140):
			FtlData.draw_ftl_text(ci, 9, line, Vector2(cx + 85, ly), Color.WHITE, 1)
			ly += FtlData.ftl_line_height(9)
	return y2 + 7 + 242


# ---------------------------------------------------------------- systems

## InfoBox::CalcCenterCountForSystem: 10 px centre tiles needed for the widest level description.
static func center_count(sys_id: String, max_power: int) -> int:
	var n := max_power + (1 if sys_id in ["sensors", "doors"] else 0)
	var w := 0
	for l in n:
		w = maxi(w, FtlData.ftl_text_width(10, TooltipText.level_description(sys_id, l, false)))
	return maxi(1, (w - 163 + 9) / 10)


## InfoBox::CalcWidthForSystem = 306 + 10·count + 21.
static func system_width(sys_id: String, max_power: int) -> int:
	return 327 + 10 * center_count(sys_id, max_power)


## System panel content {kind "system", name, title, description, warning, free_drone, ...} through the filter.
## `store` = SystemStoreBox (drones: `system_drones` text replaces the description).
static func system_content(sys_id: String, level: int, free_drone := "", ctx := {}) -> Dictionary:
	var info := UpgradeSession.system_info(sys_id)
	var desc := String(info.get("desc", ""))
	if sys_id == "drones" and String(ctx.get("context", "")) == "store":
		desc = TooltipText.t("system_drones")
	var d := {"kind": "system", "name": sys_id, "title": FtlData.blueprint_title(sys_id, "system"), "description": desc,
		"stats": [], "price": "", "warning": "", "tip": "", "tip_warning": "", "free_drone": free_drone}
	if level == 1 and sys_id in ["shields", "weapons"]:
		d.warning = TooltipText.t("weak_warning")
	var f: Variant = Hooks.filter(&"infobox_content", d, "system", sys_id, ctx)
	if Hooks.is_cancel(f):
		return {}
	d = f
	d["desc"] = ItemInfoBox.compose(String(d.description), d.stats)
	return d


## InfoBox::OnRender, system: frame + text at `loc` (InfoBox location), the level table at loc.y + 200 + yShift.
## `costs` = the system blueprint's upgradeCost levels; `level` = current power level, `upgrade` = previewed bars.
static func draw_system(ci: CanvasItem, loc: Vector2, d: Dictionary, max_power: int, level: int, upgrade := 0,
		y_shift := 0, force_w := 0) -> void:
	if d.is_empty():
		return
	var sys_id := String(d.name)
	var x := loc.x
	var sw := force_w if force_w > 0 else system_width(sys_id, max_power)
	var dx := sw - 32
	var h := 48 + (_h(10, String(d.warning), dx) if String(d.warning) != "" else 0) + _h(10, String(d.desc), dx) + 15
	var dy := maxi(135, h)
	var off := 67 - maxi(0, h - 135)
	WindowFrame.draw(ci, Rect2(x + 7, loc.y + off + 7, dx + 18, dy - 14))
	var y := loc.y + off + 13
	FtlData.draw_ftl_text(ci, 16, String(d.title), Vector2(x + 18, y), Color.WHITE, 0, dx)
	y += _h(16, String(d.title), dx)
	if String(d.warning) != "":
		y += 10
		FtlData.draw_ftl_text(ci, 10, String(d.warning), Vector2(x + 18, y), WARN_COL, 0, dx)
		y += _h(10, String(d.warning), dx)
	else:
		y += 15
	FtlData.draw_ftl_text(ci, 10, String(d.desc), Vector2(x + 18, y), Color.WHITE, 0, dx)
	y += _h(10, String(d.desc), dx)
	var fd := String(d.get("free_drone", ""))
	if fd != "":
		var dbp := FtlData.drone_blueprint(fd)
		var icon := FtlData.texture("img/ship/drones/%s_base.png" % String(dbp.get("drone_image", "")))
		if icon:
			ci.draw_texture(icon, (Vector2(x + 50, y + 25) - icon.get_size() / 2).round())
		FtlData.draw_ftl_text(ci, 10, TooltipText.f("free_drone", FtlData.blueprint_title(fd, "drone")), Vector2(x + 90,
			y + 8), FtlColors.GREEN, 0, dx - 72)
	# Level table.
	var t := loc.y + 200 + y_shift
	var n := max_power + (1 if sys_id in ["sensors", "doors"] else 0)
	var costs: Array = UpgradeSession.system_info(sys_id).get("costs", [])
	var scrap := FtlData.texture("img/upgradeUI/details_scrap.png")
	for i in 8:
		var ry := t + 17 + 26 * i
		var vis := i >= 8 - n
		ci.draw_rect(Rect2(x + 75, ry, sw - 86, 24), SYS_ROW_ON if vis else SYS_ROW_OFF)
		if not vis:
			continue
		if scrap:
			ci.draw_texture_rect(scrap, Rect2(x + 75, ry, 24, 24), false)
		if i < 8 - level:
			var ci_idx := 6 - i
			var cost := str(costs[ci_idx]) if i >= 8 - max_power and ci_idx >= 0 and ci_idx < costs.size() else " -"
			FtlData.draw_ftl_text(ci, 0, cost, Vector2(x + 105, ry + 7), Color.WHITE)
		FtlData.draw_ftl_text(ci, 10, TooltipText.level_description(sys_id, 7 - i, false), Vector2(x + 149, ry + 5),
			Color.WHITE)
	var a := FtlData.texture("img/upgradeUI/details_base_A.png")
	var b := FtlData.texture("img/upgradeUI/details_base_B.png")
	var c := FtlData.texture("img/upgradeUI/details_base_C.png")
	if a:
		ci.draw_texture(a, Vector2(x, t))
	var cx := x + 306
	for k in (sw - 327) / 10:
		if b:
			ci.draw_texture(b, Vector2(cx, t + 6))
		cx += 10
	if c:
		ci.draw_texture(c, Vector2(cx, t + 6))
	for k in max_power:
		var col := FtlColors.GREEN
		if GameOptions.colorblind:
			col = Color.WHITE
		if k >= level:
			col = UPGRADE_COL if k < level + upgrade else Color(UPGRADE_COL, 0.25)
		ci.draw_rect(Rect2(x + 27, t + 202 - 26 * k, 28, 18), col)
