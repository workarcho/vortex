extends Node
## Tests for rules/crew_combat.md (races, hits, shooting/punching cadence, kills, sabotage, intruder
## AI, defenders, doors vs intruders). Run:
##   godot --headless --path godot res://tests/test_crew_combat.tscn

const Harness := preload("res://tests/harness.gd")

const DT := 1.0 / 60.0

var fails := 0


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func near(name: String, got: float, want: float, tol: float) -> void:
	check("%s ~= %.2f (+/-%.2f) [%.2f]" % [name, want, tol, got], absf(got - want) <= tol, true)


func between(name: String, got: float, lo: float, hi: float) -> void:
	check("%s in [%.2f, %.2f] [%.2f]" % [name, lo, hi, got], got >= lo and got <= hi, true)


func step(s: ShipState, ai: CrewAI = null) -> void:
	s.tick(DT * GameClock.BASE)
	if ai:
		ai.tick()


func run(s: ShipState, seconds: float, ai: CrewAI = null, per_step := Callable()) -> void:
	var t := 0.0
	while t < seconds - 1e-6:
		if per_step.is_valid():
			per_step.call()
		step(s, ai)
		t += DT


func time_until(s: ShipState, cond: Callable, max_s: float, ai: CrewAI = null) -> float:
	var t := 0.0
	while t <= max_s:
		if cond.call():
			return t
		step(s, ai)
		t += DT
	return max_s + 1.0


func kestrel() -> ShipState:
	var s := ShipState.new("PLAYER_SHIP_HARD", true)
	s.rng.seed = 12345
	return s


## Kestrel with only crew member 0 left (the others are removed), standing in `room`.
func duel_ship(room: int) -> ShipState:
	var s := kestrel()
	s.crew.resize(1)
	s.crew[0].place(s, room, s.graph.find_slot(room, s.crew[0]))
	return s


## Hit events on `c` over `seconds`: [count, total damage].
func hits_on(s: ShipState, c: CrewMember, seconds: float) -> Array:
	var n := 0
	var total := 0.0
	var last := c.hp
	var t := 0.0
	while t < seconds and c.is_alive():
		step(s)
		if c.hp < last - 0.001:
			n += 1
			total += last - c.hp
		last = c.hp
		for k in s.crew:  # keep everyone alive and comparable
			k.hp = k.max_hp
		last = c.hp
		t += DT
	return [n, total]


func room_without_system(s: ShipState) -> int:
	for r in s.layout.rooms:
		if s.system_in_room(r.id) == null and s.graph.slot_count(r.id) >= 2:
			return r.id
	return -1


func has_airlock(s: ShipState, room: int) -> bool:
	for d in s.env.doors:
		if d.airlock and (d.left == room or d.right == room):
			return true
	return false


func _ready() -> void:
	Harness.run(self, _run)


## Crew laser lifecycle (CrewAnimation::UpdateShooting / OnUpdateEffects, CrewLaser): spawn at the shooter when the
## timer fires, fly at 160 px/s, damage only after landing (next frame), hit animation 0.5 s, then removed.
## Mind control and target choice (ShipManager::UpdateCrewmembers splits each room into GetIntruder true / false
## lists and a crew member only picks from the other list; GetIntruder is inverted while mind controlled).
func _mind_allegiance(wr: int) -> void:
	print("Mind control: a controlled crew is picked by neither side's former allies, and fights with its new side")
	var s := duel_ship(wr)
	var defender := s.crew[0]
	var boarder := s.add_crew("human", false, wr)
	boarder.place(s, wr, (defender.slot + 1) % s.graph.slot_count(wr))
	MindRule.set_mind(boarder, s, true)
	run(s, 3.0)
	check("controlled boarder: no longer an intruder aboard the player ship", boarder.is_intruder(s), false)
	check("  the player crew never targets it, it never targets them", [defender.target, boarder.target],
		[null, null])
	check("  nobody hurt", [defender.hp, boarder.hp], [defender.max_hp, boarder.max_hp])
	var other := s.add_crew("human", false, wr)
	other.place(s, wr, (defender.slot + 2) % s.graph.slot_count(wr))
	run(s, 0.5)
	check("a second (free) boarder: both the player crew and the controlled one target it",
		[defender.target, boarder.target], [other, other])
	MindRule.set_mind(boarder, s, false)
	other.hp = 0.0  # the free boarder dies: its attackers drop it (no longer ValidTarget)
	run(s, 0.5)
	check("released: enemies again", [defender.target, boarder.target], [boarder, defender])
	# Already fighting when the takeover happens: SetMindControl -> MoveToRoom clears the controlled crew's own
	# target, but nothing clears its attacker's crewTarget (CrewMember::OnLoop only drops a target that is no longer
	# ValidTarget / InsideRoom, and UpdateCrewmembers only re-targets from a non-empty list), so the attacker keeps
	# hitting it until it dies or leaves the room [exe].
	MindRule.set_mind(boarder, s, true)
	run(s, 0.5)
	check("taken over mid-fight: it stops attacking", boarder.target, null)
	check("  the crew already fighting it keeps its target (vanilla crewTarget is sticky)", defender.target, boarder)
	print("Mind control by the enemy: a player crew controlled aboard the enemy ship")
	var e := ShipState.new("PLAYER_SHIP_HARD", false)
	e.rng.seed = 4321
	e.crew.resize(1)
	var guard := e.crew[0]
	guard.place(e, wr, e.graph.find_slot(wr, guard))
	var raider := e.add_crew("human", true, wr)
	raider.place(e, wr, (guard.slot + 1) % e.graph.slot_count(wr))
	MindRule.set_mind(raider, e, true)
	run(e, 3.0)
	check("controlled player crew is on the enemy side there: no fight", [raider.is_intruder(e), guard.target,
		raider.target], [false, null, null])
	var raider2 := e.add_crew("human", true, wr)
	raider2.place(e, wr, (guard.slot + 2) % e.graph.slot_count(wr))
	run(e, 0.5)
	check("  it fights a free player boarder with the enemy crew", [guard.target, raider.target], [raider2, raider2])


func _crew_lasers(wr: int) -> void:
	print("Crew lasers (projectiles; damage when they land)")
	var s := duel_ship(wr)
	var defender: CrewMember = s.crew[0]
	var boarder := s.add_crew("human", false, wr)
	boarder.place(s, wr, (defender.slot + 1) % s.graph.slot_count(wr))
	step(s)
	boarder.stun = 100.0  # the boarder does not shoot back
	defender.shoot_timer = defender.shoot_goal  # fires on the next frame
	step(s)
	check("timer fired: one shot in flight", defender.shots.size(), 1)
	check("  shot sound counter", defender.shots_fired, 1)
	check("  no damage on spawn", boarder.hp, 100.0)
	var sh: Dictionary = defender.shots[0]
	var start := Vector2(floorf(defender.pos.x), floorf(defender.pos.y))
	near("  first step 10 x speed factor (160 px/s)", (sh.pos as Vector2).distance_to(start), 160.0 * DT, 0.01)
	var aim := CrewCombat.aim_point(s, boarder)
	check("  aimed within +-8 px of the target", absf(sh.to.x - aim.x) <= 8 and absf(sh.to.y - aim.y) <= 8, true)
	var dist := start.distance_to(sh.to)
	var frames := 1
	while sh.death < 0.0 and frames < 200:
		if frames == 2:
			check("  no damage while flying", boarder.hp, 100.0)
		step(s)
		frames += 1
	near("flight time = distance / 160 px/s", frames * DT, dist / 160.0, 2.0 * DT)
	check("  landed: hit animation, damage pending", defender.damage_done > 0.0 and boarder.hp == 100.0, true)
	var pending := defender.damage_done
	step(s)
	near("  damage dealt the next frame (3..7 x multipliers)", 100.0 - boarder.hp, pending * defender.hit_multiplier(), 0.001)
	check("  hit animation still shown", defender.shots.size(), 1)
	run(s, CrewCombat.SHOT_HIT_TIME)
	check("  removed after the 0.5 s hit animation", defender.shots.filter(func(x): return x.death >= 0.0).size(), 0)

	print("Pending damage waits for a target")
	defender.damage_done = 5.0
	var keep := defender.target
	defender.target = null
	CrewCombat.consume_damage(s, defender)
	check("no target: fDamageDone kept", defender.damage_done, 5.0)
	defender.target = keep
	var hp0 := boarder.hp
	CrewCombat.consume_damage(s, defender)
	near("target again: dealt", hp0 - boarder.hp, 5.0, 0.001)

	print("Out of range (> 22 px, other room): 0.1 hit, no laser")
	var other := room_without_system(s)
	var far: Vector2 = s.room_rect(other).get_center()
	defender.shots.clear()
	defender.damage_done = 0.0
	defender.shoot_timer = defender.shoot_goal + 1.0
	CrewCombat.shoot(s, defender, far, false, DT)
	check("no shot", defender.shots.size(), 0)
	near("fDamageDone 0.1", defender.damage_done, 0.1, 0.0001)

	print("Rock / mantis fire on shoot-animation frame 3 (1.0 s loop), others on the 1.0-1.3 s timer")
	for race in ["rock", "mantis", "human"]:
		s = duel_ship(wr)
		var shooter := s.add_crew(race, true, wr)
		s.crew[0].hp = 1000000.0  # a target that never dies
		s.crew[0].max_hp = 1000000.0
		s.crew[0].stun = 100.0
		var tgt: CrewMember = s.crew[0]
		tgt.player_owned = false  # the shooter's enemy, standing in its own (now "enemy") ship
		run(s, 10.0)
		if race == "human":
			between("human shots in 10 s", shooter.shots_fired, 7, 10)
		else:
			between("%s shots in 10 s (one per second)" % race, shooter.shots_fired, 9, 10)

	print("Firing frame (GetFiringFrame): 0 in line, else 1 / 2 by the aim side")
	check("right, level", CrewCombat.firing_frame(Vector2.ZERO, Vector2(10, 0)), 0)
	check("right, a bit up", CrewCombat.firing_frame(Vector2.ZERO, Vector2(10, -3)), 2)
	check("right, a bit down", CrewCombat.firing_frame(Vector2.ZERO, Vector2(10, 3)), 1)
	check("up, a bit right", CrewCombat.firing_frame(Vector2.ZERO, Vector2(3, -10)), 1)
	check("down, a bit right", CrewCombat.firing_frame(Vector2.ZERO, Vector2(3, 10)), 2)


func _run() -> void:
	print("Races (GetMaxHealth / GetDamageMultiplier / CanBurn / CanSuffocate)")
	check("human 100 HP", CrewMember.new("human").max_hp, 100.0)
	check("rock 150 HP", CrewMember.new("rock").max_hp, 150.0)
	check("crystal 125 HP", CrewMember.new("crystal").max_hp, 125.0)
	check("zoltan (energy) 70 HP", CrewMember.new("energy").max_hp, 70.0)
	check("mantis 100 HP", CrewMember.new("mantis").max_hp, 100.0)
	check("mantis damage x1.5", CrewMember.new("mantis").damage_mult(), 1.5)
	check("engi damage x0.5", CrewMember.new("engi").damage_mult(), 0.5)
	check("rock cannot burn", CrewMember.new("rock").can_burn(), false)
	check("lanius (anaerobic) cannot suffocate", CrewMember.new("anaerobic").can_suffocate(), false)
	check("crystal suffocates x0.5", CrewMember.new("crystal").suffocation_mult(), 0.5)

	print("Hit damage: 3..7 x race x combat skill")
	var h := CrewMember.new("human")
	near("human min", h.roll_hit(0.0), 3.0, 0.001)
	near("human max", h.roll_hit(1.0), 7.0, 0.001)
	near("mantis max", CrewMember.new("mantis").roll_hit(1.0), 10.5, 0.001)
	near("engi min", CrewMember.new("engi").roll_hit(0.0), 1.5, 0.001)
	h.skills.combat = 8
	near("combat level 2: x1.1", h.roll_hit(1.0), 7.7, 0.001)
	h.skills.combat = 16
	near("combat level 3: x1.2", h.roll_hit(1.0), 8.4, 0.001)

	print("Shooting duel (different tiles)")
	var s := kestrel()
	var wr := s.sys("weapons").room
	s = duel_ship(wr)
	var defender := s.crew[0]
	var boarder := s.add_crew("human", false, wr)
	boarder.place(s, wr, (defender.slot + 1) % s.graph.slot_count(wr))
	step(s)
	check("boarder is an intruder", boarder.is_intruder(s), true)
	check("defender targets the boarder", defender.target, boarder)
	check("boarder targets the defender", boarder.target, defender)
	check("not on the same tile: shooting", defender.shared_spot, false)
	check("fighting crew do not man (no weapons bonus)", s.crew_level_in("weapons"), 0)
	var r := hits_on(s, boarder, 30.0)
	between("hits on the boarder in 30 s (one per 1.0-1.3 s)", r[0], 22, 31)
	between("  mean damage per hit", r[1] / maxf(r[0], 1), 3.0, 7.0)

	_crew_lasers(wr)
	_mind_allegiance(wr)

	print("Punching (same tile)")
	s = duel_ship(wr)
	defender = s.crew[0]
	boarder = s.add_crew("human", false, wr)
	boarder.place(s, wr, defender.slot)  # intruder slots are separate: same tile allowed
	step(s)
	check("same tile: shared spot (punch)", defender.shared_spot, true)
	r = hits_on(s, boarder, 30.0)
	between("punches in 30 s (one per 1.0-1.3 s cycle)", r[0], 22, 31)

	print("Kills, skill, death")
	s = duel_ship(wr)
	defender = s.crew[0]
	boarder = s.add_crew("human", false, wr)
	boarder.hp = 2.0
	var t := time_until(s, func(): return not boarder.is_alive(), 5.0)
	# 1.0-1.3 s shoot timer + laser flight (160 px/s, < 0.4 s inside a room) + 1 frame.
	check("weak boarder killed within 1.7 s", t <= 1.7, true)
	check("defender gets +1 combat skill", defender.skills.combat, 1)
	run(s, 0.1)
	check("defender stops fighting", defender.fighting, false)
	check("dead boarder stays in the list, not alive", s.crew.has(boarder) and not boarder.is_alive(), true)
	check("its intruder slot is free again", s.graph.find_slot(wr, CrewMember.new("human", false)) >= 0, true)
	s = duel_ship(wr)
	defender = s.crew[0]
	defender.hp = 2.0
	boarder = s.add_crew("human", false, wr)
	time_until(s, func(): return not defender.is_alive(), 5.0)
	check("enemy kills do not give the enemy skill points", boarder.skills.combat, 0)

	print("Full fight: mantis vs human, engi vs human")
	var wins := 0
	for seed in 10:
		s = duel_ship(wr)
		s.rng.seed = seed
		boarder = s.add_crew("mantis", false, wr)
		time_until(s, func(): return not boarder.is_alive() or not s.crew[0].is_alive(), 120.0)
		if boarder.is_alive():
			wins += 1
	between("mantis boarder wins most of 10 duels", wins, 7, 10)
	wins = 0
	for seed in 10:
		s = duel_ship(wr)
		s.rng.seed = seed
		boarder = s.add_crew("engi", false, wr)
		time_until(s, func(): return not boarder.is_alive() or not s.crew[0].is_alive(), 120.0)
		if boarder.is_alive():
			wins += 1
	between("engi boarder wins few of 10 duels", wins, 0, 3)

	print("When crew fight")
	s = duel_ship(wr)
	s.hostile = false
	boarder = s.add_crew("human", false, wr)
	run(s, 3.0)
	check("ship not hostile: nobody fights", s.crew[0].fighting or boarder.fighting, false)
	check("  nobody hurt", s.crew[0].hp + boarder.hp, 200.0)
	s = duel_ship(wr)
	defender = s.crew[0]
	defender.stun = 10.0
	boarder = s.add_crew("human", false, wr)
	boarder.hp = 1.0
	run(s, 3.0)
	check("stunned crew deal no damage", boarder.hp, 1.0)
	var empty := room_without_system(s)
	s = duel_ship(empty)
	defender = s.crew[0]
	boarder = s.add_crew("human", false, wr)
	run(s, 2.0)
	check("different rooms: no fight", defender.fighting or boarder.fighting, false)

	print("Sabotage (8/s, one bar per 100, stacks, stops when fighting)")
	s = kestrel()
	var shr := s.sys("shields").room
	s.crew.clear()
	boarder = s.add_crew("human", false, shr)
	run(s, 12.4)
	check("after 12.4 s: no bar broken yet", s.sys("shields").damage, 0)
	check("  intruder is sabotaging", boarder.task, CrewMember.Task.SABOTAGE)
	run(s, 0.2)
	check("after 12.6 s: one bar broken", s.sys("shields").damage, 1)
	s = kestrel()
	s.crew.clear()
	s.add_crew("human", false, shr)
	s.add_crew("human", false, shr)
	run(s, 6.35)
	check("two saboteurs: one bar in 6.25 s", s.sys("shields").damage, 1)
	s = kestrel()
	s.crew.clear()
	boarder = s.add_crew("human", false, shr)
	s.sys("shields").damage = s.sys("shields").get_level() - 1
	run(s, 13.0)
	check("system completely destroyed", s.sys("shields").damage, s.sys("shields").get_level())
	check("  sabotage stops there", boarder.task, CrewMember.Task.NONE)
	s = kestrel()
	s.crew.resize(1)
	s.crew[0].place(s, shr, s.graph.find_slot(shr, s.crew[0]))
	boarder = s.add_crew("human", false, shr)
	run(s, 13.0)
	check("fighting intruder does not sabotage", s.sys("shields").damage, 0)
	s.damage_system("shields", 1)
	var prog := s.sys("shields").repair_progress
	run(s, 1.0)
	check("fighting defender does not repair", s.sys("shields").repair_progress, prog)

	print("Sabotage shots (status 7: crew lasers at the room centre; CrewMember::UpdateRepair throws the hit away)")
	s = kestrel()
	s.crew.clear()
	boarder = s.add_crew("human", false, shr)
	var landed := 0
	var discarded := 0
	var centre: Vector2 = s.room_rect(shr).get_center()
	var near_centre := true
	var ts := 0.0
	while ts < 6.0:
		var pending_before := boarder.damage_done
		step(s)
		ts += DT
		if pending_before > 0.0 and boarder.damage_done == 0.0:
			discarded += 1
		for sh in boarder.shots:
			if absf(sh.to.x - centre.x) > 8.0 or absf(sh.to.y - centre.y) > 8.0:
				near_centre = false
		if boarder.damage_done > 0.0:
			landed += 1
	check("saboteur fires crew lasers on the shoot timer", boarder.shots_fired >= 4, true)
	check("  aimed at the room centre (+-8 px jitter)", near_centre, true)
	check("  landed shots set fDamageDone (3..7) like any shot", landed > 0, true)
	check("  next frame the sabotage step takes it (no damage to anyone)", discarded, landed)
	check("  bars only from the 8/s sabotage: none after 6 s", s.sys("shields").damage, 0)
	# A value still pending when the saboteur gets a target is dealt to it (OnLoop combat step comes first).
	boarder.damage_done = 0.0
	var guard := 0
	while boarder.damage_done == 0.0 and guard < 600:
		step(s)
		guard += 1
	var pend := boarder.damage_done
	var victim := s.add_crew("human", true, shr)
	victim.place(s, shr, (boarder.slot + 1) % s.graph.slot_count(shr))
	boarder.target = victim
	boarder.fighting = true
	step(s)
	near("  pending sabotage hit carried into a new fight", 100.0 - victim.hp, pend * boarder.hit_multiplier(), 0.001)

	print("Intruder AI on the player ship (UpdateIntruders, goal: systems)")
	s = kestrel()
	var ai := CrewAI.new(s)
	var start := room_without_system(s)
	var b1 := s.add_crew("human", false, start)
	var b2 := s.add_crew("human", false, start)
	for k in 3:  # keep the defenders out of the way: no fighting in this test
		s.crew[k].hp = 0.0
	s.crew_changed()
	step(s, ai)
	check("boarders leave a room without a system", b1.target_room != start, true)
	check("  both go together", b1.target_room, b2.target_room)
	check("  to a room with a system", s.system_in_room(b1.target_room) != null, true)
	check("  the leader's task room is that room", b1.ai_task.room, b1.target_room)
	var dest := b1.target_room
	time_until(s, func(): return b1.room == dest and not b1.is_walking() and not b2.is_walking(), 20.0, ai)
	run(s, 1.0, ai)
	check("they sabotage there", b1.task == CrewMember.Task.SABOTAGE and b2.task == CrewMember.Task.SABOTAGE, true)
	var sd := s.system_in_room(dest)
	time_until(s, func(): return sd.damage >= sd.get_level(), 60.0, ai)
	run(s, 0.5, ai)
	check("system destroyed -> they move on", b1.target_room != dest, true)

	s = kestrel()
	ai = CrewAI.new(s)
	var pr := s.sys("pilot").room
	boarder = s.add_crew("human", false, pr)
	step(s, ai)
	check("defender in the room (doors powered): intruder stays (-10)", boarder.target_room, pr)
	check("  priority of its own room", ai.prioritize_intruder_room(boarder, pr, ai.intruder_list()), -10)

	print("Defenders on an enemy ship (CrewAI fight task)")
	var e := ShipState.new("REBEL_FAT", false)
	e.rng.seed = 7
	var eai := CrewAI.new(e)
	step(e, eai)
	var target_room := -1
	for rr in e.layout.rooms:
		if not has_airlock(e, rr.id) and e.system_in_room(rr.id) == null and eai.room_has_doors(rr.id):
			var occupied := false
			for c in e.crew:
				if c.room == rr.id:
					occupied = true
			if not occupied:
				target_room = rr.id
				break
	check("found an empty room without airlock", target_room >= 0, true)
	boarder = e.add_crew("human", true, target_room)
	boarder.hp = 30.0  # make sure the defenders win
	step(e, eai)
	check("count_boarders sees the player boarder", eai.count_boarders(target_room), 1)
	var fighters := e.crew.filter(func(c): return c.ai_task.id == CrewAI.FIGHT)
	check("one enemy crew takes the fight task", fighters.size(), 1)
	check("  and walks to the boarded room", fighters[0].target_room if fighters.size() > 0 else -1, target_room)
	check("player boarder is not moved by the enemy AI", eai.intruder_list().size(), 0)
	t = time_until(e, func(): return not boarder.is_alive() or not fighters[0].is_alive(), 120.0, eai)
	check("the fight ends within 120 s", t <= 120.0, true)
	print("    boarder alive: %s, fighter alive: %s, after %.1f s" % [boarder.is_alive(), fighters[0].is_alive(), t])
	if t > 120.0:
		for c in e.crew:
			print("    ", [c.race, c.room, c.target_room, c.slot, c.hp, c.fighting, c.ai_task, c.is_walking(), c.pos, c.is_on_slot(e)])
	run(e, 0.5, eai)
	check("fight task cleared afterwards", e.crew.filter(func(c): return c.ai_task.id == CrewAI.FIGHT).size(), 0)

	print("Doors vs intruders")
	s = kestrel()
	check("Kestrel doors level 1: no blast doors", s.env.door_blast(), 0)
	var di := -1
	for i in s.env.doors.size():
		if not s.env.doors[i].airlock:
			di = i
			break
	var d: Dictionary = s.env.doors[di]
	var probe := CrewMember.new("human", false)
	check("level 1: closed door not sealed for intruders", s.graph.is_sealed(d, probe), false)
	var ds := s.sys("doors")
	ds.override_level = 2
	ds.power = 2
	check("doors level 2: blast 1", s.env.door_blast(), 1)
	check("  sealed for intruders", s.graph.is_sealed(d, probe), true)
	check("  never for own crew", s.graph.is_sealed(d, s.crew[0]), false)
	step(s)
	check("  door health on normal: 8", d.health, 8)
	s.crew.clear()
	boarder = s.add_crew("human", false, d.left)
	boarder.move_to_room(s, d.right)
	t = time_until(s, func(): return boarder.blocking_door >= 0, 10.0)
	check("intruder stops at a closed blast door", boarder.blocking_door >= 0, true)
	di = maxi(boarder.blocking_door, 0)
	d = s.env.doors[di]
	t = time_until(s, func(): return d.forced > 0.0, 20.0)
	between("  breaks it in 8 hits (8..10.4 s)", t, 7.0, 10.6)
	check("  door is open while forced", d.open, true)
	s.env.set_door(di, false)
	check("  cannot be closed while forced", d.open, true)
	time_until(s, func(): return boarder.room == d.right, 5.0)
	check("  intruder gets through", boarder.room, d.right)
	run(s, 7.5)
	check("forced state lasts 7 s", d.forced, 0.0)
	s.env.set_door(di, false)
	check("  then it can be closed again", d.open, false)

	print("Fire / suffocation per race")
	s = kestrel()
	s.crew.clear()
	var rock := s.add_crew("rock", true, wr)
	var hum := s.add_crew("human", true, wr)
	s.ignite(wr, 0)
	s.ignite(wr, 1)
	s.env.oxygen[wr] = 100.0
	var hp_h := hum.hp
	s.env._tick_crew(1.0)
	check("rock takes no fire damage", rock.hp, 150.0)
	near("human takes 2 x 2.128 HP/s", hp_h - hum.hp, 4.256, 0.01)
	s = kestrel()
	s.crew.clear()
	var lan := s.add_crew("anaerobic", true, wr)
	var cry := s.add_crew("crystal", true, wr)
	s.env.oxygen[wr] = 0.0
	s.env._tick_crew(1.0)
	check("lanius does not suffocate", lan.hp, 100.0)
	near("crystal suffocates at half rate (3.2 HP/s)", 125.0 - cry.hp, 3.2, 0.01)


	print("Room O2 as drawn (Room::lastO2): 0 everywhere on a ship without an oxygen system")
	var an := ShipState.new("ANAEROBIC_SCOUT", false)
	check("ANAEROBIC_SCOUT has no oxygen system", an.sys("oxygen") == null, true)
	var r0: int = an.layout.rooms[0].id
	check("  every room reads 0 % (red floor + low-O2 stripes when visible)",
		an.layout.rooms.all(func(rm): return an.env.room_o2(rm.id) == 0.0), true)
	check("  the stored levels are not used for it", [an.env.oxygen.get(r0, -1.0) > 0.0, an.env.room_o2(r0)],
		[true, 0.0])
	var k := kestrel()
	k.env.oxygen[wr] = 37.0
	check("with an oxygen system: the room's level", k.env.room_o2(wr), 37.0)
