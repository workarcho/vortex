class_name CrewMember
extends RefCounted
## One crew member: health, position, movement along door waypoints, current task, skills and
## hand-to-hand combat state (rules/crew.md, rules/crew_combat.md). Holds no reference to its ship
## (avoids a reference cycle); the ship is passed in.
##
## Everyone physically aboard a ship is in that ship's `crew` list. `player_owned` says which side the
## crew member belongs to; aboard the other side's ship it is an intruder (CrewMember::GetIntruder).

enum State { IDLE, WALKING }
enum Task { NONE, MAN, REPAIR_SYSTEM, FIRE, BREACH, SABOTAGE }

const BASE_SPEED := 80.0  # px/s (5 px per frame-factor x 16)
const REPAIR_RATE := 8.0  # health/progress per second at speed 1.0
const SNAP := 0.5  # px, position equality tolerance
const DOOR_FAKE_OPEN := 1.0  # s a closed door stays visually open while crew cross it

## Skill ids (same order as EvasionRule.Skill).
const SKILLS := ["pilot", "engines", "shields", "weapons", "repair", "combat"]
## Progress needed for level 3 (level 2 at half). repair/combat from the exe; the rest from xftl.
const SKILL_CAPS := {"pilot": 30, "engines": 30, "shields": 110, "weapons": 130, "repair": 36, "combat": 16}
## Human caps (CrewMember::CrewMember, species "human"; rules/races.md "Skills").
const HUMAN_SKILL_CAPS := {"pilot": 26, "engines": 26, "shields": 100, "weapons": 116, "repair": 32, "combat": 14}
const REPAIR_SKILL_MOD := [1.0, 1.1, 1.2]

const RACE_SPEED := {"mantis": 1.2, "rock": 0.5, "crystal": 0.8, "anaerobic": 0.85}
const RACE_REPAIR := {"engi": 2.0, "mantis": 0.5}
const RACE_FIRE := {"rock": 2.0, "crystal": 1.0}  # others 1.2
const DEFAULT_FIRE_MULT := 1.2
## Max health (CrewMember::GetMaxHealth and race overrides; others 100).
const RACE_HP := {"rock": 150.0, "crystal": 125.0, "energy": 70.0, "ghost": 50.0}
## Combat damage multiplier (GetDamageMultiplier; others 1.0).
const RACE_DAMAGE := {"mantis": 1.5, "engi": 0.5}
## Suffocation damage multiplier (GetSuffocationModifier; others 1.0).
const RACE_SUFFOCATION := {"crystal": 0.5}
const COMBAT_SKILL_MOD := [1.0, 1.1, 1.2]

## Attack timing (CrewAnimation timers, seconds) and damage per hit (rules/crew_combat.md).
const SHOOT_MIN := 1.0
const SHOOT_MAX := 1.3
const PUNCH_MIN := 0.5  # damage lands after this; the punch animation lasts twice as long
const PUNCH_MAX := 0.65
const HIT_MIN := 3.0
const HIT_MAX := 7.0
const DEATH_ANIM := 0.75  # s, <race>_death_right animation (visual only)
const DEATH_FADE := 1.0  # s, last death frame fades out after the animation (Animation::SetFadeOut(1.0))
## CrewAnimation::GetDeathSound overrides; other races (human, slug) use death1-2 (male) / femaleDeath1-3.
const DEATH_SOUNDS := {"engi": "engiDeath", "energy": "energyDeath", "mantis": "mantisDeath",
	"rock": "rockDeath", "crystal": "crystalDeath", "anaerobic": "shrikeDeath"}
## Zoltan death explosion (EnergyAlien::GetRoomDamage -> DamageCrew (0 + 1) x 15) to other-side crew in the room.
const ZOLTAN_BLAST := 15.0
## Crystal lockdown cooldown (CrystalAlien ctor powerCooldown max; charge +1 /s).
const LOCKDOWN_COOLDOWN := 50.0
const ENEMY_LOCKDOWN_START := 10.0
## CrewAnimation::GetShootingSound overrides (prefix + 1..3); others use crewLaser.
const SHOOT_SOUNDS := {"mantis": "mantisSpit", "rock": "rockThrow"}

var race := "human"
var hp := 100.0
var max_hp := 100.0
var room := -1  # room the crew member is physically in
var target_room := -1  # room it is assigned to (where its slot is)
var slot := -1  # reserved slot in target_room
var pos := Vector2.ZERO  # local ship coordinates (centre of the sprite)
var path: Array = []  # waypoints [{pos: Vector2, door: int}] (door >= 0: this segment crosses that door)
var state := State.IDLE
var task := Task.NONE
## Fire tile it is putting out (CrewMember::currentRepair): kept until that tile is out, then the first burning tile
## of the room in grid order (ShipManager::GetFires -> Spreader<Fire>::GetSquares, x-major). -1 = none.
var fire_tile := -1
var stun := 0.0  # s
var selected := false
var hovered := false  # selectionState 2 ("potential": under the pointer / in the drag box; rules/crew_controls.md)
var saved_room := -1  # saved station (ShipManager::SaveCrewPositions); -1 = none
var saved_slot := -1
var skills := {}  # skill id -> progress
var skill_up := {}  # skill id -> s into its 1.0 s skill-gained tracker (crew list arrow, CrewList)
var level_up := -1.0  # s into the 2.0 s levelUp tracker (-1 = not running); drawn by ShipView over the crew
var last_level_up := ""  # lastLevelUp: the skill whose level went up last (levelUp icon)
var facing := "down"  # "down", "up", "left", "right"
## CrewAI task (where to go, rules/crew_ai.md): {id: CrewAI enum, room, sys: system id or ""}.
## `task` above is what the crew is actually doing in its current room.
var ai_task := {"id": 4, "room": -1, "sys": ""}
var manning_id := ""  # iManningId: system of the last room it stood in while able to man ("home")
var _crossing_door := -1

# Side and combat (rules/crew_combat.md)
var player_owned := true  # iShipId == 0
var target: CrewMember = null  # crewTarget when it is a crew member
var blocking_door := -1  # door index it is stopped at and attacking (blockingDoor), or -1
var fighting := false  # bFighting: has a target (crew or door)
var shared_spot := false  # bSharedSpot: target stands on the same tile -> punch instead of shoot
var shoot_timer := 0.0  # CrewAnimation.shootTimer (loops; only advances while shooting)
var shoot_goal := 0.0
var punch_time := -1.0  # time into the current punch animation (-1 = not punching)
var punch_goal := 0.0
var punch_hit := false  # damage of this punch already dealt
# Crew lasers in flight (CrewAnimation::shots, CrewLaser projectiles; rules/crew_combat.md "Crew lasers"):
# {pos, to, heading (deg), death (-1 flying, else s into the hit animation)}.
var shots: Array = []
var damage_done := 0.0  # CrewAnimation::fDamageDone: set when a shot lands / a punch connects, consumed next frame
var aim := Vector2.ZERO  # currentTarget: the point it faces and shoots at (firing frame, shot aim)
var shoot_anim := 0.0  # rock / mantis: shoot animation loop time (their shots follow its frames)
var shot_frame_done := false  # rock / mantis: the shot of the current pass through frame 3 is fired
var shots_fired := 0  # visual/sound only: shots spawned so far (a rise = a new shot sound)
var medbay_rate := 0.0  # fMedbay converted to HP/s (negative while a hacked medbay hurts)
var dead_time := 0.0  # s since death (death animation)
var death_sound_done := false  # visual/sound only: death sound already played
var last_shots_fired := 0  # visual/sound only: shots_fired seen last frame
# Crew drones (rules/drones.md §9-10): "" = a normal crew member; else "repair" (RepairDrone), "battle"
# (BattleDrone, anti-personnel), "boarder" (BoarderDrone) or "boarder_ion" (IonDrone). `race` holds the
# animation set (repair / battle / boarder_ion).
var drone_kind := ""
var drone: RefCounted = null  # the Drone of the drone system that owns this crew drone
var frozen := false  # crew drone whose drone is unpowered: frozen in place, no task (CrewDrone::SetPowered)
# Ion boarding drone (IonDroneAnimation, rules/drones.md §9 "Ion boarding drone animation"; CrewCombat.update_ion_drone):
var ion_timer := 0.0  # shootTimer currTime (6 s goal, looping); runs only while idle in status 7
var ion_charge := -1.0  # ionAnimation (boarder_ion_ion, 1 s) time since its start; -1 = not running
var ion_effect := 0.0  # ionEffect: grows 1/s once the charge animation is done; discharge at 1.25 (glow alpha)
var ion_explosion := -1.0  # ionExplosion (explosion_big1_ion, 0.5 s) time; -1 = not running
var ion_explosion_pos := Vector2.ZERO  # its top-left (lastPosition - 32 at the discharge)
var ion_door_t := 0.0  # door attack: boarder_ion_shoot_<dir> loop time (1.5 s loop, advanced twice per frame)
var ion_damaged_door := false  # damagedDoor: the hit of the current door-animation pass is done
var ion_charges := 0  # visual/sound only: charges started (ionBoarderCharge)
var ion_discharges := 0  # visual/sound only: discharges (ionHit1)
var last_ion_charges := 0  # visual/sound only: ion_charges / ion_discharges seen last frame
var last_ion_discharges := 0
var last_ion_room := -1  # IonDrone::lastRoom (BlockRoom): the room of its last discharge
# Mind control (rules/mind_control.md): bMindControlled flips the side (GetIntruder); boosts per level.
var mind_controlled := false
var health_boost := 0.0  # SetHealthBoost: HP added to both hp and max_hp while controlled
var mind_damage_boost := 1.0  # fMindDamageBoost (melee damage multiplier)
var resisted := 0.0  # s left showing "resisted" (bResisted, a telepathic crew shrugged it off; visual)
# Identity and look (rules/crew_appearance.md): long / short name, gender (from the name pool, every race), colour
# choice per colorList layer (-1 = not rolled yet). Set by CrewIdentity; kept for the whole run.
var name_long := ""  # crewNameLong (info box, used-name list)
var name_short := ""  # crewName (crew list, equipment boxes; ShortenName of the long name)
var male := true
var color_choices: Array = []
# Races (rules/races.md): zoltan death blast done for this life; crystal power cooldown (powerCooldown).
var blast_done := false
var power_charge := 0.0
var power_max := 0.0  # 0 = no special power; INF = an enemy crystal that never uses it
## ScoreKeeper SCrewStats (rules/save_and_profile.md §2.4): [evasions, repairs, kills, jumps, skill masteries] of
## this crew member, for the profile's crew records.
var crew_stats := [0, 0, 0, 0, 0]
## BoardingGoal targetsDestroyed: crew killed (CrewMember::OnLoop) + systems sabotaged to 0 (UpdateRepair) by this
## crew member; read by ACH_BOARDING_DRONE (AchievementTracker).
var targets_destroyed := 0
## BoardingGoal fHealthLimit: as an intruder, the HP fraction at or below which the enemy AI pulls it back
## (CrewAI::ReadyForEvac; ShipAI.evac_room). CrewMember constructor default 0.25; CrewAI::OnInit sets the
## ship's BoardingGoal(boardingAI) (1: 0.25, 2: -100) on its crew; event boarders get BoardingGoal(2).
## Not saved (vanilla re-creates crew with the default on load; ShipSave.CREW_SKIP).
var boarding_health_limit := 0.25


func _init(race_id := "human", owned_by_player := true) -> void:
	race = race_id
	player_owned = owned_by_player
	max_hp = RACE_HP.get(race, 100.0)
	hp = max_hp
	for s in SKILLS:
		skills[s] = 0
	shoot_goal = randf_range(SHOOT_MIN, SHOOT_MAX)
	if race == "crystal":
		# CrystalAlien ctor: player (0, 50); enemy starts at 10 and half of them can never use it.
		power_max = LOCKDOWN_COOLDOWN
		if not player_owned:
			power_charge = ENEMY_LOCKDOWN_START
			if randf() < 0.5:
				power_max = INF


## Has a special power (crystal lockdown; HasSpecialPower).
func has_power() -> bool:
	return power_max > 0.0 and not is_drone()


## PowerReady: charge reached the (finite) max.
func power_ready() -> bool:
	return has_power() and power_max < INF and power_charge >= power_max


## CrystalAlien::OnLoop: +1 /s (speed factor), clamped to the max.
func tick_power(seconds: float) -> void:
	if has_power() and power_max < INF:
		power_charge = minf(power_charge + seconds, power_max)


const LEVEL_UP_TIME := 2.0  # levelUp AnimationTracker length (CrewMember ctor)


## CrewMember::OnLoop: the levelUp tracker advances on game time and stops when done.
func tick_level_up(seconds: float) -> void:
	if level_up >= 0.0:
		level_up += seconds
		if level_up >= LEVEL_UP_TIME:
			level_up = -1.0


## ResetPower: full charge.
func reset_power() -> void:
	if has_power() and power_max < INF:
		power_charge = power_max


## Cooldown fraction 0..1 (crew box bar).
func power_fraction() -> float:
	if not has_power() or power_max >= INF:
		return 0.0
	return clampf(power_charge / power_max, 0.0, 1.0)


## CrystalAlien::ActivatePower on the ship it stands on: lockdown of its room. Returns true if cast.
func activate_power(ship: ShipState) -> bool:
	if not power_ready() or not is_alive() or room < 0:
		return false
	power_charge = 0.0
	LockdownRule.lockdown_room(ship, room, pos)
	FtlData.play("lockdown%d" % (randi() % 2 + 1))
	return true


## CrewMember::GetIntruder: on a ship that is not its own, inverted while mind controlled (a controlled
## crew is an intruder on its own ship and a friend aboard the controlling side's ship).
func is_intruder(ship: ShipState) -> bool:
	return (player_owned != ship.is_player) != mind_controlled


## IsTelepathic (only SlugAlien overrides it): immune to mind control.
func is_telepathic() -> bool:
	return race == "slug"


## CrewMember::SetHealthBoost: a raised boost adds to both current and max HP; a lowered one drops the
## max and clamps the current HP.
func set_health_boost(b: float) -> void:
	if b > health_boost:
		max_hp += b - health_boost
		hp += b - health_boost
	elif b < health_boost:
		max_hp -= health_boost - b
		hp = minf(hp, max_hp)
	health_boost = b


## Crew drone (CrewMember::IsDrone).
func is_drone() -> bool:
	return drone_kind != ""


## CrewMember::DirectModifyHealth (0x0046eb20) plays `lowCrewHealth` when the integer health (truncated) goes from
## above 25 to 25 or less in one change: (int)new < 26 and (int)old > 25. Absolute HP, not a fraction of the
## maximum. Only crew owned by the player (iShipId == 0, wherever they stand; mind control does not change it),
## never crew drones (IsDrone). Every crossing plays it again (no timer); Kill / SetHealthBoost / cloning set the
## health directly and never play it. Call after any health change that vanilla routes through DirectModifyHealth
## (ApplyDamage, fire / suffocation, medbay, ship weapon damage), with the health before the change.
const LOW_HEALTH_SOUND_BELOW := 26


func check_low_health_sound(old_hp: float) -> void:
	if int(hp) < LOW_HEALTH_SOUND_BELOW and int(old_hp) >= LOW_HEALTH_SOUND_BELOW and player_owned \
			and not is_drone():
		FtlData.play("lowCrewHealth")


## Max health of a crew drone (RepairDrone 25, BattleDrone / BoarderDrone 150, IonDrone 125).
const DRONE_HP := {"repair": 25.0, "battle": 150.0, "boarder": 150.0, "boarder_ion": 125.0}
## Damage multiplier of fighting drones (BattleDrone / BoarderDrone 1.2).
const DRONE_DAMAGE := {"battle": 1.2, "boarder": 1.2}


## Turns this crew member into a crew drone of the given kind (health, animations).
func make_drone(kind: String) -> void:
	drone_kind = kind
	race = "battle" if kind == "boarder" else kind
	max_hp = DRONE_HP.get(kind, 100.0)
	hp = max_hp
	reset_ion_anim()


## IonDroneAnimation::Restart (deploy): shoot timer restarted, charge stopped, ionEffect 0.
func reset_ion_anim() -> void:
	ion_timer = 0.0
	ion_charge = -1.0
	ion_effect = 0.0
	ion_door_t = 0.0
	ion_damaged_door = false


## CrewMember::BlockRoom: -1 for crew; the ion boarding drone blocks the room of its last discharge
## (IonDrone::BlockRoom = lastRoom), so the intruder AI moves it on to another system.
func block_room() -> int:
	return last_ion_room if drone_kind == "boarder_ion" else -1
	set_meta("no_clone", true)  # drones are never cloned (no permanent death, rebuilt by the drone system)


## CanFight: battle and boarding drones fight; repair and ion drones do not.
func can_fight() -> bool:
	return drone_kind in ["", "battle", "boarder"]


## CanRepair: crew, and repair drones only while powered (handled by `frozen`).
func can_repair() -> bool:
	return drone_kind in ["", "repair"]


## CanSabotage: crew, boarding and ion drones.
func can_sabotage() -> bool:
	return drone_kind in ["", "boarder", "boarder_ion"]


## Race properties (vtable overrides, rules/crew_combat.md "Races"). Crew drones neither burn nor suffocate.
func can_burn() -> bool:
	return race != "rock" and not is_drone()


func can_suffocate() -> bool:
	return race != "anaerobic" and not is_drone()


func suffocation_mult() -> float:
	return RACE_SUFFOCATION.get(race, 1.0)


func damage_mult() -> float:
	if is_drone():
		return DRONE_DAMAGE.get(drone_kind, 1.0)
	return RACE_DAMAGE.get(race, 1.0)


## Damage of one hit (punch or crew laser): 3..7 x race x combat skill.
func roll_hit(rng_value: float) -> float:
	return lerpf(HIT_MIN, HIT_MAX, rng_value) * hit_multiplier()


## Multiplier applied to fDamageDone when it is dealt (CrewMember::OnLoop): race x mind boost x combat skill.
func hit_multiplier() -> float:
	return damage_mult() * mind_damage_boost * COMBAT_SKILL_MOD[skill_level("combat") - 1]


func is_alive() -> bool:
	return hp > 0.0


## Death sound (CrewAnimation::GetDeathSound): race overrides, else by gender (human, slug, ...):
## death1-2 male / femaleDeath1-3 female.
func death_sound() -> String:
	if DEATH_SOUNDS.has(race):
		return DEATH_SOUNDS[race]
	return "death%d" % (randi() % 2 + 1) if male else "femaleDeath%d" % (randi() % 3 + 1)


## CrewMember::SetName: the long name always; the short one re-derived (ShortenName) unless `force`.
func set_name(full: String, force := false) -> void:
	name_long = full
	name_short = full if force else CrewIdentity.shorten(full)


## GetName for labels: the short name, or the race title when unnamed (drones, old saves).
func display_name() -> String:
	if name_short != "":
		return name_short
	var t := FtlData.tr_id("crew_%s_title" % race)
	return t if t != "crew_%s_title" % race else race.capitalize()


## Shot sound (CrewAnimation::GetShootingSound): random variant 1..3. (The ion boarding drone fires no crew
## lasers: its ionBoarderCharge / ionHit1 sounds follow ion_charges / ion_discharges.)
func shooting_sound() -> String:
	return "%s%d" % [SHOOT_SOUNDS.get(race, "crewLaser"), randi() % 3 + 1]


func is_walking() -> bool:
	return state == State.WALKING


## Repairing, sabotaging, fighting or moving (CrewMember::IsBusy).
func is_busy() -> bool:
	return is_walking() or fighting or task in [Task.REPAIR_SYSTEM, Task.FIRE, Task.BREACH, Task.SABOTAGE]


# ------------------------------------------------------------ skills

## Progress cap of a skill for this crew member: humans have lower caps (CrewMember ctor), others the defaults.
func skill_cap(skill: String) -> int:
	if race == "human" and not is_drone():
		return HUMAN_SKILL_CAPS.get(skill, 1)
	return SKILL_CAPS.get(skill, 1)


## CrewMember ctor conversion of existing progress to new caps: at the old cap -> new cap; exactly at
## old cap / 2 -> new cap / 2; otherwise int(progress x 0.9).
static func convert_progress(p: int, old_cap: int, new_cap: int) -> int:
	if p >= old_cap:
		return new_cap
	if p * 2 == old_cap:
		return new_cap / 2
	return int(p * 0.9)


## 1 below cap/2, 2 at >= cap/2, 3 at cap.
func skill_level(skill: String) -> int:
	var cap: int = skill_cap(skill)
	var p: int = skills.get(skill, 0)
	if p >= cap:
		return 3
	if p * 2 >= cap:
		return 2
	return 1


func add_skill(skill: String) -> void:
	if skills.has(skill):
		var cap := skill_cap(skill)
		var old_level := skill_level(skill)
		if skills[skill] < cap:
			skill_up[skill] = 0.0  # CrewMember::IncreaseSkill starts skillUp[0][skill] (not at max)
			if skills[skill] + 1 >= cap:
				crew_stats[4] += 1  # CrewMember::MasterSkill: a skill mastered (crew record "masteries")
		skills[skill] = mini(skills[skill] + 1, cap)
		# CrewMember::IncreaseSkill (0x0046e3f0; player crew, not drones): the level (1 below cap/2, 2 from cap/2,
		# 3 at cap) went up -> levelUp tracker (2.0 s) restarted, `levelup` sound, lastLevelUp = skill.
		if skill_level(skill) > old_level and player_owned and not is_drone():
			level_up = 0.0
			last_level_up = skill
			FtlData.play("levelup")


# ------------------------------------------------------------ rates

func move_speed() -> float:
	if is_drone():
		return BASE_SPEED * 0.5  # crew drones move x0.5 (rules/crew.md)
	return BASE_SPEED * RACE_SPEED.get(race, 1.0)


## Repair speed multiplier (skill x race), x fire multiplier while the room burns.
func repair_speed(room_on_fire: bool) -> float:
	var sp: float = REPAIR_SKILL_MOD[skill_level("repair") - 1] * RACE_REPAIR.get(race, 1.0)
	if drone_kind == "repair":
		sp = 2.0  # RepairDrone::GetRepairSpeed
	if room_on_fire:
		sp *= RACE_FIRE.get(race, DEFAULT_FIRE_MULT)
	return sp


# ------------------------------------------------------------ movement

## Places the crew member standing on a slot.
func place(ship: ShipState, room_id: int, slot_id: int) -> void:
	room = room_id
	target_room = room_id
	slot = slot_id
	pos = ship.graph.slot_position(room_id, slot_id)
	path.clear()
	state = State.IDLE


## Standing still on its own slot.
func is_on_slot(ship: ShipState) -> bool:
	return state == State.IDLE and slot >= 0 and \
		pos.distance_to(ship.graph.slot_position(target_room, slot)) <= SNAP


## Order to walk into a room (CrewMember::MoveToRoom, not forced). Returns false if ignored:
## dead, stunned on its slot, already assigned there, room full or unreachable.
func move_to_room(ship: ShipState, room_id: int, force := false) -> bool:
	if not is_alive() or room_id < 0 or room_id == target_room or frozen:
		return false
	if stun > 0.0 and is_on_slot(ship) and not force:
		return false
	var new_slot := ship.graph.find_slot(room_id, self)
	if new_slot < 0:
		return false
	return walk_to_slot(ship, room_id, new_slot)


## Walks to a given slot of a room (also inside the current room). Used by move_to_room and by
## "return to stations" (CrewMember::RestorePosition). Returns false if unreachable.
func walk_to_slot(ship: ShipState, room_id: int, new_slot: int) -> bool:
	if not is_alive() or room_id < 0 or new_slot < 0 or frozen:
		return false
	# Mid-crossing: finish going through the door first.
	var start_pos := pos
	var start_room := room
	var keep := []
	if is_walking() and not path.is_empty() and path[0].door >= 0:
		keep.append(path[0])
		start_pos = path[0].pos
		var r := ship.room_at(start_pos)
		start_room = r if r >= 0 else room
	var doors: Variant = ship.graph.find_path(start_pos, start_room, room_id, self)
	if doors == null:
		return false
	var wps := keep
	var cur_room := start_room
	for di in doors:
		var d: Dictionary = ship.env.doors[di]
		var cross: Array = ship.graph.crossing(d, cur_room)
		wps.append({"pos": cross[0], "door": -1})  # entry tile (aligned with the door)
		wps.append({"pos": cross[1], "door": di})  # 35 px straight through
		cur_room = d.right if d.left == cur_room else d.left
	wps.append({"pos": ship.graph.slot_position(room_id, new_slot), "door": -1})
	path = wps
	blocking_door = -1
	target_room = room_id
	slot = new_slot  # the old slot is freed immediately
	state = State.WALKING
	task = Task.NONE
	return true


## Straight-line motion along the waypoints.
func update_movement(ship: ShipState, seconds: float) -> void:
	if not is_walking():
		return
	var remaining := move_speed() * seconds
	while remaining > 0.0 and not path.is_empty():
		var wp: Dictionary = path[0]
		if wp.door >= 0 and _crossing_door != wp.door and ship.graph.is_sealed(ship.env.doors[wp.door], self):
			# Sealed for us: stop at the entry tile and attack the door (CrewMember::GetNewGoal).
			blocking_door = wp.door
			break
		if wp.door >= 0 and blocking_door == wp.door:
			blocking_door = -1  # the door gave way
		if wp.door >= 0 and _crossing_door != wp.door:
			_crossing_door = wp.door
			var dd: Dictionary = ship.env.doors[wp.door]
			if not dd.open:
				dd.crew_pass = DOOR_FAKE_OPEN  # fake open (visual only)
		var to: Vector2 = wp.pos - pos
		var dist := to.length()
		if dist > SNAP:
			_face(to)
		if dist <= remaining or dist <= SNAP:
			pos = wp.pos
			remaining -= dist
			path.pop_front()
			if wp.door >= 0:
				ship.env.doors[wp.door].crew_pass = 0.0  # fake close at the next waypoint
				_crossing_door = -1
		else:
			pos += to / dist * remaining
			remaining = 0.0
	var r := ship.room_at(pos)
	if r >= 0:
		room = r
	if path.is_empty():
		state = State.IDLE
		room = target_room


func _face(v: Vector2) -> void:
	if absf(v.x) >= absf(v.y):
		facing = "right" if v.x > 0 else "left"
	else:
		facing = "down" if v.y > 0 else "up"


# ------------------------------------------------------------ tasks

## Idle crew on its slot picks fire > breach > the room's system (CrewAI::SelectRepair)
## and works from its slot. Repairers stack (each applies its own amount).
func update_task(ship: ShipState, seconds: float) -> void:
	var was_fire := task == Task.FIRE  # still on the same fire job as last frame (same room, on its slot)
	if not is_alive() or stun > 0.0 or not is_on_slot(ship) or fighting or frozen:
		task = Task.NONE
		return
	if is_intruder(ship):
		# ShipManager::UpdateCrewmembers: aboard a ship that is not hostile (dead crew, accepted surrender,
		# peaceful event ship) every intruder is StopRepairing'd each frame -> no sabotage (rules/teleporter.md
		# "Boarders on a ship that stops being hostile").
		if can_sabotage() and ship.hostile:
			_update_sabotage(ship, seconds)
		else:
			task = Task.NONE
		return
	if not can_repair():
		task = Task.NONE
		return
	var room_fires: Dictionary = ship.fires.get(room, {})
	if not room_fires.is_empty():
		task = Task.FIRE
		if not was_fire or not room_fires.has(fire_tile):
			fire_tile = _first_fire(ship, room_fires)
		var tile := fire_tile
		var f: Dictionary = room_fires[tile]
		f.health -= REPAIR_RATE * repair_speed(true) * seconds
		if f.health <= 0.0:
			ship.extinguish(room, tile)
		return
	var room_breaches: Dictionary = ship.breaches.get(room, {})
	if not room_breaches.is_empty():
		task = Task.BREACH
		var tile: int = room_breaches.keys().min()
		var b: Dictionary = room_breaches[tile]
		b.health -= REPAIR_RATE * repair_speed(false) * seconds
		if b.health <= 0.0:
			ship.seal_breach(room, tile)
		return
	var s := ship.system_in_room(room)
	if s and s.damage > 0:
		task = Task.REPAIR_SYSTEM
		# x0.5 while the system is under a hacking attack (bUnderAttack; rules/crew.md, hacking.md).
		if s.partial_repair(REPAIR_RATE * repair_speed(false) * seconds * (0.5 if s.under_attack else 1.0)):
			ship.repair_system(s.key, 1)
			if ship.is_player and not is_drone():
				add_skill("repair")
				crew_stats[1] += 1  # crew record "repairs" (one per repaired bar)
		return
	if s and ship.graph.console_slot(room) == slot and not is_drone():
		task = Task.MAN
		var dir := ship.graph.console_dir(room)
		if dir != "":
			facing = dir
	else:
		task = Task.NONE


## First burning tile of the room in the exe's grid order (column by column: x, then y).
func _first_fire(ship: ShipState, room_fires: Dictionary) -> int:
	var best := -1
	var best_g := Vector2i.ZERO
	for idx in room_fires:
		var g := ship.env.tile_global(room, idx)
		if best < 0 or g.x < best_g.x or (g.x == best_g.x and g.y < best_g.y):
			best = idx
			best_g = g
	return best


## Intruders damage the room's system instead of repairing (CrewAI::SelectRepair intruder branch +
## ShipSystem::DamageOverTime): 8 progress/s per saboteur (no skill or race term), one bar per 100,
## until the system is completely destroyed. +1 combat skill per bar (player crew only).
## Sabotage shots (CrewMember::UpdateRepair): a saboteur is in CrewAnimation status 7 (OnUpdate `fighting` =
## bFighting || Sabotaging), so it shoots crew lasers at the room centre (SelectSabotageTarget) on the normal
## shoot timer, and a landed laser sets fDamageDone like any other. Next frame UpdateRepair takes that value
## (fDamageDone = 0; CrewCombat.update_attack) and only re-aims at the room centre: sabotage shots never hurt
## anyone. (A value still pending when the crew gets a target is dealt to it by the OnLoop combat step first.)
## The ion boarding drone (IonDrone::UpdateRepair is empty) breaks no bars: it only stands there in status 7
## (its ion charge, CrewCombat.update_ion_drone).
func _update_sabotage(ship: ShipState, seconds: float) -> void:
	var s := ship.system_in_room(room)
	if s == null or s.damage >= s.get_level():
		task = Task.NONE
		return
	task = Task.SABOTAGE
	if drone_kind == "boarder_ion":
		return
	var centre := ship.room_rect(room).get_center()
	aim = centre
	CrewCombat._face(self, centre)
	CrewCombat.shoot(ship, self, centre, false, seconds)
	if s.damage_over_time(REPAIR_RATE * seconds):  # fDamageOverTime, shared with fire
		ship.damage_system_over_time(s)  # the last bar going costs the ship 1 hull (bExploded)
		if player_owned and not is_drone():
			add_skill("combat")
		if s.damage >= s.get_level():
			targets_destroyed += 1  # UpdateRepair: the system is CompletelyDestroyed
