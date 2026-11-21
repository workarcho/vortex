extends Node
## Tests for rules/hacking.md (hacking system, hacking drone, passive and pulse effects). Run:
##   godot --headless --path godot res://tests/test_hacking.tscn

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


## TEST_SHIP_ALL with its hacking system at `power` bars and a big reactor.
func hacker(power := 3) -> ShipState:
	var s := ShipState.new("TEST_SHIP_ALL", true)
	s.reactor_max = 60
	while s.sys("hacking").power < power and s.increase_power("hacking") == "ok":
		pass
	return s


func enemy(name := "REBEL_FAT") -> ShipState:
	var e := ShipState.new(name, false)
	DroneSystemRule.set_drones(e, [])
	return e


## Launches a hack on `sys_id` and flies until the drone is attached (max 15 s).
func attach(cb: Combat, p: ShipState, e: ShipState, sys_id: String) -> float:
	check("arm (drone parts, CanHack)", HackingRule.arm(p), "ok")
	check("click on the %s room" % sys_id, HackingRule.room_clicked(p, e.sys(sys_id).room), true)
	var t := 0.0
	while t < 15.0 and not (p.hack_drone != null and p.hack_drone.arrived()):
		cb._physics_process(DT)
		t += DT
	return t


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	test_launch_and_flight()
	test_passive()
	test_pulse_and_cooldown()
	test_pulse_rescale_and_ion()
	test_drone_lost()
	test_super_shield()
	test_unpowered_and_ending()
	test_effects_table()
	test_hacked_doors()
	test_ai()
	test_debug_virtual()
	test_ui_reveals()


func test_launch_and_flight() -> void:
	print("Launch and flight")
	var p := hacker()
	var e := enemy()
	var cb := make_combat(p, e)
	var parts := p.drone_parts
	check("effect timer table 4/7/10 s", HackingRule.EFFECT_TIMER.slice(1), [4.0, 7.0, 10.0])
	check("not armed without a click", p.hack_armed, false)
	check("arm", HackingRule.arm(p), "ok")
	check("click again disarms", HackingRule.arm(p), "off")
	HackingRule.arm(p)
	check("room without a system: consumed, nothing queued", [HackingRule.room_clicked(p, _empty_room(e)),
		p.hack_queued == null, p.hack_armed], [true, true, false])
	HackingRule.arm(p)
	HackingRule.room_clicked(p, e.sys("shields").room)
	check("queued (launched next frame)", [p.hack_queued == e.sys("shields"), p.hacking], [true, false])
	cb._physics_process(DT)
	var d := p.hack_drone
	check("launched: hacking, one drone part spent", [p.hacking, p.drone_parts], [true, parts - 1])
	check("drone starts from the hacking room toward x + 600", [d.space_ship == p, d.pod_phase,
		d.destination.x == p.shield_center.x + Drone.HACK_EXIT_DIST], [true, 0, true])
	check("button now shows the drone (not arm-able)", HackingRule.button_active(p), false)
	var before := d.pos
	cb._physics_process(DT)
	near("speed 28 per f = 448 px/s", d.pos.distance_to(before) / DT, 448.0, 1.0)
	check("targetable type 6 in flight (defence drones shoot it)", d.targetable_type(), Drone.T_POD)
	check("defence drones accept type 6", [Drone.ACCEPTS[1].has(6), Drone.ACCEPTS[4].has(6),
		Drone.ACCEPTS[3].has(6)], [true, true, true])
	var t := 0.0
	while t < 15.0 and d.pod_phase < 2:
		cb._physics_process(DT)
		if d.pod_phase == 1 and d.space_ship != e:
			break
		t += DT
	check("crossed into the enemy space and landed", [d.space_ship == e, d.arrived()], [true, true])
	check("stopped outside the hull (20 px look-ahead in a room)",
		[e.room_at(d.pos) < 0, e.room_at(d.pos + Vector2.from_angle(deg_to_rad(d.heading)) * 20.0) >= 0],
		[true, true])
	check("attached drone: not targetable, not hittable", [d.targetable_type(), d.hit_by(_laser(1))],
		[Drone.T_OTHER, false])
	# Landing points: on the target room directly when a scan line reaches it first.
	var rng := RandomNumberGenerator.new()
	var direct := 0
	for i in 40:
		var land := HackingRule.pick_landing(e, e.sys("shields").room, rng)
		var ahead: Vector2 = land.point + land.dir * 1.0
		if e.room_at(ahead) == e.sys("shields").room:
			direct += 1
		if i < 3:
			check("landing point %d on the hull edge" % i,
				e.room_at(ahead) >= 0 and e.room_at(land.point - land.dir) < 0, true)
	check("some landings directly on the target room", direct > 0, true)


func _empty_room(s: ShipState) -> int:
	for r in s.layout.rooms:
		if s.system_in_room(r.id) == null:
			return r.id
	return -1


func _laser(dmg: int, ion := 0) -> Damage:
	var d := Damage.new()
	d.damage = dmg
	d.ion = ion
	return d


func test_passive() -> void:
	print("\nPassive effect (drone attached)")
	var p := hacker()
	var e := enemy()
	var cb := make_combat(p, e)
	var sh := e.sys("shields")
	var power := sh.power
	attach(cb, p, e, "shields")
	cb._physics_process(DT)
	check("target under attack at level 1", [sh.under_attack, sh.hack_level, sh.hack_effect(), sh.hacked],
		[true, 1, 1, false])
	check("the system keeps its power", sh.power, power)
	check("room hack level 1", int(e.room_hack.get(sh.room, 0)), 1)
	var doors := e.env.doors.filter(func(d): return d.left == sh.room or d.right == sh.room)
	check("its doors hacked (level 1) and closed", doors.all(func(d): return d.hacked == 1 and not d.open), true)
	check("other doors untouched", e.env.doors.filter(func(d): return d.hacked > 0).size(), doors.size())
	e.env.set_door(e.env.doors.find(doors[0]), true)
	check("hacked doors cannot be opened", doors[0].open, false)
	check("hacked door: blast-2 strength", doors[0].base, e.env.hacked_door_health())
	check("power bars: on (passive is not purple)", sh.bar_state(0), "on")
	# Repairs x0.5 while under attack.
	e.damage_system("shields", 1)
	var c := CrewMember.new("human", false)
	var slot := e.graph.find_slot(sh.room, c)
	c.place(e, sh.room, slot)
	sh.repair_progress = 0.0
	c.update_task(e, 1.0)
	near("repair x0.5 under attack (8/s -> 4/s)", sh.repair_progress, 4.0, 0.01)


func test_pulse_and_cooldown() -> void:
	print("\nPulse (level 2), cooldown")
	var p := hacker(3)
	var e := enemy()
	var cb := make_combat(p, e)
	e.set_shield_layers_max(3)
	attach(cb, p, e, "shields")
	cb._physics_process(DT)
	var hs := p.sys("hacking")
	check("can pulse", HackingRule.can_pulse(p), true)
	check("pulse starts", HackingRule.initiate_pulse(p), true)
	check("hacking system locked indefinitely (-1)", hs.ion, -1)
	check("cannot pulse again", HackingRule.can_pulse(p), false)
	check("power frozen while pulsing", p.decrease_power("hacking"), false)
	run_combat(cb, 0.1)
	var sh := e.sys("shields")
	check("target level 2 (actively hacked)", [sh.hack_level, sh.hacked], [2, true])
	check("purple bars", sh.bar_state(0), "hack")
	check("target power locked (GetLocked)", [e.decrease_power("shields"), e.increase_power("shields")],
		[false, "locked"])
	check("pulse sparks on the room", int(e.room_hack.get(sh.room, 0)), 2)
	near("duration at power 3", p.hack_duration, 10.0, 0.001)
	run_combat(cb, 2.0)
	check("shields drain: 1 layer after 2 s", e.shield_layers, 2)
	run_combat(cb, 2.0)
	check("2 layers after 4 s", e.shield_layers, 1)
	check("pulse fraction", HackingRule.pulse_fraction(p) < 0.65 and HackingRule.pulse_fraction(p) > 0.5, true)
	run_combat(cb, 6.0)
	check("pulse over after 10 s: cooldown 4 locks (20 s)", hs.ion, HackingRule.COOLDOWN_LOCKS)
	run_combat(cb, 0.1)
	check("target back to passive level 1", [sh.hack_level, sh.hacked], [1, false])
	check("shields recharge again", e.shield_layers <= 1 and e.shield_charger > 0.0, true)
	run_combat(cb, 19.0)
	check("still cooling down at 19 s", HackingRule.can_pulse(p), false)
	run_combat(cb, 1.2)
	check("ready after 20 s", HackingRule.can_pulse(p), true)
	# Partial charge when the pulse starts: drained first, no layer lost for it.
	var p2 := hacker(1)
	var e2 := enemy()
	var cb2 := make_combat(p2, e2)
	e2.set_shield_layers_max(2)
	attach(cb2, p2, e2, "shields")
	e2.shield_layers = 1
	e2.shield_charger = 1.0
	HackingRule.initiate_pulse(p2)
	near("power 1: 4 s pulse", p2.hack_duration, 4.0, 0.001)
	run_combat(cb2, 1.1)
	check("partial charge drained first (layer kept)", e2.shield_layers, 1)
	run_combat(cb2, 2.0)
	check("then 1 layer lost after 2 more s", e2.shield_layers, 0)


func test_pulse_rescale_and_ion() -> void:
	print("\nPulse: power change rescales, ion ends it")
	var p := hacker(3)
	var e := enemy()
	var cb := make_combat(p, e)
	attach(cb, p, e, "engines")
	HackingRule.initiate_pulse(p)
	run_combat(cb, 5.0)
	near("elapsed 5 of 10", p.hack_elapsed, 5.0, 0.05)
	p.damage_system("hacking", 1)  # power 3 -> 2: 10 s -> 7 s
	run_combat(cb, DT)
	near("rescaled: 5/10 x 7 = 3.5", p.hack_elapsed, 3.5, 0.05)
	near("new duration 7", p.hack_duration, 7.0, 0.001)
	p.ion_system("hacking", 1)
	run_combat(cb, DT)
	check("ion replaces the -1 lock: pulse over, cooldown = ion", p.sys("hacking").ion, 1)
	run_combat(cb, DT)
	check("target back to level 1", e.sys("engines").hack_level, 1)


func test_drone_lost() -> void:
	print("\nDrone shot down / ion stun")
	var p := hacker()
	var e := enemy()
	var cb := make_combat(p, e)
	HackingRule.arm(p)
	HackingRule.room_clicked(p, e.sys("weapons").room)
	run_combat(cb, 0.2)
	var d := p.hack_drone
	check("ion hit: +5 s stun per point, still alive", [d.hit_by(_laser(0, 1)), d.ion_stun, d.exploding < 0.0],
		[true, 5.0, true])
	d.hit_by(_laser(0, 1))
	check("stun adds up", d.ion_stun, 10.0)
	var at := d.pos
	run_combat(cb, 0.5)
	check("stunned drone does not fly on", d.pos.distance_to(at) < 30.0, true)
	d.ion_stun = 0.0
	var parts := p.drone_parts
	check("hull damage blows it up", [d.hit_by(_laser(1)), d.exploding >= 0.0], [true, true])
	run_combat(cb, 1.5)
	check("hack cancelled, drone gone, part not refunded", [p.hacking, d.deployed, p.drone_parts],
		[false, false, parts])
	check("a new launch is possible (needs a part)", HackingRule.button_active(p), true)


func test_super_shield() -> void:
	print("\nSuper shields")
	var p := hacker()
	var e := enemy()
	var cb := make_combat(p, e)
	e.super_shield = 2
	run_combat(cb, DT)
	check("blocked: SUPER SHIELDS PREVENT HACKING", HackingRule.arm(p), "blocked")
	check("StartHacking refused while blocked", HackingRule.start_hacking(p, e.sys("shields")), false)
	e.super_shield = 0
	HackingRule.arm(p)
	HackingRule.room_clicked(p, e.sys("shields").room)
	run_combat(cb, DT)
	e.super_shield = 3
	var d := p.hack_drone
	var t := 0.0
	while t < 10.0 and d.exploding < 0.0 and not d.arrived():
		cb._physics_process(DT)
		t += DT
	check("drone crossing a super shield blows up", [d.exploding >= 0.0, d.arrived()], [true, false])


func test_unpowered_and_ending() -> void:
	print("\nUnpowered hacking system, target destroyed, stop")
	var p := hacker(1)
	var e := enemy()
	var cb := make_combat(p, e)
	attach(cb, p, e, "oxygen")
	cb._physics_process(DT)
	var o := e.sys("oxygen")
	check("passive", o.hack_effect(), 1)
	p.decrease_power("hacking")
	run_combat(cb, 0.1)
	check("unpowered: target cleared, drone stays", [o.hack_effect(), p.hacking, p.hack_drone.deployed],
		[0, true, true])
	check("cannot pulse unpowered", HackingRule.can_pulse(p), false)
	p.increase_power("hacking")
	run_combat(cb, 0.1)
	check("repowered: passive again", o.hack_effect(), 1)
	HackingRule.initiate_pulse(p)
	run_combat(cb, 0.1)
	check("power frozen while pulsing", p.decrease_power("hacking"), false)
	p.damage_system("hacking", 10)
	run_combat(cb, 0.1)
	check("destroyed mid-pulse: aborted to 20 s cooldown", p.sys("hacking").ion, HackingRule.COOLDOWN_LOCKS)
	# Target system completely destroyed: passive stays, no pulse.
	p.sys("hacking").lock_system(0)
	p.repair_system("hacking", 10)
	p.increase_power("hacking")
	e.damage_system("oxygen", 10)
	run_combat(cb, 0.1)
	check("destroyed target: passive stays, CanPulse false", [o.hack_effect(), HackingRule.can_pulse(p)], [1, false])
	HackingRule.stop(p)
	check("stop (jump / stand-down): cleared, drone removed", [o.hack_effect(), p.hacking, p.hack_drone.deployed],
		[0, false, false])
	# Hacking system itself hacked (the other side pulses it): abort + passive cleared + drone stunned.
	var p2 := hacker(2)
	var e2 := enemy()
	var cb2 := make_combat(p2, e2)
	attach(cb2, p2, e2, "weapons")
	HackingRule.initiate_pulse(p2)
	run_combat(cb2, 0.1)
	p2.sys("hacking").hacked = true
	run_combat(cb2, 0.1)
	check("own hacking system hacked: pulse aborted, target cleared, drone stunned",
		[p2.sys("hacking").ion, e2.sys("weapons").hack_effect(), p2.hack_drone.stunned()],
		[HackingRule.COOLDOWN_LOCKS, 0, true])
	# Enemy destroyed -> hack stops.
	p2.sys("hacking").hacked = false
	e2.hull = 0
	run_combat(cb2, 0.1)
	check("target ship destroyed: hack stops", p2.hacking, false)


func test_effects_table() -> void:
	print("\nPulse effects per system")
	var s := ShipState.new("TEST_SHIP_ALL", false)
	s.reactor_max = 60
	var o := ShipState.new("REBEL_FAT", true)
	s.opponent = o
	o.opponent = s
	# Engines / piloting: evasion 0.
	check("evasion > 0 before", s.dodge_factor() > 0, true)
	s.sys("engines").hacked = true
	check("engines hacked: evasion 0", s.dodge_factor(), 0)
	s.sys("engines").hacked = false
	s.sys("pilot").hacked = true
	check("piloting hacked: evasion 0", s.dodge_factor(), 0)
	s.sys("pilot").hacked = false
	# Oxygen -6 %/s.
	s.sys("oxygen").hacked = true
	var room: int = s.layout.rooms[0].id
	s.env.oxygen[room] = 50.0
	s.env._tick_oxygen_system(1.0)
	near("oxygen hacked: -6 %/s", s.env.oxygen[room], 44.0, 0.01)
	s.sys("oxygen").hacked = false
	# Weapons: charge drains 1 s/s; multi-charge drops a level when full.
	var w := WeaponState.new(FtlData.weapon_blueprint("LASER_BURST_2"), 0)
	w.powered = true
	w.charge = 5.0
	w.tick(GameClock.BASE * 1.0, 0, true)
	near("hacked weapon: -1 s per s", w.charge, 4.0, 0.001)
	var cg := WeaponState.new(FtlData.weapon_blueprint("LASER_CHARGEGUN_PLAYER"), 0)
	cg.powered = true
	cg.charge_level = 2
	cg.charge = cg.max_charge(0)
	cg.tick(GameClock.BASE * 0.5, 0, true)
	check("full multi-charge weapon drops a level", cg.charge_level, 1)
	# Weapons on a hacked ship keep draining even when the target is cloaked.
	var ws := s.weapons[0] if not s.weapons.is_empty() else null
	if ws:
		s.try_power_weapon(ws)
		ws.charge = 3.0
		s.sys("weapons").hacked = true
		s.depower_weapon(ws)
		check("hacked weapons: power frozen (no depower)", ws.powered, true)
		s.sys("cloaking").turned_on = false
		s.tick(GameClock.BASE * 1.0)
		check("hacked weapons drain in ShipState.tick", ws.charge < 3.0, true)
		s.sys("weapons").hacked = false
	# Artillery drains too.
	if not s.artillery.is_empty():
		var a := s.artillery[0]
		s.sys("artillery").power = 1
		ArtilleryRule.tick(s, 0.0)
		a.charge = 3.0
		s.sys("artillery").hacked = true
		ArtilleryRule.tick(s, GameClock.BASE * 1.0)
		near("hacked artillery: charge drains", a.charge, 2.0, 0.01)
		s.sys("artillery").hacked = false
	# Doors system pulse: every door hacked.
	s.sys("doors").hacked = true
	HackingRule.update_ship(s)
	check("doors pulse: every door hacked and closed", s.env.doors.all(func(d): return d.hacked == 2 and not d.open),
		true)
	s.sys("doors").hacked = false
	HackingRule.update_ship(s)
	check("pulse over: doors released", s.env.doors.any(func(d): return d.hacked > 0), false)
	# Teleporter: entering level 2 clears the cooldown.
	s.sys("teleporter").lock_system(3)
	s.sys("teleporter").hacked = true
	HackingRule.update_ship(s)
	check("teleporter hacked: cooldown cleared", s.sys("teleporter").ion, 0)
	check("hacked teleporter can receive (AI, countHacked)", TeleporterRule.can_receive(s, o, true), true)
	s.sys("teleporter").hacked = false
	# Cloaking: turned off, cannot start.
	s.sys("cloaking").power = 2
	CloakRule.turn_on(s)
	s.sys("cloaking").hacked = true
	CloakRule.tick(s, 0.1)
	check("cloak hacked: off and not ready", [s.is_cloaked(), CloakRule.ready(s)], [false, false])
	s.sys("cloaking").hacked = false
	# Battery: reactor -2.
	s.sys("battery").hacked = true
	BatteryRule.tick(s, 0.1)
	check("battery hacked: reactor -2", s.reactor_capacity(), s.reactor_max - 2)
	s.sys("battery").hacked = false
	BatteryRule.tick(s, 0.1)
	# Clonebay / medbay already have their own rule tests (clonebay power 0, medbay -12.8 HP/s).
	check("medbay hacked: -12.8 HP/s", MedbayRule.hp_per_second(3, true), -12.8)
	# Drones: stunned.
	var d := ShipState.new("TEST_SHIP_ALL", true)
	d.reactor_max = 60
	DroneSystemRule.set_drones(d, ["DEFENSE_1"])
	d.drone_parts = 5
	d.opponent = o
	DroneSystemRule.power_drone(d, d.drones[0])
	d.sys("drones").hacked = true
	DroneSystemRule.tick(d, 0.1)
	check("drone system hacked: drones stunned", d.drones[0].stunned(), true)
	DroneSystemRule.depower_drone(d, d.drones[0])
	check("  and the player cannot power drones", DroneSystemRule.player_toggle(d, d.drones[0]), "locked")
	# Sensors: counted as unpowered for vision (main.gd show_power) -> flag only here.
	s.sys("sensors").hacked = true
	check("sensors hacked flag", s.sys("sensors").hacked, true)
	s.sys("sensors").hacked = false
	# Symbol flashes blue while hacked; purple outline.
	s.sys("shields").hacked = true
	check("symbol flashes blue", s.sys("shields").symbol_color(0.05), "blue")
	check("purple frame", FtlColors.lock_outline(s.sys("shields")), FtlColors.PURPLE_HACK)
	s.sys("shields").hacked = false


func test_hacked_doors() -> void:
	print("\nHacked doors seal against their own crew")
	var e := ShipState.new("REBEL_FAT", false)
	var sh := e.sys("shields")
	sh.hack_level = 1
	sh.under_attack = true
	HackingRule.update_ship(e)
	var di := -1
	for i in e.env.doors.size():
		var dd: Dictionary = e.env.doors[i]
		if (dd.left == sh.room or dd.right == sh.room) and dd.left >= 0 and dd.right >= 0:
			di = i
			break
	var door: Dictionary = e.env.doors[di]
	var own := CrewMember.new("human", false)
	var boarder := CrewMember.new("human", true)
	check("sealed for the ship's own crew", e.graph.is_sealed(door, own), true)
	check("open to intruders", e.graph.is_sealed(door, boarder), false)
	# An own crew walking through it stops and attacks the door.
	var other: int = door.left if door.right == sh.room else door.right
	var c := e.add_crew("human", false, other)
	c.move_to_room(e, sh.room)
	for i in 120:
		HackingRule.update_ship(e)
		c.update_movement(e, DT)
	check("own crew blocked at a hacked door", [c.blocking_door >= 0, c.room != sh.room], [true, true])


func test_ai() -> void:
	print("\nEnemy AI: launch on a random system, pulse as soon as possible")
	var p := ShipState.new("PLAYER_SHIP_HARD", true)
	var e := ShipState.new("TEST_SHIP_ALL", false)
	e.reactor_max = 60  # room for every system (the AI powers hacking last)
	DroneSystemRule.set_drones(e, [])
	e.drone_parts = 3
	var cb := make_combat(p, e)
	var t := 0.0
	while t < 30.0 and not HackingRule.pulsing(e):
		cb._physics_process(DT)
		t += DT
	check("enemy launched a hack (part spent)", [e.hacking, e.drone_parts], [true, 2])
	check("target is a player system", e.hack_target != null and p.systems.values().has(e.hack_target), true)
	check("enemy pulses once attached", HackingRule.pulsing(e), true)
	run_combat(cb, 0.1)
	check("player system actively hacked", e.hack_target.hacked, true)
	var ai := ShipAI.new(e, RandomNumberGenerator.new())
	ai.target = p
	p.hacking = true
	check("hard key targets include the player's hacking system while it hacks",
		p.sys("hacking") == null or ai.key_targets().has("hacking"), true)
	p.hacking = false
	ai.hostile = false
	ai.tick(DT)
	check("stand-down stops hacking", e.hacking, false)


func test_debug_virtual() -> void:
	print("\nDebug virtual hacking system")
	var p := ShipState.new("PLAYER_SHIP_HARD", true)
	var e := enemy()
	var cb := make_combat(p, e)
	check("REBEL_FAT has no hacking system", e.sys("hacking"), null)
	var v := HackingRule.ensure_virtual(e)
	e.drone_parts = 1
	check("virtual system level 3 power 3, not in systems", [v.get_level(), v.effective_power(),
		e.systems.values().has(v)], [3, 3, false])
	check("StartHacking on the player's engines", HackingRule.start_hacking(e, p.sys("engines")), true)
	var t := 0.0
	while t < 15.0 and not (e.hack_drone != null and e.hack_drone.arrived()):
		cb._physics_process(DT)
		t += DT
	check("virtual hacker's drone lands", e.hack_drone.arrived(), true)
	run_combat(cb, 0.2)
	check("the AI pulses it (CombatAI)", p.sys("engines").hacked, true)
	check("player evasion 0", p.dodge_factor(), 0)
	run_combat(cb, 10.5)
	check("pulse ends, cooldown on the virtual system", [p.sys("engines").hacked, v.ion > 0], [false, true])


## What hacking reveals to the player (rules/hacking.md "UI"): the hacked room (tempVision) and the enemy weapon
## charge bars (WeaponAnimation::RenderChargeBar: iHackLevel > 0, or the player's sensors at power > 2).
func test_ui_reveals() -> void:
	print("
UI: vision of the hacked room, enemy weapon charge bars")
	var p := hacker()
	var e := enemy()
	var cb := make_combat(p, e)
	p.sys("sensors").override_level = 1  # sensors are a subsystem: power = level (crew removed: no manning bonus)
	p.crew.clear()
	var ws := e.sys("weapons")
	var w: WeaponState = e.weapons[0]
	w.powered = true
	check("sensors < 2: weapons room blacked out", e.blacked_out_rooms().has(ws.room), true)
	check("no charge bar without sensors 3 or hack", WeaponArt.charge_bar_visible(e, w), false)
	attach(cb, p, e, "weapons")
	cb._physics_process(DT)
	w.powered = true
	check("drone attached: weapons room visible (tempVision)", e.blacked_out_rooms().has(ws.room), false)
	check("other rooms still blacked out", e.blacked_out_rooms().has(e.sys("shields").room), true)
	check("passive hack: charge bar shown, level 1 (yellow)", [WeaponArt.charge_bar_visible(e, w),
		WeaponArt.hack_level(e, w)], [true, 1])
	w.powered = false
	check("unpowered weapon: no bar", WeaponArt.charge_bar_visible(e, w), false)
	w.powered = true
	HackingRule.initiate_pulse(p)
	run_combat(cb, 0.1)
	w.powered = true
	check("pulse: level 2 (purple bar)", WeaponArt.hack_level(e, w), 2)
	# No hack: the player's sensors provide the charge at effective power > 2 (DoSensorsProvide(4)).
	var p2 := hacker()
	var e2 := enemy()
	make_combat(p2, e2)
	var w2: WeaponState = e2.weapons[0]
	w2.powered = true
	p2.crew.clear()
	p2.sys("sensors").override_level = 3
	check("sensors power 3 (> 2): bar shown", [p2.sys("sensors").effective_power(),
		WeaponArt.charge_bar_visible(e2, w2)], [3, true])
	p2.sys("sensors").override_level = 2
	check("sensors power 2: no bar", [p2.sys("sensors").effective_power(), WeaponArt.charge_bar_visible(e2, w2)],
		[2, false])
	check("player weapons never get the bar", WeaponArt.charge_bar_visible(p2, p2.weapons[0]), false)
