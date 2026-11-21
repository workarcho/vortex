class_name StarMap
extends RefCounted
## One sector's beacon map (rules/starmap.md §2, §3) and its generation (StarMap::GenerateMap /
## PopulateGrid / GenerateEvents / GenerateNebulas). Pure function of the sector seed + description + flags:
## the whole map and every event are created at once from one RNG stream (`engine.rng`, reseeded here).
##
## Beacon = {id, pos: Vector2 (map coords, grid origin at 0,0), cell: Vector2i, links: Array[int], event: {},
##   visited: int, known: bool, nebula: bool, exit: bool, env: int, fleet: bool (overtaken by the rebels),
##   shop: RunStore or null (generated on the first visit), event_fresh: bool (new event on a visited beacon),
##   ship_left: bool (set when the player left it with a hostile event ship still alive),
##   quest: bool (questLoc: QUEST label + map_quest_loc text; cleared on arrival)}

## Map rendering rules (rules/starmap.md "Map rendering"; StarMap::OnRender / DrawConnection) [exe].
const LINK_CURRENT := "current"  # green (120, 255, 120)
const LINK_HOVER := "hover"  # COLOR_YELLOW (255, 255, 50)
const MARKER_RADIUS := 22.0  # ship sprite centre: primitive (-10, -32, 64, 64) -> (22, 0) in the beacon frame
const MARKER_DEG_PER_S := 18.0  # 1.125 deg per speed-factor unit (x16 per s) -> 20 s per lap, counter-clockwise

var beacons: Array = []
var start := -1
var exit := -1
var clouds: Array = []  # [{img, rect: Rect2}] nebula clouds (map coords)
var seed := 0
var regenerations := 0  # whole-grid regenerations (disconnected graph / no valid exit)
var desc_name := ""
var revealed := false  # bMapRevealed (a reveal_map event): ships / hazards shown on every beacon


func beacon(id: int) -> Dictionary:
	return beacons[id]


## Connections drawn on the beacon map, in draw order, as [from, to, LINK_*] (`from` = the alpha-1.0 end):
## hover (`hover` != current, `show_paths` on) -> all the hovered beacon's links except the one back to the current
## beacon; then always the current beacon's own links. Edges between other beacons are never drawn.
func visible_connections(current: int, hover: int, show_paths := true) -> Array:
	var out := []
	if show_paths and hover >= 0 and hover != current:
		for n in links_of(hover):
			if n != current:
				out.append([hover, n, LINK_HOVER])
	for n in links_of(current):
		out.append([current, n, LINK_CURRENT])
	return out


## Ships / hazards of a beacon are visible: map revealed, or known (neighbour of a visited beacon) with ADV_SCANNERS.
func intel_visible(id: int, scanners: bool) -> bool:
	return revealed or (scanners and bool(beacons[id].known))


## [shadow, icon] image names (img/map/...) of a beacon (first match): overtaken -> warning; visited with a hostile
## ship left alive -> red triangle; visited -> blue diamond; unvisited with a ship and intel -> yellow triangle;
## else the yellow diamond. Exit / store / distress / quest have no icon of their own (labels only).
func beacon_icon(id: int, scanners: bool) -> Array:
	var b: Dictionary = beacons[id]
	if b.fleet:
		return ["map_icon_diamond_shadow.png", "map_icon_warning.png"]
	if b.visited > 0:
		if b.get("ship_left", false):
			return ["map_icon_triangle_shadow.png", "map_icon_triangle_red.png"]
		return ["map_icon_diamond_shadow.png", "map_icon_diamond_blue.png"]
	if not b.event.get("ship", {}).is_empty() and intel_visible(id, scanners):
		return ["map_icon_triangle_shadow.png", "map_icon_triangle_yellow.png"]
	return ["map_icon_diamond_shadow.png", "map_icon_diamond_yellow.png"]


## Ship marker orbit angle (degrees, shipRotation[0]) after `dt` s: decreases 18 deg/s (counter-clockwise on screen),
## wraps to 360 once <= 0; frozen while out of fuel.
static func marker_step(angle: float, dt: float, out_of_fuel: bool) -> float:
	if out_of_fuel:
		return angle
	var a := angle - MARKER_DEG_PER_S * dt
	return 360.0 if a <= 0.0 else a


## Marker sprite centre relative to the beacon (radius 22, rotated by `angle` degrees, y down).
static func marker_offset(angle: float) -> Vector2:
	return Vector2(MARKER_RADIUS, 0).rotated(deg_to_rad(angle))


## Direction the nose points (the image's -y rotated by `angle`): tangent to the orbit, along the motion.
static func marker_heading(angle: float) -> Vector2:
	return Vector2(0, -1).rotated(deg_to_rad(angle))


func links_of(id: int) -> Array:
	return beacons[id].links if id >= 0 and id < beacons.size() else []


func connected(a: int, b: int) -> bool:
	return b in links_of(a)


## Path a -> b as a node list including both ends (unweighted Dijkstra = BFS) or [] if unreachable.
func path(a: int, b: int) -> Array:
	if a == b:
		return [a]
	var prev := {a: -1}
	var queue := [a]
	while not queue.is_empty():
		var cur: int = queue.pop_front()
		for n in beacons[cur].links:
			if prev.has(n):
				continue
			prev[n] = cur
			if n == b:
				var out := [b]
				var p: int = cur
				while p != -1:
					out.push_front(p)
					p = prev[p]
				return out
			queue.append(n)
	return []


func all_connected() -> bool:
	if beacons.is_empty():
		return false
	var seen := {0: true}
	var queue := [0]
	while not queue.is_empty():
		var cur: int = queue.pop_front()
		for n in beacons[cur].links:
			if not seen.has(n):
				seen[n] = true
				queue.append(n)
	return seen.size() == beacons.size()


func beacon_at_cell(c: Vector2i) -> int:
	for b in beacons:
		if b.cell == c:
			return b.id
	return -1


# ------------------------------------------------------------------ quests (rules/events.md §2.4)

const QUEST_NO_EVENT := -2  # AddQuest: GetBaseEvent returned nothing (nothing placed, nothing delayed)
const QUEST_NONE := -1  # AddQuest: no candidate beacon (the caller delays it or drops it)


## Quest candidates (StarMap::AddQuest): unvisited, not nebula, not the exit, not overtaken, not already a quest,
## the event neither a store nor a distress beacon, not `current`; then with n = Dijkstra(current, loc) node count
## (both ends) and jumpsLeft = int((|loc − fleetCentre| − 767) / 64 − 1): 1 < n < jumpsLeft (reachable before the
## fleet), or, when `force` (delayed quests at the next sector's start), any n ≠ 0 (reachable).
func quest_candidates(current: int, fleet_center: Vector2, force: bool) -> Array:
	var t := RunTuning.section("quests")
	var out := []
	for b in beacons:
		if b.visited != 0 or b.nebula or b.exit or b.fleet or b.get("quest", false) or b.id == current:
			continue
		var ev: Dictionary = b.event
		if ev.get("store", false) or ev.get("distress", false):
			continue
		var d: float = (b.pos as Vector2).distance_to(fleet_center)
		var jumps_left := int((d - float(t.get("danger_radius", 767))) / float(t.get("jump_len", 64)) - 1.0)
		var n := path(current, b.id).size()
		if (n > 1 and n < jumps_left) or (n != 0 and force):
			out.append(b.id)
	return out


## StarMap::AddQuest(name, force): the quest event is created first (GetBaseEvent on the sector stream), then a
## uniform pick among `quest_candidates` gets it as its event and `quest = true`. Returns the beacon id, or
## QUEST_NONE (no candidate) / QUEST_NO_EVENT. Delaying to the next sector is the caller's (RunState) job.
func add_quest(engine: EventEngine, name: String, current: int, fleet_center: Vector2, force: bool) -> int:
	var ev := engine.base_event(name)
	if ev.is_empty():
		return QUEST_NO_EVENT
	var cands := quest_candidates(current, fleet_center, force)
	if cands.is_empty():
		return QUEST_NONE
	var id: int = cands[engine.r(cands.size())]
	beacons[id].event = ev
	beacons[id].quest = true
	return id


## GenerateMap, ROCK_HOME with crystalAlienFound: the first beacon whose event is ROCK_CRYSTAL_BEACON is flagged as
## a quest (its event stays). Returns the beacon id or -1.
func mark_event_quest(event_name: String) -> int:
	for b in beacons:
		if String(b.event.get("name", "")) == event_name:
			b.quest = true
			return b.id
	return -1


# ------------------------------------------------------------------ generation

## GenerateMap: grid (regenerated until connected and a valid exit exists), start / exit events, sector events
## and nebulas, then the start beacon is visited and known with its neighbours.
## `desc`: the <sectorDescription>; `start_event` overrides the start beacon's event (START_GAME on the first
## sector of a run).
static func generate(sector_seed: int, desc: XmlNode, engine: EventEngine, start_event := "") -> StarMap:
	var m := StarMap.new()
	m.seed = sector_seed
	m.desc_name = desc.attr("name") if desc else ""
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
	for guard in 200:
		m._populate_grid(engine, tun)
		if not m.all_connected():
			m.regenerations += 1
			continue
		if m._place_start_exit(engine, tun):
			break
		m.regenerations += 1
	# Events (rules/events.md §2.1, §2.2)
	var first := desc.child("startEvent").text if desc and desc.child("startEvent") else ""
	if first == "":
		first = RunTuning.name_of("start_beacon")
	m.beacons[m.start].event = engine.base_event(first)
	m.beacons[m.exit].event = engine.base_event(RunTuning.name_of("finish"))
	m._generate_events(desc, engine, tun)
	if start_event != "":
		m.beacons[m.start].event = engine.base_event(start_event)  # StarMap::NewGame (after GenerateMap)
		# StarMap::NewGame appends " \n \n" + a random tip (GetTextFromList("TIPS_LIST_PC"); the profile's very
		# first run uses `first_run_tip_pc` instead, not tracked here). Own stream so the sector RNG is untouched.
		var tip := start_tip(engine, sector_seed)
		var sev: Dictionary = m.beacons[m.start].event
		if tip != "" and sev.has("text"):
			sev.text = String(sev.text) + " \n \n" + tip
	var s: Dictionary = m.beacons[m.start]
	s.visited += 1
	s.known = true
	for n in s.links:
		m.beacons[n].known = true
	return m


## PopulateGrid: 6×4 cells x-major; 1/5 empty roll, kept empty only while processed/emptyRolls > 4; random
## point in the cell (10 px margin); links to beacons of the 3×3 neighbouring cells within 165 px.
func _populate_grid(engine: EventEngine, tun: Dictionary) -> void:
	beacons.clear()
	var gw := int(tun.grid_w)
	var gh := int(tun.grid_h)
	var cell := int(tun.cell)
	var margin := int(tun.margin)
	var spread := int(tun.spread)
	var processed := 0
	var empty_rolls := 0
	var link := float(tun.link_distance)
	for gx in gw:
		for gy in gh:
			var skip := false
			if engine.r(int(tun.empty_roll)) == 0:
				empty_rolls += 1
				skip = processed / empty_rolls > int(tun.empty_ratio)
			processed += 1
			if skip:
				continue
			var x := gx * cell + margin + engine.r(spread)
			var y := gy * cell + margin + engine.r(spread)
			y = mini(y, int(tun.y_max))
			if gx >= int(tun.top_right_from_col) and gy == 0:
				y = maxi(y, int(tun.top_right_y_min))
			var b := {"id": beacons.size(), "pos": Vector2(x, y), "cell": Vector2i(gx, gy), "links": [], "event": {},
				"visited": 0, "known": false, "nebula": false, "exit": false, "env": -1, "fleet": false,
				"shop": null, "event_fresh": false, "quest": false}
			for o in beacons:
				if absi(o.cell.x - gx) <= 1 and absi(o.cell.y - gy) <= 1 and o.pos.distance_to(b.pos) <= link:
					o.links.append(b.id)
					b.links.append(o.id)
			beacons.append(b)


## Start: cell (0, rand%4), first beacon if empty. Exit: cell (4 + rand%2, rand%4), redrawn while empty;
## accepted when the start→exit path has 4 < nodes < 100 (≥ 4 jumps); 16 rejections -> false (regenerate).
func _place_start_exit(engine: EventEngine, tun: Dictionary) -> bool:
	start = beacon_at_cell(Vector2i(0, engine.r(int(tun.grid_h))))
	if start < 0:
		start = 0
	var ec: Array = tun.exit_cols
	for attempt in int(tun.exit_tries):
		var e := -1
		for redraw in 200:
			e = beacon_at_cell(Vector2i(int(ec[0]) + engine.r(int(ec[1])), engine.r(int(tun.grid_h))))
			if e >= 0:
				break
		if e < 0:
			return false
		var nodes := path(start, e).size()
		if nodes >= int(tun.exit_min_nodes) and nodes < int(tun.exit_max_nodes):
			exit = e
			beacons[e].exit = true
			return true
	return false


## GenerateEvents: NEBULA-named entries feed the nebula clouds; the rest in XML order onto random free
## beacons (draws on taken beacons don't count; an empty pool stops everything); leftovers get NEUTRAL.
func _generate_events(desc: XmlNode, engine: EventEngine, tun: Dictionary) -> void:
	var entries := []
	var nebula_names := []
	if desc:
		for e in desc.children_named("event"):
			var nm := e.attr("name")
			if nm.contains("NEBULA"):
				var k := engine.select_amount(int(e.attr("min", "0")), int(e.attr("max", "0")),
					float(e.attr("chance", "-1")))
				for i in k:
					nebula_names.append(nm)
			else:
				entries.append(e)
	if not nebula_names.is_empty():
		_generate_nebulas(nebula_names, engine, tun)
	var pool := range(beacons.size())
	var stop := false
	for e in entries:
		if stop:
			break
		var n := engine.select_amount(int(e.attr("min", "0")), int(e.attr("max", "0")), float(e.attr("chance", "-1")))
		var placed := 0
		while placed < n:
			if pool.is_empty():
				stop = true
				break
			var idx := engine.r(pool.size())
			var id: int = pool[idx]
			pool.remove_at(idx)
			if not beacons[id].event.is_empty():
				continue
			beacons[id].event = engine.base_event(e.attr("name"))
			placed += 1
	for b in beacons:
		if b.event.is_empty():
			b.event = engine.base_event(RunTuning.name_of("neutral"))


## GenerateNebulas: clouds (small images below 6 names, else large) around a random free beacon, then
## clustered onto existing clouds (or re-centred after 21 failed tries); every free beacon strictly inside a
## kept cloud becomes a nebula beacon (event: a popped name, or NEBULA; the exit -> FINISH_BEACON_NEBULA).
func _generate_nebulas(names: Array, engine: EventEngine, tun: Dictionary) -> void:
	var imgs: Array = tun.nebula_small if names.size() < int(tun.nebula_small_below) else tun.nebula_large
	var sizes := []
	for p in imgs:
		var t := FtlData.texture("img/" + String(p))
		sizes.append(t.get_size() if t else Vector2(119, 63))
	var free := []
	for b in beacons:
		if not b.nebula:
			free.append(b.id)
	while names.size() > 0 and free.size() - names.size() < int(tun.nebula_min_free):
		names.remove_at(engine.r(names.size()))
	if names.is_empty() or free.is_empty():
		return
	var attempts := 0
	var k := engine.r(imgs.size())
	var c: Vector2 = beacons[free[engine.r(free.size())]].pos
	var rect := Rect2(c - sizes[k] / 2.0, sizes[k])
	for guard in 2000:
		if names.is_empty() or free.is_empty():
			break
		var captured := 0
		for id in free.duplicate():
			var p: Vector2 = beacons[id].pos
			if p.x > rect.position.x + 1 and p.x < rect.position.x + 1 + rect.size.x - 10 \
					and p.y > rect.position.y + 5 and p.y < rect.end.y - 5:
				var b: Dictionary = beacons[id]
				b.nebula = true
				b.env = 3
				if b.event.is_empty():
					b.event = engine.base_event(names.pop_at(engine.r(names.size())) if not names.is_empty()
						else RunTuning.name_of("nebula"))
				elif b.exit:
					b.event = engine.base_event(RunTuning.name_of("finish_nebula"))
				free.erase(id)
				captured += 1
		if captured > 0:
			clouds.append({"img": imgs[k], "rect": rect})
		else:
			attempts += 1
		k = engine.r(imgs.size())
		if attempts < int(tun.nebula_attempts) and not clouds.is_empty():
			var e: Rect2 = clouds[engine.r(clouds.size())].rect
			var sz: Vector2 = sizes[k]
			var x := e.position.x + engine.r(int(e.size.x + sz.x)) - sz.x
			var y := e.position.y + engine.r(int(e.size.y + sz.y)) - sz.y
			rect = Rect2(Vector2(x, y), sz)
		else:
			attempts = 0
			if free.is_empty():
				break
			c = beacons[free[engine.r(free.size())]].pos
			rect = Rect2(c - sizes[k] / 2.0, sizes[k])


## A tip for the run's first event: TIPS_LIST_PC (its `<text load="TIPS_LIST"/>` entry resolves into that list),
## drawn uniformly per level from a stream seeded by the sector seed.
static func start_tip(engine: EventEngine, sector_seed: int) -> String:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([sector_seed, "tip"])
	var lname := "TIPS_LIST_PC"
	for _depth in 4:
		var l: Array = engine.db.text_lists.get(lname, [])
		if l.is_empty():
			return ""
		var n: XmlNode = l[rng.randi() % l.size()]
		if n.has_attr("load"):
			lname = n.attr("load")
			continue
		return engine.tr_text(n.attr("id")) if n.has_attr("id") else EventEngine.decode(n.text)
	return ""
