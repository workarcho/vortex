class_name SuperShieldRule
extends RefCounted
## Zoltan super shield (rules/augments.md §3; drone side rules/drones.md §7). State lives in ShipState
## (`super_shield` = Shields power.super.first, `super_shield_max` = .second); both the ENERGY_SHIELD augment
## and the super shield drone write the same two fields.
##
## - `loop`: Shields::OnLoop (first thing in the shields tick): with ENERGY_SHIELD, max < 1 -> points 5; max 5.
##   A ship therefore gets 5 points on its first frame and nothing refills them in a fight afterwards.
## - `jump`: Shields::Jump: points = max with ENERGY_SHIELD, else 0 (a drone-made super shield is lost).
## - `instant_charge`: enemy creation / bought shields (InstantCharge): 5 with ENERGY_SHIELD.
## - `drain`: ShipAI stand-down (not hostile, or own hull <= 0): points = max = 0. A neutral Zoltan is refilled
##   by its own loop and drained by its AI in the same frame -> shows 0.
## - `power`: PowerSuperShields(n): points = max = n (flagship stage 3: 12, drawn as 5 boxes).
## - `hit`: CollisionReal with super points > 0 (the projectile is always stopped).

const AUG := "ENERGY_SHIELD"
const FLAGSHIP_POINTS := 12  # BossShip::StartStage(3): PowerSuperShields


static func loop(ship: ShipState) -> void:
	if AugmentRule.has(ship, AUG):
		if ship.super_shield_max < 1:
			ship.super_shield = AugmentRule.SUPER_SHIELD_POINTS
		ship.super_shield_max = AugmentRule.SUPER_SHIELD_POINTS
	ship.super_shield = maxi(ship.super_shield, 0)


static func jump(ship: ShipState) -> void:
	ship.super_shield = ship.super_shield_max if AugmentRule.has(ship, AUG) else 0


static func instant_charge(ship: ShipState) -> void:
	if AugmentRule.has(ship, AUG):
		ship.super_shield = AugmentRule.SUPER_SHIELD_POINTS
		ship.super_shield_max = AugmentRule.SUPER_SHIELD_POINTS


static func drain(ship: ShipState) -> void:
	ship.super_shield = 0
	ship.super_shield_max = 0


static func power(ship: ShipState, points: int) -> void:
	ship.super_shield = points
	ship.super_shield_max = points


## Flagship stage hook (BossShip::StartStage; the flagship itself is not implemented yet): stage 3 powers a
## 12-point super shield.
static func flagship_stage(ship: ShipState, stage: int) -> void:
	if stage == 3:
		power(ship, FLAGSHIP_POINTS)


## Shields::CollisionReal with super points: ion > 0 -> ION_ARMOR roll (0 on success, green RESIST), else
## 2 x ion; total = max(damage + ion term, 0) is removed (piercing ignored, normal layers untouched).
## Returns {lost, resisted}; also stored in `ship.last_super_hit` for the visuals.
static func hit(ship: ShipState, d: Damage, rng: RandomNumberGenerator) -> Dictionary:
	var ion_term := 0
	var resisted := false
	if d.ion > 0:
		if AugmentRule.ion_resist(ship, rng):
			resisted = true
			Hooks.emit(&"augment_resisted", ship, "ION_ARMOR", -1)
		else:
			ion_term = 2 * d.ion
	var total := maxi(d.damage + ion_term, 0)
	var before := ship.super_shield
	ship.super_shield = maxi(ship.super_shield - total, 0)
	ship.last_super_hit = {"lost": before - ship.super_shield, "total": total, "resisted": resisted}
	return ship.last_super_hit


## Max points drawn by the bubble alpha / HUD (`points / max(5, max)`).
static func alpha(ship: ShipState) -> float:
	return float(ship.super_shield) / maxf(5.0, float(ship.super_shield_max))
