extends Node
## Tests for rules/starmap.md §1 (sector tree), §4 (rebel fleet) and §5 (out of fuel: wait / distress), the sector
## transition (NEXT SECTOR → sector map → new beacon map) and the entry into the Last Stand. Run:
##   godot --headless --path godot res://tests/test_sectors.tscn

const Harness := preload("res://tests/harness.gd")

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


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	var db := EventDB.shared()
	# --- sector tree
	var bad := {}
	var hostile := 0
	var nebula := 0
	var total := 0
	for s in range(1, 81):
		var t := SectorTree.generate(s * 31, db, true)
		if t.columns.size() != 8:
			bad["8 columns"] = s
		if t.columns[0].size() != 1 or t.columns[1].size() != 2 or t.columns[7].size() != 1:
			bad["1 / 2 / ... / 1 sectors"] = s
		for c in range(1, 7):
			var n: int = t.columns[c].size()
			if n < 2 or n > 4:
				bad["2..4 per column"] = s
			if c > 1 and n == t.columns[c - 1].size():
				bad["count differs from previous column"] = s
		if t.sectors[t.final_id()].desc != "FINAL":
			bad["final = FINAL"] = s
		var used := {}
		for sec in t.sectors:
			var d: XmlNode = db.sectors.get(sec.desc)
			if d == null:
				bad["description exists"] = s
				continue
			if int(d.attr("minSector", "0")) > int(sec.level):
				bad["minSector respected"] = s
			if d.attr("unique") == "true":
				if used.has(sec.desc):
					bad["unique sectors once"] = s
				used[sec.desc] = true
			if sec.level < 7 and sec.links.is_empty():
				bad["every sector links forward"] = s
			for l in sec.links:
				if t.sectors[l].level != sec.level + 1:
					bad["links go to the next column"] = s
			if sec.level >= 1 and sec.level <= 6:
				total += 1
				if sec.cls == "HOSTILE":
					hostile += 1
				elif sec.cls == "NEBULA":
					nebula += 1
		# no crossing: links of consecutive sectors in a column are ordered
		for c in range(0, 7):
			var maxlink := -1
			for id in t.columns[c]:
				var ls: Array = t.sectors[id].links.duplicate()
				ls.sort()
				if not ls.is_empty() and ls[0] < maxlink:
					bad["links never cross"] = s
				if not ls.is_empty():
					maxlink = ls[-1]
		for c in range(1, 8):
			for id in t.columns[c]:
				var has_in := false
				for p in t.columns[c - 1]:
					if id in t.sectors[p].links:
						has_in = true
				if not has_in:
					bad["every sector reachable"] = s
	check("sector tree invariants over 80 seeds", bad, {})
	var hf := float(hostile) / total
	var nf := float(nebula) / total
	check("class odds ≈ 40 %% hostile (%.2f), 20 %% nebula (%.2f)" % [hf, nf], hf > 0.33 and hf < 0.47
		and nf > 0.14 and nf < 0.26, true)
	check("same seed → same tree", SectorTree.generate(5, db).sectors.map(func(x): return x.desc),
		SectorTree.generate(5, db).sectors.map(func(x): return x.desc))

	# --- rebel fleet
	var rng := RandomNumberGenerator.new()
	rng.seed = 4
	var f := RebelFleet.start(rng)
	check("fleet starts at x -959, y in [50, 300)", [f.center.x, f.center.y >= 50 and f.center.y < 300], [-959.0, true])
	check("normal move 64", f.advance(false, false), 64)
	check("nebula beacon in a nebula sector 51, elsewhere 32", [f.advance(true, true), f.advance(true, false)], [51, 32])
	f.pursuit_delay = 2
	check("pursuit delay > 0 doubles and decays", [f.advance(false, false), f.pursuit_delay], [128, 1])
	f.pursuit_delay = -1
	check("pursuit delay < 0 stops one move", [f.advance(false, false), f.pursuit_delay], [0, 0])
	f.center.x = 50
	f.advance(false, false)
	check("centre capped at x 60", [f.center.x, f.advance(false, false)], [60.0, 0])

	var r := RunState.new_run(42)
	close_dialogs(r)
	var x0 := r.fleet.center.x
	var nb: int = r.map.links_of(r.current_beacon)[0]
	var was_nebula: bool = r.beacon().nebula
	r.jump_to(nb)
	check("a jump advances the fleet", r.fleet.center.x - x0, 32.0 if was_nebula else 64.0)
	# Overtake by moving the zone over the map.
	r.fleet.center.x = 0
	for bid in r.fleet.newly_covered(r.map):
		RebelFleet.overtake(r.map, bid, r.engine)
	var over := r.map.beacons.filter(func(b): return b.fleet)
	check("beacons inside the zone are overtaken (%d)" % over.size(), over.size() > 0 and over.all(
		func(b): return r.fleet.covers(b.pos)), true)
	check("overtaken beacons get FLEET events", over.all(func(b): return String(b.event.get("name", "")).begins_with(
		"FLEET_EASY")), true)
	var ex: Dictionary = r.map.beacons[r.map.exit]
	r.fleet.center.x = 60
	for bid in r.fleet.newly_covered(r.map):
		RebelFleet.overtake(r.map, bid, r.engine)
	check("exit overtaken → FLEET_EASY_BEACON(_DLC), still the exit", [String(ex.event.get("name", "")).begins_with(
		"FLEET_EASY_BEACON"), ex.exit], [true, true])

	# --- out of fuel: wait / distress
	var rw := RunState.new_run(43)
	close_dialogs(rw)
	rw.ship.fuel = 0
	check("no fuel: cannot jump", rw.can_target(rw.map.links_of(rw.current_beacon)[0]), false)
	check("no fuel: wait allowed", rw.can_wait(), true)
	var wx := rw.fleet.center.x
	check("wait", rw.apply(RunIntent.make(RunIntent.WAIT)), true)
	check("wait advances the fleet", rw.fleet.center.x > wx, true)
	check("wait sets the NO_FUEL event", rw.log[-1].begins_with("event") and rw.log.any(func(l): return l.begins_with("wait (fuel 0): NO_FUEL")), true)
	close_dialogs(rw)
	if rw.ship.fuel == 0 and rw.can_wait():
		rw.apply(RunIntent.make(RunIntent.TOGGLE_DISTRESS))
		check("distress on", rw.distress, true)
		rw.apply(RunIntent.make(RunIntent.WAIT))
		check("distress wait uses NO_FUEL_DISTRESS (or the fleet one)", rw.log.any(func(l): return l.begins_with("wait (fuel 0): NO_FUEL_DISTRESS") or l.begins_with("wait (fuel 0): NO_FUEL_FLEET")), true)

	# --- sector transition
	var rs := RunState.new_run(44)
	close_dialogs(rs)
	rs.jump_to(rs.map.exit)
	close_dialogs(rs)
	rs.enemy = {}
	rs.ship.ftl_charge = 1.0
	rs.apply(RunIntent.make(RunIntent.OPEN_MAP))
	check("NEXT SECTOR opens the sector map", [rs.apply(RunIntent.make(RunIntent.NEXT_SECTOR)), rs.choosing_sector],
		[true, true])
	var nbs: Array = rs.tree.neighbours(rs.sector_id)
	var far: int = rs.tree.columns[3][0]
	check("non-neighbour sector refused", rs.apply(RunIntent.make(RunIntent.SELECT_SECTOR, far)), false)
	var touch := InputProfile.new(InputProfile.TOUCH)
	touch.run = rs
	touch.sector_click(nbs[0])
	check("touch: tap selects the sector, no jump yet", [rs.selected_sector, rs.sector], [nbs[0], 0])
	var map0 := rs.map
	var fuel0 := rs.ship.fuel
	touch.sector_jump_button()
	check("JUMP enters sector 2 with a new map", [rs.sector, rs.sector_id, rs.map != map0, rs.choosing_sector,
		rs.ship.fuel], [1, nbs[0], true, false, fuel0 - 1])
	check("new sector's description", rs.sector_desc, rs.tree.sectors[nbs[0]].desc)
	check("new fleet at the left edge", rs.fleet.center.x, -959.0)
	var pc := InputProfile.new(InputProfile.PC)
	pc.run = rs
	# walk to the last sector through the tree
	for step in 6:
		close_dialogs(rs)
		rs.enemy = {}
		rs.choosing_sector = true
		pc.sector_key(0)
	check("last sector reached → the Last Stand (rules/flagship.md)", [rs.over, rs.is_last_sector(),
		LastStand.active(rs), rs.sector_desc], ["", true, true, "FINAL"])
	rs.end_run("victory")
	check("run end blocks intents", rs.apply(RunIntent.make(RunIntent.OPEN_MAP)), false)

	# --- game over
	var rg := RunState.new_run(45)
	rg.game_over("gameover_crew")
	check("game over", [rg.over, rg.modal()], ["gameover", true])

