class_name Bomb
extends Node2D
## A teleported bomb (rules/weapons.md "Bombs"; FTL's BombProjectile). It appears directly on its target
## point in the destination space (no flight, shields ignored), plays its animation backwards
## (materialising), waits EXPLOSIVE_DELAY and explodes there (DamageArea).

const EXPLOSIVE_DELAY := 0.4  # s after the materialise animation (explosiveDelay)
const MISS_STEP := 117.0  # px: a dodged bomb drifts this far per step until it is outside every room

var bp := {}
var dmg: Damage
var owner_ship: ShipState
var target_ship: ShipState
var dest_space: Space
var target := Vector2.ZERO
var missed := false
var self_target := false
var dead := false
var phase := 0  # 0 materialising, 1 armed (delay), 2 exploding
var timer := 0.0
var _anim := {}
var _explosion := {}


func setup(w: WeaponState, from_space: Space, to_space: Space, point: Vector2, rng: RandomNumberGenerator) -> void:
	bp = w.bp
	dmg = w.make_damage()
	dmg.owner = 0 if from_space.ship.is_player else 1
	owner_ship = from_space.ship
	target_ship = to_space.ship
	dest_space = to_space
	target = point
	position = point
	self_target = owner_ship == target_ship
	z_index = 6
	_anim = FtlData.anim(String(bp.get("image", "")))
	var ex := String(bp.get("explosion", ""))
	_explosion = FtlData.anim(ex if ex != "" else "explosion_random")  # explosion_random: big2..4
	if _explosion.is_empty():
		_explosion = FtlData.anim("explosion_big1")
	timer = materialise_time()
	# BombProjectile::CollisionCheck (first contact): evasion, unless fired at its own ship.
	# GetDodged also counts as dodged when the target is not hostile.
	if not self_target and (not target_ship.hostile or target_ship.roll_dodged(rng)):
		missed = true
		position = miss_position(target_ship, point, rng.randi() % 4)
		dest_space.show_miss(position)
		FtlData.play_random(bp.get("miss_sounds", []))
	Combat.log("%s (bomb) -> %s room %d%s" % [bp.name, target_ship.blueprint.name,
		target_ship.room_at(point), " MISSED" if missed else ""])


## Length of the materialise animation (the bomb image animation, played in reverse).
func materialise_time() -> float:
	return maxf(float(_anim.get("time", 0.35)), 0.01)


## Dodged bomb: from the target point, step MISS_STEP px in one direction (0 up, 1 down, 2 left,
## 3 right) until the point is outside every room.
static func miss_position(ship: ShipState, start: Vector2, dir: int) -> Vector2:
	var step: Vector2 = [Vector2(0, -MISS_STEP), Vector2(0, MISS_STEP), Vector2(-MISS_STEP, 0),
		Vector2(MISS_STEP, 0)][dir]
	var p := start
	for i in 100:
		if ship.room_at(p) < 0:
			break
		p += step
	return p


func step(f: float, rng: RandomNumberGenerator) -> void:
	if dead:
		return
	timer -= f / GameClock.BASE
	queue_redraw()
	if timer > 0.0:
		return
	match phase:
		0:
			phase = 1
			timer = EXPLOSIVE_DELAY
		1:
			_explode(rng)
			phase = 2
			timer = maxf(float(_explosion.get("time", 0.5)), 0.1)
		_:
			dead = true


func _explode(rng: RandomNumberGenerator) -> void:
	FtlData.play_random(bp.get("hit_ship_sounds", []))
	if missed or target_ship.is_destroyed():
		return
	# ZOLTAN_BYPASS on the firing ship: the bomb ignores the super shield (rules/augments.md §2).
	if target_ship.super_shield > 0 and not self_target and not AugmentRule.bypasses_super(owner_ship):
		# Zoltan super shield (rules/weapons.md): the bomb hits the super shield (damage + sysDamage).
		var before := target_ship.super_shield
		target_ship.damage_super_shield(dmg.damage + dmg.sys_damage)
		if target_ship.super_shield < before:
			target_ship.shield_popped(position, true)
		dest_space.flash_shield(position)
		return
	var room := target_ship.room_at(position)
	var r := target_ship.apply_damage(room, dmg, rng)
	Combat.log("%s (bomb) -> %s: room %d: system -%d, ion %d, crew %d%s%s%s → hull %d" % [bp.name,
		target_ship.blueprint.name, room, r.system, r.ion, r.crew, ", FIRE" if r.fire else "",
		", BREACH" if r.breach else "", ", LOCKDOWN (not modelled)" if r.get("lockdown", false) else "",
		target_ship.hull])
	if r.breach:
		FtlData.play("hullBreach")
	var y := -36.0
	dest_space.show_resists(r, position)
	if r.ion > 0:
		dest_space.show_number(r.ion, position, Space.MSG_ION)
	var extra_sys: int = r.system - maxi(dmg.damage, 0)
	if extra_sys > 0:
		dest_space.show_number(extra_sys, position, Space.MSG_SYSTEM)
	if r.hull > 0:
		dest_space.show_number(r.hull, position, Space.MSG_HULL)
	if dmg.crew_hp_damage() < 0 and r.crew > 0:
		dest_space.show_text("HEAL", position + Vector2(0, y), FtlColors.GREEN)
	if r.get("lockdown", false):
		dest_space.show_text("LOCKDOWN", position + Vector2(0, y - 18), FtlColors.BLUE)


func _draw() -> void:
	match phase:
		0:
			if not _anim.is_empty():  # reverse: last frame first
				var p := 1.0 - timer / materialise_time()
				Projectile.draw_anim_frame(self, _anim, 1.0 - clampf(p, 0.0, 0.999))
		1:
			if not _anim.is_empty():
				Projectile.draw_anim_frame(self, _anim, 0.0)
		_:
			if not _explosion.is_empty():
				var t := maxf(float(_explosion.get("time", 0.5)), 0.1)
				Projectile.draw_anim_frame(self, _explosion, clampf(1.0 - timer / t, 0.0, 0.999))
