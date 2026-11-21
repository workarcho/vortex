extends Node
## Tests for rules/mind_control.md (mind control system, controlled crew, enemy AI). Run:
##   godot --headless --path godot res://tests/test_mind.tscn

const Harness := preload("res://tests/harness.gd")

const DT := 1.0 / 60.0

var fails := 0


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func near(name: String, got: float, want: float, tol := 0.05) -> void:
	check("%s ~= %.3f [%.3f]" % [name, want, got], absf(got - want) <= tol, true)


func space(ship: ShipState) -> Space:
	var sp := Space.new()
	add_child(sp)  # in the tree first: setup() makes its camera current
	sp.setup(ship)
	return sp


func make_combat(player: ShipState, enemy: ShipState) -> Combat:
	var cb := Combat.new()
	var ps := space(player)
	var es := space(enemy)
	cb.add_space(ps, es)
	cb.add_space(es, ps)
	return cb


func run_combat(cb: Combat, seconds: float) -> void:
	var t := 0.0
	while t < seconds - 1e-6:
		cb._physics_process(DT)
		t += DT


## TEST_SHIP_ALL with its mind system at `power` bars and a big reactor.
func mind_ship(power := 3, player := true) -> ShipState:
	var s := ShipState.new("TEST_SHIP_ALL", player)
	s.reactor_max = 60
	DroneSystemRule.set_drones(s, [])
	var m := s.sys("mind")
	while m.power < power and s.increase_power("mind") == "ok":
		pass
	while m.power > power and s.decrease_power("mind"):
		pass
	return s


func enemy() -> ShipState:
	var e := ShipState.new("REBEL_FAT", false)
	DroneSystemRule.set_drones(e, [])
	return e


## First living own crew of `ship` (not an intruder, not a drone).
func own(ship: ShipState) -> CrewMember:
	for c in ship.crew:
		if c.is_alive() and not c.is_intruder(ship) and not c.is_drone():
			return c
	return null


## Leaves only `c` aboard its ship (no fights: duration tests).
func isolate(ship: ShipState, c: CrewMember) -> void:
	for o in ship.crew.duplicate():
		if o != c:
			ship.crew.erase(o)
	ship.crew_changed()


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	test_tables()
	test_control_enemy()
	test_levels()
	test_slug_and_filters()
	test_super_shield()
	test_free_own_crew()
	test_hacked_mind()
	test_ai()
	test_jump_and_destroyed()


func test_tables() -> void:
	print("Tables")
	check("duration 14/20/28 s", MindRule.TIMER.slice(1), [14.0, 20.0, 28.0])
	check("HP boost 0/15/30", MindRule.HEALTH_BOOST.slice(1), [0.0, 15.0, 30.0])
	check("damage x1/x1.25/x2", MindRule.DAMAGE_BOOST.slice(1), [1.0, 1.25, 2.0])
	check("one target at every level", MindRule.COUNT.slice(1), [1, 1, 1])
	var c := CrewMember.new("human", true)
	c.set_health_boost(30.0)
	check("boost raises hp and max", [c.hp, c.max_hp], [130.0, 130.0])
	c.hp = 120.0
	c.set_health_boost(15.0)
	check("lower boost: max drops, hp clamped", [c.hp, c.max_hp], [115.0, 115.0])
	c.set_health_boost(0.0)
	check("boost removed", [c.hp, c.max_hp], [100.0, 100.0])


func test_control_enemy() -> void:
	print("\nControl an enemy crew (level 3)")
	var p := mind_ship(3)
	var e := enemy()
	var cb := make_combat(p, e)
	run_combat(cb, DT)
	var target := own(e)
	var room := target.room
	check("bCanUse: hostile target with crew", p.mind_can_use, true)
	check("arm", MindRule.arm(p), "ok")
	check("armed click on the enemy room", MindRule.room_clicked(p, e, room), true)
	check("disarmed after the click", p.mind_armed, false)
	var others := e.crew.filter(func(c): return c.is_alive() and c.room == room and not c.is_intruder(e))
	run_combat(cb, DT)
	var ctl := e.crew.filter(func(c): return c.mind_controlled)
	check("one crew of that room controlled", [ctl.size(), p.mind_list.size()], [1, 1])
	var c: CrewMember = ctl[0] if not ctl.is_empty() else target
	check("it was in the clicked room", others.has(c), true)
	check("in use, mind locked indefinitely", [p.mind_in_use, p.sys("mind").ion], [true, -1])
	check("owner unchanged, now an intruder on its own ship", [c.player_owned, c.is_intruder(e)], [false, true])
	check("level 3 boosts: +30 HP, x2 damage", [c.max_hp, c.mind_damage_boost], [130.0, 2.0])
	check("not player-controllable", CrewControl.controllable(c), false)
	check("enemy crew AI drives it as an intruder", cb.crew_ais.values()[1].intruder_list().has(c), true)
	run_combat(cb, 3.0)
	check("it fights its own crew (or sabotages)", c.fighting or c.task == CrewMember.Task.SABOTAGE \
		or c.is_walking() or e.crew.any(func(o): return o.target == c), true)
	c.hp = c.max_hp
	isolate(e, c)
	run_combat(cb, 24.5)
	check("still controlled before 28 s", [c.mind_controlled, p.mind_in_use], [true, true])
	var t := 0.0
	while t < 1.0 and p.mind_in_use:
		cb._physics_process(DT)
		t += DT
	check("released after 28 s", [p.mind_in_use, c.mind_controlled], [false, false])
	check("cooldown 20 s (4 locks)", p.sys("mind").ion, MindRule.LOCK)
	check("boost gone, back on its side", [c.max_hp, c.mind_damage_boost, c.is_intruder(e)], [100.0, 1.0, false])
	check("cannot arm on cooldown", MindRule.arm(p), "no")


func test_levels() -> void:
	print("\nLevels and power changes")
	for lvl in [1, 2]:
		var p := mind_ship(lvl)
		var e := enemy()
		var cb := make_combat(p, e)
		run_combat(cb, DT)
		MindRule.arm(p)
		MindRule.room_clicked(p, e, own(e).room)
		run_combat(cb, DT)
		var c: CrewMember = p.mind_list[0] if not p.mind_list.is_empty() else null
		if c:
			isolate(e, c)
		check("level %d: duration" % lvl, p.mind_duration, MindRule.TIMER[lvl])
		check("level %d: boost" % lvl, [c.max_hp, c.mind_damage_boost] if c else [],
			[100.0 + MindRule.HEALTH_BOOST[lvl], MindRule.DAMAGE_BOOST[lvl]])
		run_combat(cb, MindRule.TIMER[lvl] - 1.0)
		check("level %d: still in use 1 s before the end" % lvl, p.mind_in_use, true)
		run_combat(cb, 1.2)
		check("level %d: released" % lvl, p.mind_in_use, false)
	# Power drop mid-use: the shorter duration ends it at once (elapsed keeps counting).
	var p := mind_ship(3)
	var e := enemy()
	var cb := make_combat(p, e)
	run_combat(cb, DT)
	MindRule.arm(p)
	MindRule.room_clicked(p, e, own(e).room)
	run_combat(cb, DT)
	isolate(e, p.mind_list[0])
	run_combat(cb, 16.0)
	check("in use at 16 s (level 3)", p.mind_in_use, true)
	p.damage_system("mind", 2)  # power 3 -> 1: 14 s
	run_combat(cb, 0.1)
	check("power down to 1: 16 s > 14 s -> released", p.mind_in_use, false)
	# A controlled crew dying ends it with the cooldown.
	var p2 := mind_ship(3)
	var e2 := enemy()
	var cb2 := make_combat(p2, e2)
	run_combat(cb2, DT)
	MindRule.arm(p2)
	MindRule.room_clicked(p2, e2, own(e2).room)
	run_combat(cb2, DT)
	p2.mind_list[0].hp = 0.0
	run_combat(cb2, 0.1)
	check("controlled crew died: released, 20 s cooldown", [p2.mind_in_use, p2.sys("mind").ion],
		[false, MindRule.LOCK])


func test_slug_and_filters() -> void:
	print("\nSlugs resist; queue filters")
	var p := mind_ship(3)
	var e := enemy()
	var cb := make_combat(p, e)
	run_combat(cb, DT)
	var room: int = own(e).room
	for c in e.crew.filter(func(c): return c.room == room):
		c.race = "slug"
	MindRule.arm(p)
	MindRule.room_clicked(p, e, room)
	run_combat(cb, DT)
	check("only Slugs: nothing happens, no cooldown, no resisted", [p.mind_in_use, p.sys("mind").ion,
		e.crew.any(func(c): return c.resisted > 0.0)], [false, 0, false])
	# Slug + human in the same room: the human is controlled, the Slug resists.
	var h := e.add_crew("human", false, room)
	MindRule.arm(p)
	MindRule.room_clicked(p, e, room)
	run_combat(cb, DT)
	check("human controlled", h != null and h.mind_controlled, true)
	check("slug resisted", e.crew.any(func(c): return c.race == "slug" and c.resisted > 0.0), true)
	# Own crew that are not controlled are never targets; drones never.
	var p2 := mind_ship(3)
	var e2 := enemy()
	var cb2 := make_combat(p2, e2)
	run_combat(cb2, DT)
	var mine := own(p2)
	MindRule.queue_room(p2, p2, mine.room)
	run_combat(cb2, DT)
	check("own (not controlled) crew filtered out", [mine.mind_controlled, p2.mind_in_use], [false, false])
	# Intruders aboard: usable against them.
	var b := p2.add_crew("human", false, -1)
	run_combat(cb2, DT)
	check("intruder aboard -> usable", p2.mind_can_use, true)
	MindRule.arm(p2)
	MindRule.room_clicked(p2, p2, b.room)
	run_combat(cb2, DT)
	check("intruder controlled: a friend aboard the player ship", [b.mind_controlled, b.is_intruder(p2)], [true, false])


func test_super_shield() -> void:
	print("\nSuper shields block")
	var p := mind_ship(3)
	var e := enemy()
	var cb := make_combat(p, e)
	e.super_shield = 2
	run_combat(cb, DT)
	check("bBlocked", p.mind_blocked, true)
	check("arming warns (SUPER SHIELDS)", MindRule.arm(p), "blocked")
	MindRule.queue_room(p, e, own(e).room)
	run_combat(cb, DT)
	check("crew on a super-shielded ship are dropped", p.mind_in_use, false)


func test_free_own_crew() -> void:
	print("\nFreeing own crew controlled by the enemy")
	var p := mind_ship(3)
	var e := mind_ship(3, false)
	var cb := make_combat(p, e)
	run_combat(cb, DT)
	var mine := own(p)
	MindRule.queue_room(e, p, mine.room)
	run_combat(cb, DT)
	var victim: CrewMember = e.mind_list[0] if not e.mind_list.is_empty() else null
	check("enemy controls a player crew", victim != null and victim.player_owned and victim.mind_controlled, true)
	check("player crew controlled: intruder on its own ship", victim.is_intruder(p) if victim else false, true)
	check("removed from the player's selection", CrewControl.controllable(victim) if victim else true, false)
	check("cannot teleport", TeleporterRule.can_teleport(p, victim) if victim else true, false)
	check("player crew AI drives it as an intruder", cb.crew_ais.values()[0].intruder_list().has(victim), true)
	check("player can use mind control (intruder aboard)", p.mind_can_use, true)
	MindRule.arm(p)
	MindRule.room_clicked(p, p, victim.room)
	run_combat(cb, DT)
	check("freed by the player's mind control", victim.mind_controlled, false)
	run_combat(cb, 0.1)
	check("both systems on cooldown", [p.sys("mind").ion, e.sys("mind").ion, p.mind_in_use, e.mind_in_use],
		[MindRule.LOCK, MindRule.LOCK, false, false])


func test_hacked_mind() -> void:
	print("\nHacked mind system: used by the hacker against its own crew")
	var p := mind_ship(3)
	var e := mind_ship(3, false)
	var cb := make_combat(p, e)
	run_combat(cb, DT)
	MindRule.arm(e)
	MindRule.queue_room(e, p, own(p).room)
	run_combat(cb, DT)
	check("enemy in use", e.mind_in_use, true)
	e.sys("mind").hacked = true
	run_combat(cb, DT)
	check("entering the pulse releases (no cooldown, usable by the hacker)", [e.mind_in_use, e.sys("mind").ion],
		[false, 0])
	check("hacked level = undamaged bars", MindRule.level(e), 3)
	var ec := own(e)
	MindRule.queue_room(e, e, ec.room)
	run_combat(cb, DT)
	check("sides swapped: the enemy system controls its own crew",
		e.mind_list.size() == 1 and not e.mind_list[0].player_owned, true)
	# The player's mind system while hacked: the player-ship AI part uses it on the player's crew.
	var p2 := mind_ship(3)
	var e2 := enemy()
	var cb2 := make_combat(p2, e2)
	p2.sys("mind").hacked = true
	run_combat(cb2, 0.2)
	check("hacked player mind system controls a player crew",
		p2.mind_list.size() == 1 and p2.mind_list[0].player_owned, true)
	p2.sys("mind").hacked = false
	run_combat(cb2, DT)
	check("pulse over: released with the cooldown", [p2.mind_in_use, p2.sys("mind").ion], [false, MindRule.LOCK])


func test_ai() -> void:
	print("\nEnemy AI (CombatAI::UpdateMindControl)")
	var p := ShipState.new("PLAYER_SHIP_HARD", true)
	var e := mind_ship(3, false)
	var cb := make_combat(p, e)
	var t := 0.0
	while t < 5.0 and not e.mind_in_use:
		cb._physics_process(DT)
		t += DT
	check("enemy mind-controls a player crew as soon as it can", e.mind_in_use, true)
	check("  a player crew", not e.mind_list.is_empty() and e.mind_list[0].player_owned, true)
	var ai: ShipAI = cb.ais.values()[0]
	ai.hostile = false
	run_combat(cb, DT)
	check("not hostile: released", e.mind_in_use, false)


func test_jump_and_destroyed() -> void:
	print("\nJump / destroyed")
	var p := mind_ship(3)
	var e := enemy()
	var cb := make_combat(p, e)
	run_combat(cb, DT)
	MindRule.arm(p)
	MindRule.room_clicked(p, e, own(e).room)
	run_combat(cb, DT)
	MindRule.jump(p)
	check("jump: released, no cooldown", [p.mind_in_use, p.sys("mind").ion, e.crew.any(func(c): return c.mind_controlled)],
		[false, 0, false])
	MindRule.arm(p)
	MindRule.room_clicked(p, e, own(e).room)
	run_combat(cb, DT)
	p.hull = 0
	run_combat(cb, DT)
	check("own ship destroyed: released", p.mind_in_use, false)
