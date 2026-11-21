class_name Projectile
extends Node2D
## FTL projectile using the "two spaces" model (rules/timing_and_projectiles.md).
## The logic lives here; Combat moves it from one Space to another by changing its parent node.

const ENTRY_RADIUS := 600.0
const EXIT_RADIUS := 700.0

var owner_ship: ShipState
var target_ship: ShipState
var current_space: Space
var destination_space: Space

var weapon: Dictionary
var dmg: Damage
var speed_units := 60.0
var heading := -1.0  # degrees; -1 = unassigned
var entry_angle := -1.0  # degrees; -1 = roll on entry (otherwise shared by the volley)
var target := Vector2.ZERO
var last_position := Vector2.ZERO

var inside_shield := false
var missed := false
var passed_target := false
var dead := false
var dying := 0.0  # > 0: death animation (explosion)

var crystal_shard := false  # CRYSTAL_SHARDS shot (owner -1; kill = ACH_CRYSTAL_SHARD, achievements not modelled)
var fake := false  # flak "fake" debris: visual only (no dodge roll, no shield or hull hit)
var spin := 0.0  # deg/s (flak debris; <spin>)
var _spin_angle := 0.0
var _fixed_frame := -1  # flak debris: one random frame, not animated
var _anim := {}
var _explosion := {}
var _anim_time := 0.0


## `image`: flight animation override (flak debris); `is_fake`: flak fake debris.
## A drone shot (rules/drones.md §5-§6): starts at the drone, already in `space` (no transfer). `target`
## = the ship it is aimed at (combat drone), or null for a defence drone shot (only hits projectiles and
## drones; never a ship).
func setup_drone(w: WeaponState, owner: ShipState, space: Space, start: Vector2, target_point: Vector2,
		target_ship_or_null: ShipState) -> void:
	weapon = w.bp
	dmg = w.make_damage()
	dmg.owner = 0 if owner.is_player else 1
	speed_units = w.speed()
	owner_ship = owner
	target_ship = target_ship_or_null
	current_space = space
	destination_space = space
	position = start
	last_position = start
	target = target_point
	heading = rad_to_deg((target_point - start).angle())
	inside_shield = target_ship != null and target_ship.inside_shield(start)
	_anim = FtlData.anim(String(weapon.image))
	spin = float(weapon.get("spin", 0.0))
	z_index = 5
	var ex := String(weapon.get("explosion", ""))
	if ex == "":
		ex = "explosion_random" if _is_missile() else "explosion_missile1"
	_explosion = FtlData.anim(ex)


## Asteroid (rules/hazards.md §2): 1 damage, 20 % fire, 10 % breach, no owner, 560 px/s straight at a room
## centre of `space`'s ship, spinning 160°/s, image asteroids/asteroid<n>.png, defence drones may shoot it.
var static_tex: Texture2D = null


func setup_asteroid(space: Space, start: Vector2, target_point: Vector2, image_n: int, angle: float) -> void:
	weapon = {"name": "ASTEROID", "type": "ASTEROID", "drone_targetable": true, "image": "",
		"hit_ship_sounds": ["hitHull1", "hitHull2", "hitHull3"], "hit_shield_sounds": ["hitShield1", "hitShield2",
		"hitShield3"], "miss_sounds": [], "damage": 1, "sp": 0}
	dmg = Damage.new()
	dmg.damage = 1
	dmg.fire_chance = 2
	dmg.breach_chance = 1
	dmg.owner = -1
	speed_units = HazardRule.AST_SPEED
	owner_ship = null
	target_ship = space.ship
	current_space = space
	destination_space = space
	position = start
	last_position = start
	target = target_point
	heading = rad_to_deg((target_point - start).angle())
	spin = HazardRule.AST_SPIN
	_spin_angle = angle
	static_tex = FtlData.texture("img/asteroids/asteroid%d.png" % image_n)
	z_index = 5
	_explosion = FtlData.anim("explosion1")


## Targetable type for defence drones (rules/drones.md §6): <drone_targetable> 2, missiles 1, lasers /
## ion / drone lasers / flak pieces 4, anything else 5; fake flak debris is never a target (-1).
func targetable_type() -> int:
	if fake:
		return -1
	if weapon.get("drone_targetable", false):
		return Drone.T_ASTEROID
	match String(weapon.get("type", "")):
		"MISSILES":
			return Drone.T_MISSILE
		"LASER", "BURST":
			return Drone.T_LASER
	return Drone.T_OTHER


## Shot down (defence drone laser, projectile collision, drone hit): death animation, no damage.
func destroy() -> void:
	if dying <= 0.0 and not dead:
		_die()


func setup(w: WeaponState, from_space: Space, to_space: Space, start: Vector2, target_point: Vector2,
		image := "", is_fake := false) -> void:
	weapon = w.bp
	dmg = w.make_damage()
	dmg.owner = 0 if from_space.ship.is_player else 1
	fake = is_fake
	if fake:
		dmg = Damage.new()
	speed_units = w.speed()
	owner_ship = from_space.ship
	target_ship = to_space.ship
	current_space = from_space
	destination_space = to_space
	position = start
	last_position = start
	target = target_point
	heading = owner_ship.fire_heading
	_anim = FtlData.anim(image if image != "" else String(weapon.image))
	if image != "" and not _anim.is_empty():
		_fixed_frame = randi() % _anim.frames.size()  # SetCurrentFrame(random) + Stop
	spin = float(weapon.get("spin", 0.0))
	z_index = -1  # own outgoing shots render under the ship (SpaceManager::OnRenderProjectiles layer 2)
	# Death animation: the blueprint <explosion>, else explosion_missile1 (Projectile) or a random
	# explosion_big2..4 (Missile: "explosion_random").
	var ex := String(weapon.get("explosion", ""))
	if ex == "":
		ex = "explosion_random" if _is_missile() else "explosion_missile1"
	_explosion = FtlData.anim(ex)


## Missile-class shots (missiles, crystal shards) draw nose-first; the rest (lasers, ion, flak) centred.
func _is_missile() -> bool:
	return weapon.get("type", "") == "MISSILES" and not fake and _fixed_frame < 0


func in_destination() -> bool:
	return current_space == destination_space


## One simulation step. f = clock factor.
func step(f: float, rng: RandomNumberGenerator) -> void:
	if dying > 0.0:
		dying -= f / GameClock.BASE
		if dying <= 0.0:
			dead = true
		queue_redraw()
		return
	last_position = position
	var dist := speed_units * f
	if in_destination() and not passed_target:
		position = position.move_toward(target, dist)
		if position == target:
			passed_target = true
			heading = rad_to_deg((target - last_position).angle())
	else:
		position += Vector2.from_angle(deg_to_rad(heading)) * dist
	_anim_time += f / GameClock.BASE
	_spin_angle += spin * f / GameClock.BASE

	if in_destination():
		_check_collisions(rng)
	if not dead and dying <= 0.0:
		var center := current_space.ship.shield_center
		if position.distance_to(center) > EXIT_RADIUS and _leaving(center):
			_transfer(rng)
	queue_redraw()


func _leaving(center: Vector2) -> bool:
	return (position - center).dot(position - last_position) > 0.0


func _transfer(rng: RandomNumberGenerator) -> void:
	if in_destination():
		dead = true  # already went through its destination
		return
	# Enters the destination space 600 px from the shield center, at the volley's angle
	# (or a random one if it has none).
	if entry_angle < 0.0:
		entry_angle = float(rng.randi() % 360)
	var angle := deg_to_rad(entry_angle)
	current_space = destination_space
	var center := destination_space.ship.shield_center
	position = center + Vector2.from_angle(angle) * ENTRY_RADIUS
	last_position = position
	heading = rad_to_deg((target - position).angle())
	inside_shield = false
	z_index = 5
	reparent(destination_space.world, false)


func _check_collisions(rng: RandomNumberGenerator) -> void:
	var ship := target_ship
	# A dying ship stays a target until its explosion is over (SpaceManager keeps it until DestroyedDone).
	if ship == null or ship.destroyed_done() or fake:
		return
	var now_inside := ship.inside_shield(position)
	if now_inside and not inside_shield and not missed:
		var result := ship.on_projectile_enters_shield(dmg, rng, position)
		Combat.log("%s -> %s: crosses shield => %s (layers now %d, evasion %d%%)" % [
			weapon.name, ship.blueprint.name, result, ship.shield_layers, ship.dodge_factor()])
		match result:
			"miss":
				missed = true
				Hooks.emit(&"projectile_dodged", ship, weapon, position)
				FtlData.play_random(weapon.get("miss_sounds", []))
				destination_space.show_miss(position)
			"super":
				Hooks.emit(&"projectile_absorbed", ship, weapon, "super")
				# Zoltan super shield (rules/augments.md §3): absorbed, normal layers untouched; green number
				# of the points lost (if any), green RESIST when ION_ARMOR cancelled the ion part.
				var h: Dictionary = ship.last_super_hit
				if bool(h.get("resisted", false)):
					destination_space.show_resist(position, AugmentRule.RESIST_SHIELD_COLOR)
				if int(h.get("total", 0)) != 0:
					destination_space.show_number(int(h.total), position, AugmentRule.SUPER_DAMAGE_COLOR)
				FtlData.play_random(weapon.get("hit_shield_sounds", []))
				_die()
				destination_space.flash_shield(position)
				return
			"shield":
				Hooks.emit(&"projectile_absorbed", ship, weapon, "shield")
				var ion_resisted := ship.shield_ion_resisted  # ION_ARMOR (read before shield_absorb resets it)
				ship.shield_absorb(dmg)
				if dmg.ion > 0 and ion_resisted:
					destination_space.show_resist(position, AugmentRule.RESIST_SHIELD_COLOR)
				elif dmg.ion > 0:
					destination_space.show_number(dmg.ion, position, Space.MSG_ION)
				FtlData.play_random(weapon.get("hit_shield_sounds", []))
				_die()
				destination_space.flash_shield(position)
				return
	inside_shield = now_inside
	if passed_target and not missed and dying <= 0.0:
		var room := ship.room_at(target)
		if room < 0:
			# Target point outside every room (flak spread): DamageArea hits nothing, the projectile
			# counts as missed and keeps flying (Projectile::CollisionCheck).
			missed = true
			FtlData.play_random(weapon.get("miss_sounds", []))
			return
		var r := ship.apply_damage(room, dmg, rng)
		r["shard"] = crystal_shard  # Damage crystalShard (ACH_CRYSTAL_SHARD)
		Hooks.emit(&"projectile_hit", ship, weapon, room, r)
		FtlData.play_random(weapon.get("hit_ship_sounds", []))
		if r.breach:
			FtlData.play("hullBreach")
		Combat.log("%s -> %s: HIT room %d: hull -%d, system -%d, ion %d, crew %d%s%s → hull %d" % [
			weapon.name, ship.blueprint.name, room, r.hull, r.system, r.ion, r.crew,
			", FIRE" if r.fire else "", ", BREACH" if r.breach else "", ship.hull])
		_show_numbers(r)
		_die()


## Damage numbers (DamageMessage): ion (cyan), extra system damage (red), hull (white).
func _show_numbers(r: Dictionary) -> void:
	destination_space.show_resists(r, position)
	if r.ion > 0:
		destination_space.show_number(r.ion, position, Space.MSG_ION)
	var extra_sys: int = r.system - maxi(dmg.damage, 0)
	if extra_sys > 0:
		destination_space.show_number(extra_sys, position, Space.MSG_SYSTEM)
	if r.hull > 0:
		destination_space.show_number(r.hull, position, Space.MSG_HULL)


func _die() -> void:
	dying = _death_time()
	_anim_time = 0.0


## Death animation length: the blueprint <explosion> animation, or a short generic flash.
func _death_time() -> float:
	return maxf(float(_explosion.time), 0.1) if not _explosion.is_empty() else 0.4


func _draw() -> void:
	if dying > 0.0:
		if not _explosion.is_empty():
			draw_anim_frame(self, _explosion, 1.0 - dying / _death_time())
			return
		var t := 1.0 - dying / 0.4
		draw_circle(Vector2.ZERO, 6.0 + 22.0 * t, Color(1.0, 0.7, 0.2, 1.0 - t))
		return
	if static_tex != null:
		draw_set_transform(Vector2.ZERO, deg_to_rad(_spin_angle))
		draw_texture(static_tex, -static_tex.get_size() / 2.0)
		draw_set_transform(Vector2.ZERO, 0)
		return
	if _anim.is_empty():
		draw_circle(Vector2.ZERO, 4, Color.RED)
		return
	var frames: Array = _anim.frames
	var ft: float = maxf(float(_anim.time), 0.01) / frames.size()
	var src: Rect2 = frames[(_fixed_frame if _fixed_frame >= 0 else int(_anim_time / ft)) % frames.size()]
	if _is_missile():
		# Missile::OnRenderSpecific: rotate heading + 90°, frame top-centre on the position (the nose
		# leads, the exhaust trails behind).
		draw_set_transform(Vector2.ZERO, deg_to_rad(heading) + PI / 2)
		draw_texture_rect_region(_anim.texture, Rect2(Vector2(-int(src.size.x) / 2, 0), src.size), src)
	else:
		# LaserBlast::OnRenderSpecific: centred, rotated to the heading (or the spin angle when spinning).
		var rot := deg_to_rad(_spin_angle) if spin > 0.0 else deg_to_rad(heading)
		draw_set_transform(Vector2.ZERO, rot)
		draw_texture_rect_region(_anim.texture, Rect2(-src.size / 2, src.size), src)
	draw_set_transform(Vector2.ZERO, 0)


## Draws the frame of `anim` at `progress` (0..1) centred on the node's origin.
static func draw_anim_frame(node: CanvasItem, anim: Dictionary, progress: float, modulate := Color.WHITE) -> void:
	var frames: Array = anim.frames
	var i := clampi(int(progress * frames.size()), 0, frames.size() - 1)
	var src: Rect2 = frames[i]
	node.draw_texture_rect_region(anim.texture, Rect2(-src.size / 2, src.size), src, modulate)
