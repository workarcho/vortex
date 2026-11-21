class_name AugmentRule
extends RefCounted
## Augment registry and the engine rules of the 32 vanilla augments (rules/augments.md).
##
## Storage stays `ShipState.augments` (an Array of ids, duplicates = stacked copies, slot order = equipment
## order). Everything that asks about an augment goes through here:
## - `count(ship, id)` (ShipObject augList[id]), `has()` (count > 0),
## - `value(ship, id)` = count x blueprint <value> (GetAugmentationValue: linear stacking), passed through the
##   `augment_value` filter so mods can rebalance numbers,
## - `can_add()` / `add()`: max 3 per ship (any ship, enemies and events included; ShipObject::AddAugmentation),
##   `duplicate_refused()`: a non-stackable augment already owned (store `have_<id>`, reward AUGMENT_FULL).
##   Only ION_ARMOR, SCRAP_COLLECTOR, AUTO_COOLDOWN, SHIELD_RECHARGE, FTL_BOOSTER and STASIS_POD are
##   <stackable>; the first five read `value()` so each copy adds its <value>, STASIS_POD has no effect.
## - the per-augment rules below, each called from its natural engine site (rules/augments.md §2, §6).
## The QoL "Start with scanners" (mods/qol) patches the blueprint data, so ADV_SCANNERS arrives through the
## ship's <aug> list like any other augment and is read through this registry.

const MAX := 3

## The 32 augments with an <augBlueprint> at runtime (21 blueprints.xml + 11 dlcBlueprints.xml).
const ALL := ["ROCK_ARMOR", "SYSTEM_CASING", "CRYSTAL_SHARDS", "ENERGY_SHIELD", "NANO_MEDBAY", "SLUG_GEL",
	"CREW_STIMS", "DRONE_SPEED", "ION_ARMOR", "CLOAK_FIRE", "REPAIR_ARM", "SCRAP_COLLECTOR", "ADV_SCANNERS",
	"AUTO_COOLDOWN", "SHIELD_RECHARGE", "WEAPON_PREIGNITE", "FTL_BOOSTER", "FTL_JUMPER", "DRONE_RECOVERY",
	"FTL_JAMMER", "STASIS_POD", "O2_MASKS", "EXPLOSIVE_REPLICATOR", "FIRE_EXTINGUISHERS", "FLEET_DISTRACTION",
	"TELEPORT_HEAL", "BATTERY_BOOSTER", "DEFENSE_SCRAMBLER", "BACKUP_DNA", "HACKING_STUN", "LIFE_SCANNER",
	"ZOLTAN_BYPASS"]

## Augments whose <value> the engine never reads (hard-coded numbers in the exe; §4). STASIS_POD has no effect.
const VALUE_IGNORED := ["ENERGY_SHIELD", "SLUG_GEL", "CLOAK_FIRE", "FTL_JAMMER", "EXPLOSIVE_REPLICATOR",
	"STASIS_POD"]

const SUPER_SHIELD_POINTS := 5  # ENERGY_SHIELD: Shields::OnLoop fill (value 2 unused)
const SLUG_GEL_REPAIR := 0.75  # OuterHull::OnLoop PartialRepair(0.75) per breach -> ~16.7 s
const STIMS_WALK_TIME := 0.7  # CrewAnimation: walk cycle 0.7 s instead of 1.0 s with CREW_STIMS
const REPAIR_ARM_HULL := 2  # ModifyScrapCount: DamageHull(-2) on every scrap income
const HACK_STUN := 0.2  # HACKING_STUN: fStunTime = max(fStunTime, 0.2) each frame of a pulse
const RESIST_ROOM_COLOR := Color(40 / 255.0, 210 / 255.0, 230 / 255.0)  # ION_ARMOR "RESIST" on a room
const RESIST_SHIELD_COLOR := Color(40 / 255.0, 240 / 255.0, 40 / 255.0)  # ION_ARMOR "RESIST" on a shield
const SUPER_DAMAGE_COLOR := Color(40 / 255.0, 240 / 255.0, 40 / 255.0)  # green number of a super-shield hit


# ---------------------------------------------------------------- registry

static func count(ship: ShipState, id: String) -> int:
	return ship.augments.count(id) if ship != null else 0


static func has(ship: ShipState, id: String) -> bool:
	return count(ship, id) > 0


## Blueprint <value> of one copy (`1.f` reads as 1.0); 0 for an unknown id.
static func data_value(id: String) -> float:
	var info := FtlData.item_info("augment", id)
	return float(info.get("value", 0.0)) if not info.is_empty() else 0.0


## GetAugmentationValue: count x <value> (0 without the augment), then the `augment_value` filter.
static func value(ship: ShipState, id: String) -> float:
	var n := count(ship, id)
	var v := n * data_value(id) if n > 0 else 0.0
	var fv: Variant = Hooks.filter(&"augment_value", v, ship, id)
	return v if Hooks.is_cancel(fv) or fv == null else float(fv)


static func stackable(id: String) -> bool:
	return bool(FtlData.item_info("augment", id).get("stackable", false))


## True when a second copy of `id` is refused because it is owned and its <stackable> is false
## (AugmentStoreBox::CanHold `have_<id>`; WorldManager::ModifyResources AUGMENT_FULL). Only the store and
## event rewards ask; ShipObject::AddAugmentation itself never checks <stackable>.
static func duplicate_refused(ship: ShipState, id: String) -> bool:
	return has(ship, id) and not stackable(id)


## AugmentStoreBox::CanHold: "" when `ship` may take one more `id`, else the reason
## (`max_augments`, `have_<id>` for a non-stackable one already owned).
static func can_add(ship: ShipState, id: String, max_augs := MAX) -> String:
	if ship.augments.size() >= max_augs:
		return "max_augments"
	if duplicate_refused(ship, id):
		return "have_" + id
	return ""


## ShipObject::AddAugmentation: refused (false) at 3 augments; no <stackable> check here. The store (can_add)
## and event rewards (duplicate_refused -> AUGMENT_FULL) stop a non-stackable duplicate before calling it, so in
## vanilla play only the 6 stackable augments can be owned twice (rules/augments.md "Stacking").
static func add(ship: ShipState, id: String) -> bool:
	if ship.augments.size() >= MAX:
		return false
	ship.augments.append(id)
	Hooks.emit(&"augment_added", ship, id)
	return true


static func remove(ship: ShipState, id: String) -> bool:
	if not ship.augments.has(id):
		return false
	ship.augments.erase(id)
	Hooks.emit(&"augment_removed", ship, id)
	return true


## The ship whose augments a crew member uses (its owner, iShipId), wherever it stands.
static func crew_owner(on: ShipState, c: CrewMember) -> ShipState:
	if on == null:
		return null
	return on if c.player_owned == on.is_player else on.opponent


# ---------------------------------------------------------------- damage (ShipManager::ResistDamage)

## Percent resist roll (ROCK_ARMOR hull, SYSTEM_CASING system): `1 + r%100 <= int(v x 100)`. No roll without
## the augment.
static func resist(ship: ShipState, id: String, rng: RandomNumberGenerator) -> bool:
	if not has(ship, id):
		return false
	var chance := int(value(ship, id) * 100.0 + 1e-4)
	return 1 + rng.randi() % 100 <= chance


## ION_ARMOR: `1 + r%10 <= int(v x count x 10)` -> 50 % per copy, always with two.
static func ion_resist(ship: ShipState, rng: RandomNumberGenerator) -> bool:
	if not has(ship, "ION_ARMOR"):
		return false
	var chance := int(value(ship, "ION_ARMOR") * 10.0 + 1e-4)
	return 1 + rng.randi() % 10 <= chance


## CRYSTAL_SHARDS (ShipManager::CheckCrystalAugment) after a hit with hull damage > 0: needs a current target;
## `r%100 < v x 100` (10 %) queues a shard from `at` (own ship coordinates) in `ship.pending_shards`
## (superBarrage); Combat launches it (CRYSTAL_1, damage 1, no owner) at a random room of the target.
static func crystal_check(ship: ShipState, at: Vector2, rng: RandomNumberGenerator) -> bool:
	if not has(ship, "CRYSTAL_SHARDS") or ship.opponent == null or ship.opponent.is_destroyed():
		return false
	if rng.randi() % 100 >= int(value(ship, "CRYSTAL_SHARDS") * 100.0 + 1e-4):
		return false
	ship.pending_shards.append({"from": at, "heading": float(rng.randi() % 360)})
	return true


# ---------------------------------------------------------------- rates

## Crew move speed multiplier: CREW_STIMS (+25 %) for crew, DRONE_SPEED (+25 %) for crew drones.
static func move_mult(owner: ShipState, c: CrewMember) -> float:
	if owner == null:
		return 1.0
	return 1.0 + value(owner, "DRONE_SPEED" if c.is_drone() else "CREW_STIMS")


## Walk cycle length (CrewAnimation::OnUpdate): 0.7 s for stimmed crew, else 1.0 s.
static func walk_time(owner: ShipState, c: CrewMember) -> float:
	return STIMS_WALK_TIME if owner != null and not c.is_drone() and has(owner, "CREW_STIMS") else 1.0


## Suffocation damage multiplier: O2_MASKS value (0.5) for the owner's crew.
static func suffocation_mult(owner: ShipState) -> float:
	return value(owner, "O2_MASKS") if has(owner, "O2_MASKS") else 1.0


## NANO_MEDBAY (MedbaySystem::GetHealingSpeed): every room but the medbay heals at the value (0.25) for the
## ship's own crew; needs the medbay system (not its power); 0 while the medbay is actively hacked.
static func nano_speed(ship: ShipState, room: int) -> float:
	if not has(ship, "NANO_MEDBAY"):
		return 0.0
	var m := ship.sys("medbay")
	if m == null or m.room == room or m.hacked:
		return 0.0
	return value(ship, "NANO_MEDBAY")


## AUTO_COOLDOWN: weapon (and artillery) charge rate x (1 + 0.1 x count).
static func charge_mult(ship: ShipState) -> float:
	return 1.0 + value(ship, "AUTO_COOLDOWN")


## SHIELD_RECHARGE: shield layer charge x (1 + 0.15 x count).
static func shield_recharge_mult(ship: ShipState) -> float:
	return 1.0 + value(ship, "SHIELD_RECHARGE")


# ---------------------------------------------------------------- resources

## ShipManager::ModifyScrapCount(amount, income = true): SCRAP_COLLECTOR +10 % per copy; REPAIR_ARM -15 % only
## while hull < max (checked before its repair) and +2 hull on every gain. Returns the amount actually added
## (the caller adds it). Non-income changes (store, sales) never come here.
static func scrap_income(ship: ShipState, amount: int) -> int:
	if amount <= 0:
		return amount
	var ra := value(ship, "REPAIR_ARM") if has(ship, "REPAIR_ARM") and ship.hull < ship.max_hull else 0.0
	var sc := value(ship, "SCRAP_COLLECTOR")
	var out := int(amount * (1.0 + sc - ra) + 1e-4)
	if has(ship, "REPAIR_ARM"):
		ship.take_hull_damage(-REPAIR_ARM_HULL)  # DamageHull(-2): once per gain, even at full hull
	return out


## ProjectileFactory::SpendMissiles: with EXPLOSIVE_REPLICATOR `(r & 1) == 0` saves the shot (nothing spent;
## event 12 -> the "0" popup at the missile counter). Drone parts are never saved. Returns true when saved.
static func spend_missiles(ship: ShipState, n: int, rng: RandomNumberGenerator, w: WeaponState = null) -> bool:
	if n <= 0:
		return false
	if has(ship, "EXPLOSIVE_REPLICATOR") and (rng.randi() & 1) == 0:
		ship.missiles_saved += 1
		Hooks.emit(&"missile_saved", ship, w)
		return true
	ship.missiles -= n
	return false


# ---------------------------------------------------------------- per frame (ShipManager / OuterHull::OnLoop)

## SLUG_GEL (breaches self-seal, 0.75 repair speed), FIRE_EXTINGUISHERS (every fire, value 1.0 repair speed),
## HACKING_STUN of the opponent (crew in a room under its hacking pulse stay stunned).
static func tick(ship: ShipState, seconds: float) -> void:
	if has(ship, "SLUG_GEL"):
		for room in ship.breaches.keys():
			for tile in ship.breaches[room].keys():
				var b: Dictionary = ship.breaches[room][tile]
				b.health -= CrewMember.REPAIR_RATE * SLUG_GEL_REPAIR * seconds
				if b.health <= 0.0:
					ship.seal_breach(room, tile)
	if has(ship, "FIRE_EXTINGUISHERS"):
		var sp := value(ship, "FIRE_EXTINGUISHERS")
		for room in ship.fires.keys():
			for tile in ship.fires.get(room, {}).keys():
				var f: Dictionary = ship.fires[room][tile]
				f.health -= CrewMember.REPAIR_RATE * sp * seconds
				if f.health <= 0.0:
					ship.extinguish(room, tile)
	var o := ship.opponent
	if o != null and has(o, "HACKING_STUN"):
		for s in ship.systems.values():
			if not s.hacked:
				continue
			for c in ship.crew:
				if c.is_alive() and c.room == s.room:
					c.stun = maxf(c.stun, HACK_STUN)


# ---------------------------------------------------------------- jump (WeaponSystem::Jump)

## WeaponSystem::Jump: with WEAPON_PREIGNITE every weapon gets ForceCoolup — a powered one is full (multi-charge:
## one level banked), an unpowered one is left as it is (ForceCoolup returns at once; its charge keeps draining);
## without the augment every charge is lost on the jump.
static func jump_weapons(ship: ShipState) -> void:
	var pre := has(ship, "WEAPON_PREIGNITE")
	for w in ship.weapons:
		if pre:
			if not w.powered:
				continue
			w.charge = w.max_charge(ship.crew_level_in("weapons"))
			w.charge_level = 1 if w.charge_levels() >= 2 else 0
			if w.charge_levels() >= 2:
				w.charge = 0.0
		else:
			w.charge = 0.0
			w.charge_level = 0


## DEFENSE_SCRAMBLER (ShipManager::SetTarget of the other ship): its space drones are disrupted while their
## target has the augment.
static func drones_disrupted(drone_owner: ShipState) -> bool:
	return drone_owner != null and has(drone_owner.opponent, "DEFENSE_SCRAMBLER")


## LIFE_SCANNER of the player ship: crew in blacked-out rooms are drawn (ShipManager::OnRender).
static func life_scanner(viewed: ShipState) -> bool:
	var me := viewed if viewed.is_player else viewed.opponent
	return has(me, "LIFE_SCANNER")


## ZOLTAN_BYPASS of the acting ship: teleporter, mind control and bombs ignore the target's super shield.
static func bypasses_super(ship: ShipState) -> bool:
	return has(ship, "ZOLTAN_BYPASS")
