extends Node
## Tests for rules/crew_ai.md (enemy crew AI: tasks, priorities, assignment, doors, healing). Run:
##   godot --headless --path godot res://tests/test_crew_ai.tscn

const Harness := preload("res://tests/harness.gd")

const DT := 1.0 / 60.0

var fails := 0


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


## Enemy ship with its CrewAI, after one frame (crew adopt their stations).
func enemy(bp := "REBEL_FAT") -> Array:
	var s := ShipState.new(bp, false)
	var ai := CrewAI.new(s)
	step(s, ai)
	return [s, ai]


func step(s: ShipState, ai: CrewAI) -> void:
	s.tick(DT * GameClock.BASE)
	ai.tick()


func run(s: ShipState, ai: CrewAI, seconds: float, per_step := Callable()) -> void:
	var t := 0.0
	while t < seconds:
		if per_step.is_valid():
			per_step.call()
		step(s, ai)
		t += DT


## Seconds until cond() (or max_s + 1).
func time_until(s: ShipState, ai: CrewAI, cond: Callable, max_s: float, per_step := Callable()) -> float:
	var t := 0.0
	while t <= max_s:
		if cond.call():
			return t
		if per_step.is_valid():
			per_step.call()
		step(s, ai)
		t += DT
	return max_s + 1.0


func count_task(s: ShipState, id: int, room := -1) -> int:
	var n := 0
	for c in s.crew:
		if c.is_alive() and c.ai_task.id == id and (room < 0 or c.ai_task.room == room):
			n += 1
	return n


func count_desired(ai: CrewAI, id: int, room := -1) -> int:
	var n := 0
	for t in ai.desired:
		if t.id == id and (room < 0 or t.room == room):
			n += 1
	return n


func has_airlock(s: ShipState, room: int) -> bool:
	for d in s.env.doors:
		if d.airlock and (d.left == room or d.right == room):
			return true
	return false


func crew_in(s: ShipState, room: int) -> int:
	var n := 0
	for c in s.crew:
		if c.is_alive() and (c.room == room or c.target_room == room):
			n += 1
	return n


## A room with a system, doors, no airlock and nobody in it (or -1).
func empty_system_room(s: ShipState, ai: CrewAI) -> int:
	for sy in s.systems.values():
		if ai.room_has_doors(sy.room) and not has_airlock(s, sy.room) and crew_in(s, sy.room) == 0 \
				and s.room_tiles(sy.room) >= 2:
			return sy.room
	return -1


func no_spread(s: ShipState) -> Callable:
	return func(): s.env.spread_timers.clear()


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	ShipAI.difficulty = ShipAI.Difficulty.NORMAL
	var r := enemy()
	var s: ShipState = r[0]
	var ai: CrewAI = r[1]

	print("Initial placement (enemy, normal): pilot, shields, weapons")
	check("3 crew", s.crew.size(), 3)
	check("crew 0 in piloting", s.crew[0].room, s.sys("pilot").room)
	check("crew 1 in shields", s.crew[1].room, s.sys("shields").room)
	check("crew 2 in weapons", s.crew[2].room, s.sys("weapons").room)
	check("crew 0 manning pilot", ai.same_task(s.crew[0].ai_task,
		CrewAI.make_task(CrewAI.MAN, s.sys("pilot").room, "pilot")), true)
	ShipAI.difficulty = ShipAI.Difficulty.HARD
	var sh := ShipState.new("REBEL_FAT", false)
	check("hard: crew 1 in engines", sh.crew[1].room, sh.sys("engines").room)
	ShipAI.difficulty = ShipAI.Difficulty.NORMAL

	print("Priority values (no crew: no danger check)")
	var P := func(id: int, room: int, sys_id := "") -> int:
		return ai.prioritize(CrewAI.make_task(id, room, sys_id))
	var wr := s.sys("weapons").room
	var shr := s.sys("shields").room
	var o2r := s.sys("oxygen").room
	var no_sys := -1
	for rr in s.layout.rooms:
		if s.system_in_room(rr.id) == null:
			no_sys = rr.id
			break
	check("man pilot", P.call(CrewAI.MAN, 0, "pilot"), 64)
	check("man shields", P.call(CrewAI.MAN, 0, "shields"), 65)
	check("man weapons", P.call(CrewAI.MAN, 0, "weapons"), 66)
	check("man engines", P.call(CrewAI.MAN, 0, "engines"), 67)
	check("man oxygen", P.call(CrewAI.MAN, 0, "oxygen"), 68)
	check("man sensors", P.call(CrewAI.MAN, 0, "sensors"), 69)
	check("man doors", P.call(CrewAI.MAN, 0, "doors"), 70)
	check("man medbay", P.call(CrewAI.MAN, 0, "medbay"), 72)
	check("man drones (unmannable)", P.call(CrewAI.MAN, 0, "drones"), 1000)
	ShipAI.difficulty = ShipAI.Difficulty.HARD
	check("hard: man shields", P.call(CrewAI.MAN, 0, "shields"), 67)
	check("hard: man engines", P.call(CrewAI.MAN, 0, "engines"), 65)
	ShipAI.difficulty = ShipAI.Difficulty.NORMAL
	check("repair shields (flat)", P.call(CrewAI.REPAIR, shr, "shields"), 1)
	check("repair weapons 48+1", P.call(CrewAI.REPAIR, wr, "weapons"), 49)
	check("repair engines 48+4", P.call(CrewAI.REPAIR, 0, "engines"), 52)
	check("repair oxygen 48+3", P.call(CrewAI.REPAIR, o2r, "oxygen"), 51)
	check("fire in shields room 16+0", P.call(CrewAI.FIRE, shr), 16)
	check("fire in weapons room 16+1", P.call(CrewAI.FIRE, wr), 17)
	check("fire in a room without system", P.call(CrewAI.FIRE, no_sys), 24)
	check("breach in weapons room 32+1", P.call(CrewAI.BREACH, wr), 33)
	check("breach in a room without system", P.call(CrewAI.BREACH, no_sys), 40)
	check("heal", P.call(CrewAI.HEAL, 0), 0)
	check("idle", P.call(CrewAI.IDLE, 0), 1000)
	check("dead", P.call(CrewAI.DEAD, -1), -1)
	check("fire < breach < repair < man (weapons)",
		P.call(CrewAI.FIRE, wr) < P.call(CrewAI.BREACH, wr) and P.call(CrewAI.BREACH, wr)
		< P.call(CrewAI.REPAIR, wr, "weapons") and P.call(CrewAI.REPAIR, wr, "weapons")
		< P.call(CrewAI.MAN, wr, "weapons"), true)
	ai.medbay_requested = true
	check("medbay requested: fire in medbay room uses base 1", ai.system_base("medbay"), 1)
	ai.medbay_requested = false

	print("Low ship oxygen: repairing oxygen becomes 0")
	for k in s.env.oxygen:
		s.env.oxygen[k] = 20.0
	check("repair oxygen at 20 % ship O2", P.call(CrewAI.REPAIR, o2r, "oxygen"), 0)
	for k in s.env.oxygen:
		s.env.oxygen[k] = 100.0

	print("Danger rating -> every task there is worth 100 for that crew")
	var c0 := s.crew[0]
	var t_fire := CrewAI.make_task(CrewAI.FIRE, wr, "weapons")
	check("safe room: fire task 17", ai.prioritize(t_fire, c0), 17)
	for i in 4:
		s.ignite(wr, i)
	check("4 fires: dangerous", ai.danger_rating(wr, c0), 0)
	check("  fire task = 100", ai.prioritize(t_fire, c0), 100)
	s.fires.clear()
	s.ignite(wr, 0)
	c0.hp = 15.0
	check("1 fire and crew < 20 % HP: 100", ai.prioritize(t_fire, c0), 100)
	c0.hp = c0.max_hp
	check("1 fire, healthy crew: 17", ai.prioritize(t_fire, c0), 17)
	s.fires.clear()
	var al := -1
	for i in s.env.doors.size():
		if s.env.doors[i].airlock:
			al = i
			break
	if al >= 0:
		var alr: int = maxi(s.env.doors[al].left, s.env.doors[al].right)
		s.env.doors[al].open = true
		check("open airlock: room dangerous", ai.danger_rating(alr, c0), 0)
		check("  man task there = 100", ai.prioritize(CrewAI.make_task(CrewAI.MAN, alr, "x"), c0), 100)
		s.env.doors[al].open = false

	print("Assignment: the crew with the least important current task takes the new one")
	r = enemy()
	s = r[0]
	ai = r[1]
	s.damage_system("engines", 1)  # engines room is empty (repair 52)
	step(s, ai)
	var er := s.sys("engines").room
	check("weapons crew (manning 66, least important) takes the repair", s.crew[2].ai_task.id, CrewAI.REPAIR)
	check("  and walks to engines", s.crew[2].target_room, er)
	check("pilot (64) keeps manning", s.crew[0].ai_task.id, CrewAI.MAN)
	check("shields (65) keeps manning", s.crew[1].ai_task.id, CrewAI.MAN)
	check("one crew on the repair", count_task(s, CrewAI.REPAIR), 1)

	print("Enemy crew repair a damaged system and return to man stations")
	var eng := s.sys("engines")
	var t := time_until(s, ai, func(): return eng.damage == 0, 30.0)
	check("engines repaired by the AI crew (< 20 s incl. walk)", t < 20.0, true)
	t = time_until(s, ai, func(): return s.is_manned("pilot") and s.is_manned("shields") \
		and s.is_manned("weapons") and s.active_manning_crew("weapons") != null \
		and s.active_manning_crew("shields") != null and s.active_manning_crew("pilot") != null, 20.0)
	check("pilot, shields and weapons manned on console again", t < 20.0, true)
	check("nobody left on a repair task", count_task(s, CrewAI.REPAIR), 0)
	check("3 manning tasks", count_task(s, CrewAI.MAN), 3)

	print("Fire: at most 2 crew per burning room; none under 10 % O2")
	r = enemy()
	s = r[0]
	ai = r[1]
	var fr := empty_system_room(s, ai)
	check("found an empty room without airlock", fr >= 0, true)
	s.ignite(fr, 0)
	ai.check_for_problems()
	check("2 fire tasks desired", count_desired(ai, CrewAI.FIRE, fr), 2)
	step(s, ai)
	step(s, ai)
	check("exactly 2 crew sent to the fire", count_task(s, CrewAI.FIRE, fr), 2)
	ai.check_for_problems()
	check("2 crew on it -> no more desired fire tasks", count_desired(ai, CrewAI.FIRE, fr), 0)
	check("  one bonus fire task", ai.bonus.filter(func(b): return b.id == CrewAI.FIRE).size(), 1)
	check("third crew (pilot, 64) stays", s.crew[0].ai_task.id, CrewAI.MAN)
	r = enemy()
	s = r[0]
	ai = r[1]
	s.ignite(fr, 0)
	s.env.oxygen[fr] = 5.0
	ai.check_for_problems()
	check("O2 5 %: no fire task", count_desired(ai, CrewAI.FIRE), 0)
	check("  but the ship is not calm", ai.calm, false)

	print("Fire beats breach beats repair (same crew pool)")
	r = enemy()
	s = r[0]
	ai = r[1]
	s.ignite(fr, 0)
	s.env.oxygen[fr] = 100.0
	ai.check_for_problems()
	var ids := ai.desired.map(func(x): return x.id)
	check("fire task is listed", ids.has(CrewAI.FIRE), true)
	var tf := ai.prioritize(ai.desired[ids.find(CrewAI.FIRE)], s.crew[2])
	var tb := ai.prioritize(CrewAI.make_task(CrewAI.BREACH, fr), s.crew[2])
	var trp := ai.prioritize(CrewAI.make_task(CrewAI.REPAIR, fr, s.system_in_room(fr).id), s.crew[2])
	check("fire < breach < repair for the same room", tf < tb and tb < trp, true)

	print("Venting: empty burning room with an airlock gets its airlock opened, no crew sent")
	r = enemy("PLAYER_SHIP_HARD")  # Kestrel as an AI ship (has a doors system)
	s = r[0]
	ai = r[1]
	var vr := -1
	for rr in s.layout.rooms:
		if has_airlock(s, rr.id) and crew_in(s, rr.id) == 0 and ai.room_has_doors(rr.id):
			vr = rr.id
			break
	check("found an empty room with an airlock", vr >= 0, true)
	if vr >= 0:
		s.ignite(vr, 0)
		step(s, ai)
		check("its airlock is open", s.env.airlocks_open_in(vr) > 0, true)
		check("no crew sent to it", count_task(s, CrewAI.FIRE, vr), 0)

	print("Breach: enemy closes every door of the breached room each frame")
	r = enemy("PLAYER_SHIP_HARD")
	s = r[0]
	ai = r[1]
	s.env.set_all_doors(true)
	var br := s.sys("oxygen").room
	s.add_breach(br, 0)
	step(s, ai)
	var all_closed := true
	var others_open := true
	for d in s.env.doors:
		if d.airlock:
			continue
		if d.left == br or d.right == br:
			all_closed = all_closed and not d.open
		else:
			others_open = others_open and d.open
	check("doors of the breached room closed", all_closed, true)
	check("other doors untouched", others_open, true)
	check("one crew sent to the breach", count_task(s, CrewAI.BREACH, br), 1)
	ai.check_for_problems()
	check("  then no desired breach task (bonus instead)", count_desired(ai, CrewAI.BREACH), 0)
	s.add_breach(br, 1)
	ai.check_for_problems()
	check("second breach in a room already handled: bonus only", count_desired(ai, CrewAI.BREACH), 0)
	s.sys("doors").damage = s.sys("doors").get_level()
	s.env.set_all_doors(true)
	step(s, ai)
	var still_open := true
	for d in s.env.doors:
		if not d.airlock and (d.left == br or d.right == br):
			still_open = still_open and d.open
	check("broken doors system: doors not closed", still_open, true)

	print("Player ship: crew are never moved by the AI; doors untouched")
	s = ShipState.new("PLAYER_SHIP_HARD", true)
	ai = CrewAI.new(s)
	check("player CrewAI is off", ai.ai_on, false)
	var rooms_before := s.crew.map(func(c): return c.target_room)
	s.env.set_all_doors(true)
	s.damage_system("shields", 2)
	s.damage_system("engines", 1)
	s.add_breach(s.sys("oxygen").room, 0)
	s.ignite(s.sys("medbay").room, 0)
	s.crew[0].hp = 10.0
	run(s, ai, 3.0, no_spread(s))
	check("player crew stay where they were", s.crew.map(func(c): return c.target_room), rooms_before)
	var doors_open := true
	for d in s.env.doors:
		if not d.airlock:
			doors_open = doors_open and d.open
	check("player doors not closed by the AI", doors_open, true)
	check("engineer labelled as repairing engines", s.crew[1].ai_task.id, CrewAI.REPAIR)
	check("pilot labelled as manning", s.crew[0].ai_task.id, CrewAI.MAN)

	print("Healing: hurt enemy crew walk to a working medbay")
	r = enemy("PLAYER_SHIP_HARD")
	s = r[0]
	ai = r[1]
	var mb := s.sys("medbay")
	if mb.power == 0:
		mb.power = 1
	s.crew[2].hp = 20.0
	step(s, ai)
	check("crew at 20 % gets the heal task", s.crew[2].ai_task.id, CrewAI.HEAL)
	check("  and walks to the medbay", s.crew[2].target_room, mb.room)
	check("hurt_crew flag", ai.hurt_crew, true)
	run(s, ai, 6.0)
	check("still healing in the medbay (no heal mechanic yet)", s.crew[2].ai_task.id, CrewAI.HEAL)
	s.crew[2].hp = s.crew[2].max_hp
	run(s, ai, 0.1)
	check("full HP: leaves the heal task", s.crew[2].ai_task.id != CrewAI.HEAL, true)
	r = enemy("PLAYER_SHIP_HARD")
	s = r[0]
	ai = r[1]
	s.sys("medbay").power = 0
	s.crew[2].hp = 20.0
	step(s, ai)
	check("unpowered medbay: no heal task", s.crew[2].ai_task.id != CrewAI.HEAL, true)
	check("  medbay requested", ai.medbay_requested, true)

