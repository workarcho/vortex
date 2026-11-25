class_name WeaponState
extends RefCounted
## Weapon state: power, charge, target and firing
## (rules/timing_and_projectiles.md "Weapons", rules/targeting.md "Firing").

const DISCHARGE_RATE := 0.375

var bp := {}
var mount_index := 0
var powered := true
var bonus_power := 0  # zoltan bars given to this weapon (WeaponSystem::UpdateBonusPower); reactor cost = power - bonus
var charge := 0.0  # accumulated seconds

# Targeting
var autofire := false
var fire_when_ready := false
var target_ship: ShipState = null
var target_room := -1
var target_point := Vector2.ZERO
var target_point2 := Vector2.ZERO  # beams: end of the sweep (rules/weapons.md "Beams")
var pending_points: Array[Vector2] = []  # enemy AI: per-shot points for the next volley


# Current volley (burst): queued shots that leave in step with the weapon animation
var queued_shots := 0
var shot_timer := 0.0  # s until the next shot
var volley_entry_angle := -1.0  # shared by the whole volley
var volley_target: ShipState = null
var volley_point := Vector2.ZERO
var volley_points: Array[Vector2] = []  # one point per shot (enemy AI: a different room each); empty = all at volley_point
var volley_shot := 0  # index of the next shot of the volley
var charge_level := 0  # multi-charge weapons (chargeLevels >= 2): completed charge levels
var boost_level := 0  # chain weapons (<boost>): volleys fired in a row (rules/weapons.md "Chain")
var current_ship: ShipState = null  # ProjectileFactory::currentShipTarget (the ship's target ship, set_current_ship)
var anim := {}  # FtlData.weapon_anim: {length, charged_frame, fire_frame, fire_point, mount_point, sheet...}
# Visual state only (read by ShipView / WeaponArt; rules/weapon_visuals.md "Weapon mounts")
var fire_anim := -1.0  # s into the firing animation (chargedFrame -> last frame over fire_time); -1 = idle
var beam_level := -1.0  # beam being swept: fraction done (WeaponAnimation::SetFireLevel); -1 = none
# Artillery (rules/artillery.md): the system's own ProjectileFactory; its charge time is scaled by
# cooldown_modifier = 1.5 - 0.25 x artillery power (SetCooldownModifier keeps the charge fraction).
var is_artillery := false
var system_key := "artillery"  # artillery: the key of the ArtillerySystem that owns it (ShipState.artillery_system)
var cooldown_modifier := 1.0


func _init(blueprint: Dictionary, mount: int) -> void:
	bp = blueprint
	mount_index = mount
	anim = FtlData.weapon_anim(String(bp.get("weapon_art", "")))


## Duration of the firing animation (SetFireTime in the ProjectileFactory constructor).
func fire_time() -> float:
	if bp.type == "BOMB" or int(bp.get("charge_levels", 1)) > 1:
		return 1.0
	return 0.25


## Time from the start of the animation until the shot leaves (fireFrame frame).
func first_shot_delay() -> float:
	var span := float(int(anim.length) - int(anim.charged_frame))
	if span <= 0.0:
		return 0.0
	return float(int(anim.fire_frame) - int(anim.charged_frame)) / span * fire_time()


## Starts a volley: queues the shots and rolls a shared entry angle.
## `points`: optional per-shot target points (enemy AI); otherwise every shot goes to target_point.
func start_volley(rng: RandomNumberGenerator, points: Array[Vector2] = []) -> void:
	queued_shots = shots_this_volley()
	shot_timer = first_shot_delay()
	volley_entry_angle = float(rng.randi() % 360)
	volley_target = target_ship
	volley_point = target_point if points.is_empty() else points[0]
	volley_points = points.duplicate()
	volley_shot = 0
	fire_anim = 0.0
	_add_boost()


## ProjectileFactory::SetCurrentShip (ShipManager::SetTarget, every frame from ShipState.tick): a different target
## ship, or none (the enemy removed: destroyed, crew dead, fled, the beacon left), loses the chain boost
## (and shotsFiredAtTarget, not modelled). WeaponSystem::Jump itself keeps it; a new fight always has a new ship.
func set_current_ship(t: ShipState) -> void:
	if t != current_ship or t == null:
		boost_level = 0
	current_ship = t


## Chain weapons: every volley raises the boost level, up to `count` (cooldown boost) or `count + 1`
## (damage boost, whose first level adds nothing) (ProjectileFactory::Update).
func _add_boost() -> void:
	var b: Dictionary = bp.get("boost", {})
	if b.is_empty() or float(b.amount) <= 0.0:
		return
	boost_level = mini(boost_level + 1, int(b.count) + (1 if b.type == "damage" else 0))


## Damage boost: (boost_level - 1) × amount, added to the first positive field of
## damage, ion, crew damage, system damage (in that order).
func boost_damage_bonus() -> int:
	var b: Dictionary = bp.get("boost", {})
	if b.is_empty() or b.type != "damage" or boost_level <= 0:
		return 0
	return int((boost_level - 1) * float(b.amount))


## Damage of one projectile / beam of this weapon, chain bonus included.
func make_damage() -> Damage:
	var d := Damage.from_weapon(bp)
	var bonus := boost_damage_bonus()
	if bonus > 0:
		if d.damage > 0:
			d.damage += bonus
		elif d.ion > 0:
			d.ion += bonus
		elif d.pers_damage > 0:
			d.pers_damage += bonus
		elif d.sys_damage > 0:
			d.sys_damage += bonus
	return d


## Shots of the next volley: blueprint shots, or the current charge level for multi-charge weapons.
## A beam is one shot (its two points are start and end); flak is one shot that splits on launch.
func shots_this_volley() -> int:
	if is_beam():
		return 1
	if charge_levels() >= 2:
		return maxi(charge_level, 1)
	return int(bp.shots)


## Target point of the next shot of the current volley (advances the shot index).
func next_shot_point() -> Vector2:
	var p := volley_point
	if volley_shot < volley_points.size():
		p = volley_points[volley_shot]
	volley_shot += 1
	return p


func charge_levels() -> int:
	return int(bp.get("charge_levels", 1))


func is_beam() -> bool:
	return bp.get("type", "") == "BEAM"


func is_bomb() -> bool:
	return bp.get("type", "") == "BOMB"


func is_flak() -> bool:
	return bp.get("type", "") == "BURST"


## ProjectileFactory chargeLevel: single-charge weapons are at level 1 when fully charged.
func current_charge_level(weapons_crew_level: int) -> int:
	if charge_levels() >= 2:
		return charge_level
	return 1 if is_charged(weapons_crew_level) else 0


## Advances the volley; returns how many shots must leave in this step.
func tick_volley(seconds: float) -> int:
	if fire_anim >= 0.0:  # visual: the animation restarts while shots remain queued
		fire_anim += seconds
		if fire_anim >= fire_time():
			fire_anim = fire_anim - fire_time() if queued_shots > 0 else -1.0
	if queued_shots <= 0:
		return 0
	shot_timer -= seconds
	var n := 0
	while queued_shots > 0 and shot_timer <= 0.0:
		n += 1
		queued_shots -= 1
		shot_timer += fire_time()
	return n


func short_name() -> String:
	var s: String = bp.get("short", "")
	var t := FtlData.tr_id(s) if s != "" else ""
	return t if t != "" and t != s else FtlData.blueprint_title(String(bp.get("name", "")), "weapon")


func power_cost() -> int:
	return int(bp.power)


func missiles_per_shot() -> int:
	return int(bp.missiles)


func uses_missiles() -> bool:
	return missiles_per_shot() > 0


## Cooldown before the crew modifier: the blueprint cooldown minus boost_level × amount for a
## cooldown-boost chain weapon (baseCooldown in ProjectileFactory::Update).
func base_cooldown() -> float:
	var cd := float(bp.cooldown)
	var b: Dictionary = bp.get("boost", {})
	if not b.is_empty() and b.type == "cooldown" and boost_level > 0:
		cd -= boost_level * float(b.amount)
	return cd


func max_charge(weapons_crew_level: int) -> float:
	return base_cooldown() * charge_modifier(weapons_crew_level)


## ProjectileFactory::cooldownModifier: WeaponSystem::OnLoop sets the manning skill bonus every frame,
## ArtillerySystem::OnLoop 1.5 − 0.25 × power (here: skill bonus × `cooldown_modifier`).
func charge_modifier(weapons_crew_level: int) -> float:
	return EvasionRule.skill_bonus(EvasionRule.Skill.WEAPONS, weapons_crew_level) * cooldown_modifier


## ProjectileFactory::SetCooldownModifier: the charge is rescaled so its fraction is kept.
func set_cooldown_modifier(m: float) -> void:
	if is_equal_approx(m, cooldown_modifier) or cooldown_modifier <= 0.0:
		cooldown_modifier = m
		return
	charge = charge / cooldown_modifier * m
	cooldown_modifier = m


func is_charged(weapons_crew_level: int) -> bool:
	if charge_levels() >= 2:
		return charge_level >= 1  # a multi-charge weapon can fire from its first level
	return charge >= max_charge(weapons_crew_level)


func has_target() -> bool:
	return target_ship != null and target_room >= 0


## FTL's firing conditions (FireNextShot).
func should_fire(weapons_crew_level: int, ship_missiles: int) -> bool:
	if queued_shots > 0 or not powered or not is_charged(weapons_crew_level):
		return false
	if ship_missiles < missiles_per_shot():
		return false
	return (fire_when_ready or autofire) and has_target()


func set_target(ship: ShipState, room: int, point: Vector2, panel_autofire: bool,
		point2 := Vector2.ZERO) -> void:
	target_ship = ship
	target_room = room
	target_point = point
	target_point2 = point2
	autofire = panel_autofire
	fire_when_ready = not panel_autofire


func clear_target() -> void:
	pending_points.clear()
	target_ship = null
	target_room = -1
	fire_when_ready = false


## After firing: without autofire the target is released.
func after_fire() -> void:
	charge = 0.0
	charge_level = 0
	if not autofire:
		clear_target()
	fire_when_ready = false


func set_autofire(on: bool) -> void:
	if not on and autofire and has_target():
		fire_when_ready = true  # fires once more, then releases the target
	autofire = on


## `rate`: charge speed multiplier (AUTO_COOLDOWN, AugmentRule.charge_mult); drains are not scaled.
func tick(f: float, weapons_crew_level: int, hacked := false, rate := 1.0) -> void:
	var mx := max_charge(weapons_crew_level)
	if powered and hacked:
		# ProjectileFactory::Update with iHackLevel >= 2 (rules/hacking.md): the charge drains at 1 s per s
		# (the normal charge rate, reversed); a full multi-charge weapon first drops one stored level.
		if charge >= mx and charge_level > 0:
			charge_level -= 1
		charge = maxf(charge - f / GameClock.BASE, 0.0)
	elif powered:
		charge = minf(charge + f / GameClock.BASE * rate, mx)
		# Multi-charge: each full cooldown adds a level; the timer restarts until the last level.
		if charge_levels() >= 2 and charge >= mx and charge_level < charge_levels():
			charge_level += 1
			if charge_level < charge_levels():
				charge = 0.0
	else:
		# Unpowered (ProjectileFactory::Update): a full timer first drops one stored level; the timer
		# drains at 0.375/factor; once it is empty every stored level and the chain boost are lost.
		if charge <= 0.0:
			charge = 0.0
			charge_level = 0
			boost_level = 0
		else:
			if charge >= mx and charge_level > 0:
				charge_level -= 1
			charge = maxf(charge - f * DISCHARGE_RATE, 0.0)


func ratio(weapons_crew_level: int) -> float:
	return clampf(charge / max_charge(weapons_crew_level), 0.0, 1.0)


func speed() -> float:
	if float(bp.speed) > 0.0:
		return float(bp.speed)
	return 35.0 if bp.type == "MISSILES" else 60.0
