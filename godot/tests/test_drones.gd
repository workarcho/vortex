extends Node
## Tests for rules/drones.md (drone system, space drones, crew drones) and the dead-crew removal of
## rules/crew.md "Crew animations and sounds". Run:
##   godot --headless --path godot res://tests/test_drones.tscn

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
	check("%s ~= %.3f [%.3f]" % [name, want, got], absf(got - want) <= tol, true)


func space(ship: ShipState) -> Space:
	var sp := Space.new()
	add_child(sp)  # in the tree first: setup() makes its camera current
	sp.setup(ship)
	return sp


func make_combat(player: ShipState, enemy: ShipState) -> Combat:
	var cb := Combat.new()
	cb.rng.seed = 4242  # deterministic: enemy AI/targeting rolls must not change the measured cadence
	seed(4242)
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


func run(s: ShipState, seconds: float) -> void:
	var t := 0.0
	while t < seconds - 1e-6:
		s.tick(F)
		t += DT


## TEST_SHIP_ALL (drone system level 6, reactor 25) with the given drones and parts; opponent REBEL_FAT
## without drones (so nothing else moves in its space).
func drone_ship(names: Array, parts := 10) -> ShipState:
	var s := ShipState.new("TEST_SHIP_ALL", true)
	s.reactor_max = 40
	DroneSystemRule.set_drones(s, names)
	s.drone_parts = parts
	_seed(s)
	return s


func enemy() -> ShipState:
	var e := ShipState.new("REBEL_FAT", false)
	DroneSystemRule.set_drones(e, [])
	_seed(e)
	return e


## Deterministic runs: every random source a ship owns gets a fixed seed.
func _seed(ship: ShipState) -> void:
	ship.rng.seed = 777
	ship.env._rng.seed = 778


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	test_blueprints()
	test_parts_and_power()
	test_depower_order()
	test_ion_stun_and_collision()
	test_defense_rules()
	test_defense_intercept()
	test_combat_cadence()
	test_super_shield()
	test_hull_repair()
	test_crew_drones()
	test_boarding_pod()
	test_ion_boarder_anim()
	test_recall_and_ai()
	test_dead_crew_removal()


func test_blueprints() -> void:
	print("Drone blueprints (§1)")
	var d1 := FtlData.drone_blueprint("DEFENSE_1")
	check("DEFENSE_1 power / speed / cooldown / target", [d1.power, d1.speed, d1.cooldown, d1.target_type],
		[2, 5.0, 1.0, Drone.TARGET_MISSILES])
	var d2 := FtlData.drone_blueprint("DEFENSE_2")
	check("DEFENSE_2 cooldown 0.88 s, targets lasers", [d2.cooldown, d2.target_type], [0.88, Drone.TARGET_LASERS])
	check("BOSS_DEFENSE_2: level 2 => lasers", FtlData.drone_blueprint("BOSS_DEFENSE_2").target_type,
		Drone.TARGET_LASERS)
	check("ANTI_DRONE targets drones, 7 s", [FtlData.drone_blueprint("ANTI_DRONE").target_type,
		FtlData.drone_blueprint("ANTI_DRONE").cooldown], [Drone.TARGET_DRONES, 7.0])
	check("COMBAT_2 power 4 speed 28 image", [FtlData.drone_blueprint("COMBAT_2").power,
		FtlData.drone_blueprint("COMBAT_2").speed, FtlData.drone_blueprint("COMBAT_2").drone_image],
		[4, 28.0, "drone_combat2"])
	check("flak SHOTGUN_PLAYER is drone_targetable", FtlData.weapon_blueprint("SHOTGUN_PLAYER").drone_targetable, true)
	var k := ShipState.new("PLAYER_SHIP_HARD", true)
	check("Kestrel: no drone system started, 2 parts, 2 slots", [k.sys("drones") == null, k.drone_parts,
		k.drone_slots], [true, 2, 2])
	var r := ShipState.new("REBEL_FAT", false)
	check("REBEL_FAT: DRONES_STANDARD fitting level 2 -> COMBAT_1, 4 parts",
		[r.drones.map(func(d): return d.bp.name), r.drone_parts], [["COMBAT_1"], 4])
	var c := ShipState.new("CIRCLE_SCOUT", false)
	check("CIRCLE_SCOUT: DRONES_DEFENSE -> DEFENSE_1", c.drones.map(func(d): return d.bp.name), ["DEFENSE_1"])


func test_parts_and_power() -> void:
	print("\nDrone parts and power (§2)")
	var s := drone_ship(["DEFENSE_1", "REPAIR"], 1)
	s.opponent = enemy()
	var ds := s.sys("drones")
	var free := s.reactor_free()
	check("power DEFENSE_1", DroneSystemRule.power_drone(s, s.drones[0]), "ok")
	check("  deployment costs 1 part", s.drone_parts, 0)
	check("  system power = drone power", ds.power, 2)
	check("  reactor bars taken", free - s.reactor_free(), 2)
	check("REPAIR with 0 parts -> no_parts", DroneSystemRule.power_drone(s, s.drones[1]), "no_parts")
	DroneSystemRule.depower_drone(s, s.drones[0])
	check("depowered: stays deployed", [s.drones[0].powered, s.drones[0].deployed], [false, true])
	check("  system power 0", ds.power, 0)
	check("re-power a deployed drone with 0 parts: free", DroneSystemRule.power_drone(s, s.drones[0]), "ok")
	check("  parts still 0", s.drone_parts, 0)
	s.drone_parts = 5
	ds.level = 2
	check("system at capacity -> no_system_power", DroneSystemRule.power_drone(s, s.drones[1]), "no_system_power")
	ds.level = 6
	s.reactor_max = s.reactor_used()
	check("no reactor bars -> reactor", DroneSystemRule.power_drone(s, s.drones[1]), "reactor")
	s.reactor_max = 40
	check("increase_power('drones') refused (per drone)", s.increase_power("drones"), "max")
	check("player toggle: on", DroneSystemRule.player_toggle(s, s.drones[1]), "ok")
	check("  repair drone aboard, in the drone room", [s.drones[1].crew != null,
		s.drones[1].crew.room if s.drones[1].crew else -1], [true, ds.room])
	check("player toggle again: off", DroneSystemRule.player_toggle(s, s.drones[1]), "off")
	s.ion_system("drones", 1)
	check("ionized system: toggle locked", DroneSystemRule.player_toggle(s, s.drones[1]), "locked")
	var lone := drone_ship(["COMBAT_1"], 3)
	check("combat drone without an enemy: no_target", DroneSystemRule.player_toggle(lone, lone.drones[0]), "no_target")
	check("  no part spent", lone.drone_parts, 3)


func test_depower_order() -> void:
	print("\nDepower order, ion, damage (§2)")
	var s := drone_ship(["DEFENSE_1", "ANTI_DRONE", "DEFENSE_2"])
	s.opponent = enemy()
	for d in s.drones:
		DroneSystemRule.power_drone(s, d)
	check("all powered: 2 + 1 + 3", s.sys("drones").power, 6)
	s.damage_system("drones", 1)
	check("damage 1 (max 5): last slot (DEFENSE_2, 3 bars) depowered",
		s.drones.map(func(d): return d.powered), [true, true, false])
	s.repair_system("drones", 1)
	DroneSystemRule.power_drone(s, s.drones[2])
	s.ion_system("drones", 1)
	check("ion 1: last powered drone depowered whole (frees 3 > 1)",
		s.drones.map(func(d): return d.powered), [true, true, false])
	check("  still deployed", s.drones[2].deployed, true)
	s.ion_system("drones", 3)
	check("ion 3 more: DEFENSE_1 (2) and ANTI_DRONE (1)", s.drones.map(func(d): return d.powered),
		[false, false, false])
	run(s, 21.0)
	check("ion over: drones not re-powered", s.drones.map(func(d): return d.powered), [false, false, false])
	check("  system unlocked", s.sys("drones").is_locked(), false)
	DroneSystemRule.power_drone(s, s.drones[0])
	DroneSystemRule.power_drone(s, s.drones[1])
	s.reactor_max = s.reactor_used() - 1
	s.tick(F)
	check("reactor overuse: a powered drone loses its power (last first if picked)",
		DroneSystemRule.power_used(s) < 3 or s.reactor_free() >= 0, true)


func test_ion_stun_and_collision() -> void:
	print("\nIon stun, collisions, rebuild (§3)")
	var p := drone_ship(["DEFENSE_1", "DEFENSE_2"])
	var e := enemy()
	var cb := make_combat(p, e)
	DroneSystemRule.power_drone(p, p.drones[0])
	var d := p.drones[0]
	check("deployed in its own space, on the shield ellipse", [d.space_ship == p,
		absf(((d.pos - p.shield_center) / p.shield_axes).length() - 1.0) < 0.01], [true, true])
	var ion := Damage.new()
	ion.ion = 2
	check("ion shot consumed", d.hit_by(ion), true)
	check("  powered drone stunned 5 s x 2", d.ion_stun, 10.0)
	check("  not destroyed", [d.deployed, d.exploding < 0.0], [true, true])
	var d2 := p.drones[1]
	DroneSystemRule.power_drone(p, d2)
	DroneSystemRule.depower_drone(p, d2)
	d2.hit_by(ion)
	check("unpowered drone: ion does not stun", d2.ion_stun, 0.0)
	# An enemy laser crossing the drone (projectile in the player's space, 10 px).
	var w := WeaponState.new(FtlData.weapon_blueprint("LASER_BURST_1"), 0)
	var shot := Projectile.new()
	shot.setup_drone(w, e, cb.space_of(p), d.pos + Vector2(-5, 0), d.pos + Vector2(200, 0), p)
	cb.space_of(p).world.add_child(shot)
	cb.projectiles.append(shot)
	var parts := p.drone_parts
	cb._drone_collisions(F)
	check("laser within 10 px: drone blows up", d.exploding >= 0.0, true)
	check("  the laser is consumed", shot.dying > 0.0, true)
	run_combat(cb, 1.2)
	check("explosion over: undeployed, depowered, rebuilding 10 s", [d.deployed, d.powered,
		d.destroyed_timer > 8.0], [false, false, true])
	check("  rebuilding: cannot power", DroneSystemRule.power_drone(p, d), "rebuilding")
	run_combat(cb, 10.0)
	check("after 10 s: deployable again, costs a part", [DroneSystemRule.power_drone(p, d), p.drone_parts],
		["ok", parts - 1])
	# Own shots pass through own drones.
	var own := Projectile.new()
	own.setup_drone(w, p, cb.space_of(p), d.pos, d.pos + Vector2(200, 0), e)
	cb.space_of(p).world.add_child(own)
	cb.projectiles.append(own)
	cb._drone_collisions(F)
	check("own shot does not hit own drone", d.exploding < 0.0, true)
	# Missile vs defence laser: two projectiles of different owners within 10 px destroy each other.
	var m := Projectile.new()
	m.setup_drone(WeaponState.new(FtlData.weapon_blueprint("MISSILES_2_PLAYER"), 0), e, cb.space_of(p),
		p.shield_center + Vector2(300, 0), p.shield_center, p)
	var l := Projectile.new()
	l.setup_drone(WeaponState.new(FtlData.weapon_blueprint("DRONE_LASER"), 0), p, cb.space_of(p),
		p.shield_center + Vector2(306, 0), p.shield_center + Vector2(400, 0), null)
	for x in [m, l]:
		cb.space_of(p).world.add_child(x)
		cb.projectiles.append(x)
	cb._drone_collisions(F)
	check("missile and drone laser 6 px apart both destroyed", [m.dying > 0.0, l.dying > 0.0], [true, true])
	check("missile targetable type 1, laser 4, flak 2", [m.targetable_type(), l.targetable_type(),
		_flak_type()], [Drone.T_MISSILE, Drone.T_LASER, Drone.T_ASTEROID])


func _flak_type() -> int:
	var p := Projectile.new()
	p.weapon = FtlData.weapon_blueprint("SHOTGUN_PLAYER")
	var t := p.targetable_type()
	p.free()
	return t


func test_defense_rules() -> void:
	print("\nDefence drone targeting (§6)")
	var s := drone_ship(["DEFENSE_1", "DEFENSE_2", "ANTI_DRONE"])
	s.opponent = enemy()
	for d in s.drones:
		DroneSystemRule.power_drone(s, d)
	var d1 := s.drones[0]
	var d2 := s.drones[1]
	var anti := s.drones[2]
	d1.offer(1, Drone.T_LASER, Vector2.ZERO, Vector2.ZERO)
	check("DEFENSE_1 refuses lasers", d1.has_target, false)
	d1.offer(2, Drone.T_MISSILE, Vector2(5, 5), Vector2.ZERO)
	check("DEFENSE_1 accepts missiles", [d1.has_target, d1.target_id], [true, 2])
	d1.offer(3, Drone.T_POD, Vector2.ZERO, Vector2.ZERO)
	check("  once a missile was accepted only missiles replace it", d1.target_id, 2)
	d1.offer(4, Drone.T_MISSILE, Vector2(7, 7), Vector2.ZERO)
	check("  a later missile replaces it (last valid offer)", d1.target_id, 4)
	d2.offer(5, Drone.T_LASER, Vector2.ZERO, Vector2.ZERO)
	check("DEFENSE_2 accepts lasers", d2.target_id, 5)
	d2.offer(6, Drone.T_DRONE, Vector2.ZERO, Vector2.ZERO)
	check("  refuses drones", d2.target_id, 5)
	d2.offer(7, Drone.T_OTHER, Vector2.ZERO, Vector2.ZERO)
	check("  refuses bombs / beams (type 5)", d2.target_id, 5)
	anti.offer(8, Drone.T_MISSILE, Vector2.ZERO, Vector2.ZERO)
	check("ANTI_DRONE refuses missiles", anti.has_target, false)
	anti.offer(9, Drone.T_DRONE, Vector2.ZERO, Vector2.ZERO)
	check("ANTI_DRONE accepts drones", anti.target_id, 9)
	anti.offer(10, Drone.T_POD, Vector2.ZERO, Vector2.ZERO)
	check("  and pods (type 6)", anti.target_id, 10)
	d1.shot_at_id = 11
	d1.target_type = Drone.T_OTHER
	d1.offer(11, Drone.T_MISSILE, Vector2.ZERO, Vector2.ZERO)
	check("shotAtTargetId refused (not for anti-drone)", d1.target_id != 11, true)
	anti.shot_at_id = 12
	anti.target_type = Drone.T_OTHER
	anti.offer(12, Drone.T_DRONE, Vector2.ZERO, Vector2.ZERO)
	check("  anti-drone accepts its shotAtTargetId", anti.target_id, 12)
	# Lead, turret, box
	near("AimAhead((100,0), v (0,10), shot 20)", Drone.aim_ahead(Vector2(100, 0), Vector2(0, 10), 20.0),
		sqrt(10000.0 / 300.0), 0.001)
	check("turret turns 30 deg per f", Drone.turn_toward(0.0, 90.0, 30.0), 30.0)
	check("  the shorter way", Drone.turn_toward(10.0, 340.0, 20.0), -10.0)
	check("  snaps when it would pass", Drone.turn_toward(80.0, 90.0, 30.0), 90.0)
	check("aim box: shield centre + (-350..250)", [d1.in_aim_box(s.shield_center + Vector2(240, -340)),
		d1.in_aim_box(s.shield_center + Vector2(260, 0))], [true, false])
	# Fire: a stationary missile inside the box, cooldown ready.
	d1.has_target = false
	d1.target_type = Drone.T_OTHER
	d1.cooldown = -0.01
	d1.fire_ready = true
	var tp := s.shield_center + Vector2(20, 10)  # inside the aim box wherever the drone is
	d1.offer(20, Drone.T_MISSILE, tp, Vector2.ZERO)
	d1.aim_angle = 90.0
	d1.step(F)
	check("turret not on target yet: no shot", d1.pending_shot.is_empty(), true)
	for i in 60:
		d1.offer(20, Drone.T_MISSILE, tp, Vector2.ZERO)
		d1.step(F)
		if not d1.pending_shot.is_empty():
			break
	check("aligned and ready: shot at the point", d1.pending_shot.get("to", Vector2.INF) == tp, true)
	check("  cooldown reset to 1.0 s, target cleared, marked shot at",
		[snappedf(d1.cooldown, 0.01), d1.has_target, d1.shot_at_id], [1.0, false, 20])
	d1.pending_shot = {}
	d1.offer(30, Drone.T_MISSILE, s.shield_center + Vector2(900, 0), Vector2.ZERO)
	d1.step(F)
	check("target outside the box is dropped", d1.has_target, false)
	# Cooldown only runs while powered and not stunned; deploy sets 1.0 s.
	var fresh := drone_ship(["DEFENSE_2"])
	fresh.opponent = enemy()
	DroneSystemRule.power_drone(fresh, fresh.drones[0])
	check("deploy cooldown 1.0 s", fresh.drones[0].cooldown, 1.0)
	fresh.drones[0].ion_stun = 5.0
	fresh.drones[0].step(F * 30)
	check("  stunned: cooldown frozen", fresh.drones[0].cooldown, 1.0)
	check("defence orbit speed: blueprint speed per f (DEFENSE_2 7 -> 112 px/s)",
		fresh.drones[0].flight_speed() * GameClock.BASE, 112.0)


## A missile flying straight past a defence drone: the drone leads, fires once ready and the laser
## meets the missile (end-of-frame 10 px rule), destroying both.
func test_defense_intercept() -> void:
	print("\nDefence drone intercept (§6)")
	var p := drone_ship(["DEFENSE_1"])
	var e := enemy()
	var cb := make_combat(p, e)
	DroneSystemRule.power_drone(p, p.drones[0])
	var d := p.drones[0]
	var hits := 0
	for trial in 5:
		d.cooldown = -0.1
		d.fire_ready = true
		d.has_target = false
		d.shot_at_id = 0
		var m := Projectile.new()
		var start := p.shield_center + Vector2(-200 + 50 * trial, -260)
		m.setup_drone(WeaponState.new(FtlData.weapon_blueprint("MISSILES_2_PLAYER"), 0), e, cb.space_of(p),
			start, p.shield_center + Vector2(0, 30 * trial), p)
		cb.space_of(p).world.add_child(m)
		cb.projectiles.append(m)
		var t := 0.0
		while t < 1.5 and m.dying <= 0.0 and not m.dead:
			cb._physics_process(DT)
			t += DT
		if m.dying > 0.0 and not m.passed_target:
			hits += 1
		run_combat(cb, 1.0)
	print("    defence drone shot down %d / 5 missiles" % hits)
	check("defence drone shoots missiles down (>= 3 of 5)", hits >= 3, true)


func test_combat_cadence() -> void:
	print("\nCombat drone (§5)")
	var p := drone_ship(["COMBAT_1", "COMBAT_BEAM"])
	var e := enemy()
	var cb := make_combat(p, e)
	var d := p.drones[0]
	DroneSystemRule.power_drone(p, d)
	check("flies in the enemy's space", d.space_ship == e, true)
	var a := maxf(e.shield_axes.x, e.shield_axes.y)
	near("speed = 15 x max(a,b) / 350 per f", d.flight_speed(), 15.0 * a / 350.0, 0.001)
	check("destinations on 1.15 x the shield ellipse",
		absf(((d.destination - e.shield_center) / e.shield_axes).length() - 1.15) < 0.01, true)
	# Measure one leg: time from arrival to the shot = 0.5 s; time between shots = leg / speed + 0.5.
	var times := []
	var legs := []
	var t := 0.0
	var last_dest := d.destination
	var leg_start := d.pos
	var shot: Projectile = null
	var seen := {}
	for x in cb.projectiles:
		seen[x] = true
	while t < 20.0 and times.size() < 4:
		cb._physics_process(DT)
		t += DT
		if d.destination != last_dest:
			legs.append(leg_start.distance_to(last_dest))
			leg_start = last_dest
			last_dest = d.destination
		for x in cb.projectiles:
			if not seen.has(x):
				seen[x] = true
				if x is Projectile and x.owner_ship == p:  # (the enemy's own weapons fire too)
					times.append(t)
					shot = x
	check("fired 4 shots in 20 s", times.size(), 4)
	if times.size() >= 3 and legs.size() >= 3:
		var speed_px := d.flight_speed() * GameClock.BASE
		near("period = next leg / speed + 0.5 s", times[2] - times[1], legs[2] / speed_px + 0.5, 0.15)
	check("drone laser starts in the enemy space aimed at a room centre", shot != null
		and shot.current_space.ship == e and e.room_at(shot.target) >= 0, true)
	# Beam drone: a beam from the drone between two different rooms.
	var b := p.drones[1]
	DroneSystemRule.power_drone(p, b)
	var got_beam := false
	t = 0.0
	while t < 15.0 and not got_beam:
		cb._physics_process(DT)
		t += DT
		for x in cb.projectiles:
			if x is Beam and x.owner_ship == p:
				got_beam = x.sub_start.distance_to(b.pos) < 30.0 and x.target1 != x.target2
	check("beam drone sweeps from the drone across two rooms", got_beam, true)
	# Unpowered: drifts, shot lost; stunned: same.
	DroneSystemRule.depower_drone(p, d)
	check("depowered: pause / fire cleared", [d.pause, d.fire_ready], [-1.0, false])
	e.hull = 0
	run_combat(cb, 0.1)
	check("enemy destroyed: player combat drones recalled (undeployed)", [d.deployed, b.deployed], [false, false])


func test_super_shield() -> void:
	print("\nSuper shield drone (§7)")
	var s := ShipState.new("REBEL_FAT", false)
	s.reactor_max = 30
	s.sys("drones").level = 4
	DroneSystemRule.set_drones(s, ["DRONE_SHIELD"])
	s.drone_parts = 2
	s.opponent = drone_ship([])
	DroneSystemRule.power_drone(s, s.drones[0])
	var d := s.drones[0]
	check("deploy cooldown = SUPER_SHIELD_TIME[0] = 8 s", d.cooldown, 8.0)
	var t := 0.0
	var first := -1.0
	var second := -1.0
	var stopped := false
	while t < 20.0:
		var before := s.super_shield
		var p0 := d.pos
		d.step(F)
		t += DT
		if d.glow > 0.0 and d.pos == p0 and first < 0.0:
			stopped = true
		if s.super_shield > before:
			if first < 0.0:
				first = t
			elif second < 0.0:
				second = t
	near("first layer after 8 s", first, 8.0, 0.05)
	near("second after 10 s more (1 layer -> 10 s)", second - first, 10.0, 0.05)
	check("stops while glowing (< 1.5 s left)", stopped, true)
	check("super shield layers 2, max 5", [s.super_shield, s.super_shield_max], [2, 5])
	var dmg := Damage.new()
	dmg.damage = 1
	dmg.ion = 1
	var rng := RandomNumberGenerator.new()
	s.shield_layers = 2
	var res := s.on_projectile_enters_shield(dmg, rng) if s.dodge_factor() == 0 else "super"
	if s.dodge_factor() > 0:
		while true:
			var before_super := s.super_shield
			res = s.on_projectile_enters_shield(dmg, rng)
			if res != "miss" or before_super != s.super_shield:
				break
	check("a shot hits the super shield: absorbed, damage + 2 x ion off it", [res, s.super_shield], ["super", 0])
	check("  normal layers untouched", s.shield_layers, 2)
	DroneSystemRule.depower_drone(s, d)
	check("unpowered: cooldown reset to full (0 layers -> 8 s)", d.cooldown, 8.0)


func test_hull_repair() -> void:
	print("\nHull repair drone (§8)")
	var p := drone_ship(["SHIP_REPAIR"])
	var e := enemy()
	var cb := make_combat(p, e)
	p.hull = 10
	DroneSystemRule.power_drone(p, p.drones[0])
	var d := p.drones[0]
	var repairs := d.lifespan
	check("3-5 repairs", repairs >= 3 and repairs <= 5, true)
	check("flies around its own ship", d.space_ship == p, true)
	run_combat(cb, 40.0)
	check("hull +1 per stop", p.hull, 10 + repairs)
	check("used up: undeployed, no rebuild timer", [d.deployed, d.rebuilding()], [false, false])
	DroneSystemRule.power_drone(p, d)
	run_combat(cb, 0.5)
	DroneSystemRule.depower_drone(p, d)
	run_combat(cb, 0.1)
	check("depowering destroys it (part lost, no rebuild)", [d.deployed, d.rebuilding()], [false, false])


func test_crew_drones() -> void:
	print("\nCrew drones (§10)")
	var p := drone_ship(["REPAIR", "BATTLE"])
	var e := enemy()
	var cb := make_combat(p, e)
	var ds := p.sys("drones")
	DroneSystemRule.power_drone(p, p.drones[0])
	var r := p.drones[0].crew
	check("repair drone: 25 HP, crew drone, not own crew for the AI", [r.max_hp, r.is_drone(),
		p.own_crew().has(r)], [25.0, true, false])
	check("  cannot burn or suffocate, moves x0.5", [r.can_burn(), r.can_suffocate(), r.move_speed()],
		[false, false, 40.0])
	# Repair drone fixes a damaged system (speed 2.0 => 16 / s => one bar in 6.25 s).
	p.damage_system("drones", 1)
	r.place(p, ds.room, p.graph.find_slot(ds.room, r))
	run_combat(cb, 3.0)
	check("  repairing after 3 s (half a bar)", [ds.damage, snappedf(ds.repair_progress, 1.0) >= 40.0], [1, true])
	run_combat(cb, 3.5)
	check("  bar repaired in ~6.25 s", ds.damage, 0)
	DroneSystemRule.depower_drone(p, p.drones[0])
	run_combat(cb, 0.1)
	check("unpowered: frozen", r.frozen, true)
	DroneSystemRule.power_drone(p, p.drones[1])
	var b := p.drones[1].crew
	check("anti-personnel drone: 150 HP, fights, x1.2 damage", [b.max_hp, b.can_fight(), b.damage_mult()],
		[150.0, true, 1.2])
	b.hp = 0.0
	run_combat(cb, 0.1)
	check("killed: drone destroyed, 10 s rebuild", [p.drones[1].deployed, p.drones[1].rebuilding()], [false, true])
	check("  body still shown (explosion)", p.crew.has(b), true)
	run_combat(cb, 1.0)
	check("  body removed after its 1.0 s explosion", p.crew.has(b), false)
	DroneSystemRule.power_drone(p, p.drones[0])
	DroneSystemRule.set_deployed(p, p.drones[0], false)
	check("undeployed repair drone removed from the ship", p.crew.has(r), false)
	check("crew drones cannot teleport", TeleporterRule.can_teleport(p, b), false)


func test_boarding_pod() -> void:
	print("\nBoarding drone (§9)")
	var p := drone_ship(["BOARDER"])
	var e := enemy()
	var cb := make_combat(p, e)
	var breaches_before := e.breaches.size()
	DroneSystemRule.power_drone(p, p.drones[0])
	var d := p.drones[0]
	check("pod starts in its own space at the drone room", [d.space_ship == p,
		d.pos == p.room_rect(p.sys("drones").room).get_center()], [true, true])
	check("pod speed 18 per f (288 px/s)", d.flight_speed() * GameClock.BASE, 288.0)
	var t := 0.0
	while t < 10.0 and d.pod_phase < 2:
		cb._physics_process(DT)
		t += DT
	check("pod delivered", d.pod_phase, 2)
	var c := d.crew
	check("boarding drone aboard the enemy as an intruder", c != null and e.crew.has(c) and c.is_intruder(e), true)
	check("  150 HP, x1.2", [c.max_hp, c.damage_mult()] if c else [], [150.0, 1.2])
	check("  in a system room", c != null and e.system_in_room(c.room) != null, true)
	check("impact breach", e.breaches.size() > breaches_before, true)
	c.hp = 0.0
	run_combat(cb, 0.1)
	check("boarder killed: pod destroyed, 10 s rebuild", [d.deployed, d.rebuilding()], [false, true])
	# Super shields: the enemy AI never launches a pod against a super-shielded player; a pod crossing
	# into a super shield blows up.
	var e2 := ShipState.new("REBEL_FAT", false)
	DroneSystemRule.set_drones(e2, ["BOARDER"])
	var p2 := drone_ship([])
	e2.opponent = p2
	p2.super_shield = 1
	check("enemy pod vs super shields: cannot deploy", e2.drones[0].can_be_deployed(), false)
	var p3 := drone_ship(["BOARDER"])
	var e3 := enemy()
	var cb3 := make_combat(p3, e3)
	e3.super_shield = 2
	DroneSystemRule.power_drone(p3, p3.drones[0])
	t = 0.0
	while t < 10.0 and p3.drones[0].exploding < 0.0 and p3.drones[0].pod_phase < 2:
		cb3._physics_process(DT)
		t += DT
	check("player pod into a super shield: blown up", p3.drones[0].exploding >= 0.0, true)


func test_recall_and_ai() -> void:
	print("\nJump recall and enemy AI (§2, §11)")
	var p := drone_ship(["DEFENSE_1", "REPAIR"])
	p.opponent = enemy()
	for d in p.drones:
		DroneSystemRule.power_drone(p, d)
	var parts := p.drone_parts
	DroneSystemRule.jump(p)
	check("jump: space drone recalled (undeployed), crew drone stays",
		[p.drones[0].deployed, p.drones[1].deployed], [false, true])
	check("  no refund without DRONE_RECOVERY", p.drone_parts, parts)
	DroneSystemRule.power_drone(p, p.drones[0])
	p.augments.append("DRONE_RECOVERY")
	parts = p.drone_parts
	DroneSystemRule.jump(p)
	check("  DRONE_RECOVERY refunds the part", p.drone_parts, parts + 1)
	# Enemy AI powers its drone in the round-robin (costs a part once).
	var player := drone_ship([])
	var e := ShipState.new("REBEL_FAT", false)
	var cb := make_combat(player, e)
	var before := e.drone_parts
	run_combat(cb, 0.5)
	check("enemy AI deploys COMBAT_1 (1 part)", [e.drones[0].powered, e.drones[0].deployed, e.drone_parts],
		[true, true, before - 1])
	check("  its drones bars are counted in its reactor", e.sys("drones").power, 2)
	e.ion_system("drones", 1)
	run_combat(cb, 0.1)
	check("  ionized: drone depowered, stays deployed", [e.drones[0].powered, e.drones[0].deployed], [false, true])
	run_combat(cb, 5.5)
	check("  after the ion the AI re-powers it for free", [e.drones[0].powered, e.drone_parts], [true, before - 1])
	player.hull = 0
	run_combat(cb, 0.2)
	check("  target gone: enemy drone stays deployed (recall never undeploys enemy drones)",
		e.drones[0].deployed, true)


func test_dead_crew_removal() -> void:
	print("\nDead crew removal (rules/crew.md: 0.75 s animation + 1.0 s fade)")
	var s := ShipState.new("PLAYER_SHIP_HARD", true)
	var n := s.crew.size()
	var c := s.crew[0]
	c.hp = 0.0
	s.crew_changed()
	run(s, 1.0)
	check("body still aboard at 1.0 s", s.crew.has(c), true)
	run(s, 0.8)
	check("removed at 1.75 s (no clonebay)", s.crew.has(c), false)
	check("  crew count", s.crew.size(), n - 1)
	# With a clonebay the body goes to the clone queue at 0.75 s instead (ClonebayRule).
	var k := ShipState.new("TEST_SHIP_ALL_CLONE", true)
	var e := enemy()
	var cb := make_combat(k, e)
	var v := k.crew[0]
	v.hp = 0.0
	k.crew_changed()
	run_combat(cb, 0.5)
	check("clonebay: body kept until the pick-up", k.crew.has(v), true)
	run_combat(cb, 0.4)
	check("  then queued for cloning (not removed as dead)", [k.crew.has(v), k.clone_queue.has(v)], [false, true])
	# Enemy crew killed aboard the player ship (no clonebay on the enemy): removed at 1.75 s.
	var p := ShipState.new("PLAYER_SHIP_HARD", true)
	var en := enemy()
	p.opponent = en
	var boarder := p.add_crew("human", false)
	boarder.hp = 0.0
	run(p, 1.8)
	check("dead intruder removed from the boarded ship", p.crew.has(boarder), false)

## Ion boarding drone state machine (IonDroneAnimation, rules/drones.md §9 "Ion boarding drone animation").
func test_ion_boarder_anim() -> void:
	print("
Ion boarding drone animation (IonDroneAnimation)")
	var s := ShipState.new("PLAYER_SHIP_HARD", true)
	_seed(s)
	var shr := s.sys("shields").room
	s.crew.resize(1)
	var dfd: CrewMember = s.crew[0]
	dfd.place(s, shr, s.graph.find_slot(shr, dfd))
	var c := s.add_crew("boarder_ion", false, shr)
	c.make_drone("boarder_ion")
	var t := 0.0
	var charge_at := -1.0
	var fire_at := -1.0
	var effect_at_charge_end := -1.0
	var stun_after := -1.0
	var ion_after := -1
	var expl := []
	while t < 9.0:
		s.tick(F)
		t += DT
		c.hp = c.max_hp  # the defender shoots it; keep it alive
		dfd.hp = dfd.max_hp
		if charge_at < 0.0 and c.ion_charges == 1:
			charge_at = t
		if charge_at >= 0.0 and effect_at_charge_end < 0.0 and t >= charge_at + 0.95:
			effect_at_charge_end = c.ion_effect
		if fire_at < 0.0 and c.ion_discharges == 1:
			fire_at = t
			stun_after = dfd.stun
			ion_after = s.sys("shields").ion
			expl = [c.ion_explosion, c.ion_explosion_pos, Vector2(floorf(c.pos.x) - 32.0, floorf(c.pos.y) - 32.0)]
			break
	check("status 7 while sabotaging (task SABOTAGE, standing)", CrewCombat.ion_status7(s, c), true)
	near("charge starts after the 6 s shoot timer (ionBoarderCharge)", charge_at, 6.0, 2.0 * DT)
	near("  ionEffect stays 0 during the 1 s charge animation", effect_at_charge_end, 0.0, 0.001)
	near("discharge 1.0 s charge + 1.25 s hold later (ionHit1)", fire_at - charge_at, 2.25, 2.0 * DT)
	check("  room ionized: shields ion +3 (5 s lock each)", ion_after, 3)
	near("  defender stunned 6 s", stun_after, 6.0, 2.0 * DT)
	check("  the drone itself is not stunned (no friendly fire)", c.stun, 0.0)
	check("  charge stopped, timer restarted, BlockRoom = this room",
		[c.ion_charge, c.ion_timer < 1.0, c.last_ion_room, c.block_room()], [-1.0, true, shr, shr])
	check("  explosion_big1_ion started, centred on the drone (top-left pos - 32)", [expl[0], expl[1]], [0.0, expl[2]])
	run(s, 0.45)
	check("  explosion still running at 0.45 s", c.ion_explosion > 0.0, true)
	run(s, 0.1)
	check("  explosion over after 0.5 s", c.ion_explosion, -1.0)
	check("no crew lasers, no punches", [c.shots.size(), c.shots_fired], [0, 0])
	check("IonDrone::UpdateRepair is empty: no bar sabotaged", s.sys("shields").damage, 0)

	print("Charge animation timing and the held timer")
	c.reset_ion_anim()
	c.ion_timer = CrewCombat.ION_TIMER + 0.001  # fires on the next status-7 frame
	CrewCombat.update_ion_drone(s, c, DT)
	check("timer done: charge at frame 0, ionEffect 0", [c.ion_charge >= 0.0, c.ion_effect, c.ion_charges], [true, 0.0, 2])
	var tm := c.ion_timer
	for i in 30:
		CrewCombat.update_ion_drone(s, c, DT)
	check("  shoot timer frozen while charging", c.ion_timer, tm)
	c.stun = 1.0
	var ch := c.ion_charge
	CrewCombat.update_ion_drone(s, c, DT)
	check("  stunned (not status 7): charge frozen", c.ion_charge, ch)
	c.stun = 0.0
	c.reset_ion_anim()
	c.stun = 2.0
	CrewCombat.update_ion_drone(s, c, 1.0)
	check("  timer does not run outside status 7", c.ion_timer, 0.0)
	c.stun = 0.0
	CrewCombat.update_ion_drone(s, c, 1.0)
	near("  runs again in status 7", c.ion_timer, 1.0, 0.001)

	print("Door attack (boarder_ion_shoot_<dir>, door branch)")
	c.reset_ion_anim()
	c.blocking_door = 0
	c.damage_done = 0.0
	var hits := []
	t = 0.0
	while t < 2.9:
		CrewCombat.update_ion_drone(s, c, DT)
		t += DT
		if c.damage_done > 0.0:
			hits.append(t)
			if hits.size() == 1:
				check("  hit 3..7", c.damage_done >= 3.0 and c.damage_done <= 7.0, true)
			c.damage_done = 0.0
	check("one door hit per pass of the 1.5 s strip run at double speed: 4 hits in 2.9 s", hits.size(), 4)
	near("  0.75 s apart", hits[1] - hits[0], 0.75, 2.0 * DT)
	check("  charge held at frame 0, ionEffect 0, no charge sound", [c.ion_charge, c.ion_effect, c.ion_charges],
		[0.0, 0.0, 2])
	c.blocking_door = -1
	t = 0.0
	while c.ion_discharges < 2 and t < 3.0:
		CrewCombat.update_ion_drone(s, c, DT)
		t += DT
	near("after the door: the held charge plays out (discharge 2.25 s later, no new charge sound)", t, 2.25, 2.0 * DT)
	check("  charges counter unchanged", c.ion_charges, 2)

	print("Intruder AI: the discharge room is blocked (+100), no -10 stay (cannot fight)")
	var ai := CrewAI.new(s)
	var base := ai.prioritize_intruder_room(c, shr, [c])
	c.last_ion_room = -1
	var unblocked := ai.prioritize_intruder_room(c, shr, [c])
	check("BlockRoom +100", base - unblocked, 100)
	check("ion drone never takes the -10 stay score (CanFight false)", unblocked >= 0, true)
