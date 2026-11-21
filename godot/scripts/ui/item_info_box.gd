class_name ItemInfoBox
## The InfoBox description panel of the store and of the store's SELL tab (rules/store.md "Info box content"):
## content per blueprint kind as the exe builds it (InfoBox::SetBlueprint ×5, WeaponBlueprint::GetDescription(false),
## BlueprintManager::GetChanceString, InfoBox::CreateTipBox) and the renderer (InfoBox::OnRender): primary
## WindowFrame with the title (font 16) / red warning (font 10) / description (font 10), plus the TIP frame below it
## (font 9, optional pink tip warning). Pure functions of the blueprint data; no state.

const W := 323  # WindowFrame width (0x143)
const DESC_W := 305  # descBoxSize.x (0x131): wrap width of title and description
const FRAME_H := {"weapon": 252, "drone": 162, "item": 121, "augment": 136, "crew": 242}
const DESC_BOX_H := {"weapon": 266, "drone": 176, "item": 135, "augment": 150, "crew": 182}
const TYPES := {"LASER": 0, "MISSILES": 1, "BEAM": 2, "BOMB": 3, "BURST": 4}
const COL_WARN := Color8(255, 120, 120)  # 0x831aa0
const COL_TIP_WARN := Color(0.99215686, 0.5764706, 0.5764706)


static func _t(id: String) -> String:
	return FtlData.tr_id(id).replace("\\n", "\n")


## TextLibrary::FormatText: every "\1" replaced by the value.
static func fmt(id: String, v: Variant) -> String:
	return _t(id).replace("\\1", str(v))


## ostream << (double)float: default format, 6 significant digits, no trailing zeros (8 → "8", 11.5 → "11.5").
static func fmt_float(v: float) -> String:
	if is_equal_approx(v, roundf(v)) and absf(v) < 1e6:
		return str(int(roundf(v)))
	var digits := int(floor(log(absf(v)) / log(10.0))) + 1 if v != 0.0 else 1
	var s := String.num(v, maxi(0, 6 - digits))
	if "." in s:
		s = s.rstrip("0").rstrip(".")
	return s


## BlueprintManager::GetChanceString: 0 → "", 1–3 low, 4–6 medium, ≥ 7 high.
static func chance_string(rating: int) -> String:
	if rating == 0:
		return ""
	return _t("chance_low" if rating < 4 else ("chance_medium" if rating < 7 else "chance_high"))


## WeaponBlueprint::GetDescription(tooltip = false), the text of the store / equipment info box: the blueprint
## description, then one " \n"-separated stat line per field (rules/store.md "Weapon stat lines").
static func weapon_description(nm: String, ae: bool) -> String:
	var info := FtlData.item_info("weapon", nm)
	return compose(String(info.get("desc", "")).replace("\\n", "\n"), weapon_stats(nm, ae))


## The stat lines of `weapon_description` (without the description).
static func weapon_stats(nm: String, ae: bool) -> Array:
	var bp := FtlData.weapon_blueprint(nm)
	if bp.is_empty():
		return []
	var ty: int = TYPES.get(String(bp.type).strip_edges(), 0)
	var out := []
	out.append(fmt("required_power", int(bp.power)))
	out.append(fmt("charge_time", fmt_float(float(bp.cooldown))))
	var boost: Dictionary = bp.get("boost", {})
	if int(boost.get("count", 0)) > 1:
		var total := float(boost.count) * float(boost.amount)
		if String(boost.type).strip_edges() == "damage":
			out.append(_t("boost_power_damage"))
			var base := int(bp.ion) if int(bp.ion) > 0 else int(bp.damage)
			out.append(fmt("damage_cap", fmt_float(base + total)))
		else:
			out.append(_t("boost_power_speed"))
			out.append(fmt("speed_cap", fmt_float(float(bp.cooldown) - total)))
	if int(bp.missiles) > 0:
		out.append(_t("requires_missiles"))
	if ty == 0 or (ty == 1 and int(bp.shots) > 1):
		out.append(fmt("shots", int(bp.shots)))
	if ty == 4:
		out.append(fmt("shots", mini_count(bp)))
	if int(bp.charge_levels) > 1:
		out.append(fmt("charge", int(bp.charge_levels)))
	out.append(fmt("damage_room" if ty == 2 else "damage_shot", int(bp.damage)))
	if int(bp.sp) != 0:
		out.append(fmt("shield_piercing", int(bp.sp)))
	if int(bp.fire_chance) != 0:
		out.append(fmt("fire_chance", chance_string(int(bp.fire_chance))))
	if int(bp.breach_chance) != 0:
		out.append(fmt("breach_chance", chance_string(int(bp.breach_chance))))
	if int(bp.stun_chance) != 0 and ae:
		out.append(fmt("stun_chance", chance_string(int(bp.stun_chance))))
	if int(bp.ion) != 0:
		out.append(fmt("ion_damage", int(bp.ion)))
	if int(roundf(float(bp.stun))) != 0:
		out.append(fmt("stun_damage", int(roundf(float(bp.stun)))))
	if int(bp.pers_damage) > 0:
		out.append(fmt("personnel_damage", int(bp.pers_damage) * 15))
	if int(bp.sys_damage) != 0:
		out.append(fmt("system_damage", int(bp.sys_damage)))
	if int(bp.hull_bust) != 0:
		out.append(_t("double_damage"))
	return out


## description + " \n\n" + the stat lines joined with " \n" (vanilla text layout of the info box).
static func compose(description: String, stats: Array) -> String:
	if stats.is_empty():
		return description
	return description + " \n\n" + " \n".join(PackedStringArray(stats))


## WeaponBlueprint::miniCount: the summed `count` of the non-fake <projectile> entries (flak).
static func mini_count(bp: Dictionary) -> int:
	var n := 0
	for p in bp.get("mini_projectiles", []):
		if not bool(p.get("fake", false)):
			n += 1
	return n


## InfoBox::SetBlueprint(DroneBlueprint): description + " \n\n" required_power + " \n" drone_required.
static func drone_description(nm: String) -> String:
	var info := FtlData.item_info("drone", nm)
	return compose(String(info.get("desc", "")).replace("\\n", "\n"), drone_stats(nm))


static func drone_stats(nm: String) -> Array:
	var info := FtlData.item_info("drone", nm)
	return [fmt("required_power", int(info.get("power", 0))), _t("drone_required")]


## The box content for a blueprint: {kind, name, title, description, stats, price, desc, warning, tip, tip_warning}.
## `has_system` = the shopper owns the weapons (weapon) / drones (drone) system. Store and equipment use status 2:
## the blueprint's <tip> (drones fall back to tip_drone_generic; tip_drone_warning when the ship has no drone
## system). Items (fuel, missiles, drone parts) and augments: title + description only, no tip.
## Mods: the `infobox_content` filter (rules/hooks.md) gets the structured dict with args (kind, name, ctx) —
## ctx {context: "store"|"equipment"|"hangar"|"upgrades", sell_price, owned, ae} — before `desc` is composed
## (= description + " \n\n" + stats joined with " \n"); a non-empty `price` is drawn under it (`{scrap}` = icon).
static func content(kind: String, nm: String, has_system: bool, ae: bool, ctx := {}) -> Dictionary:
	var info := FtlData.item_info(kind, nm)
	var out := {"kind": kind, "name": nm, "title": FtlData.blueprint_title(nm, kind), "description": String(info.get(
		"desc", "")).replace("\\n", "\n"), "stats": [], "price": "", "warning": "", "tip": "", "tip_warning": ""}
	match kind:
		"weapon":
			out.stats = weapon_stats(nm, ae)
			if String(info.get("tip", "")) != "":
				out.tip = _t(String(info.tip))
		"drone":
			out.stats = drone_stats(nm)
			out.tip = _t(String(info.tip)) if String(info.get("tip", "")) != "" else _t("tip_drone_generic")
			if not has_system:
				out.tip_warning = _t("tip_drone_warning")
	var c := ctx.duplicate()
	c["ae"] = ae
	return finish(out, c)


## Runs the `infobox_content` filter and composes `desc`. Returns {} when a mod cancelled the box.
static func finish(d: Dictionary, ctx := {}) -> Dictionary:
	var f: Variant = Hooks.filter(&"infobox_content", d, String(d.get("kind", "")), String(d.get("name", "")), ctx)
	if Hooks.is_cancel(f):
		return {}
	var out: Dictionary = f
	out["desc"] = compose(String(out.get("description", "")), out.get("stats", []))
	return out


## Primary frame rect (WindowFrame(7, 7, 323, h) drawn at location + (0, 67)).
static func frame_rect(loc: Vector2, kind: String, h := -1) -> Rect2:
	return Rect2(loc + Vector2(7, 74), Vector2(W, h if h >= 0 else int(FRAME_H.get(kind, 121))))


## TIP frame rect: top at location.y + 77 + descBoxSize.y (+ yShift), height max(60, text + 35) − 4 where text =
## the tip (font 9, wrap 307) plus 10 + the tip warning when there is one.
static func tip_rect(loc: Vector2, d: Dictionary) -> Rect2:
	var th := _height(9, String(d.tip), DESC_W + 2)
	if String(d.tip_warning) != "":
		th += 10 + _height(9, String(d.tip_warning), DESC_W + 2)
	var h := maxi(60, th + 35) - 4
	return Rect2(loc + Vector2(7, 77 + int(DESC_BOX_H.get(String(d.kind), 135))), Vector2(W, h))


static func _height(font: int, t: String, wrap: int) -> int:
	if t == "":
		return 0
	return FtlData.ftl_wrap(font, t, wrap).size() * FtlData.ftl_line_height(font)


## Height of the primary frame's text (title, warning, description, price) from the frame's top inner edge.
static func text_height(d: Dictionary) -> int:
	var h := 6 + _height(16, String(d.title), DESC_W)
	h += (10 + _height(10, String(d.warning), DESC_W)) if String(d.warning) != "" else 15
	h += _height(10, String(d.desc), DESC_W)
	if String(d.get("price", "")) != "":
		h += 2 * FtlData.ftl_line_height(10)
	return h


## A price line: text segments with the scrap icon at every `{scrap}` (font 10, white).
static func draw_price(ci: CanvasItem, price: String, at: Vector2) -> void:
	var x := at.x
	var icon := FtlData.texture("img/upgradeUI/details_scrap.png")
	var parts := price.split("{scrap}")
	for i in parts.size():
		x += FtlData.draw_ftl_text(ci, 10, parts[i], Vector2(x, at.y), Color.WHITE)
		if i < parts.size() - 1:
			if icon:
				ci.draw_texture_rect(icon, Rect2(Vector2(x + 1, at.y - 2), Vector2(18, 18)), false)
			x += 20


## InfoBox::OnRender for `content()` at `loc` (= InfoBox.location): returns the y below the description (crew
## skills etc. go there).
static func draw(ci: CanvasItem, loc: Vector2, d: Dictionary, frame_h := -1) -> float:
	var base_h := frame_h if frame_h >= 0 else int(FRAME_H.get(String(d.kind), 121))
	var fh := maxi(base_h, text_height(d) + 12)  # grows only when a mod's content does not fit (vanilla fits)
	WindowFrame.draw(ci, frame_rect(loc, String(d.kind), fh))
	var x := loc.x + 18
	var y := loc.y + 67 + 13
	FtlData.draw_ftl_text(ci, 16, String(d.title), Vector2(x, y), Color.WHITE, 0, DESC_W)
	y += _height(16, String(d.title), DESC_W)
	if String(d.warning) != "":
		y += 10
		FtlData.draw_ftl_text(ci, 10, String(d.warning), Vector2(x, y), COL_WARN, 0, DESC_W)
		y += _height(10, String(d.warning), DESC_W)
	else:
		y += 15
	FtlData.draw_ftl_text(ci, 10, String(d.desc), Vector2(x, y), Color.WHITE, 0, DESC_W)
	y += _height(10, String(d.desc), DESC_W)
	if String(d.get("price", "")) != "":
		y += FtlData.ftl_line_height(10)
		draw_price(ci, String(d.price), Vector2(x, y))
		y += FtlData.ftl_line_height(10)
	if String(d.tip) != "":
		var tipr := tip_rect(loc, d)
		tipr.position.y += fh - base_h
		WindowFrame.draw(ci, tipr)
		var ty := tipr.position.y + 15
		FtlData.draw_ftl_text(ci, 9, String(d.tip), Vector2(loc.x + 20, ty), Color.WHITE, 0, DESC_W + 2)
		if String(d.tip_warning) != "":
			ty += _height(9, String(d.tip), DESC_W + 2) + 10
			FtlData.draw_ftl_text(ci, 9, String(d.tip_warning), Vector2(loc.x + 20, ty), COL_TIP_WARN, 0, DESC_W + 2)
	return y
