class_name LockdownRule
extends RefCounted
## Crystal lockdown (rules/races.md "Crystal"): Ship::LockdownRoom, Door::SetLockdown, LockdownShard,
## Ship::RoomLocked. Used by crystal crew (CrystalAlien::ActivatePower) and BOMB_LOCK (`lockdown` damage).
## Door state lives in ShipEnvironment.doors (`lockdown` s left, `lock_base` remembered base health); the shards
## in ShipState.lockdowns.

const DURATION := 12.0  # s, Door lockedDown tracker
const DOOR_HEALTH := 50
const SHARD_SEGMENT := 12.0  # px: 3 shards per 35 px tile side, one per 12 px segment
const SHARD_MIN_SPEED := 1.0  # px per frame (1/60 s), not scaled by the speed factor
const SHARD_MAX_SPEED := 2.0
const SHARD_OFFSET := Vector2(9, 14)  # drawn at position - (9, 14)
const SHARD_ANIM_TIME := 0.5  # crystal_1 / crystal_2 length
const T := 35.0


## Ship::LockdownRoom(room, origin): seals every door of the room for 12 s at 50 HP and throws the shards.
static func lockdown_room(ship: ShipState, room: int, origin: Vector2) -> void:
	if room < 0:
		return
	for i in ship.env.doors.size():
		var d: Dictionary = ship.env.doors[i]
		if d.left == room or d.right == room:
			ship.env.set_lockdown(i)
			_add_shard(ship, room, origin, ship.graph.door_center(d), "crystal_1")
	var r := ship.room_rect(room)
	var cols := int(roundf(r.size.x / T))
	var rows := int(roundf(r.size.y / T))
	for i in cols:
		for k in 3:
			var x := r.position.x + i * T + k * SHARD_SEGMENT + ship.rng.randf() * SHARD_SEGMENT
			_add_shard(ship, room, origin, Vector2(x, r.position.y), "")
			_add_shard(ship, room, origin, Vector2(x, r.end.y), "")
	for j in rows:
		for k in 3:
			var y := r.position.y + j * T + k * SHARD_SEGMENT + ship.rng.randf() * SHARD_SEGMENT
			_add_shard(ship, room, origin, Vector2(r.position.x, y), "")
			_add_shard(ship, room, origin, Vector2(r.end.x, y), "")


static func _add_shard(ship: ShipState, room: int, origin: Vector2, goal: Vector2, anim: String) -> void:
	if anim == "":
		anim = "crystal_1" if ship.rng.randi() % 2 == 0 else "crystal_2"
	ship.lockdowns.append({"room": room, "pos": origin, "goal": goal, "anim": anim,
		"speed": ship.rng.randf_range(SHARD_MIN_SPEED, SHARD_MAX_SPEED), "life": 0.0,
		"phase": 0, "t": 0.0, "melt": 0.0})


## LockdownShard::Update: fly (phase 0), animation forward (1), then backward over (12 - lifetime) s (2); removed
## at the end of the reverse.
static func tick(ship: ShipState, seconds: float) -> void:
	if ship.lockdowns.is_empty() or seconds <= 0.0:
		return
	var keep: Array = []
	for s in ship.lockdowns:
		s.life += seconds
		match int(s.phase):
			0:
				var step: float = s.speed * 60.0 * seconds
				var to: Vector2 = s.goal - s.pos
				if to.length() <= step:
					s.pos = s.goal
					s.phase = 1
					s.t = 0.0
				else:
					s.pos += to.normalized() * step
			1:
				s.t += seconds
				if s.t >= SHARD_ANIM_TIME:
					s.phase = 2
					s.t = 0.0
					s.melt = maxf(DURATION - s.life, 0.0)
			2:
				s.t += seconds
				if s.t >= s.melt:
					continue
		keep.append(s)
	ship.lockdowns = keep


## Animation frame of a shard (0 while flying).
static func shard_frame(s: Dictionary, frames: int) -> int:
	match int(s.phase):
		1:
			return clampi(int(s.t / SHARD_ANIM_TIME * frames), 0, frames - 1)
		2:
			var f: float = s.t / s.melt if s.melt > 0.0 else 1.0
			return clampi(frames - 1 - int(f * frames), 0, frames - 1)
	return 0


## Ship::RoomLocked: any live shard belongs to the room.
static func room_locked(ship: ShipState, room: int) -> bool:
	for s in ship.lockdowns:
		if s.room == room:
			return true
	return false
