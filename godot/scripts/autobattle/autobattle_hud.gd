class_name AutobattleHud
extends Control
## Autobattle demo (scripts/autobattle/autobattle.gd): the status of one ship, anchored to a top corner of the
## canvas. The left ship's reads like the player's top-left ShipStatus (hull frame and segmented bar, shields frame and
## bubbles, evade / O2 box) plus a name block, a system column (icon, power bars, ion / hack / broken state), the
## weapons' charge bars and the crew's health. The right ship's is the same block mirrored onto the right edge: the
## frame art is flipped and the column hangs from the right edge, the texts stay readable (alignment swapped).
## Drawn in local units (WIDTH wide) and scaled by the scene (`scale`); mouse-transparent, nothing interactive.
## `mode` (autobattle.gd ui_mode): "full" (all of the above), "hull" (the hull frame and bar + the class name under
## it) or "none" (nothing drawn).

const WIDTH := 400.0
const NAME_POS := Vector2(146, 46)  # name block (right of the shields frame)
const SYS_TOP := 152.0  # first system row
const SYS_ROW := 24.0
const ICON := 44.0  # system icon box: the 64 × 64 icon art (glyph in its middle half) scaled into it
const ICON_AT := Vector2(-9, -10)  # icon box offset from the row's top-left (glyph ~ 22 px at x 2..24)
const BAR_X := 30.0  # first power bar
const BAR := Vector2(7, 13)
const BAR_STEP := 9.0
const WEAPON_ROW := 16.0
const CREW_ROW := 14.0
const TAG_W := 44.0  # room for the ION / HACKED / BROKEN tag right of the bars
const HULL_NAME_POS := Vector2(12, 44)  # "hull" mode: class name under the hull frame
const HULL_ONLY_H := 66.0  # "hull" mode: local height of the block (frame + name)
const MODES := ["full", "hull", "none"]

var ship: ShipState
var mirrored := false
var subtitle := ""  # e.g. "Rebel fleet · sector 5"
var mode := "full"  # "full" | "hull" | "none"
var _t := 0.0


func setup(s: ShipState, mirror: bool, sub: String) -> void:
	ship = s
	mirrored = mirror
	subtitle = sub
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size = Vector2(WIDTH, 720)


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


# ------------------------------------------------------------------ mirrored drawing helpers

## Image at `pos` (local, left layout); mirrored: the image flipped onto the mirrored place.
func _img(rel: String, pos: Vector2, color := Color.WHITE) -> void:
	var t := HudDraw.tex(rel)
	if t == null:
		return
	if mirrored:
		draw_set_transform(Vector2(WIDTH - pos.x, 0), 0.0, Vector2(-1, 1))
		draw_texture(t, Vector2(0, pos.y).round(), color)
		draw_set_transform(Vector2.ZERO)
	else:
		draw_texture(t, pos.round(), color)


## Left `w` px of an image (hull bar); mirrored: they grow from the right edge.
func _img_cropped(rel: String, pos: Vector2, w: float, color: Color) -> void:
	if mirrored:
		draw_set_transform(Vector2(WIDTH - pos.x, 0), 0.0, Vector2(-1, 1))
		HudDraw.img_cropped(self, rel, Vector2(0, pos.y), w, color)
		draw_set_transform(Vector2.ZERO)
	else:
		HudDraw.img_cropped(self, rel, pos, w, color)


func _rect(r: Rect2) -> Rect2:
	return Rect2(WIDTH - r.end.x, r.position.y, r.size.x, r.size.y) if mirrored else r


## Icon art (not flipped: it reads like text) in the local box `r`.
func _icon(rel: String, r: Rect2, color := Color.WHITE) -> void:
	var t := HudDraw.tex(rel)
	if t != null:
		draw_texture_rect(t, _rect(r), false, color)


## FTL text; `align` 0 left / 1 centre / 2 right in the left layout (swapped when mirrored).
func _text(font_id: int, s: String, pos: Vector2, color := Color.WHITE, align := 0) -> void:
	var x := WIDTH - pos.x if mirrored else pos.x
	var a := align
	if mirrored and align != 1:
		a = 2 - align
	HudDraw.text(self, font_id, s, Vector2(x, pos.y), color, a)


# ------------------------------------------------------------------ drawing

func _draw() -> void:
	if ship == null or mode == "none":
		return
	_draw_hull()
	if mode == "hull":
		_text(12, ship_class(), HULL_NAME_POS, Color.WHITE)
		return
	_draw_shields()
	_draw_evade_oxygen()
	_draw_name()
	var y := _draw_systems(SYS_TOP)
	y = _draw_weapons(y + 6.0)
	_draw_crew(y + 6.0)


## ShipStatus hull frame (top_hull.png), segmented bar cropped to 360 · hull / max, label 4-slice + "HULL".
func _draw_hull() -> void:
	_img("statusUI/top_hull.png", HudLayout.HULL_FRAME)
	var col := HudLayout.HULL_GREEN if ship.hull >= 20 else (HudLayout.HULL_YELLOW if ship.hull >= 10
		else HudLayout.HULL_RED)
	var frac := clampf(float(ship.hull) / maxf(ship.max_hull, 1), 0.0, 1.0)
	_img_cropped("statusUI/top_hull_bar_mask.png", HudLayout.HULL_FILL, HudLayout.HULL_FILL_W * frac, col)
	var label := HudDraw.txt("status_hull")
	var tw := FtlData.ftl_text_width(62, label)
	var t := HudDraw.tex("statusUI/top_hull_label.png")
	if t:
		var h := t.get_height()
		if mirrored:
			draw_set_transform(Vector2(WIDTH, 0), 0.0, Vector2(-1, 1))
		draw_texture_rect_region(t, Rect2(0, 0, 16, h), Rect2(0, 0, 16, h))
		draw_texture_rect_region(t, Rect2(16, 0, maxf(tw - 15, 0), h), Rect2(16, 0, 1, h))
		draw_texture_rect_region(t, Rect2(tw + 1, 0, 34, h), Rect2(17, 0, 34, h))
		draw_texture_rect_region(t, Rect2(tw + 35, 0, maxf(HudLayout.HULL_LABEL_END - tw - 35, 0), h),
			Rect2(51, 0, 1, h))
		draw_set_transform(Vector2.ZERO)
	_text(62, label, HudLayout.HULL_TEXT, HudLayout.BUTTON_TEXT)


## Shields frame, one bubble per layer (max 4), the Zoltan super shield bars or the recharge bar.
func _draw_shields() -> void:
	var sh := ship.sys("shields")
	var hacked := sh != null and sh.hack_effect() > 1
	_img("statusUI/top_shields4_on.png" if ship.shield_layers > 0 else "statusUI/top_shields4_off.png",
		HudLayout.SHIELDS_FRAME)
	if hacked and fmod(_t, 0.5) < 0.25:
		_img("statusUI/top_shields4_purple.png", HudLayout.SHIELDS_FRAME + Vector2(12, 6))
	var mx := mini(ship.max_shield_layers(), 4)
	for i in mx:
		var on := i < ship.shield_layers
		var img := "on" if on else "off"
		if hacked:
			img = "hacked_charged" if on else "hacked"
		_img("statusUI/top_shieldsquare1_%s.png" % img, HudLayout.SHIELD_BUBBLE + Vector2(HudLayout.SHIELD_STEP * i, 0))
	if ship.super_shield > 0:
		for k in mini(ship.super_shield, 5):
			_img("statusUI/energy_shield_bar2.png" if k == 2 else "statusUI/energy_shield_bar.png",
				HudLayout.ENERGY_SHIELD + Vector2(3 + 18 * k, 3))
	elif mx > 0:
		_img("statusUI/energy_shield_box.png", HudLayout.ENERGY_SHIELD)
		if ship.shield_layers < ship.max_shield_layers():
			var r := clampf(ship.shield_charger / ShipState.SHIELD_CHARGE_TIME, 0.0, 1.0)
			draw_rect(_rect(Rect2(HudLayout.ENERGY_SHIELD + Vector2(3, 3), Vector2(roundf(92 * r), 6))),
				FtlColors.PURPLE_HACK if hacked else Color8(27, 132, 255))


func _draw_evade_oxygen() -> void:
	var dodge := ship.dodge_factor()
	var o2 := int(ship.env.average_oxygen())
	var img := "top_evade_oxygen"
	if dodge == 0:
		img = "top_evade_oxygen_both_red" if o2 < 25 else "top_evade_oxygen_up_red"
	elif o2 < 25:
		img = "top_evade_oxygen_down_red"
	_img("statusUI/%s.png" % img, HudLayout.EVADE_BOX)
	var x := float(HudLayout.EVADE_TEXT_X)
	if mirrored:  # flipped box: "N%" reads from the box's left side (the mirror of x 92)
		_text(10, "%d%%" % dodge, Vector2(x + 10, HudLayout.EVADE_TEXT_Y), HudLayout.BUTTON_ON, 2)
		_text(10, "%d%%" % o2, Vector2(x + 10, HudLayout.O2_TEXT_Y), HudLayout.BUTTON_ON, 2)
		return
	_text(10, str(dodge), Vector2(x, HudLayout.EVADE_TEXT_Y), HudLayout.BUTTON_ON, 2)
	_text(10, "%", Vector2(x, HudLayout.EVADE_TEXT_Y), HudLayout.BUTTON_ON)
	_text(10, str(o2), Vector2(x, HudLayout.O2_TEXT_Y), HudLayout.BUTTON_ON, 2)
	_text(10, "%", Vector2(x, HudLayout.O2_TEXT_Y), HudLayout.BUTTON_ON)


## Class name, the round's fleet / sector line, hull points and reactor use.
func _draw_name() -> void:
	_text(12, ship_class(), NAME_POS, Color.WHITE)
	_text(10, subtitle, NAME_POS + Vector2(0, 22), FtlColors.GREY)
	var line := "HULL %d/%d   REACTOR %d/%d" % [maxi(ship.hull, 0), ship.max_hull, ship.reactor_used(),
		ship.reactor_capacity()]
	_text(10, line, NAME_POS + Vector2(0, 40), HudLayout.BUTTON_ON)
	if ship.is_destroyed():
		_text(12, "DESTROYED", NAME_POS + Vector2(0, 60), FtlColors.RED)
	elif ship.is_cloaked():
		_text(10, "CLOAKED", NAME_POS + Vector2(0, 60), FtlColors.BLUE)


## One row per installed system (SystemState.ORDER): icon tinted by state, its power bars, ion / hack text.
func _draw_systems(y: float) -> float:
	for id in SystemState.ORDER:
		var s := ship.sys(id)
		if s == null:
			continue
		var lv := s.get_level()
		var state := "green" if s.effective_power() > 0 else "grey"
		if s.damage >= lv and lv > 0:
			state = "red"
		elif s.damage > 0:
			state = "orange"
		elif s.is_ionized():
			state = "blue"
		var icon_col := FtlColors.PURPLE_HACK if s.hacked else Color.WHITE
		_icon("icons/s_%s_%s1.png" % [id, state], Rect2(Vector2(0, y) + ICON_AT, Vector2(ICON, ICON)), icon_col)
		for i in lv:
			FtlColors.draw_power_bar(self, _rect(Rect2(BAR_X + i * BAR_STEP, y + 6, BAR.x, BAR.y)), s.bar_state(i))
		var tag := ""
		var tc := FtlColors.WHITE
		if s.hacked:
			tag = "HACKED"
			tc = FtlColors.PURPLE_HACK
		elif s.is_ionized():
			tag = "ION"
			tc = FtlColors.BLUE
		elif lv > 0 and s.damage >= lv:
			tag = "BROKEN"
			tc = FtlColors.RED
		if tag != "":
			_text(9, tag, Vector2(BAR_X + lv * BAR_STEP + 4, y + 5), tc)
		y += SYS_ROW
	return y


## Weapons: short name and charge bar (yellow while powered, grey off), drones deployed after them.
func _draw_weapons(y: float) -> float:
	var wl := ship.crew_level_in("weapons")
	for w in ship.weapons:
		var r := Rect2(0, y + 4, 60, 6)
		draw_rect(_rect(r), Color(0.1, 0.12, 0.14, 0.85))
		var fill := Rect2(r.position, Vector2(roundf(60 * clampf(w.ratio(wl), 0.0, 1.0)), 6))
		if fill.size.x > 0:
			draw_rect(_rect(fill), Color8(255, 200, 60) if w.powered else FtlColors.GREY)
		_text(9, FtlData.blueprint_short(String(w.bp.get("name", "")), "weapon"), Vector2(66, y),
			Color.WHITE if w.powered else FtlColors.GREY)
		y += WEAPON_ROW
	var drones := ship.drones.filter(func(d): return d.powered)
	if not drones.is_empty():
		var names := drones.map(func(d): return FtlData.blueprint_short(String(d.bp.get("name", "")), "drone"))
		_text(9, "DRONES: " + ", ".join(PackedStringArray(names)), Vector2(0, y), FtlColors.GREEN)
		y += WEAPON_ROW
	return y


## This side's living crew, aboard either ship (drones left out): [[crew, away], ...].
func _crew_list() -> Array:
	var list := []
	for s in [ship, ship.opponent]:
		if s == null:
			continue
		for c in s.crew:
			if c.is_alive() and not c.is_drone() and c.player_owned == ship.is_player:
				list.append([c, s != ship])
	return list


func _crew_name(c: CrewMember, away: bool) -> String:
	var nm := FtlData.blueprint_title(c.race, "crew")
	if c.mind_controlled:
		nm += " (MC)"
	elif away:
		nm += " (boarding)"
	return nm


func ship_class() -> String:
	var cls := TitleState.ship_class(String(ship.blueprint.get("name", "")))
	if cls == "":
		cls = FtlData.readable_name(String(ship.blueprint.get("name", "")))
	return cls


## Local height of the top block the ships keep clear of in "hull" mode (0 otherwise: "full" keeps clear of the
## whole column instead, "none" draws nothing).
func top_height() -> float:
	return HULL_ONLY_H if mode == "hull" else 0.0


## Local width of the system / weapons / crew column (the scene keeps the ships clear of it; 0 unless "full").
func column_width() -> float:
	if mode != "full":
		return 0.0
	if ship == null:
		return 160.0
	var w := 0.0
	for id in ship.systems:
		w = maxf(w, BAR_X + ship.systems[id].get_level() * BAR_STEP + TAG_W)
	for wp in ship.weapons:
		w = maxf(w, 66.0 + FtlData.ftl_text_width(9, FtlData.blueprint_short(String(wp.bp.get("name", "")), "weapon")))
	for e in _crew_list():
		w = maxf(w, 46.0 + FtlData.ftl_text_width(9, _crew_name(e[0], true)))
	return w


## This side's living crew: health bar and race, one row each.
func _draw_crew(y: float) -> void:
	var list := _crew_list()
	for i in list.size():
		var c: CrewMember = list[i][0]
		var away: bool = list[i][1]
		var p := Vector2(0, y + i * CREW_ROW)
		var r := Rect2(p + Vector2(0, 4), Vector2(40, 5))
		draw_rect(_rect(r), Color(0.1, 0.12, 0.14, 0.85))
		var f := clampf(c.hp / maxf(c.max_hp, 1.0), 0.0, 1.0)
		var col := FtlColors.GREEN if f > 0.5 else (FtlColors.YELLOW if f > 0.25 else FtlColors.RED)
		draw_rect(_rect(Rect2(r.position, Vector2(roundf(40 * f), 5))), col)
		_text(9, _crew_name(c, away), p + Vector2(46, -1), FtlColors.ORANGE if away else FtlColors.WHITE)
