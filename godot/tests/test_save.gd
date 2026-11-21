extends Node
## Run save / Continue and the player profile (rules/save_and_profile.md): SaveGame round trip of a mid-run state
## (map, sector tree, fleet, store, ship systems / power / damage / crew / weapons / cargo, RNG streams, score,
## event dialog), the event ship of a mid-combat save through the real scene (main.tscn), Continue enabled /
## disabled and the New Game confirm, the save deleted at the run end, profile persistence, stat totals, crew
## records, unlocks, achievements, top scores and our extended statistics (win streak, per ship / difficulty).
## Files go to user://test_*.sav (never the real continue.sav / profile.sav). Run:
##   godot --headless --path godot res://tests/test_save.tscn

const Harness := preload("res://tests/harness.gd")
const MAIN := preload("res://scripts/main.gd")
const SAVE_PATH := "user://test_continue.sav"
const PROF_PATH := "user://test_profile.sav"

var fails := 0
var main: Node


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame
		await get_tree().process_frame


func close_dialogs(r: RunState) -> void:
	for i in 10:
		if r.phase == RunState.Phase.DIALOG:
			var first := r.dialog_choices.find_custom(func(v): return v.enabled)
			r.choose(maxi(first, 0))
		elif r.phase == RunState.Phase.MESSAGE:
			r.apply(RunIntent.make(RunIntent.CONTINUE))


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	FtlData.muted = true
	var old := [SaveGame.path, SaveGame.persist, PlayerProfile.path, PlayerProfile.persist]
	SaveGame.path = SAVE_PATH
	SaveGame.persist = true
	PlayerProfile.path = PROF_PATH
	PlayerProfile.persist = true
	_wipe()
	_round_trip()
	_codec()
	await _combat_round_trip()
	_continue_button()
	_deleted_at_run_end()
	_profile_persistence()
	_stats_and_streaks()
	await _stats_view()
	_profile_slots()
	_wipe()
	SaveGame.path = old[0]
	SaveGame.persist = old[1]
	PlayerProfile.path = old[2]
	PlayerProfile.persist = old[3]
	PlayerProfile.reset_current()
	RunState.current = null
	Settings.thaw()


func _wipe() -> void:
	SaveGame.delete()
	for p in [PROF_PATH, PROF_PATH + ".new"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	PlayerProfile.reset_current(PlayerProfile.new())


## [ours] Three profiles (ProfileSlots) under user://test_slots_*: first start seeds slot 0 with every ship,
## each slot has its own profile and run save, UNLOCK ALL, DELETE, the active slot persists.
func _profile_slots() -> void:
	print("profile slots")
	var keep_dir := ProfileSlots.dir
	ProfileSlots.dir = "user://test_slots_"
	var clean := func() -> void:
		for i in ProfileSlots.COUNT:
			for f in [ProfileSlots.profile_path(i), ProfileSlots.save_path(i)]:
				for g in [f, f + ".new"]:
					if FileAccess.file_exists(g):
						DirAccess.remove_absolute(ProjectSettings.globalize_path(g))
		if FileAccess.file_exists(ProfileSlots.cfg_path()):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(ProfileSlots.cfg_path()))
	clean.call()
	ProfileSlots.start()
	check("first start: slot 0 active", [ProfileSlots.active, PlayerProfile.path, SaveGame.path],
		[0, "user://test_slots_profile.sav", "user://test_slots_continue.sav"])
	check("first start: slot 0 fully unlocked", PlayerProfile.current().unlock_percent(), 100)
	check("unlock all earns no achievement", PlayerProfile.current().has_achievement(PlayerProfile.ACH_UNLOCK_ALL), false)
	ProfileSlots.select(1)
	check("slot 1 paths", [PlayerProfile.path, SaveGame.path],
		["user://test_slots_profile_2.sav", "user://test_slots_continue_2.sav"])
	check("slot 1 fresh: Kestrel A only", PlayerProfile.current().unlock_percent() < 100, true)
	check("slot 1 unused", ProfileSlots.used(1), false)
	var t := TitleState.new()
	t.unlock_all = false
	check("slot 1 hangar: Engi locked", t.unlocked(3, 0), false)
	ProfileSlots.unlock_all(1)
	check("slot 1 after UNLOCK ALL", [PlayerProfile.current().unlock_percent(), t.unlocked(3, 0), ProfileSlots.used(1)],
		[100, true, true])
	check("slot 2 untouched", ProfileSlots.profile_of(2).unlock_percent() < 100, true)
	ProfileSlots.start()  # restart: the active slot is remembered
	check("restart keeps slot 1", ProfileSlots.active, 1)
	ProfileSlots.wipe(1)
	check("DELETE: slot 1 file gone, profile fresh", [ProfileSlots.used(1), PlayerProfile.current().unlock_percent() < 100],
		[false, true])
	check("slot 0 still unlocked", ProfileSlots.profile_of(0).unlock_percent(), 100)
	clean.call()
	ProfileSlots.dir = keep_dir
	ProfileSlots.active = 0


func _store_beacon(r: RunState) -> int:
	for b in r.map.beacons:
		if b.id != r.current_beacon and b.event.get("store", false):
			return b.id
	return -1


func _crew_key(c: CrewMember) -> Array:
	return [c.race, c.name_long, c.male, c.player_owned, c.hp, c.room, c.slot, c.skills.duplicate(),
		c.crew_stats.duplicate()]


func _ship_key(s: ShipState) -> Dictionary:
	var sys := {}
	for id in s.systems:
		var x: SystemState = s.systems[id]
		sys[id] = [x.level, x.damage, x.power, x.power_loss, x.room]
	return {"hull": s.hull, "fuel": s.fuel, "scrap": s.scrap, "missiles": s.missiles, "parts": s.drone_parts,
		"reactor": s.reactor_max, "systems": sys, "weapons": s.weapons.map(func(w): return [w.bp.name, w.powered,
		snappedf(w.charge, 0.001)]), "drones": s.drones.map(func(d): return d.bp.name), "augments": s.augments.duplicate(),
		"crew": s.crew.map(func(c): return _crew_key(c)), "fires": s.fires.duplicate(true),
		"breaches": s.breaches.duplicate(true), "o2": s.env.oxygen.duplicate(), "title": s.ship_title}


# ------------------------------------------------------------------ run round trip

func _round_trip() -> void:
	print("Run save round trip (§1.3)")
	var r := RunState.new_run(4242, "PLAYER_SHIP_HARD")
	RunState.current = r
	close_dialogs(r)
	var sb := _store_beacon(r)
	check("a store beacon exists", sb >= 0, true)
	r.jump_to(sb)
	close_dialogs(r)
	check("store generated", r.store() != null, true)
	# Mid-run changes on the player ship.
	var s := r.ship
	s.scrap = 777
	s.fuel = 9
	s.missiles = 3
	s.damage_system("shields", 1)
	s.ignite(s.sys("weapons").room, 0)
	s.add_breach(s.sys("engines").room, 0)
	s.env.oxygen[s.sys("pilot").room] = 42.5
	s.crew[0].hp = 37.0
	s.crew[0].skills["pilot"] = 7
	s.crew[0].name_long = "Saved Sam"
	s.crew[1].crew_stats = [1, 2, 3, 4, 0]
	r.give_item("weapon", "LASER_HEAVY_1")
	r.give_item("augment", "SCRAP_COLLECTOR")
	r.cargo = ["", "DRONE_DEFENSE_1"]
	s.ship_title = "Test Saver"
	s.add_crew("engi", true)
	r.store().sections[0].boxes[0].count = 0  # bought out
	r.score.add_scrap_collected(55)
	r.stats.scrap = 123
	r.track["damage_dealt"] = 17
	# Quest / secret-sector fields (quests agent) and beacon quest flags.
	r.delayed_quests.append("TEST_QUEST")
	r.secret_sector = true
	r.ruwen_flag = true
	r.unlocked_ships.append(4)
	r.map.beacons[0]["quest"] = true
	var before := _ship_key(s)
	var map_before: Array = r.map.beacons.map(func(b): return [b.id, b.visited, b.known, b.pos,
		String(b.event.get("name", ""))])
	var store_before: Array = r.store().sections.map(func(sec): return sec.boxes.map(func(o): return [o.get("name", ""),
		o.get("price", 0), o.get("count", 0)]))
	check("save written", SaveGame.save_run(r), true)
	check("save file exists", SaveGame.exists(), true)
	var r2 := SaveGame.load_run()
	check("loaded", r2 != null, true)
	if r2 == null:
		return
	check("seed / sector / beacon", [r2.seed, r2.sector, r2.sector_id, r2.current_beacon, r2.sector_name],
		[r.seed, r.sector, r.sector_id, r.current_beacon, r.sector_name])
	check("map beacons (visited, known, events)", r2.map.beacons.map(func(b): return [b.id, b.visited, b.known, b.pos,
		String(b.event.get("name", ""))]), map_before)
	check("map start / exit", [r2.map.start, r2.map.exit], [r.map.start, r.map.exit])
	check("sector tree", r2.tree.sectors.map(func(x): return [x.desc, x.name, x.visited]),
		r.tree.sectors.map(func(x): return [x.desc, x.name, x.visited]))
	check("rebel fleet", [r2.fleet.center, r2.fleet.pursuit_delay], [r.fleet.center, r.fleet.pursuit_delay])
	check("store kept (offers, prices, sold out)", r2.store().sections.map(func(sec): return sec.boxes.map(
		func(o): return [o.get("name", ""), o.get("price", 0), o.get("count", 0)])), store_before)
	check("store is a RunStore", r2.store() is RunStore, true)
	var after := _ship_key(r2.ship)
	for k in before:
		check("ship " + k, after[k], before[k])
	check("cargo", r2.cargo, r.cargo)
	check("score", [r2.score.current, r2.score.sector, r2.score.difficulty], [r.score.current, r.score.sector,
		r.score.difficulty])
	check("stats / track", [r2.stats.scrap, r2.track.damage_dealt], [123, 17])
	check("quest fields", [r2.delayed_quests, r2.delayed_quests.is_typed(), r2.secret_sector, r2.ruwen_flag,
		r2.unlocked_ships, r2.unlocked_ships.is_typed(), r2.map.beacons[0].get("quest", false)],
		[["TEST_QUEST"], true, true, true, [4], true, true])
	r2.secret_sector = false
	r.secret_sector = false
	check("difficulty / ae", [r2.engine.difficulty, r2.engine.ae], [r.engine.difficulty, r.engine.ae])
	check("crew records counters kept", r2.ship.crew[1].crew_stats, [1, 2, 3, 4, 0])
	# The RNG streams continue where they were: the same next numbers, the same next event.
	check("run rng continues", r2.rng.randi(), r.rng.randi())
	check("engine rng continues", r2.engine.rng.randi(), r.engine.rng.randi())
	check("ship (crew combat) rng state", r2.ship.rng.state, r.ship.rng.state)
	var nb := -1
	for n in r.map.beacons[r.current_beacon].links:
		nb = n
		break
	r.jump_to(nb)
	r2.jump_to(nb)
	check("same next arrival event", String(r2.dialog.get("name", "")), String(r.dialog.get("name", "")))
	check("same fleet move", r2.fleet.center, r.fleet.center)
	# Drones (Engi A) and their system.
	var re := RunState.new_run(8, "PLAYER_SHIP_CIRCLE")
	var re2 := SaveGame.restore(SaveGame.build(re))
	check("drones kept", re2.ship.drones.map(func(d): return d.bp.name), re.ship.drones.map(func(d): return d.bp.name))
	check("drone system", re2.ship.sys("drones").level, re.ship.sys("drones").level)
	# An open event dialog is saved with its choices.
	var r3 := RunState.new_run(99, "PLAYER_SHIP_HARD")
	check("start dialog open", r3.phase, RunState.Phase.DIALOG)
	SaveGame.save_run(r3)
	var r4 := SaveGame.load_run()
	check("dialog restored", [r4.phase, String(r4.dialog.get("name", "")), r4.dialog_choices.size()],
		[r3.phase, String(r3.dialog.get("name", "")), r3.dialog_choices.size()])
	check("dialog choice works after load", r4.choose(0), true)
	# Pending upgrades in an open upgrade window count (ConfirmUpgrades).
	var r5 := RunState.new_run(5, "PLAYER_SHIP_HARD")
	close_dialogs(r5)
	r5.ship.scrap = 500
	var lv := r5.ship.sys("shields").level
	check("upgrade bought (temporary)", r5.mgmt.upgrades.buy(r5.ship, "shields"), "ok")
	var d := SaveGame.build(r5)
	var r6 := SaveGame.restore(d)
	check("pending upgrade saved as committed", r6.ship.sys("shields").level, lv + 1)
	check("live run untouched by the save", r5.ship.sys("shields").level, lv)
	check("no save after the run ended", (func():
		r5.end_run("gameover")
		return SaveGame.save_run(r5)).call(), false)


## Generic codec details: typed arrays, RNG objects, objects not on the allow list.
func _codec() -> void:
	print("Codec")
	var n := XmlNode.new()
	n.tag = "ship"
	n.attrs = {"load": "X"}
	var c := XmlNode.new()
	c.tag = "crew"
	n.children.append(c)
	var back: Variant = SaveCodec.decode(SaveCodec.encode({"node": n, "v": Vector2i(3, 4), 7: [1.5]}))
	check("XmlNode tree", [back.node.tag, back.node.attrs, back.node.children.size(), back.node.children[0].tag],
		["ship", {"load": "X"}, 1, "crew"])
	check("typed child array", back.node.children.is_typed(), true)
	check("int keys / vectors", [back[7], back.v], [[1.5], Vector2i(3, 4)])
	var g := RandomNumberGenerator.new()
	g.seed = 12
	g.randi()
	var g2: RandomNumberGenerator = SaveCodec.decode(SaveCodec.encode(g))
	check("rng state", g2.randi(), g.randi())
	check("other objects cut", SaveCodec.encode(Node.new()) == null, true)


# ------------------------------------------------------------------ mid-combat save through main.tscn

func _start_main() -> void:
	main = load("res://main.tscn").instantiate()
	add_child(main)
	await frames(6)


func _stop_main() -> void:
	main.queue_free()
	await get_tree().process_frame
	main = null


func _combat_round_trip() -> void:
	print("Mid-combat save (§1.3, main.tscn)")
	MAIN.run_mode = true
	MAIN.input_mode = InputProfile.PC
	MAIN.player_ship_name = "PLAYER_SHIP_HARD"
	var r := RunState.new_run(31337)
	close_dialogs(r)
	r.show_event(r.engine.base_event("PIRATE"))
	close_dialogs(r)
	RunState.current = r
	await _start_main()
	check("enemy in the scene", main.has_enemy, true)
	var es: ShipState = main.enemy_space.ship
	es.hull = maxi(es.hull - 3, 1)
	var sys_id: String = es.systems.keys()[0]
	es.damage_system(sys_id, 1)
	var hull := es.hull
	var dmg: int = es.sys(sys_id).damage
	var crew_n := es.crew.size()
	r.ship.hull -= 4
	var phull := r.ship.hull
	check("saved from the scene", main.save_run_now(), true)
	await _stop_main()
	RunState.current = null
	var r2 := SaveGame.load_run()
	check("enemy record restored", [r2.enemy.get("blueprint"), r2.enemy.get("hostile"), r2.enemy.has("saved_ship")],
		[r.enemy.get("blueprint"), r.enemy.get("hostile"), true])
	RunState.current = r2
	await _start_main()
	check("continued: enemy still there", main.has_enemy, true)
	var es2: ShipState = main.enemy_space.ship
	check("enemy hull kept", es2.hull, hull)
	check("enemy system damage kept", es2.sys(sys_id).damage, dmg)
	check("enemy crew count kept", es2.crew.size(), crew_n)
	check("player hull kept", main.player_space.ship.hull, phull)
	check("player ship is the run's", main.player_space.ship == r2.ship, true)
	check("snapshot consumed", r2.enemy.has("saved_ship"), false)
	await frames(4)
	await _stop_main()
	RunState.current = null
	MAIN.run_mode = false
	SaveGame.delete()


# ------------------------------------------------------------------ Continue / New Game

func _continue_button() -> void:
	print("Continue button / New Game confirm (§1.1)")
	SaveGame.delete()
	var t := TitleState.new()
	check("no save: Continue disabled", t.continue_enabled(), false)
	check("no save: Continue refused", t.apply(TitleState.make(TitleState.MENU_CONTINUE)), false)
	check("no save: New Game opens the hangar", [t.apply(TitleState.make(TitleState.MENU_NEW_GAME)), t.screen],
		[true, TitleState.Screen.HANGAR])
	var r := RunState.new_run(1)
	SaveGame.save_run(r)
	t = TitleState.new()
	check("save: Continue enabled", t.continue_enabled(), true)
	check("save: Continue", [t.apply(TitleState.make(TitleState.MENU_CONTINUE)), t.pending], [true, "continue"])
	t.pending = ""
	check("save: New Game asks first", [t.apply(TitleState.make(TitleState.MENU_NEW_GAME)), t.pending, t.screen],
		[true, "confirm_new_game", TitleState.Screen.MENU])
	check("cancel keeps the menu", [t.apply(TitleState.make(TitleState.NEW_GAME_CONFIRM, 0)), t.screen,
		t.confirm_new_game], [true, TitleState.Screen.MENU, false])
	t.apply(TitleState.make(TitleState.MENU_NEW_GAME))
	check("confirm opens the hangar and deletes", [t.apply(TitleState.make(TitleState.NEW_GAME_CONFIRM, 1)),
		t.screen, t.pending], [true, TitleState.Screen.HANGAR, "delete_save"])
	SaveGame.delete()
	check("deleted: Continue disabled", TitleState.new().continue_enabled(), false)
	SaveGame.persist = false
	SaveGame.save_run(r)
	check("persist off: nothing written", SaveGame.exists(), false)
	SaveGame.persist = true


func _deleted_at_run_end() -> void:
	print("Save deleted at the run end (§1.1)")
	for kind in ["gameover", "victory"]:
		var r := RunState.new_run(77)
		RunState.current = r
		SaveGame.save_run(r)
		check(kind + ": saved", SaveGame.exists(), true)
		if kind == "gameover":
			r.game_over("gameover_crew")
		else:
			r.end_run("victory")
		check(kind + ": save deleted", SaveGame.exists(), false)
	var r2 := RunState.new_run(78)
	RunState.current = r2
	SaveGame.save_run(r2)
	ProfileTracker.abandon(r2)
	check("abandoned (RESTART / HANGAR): deleted", SaveGame.exists(), false)
	RunState.current = null


# ------------------------------------------------------------------ profile

func _profile_persistence() -> void:
	print("Profile persistence (§2)")
	_wipe()
	var p := PlayerProfile.current()
	check("fresh: only the Kestrel A", [p.is_unlocked(0, 0), p.is_unlocked(3, 0), p.is_unlocked(0, 1)],
		[true, false, false])
	p.unlock_ship(3, 0)
	p.set_achievement("ACH_SECTOR_5", 2)
	p.set_ship_victory(0, 1, 1)
	p.quests[4] = true
	p.add_total(0, 12)
	p.games_played = 5
	p.extra["runs"] = 5
	PlayerProfile.insert_score(p.top_scores, {"name": "A", "score": 100, "ship_id": 0, "type": 0})
	check("saved", p.save(), true)
	PlayerProfile.reset_current()
	var q := PlayerProfile.current()
	check("reloaded object", q != p, true)
	check("unlocks", [q.is_unlocked(3, 0), q.is_unlocked(0, 0)], [true, true])
	check("achievement + difficulty", q.achievements.get("ACH_SECTOR_5"), 2)
	check("victory marker", q.ship_victory(0, 1), 1)
	check("quest", q.quests.has(4), true)
	check("totals / games", [q.stat_total[0], q.games_played], [12, 5])
	check("extra", q.extra.get("runs"), 5)
	check("top scores", q.top_scores.size(), 1)
	# Hangar unlocks read the profile (with the unlock-all setting off).
	var t := TitleState.new()
	t.unlock_all = false
	check("hangar: Engi unlocked by the profile", t.unlocked(3, 0), true)
	check("hangar: Mantis locked", t.unlocked(2, 0), false)
	# ScoreKeeper::UnlockShip: five type A -> Lanius; all ten -> ACH_UNLOCK_ALL.
	for id in [1, 2, 4]:
		q.unlock_ship(id, 0)
	check("five type A unlock the Lanius", q.is_unlocked(PlayerProfile.LANIUS, 0), true)
	for id in 10:
		q.unlock_ship(id, 0)
	check("all type A: ACH_UNLOCK_ALL", q.has_achievement(PlayerProfile.ACH_UNLOCK_ALL), true)
	# Top score list: 5 entries, best first, equal scores after the older one.
	var l := []
	for v in [50, 80, 80, 10, 90, 70, 60]:
		PlayerProfile.insert_score(l, {"score": v, "name": str(v)})
	check("top 5 sorted", l.map(func(e): return e.score), [90, 80, 80, 70, 60])
	check("a lower score does not enter", PlayerProfile.insert_score(l, {"score": 5}), -1)


func _finish(r: RunState, kind: String) -> void:
	if kind == "victory":
		r.end_run("victory")
	else:
		r.game_over("gameover_crew")


func _stats_and_streaks() -> void:
	print("Stats increments, records and streaks (§2–§3)")
	_wipe()
	var p := PlayerProfile.current()
	var r := RunState.new_run(11, "PLAYER_SHIP_HARD", EventEngine.Difficulty.EASY)
	RunState.current = r
	check("games played +1", p.games_played, 1)
	check("start beacon + start crew in the totals", [p.stat_total[1], p.stat_total[3]],
		[r.score.beacons(), r.score.crew()])
	r.score.add_defeated_ship()
	r.score.add_scrap_collected(40)
	check("totals follow the run", [p.stat_total[0], p.stat_total[2]], [1, 40])
	# Crew records (ScoreKeeper::UpdateCrewStat).
	r.ship.crew[0].crew_stats = [3, 9, 1, 6, 2]
	r.ship.crew[0].name_long = "Record Holder"
	# Sector 5 with the Kestrel: ACH_SECTOR_5 + Engi unlocked.
	ProfileTracker.reached_sector(r, 5)
	check("sector 5: achievement", p.has_achievement("ACH_SECTOR_5"), true)
	check("sector 5 with the Kestrel unlocks the Engi", p.is_unlocked(3, 0), true)
	r.track["damage_dealt"] = 30
	r.track["time"] = 600.0
	_finish(r, "victory")
	check("victory counted", p.victories, 1)
	check("ACH_WIN_EASY (not NORMAL on easy)", [p.has_achievement("ACH_WIN_EASY"),
		p.has_achievement("ACH_WIN_NORMAL")], [true, false])
	check("victory marker Kestrel A easy", p.ship_victory(0, 0), 0)
	check("victory with the Kestrel unlocks the next ship", p.is_unlocked(PlayerProfile.CHAIN[1], 0), true)
	check("records: best run", p.stat_max[0], 1)
	check("crew records", [p.crew_records[1].value, p.crew_records[1].name, p.crew_records[3].value], [9,
		"Record Holder", 6])
	check("top score entry", [p.top_scores.size(), p.top_scores[0].victory, p.top_scores[0].ship_id], [1, true, 0])
	check("ship best list", p.ship_best(0, 0).size(), 1)
	check("profile written", FileAccess.file_exists(PROF_PATH), true)
	# Second win (normal), then a loss: streak 2 -> 0, best 2.
	var r2 := RunState.new_run(12, "PLAYER_SHIP_HARD_2", EventEngine.Difficulty.NORMAL)
	RunState.current = r2
	r2.track["time"] = 300.0
	_finish(r2, "victory")
	check("streak 2", p.extra.streak, 2)
	check("ACH_WIN_NORMAL on normal", p.has_achievement("ACH_WIN_NORMAL"), true)
	var r3 := RunState.new_run(13, "PLAYER_SHIP_CIRCLE", EventEngine.Difficulty.HARD)
	RunState.current = r3
	_finish(r3, "gameover")
	check("loss resets the streak, best kept", [p.extra.streak, p.extra.best_streak], [0, 2])
	check("runs / wins / losses", [p.extra.runs, p.extra.wins, p.extra.losses], [3, 2, 1])
	check("per ship", [p.extra.by_ship["0:0"].wins, p.extra.by_ship["0:1"].wins, p.extra.by_ship["3:0"].losses],
		[1, 1, 1])
	check("per difficulty", [p.extra.by_difficulty[0].wins, p.extra.by_difficulty[1].wins,
		p.extra.by_difficulty[2].runs], [1, 1, 1])
	check("fastest win", p.extra.fastest_win.time, 300.0)
	check("results by cause", [p.extra.results.get("victory"), p.extra.results.get("gameover_crew")], [2, 1])
	check("damage dealt summed", p.extra.damage_dealt, 30)
	check("history newest first", p.extra.history[0].result, "gameover_crew")
	check("games played", p.games_played, 3)
	# Unlock quest (hook ship_unlocked from RunState._unlock_ship).
	var rq := RunState.new_run(16)
	RunState.current = rq
	rq._unlock_ship({"unlock_ship": 5, "text": ""})
	check("quest unlock -> profile ship + quest marker", [p.is_unlocked(5, 0), p.quests.has(5)], [true, true])
	# Abandoned run: no streak, counted apart.
	var r4 := RunState.new_run(14)
	RunState.current = r4
	ProfileTracker.abandon(r4)
	check("abandoned", [p.extra.abandoned, p.extra.runs, p.extra.streak], [1, 4, 0])
	check("abandon is once", (func():
		ProfileTracker.abandon(r4)
		return p.extra.abandoned).call(), 1)
	# Hooks: crew death and the pilot's evasion are counted for the current run.
	var r5 := RunState.new_run(15)
	RunState.current = r5
	var pilot := r5.ship.active_manning_crew("pilot")
	Hooks.emit(&"projectile_dodged", r5.ship, {}, Vector2.ZERO)
	check("dodge counted", r5.track.dodges, 1)
	if pilot != null:
		check("pilot evasion", pilot.crew_stats[0], 1)
	var c: CrewMember = r5.ship.crew[0]
	Hooks.emit(&"crew_died", r5.ship, c)
	check("crew death counted", r5.track.crew_lost, 1)
	# The MORE STATS page lines (pure).
	var cols := StatsView.more_lines(p)
	check("more stats: three columns", cols.size(), 3)
	check("more stats: runs line", cols[0][0], ["Runs played", "4"])
	check("more stats: win rate", cols[0][4], ["Win rate", "50%"])
	check("more stats button off without the mod group", StatsView.more_enabled(),
		Settings.on("qol.stats.more_page") if Settings.items.has("qol.stats.more_page") else false)
	RunState.current = null


## The Stats screen draws the profile (top scores, ship best, stats, achievements) and the MORE STATS page.
func _stats_view() -> void:
	print("Stats screen (§2.4, §3)")
	var sv := StatsView.new()
	add_child(sv)
	sv.setup(TitleState.new())
	sv.open()
	for lr in [[0, 0], [1, 1], [0, 1]]:
		sv.left = lr[0]
		sv.right = lr[1]
		sv._build()
		await frames(2)
	check("no MORE STATS button without the filter", sv.buttons.has("more"), StatsView.more_enabled())
	var cb := func(_v): return true
	Hooks.add_filter(&"stats_more_button", cb)
	sv._build()
	check("MORE STATS button with the filter", sv.buttons.has("more"), true)
	sv.click((sv.buttons.more.rect as Rect2).get_center())
	check("MORE STATS page open", sv.more, true)
	await frames(2)
	sv.click((sv.buttons.more.rect as Rect2).get_center())
	check("BACK closes it", sv.more, false)
	Hooks.remove_filter(&"stats_more_button", cb)
	sv.queue_free()
