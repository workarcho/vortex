extends RefCounted
## Internal QoL mod (rules/qol_plan.md groups; rules/hooks.md is the only API it uses). The engine has no QoL
## flags: every feature below is a hook listener, a filter or a data patch, and everything is OFF by default.
##
## Groups:
## - Weapon cooldown numbers (A1): seconds left until charged, above each powered charging weapon box.
## - Better health bars (A2 hull numbers, A3 enemy bar proportional above 22 hull, A4 player bar colour by thirds).
## - Pause on combat start: the game pauses when a fight begins.
## - Drone autodeploy: an AUTO toggle on the drone panel that powers / redeploys drones whenever possible.
## - Start with scanners (gameplay, frozen per run): the player ships' blueprints get ADV_SCANNERS (Long-Ranged
##   Scanners) through the data_text_loaded filter.
## - Better info (A6 / A7, Hyperspace / Multiverse style, rules/tooltips.md §8): the redesigned weapon tooltip (rule
##   `tooltip.weapon`: numeric stats in blank-line groups, chances in %) and the info panel "Stats:" block with
##   Default / Selling price (filter `infobox_content`). Texts: text_qol.xml (ours).
## - Extended statistics: the MORE STATS page of the Stats screen (filter `stats_more_button`;
##   rules/save_and_profile.md §3).

const AutoButton := preload("auto_drone_button.gd")

const G_COOLDOWN := "qol_cooldown"
const G_HEALTH := "qol_health"
const G_PAUSE := "qol_pause"
const G_DRONES := "qol_drones"
const G_SCANNERS := "qol_scanners"
const G_INFO := "qol_info"
const G_STATS := "qol_stats"

const COOLDOWN_ON := "qol.cooldown.numbers"
const COOLDOWN_FORMAT := "qol.cooldown.format"
const HULL_NUMBERS := "qol.health.hull_numbers"
const HULL_CAP := "qol.health.hull_cap"
const HULL_THIRDS := "qol.health.thirds"
const PAUSE_ON := "qol.pause.on_combat"
const DRONE_AUTO := "qol.drones.auto_button"
const DRONE_AUTO_START := "qol.drones.start_on"
const SCANNERS_ON := "qol.scanners.augment"
const INFO_WEAPON_TIP := "qol.info.weapon_tooltip"
const INFO_PANEL := "qol.info.panel_stats"
const STATS_PAGE := "qol.stats.more_page"

const SCANNERS_AUG := "ADV_SCANNERS"  # blueprints.xml <augBlueprint name="ADV_SCANNERS"> (Long-Ranged Scanners)
const SCANNER_FILES := ["data/blueprints.xml", "data/dlcBlueprints.xml"]
const MAX_AUGMENTS := 3
const ENEMY_BAR_SEGMENTS := 22.0  # box_hostiles_hull2.png: 22 segments
const MANUAL_OFF := "qol_manual_off"  # drone meta: depowered by the player while AUTO is on

var ctx: ModContext
var settings: Node


func _mod_init(c: ModContext) -> void:
	ctx = c
	settings = c.settings
	_declare()
	c.listen(&"hud_draw.weapon_box", _draw_cooldown)
	c.listen(&"hud_draw.ship_status", _draw_player_hull)
	c.listen(&"hud_draw.enemy_window", _draw_enemy_hull)
	c.add_filter(&"hud_hull_fraction", _hull_fraction)
	c.add_filter(&"hud_hull_color", _hull_color)
	c.listen(&"combat_started", _on_combat_started)
	c.listen(&"hud_ready", _on_hud_ready)
	c.listen(&"sim_tick", _on_sim_tick)
	c.listen(&"drone_depowered", _on_drone_depowered)
	c.listen(&"drone_powered", _on_drone_powered)
	c.add_filter(&"data_text_loaded", _patch_scanners)
	c.listen(&"settings_changed", _on_settings_changed)
	c.set_rule(&"tooltip.weapon", _weapon_tooltip)
	c.add_filter(&"infobox_content", _infobox_content)
	c.add_filter(&"stats_more_button", _stats_more_button)
	_load_texts()
	_map_hyperspace()


func _declare() -> void:
	ctx.declare_group(G_COOLDOWN, "Weapon cooldown numbers", "Seconds until each weapon is charged (HS showNumericalWeaponCooldown).")
	ctx.declare(G_COOLDOWN, {"id": COOLDOWN_ON, "label": "Show seconds above charging weapons", "default": true})
	ctx.declare(G_COOLDOWN, {"id": COOLDOWN_FORMAT, "label": "Format", "type": "enum",
		"options": ["one decimal", "whole seconds"], "default": "one decimal"})
	ctx.declare_group(G_HEALTH, "Better health bars", "Hull numbers, capped enemy bar, colour by thirds.")
	ctx.declare(G_HEALTH, {"id": HULL_NUMBERS, "label": "Hull numbers on the hull bars", "default": true})
	ctx.declare(G_HEALTH, {"id": HULL_CAP, "label": "Enemy hull bar proportional above 22 hull", "default": true})
	ctx.declare(G_HEALTH, {"id": HULL_THIRDS, "label": "Player hull colour by thirds of max hull", "default": true})
	ctx.declare_group(G_PAUSE, "Pause on combat start", "The game pauses when a fight begins.")
	ctx.declare(G_PAUSE, {"id": PAUSE_ON, "label": "Pause when a hostile ship engages", "default": true})
	ctx.declare_group(G_DRONES, "Drone autodeploy", "AUTO toggle on the drone panel, like weapon autofire.")
	ctx.declare(G_DRONES, {"id": DRONE_AUTO, "label": "AUTO button on the drone panel", "default": true})
	ctx.declare(G_DRONES, {"id": DRONE_AUTO_START, "label": "AUTO starts switched on", "default": false})
	ctx.declare_group(G_SCANNERS, "Start with scanners", "Player ships start with Long-Ranged Scanners.")
	ctx.declare(G_SCANNERS, {"id": SCANNERS_ON, "label": "Give the player ship Long-Ranged Scanners",
		"default": true, "gameplay": true})
	ctx.declare_group(G_INFO, "Better info", "Numeric weapon tooltips and item info with stats and prices (HS / MV).")
	ctx.declare(G_INFO, {"id": INFO_WEAPON_TIP, "label": "Redesigned weapon tooltip (numeric stats)", "default": true})
	ctx.declare(G_INFO, {"id": INFO_PANEL, "label": "Info panel: Stats block and Default / Selling price",
		"default": true})
	ctx.declare_group(G_STATS, "Extended statistics",
		"A MORE STATS page on the Stats screen: win rates per ship and difficulty, streaks, damage, kills, ...")
	ctx.declare(G_STATS, {"id": STATS_PAGE, "label": "MORE STATS button on the Stats screen", "default": true})


## Extended statistics: the Stats screen shows its MORE STATS button (the statistics themselves are always
## recorded by the engine's ProfileTracker, so turning this on later shows the whole history).
func _stats_more_button(v: Variant) -> Variant:
	return true if settings.on(STATS_PAGE) else v


## hyperspace.xml switches with an equivalent here (rules/hooks.md "hyperspace.xml mapping").
func _map_hyperspace() -> void:
	var enabled := func(a: Dictionary) -> Variant: return a.get("enabled", "false") == "true"
	var only_on := func(a: Dictionary) -> Variant: return true if a.get("enabled", "false") == "true" else null
	ctx.map_hyperspace("showNumericalWeaponCooldown", "group:" + G_COOLDOWN, only_on)
	ctx.map_hyperspace("hullNumbers", "group:" + G_HEALTH, only_on)
	ctx.map_hyperspace("hullNumbers", HULL_NUMBERS, enabled)
	ctx.map_hyperspace("hullBars", "group:" + G_HEALTH,
		func(a: Dictionary) -> Variant: return true if a.get("type", "0") != "0" else null)
	ctx.map_hyperspace("hullBars", HULL_CAP, func(a: Dictionary) -> Variant: return a.get("type", "0") != "0")
	ctx.map_hyperspace("playerHpColorFix", "group:" + G_HEALTH, only_on)
	ctx.map_hyperspace("playerHpColorFix", HULL_THIRDS, enabled)


# ---------------------------------------------------------------- A1 cooldown numbers

## Seconds until `w` is charged (current charge level for multi-charge weapons), or -1 when nothing to show.
static func cooldown_left(w: WeaponState, crew_level: int) -> float:
	if w == null or not w.powered:
		return -1.0
	var mx := w.max_charge(crew_level)
	if w.charge_levels() >= 2:
		if w.charge_level >= w.charge_levels():
			return -1.0
	elif w.charge >= mx:
		return -1.0
	return maxf(mx - w.charge, 0.0)


## The text drawn above a weapon box ("" = nothing: setting off, unpowered or charged).
func cooldown_text(w: WeaponState, crew_level: int) -> String:
	if not settings.on(COOLDOWN_ON):
		return ""
	var left := cooldown_left(w, crew_level)
	if left < 0.0:
		return ""
	if String(settings.value(COOLDOWN_FORMAT)) == "whole seconds":
		return str(ceili(left))
	return "%.1f" % left


func _draw_cooldown(box: Control, w: WeaponState, crew_level: int) -> void:
	var t := cooldown_text(w, crew_level)
	if t == "" or box.get("dragged"):
		return
	# Above the panel frame, centred on the box frame (x 8..95), white small digits (font 10).
	HudDraw.text(box, 10, t, Vector2(51, -27), Color.WHITE, 1)


# ---------------------------------------------------------------- A2-A4 health bars

## "hull/max" for the hull bars ("" when the setting is off).
func hull_text(ship: ShipState) -> String:
	if not settings.on(HULL_NUMBERS):
		return ""
	return "%d/%d" % [ship.hull, ship.max_hull]


func _draw_player_hull(ci: Control, ship: ShipState) -> void:
	var t := hull_text(ship)
	if t != "":  # in the free space right of the HULL label, above the frame line, font 62
		HudDraw.text(ci, 62, t, Vector2(132, 6), HudLayout.BUTTON_ON)


func _draw_enemy_hull(ci: Control, enemy: ShipState) -> void:
	var t := hull_text(enemy)
	if t != "":  # on the TARGET header line, right-aligned to the window's inner edge
		HudDraw.text(ci, 62, t, HudLayout.ENEMY_STATUS + Vector2(258, -36), Color.WHITE, 2)


func _hull_fraction(frac: float, ship: ShipState, where: String) -> Variant:
	if where == "enemy" and settings.on(HULL_CAP) and ship.max_hull > ENEMY_BAR_SEGMENTS:
		return clampf(float(ship.hull) / ship.max_hull, 0.0, 1.0)  # HS hullBars type 2: proportional cap
	return null


func _hull_color(col: Color, ship: ShipState, where: String) -> Variant:
	if where != "player" or not settings.on(HULL_THIRDS) or ship.max_hull <= 0:
		return null
	var r := float(ship.hull) / ship.max_hull
	if r > 2.0 / 3.0:
		return HudLayout.HULL_GREEN
	return HudLayout.HULL_YELLOW if r > 1.0 / 3.0 else HudLayout.HULL_RED


# ---------------------------------------------------------------- pause on combat start

func _on_combat_started(_me: ShipState, _enemy: ShipState, combat: Combat) -> void:
	if settings.on(PAUSE_ON) and combat != null:
		combat.paused = true
	if settings.on(DRONE_AUTO) and settings.on(DRONE_AUTO_START) and _me != null and not _me.has_meta(AutoButton.META):
		set_auto(_me, true)


# ---------------------------------------------------------------- drone autodeploy

func button_enabled() -> bool:
	return settings.on(DRONE_AUTO)


func _on_hud_ready(region: String, node: Control, ship: ShipState) -> void:
	if region != "drone_panel" or node.get_node_or_null("QolDroneAuto") != null:
		return
	var b: Control = AutoButton.new()
	b.setup(ship, self, node.size.x)
	b.visible = button_enabled()
	node.add_child(b)


func set_auto(ship: ShipState, on: bool) -> void:
	ship.set_meta(AutoButton.META, on)
	for d in ship.drones:
		if d.has_meta(MANUAL_OFF):
			d.remove_meta(MANUAL_OFF)
	FtlData.play("powerUpSystem" if on else "powerDownSystem")


func auto_on(ship: ShipState) -> bool:
	return button_enabled() and bool(ship.get_meta(AutoButton.META, false))


func _on_drone_depowered(ship: ShipState, d: Drone, by_player: bool) -> void:
	if by_player and auto_on(ship):
		d.set_meta(MANUAL_OFF, true)  # the player switched it off: AUTO leaves it alone until powered again


func _on_drone_powered(_ship: ShipState, d: Drone) -> void:
	if d.has_meta(MANUAL_OFF):
		d.remove_meta(MANUAL_OFF)


func _on_sim_tick(combat: Combat, _seconds: float) -> void:
	for sp in combat.spaces:
		var ship: ShipState = sp.ship
		if ship.is_player and auto_on(ship):
			auto_deploy(ship)


## Powers every drone that can be powered right now without a refusal (no fail sound, no NOT ENOUGH POWER):
## only during a fight with a hostile, living enemy; slot order; drones the player switched off are skipped.
static func auto_deploy(ship: ShipState) -> int:
	var t := ship.opponent
	if t == null or t.is_destroyed() or not t.hostile or ship.is_destroyed():
		return 0
	var s := ship.sys("drones")
	if s == null or s.is_locked() or s.hacked:
		return 0
	var n := 0
	for d in ship.drones:
		if d.powered or d.has_meta(MANUAL_OFF) or d.rebuilding():
			continue
		if not d.deployed and (ship.drone_parts < 1 or not d.can_be_deployed()):
			continue
		if s.max_power() - DroneSystemRule.power_used(ship) < d.required_power():
			continue
		if ship.power_free() < d.required_power():
			continue
		if DroneSystemRule.power_drone(ship, d) == "ok":
			n += 1
	return n


# ---------------------------------------------------------------- start with scanners (data patch)

func _patch_scanners(text: String, rel: String) -> Variant:
	if not rel in SCANNER_FILES or not settings.on(SCANNERS_ON):
		return null
	return add_scanners(text)


## Adds <aug name="ADV_SCANNERS"/> to every <shipBlueprint name="PLAYER_SHIP_..."> that lacks it and has a free
## augment slot (comments are stripped first so commented-out blueprints are not touched twice).
static func add_scanners(text: String) -> String:
	var src := FtlData.strip_comments(text)
	var re := RegEx.create_from_string("(<shipBlueprint\\s+[^>]*name=\"PLAYER_SHIP_[^\"]*\"[^>]*>)([\\s\\S]*?)(</shipBlueprint>)")
	var out := ""
	var last := 0
	for m in re.search_all(src):
		var body := m.get_string(2)
		out += src.substr(last, m.get_start() - last) + m.get_string(1)
		var augs := RegEx.create_from_string("<aug\\s+name=").search_all(body).size()
		if not body.contains("\"" + SCANNERS_AUG + "\"") and augs < MAX_AUGMENTS:
			body += "\t<aug name=\"%s\"/>\n" % SCANNERS_AUG
		out += body + m.get_string(3)
		last = m.get_end()
	return out + src.substr(last)


func _on_settings_changed(id: String, _value: Variant) -> void:
	if id == SCANNERS_ON or id == "group:" + G_SCANNERS:
		FtlData.clear_data_cache()  # ships created from now on read the re-patched blueprints


# ---------------------------------------------------------------- Better info (A6 / A7)

var texts := {}


func _load_texts() -> void:
	var f := FileAccess.open(ctx.dir.path_join("text_qol.xml"), FileAccess.READ)
	if f == null:
		return
	for m in RegEx.create_from_string("<text name=\"([^\"]+)\">([^<]*)</text>").search_all(f.get_as_text()):
		texts[m.get_string(1)] = m.get_string(2)


func qt(id: String, a: Variant = "", b: Variant = "") -> String:
	return String(texts.get(id, id)).replace("\\1", str(a)).replace("\\2", str(b))


## The numeric stat groups of a weapon blueprint (MV weapon tooltip / Stats block, screenshots 70 / 71): power and
## charge time (+ chain lines, missiles); shots and charge levels; damage lines; chances in % (rating × 10).
func weapon_stat_groups(bp: Dictionary, ae := true) -> Array:
	var T := TooltipText
	var ty := String(bp.get("type", "LASER")).strip_edges()
	var g1 := [T.f("required_power", int(bp.get("power", 0))), T.f("charge_time",
		ItemInfoBox.fmt_float(float(bp.get("cooldown", 0.0))))]
	var boost: Dictionary = bp.get("boost", {})
	if int(boost.get("count", 0)) > 1:
		var total := float(boost.count) * float(boost.amount)
		if String(boost.get("type", "")).strip_edges() == "damage":
			var base := int(bp.ion) if int(bp.get("ion", 0)) > 0 else int(bp.damage)
			g1 += [T.t("boost_power_damage"), T.f("damage_cap", ItemInfoBox.fmt_float(base + total))]
		else:
			g1 += [T.t("boost_power_speed"), T.f("speed_cap", ItemInfoBox.fmt_float(float(bp.cooldown) - total))]
		g1.append(qt("qol_chain_volleys", int(boost.count)))  # ours: volleys until the cap (boostLevel +1 per volley)
	if int(bp.get("missiles", 0)) > 0:
		g1.append(T.t("requires_missiles"))
	var shots := ItemInfoBox.mini_count(bp) if ty == "BURST" else int(bp.get("shots", 1))
	var g2 := [] if ty == "BEAM" else [T.f("shots", shots)]
	if int(bp.get("charge_levels", 1)) > 1:
		g2.append(T.f("charge", int(bp.charge_levels)))
	var g3 := [qt("qol_room_damage" if ty == "BEAM" else "qol_hull_damage", int(bp.get("damage", 0)))]
	if int(bp.get("ion", 0)) != 0:
		g3.append(qt("qol_ion_damage", int(bp.ion)))
	if int(bp.get("sys_damage", 0)) != 0:
		g3.append(qt("qol_system_damage", int(bp.sys_damage)))
	if int(bp.get("pers_damage", 0)) != 0:
		g3.append(qt("qol_crew_damage", 15 * int(bp.pers_damage)))
	var sp := int(bp.get("sp", 0))
	if sp != 0:
		g3.append(T.f("shield_piercing", sp))
	if int(roundf(float(bp.get("stun", 0.0)))) != 0:
		g3.append(qt("qol_stun", int(roundf(float(bp.stun)))))
	if int(bp.get("hull_bust", 0)) != 0:
		g3.append(T.t("double_damage"))
	var g4 := []
	if int(bp.get("fire_chance", 0)) > 0:
		g4.append(qt("qol_fire_chance", 10 * int(bp.fire_chance)))
	if int(bp.get("breach_chance", 0)) > 0:
		g4.append(qt("qol_breach_chance", 10 * int(bp.breach_chance)))
	if int(bp.get("stun_chance", 0)) > 0 and ae:
		g4.append(qt("qol_stun_chance", 10 * int(bp.stun_chance)))
	return [g1, g2, g3, g4].filter(func(g): return not g.is_empty())


## Rule `tooltip.weapon` (A6): groups joined by a blank line; vanilla when the item (or the group) is off.
func _weapon_tooltip(default: Callable, bp: Dictionary, c := {}) -> String:
	if not settings.on(INFO_WEAPON_TIP) or bp.is_empty():
		return default.call(bp, c)
	var parts := PackedStringArray()
	for g in weapon_stat_groups(bp, TooltipText.ae):
		parts.append("\n".join(PackedStringArray(g)))
	return "\n\n".join(parts)


## Filter `infobox_content` (A6 / A7 info box): weapons get "Stats:" + the groups; weapons, drones and augments get the
## Default / Selling price line (sell price from the context when known, else half the cost).
func _infobox_content(d: Dictionary, kind: String, nm: String, c: Dictionary) -> Variant:
	if not settings.on(INFO_PANEL) or not kind in ["weapon", "drone", "augment"]:
		return null
	var out := d.duplicate(true)
	if kind == "weapon":
		var lines := [qt("qol_stats")]
		var groups := weapon_stat_groups(FtlData.weapon_blueprint(nm), bool(c.get("ae", true)))
		for i in groups.size():
			if i > 0:
				lines.append("")
			lines += groups[i]
		out.stats = lines
	var cost := int(FtlData.item_info(kind, nm).get("cost", 0))
	var sell: int = int(c.get("sell_price", cost / 2))
	out.price = qt("qol_price", cost, sell)
	return out
