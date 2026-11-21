class_name ShipEnvironment
extends RefCounted
## Per-room oxygen, doors, breaches and fire of a ship (rules/fire_and_oxygen.md).
## Fire and breaches are stored in ShipState.fires / .breaches (room -> {tile: data}).

const O2_REFILL := 1.2  # %/s per "unit" of the oxygen system
const O2_DRAIN := 1.2  # %/s with no working system
const O2_HACKED := 6.0
const O2_SPREAD := 8.0  # %/s of the difference from the group average
const BREACH_LOSS := 8.0  # %/s per breach (base 0.5 x 16)
const AIRLOCK_LOSS := 16.0  # %/s per open airlock
const LEAK_SOUND_ABOVE := 1.0  # % (OxygenSystem::ComputeAirLoss: bLeakingO2 only for rooms above it)
const LOSS_FALLOFF := 0.75  # per room of distance
const FIRE_O2 := 0.96  # %/s per fire
const FIRE_SYS := 8.0  # % of a bar per second per fire
const FIRE_CREW := 2.128  # HP/s per fire
const SUFFOCATE := 6.4  # HP/s
const SUFFOCATE_BELOW := 5.0
const FIRE_STARVE_BELOW := 10.0  # Fire::UpdateDeathTimer: starves while (int) room O2 <= 10 (fOxygen is truncated)
## Fire start-timer rates (Fire::UpdateStartTimer x SpeedFactor 16/s), chosen per burning neighbour by
## Spreader<Fire>::CheckSquareSpread from ShipGraph::ConnectedGridSquares (rules/fire_and_oxygen.md "Spread").
const SPREAD_OPEN := 1.6  # 0.1 x 16: same room, open / forced-open door, hacked door
const SPREAD_DOOR_LOW := 0.914  # 0.05714 x 16: closed door without blast (doors system level 0/1)
const SPREAD_DOOR_HIGH := 0.16  # 0.01 x 16: closed blast door (doors system level 2+)
const SPREAD_TIMER_MIN := 10  # fStartTimer = random % 40 + 10
const SPREAD_TIMER_SPAN := 40
const DEATH_TIMER_MIN := 5  # fDeathTimer = random % 10 + 5
const DEATH_TIMER_SPAN := 10
const DEATH_RATE := 0.16  # 0.01 x 16 per (15 - 3 x connected burning neighbours)
## Doors vs intruders (Door::SetBlastDoor/ApplyDamage, rules/crew_combat.md "Doors").
const DOOR_BASE_HEALTH := 4  # level 0/1 (no blast door)
const DOOR_HEALTH := [[12, 16, 20], [8, 12, 18], [6, 10, 15]]  # [easy/normal/hard][blast 1..3]
const DOOR_FORCED_OPEN := 7.0  # s

var ship: ShipState
var oxygen := {}  # room_id -> %
## [{x, y, left, right, vertical, open, airlock, crew_pass, health, base, forced, hacked}]
## hacked: Door::iHacked (0 none; >0 forced closed, a blast-2 door sealed against its own crew).
## crew_pass: s of fake-open; health/base: hits left / full (Door::health/baseHealth);
## forced: s left of the 7 s forced-open state after intruders broke it; shown: drawn open last time the door
## sounds were checked (update_door_sounds).
var doors: Array = []
## OxygenSystem::bLeakingO2 of the last tick: a breach or open airlock (not lanius drain) took air from a room
## that still had more than 1 %. The player ship's "airLeak" loop follows it (rules/fire_and_oxygen.md "Sounds").
var leaking_o2 := false
## Sounds this environment played (airLoss / doorOpen / doorClose), for tests; capped.
var sound_log: Array[String] = []
var tile_room := {}  # Vector2i (global tile) -> room_id
var spread_timers := {}  # Vector2i -> s remaining
var _rng := RandomNumberGenerator.new()


func _init(s: ShipState) -> void:
	ship = s
	for r in ship.layout.rooms:
		oxygen[r.id] = 100.0
		var rr: Rect2i = r.rect
		for y in rr.size.y:
			for x in rr.size.x:
				tile_room[rr.position + Vector2i(x, y)] = r.id
	for d in ship.layout.doors:
		doors.append({"x": d.x, "y": d.y, "left": d.left, "right": d.right, "vertical": d.vertical,
			"open": false, "airlock": d.left < 0 or d.right < 0, "crew_pass": 0.0,
			"health": DOOR_BASE_HEALTH, "base": DOOR_BASE_HEALTH, "forced": 0.0, "hacked": 0,
			"lockdown": 0.0, "lock_base": 0, "shown": false})


# ------------------------------------------------------------ geometry

func tile_global(room_id: int, index: int) -> Vector2i:
	var rr: Rect2i = _room(room_id).rect
	return rr.position + Vector2i(index % rr.size.x, index / rr.size.x)


func tile_index(g: Vector2i) -> int:
	var rr: Rect2i = _room(tile_room[g]).rect
	var l := g - rr.position
	return l.y * rr.size.x + l.x


func _room(room_id: int) -> Dictionary:
	for r in ship.layout.rooms:
		if r.id == room_id:
			return r
	return {}


## Door on the edge between two neighboring tiles (or null if wall / same room).
func door_between(a: Vector2i, b: Vector2i) -> Variant:
	var vertical := a.y == b.y
	var edge := Vector2i(maxi(a.x, b.x), a.y) if vertical else Vector2i(a.x, maxi(a.y, b.y))
	for d in doors:
		if d.vertical == vertical and d.x == edge.x and d.y == edge.y:
			return d
	return null


## How two neighboring tiles connect: "room", "open", "closed" or "" (wall).
func connection(a: Vector2i, b: Vector2i) -> String:
	if not tile_room.has(a) or not tile_room.has(b):
		return ""
	if tile_room[a] == tile_room[b]:
		return "room"
	var d = door_between(a, b)
	if d == null:
		return ""
	return "open" if d.open else "closed"


func _neighbors(g: Vector2i) -> Array:
	return [g + Vector2i.LEFT, g + Vector2i.RIGHT, g + Vector2i.UP, g + Vector2i.DOWN]


## Distances (in rooms) from a room, following open doors between rooms.
func room_distances(from_room: int) -> Dictionary:
	var dist := {from_room: 0}
	var queue := [from_room]
	while not queue.is_empty():
		var r: int = queue.pop_front()
		for d in doors:
			if not d.open or d.airlock:
				continue
			var other := -1
			if d.left == r:
				other = d.right
			elif d.right == r:
				other = d.left
			if other >= 0 and not dist.has(other):
				dist[other] = dist[r] + 1
				queue.append(other)
	return dist


func airlocks_open_in(room_id: int) -> int:
	var n := 0
	for d in doors:
		if d.airlock and d.open and (d.left == room_id or d.right == room_id):
			n += 1
	return n


func fires_in(room_id: int) -> int:
	return ship.fires.get(room_id, {}).size()


## Room::lastO2 as drawn (floor tint, low-O2 stripes): ShipManager::OnLoop hands Ship::OnLoop the oxygen system's
## levels, or an empty list when the ship has no oxygen system, and Ship::OnLoop then stores 0 for every room. So a
## ship without an oxygen system (lanius ships) shows red floors and stripes in every visible room.
func room_o2(room_id: int) -> float:
	if ship.sys("oxygen") == null:
		return 0.0
	return oxygen.get(room_id, 100.0)


func average_oxygen() -> float:
	if oxygen.is_empty():
		return 0.0
	var t := 0.0
	for v in oxygen.values():
		t += v
	return t / oxygen.size()


# ------------------------------------------------------------ simulation

func tick(seconds: float) -> void:
	if seconds <= 0.0:
		return
	_tick_oxygen_system(seconds)
	_redistribute(seconds)
	var lanius := lanius_per_room()
	_leaking = false
	var has_o2 := ship.sys("oxygen") != null
	for room_id in oxygen.keys():
		var fires := fires_in(room_id)
		if fires > 0:
			oxygen[room_id] -= FIRE_O2 * fires * seconds
		# ShipManager::UpdateEnvironment: UpdateAirlock, then UpdateBreach (same order as the exe).
		var airlocks := airlocks_open_in(room_id)
		if airlocks > 0:
			# OxygenSystem::UpdateAirlock: a room above 10 % is emptied at once with the "airLoss" whoosh (both ships).
			if oxygen[room_id] > 10.0:
				oxygen[room_id] = 0.0
				if has_o2:
					play_sound("airLoss")
			_air_loss(room_id, AIRLOCK_LOSS * airlocks * seconds, false)
		# Each lanius in the room drains it like one more breach (ships with an oxygen system only); with no
		# real breach the call is silent (no airLeak, no breach warning) (rules/races.md "Lanius").
		var real: int = ship.breaches.get(room_id, {}).size()
		var breaches: int = real + lanius.get(room_id, 0)
		if breaches > 0:
			_air_loss(room_id, BREACH_LOSS * breaches * seconds, real == 0)
	leaking_o2 = _leaking and has_o2
	for room_id in oxygen.keys():
		oxygen[room_id] = clampf(oxygen[room_id], 0.0, 100.0)
	_tick_fire(seconds)
	_tick_doors(seconds)
	_tick_crew(seconds)
	update_door_sounds()


## Anaerobic crew (lanius) per room (iRoomId; any owner, alive or dying), only on ships with an oxygen system.
func lanius_per_room() -> Dictionary:
	var out := {}
	if ship.sys("oxygen") == null:
		return out
	for c in ship.crew:
		if c.race == "anaerobic" and not c.is_drone() and c.room >= 0:
			out[c.room] = out.get(c.room, 0) + 1
	return out


func _tick_oxygen_system(seconds: float) -> void:
	var s := ship.sys("oxygen")
	var rate := -O2_DRAIN
	if s and s.hacked:
		rate = -O2_HACKED
	elif s and s.effective_power() > 0 and s.max_power() > 0:
		rate = O2_REFILL * (1 + 3 * (s.effective_power() - 1))
	for room_id in oxygen.keys():
		oxygen[room_id] += rate * seconds


func _redistribute(seconds: float) -> void:
	var seen := {}
	for room_id in oxygen.keys():
		if seen.has(room_id):
			continue
		var group := room_distances(room_id).keys()
		var avg := 0.0
		for r in group:
			seen[r] = true
			avg += oxygen[r]
		avg /= group.size()
		for r in group:
			oxygen[r] += (avg - oxygen[r]) * minf(O2_SPREAD / 100.0 * seconds, 1.0)


var _leaking := false


## Air loss from a room: base x 0.75^distance in the connected rooms (OxygenSystem::ComputeAirLoss). A loud
## (not silent) loss that reaches a room above 1 % sets bLeakingO2.
func _air_loss(from_room: int, amount: float, silent := true) -> void:
	var dist := room_distances(from_room)
	for r in dist:
		if oxygen[r] > 0.0:
			if not silent and oxygen[r] > LEAK_SOUND_ABOVE:
				_leaking = true
			oxygen[r] -= amount * pow(LOSS_FALLOFF, dist[r])


## Plays a sound and remembers it in `sound_log`.
func play_sound(sound: String) -> void:
	FtlData.play(sound)
	sound_log.append(sound)
	if sound_log.size() > 32:
		sound_log.remove_at(0)


## Door sounds of the player ship (Door::Door gives only iShipId 0 doors doorAnim.soundForward = "doorOpen" /
## soundReverse = "doorClose"; Animation::Start / StartReverse play them when the door animation starts from
## fully closed / fully open). Our doors do not animate, so a change of the shown state (open, fake-opened by
## crew walking through, or forced open) plays the sound. `silent`: only resync (ManipulateAllDoors sets
## SoundControl::ignoreSounds and plays its own "doorOpen" count instead).
func update_door_sounds(silent := false) -> void:
	for d in doors:
		var shown: bool = d.open or float(d.crew_pass) > 0.0 or float(d.forced) > 0.0
		if not d.has("shown"):
			d.shown = shown
			continue
		if d.shown == shown:
			continue
		d.shown = shown
		if not silent and ship.is_player:
			play_sound("doorOpen" if shown else "doorClose")


func _tick_fire(seconds: float) -> void:
	# Fire damage to systems (8 % of a bar/s per fire)
	for room_id in ship.fires:
		var n: int = ship.fires[room_id].size()
		var s := ship.system_in_room(room_id)
		if s == null or n == 0:
			continue
		# ShipManager::CheckSpreadDamage: DamageOverTime per burning tile (fDamageOverTime, shared with sabotage).
		if s.damage_over_time(FIRE_SYS * n * seconds) and s.damage < s.get_level():
			ship.damage_system_over_time(s)  # the last bar going costs the ship 1 hull (bExploded)
		if s.damage >= s.get_level():
			s.damage_progress = 0.0

	# Spread (Spreader<Fire>::UpdateSpread): every non-burning tile runs Fire::UpdateStartTimer once per burning
	# neighbour per frame, at that neighbour's connection rate; the 10-49 timer is rolled when it starts and cleared
	# (ResetStartTimer) on a frame with no burning neighbour. Reaching < 0 sets the tile on fire (fDamage 100).
	var burning := {}
	for room_id in ship.fires:
		for idx in ship.fires[room_id]:
			burning[tile_global(room_id, idx)] = true
	var touched := {}
	for g in burning:
		for nb in _neighbors(g):
			if burning.has(nb) or not tile_room.has(nb):
				continue
			var rate := fire_spread_rate(g, nb)
			if rate <= 0.0:
				continue
			if not spread_timers.has(nb):
				spread_timers[nb] = float(SPREAD_TIMER_MIN + _rng.randi() % SPREAD_TIMER_SPAN)
			spread_timers[nb] -= rate * seconds
			touched[nb] = true
	for g in spread_timers.keys():
		if not touched.has(g):
			spread_timers.erase(g)  # no longer has burning neighbors
		elif spread_timers[g] < 0.0:
			spread_timers.erase(g)
			ship.ignite(tile_room[g], tile_index(g))

	# Burn out from lack of oxygen (Fire::UpdateDeathTimer; fOxygen = (int) room O2, set by
	# ShipManager::UpdateEnvironment; 0 on a ship without an oxygen system).
	for room_id in ship.fires.keys():
		var room_fires: Dictionary = ship.fires[room_id]
		var o2 := fire_oxygen(room_id)
		for idx in room_fires.keys():
			var f: Dictionary = room_fires[idx]
			var g := tile_global(room_id, idx)
			var connected := 0
			for nb in _neighbors(g):
				if burning.has(nb) and connection(g, nb) != "":
					connected += 1
			if f.death >= 0.0:
				f.death -= (15 - 3 * connected) * DEATH_RATE * seconds
				if f.death < 0.0:
					f.death = 0.0
			if o2 <= FIRE_STARVE_BELOW:
				if f.death < 0.0:
					f.death = float(DEATH_TIMER_MIN + _rng.randi() % DEATH_TIMER_SPAN)
				elif f.death == 0.0:
					room_fires.erase(idx)
		if room_fires.is_empty():
			ship.fires.erase(room_id)


## Start-timer rate (per second) that a burning tile `from` gives its non-burning neighbour `to`, 0 = no spread
## (wall / space). ShipGraph::ConnectedGridSquares: same room or open / forced-open door -> 3, closed door ->
## 2 (iBlast 0) or 4 (blast door), hacked door -> 6; Spreader<Fire>::CheckSquareSpread maps 2 -> door level 1
## (0.0571), 4/5 -> 3 (0.01), anything else -> 0 (0.1; the hacked case included) for Fire::UpdateStartTimer.
func fire_spread_rate(from: Vector2i, to: Vector2i) -> float:
	if not tile_room.has(from) or not tile_room.has(to):
		return 0.0
	if tile_room[from] == tile_room[to]:
		return SPREAD_OPEN
	var d = door_between(from, to)
	if d == null:
		return 0.0
	if d.open or float(d.forced) > 0.0 or int(d.hacked) > 0:
		return SPREAD_OPEN
	return SPREAD_DOOR_LOW if door_blast() == 0 else SPREAD_DOOR_HIGH


## Oxygen a fire in the room sees (Fire::fOxygen): the room level truncated to an integer, or 0 when the ship has
## no oxygen system (ShipManager::UpdateEnvironment: systemKey[oxygen] == -1 -> SetOxygenLevel(0)).
func fire_oxygen(room_id: int) -> float:
	if ship.sys("oxygen") == null:
		return 0.0
	return floorf(float(oxygen.get(room_id, 100.0)))


func _tick_crew(seconds: float) -> void:
	var changed := false
	var no_o2 := ship.sys("oxygen") == null  # no oxygen system: crew suffocate whatever the stored O2 [exe]
	for c in ship.crew:
		if not c.is_alive():
			continue
		var dmg := 0.0
		if c.can_burn():
			dmg += FIRE_CREW * fires_in(c.room) * seconds
		# ShipManager::UpdateCrewmembers: O2 <= 5 % (inclusive).
		if (no_o2 or oxygen.get(c.room, 100.0) <= SUFFOCATE_BELOW) and c.can_suffocate():
			dmg += SUFFOCATE * c.suffocation_mult() * seconds \
				* AugmentRule.suffocation_mult(AugmentRule.crew_owner(ship, c))  # O2_MASKS x0.5
		if dmg > 0.0:
			var old_hp := c.hp
			c.hp = maxf(c.hp - dmg, 0.0)
			c.check_low_health_sound(old_hp)
			if c.hp <= 0:
				changed = true
	if changed:
		ship.crew_changed()


# ------------------------------------------------------------ doors

## Door level = effective power of the doors system (0 without one).
func door_level() -> int:
	return ship.system_power("doors")


## Blast level: 0 for door level 0-1, else level - 1 (max 3).
func door_blast() -> int:
	return clampi(door_level() - 1, 0, 3)


## A hacked door is a blast-2 door (DOOR_HEALTH_2 strength, rules/hacking.md).
func hacked_door_health() -> int:
	return DOOR_HEALTH[clampi(int(ShipAI.difficulty), 0, 2)][1]


func door_base_health() -> int:
	var b := door_blast()
	if b == 0:
		return DOOR_BASE_HEALTH
	return DOOR_HEALTH[clampi(int(ShipAI.difficulty), 0, 2)][b - 1]


## Keeps door health in step with the blast level (proportional rescale on a level change) and runs
## the forced-open timers.
func _tick_doors(seconds: float) -> void:
	var normal := door_base_health()
	for d in doors:
		_tick_door(d, seconds, normal)


func _tick_door(d: Dictionary, seconds: float, normal: int) -> void:
	if d.lockdown > 0.0:
		# Crystal lockdown (Door::OnLoop): 12 s at 50 HP, then the remembered health comes back.
		d.lockdown = maxf(d.lockdown - seconds, 0.0)
		if d.lockdown <= 0.0:
			_end_lockdown(d)
		return
	var base := hacked_door_health() if d.hacked > 0 else normal
	if d.base != base:
		d.health = int(minf(float(d.health) / d.base, 1.0) * base)
		d.base = base
	if d.forced > 0.0:
		d.forced = maxf(d.forced - seconds, 0.0)


## Ship::PauseLoop (rules/pause.md): while the game is paused the player ship's outer airlocks (vOuterAirlocks) still
## run Door::OnLoop — their forced-open / lockdown timers and blast-level health keep going; interior doors only
## animate (ShipView). Nothing else of the ship runs (no air, fire, crew).
func pause_tick_airlocks(seconds: float) -> void:
	var normal := door_base_health()
	for d in doors:
		if d.airlock:
			_tick_door(d, seconds, normal)


## One hit from an intruder (Door::ApplyDamage: -1 per hit, whatever the damage). At 0 the door is
## forced open for 7 s and its health resets.
func damage_door(i: int) -> void:
	var d: Dictionary = doors[i]
	if d.forced > 0.0 and d.lockdown <= 0.0:
		return
	d.health -= 1
	if d.health < 1:
		d.forced = DOOR_FORCED_OPEN
		if d.lockdown > 0.0:
			d.lockdown = 0.0  # breaking a locked-down door ends its lockdown (Door::ApplyDamage)
			_end_lockdown(d)
		d.health = d.base
		d.open = true


## Door::SetLockdown(true): 12 s tracker (restarted by a second lockdown), health and base set to 50; the normal
## base health is remembered.
func set_lockdown(i: int) -> void:
	var d: Dictionary = doors[i]
	if d.lockdown <= 0.0:
		d.lock_base = d.base
	d.lockdown = LockdownRule.DURATION
	d.health = LockdownRule.DOOR_HEALTH
	d.base = LockdownRule.DOOR_HEALTH


func _end_lockdown(d: Dictionary) -> void:
	d.base = d.lock_base if d.lock_base > 0 else DOOR_BASE_HEALTH
	d.health = d.base

func set_door(i: int, open: bool) -> void:
	if not open and doors[i].forced > 0.0:
		return  # a broken door stays open while forced
	if open and doors[i].hacked > 0:
		return  # hacked doors are held closed
	doors[i].open = open


func set_all_doors(open: bool, include_airlocks := false) -> void:
	for i in doors.size():
		if not doors[i].airlock or include_airlocks:
			set_door(i, open)
