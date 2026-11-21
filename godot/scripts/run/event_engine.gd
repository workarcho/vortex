class_name EventEngine
extends RefCounted
## Event resolution and creation (rules/events.md §2.3, §3, §4, §5). Pure rules: no nodes, no UI.
## `create_event` turns a template (XmlNode) into a LocationEvent dictionary, resolving lists, texts, rewards,
## random items and ship seeds **at creation time** from `rng` (the sector stream, or a ship seed).
##
## LocationEvent = {name, text, choices: [{text, req, lvl, max_lvl, max_group, blue, hidden, event}],
##   res: {fuel, missiles, drones, scrap}, steal, weapon, drone, augment, crew: {amount, race, name, skills},
##   remove_crew: {race, clone, text}, remove, upgrade: {system, amount}, system (name of a system to install, "" =
##   none), damage: [{amount, system, effect}],
##   status: [{type, target, system, amount}], environment, env_target, ship: {template, hostile, seed} |
##   {hostile_only, hostile}, boarders: {amount, race}, store, distress, reveal_map, repair, modify_pursuit,
##   quest, secret_sector, unlock_ship, auto_reward: [type, level], content: bool}
## Unknown tags are ignored (mods can add handlers in `_apply_child`).

enum Difficulty { EASY, NORMAL, HARD }
const MAX_DEPTH := 16
const RES_KEYS := ["fuel", "missiles", "drones", "scrap"]

var db: EventDB
var rng := RandomNumberGenerator.new()
var level := 0  # StarMap::worldLevel (0-based sector)
var difficulty := Difficulty.NORMAL
var ae := true  # Advanced Edition content (OVERRIDE_ lists, _DLC events)
var used_unique := {}  # unique event names created this sector
var used_text := {}  # text list name -> {index: true} (drawn without replacement this sector)
var last_text_pick: XmlNode = null  # the <text> entry the last `resolve_text` drew from a textList (or null)
var crew_rarity := {}  # race -> rarity override from the sector rarityList


func _init(database: EventDB = null) -> void:
	db = database if database != null else EventDB.shared()


func r(n: int) -> int:
	return int(rng.randi() % maxi(n, 1))


## EventGenerator::Clear (new sector): unique events and used texts go back into the pools.
func clear_sector() -> void:
	used_unique.clear()
	used_text.clear()


## RandomAmount::SelectAmount: chance of none, then min if max == 0, else uniform [min, max].
func select_amount(mn: int, mx: int, chance := -1.0) -> int:
	if chance > 0.0 and r(100) < int(100.0 * chance):
		return 0
	if mx == 0:
		return mn
	if mx < mn:
		var t := mn
		mn = mx
		mx = t
	return mn + r(mx + 1 - mn)


# ------------------------------------------------------------------ resolution (§2.3)

## GetBaseEvent(name, L, ignoreUnique, seed): resolves lists (OVERRIDE_ with AE), skips used unique events
## (re-rolls the whole resolution), creates the event. `seed` >= 0: created from a stream seeded with it
## (ship result events); the sector stream is left untouched.
func base_event(name: String, seed := -1) -> Dictionary:
	if name == "":
		return {}
	if not db.has_event_or_list(name):
		push_warning("event not found: " + name)
		return {}
	var saved := rng
	if seed >= 0:
		rng = RandomNumberGenerator.new()
		rng.seed = seed
	var out := {}
	for attempt in 64:
		var n := name
		var inline: XmlNode = null
		var guard := 0
		while (db.lists.has(n) or (ae and db.lists.has("OVERRIDE_" + n))) and guard < 32:
			guard += 1
			var key := "OVERRIDE_" + n if ae and db.lists.has("OVERRIDE_" + n) else n
			var entries: Array = db.lists[key]
			if entries.is_empty():
				n = ""
				break
			var e: XmlNode = entries[r(entries.size())]
			if e.has_attr("load"):
				n = e.attr("load")
			else:
				inline = e
				break
		if inline != null:
			out = create_event(inline, n + "_inline", 0)
			break
		if n == "" or not db.events.has(n) or used_unique.has(n):
			continue
		out = create_event(db.events[n], n, 0)
		break
	rng = saved
	return out


func new_event(name: String) -> Dictionary:
	return {"name": name, "text": "", "choices": [], "res": {"fuel": 0, "missiles": 0, "drones": 0, "scrap": 0},
		"steal": false, "weapon": "", "drone": "", "augment": "", "crew": {}, "remove_crew": {}, "remove": "",
		"upgrade": {}, "system": "", "damage": [], "status": [], "environment": -1, "env_target": 2, "ship": {}, "boarders": {},
		"store": false, "distress": false, "reveal_map": false, "repair": false, "modify_pursuit": 0, "quest": "",
		"secret_sector": false, "unlock_ship": -1, "auto_reward": [], "content": false,
		"back": SpaceImages.DEFAULT_BACK, "planet": SpaceImages.DEFAULT_PLANET, "fleet_pos": 0}


## EventGenerator::CreateEvent for a template node (a `load=` node is resolved by name).
func create_event(node: XmlNode, name := "", depth := 0) -> Dictionary:
	if node == null or depth > MAX_DEPTH:
		return {}
	if node.has_attr("load"):
		return base_event(node.attr("load")) if depth < MAX_DEPTH else {}
	var ev := new_event(name if name != "" else node.attr("name"))
	var reward: XmlNode = null
	for c in node.children:
		if c.tag == "autoReward":
			reward = c
		else:
			_apply_child(ev, c, depth)
	if reward != null:
		generate_reward(ev, reward.text.strip_edges(), reward.attr("level", "LOW") if reward.has_attr("level")
			else "LOW")
	# CreateEvent: a textList entry's planet= / back= (non-empty) override the event's <img> lists
	# (rules/backgrounds.md §2).
	var ti: Array = ev.get("text_img", [])
	if ti.size() == 2:
		if String(ti[0]) != "":
			ev.planet = ti[0]
		if String(ti[1]) != "":
			ev.back = ti[1]
	ev.erase("text_img")
	if ev.choices.is_empty():
		ev.choices.append({"text": tr_text("continue"), "req": "", "lvl": 1, "max_lvl": 1 << 30, "max_group": -1,
			"blue": false, "hidden": true, "event": {}})
	ev.content = ev.text != "" or _has_effects(ev) or ev.choices.size() > 1 or not ev.choices[0].event.is_empty()
	if node.attr("unique") == "true" and ev.name != "":
		used_unique[ev.name] = true
	return ev


func _has_effects(ev: Dictionary) -> bool:
	for k in RES_KEYS:
		if int(ev.res[k]) != 0:
			return true
	return ev.weapon != "" or ev.drone != "" or ev.augment != "" or not ev.crew.is_empty() \
		or not ev.remove_crew.is_empty() or not ev.damage.is_empty() or not ev.ship.is_empty() or ev.store \
		or String(ev.get("system", "")) != ""


## EventsParser::ProcessEvent <crewMember>: for each skill in CrewBlueprint order (pilot, engines, shields,
## weapons, repair, combat) `all_skills` (when present) else that skill's attribute -> {skill: level} (0..2;
## CreateEvent sets skillLevel.first = (max / 2) * level). Empty = CreateEvent rolls RandomSkills(worldLevel).
static func crew_skill_attrs(c: XmlNode) -> Dictionary:
	var out := {}
	for sk in CrewMember.SKILLS:
		var a := "all_skills" if c.has_attr("all_skills") else String(sk)
		if c.has_attr(a):
			out[sk] = int(c.attr(a))
	return out


func _apply_child(ev: Dictionary, c: XmlNode, depth: int) -> void:
	match c.tag:
		"text":
			last_text_pick = null
			ev.text = resolve_text(c)
			if last_text_pick != null:
				ev["text_img"] = [last_text_pick.attr("planet"), last_text_pick.attr("back")]
		"img":  # <img back="LIST" planet="LIST"/> (image list names; "NONE" = no planet)
			if c.has_attr("back"):
				ev.back = c.attr("back")
			if c.has_attr("planet"):
				ev.planet = c.attr("planet")
		"fleet":  # fleet background (SpaceManager::SetDangerZone): rebel 1, fed 2, battle 3
			ev.fleet_pos = {"rebel": 1, "fed": 2, "battle": 3}.get(c.text.strip_edges(), 0)
		"choice":
			var ch := {"text": "", "req": c.attr("req"), "lvl": int(c.attr("lvl", "1")),
				"max_lvl": int(c.attr("max_lvl", str(1 << 30))), "max_group": int(c.attr("max_group", "-1")),
				"blue": c.attr("blue", "true") != "false", "hidden": c.attr("hidden") == "true", "event": {}}
			var t := c.child("text")
			if t != null:
				ch.text = resolve_text(t)
			var e := c.child("event")
			if e != null:
				ch.event = create_event(e, "", depth + 1)
			ev.choices.append(ch)
		"item_modify":
			_item_modify(ev, c)
		"weapon", "drone", "augment":
			var n := c.attr("name")
			ev[c.tag] = random_item(c.tag) if n == "RANDOM" else resolve_item_name(n)
		"crewMember":
			ev.crew = {"amount": int(c.attr("amount", "1")), "race": c.attr("class", "random"),
				"name": tr_text(c.attr("id")) if c.has_attr("id") else "", "skills": crew_skill_attrs(c)}
			if ev.crew.amount < 0:
				# A loss (rules/events.md "Crew removal"): the class is kept verbatim as a species preference
				# (none / random / traitor = uniform pick); class="traitor" turns the victim hostile.
				ev.crew.race = c.attr("class", "")
				ev.crew["traitor"] = ev.crew.race == "traitor"
				ev.crew["clone"] = false
				ev.crew["text"] = ""
			elif ev.crew.race == "random" or ev.crew.race == "":
				ev.crew.race = random_crew()
		"removeCrew":
			var cl := c.child("clone")
			var t := c.child("text")
			if cl == null:
				push_warning("removeCrew without <clone> in event %s (the exe would crash)" % ev.name)
			ev.remove_crew = {"amount": -1, "race": c.attr("class", ""), "clone": cl != null and cl.text.strip_edges() == "true",
				"text": resolve_text(t) if t != null else "", "traitor": false}
		"remove":
			ev.remove = c.attr("name")
		"upgrade":
			ev.upgrade = {"system": c.attr("system"), "amount": int(c.attr("amount", "1"))}
		"system":  # <system name="medbay"/>: CreateEvent systemId = NameToSystemId(name) (unknown = none)
			ev.system = c.attr("name") if SystemState.ORDER.has(c.attr("name")) else ""
		"damage":
			ev.damage.append({"amount": int(c.attr("amount", "0")), "system": c.attr("system"),
				"effect": c.attr("effect")})
		"status":
			ev.status.append({"type": c.attr("type"), "target": c.attr("target", "player"),
				"system": c.attr("system"), "amount": int(c.attr("amount", "0"))})
		"environment":
			ev.environment = {"asteroid": 1, "sun": 2, "nebula": 3, "storm": 4, "pulsar": 5, "PDS": 6}.get(
				c.attr("type"), -1)
			ev.env_target = {"player": 0, "enemy": 1, "all": 2}.get(c.attr("target", "all"), 2)
		"ship":
			ev.ship = _ship(c)
		"boarders":
			ev.boarders = {"amount": select_amount(int(c.attr("min", "0")), int(c.attr("max", "0"))),
				"race": c.attr("class", "random"), "breach": c.attr("breach") == "true"}
			if ev.boarders.race == "random":
				ev.boarders.race = random_crew()
		"store":
			ev.store = true
		"distressBeacon":
			ev.distress = true
		"reveal_map":
			ev.reveal_map = true
		"repair":
			ev.repair = true
		"secretSector":
			ev.secret_sector = true
		"modifyPursuit":
			ev.modify_pursuit = int(c.attr("amount", "0"))
		"quest":
			ev.quest = c.attr("event")
		"unlockShip":
			ev.unlock_ship = int(c.attr("id", "-1"))


## <ship load="X" hostile="b"/>: template (or shipList pick) + shipSeed; a bare <ship hostile="b"/> only
## changes the hostility of the ship already there.
func _ship(c: XmlNode) -> Dictionary:
	var hostile := c.attr("hostile") == "true"
	var tname := c.attr("load")
	if tname == "" and not c.has_attr("auto_blueprint") and not c.has_attr("blueprint") and c.children.is_empty():
		return {"hostile_only": true, "hostile": hostile}
	if db.ship_lists.has(tname):
		var l: Array = db.ship_lists[tname]
		tname = l[r(l.size())] if not l.is_empty() else ""
	var tmpl: XmlNode = db.ships.get(tname, c if tname == "" else null)
	if tmpl == null:
		push_warning("ship template not found: " + tname)
		return {}
	return {"template": tname, "node": tmpl, "hostile": hostile, "seed": int(rng.randi() & 0x7fffffff)}


## <item_modify steal [min max chance]><item type min max [chance]/>: count n (all when unset), rolled in the
## order fuel (rand%4 < n), drones (rand%3 < n), missiles (rand%2 < n), scrap (n > 0).
func _item_modify(ev: Dictionary, c: XmlNode) -> void:
	ev.steal = c.attr("steal") == "true"
	var amounts := {}
	for it in c.children_named("item"):
		amounts[it.attr("type")] = it
	var n := 100
	var mn := int(c.attr("min", "0"))
	var mx := int(c.attr("max", "0"))
	if mn != 0 or mx != 0:
		n = select_amount(mn, mx, float(c.attr("chance", "-1")))
	for pair in [["fuel", 4], ["drones", 3], ["missiles", 2], ["scrap", 0]]:
		var it: XmlNode = amounts.get(pair[0])
		if it == null:
			continue
		var roll: bool = n > 0 if pair[1] == 0 else r(pair[1]) < n
		if not roll:
			continue
		var v := select_amount(int(it.attr("min", "0")), int(it.attr("max", "0")), float(it.attr("chance", "-1")))
		ev.res[pair[0]] = v
		if v != 0:
			n -= 1


func tr_text(id: String) -> String:
	return FtlData.tr_id(id).replace("\\n", "\n") if id != "" else ""


static func decode(s: String) -> String:
	return s.replace("&quot;", "\"").replace("&apos;", "'").replace("&lt;", "<").replace("&gt;", ">") \
		.replace("&amp;", "&").replace("\\n", "\n")


## <text id=…> / <text load="list"> (drawn without replacement per sector) / literal.
func resolve_text(n: XmlNode) -> String:
	if n.has_attr("load"):
		var lname := n.attr("load")
		var l: Array = db.text_lists.get(lname, [])
		var used: Dictionary = used_text.get(lname, {})
		var free := []
		for i in l.size():
			if not used.has(i):
				free.append(i)
		if free.is_empty():
			push_warning("Ran out of texts: " + lname)
			return ""
		var pick: int = free[r(free.size())]
		used[pick] = true
		used_text[lname] = used
		var out := resolve_text(l[pick])
		last_text_pick = l[pick]
		return out
	if n.has_attr("id"):
		return tr_text(n.attr("id"))
	return decode(n.text)


# ------------------------------------------------------------------ rewards (§4.1)

## GenerateReward: `level` "LOW"/"MED"/"HIGH" exactly, anything else = RANDOM (rand%3). Results are assigned
## (overwrite item_modify values). The item step is skipped when the event already grants an item.
func generate_reward(ev: Dictionary, type: String, level_str: String) -> void:
	var lv: int = {"LOW": 0, "MED": 1, "HIGH": 2}.get(level_str, 3)
	if lv == 3:
		lv = r(3)
	ev.auto_reward = [type, lv]
	var tun := RunTuning.section("reward")
	var has_item: bool = ev.weapon != "" or ev.drone != "" or ev.augment != ""
	match type:
		"standard":
			if r(100) < int(tun.get("standard_item_percent", 3)):
				if not has_item:
					_reward_item(ev, ["weapon", "drone", "augment"][r(3)])
				return
			ev.res.scrap = reward_scrap(lv)
			for k in _two_resources():
				ev.res[k] = reward_amount(k, 0)
		"stuff":
			if r(100) < int(tun.get("stuff_item_percent", 6)):
				if not has_item:
					_reward_item(ev, ["weapon", "drone", "augment"][r(3)])
				return
			ev.res.scrap = reward_scrap(0)
			for k in _two_resources():
				ev.res[k] = reward_amount(k, lv)
		"fuel", "missiles", "droneparts":
			ev.res.scrap = reward_scrap(lv)
			ev.res[_res_key(type)] = reward_amount(_res_key(type), lv)
		"fuel_only", "missiles_only", "droneparts_only":
			var k := _res_key(type.trim_suffix("_only"))
			ev.res[k] = reward_amount(k, lv)
		"scrap_only":
			ev.res.scrap = reward_scrap(lv)
		"item":
			if not has_item:
				_reward_item(ev, ["weapon", "drone", "augment"][r(3)])
		"weapon", "drone", "augment":
			ev.res.scrap = reward_scrap(lv)
			if not has_item:
				_reward_item(ev, type)
		_:
			pass  # unknown type (vanilla's "scrap") gives nothing


func _res_key(t: String) -> String:
	return "drones" if t == "droneparts" else t


## Two different resources among fuel / missiles / drone parts.
func _two_resources() -> Array:
	var pool := ["fuel", "missiles", "drones"]
	var a: String = pool[r(3)]
	pool.erase(a)
	return [a, pool[r(2)]]


func _reward_item(ev: Dictionary, kind: String) -> void:
	ev[kind] = random_item(kind)


## Scrap at level `lv`: int(randint[1000·lo, 1000·hi] / 1000 × (base + per_level·L')), L' = L+1 easy,
## max(0, L−1) hard, L normal.
func reward_scrap(lv: int) -> int:
	var tun := RunTuning.section("reward")
	var v: Array = tun.scrap_variance[lv]
	var lo := int(roundf(float(v[0]) * 1000.0))
	var hi := int(roundf(float(v[1]) * 1000.0))
	var m := float(lo + r(hi + 1 - lo)) / 1000.0
	return int(m * (float(tun.scrap_base) + float(tun.scrap_per_level) * scrap_level()))


func scrap_level() -> int:
	match difficulty:
		Difficulty.EASY:
			return level + 1
		Difficulty.HARD:
			return maxi(0, level - 1)
	return level


func reward_amount(key: String, lv: int) -> int:
	var table: Array = RunTuning.section("reward")["droneparts" if key == "drones" else key]
	var e: Array = table[lv]
	return int(e[0]) + r(int(e[1]) + 1 - int(e[0]))


## RandomItems<T>(1): weighted draw, weight = 6 − rarity, rarity 0 never.
## BlueprintManager::GetWeaponBlueprint / GetDroneBlueprint / GetAugmentBlueprint: a name that is a
## <blueprintList> (DLC_WEAPONS, DLC_DRONES, DLC_AUGMENTS, WEAPONS_CRYSTAL ...) stands for one random entry
## (random % list size), resolved when the event is created (EventGenerator::CreateEvent calls the getter).
func resolve_item_name(n: String) -> String:
	var entries := FtlData.blueprint_list(n)
	return String(entries[r(entries.size())]) if not entries.is_empty() else n


func random_item(kind: String) -> String:
	return _weighted(db.rarity.get(kind, {}))


## GetRandomCrew: same weighting over crew races, sector rarityList overrides applied.
func random_crew() -> String:
	var table: Dictionary = db.rarity.get("crew", {}).duplicate()
	for k in crew_rarity:
		table[k] = crew_rarity[k]
	var pick := _weighted(table)
	return pick if pick != "" else "human"


func _weighted(table: Dictionary) -> String:
	var total := 0
	for k in table:
		if int(table[k]) > 0:
			total += 6 - int(table[k])
	if total <= 0:
		return ""
	var x := r(total)
	for k in table:
		var rr := int(table[k])
		if rr <= 0:
			continue
		x -= 6 - rr
		if x < 0:
			return k
	return ""


# ------------------------------------------------------------------ event ships (§5)

## WorldManager::CreateShip for a ship event: blueprint pick from `auto_blueprint` (minSector ≤ s ≤ maxSector,
## s = L − easy) and the surrender / escape thresholds (L/2 + SelectAmount), all from the ship seed.
## Returns {blueprint, surrender_threshold, escape_threshold, escape_timer, has_surrender, ...}.
func setup_ship(ship_ev: Dictionary) -> Dictionary:
	var tmpl: XmlNode = ship_ev.node
	var srng := RandomNumberGenerator.new()
	srng.seed = int(ship_ev.seed)
	var saved := rng
	rng = srng
	var bp := tmpl.attr("blueprint")
	if bp == "":
		var lname := tmpl.attr("auto_blueprint", RunTuning.name_of("default_auto_blueprint"))
		var entries := FtlData.blueprint_list(lname)
		if entries.is_empty() and FtlData.has_ship_blueprint(lname):
			entries = [lname]
		var s := maxi(level - (1 if difficulty == Difficulty.EASY else 0), 0)
		var cands := []
		for e in entries:
			var body := FtlData.ship_blueprint_text(e)
			if body == "":
				continue
			var mn := FtlData.tag_value(body, "minSector")
			var mx := FtlData.tag_value(body, "maxSector")
			if (mn == "" or int(mn) <= s) and (mx == "" or s <= int(mx)):
				cands.append(e)
		if cands.is_empty():
			cands = entries.filter(func(e): return FtlData.has_ship_blueprint(e))
		bp = cands[r(cands.size())] if not cands.is_empty() else "REBEL_FAT"
	var out := {"blueprint": bp, "has_surrender": false, "has_escape": false, "surrender_threshold": -100,
		"escape_threshold": -100, "escape_timer": 15.0}
	var sur := tmpl.child("surrender")
	if sur != null:
		out.has_surrender = true
		out.surrender_threshold = level / 2 + select_amount(int(sur.attr("min", "0")), int(sur.attr("max", "0")),
			float(sur.attr("chance", "-1")))
	var esc := tmpl.child("escape")
	if esc != null:
		out.has_escape = true
		out.escape_threshold = level / 2 + select_amount(int(esc.attr("min", "0")), int(esc.attr("max", "0")),
			float(esc.attr("chance", "-1")))
		if out.escape_threshold == out.surrender_threshold:
			out.escape_threshold -= 1
		out.escape_timer = float(esc.attr("timer", "0")) if float(esc.attr("timer", "0")) > 0 else 15.0
	rng = saved
	return out


## The template's outcome event (`destroyed`, `deadCrew`, `surrender`, `gotaway`), created from the ship seed
## (GetBaseEvent(name, L, false, shipSeed)). Missing `destroyed` / `deadCrew` -> the *_DEFAULT lists.
func ship_outcome_event(ship_ev: Dictionary, kind: String) -> Dictionary:
	var tmpl: XmlNode = ship_ev.get("node")
	var n: XmlNode = tmpl.child(kind) if tmpl != null else null
	var seed := int(ship_ev.get("seed", 0))
	if n == null:
		match kind:
			"destroyed":
				return base_event(RunTuning.name_of("destroyed_default"), seed)
			"deadCrew":
				return base_event(RunTuning.name_of("dead_crew_default"), seed)
		return {}
	if n.has_attr("load"):
		return base_event(n.attr("load"), seed)
	var saved := rng
	rng = RandomNumberGenerator.new()
	rng.seed = seed
	var ev := create_event(n, "%s_%s" % [ship_ev.get("template", ""), kind], 0)
	rng = saved
	return ev
