class_name LastStand
extends RefCounted
## Sector 8, "The Last Stand" (rules/flagship.md): the boss level of StarMap (GenerateMap's bossLevel branch,
## UpdateBoss / ReverseBossPath / ForceBossJump / ClearBoss / CheckGameOver, the waiting branch of
## UpdateDangerZone) and the fight flow of WorldManager / BossShip (GetEvent at the flagship's beacon, StartStage,
## GetSubEvent, Defeated, CommandGui::Victory). Static functions over a RunState; the boss state is the plain
## dictionary `RunState.boss` (saved with the run):
##   active (bossLevel), path (beacon ids, flagship start -> base), loc (bossLoc), jumping (bossJumping),
##   reversed (reversedPath), arrived (arrivedAtBase 0..4), base, stage (currentStage), next_stage, crew_counts,
##   death_began (bDeathBegan), won (CommandGui alreadyWon), victory_pending, power_time / power_goal / power_count,
##   stalemate / escaping / escape_timer / last_hull.
## Beacons of the boss level carry `boss` (the flagship is there) and `fleet_changing` (overtaken next turn).

const FINAL_DESC := "FINAL"
const BASE_EVENT := "FEDERATION_BASE"
const START_EVENT := "LAST_STAND_START"
const STAGE_TEXT := "BOSS_TEXT_"
const EV_AUTOMATED := "BOSS_AUTOMATED"
const EV_DESTROYED := "BOSS_DESTROYED"
const EV_ESCAPED := "BOSS_ESCAPED"
const EV_STALEMATE := "BOSS_STALEMATE"
const DANGER_ZONE := Vector2(60, 200)  # GenerateMap: dangerZone = (60, 200) (no move, no sweep)
const BASE_COLS := [[2, 3, 5], [2, 3, 5], [3, 4, 7]]  # easy / normal / hard: x = col0 + rand%2, min < nodes < max
const BOSS_COL := 4  # flagship start: (4 + rand%2, rand%4)
const BOSS_NODES := [4, 6]  # Dijkstra(flagship, base) node count 4..6 (3-5 jumps)
const TRIES := 16  # shared base + flagship attempts before the whole map is regenerated
const TURNS_TO_LOSE := 4  # arrivedAtBase == 4 -> CheckGameOver
## BossShip::GetEvent: StatusEffect {type 2 = limit, system 7 = sensors, amount 2, target 0 = player}.
const SENSOR_LIMIT := {"type": "limit", "target": "player", "system": "sensors", "amount": 2}


static func active(run: RunState) -> bool:
	return run != null and bool(run.boss.get("active", false))


# ------------------------------------------------------------------ map (GenerateMap, bossLevel)

## GenerateMap for the boss level: grid (regenerated until connected), start (0, rand%4); the base cell
## (2 + rand%2, rand%4) with exactly 3 jumps (easy / normal) or (3 + rand%2, rand%4) with 4–5 jumps (hard); start
## event = sector startEvent, base = FINISH_BEACON, GenerateEvents; then the danger zone (60, 200), one random
## non-base beacon flagged fleetChanging, the flagship start (4 + rand%2, rand%4) 3–5 jumps from the base (turned
## into a fleet beacon, `boss`), base event FEDERATION_BASE, start event LAST_STAND_START. 16 rejected base /
## flagship candidates in total -> everything is generated again. Returns [map, boss state].
static func generate(sector_seed: int, desc: XmlNode, engine: EventEngine) -> Array:
	var m := StarMap.new()
	m.seed = sector_seed
	m.desc_name = desc.attr("name") if desc else FINAL_DESC
	engine.rng = RandomNumberGenerator.new()
	engine.rng.seed = sector_seed
	engine.clear_sector()
	engine.crew_rarity.clear()
	if desc:
		var rl := desc.child("rarityList")
		if rl:
			for b in rl.children_named("blueprint"):
				engine.crew_rarity[b.attr("name")] = int(b.attr("rarity", "0"))
	var tun := RunTuning.section("map")
	var cols: Array = BASE_COLS[clampi(int(engine.difficulty), 0, 2)]
	var state := {}
	for guard in 200:
		m._populate_grid(engine, tun)
		if not m.all_connected():
			m.regenerations += 1
			continue
		m.start = m.beacon_at_cell(Vector2i(0, engine.r(int(tun.grid_h))))
		if m.start < 0:
			m.start = 0
		var tries := 0
		var base := -1
		while tries < TRIES:
			var y := engine.r(int(tun.grid_h))
			engine.r(2)  # the normal exit column draw, overwritten in the boss level
			var x := int(cols[0]) + engine.r(2)
			var id := m.beacon_at_cell(Vector2i(x, y))
			if id < 0:
				continue
			tries += 1
			var n := m.path(m.start, id).size()
			if n > int(cols[1]) and n < int(cols[2]):
				base = id
				break
		if base < 0:
			m.regenerations += 1
			continue
		m.exit = base
		m.beacons[base].exit = true
		var first := desc.child("startEvent").text if desc and desc.child("startEvent") else ""
		m.beacons[m.start].event = engine.base_event(first if first != "" else RunTuning.name_of("start_beacon"))
		m.beacons[base].event = engine.base_event(RunTuning.name_of("finish"))
		m._generate_events(desc, engine, tun)
		for b in m.beacons:
			b.boss = false
			b.fleet_changing = false
		var pick: Dictionary = m.beacons[engine.r(m.beacons.size())]
		if not pick.exit:
			pick.fleet_changing = true
		var path := []
		while tries < TRIES:
			var y := engine.r(int(tun.grid_h))
			var x := BOSS_COL + engine.r(2)
			var id := m.beacon_at_cell(Vector2i(x, y))
			if id < 0:
				continue
			tries += 1
			var p := m.path(id, base)
			if p.size() >= int(BOSS_NODES[0]) and p.size() <= int(BOSS_NODES[1]):
				path = p
				break
		if path.is_empty():
			m.regenerations += 1
			continue
		var bs: Dictionary = m.beacons[path[0]]
		bs.boss = true
		RebelFleet.overtake(m, path[0], engine)  # TurnIntoFleetLocation
		m.beacons[base].event = engine.base_event(BASE_EVENT)
		m.beacons[m.start].event = engine.base_event(START_EVENT)
		state = {"active": true, "path": path, "loc": 0, "jumping": false, "reversed": false, "arrived": 0,
			"base": base, "stage": 0, "next_stage": 1, "crew_counts": [], "death_began": true, "won": false,
			"victory_pending": false, "power_time": 0.0, "power_goal": 30.0, "power_count": 0}
		break
	var s: Dictionary = m.beacons[m.start]
	s.visited += 1
	s.known = true
	for n in s.links:
		m.beacons[n].known = true
	return [m, state]


## Sector entry of the Last Stand (RunState.enter_last_stand): map + boss state, fleet parked at (60, 200).
static func enter(run: RunState, level: int) -> void:
	run.sector = level
	run.engine.level = level
	run.sector_desc = FINAL_DESC
	var desc: XmlNode = run.engine.db.sectors.get(FINAL_DESC)
	var sector_seed := int(run.rng.randi() & 0x7fffffff)
	var res := generate(sector_seed, desc, run.engine)
	run.map = res[0]
	run.boss = res[1]
	var fm: Variant = Hooks.filter(&"map_generated", run.map, run, level)
	if fm is StarMap:
		run.map = fm
	run.fleet = RebelFleet.new()
	run.fleet.center = DANGER_ZONE
	if run.tree != null and run.sector_id >= 0:
		run.sector_name = run.tree.sectors[run.sector_id].name
	else:
		var nl := desc.child("nameList") if desc else null
		var names := nl.children_named("name") if nl else []
		run.sector_name = run.engine.tr_text(names[0].attr("id")) if not names.is_empty() else FINAL_DESC
	run.current_beacon = run.map.start
	run.selected = -1
	run._log("last stand: base %d, flagship path %s" % [int(run.boss.get("base", -1)), str(run.boss.get("path", []))])
	Hooks.emit(&"sector_entered", run, level, FINAL_DESC)
	run._arrive(false)


# ------------------------------------------------------------------ flagship movement (UpdateBoss)

static func boss_beacon(run: RunState) -> int:
	var B := run.boss
	var path: Array = B.get("path", [])
	return int(path[int(B.loc)]) if not path.is_empty() else -1


## The flagship's next hop (path[bossLoc + 1]) or -1 at the end of its path.
static func next_hop(run: RunState) -> int:
	var path: Array = run.boss.get("path", [])
	var i := int(run.boss.get("loc", 0)) + 1
	return int(path[i]) if i < path.size() else -1


static func turns_left(run: RunState) -> int:
	return TURNS_TO_LOSE - int(run.boss.get("arrived", 0))


## ReverseBossPath.
static func reverse_path(B: Dictionary) -> void:
	B.reversed = not bool(B.reversed)
	var p: Array = B.path
	p.reverse()
	B.loc = p.size() - 1 - int(B.loc)


## One turn of the flagship (StarMap::UpdateBoss, from UpdateDangerZone on every jump / wait): away from the
## base it alternates a "prepare" turn (bossJumping set) and a jump turn (one beacon along the path: the beacon is
## overtaken unless it is the base, and loses its store / repair / distress); at the base arrivedAtBase counts
## 1 → 4. Then every fleetChanging beacon is overtaken and 1 (2 once bossLoc > 1 or the path was reversed) new
## random non-base, non-overtaken beacons are flagged.
static func update_boss(run: RunState) -> void:
	var B := run.boss
	var m := run.map
	var path: Array = B.path
	var last := path.size() - 1
	var tail := false
	if not m.beacons[int(path[int(B.loc)])].exit:
		if int(B.loc) == last:
			reverse_path(B)
		B.arrived = 0
		if not bool(B.jumping):
			B.jumping = true
			tail = true
		else:
			_move(run)
			B.jumping = false
	else:
		if not bool(B.jumping):
			if int(B.arrived) != 0:
				B.arrived = mini(int(B.arrived) + 1, TURNS_TO_LOSE)
			B.jumping = true
			tail = true
		elif int(B.arrived) == 0:
			_move(run)
			B.jumping = false
		else:
			B.jumping = false
	if not tail and bool(B.reversed):
		reverse_path(B)
	if int(B.loc) == B.path.size() - 1:
		B.jumping = false
	# fleetChanging beacons are overtaken; new ones flagged.
	var cands := []
	for b in m.beacons:
		if b.get("fleet_changing", false):
			b.fleet_changing = false
			RebelFleet.overtake(m, b.id, run.engine)
			continue
		if not b.exit and not b.fleet:
			cands.append(b.id)
	if not cands.is_empty():
		m.beacons[cands[int(run.rng.randi() & 0x7fffffff) % cands.size()]].fleet_changing = true
		if cands.size() > 1 and (int(B.loc) > 1 or bool(B.reversed)):
			m.beacons[cands[int(run.rng.randi() & 0x7fffffff) % cands.size()]].fleet_changing = true
	run._log("flagship turn: beacon %d (%s), arrived %d" % [boss_beacon(run),
		"jumping" if B.jumping else "idle", int(B.arrived)])


static func _move(run: RunState) -> void:
	var B := run.boss
	var m := run.map
	var path: Array = B.path
	m.beacons[int(path[int(B.loc)])].boss = false
	B.loc = int(B.loc) + 1
	var b: Dictionary = m.beacons[int(path[int(B.loc)])]
	b.boss = true
	if not b.exit:
		RebelFleet.overtake(m, b.id, run.engine)
	var ev: Dictionary = b.event
	ev.store = false
	ev.repair = false
	ev.distress = false
	b.shop = null
	if int(B.loc) == path.size() - 1:
		B.arrived = 1


## ForceBossJump (the flagship escaped a fight): it jumps on the next turn; from the base it heads back out.
static func force_jump(run: RunState) -> void:
	var B := run.boss
	B.jumping = true
	if not bool(B.reversed) and int(B.loc) == B.path.size() - 1:
		reverse_path(B)
		B.arrived = 0


## ClearBoss (victory): every event cleared, no fleet, the current beacon becomes an exit.
static func clear_boss(run: RunState) -> void:
	var B := run.boss
	B.active = false
	run.fleet.center.x = -1000.0
	for b in run.map.beacons:
		b.event = run.engine.new_event("CLEARED")
		b.fleet = false
		b.fleet_changing = false
	run.beacon().exit = true
	var bb := boss_beacon(run)
	if bb >= 0:
		run.map.beacons[bb].boss = false


## StarMap::CheckGameOver: the flagship spent its turns at the base and the player is not fighting it there.
static func base_destroyed(run: RunState) -> bool:
	return active(run) and int(run.boss.get("arrived", 0)) == TURNS_TO_LOSE and boss_beacon(run) != run.current_beacon


## The map's WAIT button in the boss level (StarMap::OnLoop): also with fuel, as long as no ship is at the beacon.
static func can_wait(run: RunState) -> bool:
	return active(run) and run.phase == RunState.Phase.IDLE and (run.enemy.is_empty() or bool(run.enemy.done))


## Wait in the boss level (UpdateDangerZone's waiting branch): UpdateBoss, boss_wait, the current beacon's event
## cleared unless overtaken (out of fuel: SetupNoFuel as usual), then GetWaitLocation "arrives" at the same beacon.
## Returns false outside the boss level (RunState.wait does the normal thing).
static func wait(run: RunState) -> bool:
	if not active(run):
		return false
	run.map_open = false
	run.selected = -1
	update_boss(run)
	var b := run.beacon()
	if run.ship.fuel < 1:
		var names: Dictionary = RunTuning.section("fleet").names
		var n := String(names.no_fuel_distress if run.distress else names.no_fuel)
		if b.fleet:
			n = String(names.no_fuel_fleet)
			if run.engine.ae and run.engine.db.has_event_or_list(n + "_DLC"):
				n += "_DLC"
		b.event = run.engine.base_event(n, int(run.rng.randi() & 0x7fffffff))
	elif not b.fleet:
		b.event = run.engine.new_event("CLEARED")  # LocationEvent::ClearEvent(true)
	b.event_fresh = true
	run._log("wait (last stand): flagship at %d" % boss_beacon(run))
	run._clear_location(true)
	run._arrive(false)
	return true


# ------------------------------------------------------------------ the fight (WorldManager / BossShip)

## WorldManager::CreateLocation: at the flagship's beacon the event is BossShip::GetEvent (BOSS_TEXT_<nextStage>,
## a ship present, fleetPosition 1, the player's sensors limited to 2) and the flagship's next stage spawns.
static func location_event(run: RunState, b: Dictionary, ev: Dictionary) -> Dictionary:
	if not active(run) or not b.get("boss", false):
		return ev
	var B := run.boss
	var boss_ev := run.engine.base_event(STAGE_TEXT + str(int(B.next_stage)))
	if boss_ev.is_empty():
		boss_ev = run.engine.new_event(STAGE_TEXT + str(int(B.next_stage)))
	boss_ev.status = boss_ev.get("status", []) + [SENSOR_LIMIT.duplicate()]
	boss_ev.fleet_pos = 1
	boss_ev.flagship = true  # RunState._arrive: no beacon environment (CreateLocation uses this event's only)
	start_stage(run)
	return boss_ev


## BossShip::StartStage: currentStage = nextStage, stalemate reset, power timer started; the enemy record.
static func start_stage(run: RunState) -> void:
	var B := run.boss
	B.stage = int(B.next_stage)
	B.death_began = int(B.stage) != 3
	B.stalemate = 0.0
	B.escaping = false
	B.escape_timer = 15.0
	B.last_hull = -1
	FlagshipRule.start_timer(B, run.rng)
	var bp := FlagshipRule.blueprint_name(int(B.stage), int(run.engine.difficulty), run.engine.ae)
	run.enemy = {"boss": true, "stage": int(B.stage), "blueprint": bp, "ship_ev": {}, "hostile": true,
		"surrendered": false, "done": false, "outcome": "", "has_surrender": false, "has_escape": false,
		"escaping": false, "escaped": false, "escape_timer": 15.0, "status": []}
	run.enemy_serial += 1
	run.ship.ftl_charge = 0.0
	run.store_open = false
	run._log("flagship stage %d (%s), crew %s" % [int(B.stage), bp, str(B.crew_counts)])


## RunState.build_enemy_ship for the flagship.
static func build_ship(run: RunState) -> ShipState:
	var B := run.boss
	var es := FlagshipRule.build(int(B.stage), int(run.engine.difficulty), run.engine.ae, B.get("crew_counts", []))
	B.last_hull = es.hull
	Hooks.emit(&"enemy_ship_built", run, es)
	for st in run.enemy.get("status", []):
		RunState.apply_status_to(es, st)
	if run.hazard != null:
		run.hazard.apply_status(es)
	return es


## Per frame for the flagship (RunState.check_combat): BossShip::OnLoop (surges, crew snapshot, the death of the
## last stage = victory begins: music cut, `victory` stinger), the boss stalemate jump, then WorldManager's boss
## branch: BossShip::GetSubEvent (BOSS_AUTOMATED once the crew is dead; when the ship is gone BOSS_DESTROYED (stage
## 3) / BOSS_ESCAPED / BOSS_STALEMATE) -> Defeated ? ClearBoss + victory : ForceBossJump.
static func check_combat(run: RunState, es: ShipState, seconds: float) -> String:
	var E := run.enemy
	var B := run.boss
	if E.is_empty() or bool(E.done) or es == null:
		return ""
	var live := seconds > 0.0 and not run.modal()
	if live and bool(E.hostile):
		FlagshipRule.loop(B, es, seconds, run.rng, int(run.engine.difficulty))
		if not bool(E.escaped) and FlagshipRule.stalemate(B, es, run.ship, seconds):
			E.escaped = true  # ShipManager::JumpLeave: 2 s jump animation (main.gd draws it)
			E.jump_left = FlagshipRule.JUMP_TIME
			es.jumping = true
			run._log("flagship stalemate: it jumps away")
		E.escaping = bool(B.get("escaping", false))
		E.escape_timer = float(B.get("escape_timer", 15.0))
	elif live:
		FlagshipRule.tick_super_drones(es)
	if bool(E.escaped) and float(E.get("jump_left", 0.0)) > 0.0:
		E.jump_left = float(E.jump_left) - seconds
	# BossShip::OnLoop: dying and not jumping -> the next stage; in stage 3 the victory starts at once.
	if es.is_destroyed() and not es.jumping:
		B.next_stage = mini(int(B.stage) + 1, 3)
		if es.explosion != null and FlagshipRule.invincible(es) and not es.explosion.jump_out:
			es.explosion.set_jump_out(true)  # Ship::SetDestroyed(bossAnimation = bInvincible)
		if not bool(B.death_began):
			B.death_began = true
			_victory_begins(run)
	if int(B.stage) == 3 and es.is_destroyed() and not es.destroyed_done():
		B.won = true  # CommandGui::SetBossDead: no game over from now on
	if run.phase != RunState.Phase.IDLE or not bool(E.hostile):
		return ""
	if base_destroyed(run):
		return ""
	# GetSubEvent
	var gone := es.destroyed_done() or (bool(E.escaped) and float(E.get("jump_left", 0.0)) <= 0.0)
	if not gone:
		if _dead_crew(run, es):
			es.blueprint.crew = []  # bAutomated: the systems run without crew
			run._log("flagship crew dead: automated")
			_show(run, EV_AUTOMATED)
			return "automated"
		return ""
	if _player_crew_aboard(es) > 0:
		run.lost_crew_flag = true
		AchievementTracker.set_flag(run, "lost_crew")
	var name := EV_STALEMATE if bool(E.escaped) else (EV_DESTROYED if int(B.stage) == 3 else EV_ESCAPED)
	if bool(E.escaped):
		B.next_stage = int(B.stage)
	E.done = true
	E.hostile = false
	E.outcome = name
	var kind := "boss_stalemate" if bool(E.escaped) else ("boss_destroyed" if name == EV_DESTROYED else "boss_escaped")
	Hooks.emit(&"combat_outcome", run, kind)
	_show(run, name)
	if name == EV_DESTROYED:  # BossShip::Defeated -> StarMap::ClearBoss + CommandGui::Victory
		clear_boss(run)
		B.victory_pending = true
	else:
		force_jump(run)
	return kind


static func _show(run: RunState, name: String) -> void:
	var ev := run.engine.base_event(name)
	if ev.is_empty():
		return
	run._log("flagship event %s" % name)
	run.show_event(ev)


## CompleteShip::DeadCrew for the flagship: no crew of its side alive anywhere and not automated yet.
static func _dead_crew(run: RunState, es: ShipState) -> bool:
	if es.blueprint.crew.is_empty():
		return false
	var mine := func(c): return c.is_alive() and not c.player_owned and not c.is_drone()
	return es.crew.filter(mine).is_empty() and run.ship.crew.filter(mine).is_empty()


static func _player_crew_aboard(es: ShipState) -> int:
	return es.crew.filter(func(c): return c.is_alive() and c.player_owned and not c.is_drone()).size()


## BossShip::OnLoop at the last stage's death: StopPlaylist(100) + sound `victory`, ScoreKeeper::SetVictory.
## (ACH_WIN_EASY / ACH_WIN_NORMAL, SetVictoryAchievement and the score save follow from RunState.end_run("victory")
## through ProfileTracker.)
static func _victory_begins(run: RunState) -> void:
	run.score.victory = true
	run._log("flagship destroyed: victory")
	var music: Node = Engine.get_main_loop().root.get_node_or_null("Music") if Engine.get_main_loop() is SceneTree \
		else null
	if music != null and music.has_method("boss_destroyed"):
		music.boss_destroyed()
	else:
		FtlData.play("victory")


## Per unpaused frame (RunState.tick): CommandGui::CheckGameover's StarMap::CheckGameOver (gameover_fedbase) and,
## once the BOSS_DESTROYED box is closed, CommandGui::Victory -> the victory window (gameover_win).
static func tick(run: RunState) -> void:
	if run.over != "":
		return
	if bool(run.boss.get("victory_pending", false)) and run.phase == RunState.Phase.IDLE:
		run.boss.victory_pending = false
		run.over_cause = "gameover_win"
		run.end_run("victory", FtlData.tr_id("gameover_win").replace("\\n", "\n"))
		return
	if base_destroyed(run) and not bool(run.boss.get("won", false)):
		run.game_over("gameover_fedbase")


## CommandGui alreadyWon: the flagship's last stage is dying or dead -> no game over.
static func already_won(run: RunState) -> bool:
	return run != null and bool(run.boss.get("won", false))


# ------------------------------------------------------------------ debug / CLI (main.gd _run_cli_partb)

## --last-stand: jump straight into sector 8. --boss-stage=N: sector 8, then straight to the flagship's beacon with
## stage N next (stages 2 / 3 start with the stage-1 crew). --boss-turns=N: N flagship turns (map screenshots).
## --boss-surge: the power timer 0.5 s before its surge.
static func cli(run: RunState, a: String) -> void:
	if run == null:
		return
	if a == "--last-stand":
		debug_enter(run)
	elif a.begins_with("--boss-stage="):
		debug_enter(run)
		debug_fight(run, int(a.get_slice("=", 1)))
	elif a.begins_with("--boss-turns="):
		debug_enter(run)
		for i in int(a.get_slice("=", 1)):
			update_boss(run)
	elif a == "--boss-surge" and active(run):
		run.boss.power_time = float(run.boss.get("power_goal", 30.0)) - 0.5


static func _close_dialogs(run: RunState) -> void:
	for i in 8:
		if run.phase == RunState.Phase.DIALOG:
			run.choose(maxi(run.dialog_choices.find_custom(func(v): return v.enabled), 0))
		elif run.phase == RunState.Phase.MESSAGE:
			run.apply(RunIntent.make(RunIntent.CONTINUE))


static func debug_enter(run: RunState) -> void:
	if active(run):
		return
	_close_dialogs(run)
	run._clear_location()
	if run.tree != null:
		run.sector_id = run.tree.final_id()
		run.tree.sectors[run.sector_id].visited = true
	run.score.set_sector(8)
	run.enter_last_stand()
	print("last stand: base %d, flagship at %d, path %s" % [int(run.boss.base), boss_beacon(run), str(run.boss.path)])


static func debug_fight(run: RunState, stage: int) -> void:
	_close_dialogs(run)
	var B := run.boss
	B.next_stage = clampi(stage, 1, 3)
	if B.next_stage > 1 and B.get("crew_counts", []).is_empty():
		B.crew_counts = FlagshipRule.stage_crew(1, [], 19)
	run._clear_location()
	run.current_beacon = boss_beacon(run)
	run._arrive(true)
	print("flagship fight: stage %d at beacon %d" % [int(B.stage), run.current_beacon])
