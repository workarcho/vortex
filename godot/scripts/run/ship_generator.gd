class_name ShipGenerator
extends RefCounted
## Event ship scaling (rules/events.md §5.3, ShipGenerator::CreateShip): from the auto blueprint and the sector,
## all draws from the ship seed. `generate` returns a plan (pure data); `apply` builds it onto a fresh enemy
## ShipState. Parts marked [partial] in the rule follow the rule text (candidate checks inferred).
##
## Plan = {blueprint, s, levels: {sys: level}, max: {sys: max}, crew: [races], automated, weapons: [names],
##   drones: [names], drone_parts, scrap}

const OFFENSIVE := ["weapons", "drones", "teleporter", "artillery"]
const DEFENSIVE := ["shields", "engines", "cloaking"]


static func _t() -> Dictionary:
	return RunTuning.section("ship_gen")


## `tmpl`: the event's <ship> template (weaponOverride / droneOverride / crew); may be null.
## `ae`: Advanced Edition content on — the weapon / drone pools then use the OVERRIDE_ lists
## (BlueprintManager::GetBlueprintList, FtlData.blueprint_list_ae).
static func generate(bp_name: String, level: int, difficulty: int, seed: int, tmpl: XmlNode = null,
		ae := true) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var t := _t()
	var easy := difficulty == EventEngine.Difficulty.EASY
	var hard := difficulty == EventEngine.Difficulty.HARD
	var s := level - (1 if easy else 0)
	var S := maxi(s, 0)
	var body := FtlData.ship_blueprint_text(bp_name)
	var plan := {"blueprint": bp_name, "s": s, "levels": {}, "max": {}, "crew": [], "automated": false,
		"weapons": [], "drones": [], "drone_parts": 0,
		"scrap": int(float(t.scrap_mul) * pow(S + 1, float(t.scrap_pow)) + float(t.scrap_add)), "augments_removed": []}
	if easy and s == -1:
		plan.augments_removed.append("ENERGY_SHIELD")
	# Crew: int(min(0.125·S, 1)·(max − amount) + amount); amount 0 → automated.
	var cc := FtlData.tag_attrs(body, "crewCount")
	var a := int(cc.get("amount", "0"))
	var m := int(cc.get("max", str(a)))
	var n := int(minf(float(t.crew_scale) * S, 1.0) * (m - a) + a)
	plan.automated = a == 0
	var races := _crew_races(String(cc.get("class", "human")), n, tmpl, rng)
	plan.crew = races
	# System maxima (GenerateSystemMaxes) and optional systems.
	var sys_re := RegEx.create_from_string("<(\\w+)\\s+([^>]*?)/?>")
	var block := FtlData.tag_value(body, "systemList")
	var k := 1 if s < 0 else (2 if easy else 2 + (1 if s > 1 else 0))
	var opt_chance := S + (1 if easy else (3 if hard else 2))
	var added_offensive := false
	var added_other := 0
	for mt in sys_re.search_all(block):
		var at := FtlData.attrs(mt.get_string(2))
		if not at.has("room"):
			continue
		var id := mt.get_string(1)
		var p := int(at.get("power", "1"))
		var M := maxi(int(at.get("max", str(p))), p)
		var start: bool = at.get("start", "true") == "true"
		if not start:
			if M <= 0 or int(rng.randi() % 10) >= opt_chance:
				continue
			if id in ["weapons", "drones", "teleporter"]:
				added_offensive = true
			else:
				added_other += 1
		var mx := clampi(int(float(t.level_scale) * s * (M - p) + p) + int(rng.randi() % k), p, M)
		plan.levels[id] = p
		plan.max[id] = mx
	# Upgrade budgets: A = S+1, B = s+2, C = S/3+1 (hard +2); added systems cost A−1 / C−2 (hard C−1).
	var A := S + 1
	var B := s + 2
	var C := S / 3 + 1 + (2 if hard else 0)
	if added_offensive:
		A -= 1
	C -= added_other * (1 if hard else 2)
	_upgrade(plan, maxi(A, 0), func(id): return not id in OFFENSIVE, rng)
	_upgrade(plan, maxi(B, 0), func(id): return not id in DEFENSIVE, rng)
	_upgrade(plan, maxi(A + B + C, 0) if A + B + C > 0 else 0, func(_id): return true, rng)
	# Weapons.
	if plan.levels.has("weapons"):
		_pick_weapons(plan, body, tmpl, rng, ae)
	# Drones: count + s (cap 20), drones from the list that fit the drone system.
	var dl := FtlData.tag_attrs(body, "droneList")
	plan.drone_parts = mini(int(dl.get("drones", "0")) + maxi(s, 0), int(t.drone_parts_cap))
	if plan.levels.has("drones") and dl.has("load"):
		_pick_drones(plan, String(dl.load), tmpl, rng, ae)
	return plan


static func _crew_races(cls: String, n: int, tmpl: XmlNode, rng: RandomNumberGenerator) -> Array:
	var out := []
	var props := []  # [race, proportion]
	var cnode := tmpl.child("crew") if tmpl != null else null
	if cnode != null:
		for c in cnode.children_named("crewMember"):
			props.append([c.attr("type", "human"), float(c.attr("prop", "1"))])
	for i in n:
		if props.is_empty():
			out.append(cls)
			continue
		var x := rng.randf()
		var race: String = props[-1][0]
		var acc := 0.0
		for p in props:
			acc += float(p[1])
			if x < acc:
				race = p[0]
				break
		out.append(race if race != "random" else cls)
	return out


## `count` random +1 upgrades among systems accepted by `ok` that are below their generated max.
static func _upgrade(plan: Dictionary, count: int, ok: Callable, rng: RandomNumberGenerator) -> void:
	for i in count:
		var cands := []
		for id in plan.levels:
			if ok.call(id) and int(plan.levels[id]) < int(plan.max[id]):
				cands.append(id)
		if cands.is_empty():
			return
		cands.sort()
		var id: String = cands[rng.randi() % cands.size()]
		plan.levels[id] = int(plan.levels[id]) + 1


## ShipGenerator::GetWeaponFlags (0x5f95c0): bit0 = damage, bit1 = shield stripping. LASER (type 0): 3, or 2 with
## damage 0 (ion lasers). MISSILES (type 1): 3 / 2 when shield piercing < 4, else 1 / 0. Every other type (BEAM,
## BOMB, BURST = flak): 1 with damage, else 0.
static func weapon_flags(w: Dictionary) -> int:
	var dmg := int(w.get("damage", 0)) != 0
	match String(w.get("type", "")):
		"LASER":
			return 3 if dmg else 2
		"MISSILES":
			var strip := int(w.get("sp", 0)) < 4
			return (3 if strip else 1) if dmg else (2 if strip else 0)
	return 1 if dmg else 0


static func _pick_weapons(plan: Dictionary, body: String, tmpl: XmlNode, rng: RandomNumberGenerator,
		ae := true) -> void:
	var slots := int(FtlData.tag_value(body, "weaponSlots")) if FtlData.tag_value(body, "weaponSlots") != "" else 4
	var names := []
	var used := 0
	var ov := tmpl.child("weaponOverride") if tmpl != null else null
	if ov != null:
		var pool := ov.children_named("name").map(func(x): return x.text.strip_edges())
		var cnt := int(ov.attr("count", str(pool.size())))
		for i in mini(cnt, pool.size()):
			var nm: String = pool.pop_at(rng.randi() % pool.size())
			var w := FtlData.weapon_blueprint(nm)
			if w.is_empty():
				continue
			names.append(nm)
			used += int(w.power)
		plan.levels.weapons = maxi(int(plan.levels.weapons), used)
		plan.max.weapons = maxi(int(plan.max.weapons), used)
	var lst := FtlData.tag_attrs(body, "weaponList")
	var list := FtlData.blueprint_list_ae(String(lst.get("load", "")), ae) if lst.has("load") else []
	var sys_max := int(plan.levels.weapons)
	var flags := 3
	var bps := {}
	for nm in list:
		var w := FtlData.weapon_blueprint(nm)
		if not w.is_empty() and int(w.power) > 0:
			bps[nm] = w
	for guard in 8:
		if names.size() >= slots:
			break
		var remaining := sys_max - used
		var cands := []
		for nm in bps:
			var w: Dictionary = bps[nm]
			var p := int(w.power)
			# GetPossibleWeaponList (0x5fb240): remaining >> 2 < p <= remaining (integer shift), never a weapon
			# that takes the whole system once it has 2+ bars (first weapon included), and with 3+ bars the
			# first weapon is not a 1-power one.
			if not ((remaining >> 2) < p and p <= remaining):
				continue
			if sys_max >= 2 and p == sys_max:
				continue
			if sys_max >= 3 and names.is_empty() and p == 1:
				continue
			if flags != 0 and (weapon_flags(w) & flags) == 0:
				continue
			cands.append(nm)
		if cands.is_empty():
			break
		cands.sort()
		var pick: String = cands[rng.randi() % cands.size()]
		names.append(pick)
		used += int(bps[pick].power)
		flags &= ~weapon_flags(bps[pick])
	# CreateShip picks until the list is empty, with no fallback: a weapons system with no fitting weapon (e.g.
	# AUTO_ASSAULT left at 0-1 bars) stays empty.
	plan.weapons = names


static func _pick_drones(plan: Dictionary, list_name: String, tmpl: XmlNode, rng: RandomNumberGenerator,
		ae := true) -> void:
	var budget := int(plan.levels.drones)
	var names := []
	var ov := tmpl.child("droneOverride") if tmpl != null else null
	var pool: Array = ov.children_named("name").map(func(x): return x.text.strip_edges()) if ov != null \
		else FtlData.blueprint_list_ae(list_name, ae)
	for guard in 4:
		var cands := []
		for nm in pool:
			var d := FtlData.drone_blueprint(nm)
			if not d.is_empty() and int(d.power) <= budget and int(d.power) > 0:
				cands.append(nm)
		if cands.is_empty():
			break
		var pick: String = cands[rng.randi() % cands.size()]
		names.append(pick)
		budget -= int(FtlData.drone_blueprint(pick).power)
	plan.drones = names


## Builds the plan onto a freshly created enemy ShipState: system levels (optional systems installed in their
## blueprint rooms), crew, weapons, drones, drone parts; then the enemy startup power runs again.
static func apply(ship: ShipState, plan: Dictionary) -> void:
	ship.blueprint = ship.blueprint.duplicate(true)
	for b in ship.blueprint.systems:
		if plan.levels.has(b.id):
			if ship.sys(b.id) == null:
				b.start = true
				ship.systems[b.id] = SystemState.new(b.id, int(b.room), int(plan.levels[b.id]))
			else:
				ship.sys(b.id).level = int(plan.levels[b.id])
	for id in plan.get("augments_removed", []):
		AugmentRule.remove(ship, id)
	# Reactor: enough for every generated level (enemies run everything) [inferred].
	var need := 0
	for s in ship.systems.values():
		if s.uses_reactor():
			need += s.get_level()
	ship.reactor_max = maxi(ship.reactor_max, need)
	# Crew.
	for c in ship.crew.duplicate():
		if c.is_alive() and not c.player_owned:
			ship.crew.erase(c)
	ship.blueprint.crew = plan.crew.duplicate()
	ship._place_initial_crew()
	# Weapons.
	for w in ship.weapons:
		ship.depower_weapon(w)
	ship.weapons.clear()
	for i in plan.weapons.size():
		var bp := FtlData.weapon_blueprint(plan.weapons[i])
		if not bp.is_empty():
			var ws := WeaponState.new(bp, i)
			ws.powered = false
			ship.weapons.append(ws)
	if ship.sys("drones") != null:
		DroneSystemRule.set_drones(ship, plan.drones)
		ship.drone_parts = int(plan.drone_parts)
	for s in ship.systems.values():
		ship._set_power(s, 0)
	ship._startup_power()
	ship.shield_layers = ship.max_shield_layers()
	SuperShieldRule.instant_charge(ship)  # InstantCharge: a Zoltan enemy arrives with 5 super points
	ship.crew_changed()
