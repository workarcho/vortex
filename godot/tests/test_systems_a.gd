extends Node
## Tests for the startup power-up and the "systems A" rules: rules/power.md "Startup power-up",
## rules/battery.md, rules/cloaking.md, rules/teleporter.md, rules/artillery.md, rules/clonebay.md. Run:
##   godot --headless --path godot res://tests/test_systems_a.tscn

const Harness := preload("res://tests/harness.gd")

const DT := 1.0 / 60.0
const F := DT * GameClock.BASE

var fails := 0


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func near(name: String, got: float, want: float, tol := 0.05) -> void:
	check("%s ~= %.2f [%.3f]" % [name, want, got], absf(got - want) <= tol, true)


func run(s: ShipState, seconds: float) -> void:
	var t := 0.0
	while t < seconds - 1e-6:
		s.tick(F)
		t += DT


func space(ship: ShipState) -> Space:
	var sp := Space.new()
	add_child(sp)  # in the tree first: setup() makes its camera current
	sp.setup(ship)
	return sp


## Combat with two spaces (not in the tree: stepped by hand).
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


func set_power(s: ShipState, id: String, n: int) -> void:
	while s.sys(id).power > n and s.decrease_power(id):
		pass
	while s.sys(id).power < n and s.increase_power(id) == "ok":
		pass


func powers(s: ShipState, ids: Array) -> Array:
	return ids.map(func(id): return s.sys(id).power)


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	test_startup()
	test_battery()
	test_cloaking()
	test_teleporter()
	test_artillery()
	test_clonebay()


# ------------------------------------------------------------ startup power

func test_startup() -> void:
	print("Startup power-up (blueprint order; player 1 bar, shields full, weapons 0; enemy full)")
	var k := ShipState.new("PLAYER_SHIP_HARD", true)
	check("Kestrel shields / engines / medbay / oxygen", powers(k, ["shields", "engines", "medbay", "oxygen"]),
		[2, 1, 1, 1])
	check("Kestrel weapons 0, no weapon powered", [k.sys("weapons").power,
		k.weapons.filter(func(w): return w.powered).size()], [0, 0])
	check("Kestrel reactor 5 of 8 used (3 free for the weapons)", k.reactor_used(), 5)
	check("Kestrel shield layers charged", k.shield_layers, 1)
	var t := ShipState.new("TEST_SHIP_ALL", true)
	check("test ship: shields full 4, others 1, weapons/drones 0",
		powers(t, ["shields", "engines", "oxygen", "weapons", "drones", "medbay", "teleporter", "cloaking",
			"artillery", "mind", "hacking"]), [4, 1, 1, 0, 0, 1, 1, 1, 1, 1, 1])
	check("test ship reactor used 12 of 25", t.reactor_used(), 12)
	var e := ShipState.new("TEST_SHIP_ALL", false)
	check("enemy: full levels in blueprint order until the reactor (25) runs out",
		powers(e, ["shields", "engines", "oxygen", "weapons", "drones", "medbay", "teleporter", "cloaking",
			"artillery", "mind", "hacking"]), [4, 4, 3, 0, 0, 3, 3, 3, 4, 1, 0])
	check("enemy user_power = startup power", e.sys("engines").user_power, 4)


# ------------------------------------------------------------ battery

func full_reactor_ship() -> ShipState:
	var s := ShipState.new("TEST_SHIP_ALL", true)
	s.reactor_max = s.reactor_used()  # nothing free
	return s


func test_battery() -> void:
	print("\nBattery (rules/battery.md)")
	var s := full_reactor_ship()
	var b := s.sys("battery")
	check("subsystem: power = level 2 without reactor", b.effective_power(), 2)
	check("reactor full: engines + refused", s.increase_power("engines"), "reactor")
	check("ready", BatteryRule.ready(s), true)
	check("turn on", BatteryRule.turn_on(s), true)
	check("  4 extra bars (2 x power 2)", s.battery_cap, 4)
	check("  indefinite lock (-1) while on", b.ion, -1)
	check("  white lock frame", FtlColors.lock_outline(b), Color.WHITE)
	check("  second turn on refused", BatteryRule.turn_on(s), false)
	check("engines + takes a battery bar", s.increase_power("engines"), "ok")
	var en := s.sys("engines")
	check("  engines power 2, 1 from the battery", [en.power, en.battery], [2, 1])
	check("  top bar drawn as a battery bar", en.bar_state(1), "battery")
	check("  bottom bar normal", en.bar_state(0), "on")
	s.increase_power("engines")
	s.increase_power("engines")
	check("engines 4: 3 battery bars, battery 3/4", [en.battery, s.battery_used()], [3, 3])
	s.decrease_power("engines")
	check("engines - frees a battery bar first", [en.power, en.battery], [3, 2])
	run(s, 29.9)
	check("still on at 29.9 s", b.turned_on, true)
	run(s, 0.2)
	check("off after 30 s", [b.turned_on, s.battery_cap, s.battery_used()], [false, 0, 0])
	check("  engines back to its reactor bar", en.power, 1)
	check("  cooldown lock 4 units", b.ion, 4)
	near("  cooldown 20 s", b.lock_remaining(), 20.0, 0.1)
	run(s, 19.8)
	check("  still locked at 19.8 s", BatteryRule.ready(s), false)
	run(s, 0.3)
	check("  ready after 20 s", BatteryRule.ready(s), true)

	s = full_reactor_ship()
	s.augments.append("BATTERY_BOOSTER")
	BatteryRule.turn_on(s)
	run(s, 30.1)
	check("BATTERY_BOOSTER: cooldown 2 units (10 s)", s.sys("battery").ion, 2)

	print("Battery end: CheckForRepower, shields in pairs, weapons, damage, jump")
	s = full_reactor_ship()
	BatteryRule.turn_on(s)
	s.increase_power("cloaking")
	check("cloaking 2 (1 battery bar)", [s.sys("cloaking").power, s.sys("cloaking").battery], [2, 1])
	s.decrease_power("medbay")  # frees a reactor bar
	run(s, 30.1)
	check("battery ended: cloaking re-powered from the freed reactor bar", [s.sys("cloaking").power,
		s.sys("cloaking").battery], [2, 0])

	s = full_reactor_ship()
	set_power(s, "shields", 2)
	s.reactor_max = s.reactor_used()
	BatteryRule.turn_on(s)
	s.increase_power("shields")
	check("shields 4 with 2 battery bars", [s.sys("shields").power, s.sys("shields").battery], [4, 2])
	run(s, 30.1)
	check("battery ended: shields lose the whole layer", [s.sys("shields").power, s.max_shield_layers()], [2, 1])

	s = full_reactor_ship()
	BatteryRule.turn_on(s)
	check("weapon powered from the battery", s.try_power_weapon(s.weapons[0]), "ok")
	check("  weapons bars from the battery", s.sys("weapons").battery, s.weapons[0].power_cost())
	run(s, 30.1)
	check("battery ended: weapon depowered (reactor full)", s.weapons[0].powered, false)
	check("  weapons power 0", s.sys("weapons").power, 0)

	s = full_reactor_ship()
	BatteryRule.turn_on(s)
	for i in 3:
		s.increase_power("engines")
	s.damage_system("battery", 1)
	run(s, DT)
	check("battery damaged to 1 while on: pool 2, 1 random bar removed", [s.battery_cap, s.battery_used()], [2, 2])
	s.damage_system("battery", 1)
	run(s, DT)
	check("battery destroyed: off, all battery bars gone", [s.sys("battery").turned_on, s.battery_used()],
		[false, 0])

	s = full_reactor_ship()
	BatteryRule.turn_on(s)
	run(s, 1.0)
	BatteryRule.jump(s)
	check("jump: off and immediately ready", [s.sys("battery").turned_on, BatteryRule.ready(s)], [false, true])

	s = full_reactor_ship()
	s.sys("battery").hacked = true
	run(s, DT)
	check("actively hacked battery: reactor -2", s.reactor_capacity(), s.reactor_max - 2)
	check("  reactor overuse removed bars until it fits", s.reactor_free() >= 0, true)

	var ai_ship := ShipState.new("TEST_SHIP_ALL", false)
	var ai := ShipAI.new(ai_ship, RandomNumberGenerator.new())
	ai.target = ShipState.new("PLAYER_SHIP_HARD", true)
	ai.tick(DT)
	check("enemy AI switches the battery on", ai_ship.sys("battery").turned_on, true)
	check("  and uses its bars once the reactor is full", ai_ship.battery_used() > 0, true)
	check("  reactor never over-used", ai_ship.reactor_free() >= 0, true)


# ------------------------------------------------------------ cloaking

func cloak_ship(power: int) -> ShipState:
	var s := ShipState.new("TEST_SHIP_ALL", true)
	s.reactor_max = 40
	set_power(s, "cloaking", power)
	return s


func test_cloaking() -> void:
	print("\nCloaking (rules/cloaking.md)")
	for p in [1, 2, 3]:
		var s := cloak_ship(p)
		var c := s.sys("cloaking")
		var before := s.dodge_factor()
		check("power %d: on" % p, CloakRule.turn_on(s), true)
		check("  duration %d s" % (5 * p), c.timer_goal, 5.0 * p)
		check("  evasion +60", s.dodge_factor() - before, 60)
		check("  locked indefinitely (power bars frozen)", [c.ion, s.decrease_power("cloaking")], [-1, false])
		run(s, 5.0 * p - 0.1)
		check("  still cloaked just before the end", s.is_cloaked(), true)
		run(s, 0.2)
		check("  decloaked after %d s" % (5 * p), s.is_cloaked(), false)
		near("  cooldown 20 s", c.lock_remaining(), 20.0, 0.2)
		check("  refused while cooling down", CloakRule.turn_on(s), false)
	var s := cloak_ship(3)
	CloakRule.turn_on(s)
	run(s, 10.0)
	s.damage_system("cloaking", 1)
	run(s, DT)
	check("3 power, 10 s used, 1 bar lost -> goal 10 s", s.sys("cloaking").timer_goal, 10.0)
	near("  elapsed rescaled to 6.67 s", s.sys("cloaking").timer, 6.67 + DT, 0.05)

	s = cloak_ship(3)
	CloakRule.turn_on(s)
	CloakRule.fired_weapon(s)
	near("a volley burns 20 % (3 s of 15)", s.sys("cloaking").timer, 3.0, 0.001)
	s = cloak_ship(3)
	s.augments.append("CLOAK_FIRE")
	CloakRule.turn_on(s)
	CloakRule.fired_weapon(s)
	check("CLOAK_FIRE: no cost", s.sys("cloaking").timer, 0.0)

	s = cloak_ship(3)
	CloakRule.turn_on(s)
	s.ion_system("cloaking", 1)
	run(s, DT)
	check("ion while cloaked: lock -1 replaced by 1, power 2, still on", [s.sys("cloaking").ion,
		s.sys("cloaking").power, s.is_cloaked()], [1, 2, true])
	check("  goal follows the power (10 s)", s.sys("cloaking").timer_goal, 10.0)

	print("Cloak visuals (Ship::OnRenderBase)")
	s = cloak_ship(3)
	CloakRule.turn_on(s)
	check("hull alpha at the start of the fade", s.cloak_alpha(), 0.75)
	run(s, 0.25)
	near("  half way (0.25 s)", s.cloak_alpha(), 0.5625, 0.01)
	run(s, 0.3)
	near("  faded (0.5 s): 0.375", s.cloak_alpha(), 0.375, 0.001)
	check("  overlay alpha 1", s.cloak_overlay_alpha(), 1.0)
	check("  rooms / doors / weapons alpha 0.5 (GetCloakAlpha(false))", s.cloak_interior_alpha(), 0.5)
	CloakRule.turn_off(s)
	check("decloak: hull alpha 1.0 at once", s.cloak_alpha(), 1.0)
	run(s, 0.25)
	near("  overlay fades out (0.5 at 0.25 s)", s.cloak_overlay_alpha(), 0.5, 0.05)
	near("  rooms fade back (0.75 at 0.25 s)", s.cloak_interior_alpha(), 0.75, 0.03)
	run(s, 0.3)
	check("  rooms opaque again after 0.5 s", s.cloak_interior_alpha(), 1.0)
	var stealth2 := FtlData.ship_blueprint("PLAYER_SHIP_STEALTH_2")
	check("<cloakImage> override: STEALTH_2 uses stealth_cloak.png", stealth2.get("cloak_img"), "stealth")
	check("cloak_img defaults to img", FtlData.ship_blueprint("PLAYER_SHIP_HARD").get("cloak_img"), "kestral")
	check("layout <cloak> offset (stealth: -10, -10)", FtlData.ship_layout("stealth").get("cloak_offset"),
		Vector2(-10, -10))

	print("Weapons targeting a cloaked ship do not charge")
	var a := ShipState.new("PLAYER_SHIP_HARD", true)
	var e := cloak_ship(3)
	a.opponent = e
	a.reactor_max = 20
	a.try_power_weapon(a.weapons[0])
	run(a, 1.0)
	var ch := a.weapons[0].charge
	CloakRule.turn_on(e)
	run(a, 2.0)
	check("charge frozen while the target cloaks", a.weapons[0].charge, ch)
	a.depower_weapon(a.weapons[0])
	run(a, 1.0)
	check("  no decay either (unpowered)", a.weapons[0].charge, ch)
	CloakRule.turn_off(e)
	a.try_power_weapon(a.weapons[0])
	run(a, 1.0)
	near("  charges again after the decloak", a.weapons[0].charge, ch + 1.0, 0.05)

	print("Enemy AI and cloaking (combat_ai.md section 6)")
	var es := ShipState.new("TEST_SHIP_ALL", false)
	var ai := ShipAI.new(es, RandomNumberGenerator.new())
	var player := ShipState.new("PLAYER_SHIP_HARD", true)
	ai.target = player
	ai.tick(DT)
	check("AI cloaks as soon as it can (power 3 -> 15 s)", [es.is_cloaked(), es.sys("cloaking").timer_goal],
		[true, 15.0])
	check("  keeps its cloaking bars (locked)", es.sys("cloaking").power, 3)
	var rebel := ShipState.new("REBEL_FAT", false)
	var ai2 := ShipAI.new(rebel, RandomNumberGenerator.new())
	var tgt := cloak_ship(2)
	ai2.target = tgt
	ai2.check_power_levels()
	var rw := rebel.weapons[0]
	rw.charge = rw.max_charge(0)
	CloakRule.turn_on(tgt)
	ai2.update_weapons()
	check("AI holds fire while the target is cloaked", rw.fire_when_ready or not rw.pending_points.is_empty(), false)
	CloakRule.turn_off(tgt)
	ai2.update_weapons()
	check("  fires once it decloaks", rw.pending_points.is_empty(), false)
	es.weapons[0].charge = 100.0
	ai.firing_while_cloaked = false
	ai.update_weapons()
	check("cloaked AI without the fire roll holds fire", es.weapons[0].pending_points.is_empty(), true)


# ------------------------------------------------------------ teleporter

func teleport_pair(enemy_bp := "REBEL_FAT") -> Array:
	var p := ShipState.new("TEST_SHIP_ALL", true)
	p.reactor_max = 40
	var e := ShipState.new(enemy_bp, false)
	var cb := make_combat(p, e)
	return [p, e, cb]


## Puts player crew 0..n-1 on the teleporter pad (standing on its slots).
func on_pad(p: ShipState, n: int) -> Array:
	var room := p.sys("teleporter").room
	var out := []
	for i in n:
		var c := p.crew[i]
		c.place(p, room, i % p.graph.slot_count(room))
		out.append(c)
	return out


func test_teleporter() -> void:
	print("\nTeleporter (rules/teleporter.md)")
	for pw in [1, 2, 3]:
		var s := ShipState.new("TEST_SHIP_ALL", true)
		s.reactor_max = 40
		set_power(s, "teleporter", pw)
		TeleporterRule.start_cooldown(s)
		check("power %d: lock %d units = %d s" % [pw, [4, 3, 2][pw - 1], [20, 15, 10][pw - 1]],
			[s.sys("teleporter").ion, TeleporterRule.cooldown_seconds(pw)], [[4, 3, 2][pw - 1], [20.0, 15.0, 10.0][pw - 1]])
		check("  not charged while locked", TeleporterRule.charged(s), false)
	var r := teleport_pair()
	var p: ShipState = r[0]
	var e: ShipState = r[1]
	var cb: Combat = r[2]
	var tp := p.sys("teleporter")
	check("TEST_SHIP_ALL teleporter room 2 slots", p.graph.slot_count(tp.room), 2)
	check("nobody on the pad: can not send", TeleporterRule.can_send(p, e), false)
	check("  empty party costs nothing", [cb.initiate_teleport(p, 0, TeleporterRule.SEND), tp.ion], [0, 0])
	var party := on_pad(p, 2)
	check("2 crew on the pad: prepared 2", TeleporterRule.prepared_crew(p), 2)
	check("can send", TeleporterRule.can_send(p, e), true)
	var big := -1
	for room in e.layout.rooms:
		if e.graph.slot_count(room.id) == 2 and big < 0:
			big = room.id
	check("send 2 to a 2-slot room", cb.initiate_teleport(p, big, TeleporterRule.SEND), 2)
	check("  cooldown 20 s at power 1 (lock 4)", tp.ion, 4)
	check("  a second send while in flight is ignored", cb.initiate_teleport(p, big, TeleporterRule.SEND), 0)
	run_combat(cb, 0.45)
	check("  0.45 s: still aboard, dematerialising", [p.crew.has(party[0]), p.teleporting.has(party[0])],
		[true, true])
	run_combat(cb, 0.1)
	check("  0.55 s: aboard the enemy as intruders", [e.crew.has(party[0]), e.crew.has(party[1]),
		party[0].is_intruder(e)], [true, true, true])
	check("  in the target room", [party[0].room, party[1].room], [big, big])
	check("  materialising", e.teleporting.has(party[0]), true)
	run_combat(cb, 0.5)
	check("  done after 1.0 s", e.teleporting.is_empty(), true)

	print("Retrieve, spill, cap 4, crew left behind")
	tp.lock_system(0)
	check("can retrieve (own crew aboard)", TeleporterRule.can_receive(p, e), true)
	check("retrieve from their room", cb.initiate_teleport(p, big, TeleporterRule.RETRIEVE), 2)
	run_combat(cb, 1.1)
	check("  back on the pad", [p.crew.has(party[0]), party[0].room, party[1].room], [true, tp.room, tp.room])
	check("  cooldown on our teleporter", tp.ion > 0, true)
	tp.lock_system(0)
	# 4 crew in a 2-slot room of the enemy: 2 land there, 2 spill into a door-connected room
	var four := []
	for i in 5:
		var c := p.crew[i]
		c.place(p, tp.room, i % 2)
		four.append(c)
	check("TeleportCrew takes at most 4", TeleporterRule.pick_party(p, tp.room, false).size(), 4)
	cb.initiate_teleport(p, big, TeleporterRule.SEND)
	run_combat(cb, 0.6)
	var rooms := {}
	for c in four.slice(0, 4):
		rooms[c.room] = rooms.get(c.room, 0) + 1
	check("  4 sent to a 2-slot room: 2 there, 2 spill elsewhere", [rooms.get(big, 0), rooms.size() >= 2],
		[2, true])
	check("  the 5th stays home", p.crew.has(four[4]), true)
	run_combat(cb, 0.6)
	e.hull = 0
	run_combat(cb, DT)
	check("enemy destroyed: boarders still alive during the explosion",
		four.slice(0, 4).all(func(c): return c.is_alive()), true)
	run_combat(cb, ShipExplosion.ENEMY_TIME + 0.1)
	check("explosion over: our boarders die (KillEveryone)", four.slice(0, 4).all(func(c): return not c.is_alive()),
		true)

	test_teleporter_dead_crew()
	test_boarder_orders()

	print("Cloak blocks teleports")
	r = teleport_pair("TEST_SHIP_ALL")
	p = r[0]
	e = r[1]
	cb = r[2]
	on_pad(p, 1)
	CloakRule.turn_on(e)
	check("can_send ignores cloak, but the command is cancelled", cb.arm_teleporter(p, TeleporterRule.SEND), true)
	cb.teleport_room_clicked(0)
	run_combat(cb, DT)
	check("  no teleport, command cancelled", [p.sys("teleporter").ion, cb.player_tp_command.is_empty()], [0, true])

	print("Enemy boarding AI (combat_ai.md section 5, crew_ai.md task 8)")
	var player := ShipState.new("PLAYER_SHIP_HARD", true)
	var mantis := ShipState.new("MANTIS_FIGHTER", false)
	cb = make_combat(player, mantis)
	var ai: ShipAI = cb.ais.values()[0]
	check("MANTIS_FIGHTER boardingAI sabotage (1): keeps 2 of 3 crew", [ai.boarding_ai, ai.crew_needed], [1, 2])
	var boarding_task := false
	var t := 0.0
	while t < 6.0 and player.intruders().is_empty():
		cb._physics_process(DT)
		for c in mantis.crew:
			if c.ai_task.id == CrewAI.BOARD:
				boarding_task = true
		t += DT
	check("a mantis took the board task (8)", boarding_task, true)
	run_combat(cb, 1.1)
	check("one mantis boarded the player", player.intruders().size(), 1)
	check("  times teleported 1, request 0", [ai.times_teleported, ai.teleport_request], [1, 0])
	check("  enemy teleporter (power 1) on a 20 s cooldown", mantis.sys("teleporter").ion, 4)
	check("  the boarder is driven by the player ship crew AI", player.intruders()[0].ai_task.id != CrewAI.BOARD,
		true)


## Boarders on a ship whose crew all died (WorldManager::OnLoop deadCrew -> UpdateLocation: hostile = false,
## no KillEveryone, no automatic return): they stop sabotaging and fighting (ShipManager::UpdateCrewmembers),
## stay aboard, and the teleporter can still retrieve them (CanReceiveTeleport; UpdateTarget / SelectTarget
## have no hostile check). Enemy crew drones aboard the player ship die (DestroyBoardingDrones).
func test_teleporter_dead_crew() -> void:
	print("Enemy crew killed with boarders aboard (rules/teleporter.md \"Boarders on a ship that stops being hostile\")")
	var r := teleport_pair()
	var p: ShipState = r[0]
	var e: ShipState = r[1]
	var cb: Combat = r[2]
	var ai: ShipAI = cb.ais.values()[0]
	var tp := p.sys("teleporter")
	var target := e.sys("shields")
	var party := on_pad(p, 2)
	check("boarders sent to the enemy shield room",
		cb.initiate_teleport(p, target.room, TeleporterRule.SEND), 2)
	run_combat(cb, 1.1)
	check("  aboard, as intruders", party.all(func(c): return e.crew.has(c) and c.is_intruder(e)), true)
	for c in e.crew:  # keep the enemy crew out of the fight: they stand still elsewhere
		if not c.player_owned:
			c.hp = 0.0
	run_combat(cb, 0.1)
	for c in party:
		c.place(e, target.room, party.find(c))
	run_combat(cb, 2.0)
	check("hostile ship: the boarders sabotage the shields",
		party.any(func(c): return c.task == CrewMember.Task.SABOTAGE) and target.damage_progress > 0.0, true)
	var drone := p.add_crew("human", false)
	drone.make_drone("boarder")
	ai.hostile = false  # what the deadCrew outcome does (RunState.combat_outcome: enemy.hostile = false)
	run_combat(cb, DT)
	var dmg := target.damage
	var prog := target.damage_progress
	run_combat(cb, 3.0)
	check("non-hostile: StopRepairing every frame -> no sabotage task", party.all(func(c):
		return c.task != CrewMember.Task.SABOTAGE), true)
	# ShipSystem::OnLoop keeps fDamageOverTime while intruders occupy the room (bOccupied): frozen, not reset.
	check("  no further system damage, progress frozen", [target.damage, target.damage_progress], [dmg, prog])
	check("  not fighting either", party.all(func(c): return not c.fighting), true)
	check("  the boarders stay aboard, alive (no automatic return)",
		party.all(func(c): return c.is_alive() and e.crew.has(c)), true)
	check("  enemy boarding drone aboard our ship destroyed (DestroyBoardingDrones)", drone.is_alive(), false)
	tp.lock_system(0)
	check("can not send to a non-hostile ship", cb.arm_teleporter(p, TeleporterRule.SEND), false)
	check("can still arm RETRIEVE (own crew aboard)", cb.arm_teleporter(p, TeleporterRule.RETRIEVE), true)
	run_combat(cb, DT)
	check("  stays armed on the neutral ship while it holds our crew", cb.player_tp_armed, TeleporterRule.RETRIEVE)
	check("  its room click is taken", cb.teleport_room_clicked(target.room), true)
	run_combat(cb, 1.2)
	check("  boarders back home on the pad", party.all(func(c): return p.crew.has(c) and c.room == tp.room), true)
	tp.lock_system(0)
	check("nobody left aboard: the neutral ship can no longer be armed against",
		cb.arm_teleporter(p, TeleporterRule.RETRIEVE), false)


## Move orders for own crew aboard the enemy ship (CrewControl::RButton -> ShipManager::CommandCrewMoveRoom on
## the target ship): they walk there by the enemy ship's graph; its doors sealed against them (blast doors, doors
## level >= 2, closed) are broken through (rules/crew_combat.md "Doors"); the enemy CrewAI never moves them
## (GetControllable crew are left out of intruderList); works while the ship is non-hostile too.
func test_boarder_orders() -> void:
	print("Move orders for own boarders on the enemy ship (rules/crew_controls.md)")
	for hostile in [true, false]:
		var r := teleport_pair("TEST_SHIP_ALL")
		var p: ShipState = r[0]
		var e: ShipState = r[1]
		var cb: Combat = r[2]
		var ai: ShipAI = cb.ais.values()[0]
		ai.hostile = hostile
		for c in e.crew:
			c.hp = 0.0  # no defenders (keeps the walk deterministic)
		set_power(e, "doors", 2)  # blast doors: sealed against the other side's crew while closed
		var start := e.sys("pilot").room
		var goal := -1
		var best := 0.0
		for room in e.layout.rooms:
			var d := e.room_rect(room.id).get_center().distance_to(e.room_rect(start).get_center())
			if d > best and e.graph.slot_count(room.id) > 0:
				best = d
				goal = room.id
		var b := e.add_crew("human", true, start)
		run_combat(cb, 0.2)
		for di in e.env.doors.size():
			e.env.set_door(di, false)
		check("%s: boarder ordered to the far room %d" % ["hostile" if hostile else "neutral", goal],
			e.order_crew_move([b], goal), 1)
		var t := 0.0
		var broke := false
		while t < 300.0 and not (b.room == goal and b.is_on_slot(e)):
			run_combat(cb, 0.5)
			t += 0.5
			# The walk is what's tested, not survival: keep the air in (broken airlock doors vent rooms at random).
			for room_id in e.env.oxygen.keys():
				e.env.oxygen[room_id] = 100.0
			for d in e.env.doors:
				if float(d.forced) > 0.0:
					broke = true
		# Every door on the way is a sealed blast door (health 12 at level 2, one per hit): a long walk.
		check("  arrives (%.1f s), through sealed doors it breaks" % t, [b.room, b.is_on_slot(e), broke],
			[goal, true, true])
		check("  the enemy CrewAI did not re-task it", b.target_room, goal)
		check("  still ours, alive", [b.player_owned, b.is_alive(), e.crew.has(b)], [true, true, true])


# ------------------------------------------------------------ artillery

func test_artillery() -> void:
	print("\nArtillery (rules/artillery.md)")
	var s := ShipState.new("TEST_SHIP_ALL", true)
	s.reactor_max = 40
	check("one FED artillery on the 5th mount", [s.artillery.size(), s.artillery[0].bp.name,
		s.artillery[0].mount_index], [1, "ARTILLERY_FED", 4])
	var w := s.artillery[0]
	for pw in [1, 2, 3, 4]:
		check("charge time at power %d" % pw, ArtilleryRule.charge_time(w, pw), [50.0, 40.0, 30.0, 20.0][pw - 1])
	run(s, 10.0)
	near("power 1: 10 s of 50", w.charge, 10.0, 0.05)
	check("  max 50 s", w.max_charge(0), 50.0)
	set_power(s, "artillery", 4)
	run(s, DT)
	near("power 4: fraction kept (10/50 -> 4/20)", w.charge, 4.0 + DT, 0.02)
	set_power(s, "artillery", 0)
	run(s, DT)  # the modifier (1.5 at power 0) rescales the charge first
	var before := w.charge
	run(s, 0.5)
	near("unpowered: drains 6 s of charge per second", before - w.charge, 3.0, 0.1)
	var enemy := cloak_ship(3)
	s.opponent = enemy
	set_power(s, "artillery", 4)
	run(s, DT)
	CloakRule.turn_on(enemy)
	before = w.charge
	run(s, 1.0)
	check("holds its charge while the target is cloaked", w.charge, before)
	check("  and does not fire", ArtilleryRule.ready_to_fire(s, w), false)
	ArtilleryRule.jump(s)
	check("jump: charge 0", w.charge, 0.0)

	var p := ShipState.new("TEST_SHIP_ALL", true)
	p.reactor_max = 40
	set_power(p, "artillery", 4)
	var e := ShipState.new("REBEL_FAT", false)
	var cb := make_combat(p, e)
	var rng := RandomNumberGenerator.new()
	p.opponent = e
	var pts := ArtilleryRule.pick_points(p, w, rng)
	var far := 0.0
	for room in e.layout.rooms:
		far = maxf(far, pts[0].distance_to(e.room_rect(room.id).get_center()))
	check("beam: 2 points, the end is the room centre farthest from the start",
		[pts.size(), is_equal_approx(pts[0].distance_to(pts[1]), far)], [2, true])
	var hull := e.hull
	var t := 0.0
	var fired := false
	while t < 21.0:
		cb._physics_process(DT)
		if w.queued_shots > 0 or cb.projectiles.any(func(x): return x is Beam):
			fired = true
		t += DT
	check("fires by itself after 20 s at power 4", fired, true)
	check("  the beam hit the enemy hull", e.hull < hull, true)


# ------------------------------------------------------------ clonebay

func clone_ship() -> ShipState:
	var s := ShipState.new("TEST_SHIP_ALL_CLONE", true)
	s.reactor_max = 40
	return s


func clone_run(s: ShipState, seconds: float, ships := []) -> void:
	var all := ships if not ships.is_empty() else [s]
	var t := 0.0
	while t < seconds - 1e-6:
		for x in all:
			x.tick(F)
		ClonebayRule.collect_dead(s, all)
		ClonebayRule.tick(s, DT)
		t += DT


func test_clonebay() -> void:
	print("\nClone bay (rules/clonebay.md)")
	check("clone times 12 / 9 / 7 s", [ClonebayRule.clone_time(1), ClonebayRule.clone_time(2),
		ClonebayRule.clone_time(3)], [12.0, 9.0, 7.0])
	var s := clone_ship()
	var cb := s.sys("clonebay")
	check("clonebay power 1 at start", cb.power, 1)
	var c := s.crew[0]
	c.skills["pilot"] = 20
	c.skills["repair"] = 36
	c.skills["shields"] = 50
	var n := s.crew.size()
	c.hp = 0.0
	s.crew_changed()
	clone_run(s, 0.8)
	check("dead crew leaves the ship after its death animation and is queued", [s.crew.size(),
		s.clone_queue.size()], [n - 1, 1])
	clone_run(s, 11.0)
	check("not cloned yet at ~11.8 s (power 1: 12 s)", c.is_alive(), false)
	clone_run(s, 1.1)
	check("cloned after 12 s", [c.is_alive(), s.crew.has(c), s.clone_queue.size()], [true, true, 0])
	check("  full health", c.hp, c.max_hp)
	check("  in the clonebay room", c.room, cb.room)
	check("  skill loss 10 % of the human cap (pilot 26 -> -2, repair 32 -> -3, shields 100 -> -10)",
		[c.skills.pilot, c.skills.repair, c.skills.shields, c.skills.combat], [18, 33, 40, 0])

	s = clone_ship()
	cb = s.sys("clonebay")
	s.crew[0].hp = 0.0
	clone_run(s, 0.8 + 6.0)
	set_power(s, "clonebay", 2)
	clone_run(s, DT)
	near("power 1 -> 2 after 6 s: progress fraction kept (6/12 -> 4.5/9)", cb.timer, 4.5, 0.1)

	s = clone_ship()
	cb = s.sys("clonebay")
	s.crew[0].hp = 0.0
	s.crew[1].hp = 0.0
	clone_run(s, 2.0)
	check("powered with a queue: no cloneBroken loop, no warning", [ClonebayRule.dying(s),
		CloneQueueBox.dying_warning(s)], [false, false])
	set_power(s, "clonebay", 0)
	var newest: CrewMember = s.clone_queue[1]
	clone_run(s, 3.1)
	check("unpowered: progress reset", cb.timer, 0.0)
	check("  one crew lost after 3 s (the most recent death)", [s.clone_queue.size(), s.clone_queue.has(newest)],
		[1, false])
	check("  cloneBroken loop + CLONEBAY OFF warning while dying", [ClonebayRule.dying(s),
		CloneQueueBox.dying_warning(s)], [true, true])
	clone_run(s, 3.1)
	check("  the next one 3 s later", s.clone_queue.size(), 0)
	check("  queue empty: loop and warning stop", [ClonebayRule.dying(s), CloneQueueBox.dying_warning(s)],
		[false, false])

	s = clone_ship()
	s.crew[0].hp = 0.0
	clone_run(s, 1.0)
	s.sys("clonebay").hack_level = 2
	s.sys("clonebay").under_attack = true
	check("hacked but powered: crew dying with the cloneBroken loop, no warning (Functioning ignores hacks)",
		[ClonebayRule.dying(s), CloneQueueBox.dying_warning(s)], [true, false])

	s = clone_ship()
	s.augments.append("BACKUP_DNA")
	s.crew[0].hp = 0.0
	set_power(s, "clonebay", 0)
	clone_run(s, 8.0)
	check("BACKUP_DNA: nobody lost while unpowered", s.clone_queue.size(), 1)
	check("  no cloneBroken loop, no warning", [ClonebayRule.dying(s), CloneQueueBox.dying_warning(s)],
		[false, false])

	s = clone_ship()
	var e := ShipState.new("REBEL_FAT", false)
	var boarder := s.crew[2]
	s.crew.erase(boarder)
	boarder.place(e, e.layout.rooms[0].id, 0)
	e.crew.append(boarder)
	boarder.hp = 0.0
	clone_run(s, 1.0, [s, e])
	check("crew killed aboard the enemy is queued at home", [e.crew.has(boarder), s.clone_queue.has(boarder)],
		[false, true])

	print("Jump healing (CloneHealing): 8 / 16 / 25 HP by usable level, no power needed")
	s = clone_ship()
	set_power(s, "clonebay", 0)
	for x in s.crew:
		x.hp = 10.0
	ClonebayRule.jump_heal(s)
	check("level 3: +25", s.crew[0].hp, 35.0)
	s.damage_system("clonebay", 1)
	ClonebayRule.jump_heal(s)
	check("level 3 with 1 damage: +16", s.crew[0].hp, 51.0)
	s.damage_system("clonebay", 2)
	ClonebayRule.jump_heal(s)
	check("destroyed: +0", s.crew[0].hp, 51.0)
