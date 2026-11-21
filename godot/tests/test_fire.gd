extends Node
## Tests for rules/fire_and_oxygen.md. Run:
##   godot --headless --path godot res://tests/test_fire.tscn

const Harness := preload("res://tests/harness.gd")

var fails := 0


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func near(name: String, got: float, want: float, tol: float) -> void:
	check("%s ~= %.1f (+/-%.1f) [%.2f]" % [name, want, tol, got], absf(got - want) <= tol, true)


func run(s: ShipState, seconds: float) -> void:
	var steps := int(seconds * 60.0)
	for i in steps:
		s.env.tick(1.0 / 60.0)


func new_ship() -> ShipState:
	return ShipState.new("PLAYER_SHIP_HARD", true)


func set_o2_power(s: ShipState, p: int) -> void:
	s.sys("oxygen").override_level = maxi(p, 1)
	s.sys("oxygen").power = p


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	print("Oxygen system (doors closed)")
	var s := new_ship()
	var room := s.sys("weapons").room
	s.env.oxygen[room] = 50.0
	run(s, 10)
	near("power 1: +1.2 %/s, 50 -> 10 s", s.env.oxygen[room], 62.0, 0.3)
	s = new_ship()
	set_o2_power(s, 3)
	s.env.oxygen[room] = 0.0
	run(s, 5)
	near("power 3: +8.4 %/s, 0 -> 5 s", s.env.oxygen[room], 42.0, 0.3)
	s = new_ship()
	set_o2_power(s, 0)
	run(s, 10)
	near("unpowered: -1.2 %/s, 100 -> 10 s", s.env.oxygen[room], 88.0, 0.3)

	print("Breach (doors closed, oxygen level 1)")
	s = new_ship()
	s.add_breach(room, 0)
	run(s, 5)
	near("-8 + 1.2 = -6.8 %/s, 100 -> 5 s", s.env.oxygen[room], 66.0, 0.5)

	print("Spreading through open doors")
	s = new_ship()
	set_o2_power(s, 0)
	s.env.set_all_doors(true)
	for r in s.env.oxygen:
		s.env.oxygen[r] = 100.0
	s.env.oxygen[room] = 0.0
	check("with inner doors open, all rooms connected",
		s.env.room_distances(room).size(), s.layout.rooms.size())
	run(s, 60)
	var lo := 100.0
	var hi := 0.0
	for r in s.env.oxygen:
		lo = minf(lo, s.env.oxygen[r])
		hi = maxf(hi, s.env.oxygen[r])
	# 8 %/s of the difference -> time constant 12.5 s; at 60 s less than 1 % of the initial difference remains
	check("after 60 s all rooms even (diff < 1.5)", hi - lo < 1.5, true)

	print("Airlock")
	s = new_ship()
	var airlock_room := -1
	for d in s.env.doors:
		if d.airlock:
			airlock_room = d.left if d.left >= 0 else d.right
			d.open = true
			break
	s.env.tick(1.0 / 60.0)
	check("opening airlock with > 10 % -> room at 0 instantly", s.env.oxygen[airlock_room] < 1.0, true)

	# The zeroing only hits the airlock's own room; a neighbour joined by an open door loses
	# 16 x 0.75 = 12 %/s plus the pull toward the group average (not instant).
	s = new_ship()
	var neighbour := -1
	for d in s.env.doors:
		if d.airlock and neighbour < 0:
			airlock_room = d.left if d.left >= 0 else d.right
			for d2 in s.env.doors:
				if not d2.airlock and (d2.left == airlock_room or d2.right == airlock_room):
					neighbour = d2.right if d2.left == airlock_room else d2.left
					d2.open = true
					d.open = true
					break
	s.env.tick(1.0 / 60.0)
	check("neighbour of an open airlock is not zeroed", s.env.oxygen[neighbour] > 99.0, true)
	run(s, 1.0)
	check("neighbour after 1 s between 78 and 92 %", s.env.oxygen[neighbour] > 78.0 and s.env.oxygen[neighbour] < 92.0, true)

	print("Floor colour (Room::OnRenderFloor)")
	check("100 % -> E6E2DB", ShipView.floor_color(100.0).to_html(false), "e6e2db")
	check("50 % -> step 12", ShipView.floor_color(50.0).to_html(false), Color8(242, 202, 195).to_html(false))
	check("0 % -> FFB0A9", ShipView.floor_color(0.0).to_html(false), "ffb0a9")

	print("Fire")
	s = new_ship()
	set_o2_power(s, 3)
	s.ignite(room, 0)
	s.env.spread_timers.clear()
	run(s, 12.6)
	check("1 fire, 12.6 s: weapons lose 1 bar (8 %/s)", s.sys("weapons").damage >= 1, true)

	s = new_ship()
	set_o2_power(s, 3)
	var pilot := s.sys("pilot").room
	s.ignite(pilot, 0)
	s.ignite(pilot, 1)
	var hp_before: float = s.crew[0].hp
	for i in 600:  # 10 s, without letting it spread to more tiles
		s.env.spread_timers.clear()
		s.env.tick(1.0 / 60.0)
	near("crew with 2 fires, 10 s: -42.6 HP", hp_before - s.crew[0].hp, 42.56, 0.5)

	print("Suffocation")
	s = new_ship()
	set_o2_power(s, 0)
	s.env.oxygen[pilot] = 0.0
	run(s, 5)
	near("oxygen < 5 %: -6.4 HP/s, 5 s", 100.0 - s.crew[0].hp, 32.0, 0.5)

	print("Fire without oxygen goes out")
	s = new_ship()
	set_o2_power(s, 0)
	var er := s.sys("medbay").room
	s.env.oxygen[er] = 0.0
	s.ignite(er, 0)
	for i in 360:  # 6 s, no spreading
		s.env.spread_timers.clear()
		s.env.oxygen[er] = 0.0
		s.env.tick(1.0 / 60.0)
	check("fire alone with O2 0: goes out in <= 5.84 s", s.fires.has(er), false)

	print("Spreading within the room (max 49 / 1.6 = 30.6 s)")
	s = new_ship()
	set_o2_power(s, 3)
	var big := -1
	for r in s.layout.rooms:
		if s.room_tiles(r.id) == 4:
			big = r.id
			break
	s.ignite(big, 0)
	run(s, 31)
	check("after 31 s more than 1 tile is on fire", s.fires[big].size() > 1, true)

	print("Door control box (ShipManager::ManipulateAllDoors, Z = open / X = close)")
	s = new_ship()
	var inner := 0
	var locks := 0
	for d in s.env.doors:
		if d.airlock:
			locks += 1
		else:
			inner += 1
	check("open all: every interior door opens", s.manipulate_all_doors(true), inner)
	check("  airlocks stay closed", s.env.doors.filter(func(d): return d.airlock and d.open).size(), 0)
	check("open again: now the airlocks open (vent)", s.manipulate_all_doors(true), locks)
	check("close all: interior + airlocks close", s.manipulate_all_doors(false), inner + locks)
	check("  everything closed", s.env.doors.filter(func(d): return d.open).size(), 0)
	s.sys("doors").ion = 2
	check("ionized doors system: buttons do nothing", s.manipulate_all_doors(true), 0)
	s.sys("doors").ion = 0
	s.damage_system("doors", s.sys("doors").get_level())
	check("broken doors system: nothing", s.manipulate_all_doors(true), 0)

	_test_sounds()



## Air and door sounds (rules/fire_and_oxygen.md "Sounds"): airLoss whoosh, airLeak loop flag, door sounds.
func _test_sounds() -> void:
	print("Sounds: airlock")
	var s := new_ship()
	var lock := -1
	var room := -1
	var inner := -1
	for i in s.env.doors.size():
		var d: Dictionary = s.env.doors[i]
		if d.airlock and lock < 0:
			lock = i
			room = d.left if d.left >= 0 else d.right
	for i in s.env.doors.size():
		var d: Dictionary = s.env.doors[i]
		if not d.airlock and (d.left == room or d.right == room):
			inner = i
			break
	s.env.set_door(lock, true)
	s.env.sound_log.clear()
	s.env.tick(1.0 / 60.0)
	check("airlock opens on a full room: airLoss once", s.env.sound_log.count("airLoss"), 1)
	check("  lone airlock room (emptied at once): no airLeak", s.env.leaking_o2, false)
	run(s, 1.0)
	check("  no second airLoss while it stays empty", s.env.sound_log.count("airLoss"), 1)
	s.env.set_door(inner, true)  # the neighbour now drains through the airlock room
	s.env.tick(1.0 / 60.0)
	check("neighbour drained through the open airlock: airLeak on", s.env.leaking_o2, true)
	s.env.set_door(lock, false)
	s.env.tick(1.0 / 60.0)
	check("airlock closed: airLeak off", s.env.leaking_o2, false)

	print("Sounds: breach")
	s = new_ship()
	var broom: int = s.sys("weapons").room
	s.env.sound_log.clear()
	s.add_breach(broom, 0)
	check("new breach in a room with air: airLoss", s.env.sound_log, ["airLoss"] as Array[String])
	s.add_breach(broom, 0)
	check("  same tile again: nothing", s.env.sound_log.size(), 1)
	s.env.tick(1.0 / 60.0)
	check("breach draining a room: airLeak on", s.env.leaking_o2, true)
	set_o2_power(s, 0)
	s.env.oxygen[broom] = 0.5
	s.env.tick(1.0 / 60.0)
	check("room at <= 1 %: airLeak off", s.env.leaking_o2, false)
	s.env.oxygen[broom] = 0.0
	s.env.sound_log.clear()
	s.add_breach(broom, 1)
	check("new breach in an airless room: no airLoss", s.env.sound_log.size(), 0)
	s.seal_breach(broom, 0)
	s.seal_breach(broom, 1)
	s.env.oxygen[broom] = 100.0
	s.env.tick(1.0 / 60.0)
	check("no breach, no open airlock: airLeak off", s.env.leaking_o2, false)

	print("Sounds: doors")
	s = new_ship()
	s.env.sound_log.clear()
	s.env.set_door(inner, true)
	s.env.update_door_sounds()
	check("player door opened: doorOpen", s.env.sound_log, ["doorOpen"] as Array[String])
	s.env.set_door(inner, false)
	s.env.update_door_sounds()
	check("closed: doorClose", s.env.sound_log, ["doorOpen", "doorClose"] as Array[String])
	s.env.sound_log.clear()
	s.env.doors[inner].crew_pass = 0.3  # crew walking through (Door::FakeOpen)
	s.env.tick(1.0 / 60.0)
	s.env.doors[inner].crew_pass = 0.0
	s.env.tick(1.0 / 60.0)
	check("crew walking through: doorOpen, doorClose", s.env.sound_log, ["doorOpen", "doorClose"] as Array[String])
	s.env.sound_log.clear()
	s.manipulate_all_doors(true)
	s.env.tick(1.0 / 60.0)
	check("open all: no per-door sounds (the button plays doorOpen x n)", s.env.sound_log.size(), 0)
	var e := ShipState.new("PLAYER_SHIP_HARD", false)
	e.env.set_door(inner, true)
	e.env.tick(1.0 / 60.0)
	check("enemy ship doors: silent", e.env.sound_log.filter(func(x): return x.begins_with("door")).size(), 0)
