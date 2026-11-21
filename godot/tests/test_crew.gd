extends Node
## Tests for rules/crew.md (movement, slots, doors, manning, repair, firefighting). Run:
##   godot --headless --path godot res://tests/test_crew.tscn

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


func new_ship() -> ShipState:
	return ShipState.new("PLAYER_SHIP_HARD", true)


## One frame of the full ship simulation (crew, systems, environment) at normal speed.
func step(s: ShipState) -> void:
	s.tick(DT * GameClock.BASE)


## Game seconds until cond() is true (or max_s + 1 if it never happens).
func time_until(s: ShipState, cond: Callable, max_s: float, per_step := Callable()) -> float:
	var t := 0.0
	while t <= max_s:
		if cond.call():
			return t
		if per_step.is_valid():
			per_step.call()
		step(s)
		t += DT
	return max_s + 1.0


func room_of(s: ShipState, sys_id: String) -> int:
	return s.sys(sys_id).room


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	var s := new_ship()
	var pilot := s.crew[0]
	var engineer := s.crew[1]
	var gunner := s.crew[2]

	print("Initial placement (one per system, on its console slot)")
	check("3 crew", s.crew.size(), 3)
	check("pilot in piloting room", pilot.room, room_of(s, "pilot"))
	check("pilot on console slot 0 (blueprint <slot>)", pilot.slot, 0)
	check("engineer in engines room", engineer.room, room_of(s, "engines"))
	check("gunner in weapons room", gunner.room, room_of(s, "weapons"))
	check("crew_rooms has the 3 rooms", s.crew_rooms.size(), 3)
	check("Kestrel start evasion: engines 1 (5, startup power) + engines crew 5 + pilot 5", s.dodge_factor(), 15)

	print("Walking speed (80 px/s): pilot room 0 -> room 1 through one door")
	s = new_ship()
	pilot = s.crew[0]
	check("order accepted", s.order_crew_move([pilot], 1), 1)
	# slot (14,2) -> door entry tile (14,3): 35 px; through the door to (13,3): 35 px;
	# diagonal to slot 0 of room 1 (12,2): 35*sqrt(2).
	var length := 70.0 + 35.0 * sqrt(2.0)
	var t := time_until(s, func(): return not pilot.is_walking(), 10.0)
	near("time = %.1f px / 80" % length, t, length / 80.0, length / 80.0 * 0.05)
	check("arrived in room 1", pilot.room, 1)
	check("standing on slot 0", pilot.is_on_slot(s) and pilot.slot == 0, true)

	print("Pathfinding through doors (piloting -> oxygen, not adjacent)")
	s = new_ship()
	pilot = s.crew[0]
	var o2 := room_of(s, "oxygen")
	s.order_crew_move([pilot], o2)
	var doors_crossed := 0
	for wp in pilot.path:
		if wp.door >= 0:
			doors_crossed += 1
	check("path crosses several doors", doors_crossed >= 3, true)
	var always_inside := true
	var fake_open_seen := false
	var real_open := false
	t = 0.0
	while pilot.is_walking() and t < 30.0:
		step(s)
		t += DT
		if s.room_at(pilot.pos) < 0:
			always_inside = false
		for d in s.env.doors:
			if d.crew_pass > 0.0:
				fake_open_seen = true
			if d.open:
				real_open = true
	check("arrived in the oxygen room", pilot.room, o2)
	check("always inside a room (no wall crossing)", always_inside, true)
	check("crossed closed doors show open (crew_pass > 0)", fake_open_seen, true)
	check("doors' real state unchanged (still closed)", real_open, false)
	check("piloting room now empty -> autopilot with 1 power = 0 % evasion", s.dodge_factor(), 0)

	print("Slots: console first, full room ignored")
	s = new_ship()
	var sensors := room_of(s, "sensors")  # 2x1, console slot 1
	s.order_crew_move([s.crew[1]], sensors)
	check("first crew into sensors gets console slot 1", s.crew[1].slot, 1)
	s.order_crew_move([s.crew[2]], sensors)
	check("second crew gets lowest free slot 0", s.crew[2].slot, 0)
	check("third crew into the full sensors room: ignored", s.order_crew_move([s.crew[0]], sensors), 0)
	check("  ...and stays in the piloting room", s.crew[0].target_room, room_of(s, "pilot"))

	print("System repair (8/s, 12.5 s per bar)")
	s = new_ship()
	s.damage_system("weapons", 1)
	var w := s.sys("weapons")
	t = time_until(s, func(): return w.damage == 0, 20.0)
	near("1 repairer: 1 bar", t, 12.5, 0.3)
	check("gunner gained 1 repair progress", s.crew[2].skills.repair, 1)

	s = new_ship()
	w = s.sys("weapons")
	s.order_crew_move([s.crew[1]], w.room)
	time_until(s, func(): return not s.crew[1].is_walking(), 20.0)
	s.damage_system("weapons", 1)
	t = time_until(s, func(): return w.damage == 0, 20.0)
	near("2 repairers stack: half the time", t, 6.25, 0.3)

	s = new_ship()
	w = s.sys("weapons")
	s.damage_system("weapons", 1)
	time_until(s, func(): return false, 5.0)
	s.order_crew_move([s.crew[2]], 1)  # repairer leaves
	time_until(s, func(): return false, 3.0)
	check("repair progress reset once no friendly is in the room (bFriendlies)", w.repair_progress, 0.0)

	print("Progress reset rules (ShipSystem::OnLoop)")
	var u := SystemState.new("weapons", 0, 3)
	u.damage = 1
	check("partial repair marks the frame", [u.partial_repair(40.0), u.repaired_last_frame], [false, true])
	u.friendlies = false
	u.loop_progress()
	check("  repaired this frame: kept", u.repair_progress, 40.0)
	u.friendlies = true
	u.loop_progress()
	check("  not repaired, friendlies present: kept", u.repair_progress, 40.0)
	u.friendlies = false
	u.loop_progress()
	check("  not repaired, no friendlies: reset", u.repair_progress, 0.0)
	u.damage_over_time(30.0)
	u.loop_progress()
	check("damaged this frame: kept", u.damage_progress, 30.0)
	u.occupied = true
	u.loop_progress()
	check("  not damaged, intruders present: kept", [u.damage_progress, u.sabotaged()], [30.0, true])
	u.occupied = false
	u.loop_progress()
	check("  not damaged, no intruders: reset", [u.damage_progress, u.sabotaged()], [0.0, false])
	check("damage_over_time breaks a bar at 100", [u.damage_over_time(60.0), u.damage_over_time(40.0),
		u.damage_progress], [false, true, 0.0])

	s = new_ship()
	var sh := s.sys("shields")
	s.crew.clear()
	s.ignite(sh.room, 0)
	time_until(s, func(): return false, 2.0, func(): s.env.spread_timers.clear())
	check("fire builds damage progress", sh.damage_progress > 0.0, true)
	for tile in (s.fires.get(sh.room, {}) as Dictionary).keys():
		s.extinguish(sh.room, tile)
	step(s)
	step(s)
	check("  fire gone, no intruders: progress reset (no stuck red bar)", sh.damage_progress, 0.0)
	var boarder := s.add_crew("human", false, sh.room)
	step(s)
	check("intruder in the room: bOccupied", [sh.occupied, sh.friendlies], [true, false])
	boarder.hp = 0.0
	step(s)
	check("  dead intruder does not count", sh.occupied, false)

	print("Firefighting (fire 100, -8 x 1.2 /s -> 10.4 s) and breaches (12.5 s)")
	s = new_ship()
	var wr := room_of(s, "weapons")
	s.ignite(wr, 3)
	var no_spread := func(): s.env.spread_timers.clear()
	t = time_until(s, func(): return not s.fires.has(wr), 20.0, no_spread)
	near("1 human puts out a fire", t, 100.0 / 9.6, 0.3)

	s = new_ship()
	s.add_breach(wr, 2)
	t = time_until(s, func(): return not s.breaches.has(wr), 20.0)
	near("1 human repairs a breach", t, 12.5, 0.3)

	print("Task priority: fire > breach > system")
	s = new_ship()
	gunner = s.crew[2]
	w = s.sys("weapons")
	s.ignite(wr, 0)
	s.add_breach(wr, 1)
	s.damage_system("weapons", 1)
	time_until(s, func(): return false, 1.0, func(): s.env.spread_timers.clear())
	check("fights the fire first", gunner.task, CrewMember.Task.FIRE)
	check("  breach untouched", s.breaches[wr][1].health, 100.0)
	check("  no system repair progress", w.repair_progress, 0.0)
	time_until(s, func(): return not s.fires.has(wr), 20.0, func(): s.env.spread_timers.clear())
	step(s)
	check("then the breach", gunner.task, CrewMember.Task.BREACH)
	time_until(s, func(): return not s.breaches.has(wr), 20.0)
	step(s)
	check("then the system", gunner.task, CrewMember.Task.REPAIR_SYSTEM)

	print("Manning bonus (console slot, idle, undamaged system)")
	s = new_ship()
	check("pilot on console: bonus level 1", s.crew_level_in("pilot"), 1)
	check("weapons on console: bonus level 1", s.crew_level_in("weapons"), 1)
	check("oxygen (not boostable, nobody there): 0", s.crew_level_in("oxygen"), 0)
	s.crew[0].place(s, room_of(s, "pilot"), 1)
	check("pilot on the other slot: no bonus", s.crew_level_in("pilot"), 0)
	check("  but the room is still manned", s.is_manned("pilot"), true)
	check("  evasion = engines 5 + engines crew 5 (no pilot bonus, not autopilot)", s.dodge_factor(), 10)
	s = new_ship()
	s.damage_system("engines", 1)
	check("engines damaged: no engines bonus (IsMannedBoost)", s.crew_level_in("engines"), 0)
	s = new_ship()
	s.order_crew_move([s.crew[2]], 1)
	step(s)
	check("walking crew: no weapons bonus", s.crew_level_in("weapons"), 0)
	s = new_ship()
	s.add_breach(wr, 0)
	step(s)
	check("repairing a breach: no weapons bonus", s.crew_level_in("weapons"), 0)


	print("Console slot and facing (ShipManager::AddSystem / Ship::ChoosePrimarySlot)")
	s = new_ship()
	check("Kestrel shields (no <slot>): player default slot 0, facing left",
		[s.graph.console_slot(room_of(s, "shields")), s.graph.console_dir(room_of(s, "shields"))], [0, "left"])
	check("Kestrel engines (no <slot>): slot 2, facing down",
		[s.graph.console_slot(room_of(s, "engines")), s.graph.console_dir(room_of(s, "engines"))], [2, "down"])
	check("Kestrel weapons (no <slot>): slot 1, facing up",
		[s.graph.console_slot(room_of(s, "weapons")), s.graph.console_dir(room_of(s, "weapons"))], [1, "up"])
	check("Kestrel pilot (blueprint <slot> right / 0) wins",
		[s.graph.console_slot(room_of(s, "pilot")), s.graph.console_dir(room_of(s, "pilot"))], [0, "right"])
	check("oxygen (not boostable): no console", s.graph.console_slot(room_of(s, "oxygen")), -1)
	check("player medbay without <slot>: blocked tile 1", s.graph.blocked_slot(room_of(s, "medbay")), 1)
	check("engineer starts on the engines console (slot 2)", s.crew[1].slot, 2)
	check("gunner starts on the weapons console (slot 1)", s.crew[2].slot, 1)
	for _i in 30:
		step(s)
	check("engineer faces the engines console (down)", s.crew[1].facing, "down")
	var en := ShipState.new("REBEL_FAT", false)
	check("enemy pilot without <slot>: slot 0 facing up",
		[en.graph.console_slot(en.sys("pilot").room), en.graph.console_dir(en.sys("pilot").room)], [0, "up"])
	var sr := en.sys("shields").room
	var pick := en.graph.choose_primary_slot(sr)
	check("enemy shields: ChoosePrimarySlot picks a tile of the room", pick[0] >= 0 and pick[0] < en.graph.slot_count(sr), true)
	check("  facing one of the four walls", pick[1] in ["up", "down", "left", "right"], true)
	check("  reproducible", en.graph.choose_primary_slot(sr), pick)
	check("  is the console", en.graph.console_slot(sr), pick[0])

	print("Manning level boost (GetEffectivePower: sensors / doors +1 when manned and intact)")
	s = new_ship()
	var sens_room := room_of(s, "sensors")
	var sens_lvl := s.sys("sensors").get_level()
	check("unmanned sensors: effective = level", s.system_power("sensors"), sens_lvl)
	check("  manning icon manning_bar_off", SystemPowerColumn.manning_icon(s, s.sys("sensors"))[0], "manning_bar_off")
	s.crew[0].place(s, sens_room, s.graph.console_slot(sens_room))
	step(s)
	check("manned sensors: effective = level + 1", s.system_power("sensors"), sens_lvl + 1)
	check("  manning icon manning_bar_on", SystemPowerColumn.manning_icon(s, s.sys("sensors"))[0], "manning_bar_on")
	s.damage_system("sensors", 1)
	step(s)
	check("damaged manned sensors: no boost", s.system_power("sensors"), sens_lvl - 1)
	check("  no manning icon (BlockedBoosted)", SystemPowerColumn.manning_icon(s, s.sys("sensors")), [])
	s = new_ship()
	s.sys("sensors").level = 3
	check("DoSensorsProvide(3) (enemy power bars) needs effective > 3: level 3 alone no", s.sensors_provide(3), false)
	check("  weapon charge (4) needs > 2: yes", s.sensors_provide(4), true)
	s.crew[0].place(s, sens_room, s.graph.console_slot(sens_room))
	step(s)
	check("  level 3 manned (effective 4): power bars yes", s.sensors_provide(3), true)
	s = new_ship()
	s.crew[0].place(s, room_of(s, "doors"), s.graph.console_slot(room_of(s, "doors")))
	step(s)
	check("manned doors: +1", s.system_power("doors"), s.sys("doors").get_level() + 1)
	check("manned shields: no level boost (not level-boostable)", s.system_power("shields"), s.sys("shields").power)
	check("pilot left its console: manning_outline", SystemPowerColumn.manning_icon(s, s.sys("pilot"))[0],
		"manning_outline")
	s = new_ship()
	check("pilot manned (skill 1): manning_white", SystemPowerColumn.manning_icon(s, s.sys("pilot"))[0], "manning_white")
	check("shields unmanned: manning_outline", SystemPowerColumn.manning_icon(s, s.sys("shields"))[0], "manning_outline")
	check("medbay (not boostable): no icon", SystemPowerColumn.manning_icon(s, s.sys("medbay")), [])

	print("Hits and deaths")
	s = new_ship()
	var d := Damage.from_weapon(FtlData.weapon_blueprint("LASER_BURST_3"))
	var rng := RandomNumberGenerator.new()
	s.crew[2].hp = 10.0
	s.apply_damage(wr, d, rng)
	s.crew_changed()
	check("gunner killed by the hit", s.crew[2].is_alive(), false)
	check("weapons room no longer in crew_rooms", s.crew_rooms.has(wr), false)
	check("dead crew frees its slot (room accepts a new crew)", s.graph.find_slot(wr) >= 0, true)

	_test_low_health_sound()

	print("Saved stations at start (ShipManager::OnInit -> SaveCrewPositions)")
	s = new_ship()
	var pilot_room := room_of(s, "pilot")
	check("pilot's saved station = its starting console", [s.crew[0].saved_room, s.crew[0].saved_slot],
		[pilot_room, s.graph.console_slot(pilot_room)])
	s.order_crew_move([s.crew[0]], room_of(s, "medbay"))
	time_until(s, func(): return s.crew[0].is_on_slot(s), 10.0)
	check("return to stations works without saving first", s.restore_crew_positions(), true)
	time_until(s, func(): return s.crew[0].is_on_slot(s), 10.0)
	check("  pilot back on its console", [s.crew[0].room, s.crew[0].slot], [pilot_room, s.graph.console_slot(pilot_room)])

	print("New crew placement (AddCrewMember roomId -1 -> pilot room, Ship::GetAvailableRoom)")
	s = new_ship()
	var nc := s.add_crew("mantis", true)
	check("event / store crew lands in the pilot room", nc.room, pilot_room)
	check("  gets a name (CrewIdentity)", nc.name_long != "", true)
	check("  no saved station (only OnInit saves)", nc.saved_room, -1)
	var nc2 := s.add_crew("engi", true)  # Kestrel pilot room has 2 slots: now full
	var conn := []
	for d2 in s.env.doors:
		if int(d2.left) == pilot_room and int(d2.right) >= 0:
			conn.append(int(d2.right))
		elif int(d2.right) == pilot_room and int(d2.left) >= 0:
			conn.append(int(d2.left))
	check("pilot room full: first room through its doors", nc2.room, conn[0] if not conn.is_empty() else -1)
	check("available_room keeps a free preferred room", s.available_room(room_of(s, "medbay"), null),
		room_of(s, "medbay"))

	print("Typing animation (bActiveManning)")
	s = new_ship()
	check("pilot on its console types (calm, no enemy)", ShipView.is_typing(s, s.crew[0]), true)
	var o2_room := room_of(s, "oxygen")
	s.crew[1].place(s, o2_room, s.graph.console_slot(o2_room))
	step(s)
	check("oxygen (not boostable): no typing", ShipView.is_typing(s, s.crew[1]), false)



## CrewMember::DirectModifyHealth -> lowCrewHealth: (int)new < 26 and (int)old > 25, player-owned non-drone crew,
## once per crossing (rules/crew.md "Low health warning").
func _test_low_health_sound() -> void:
	print("Low health warning sound (lowCrewHealth)")
	check("lowCrewHealth exists in sounds.xml", FtlData.has_sound("lowCrewHealth"), true)
	var was_muted := FtlData.muted
	FtlData.muted = true
	FtlData.record_plays = true
	var plays := func() -> int:
		var n := FtlData.play_log.filter(func(r): return r.name == "lowCrewHealth").size()
		FtlData.play_log.clear()
		return n
	FtlData.play_log.clear()
	# Ship weapon damage (LASER_BURST_3: 15 crew HP per hit) on the gunner, alone in the weapons room.
	var s := new_ship()
	var wr := room_of(s, "weapons")
	var gunner := s.crew[2]
	var d := Damage.from_weapon(FtlData.weapon_blueprint("LASER_BURST_3"))
	var rng := RandomNumberGenerator.new()
	gunner.hp = 40.0
	s.apply_damage(wr, d, rng)
	check("weapon hit 40 -> 25 HP: plays once", [gunner.hp, plays.call()], [25.0, 1])
	s.apply_damage(wr, d, rng)
	check("already low (25 -> 10): silent", [gunner.hp, plays.call()], [10.0, 0])
	gunner.hp = 30.0  # healed back above the threshold
	s.apply_damage(wr, d, rng)
	check("healed above, hit again (30 -> 15): plays again", plays.call(), 1)
	gunner.hp = 26.5
	s.apply_damage(wr, d, rng)
	check("integer health: 26.5 -> 11.5 plays", plays.call(), 1)
	# Edge cases on the check itself (integer truncation; absolute HP, not a fraction of the maximum).
	var c := CrewMember.new("human", true)
	c.hp = 25.9
	c.check_low_health_sound(26.0)
	check("26.0 -> 25.9 (int 26 -> 25): plays", plays.call(), 1)
	c.hp = 25.0
	c.check_low_health_sound(25.9)
	check("25.9 -> 25.0 (int 25 -> 25): silent", plays.call(), 0)
	c.hp = 0.0
	c.check_low_health_sound(100.0)
	check("100 -> 0 in one change (lethal hit): plays", plays.call(), 1)
	var rock := CrewMember.new("rock", true)
	rock.hp = 37.0  # 25 % of 150 would be 37.5: the threshold is absolute
	rock.check_low_health_sound(40.0)
	check("rock 40 -> 37 (150 max): silent (absolute 25 HP threshold)", plays.call(), 0)
	var enemy := CrewMember.new("human", false)
	enemy.hp = 10.0
	enemy.check_low_health_sound(50.0)
	check("enemy-owned crew: silent", plays.call(), 0)
	var drone := CrewMember.new("human", true)
	drone.make_drone("battle")
	drone.hp = 10.0
	drone.check_low_health_sound(50.0)
	check("player crew drone: silent", plays.call(), 0)
	# Suffocation over time (ShipEnvironment._tick_crew -> UpdateHealth -> DirectModifyHealth): one play per crossing.
	s = new_ship()
	var pilot := s.crew[0]
	pilot.hp = 27.0
	for i in 60:  # 1 s at 6.4 HP/s: 27 -> ~20.6
		s.env.oxygen[pilot.room] = 0.0
		s.env._tick_crew(1.0 / 60.0)
	check("suffocating 27 -> %.1f HP: plays exactly once" % pilot.hp, plays.call(), 1)
	# Kill (health set to 0 directly) never plays it.
	s = new_ship()
	ClonebayRule.kill_no_clone(s.crew[0])
	for i in 10:
		step(s)
	check("Kill (direct health = 0): silent", plays.call(), 0)
	FtlData.record_plays = false
	FtlData.play_log.clear()
	FtlData.muted = was_muted
