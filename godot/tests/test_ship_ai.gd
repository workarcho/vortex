extends Node
## Tests for rules/combat_ai.md (enemy ShipAI: power allocation, firing, targeting). Run:
##   godot --headless --path godot res://tests/test_ship_ai.tscn

const Harness := preload("res://tests/harness.gd")

var fails := 0
var rng := RandomNumberGenerator.new()


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func near(name: String, got: float, want: float, tol: float) -> void:
	if absf(got - want) <= tol:
		print("  ok   ", name, " = %.3f (want %.3f ± %.3f)" % [got, want, tol])
	else:
		fails += 1
		print("  FAIL ", name, ": got %.3f, expected %.3f ± %.3f" % [got, want, tol])


## REBEL_FAT (oxygen 1, shields 2, engines 2, weapons, drones, pilot) with the given weapons and reactor.
func enemy(weapon_names: Array, reactor: int, shields_level := 2) -> ShipState:
	var s := ShipState.new("REBEL_FAT", false)
	s.weapons.clear()
	for i in weapon_names.size():
		var ws := WeaponState.new(FtlData.weapon_blueprint(weapon_names[i]), i)
		ws.powered = false
		s.weapons.append(ws)
	s.sys("weapons").override_level = 4
	s.sys("weapons").power = 0
	s.sys("shields").override_level = shields_level
	s.reactor_max = reactor
	return s


func ai_for(s: ShipState, seed_value := 1) -> ShipAI:
	var r := RandomNumberGenerator.new()
	r.seed = seed_value
	var ai := ShipAI.new(s, r)
	ai.target = ShipState.new("PLAYER_SHIP_HARD", true)
	return ai


func powered(s: ShipState) -> Array:
	return s.weapons.map(func(w): return w.powered)


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	ShipAI.difficulty = ShipAI.Difficulty.NORMAL

	print("Power order with a short reactor")
	var s := enemy(["LASER_BURST_1"], 2)
	var ai := ai_for(s)
	ai.check_power_levels()
	check("reactor 2: oxygen", s.sys("oxygen").power, 1)
	check("reactor 2: weapon powered", powered(s), [true])
	check("reactor 2: shields", s.sys("shields").power, 0)
	check("reactor 2: engines", s.sys("engines").power, 0)
	check("reactor 2: drones (not modelled -> 0)", s.sys("drones").power, 0)
	s = enemy(["LASER_BURST_1"], 3)
	ai = ai_for(s)
	ai.check_power_levels()
	check("reactor 3: shields (1 free bar is not a layer)", s.sys("shields").power, 0)
	check("reactor 3: engines get the bar", s.sys("engines").power, 1)

	print("Round-robin: weapon -> shield layer -> engines, per pass")
	s = enemy(["LASER_HEAVY_1", "LASER_HEAVY_1"], 8, 4)
	ai = ai_for(s)
	ai.check_power_levels()
	check("reactor 8: weapons", powered(s), [true, true])
	check("reactor 8: shields 2 layers", s.sys("shields").power, 4)
	check("reactor 8: engines 1 (pass 2 ran out)", s.sys("engines").power, 1)
	s = enemy(["LASER_HEAVY_1", "LASER_HEAVY_1"], 7, 4)
	ai = ai_for(s)
	ai.check_power_levels()
	check("reactor 7: shields 1 layer (2nd layer does not fit)", s.sys("shields").power, 2)
	check("reactor 7: engines take the last bar", s.sys("engines").power, 2)
	check("reactor 7: weapons", powered(s), [true, true])
	check("reactor 7: nothing left", s.reactor_free(), 0)

	print("Weapons: most charged first")
	s = enemy(["LASER_HEAVY_1", "LASER_HEAVY_1"], 2)
	s.weapons[0].charge = 2.0
	s.weapons[1].charge = 5.0
	ai = ai_for(s)
	ai.check_power_levels()
	check("charges 2 / 5 -> slot 2 powered", powered(s), [false, true])
	s = enemy(["LASER_HEAVY_1", "LASER_HEAVY_1"], 2)
	s.weapons[0].charge = 3.0
	s.weapons[1].charge = 3.0
	ai = ai_for(s)
	ai.check_power_levels()
	check("tie 3 / 3 -> earlier slot", powered(s), [true, false])
	s = enemy(["LASER_HEAVY_1", "LASER_HEAVY_1"], 2)
	s.weapons[0].charge = 3.2
	s.weapons[1].charge = 3.5
	ai = ai_for(s)
	ai.check_power_levels()
	check("3.2 / 3.5 -> later slot (best truncated to 3)", powered(s), [false, true])

	print("Re-allocation every frame keeps charge and shield layers")
	s = enemy(["LASER_HEAVY_1"], 8, 4)
	ai = ai_for(s)
	ai.check_power_levels()
	s.shield_layers = 2
	s.weapons[0].charge = 4.0
	for i in 3:
		ai.check_power_levels()
	check("shield layers kept", s.shield_layers, 2)
	check("weapon charge kept", s.weapons[0].charge, 4.0)
	check("weapon still powered", s.weapons[0].powered, true)

	print("Ion")
	s = enemy(["LASER_HEAVY_1"], 8, 4)
	ai = ai_for(s)
	ai.check_power_levels()
	var eng_before := s.sys("engines").power
	s.ion_system("engines", 1)
	ai.check_power_levels()
	check("ionized engines keep their frozen bars", s.sys("engines").power, eng_before - 1)
	check("  -> still locked", s.sys("engines").is_locked(), true)
	s = enemy(["LASER_HEAVY_1", "LASER_HEAVY_1"], 10, 4)
	ai = ai_for(s)
	ai.check_power_levels()
	check("two weapons powered", powered(s), [true, true])
	s.ion_system("weapons", 1)
	ai.check_power_levels()
	check("ion 1 on weapons: last slot off, first kept", powered(s), [true, false])
	var f := GameClock.factor(1.0 / 60.0)
	for i in 330:  # 5.5 s
		s.tick(f)
		ai.tick(1.0 / 60.0)
	check("ion over: weapon re-powered by the AI", powered(s), [true, true])

	print("Medbay only with hurt crew")
	s = ShipState.new("PLAYER_SHIP_HARD", false)
	s.reactor_max = 2
	ai = ai_for(s)
	ai.check_power_levels()
	check("crew healthy: medbay", s.sys("medbay").power, 0)
	s.crew[0].hp = s.crew[0].max_hp * 0.2
	ai.check_power_levels()
	check("crew at 20 %: medbay", s.sys("medbay").power, 1)
	s.crew[0].hp = s.crew[0].max_hp * 0.5
	s.damage_system("engines", 1)
	check("50 % hp, ship not calm -> hurt", ai.crew_hurt(), false)

	print("Firing: each shot of a volley picks a different room")
	s = enemy(["LASER_BURST_3"], 10, 4)
	ai = ai_for(s, 7)
	ai.check_power_levels()
	var all_distinct := true
	for i in 300:
		var pts := ai.pick_points(3)
		for j in pts.size():
			if pts.find(pts[j]) != j:
				all_distinct = false
	check("300 volleys of 3: all points distinct", all_distinct, true)
	var w := s.weapons[0]
	w.charge = w.max_charge(0)
	ai.update_weapons()
	check("charged weapon gets a target", w.has_target(), true)
	check("  -> 3 per-shot points", w.pending_points.size(), 3)
	var rooms := {}
	for p in w.pending_points:
		rooms[ai.target.room_at(p)] = true
	check("  -> 3 different rooms", rooms.size(), 3)
	check("  -> points are room centers", w.pending_points[0] == ai.target.room_rect(
		ai.target.room_at(w.pending_points[0])).get_center(), true)
	w.queued_shots = 1
	w.clear_target()
	ai.update_weapons()
	check("previous volley still queued -> no new firing", w.has_target(), false)

	print("PrioritizeSystem by difficulty")
	var tgt := ShipState.new("PLAYER_SHIP_HARD", true)
	for tw in tgt.weapons:  # startup leaves player weapons unpowered (rules/power.md)
		tgt.try_power_weapon(tw)
	var have := 0
	for id in ShipAI.SYSTEM_TARGETS:
		if tgt.sys(id) != null:
			have += 1
	for d in [[ShipAI.Difficulty.EASY, 0.20, "easy"], [ShipAI.Difficulty.NORMAL, 0.33, "normal"]]:
		ShipAI.difficulty = d[0]
		ai = ai_for(s, 42)
		ai.target = tgt
		var hits := 0
		var n := 20000
		for i in n:
			if ai.prioritize_system() != "":
				hits += 1
		near("%s: system chosen" % d[2], float(hits) / n, d[1] * have / 5.0, 0.015)
	ShipAI.difficulty = ShipAI.Difficulty.HARD
	ai = ai_for(s, 43)
	ai.target = tgt
	var keys := ai.key_targets()
	check("hard: shields/weapons are key targets (powered)", keys.has("shields") and keys.has("weapons"), true)
	check("hard: medbay/sensors never key targets", keys.has("medbay") or keys.has("sensors"), false)
	var rooms_n := 0
	var key_n := 0
	var n2 := 20000
	for i in n2:
		var id := ai.prioritize_system()
		if id == "":
			rooms_n += 1
		elif keys.has(id):
			key_n += 1
	near("hard: random room", float(rooms_n) / n2, 0.5, 0.015)
	# 25 % key + key systems drawn by the 25 % random-system branch
	near("hard: key systems", float(key_n) / n2,
		0.25 + 0.25 * keys.size() / float(tgt.systems.size()), 0.015)
	ShipAI.difficulty = ShipAI.Difficulty.NORMAL

	print("Charge goal")
	var cw := WeaponState.new(FtlData.weapon_blueprint("LASER_CHARGEGUN_2"), 0)
	check("LASER_CHARGEGUN_2 charge levels", cw.charge_levels(), 4)
	var seen := {}
	var in_range := true
	for i in 2000:
		var g := ai.select_charge_goal(cw)
		seen[g] = true
		if g < 1 or g > 4:
			in_range = false
	check("goal always in 1..4", in_range, true)
	check("every goal 1..4 appears", seen.size(), 4)
	var single := WeaponState.new(FtlData.weapon_blueprint("LASER_BURST_1"), 0)
	check("single-charge weapon goal", ai.select_charge_goal(single), 1)

	print("Multi-charge firing: waits for its goal, then fires with level shots")
	s = enemy(["LASER_CHARGEGUN_2"], 10, 4)
	ai = ai_for(s, 5)
	ai.check_power_levels()
	w = s.weapons[0]
	ai.charge_goals[w] = 3
	w.charge_level = 2
	ai.update_weapons()
	check("level 2 < goal 3 -> no firing", w.has_target(), false)
	w.charge_level = 4
	ai.update_weapons()
	check("level 4 (full) >= goal -> fires", w.has_target(), true)
	check("  -> 4 points (one per charge level)", w.pending_points.size(), 4)

