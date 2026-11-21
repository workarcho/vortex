extends Node
## Tests for what happens to timers when combat ends (ShipManager::SetSafe / JumpArrive / Wait, chain weapon boost via
## ProjectileFactory::SetCurrentShip) and for the system explosion (ShipSystem::DamageOverTime bExploded -> 1 hull in
## ShipManager::OnLoop): rules/ftl_drive.md §4.3, rules/mind_control.md, rules/weapons.md "Chain",
## rules/damage.md "System explosion". Run:
##   godot --headless --path godot res://tests/test_combat_end.tscn

const Harness := preload("res://tests/harness.gd")

const DT := 1.0 / 60.0

var fails := 0


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	test_set_safe()
	test_arrive_locks()
	test_run_state_safe()
	test_crystal_power()
	test_chain_boost()
	test_sabotage_explosion()
	test_fire_explosion()
	test_no_explosion_paths()


func run(s: ShipState, seconds: float) -> void:
	var t := 0.0
	while t < seconds - 1e-6:
		s.tick(DT * GameClock.BASE)
		t += DT


func all_ship() -> ShipState:
	var s := ShipState.new("TEST_SHIP_ALL", true)
	s.reactor_max = 60
	s.rng.seed = 777
	return s


func test_set_safe() -> void:
	print("ShipManager::SetSafe: only teleporter, cloaking and battery are forced ready")
	var s := all_ship()
	s.sys("teleporter").lock_system(3)
	s.sys("cloaking").lock_system(4)
	s.sys("battery").lock_system(4)
	s.sys("mind").lock_system(4)
	s.sys("hacking").lock_system(4)
	s.sys("shields").add_ion(2)
	s.sys("oxygen").add_ion(2)
	s.ftl_charge = 0.2
	s.set_safe()
	check("teleporter / cloak / battery cooldowns cleared",
		[s.sys("teleporter").ion, s.sys("cloaking").ion, s.sys("battery").ion], [0, 0, 0])
	check("mind control and hacking cooldowns keep running", [s.sys("mind").ion, s.sys("hacking").ion], [4, 4])
	check("ion on shields / oxygen kept", [s.sys("shields").ion, s.sys("oxygen").ion], [2, 2])
	check("FTL full, bWasSafe set", [s.ftl_charge, s.was_safe], [1.0, true])
	var s2 := all_ship()
	s2.sys("cloaking").lock_system(-1)  # cloak running
	s2.sys("battery").lock_system(-1)  # battery running
	s2.sys("teleporter").lock_system(-1)
	s2.set_safe()
	check("running cloak / battery (-1) not cut short; teleporter LockSystem(0) always",
		[s2.sys("cloaking").ion, s2.sys("battery").ion, s2.sys("teleporter").ion], [-1, -1, 0])
	# The mind control cooldown is not instant out of combat: 20 s as always.
	var s3 := all_ship()
	s3.sys("mind").lock_system(4)
	for i in 60 * 19:
		s3.set_safe()
		s3.tick(DT * GameClock.BASE)
	check("mind cooldown still running after 19 s safe", s3.sys("mind").ion > 0, true)
	for i in 60 * 2:
		s3.set_safe()
		s3.tick(DT * GameClock.BASE)
	check("  ready after 20 s", s3.sys("mind").ion, 0)


func test_arrive_locks() -> void:
	print("ShipManager::JumpArrive (bWasSafe) / Wait: mind, shields, engines, weapons, piloting unlocked")
	var s := all_ship()
	s.set_safe()
	for id in ["mind", "shields", "engines", "weapons", "pilot", "oxygen", "sensors"]:
		s.sys(id).add_ion(3)
	s.arrive_locks()
	check("after a safe beacon: mind / shields / engines / weapons / pilot cleared",
		["mind", "shields", "engines", "weapons", "pilot"].map(func(id): return s.sys(id).ion), [0, 0, 0, 0, 0])
	check("  oxygen / sensors ion kept", [s.sys("oxygen").ion, s.sys("sensors").ion], [3, 3])
	check("  bWasSafe reset", s.was_safe, false)
	s.sys("shields").add_ion(2)
	s.arrive_locks()
	check("leaving a beacon that was never safe: shields ion kept", s.sys("shields").ion, 2)
	s.arrive_locks(true)
	check("ShipManager::Wait clears it regardless", s.sys("shields").ion, 0)


func test_run_state_safe() -> void:
	print("RunState: SetSafe every frame at a safe beacon")
	var r := RunState.new_run(2024)
	for i in 10:
		if r.phase == RunState.Phase.DIALOG:
			var first := r.dialog_choices.find_custom(func(v): return v.enabled)
			r.choose(maxi(first, 0))
		elif r.phase == RunState.Phase.MESSAGE:
			r.apply(RunIntent.make(RunIntent.CONTINUE))
	check("start beacon is safe", r.ftl_safe(), true)
	r.ship.was_safe = false
	r.ship.ftl_charge = 0.0
	r.ship.sys("shields").lock_system(2)
	r.tick(DT)
	check("RunState.tick: bWasSafe and FTL full", [r.ship.was_safe, r.ship.ftl_charge], [true, 1.0])
	check("  shields lock not touched by SetSafe", r.ship.sys("shields").ion, 2)


func test_crystal_power() -> void:
	print("Crystal lockdown cooldown: refilled by JumpArrive only (CrewMember::Jump -> ResetPower)")
	var r := RunState.new_run(2024)
	for i in 10:
		if r.phase == RunState.Phase.DIALOG:
			var first := r.dialog_choices.find_custom(func(v): return v.enabled)
			r.choose(maxi(first, 0))
		elif r.phase == RunState.Phase.MESSAGE:
			r.apply(RunIntent.make(RunIntent.CONTINUE))
	var c := r.ship.add_crew("crystal", true, r.ship.crew[0].room)
	check("player crystal starts at (0, 50)", [c.power_charge, c.power_max], [0.0, 50.0])
	for i in 60 * 5:
		r.tick(DT)
		r.ship.tick(DT * GameClock.BASE)
	check("safe beacon (SetSafe every frame): still charging at 1 /s, no refill", snappedf(c.power_charge, 0.1), 5.0)
	r._clear_location(true)
	check("ShipManager::Wait does not refill it", c.power_ready(), false)
	r._clear_location()
	check("jump arrival: full (50 / 50), ready", [c.power_charge, c.power_ready()], [50.0, true])


func test_chain_boost() -> void:
	print("Chain weapons: boost lost when the target ship changes or is gone (ProjectileFactory::SetCurrentShip)")
	var w := WeaponState.new(FtlData.weapon_blueprint("LASER_CHAINGUN"), 0)
	var a := ShipState.new("REBEL_FAT", false)
	var b := ShipState.new("REBEL_FAT", false)
	w.set_current_ship(a)
	w.boost_level = 3
	w.set_current_ship(a)
	check("same target: boost kept", w.boost_level, 3)
	w.set_current_ship(b)
	check("new target ship: boost 0", w.boost_level, 0)
	w.boost_level = 2
	w.set_current_ship(null)
	check("no target: boost 0", w.boost_level, 0)
	# Through ShipState.tick: the next fight is a new ShipState, and with no opponent the boost is gone at once.
	var p := ShipState.new("PLAYER_SHIP_HARD", true)
	p.weapons.clear()
	var cw := WeaponState.new(FtlData.weapon_blueprint("LASER_CHAINGUN"), 0)
	p.weapons.append(cw)
	p.opponent = a
	p.tick(DT * GameClock.BASE)
	cw.boost_level = 3
	p.tick(DT * GameClock.BASE)
	check("fighting the same ship: boost kept", cw.boost_level, 3)
	p.opponent = null  # enemy gone / beacon left
	p.tick(DT * GameClock.BASE)
	check("enemy gone: boost lost", cw.boost_level, 0)
	cw.boost_level = 3
	p.opponent = b
	p.tick(DT * GameClock.BASE)
	check("next fight (another ship): boost lost", cw.boost_level, 0)
	var iw := WeaponState.new(FtlData.weapon_blueprint("ION_CHAINGUN"), 0)
	iw.set_current_ship(a)
	iw.boost_level = 4
	iw.set_current_ship(b)
	check("chain ion (damage boost) too", iw.boost_level, 0)


## Enemy ship whose crew is one of its own crew members under mind control, standing in the shields room with the
## shields one bar from completely destroyed.
func sabotage_ship(hull: int) -> ShipState:
	var s := ShipState.new("REBEL_FAT", false)
	s.rng.seed = 4242
	s.crew.clear()
	var shr := s.sys("shields").room
	var c := s.add_crew("human", false, shr)
	c.mind_controlled = true
	s.crew_changed()
	s.sys("shields").damage = s.sys("shields").get_level() - 1
	s.hull = hull
	return s


func test_sabotage_explosion() -> void:
	print("Sabotage finishing a system: 1 hull damage (bExploded)")
	var s := sabotage_ship(5)
	var c: CrewMember = s.crew[0]
	check("mind-controlled own crew is an intruder", c.is_intruder(s), true)
	run(s, 13.0)
	check("system completely destroyed", s.sys("shields").damage, s.sys("shields").get_level())
	check("  hull 5 -> 4", s.hull, 4)
	check("  explosion queued in the shields room", s.pending_explosions, [s.sys("shields").room])
	run(s, 13.0)
	check("  only once", s.hull, 4)
	s = sabotage_ship(1)
	run(s, 13.0)
	check("at 1 hull the ship is destroyed", s.is_destroyed(), true)
	# The same ship's own crew that is not controlled repairs instead.
	var o := ShipState.new("REBEL_FAT", false)
	o.crew.clear()
	var shr := o.sys("shields").room
	o.add_crew("human", false, shr)
	o.crew_changed()
	o.sys("shields").damage = o.sys("shields").get_level() - 1
	o.hull = 1
	run(o, 13.0)
	check("own (uncontrolled) crew never sabotages: repaired, hull 1",
		[o.sys("shields").damage < o.sys("shields").get_level() - 1, o.hull], [true, 1])
	# Player boarders on the enemy ship: same rule.
	var e := ShipState.new("REBEL_FAT", false)
	e.crew.clear()
	var er := e.sys("weapons").room
	e.add_crew("human", true, er)
	e.crew_changed()
	e.sys("weapons").damage = e.sys("weapons").get_level() - 1
	e.hull = 3
	run(e, 13.0)
	check("player boarder finishes the weapons: hull 3 -> 2", e.hull, 2)
	# Jumping: DamageHull(force = false) does nothing, the explosion still shows.
	var j := sabotage_ship(5)
	j.jumping = true
	run(j, 13.0)
	check("jumping ship: no hull loss, explosion still queued", [j.hull, j.pending_explosions.size()], [5, 1])


func test_fire_explosion() -> void:
	print("Fire finishing a system: 1 hull damage")
	var s := ShipState.new("REBEL_FAT", false)
	s.crew.clear()
	s.crew_changed()
	var sys := s.sys("shields")
	sys.damage = sys.get_level() - 1
	s.hull = 6
	s.ignite(sys.room, 0)
	var t := 0.0
	while sys.damage < sys.get_level() and t < 30.0:
		s.tick(DT * GameClock.BASE)
		t += DT
	s.tick(DT * GameClock.BASE)
	check("fire destroyed the shields", sys.damage, sys.get_level())
	check("  hull 6 -> 5", s.hull, 5)


func test_no_explosion_paths() -> void:
	print("Weapon / event system damage and ion never cost hull")
	var s := ShipState.new("REBEL_FAT", false)
	s.crew.clear()
	s.crew_changed()
	s.hull = 2
	s.damage_system("shields", 10)
	s.ion_system("engines", 3)
	run(s, 1.0)
	check("system destroyed by DamageSystem: hull unchanged", [s.sys("shields").damage == s.sys("shields").get_level(),
		s.hull], [true, 2])
	# A system already destroyed does not explode again (fire keeps burning there).
	s.ignite(s.sys("shields").room, 0)
	run(s, 15.0)
	check("fire on a destroyed system: hull unchanged", s.hull, 2)
