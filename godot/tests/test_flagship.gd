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
	test_wait_animation()
	test_super_drone_save()
	test_credits()
	test_artillery_systems()
	test_jump_out_visuals()
	test_boss_target_box()


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
	check("boss level cleared", LastStand.active(r), false)
	# WorldManager::OnLoop: Defeated -> ClearBoss + CommandGui::Victory, then UpdateLocation(BOSS_DESTROYED), one
	# frame; the event box sits behind the game-over window (first focus window) and is never seen.
	check("victory in the same frame", [r.over, r.over_cause], ["victory", "gameover_win"])
	check("BOSS_DESTROYED applied (logged), its box not shown", [r.log.any(func(l): return l == \
		"flagship event BOSS_DESTROYED"), r.phase, r.dialog.is_empty()], [true, RunState.Phase.IDLE, true])
	check("victory crew names = the living player crew", LastStand.victory_crew_names(r).size(),
		r.ship.crew.filter(func(c): return c.player_owned and c.is_alive() and not c.is_drone()).size())
	# The window shows the credits first (GameOver::SetVictory -> CreditScreen::Start).
	var box := RunEndBox.new()
	box.setup(r, Callable())
	add_child(box)
	box._process(0.016)
	check("credits first", [box.showing_credits(), box.credits.ship_name], [true, r.ship.ship_title])
	box.credits.skip()  # Esc (GameOver::KeyDown)
	box._process(0.016)
	check("Esc: the window", box.showing_credits(), false)
	box.queue_free()


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
	r.map_open = true
	check("wait", r.apply(RunIntent.make(RunIntent.WAIT)), true)
	LastStand.step_wait(r, LastStand.WAIT_TIME)
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


func test_wait_animation() -> void:
	print("WAIT animation in the boss level (StarMap waiting, UpdateDangerZone)")
	var r := new_run(9)
	LastStand._close_dialogs(r)
	LastStand.update_boss(r)  # a prepare turn: the flagship is jumping
	check("flagship jumping", r.boss.jumping, true)
	var at := LastStand.boss_beacon(r)
	var nxt := LastStand.next_hop(r)
	check("map opens", r.apply(RunIntent.make(RunIntent.OPEN_MAP)), true)
	check("wait starts", r.apply(RunIntent.make(RunIntent.WAIT)), true)
	check("waiting, map still open, no turn yet", [LastStand.waiting(r), r.map_open, LastStand.boss_beacon(r),
		r.boss.jumping], [true, true, at, true])
	check("close refused while waiting", r.apply(RunIntent.make(RunIntent.CLOSE_MAP)), false)
	check("wait refused while waiting", [r.can_wait(), r.apply(RunIntent.make(RunIntent.WAIT))], [false, false])
	check("beacons ignored while waiting", r.apply(RunIntent.make(RunIntent.SELECT_BEACON,
		r.map.links_of(r.current_beacon)[0])), false)
	LastStand.step_wait(r, 1.0)
	check("half way", LastStand.wait_progress(r), 0.5)
	var pa: Vector2 = r.map.beacons[at].pos
	var pb: Vector2 = r.map.beacons[nxt].pos
	var wp: Vector2 = LastStandMap.wait_position(r)
	check("marker 0.6 x progress along the hop", wp.distance_to(pa + (pb - pa) * 0.3) < 0.001, true)
	check("no idle slide while waiting", LastStandMap.step_slide(5.0, r, 1.0), 0.0)
	LastStand.step_wait(r, 0.99)
	check("still waiting at 1.99 s", LastStand.waiting(r), true)
	LastStand.step_wait(r, 0.02)
	check("done: map closed, flagship moved", [LastStand.waiting(r), r.map_open, LastStand.boss_beacon(r)],
		[false, false, nxt])
	check("no wait position afterwards", LastStandMap.wait_position(r), null)
	# A prepare turn during the wait: the marker does not move (not jumping).
	var r2 := new_run(9)
	LastStand._close_dialogs(r2)
	r2.map_open = true
	LastStand.wait(r2)
	LastStand.step_wait(r2, 1.0)
	check("idle flagship: no wait slide", LastStandMap.wait_position(r2), null)
	LastStand.step_wait(r2, 1.0)
	check("prepare turn taken at the end", r2.boss.jumping, true)


func test_super_drone_save() -> void:
	print("Surge drones in a mid-fight save (ShipManager::SaveSuperDrones / LoadSuperDrones)")
	var r := new_run(4)
	var B := r.boss
	LastStand.debug_fight(r, 2)
	var es := fight(r)
	B.power_time = float(B.power_goal) + 0.01
	r.check_combat(es, 0.1)
	var sd := FlagshipRule.deployed_super_drones(es)
	sd[0].lifespan = 1
	var snap := ShipSave.snapshot(es)
	check("7 surge drones saved", (snap.get("super_drones", []) as Array).size(), 7)
	var es2 := r.build_enemy_ship()
	ShipSave.apply(es2, snap)
	check("not rebuilt before the opponent is set", FlagshipRule.super_drones(es2).size(), 0)
	es2.opponent = r.ship
	ShipSave.redeploy(es2)
	var sd2 := FlagshipRule.deployed_super_drones(es2)
	check("7 restored, 6 deployed", [FlagshipRule.super_drones(es2).size(), sd2.size()], [7, 6])
	check("same blueprints", FlagshipRule.super_drones(es2).map(func(d): return d.bp.name),
		FlagshipRule.super_drones(es).map(func(d): return d.bp.name))
	check("shots left kept, aimed at the player", [sd2[0].lifespan, sd2[1].lifespan, sd2[1].target_ship == r.ship,
		sd2[1].powered], [1, 2, true, true])
	check("no power needed", sd2.all(func(d): return int(d.bp.power) == 0), true)


func test_credits() -> void:
	print("Credits (CreditScreen::Start / OnRender / Done)")
	check("crew line 3", CreditScreen.crew_text(["A", "B", "C"]), "A, B and C")
	check("crew line 2", CreditScreen.crew_text(["A", "B"]), "A and B")
	check("crew line 1", CreditScreen.crew_text(["A"]), "A")
	check("missing text", CreditScreen.text_of("font"), "Could not find: font")
	check("known text", CreditScreen.text_of("game_from"), "A game from:")
	var c := CreditScreen.new()
	c.start("The Kestrel", ["Ann", "Bob"])
	check("backers from credits.txt", c.names.size(), 1016)
	check("first / last backer", [c.names[0], c.names[-1]], ["A and K", "Zalastik"])
	check("start: pause 5, scroll 0, text invisible", [c.pausing, c.scroll, c.text_alpha()], [5.0, 0.0, 0.0])
	c.step(0.5)
	check("fade in", is_equal_approx(c.text_alpha(), 0.5), true)
	c.step(4.5)
	check("still until 5 s", c.scroll, 0.0)
	c.step(1.0)
	check("56 px/s", is_equal_approx(c.scroll, -56.0), true)
	var t := 6.0
	var held := 0.0
	while not c.done() and t < 600.0:
		c.step(1.0 / 64.0)
		t += 1.0 / 64.0
		if c.scroll == CreditScreen.HOLD_AT:
			held += 1.0 / 64.0
	check("hold 3 s at -720", absf(held - 3.0) < 0.05, true)
	var want := 5.0 + 3.0 + (338 * 40 + 3906) / 56.0
	check("done after the last line (%.1f s)" % t, absf(t - want) < 0.1, true)
	var m := CreditScreen.new()
	m.start("", [])
	check("no ship (main menu): scroll -70, no pause", [m.scroll, m.pausing, m.text_alpha()], [-70.0, 0.0, 1.0])
	m.on_touch(true)
	m.step(1.0)
	check("touch hint shown", m.skip_timer, 1.0)
	check("held 1 s: not yet", m.done(), false)
	m.step(1.0)
	check("held 2 s: skip", m.done(), true)
	m.on_touch(false)
	m.step(0.5)
	check("hint fades", is_equal_approx(m.skip_timer, 0.5), true)
	c.free()
	m.free()


func test_artillery_systems() -> void:
	print("Artillery: one ArtillerySystem per <artillery> entry (ShipManager::AddSystem / CreateSystems)")
	var rooms := {1: [9, 10, 14, 18], 2: [9, 10, 14], 3: [9, 10]}
	# ProcessShipBlueprint keeps one SystemTemplate per id: the last <artillery> entry's power wins for all copies.
	var level := {1: 3, 2: 3, 3: 4}
	for st in [1, 2, 3]:
		var es := FlagshipRule.build(st, 1, true, FlagshipRule.stage_crew(1, [], 19))
		var arts := es.systems_of("artillery")
		check("stage %d: one system per artillery room" % st, arts.map(func(s): return s.room), rooms[st])
		var keys := []
		for i in arts.size():
			keys.append(SystemState.key_for("artillery", i + 1))
		check("  keys artillery, artillery#2 ...", arts.map(func(s): return s.key), keys)
		var owner_rooms := es.artillery.map(func(w): return es.artillery_system(w).room)
		check("  each weapon owned by the system in its room", owner_rooms, rooms[st])
		check("  every copy at the last entry's power", arts.map(func(s): return s.get_level()),
			arts.map(func(_s): return level[st]))
		check("  all powered (enemy startup power)", arts.all(func(s): return s.power == level[st]), true)
		check("  each in the system list (vSystemList, blueprint order, artillery last)",
			es.system_list().slice(es.system_list().size() - arts.size()), keys)
		var in_rooms: Array = rooms[st].map(func(r): return es.system_in_room(r).key)
		check("  a room symbol in every artillery room (system_in_room)", in_rooms, keys)
	var es := FlagshipRule.build(1, 1, true, FlagshipRule.stage_crew(1, [], 19))
	var d := Damage.new()
	d.damage = 1
	es.apply_damage(18, d, rng)
	check("a hit in room 18 damages only artillery#4", es.systems_of("artillery").map(func(s): return s.damage),
		[0, 0, 0, 1])
	ArtilleryRule.tick(es, 1.0)
	check("  its weapon charges slower (power 2: x1.0), the others x0.75 (power 3)",
		es.artillery.map(func(w): return w.cooldown_modifier), [0.75, 0.75, 0.75, 1.0])
	es.sys("artillery#2").hacked = true
	es.artillery[1].charge = 5.0
	es.artillery[0].charge = 5.0
	ArtilleryRule.tick(es, 16.0)
	check("  a hacked artillery#2 drains only its own weapon", [es.artillery[0].charge > 5.0,
		es.artillery[1].charge < 5.0], [true, true])
	check("  WeaponArt hack level per system", [WeaponArt.hack_level(es, es.artillery[0]),
		WeaponArt.hack_level(es, es.artillery[1])], [0, 2])
	es.sys("artillery#2").hacked = false
	var c: CrewMember = es.crew.filter(func(m): return m.room == 14)[0]
	check("crew in room 14 man artillery#3, not the first artillery", [es.is_manned("artillery#3"),
		es.system_in_room(14) == es.sys("artillery#3")], [true, true])
	check("  the console of each artillery room (enemy: slot 0 facing up)", es.graph.console_dir(14), "up")
	c.hp = 0.0
	# Saved and loaded (mid-fight save, ShipSave): the four systems come back with their keys and rooms.
	var snap := ShipSave.snapshot(es)
	var es2 := FlagshipRule.build(1, 1, true, FlagshipRule.stage_crew(1, [], 19))
	ShipSave.apply(es2, snap)
	var loaded := es2.systems_of("artillery").map(func(s): return [s.key, s.room, s.damage])
	check("save / load keeps the four systems", loaded, [["artillery", 9, 0], ["artillery#2", 10, 0], ["artillery#3", 14, 0], ["artillery#4", 18, 1]])
	# The AI stand-down (DeactiveWeapons) depowers every artillery system.
	var ai := ShipAI.new(es, rng)
	ai._stand_down()
	check("stand-down depowers all four", es.systems_of("artillery").map(func(s): return s.power), [0, 0, 0, 0])
	# A ship with one artillery keeps the plain key.
	var fed := ShipState.new("PLAYER_SHIP_FED", true)
	check("FED cruiser: one artillery system, key 'artillery'", [fed.systems_of("artillery").size(),
		fed.artillery[0].system_key, fed.artillery_system(fed.artillery[0]) == fed.sys("artillery")], [1, "artillery",
		true])


func test_jump_out_visuals() -> void:
	print("Jump-out visuals (ExplosionAnimation / Ship::OnLoop GetFinalGib / Ship::OnRenderJump)")
	for st in [1, 2]:
		var es := FlagshipRule.build(st, 1, true, FlagshipRule.stage_crew(1, [], 19))
		es.hull = 0
		es.on_destroyed()
		es.explosion.set_jump_out(FlagshipRule.invincible(es))  # LastStand.check_combat (SetDestroyed bossAnimation)
		var ex: ShipExplosion = es.explosion
		check("stage %d: jump-out, 4 s" % st, [ex.jump_out, ex.duration], [true, 4.0])
		var fg := ex.final_gib()
		check("  final gib = gib4 (the core that stays: velocity 0)", [fg.index, fg.vel], [4, Vector2.ZERO])
		check("  its texture is boss_%d_gib4" % st, fg.tex != null and fg.tex == FtlData.first_texture(
			["img/ship/boss_%d_gib4.png" % st, "img/ships_glow/boss_%d_gib4.png" % st]), true)
		ex.time = 2.9
		check("  before 0.75: no jump fade yet", ex.jump_out_progress(), -1.0)
		ex.time = 3.5
		check("  at 3.5 s: fade progress 0.5", is_equal_approx(ex.jump_out_progress(), 0.5), true)
	var s3 := FlagshipRule.build(3, 1, true, FlagshipRule.stage_crew(1, [], 19))
	s3.hull = 0
	s3.on_destroyed()
	s3.explosion.set_jump_out(FlagshipRule.invincible(s3))
	check("stage 3: a real explosion, 6 s (boss_3), no jump fade", [s3.explosion.jump_out, s3.explosion.duration,
		s3.explosion.jump_out_progress()], [false, 6.0, -1.0])


func test_boss_target_box() -> void:
	print("Boss TARGET box (CombatControl boss_visual) and the enemy system list (vSystemList order)")
	var es := FlagshipRule.build(1, 1, true, FlagshipRule.stage_crew(1, [], 19))
	check("flagship = boss visuals", EnemyWindow.is_boss_ship(es), true)
	var w := EnemyWindow.new()
	w.enemy = es
	w.boss = true
	check("boss frame (752, 7) 523 x 598", w.frame_rect(), Rect2(752, 7, 523, 598))
	check("status block box + (12, 40), info box + (480, 35)", [w.status_origin(), w.info_origin()],
		[Vector2(764, 47), Vector2(1232, 42)])
	var boxes := w.system_boxes()
	check("12 system boxes, blueprint order, four artillery boxes", boxes.map(func(e): return e[0]),
		["pilot", "shields", "doors", "cloaking", "medbay", "engines", "oxygen", "hacking", "artillery",
		"artillery#2", "artillery#3", "artillery#4"])
	check("  from box + (80, 535), 30 px apart", [boxes[0][1], boxes[11][1]], [Vector2(832, 542), Vector2(1162, 542)])
	var n := ShipState.new("REBEL_SKINNY_ELITE", false)
	w.enemy = n
	w.boss = false
	check("normal ship: frame and boxes as before", [w.frame_rect(), w.system_boxes()[0][1]],
		[Rect2(872, 45, 410, 555), Vector2(912, 515)])
	check("  in blueprint order (vanilla Elite Fighter: O2, pilot, shields, engines, weapons, medbay)",
		w.system_boxes().map(func(e): return e[0]), ["oxygen", "pilot", "shields", "engines", "weapons", "medbay"])
	check("not a boss", EnemyWindow.is_boss_ship(n), false)
	w.free()
	var hud := CommandHud.new()
	check("boss fight: intruder warning 120 px left, engines warning (-85, -35)", [CommandHud.BOSS_INTRUDER_SHIFT,
		CommandHud.BOSS_ENGINES_SHIFT], [Vector2(-120, 0), Vector2(-85, -35)])
	hud.free()
