extends Node
## Tests for quests (rules/events.md §2.4, rules/starmap.md "Quests") and the Crystal secret sector (rules/events.md
## §2.6, rules/starmap.md "Secret sector"): AddQuest placement in the current sector (candidate rules, fleet
## distance), delayed quests forced into the next sector, the QUEST label / map_quest_loc text, removal on arrival,
## the fleet overtaking a quest beacon, quests in late sectors (no_time), the stasis pod → Ruwen → ROCK_HOME quest
## beacon → secret sector → crystal unlock path, and leaving the secret sector. Run:
##   godot --headless --path godot res://tests/test_quests.tscn

const Harness := preload("res://tests/harness.gd")
const QUEST := "MERCHANT_DELIVER"  # a plain (non-list) vanilla quest event

var fails := 0


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func close_dialogs(r: RunState) -> void:
	for i in 12:
		if r.phase == RunState.Phase.DIALOG:
			r.choose(maxi(r.dialog_choices.find_custom(func(v): return v.enabled), 0))
		elif r.phase == RunState.Phase.MESSAGE:
			r.apply(RunIntent.make(RunIntent.CONTINUE))
	r.store_open = false


func quest_beacons(r: RunState) -> Array:
	return r.map.beacons.filter(func(b): return b.quest).map(func(b): return b.id)


## An event that only gives the quest (as `<quest event=.../>` inside any vanilla event would).
func quest_event(r: RunState, q: String) -> Dictionary:
	var ev := r.engine.new_event("TEST_QUEST_GIVER")
	ev.text = "giver"
	ev.quest = q
	ev.content = true
	ev.choices = [{"text": "continue", "req": "", "lvl": 1, "max_lvl": 1 << 30, "max_group": -1, "blue": false,
		"hidden": true, "event": {}}]
	return ev


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	_placement()
	_candidates()
	_map_view()
	_fleet()
	_next_sector()
	_late_sector()
	_rock_home_and_secret()


## AddQuest in the current sector: one beacon gets the quest event + flag, text appended; arrival clears it.
func _placement() -> void:
	print("quest placement (current sector)")
	var r := RunState.new_run(101)
	close_dialogs(r)
	var ev := quest_event(r, QUEST)
	r.show_event(ev)
	var qs := quest_beacons(r)
	check("one quest beacon", qs.size(), 1)
	if qs.is_empty():
		return
	var q: int = qs[0]
	var b: Dictionary = r.map.beacon(q)
	check("  its event is the quest event", String(b.event.name), QUEST)
	check("  unvisited, not exit / nebula / overtaken / current", [b.visited, b.exit, b.nebula, b.fleet,
		q == r.current_beacon], [0, false, false, false, false])
	var n := r.map.path(r.current_beacon, q).size()
	var jl := int((b.pos.distance_to(r.fleet.center) - 767.0) / 64.0 - 1.0)
	check("  1 < path nodes < jumpsLeft", [n > 1, n < jl], [true, true])
	check("  dialog text + ' \\n\\n' + added_quest", String(r.dialog.text).ends_with(" \n\n" + FtlData.tr_id("added_quest")),
		true)
	check("  nothing delayed", r.delayed_quests.size(), 0)
	# removal on visit (GetNewLocation clears questLoc); the quest event fires
	close_dialogs(r)
	r.jump_to(q)
	check("arriving clears the quest flag", r.map.beacon(q).quest, false)
	check("  the quest event is shown", String(r.dialog.get("name", "")), QUEST)


## Candidate rules: store / distress / visited / current are skipped; the fleet distance limits non-forced picks.
func _candidates() -> void:
	print("quest candidates")
	var r := RunState.new_run(202)
	close_dialogs(r)
	var m := r.map
	var c := m.quest_candidates(r.current_beacon, r.fleet.center, false)
	var bad := c.filter(func(id): var b: Dictionary = m.beacon(id); return b.visited > 0 or b.exit or b.nebula \
		or b.event.get("store", false) or b.event.get("distress", false) or id == r.current_beacon)
	check("no candidate breaks a rule", bad, [])
	# The fleet right on top of the map: no beacon is reachable before it -> nothing unforced, everything forced.
	var near := Vector2(300, 200)
	check("fleet close: no unforced candidate", m.quest_candidates(r.current_beacon, near, false), [])
	check("fleet close: forced candidates exist", m.quest_candidates(r.current_beacon, near, true).size() > 0, true)


## Map view: QUEST label (purple) without `known`, map_quest_loc text, suppressed once overtaken.
func _map_view() -> void:
	print("quest map marker")
	var r := RunState.new_run(303)
	close_dialogs(r)
	r.show_event(quest_event(r, QUEST))
	var qs := quest_beacons(r)
	if qs.is_empty():
		check("quest placed", false, true)
		return
	var q: int = qs[0]
	var v := StarMapView.new()
	add_child(v)
	var p := InputProfile.new(InputProfile.PC)
	p.run = r
	v.setup(r, p)
	r.map.beacon(q).known = false
	check("label: map_icon_quest, purple (needs no known)", v.label_for(r.map.beacon(q), {}),
		["map_icon_quest", "purple"])
	check("label text QUEST", FtlData.tr_id("map_icon_quest"), "QUEST")
	check("tooltip: map_quest_loc", v._location_text(q, {}), FtlData.tr_id("map_quest_loc"))
	check("label hidden while the fleet's next move covers it", v.label_for(r.map.beacon(q), {q: true}), [])
	check("sector number shown", v.sector_number_text(), "1")
	v.queue_free()


## Fleet: overtaking a quest beacon replaces its event (quest lost; flag kept as in the exe, label suppressed);
## no candidate in reach while sector ≤ 5 -> delayed to the next sector with added_quest_sector.
func _fleet() -> void:
	print("fleet interaction")
	var r := RunState.new_run(404)
	close_dialogs(r)
	r.show_event(quest_event(r, QUEST))
	var qs := quest_beacons(r)
	if qs.is_empty():
		check("quest placed", false, true)
		return
	var q: int = qs[0]
	RebelFleet.overtake(r.map, q, r.engine)
	var b: Dictionary = r.map.beacon(q)
	check("overtaken quest beacon: fleet event", String(b.event.name).begins_with("FLEET_EASY"), true)
	var v := StarMapView.new()
	add_child(v)
	var p := InputProfile.new(InputProfile.PC)
	p.run = r
	v.setup(r, p)
	check("  no QUEST label", v.label_for(b, {}), [])
	check("  tooltip says fleet", v._location_text(q, {}), FtlData.tr_id("map_fleet_loc"))
	v.queue_free()
	close_dialogs(r)
	# Fleet right behind every beacon: no unforced candidate -> delayed.
	r.fleet.center = Vector2(400, 200)
	var ev := quest_event(r, QUEST)
	r.show_event(ev)
	check("no candidate in reach: delayed", Array(r.delayed_quests), [QUEST])
	check("  text added_quest_sector", String(ev.text).ends_with(FtlData.tr_id("added_quest_sector")), true)
	check("  still a single quest beacon (the overtaken one)", quest_beacons(r), [q])


## Delayed quests are forced into the next sector at its start (AddQuest force: any reachable candidate).
func _next_sector() -> void:
	print("delayed quest -> next sector")
	var r := RunState.new_run(505)
	close_dialogs(r)
	r.delayed_quests.append(QUEST)
	r.jump_to(r.map.exit)
	close_dialogs(r)
	r.enemy = {}
	r.ship.ftl_charge = 1.0
	r.ship.fuel = 5
	r.apply(RunIntent.make(RunIntent.OPEN_MAP))
	r.apply(RunIntent.make(RunIntent.NEXT_SECTOR))
	r.go_to_sector(int(r.tree.neighbours(r.sector_id)[0]))
	check("sector 2", r.sector, 1)
	var qs := quest_beacons(r)
	check("delayed quest placed at the sector start", qs.size(), 1)
	check("  delayed list emptied", r.delayed_quests.size(), 0)
	if not qs.is_empty():
		var b: Dictionary = r.map.beacon(qs[0])
		check("  event + not the start beacon", [String(b.event.name), qs[0] != r.map.start], [QUEST, true])


## Sector > 5 (worldLevel 6, 7): no candidate -> the quest is dropped with no_time.
func _late_sector() -> void:
	print("late sector: no_time")
	var r := RunState.new_run(606)
	close_dialogs(r)
	r.enter_sector(6, "REBEL_SECTOR")
	close_dialogs(r)
	r.fleet.center = Vector2(400, 200)
	var ev := quest_event(r, QUEST)
	r.show_event(ev)
	check("dropped, not delayed", [quest_beacons(r), r.delayed_quests.size()], [[], 0])
	check("  text no_time", String(ev.text).ends_with(FtlData.tr_id("no_time")), true)


## Stasis pod -> Ruwen (flag) -> ROCK_HOME crystal beacon flagged quest -> reactivate -> secret sector at the same
## level ("?" on the map) -> START_BEACON_CRYSTAL gives the CRYSTAL_UNLOCK quest -> NEXT SECTOR = random sector of
## the next level, no choice.
func _rock_home_and_secret() -> void:
	print("stasis pod / Ruwen / rock home / secret sector")
	var r := RunState.new_run(707)
	close_dialogs(r)
	r.give_item("augment", "STASIS_POD")
	check("stasis pod carried", r.equipment_level("STASIS_POD"), 1)
	var zs := r.engine.base_event("ZOLTAN_CREW_STUDY")
	r.show_event(zs)
	var pod := r.dialog_choices.find_custom(func(v): return v.enabled and v.event.get("remove", "") == "STASIS_POD")
	check("stasis pod choice offered", pod >= 0, true)
	r.choose(pod)
	check("  pod still carried while the outcome box is open", r.equipment_level("STASIS_POD"), 1)
	check("  its reward box lists the removal", r.dialog_rewards.has(["removed", "STASIS_POD"]), true)
	r.choose(0)
	check("  pod removed on Continue", r.equipment_level("STASIS_POD"), 0)
	for i in 3:
		if r.phase == RunState.Phase.DIALOG and not r.ruwen_flag:
			r.choose(0)
	check("Ruwen joined: crystal crew + ruwen flag", [r.equipment_level("crystal") > 0, r.ruwen_flag], [true, true])
	check("crystalAlienFound", r.crystal_alien_found(), true)
	close_dialogs(r)
	# ROCK_HOME (sector 5, worldLevel 4)
	r.enter_sector(4, "ROCK_HOME")
	var rb := -1
	for b in r.map.beacons:
		if String(b.event.get("name", "")) == "ROCK_CRYSTAL_BEACON":
			rb = b.id
	check("ROCK_HOME has the crystal beacon", rb >= 0, true)
	if rb < 0:
		return
	check("  flagged as a quest (QUEST label)", r.map.beacon(rb).quest, true)
	# without the flag it is not marked
	var r2 := RunState.new_run(707)
	r2.ship.add_crew("crystal", true)
	r2.enter_sector(4, "ROCK_HOME")
	var marked := r2.map.beacons.filter(func(b): return b.quest).size()
	check("crystal crew without Ruwen: no quest mark", marked, 0)
	# reactivate -> secret sector
	close_dialogs(r)
	r.jump_to(rb)
	check("arrival clears the mark", r.map.beacon(rb).quest, false)
	var reac := r.dialog_choices.find_custom(func(v): return v.enabled and v.event.get("res", {}).get("fuel", 0) == 1 \
		and not v.event.choices.is_empty())
	check("crystal choice offered", reac >= 0, true)
	if reac < 0:
		return
	var lvl := r.sector
	var rock_id := r.sector_id
	r.ship.fuel = 3
	r.choose(reac)
	check("  +1 fuel listed, applied on Continue", [r.dialog_rewards.has(["fuel", 1]), r.ship.fuel], [true, 3])
	r.choose(0)  # Continue: +1 fuel (ModifyResources) -> <secretSector/>
	check("secret sector entered", [r.secret_sector, r.sector_desc, r.sector, r.sector_id], [true, "CRYSTAL_HOME", lvl,
		rock_id])
	check("  fuel -1 for the jump", r.ship.fuel, 3)
	check("  sector name", r.sector_name, FtlData.tr_id("sectorname_CRYSTAL_HOME"))
	check("  start event START_BEACON_CRYSTAL", String(r.dialog.get("name", "")), "START_BEACON_CRYSTAL")
	var v := StarMapView.new()
	add_child(v)
	var p := InputProfile.new(InputProfile.PC)
	p.run = r
	v.setup(r, p)
	check("  map sector number '?'", v.sector_number_text(), "?")
	v.queue_free()
	r.choose(0)  # continue -> the CRYSTAL_UNLOCK quest
	var qs := quest_beacons(r)
	var placed := qs.size() == 1 or r.delayed_quests.has("CRYSTAL_UNLOCK")
	check("CRYSTAL_UNLOCK quest placed (or delayed)", placed, true)
	if qs.size() == 1:
		close_dialogs(r)
		r.jump_to(qs[0])
		check("  CRYSTAL_UNLOCK: unlock ship 8 recorded when the box opens", r.unlocked_ships.has(8), true)
		check("  CRYSTAL_SHARDS augment pending in the box", [r.ship.has_augment("CRYSTAL_SHARDS"),
			r.dialog_rewards.has(["augment", "CRYSTAL_SHARDS"])], [false, true])
		r.choose(0)
		check("  CRYSTAL_SHARDS augment", r.ship.has_augment("CRYSTAL_SHARDS"), true)
	# leave: NEXT SECTOR at the exit -> random sector of level + 1, no sector choice
	close_dialogs(r)
	r.jump_to(r.map.exit)
	close_dialogs(r)
	r.enemy = {}
	r.ship.ftl_charge = 1.0
	r.ship.fuel = 5
	r.apply(RunIntent.make(RunIntent.OPEN_MAP))
	check("NEXT SECTOR from the secret sector", r.apply(RunIntent.make(RunIntent.NEXT_SECTOR)), true)
	check("  no sector choice, next level, secret cleared", [r.choosing_sector, r.sector, r.secret_sector],
		[false, lvl + 1, false])
	check("  in a tree sector of that level", int(r.tree.sectors[r.sector_id].level), lvl + 1)
	check("  fuel -1", r.ship.fuel, 4)
