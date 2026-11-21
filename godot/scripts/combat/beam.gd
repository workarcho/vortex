class_name Beam
extends Node2D
## A beam shot (rules/weapons.md "Beams"; FTL's BeamWeapon). One object for both spaces: it lives in the
## destination space's world (sweep, damage, drawing there) and draws its outgoing half in the source
## space through `source_line`. It never travels: it acts from the frame it is fired.

const DEFAULT_SPEED := 5.0  # units per factor when the blueprint has no <speed> (BeamWeapon constructor)
const SIDE_DISTANCE := 600.0  # prototype: the off-screen start of the incoming half, from the shield centre
const SMOKE_STEP := 5.0  # px the end point moves between two smoke puffs
const CONTACT_OFFSET := Vector2(24, 33)  # beam_contact frame drawn at end - (24, 33), tinted
const OUT_LENGTH := 2000.0  # outgoing half: from the mount 2000 px along the firing heading
const WOBBLE := 0.125  # deg per factor: the outgoing half drifts by ±this (dh, random sign)
const WIDTH_PER_DAMAGE := 6.0  # GL_DrawLaser width = damage × 6

static var _next_side := 0  # RandomSidePoint side, cycles 0..3 for every beam fired

var weapon: WeaponState
var bp := {}
var dmg: Damage
var owner_ship: ShipState
var target_ship: ShipState
var source_space: Space
var dest_space: Space
var length := 0.0
var speed_units := DEFAULT_SPEED
var target1 := Vector2.ZERO  # sweep start (first aiming point)
var target2 := Vector2.ZERO  # direction / end of the sweep (second aiming point)
var current := Vector2.ZERO  # current end of the beam on the target
var sub_start := Vector2.ZERO  # incoming half: off-screen start in the destination space
var mount := Vector2.ZERO
var heading := 0.0
var dh := 0.0
var started := false  # checkedCollision: the sweep only moves after the first collision check
var finished := false
var dead := false
var pierced := true  # piercedShield
var shielded := false  # the incoming half crosses a shield with layers
var shield_point := Vector2.ZERO  # where the incoming half enters the shield ellipse
var last_damage := 0  # damage that reaches the hull after shields (lastDamage)
var last_room := -1
var last_tile := -1
var source_line: Node2D
var _super_hit := false  # the beam already damaged a Zoltan super shield
var color := Color8(227, 39, 39)
var _contact := {}
var _contacts: Array = []  # ages (s) of the live contact glows (one more every 0.25..0.34 s)
var _contact_timer := -1.0
var _smoke: Array = []  # [{pos, t, scale, anim, first}] puffs left along the path (pierced only)
var _last_smoke := Vector2.INF
var _smoke_anim := {}
var _explosion1 := {}
var _time := 0.0


## `p1`/`p2`: the two aiming points on the target ship (start and direction of the sweep).
func setup(w: WeaponState, from_space: Space, to_space: Space, p1: Vector2, p2: Vector2,
		rng: RandomNumberGenerator) -> void:
	weapon = w
	bp = w.bp
	dmg = w.make_damage()
	dmg.owner = 0 if from_space.ship.is_player else 1
	owner_ship = from_space.ship
	target_ship = to_space.ship
	source_space = from_space
	dest_space = to_space
	length = float(bp.get("length", 0))
	speed_units = float(bp.speed) if float(bp.speed) > 0.0 else DEFAULT_SPEED
	target1 = p1
	target2 = p2
	current = p1
	color = bp.get("color", color)
	heading = owner_ship.fire_heading
	dh = WOBBLE if rng.randi() & 1 else -WOBBLE
	mount = WeaponArt.fire_location(owner_ship, w)
	sub_start = side_point(target_ship, _next_side, rng)
	_next_side = (_next_side + 1) % 4
	_contact = FtlData.anim(String(bp.get("image", "")))
	_smoke_anim = _fire_smoke_anim()
	_explosion1 = FtlData.anim("explosion1")
	z_index = 5
	if from_space != to_space:
		source_line = Node2D.new()
		source_line.z_index = -1  # own outgoing beam renders under the ship (layer 2)
		source_line.draw.connect(_draw_source)
		from_space.world.add_child(source_line)


## Off-screen point on one side of the target (Projectile::RandomSidePoint: (-400, 0..800), (800, 0..400),
## (0..800, -400), (0..800, 800) around a (200, 200) ship centre). Prototype: relative to the shield centre,
## so 600 px left / right / above / below it, the "along" offset in [-200, 600) ([-200, 200) on the right).
static func side_point(ship: ShipState, side: int, rng: RandomNumberGenerator) -> Vector2:
	var c := ship.shield_center
	match side:
		0:
			return c + Vector2(-SIDE_DISTANCE, rng.randi() % 800 - 200)
		1:
			return c + Vector2(SIDE_DISTANCE, (rng.randi() % 800) / 2 - 200)
		2:
			return c + Vector2(rng.randi() % 800 - 200, -SIDE_DISTANCE)
		_:
			return c + Vector2(rng.randi() % 800 - 200, SIDE_DISTANCE)


## effects/fire_smoke.png: 7 frames of 34 x 34, 0.5 s (built in code by BeamWeapon::CollisionCheck).
static func _fire_smoke_anim() -> Dictionary:
	var tex := FtlData.texture("img/effects/fire_smoke.png")
	if tex == null:
		return {}
	var frames: Array[Rect2] = []
	for i in 7:
		frames.append(Rect2(i * 34, 0, 34, 34))
	return {"texture": tex, "frames": frames, "time": 0.5}


## Sweep duration in seconds: length / (speed × 16).
func sweep_time() -> float:
	return length / (speed_units * GameClock.BASE)


## One simulation step (BeamWeapon::OnUpdate, then CollisionCheck against the target ship).
func step(f: float, rng: RandomNumberGenerator) -> void:
	if dead:
		return
	_time += f / GameClock.BASE
	# The beam is killed as soon as its weapon loses power.
	if not weapon.powered:
		_kill()
		return
	if started:
		heading += dh * f
		current = current.move_toward(target2, speed_units * f)
		if current == target2 or current.distance_squared_to(target1) > length * length:
			finished = true  # lifespan = -1: removed after this frame's collision check
		# Weapon art holds fireFrame .. last frame along the sweep (WeaponAnimation::SetFireLevel).
		var span := minf(length, target1.distance_to(target2))
		weapon.beam_level = clampf(current.distance_to(target1) / span, 0.0, 1.0) if span > 0.0 else 1.0
	_update_effects(f / GameClock.BASE)
	_collide(rng)
	started = true
	if finished:
		_kill()
	queue_redraw()
	if source_line:
		source_line.queue_redraw()


func _kill() -> void:
	dead = true
	weapon.beam_level = -1.0
	if source_line:
		source_line.queue_free()
		source_line = null


## BeamWeapon::CollisionCheck: shields reduce the beam by (layers − piercing); the beam never removes a
## layer and never misses. Then ShipManager::DamageBeam between the previous and the current point.
func _collide(rng: RandomNumberGenerator) -> void:
	var ship := target_ship
	if ship.is_destroyed():
		return
	# Zoltan super shield (rules/weapons.md): always blocks; damaged once by max(damage, 1) (prototype:
	# at the first contact, not at 33 % / 80 % of the sweep).
	if ship.super_shield > 0 and ship.inside_shield(current) and not ship.inside_shield(sub_start):
		shielded = true
		pierced = false
		last_damage = 0
		shield_point = _shield_entry(ship)
		if not _super_hit:
			_super_hit = true
			ship.damage_super_shield(maxi(dmg.damage, 1))
			ship.shield_popped(shield_point, true)
			FtlData.play_random(bp.get("hit_shield_sounds", []))
		dest_space.flash_shield(shield_point, get_instance_id())
		return
	shielded = ship.shield_layers > 0 and ship.inside_shield(current) and not ship.inside_shield(sub_start)
	var eff := dmg.damage
	pierced = true
	if shielded:
		var block := ship.shield_layers - dmg.shield_piercing
		if block >= dmg.damage:
			pierced = false
		eff = dmg.damage - maxi(block, 0)
		shield_point = _shield_entry(ship)
	last_damage = maxi(eff, 0)
	if pierced:
		var d := dmg.copy()
		d.damage = eff
		var r := ship.apply_beam(current, last_room, last_tile, d, rng)
		Hooks.emit(&"beam_damage", ship, self, r)  # hitByBeam / killedByBeam (AchievementTracker)
		dest_space.show_resists(r, current)  # ROCK_ARMOR / SYSTEM_CASING / ION_ARMOR "RESIST"
		_report(r)
	elif shielded and not started:
		FtlData.play_random(bp.get("hit_shield_sounds", []))
	if shielded:
		dest_space.flash_shield(shield_point, get_instance_id())  # one arc that follows the beam
	if pierced:
		_spawn_effects()
	last_room = ship.room_at(current)
	last_tile = ship.tile_at(last_room, current)


## Point where the segment sub_start -> current enters the shield ellipse (bisection).
func _shield_entry(ship: ShipState) -> Vector2:
	var a := sub_start
	var b := current
	for i in 24:
		var m := (a + b) * 0.5
		if ship.inside_shield(m):
			b = m
		else:
			a = m
	return b


func _report(r: Dictionary) -> void:
	if r.room < 0:
		return
	if r.new_room:
		Combat.log("%s (beam) -> %s: room %d: hull -%d, system -%d, ion %d%s → hull %d" % [bp.name,
			target_ship.blueprint.name, r.room, r.hull, r.system, r.ion,
			", shields -%d" % (dmg.damage - last_damage) if shielded else "", target_ship.hull])
		if r.hull > 0:
			dest_space.show_number(r.hull, current, Space.MSG_HULL)
		if r.ion > 0:
			dest_space.show_number(r.ion, current, Space.MSG_ION)
		if r.hull > 0 or r.system > 0:
			FtlData.play_random(bp.get("hit_ship_sounds", []))
	if r.fire:
		Combat.log("%s (beam): FIRE room %d tile %d" % [bp.name, r.room, r.tile])
	if r.breach:
		FtlData.play("hullBreach")


# ------------------------------------------------------------ effects (BeamWeapon::CollisionCheck / OnUpdate)

func _update_effects(sec: float) -> void:
	_contact_timer -= sec
	for i in _contacts.size():
		_contacts[i] += sec
	var life: float = maxf(float(_contact.get("time", 0.75)), 0.01)
	_contacts = _contacts.filter(func(t): return t < life)
	for p in _smoke:
		p.t += sec
	_smoke = _smoke.filter(func(p): return p.t < float(p.anim.time) * (1.0 - float(p.first) / p.anim.frames.size()))


## While the beam pierces: a new contact glow every (25..34) / 100 s, and a smoke puff every 5 px the end
## point moves: fire_smoke at scale 0.4 (<= 1 damage through) / 0.5 (2), explosion1 from frame 4 at 0.75 (>= 3).
func _spawn_effects() -> void:
	if _contact_timer <= 0.0:
		_contacts.append(0.0)
		_contact_timer = float(randi() % 10 + 25) / 100.0
	if _last_smoke == Vector2.INF:
		_last_smoke = current
	if _last_smoke.distance_to(current) > SMOKE_STEP:
		var big := last_damage >= 3 and not _explosion1.is_empty()
		var anim: Dictionary = _explosion1 if big else _smoke_anim
		if not anim.is_empty():
			var jitter := Vector2(randi() % 7 - 3, randi() % 7 - 3)
			_smoke.append({"pos": _last_smoke + jitter, "t": 0.0, "anim": anim,
				"scale": 0.75 if big else (0.5 if last_damage == 2 else 0.4), "first": 4 if big else 0})
		_last_smoke = current


# ------------------------------------------------------------ drawing (BeamWeapon::OnRenderSpecific)

## GL_DrawLaser: a band `width` px wide along a -> b, beam colour at full alpha on the centre line fading
## to transparent at both edges.
static func draw_laser(ci: CanvasItem, a: Vector2, b: Vector2, width: float, col: Color) -> void:
	if width <= 0.0 or a == b:
		return
	var n := (b - a).normalized().orthogonal() * (width / 2.0)
	var edge := Color(col, 0.0)
	ci.draw_polygon(PackedVector2Array([a - n, b - n, b, a]), PackedColorArray([edge, edge, col, col]))
	ci.draw_polygon(PackedVector2Array([a, b, b + n, a + n]), PackedColorArray([col, col, edge, edge]))


func _outer_width() -> float:
	return maxi(dmg.damage, 1) * WIDTH_PER_DAMAGE


## Width inside the shield: what pierced (a 0-damage beam that is not blocked still shows 1).
func _inner_width() -> float:
	if pierced and dmg.damage == 0:
		return WIDTH_PER_DAMAGE
	return last_damage * WIDTH_PER_DAMAGE


func _draw() -> void:
	if dead or not started:
		return
	# Smoke puffs under the beam (only while it pierces).
	if pierced:
		for p in _smoke:
			var fr: Array = p.anim.frames
			var i := clampi(int(p.first) + int(p.t / float(p.anim.time) * fr.size()), 0, fr.size() - 1)
			var src: Rect2 = fr[i]
			var sz: Vector2 = src.size * float(p.scale)
			draw_texture_rect_region(p.anim.texture, Rect2(p.pos - sz / 2, sz), src)
	# The incoming beam: from the off-screen side point to the end point. Full width outside the shield,
	# the damage that got through inside it (nothing past the shield when it is blocked).
	if shielded:
		draw_laser(self, sub_start, shield_point, _outer_width(), color)
		draw_laser(self, shield_point, current, _inner_width(), color)
	else:
		draw_laser(self, sub_start, current, _inner_width(), color)
	# Contact glow (the blueprint image, beam_contact) at end - (24, 33), tinted with the beam colour.
	if pierced and not _contact.is_empty():
		var src: Rect2 = _contact.frames[0]
		for t in _contacts:
			draw_texture_rect_region(_contact.texture, Rect2(current - CONTACT_OFFSET, src.size), src, color)


## Outgoing half in the firing ship's space: from the fire point 2000 px along the (drifting) heading.
func _draw_source() -> void:
	if dead or not started:
		return
	var end := mount + Vector2.from_angle(deg_to_rad(heading)) * OUT_LENGTH
	draw_laser(source_line, mount, end, _outer_width(), color)
