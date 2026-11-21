class_name TooltipText
extends RefCounted
## Tooltip content builders (rules/tooltips.md §4–§5): pure functions over game state, unit-testable. Every public
## builder runs through the replaceable rule `tooltip.<kind>` (rules/hooks.md: `Hooks.rule(&"tooltip.<kind>",
## default, args...)`), so a mod can replace one whole builder; the TooltipService then runs the `tooltip` filter on
## the final text. The `*_vanilla` functions are the defaults (FTL 1.6.9 line by line).
##
## Hotkey names: the bindings this engine implements (main.gd `_hotkey`, CrewControl). FTL binds system power keys
## too; we have none, so system tooltips have no hotkey block (exe: skipped when both keys are unbound) and texts
## with a "\1" hotkey line drop that line when the key is unbound [ours].

const KEYS := {"weapon1": "1", "weapon2": "2", "weapon3": "3", "weapon4": "4", "drone1": "5", "drone2": "6",
	"drone3": "7", "crew1": "F1", "crew2": "F2", "crew3": "F3", "crew4": "F4", "crew5": "F5", "crew6": "F6",
	"crew7": "F7", "crew8": "F8", "open": "Z", "close": "X", "autofire": "V", "force_autofire": "Shift",
	"ship_info": "U", "save_stations": "/", "ret_stations": "Enter", "lockdown": "P", "jump": "J"}
const SYSTEM_NAMES := ["shields", "engines", "oxygen", "weapons", "drones", "medbay", "pilot", "sensors", "doors",
	"teleporter", "cloaking", "artillery", "battery", "clonebay", "mind", "hacking"]
## GetSkillFromSystem: system -> skill index (0 piloting, 1 engines, 2 shields, 3 weapons).
const SYSTEM_SKILL := {"pilot": 0, "engines": 1, "shields": 2, "weapons": 3}
const SKILL_IDS := ["pilot", "engines", "shields", "weapons", "repair", "combat"]  # = CrewMember.SKILLS
const ENGINE_EVADE := [5, 10, 15, 20, 25, 28, 31, 35]
const CLONE_TIME := [3.0, 12.0, 9.0, 7.0]
const CLONE_HEALTH := [0, 8, 16, 25]
const HACK_TIME := [4, 4, 7, 10]  # HACKING_EFFECT_TIMER[level + 1]
const NEEDS_NO_POWER := ["pilot", "sensors", "doors", "battery"]  # subsystems (bNeedsPower false)

static var ae := true  # Advanced Edition content (stun chance in weapon texts); main.gd sets it from the run
static var keys := KEYS.duplicate()


# ---------------------------------------------------------------- text helpers

static func t(id: String) -> String:
	return FtlData.tr_id(id).replace("\\n", "\n")


## TextLibrary::FormatText: \1 / \2 replaced.
static func f(id: String, a: Variant = "", b: Variant = "") -> String:
	return t(id).replace("\\1", str(a)).replace("\\2", str(b))


static func key(binding: String) -> String:
	return String(keys.get(binding, ""))


## Text with \1 = the key name of `binding`; when unbound, the line holding \1 is dropped [ours].
static func with_key(id: String, binding: String, binding2 := "") -> String:
	var s := t(id)
	var k := key(binding)
	if k == "":
		var out := PackedStringArray()
		for l in s.split("\n"):
			if not l.contains("\\1"):
				out.append(l)
		s = "\n".join(out).strip_edges(false, true)
	s = s.replace("\\1", k)
	if binding2 != "":
		s = s.replace("\\2", key(binding2))
	return s


## C++ ostream << double (6 significant digits, no trailing zeros).
static func num(v: float) -> String:
	return ItemInfoBox.fmt_float(v)


## Hooks.rule(&"tooltip.<kind>", default, args...).
static func rule(kind: String, default: Callable, args: Array) -> String:
	var r: Variant = Hooks.callv("rule", [StringName("tooltip." + kind), default] + args)
	return "" if r == null else String(r)


## A simple text-id tooltip (status readouts, buttons, hazards, menus) through rule `tooltip.<kind>`:
## the default returns the formatted text of `id`; ctx may hold `key` (binding for \1) and `key2`.
static func simple(kind: String, id: String, ctx := {}) -> String:
	return rule(kind, simple_vanilla, [id, ctx])


static func simple_vanilla(id: String, ctx := {}) -> String:
	if ctx.has("key"):
		return with_key(id, String(ctx.key), String(ctx.get("key2", "")))
	if ctx.has("arg"):
		return f(id, ctx.arg, ctx.get("arg2", ""))
	return t(id)


# ---------------------------------------------------------------- systems (§5.1)

static func system_index(sys_id: String) -> int:
	return SYSTEM_NAMES.find(sys_id)


## ShipSystem::GetLevelDescription(sys, level, tooltip): level is 0-based (power − 1); < 0 = the OFF text.
static func level_description(sys_id: String, level: int, tooltip := true) -> String:
	var s := sys_id
	if s == "sensors" and level >= 4:
		s = "cloaking"  # exe quirk: sensors level index >= 4 falls into the cloak case
	if level < 0:
		match s:
			"shields":
				return t("shields_off")
			"engines":
				return t("engine_off")
			"oxygen", "weapons", "drones", "medbay", "pilot", "sensors", "doors", "artillery":
				return t(s + "_off")
			"clonebay":
				return t("clone_off")
		return ""
	match s:
		"shields":
			return t("shields_%d" % (level >> 1)) if level % 2 == 1 else ""
		"engines":
			return f("engine", ENGINE_EVADE[level] if level <= 7 else 0, num(1.0 + 0.25 * level))
		"oxygen":
			return f("oxygen_on", 1 if level == 0 else int(level * 3.0))
		"weapons", "drones":
			return t("system_power")
		"medbay":
			return f("medbay_healing", ["1", "1.5", "3"][level] if level <= 2 else "1")
		"pilot":
			return t("pilot_%d" % (level + 1))
		"sensors":
			return t("sensor_%d" % (level + 1))
		"doors":
			return t("door_%d" % (level + 1))
		"teleporter":
			return f("teleporter_on", 15 if level == 1 else (10 if level == 2 else 20))
		"cloaking":
			return f("cloak", 5 * level + 5)
		"artillery":
			return t("artillery_%d" % (level + 1))
		"battery":
			return f("battery_power", 2 * level + 2)
		"clonebay":
			var i := clampi(level + 1, 0, 3)
			if tooltip:
				return f("clone", num(CLONE_TIME[i]))
			return f("clone_full", num(CLONE_TIME[i]), CLONE_HEALTH[i])
		"mind":
			return t("mind_%d" % (level + 1))
		"hacking":
			return f("hacking_duration", HACK_TIME[clampi(level + 1, 0, 3)])
	return ""


## ShipSystem::GetMannedDescription(skill, level).
static func manned_description(skill: int, lvl: int) -> String:
	var b := EvasionRule.skill_bonus(skill, lvl)
	match skill:
		0:
			return f("pilot_skill", int(b))
		1:
			return f("engine_skill", int(b))
		2:
			return f("shield_skill", roundi((b - 1.0) * 100.0))
		3:
			return f("weapon_skill", roundi((1.0 - b) * 100.0))
	return ""


## SystemBox::GenerateTooltip for a player system box.
static func system(ship: ShipState, sys_id: String) -> String:
	return rule("system", system_vanilla, [ship, sys_id])


static func system_vanilla(ship: ShipState, sys_id: String) -> String:
	var s := ship.sys(sys_id) if ship else null
	if s == null:
		return ""
	var base := system_override(ship, sys_id)
	if base == "":
		base = t("tooltip_" + sys_id)
	var body := ""
	var e := s.effective_power()
	if sys_id == "clonebay":
		body += " \n\n" + f("clonebay_health", CLONE_HEALTH[clampi(s.max_power(), 0, 3)])
		if s.damage > 0:
			body += t("clonebay_damaged")
	if sys_id != "weapons" and sys_id != "drones":
		var d := level_description(sys_id, e - 1, true)
		if s.hack_effect() >= 2:
			body += " \n\n" + t("hack_%s_player" % sys_id)
		elif e - 1 < 0 and d != "":
			body += " \n\n" + d
		elif d != "":
			body += " \n\n" + f("level", e, d)
	var manned := ship.crew_level_in(sys_id)
	if manned > 0:
		if sys_id == "sensors" or sys_id == "doors":
			body += " \n\n" + f("manning_bonus", t("subsystem_manned"))
		else:
			body += " \n\n" + f("manning_bonus", manned_description(int(SYSTEM_SKILL.get(sys_id, -1)), manned))
	body += " \n\n" + t("status") + "\n"
	var bullets := PackedStringArray()
	var needs_power := not NEEDS_NO_POWER.has(sys_id)
	var temp := s.power_loss != 0
	if not temp and e >= s.get_level():
		bullets.append(t("full_powered" if needs_power else "full_functional"))
	elif e >= 1:
		bullets.append(t("partial_powered" if needs_power else "partial_functional"))
	elif needs_power and e <= 0:
		bullets.append(t("unpowered"))
	if ship.is_boostable(sys_id) and not SystemPowerColumn.blocked_boosted(ship, s) and manned == 0:
		bullets.append(t("unmanned"))
	if int(s.get_meta("bonus_power", 0)) > 0:
		bullets.append(t({"weapons": "zoltan_rearrange_weapon", "drones": "zoltan_rearrange_drone"}.get(sys_id,
			"zoltan")))
	if s.damage > 0:
		bullets.append(t("destroyed" if s.damage >= s.get_level() else "damaged"))
	if temp:
		bullets.append(t("temp_disabled"))
	if s.ion != 0:
		bullets.append(t("ioned"))
	if ship.fires.has(s.room) and not (ship.fires[s.room] as Dictionary).is_empty():
		bullets.append(t("on_fire"))
	if s.sabotaged():
		bullets.append(t("sabotaged"))
	if s.hack_effect() > 0:
		bullets.append(t("hacked"))
	for b in bullets:
		body += f("bullet", b) + " \n"
	var n := "medbay" if sys_id == "clonebay" else sys_id
	if key(n) != "" or key("un_" + n) != "":
		body += "\n"
		if key(n) != "":
			body += f("add_power", key(n)) + " \n"
		if key("un_" + n) == "":
			body += f("remove_power_alt", key(n)) + " \n"
		else:
			body += f("remove_power", key("un_" + n)) + " \n"
	return base + body.substr(0, maxi(body.length() - 1, 0))


## GetOverrideTooltip: artillery = the artillery weapon's blueprint tooltip text.
static func system_override(ship: ShipState, sys_id: String) -> String:
	if sys_id != "artillery":
		return ""
	for w: WeaponState in ship.artillery:
		var tt := String(w.bp.get("tooltip_text", ""))
		if tt != "":
			return tt
	return ""


## Enemy system box (target window): tooltip_<name>_enemy, instant.
static func system_enemy(sys_id: String) -> String:
	return rule("system_enemy", func(id: String) -> String: return t("tooltip_%s_enemy" % id), [sys_id])


# ---------------------------------------------------------------- weapons / drones (§5.2, §5.3)

const TYPE_IDS := {"LASER": "type_laser", "MISSILES": "type_missile", "BEAM": "type_beam", "BOMB": "type_bomb",
	"BURST": "type_burst"}


## WeaponBlueprint::GetDescription(tooltip = true). `bp` = FtlData.weapon_blueprint dictionary.
static func weapon(bp: Dictionary, ctx := {}) -> String:
	return rule("weapon", weapon_vanilla, [bp, ctx])


static func weapon_vanilla(bp: Dictionary, _ctx := {}) -> String:
	if bp.is_empty():
		return ""
	var ty := String(bp.get("type", "LASER")).strip_edges()
	var tid: String = TYPE_IDS.get(ty, "type_laser")
	if ty == "LASER" and int(bp.get("ion", 0)) > 0:
		tid = "type_ion"
	if ty == "MISSILES" and int(bp.get("missiles", 0)) <= 0:
		tid = "type_crystal"
	var boost: Dictionary = bp.get("boost", {})
	var charge := int(bp.get("charge_levels", 1)) > 1
	var chain := not boost.is_empty() and int(boost.get("count", 0)) > 0
	var tname := t(tid)
	if charge and FtlData.tr_id(tid + "_charge") != tid + "_charge":
		tname = t(tid + "_charge")
	elif chain and FtlData.tr_id(tid + "_chain") != tid + "_chain":
		tname = t(tid + "_chain")
	if String(bp.get("flavor_type", "")) != "":
		tname = String(bp.flavor_type) + "\n" + tname
	var effects := ""
	if int(bp.get("missiles", 0)) > 0:
		effects += t("type_missile_effect") + " \n"
	if int(bp.get("ion", 0)) > 0:
		effects += t("type_ion_effect") + " \n"
	if charge:
		effects += t("type_charge_effect") + " \n"
	if chain:
		effects += t("type_chain_effect") + " \n"
	var s := f("type_desc", tname, effects) + " \n"
	if int(boost.get("count", 0)) >= 2:
		var total := float(boost.count) * float(boost.amount)
		if String(boost.get("type", "")).strip_edges() == "damage":
			var base := int(bp.ion) if int(bp.get("ion", 0)) > 0 else int(bp.damage)
			s += t("boost_power_damage") + " \n" + f("damage_cap", num(base + total)) + " \n"
		else:
			s += t("boost_power_speed") + " \n" + f("speed_cap", num(float(bp.cooldown) - total)) + " \n"
	var shots := int(bp.get("shots", 1))
	if ty == "BURST":
		shots = ItemInfoBox.mini_count(bp)
	if ty == "LASER" or ty == "BURST" or (ty == "MISSILES" and shots > 1):
		if shots > 1 or ty == "LASER":
			s += f("shots", shots) + " \n"
	if charge:
		s += f("charge", int(bp.charge_levels)) + " \n"
	s += f("damage_room" if ty == "BEAM" else "damage_shot", int(bp.get("damage", 0))) + " \n"
	var sp := int(bp.get("sp", 0))
	if sp != 0 and sp != 5:
		s += f("shield_piercing", sp) + " \n"
	var chances := PackedStringArray()
	if int(bp.get("breach_chance", 0)) > 0:
		chances.append(t("chance_of_breach"))
	if int(bp.get("fire_chance", 0)) > 0:
		chances.append(t("chance_of_fire"))
	if int(bp.get("stun_chance", 0)) > 0 and ae:
		chances.append(t("chance_of_stun"))
	if not chances.is_empty():
		s += f("chance_of", t("chance_of_separator").join(chances)) + " \n"
	if int(bp.get("ion", 0)) != 0:
		s += f("ion_damage", int(bp.ion)) + " \n"
	if int(roundf(float(bp.get("stun", 0.0)))) != 0:
		s += f("stun_damage", int(roundf(float(bp.stun)))) + " \n"
	if int(bp.get("pers_damage", 0)) > 0:
		s += f("personnel_damage", 15 * int(bp.pers_damage)) + " \n"
	if int(bp.get("sys_damage", 0)) != 0:
		s += f("system_damage", int(bp.sys_damage)) + " \n"
	if int(bp.get("hull_bust", 0)) != 0:
		s += t("double_damage") + " \n"
	return s


## Weapon box hover (ArmamentControl::OnLoop): the rule's text + " \n\n" hotkey + " \n" rearrange (box lines are
## never part of the rule). The description's last " \n" is dropped first [measured: screenshot 57 shows one blank
## line before "Hotkey"].
static func weapon_box(w: WeaponState, slot: int) -> String:
	if w == null:
		return ""
	var d := weapon(w.bp, {"weapon": w, "slot": slot})
	return box_lines(d, "weapon%d" % (slot + 1))


static func box_lines(desc: String, binding: String) -> String:
	if desc == "":
		return ""
	var d := desc
	if d.ends_with(" \n"):
		d = d.substr(0, d.length() - 2)
	var out := d
	if key(binding) != "":
		out += " \n\n" + f("hotkey", key(binding))
	return out + " \n" + t("rearrange")


## DroneBox::GenerateTooltip: blueprint description + " \n\n" + state line.
static func drone(d: Drone, ctx := {}) -> String:
	return rule("drone", drone_vanilla, [d, ctx])


static func drone_vanilla(d: Drone, _ctx := {}) -> String:
	if d == null:
		return ""
	var info := FtlData.item_info("drone", String(d.bp.get("name", "")))
	var s := String(info.get("desc", ""))
	var state := "powered_deployed"
	if d.rebuilding():
		state = "rebuilding"
	elif not d.deployed:
		state = "undeployed"
	elif not d.powered:
		state = "unpowered_deployed"
	return s + " \n\n" + t(state)


static func drone_box(d: Drone, slot: int) -> String:
	if d == null:
		return ""
	var s := drone(d, {"slot": slot})
	if key("drone%d" % (slot + 1)) != "":
		s += " \n\n" + f("hotkey", key("drone%d" % (slot + 1)))
	return s + " \n" + t("rearrange")


## Space drone under the cursor (CombatControl::OnRenderCombat; Drone::GetTooltip per class).
static func space_drone(d: Drone, friendly: bool) -> String:
	return rule("space_drone", space_drone_vanilla, [d, friendly])


static func space_drone_vanilla(d: Drone, friendly: bool) -> String:
	var side := "friendly" if friendly else "enemy"
	match String(d.bp.get("type", "")):
		"COMBAT":
			return t("combat_" + side)
		"DEFENSE":
			var tt := int(d.bp.get("target_type", 1))
			return t(("defense_2_" if tt == 4 else ("anti_combat_" if tt == 3 else "defense_")) + side)
		"HACKING":
			return t("hacking_tooltip") if d.deployed and not d.dead else ""
		"SHIP_REPAIR":
			return t("repair_tooltip")
		"BOARDER":
			return t("boarding_tooltip")
		"SHIELD":
			return t("shield_tooltip")
	return ""


# ---------------------------------------------------------------- crew (§5.4, §5.5)

## CrewMember::GetSkillProgress: (xp − half if xp >= half else xp, half), half = maxXp / 2.
static func skill_progress(c: CrewMember, skill: String) -> Vector2i:
	var mx: int = c.skill_cap(skill)  # humans have lower caps
	var half := mx / 2
	var xp := int(c.skills.get(skill, 0))
	return Vector2i(xp - half if xp >= half else xp, half)


## Description part of GetSkillTooltip.
static func skill_description(s: int, lvl: int) -> String:
	if s <= 3:
		return manned_description(s, lvl)
	var v := roundi((EvasionRule.skill_bonus(s, lvl) - 1.0) * 100.0)
	var nm := "repair" if s == 4 else "combat"
	return t(nm + "_0") if v <= 0 else f(nm + "_skilled", v)


## CrewMember::GetSkillTooltip(s, level, progress, infobox).
static func skill_tooltip(s: int, lvl: int, progress: Vector2i, infobox: bool) -> String:
	var d := skill_description(s, lvl)
	if infobox:
		return f("%s_skill_infobox" % SKILL_IDS[s], d)
	return f("%s_skill_tooltip" % SKILL_IDS[s], d) + "\n" + f("next_level", progress.x, progress.y)


## Crew list skill row s (instant, static).
static func crew_skill(c: CrewMember, s: int) -> String:
	return rule("crew_skill", crew_skill_vanilla, [c, s])


static func crew_skill_vanilla(c: CrewMember, s: int) -> String:
	var sk: String = SKILL_IDS[s]
	return skill_tooltip(s, c.skill_level(sk), skill_progress(c, sk), false)


## Crew list entry n (0-based): health + hotkey, or `cloning` when not selectable.
static func crew_box(c: CrewMember, n: int) -> String:
	return rule("crew_box", crew_box_vanilla, [c, n])


static func crew_box_vanilla(c: CrewMember, n: int) -> String:
	if not c.is_alive():
		return t("cloning")
	var s := f("health", int(c.hp), int(c.max_hp))
	if key("crew%d" % (n + 1)) != "":
		s += "\n" + f("hotkey", key("crew%d" % (n + 1)))
	return s


## CrewMember::GetTooltip.
static func crew_one(c: CrewMember) -> String:
	var s := ""
	if c.name_short != "":
		s = c.name_short + " \n"
	if not c.is_alive():
		return s + t("death_tooltip")
	return s + f("health_tooltip", maxi(1, int(c.hp)), int(c.max_hp))


## Crew under the cursor in a room (several on a tile joined with " \n").
static func crew_room(list: Array, ctx := {}) -> String:
	return rule("crew_room", crew_room_vanilla, [list, ctx])


static func crew_room_vanilla(list: Array, _ctx := {}) -> String:
	var parts := PackedStringArray()
	for c in list:
		parts.append(crew_one(c))
	return " \n".join(parts)


# ---------------------------------------------------------------- command / misc

## FTL button (inactive): pilot + engine parts, joined with "\n\n" (empty parts dropped), or no fuel.
static func ftl_button(ship: ShipState) -> String:
	return rule("ftl", ftl_button_vanilla, [ship])


## FTLButton::OnRender: an active button hovered with the pilot or engines down -> GetPilotTooltip + "\n\n" +
## GetEngineTooltip (empty parts dropped); otherwise (inactive, out of fuel) tooltip_jump_noFuel.
static func ftl_button_vanilla(ship: ShipState) -> String:
	var parts := PackedStringArray()
	var p := pilot_tooltip(ship)
	var e := engine_tooltip(ship)
	if p != "":
		parts.append(p)
	if e != "":
		parts.append(e)
	if parts.is_empty() and ship.fuel <= 0:
		return t("tooltip_jump_noFuel")
	return "\n\n".join(parts)


static func pilot_tooltip(ship: ShipState) -> String:
	var s := ship.sys("pilot")
	if FtlDrive.pilot_indicator(ship):
		return ""
	if s != null and s.effective_power() > 0 and s.hack_effect() < 2:
		return t("tooltip_jump_noCrew")
	return t("tooltip_jump_noPiloting")


static func engine_tooltip(ship: ShipState) -> String:
	if FtlDrive.engines_indicator(ship):
		return ""
	return t("tooltip_jump_noEngines")


## HackingSystem::GetPulseTooltip: hack_<system> of the hacked target, else hack_no_system.
static func pulse_text(ship: ShipState) -> String:
	var tgt: SystemState = ship.hack_target if ship.hack_target != null else ship.hack_queued
	return t("hack_" + tgt.id) if tgt != null else t("hack_no_system")


## Store box that cannot be bought (reason = max_weapons, max_drones, max_crew, sys_full, max_augments, have_augment).
static func store_blocked(reason: String) -> String:
	return simple("store_blocked", reason)
