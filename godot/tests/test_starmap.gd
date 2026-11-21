extends Node
## Tests for rules/starmap.md §2 (beacon map generation: grid, links, connectivity, start/exit, events,
## nebulas, determinism by seed). Uses the user's FTL data (sector_data.xml, events). Run:
##   godot --headless --path godot res://tests/test_starmap.tscn

const Harness := preload("res://tests/harness.gd")

var fails := 0


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	var db := EventDB.shared()
	check("sector descriptions loaded", db.sectors.has("STANDARD_SPACE") and db.sectors.has("CIVILIAN_SECTOR"), true)
	var tun := RunTuning.section("map")
	var link := float(tun.link_distance)
	for desc_name in ["STANDARD_SPACE", "CIVILIAN_SECTOR", "NEBULA_SECTOR", "REBEL_SECTOR"]:
		var desc: XmlNode = db.sectors.get(desc_name)
		var bad := {}
		var counts := []
		var nebulas := 0
		for s in range(1, 41):
			var eng := EventEngine.new(db)
			var m := StarMap.generate(s * 7919, desc, eng)
			counts.append(m.beacons.size())
			if not m.all_connected():
				bad["connected"] = s
			var nodes := m.path(m.start, m.exit).size()
			if nodes < 5:
				bad["exit >= 4 jumps"] = s
			if m.beacons[m.start].cell.x != 0 and m.start != 0:
				bad["start column 0"] = s
			if m.beacons[m.exit].cell.x < 4 or not m.beacons[m.exit].exit:
				bad["exit columns 4-5"] = s
			var cells := {}
			for b in m.beacons:
				if cells.has(b.cell):
					bad["one beacon per cell"] = s
				cells[b.cell] = true
				if b.event.is_empty():
					bad["every beacon has an event"] = s
				var local: Vector2 = b.pos - Vector2(b.cell) * 110.0
				if local.x < 10 or local.x > 99 or local.y < 10 or (local.y > 99 and b.pos.y != 415):
					bad["position inside its cell margin"] = s
				if b.pos.y > 415:
					bad["y clamp 415"] = s
				if b.cell.x >= 4 and b.cell.y == 0 and b.pos.y < 30:
					bad["top-right y >= 30"] = s
				for n in b.links:
					var o: Dictionary = m.beacons[n]
					if not b.id in o.links:
						bad["links symmetric"] = s
					if b.pos.distance_to(o.pos) > link + 0.001:
						bad["link <= 165 px"] = s
					if absi(o.cell.x - b.cell.x) > 1 or absi(o.cell.y - b.cell.y) > 1:
						bad["links to neighbouring cells only"] = s
				if b.nebula:
					nebulas += 1
					if b.env != 3:
						bad["nebula env 3"] = s
			var st: Dictionary = m.beacons[m.start]
			if st.visited != 1 or not st.known or not st.links.all(func(n): return m.beacons[n].known):
				bad["start visited, neighbours known"] = s
			if m.beacons[m.exit].event.is_empty():
				bad["exit has an event"] = s
		check("%s: invariants over 40 seeds (failures)" % desc_name, bad, {})
		var mn: int = counts.min()
		var mx: int = counts.max()
		check("%s: beacon count in [14, 24] (%d..%d)" % [desc_name, mn, mx], mn >= 14 and mx <= 24, true)
		if desc_name == "NEBULA_SECTOR":
			check("NEBULA_SECTOR has nebula beacons (%d)" % nebulas, nebulas > 0, true)

	# Determinism by seed, and different seeds differ.
	var desc2: XmlNode = db.sectors["STANDARD_SPACE"]
	var a := StarMap.generate(12345, desc2, EventEngine.new(db))
	var b2 := StarMap.generate(12345, desc2, EventEngine.new(db))
	var c := StarMap.generate(54321, desc2, EventEngine.new(db))
	check("same seed -> same map", _sig(a), _sig(b2))
	check("different seed -> different map", _sig(a) != _sig(c), true)

	# Event placement: STORE (min 1) present in STANDARD_SPACE maps; FINISH_BEACON at the exit.
	var stores := 0
	for b in a.beacons:
		if b.event.get("store", false):
			stores += 1
	check("STANDARD_SPACE has a store beacon (%d)" % stores, stores >= 1, true)
	check("exit event FINISH_BEACON", String(a.beacons[a.exit].event.name).begins_with("FINISH_BEACON"), true)

	# First sector of a run: START_GAME at the start.
	var r := RunState.new_run(99)
	check("new run start event", r.dialog.get("name", ""), "START_GAME")
	check("new run sector name", r.sector_name, FtlData.tr_id("sectorname_CIVILIAN_SECTOR"))

	_rendering_rules(a)



## rules/starmap.md "Map rendering": which connections are drawn, beacon icons with scanners, ship marker orbit.
func _rendering_rules(m: StarMap) -> void:
	print("Map rendering rules")
	var cur := m.start
	var links: Array = m.links_of(cur)
	var edges := func(h: int, sp := true) -> Array:
		return m.visible_connections(cur, h, sp).map(func(e): return [e[0], e[1], e[2]])
	var idle: Array = edges.call(-1)
	check("idle: only the current beacon's links, green, from current",
		idle == links.map(func(n): return [cur, n, StarMap.LINK_CURRENT]), true)
	check("hovering the current beacon adds nothing", edges.call(cur) == idle, true)
	var adj: int = links[0]
	var ha: Array = edges.call(adj)
	var want := []
	for n in m.links_of(adj):
		if n != cur:
			want.append([adj, n, StarMap.LINK_HOVER])
	check("hover adjacent: its links (minus the one back to current) in yellow, drawn before the green ones",
		ha == want + idle, true)
	check("  the edge back to the current beacon stays green only",
		ha.filter(func(e): return e[2] == StarMap.LINK_HOVER and (e[1] == cur or e[0] == cur)).size(), 0)
	var far := -1
	var best := 0
	for b in m.beacons:
		var n := m.path(cur, b.id).size()
		if n > best:
			best = n
			far = b.id
	var hf: Array = edges.call(far)
	check("hover far beacon (%d jumps): all its links in yellow" % (best - 1),
		hf.slice(0, m.links_of(far).size()) == m.links_of(far).map(func(n): return [far, n, StarMap.LINK_HOVER]), true)
	check("  no edge between two other beacons in green",
		hf.filter(func(e): return e[2] == StarMap.LINK_CURRENT and e[0] != cur).size(), 0)
	check("showpaths off: hover adds nothing", edges.call(far, false) == idle, true)

	# Icons: a known unvisited ship beacon is a yellow triangle only with ADV_SCANNERS (or a revealed map).
	var sb := -1
	for b in m.beacons:
		if b.visited == 0 and not b.event.get("ship", {}).is_empty():
			sb = b.id
			break
	if sb >= 0:
		m.beacons[sb].known = true
		check("ship beacon without scanners: yellow diamond", m.beacon_icon(sb, false)[1], "map_icon_diamond_yellow.png")
		check("ship beacon with scanners: yellow triangle", m.beacon_icon(sb, true)[1], "map_icon_triangle_yellow.png")
		m.beacons[sb].known = false
		check("unknown ship beacon with scanners: diamond", m.beacon_icon(sb, true)[1], "map_icon_diamond_yellow.png")
		m.revealed = true
		check("revealed map: triangle without scanners", m.beacon_icon(sb, false)[1], "map_icon_triangle_yellow.png")
		m.revealed = false
	check("current (visited) beacon: blue diamond", m.beacon_icon(cur, false)[1], "map_icon_diamond_blue.png")
	m.beacons[cur]["ship_left"] = true
	check("visited with a hostile left alive: red triangle", m.beacon_icon(cur, false)[1], "map_icon_triangle_red.png")
	m.beacons[cur].fleet = true
	check("overtaken: warning icon", m.beacon_icon(cur, false)[1], "map_icon_warning.png")
	m.beacons[cur].fleet = false
	m.beacons[cur]["ship_left"] = false

	# Ship marker: radius 22, 18 deg/s decreasing (counter-clockwise on screen), 20 s per lap, frozen out of fuel.
	check("marker at angle 360 sits 22 px right", StarMap.marker_offset(360.0).is_equal_approx(Vector2(22, 0)), true)
	check("marker radius 22 at any angle", is_equal_approx(StarMap.marker_offset(137.0).length(), 22.0), true)
	var a1 := StarMap.marker_step(360.0, 5.0, false)
	check("5 s -> 90 deg less", is_equal_approx(a1, 270.0), true)
	check("angle 270 = above the beacon (counter-clockwise from the right)",
		StarMap.marker_offset(a1).is_equal_approx(Vector2(0, -22)), true)
	var ang := 360.0
	var steps := 0
	while steps < 10000:
		ang = StarMap.marker_step(ang, 0.01, false)
		steps += 1
		if ang == 360.0:
			break
	check("one lap ~ 20 s (%.2f s)" % (steps * 0.01), absf(steps * 0.01 - 20.0) < 0.02, true)
	check("frozen while out of fuel", StarMap.marker_step(123.0, 3.0, true), 123.0)
	# Nose-first: the heading is the direction of motion (offset after a small step - before).
	var d := StarMap.marker_offset(StarMap.marker_step(200.0, 0.05, false)) - StarMap.marker_offset(200.0)
	check("nose points along the motion", StarMap.marker_heading(200.0).dot(d.normalized()) > 0.99, true)


func _sig(m: StarMap) -> String:
	var parts := []
	for b in m.beacons:
		parts.append("%d,%d:%s:%s" % [int(b.pos.x), int(b.pos.y), str(b.links), String(b.event.get("name", ""))])
	return "%d/%d|%s" % [m.start, m.exit, ";".join(parts)]
