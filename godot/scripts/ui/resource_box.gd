class_name ResourceBox
extends RefCounted
## ChoiceBox::PrintResourceBox / RenderResources / RenderResource (rules/events.md "Resource box"): what an event
## gives or takes, in one black α 0.5 box with a 2 px outline in the text colour. Used after a choice's text
## (`choice = true`, left-aligned, centred on the text vertically) and for the rewards of the event just shown
## (`choice = false`, centred under the event text).
## Row 1, left to right [exe]:
## - fuel / missiles / drone parts / scrap: `ui_icons/icon_<name>.png` (32×32, green when gained, red when lost),
##   each followed by its number (font 10, text colour, at icon + (30, 9));
## - a weapon: WeaponBlueprint::RenderIcon (weapon art at its charged frame, rotated) + its title (font 10);
## - a drone: DroneBlueprint::RenderIcon (drone image, or the crew-like drone portrait) + its title;
## - an augment: "Augment:" (font 12) + its title (font 10);
## - crew gained / lost: portrait icon + long name ("is gone" / "is now an enemy" in red); gained crew add up to
##   two skill icons (the blueprint's skills with a level, RenderSkillIcon).
## On a choice box the items go on a second row under the resources. The reward box (choice = false) adds one
## line of alerts under the items (hull damage / repair, intruders, fleet delay, item removed, upgrade, system
## installed), joined by 5 spaces, centred, red when all bad, green when all good, white when mixed or neither.
## Input `res`: {fuel, missiles, drones, scrap: int, weapon, drone, augment: blueprint name, crew: [{name, lost,
## traitor, race, male, colors, skills: {skill: level 1..2}}], alerts: [[text, good: bool | null = neither]]}.

const ORDER := ["fuel", "missiles", "drones", "scrap"]
const ICON := 32
const PAD := 5
const COL_GAIN := Color8(120, 255, 120)  # COLOR_GREEN
const COL_LOSS := Color8(255, 92, 92)  # COLOR_RED
const ALERT_SEP := "     "  # RenderResources joins the alert texts with five spaces
const ITEM_GAP := 20  # reward box: row_x += 20 after the resources, before the items
const CREW_TEXT_DX := 15  # crew icon centred at row_x, name (font 10) at row_x + 15, y + 9
const ALERT_ROW_DY := 28  # the alert line starts 28 px under the first row (row height 24)
const SKILL_ICON := 26  # CrewBlueprint::RenderSkillIcon: people/skill_<name>_white.png blitted 26×26
const SKILL_STEP := 23  # next skill icon x


## RenderResource advance: 45 px for |v| < 10, 50 otherwise, +5 when negative.
static func advance(v: int) -> int:
	return (45 if absi(v) < 10 else 50) + (5 if v < 0 else 0)


static func is_empty(res: Dictionary, choice := true) -> bool:
	if not (res.get("crew", []) as Array).is_empty():
		return false
	for k in ORDER:
		if int(res.get(k, 0)) != 0:
			return false
	for k in ["weapon", "drone", "augment"]:
		if String(res.get(k, "")) != "":
			return false
	return choice or (res.get("alerts", []) as Array).is_empty()


## Box size for these resources (0 when nothing to show).
static func measure(res: Dictionary, choice := true) -> Vector2:
	return layout(res, choice).size


## Crew item text (RenderResources crew branch): gained crew = the crew's long name; lost crew = `dead_crew`
## (" is gone") or `traitor_crew` (" is now an enemy") with the name.
static func crew_text(cr: Dictionary) -> String:
	var nm := String(cr.get("name", ""))
	if bool(cr.get("lost", false)):
		var id := "traitor_crew" if bool(cr.get("traitor", false)) else "dead_crew"
		return FtlData.tr_id(id).replace("\\1", nm)
	return nm


## The box layout (RenderResources run once to measure, then again to draw with the measured size):
## {size: rect size (row_x + 5, row height), offset: content y offset in the box, ops: [[row, kind, ...]]}.
## Op positions are relative to the content origin; row 0 ops are shifted to centre the first row when a wider
## second row follows, row 1 ops (choice items) to centre that row.
static func layout(res: Dictionary, choice := true) -> Dictionary:
	var empty := {"size": Vector2.ZERO, "offset": 0.0, "ops": [], "w": 0}
	if is_empty(res, choice):
		return empty
	var ops := []
	var x := PAD  # row_x
	var y := 0  # current row top
	var row := 0
	var row_h := 0
	var first_w := 0  # first row width / height when a second row follows (ResourceBoxDesc.row1)
	var first_h := 0
	var item := false
	for k in ORDER:
		var v := int(res.get(k, 0))
		if v != 0:
			ops.append([row, "res", k, v, Vector2(x, y)])
			x += advance(v)
	if x <= PAD:
		row_h = ICON
	elif choice:  # a choice box puts the items under the resources
		first_w = x
		first_h = ICON
		y += ICON
		row = 1
		row_h = 0
		x = 10
	else:
		x += ITEM_GAP
		row_h = ICON
	var wpn := String(res.get("weapon", ""))
	if wpn != "":
		var d := WeaponIcon.weapon_dims(wpn)
		var dw := int(d.x)
		var dh := int(d.y)
		if dh > 32 and choice:
			y += (dh - 32) >> 1
		ops.append([row, "weapon", wpn, Vector2(x + dw / 2, y + 16)])
		var t := FtlData.blueprint_title(wpn, "weapon")
		ops.append([row, "text", 10, t, Vector2(x + dw + 10, y + 9), "row"])
		x += FtlData.ftl_text_width(10, t) + 20 + dw
		var v := dh + 9
		row_h = maxi(ICON, v) if row_h < v else ICON
		item = true
	var dr := String(res.get("drone", ""))
	if dr != "":
		var d := WeaponIcon.drone_dims(dr)
		var dw := int(d.x)
		var dh := int(d.y)
		var crew_like := WeaponIcon.drone_is_crew_like(dr)
		if crew_like:
			if choice:
				x += 10
		else:
			x -= 16
			if choice and dh - 16 > 32:
				y += -10 + (dh - 48) / 2
				dh -= 10
		ops.append([row, "drone", dr, Vector2(x + dw / 2, y + 16)])
		var t := FtlData.blueprint_title(dr, "drone")
		ops.append([row, "text", 10, t, Vector2(x + dw + (15 if crew_like else -10), y + 9), "row"])
		var tend := x + FtlData.ftl_text_width(10, t)
		if crew_like:
			x = tend + 20 + dw
			row_h = maxi(ICON, row_h)
		else:
			x = tend - 4 + dw
			row_h = maxi(dh - 16, row_h)
		item = true
	var aug := String(res.get("augment", ""))
	if aug != "":
		var label := FtlData.tr_id("augment")  # "Augment:"
		ops.append([row, "text", 12, label, Vector2(x, y + 9), "row"])
		var nx := x + FtlData.ftl_text_width(12, label) + 5
		var t := FtlData.blueprint_title(aug, "augment")
		ops.append([row, "text", 10, t, Vector2(nx, y + 9), "row"])
		x = nx + FtlData.ftl_text_width(10, t) + 5
		row_h = maxi(ICON, row_h)
		item = true
	for cr in res.get("crew", []):
		if x == PAD or item:
			x += 20
		var text_x := x + CREW_TEXT_DX
		if x == 10 and choice:
			text_x = 30
			x = 15
		elif not item and choice:
			text_x = x + 13
			x -= 2
		ops.append([row, "crew", cr, Vector2(x, y + 16)])
		var t := crew_text(cr)
		ops.append([row, "text", 10, t, Vector2(text_x, y + 9), "loss" if bool(cr.get("lost", false)) else "row"])
		var end_x := text_x + FtlData.ftl_text_width(10, t) + 15
		# Gained crew: up to two skill icons (RenderSkillIcon, 26×26 at row y + 2) for the blueprint's skills with
		# a level, in CrewBlueprint order; the first 10 px back from the name end + 15, the next 23 px further.
		var shown := 0
		if not bool(cr.get("lost", false)):
			var sk: Dictionary = cr.get("skills", {})
			for i in CrewMember.SKILLS.size():
				if int(sk.get(CrewMember.SKILLS[i], 0)) <= 0:
					continue
				var ix := end_x - 10 if shown == 0 else end_x
				ops.append([row, "skill", i, float(sk[CrewMember.SKILLS[i]]) / 2.0, Vector2(ix, y + 2)])
				end_x = ix + SKILL_STEP
				shown += 1
				if shown == 2:
					break
		x = end_x + 5 if shown > 0 else end_x - 7
		row_h = maxi(ICON, row_h)
		item = true
	var alerts: Array = [] if choice else res.get("alerts", [])
	if alerts.is_empty():
		if not choice and not item:
			x -= ITEM_GAP + PAD  # resources only: the trailing gap is taken back
	else:
		var texts := PackedStringArray()
		var good := false
		var bad := false
		for a in alerts:  # [text, true = helpful | false = dangerous | null = neither (upgrade failed)]
			texts.append(String(a[0]))
			if a[1] == null:
				continue
			if bool(a[1]):
				good = true
			else:
				bad = true
		var t := ALERT_SEP.join(texts)
		var kind := "white" if good == bad else ("gain" if good else "loss")
		if x <= PAD and not item:  # alerts alone: left-aligned at row_x 30
			row_h = ICON
			x = 30
			ops.append([0, "text", 10, t, Vector2(x, y + 9), kind])
		else:  # second row, centred under the first
			y += ALERT_ROW_DY
			first_w = x
			first_h = row_h
			row_h = 24
			x = 25
			ops.append([2, "ctext", 10, t, Vector2(0, y + 9), kind])
		x += FtlData.ftl_text_width(10, t) + 25
	var w := maxi(x, first_w)
	var h := row_h + first_h
	# PrintResourceBox: rows taller than an icon centre the content (reward box only).
	var offset := 0
	if h > ICON and not choice:
		offset = (first_h - ICON) / 2 if first_h != 0 else (h - ICON) >> 1
	# Second pass (desc = measured box): the first row is centred in the box when a second row follows; a choice
	# box's item row is centred too.
	var shift := [0.0, 0.0, 0.0]
	if first_w > 0:
		shift[0] = floorf((w - first_w) / 2.0)
		shift[1] = floorf((w - x) / 2.0)
	for op in ops:
		var p: Vector2 = op[op.size() - 2] if op[1] == "text" or op[1] == "ctext" else op[op.size() - 1]
		if op[1] == "ctext":
			p.x = w / 2.0
		else:
			p.x += shift[op[0]]
		if op[1] == "text" or op[1] == "ctext":
			op[op.size() - 2] = p
		else:
			op[op.size() - 1] = p
	return {"size": Vector2(w + PAD, h), "offset": float(offset), "ops": ops, "w": w}


## CrewBlueprint::RenderSkillIcon(x, y, skill): BlueprintManager::GetSkillIcon(skill, false) =
## `people/skill_<name>_white.png` blitted 26×26 at (x, y), tinted by level / max: below 0.5 white, below 1
## COLOR_GREEN, at 1 COLOR_YELLOW (colour-blind: COLOR_CB_BLUE). An event skill level 1 = 0.5, 2 = 1.
static func draw_skill_icon(ci: CanvasItem, skill: int, ratio: float, at: Vector2) -> void:
	var tex := FtlData.texture("img/people/skill_%s_white.png" % CrewMember.SKILLS[skill])
	if tex == null:
		return
	var tint := Color.WHITE
	if ratio >= 1.0:
		tint = Color8(0, 147, 224) if GameOptions.colorblind else FtlColors.YELLOW
	elif ratio >= 0.5:
		tint = FtlColors.GREEN
	ci.draw_texture_rect(tex, Rect2(at.floor(), Vector2(SKILL_ICON, SKILL_ICON)), false, tint)


## Draws the box with its top-left at `pos`; returns its size. `text_col` = the row / box text colour.
static func draw(ci: CanvasItem, res: Dictionary, pos: Vector2, text_col: Color, choice := true) -> Vector2:
	var lay := layout(res, choice)
	var sz: Vector2 = lay.size
	if sz == Vector2.ZERO:
		return sz
	pos = pos.floor()
	ci.draw_rect(Rect2(pos, sz), Color(0, 0, 0, 0.5))
	ci.draw_rect(Rect2(pos + Vector2(1, 1), sz - Vector2(2, 2)), text_col, false, 2.0)
	var o := pos + Vector2(0, lay.offset)
	for op in lay.ops:
		match String(op[1]):
			"res":
				var k := String(op[2])
				var v := int(op[3])
				var p: Vector2 = o + op[4]
				var tex := FtlData.texture("img/ui_icons/icon_%s.png" % k)
				if tex:
					ci.draw_texture_rect(tex, Rect2(p, Vector2(ICON, ICON)), false, COL_GAIN if v > 0 else COL_LOSS)
				FtlData.draw_ftl_text(ci, 10, str(v), p + Vector2(30, 9), text_col)
			"weapon":
				WeaponIcon.draw_weapon(ci, String(op[2]), o + op[3])
			"drone":
				WeaponIcon.draw_drone(ci, String(op[2]), o + op[3])
			"crew":
				var cr: Dictionary = op[2]
				var lk := CrewPortrait.look(String(cr.get("race", "human")), bool(cr.get("male", true)),
					cr.get("colors", []))
				CrewPortrait.draw_icon(ci, lk, o + op[3])  # CrewBlueprint::RenderIcon(1.0), centred
			"skill":
				draw_skill_icon(ci, int(op[2]), float(op[3]), o + op[4])
			"text", "ctext":
				var col := text_col
				match String(op[5]):
					"loss":
						col = COL_LOSS
					"gain":
						col = COL_GAIN
					"white":
						col = Color.WHITE
				FtlData.draw_ftl_text(ci, int(op[2]), String(op[3]), o + op[4], col, 1 if op[1] == "ctext" else 0)
	return sz
