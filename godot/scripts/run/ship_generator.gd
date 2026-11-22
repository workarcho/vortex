class_name ShipGenerator
extends RefCounted
## Event ship scaling (rules/events.md §5.3, ShipGenerator::CreateShip): from the auto blueprint and the sector,
## all draws from the ship seed. `generate` returns a plan (pure data); `apply` builds it onto a fresh enemy
## ShipState. Parts marked [partial] in the rule follow the rule text (candidate checks inferred).
##
## Plan = {blueprint, s, levels: {sys: level}, max: {sys: max}, crew: [races], crew_groups: [sizes], automated,
##   weapons: [names], drones: [names], drone_parts, scrap}

const OFFENSIVE := ["weapons", "drones", "teleporter", "artillery"]
const DEFENSIVE := ["shields", "engines", "cloaking"]


static func _t() -> Dictionary:
	return RunTuning.section("ship_gen")


## `tmpl`: the event's <ship> template (weaponOverride / droneOverride / crew); may be null.
## `ae`: Advanced Edition content on — the weapon / drone pools then use the OVERRIDE_ lists
## (BlueprintManager::GetBlueprintList, FtlData.blueprint_list_ae).
## `crew_table`: crew race -> rarity for class "random" (GetRandomCrew; the sector rarityList applied, see
## EventEngine.crew_rarity_table); empty = the blueprint rarities.
static func generate(bp_name: String, level: int, difficulty: int, seed: int, tmpl: XmlNode = null,
		ae := true, crew_table := {}) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var t := _t()
	var easy := difficulty == EventEngine.Difficulty.EASY
	var hard := difficulty == EventEngine.Difficulty.HARD
	var s := level - (1 if easy else 0)
	var S := maxi(s, 0)
	var body := FtlData.ship_blueprint_text(bp_name)
	var plan := {"blueprint": bp_name, "s": s, "levels": {}, "max": {}, "crew": [], "crew_groups": [], "automated": false,
		"weapons": [], "drones": [], "drone_parts": 0,
		"scrap": int(float(t.scrap_mul) * pow(S + 1, float(t.scrap_pow)) + float(t.scrap_add)), "augments_removed": []}
	if easy and s == -1:
		plan.augments_removed.append("ENERGY_SHIELD")
	# Crew count: int(min(0.125·S, 1)·(max − amount) + amount). The crew themselves are drawn at the end (after
	# the drones), where CreateShip adds them.
	var cc := FtlData.tag_attrs(body, "crewCount")
	var a := int(cc.get("amount", "0"))
	var m := int(cc.get("max", str(a)))
	var n := 0 if a == 0 else int(minf(float(t.crew_scale) * S, 1.0) * (m - a) + a)
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
		# GenerateSystemMaxes (0x5fbe90) works from the blueprint power p (0 allowed), but the system itself is
		# created by ShipManager::AddSystem (0x0049ca00), which starts it at max(p, 1) bars (+ shipLevel 0,
		# capped by the system blueprint's max): AUTO_ASSAULT's <weapons power="0"> is a 1-bar weapons system.
		var mx := clampi(int(float(t.level_scale) * s * (M - p) + p) + int(rng.randi() % k), p, M)
		plan.levels[id] = start_level(id, p)
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
	# Crew (after weapons and drones, as in CreateShip): one group per crew entry, each group placed by its own
	# AddInitialCrew call. Automated = crew count 0 and no <crew> override.
	var descs := crew_descs(tmpl)
	plan.automated = n == 0 and descs.is_empty()
	var groups := _crew_races(String(cc.get("class", "human")), n, descs, rng, crew_table)
	plan.crew_groups = groups.map(func(g): return g.size())
	for g in groups:
		plan.crew.append_array(g)
	return plan


## The event <ship>'s <crew> override as CrewDesc entries (EventsParser::ProcessShipEvent 0x5bfc40): every child
## node of <crew> (whatever its tag), attributes "type" (default "random"; any other attribute such as "class" is
## ignored, so GHOST_SHIP's `<crewMember class="ghost" prop="2"/>` is type "random"), "prop" (strtof, default 0)
## and "amount" (atoi, default 0); an entry with prop 0 and amount 0 is dropped. Order kept.
static func crew_descs(tmpl: XmlNode) -> Array:
	var out := []
	var cnode := tmpl.child("crew") if tmpl != null else null
	if cnode == null:
		return out
	for c in cnode.children:
		var prop := float(c.attr("prop", "0"))
		var amount := int(c.attr("amount", "0"))
		if prop != 0.0 or amount != 0:
			out.append({"type": c.attr("type", "random"), "prop": prop, "amount": amount})
	return out


## ShipGenerator::CreateShip (0x5fca40) crew, after the drones. Entries = the <crew> override (`descs`), or, without
## one and a crew count > 0, a single {type = crewCount class, prop 1}. In entry order:
##   subCount = amount if prop <= 0; else f = float32(prop × crewCount): 1 if f <= 1.0, else int(f)
## (no total cap and no normalisation: 0.8 / 0.2 of 6 gives 4 + 1 = 5 crew, every prop > 0 entry gives at least
## one, also on a crew-count-0 blueprint). Each entry: list = GetPossibleCrewList(type) — "random" answers one
## GetRandomCrew(1) race (0x5f9640), any other type that race; then while the list is non-empty and subCount > 0:
## pick random32() % size (always index 0), subCount −1, and GetPossibleCrewList(type) again (a fresh draw for
## "random", also after the last member). The entry's crew go to one AddInitialCrew call; the room limit (no free
## slot left) is applied there (ShipState._place_initial_crew). Returns one race array per entry.
static func _crew_races(cls: String, n: int, descs: Array, rng: RandomNumberGenerator,
		crew_table := {}) -> Array:
	var entries := descs
	if entries.is_empty() and n > 0:
		entries = [{"type": cls, "prop": 1.0, "amount": 0}]
	var groups := []
	for d in entries:
		var sub := 0
		var prop: float = d.prop
		if prop <= 0.0:
			sub = int(d.amount)
		else:
			# float32 product, as the exe computes it (proportion is a float, crewCount converted to float).
			var f: float = PackedFloat32Array([PackedFloat32Array([prop])[0] * float(n)])[0]
			sub = 1 if f <= 1.0 else int(f)
		var group := []
		var ctype := String(d.type)
		var race := _possible_crew(ctype, rng, crew_table)
		while sub > 0:
			rng.randi()  # random32() % crewList.size(): the list holds one race
			group.append(race)
			sub -= 1
			race = _possible_crew(ctype, rng, crew_table)
		groups.append(group)
	return groups


## GetPossibleCrewList(type) reduced to its single entry: GetRandomCrew(1) for "random", else the type itself.
static func _possible_crew(type: String, rng: RandomNumberGenerator, crew_table: Dictionary) -> String:
	return random_race(crew_table, rng) if type == "random" else type


## GetRandomCrew(1): one rarity-weighted crew race (`table` empty = the crew blueprint rarities); "human" if none.
static func random_race(table: Dictionary, rng: RandomNumberGenerator) -> String:
	var t: Dictionary = table if not table.is_empty() else EventDB.shared().rarity.get("crew", {})
	var race := RunStore.pick_weighted(t, rng)
	return race if race != "" else "human"


## ShipManager::AddSystem (0x0049ca00): a new system starts at max(blueprint power, 1) + shipLevel (0 for every
## ship built here and by ShipManager::OnInit(bp, 0)), capped by the system blueprint's <maxPower>.
static func start_level(id: String, power: int) -> int:
	var lvl := maxi(power, 1)
	var cap := int(UpgradeSession.system_info(id).max)
	return mini(lvl, cap) if cap > 0 else lvl


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
			var w := FtlData.weapon_blueprint(nm) if FtlData.has_weapon_blueprint(nm) else {}
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
		if not FtlData.has_weapon_blueprint(nm):
			continue  # GetWeaponBlueprint's default blueprint (unknown name, power 0): never a candidate
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
	# CreateShip picks until the list is empty, with no fallback: a weapons system with no fitting weapon stays
	# empty (rare in vanilla data: every system has at least 1 bar and most lists hold 1-power weapons).
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
	# One AddInitialCrew call per crew entry: each group starts again at the head of the system order.
	var at := 0
	for size in plan.get("crew_groups", [plan.crew.size()]):
		ship._place_initial_crew(plan.crew.slice(at, at + int(size)))
		at += int(size)
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
