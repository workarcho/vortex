class_name CrewCombat
extends RefCounted
## Crew-vs-crew combat aboard one ship (rules/crew_combat.md): target choice
## (ShipManager::UpdateCrewmembers), attacks (CrewMember::OnLoop + CrewAnimation punch/shoot timers),
## door attacks by intruders (Door::ApplyDamage).

const SHOT_RANGE := 22.0  # px: a shot at a point farther than this in another room becomes a 0.1 hit, no laser
# Crew lasers (CrewLaser, rules/crew_combat.md "Crew lasers"): projectiles that deal their damage when they land.
const SHOT_SPEED := 10.0  # speed_magnitude, px per speed-factor unit (x16 = 160 px/s)
const SHOT_JITTER := 8  # +-px added to a crew target's point per shot (not for doors: ExactTarget)
const SHOT_HIT_TIME := 0.5  # Projectile death_animation explosion_missile1_strip9: 9 frames, 0.5 s (x0.5 scale)
const FAR_SHOT_DAMAGE := 0.1  # fDamageDone when the target point is out of range (UpdateShooting)
const DOOR_AIM := Vector2(0, 5)  # Door::GetPosition (y + 8) + PositionShift 0 - 3, from the door centre
# RockAnimation / MantisAnimation::FireShot: no shoot timer; one shot each time the looping shoot animation
# (4 frames, 1.0 s) reaches frame 3.
const FRAME_FIRE_RACES := ["rock", "mantis"]
const FRAME_FIRE_LOOP := 1.0
const FRAME_FIRE_FRAMES := 4
const FRAME_FIRE_AT := 3


# Ion boarding drone (IonDroneAnimation, rules/drones.md §9 "Ion boarding drone animation").
const ION_TIMER := 6.0  # shootTimer ResetMinMax(6000, 6000), looping; advances only while idle in status 7
const ION_CHARGE_TIME := 1.0  # boarder_ion_ion: 5 frames, 1 s, not looping (then holds its last frame)
const ION_EFFECT_RATE := 1.0  # ionEffect += 0.0625 per speed-factor unit (= 1/s) once the charge is done
const ION_EFFECT_FIRE := 1.25  # FireShot when ionEffect >= 1.25 -> discharge 2.25 s after the charge starts
const ION_EXPLOSION_TIME := 0.5  # explosion_big1_ion: 10 frames of 64 px, 0.5 s
const ION_EXPLOSION_HALF := 32.0  # int(fScale 1 x 64) / 2
const ION_DOOR_LOOP := 1.5  # boarder_ion_shoot_<dir>: 2 frames, 1.5 s, looping
const ION_DOOR_SPEED := 2.0  # the door strip is Update()d twice per frame (UpdateShooting + OnUpdate)
const ION_DAMAGE := 3  # IonDrone::GetRoomDamage: iIonDamage 3, iStun 6, bFriendlyFire false
const ION_STUN := 6.0


## Same-room hostile, living, standing crew of the other side.
static func opponents(ship: ShipState, c: CrewMember) -> Array:
	var side := c.is_intruder(ship)
	var out := []
	for o in ship.crew:
		if o != c and o.is_alive() and o.room == c.room and o.is_intruder(ship) != side 				and not ship.teleporting.has(o):  # crew in a teleport animation cannot be attacked
			out.append(o)
	return out


## Target selection for every crew member (second loop of ShipManager::UpdateCrewmembers).
static func update_targets(ship: ShipState) -> void:
	for c in ship.crew:
		if not c.is_alive():
			c.target = null
			c.fighting = false
			continue
		# CrewMember::OnLoop: drop a target that died or is no longer in our room.
		if c.target != null and (not c.target.is_alive() or c.target.room != c.room):
			c.target = null
		if not c.can_fight() or c.frozen:  # repair / ion drones never fight; unpowered drones are frozen
			c.target = null
			# The ion boarding drone still attacks a sealed door it is blocked by (crewTarget = blockingDoor;
			# IonDroneAnimation door branch).
			c.fighting = c.blocking_door >= 0 and not c.frozen
			continue
		c.shared_spot = false
		if c.room >= 0:
			var opp := opponents(ship, c)
			if not opp.is_empty():
				var pick: CrewMember = opp[ship.rng.randi() % opp.size()]
				var forced := false
				var me_ready := c.is_on_slot(ship)
				for o in opp:
					if o.target_room == c.target_room and o.slot == c.slot and me_ready and o.is_on_slot(ship):
						pick = o
						forced = true
						c.shared_spot = true
				if me_ready:  # ReadyToFight = AtFinalGoal
					set_target(c, pick if ship.hostile else null, forced)
		c.fighting = c.target != null or c.blocking_door >= 0


## CrewMember::SetCurrentTarget: an existing target is kept unless forced (all crew have the same
## priority); a null target clears it.
static func set_target(c: CrewMember, t: CrewMember, forced: bool) -> void:
	if c.target != null and not forced and t != null:
		return
	c.target = t


## One crew member's attack this frame (CrewMember::OnLoop damage step, CrewAnimation::OnUpdate punch /
## UpdateShooting, OnUpdateEffects shots). Returns true if it killed someone.
static func update_attack(ship: ShipState, c: CrewMember, seconds: float) -> bool:
	if not c.is_alive():
		c.shots.clear()  # a dying crew's shots are no longer drawn (OnRenderHealth skips status 3)
		c.damage_done = 0.0
		return false
	var killed := consume_damage(ship, c)
	if c.task == CrewMember.Task.SABOTAGE and not c.fighting:
		# CrewMember::UpdateRepair (sabotage branch, after the combat step): a landed sabotage shot's fDamageDone
		# is taken and thrown away (it only re-aims at the room centre) -> sabotage shots deal no damage.
		c.damage_done = 0.0
	if c.drone_kind == "boarder_ion":
		return killed  # IonDroneAnimation: no punches / crew lasers (update_ion_drone, after the task step)
	_animate_attack(ship, c, seconds)
	update_shots(ship, c, seconds)
	return killed


## CrewMember::OnLoop: while it has a target (crew in its room, or the door it is blocked by), the pending
## fDamageDone (from a shot that landed or a punch, last frame) x race x mind boost x combat skill is dealt to
## that target, whoever it is now. With no target the damage stays pending. Returns true on a kill.
static func consume_damage(ship: ShipState, c: CrewMember) -> bool:
	var t := c.target
	if t != null and (not t.is_alive() or t.room != c.room):
		c.target = null
		t = null
	if t == null and c.blocking_door < 0:
		return false
	var dmg := c.damage_done * c.hit_multiplier()
	c.damage_done = 0.0
	if c.blocking_door >= 0:
		if dmg > 0.0:
			ship.env.damage_door(c.blocking_door)  # Door::ApplyDamage: -1 health per hit
		return false
	enemy_lockdown(ship, c)  # checked every frame with a crew target, before the damage
	if dmg <= 0.0:
		return false
	return _hit(ship, c, t, dmg)


## The animation side of an attack: punch timer (same tile) or shooting (door, crew target).
static func _animate_attack(ship: ShipState, c: CrewMember, seconds: float) -> void:
	if c.stun > 0.0:
		c.punch_time = -1.0  # stunned: animation forced to idle, no new punch / shot
		return
	if c.blocking_door >= 0:
		c.punch_time = -1.0
		var d: Dictionary = ship.env.doors[c.blocking_door]
		c.aim = ship.graph.door_center(d) + DOOR_AIM
		_face(c, c.aim)
		shoot(ship, c, c.aim, true, seconds)
		return
	var t := c.target
	if t == null or c.is_walking():
		c.punch_time = -1.0
		return
	c.aim = aim_point(ship, t)
	_face(c, c.aim)
	if c.shared_spot and not c.is_drone():
		# Punch: the animation lasts 2 x goal (goal 0.5-0.65 s); fDamageDone is set at the goal.
		if c.punch_time < 0.0:
			c.punch_time = 0.0
			c.punch_goal = ship.rng.randf_range(CrewMember.PUNCH_MIN, CrewMember.PUNCH_MAX)
			c.punch_hit = false
		c.punch_time += seconds
		if not c.punch_hit and c.punch_time > c.punch_goal:
			c.punch_hit = true
			c.damage_done = lerpf(CrewMember.HIT_MIN, CrewMember.HIT_MAX, ship.rng.randf())
		if c.punch_time >= 2.0 * c.punch_goal:
			c.punch_time = -1.0
		return
	c.punch_time = -1.0
	shoot(ship, c, c.aim, false, seconds)


## The point a crew member shoots at (CrewMember::OnLoop currentTarget): the target's integer position, y moved by
## its PositionShift - 3 (0 normally; two crew sharing a tile: intruder +7, defender -7).
static func aim_point(ship: ShipState, t: CrewMember) -> Vector2:
	var shift := 3.0
	if t.shared_spot and t.is_on_slot(ship):
		shift = 10.0 if t.is_intruder(ship) else -4.0
	return Vector2(floorf(t.pos.x), floorf(t.pos.y) + shift - 3.0)


## CrewAnimation::UpdateShooting: when the shot is due (shoot timer, or the rock / mantis animation frame), a
## point within 22 px or in the shooter's room gets a crew laser (jittered +-8 px unless exact, shot sound);
## farther in another room it becomes a 0.1 hit at once, without a laser. Sabotage shots too (their landing
## value is thrown away by the sabotage step, CrewCombat.update_attack).
static func shoot(ship: ShipState, c: CrewMember, at: Vector2, exact: bool, seconds: float) -> void:
	if not _fire_ready(ship, c, seconds):
		return
	var from := Vector2(floorf(c.pos.x), floorf(c.pos.y))
	if from.distance_to(at) > SHOT_RANGE and ship.room_at(from) != ship.room_at(at):
		c.damage_done = FAR_SHOT_DAMAGE
		return
	var to := at
	if not exact:
		to += Vector2(ship.rng.randi_range(-SHOT_JITTER, SHOT_JITTER), ship.rng.randi_range(-SHOT_JITTER, SHOT_JITTER))
	var v := to - from
	c.shots.append({"pos": from, "to": to, "heading": rad_to_deg(v.angle()) if v.length() > 0.0 else 0.0,
		"death": -1.0})
	c.shots_fired += 1


## CrewAnimation::OnUpdateEffects: every shot flies straight to its point at 160 px/s; when it is within one step
## it starts its hit animation (0.5 s, then removed) and sets fDamageDone = 3..7 (dealt next frame).
static func update_shots(ship: ShipState, c: CrewMember, seconds: float) -> void:
	var step := SHOT_SPEED * seconds * GameClock.BASE
	var i := 0
	while i < c.shots.size():
		var s: Dictionary = c.shots[i]
		if s.death < 0.0:
			s.pos = (s.pos as Vector2).move_toward(s.to, step)
			if (s.pos as Vector2).distance_squared_to(s.to) <= step * step:
				s.death = 0.0
				c.damage_done = lerpf(CrewMember.HIT_MIN, CrewMember.HIT_MAX, ship.rng.randf())
		if s.death >= 0.0:
			s.death += seconds  # Projectile::Dead updates the hit animation the same frame
			if s.death >= SHOT_HIT_TIME:
				c.shots.remove_at(i)
				continue
		i += 1


## Shot due this frame: the looping shoot timer (CrewAnimation::FireShot), or for rock / mantis the shoot
## animation entering frame 3 (once per 1.0 s loop; the animation only runs while shooting).
static func _fire_ready(ship: ShipState, c: CrewMember, seconds: float) -> bool:
	if c.drone_kind == "" and c.race in FRAME_FIRE_RACES:
		var frame := int(c.shoot_anim / FRAME_FIRE_LOOP * FRAME_FIRE_FRAMES) % FRAME_FIRE_FRAMES
		var fire := false
		if frame == FRAME_FIRE_AT:
			if not c.shot_frame_done:
				c.shot_frame_done = true
				fire = true
		elif frame < FRAME_FIRE_AT:
			c.shot_frame_done = false
		c.shoot_anim = fmod(c.shoot_anim + seconds, FRAME_FIRE_LOOP)
		return fire
	return _shoot_ready(ship, c, seconds)


## CrewAnimation::GetFiringFrame for the other races: the shoot strip is not animated; frame 0 when the aim is
## exactly in line, else 1 / 2 by the side of the aim relative to the facing (SetDirection sub_direction).
static func firing_frame(from: Vector2, to: Vector2) -> int:
	var dx := to.x - from.x
	var dy := to.y - from.y
	if absf(dy) < absf(dx):  # facing right / left; sub-direction up -> 2, down -> 1
		if dy == 0.0:
			return 0
		return 2 if dy < 0.0 else 1
	if dx == 0.0:
		return 0
	if dy < 0.0:  # facing up: right -> 1, left -> 2
		return 1 if dx > 0.0 else 2
	return 2 if dx > 0.0 else 1  # facing down: right -> 2, left -> 1


## Enemy crystal AI (CrewMember::OnLoop combat step, rules/races.md): every frame with a crew target, an enemy-owned
## crystal whose power is ready, above 50 % health and whose room is not already locked casts lockdown.
static func enemy_lockdown(ship: ShipState, c: CrewMember) -> bool:
	if c.player_owned or not c.power_ready() or c.hp <= c.max_hp * 0.5 or LockdownRule.room_locked(ship, c.room):
		return false
	return c.activate_power(ship)


## Looping shoot timer (goal 1.0-1.3 s, re-rolled each shot). Only runs while shooting.
static func _shoot_ready(ship: ShipState, c: CrewMember, seconds: float) -> bool:
	c.shoot_timer += seconds
	if c.shoot_timer <= c.shoot_goal:
		return false
	c.shoot_timer = 0.0
	c.shoot_goal = ship.rng.randf_range(CrewMember.SHOOT_MIN, CrewMember.SHOOT_MAX)
	return true


## Applies a hit (CrewMember::ApplyDamage). A kill gives the attacker +1 combat skill (player crew)
## and clears its target; hook `crew_killed` (ACH_ROCK_FIRE / ACH_BOARDING_DRONE, AchievementTracker) is told
## before the killer's targetsDestroyed counts the kill (CrewMember::OnLoop).
static func _hit(ship: ShipState, c: CrewMember, t: CrewMember, dmg: float) -> bool:
	var was_alive := t.is_alive()
	var old_hp := t.hp
	t.hp = clampf(t.hp - dmg, 0.0, t.max_hp)
	t.check_low_health_sound(old_hp)
	if was_alive and not t.is_alive():
		if c.player_owned and not c.is_drone():
			c.add_skill("combat")
			c.crew_stats[2] += 1  # crew record "kills"
		Hooks.emit(&"crew_killed", ship, c, t)
		c.targets_destroyed += 1
		c.target = null
		return true
	return false


static func _face(c: CrewMember, p: Vector2) -> void:
	var v := p - c.pos
	if v.length() < 0.5:
		return
	if absf(v.y) < absf(v.x):  # CrewAnimation::SetDirection: vertical on exact diagonals
		c.facing = "right" if v.x > 0 else "left"
	else:
		c.facing = "down" if v.y > 0 else "up"


## Ion boarding drone, once per frame after its task step (IonDroneAnimation::OnUpdateEffects / UpdateShooting,
## then IonDrone::GetRoomDamage -> FireShot from ShipManager::UpdateCrewmembers):
## - status 7 = alive, not stunned / frozen, and either standing in a room it sabotages (Sabotaging: an intact
##   system, task SABOTAGE) or blocked by a sealed door (bDoorTarget).
## - Idle in status 7: the 6 s shoot timer runs; when it fires the charge starts (boarder_ion_ion, 1 s, sound
##   ionBoarderCharge, ionEffect 0). The timer is frozen while charging and outside status 7.
## - Charging: the animation runs 1 s, then holds its last frame while ionEffect grows 1/s (the glow fades in).
## - FireShot at ionEffect >= 1.25: sound ionHit1, timer restarted, charge stopped, explosion_big1_ion (0.5 s)
##   centred on the drone; the room gets Damage{ion 3, stun 6} (owner = the drone's side, no friendly fire) and
##   becomes its BlockRoom (the AI moves it on).
## - Door target: the boarder_ion_shoot_<dir> strip loops (twice the speed); entering its frame 0 sets
##   fDamageDone 3..7 once per pass (one door hit, consumed next frame by consume_damage). The charge is held
##   restarted at frame 0 with ionEffect 0 meanwhile (no sound), so it resumes from scratch afterwards.
static func update_ion_drone(ship: ShipState, c: CrewMember, seconds: float) -> void:
	if not c.is_alive():
		c.ion_explosion = -1.0
		return
	if c.ion_explosion >= 0.0:  # OnUpdateEffects
		c.ion_explosion += seconds
		if c.ion_explosion >= ION_EXPLOSION_TIME:
			c.ion_explosion = -1.0
	if ion_status7(ship, c):
		_ion_update_shooting(ship, c, seconds, c.blocking_door >= 0)
	if c.ion_charge >= 0.0 and c.ion_effect >= ION_EFFECT_FIRE:
		_ion_fire(ship, c)


## CrewAnimation status 7 for the ion boarding drone (OnUpdate `fighting` = bFighting (door) || Sabotaging, not
## moving, not stunned / frozen).
static func ion_status7(ship: ShipState, c: CrewMember) -> bool:
	return (c.is_alive() and c.stun <= 0.0 and not c.frozen and not ship.teleporting.has(c)
			and (c.blocking_door >= 0 or (c.task == CrewMember.Task.SABOTAGE and not c.is_walking())))


## IonDroneAnimation::UpdateShooting (status 7 only).
static func _ion_update_shooting(ship: ShipState, c: CrewMember, seconds: float, door: bool) -> void:
	if c.ion_timer > ION_TIMER:  # TimerHelper::Done (looping: back to 0)
		c.ion_timer = 0.0
		c.ion_charge = 0.0  # Animation::Start(ionAnimation, reset)
		c.ion_effect = 0.0
		c.ion_charges += 1  # ionBoarderCharge
	if door:
		var d: Dictionary = ship.env.doors[c.blocking_door]
		c.aim = ship.graph.door_center(d) + DOOR_AIM
		_face(c, c.aim)
		c.ion_door_t += seconds  # Animation::Update in UpdateShooting
		if int(fmod(c.ion_door_t, ION_DOOR_LOOP) / ION_DOOR_LOOP * 2.0) == 0:
			if not c.ion_damaged_door:
				c.ion_damaged_door = true
				c.damage_done = lerpf(CrewMember.HIT_MIN, CrewMember.HIT_MAX, ship.rng.randf())
		else:
			c.ion_damaged_door = false
		c.ion_door_t = fmod(c.ion_door_t + seconds * (ION_DOOR_SPEED - 1.0), ION_DOOR_LOOP)  # + OnUpdate's Update
		c.ion_effect = 0.0
		c.ion_charge = 0.0
		return
	if c.ion_charge < 0.0:
		c.ion_timer += seconds  # TimerHelper::Update: only while not charging
		return
	c.ion_charge += seconds
	if c.ion_charge > ION_CHARGE_TIME:  # Animation::Done: holds the last frame
		c.ion_effect += ION_EFFECT_RATE * seconds


## IonDroneAnimation::FireShot + IonDrone::GetRoomDamage.
static func _ion_fire(ship: ShipState, c: CrewMember) -> void:
	c.ion_discharges += 1  # ionHit1
	c.ion_timer = 0.0  # TimerHelper::Start
	c.ion_charge = -1.0  # ionAnimation stopped
	c.ion_explosion = 0.0
	c.ion_explosion_pos = Vector2(floorf(c.pos.x - ION_EXPLOSION_HALF), floorf(c.pos.y - ION_EXPLOSION_HALF))
	c.last_ion_room = c.room
	var d := Damage.new()
	d.ion = ION_DAMAGE
	d.stun = ION_STUN
	d.owner = 0 if c.player_owned else 1
	d.friendly_fire = false
	ship.apply_damage(c.room, d, ship.rng)
