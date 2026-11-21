extends Node
## Tests for the run loop (rules/starmap.md §5, rules/events.md §5.4, rules/ship_destruction.md §6): jumping
## (fuel, arrival, visited/known, event shown), map intents, combat events, victory rewards, dead crew,
## surrender, exit beacon, and the PC / touch input profiles. Uses the user's FTL data. Run:
##   godot --headless --path godot res://tests/test_run.tscn

const Harness := preload("res://tests/harness.gd")

const DT := 1.0 / 60.0
var fails := 0


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func close_dialogs(r: RunState) -> void:
	for i in 10:
		if r.phase == RunState.Phase.DIALOG:
			var first := r.dialog_choices.find_custom(func(v): return v.enabled)
			r.choose(maxi(first, 0))
		elif r.phase == RunState.Phase.MESSAGE:
			r.apply(RunIntent.make(RunIntent.CONTINUE))


func ship_beacon(r: RunState, adjacent: bool) -> int:
	for b in r.map.beacons:
		var s: Dictionary = b.event.get("ship", {})
		if b.id == r.current_beacon or s.is_empty() or s.get("hostile_only", false) or not s.get("hostile", false):
			continue
		if adjacent and not r.map.connected(r.current_beacon, b.id):
			continue
		return b.id
	return -1


## Explodes `es` (hull 0) and ticks it until DestroyedDone (3 s).
func explode(es: ShipState) -> void:
	es.hull = 0
	var t := 0.0
	while not es.destroyed_done() and t < 10.0:
		es.tick(DT * GameClock.BASE)
		t += DT


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	var r := RunState.new_run(2024)
	check("start dialog open", r.phase, RunState.Phase.DIALOG)
	check("map refused under the dialog", r.apply(RunIntent.make(RunIntent.OPEN_MAP)), false)
	close_dialogs(r)
	check("idle after the start event", r.phase, RunState.Phase.IDLE)
	check("FTL full at a safe beacon", r.ship.ftl_charge, 1.0)
	check("open map", r.apply(RunIntent.make(RunIntent.OPEN_MAP)), true)
	var start := r.current_beacon
	var far := -1
	for b in r.map.beacons:
		if b.id != start and not r.map.connected(start, b.id):
			far = b.id
			break
	check("non-neighbour cannot be selected", r.apply(RunIntent.make(RunIntent.SELECT_BEACON, far)), false)
	var nb: int = r.map.links_of(start)[0]
	check("neighbour selected", r.apply(RunIntent.make(RunIntent.SELECT_BEACON, nb)), true)
	var fuel0 := r.ship.fuel
	var arr0 := r.arrival_serial
	check("confirm jump", r.apply(RunIntent.make(RunIntent.CONFIRM_JUMP)), true)
	check("jump consumes 1 fuel", r.ship.fuel, fuel0 - 1)
	check("arrived", r.current_beacon, nb)
	check("arrival counted", [r.arrival_serial - arr0, r.map.beacon(nb).visited], [1, 1])
	check("map closed after the jump", r.map_open, false)
	check("neighbours of the new beacon known", r.map.links_of(nb).all(func(n): return r.map.beacon(n).known), true)
	var ev: Dictionary = r.map.beacon(nb).event
	check("beacon event fires on arrival", r.phase == RunState.Phase.DIALOG or not ev.get("content", false), true)
	if r.phase == RunState.Phase.DIALOG:
		check("dialog is the beacon's event", r.dialog.name, ev.name)

	# Out of fuel: no target.
	close_dialogs(r)
	if not r.has_hostile():
		r.ship.fuel = 0
		r.apply(RunIntent.make(RunIntent.OPEN_MAP))
		check("no fuel: neighbour cannot be selected", r.apply(RunIntent.make(RunIntent.SELECT_BEACON,
			r.map.links_of(r.current_beacon)[0])), false)
		r.apply(RunIntent.make(RunIntent.CLOSE_MAP))
		r.ship.fuel = 10

	# --- combat event: a hostile ship appears, FTL drive charges (placeholder), victory gives rewards
	var r2 := RunState.new_run(31337)
	close_dialogs(r2)
	var sb := ship_beacon(r2, false)
	check("a beacon with a hostile ship exists", sb >= 0, true)
	var es0 := r2.enemy_serial
	r2.jump_to(sb)
	check("combat event spawns the event ship", [r2.enemy.is_empty(), r2.enemy_serial - es0, r2.has_hostile()],
		[false, 1, true])
	check("enemy blueprint exists", FtlData.has_ship_blueprint(r2.enemy.blueprint), true)
	check("FTL charge reset by the hostile ship", r2.ship.ftl_charge, 0.0)
	close_dialogs(r2)
	check("still hostile after the dialog", r2.has_hostile(), true)
	check("map refused while charging", r2.apply(RunIntent.make(RunIntent.OPEN_MAP)), false)
	var e2 := r2.ship.sys("engines")
	var expect: float = 85.0 / ((float(e2.effective_power() - 1) * 0.35 + 1.25) * 0.0625 * [1.0, 1.1, 1.17, 1.25][r2.ship.crew_level_in("engines")] * 16.0)
	check("FTL seconds to full = 85 / engine speed (%.1f s)" % expect, absf(FtlDrive.seconds_to_full(r2.ship) - expect) < 0.01, true)
	for i in int(expect / 0.5) - 1:
		r2.tick(0.5)
	check("FTL not full just before", r2.ship.ftl_charge < 1.0, true)
	for i in 3:
		r2.tick(0.5)
	check("FTL charges with engines + pilot", r2.ship.ftl_charge, 1.0)
	r2.ship.ftl_charge = 0.0
	var pilot_room := r2.ship.sys("pilot").room
	for c in r2.ship.crew:
		if c.room == pilot_room:
			c.stun = 100.0  # stunned crew do not man the pilot seat
	r2.tick(5.0)
	check("no charge without a pilot (ShipFlying)", r2.ship.ftl_charge, 0.0)
	for c in r2.ship.crew:
		c.stun = 0.0
	r2.ship.ftl_charge = 0.0
	var es := ShipState.new(r2.enemy.blueprint, false)
	check("no outcome while alive", r2.check_combat(es), "")
	explode(es)
	var scrap0 := r2.ship.scrap
	var fuel0b := r2.ship.fuel
	var missiles0 := r2.ship.missiles
	var parts0 := r2.ship.drone_parts
	check("victory: destroyed outcome", r2.check_combat(es), "destroyed")
	check("reward box open", r2.phase, RunState.Phase.DIALOG)
	var gained := (r2.ship.scrap - scrap0) + (r2.ship.fuel - fuel0b) + (r2.ship.missiles - missiles0) \
		+ (r2.ship.drone_parts - parts0)
	check("victory gives resources (%s)" % str(r2.dialog_rewards), gained > 0 and not r2.dialog_rewards.is_empty(),
		true)
	check("listed rewards match the ship (scrap)", r2.ship.scrap - scrap0, r2.dialog_rewards.reduce(
		func(a, x): return a + (int(x[1]) if x[0] == "scrap" else 0), 0))
	var rewards2 := r2.dialog_rewards.duplicate(true)
	check("enemy done, not hostile", [r2.enemy.done, r2.has_hostile()], [true, false])
	check("outcome only once", r2.check_combat(es), "")
	close_dialogs(r2)
	check("FTL ready after the fight", r2.ship.ftl_charge, 1.0)
	# Same ship seed -> same reward (seeded outcome event).
	var r3 := RunState.new_run(31337)
	close_dialogs(r3)
	r3.jump_to(sb)
	close_dialogs(r3)
	var es3 := ShipState.new(r3.enemy.blueprint, false)
	explode(es3)
	r3.check_combat(es3)
	check("victory reward reproducible from the ship seed", r3.dialog_rewards, rewards2)

	# --- dead crew victory
	var r4 := RunState.new_run(31337)
	close_dialogs(r4)
	r4.jump_to(sb)
	close_dialogs(r4)
	var es4 := ShipState.new(r4.enemy.blueprint, false)
	if not es4.blueprint.crew.is_empty():
		for c in es4.crew:
			c.hp = 0.0
		# CompleteShip::DeadCrew counts the enemy side's crew anywhere: a living enemy boarder on our ship
		# keeps the ship hostile (CrewMemberFactory enemyCrew is by owner, not by ship).
		var boarder := r4.ship.add_crew("human", false)
		check("dead crew aboard, enemy boarder alive on our ship: no outcome yet", r4.check_combat(es4), "")
		boarder.hp = 0.0
		check("dead crew outcome", r4.check_combat(es4), "deadCrew")
		check("dead crew: enemy harmless", r4.has_hostile(), false)
		# Jumping away with own crew still aboard (WorldManager::ClearLocation: lost_crew flag,
		# KillEveryone(noClone = true)): they are lost for good, never cloned.
		close_dialogs(r4)
		var left: CrewMember = r4.ship.crew[0]
		var n0 := r4.ship.crew.size()
		r4.ship.crew.erase(left)
		es4.crew.append(left)
		left.place(es4, es4.layout.rooms[0].id, 0)
		r4.ship.opponent = es4
		r4.jump_to(int(r4.map.links_of(r4.current_beacon)[0]))
		check("jump with crew aboard the enemy: lost (dead, no clone, flag)", [left.is_alive(),
			left.has_meta("no_clone"), r4.lost_crew_flag, es4.crew.has(left), r4.ship.clone_queue.has(left)],
			[false, true, true, false, false])
		check("  one crew fewer aboard our ship", r4.ship.crew.size(), n0 - 1)

	# --- surrender (a template with <surrender>)
	var r5 := RunState.new_run(31337)
	close_dialogs(r5)
	var pirate := {"template": "PIRATE", "node": r5.engine.db.ships["PIRATE"], "hostile": true, "seed": 42}
	for s in range(1, 40):  # a ship seed whose surrender roll is not "none" (chance 0.5)
		pirate.seed = s
		if int(r5.engine.setup_ship(pirate).surrender_threshold) >= 1:
			break
	r5.show_event({"name": "TEST", "text": "x", "choices": [{"text": "c", "req": "", "lvl": 1, "max_lvl": 99,
		"max_group": -1, "blue": false, "hidden": true, "event": {}}], "res": {"fuel": 0, "missiles": 0, "drones": 0,
		"scrap": 0}, "steal": false, "weapon": "", "drone": "", "augment": "", "crew": {}, "remove_crew": {},
		"remove": "", "upgrade": {}, "damage": [], "status": [], "environment": -1, "env_target": 2, "ship": pirate,
		"boarders": {}, "store": false, "distress": false, "reveal_map": false, "repair": false, "modify_pursuit": 0,
		"quest": "", "secret_sector": false, "unlock_ship": -1, "auto_reward": [], "content": true})
	close_dialogs(r5)
	check("PIRATE template has a surrender threshold", r5.enemy.has_surrender, true)
	var es5 := ShipState.new(r5.enemy.blueprint, false)
	es5.hull = maxi(int(r5.enemy.surrender_threshold), 1)
	var sur := r5.check_combat(es5)
	if int(r5.enemy.surrender_threshold) >= 1:
		check("surrender outcome at the threshold", sur, "surrender")
		check("surrender is a choice event", r5.phase == RunState.Phase.DIALOG and r5.dialog_choices.size() >= 2,
			true)
		# Accepting: the choice whose event carries <ship hostile="false"/> makes the ship non-hostile.
		var acc := -1
		for i in r5.dialog_choices.size():
			var cev: Dictionary = r5.dialog_choices[i].event
			if not cev.is_empty() and not cev.ship.is_empty() and cev.ship.get("hostile_only", false) 					and not bool(cev.ship.hostile):
				acc = i
		check("surrender has an accept choice (ship hostile=false)", acc >= 0, true)
		if acc >= 0:
			check("  shows its resources as a ResourceBox", r5.dialog_choices[acc].has("preview_res"), true)
			r5.choose(acc)
			check("accepted surrender: enemy no longer hostile", r5.has_hostile(), false)
			es5.hostile = bool(r5.enemy.hostile)
			var wc5 := WeaponControl.new(r5.ship)
			r5.ship.weapons[0].powered = true
			wc5.select(0)
			check("  ship cannot be aimed at", [wc5.armed, wc5.aim_at(es5, 0)], [0, false])
			es5.hostile = true
			check("  (a hostile one can)", wc5.aim_at(es5, 0), true)
			es5.hostile = false
			check("  interior hidden", es5.shows_interior(), false)
	else:
		check("surrender chance rolled 'none' (threshold 0)", sur, "")

	# --- exit beacon: next sector placeholder
	var r6 := RunState.new_run(5)
	close_dialogs(r6)
	r6.jump_to(r6.map.exit)
	close_dialogs(r6)
	if not r6.has_hostile():
		r6.apply(RunIntent.make(RunIntent.OPEN_MAP))
		check("at exit", r6.at_exit(), true)
		check("next sector opens the sector map", [r6.apply(RunIntent.make(RunIntent.NEXT_SECTOR)), r6.choosing_sector], [true, true])

	# --- ShipGenerator scaling (rules/events.md §5.3)
	var g0 := ShipGenerator.generate("REBEL_FAT", 0, EventEngine.Difficulty.NORMAL, 77)
	var g7 := ShipGenerator.generate("REBEL_FAT", 7, EventEngine.Difficulty.NORMAL, 77)
	check("same seed → same plan", ShipGenerator.generate("REBEL_FAT", 3, 1, 9),
		ShipGenerator.generate("REBEL_FAT", 3, 1, 9))
	check("crew int(min(0.125·S, 1)·(max − amount) + amount): 3 at sector 1, 4 at sector 8", [g0.crew.size(), g7.crew.size()], [3, 4])
	var lv0 := 0
	var lv7 := 0
	for id in g0.levels:
		lv0 += int(g0.levels[id])
	for id in g7.levels:
		lv7 += int(g7.levels[id])
	check("later sectors: more system levels (%d < %d)" % [lv0, lv7], lv0 < lv7, true)
	check("levels within [power, max]", g7.levels.keys().all(func(id): return int(g7.levels[id]) <= int(g7.max[id])),
		true)
	check("weapons fit the weapons level", g7.weapons.map(func(n): return int(FtlData.weapon_blueprint(n).power)).reduce(
		func(acc, x): return acc + x, 0) <= int(g7.levels.weapons) or g7.weapons.size() == 1, true)
	check("enemy scrap 25(S+1)^1.8 + 150", [g0.scrap, g7.scrap], [175, int(25.0 * pow(8, 1.8) + 150)])
	# BlueprintManager::GetBlueprintList: with AE on, OVERRIDE_WEAPONS_REBEL replaces WEAPONS_REBEL (flak, chain,
	# charge lasers added); without AE the base list.
	check("AE weapon pool = OVERRIDE_ list", [FtlData.blueprint_list_ae("WEAPONS_REBEL", true).has("SHOTGUN"),
		FtlData.blueprint_list_ae("WEAPONS_REBEL", false).has("SHOTGUN")], [true, false])
	var ae_only := ["SHOTGUN", "SHOTGUN_2", "LASER_CHAINGUN", "LASER_CHAINGUN_2", "LASER_CHARGEGUN_2"]
	var seen := [false, false]  # [AE plans used an AE-only weapon, non-AE plans did]
	for sd in 60:
		for k in 2:
			var gp := ShipGenerator.generate("REBEL_FAT", 5, EventEngine.Difficulty.NORMAL, sd, null, k == 0)
			if gp.weapons.any(func(n): return n in ae_only):
				seen[k] = true
	check("AE-only weapons appear only in AE plans", seen, [true, false])
	var gs := ShipState.new("REBEL_FAT", false)
	ShipGenerator.apply(gs, g7)
	check("plan applied (crew, weapons)", [gs.own_crew().size(), gs.weapons.size()], [4, g7.weapons.size()])
	check("enemy reactor powers its systems", gs.reactor_used() <= gs.reactor_capacity(), true)

	# --- escape (rules/combat_ai.md §4): escape event at the threshold, timer while flying → gotaway
	var re := RunState.new_run(31337)
	close_dialogs(re)
	var esc_ev := {"template": "PIRATE", "node": re.engine.db.ships["PIRATE"], "hostile": true, "seed": 3}
	re._spawn_enemy(esc_ev)
	var ees := re.build_enemy_ship()
	re.enemy.has_surrender = false
	re.enemy.escape_threshold = 5
	re.enemy.has_escape = true
	re.enemy.escape_timer = 2.0
	ees.hull = 5
	check("escape event at the threshold", re.check_combat(ees, 0.1), "escape")
	close_dialogs(re)
	check("escaping", re.enemy.escaping, true)
	for i in 30:
		re.check_combat(ees, 0.1)
	check("timer out: jumping, gotaway waits for the 2 s jump animation", [re.enemy.escaped, re.enemy.outcome],
		[true, ""])
	for i in 25:
		re.check_combat(ees, 0.1)
	check("timer runs out → got away", [re.enemy.escaped, re.enemy.outcome, re.has_hostile()], [true, "gotaway", false])

	# --- escape + non-hostile (ShipAI::OnLoop(hostile) stands down: no countdown, no JumpLeave, no gotaway);
	# menu pause freezes the timer. A hostile rebel that gets away applies its gotaway event (modifyPursuit +1).
	var rrun := RunState.new_run(4242)
	close_dialogs(rrun)
	rrun._spawn_enemy({"template": "REBEL_AUTO_WARNING", "node": rrun.engine.db.ships["REBEL_AUTO_WARNING"],
		"hostile": true, "seed": 5})
	var esc_rebel := rrun.build_enemy_ship()
	rrun.enemy.has_surrender = false
	rrun.enemy.escape_threshold = 5
	rrun.enemy.has_escape = true
	rrun.enemy.escape_timer = 1.0
	esc_rebel.hull = 5
	var pd0: int = rrun.fleet.pursuit_delay
	check("rebel: escape event", rrun.check_combat(esc_rebel, 0.1), "escape")
	check("escape event box open: timer frozen (menu pause)", [rrun.modal(), rrun.check_combat(esc_rebel, 0.5),
		rrun.enemy.escape_timer], [true, "", 1.0])
	close_dialogs(rrun)
	for i in 40:
		rrun.check_combat(esc_rebel, 0.1)
	check("hostile rebel got away: gotaway event, pursuit +1", [rrun.enemy.outcome, rrun.fleet.pursuit_delay - pd0],
		["gotaway", 1])

	var rn := RunState.new_run(4242)
	close_dialogs(rn)
	rn._spawn_enemy({"template": "REBEL_AUTO_WARNING", "node": rn.engine.db.ships["REBEL_AUTO_WARNING"],
		"hostile": true, "seed": 5})
	var rnes := rn.build_enemy_ship()
	rn.enemy.has_surrender = false
	rn.enemy.escape_threshold = 5
	rn.enemy.has_escape = true
	rn.enemy.escape_timer = 1.0
	rnes.hull = 5
	var pdn: int = rn.fleet.pursuit_delay
	rn.check_combat(rnes, 0.1)
	close_dialogs(rn)
	rn.check_combat(rnes, 0.5)
	rn.enemy.hostile = false  # what an event's <ship hostile="false"/> does (RunState.show_event)
	for i in 60:
		rn.check_combat(rnes, 0.1)
	check("neutral escaping rebel: no jump, no gotaway, no pursuit change",
		[rn.enemy.escaped, rnes.jumping, rn.enemy.outcome, rn.fleet.pursuit_delay - pdn, rn.enemy.escape_timer],
		[false, false, "", 0, 0.5])

	# Real flow: an escaping pirate surrenders, the player accepts (PIRATE_SURRENDER choice 1: hostile="false").
	var rsur := RunState.new_run(31337)
	close_dialogs(rsur)
	rsur._spawn_enemy({"template": "PIRATE", "node": rsur.engine.db.ships["PIRATE"], "hostile": true, "seed": 3})
	var rses := rsur.build_enemy_ship()
	rsur.enemy.has_surrender = true
	rsur.enemy.surrender_threshold = 3
	rsur.enemy.escape_threshold = 5
	rsur.enemy.has_escape = true
	rsur.enemy.escape_timer = 3.0
	rses.hull = 5
	check("pirate: escape event", rsur.check_combat(rses, 0.1), "escape")
	close_dialogs(rsur)
	rsur.check_combat(rses, 1.0)
	rses.hull = 3
	check("escaping pirate surrenders", rsur.check_combat(rses, 0.1), "surrender")
	for i in 30:
		rsur.check_combat(rses, 0.1)  # the surrender box is open: frozen
	check("surrender box open: escape timer frozen (1.9: the surrender frame still counted)",
		roundi(rsur.enemy.escape_timer * 10.0), 19)
	close_dialogs(rsur)  # accept
	check("accepted surrender: neutral", rsur.enemy.hostile, false)
	for i in 60:
		rsur.check_combat(rses, 0.1)
	check("neutral (surrendered) pirate never jumps away",
		[rsur.enemy.escaped, rses.jumping, rsur.enemy.outcome, roundi(rsur.enemy.escape_timer * 10.0)],
		[false, false, "", 19])

	# --- input profiles
	var rp := RunState.new_run(77)
	close_dialogs(rp)
	var pc := InputProfile.new(InputProfile.PC)
	pc.run = rp
	rp.apply(RunIntent.make(RunIntent.OPEN_MAP))
	var n0: int = rp.map.links_of(rp.current_beacon)[0]
	pc.beacon_hover(n0)
	check("pc: hover selects a reachable beacon", rp.selected, n0)
	pc.beacon_click(n0)
	check("pc: click jumps at once", rp.current_beacon, n0)
	var rt := RunState.new_run(77)
	close_dialogs(rt)
	var touch := InputProfile.new(InputProfile.TOUCH)
	touch.run = rt
	touch.ftl_button()
	check("touch: FTL button opens the map", rt.map_open, true)
	var n1: int = rt.map.links_of(rt.current_beacon)[0]
	touch.beacon_hover(n1)
	check("touch: no hover selection", rt.selected, -1)
	touch.beacon_click(n1)
	check("touch: tap selects, no jump", [rt.selected, rt.current_beacon != n1], [n1, true])
	touch.jump_button()
	check("touch: JUMP confirms", rt.current_beacon, n1)
	# Touch dialog: two taps (after the 0.3 s guard).
	var db := EventDB.new()
	db.add_source("<event name=\"Q\"><text>q</text><choice><text>one</text><event><text>after</text></event>" +
		"</choice><choice><text>two</text><event/></choice></event>")
	var rq := RunState.new()
	rq.engine = EventEngine.new(db)
	rq.ship = ShipState.new("PLAYER_SHIP_HARD", true)
	rq.show_event(rq.engine.base_event("Q"))
	var tq := InputProfile.new(InputProfile.TOUCH)
	tq.run = rq
	tq.dialog_opened()
	tq.choice_click(0)
	check("touch: taps ignored in the first 0.3 s", rq.highlighted, -1)
	tq.dialog_opened_at -= 1.0
	tq.choice_click(0)
	check("touch: first tap highlights", [rq.highlighted, rq.dialog.text], [0, "q"])
	tq.choice_click(0)
	check("touch: second tap applies", rq.dialog.text, "after")
	var pq := InputProfile.new(InputProfile.PC)
	pq.run = rq
	pq.choice_key(0)
	check("keys apply directly", rq.phase, RunState.Phase.IDLE)

	_touch_map_view()
	_jump_gates()

	# Event crew (FRIENDLY_SLAVER choice 1): named crew in the pilot room, shown as a ResourceBox crew item.
	var rc := RunState.new_run(7)
	rc.ship.scrap = 100
	var slaver := rc.engine.base_event("FRIENDLY_SLAVER")
	var named := slaver.duplicate(true)  # unique event: keep a copy for the named-crew check
	rc.show_event(slaver)
	var crew0 := rc.ship.crew.size()
	rc.choose(0)
	check("slaver event adds a crew member", rc.ship.crew.size(), crew0 + 1)
	var newc: CrewMember = rc.ship.crew[-1]
	check("  it has a name, not the race", newc.name_long != "", true)
	check("  placed in the pilot room", newc.room, rc.ship.sys("pilot").room)
	var crw: Array = rc.dialog_rewards.filter(func(x): return String(x[0]) == "crew")
	check("  reward entry carries the name", (crw[0][2] as Dictionary).get("name", "") if not crw.is_empty() else "",
		newc.name_long)
	var bx := EventBox.new()
	var rres: Dictionary = bx._reward_resources(rc.dialog_rewards)
	bx.free()
	check("  ResourceBox gets the crew item and the scrap", [rres.has("crew"), int(rres.get("scrap", 0)) < 0],
		[true, true])
	# <crewMember id=...>: the event's name is kept
	named.choices[0].event.crew.name = "Charlie"
	rc.show_event(named)
	rc.choose(0)
	check("crewMember id=name: the event's name", rc.ship.crew[-1].name_long, "Charlie")



func _motion(v: Control, p: Vector2, held: bool) -> void:
	var e := InputEventMouseMotion.new()
	e.position = p
	e.button_mask = MOUSE_BUTTON_MASK_LEFT if held else 0
	v._gui_input(e)


func _press(v: Control, p: Vector2, pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.position = p
	e.pressed = pressed
	e.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	v._gui_input(e)


## A finger tap at `p` as TooltipService delivers it: land (held motion), press, release, lift (off-screen motion).
func _tap(v: Control, p: Vector2) -> void:
	_motion(v, p, true)
	_press(v, p, true)
	_press(v, p, false)
	_motion(v, TooltipService.OFF_SCREEN, false)


## Touch beacon map view: JUMP states, the fixed info panel (selected beacon; a held finger previews another one
## until it lifts), PC unchanged (no JUMP, no panel, hover selects).
func _touch_map_view() -> void:
	print("touch map view: JUMP + info panel")
	var rv := RunState.new_run(77)
	close_dialogs(rv)
	var tp := InputProfile.new(InputProfile.TOUCH)
	tp.run = rv
	tp.ftl_button()
	var v := StarMapView.new()
	add_child(v)
	v.setup(rv, tp)
	check("touch map: nothing selected: JUMP off, no panel", [v.jump_state(), v.info_beacon(), v.info_rect().size.x],
		["off", -1, 0.0])
	var n1: int = rv.map.links_of(rv.current_beacon)[0]
	_tap(v, v.screen_pos(n1))
	check("tap a beacon: selected, panel shows it, JUMP lit", [rv.selected, v.info_beacon(), v.jump_state()],
		[n1, n1, "on"])
	var want := TooltipText.rule("beacon", func(x: String) -> String: return x, [v._location_text(n1, v._fleet_changing())])
	check("  panel text = the beacon tooltip text", [v.info_text(n1), want != ""], [want, true])
	var ir := v.info_rect()
	var jr := v._jump_rect()
	check("  panel stacked on JUMP (same x, above it), right of the map",
		[ir.position.x == jr.position.x, ir.end.y <= jr.position.y, jr.position.x >= StarMapView.WIN.end.x], [true, true, true])
	var n2 := -1
	for b in rv.map.beacons:
		if b.id != n1 and b.id != rv.current_beacon:
			n2 = b.id
			break
	var empty := StarMapView.WIN.position + Vector2(3, 60)
	check("  test point is empty", v.beacon_at(empty), -1)
	_motion(v, empty, true)
	_press(v, empty, true)
	_motion(v, v.screen_pos(n2), true)
	check("finger held on another beacon: panel shows it, selection kept", [v.info_beacon(), rv.selected], [n2, n1])
	check("  panel text follows", v.info_text(v.info_beacon()), TooltipText.rule("beacon",
		func(x: String) -> String: return x, [v._location_text(n2, v._fleet_changing())]))
	_motion(v, empty, true)
	_press(v, empty, false)
	_motion(v, TooltipService.OFF_SCREEN, false)
	check("finger lifted: panel back on the selected beacon", [v.info_beacon(), rv.selected], [n1, n1])
	var cur := rv.current_beacon
	_tap(v, jr.get_center())
	check("tap JUMP: jumps to the selected beacon", [rv.current_beacon != cur, rv.current_beacon], [true, n1])
	v.free()

	var rpc := RunState.new_run(77)
	close_dialogs(rpc)
	var pp := InputProfile.new(InputProfile.PC)
	pp.run = rpc
	pp.ftl_button()
	var w := StarMapView.new()
	add_child(w)
	w.setup(rpc, pp)
	var m1: int = rpc.map.links_of(rpc.current_beacon)[0]
	_motion(w, w.screen_pos(m1), false)
	check("pc map: hover selects, no JUMP, no info panel", [rpc.selected, w.jump_state(), w.info_beacon(),
		w.info_rect().size.x], [m1, "", -1, 0.0])
	check("pc map: the JUMP slot is no button", w._hit(w._jump_rect().get_center()) == "jump", false)
	w.free()

	# Sector map (touch): JUMP off until a neighbour is selected.
	var rs := RunState.new_run(77)
	close_dialogs(rs)
	var sp := InputProfile.new(InputProfile.TOUCH)
	sp.run = rs
	var sv := SectorMapView.new()
	add_child(sv)
	sv.setup(rs, sp)
	rs.choosing_sector = true
	check("sector map touch: JUMP off, no hit", [sv.jump_state(), sv._hit(sv.jump_rect().get_center())], ["off", ""])
	rs.selected_sector = int(rs.tree.neighbours(rs.sector_id)[0])
	check("  neighbour selected: JUMP lit and hit", [sv.jump_state(), sv._hit(sv.jump_rect().get_center())],
		["on", "jump"])
	check("  JUMP right of the sector box, clear of CLOSE", [sv.jump_rect().position.x >= SectorMapView.BOX.end.x,
		sv.jump_rect().intersects(SectorMapView.CLOSE_RECT)], [true, false])
	rs.choosing_sector = false
	sv.free()


## Moves the pilot-room crew out of the seat (stunned crew do not man it) or back.
func _pilot_away(r: RunState, away: bool) -> void:
	for c in r.ship.crew:
		if c.room == r.ship.sys("pilot").room:
			c.stun = 100.0 if away else 0.0


func _open_map(r: RunState) -> bool:
	var ok := r.apply(RunIntent.make(RunIntent.OPEN_MAP))
	r.apply(RunIntent.make(RunIntent.CLOSE_MAP))
	return ok


## FTL button / jump gates (rules/ftl_drive.md §4): engines and piloting must function (SystemFunctions) to open
## the star map, with or without an enemy; the charge freezes (never drains) while they are down; hazard / intruder
## beacons without an enemy charge ×3 instead of being full. Also the CommandHud FTL button states.
func _jump_gates() -> void:
	print("Jump gates")
	var r := RunState.new_run(31337)
	close_dialogs(r)
	check("safe beacon: charged, map opens", [r.ship.ftl_charge, _open_map(r)], [1.0, true])
	var hud := CommandHud.new()
	hud.ship = r.ship
	hud.run = r
	check("hud: ready", hud.ftl_state(), "ready")
	_pilot_away(r, true)
	check("no pilot, no enemy: map refused (full charge)", [r.ship.ftl_charge, _open_map(r), r.can_open_map()],
		[1.0, false, false])
	check("hud: grey JUMP (inactive), no READY", hud.ftl_state(), "inactive")
	var pc := InputProfile.new(InputProfile.PC)
	pc.run = r
	pc.ftl_button()
	check("pc FTL click refused without a pilot", r.map_open, false)
	var tp := InputProfile.new(InputProfile.TOUCH)
	tp.run = r
	tp.ftl_button()
	check("touch FTL tap refused without a pilot", r.map_open, false)
	_pilot_away(r, false)
	check("pilot back: map opens", _open_map(r), true)
	var e := r.ship.sys("engines")
	var p0 := e.power
	e.power = 0
	check("engines unpowered, no enemy: map refused", [_open_map(r), hud.ftl_state()], [false, "inactive"])
	e.power = p0
	r.ship.damage_system("engines", e.get_level())
	check("engines destroyed, no enemy: map refused", [e.effective_power(), _open_map(r), hud.engines_destroyed()],
		[0, false, true])
	r.ship.repair_system("engines", e.get_level())
	e.power = p0
	check("engines repaired + powered: map opens", _open_map(r), true)
	r.ship.damage_system("pilot", r.ship.sys("pilot").get_level())
	check("piloting destroyed (manned): map refused", [r.ship.is_manned("pilot"), _open_map(r)], [true, false])
	r.ship.repair_system("pilot", r.ship.sys("pilot").get_level())
	# Hack pulse on piloting: the indicator goes off (grey JUMP) but SystemFunctions holds (FTLButton::MouseClick
	# does not test hacking): vanilla still opens the map.
	var ps := r.ship.sys("pilot")
	ps.hack_level = 2
	ps.under_attack = true
	check("hacked piloting: indicator off, click still allowed", [hud.ftl_state(), _open_map(r)], ["inactive", true])
	ps.clear_hack()
	# A jump selected on an open map needs the systems too.
	r.apply(RunIntent.make(RunIntent.OPEN_MAP))
	var n: int = r.map.links_of(r.current_beacon)[0]
	r.apply(RunIntent.make(RunIntent.SELECT_BEACON, n))
	_pilot_away(r, true)
	check("confirm refused without a pilot", [r.apply(RunIntent.make(RunIntent.CONFIRM_JUMP)), r.current_beacon != n],
		[false, true])
	_pilot_away(r, false)
	r.apply(RunIntent.make(RunIntent.CLOSE_MAP))

	# With an enemy.
	var sb := ship_beacon(r, false)
	r.jump_to(sb)
	close_dialogs(r)
	check("enemy: hostile, charge reset", [r.has_hostile(), r.ship.ftl_charge], [true, 0.0])
	check("hud: charging", hud.ftl_state(), "charging")
	r.tick(5.0)
	var c5 := r.ship.ftl_charge
	check("enemy: charges with pilot + engines", c5 > 0.0 and c5 < 1.0, true)
	_pilot_away(r, true)
	check("hud: charging, bars off (no pilot)", hud.ftl_state(), "charging_off")
	r.tick(5.0)
	check("enemy, pilot away mid-charge: charge frozen, not drained", r.ship.ftl_charge, c5)
	_pilot_away(r, false)
	e.power = 0
	r.tick(5.0)
	check("enemy, engines unpowered mid-charge: frozen", r.ship.ftl_charge, c5)
	e.power = p0
	r.ship.ftl_charge = 1.0
	check("enemy, charged: map opens", _open_map(r), true)
	_pilot_away(r, true)
	check("enemy, charged, no pilot: refused", _open_map(r), false)
	_pilot_away(r, false)
	e.power = 0
	check("enemy, charged, engines 0: refused", _open_map(r), false)
	e.power = p0
	r.ship.fuel = 0
	check("enemy, out of fuel: button inactive, red JUMP", [r.ftl_button_active(), _open_map(r), hud.ftl_state()],
		[false, false, "no_fuel"])
	r.ship.fuel = 5
	check("enemy: in danger, SHIP button off, STORE hidden", [r.in_danger(), r.mgmt.can_open(r), hud.store_shown()],
		[true, false, false])

	# Own crew aboard the enemy ship: leaveCrewDialog first (CommandGui::LButtonDown / KeyDown).
	var es := ShipState.new(r.enemy.blueprint, false)
	r.ship.opponent = es
	var away := es.add_crew("human", true, 0)
	check("crew aboard the enemy counted", r.crew_aboard_enemy(), 1)
	check("FTL click asks first (no map yet)", [r.apply(RunIntent.make(RunIntent.OPEN_MAP)), r.leave_crew_open,
		r.map_open, r.modal()], [true, true, false, true])
	check("NO: closed, no map", [r.apply(RunIntent.make(RunIntent.LEAVE_CREW_CONFIRM, 0)), r.leave_crew_open,
		r.map_open], [true, false, false])
	r.apply(RunIntent.make(RunIntent.OPEN_MAP))
	check("YES: star map opens", [r.apply(RunIntent.make(RunIntent.LEAVE_CREW_CONFIRM, 1)), r.leave_crew_open,
		r.map_open], [true, false, true])
	r.apply(RunIntent.make(RunIntent.CLOSE_MAP))
	_pilot_away(r, true)
	check("no pilot: refused before any confirm window", [_open_map(r), r.leave_crew_open], [false, false])
	_pilot_away(r, false)
	away.hp = 0.0
	check("dead crew aboard do not ask", [r.crew_aboard_enemy(), _open_map(r), r.leave_crew_open], [0, true, false])
	r.ship.opponent = null

	# Hostile environment without an enemy: SetBoostFTL ×3, no SetSafe.
	var rh := RunState.new_run(31337)
	close_dialogs(rh)
	rh.hazard = HazardRule.create(HazardRule.Env.SUN, 2, 1, 1)
	check("sun, no enemy: hostile environment, not safe", [rh.hostile_environment(), rh.ftl_safe()], [true, false])
	check("sun, no enemy: dangerLocation -> SHIP button off", [rh.in_danger(), rh.mgmt.can_open(rh)], [true, false])
	rh.ship.ftl_charge = 0.0
	rh.tick(1.0)
	var boosted := FtlDrive.engine_speed(rh.ship, true)
	check("sun, no enemy: charges ×3 (capped at 1.2)", is_equal_approx(boosted, minf(FtlDrive.engine_speed(rh.ship)
		* 3.0, 1.2)), true)
	check("  one second of charge", is_equal_approx(rh.ship.ftl_charge, boosted * 16.0 / 85.0), true)
	_pilot_away(rh, true)
	var ch := rh.ship.ftl_charge
	rh.tick(5.0)
	check("sun, no enemy, no pilot: no charge, map refused", [rh.ship.ftl_charge, _open_map(rh)], [ch, false])
	_pilot_away(rh, false)
	rh.hazard = null
	var boarder := rh.ship.add_crew("human", false, rh.ship.sys("shields").room)
	check("intruder aboard, no enemy: hostile environment", [rh.hostile_environment(), rh.ftl_safe()], [true, false])
	rh.ship.crew.erase(boarder)
	rh.tick(0.1)
	check("safe again: full", rh.ship.ftl_charge, 1.0)
	check("safe: SHIP button usable", [rh.in_danger(), rh.mgmt.can_open(rh)], [false, true])
	hud.free()
