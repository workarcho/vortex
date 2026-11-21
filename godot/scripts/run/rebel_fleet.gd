class_name RebelFleet
extends RefCounted
## The rebel fleet's danger zone on a sector's beacon map (rules/starmap.md §4: StarMap::UpdateDangerZone /
## GetNextDangerMove / ModifyPursuit / TurnIntoFleetLocation). A circle of radius 767 whose centre moves right on
## every jump / wait; beacons inside it are overtaken (event replaced by a fleet event). Pure rules.

var center := Vector2.ZERO  # map coordinates (same frame as the beacon positions)
var pursuit_delay := 0  # < 0: the fleet does not move; > 0: double move; steps toward 0 per move
var last_move := 0


static func _t() -> Dictionary:
	return RunTuning.section("fleet")


## Start of a sector: centre (-959, 50 + rand % 250) → its edge at x = -192.
static func start(rng: RandomNumberGenerator) -> RebelFleet:
	var f := RebelFleet.new()
	var t := _t()
	f.center = Vector2(float(t.start_x), float(t.start_y) + float(rng.randi() % int(t.start_y_spread)))
	return f


func radius() -> float:
	return float(_t().radius)


func covers(p: Vector2) -> bool:
	return p.distance_squared_to(center) < radius() * radius()


## GetNextDangerMove for the beacon being left: 64 (normal), 51 (nebula beacon in a nebula sector), 32 (nebula
## beacon elsewhere); doubled while pursuit_delay > 0, 0 while < 0; 0 once the centre reached x = 60.
func next_move(leaving_nebula: bool, nebula_sector: bool) -> int:
	var t := _t()
	if pursuit_delay < 0 or center.x >= float(t.x_cap):
		return 0
	var k := 0
	if leaving_nebula:
		k = 1 if nebula_sector else 2
	var table: Array = t.move_double if pursuit_delay > 0 else t.move
	return int(table[k])


## UpdateDangerZone: move (capped at x 60), then pursuit_delay steps toward 0. Returns the move.
func advance(leaving_nebula: bool, nebula_sector: bool) -> int:
	var m := next_move(leaving_nebula, nebula_sector)
	center.x = minf(center.x + m, maxf(float(_t().x_cap), center.x))
	if pursuit_delay < 0:
		pursuit_delay += 1
	elif pursuit_delay > 0:
		pursuit_delay -= 1
	last_move = m
	return m


## Beacons the zone now covers that are not overtaken yet.
func newly_covered(map: StarMap) -> Array:
	var out := []
	for b in map.beacons:
		if not b.get("fleet", false) and covers(b.pos):
			out.append(b.id)
	return out


## TurnIntoFleetLocation: the beacon is overtaken; its event becomes FLEET_EASY (+_DLC with AE), FLEET_EASY_NEBULA
## in a nebula, the exit FLEET_EASY_BEACON (+_DLC unless easy) keeping the exit flag. Stores / repair are gone.
static func overtake(map: StarMap, id: int, engine: EventEngine) -> void:
	var b: Dictionary = map.beacons[id]
	var names: Dictionary = _t().names
	var n := ""
	if b.exit:
		n = String(names.fleet_beacon)
		if engine.difficulty != EventEngine.Difficulty.EASY and engine.db.has_event_or_list(n + "_DLC"):
			n += "_DLC"
	elif b.nebula:
		n = String(names.fleet_nebula)
	else:
		n = String(names.fleet)
		if engine.ae and engine.db.has_event_or_list(n + "_DLC"):
			n += "_DLC"
	b.fleet = true
	b.shop = null
	b.event = engine.base_event(n)
	b.event_fresh = true  # the new event fires even on an already visited beacon [inferred]
