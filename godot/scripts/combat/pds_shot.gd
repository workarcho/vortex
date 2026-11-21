class_name PdsShot
extends Projectile
## An anti-ship battery (ASB / PDS) shot = FTL `PDSFire` (rules/hazards.md §6), created by HazardRule's volley
## logic (SpaceManager::UpdatePDS) in the player's space at the gun (the populated planet, or the fleet's gun
## ship in a danger zone).
## - Blueprint `PDS_SHOT` (damage 3, breach 10, sp 5, image `pds`, explosion `explosion_random`); owner -1.
## - Heading: straight at the target when it is in the player's space (LaserBlast::ComputeHeading), otherwise
##   135 + r % 90 degrees (it leaves the player's space to the left and enters the enemy's like any shot).
## - Speed 60 on the first frame, then `20 + 3 × scale` per clock unit, scale = `1 + 7 × |pos − start| /
##   |target − start|` (the sprite is drawn at that scale: it grows from ×1 at the gun to ×8 at the target, i.e.
##   it "comes at" the ship from the background).
## - No shield / dodge / drone / projectile collision (CollisionMoving and CollisionCheck overridden): within one
##   frame's travel of the target, in its destination space, not missed and not yet passed, it calls DamageArea
##   with forceHit (the dodge was rolled when the volley was queued); a hit starts the explosion animation centred
##   on the target and plays the hit sound. The shot keeps flying and dies when it leaves the space.
## - Render layer (ForceRenderLayer): under the ship (layer 2) until it passed the target, then over it (layer 1).
##   A missed volley shot (dodged) carries numbers/text_miss.png (top-left at the shot) while it flies off.
## - Decoys (ambient fire, or a dodged volley shot) fly in the player's space to RandomSidePoint(0) = (−400,
##   r % 800) and never damage anything.

const START_SPEED := 60.0
const SCALE_GROWTH := 7.0
const SPEED_BASE := 20.0
const SPEED_PER_SCALE := 3.0
const HEADING_MIN := 135  # degrees, + r % 90 (shot leaving the player's space toward the enemy)
const HEADING_SPREAD := 90
const MISS_IMG := "img/numbers/text_miss.png"

var start_point := Vector2.ZERO
var current_scale := 1.0
var decoy := false
var hit_target := false  # PDSFire::passedTarget
var _hit_anim := {}
var _hit_t := -1.0  # s into the explosion animation (< 0: none)


## `from` = the player's space (where the gun is); `to` = the target's space (decoys: the player's space).
## `start` = the gun in player-ship coordinates; `missed_volley` = a dodged volley shot (shows MISS).
func setup_pds(from: Space, to: Space, start: Vector2, target_point: Vector2, is_decoy: bool,
		missed_volley: bool, heading_roll: int) -> void:
	weapon = FtlData.weapon_blueprint("PDS_SHOT")
	if weapon.is_empty():
		weapon = {"name": "PDS_SHOT", "type": "LASER", "damage": 3, "sp": 5, "breach_chance": 10, "image": "pds",
			"explosion": "explosion_random", "hit_ship_sounds": ["hitHull1"]}
	dmg = Damage.from_weapon(weapon)
	dmg.owner = -1
	decoy = is_decoy
	missed = missed_volley
	fake = true  # no drone / projectile collisions, never a defence-drone target (type 5)
	speed_units = START_SPEED
	owner_ship = null
	target_ship = to.ship
	current_space = from
	destination_space = to
	position = start
	last_position = start
	start_point = start
	target = target_point
	heading = rad_to_deg((target_point - start).angle()) if from == to else float(HEADING_MIN + heading_roll)
	_anim = FtlData.anim(String(weapon.get("image", "pds")))
	z_index = -1


func targetable_type() -> int:
	return -1


## Projectile::OnUpdate (move), then PDSFire::OnUpdate (scale, speed), then PDSFire::CollisionCheck.
func step(f: float, rng: RandomNumberGenerator) -> void:
	super.step(f, rng)
	if dead:
		return
	if _hit_t >= 0.0:
		_hit_t += f / GameClock.BASE
		if _hit_t >= maxf(float(_hit_anim.get("time", 0.0)), 0.05):
			_hit_t = -1.0
	var total := start_point.distance_to(target)
	current_scale = (start_point.distance_to(position) / total if total > 0.0 else 0.0) * SCALE_GROWTH + 1.0
	speed_units = current_scale * SPEED_PER_SCALE + SPEED_BASE
	if in_destination() and not missed and not hit_target:
		var reach := speed_units * f
		if position.distance_squared_to(target) <= reach * reach:
			hit_target = true
			_strike(rng)
	z_index = 5 if hit_target else -1


## The base shield / hull collision is replaced by `_strike` (forced area damage).
func _check_collisions(_rng: RandomNumberGenerator) -> void:
	pass


## DamageArea(target, forceHit): the room under the target point takes the PDS_SHOT damage.
func _strike(rng: RandomNumberGenerator) -> void:
	var ship := target_ship
	if decoy or ship == null or ship.destroyed_done():
		return
	var room := ship.room_at(target)
	if room < 0:
		return
	var r := ship.apply_damage(room, dmg, rng)
	Hooks.emit(&"projectile_hit", ship, weapon, room, r)
	FtlData.play_random(weapon.get("hit_ship_sounds", []))
	if r.breach:
		FtlData.play("hullBreach")
	Combat.log("PDS_SHOT -> %s: HIT room %d: hull -%d, system -%d, crew %d%s → hull %d" % [ship.blueprint.name,
		room, r.hull, r.system, r.crew, ", BREACH" if r.breach else "", ship.hull])
	_show_numbers(r)
	_hit_anim = FtlData.anim(String(weapon.get("explosion", "explosion_random")))
	_hit_t = 0.0 if not _hit_anim.is_empty() else -1.0


func _draw() -> void:
	if _hit_t >= 0.0 and not _hit_anim.is_empty():
		draw_set_transform(target - position)
		Projectile.draw_anim_frame(self, _hit_anim, _hit_t / maxf(float(_hit_anim.time), 0.05))
		draw_set_transform(Vector2.ZERO)
	if not _anim.is_empty():
		var frames: Array = _anim.frames
		var ft: float = maxf(float(_anim.time), 0.01) / frames.size()
		var src: Rect2 = frames[int(_anim_time / ft) % frames.size()]
		var sz := Vector2(int(src.size.x * current_scale), int(src.size.y * current_scale))
		draw_set_transform(Vector2.ZERO, deg_to_rad(heading))
		draw_texture_rect_region(_anim.texture, Rect2(-(sz / 2).floor(), sz), src)
		draw_set_transform(Vector2.ZERO)
	if missed:
		var t := FtlData.texture(MISS_IMG)
		if t:
			draw_texture(t, Vector2.ZERO)


## The launch puff (SpaceManager::pdsSmokeAnims, drawn under the player ship): effects/fire_smoke.png, 7 frames of
## 34 px over 1 s at scale 0.5 (17 px), top-left at the gun − 8.5 (centred on it).
class Smoke extends Node2D:
	const IMG := "img/effects/fire_smoke.png"
	const FRAMES := 7
	const FRAME := 34.0
	const LENGTH := 1.0
	const SCALE := 0.5
	var dead := false
	var dying := 0.0
	var t := 0.0

	func _init(at: Vector2) -> void:
		position = at
		z_index = -1

	func step(f: float, _rng: RandomNumberGenerator) -> void:
		t += f / GameClock.BASE
		if t >= LENGTH:
			dead = true
		queue_redraw()

	func _draw() -> void:
		var tex := FtlData.texture(IMG)
		if tex == null:
			return
		var i := clampi(int(t / LENGTH * FRAMES), 0, FRAMES - 1)
		var s := FRAME * SCALE
		draw_texture_rect_region(tex, Rect2(-s / 2.0, -s / 2.0, s, s), Rect2(i * FRAME, 0, FRAME, FRAME))
