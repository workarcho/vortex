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
## - Game speed: − [1x] + buttons under the scrap counter (and + / − keys) for 0.5x .. 3x. Engine.time_scale with
##   the physics tick rate raised by the same factor, so every fixed simulation step keeps its vanilla length (no
##   GameClock.MAX_FACTOR clipping) and timers, AI, projectiles and animations all speed up together. Applied only
##   while the world runs (combat not paused, no map / store / event box open); 1x when the group is turned off.
## - Card drag & reorder: on the ship screen's equipment tab a weapon / drone dragged from its slot is carried as the
##   whole card (box, icon and label); over another slot of its row the other cards slide aside to preview the new
##   order, and the drop reorders like a list (insert, not swap) through vanilla adjacent swaps (EQUIP_MOVE), so
##   power, targets, autofire and mounts follow exactly as with vanilla swaps. Cargo / augments stay vanilla.
##   Hooks `equipment_move`, `equipment_box_draw`, `equipment_draw_dragged`.

const AutoButton := preload("auto_drone_button.gd")
const SpeedControl := preload("speed_control.gd")

const G_COOLDOWN := "qol_cooldown"
const G_HEALTH := "qol_health"
const G_PAUSE := "qol_pause"
const G_DRONES := "qol_drones"
const G_SCANNERS := "qol_scanners"
const G_INFO := "qol_info"
const G_STATS := "qol_stats"
const G_SPEED := "qol_speed"
const G_CARDS := "qol_cards"

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
const SPEED_BUTTONS := "qol.speed.buttons"
const SPEED_KEYS := "qol.speed.hotkeys"
const CARDS_WHOLE := "qol.cards.whole_card"
const CARDS_REORDER := "qol.cards.reorder"
const CARDS_SLIDE := "qol.cards.slide"
## Slide animation: exponential approach, 1 - e^(-rate·dt) of the remaining distance per frame (~0.15 s to settle).
const CARD_SLIDE_RATE := 25.0
const SPEED_STEPS := [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]
const SPEED_NORMAL := 2  # index of 1x

const SCANNERS_AUG := "ADV_SCANNERS"  # blueprints.xml <augBlueprint name="ADV_SCANNERS"> (Long-Ranged Scanners)
## dlcBlueprintsOverwrite.xml holds the type C player ships (PLAYER_SHIP_*_3, e.g. the Rock C): patched too.
const SCANNER_FILES := ["data/blueprints.xml", "data/dlcBlueprints.xml", "data/dlcBlueprintsOverwrite.xml"]
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
	c.add_filter(&"input_event", _speed_input)
	c.add_filter(&"equipment_move", _equipment_move)
	c.add_filter(&"equipment_box_draw", _equipment_box_draw)
	c.add_filter(&"equipment_draw_dragged", _equipment_draw_dragged)
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
	ctx.declare_group(G_SPEED, "Game speed", "Speed the game up or slow it down (0.5x to 3x).")
	ctx.declare(G_SPEED, {"id": SPEED_BUTTONS, "label": "- / + buttons under the scrap counter", "default": true})
	ctx.declare(G_SPEED, {"id": SPEED_KEYS, "label": "Keys: + / - (also on the numpad)", "default": true})
	ctx.declare_group(G_CARDS, "Card drag & reorder",
		"Equipment tab: drag whole weapon / drone cards and reorder them like a list, with a sliding preview.")
	ctx.declare(G_CARDS, {"id": CARDS_WHOLE, "label": "Drag the whole card (box, icon and label)", "default": true})
	ctx.declare(G_CARDS, {"id": CARDS_REORDER, "label": "Reorder like a list (insert instead of swap)",
		"default": true})
	ctx.declare(G_CARDS, {"id": CARDS_SLIDE, "label": "Slide animation of the other cards", "default": true})


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
	if region == "hud":
		_add_speed_control(node)
		return
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
	if id == "group:" + G_SPEED and not settings.group_enabled(G_SPEED):
		speed_index = SPEED_NORMAL  # turned off: back to 1x at once
		restore_speed()


# ---------------------------------------------------------------- game speed

var speed_index := SPEED_NORMAL  # this session's choice (kept across jumps; not saved)
var _speed_applied := false  # Engine.time_scale / physics ticks are ours (restore_speed puts them back)
var _base_ticks := 60
var _base_steps := 8
var _speed_controls: Array[Control] = []


func speed_buttons_enabled() -> bool:
	return settings.on(SPEED_BUTTONS)


## The chosen multiplier (1x while the group is off).
func speed() -> float:
	return float(SPEED_STEPS[speed_index]) if settings.group_enabled(G_SPEED) else 1.0


## One step faster (+1) or slower (-1); false at the ends or with the group off.
func speed_step(d: int) -> bool:
	if not settings.group_enabled(G_SPEED):
		return false
	var i := clampi(speed_index + d, 0, SPEED_STEPS.size() - 1)
	if i == speed_index:
		return false
	speed_index = i
	return true


## "0.5x", "1x", "1.25x" ...
static func speed_label(m: float) -> String:
	var t := "%.2f" % m
	t = t.rstrip("0").rstrip(".")
	return t + "x"


## Every frame (SpeedControl._process): the chosen speed while the world runs, 1x otherwise (paused, a map /
## store / event box open), so menus and the pause screen keep their normal pace.
func apply_speed(running: bool) -> void:
	var m := speed() if running else 1.0
	if is_equal_approx(m, 1.0):
		restore_speed()
		return
	if not _speed_applied:
		_base_ticks = Engine.physics_ticks_per_second
		_base_steps = Engine.max_physics_steps_per_frame
		_speed_applied = true
	# Physics steps keep the 1x delta above 1x (more steps per second); below 1x each step is shorter.
	var k := maxf(m, 1.0)
	Engine.physics_ticks_per_second = roundi(_base_ticks * k)
	Engine.max_physics_steps_per_frame = ceili(_base_steps * k)
	Engine.time_scale = m


func restore_speed() -> void:
	if not _speed_applied:
		return
	_speed_applied = false
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = _base_ticks
	Engine.max_physics_steps_per_frame = _base_steps


## hud_ready "hud" (main.gd hud_root): the control goes on the ShipStatusHud (scrap counter, touch scale).
func _add_speed_control(hud_root: Control) -> void:
	var status: Control = null
	for ch in hud_root.get_children():
		if ch is ShipStatusHud:
			status = ch
	if status == null or status.get_node_or_null("QolGameSpeed") != null:
		return
	var main: Node = hud_root.get_parent().get_parent() if hud_root.get_parent() != null else null
	var sc: Control = SpeedControl.new()
	sc.setup(self, main, status)
	sc.visible = speed_buttons_enabled()
	status.add_child(sc)
	sc.tree_exited.connect(func(): _speed_controls.erase(sc))
	_speed_controls.append(sc)


## input_event filter: clicks / taps on the speed buttons, and the + / - keys.
func _speed_input(e: InputEvent, _main: Node) -> Variant:
	if not settings.group_enabled(G_SPEED):
		return null
	for sc in _speed_controls:
		if is_instance_valid(sc) and sc.handle(e):
			return Hooks.CANCEL
	if e is InputEventKey and e.pressed and not e.echo and settings.on(SPEED_KEYS) and not _speed_controls.is_empty():
		var k := (e as InputEventKey).keycode
		var d := 1 if k in [KEY_EQUAL, KEY_PLUS, KEY_KP_ADD] else (-1 if k in [KEY_MINUS, KEY_KP_SUBTRACT] else 0)
		if d != 0:
			if speed_step(d):
				FtlData.play("powerUpSystem" if d > 0 else "powerDownSystem")
			return Hooks.CANCEL
	return null


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
			g1 += [T.t("boost_power_damage"), qt("qol_damage_cap", ItemInfoBox.fmt_float(base + total), int(boost.count))]
		else:
			g1 += [T.t("boost_power_speed"),
				qt("qol_speed_cap", ItemInfoBox.fmt_float(float(bp.cooldown) - total), int(boost.count))]
		# ours: the cap line also gives the volleys needed to reach it (boostLevel +1 per volley)
	if int(bp.get("missiles", 0)) > 0:
		g1.append(T.t("requires_missiles"))
	var shots := ItemInfoBox.mini_count(bp) if ty == "BURST" else int(bp.get("shots", 1))
	var g2 := [] if ty == "BEAM" else [T.f("shots", shots)]
	if int(bp.get("charge_levels", 1)) > 1:
		g2.append(T.f("charge", int(bp.charge_levels)))
	var g3 := [qt("qol_room_damage" if ty == "BEAM" else "qol_hull_damage", int(bp.get("damage", 0)))]
	if int(bp.get("ion", 0)) != 0:
		g3.append(qt("qol_ion_damage", int(bp.ion)))
	# Negative system / crew damage repairs / heals (BOMB_HEAL_SYSTEM, BOMB_HEAL): shown as such, as a positive
	# amount. Vanilla (WeaponBlueprint::GetDescription) lists crew damage only when > 0 and has no heal line.
	var sysd := int(bp.get("sys_damage", 0))
	if sysd != 0:
		g3.append(qt("qol_system_damage", sysd) if sysd > 0 else qt("qol_system_repair", -sysd))
	var persd := int(bp.get("pers_damage", 0))
	if persd != 0:
		g3.append(qt("qol_crew_damage", 15 * persd) if persd > 0 else qt("qol_crew_heal", -15 * persd))
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


# ---------------------------------------------------------------- card drag & reorder (equipment tab)

var _card_anim := {}  # EquipmentView instance id -> {&"src": dragged box, box: [current top-left, last usec]}


## Weapon / drone slot boxes (the rows that reorder); cargo, augment and over boxes stay vanilla.
static func is_row_box(b: Vector2i) -> bool:
	return b.x == ShipInventory.WEAPON or b.x == ShipInventory.DRONE


## Items in the row of `b` (slot i holds item i; the lists are compact).
static func row_items(view: EquipmentView, b: Vector2i) -> int:
	return view.run.ship.weapons.size() if b.x == ShipInventory.WEAPON else view.run.ship.drones.size()


## Insert target of dragging slot `s` onto slot `t` of the same row (-1 = no reorder): an empty slot past the
## last item means the last position (as vanilla, which appends there).
static func insert_index(view: EquipmentView, s: Vector2i, t: Vector2i) -> int:
	if not is_row_box(s) or t.x != s.x or t.y < 0:
		return -1
	var n := row_items(view, s)
	if s.y >= n:
		return -1
	return mini(t.y, n - 1)


## Order after moving slot `s` to slot `t` (list insert): [old slot index per new slot], e.g. 4 items, s 2 -> t 1
## gives [0, 2, 1, 3]. Empty slots past the items keep their place.
static func reorder_preview(n_slots: int, n_items: int, s: int, t: int) -> Array:
	var order := range(n_items)
	if s >= 0 and s < n_items and t >= 0:
		order.remove_at(s)
		order.insert(mini(t, n_items - 1), s)
	for i in range(n_items, n_slots):
		order.append(i)
	return order


## Slot where box `b` is drawn while `s` hovers slot `t` (its own slot outside a reorder preview).
static func preview_slot(view: EquipmentView, b: Vector2i, s: Vector2i, t: Vector2i) -> int:
	var dst := insert_index(view, s, t)
	if dst < 0 or b.x != s.x:
		return b.y
	var n_slots := view.run.ship.weapon_slots if b.x == ShipInventory.WEAPON else view.run.ship.drone_slots
	return reorder_preview(n_slots, row_items(view, s), s.y, t.y).find(b.y)


## Drop: a weapon / drone moved onto another filled slot of its row is inserted there by adjacent vanilla swaps
## (RunIntent.EQUIP_MOVE, each one exactly the vanilla swap: power, targets, autofire and mounts follow).
func _equipment_move(done: Variant, view: EquipmentView, run: RunState, s: Vector2i, t: Vector2i) -> Variant:
	if done == true or not settings.on(CARDS_REORDER):
		return null
	var dst := insert_index(view, s, t)
	if dst < 0 or t.y >= row_items(view, s) or dst == s.y:
		return null  # an empty slot: vanilla moves the item to the end of the list, the same as an insert
	var step := 1 if dst > s.y else -1
	var i := s.y
	while i != dst:
		if not run.apply(ShipManagement.make(RunIntent.EQUIP_MOVE, {"src": Vector2i(s.x, i),
				"dst": Vector2i(s.x, i + step)})):
			break
		i += step
	return true


## Reorder preview: the boxes of the dragged item's row are drawn at their preview slots, sliding there; the source
## (drawn empty: the landing gap) glows, the shifted cards do not.
func _equipment_box_draw(v: Dictionary, view: EquipmentView, b: Vector2i, hover: Vector2i, drag: bool) -> Variant:
	var key := view.get_instance_id()
	if not drag or not settings.on(CARDS_REORDER):
		if _card_anim.has(key):
			_card_anim.erase(key)  # drop / cancel: snap (the boxes hold their new items now)
		return null
	var s := view.drag_source()
	if not is_row_box(s) or b.x != s.x:
		return null
	var target := view.box_rect(Vector2i(b.x, preview_slot(view, b, s, hover))).position
	var out := v.duplicate()
	if insert_index(view, s, hover) >= 0:
		out.look = view.box_look(b, s if b == s else ShipInventory.NONE, true)
	var anim: Dictionary = _card_anim.get_or_add(key, {})
	if anim.get(&"src", s) != s:
		anim.clear()  # another drag started without an idle frame in between: no stale positions
	anim[&"src"] = s
	var now := Time.get_ticks_usec()
	var cur: Vector2 = target
	if settings.on(CARDS_SLIDE) and anim.has(b):
		var dt := clampf((now - int(anim[b][1])) / 1000000.0, 0.0, 0.1)
		cur = (anim[b][0] as Vector2).lerp(target, 1.0 - exp(-CARD_SLIDE_RATE * dt))
		if cur.distance_to(target) < 0.5:
			cur = target
	elif not anim.has(b):
		cur = v.pos  # first frame of the drag: from the box's own slot
	anim[b] = [cur, now]
	out.pos = cur
	return out


## The card position of box `b` drawn last by the reorder preview (tests; null = not in a preview).
func card_pos(view: EquipmentView, b: Vector2i) -> Variant:
	var anim: Dictionary = _card_anim.get(view.get_instance_id(), {})
	return anim[b][0] if anim.has(b) else null


## The dragged weapon / drone is carried as its whole card (selected box + icon + label), held at the grab point.
func _equipment_draw_dragged(_v: Variant, view: EquipmentView, s: Vector2i, mouse: Vector2, grab: Vector2) -> Variant:
	if not settings.on(CARDS_WHOLE) or not is_row_box(s):
		return null
	var look := view.box_look(s, s, false)  # the idle hovered look: `selected` with its item
	look.overlay = Color(1, 1, 1, 0)
	view.draw_box_at(s, mouse - grab, look, false)
	view.drawn_dragged = view.inv().item_at(view.run, s)
	view.drawn_dragged["card"] = true
	return Hooks.CANCEL
