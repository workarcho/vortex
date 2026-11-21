class_name CrewAI
extends RefCounted
## Automatic crew behaviour of one ship (rules/crew_ai.md: CrewAI::OnLoop and helpers).
## Ticked every frame by Combat right after the ship's own simulation step.
##
## Tasks only decide WHERE crew go; the work itself (fire > breach > system in the current room) is
## done by CrewMember.update_task (CrewAI::SelectRepair, rules/crew.md) for every crew of every ship.
##
## Enemy ship (`ai_on`): full behaviour (task list, priorities, assignment, healing, breach sealing,
## airlocks, venting). Player ship: crew are never moved; only their task label is kept up to date.
##
## Boarders: CheckForProblems emits fight tasks (7) for rooms with intruders; intruders aboard (not
## player-controllable) are driven by update_intruders (CrewAI::UpdateIntruders, rules/crew_combat.md).
## Teleporter boarding: ShipAI sets the request (SetTeleportRequest); CheckForProblems emits board tasks
## (8) for the teleporter room; ReadyForTeleport = prepared crew >= request (rules/teleporter.md).
## Crew drones (rules/drones.md §10): never take crew tasks; moved by update_drones (CrewAI::UpdateDrones).
## Boarding drones are AI-driven intruders (update_intruders), also the player's.
## Mind control: a controlled crew is an intruder on its own ship (update_intruders drives it) and a
## non-controllable friend aboard the controlling side's ship (rules/mind_control.md). Not modelled:
## crystal lockdown.

enum { MAN, REPAIR, FIRE, BREACH, IDLE, DEAD, HEAL, FIGHT, BOARD }

const SAFE_O2 := 10.0  # % room oxygen: fire tasks / venting need at least this (0x837c1c)
const LOW_SHIP_O2 := 25  # ship oxygen % below which repairing oxygen gets priority 0
const HURT_ALWAYS := 0.25  # HP fraction: always go heal below this
const HURT_CALM := 0.99  # ... or below this while the ship is calm; healing ends at this
const DANGER_SUFFOCATE_HP := 0.25
const DANGER_BURN_HP := 0.20
const DANGER_FIRES := 4
const BOARD_MIN_HP := 0.5
const MAX_FIRE_CREW := 2

## The exe passes the desired-task INDEX to SafeBlowoutOxygen instead of the task's room (consistent
## at all three call sites in the decompile). false = the evident intended behaviour (vent the task's
## room); true reproduces the exe quirk. See "Implementation notes" in rules/crew_ai.md.
const VENT_USES_TASK_INDEX := false

## PrioritizeSystem base values (lower = more important).
const SYSTEM_BASE := {"shields": 0, "weapons": 1, "clonebay": 1, "artillery": 2, "medbay": 2,
	"oxygen": 3, "teleporter": 3, "engines": 4, "drones": 4, "pilot": 4, "cloaking": 5, "mind": 5,
	"hacking": 5, "sensors": 6, "battery": 6, "doors": 7}
const SYSTEM_BASE_DEFAULT := 8
## Manning task priority per system (others: 1000 = never taken). Hard swaps shields/engines.
const MAN_PRIORITY := {"pilot": 64, "shields": 65, "weapons": 66, "artillery": 66, "engines": 67,
	"oxygen": 68, "sensors": 69, "doors": 70, "cloaking": 70, "teleporter": 71, "medbay": 72}
const MAN_PRIORITY_HARD := {"shields": 67, "engines": 65}

var ship: ShipState
var ai_on := false  # bAIon = not the player ship
var hostile := true  # runs only while hostile (ShipAI.hostile for enemies)
var calm := true  # bCalmShip
var hurt_crew := false  # bHurtCrew
var medbay_requested := false  # bMedbayRequested
var multiracial := false  # bMultiracialCrew
var override_race := false  # bOverrideRace
var teleport_request := 0  # iTeleportRequest (SetTeleportRequest: capped at the teleporter room slots)
var urgent_teleport := false
var desired: Array = []  # desiredTaskList [{id, room, sys}]
var bonus: Array = []  # bonusTaskList (only for crew drones, not modelled)
var breached_rooms := {}  # room -> true, this frame

var _room_doors := {}  # room -> [door index] (static layout)
var _room_airlocks := {}  # room -> [door index]


func _init(s: ShipState) -> void:
	ship = s
	ai_on = not s.is_player
	for i in ship.env.doors.size():
		var d: Dictionary = ship.env.doors[i]
		for r in [d.left, d.right]:
			if r < 0:
				continue
			if not _room_doors.has(r):
				_room_doors[r] = []
			_room_doors[r].append(i)
			if d.airlock:
				if not _room_airlocks.has(r):
					_room_airlocks[r] = []
				_room_airlocks[r].append(i)
	for c in ship.crew:
		c.ai_task = make_task(IDLE, c.room)


static func make_task(id: int, room := -1, sys := "") -> Dictionary:
	return {"id": id, "room": room, "sys": sys}


static func same_task(a: Dictionary, b: Dictionary) -> bool:
	return a.id == b.id and a.room == b.room and a.sys == b.sys


# ------------------------------------------------------------ frame (CrewAI::OnLoop)

func tick() -> void:
	if not hostile or ship.is_destroyed():
		return
	breached_rooms.clear()
	multiracial = _is_multiracial()
	if not ship.crew.is_empty():
		check_for_problems()
	if ai_on:
		close_airlocks()
	for c in ship.crew:
		update_crew_member(c)
	update_drones()
	for i in desired.size():
		var t: Dictionary = desired[i]
		if t.id == FIRE or t.id == FIGHT:
			var vent_room: int = i if VENT_USES_TASK_INDEX else t.room
			if safe_blowout_oxygen(vent_room):
				continue
		attempt_to_assign(t)
	if ai_on:
		check_for_healing()
	update_intruders()


# ------------------------------------------------------------ helpers

## Player-controllable crew (the player's crew, also when boarding; never while mind controlled).
func controllable(c: CrewMember) -> bool:
	return c.player_owned and not c.is_drone() and not c.mind_controlled


func is_intruder(c: CrewMember) -> bool:
	return c.is_intruder(ship)


func room_has_doors(room: int) -> bool:
	return _room_doors.has(room)


func room_system_id(room: int) -> String:
	var s := ship.system_in_room(room)
	return s.id if s else ""


func room_oxygen(room: int) -> float:
	return ship.env.oxygen.get(room, 100.0)


## ShipManager::GetOxygenPercentage (0 without an oxygen system).
func oxygen_percentage() -> int:
	return ship.oxygen_percentage()


## Hostile boarders in a room (ShipManager::CountBoarders: living intruders standing in it).
func count_boarders(room: int) -> int:
	var n := 0
	for c in ship.crew:
		if c.is_alive() and c.room == room and c.is_intruder(ship):
			n += 1
	return n


## Living own crew (not intruders) whose stored task is exactly `t`.
func crew_on(t: Dictionary) -> int:
	var n := 0
	for c in ship.crew:
		if c.is_alive() and not c.is_intruder(ship) and not c.is_drone() and same_task(c.ai_task, t):
			n += 1
	return n


## CrewMember::IsBusy (repairing, fighting, not standing on its slot, frozen).
func is_busy(c: CrewMember) -> bool:
	return c.is_walking() or c.stun > 0.0 or not c.is_on_slot(ship) or c.fighting \
		or c.task in [CrewMember.Task.REPAIR_SYSTEM, CrewMember.Task.FIRE, CrewMember.Task.BREACH,
			CrewMember.Task.SABOTAGE]


func can_suffocate(c: CrewMember) -> bool:
	return c.can_suffocate()


func can_burn(c: CrewMember) -> bool:
	return c.can_burn()


## Damage multiplier < 1 (engi) or max HP < 100.
func bad_at_combat(c: CrewMember) -> bool:
	return c.damage_mult() < 1.0 or c.max_hp < 100.0


func _is_multiracial() -> bool:
	if override_race:
		return false
	var weak := false
	var other := false
	for c in ship.crew:
		if not c.is_alive() or c.is_intruder(ship) or c.is_drone():
			continue
		if c.race == "engi" or c.race == "energy":
			weak = true
		else:
			other = true
	return weak and other


func medbay_hacked() -> bool:
	var m := ship.sys("medbay")
	return m != null and m.hacked


# ------------------------------------------------------------ problems (CheckForProblems)

func check_for_problems() -> void:
	desired.clear()
	bonus.clear()
	calm = true
	var rooms := []
	for r in ship.layout.rooms:
		rooms.append(r.id)
	rooms.sort()
	for room in rooms:
		if not room_has_doors(room):
			continue
		var sid := room_system_id(room)
		# 1. Boarders (hook: none yet).
		var n := count_boarders(room)
		if n > 0:
			calm = false
			var t := make_task(FIGHT, room, sid)
			var need := n - crew_on(t)
			for i in need:
				desired.append(t.duplicate())
			if need == 0:
				bonus.append(t.duplicate())
		# 2. Fire: at most 2 crew per burning room, only while it has oxygen to breathe.
		if ship.env.fires_in(room) > 0:
			calm = false
			if room_oxygen(room) >= SAFE_O2:
				var t := make_task(FIRE, room, sid)
				var k := crew_on(t)
				if k >= MAX_FIRE_CREW:
					bonus.append(t.duplicate())
				for i in MAX_FIRE_CREW - k:
					desired.append(t.duplicate())
	# 3. Teleporter boarding: request - crew already on (8, teleporter room) board tasks.
	var tp := ship.sys("teleporter")
	if tp:
		var bt := make_task(BOARD, tp.room)
		for i in teleport_request - crew_on(bt):
			desired.append(bt.duplicate())
	# 4. Hull breaches: one task per breach object.
	var broom := ship.breaches.keys()
	broom.sort()
	for room in broom:
		if not room_has_doors(room):
			continue
		for tile in ship.breaches[room]:
			if ship.breaches[room][tile].health <= 0.0:
				continue
			breached_rooms[room] = true
			calm = false
			if ai_on:
				seal_room(room)
			var t := make_task(BREACH, room, room_system_id(room))
			if _anyone_on_breach(room):
				bonus.append(t)
			else:
				desired.append(t)
	# 5. Systems, in ship order: repair if damaged, man if nobody is in the room.
	for s in ship.systems.values():
		if not room_has_doors(s.room):
			continue
		if s.damage > 0:
			calm = false
			var t := make_task(REPAIR, s.room, s.id)
			if crew_on(t) > 0:
				bonus.append(t)
			else:
				desired.append(t)
		var m := make_task(MAN, s.room, s.id)
		if not ship.is_manned(s.id) and crew_on(m) == 0:
			desired.append(m)


func _anyone_on_breach(room: int) -> bool:
	for c in ship.crew:
		if c.is_alive() and not c.is_intruder(ship) and c.ai_task.id == BREACH and c.ai_task.room == room:
			return true
	return false


# ------------------------------------------------------------ priorities (PrioritizeTask)

func system_base(sys_id: String) -> int:
	if sys_id == "medbay" and medbay_requested:
		return 1
	if sys_id == "teleporter":
		if urgent_teleport:
			return 0
		return 1 if teleport_request > 0 else 3
	return SYSTEM_BASE.get(sys_id, SYSTEM_BASE_DEFAULT)


func man_priority(sys_id: String) -> int:
	if ShipAI.difficulty == ShipAI.Difficulty.HARD and MAN_PRIORITY_HARD.has(sys_id):
		return MAN_PRIORITY_HARD[sys_id]
	return MAN_PRIORITY.get(sys_id, 1000)


## Lower = more important. `c` = the crew evaluating it (null: no danger check, as for drones).
func prioritize(t: Dictionary, c: CrewMember = null) -> int:
	if t.id == DEAD:
		return -1
	if c != null:
		if danger_rating(t.room, c) == 0:
			return 100
		if (t.id == FIGHT or t.id == BOARD) and multiracial and bad_at_combat(c):
			return 100
		if t.id == BOARD and c.hp / c.max_hp < BOARD_MIN_HP:
			return 100
	match t.id:
		MAN:
			return man_priority(t.sys)
		REPAIR:
			if t.sys == "oxygen" and oxygen_percentage() < LOW_SHIP_O2:
				return 0
			if t.sys == "shields":
				return 1
			return 48 + system_base(t.sys)
		FIRE, FIGHT:
			var sid := room_system_id(t.room)
			return 16 + system_base(sid) if sid != "" else 24
		BREACH:
			var sid := room_system_id(t.room)
			return 32 + system_base(sid) if sid != "" else 40
		HEAL:
			return 0
		BOARD:
			if urgent_teleport:
				return 0
			return 32 if TeleporterRule.charged(ship) else 65
	return 1000


## 0 = dangerous for this crew, 1 = safe (DangerRating).
func danger_rating(room: int, c: CrewMember) -> int:
	if room < 0:
		return 1
	if ship.env.airlocks_open_in(room) > 0:
		return 0
	var f := c.hp / c.max_hp
	if f < DANGER_SUFFOCATE_HP and room_oxygen(room) < SAFE_O2 and can_suffocate(c):
		return 0
	var fires := ship.env.fires_in(room)
	if fires >= 1 and f < DANGER_BURN_HP and can_burn(c):
		return 0
	if fires >= DANGER_FIRES and can_burn(c):
		return 0
	var m := ship.sys("medbay")
	if m and m.room == room and m.hacked:
		return 0
	if breached_rooms.has(room) and fires == ship.room_tiles(room):
		return 0
	return 1


# ------------------------------------------------------------ assignment (AttemptToAssign)

## Give `t` to the crew doing the least important thing, if strictly better for it; a crew already
## repairing/fighting in the same room takes it at once. Returns true if the task was handed out.
func attempt_to_assign(t: Dictionary) -> bool:
	var best: CrewMember = null
	var best_cur := -1
	for c in ship.crew:
		if not c.is_alive() or controllable(c) or is_intruder(c) or c.is_drone() or not room_has_doors(c.room):
			continue
		if same_task(c.ai_task, t):
			continue
		var cur := prioritize(c.ai_task, c)
		var nw := prioritize(t, c)
		if nw > cur:
			continue
		if best == null or cur > best_cur:
			best = c
			best_cur = cur
		if c.ai_task.id in [REPAIR, FIRE, BREACH, FIGHT] and c.ai_task.room == t.room:
			give_task(c, t)
			return true
	if best and prioritize(t, best) < best_cur:
		give_task(best, t)
		return true
	if multiracial and (t.id == FIGHT or t.id == BOARD):
		multiracial = false
		override_race = true
		return attempt_to_assign(t)
	return false


## Order the walk and store the task (fails if dead or the room is full / unreachable).
func give_task(c: CrewMember, t: Dictionary) -> bool:
	if not c.is_alive():
		return false
	if c.move_to_room(ship, t.room) or c.target_room == t.room:
		c.ai_task = t.duplicate()
		return true
	return false


# ------------------------------------------------------------ per crew (UpdateCrewMember)

func update_crew_member(c: CrewMember) -> void:
	if not c.is_alive():
		c.ai_task = make_task(DEAD)
		return
	if is_intruder(c):
		return  # intruders only sabotage here (CrewMember.update_task); moved by update_intruders
	if c.is_drone():
		return  # own crew drones: update_drones
	# SetCurrentSystem: "home station" = system of the room the crew stands in while able to man.
	var here := room_system_id(c.room)
	if here != "" and c.stun <= 0.0:
		c.manning_id = here
	if controllable(c):
		_label_player_crew(c)
		return
	var busy := is_busy(c)
	var t: Dictionary = c.ai_task
	if not busy and t.id != MAN:
		var keep := false
		if t.id == HEAL:
			if medbay_hacked():
				c.ai_task = make_task(IDLE, c.room)
				keep = true
			elif c.hp / c.max_hp < HURT_CALM:
				keep = true
		elif t.id == BOARD and teleport_request > 0:
			keep = true
		if not keep:
			var home := ship.sys(c.manning_id) if c.manning_id != "" else null
			if home == null:
				c.ai_task = make_task(IDLE, c.room)
			else:
				var m := make_task(MAN, home.room, home.id)
				c.ai_task = m if crew_on(m) == 0 else make_task(IDLE, home.room)
	t = c.ai_task
	if t.id == FIGHT and count_boarders(c.target_room) == 0:  # room of its slot, not where it walks
		c.ai_task = make_task(IDLE, c.room)
	t = c.ai_task
	if not busy and t.room != c.room:
		c.ai_task = make_task(IDLE, c.room)
	t = c.ai_task
	if not busy and t.id == MAN and crew_on(t) >= 2:
		c.ai_task = make_task(IDLE, c.room)
	t = c.ai_task
	if t.id == BOARD and crew_on(t) > teleport_request:
		c.ai_task = make_task(IDLE, c.room)  # more crew boarding than requested


## CrewAI::SetTeleportRequest: capped at the teleporter room slot count (0 without a teleporter).
func set_teleport_request(n: int) -> void:
	var tp := ship.sys("teleporter")
	teleport_request = 0 if tp == null else mini(n, ship.graph.slot_count(tp.room))


## CrewAI::ReadyForTeleport: prepared crew on the pad >= request.
func ready_for_teleport() -> bool:
	return TeleporterRule.prepared_crew(ship) >= teleport_request


## Player crew: bookkeeping label only (never moved). Uses the room of its slot (currentSlot.roomId).
func _label_player_crew(c: CrewMember) -> void:
	var room := c.target_room
	var sid := room_system_id(room)
	var s := ship.system_in_room(room)
	if count_boarders(room) > 0:
		c.ai_task = make_task(FIGHT, room, sid)
	elif ship.env.fires_in(room) > 0:
		c.ai_task = make_task(FIRE, room, sid)
	elif (s and s.damage > 0) or c.task == CrewMember.Task.REPAIR_SYSTEM:
		c.ai_task = make_task(REPAIR, room, sid)
	elif c.task == CrewMember.Task.MAN:
		c.ai_task = make_task(MAN, room, sid)
	else:
		c.ai_task = make_task(IDLE, room)


# ------------------------------------------------------------ crew drones (UpdateDrones)

## CrewAI::UpdateDrones: own powered crew drones. An idle repair drone takes the best desired or bonus
## task of type repair / fire / breach (priority without danger); an anti-personnel drone goes to the
## nearest room with a fight task (distance to the room centre); otherwise drones go back to the
## drone-system room as idle.
func update_drones() -> void:
	var ds := ship.sys("drones")
	for c in ship.crew:
		if not c.is_alive() or not c.is_drone() or c.is_intruder(ship) or c.frozen:
			continue
		var best := {}
		if c.drone_kind == "repair":
			if is_busy(c):
				continue
			var best_p := 1 << 30
			for t in desired + bonus:
				if t.id in [REPAIR, FIRE, BREACH]:
					var p := prioritize(t)
					if p < best_p:
						best_p = p
						best = t
		elif c.drone_kind == "battle":
			if c.fighting or c.is_walking() and c.ai_task.id == FIGHT:
				continue
			var best_d := INF
			for t in desired + bonus:
				if t.id == FIGHT:
					var dist := c.pos.distance_to(ship.room_rect(t.room).get_center())
					if dist < best_d:
						best_d = dist
						best = t
		if best.is_empty():
			if ds == null or is_busy(c):
				continue
			best = make_task(IDLE, ds.room)
		if c.target_room != best.room and not c.move_to_room(ship, best.room):
			continue
		c.ai_task = best.duplicate()


# ------------------------------------------------------------ healing (CheckForHealing)

func check_for_healing() -> void:
	hurt_crew = false
	for c in ship.crew:
		if not c.is_alive() or controllable(c) or is_intruder(c) or c.is_drone():
			continue
		var f := c.hp / c.max_hp
		var hurt := f < HURT_ALWAYS or (f < HURT_CALM and calm)
		var healing: bool = c.ai_task.id == HEAL
		if hurt or healing:
			hurt_crew = true
		if not hurt:
			continue
		var m := ship.sys("medbay")
		if not healing and m and m.effective_power() > 0 and not m.hacked \
				and danger_rating(m.room, c) == 1:
			if c.move_to_room(ship, m.room) or c.target_room == m.room:
				c.ai_task = make_task(HEAL, m.room)
				medbay_requested = false
		else:
			medbay_requested = true


# ------------------------------------------------------------ doors (enemy only)

## ShipManager::ManipulateDoors(room, close).
func seal_room(room: int) -> void:
	if not ship.doors_function():
		return
	for i in _room_doors.get(room, []):
		ship.env.set_door(i, false)


## Close open airlocks, except those of a burning room (kept open while it is being vented).
func close_airlocks() -> void:
	if not ship.doors_function():
		return
	for room in _room_airlocks:
		if ship.env.fires_in(room) != 0:
			continue
		for i in _room_airlocks[room]:
			if ship.env.doors[i].open:
				ship.env.set_door(i, false)


## Vent an empty burning room instead of sending crew. Returns true if vented (task skipped).
func safe_blowout_oxygen(room: int) -> bool:
	if not ai_on or not _room_airlocks.has(room):
		return false
	for c in ship.crew:
		if c.is_alive() and not c.is_intruder(ship) and (c.ai_task.room == room or c.room == room):
			return false
	if room_oxygen(room) < SAFE_O2:
		return false
	if ship.doors_function():
		for i in _room_airlocks[room]:
			ship.env.set_door(i, true)
	return true


# ------------------------------------------------------------ intruders (UpdateIntruders)

## AI-driven intruders aboard: not player-controllable (CrewAI::OnLoop intruderList).
func intruder_list() -> Array:
	return ship.crew.filter(func(c): return c.is_alive() and is_intruder(c) and not controllable(c))


## CrewAI::UpdateIntruders: an intruder standing in a room other than its task room adopts it; then
## the first intruder picks a room (ChoosePriorityRoom) and it and every following intruder are
## ordered there until an order fails; the next pick starts after the last one moved.
func update_intruders() -> void:
	var list := intruder_list()
	for c in list:
		if c.is_on_slot(ship) and c.ai_task.room != c.room:
			c.ai_task = make_task(c.ai_task.id, c.room, room_system_id(c.room))
	var i := 0
	while i < list.size():
		var leader: CrewMember = list[i]
		if not room_has_doors(leader.room):
			i += 1
			continue
		var room := choose_priority_room(leader, list)
		var tid: int = leader.ai_task.id
		var tsys: String = leader.ai_task.sys
		var j := i
		while j < list.size():
			var c: CrewMember = list[j]
			if room != c.ai_task.room:
				if not (c.move_to_room(ship, room) or c.target_room == room):
					j -= 1
					break
				c.ai_task = make_task(tid, room, tsys)
			j += 1
		if j + 1 == i:
			return  # the leader itself could not be moved
		i = j + 1


## CrewAI::ChoosePriorityRoom: score of the current task room vs every non-full (intruder slots),
## reachable room with doors; strictly lower wins; ties among the best are random unless they tie
## with the current room.
func choose_priority_room(c: CrewMember, list: Array) -> int:
	var cur_room: int = c.ai_task.room
	var cur := prioritize_intruder_room(c, cur_room, list)
	var best := cur
	var cands := []
	for r in ship.layout.rooms:
		var room: int = r.id
		if ship.graph.room_full(room, true) or not room_has_doors(room):
			continue
		if room != c.room and ship.graph.find_path(c.pos, c.room, room, c) == null:
			continue
		var p := prioritize_intruder_room(c, room, list)
		if p < best:
			best = p
			cands = [room]
		elif p == best and p != cur:
			cands.append(room)
	if cands.is_empty():
		return cur_room
	return cands[ship.rng.randi() % cands.size()]


## CrewAI::PrioritizeIntruderRoom (lower = better), boarding goal "system" (BoardingGoal default):
## -10 to stay in its own room while defenders are there (doors system powered; only crew that can fight, and
## not its BlockRoom); +100 fire (if it can burn), +70 oxygen < 10 % (if it can suffocate); +5 if the number of
## intruders aboard differs from the room's slot count; +10 if not connected to its current room; +100 for its
## BlockRoom (the ion boarding drone's last discharge room); +20 if no intact system.
func prioritize_intruder_room(c: CrewMember, room: int, list: Array) -> int:
	var defenders := 0
	for o in ship.crew:
		if o.is_alive() and o.room == room and not o.is_intruder(ship):
			defenders += 1
	var blocked := c.block_room()
	if defenders > 0 and ship.system_power("doors") != 0 and room == c.room and c.can_fight() and room != blocked:
		return -10
	var p := 0
	if ship.env.fires_in(room) > 0 and c.can_burn():
		p += 100
	if room_oxygen(room) < SAFE_O2 and c.can_suffocate():
		p += 70
	if list.size() != ship.graph.slot_count(room):
		p += 5
	if not _rooms_connected(c.room, room):
		p += 10
	if room == blocked:
		p += 100
	var s := ship.system_in_room(room)
	if s == null or s.damage >= s.get_level():
		p += 20
	return p


## ShipGraph::IsRoomConnected: the same room or joined by a (non-airlock) door.
func _rooms_connected(a: int, b: int) -> bool:
	if a == b:
		return true
	for i in _room_doors.get(a, []):
		var d: Dictionary = ship.env.doors[i]
		if (d.left == a and d.right == b) or (d.left == b and d.right == a):
			return true
	return false
