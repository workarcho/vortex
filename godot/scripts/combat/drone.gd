class_name Drone
extends RefCounted
## One drone of a drone-system slot (rules/drones.md). Holds the system-side state (power, deployment,
## rebuild timer, hack) and the behaviour of space drones: flight paths, cooldowns, targeting
## (CombatDrone, DefenseDrone, SuperShieldDrone, ShipRepairDrone, BoarderPodDrone). Crew drones (REPAIR,
## BATTLE) and delivered boarders are CrewMember objects linked through `crew`.
##
## Units: `f` = the frame's speed factor (seconds x 16). Velocities are px per f. Positions are in the
## space of `space_ship` (that ship's local coordinates, the same frame as its rooms and shield ellipse).
## The exe's space coordinates centre a ship on (200, 200); the prototype uses the ship's shield centre
## for that point (as Projectile / Beam already do), so exe constants given in absolute space coordinates
## are converted relative to it (see "Implementation notes" in rules/drones.md).
##
## Combat reads `pending_shot` (set by take_shot / the defence turret) and spawns the projectile.

enum Kind { DEFENSE, COMBAT, REPAIR, BATTLE, BOARDER, SHIP_REPAIR, HACKING, SHIELD }
const KIND_OF := {"DEFENSE": Kind.DEFENSE, "COMBAT": Kind.COMBAT, "REPAIR": Kind.REPAIR,
	"BATTLE": Kind.BATTLE, "BOARDER": Kind.BOARDER, "SHIP_REPAIR": Kind.SHIP_REPAIR,
	"HACKING": Kind.HACKING, "SHIELD": Kind.SHIELD}

# Targetable types (rules/drones.md §6, exe constructors).
const T_SHIP := 0
const T_MISSILE := 1
const T_ASTEROID := 2  # asteroids and projectiles with <drone_targetable>1
const T_DRONE := 3
const T_LASER := 4
const T_OTHER := 5
const T_POD := 6  # boarding pod / hacking drone in flight
# Defence drone <target> types.
const TARGET_MISSILES := 1
const TARGET_DRONES := 3
const TARGET_LASERS := 4
const ACCEPTS := {1: [1, 2, 6], 4: [1, 2, 4, 6], 3: [3, 6]}

const REBUILD_TIME := 10.0  # s, destroyedTimer after BlowUp / crew drone death
const HIT_RADIUS := 10.0  # px, projectile end-of-frame position vs drone (squared distance < 100)
const ION_STUN_PER_ION := 5.0  # s of ionStun per ion point
const DRIFT_DECAY := 0.1  # UpdatePoweredDown: v -= 0.1 v f
const DRIFT_MAX_DIST := 400.0  # px from the movement target's ellipse centre: drift stops
const STUN_SPIN := 30.0  # deg per f while stunned (visual)
const COMBAT_ELLIPSE := 1.15  # combat / hull repair destinations: just outside the shield ellipse
const COMBAT_SPEED_DIV := 350.0  # combat speed per f = speed x max(a, b) / 350
const ARRIVAL_PAUSE := 0.5  # s at each combat destination before firing
const PAUSE_DRIFT_DIV := 1.5  # drift during the pause: pos += v x pause / 1.5 per f
const BEAM_EXTRA_PAUSE := 0.5  # beam drones stand still while sweeping
const DEFENSE_DEPLOY_COOLDOWN := 1.0  # s, defence drone cooldown on deployment
const TURRET_TURN := 30.0  # deg per f (480 deg/s)
# Defence aim box: exe -150 < x, y < 450 in space coordinates around a (200, 200) ship centre.
const AIM_BOX_MIN := -350.0
const AIM_BOX_MAX := 250.0
const DEFAULT_SHOT_SPEED := 60.0
const SUPER_SHIELD_TIME := [8.0, 10.0, 13.0, 16.0, 20.0]  # s by current super-shield layers (>= 4: 20)
const SUPER_SHIELD_MAX := 5
const SHIELD_SLOW_FROM := 2.5  # s of cooldown left: the shield drone slows down
const SHIELD_SLOW_STOP := 1.5  # ... and stops; a 3 s glow starts
const SHIELD_GLOW := 3.0
const POD_EXIT_DX := 600.0  # exe x = 800 vs a ship centre at 200: leaves its own space 600 px to the right
const POD_ENTRY_RADIUS := 600.0  # enters the target space on this circle around the shield centre
const HACK_DESTROY_AFTER := 2.0  # s hacked before the 15 %/s destruction roll starts (hacking.md)
const HACK_DESTROY_CHANCE := 3  # out of 20
const HACK_EXIT_DIST := 600.0  # hacking drone leaves its ship to x = 800 (player) / y = -400 (enemy)
const HACK_ENTRY_DIST := 600.0  # it enters the target space this far out along its landing line
const HACK_LOOKAHEAD := 20.0  # px: stops when the point this far ahead along its velocity is in a room

var bp := {}
var kind := Kind.COMBAT
var slot := 0
var owner: ShipState
var _scramble_goal := 0.0  # DEFENSE_SCRAMBLER: random turret goal while disrupted
var weapon: WeaponState = null  # the drone's <weaponBlueprint> (projectile / beam data)
var rng: RandomNumberGenerator

# Drone system state (rules/drones.md §2)
var powered := false
var bonus_power := 0  # zoltan bars given to this drone (DroneSystem::UpdateBonusPower); reactor cost = power - bonus
var deployed := false
var dead := false  # bDead: killed this frame; the drone system undeploys it (step 4)
var rebuild_on_death := true  # SetDestroyed(true, rebuild): 10 s rebuild timer
var destroyed_timer := 0.0  # s until the slot can be deployed again
var hack_level := 0
var hack_time := 0.0

# Space drone state (§3-§9)
var space_ship: ShipState = null  # the ship whose space it flies in
var move_ship: ShipState = null  # movement target (ellipse it flies around)
var target_ship: ShipState = null  # weapon target
var pos := Vector2.ZERO
var last_pos := Vector2.ZERO
var vel := Vector2.ZERO  # px per f (last movement, kept while drifting)
var destination := Vector2.ZERO
var theta := 0  # degrees: last destination angle (combat) / next orbit waypoint (defence)
var pause := -1.0  # combat: s left at the destination (-1 = flying)
var extra_pause := 0.0  # beam drone: s it stands still after firing
var fire_ready := false  # bFire
var lifespan := -1  # shots / repairs left (-1 = infinite)
var ion_stun := 0.0
var exploding := -1.0  # s left of the BlowUp animation (-1 = none)
var aim_angle := 0.0  # deg, turret / body aim
var heading := 0.0  # deg, flight direction (engine flame)
var spin := 0.0  # deg, stun spin (visual)
var cooldown := 0.0  # defence / shield drone weapon cooldown (s)
# Defence targeting (offers, PickTarget)
var has_target := false
var target_point := Vector2.ZERO
var target_vel := Vector2.ZERO  # px per f
var target_id := 0
var target_type := T_OTHER  # currentTargetType (reset every frame)
var shot_at_id := 0  # shotAtTargetId
# Combat drone target point (a random room centre of the target)
var shot_point := Vector2.ZERO
var has_shot_point := false
# Boarding pod: 0 leaving its own space, 1 flying to the target room, 2 delivered (hidden)
var pod_phase := 0
# Hacking drone: pod_phase 0 leaving / 1 flying to `destination` / 2 attached; time since landing
var land_time := -1.0
# Super shield drone
var glow := 0.0
var _glow_started := false
# Crew drone / delivered boarder
var crew: CrewMember = null
# Shot for Combat to spawn: {kind: "laser" | "beam" | "repair", from, to, to2, ship (space), target}
var pending_shot := {}


func _init(blueprint: Dictionary, ship: ShipState, slot_index: int) -> void:
	bp = blueprint
	owner = ship
	slot = slot_index
	rng = ship.rng
	kind = KIND_OF.get(String(bp.get("type", "")), Kind.COMBAT)
	var wn := String(bp.get("weapon", ""))
	if wn != "":
		var w := FtlData.weapon_blueprint(wn)
		if not w.is_empty():
			weapon = WeaponState.new(w, 99)
			weapon.powered = false
	theta = rng.randi() % 360  # SpaceDrone constructor


# ------------------------------------------------------------ queries

func required_power() -> int:
	return int(bp.get("power", 0))


func short_name() -> String:
	var s := String(bp.get("short", ""))
	return s if s != "" else FtlData.blueprint_title(String(bp.get("name", "")), "drone")


func is_space() -> bool:
	return kind in [Kind.DEFENSE, Kind.COMBAT, Kind.BOARDER, Kind.SHIP_REPAIR, Kind.HACKING, Kind.SHIELD]


func is_crew() -> bool:
	return kind in [Kind.REPAIR, Kind.BATTLE]


func rebuilding() -> bool:
	return destroyed_timer > 0.0


## SpaceDrone::GetStunned: ion stun or own hack level >= 2.
func stunned() -> bool:
	return ion_stun > 0.0 or hack_level >= 2


## Hacking drone attached to the target hull (HackingDrone arrived).
func arrived() -> bool:
	return kind == Kind.HACKING and pod_phase == 2


## In space and hittable: deployed, alive, not exploding, not a delivered pod.
func in_space() -> bool:
	return is_space() and deployed and not dead and exploding < 0.0 and space_ship != null \
		and not (kind == Kind.BOARDER and pod_phase == 2)


## Targetable type: 3 for space drones; 6 for a pod / hacking drone in flight (powered, target visible).
func targetable_type() -> int:
	if kind == Kind.HACKING:
		var t := target_ship
		if powered and t != null and not t.is_cloaked() and pod_phase < 2:
			return T_POD
		return T_OTHER
	if kind == Kind.BOARDER:
		var t := owner.opponent
		if powered and t != null and not t.is_cloaked() and pod_phase < 2:
			return T_POD
		return T_OTHER
	return T_DRONE


## SpaceDrone::ValidTarget: powered, deployed, alive, not stunned.
func valid_target() -> bool:
	return in_space() and powered and not stunned() and not arrived()


## SpaceDrone::GetSpeed: last movement per f (0 if unpowered).
func speed_vector(f: float) -> Vector2:
	if not powered or not deployed or f <= 0.0:
		return Vector2.ZERO
	return (pos - last_pos) / f


## Combat drone HasTarget: a weapon target that exists and is hostile.
func _hostile_target() -> bool:
	var t := owner.opponent
	return t != null and not t.is_destroyed() and t.hostile


## CanBeDeployed per class (rules/drones.md §2).
func can_be_deployed() -> bool:
	match kind:
		Kind.COMBAT:
			return _hostile_target()
		Kind.BOARDER:
			var t := owner.opponent
			return t != null and not t.is_destroyed() and (t.super_shield < 1 or owner.is_player)
		Kind.HACKING:
			return false  # hook: the hacking system launches it (rules/hacking.md, next batch)
	return true


## CanBeRecovered (DRONE_RECOVERY refund): space drones except pods and the hacking drone.
func can_be_recovered() -> bool:
	return is_space() and kind != Kind.BOARDER and kind != Kind.HACKING


## RecallOnJump: every space drone (crew drones stay).
func recall_on_jump() -> bool:
	return is_space()


func _ellipse_ship() -> ShipState:
	return move_ship if move_ship != null else space_ship


## Flight speed per f.
func flight_speed() -> float:
	var s := float(bp.get("speed", 0.0))
	match kind:
		Kind.COMBAT, Kind.SHIP_REPAIR:
			var e := _ellipse_ship()
			return s * maxf(e.shield_axes.x, e.shield_axes.y) / COMBAT_SPEED_DIV
		Kind.SHIELD:
			if glow > 0.0:
				return 0.0
			if cooldown < SHIELD_SLOW_FROM:
				return s * maxf(0.0, cooldown - SHIELD_SLOW_STOP)
	return s


func super_shield_time() -> float:
	if move_ship == null:
		return SUPER_SHIELD_TIME[0]
	return SUPER_SHIELD_TIME[clampi(owner.super_shield, 0, SUPER_SHIELD_TIME.size() - 1)]


# ------------------------------------------------------------ deployment / power (called by DroneSystemRule)

## SetDeployed(true): initial position and state per class.
func on_deploy() -> void:
	ion_stun = 0.0
	dead = false
	rebuild_on_death = true
	exploding = -1.0
	pause = -1.0
	extra_pause = 0.0
	fire_ready = false
	has_target = false
	has_shot_point = false
	shot_at_id = 0
	lifespan = -1
	glow = 0.0
	_glow_started = false
	vel = Vector2.ZERO
	match kind:
		Kind.COMBAT:
			move_ship = owner.opponent
			target_ship = owner.opponent
			space_ship = move_ship
			_randomize_start()
		Kind.SHIP_REPAIR:
			move_ship = owner
			target_ship = owner
			space_ship = owner
			lifespan = 3 + rng.randi() % 3  # 3-5 repairs
			_randomize_start()
		Kind.DEFENSE, Kind.SHIELD:
			move_ship = owner
			space_ship = owner
			cooldown = super_shield_time() if kind == Kind.SHIELD else DEFENSE_DEPLOY_COOLDOWN
			_randomize_start()
		Kind.BOARDER:
			move_ship = owner
			target_ship = owner.opponent
			space_ship = owner
			pod_phase = 0
			var ds := owner.sys("drones")
			pos = owner.room_rect(ds.room).get_center() if ds else owner.shield_center
			destination = Vector2(owner.shield_center.x + POD_EXIT_DX, pos.y)
		Kind.HACKING:
			# HackingDrone::SetDeployed: from the hacking room toward x = 800 (player) / y = -400 (enemy).
			move_ship = owner
			target_ship = owner.opponent
			space_ship = owner
			pod_phase = 0
			land_time = -1.0
			var hs := HackingRule.system(owner)
			pos = owner.room_rect(hs.room).get_center() if hs and hs.room >= 0 else owner.shield_center
			if owner.player_art():  # (autobattle: an enemy-art ship on the player side launches upward like an enemy)
				destination = Vector2(owner.shield_center.x + HACK_EXIT_DIST, pos.y)
			else:
				destination = Vector2(pos.x, owner.shield_center.y - HACK_EXIT_DIST)
		_:
			space_ship = null
	last_pos = pos
	if is_space() and space_ship != null:
		aim_angle = rad_to_deg((destination - pos).angle()) if destination != pos else 0.0
		heading = aim_angle


## SetDeployed(false): leaves space; its crew drone / delivered boarder is removed from the ship it is on.
func on_undeploy() -> void:
	if crew != null:
		for s in [owner, owner.opponent]:
			# A dead crew drone stays as a body until ShipState removes it (its explosion animation).
			if s != null and s.crew.has(crew) and crew.is_alive():
				s.crew.erase(crew)
				s.teleporting.erase(crew)
				s.crew_changed()
		crew.drone = null
		crew = null
	space_ship = null
	pause = -1.0
	fire_ready = false
	has_target = false
	ion_stun = 0.0
	exploding = -1.0
	pending_shot = {}


## Powered again while deployed (Drone::SetPowered / DefenseDrone::SetPowered).
func on_repowered() -> void:
	if kind == Kind.DEFENSE or kind == Kind.SHIELD:
		cooldown = super_shield_time() if kind == Kind.SHIELD else float(bp.get("cooldown", 1.0))
		fire_ready = false
		var e := _ellipse_ship()
		if e:  # head back to the ellipse point at the drifted position's angle
			var d := (pos - e.shield_center) / e.shield_axes
			theta = int(round(rad_to_deg(atan2(d.y, d.x)))) % 360
			_next_waypoint()


## Depowered (DePowerDrone): stays deployed; the hull repair drone is destroyed (part lost).
func on_depowered() -> void:
	pause = -1.0
	fire_ready = false
	if kind == Kind.SHIP_REPAIR and deployed:
		kill(false)
	if kind == Kind.SHIELD:
		cooldown = super_shield_time()
		glow = 0.0
		_glow_started = false


## SetDestroyed(true, rebuild) through the bDead flag: the drone system undeploys it next.
func kill(rebuild: bool) -> void:
	if dead:
		return
	dead = true
	rebuild_on_death = rebuild


## SpaceDrone::BlowUp: explosion animation and sound, then destroyed with a 10 s rebuild.
func blow_up() -> void:
	if exploding >= 0.0 or dead:
		return
	var an := FtlData.anim("explosion1")
	exploding = maxf(float(an.get("time", 0.5)), 0.1) if not an.is_empty() else 0.5
	FtlData.play("smallExplosion")


## Drone::SetHacked (drone system hacked: level 2 stuns; after 2 s, 15 % per whole second to blow up).
func set_hacked(level: int, seconds: float) -> void:
	hack_level = level
	if level < 2 or not deployed or dead:
		hack_time = 0.0
		return
	var before := int(hack_time)
	hack_time += seconds
	if hack_time > HACK_DESTROY_AFTER and int(hack_time) > before and rng.randi() % 20 < HACK_DESTROY_CHANCE:
		if is_space():
			blow_up()
		elif crew != null:
			crew.hp = 0.0  # CrewDrone::BlowUp (-1000 HP)


# ------------------------------------------------------------ crew drones

## Deploys the crew drone in the drone-system room (CrewMember::Restart there; spill like an arrival).
func spawn_crew() -> bool:
	var ds := owner.sys("drones")
	var c := CrewMember.new("human", owner.is_player)
	c.make_drone("repair" if kind == Kind.REPAIR else "battle")
	c.drone = self
	if not TeleporterRule.place_arrival(owner, c, ds.room if ds else -1):
		return false
	crew = c
	return true


## The crew drone / delivered boarder died -> the drone is destroyed with a rebuild (part lost).
func check_crew() -> void:
	if not deployed or dead:
		return
	if is_crew() or (kind == Kind.BOARDER and pod_phase == 2):
		if crew == null or not crew.is_alive():
			kill(true)


# ------------------------------------------------------------ space flight

func _ellipse_point(deg: float, scale: float) -> Vector2:
	var e := _ellipse_ship()
	var r := deg_to_rad(deg)
	return e.shield_center + Vector2(cos(r) * e.shield_axes.x, sin(r) * e.shield_axes.y) * scale


## PickDestination per class.
func pick_destination() -> void:
	match kind:
		Kind.COMBAT, Kind.SHIP_REPAIR:
			var prev := theta
			var t := rng.randi() % 360
			var guard := 0
			while absi(t - prev) < 90 and guard < 100:  # plain difference, no wrap-around
				t = rng.randi() % 360
				guard += 1
			theta = t
			destination = _ellipse_point(theta, COMBAT_ELLIPSE)
		Kind.DEFENSE, Kind.SHIELD:
			_next_waypoint()


## Defence orbit: waypoint on the ellipse at theta, then theta += 1.
func _next_waypoint() -> void:
	destination = _ellipse_point(theta, 1.0)
	theta = (theta + 1) % 360


## RandomizeStartingPosition: appear on a destination, then head to the next one.
func _randomize_start() -> void:
	pick_destination()
	pos = destination
	pick_destination()


## Straight line toward `dest` (GetNextPoint). Returns true on arrival (exactly at the destination).
func _fly_to(dest: Vector2, speed: float, f: float) -> bool:
	var d := dest - pos
	var step := speed * f
	if d.length() <= step:
		if d.length() > 0.0:
			vel = d.normalized() * speed  # keeps its flight speed for the pause drift
		pos = dest
		return true
	if speed <= 0.0:
		vel = Vector2.ZERO
		return false
	vel = d.normalized() * speed
	pos += vel * f
	heading = rad_to_deg(vel.angle())
	return false


## UpdatePoweredDown: keeps drifting with decaying speed; stops when slow or far from its ellipse.
func _drift(f: float) -> void:
	pos += vel * f
	vel -= vel * DRIFT_DECAY * f
	var e := _ellipse_ship()
	if vel.length() < 1.0 or (e != null and pos.distance_to(e.shield_center) > DRIFT_MAX_DIST):
		vel = Vector2.ZERO


## One frame of a deployed space drone (SpaceDrone::OnLoop + class OnLoop). Shots go to `pending_shot`.
func step(f: float) -> void:
	if not deployed or space_ship == null or dead:
		return
	var sec := f / GameClock.BASE
	last_pos = pos
	if weapon:
		weapon.powered = powered  # a drone beam is cut when its drone loses power
	if exploding >= 0.0:
		exploding -= sec
		if exploding < 0.0:
			kill(true)
		return
	if ion_stun > 0.0:
		ion_stun = maxf(ion_stun - sec, 0.0)
	match kind:
		Kind.DEFENSE, Kind.SHIELD:
			_step_defense(f, sec)
		Kind.COMBAT, Kind.SHIP_REPAIR:
			_step_combat(f, sec)
		Kind.BOARDER:
			_step_pod(f)
		Kind.HACKING:
			_step_hack(f, sec)
	if stunned():
		spin = fmod(spin + STUN_SPIN * f, 360.0)


func _step_combat(f: float, sec: float) -> void:
	if not powered or stunned():
		_drift(f)
		pause = -1.0
		fire_ready = false
		return
	if not has_shot_point and target_ship != null and kind == Kind.COMBAT:
		_pick_shot_point()
	if has_shot_point and kind == Kind.COMBAT:
		aim_angle = rad_to_deg((shot_point - pos).angle())
	if extra_pause > 0.0:  # beam drone: still while its beam sweeps
		extra_pause -= sec
		return
	if pause > 0.0:
		pos += vel * (pause / PAUSE_DRIFT_DIV) * f
		pause -= sec
		if pause <= 0.0:
			pause = -1.0
			fire_ready = true
			if lifespan > 0:
				lifespan -= 1
		return
	if _fly_to(destination, flight_speed(), f):
		pick_destination()
		pause = ARRIVAL_PAUSE


## PickTarget (combat): centre of a uniformly random room of the target.
func _pick_shot_point() -> void:
	var t := target_ship if kind == Kind.COMBAT else owner
	if t == null or t.layout.rooms.is_empty():
		return
	shot_point = t.random_room_center(rng)
	has_shot_point = true


## GetNextProjectile for combat and hull repair drones (call once per frame after step).
## Returns the shot to spawn ({} = none) and handles lifespan expiry.
func take_shot() -> Dictionary:
	if kind == Kind.DEFENSE or kind == Kind.SHIELD:
		var s := pending_shot
		pending_shot = {}
		return s
	if not fire_ready or not powered or hack_level >= 2 or not deployed or dead or exploding >= 0.0:
		return {}
	var out := {}
	if kind == Kind.SHIP_REPAIR:
		fire_ready = false
		var p := owner.random_room_center(rng)
		out = {"kind": "repair", "to": p, "ship": owner}
	elif kind == Kind.COMBAT:
		if not _hostile_target():
			return {}
		fire_ready = false
		var t := target_ship
		if t.is_cloaked() or t.is_destroyed() or t.jumping:
			return {}  # shot skipped
		if not has_shot_point:
			_pick_shot_point()
		var from := Vector2(int(pos.x), int(pos.y))
		if weapon != null and weapon.is_beam():
			var p2 := shot_point
			var guard := 0
			while p2 == shot_point and guard < 50 and t.layout.rooms.size() > 1:
				p2 = t.random_room_center(rng)
				guard += 1
			out = {"kind": "beam", "from": from, "to": shot_point, "to2": p2, "ship": t, "target": t}
			extra_pause = BEAM_EXTRA_PAUSE
		else:
			out = {"kind": "laser", "from": from, "to": shot_point, "ship": t, "target": t}
		has_shot_point = false
		_pick_shot_point()  # the next target point is chosen right after the shot
	if lifespan == 0:
		kill(false)  # lifespan < 1: destroyed without rebuild
	return out


# ------------------------------------------------------------ defence / shield drones

func _step_defense(f: float, sec: float) -> void:
	target_type = T_OTHER  # currentTargetType reset at the start of the drone's frame
	if not powered or stunned():
		_drift(f)
	else:
		if _fly_to(destination, flight_speed(), f):
			_next_waypoint()
		cooldown -= sec
		if cooldown < 0.0:
			fire_ready = true
	if kind == Kind.SHIELD:
		_shield_update(sec)
	else:
		_pick_target(f)


## SuperShieldDrone::OnLoop: glow below 1.5 s, a super-shield layer when ready.
func _shield_update(sec: float) -> void:
	if not powered:
		cooldown = super_shield_time()
		fire_ready = false
		return
	if glow > 0.0:
		glow = maxf(glow - sec, 0.0)
	if cooldown < SHIELD_SLOW_STOP and not _glow_started:
		_glow_started = true
		glow = SHIELD_GLOW
		FtlData.play("shieldDroneCharge")
	if fire_ready and hack_level < 2:
		owner.add_super_shield(pos)  # superShieldUp wave from the drone
		FtlData.play("shieldDroneActivate")
		fire_ready = false
		cooldown = super_shield_time()
		_glow_started = false


## Defence drone offer (DefenseDrone::ValidTargetObject + SetWeaponTarget). `id` = target identity,
## `ttype` its targetable type, `p` / `v` its current position and per-f velocity.
func offer(id: int, ttype: int, p: Vector2, v: Vector2) -> void:
	if kind != Kind.DEFENSE or not powered or not deployed or dead:
		return
	var tt := int(bp.get("target_type", TARGET_MISSILES))
	if not ACCEPTS.get(tt, []).has(ttype):
		return
	if id == shot_at_id and tt != TARGET_DRONES:
		return
	# Precedence: once a missile is accepted only missiles replace it; once a type 2 only types 1-3.
	if target_type == T_MISSILE and ttype != T_MISSILE:
		return
	if target_type == T_ASTEROID and ttype > T_DRONE:
		return
	target_type = ttype
	has_target = true
	target_point = p
	target_vel = v
	target_id = id


## Globals::AimAhead: time (in f) for a shot of speed `s` from the origin to meet a target at `rel`
## moving with `v`; <= 0 when there is no solution.
static func aim_ahead(rel: Vector2, v: Vector2, s: float) -> float:
	var a := v.dot(v) - s * s
	var b := 2.0 * rel.dot(v)
	var c := rel.dot(rel)
	if absf(a) < 1e-6:
		return -c / b if absf(b) > 1e-6 else -1.0
	var disc := b * b - 4.0 * a * c
	if disc < 0.0:
		return -1.0
	var sq := sqrt(disc)
	var t1 := (-b - sq) / (2.0 * a)
	var t2 := (-b + sq) / (2.0 * a)
	var t := minf(t1, t2)
	if t <= 0.0:
		t = maxf(t1, t2)
	return t


## Turn `from` toward `to` by at most `step` degrees the shorter way, snapping when it would pass.
static func turn_toward(from: float, to: float, step: float) -> float:
	var diff := fposmod(to - from + 180.0, 360.0) - 180.0
	if absf(diff) <= step:
		return to
	return from + signf(diff) * step


## Inside the defence aim box (relative to the own shield centre).
func in_aim_box(p: Vector2) -> bool:
	var r := p - space_ship.shield_center
	return r.x > AIM_BOX_MIN and r.x < AIM_BOX_MAX and r.y > AIM_BOX_MIN and r.y < AIM_BOX_MAX


## DefenseDrone::PickTarget (+ the shot of GetNextProjectile): lead, turret turn, box, fire.
func _pick_target(f: float) -> void:
	if AugmentRule.drones_disrupted(owner):
		# bDisrupted (DEFENSE_SCRAMBLER on the ship it fights): the turret turns toward random angles, never fires.
		if is_equal_approx(aim_angle, _scramble_goal):
			_scramble_goal = float(randi() % 360)  # visual only (no simulation effect)
		aim_angle = turn_toward(aim_angle, _scramble_goal, TURRET_TURN * f)
		has_target = false
		return
	if not has_target:
		return
	var shot_speed := weapon.speed() if weapon else DEFAULT_SHOT_SPEED
	var t := aim_ahead(target_point - pos, target_vel, shot_speed)
	if t > 0.0:
		target_point += target_vel * t
	var want := rad_to_deg((target_point - pos).angle())
	aim_angle = turn_toward(aim_angle, want, TURRET_TURN * f)
	if in_aim_box(target_point) and is_equal_approx(fposmod(aim_angle - want, 360.0), 0.0):
		shot_at_id = target_id  # marked even when the cooldown is not ready (quirk a)
		if powered and hack_level < 2 and fire_ready:
			pending_shot = {"kind": "laser", "from": pos, "to": target_point, "ship": space_ship,
				"target": null}
			fire_ready = false
			cooldown = float(bp.get("cooldown", 1.0))
			has_target = false
	else:
		has_target = false


# ------------------------------------------------------------ boarding pod

func _step_pod(f: float) -> void:
	if pod_phase == 2:
		return  # delivered: hidden, alive while its boarder lives
	var tgt := owner.opponent
	var blocked := pod_phase == 1 and tgt != null and (tgt.is_cloaked() or tgt.jumping)
	if not powered or stunned() or blocked or tgt == null:
		_drift(f)
		return
	var spd := float(bp.get("speed", 18.0))
	if pod_phase == 0:
		if _fly_to(destination, spd, f):
			# Leaves its own space: enters the target space on the 600 px circle, aims at a system room.
			space_ship = tgt
			move_ship = tgt
			var ang := deg_to_rad(float(rng.randi() % 360))
			pos = tgt.shield_center + Vector2.from_angle(ang) * POD_ENTRY_RADIUS
			last_pos = pos
			destination = _random_system_room_center(tgt)
			pod_phase = 1
		aim_angle = heading
		return
	var was_inside := tgt.inside_shield(pos)
	var arrived := _fly_to(destination, spd, f)
	aim_angle = heading
	if tgt.super_shield >= 1 and not was_inside and tgt.inside_shield(pos):
		blow_up()  # super shields pop the pod
		return
	if arrived:
		_deliver(tgt)


# ------------------------------------------------------------ hacking drone (rules/hacking.md)

## HackingDrone::OnLoop: 448 px/s; frozen while unpowered, stunned, or the target is cloaked /
## jumping. Leaves its own space, enters the target space on its landing line, and stops when the point
## 20 px ahead is inside a room (landing sound, land + extend animations). Super shields pop it.
func _step_hack(f: float, sec: float) -> void:
	if pod_phase == 2:
		land_time += sec
		return
	var tgt := target_ship
	var blocked := tgt == null or (pod_phase == 1 and (tgt.is_cloaked() or tgt.jumping))
	if not powered or stunned() or blocked:
		vel = Vector2.ZERO  # UpdatePoweredDown: the hacking drone does not move (rules/hacking.md)
		return
	var spd := float(bp.get("speed", 28.0))
	if pod_phase == 0:
		if _fly_to(destination, spd, f):
			var room := HackingRule.target_room(owner)
			var land := HackingRule.pick_landing(tgt, room, rng)
			space_ship = tgt
			move_ship = tgt
			destination = land.point
			pos = land.point - land.dir * HACK_ENTRY_DIST
			last_pos = pos
			heading = rad_to_deg(land.dir.angle())
			pod_phase = 1
		aim_angle = heading
		return
	var was_inside := tgt.inside_shield(pos)
	var reached := _fly_to(destination, spd, f)
	aim_angle = heading
	if tgt.super_shield >= 1 and not was_inside and tgt.inside_shield(pos):
		blow_up()  # crossing a super shield destroys it
		return
	var ahead := pos + Vector2.from_angle(deg_to_rad(heading)) * HACK_LOOKAHEAD
	if reached or tgt.room_at(ahead) >= 0:
		pod_phase = 2
		land_time = 0.0
		vel = Vector2.ZERO
		FtlData.play("hackLand")
		Combat.log("%s hacking drone lands on %s" % [owner.blueprint.name, tgt.blueprint.name])


## GetRandomTargettingPoint(true): centre of a uniformly random system's room.
func _random_system_room_center(t: ShipState) -> Vector2:
	var rooms := []
	for id in t.systems:
		var r: int = t.systems[id].room
		if not rooms.has(r):
			rooms.append(r)
	if rooms.is_empty():
		return t.random_room_center(rng)
	return t.room_rect(rooms[rng.randi() % rooms.size()]).get_center()


## Impact: the boarder (BoarderDrone / IonDrone) appears in the room hit, which gets a hull breach
## (DamageTarget with 0 damage and breachChance 10).
func _deliver(tgt: ShipState) -> void:
	pod_phase = 2
	var room := tgt.room_at(destination)
	var c := CrewMember.new("human", owner.is_player)
	c.make_drone("boarder_ion" if String(bp.get("name", "")) == "BOARDER_ION" else "boarder")
	c.drone = self
	if TeleporterRule.place_arrival(tgt, c, room):
		crew = c
		c.ai_task = CrewAI.make_task(CrewAI.FIGHT, c.room, "")
	else:
		kill(true)  # nowhere to stand (ship full of intruders)
		return
	var d := Damage.new()
	d.breach_chance = 10
	d.owner = 0 if owner.is_player else 1
	var r := tgt.apply_damage(room, d, rng)
	if r.breach:
		FtlData.play("hullBreach")
	Combat.log("%s boarding drone lands in room %d of %s%s" % [owner.blueprint.name, room,
		tgt.blueprint.name, " (breach)" if r.breach else ""])


# ------------------------------------------------------------ hits

## SpaceDrone::CollisionMoving response to a projectile within 10 px: returns true if the projectile is
## consumed. Ion stuns (5 s per point, only if powered) and never destroys; damage blows it up.
func hit_by(d: Damage) -> bool:
	if not in_space() or arrived():  # an attached hacking drone cannot be targeted
		return false
	if kind == Kind.HACKING:
		# HackingDrone::CollisionMoving: ion adds 5 s of stun per point; any hull damage blows it up.
		if d.ion > 0:
			ion_stun += ION_STUN_PER_ION * d.ion
		if d.damage > 0:
			blow_up()
		return true
	var dodge := int(bp.get("dodge", 0))
	if dodge > 0 and powered and rng.randi() % 10 < dodge:
		return false  # "miss"
	if d.ion > 0:
		if powered:
			ion_stun = ION_STUN_PER_ION * d.ion
	elif d.damage > 0:
		blow_up()
	return true
