class_name TeleporterRule
extends RefCounted
## Teleporter, system 9 (rules/teleporter.md): TeleportSystem::Charged/CanSend/CanReceive/
## InitiateTeleport, ShipManager::TeleportCrew, CrewMember::CanTeleport, Ship::GetAvailableRoom.
## The cooldown is the system lock counter (LockSystem(4/3/2) units of 5 s by effective power).
## The 0.5 + 0.5 s transit itself is run by Combat (it moves crew between the two ShipStates).

enum { NONE, SEND, RETRIEVE }

const LOCK_UNITS := {1: 4, 2: 3, 3: 2}  # effective power -> lock units (>= 4: no cooldown)
const MAX_CREW := 4  # TeleportCrew stops after 4
const ANIM_TIME := 0.5  # s, <race>_teleport (dematerialise, then the same strip reversed)


## Functioning: effective power > 0.
static func functioning(ship: ShipState) -> bool:
	var t := ship.sys("teleporter")
	return t != null and t.effective_power() > 0


## Charged = not locked (cooldown, ion, hacked) and Functioning.
static func charged(ship: ShipState) -> bool:
	var t := ship.sys("teleporter")
	return t != null and not t.is_locked() and not t.hacked and t.effective_power() > 0


## TeleportSystem::InitiateTeleport: LockSystem(n) with n from the effective power at this moment.
static func start_cooldown(ship: ShipState) -> void:
	var t := ship.sys("teleporter")
	if t:
		t.lock_system(LOCK_UNITS.get(t.effective_power(), 0))
	Hooks.emit(&"teleport_initiated", ship)  # AchievementTracker flag "teleported" (player)


## Cooldown in seconds for an effective power (20 / 15 / 10 s; 0 from 4 up).
static func cooldown_seconds(power: int) -> float:
	return LOCK_UNITS.get(power, 0) * SystemState.ION_SECONDS


## iPreparedCrew: distinct slots of the teleporter room held by own crew standing on them (at their
## final goal, not walking, not already teleporting).
static func prepared_crew(ship: ShipState) -> int:
	var t := ship.sys("teleporter")
	if t == null:
		return 0
	var slots := {}
	for c in ship.crew:
		if c.is_alive() and not c.is_intruder(ship) and c.target_room == t.room and c.is_on_slot(ship) \
				and not ship.teleporting.has(c):
			slots[c.slot] = true
	return slots.size()


## Living crew of one side aboard a ship.
static func crew_of_side(ship: ShipState, player_side: bool) -> Array:
	return ship.crew.filter(func(c): return c.is_alive() and c.player_owned == player_side and not c.is_drone())


## CanSend: charged, someone prepared, a hostile target without super shields (unless ZOLTAN_BYPASS).
static func can_send(ship: ShipState, target: ShipState) -> bool:
	if target == null or target.is_destroyed() or not target.hostile:
		return false
	if super_blocked(ship, target):
		return false
	return charged(ship) and prepared_crew(ship) > 0


## TeleportSystem::CanSend / SetArmed: the target's super shield blocks the player's teleporter (send and
## return) unless the sender has ZOLTAN_BYPASS. The enemy AI boards regardless (rules/teleporter.md).
static func super_blocked(ship: ShipState, target: ShipState) -> bool:
	return ship.is_player and target != null and target.super_shield > 0 and not AugmentRule.bypasses_super(ship)


## CanReceive(countHacked): charged (or hacked with a pulse but functioning, AI only) and, for the
## player, own crew aboard the target.
static func can_receive(ship: ShipState, target: ShipState, count_hacked := false) -> bool:
	if target == null or super_blocked(ship, target):
		return false
	var t := ship.sys("teleporter")
	var ok := charged(ship) or (count_hacked and t != null and t.hacked and functioning(ship))
	if not ok:
		return false
	return not ship.is_player or not crew_of_side(target, true).is_empty()


## CrewMember::CanTeleport aboard `here`: not dying, not already teleporting; a crew member walking
## through a room toward a slot in another room may only go if it is an intruder there.
static func can_teleport(here: ShipState, c: CrewMember) -> bool:
	if not c.is_alive() or here.teleporting.has(c) or c.is_drone():  # CrewDrone::CanTeleport: never
		return false
	if c.player_owned and c.mind_controlled:
		return false  # player crew under enemy mind control cannot teleport
	if not c.is_on_slot(here) and c.target_room != c.room:
		return c.is_intruder(here)
	return true


## ShipManager::TeleportCrew(room, intruders): crew-list order, in the room, intruders or not, that
## CanTeleport; at most 4.
static func pick_party(here: ShipState, room: int, intruders: bool) -> Array:
	var out := []
	for c in here.crew:
		if out.size() >= MAX_CREW:
			break
		if c.room == room and c.is_intruder(here) == intruders and can_teleport(here, c):
			out.append(c)
	return out


## Ship::GetAvailableRoom for crew arriving on `ship` (its own or the intruder slot set): the requested
## room if it has a free slot; else the first door-connected room (door order) that is not full; else the
## non-full room whose centre is closest to the requested room's centre. -1 if the ship is full.
static func available_room(ship: ShipState, c: CrewMember, room: int) -> int:
	if room >= 0 and ship.graph.find_slot(room, c) >= 0:
		return room
	if room >= 0:
		for d in ship.env.doors:
			if d.get("airlock", false):
				continue
			var other := -1
			if d.left == room:
				other = d.right
			elif d.right == room:
				other = d.left
			if other >= 0 and ship.graph.find_slot(other, c) >= 0:
				return other
	var centre := ship.room_rect(room).get_center() if room >= 0 else ship.rooms_bounds().get_center()
	var best := -1
	var best_d := INF
	for r in ship.layout.rooms:
		if ship.graph.find_slot(r.id, c) < 0:
			continue
		var dist := centre.distance_to(ship.room_rect(r.id).get_center())
		if dist < best_d:
			best_d = dist
			best = r.id
	return best


## CrewMember::SetRoom on arrival: placed on a slot of the available room, task reset to idle there.
## Returns false (and does nothing) if the ship has no free slot for it.
static func place_arrival(ship: ShipState, c: CrewMember, room: int) -> bool:
	var r := available_room(ship, c, room)
	if r < 0:
		return false
	c.place(ship, r, ship.graph.find_slot(r, c))
	reset_crew_state(c)
	c.ai_task = CrewAI.make_task(CrewAI.IDLE, r)
	ship.crew.append(c)
	ship.crew_changed()
	return true


## Clears movement, combat and work state (teleport departure / arrival, cloning).
static func reset_crew_state(c: CrewMember) -> void:
	c.path.clear()
	c.state = CrewMember.State.IDLE
	c.task = CrewMember.Task.NONE
	c.target = null
	c.fighting = false
	c.shared_spot = false
	c.blocking_door = -1
	c.medbay_rate = 0.0
	c.selected = false
