extends Node
## Tests for rules/medbay.md (heal rates, who is healed, hacking, blocked slot, AI healing trips). Run:
##   godot --headless --path godot res://tests/test_medbay.tscn

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


func step(s: ShipState) -> void:
	s.tick(DT * GameClock.BASE)


func run(s: ShipState, seconds: float) -> void:
	var t := 0.0
	while t < seconds - 1e-6:
		step(s)
		t += DT


## Kestrel with its medbay at `power` bars (level raised if needed).
func kestrel(power := 1) -> ShipState:
	var s := ShipState.new("PLAYER_SHIP_HARD", true)
	var m := s.sys("medbay")
	m.override_level = maxi(m.level, power)
	m.power = power
	m.user_power = power
	return s


func medbay_room(s: ShipState) -> int:
	return s.sys("medbay").room


## Moves crew i onto a free slot of the medbay room (teleport, no walking).
func put_in_medbay(s: ShipState, i: int) -> CrewMember:
	var c := s.crew[i]
	c.place(s, medbay_room(s), s.graph.find_slot(medbay_room(s), c))
	return c


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	print("Healing speed per power (MedbaySystem::GetHealingSpeed x 0.4 x 16)")
	near("1 bar: 6.4 HP/s", MedbayRule.hp_per_second(1, false), 6.4, 0.001)
	near("2 bars: 9.6 HP/s", MedbayRule.hp_per_second(2, false), 9.6, 0.001)
	near("3 bars: 19.2 HP/s", MedbayRule.hp_per_second(3, false), 19.2, 0.001)
	near("hacked: -12.8 HP/s", MedbayRule.hp_per_second(3, true), -12.8, 0.001)
	near("hacked even unpowered", MedbayRule.hp_per_second(0, true), -12.8, 0.001)

	print("Healing in the Kestrel medbay")
	var s := kestrel(1)
	var c := put_in_medbay(s, 0)
	c.hp = 50.0
	run(s, 1.0)
	near("level 1: +6.4 HP in 1 s", c.hp, 56.4, 0.15)
	s = kestrel(2)
	c = put_in_medbay(s, 0)
	c.hp = 50.0
	run(s, 1.0)
	near("level 2: +9.6 HP in 1 s", c.hp, 59.6, 0.2)
	s = kestrel(3)
	c = put_in_medbay(s, 0)
	c.hp = 20.0
	run(s, 1.0)
	near("level 3: +19.2 HP in 1 s", c.hp, 39.2, 0.4)
	run(s, 10.0)
	check("never above max HP", c.hp, c.max_hp)

	s = kestrel(1)
	var a := put_in_medbay(s, 0)
	var b := put_in_medbay(s, 1)
	a.hp = 40.0
	b.hp = 60.0
	run(s, 2.0)
	near("every crew in the room heals (A)", a.hp, 52.8, 0.3)
	near("  at the full rate each (B)", b.hp, 72.8, 0.3)
	check("  A and B on different slots", a.slot != b.slot, true)

	s = kestrel(1)
	s.sys("medbay").power = 0
	c = put_in_medbay(s, 0)
	c.hp = 50.0
	run(s, 2.0)
	check("unpowered medbay: no healing", c.hp, 50.0)

	s = kestrel(1)
	s.sys("medbay").damage = 1
	s._check_max_power(s.sys("medbay"))
	c = put_in_medbay(s, 0)
	c.hp = 50.0
	run(s, 2.0)
	check("broken medbay (no power left): no healing", c.hp, 50.0)

	s = kestrel(1)
	c = s.crew[2]
	c.hp = 50.0
	run(s, 2.0)
	check("crew outside the medbay: no healing", c.hp, 50.0)

	print("Hacked medbay")
	s = kestrel(1)
	s.sys("medbay").hacked = true
	c = put_in_medbay(s, 0)
	run(s, 1.0)
	near("full-health crew loses 12.8 HP in 1 s", c.hp, 87.2, 0.3)
	s = kestrel(1)
	s.sys("medbay").power = 0
	s.sys("medbay").hacked = true
	c = put_in_medbay(s, 0)
	run(s, 1.0)
	near("  also when unpowered", c.hp, 87.2, 0.3)

	print("Intruders")
	s = kestrel(1)
	var boarder := s.add_crew("human", false, medbay_room(s))
	check("boarder placed in the medbay", boarder != null and boarder.room == medbay_room(s), true)
	boarder.hp = 50.0
	s.hostile = false  # no fighting, to isolate healing
	run(s, 2.0)
	check("intruder in the medbay: not healed", boarder.hp, 50.0)
	s = kestrel(1)
	s.sys("medbay").hacked = true
	boarder = s.add_crew("human", false, medbay_room(s))
	s.hostile = false
	run(s, 1.0)
	check("intruder in a hacked medbay: not hurt", boarder.hp, 100.0)

	print("Healing while fighting")
	s = kestrel(1)
	c = put_in_medbay(s, 0)
	c.hp = 50.0
	boarder = s.add_crew("human", false, medbay_room(s))
	step(s)
	check("defender is fighting", c.fighting, true)
	near("  and still gets the heal rate", c.medbay_rate, 6.4, 0.001)
	s = kestrel(1)
	c = put_in_medbay(s, 0)
	boarder = s.add_crew("human", false, medbay_room(s))
	step(s)
	step(s)  # the rate is set before targets are chosen (same order as UpdateCrewmembers)
	near("full-health crew fighting: heal rate kept (CanHeal)", c.medbay_rate, 6.4, 0.001)
	s = kestrel(1)
	c = put_in_medbay(s, 0)
	step(s)
	check("full-health crew, nothing going on: rate 0", c.medbay_rate, 0.0)

	print("Blocked medbay tile")
	s = kestrel(1)
	var blocked := s.graph.blocked_slot(medbay_room(s))
	check("Kestrel medbay has a blocked tile", blocked >= 0, true)
	var slots := []
	for i in 3:
		var k := s.crew[i]
		var sl := s.graph.find_slot(medbay_room(s), k)
		k.place(s, medbay_room(s), sl)
		slots.append(sl)
	check("3 crew fill the 4-tile medbay without the blocked tile", slots.has(blocked), false)
	check("  the room is now full for own crew", s.graph.find_slot(medbay_room(s), s.add_crew("human", true, 0)), -1)

	print("Enemy AI healing trip (MANTIS_FIGHTER)")
	var e := ShipState.new("MANTIS_FIGHTER", false)
	var ai := CrewAI.new(e)
	e.tick(DT * GameClock.BASE)
	ai.tick()
	var hurt := e.crew[2]
	hurt.hp = 20.0
	var t := 0.0
	while t < 30.0 and hurt.hp < 99.0:
		e.tick(DT * GameClock.BASE)
		ai.tick()
		t += DT
	check("hurt crew healed to >= 99 HP within 30 s", hurt.hp >= 99.0, true)
	check("  it is in the medbay", hurt.room, e.sys("medbay").room)
	var walk_heal := t
	print("    (walk + heal took %.1f s)" % walk_heal)
	var t2 := 0.0
	while t2 < 20.0 and hurt.ai_task.id == CrewAI.HEAL:
		e.tick(DT * GameClock.BASE)
		ai.tick()
		t2 += DT
	check("  healing task ends once healed", hurt.ai_task.id != CrewAI.HEAL, true)

