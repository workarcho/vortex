extends Node
## Sound rules taken from the exe that are not tied to one system (scripts/audio/ship_sounds.gd, FtlData loops,
## jumpReady / enginesOff / levelup / autofire / downgradeSystem / store sell). Run:
##   godot --headless --path godot res://tests/test_sounds.tscn

const Harness := preload("res://tests/harness.gd")
const ShipSounds := preload("res://scripts/audio/ship_sounds.gd")

const DT := 1.0 / 60.0

var fails := 0


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func plays(sound: String) -> int:
	return FtlData.play_log.filter(func(r): return r.name == sound).size()


func step(s: ShipState, n := 1) -> void:
	for i in n:
		s.tick(DT * GameClock.BASE)


func make_run(seed := 5) -> RunState:
	var r := RunState.new_run(seed)
	for i in 10:
		if r.phase == RunState.Phase.DIALOG:
			r.choose(0)
		elif r.phase == RunState.Phase.MESSAGE:
			r.apply(RunIntent.make(RunIntent.CONTINUE))
	r.enemy = {}
	return r


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	FtlData.record_plays = true
	_test_loop_mechanics()
	_test_crew_loops()
	_test_fire_brawl_distress()
	_test_jump_ready()
	_test_engines_off()
	_test_levelup()
	_test_autofire()
	_test_downgrade_and_sell()
	FtlData.record_plays = false


func _test_loop_mechanics() -> void:
	print("UpdateSoundLoop")
	FtlData.play_log.clear()
	FtlData.update_sound_loop("fire", 2)
	check("count 2 starts the loop (logged once)", [FtlData.loop_count("fire"), plays("fire")], [2.0, 1])
	FtlData.update_sound_loop("fire", 3)
	check("a running loop is not started again", [FtlData.loop_count("fire"), plays("fire")], [3.0, 1])
	FtlData.update_sound_loop("fire", 9)
	check("count clamped to sounds.xml count (fire 4)", FtlData.loop_count("fire"), 4.0)
	FtlData.update_sound_loop("brawling", 7)
	check("brawling keeps its loop count 4 (the later plain entry does not replace it)",
		FtlData.loop_count("brawling"), 4.0)
	FtlData.update_sound_loop("fire", 0)
	FtlData.update_sound_loop("brawling", 0)
	check("count 0 stops it", [FtlData.loop_count("fire"), FtlData.loop_count("brawling")], [0.0, 0.0])
	FtlData.update_sound_loop("fire", 1)
	check("restart after a stop is logged again", plays("fire"), 2)
	FtlData.stop_sound_loop("fire")
	check("stop_sound_loop", FtlData.loop_count("fire"), 0.0)
	check("only distress plays through the pause", FtlData.UNPAUSABLE_LOOPS, ["distress"])


func _test_crew_loops() -> void:
	print("Crew loops (ShipManager::UpdateCrewmembers)")
	var s := ShipState.new("PLAYER_SHIP_HARD", true)
	step(s, 5)
	check("idle crew: nothing", ShipSounds.crew_loop_counts(s),
		{"repair": 0, "shrikeRepair": 0, "extinguish": 0, "healing": 0})
	# The pilot repairs its own (damaged) system from the console slot.
	s.damage_system("pilot", 1)
	step(s, 3)
	check("a crew member repairing a system -> repair 1", ShipSounds.crew_loop_counts(s).repair, 1)
	var pilot := s.crew[0]
	pilot.race = "anaerobic"
	check("Lanius repairing -> shrikeRepair", [ShipSounds.crew_loop_counts(s).repair,
		ShipSounds.crew_loop_counts(s).shrikeRepair], [0, 1])
	pilot.race = "rock"
	check("Rock repairing -> no sound", [ShipSounds.crew_loop_counts(s).repair,
		ShipSounds.crew_loop_counts(s).shrikeRepair], [0, 0])
	pilot.race = "human"
	pilot.stun = 1.0
	check("stunned -> not counted", ShipSounds.crew_loop_counts(s).repair, 0)
	pilot.stun = 0.0
	pilot.fighting = true
	check("fighting -> not counted", ShipSounds.crew_loop_counts(s).repair, 0)
	pilot.fighting = false
	pilot.task = CrewMember.Task.BREACH
	check("sealing a breach counts as repairing", ShipSounds.crew_loop_counts(s).repair, 1)
	pilot.task = CrewMember.Task.FIRE
	check("fighting a fire -> extinguish, not repair", [ShipSounds.crew_loop_counts(s).repair,
		ShipSounds.crew_loop_counts(s).extinguish], [0, 1])
	pilot.race = "crystal"
	check("Crystal fighting fire -> no extinguish (FireFightingSoundEffect false)",
		ShipSounds.crew_loop_counts(s).extinguish, 0)
	pilot.race = "human"
	pilot.frozen = true
	check("frozen -> no extinguish", ShipSounds.crew_loop_counts(s).extinguish, 0)
	pilot.frozen = false
	pilot.task = CrewMember.Task.SABOTAGE
	check("sabotage -> nothing", ShipSounds.crew_loop_counts(s).values().reduce(func(a, b): return a + b), 0)
	pilot.medbay_rate = 6.4
	pilot.stun = 1.0
	check("healed (even stunned) -> healing 1", ShipSounds.crew_loop_counts(s).healing, 1)
	pilot.stun = 0.0
	pilot.medbay_rate = -12.8
	check("hacked medbay (negative rate) -> no healing", ShipSounds.crew_loop_counts(s).healing, 0)
	pilot.medbay_rate = 0.0
	var enemy := ShipState.new("PLAYER_SHIP_HARD", false)
	enemy.crew[0].task = CrewMember.Task.REPAIR_SYSTEM
	check("enemy ship: no crew loops", ShipSounds.crew_loop_counts(enemy).repair, 0)
	# Simulated firefighting: a fire in the engines room, the engineer puts it out from its slot.
	var s2 := ShipState.new("PLAYER_SHIP_HARD", true)
	step(s2, 5)
	var eroom := s2.sys("engines").room
	s2.ignite(eroom, 0)
	step(s2, 3)
	check("crew on a fire -> extinguish 1", ShipSounds.crew_loop_counts(s2).extinguish, 1)
	check("one burning tile -> fire count 1", ShipSounds.fire_count(s2), 1)


func _test_fire_brawl_distress() -> void:
	print("fire / brawling / distress counts")
	var s := ShipState.new("PLAYER_SHIP_HARD", true)
	check("no fire", ShipSounds.fire_count(s), 0)
	s.fires = {0: {0: {"health": 100.0, "death": -1.0}, 1: {"health": 0.0, "death": -1.0}},
		1: {2: {"health": 50.0, "death": -1.0}}}
	check("burning tiles of the player ship (health > 0)", ShipSounds.fire_count(s), 2)
	var e := ShipState.new("PLAYER_SHIP_HARD", false)
	e.fires = s.fires.duplicate(true)
	check("enemy fires are silent", ShipSounds.fire_count(e), 0)
	s.fires = {}
	check("nobody punching", ShipSounds.brawl_count([s, e]), 0)
	s.crew[0].punch_time = 0.1
	e.crew[0].punch_time = 0.0
	e.crew[1].punch_time = 0.2
	e.crew[1].hp = 0.0
	check("punching crew of both ships, dead ones excluded", ShipSounds.brawl_count([s, e]), 2)
	var r := make_run()
	r.ship.fuel = 0
	r.distress = true
	r.map_open = false
	check("distress: map closed -> 0", ShipSounds.distress_count(r), 0)
	r.map_open = true
	check("distress: map open, out of fuel, toggle on -> 1", ShipSounds.distress_count(r), 1)
	r.distress = false
	check("toggle off -> 0", ShipSounds.distress_count(r), 0)
	r.distress = true
	r.ship.fuel = 3
	check("with fuel -> 0", ShipSounds.distress_count(r), 0)


func _test_jump_ready() -> void:
	print("jumpReady (ShipManager::OnLoop lastJumpReady)")
	FtlData.play_log.clear()
	var s := ShipState.new("PLAYER_SHIP_HARD", true)
	s.ftl_charge = 0.5
	check("charging: silent", [s.update_jump_ready_sound(), plays("jumpReady")], [false, 0])
	s.ftl_charge = 1.0
	check("becomes full: rings", [s.update_jump_ready_sound(), plays("jumpReady")], [true, 1])
	check("stays full: once", [s.update_jump_ready_sound(), plays("jumpReady")], [false, 1])
	# Run: a jump empties the drive; at a safe beacon SetSafe refills it -> the next tick rings again.
	var r := make_run()
	r.tick(DT)
	FtlData.play_log.clear()
	r.ship.ftl_charge = 0.3
	r.ship.last_jump_ready = false
	r.ship.fuel = 5
	r.tick(DT)  # safe beacon (no enemy): full at once
	check("safe beacon: the drive fills and rings once", [r.ship.ftl_charge, plays("jumpReady")], [1.0, 1])
	r.tick(DT)
	check("no second ring", plays("jumpReady"), 1)


func _test_engines_off() -> void:
	print("enginesOff (ShipManager::OnLoop lastEngineStatus)")
	FtlData.play_log.clear()
	var s := ShipState.new("PLAYER_SHIP_HARD", true)
	step(s)
	check("dodge > 0 from the start: silent (lastEngineStatus starts false)", [s.last_engine_status,
		plays("enginesOff"), plays("enginesOn")], [true, 0, 0])
	s.damage_system("engines", s.sys("engines").get_level())
	step(s)
	check("dodge drops to 0: enginesOff", [s.dodge_factor(), plays("enginesOff")], [0, 1])
	step(s, 3)
	check("only on the transition", plays("enginesOff"), 1)
	s.last_engine_status = false
	s.repair_system("engines", s.sys("engines").get_level())
	s.sys("engines").power = 1
	s.update_engine_sound()
	check("back up: no sound at all (no enginesOn in the exe)", [plays("enginesOn"), plays("enginesOff")], [0, 1])
	var e := ShipState.new("PLAYER_SHIP_HARD", false)
	e.last_engine_status = true
	e.damage_system("engines", e.sys("engines").get_level())
	check("enemy ship: never", [e.update_engine_sound(), plays("enginesOff")], [false, 1])


func _test_levelup() -> void:
	print("levelup (CrewMember::IncreaseSkill)")
	FtlData.play_log.clear()
	var c := CrewMember.new("human", true)
	var cap := c.skill_cap("combat")
	c.skills["combat"] = 0
	for i in cap / 2 - 1:
		c.add_skill("combat")
	check("below half: no level up", [plays("levelup"), c.level_up], [0, -1.0])
	c.add_skill("combat")
	check("reaching half: levelup + levelUp tracker + lastLevelUp", [plays("levelup"), c.level_up,
		c.last_level_up], [1, 0.0, "combat"])
	c.tick_level_up(1.0)
	check("tracker advances", c.level_up, 1.0)
	c.tick_level_up(1.0)
	check("stops after 2.0 s", c.level_up, -1.0)
	for i in cap - cap / 2:
		c.add_skill("combat")
	check("reaching the cap: a second levelup", plays("levelup"), 2)
	c.add_skill("combat")
	check("at the cap: nothing more", plays("levelup"), 2)
	var foe := CrewMember.new("human", false)
	foe.skills["combat"] = cap / 2 - 1
	foe.add_skill("combat")
	check("enemy crew: no levelup", plays("levelup"), 2)


func _test_autofire() -> void:
	print("autofireOn / autofireOff (WeaponControl::SetAutofiring)")
	FtlData.play_log.clear()
	var s := ShipState.new("PLAYER_SHIP_HARD", true)
	var wc := WeaponControl.new(s)
	wc.armed = 0
	wc.toggle_autofire()
	check("on: autofireOn, armed weapon dropped", [s.autofire, plays("autofireOn"), wc.armed], [true, 1, -1])
	wc.toggle_autofire()
	check("off: autofireOff", [s.autofire, plays("autofireOff")], [false, 1])
	s.set_autofire(true)
	check("state restore (load): silent", plays("autofireOn"), 1)


func _test_downgrade_and_sell() -> void:
	print("downgradeSystem / store sell")
	var r := make_run()
	r.ship.scrap = 200
	r.apply(ShipManagement.make(RunIntent.OPEN_SHIP_SCREEN, {"arg": 0}))
	FtlData.play_log.clear()
	r.apply(ShipManagement.make(RunIntent.UPGRADE_BUY, {"sys": "engines"}))
	check("buy: upgradeSystem", plays("upgradeSystem"), 1)
	r.apply(ShipManagement.make(RunIntent.UPGRADE_REFUND, {"sys": "engines"}))
	check("right-click refund: downgradeSystem (not undoUpgrades)", [plays("downgradeSystem"),
		plays("undoUpgrades")], [1, 0])
	r.apply(ShipManagement.make(RunIntent.UPGRADE_REFUND, {"sys": "engines"}))
	check("nothing to refund: silent", plays("downgradeSystem"), 1)
	r.apply(ShipManagement.make(RunIntent.CLOSE_SHIP_SCREEN))
	r.store_open = true
	var items := RunStore.sellable(r)
	var wi := -1
	for i in items.size():
		if items[i].kind == "weapon":
			wi = i
			break
	FtlData.play_log.clear()
	check("store SELL list: sold", r.apply(RunIntent.make(RunIntent.STORE_SELL, wi)), true)
	check("selling plays buy (sounds.xml sell is unused)", [plays("buy"), plays("sell")], [1, 0])
