class_name RunStore
extends RefCounted
## A beacon's store (rules/store.md): generated on the first visit (Store::OnInit / CreateStoreBoxes) from the run
## RNG and the ship at that moment, then kept on the beacon (sold-out stays sold out). Pure rules: generation,
## prices, CanHold reasons, purchases, resources, hull repair and selling at half price. The run (`RunState`) owns
## the player ship and the cargo.
##
## Section = {type: WEAPONS|DRONES|AUGMENTS|CREW|SYSTEMS, boxes: [Offer]}
## Offer = {kind, name, price, count (1 / 0 sold out / -1 empty box), extra: {free_drone, skills, ident}}
## (crew `ident` = CrewIdentity dictionary {race, name, male, colors}, rolled with the box and kept on purchase)

enum { WEAPONS, DRONES, AUGMENTS, CREW, SYSTEMS }
const KINDS := ["weapon", "drone", "augment", "crew", "system"]
const SECTION_IDS := ["store_tab_weapons", "store_tab_drones", "store_tab_augments", "store_tab_crew",
	"store_tab_systems"]

var sections: Array = []
var resources := {}  # fuel / missiles / drones -> {count, price}
var repair_cost := 2
var world_level := 0
var pending_confirm := {}  # {section, box, text_id}: system purchase waiting for yes / no


static func _t() -> Dictionary:
	return RunTuning.section("store")


# ------------------------------------------------------------------ generation (§1–§3)

## Store::OnInit + CreateStoreBoxes + ItemStoreBox ctors.
static func generate(rng: RandomNumberGenerator, ship: ShipState, level: int, ae: bool, rarity: Dictionary) -> RunStore:
	var s := RunStore.new()
	s.world_level = level
	var t := _t()
	var count := int(t.sections_min) + int(rng.randi() % int(t.sections_extra))
	var owned_systems := _system_count(ship)
	var n := 5
	if not ae and owned_systems >= 11:
		n = 4
	var types := []
	if owned_systems < 11 and rng.randi() % 2 == 1:
		types.append(SYSTEMS)
	else:
		types.append(int(rng.randi() % n))
	while types.size() < count:
		var k := int(rng.randi() % n)
		if not k in types:
			types.append(k)
	# Drone override: no drone system and no systems section → drones replaced by the first type not present.
	if ship.sys("drones") == null and not SYSTEMS in types:
		for i in types.size():
			if types[i] != DRONES:
				continue
			for alt in ([WEAPONS, AUGMENTS, CREW, SYSTEMS] if n == 5 else [WEAPONS, AUGMENTS, CREW]):
				if not alt in types:
					types[i] = alt
					break
	for ty in types:
		s.sections.append({"type": ty, "boxes": s._boxes(ty, rng, ship, level, ae, rarity, types)})
	s.resources = {}
	for k in ["fuel", "missiles", "drones"]:
		var e: Array = t["droneparts" if k == "drones" else k]
		s.resources[k] = {"count": int(e[0]) + int(rng.randi() % int(e[1])), "price": int(e[2])}
	s.repair_cost = repair_price(level)
	return s


## Repair price per hull point: 2 (sectors 1–3), 3 (4–6), 4 (7–8).
static func repair_price(level: int) -> int:
	var out := 2
	for e in _t().repair_cost:
		if level >= int(e[0]):
			out = int(e[1])
	return out


static func _system_count(ship: ShipState) -> int:
	return ship.systems.size()


func _boxes(ty: int, rng: RandomNumberGenerator, ship: ShipState, level: int, ae: bool, rarity: Dictionary,
		types: Array) -> Array:
	var out := []
	match ty:
		WEAPONS, DRONES, AUGMENTS:
			var n := 3 if ae else 2 + int(rng.randi() % 2)
			for nm in random_items(rarity.get(KINDS[ty], {}), n, rng):
				out.append(_offer(KINDS[ty], nm))
		CREW:
			var n := 3 if ae else 2 + int(rng.randi() % 2)
			var used := CrewIdentity.used_names(ship)
			for i in n:
				var race := pick_weighted(rarity.get("crew", {}), rng)
				if race == "":
					continue
				var o := _offer("crew", race)
				# CrewStoreBox ctor: name + gender, colours (rules/crew_appearance.md §5) fixed for the box. Drawn from
				# CrewIdentity.rng (not the store rng) so the store contents of a seed do not change.
				o.extra.ident = CrewIdentity.roll(race, CrewIdentity.rng, used)
				o.extra.skills = random_skills(level, rng)
				out.append(o)
		SYSTEMS:
			out = _system_boxes(rng, ship, ae, DRONES in types)
	while out.size() < 3:
		out.append({"kind": KINDS[ty], "name": "", "price": -1, "count": -1, "extra": {}})
	return out


func _offer(kind: String, nm: String) -> Dictionary:
	var info := FtlData.item_info(kind, nm)
	var price := int(info.get("cost", 0))
	if kind == "crew":
		price = int(_t().crew_cost.get(nm, price))
	return {"kind": kind, "name": nm, "price": price, "count": 1, "extra": {}}


## RandomItems<T>(count): weight 6 − rarity (rarity 0 never), weighted draw without replacement.
static func random_items(table: Dictionary, count: int, rng: RandomNumberGenerator) -> Array:
	var pool := table.duplicate()
	var out := []
	for i in count:
		var nm := pick_weighted(pool, rng)
		if nm == "":
			break
		out.append(nm)
		pool.erase(nm)
	return out


static func pick_weighted(table: Dictionary, rng: RandomNumberGenerator) -> String:
	var total := 0
	var keys := table.keys()
	keys.sort()  # stable order (dictionary order depends on load order)
	for k in keys:
		if int(table[k]) > 0:
			total += 6 - int(table[k])
	if total <= 0:
		return ""
	var x := int(rng.randi() % total)
	for k in keys:
		var r := int(table[k])
		if r <= 0:
			continue
		x -= 6 - r
		if x < 0:
			return k
	return ""


## CrewBlueprint::RandomSkills(worldLevel): n bumps in RANDOM_SKILLS[level], two distinct skills, each bump one
## level (maxXP / 2) on one of the two. Returns {skill: levels}.
static func random_skills(level: int, rng: RandomNumberGenerator) -> Dictionary:
	var table: Array = _t().random_skills
	var e: Array = table[clampi(level, 0, table.size() - 1)]
	var n := mini(int(e[0]) + int(rng.randi() % (int(e[1]) - int(e[0]) + 1)), 4)
	var pool := CrewMember.SKILLS.duplicate()
	var a: String = pool.pop_at(rng.randi() % pool.size())
	var b: String = pool[rng.randi() % pool.size()]
	var out := {}
	for i in n:
		var k := a if rng.randi() % 2 == 0 else b
		out[k] = mini(int(out.get(k, 0)) + 1, 2)
	return out


## Systems section (CreateStoreBoxes case 4): forced drones / shields / medical first, then uniform picks among
## the candidates (ascending id order), padded with empty boxes.
func _system_boxes(rng: RandomNumberGenerator, ship: ShipState, ae: bool, drones_section: bool) -> Array:
	var ids: Array = _t().system_ids
	var cands := []
	for i in ids.size():
		var id: String = ids[i]
		if not ae and i >= 11:
			continue
		if drones_section and ship.sys("drones") == null and id == "drones":
			continue
		if id == "medbay" or id == "clonebay":
			var other := "clonebay" if id == "medbay" else "medbay"
			if ship.sys(other) == null:
				continue  # only the other medical system can be a random candidate
		if id == "shields" and ship.sys("shields") == null:
			continue
		if ship.sys(id) != null or not _has_room_for(ship, id):
			continue
		var info := FtlData.item_info("system", id)
		if info.is_empty() or int(info.rarity) == 0:
			continue
		cands.append(id)
	var desired := mini(3, cands.size())
	var forced := []
	if drones_section and ship.sys("drones") == null and _has_room_for(ship, "drones"):
		forced.append("drones")
		desired -= 1
	if ship.sys("shields") == null and _has_room_for(ship, "shields"):
		forced.append("shields")
		desired -= 1
	if ship.sys("medbay") == null and (not ae or ship.sys("clonebay") == null):
		var med := "medbay"
		if ae and rng.randi() % 2 == 1:
			med = "clonebay"
		if _has_room_for(ship, med):
			forced.append(med)
			desired -= 1
	var out := []
	for id in forced:
		out.append(_system_offer(id, rng))
	var rest := cands.filter(func(c): return not c in forced)
	var need := maxi(desired, 0)
	for i in rest.size():
		if need <= 0:
			break
		if int(rng.randi() % (rest.size() - i)) + 1 <= need:
			out.append(_system_offer(rest[i], rng))
			need -= 1
	return out.slice(0, 3)


func _system_offer(id: String, rng: RandomNumberGenerator) -> Dictionary:
	var o := _offer("system", id)
	if id == "drones":  # free drone: rand % 3 → DEFENSE_1 / REPAIR / COMBAT_1, price + its cost / 2
		var fd: String = _t().free_drones[rng.randi() % 3]
		o.extra.free_drone = fd
		o.price += int(FtlData.item_info("drone", fd).get("cost", 0)) / 2
	return o


## The blueprint has a room for the system (systemList entry, start="false").
static func _has_room_for(ship: ShipState, id: String) -> bool:
	for b in ship.blueprint.get("systems", []):
		if b.id == id:
			return true
	return false


# ------------------------------------------------------------------ buying rules (§4, §5)

func offer(section: int, box: int) -> Dictionary:
	if section < 0 or section >= sections.size() or box < 0 or box >= sections[section].boxes.size():
		return {}
	return sections[section].boxes[box]


## Can the ship hold it (StoreBox::CanHold)? Returns "" or the reason text id (max_weapons, max_drones, max_crew,
## max_augments, have_<aug>, sys_full). Affordability is separate.
static func can_hold(o: Dictionary, run: RunState) -> String:
	var ship := run.ship
	var cargo_free := ShipInventory.cargo_free(run) > 0  # positional cargo boxes ("" = empty)
	match String(o.kind):
		"weapon":
			if (ship.sys("weapons") != null and ship.weapons.size() < ship.weapon_slots) or cargo_free:
				return ""
			return "max_weapons"
		"drone":
			if (ship.sys("drones") != null and ship.drones.size() < ship.drone_slots) or cargo_free:
				return ""
			return "max_drones"
		"augment":
			return AugmentRule.can_add(ship, String(o.name), int(_t().max_augments))  # max 3, stackable
		"crew":
			return "max_crew" if ship.own_crew().size() >= int(_t().max_crew) or ship.blueprint.crew.is_empty() \
				and ship.own_crew().is_empty() else ""
		"system":
			var subs: Array = _t().subsystems
			if o.name in subs:
				var n := 0
				for id in ship.systems:
					if id in subs:
						n += 1
				return "" if n < int(_t().max_subsystems) else "sys_full"
			if o.name in ["medbay", "clonebay"] and (ship.sys("medbay") != null or ship.sys("clonebay") != null):
				return ""  # replacement always fits
			return "" if main_systems(ship) < int(_t().max_main_systems) else "sys_full"
	return ""


static func main_systems(ship: ShipState) -> int:
	var subs: Array = _t().subsystems
	var n := 0
	for id in ship.systems:
		if not id in subs:
			n += 1
	return n


## Box active = stock left and the ship can hold it (affordability not included).
func active(o: Dictionary, run: RunState) -> bool:
	return not o.is_empty() and int(o.count) > 0 and can_hold(o, run) == ""


## System purchases that need a yes/no (StoreBox::RequiresConfirm): medbay ↔ clonebay replacement, the 8th main
## system. Returns the text id or "".
static func confirm_text(o: Dictionary, run: RunState) -> String:
	if String(o.kind) != "system":
		return ""
	var ship := run.ship
	if o.name == "medbay" and ship.sys("clonebay") != null:
		return "confirm_buy_medbay"
	if o.name == "clonebay" and ship.sys("medbay") != null:
		return "confirm_buy_clonebay"
	if not o.name in _t().subsystems and main_systems(ship) == int(_t().max_main_systems) - 1:
		return "confirm_buy_last_system"
	return ""


## StoreBox::Activate: "ok", "scrap" (cannot afford: nothing bought), "confirm" (waiting for confirm()), a
## CanHold reason, or "none".
func buy(section: int, box: int, run: RunState) -> String:
	var o := offer(section, box)
	if o.is_empty() or int(o.count) <= 0:
		return "none"
	var why := can_hold(o, run)
	if why != "":
		return why
	# Mods may change the price or cancel the purchase (rules/hooks.md `store_purchase`).
	var fp: Variant = Hooks.filter(&"store_purchase", int(o.price), o, run)
	if Hooks.is_cancel(fp):
		return "cancelled"
	o.price = int(fp)
	if int(o.price) > run.ship.scrap:
		return "scrap"
	var ct := confirm_text(o, run)
	if ct != "":
		pending_confirm = {"section": section, "box": box, "text_id": ct}
		return "confirm"
	_purchase(o, run)
	return "ok"


## Confirm window answer for a pending system purchase.
func confirm(yes: bool, run: RunState) -> String:
	if pending_confirm.is_empty():
		return "none"
	var o := offer(int(pending_confirm.section), int(pending_confirm.box))
	pending_confirm = {}
	if not yes or int(o.price) > run.ship.scrap:
		return "cancelled"
	_purchase(o, run)
	return "ok"


func _purchase(o: Dictionary, run: RunState) -> void:
	var ship := run.ship
	ship.scrap -= int(o.price)
	o.count = 0
	Hooks.emit(&"store_bought", run, String(o.kind))  # StoreBox::Purchase: flag "store_purchase"
	match String(o.kind):
		"weapon", "drone":
			run.give_item(String(o.kind), String(o.name))
		"augment":
			AugmentRule.add(ship, String(o.name))
		"crew":
			var c := ship.add_crew(String(o.name), true, -1, o.extra.get("ident", {}))  # keeps name / gender / colours
			if c:
				for k in o.extra.get("skills", {}):
					c.skills[k] = float(c.skill_cap(k)) / 2.0 * int(o.extra.skills[k])
				ship.crew_changed()
		"system":
			install_system(ship, String(o.name))
			if o.name == "drones" and o.extra.has("free_drone"):
				run.give_item("drone", String(o.extra.free_drone))
	run.stats.scrap_spent = int(run.stats.get("scrap_spent", 0)) + int(o.price)
	run._log("store: bought %s %s for %d" % [o.kind, o.name, o.price])
	FtlData.play("buy")  # StoreBox::Purchase


## ShipManager::AddSystem [exe] (rules/events.md "System rewards"; used by the store and by event `<system>`
## rewards): nothing when the ship blueprint's systemList has no entry (no room) for it; otherwise the system
## appears in that room at level min(max(blueprint power, 1) + shipLevel (0 for the player: OnInit gives the
## reactor level * 3 extra), the system blueprint's maxPower), unpowered. Medbay and clonebay replace each other:
## the new one is upgraded to the old one's level when that is higher, the old one is depowered and removed.
## A player medbay / clonebay: the crew in its room are re-slotted around the blocked slot (EmptySlots /
## FillRoomSlot / FindSlot + MoveToRoom). Already installed: the exe would build a second ShipSystem of the same
## id (only reachable when a greyed "new_system_owned" choice is forced open); not modelled, nothing happens.
## Returns true when the system was added.
static func install_system(ship: ShipState, id: String) -> bool:
	if ship.sys(id) != null:
		return false
	var b := {}
	for e in ship.blueprint.get("systems", []):
		if e.id == id:
			b = e
			break
	if b.is_empty():
		return false
	var lvl := maxi(int(b.power), 1)
	var cap := int(UpgradeSession.system_info(id).max)
	if cap > 0:
		lvl = mini(lvl, cap)
	var other := "clonebay" if id == "medbay" else ("medbay" if id == "clonebay" else "")
	if other != "" and ship.sys(other) != null:
		var o := ship.sys(other)
		lvl = maxi(lvl, o.level)  # UpgradeSystem(1) while below the replaced system's level
		ship._set_power(o, 0)  # DecreasePower until the old one has no power
		ship.systems.erase(other)
		Hooks.emit(&"system_removed", ship, other)
	b.start = true
	ship.systems[id] = SystemState.new(id, int(b.room), lvl)
	if id == "drones" and ship.drone_slots <= 0:
		ship.drone_slots = 2  # [inferred] ships without drone slots get the default 2 with the system
	if ship.is_player and (id == "medbay" or id == "clonebay"):
		_reslot_room(ship, int(b.room))
	ship.crew_changed()
	Hooks.emit(&"system_installed", ship, id)
	return true


## AddSystem (player medbay / clonebay): every crew member whose slot is in the room gives it up, then each one in
## crew order takes a free slot again (the blocked slot excluded) and walks there.
static func _reslot_room(ship: ShipState, room: int) -> void:
	var movers := []
	for c in ship.crew:
		if c.is_alive() and c.target_room == room and c.slot >= 0:
			movers.append(c)
			c.slot = -1
	for c in movers:
		var s := ship.graph.find_slot(room, c)
		if s >= 0:
			c.walk_to_slot(ship, room, s)


## ItemStoreBox: one unit per click.
func buy_resource(kind: String, run: RunState) -> String:
	var r: Dictionary = resources.get(kind, {})
	if r.is_empty() or int(r.count) <= 0:
		return "none"
	if int(r.price) > run.ship.scrap:
		return "scrap"
	run.ship.scrap -= int(r.price)
	r.count = int(r.count) - 1
	Hooks.emit(&"store_bought", run, kind)  # StoreBox::Purchase: flag "store_purchase"
	match kind:
		"fuel":
			run.ship.fuel += 1
		"missiles":
			run.ship.missiles += 1
		"drones":
			run.ship.drone_parts += 1
	FtlData.play("buy")  # ItemStoreBox::Purchase → StoreBox::Purchase
	return "ok"


func repair_all_price(run: RunState) -> int:
	return (run.ship.max_hull - run.ship.hull) * repair_cost


## RepairStoreBox: 1 point or all, only while damaged.
func repair(all: bool, run: RunState) -> String:
	var ship := run.ship
	if ship.hull >= ship.max_hull:
		return "none"
	var points := ship.max_hull - ship.hull if all else 1
	var price := points * repair_cost
	if price > ship.scrap:
		return "scrap"
	ship.scrap -= price  # ModifyScrapCount → resource_changed (the HUD's "-N" scrap popup)
	ship.hull += points
	Hooks.emit(&"store_bought", run, "repair")  # RepairStoreBox::Purchase: flag "store_repair"
	FtlData.play("repairShip")  # RepairStoreBox::Purchase (own sound, not "buy")
	return "ok"


## Sell value: floor(cost / 2) (ModifyScrapCount income=false: no scrap augment bonus).
static func sell_value(kind: String, nm: String) -> int:
	return int(FtlData.item_info(kind, nm).get("cost", 0)) / 2


## Sellable equipment (rules/ship_management.md §3): every filled weapon / drone / augment / cargo / over-capacity
## box, as {kind, name, where, index, value, box}. The SELL tab drags boxes (ShipInventory.sell); this list keeps
## the STORE_SELL intent working.
static func sellable(run: RunState) -> Array:
	var out := []
	var inv := run.mgmt.inv
	var wheres := {ShipInventory.WEAPON: "weapons", ShipInventory.DRONE: "drones", ShipInventory.AUG: "augments",
		ShipInventory.CARGO: "cargo", ShipInventory.OVER: "over", ShipInventory.OVER_AUG: "over_aug"}
	for b in inv.sellable(run):
		var it := inv.item_at(run, b)
		out.append({"kind": it.kind, "name": it.name, "where": wheres[b.x], "index": b.y,
			"value": sell_value(String(it.kind), String(it.name)), "box": b})
	return out


## Equipment::MouseUp / OnTouch on the sell box: ModifyScrapCount(+value / 2) and the `buy` sound (the exe never
## plays sounds.xml's `sell`: no reference to it anywhere, only the "sell" store tab name).
static func sell(item: Dictionary, run: RunState) -> String:
	if run.mgmt.inv.sell(run, item.get("box", ShipInventory.NONE)) < 0:
		return "none"
	FtlData.play("buy")
	return "ok"
