extends Node
## Tests for the Last Stand and the Rebel Flagship (rules/flagship.md): stage blueprints and crew, the boss-level
## map (base / flagship path lengths, events, fleet), the flagship's turns (UpdateBoss, arrival countdown, base
## destroyed), the fight flow (BOSS_TEXT_n, jump-out of stages 1 / 2, crew carried over, BOSS_ESCAPED /
## BOSS_DESTROYED, victory), power surges (drones, barrage, super shield), automated crew, waiting, stalemate. Run:
##   godot --headless --path godot res://tests/test_flagship.tscn

const Harness := preload("res://tests/harness.gd")

var fails := 0
var rng := RandomNumberGenerator.new()


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	FtlData.muted = true
	rng.seed = 7
	test_blueprints()
	test_map()
	test_turns()
	test_fight_flow()
	test_surges()
	test_automated_and_crew()
	test_wait_and_stalemate()


func new_run(seed: int, diff := EventEngine.Difficulty.NORMAL, ae := true) -> RunState:
	var r := RunState.new_run(seed, "PLAYER_SHIP_HARD", diff, "", ae)
	r.score.track_profile = false  # never touch the player's profile
	LastStand.debug_enter(r)
	return r


func test_blueprints() -> void:
	print("Stage ships (BossShip::StartStage)")
	check("normal AE stage 1", FlagshipRule.blueprint_name(1, 1, true), "BOSS_1_NORMAL_DLC")
	check("easy stage 2", FlagshipRule.blueprint_name(2, 0, false), "BOSS_2_EASY")
	check("hard AE stage 3", FlagshipRule.blueprint_name(3, 2, true), "BOSS_3_HARD_DLC")
	for d in 3:
		for ae in [false, true]:
			for st in [1, 2, 3]:
				var n := FlagshipRule.blueprint_name(st, d, ae)
				check("blueprint exists " + n, FtlData.has_ship_blueprint(n), true)
	var s1 := FlagshipRule.build(1, 1, true, [])
	check("stage 1 crew: 11 humans", s1.crew.size(), 11)
	var rooms := s1.crew.map(func(c): return c.room)
	rooms.sort()
	check("stage 1 crew rooms", rooms, FlagshipRule.STAGE1_CREW_ROOMS)
	check("crew are enemy humans", s1.crew.all(func(c): return not c.player_owned and c.race == "human"), true)
	check("10 drone parts", s1.drone_parts, 10)
	check("stage 1 invincible (jump-out)", FlagshipRule.invincible(s1), true)
	check("four artillery systems", s1.artillery.size(), 4)
	var s3 := FlagshipRule.build(3, 1, true, FlagshipRule.stage_crew(1, [], 19))
	check("stage 3 not invincible", FlagshipRule.invincible(s3), false)
	check("stage 3 super shield 12", [s3.super_shield, s3.super_shield_max], [12, 12])
	check("stage 3 crew trimmed to its rooms", s3.crew.size() <= 11, true)
	var counts := FlagshipRule.stage_crew(1, [], 19)
	counts[0] = 0
	counts[1] = 3
	var s2 := FlagshipRule.build(2, 1, true, counts)
	var want := 0
	for i in mini(counts.size(), s2.layout.rooms.size()):
		want += int(counts[i])
	check("stage 2 crew from the counts (rooms beyond the layout dropped)", s2.crew.size(), want)
	check("3 crew placed in room 1", s2.crew.filter(func(c): return c.room == 1).size(), 3)


func test_map() -> void:
	print("Boss-level map (GenerateMap bossLevel)")
	for diff in [EventEngine.Difficulty.EASY, EventEngine.Difficulty.NORMAL, EventEngine.Difficulty.HARD]:
		for seed in [1, 2, 3, 4, 5, 11]:
			var r := new_run(seed, diff)
			var m := r.map
			var B := r.boss
			var tag := "d%d s%d" % [diff, seed]
			check(tag + " active", LastStand.active(r), true)
			check(tag + " last sector", r.is_last_sector(), true)
			var n := m.path(m.start, m.exit).size()
			var ok := n == 4 if diff != EventEngine.Difficulty.HARD else (n == 5 or n == 6)
			check(tag + " start -> base jumps (%d nodes)" % n, ok, true)
			var p: Array = B.path
			check(tag + " flagship path 4..6 nodes", p.size() >= 4 and p.size() <= 6, true)
			check(tag + " path ends at the base", int(p[-1]), m.exit)
			check(tag + " path is a shortest path", p.size(), m.path(int(p[0]), m.exit).size())
			check(tag + " flagship beacon overtaken", m.beacons[int(p[0])].fleet and m.beacons[int(p[0])].boss, true)
			check(tag + " base event", String(m.beacons[m.exit].event.name), "FEDERATION_BASE")
			check(tag + " start event", String(r.dialog.get("name", "")), "LAST_STAND_START")
			check(tag + " fleet parked", r.fleet.center, LastStand.DANGER_ZONE)
			var stores := m.beacons.filter(func(b): return b.event.get("store", false)).size()
			check(tag + " at most one store (a store under the flagship start is overtaken)", stores <= 1, true)
	var r2 := new_run(3)
	var r3 := new_run(3)
	check("same seed -> same map", [r2.boss.path, r2.map.exit], [r3.boss.path, r3.map.exit])


func test_turns() -> void:
	print("Flagship turns (UpdateBoss) and the base countdown")
	var r := new_run(3)
	var B := r.boss
	var p: Array = B.path.duplicate()
	var hops := p.size() - 1
	for i in hops:
		LastStand.update_boss(r)
		check("turn %d prepare: jumping" % (2 * i + 1), B.jumping, true)
		check("turn %d still at %d" % [2 * i + 1, int(p[i])], LastStand.boss_beacon(r), int(p[i]))
		LastStand.update_boss(r)
		check("turn %d moved to %d" % [2 * i + 2, int(p[i + 1])], LastStand.boss_beacon(r), int(p[i + 1]))
		if i + 1 < hops:
			check("moved onto a fleet beacon", r.map.beacons[int(p[i + 1])].fleet, true)
	check("at the base: arrived 1", B.arrived, 1)
	check("base not overtaken", r.map.beacons[r.map.exit].fleet, false)
	check("turns left 3", LastStand.turns_left(r), 3)
	r.current_beacon = r.map.start
	LastStand.update_boss(r)
	LastStand.update_boss(r)
	check("two more turns: 2", B.arrived, 3)
	check("not yet lost", LastStand.base_destroyed(r), false)
	LastStand.update_boss(r)
	check("arrived capped at 4", B.arrived, 4)
	check("base destroyed (player elsewhere)", LastStand.base_destroyed(r), true)
	r.current_beacon = r.map.exit
	check("player fighting at the base: not lost", LastStand.base_destroyed(r), false)
	r.current_beacon = r.map.start
	r.phase = RunState.Phase.IDLE
	LastStand.tick(r)
	check("game over", [r.over, r.over_cause], ["gameover", "gameover_fedbase"])
	var changing := r.map.beacons.filter(func(b): return b.get("fleet_changing", false))
	check("fleetChanging beacons are never the base", changing.all(func(b): return not b.exit), true)


## Kills the flagship's current ship and finishes its explosion.
func kill(r: RunState, es: ShipState, done := true) -> void:
	es.hull = 0
	es.on_destroyed()
	r.check_combat(es, 0.1)
	if done:
		es.explosion.done = true


func fight(r: RunState) -> ShipState:
	var es := r.build_enemy_ship()
	es.opponent = r.ship
	r.ship.opponent = es
	LastStand._close_dialogs(r)
	return es


func test_fight_flow() -> void:
	print("Fight flow: three stages, jump-outs, victory")
	var r := new_run(3)
	var B := r.boss
	LastStand.debug_fight(r, 1)
	check("BOSS_TEXT_1 shown", String(r.dialog.get("name", "")), "BOSS_TEXT_1")
	check("boss enemy", [r.enemy.get("boss", false), int(r.enemy.stage), r.has_hostile()], [true, 1, true])
	var sens := r.ship.sys("sensors")
	check("player sensors limited to 2", sens.get_level() - sens.power_loss <= 2, true)
	var es := fight(r)
	check("stage ship", es.blueprint.name, "BOSS_1_NORMAL_DLC")
	r.check_combat(es, 0.1)
	check("crew snapshot", (B.crew_counts as Array).reduce(func(a, x): return a + x, 0), 11)
	# Two crew die before the jump-out.
	es.crew[0].hp = 0.0
	es.crew[1].hp = 0.0
	r.check_combat(es, 0.1)
	kill(r, es, false)
	check("jump-out explosion 4 s", [es.explosion.jump_out, es.explosion.duration], [true, 4.0])
	check("next stage 2", B.next_stage, 2)
	check("no victory yet", B.won, false)
	es.explosion.done = true
	r.check_combat(es, 0.1)
	check("BOSS_ESCAPED", String(r.dialog.get("name", "")), "BOSS_ESCAPED")
	check("fight over", r.enemy.done, true)
	check("flagship will jump", B.jumping, true)
	check("not a run end", r.over, "")
	LastStand._close_dialogs(r)
	# Stage 2 at its next beacon.
	LastStand.update_boss(r)
	r._clear_location()
	r.current_beacon = LastStand.boss_beacon(r)
	r._arrive(true)
	check("BOSS_TEXT_2", String(r.dialog.get("name", "")), "BOSS_TEXT_2")
	es = fight(r)
	check("stage 2 ship", es.blueprint.name, "BOSS_2_NORMAL_DLC")
	var alive := 0
	for i in mini((B.crew_counts as Array).size(), es.layout.rooms.size()):
		alive += int(B.crew_counts[i])
	check("stage 2 crew = the 9 survivors (minus rooms the stage-2 layout lacks)", [es.crew.size(),
		(B.crew_counts as Array).reduce(func(x, y): return x + y, 0)], [alive, 9])
	kill(r, es)
	r.check_combat(es, 0.1)
	check("stage 2 escaped", String(r.dialog.get("name", "")), "BOSS_ESCAPED")
	LastStand._close_dialogs(r)
	LastStand.update_boss(r)
	r._clear_location()
	r.current_beacon = LastStand.boss_beacon(r)
	r._arrive(true)
	es = fight(r)
	check("stage 3 ship", es.blueprint.name, "BOSS_3_NORMAL_DLC")
	kill(r, es, false)
	check("no jump-out in stage 3", es.explosion.jump_out, false)
	check("victory begins (alreadyWon)", [B.won, r.score.victory], [true, true])
	check("no game over once won", LastStand.already_won(r), true)
	es.explosion.done = true
	r.check_combat(es, 0.1)
	check("BOSS_DESTROYED", String(r.dialog.get("name", "")), "BOSS_DESTROYED")
	check("boss level cleared", LastStand.active(r), false)
	r.tick(0.1)
	check("victory waits for the box", r.over, "")
	LastStand._close_dialogs(r)
	r.tick(0.1)
	check("victory", [r.over, r.over_cause], ["victory", "gameover_win"])


func test_surges() -> void:
	print("Power surges (BossShip::OnLoop power timer)")
	var r := new_run(4)
	var B := r.boss
	LastStand.debug_fight(r, 2)
	var es := fight(r)
	check("timer goal 20..30 s", float(B.power_goal) >= 20.0 and float(B.power_goal) < 30.0, true)
	check("no warning early", FlagshipRule.incoming_fire(B), false)
	B.power_time = float(B.power_goal) - 4.0
	check("POWER SURGE warning < 5 s", FlagshipRule.incoming_fire(B), true)
	B.power_time = float(B.power_goal) + 0.01
	r.check_combat(es, 0.1)
	var sd := FlagshipRule.deployed_super_drones(es)
	check("normal: 6 surge drones", sd.size(), 6)
	check("7 created", FlagshipRule.super_drones(es).size(), 7)
	check("surge drones combat, 2 shots, aimed at the player",
		sd.all(func(d): return d.kind == Drone.Kind.COMBAT and d.lifespan == 2 and d.target_ship == r.ship), true)
	check("timer restarted", float(B.power_time) < 1.0, true)
	sd[0].kill(false)
	FlagshipRule.tick_super_drones(es)
	check("spent drone leaves", FlagshipRule.deployed_super_drones(es).size(), 5)
	# Stage 3: barrage x3, then the super shield.
	var r3 := new_run(5, EventEngine.Difficulty.HARD)
	LastStand.debug_fight(r3, 3)
	var e3 := fight(r3)
	var B3 := r3.boss
	var log := []
	for i in 4:
		e3.pending_shards.clear()
		e3.super_shield = 0
		B3.power_time = float(B3.power_goal) + 0.01
		r3.check_combat(e3, 0.1)
		log.append("shield" if e3.super_shield == 12 else str(e3.pending_shards.size()))
	check("stage 3 surges: 3 barrages then the shield", log, ["7", "7", "7", "shield"])
	FlagshipRule.prepare_super_barrage(e3, rng)
	check("barrage shots LASER_HEAVY_1 damage 1",
		e3.pending_shards.all(func(s): return s.weapon == "LASER_HEAVY_1" and s.damage == 1), true)
	var r1 := new_run(6, EventEngine.Difficulty.EASY)
	LastStand.debug_fight(r1, 2)
	var e1 := fight(r1)
	FlagshipRule.prepare_super_drones(e1, 0, rng)
	check("easy: 4 surge drones", FlagshipRule.deployed_super_drones(e1).size(), 4)
	LastStand.debug_fight(r1, 1)


func test_automated_and_crew() -> void:
	print("Dead crew -> BOSS_AUTOMATED (the fight goes on)")
	var r := new_run(8)
	LastStand.debug_fight(r, 1)
	var es := fight(r)
	for c in es.crew:
		c.hp = 0.0
	r.check_combat(es, 0.1)
	check("BOSS_AUTOMATED", String(r.dialog.get("name", "")), "BOSS_AUTOMATED")
	check("still hostile", r.has_hostile(), true)
	LastStand._close_dialogs(r)
	r.check_combat(es, 0.1)
	check("shown once", r.phase, RunState.Phase.IDLE)


func test_wait_and_stalemate() -> void:
	print("Waiting in the last stand, boss stalemate")
	var r := new_run(9)
	LastStand._close_dialogs(r)
	check("wait allowed with fuel (no ship)", r.can_wait(), true)
	var before := int(r.boss.jumping)
	check("wait", r.apply(RunIntent.make(RunIntent.WAIT)), true)
	check("flagship turn on wait", int(r.boss.jumping) != before, true)
	LastStand.debug_fight(r, 1)
	check("no wait with the flagship here", r.can_wait(), false)
	var es := fight(r)
	r.ship.fuel = 0
	for i in 130:
		r.check_combat(es, 1.0)
	check("stalemate: the flagship jumps away", r.enemy.escaped, true)
	for i in 3:
		r.check_combat(es, 1.0)
	check("BOSS_STALEMATE", String(r.dialog.get("name", "")), "BOSS_STALEMATE")
	check("same stage again", r.boss.next_stage, 1)
