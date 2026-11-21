class_name ShipExplosion
extends RefCounted
## A destroyed ship's explosion (ExplosionAnimation, rules/ship_destruction.md §3): 1.5 s of random small
## explosions and crackling over the intact hull, then the final boom (2-3 big explosions, hull gone) after which
## the gibs drift and turn until the tracker ends (3 s, player ship 6 s). Drawn by ShipView._draw_explosion.

const ENEMY_TIME := 3.0  # Ship::Ship
const PLAYER_TIME := 6.0  # OnInit: iShipId == 0 (and boss_3)
const BOOM_AT := 1.5
const ANIMS_UNTIL := 3.0  # small/boom animations are drawn while current_time < 3
const MAX_SMALL := 25
const SMALL_MARGIN := 32  # x range of small explosions: box.w - 32
const BOOM_MARGIN := 128  # x range of boom points: box.w - 128
const BOOM_SCALE := 2.0
const BOOM_MIN_DIST := 64.0
const CRACKLE_VOLUME := 0.25

var duration := ENEMY_TIME
var time := 0.0  # tracker current_time (game seconds)
var running := false
var done := false
var final_boom := false
var sound_timer := -1.0
var explosion_timer := 0.0
## Gibs in blueprint order: {index (1-based), tex, start, pos (top-left, relative to the hull image), vel
## (px per factor unit), rot (degrees), rot_speed (degrees per factor unit)}
var gibs: Array = []
## Small / boom explosions: {anim (FtlData.anim), pos (top-left, ship-local), t, scale}
var anims: Array = []
var rng := RandomNumberGenerator.new()
var sounds := true
## Flagship jump-out (ExplosionAnimation::SetJumpOut, rules/flagship.md): 4.0 s; at progress 0.75 the `jumpLeave`
## sound, the hull image fades back in over the gibs with the jump glare (Ship::OnRenderJump with
## (progress − 0.75) × 4) and the last gib is no longer drawn.
const JUMP_OUT_TIME := 4.0
const JUMP_OUT_FROM := 0.75
var jump_out := false


func set_jump_out(on: bool) -> void:
	jump_out = on
	if on:
		duration = JUMP_OUT_TIME


## Jump progress 0..1 of the jump-out glare (-1 = none yet).
func jump_out_progress() -> float:
	if not jump_out or progress() <= JUMP_OUT_FROM:
		return -1.0
	return clampf((progress() - JUMP_OUT_FROM) * 4.0, 0.0, 1.0)


func _init(img: String, layout: String, is_player: bool) -> void:
	duration = PLAYER_TIME if is_player or img == "boss_3" else ENEMY_TIME
	rng.randomize()
	var i := 0
	for g in FtlData.ship_explosion(layout):
		i += 1
		var tex := FtlData.first_texture(["img/ship/%s_gib%d.png" % [img, i],
			"img/ships_glow/%s_gib%d.png" % [img, i]])
		var ang: Vector2 = g.angular
		var vel: Vector2 = g.velocity
		var dir: Vector2 = g.direction
		var rot_speed := _rand_milli(ang.x, ang.y) * 0.5
		var speed := _rand_milli(vel.x, vel.y) * 2.5
		# Direction: integer degrees in [270 - max, 270 - min] (0 = up, 90 = left, counter-clockwise).
		var a := deg_to_rad(float(_rand_int(int(270.0 - dir.y), int(270.0 - dir.x))))
		gibs.append({"index": i, "tex": tex, "start": g.pos, "pos": g.pos,
			"vel": Vector2(cos(a), sin(a)) * speed, "rot": 0.0, "rot_speed": rot_speed})


## AnimationTracker::Start(0).
func start() -> void:
	running = true
	done = false
	time = 0.0


func progress() -> float:
	return clampf(time / duration, 0.0, 1.0)


## ExplosionAnimation::Update. `f` = frame factor, `box` = the ship graph box (rooms' bounding box, ship-local).
func step(f: float, box: Rect2) -> void:
	if not running or done:
		return
	var seconds := f / GameClock.BASE
	var before := progress()
	time += seconds
	if jump_out and sounds and before < JUMP_OUT_FROM and progress() >= JUMP_OUT_FROM:
		FtlData.play("jumpLeave")
	if time > duration:  # AnimationTracker::Update: done, clamped; nothing else this frame
		time = duration
		done = true
		return
	if time >= BOOM_AT:
		if time > BOOM_AT:
			if not final_boom:
				_final_boom(box)
			else:
				for g in gibs:
					g.pos += g.vel * f
					g.rot += g.rot_speed * f
	else:
		_crackle(seconds, box)
	for e in anims:
		e.t += seconds
	anims = anims.filter(func(e): return e.t < float(e.anim.get("time", 1.0)))


func _crackle(seconds: float, box: Rect2) -> void:
	if sound_timer < 0.0:
		if sounds:
			FtlData.play("explosion%d" % (rng.randi() % 4 + 1), CRACKLE_VOLUME)
		sound_timer = float(rng.randi() % 3) * 0.3 + 0.3
	else:
		sound_timer -= seconds
	if explosion_timer < 0.0:
		if anims.size() < MAX_SMALL:
			var choice := rng.randi() % 3
			var p := Vector2(box.position.x + rng.randi() % maxi(int(box.size.x) - SMALL_MARGIN, 1),
				box.position.y + rng.randi() % maxi(int(box.size.y), 1))
			# Disassembly fall-through: 0 -> random + explosion1 x2, 1 -> explosion1 x2, 2 -> explosion1.
			if choice == 0:
				_add_anim("explosion_random", p, 1.0)
			var n := 2 if choice <= 1 else 1
			for k in n:
				_add_anim("explosion1", p, 1.0)
		explosion_timer = float(rng.randi() % 10) * 0.05
	else:
		explosion_timer -= seconds


func _final_boom(box: Rect2) -> void:
	var count := rng.randi() % 2 + 2
	var last := Vector2(-1e9, -1e9)
	for k in count:
		var p := last
		var guard := 0
		while p.distance_to(last) < BOOM_MIN_DIST and guard < 100:
			guard += 1
			p = Vector2(box.position.x + rng.randi() % maxi(int(box.size.x) - BOOM_MARGIN, 1),
				box.position.y + rng.randi() % maxi(int(box.size.y), 1))
		last = p
		_add_anim("explosion_random", p, BOOM_SCALE)
	if sounds:
		FtlData.play("explosion1", 1.0)
	final_boom = true


func _add_anim(anim_name: String, p: Vector2, scale: float) -> void:
	var an := FtlData.anim(anim_name)
	if an.is_empty():
		an = {"time": 1.0, "frames": [], "texture": null}
	anims.append({"anim": an, "pos": p, "t": 0.0, "scale": scale})


## Random integer thousandths in [lo, hi] (iMin = lo * 1000, iMax = hi * 1000), back to units.
func _rand_milli(lo: float, hi: float) -> float:
	return float(_rand_int(int(lo * 1000.0), int(hi * 1000.0))) / 1000.0


## C `rand() % (hi + 1 - lo) + lo` (lo when the range is empty).
func _rand_int(lo: int, hi: int) -> int:
	var n := hi + 1 - lo
	return lo if n <= 0 else lo + rng.randi() % n
