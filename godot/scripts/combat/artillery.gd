class_name ArtilleryRule
extends RefCounted
## Artillery, system 11 (rules/artillery.md): ArtillerySystem::OnLoop/Jump. Each artillery system owns a
## ProjectileFactory (`ShipState.artillery`, a WeaponState built from the blueprint weapon). It charges
## like any weapon with charge time = base cooldown x (1.5 - 0.25 x effective power), drains when
## unpowered, holds its charge while the target ship is cloaked, and fires by itself at random rooms.
## Combat fires it through the normal weapon path (beam / projectiles).

const MOD_BASE := 1.5
const MOD_PER_POWER := 0.25


## Charge-time modifier for an effective power (1 -> 1.25, 2 -> 1.0, 3 -> 0.75, 4 -> 0.5).
static func cooldown_modifier(power: int) -> float:
	return MOD_BASE - MOD_PER_POWER * power


## Charge time of an artillery weapon at a power (FED artillery: 50 / 40 / 30 / 20 s).
static func charge_time(w: WeaponState, power: int) -> float:
	return float(w.bp.cooldown) * cooldown_modifier(power)


## ArtillerySystem::OnLoop + ProjectileFactory::Update (`f` = speed factor of this frame).
static func tick(ship: ShipState, f: float) -> void:
	if ship.artillery.is_empty():
		return
	for w in ship.artillery:
		# Each ArtillerySystem drives its own ProjectileFactory (the flagship has one system per artillery room).
		var a := ship.artillery_system(w)
		var p := a.effective_power() if a else 0
		w.powered = p > 0
		w.set_cooldown_modifier(cooldown_modifier(p))
		if a and a.hacked:
			w.tick(f, 0, true)  # hacked factory: the charge drains like hacked weapons (rules/hacking.md)
			continue
		if ship.opponent_cloaked():
			continue  # charge frozen while the target is cloaked
		w.tick(f, 0, false, AugmentRule.charge_mult(ship))  # no manning bonus; AUTO_COOLDOWN applies


## Fires as soon as it is charged and the target ship exists, is alive and not cloaked.
static func ready_to_fire(ship: ShipState, w: WeaponState) -> bool:
	var t := ship.opponent
	return w.powered and w.queued_shots == 0 and w.is_charged(0) and t != null and not t.is_destroyed() \
		and not t.is_cloaked() and ship.hostile and t.hostile


## Target points: beam = a random room centre and the room centre farthest from it; others = one
## distinct random room centre per shot (GetRandomTargettingPoint, uniform rooms, no system priority).
static func pick_points(ship: ShipState, w: WeaponState, rng: RandomNumberGenerator) -> Array[Vector2]:
	var t := ship.opponent
	var pts: Array[Vector2] = []
	var centres: Array[Vector2] = []
	for r in t.layout.rooms:
		centres.append(t.room_rect(r.id).get_center())
	if centres.is_empty():
		return pts
	var start := centres[rng.randi() % centres.size()]
	pts.append(start)
	if w.is_beam():
		var far := start
		for c in centres:
			if c.distance_squared_to(start) > far.distance_squared_to(start):
				far = c
		pts.append(far)
		return pts
	var n := int(w.bp.shots)
	var guard := 0
	while pts.size() < n and guard < 1000:
		guard += 1
		var p := centres[rng.randi() % centres.size()]
		if pts.has(p) and pts.size() < centres.size():
			continue  # a duplicate is rolled again
		pts.append(p)
	return pts


## ArtillerySystem::Jump: charge 0 (combat starts empty).
static func jump(ship: ShipState) -> void:
	for w in ship.artillery:
		w.charge = 0.0
		w.charge_level = 0
