class_name ShipGraph
extends RefCounted
## Room slots and door-graph pathfinding of a ship (rules/crew.md "Pathfinding", "Slots").
## Positions are local ship coordinates (same space as ShipState.room_rect()).

const T := 35
const SEALED_COST := 1000.0  # a sealed door is a last resort, not impossible

## Player-ship console defaults when the blueprint gives no <slot> (ShipManager::AddSystem, iShipId 0):
## system -> [slot, facing]. Other systems have no console (not boostable).
const PLAYER_CONSOLE_DEFAULTS := {
	"shields": [0, "left"], "engines": [2, "down"], "weapons": [1, "up"], "pilot": [0, "right"],
	"sensors": [0, "up"], "doors": [0, "up"],
}
## Systems that get a console (bBoostable when AddSystem runs; artillery only on enemy ships).
const CONSOLE_SYSTEMS := ["shields", "engines", "weapons", "pilot", "sensors", "doors", "artillery"]
## Systems whose blueprint <slot> marks a blocked tile instead of a console.
const OBSTRUCTION_SYSTEMS := ["medbay", "clonebay"]

var ship: ShipState


func _init(s: ShipState) -> void:
	ship = s


# ------------------------------------------------------------ slots

func room_size(room_id: int) -> Vector2i:
	var r := ship.room_rect(room_id)
	return Vector2i(int(r.size.x / T), int(r.size.y / T))


func slot_count(room_id: int) -> int:
	var sz := room_size(room_id)
	return sz.x * sz.y


## Slot id = x + y * width (tile coords inside the room); position = tile centre.
func slot_position(room_id: int, slot: int) -> Vector2:
	var sz := room_size(room_id)
	if sz.x <= 0:
		return ship.room_rect(room_id).get_center()
	return ship.room_rect(room_id).position + Vector2((slot % sz.x) + 0.5, (slot / sz.x) + 0.5) * T


## Slot under a point of a room (or -1).
func slot_at(room_id: int, p: Vector2) -> int:
	var r := ship.room_rect(room_id)
	if not r.has_point(p):
		return -1
	var sz := room_size(room_id)
	var l := Vector2i((p - r.position) / T)
	return l.y * sz.x + l.x


## Primary (console) slot of the system in a room, or -1 if the room has none.
func console_slot(room_id: int) -> int:
	return int(_primary(room_id)[0])


## Facing of the crew manning the console ("up" / "down" / "left" / "right"; "" = not given).
func console_dir(room_id: int) -> String:
	return String(_primary(room_id)[1])


var _primary_cache := {}  # room_id -> [system id, slot, dir]


## ShipManager::AddSystem console rule (rules/crew.md "Console slot"): only boostable systems get one;
## the blueprint <slot><number/><direction/></slot> wins; otherwise the player ship uses fixed defaults
## per system and enemy ships pilot slot 0 facing up / artillery slot 0 up / Ship::ChoosePrimarySlot.
func _primary(room_id: int) -> Array:
	var s := ship.system_in_room(room_id)
	if s == null or OBSTRUCTION_SYSTEMS.has(s.id) or not CONSOLE_SYSTEMS.has(s.id) 			or (s.id == "artillery" and ship.is_player):
		return [-1, ""]
	var c: Array = _primary_cache.get(room_id, [])
	if not c.is_empty() and c[0] == s.id:
		return [c[1], c[2]]
	var bp := ship.system_by_id(s.id)
	var slot: int = bp.get("slot", -1)
	var dir: String = bp.get("slot_dir", "")
	if slot < 0:
		if ship.is_player:
			var d: Array = PLAYER_CONSOLE_DEFAULTS.get(s.id, [0, ""])
			slot = d[0]
			dir = d[1]
		elif s.id == "pilot" or s.id == "artillery":
			slot = 0
			dir = "up"
		else:
			var pick := choose_primary_slot(room_id)
			slot = pick[0]
			dir = pick[1]
	if slot >= slot_count(room_id):
		slot = 0
	_primary_cache[room_id] = [s.id, slot, dir]
	return [slot, dir]


## Ship::ChoosePrimarySlot: every (tile, wall side) pair of the room whose neighbour square is not connected
## (outside the room and no door between) is a candidate, scanned column by column (x outer, y inner) and
## per tile below, above, right, left; one is picked at random. Returns [slot, facing toward that wall].
## The exe uses the global RNG; here a per-ship-and-room seed keeps it reproducible.
func choose_primary_slot(room_id: int) -> Array:
	var r := _room_grid(room_id)
	var cands := []
	for x in range(r.position.x, r.end.x):
		for y in range(r.position.y, r.end.y):
			var slot := (x - r.position.x) + (y - r.position.y) * r.size.x
			var g := Vector2i(x, y)
			for nd in [[Vector2i(0, 1), "down"], [Vector2i(0, -1), "up"], [Vector2i(1, 0), "right"],
					[Vector2i(-1, 0), "left"]]:
				if not _grid_connected(r, g, g + nd[0]):
					cands.append([slot, nd[1]])
	if cands.is_empty():
		return [0, ""]
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%s:%d" % [ship.blueprint.get("name", ""), room_id])
	return cands[rng.randi() % cands.size()]


## Room rectangle in layout grid units.
func _room_grid(room_id: int) -> Rect2i:
	for rm in ship.layout.get("rooms", []):
		if rm.id == room_id:
			return rm.rect
	return Rect2i()


## ShipGraph::ConnectedGridSquares for a tile of room `r` and a neighbour: same room, or a door between.
func _grid_connected(r: Rect2i, a: Vector2i, b: Vector2i) -> bool:
	if r.has_point(b):
		return true
	for d in ship.layout.get("doors", []):
		var t := _door_tiles(d)
		if (t[0] == a and t[1] == b) or (t[0] == b and t[1] == a):
			return true
	return false


## Tile nobody can stand on (medbay/clonebay "slot"), or -1.
func blocked_slot(room_id: int) -> int:
	var s := ship.system_in_room(room_id)
	if s == null or not OBSTRUCTION_SYSTEMS.has(s.id):
		return -1
	var slot: int = ship.system_by_id(s.id).get("slot", -1)
	if slot == -1 and ship.is_player:
		slot = 1  # AddSystem: player medbay / clonebay without <slot> block tile 1 (-2 = none)
	return slot if slot < slot_count(room_id) else -1


## Slots of a room reserved by living crew (their destination slot), excluding `except`.
## Own crew and intruders use two separate slot sets (Room::slots[intruder]).
func taken_slots(room_id: int, except: CrewMember = null, intruders := false) -> Dictionary:
	var out := {}
	for c in ship.crew:
		if c != except and c.is_alive() and c.target_room == room_id and c.slot >= 0 				and c.is_intruder(ship) == intruders:
			out[c.slot] = true
	return out


## Slot for a crew member ordered into a room: console if free (not for intruders), else the lowest
## free slot of its side's set; -1 if full.
func find_slot(room_id: int, who: CrewMember = null) -> int:
	var intr := who != null and who.is_intruder(ship)
	var taken := taken_slots(room_id, who, intr)
	var blocked := blocked_slot(room_id)
	var console := console_slot(room_id)
	var drone := who != null and who.is_drone()  # crew drones cannot man: they never take the console
	if console >= 0 and console != blocked and not taken.has(console) and not intr and not drone:
		return console
	for i in slot_count(room_id):
		if i != blocked and not taken.has(i):
			return i
	return -1


## ShipGraph::GetRoomNeighbors: rooms geometrically touching a room (no door needed). One test point per 35 px
## tile along each side, 17 px outside the wall, tested against every room; the room itself is excluded.
func room_neighbors(room_id: int) -> Array:
	var r := ship.room_rect(room_id)
	var pts: Array[Vector2] = []
	var cols := int(roundf(r.size.x / T))
	var rows := int(roundf(r.size.y / T))
	for i in cols:
		var x := r.position.x + i * T + T * 0.5
		pts.append(Vector2(x, r.position.y - 17))
		pts.append(Vector2(x, r.end.y + 17))
	for j in rows:
		var y := r.position.y + j * T + T * 0.5
		pts.append(Vector2(r.position.x - 17, y))
		pts.append(Vector2(r.end.x + 17, y))
	var out := []
	for p in pts:
		var other := ship.room_at(p)
		if other >= 0 and other != room_id and not out.has(other):
			out.append(other)
	return out


# ------------------------------------------------------------ doors

func door_center(d: Dictionary) -> Vector2:
	if d.vertical:
		return ship.origin + Vector2(d.x * T, d.y * T + T * 0.5)
	return ship.origin + Vector2(d.x * T + T * 0.5, d.y * T)


## The two global tiles a door joins (vertical: left/right of x; horizontal: above/below y).
func _door_tiles(d: Dictionary) -> Array:
	if d.vertical:
		return [Vector2i(d.x - 1, d.y), Vector2i(d.x, d.y)]
	return [Vector2i(d.x, d.y - 1), Vector2i(d.x, d.y)]


func _tile_center(g: Vector2i) -> Vector2:
	return ship.origin + (Vector2(g) + Vector2(0.5, 0.5)) * T


## Entry (in `from_room`) and exit tile centres for crossing a door.
func crossing(d: Dictionary, from_room: int) -> Array:
	var tiles := _door_tiles(d)
	var a: Vector2i = tiles[0]
	var b: Vector2i = tiles[1]
	if ship.env.tile_room.get(a, -1) != from_room:
		var t := a
		a = b
		b = t
	return [_tile_center(a), _tile_center(b)]


func _other_room(d: Dictionary, room_id: int) -> int:
	if d.left == room_id:
		return d.right
	if d.right == room_id:
		return d.left
	return -1


## Room full for a side (Room::Full(intruder)).
func room_full(room_id: int, intruders: bool) -> bool:
	var taken := taken_slots(room_id, null, intruders)
	var blocked := blocked_slot(room_id)
	for i in slot_count(room_id):
		if i != blocked and not taken.has(i):
			return false
	return true


## Sealed for this crew member (Door::IsSealed): closed, blast level >= 1 (doors powered to 2+), the
## crew is an intruder, and not forced open. Own crew are never blocked by their own doors.
## A hacked door (Door::IsSealed with iHacked) inverts the side: sealed against its own ship's crew,
## open to intruders. A crystal lockdown seals the door for everyone, whatever its state (rules/races.md).
func is_sealed(d: Dictionary, who: CrewMember) -> bool:
	if float(d.get("lockdown", 0.0)) > 0.0:
		return true
	if who == null or d.open or d.forced > 0.0:
		return false
	if int(d.get("hacked", 0)) > 0:
		return not who.is_intruder(ship)
	if not who.is_intruder(ship):
		return false
	return ship.env.door_blast() > 0


func _sealed(d: Dictionary, who: CrewMember) -> bool:
	return is_sealed(d, who)


## Dijkstra over doors. Returns the doors to cross in order ([] = same room), or null if unreachable.
func find_path(from_pos: Vector2, from_room: int, to_room: int, who: CrewMember = null) -> Variant:
	if from_room < 0 or to_room < 0:
		return null
	if from_room == to_room:
		return []
	var doors: Array = ship.env.doors
	# Node = Vector2i(door index, room entered after crossing it).
	var dist := {}
	var prev := {}
	var open := []
	for i in doors.size():
		var d: Dictionary = doors[i]
		if d.airlock:
			continue
		var other := _other_room(d, from_room)
		if other < 0:
			continue
		var n := Vector2i(i, other)
		var cost := from_pos.distance_to(door_center(d)) + (SEALED_COST if _sealed(d, who) else 0.0)
		if cost < dist.get(n, INF):
			dist[n] = cost
			prev[n] = null
			open.append(n)
	var done := {}
	while not open.is_empty():
		var best := 0
		for k in open.size():
			if dist[open[k]] < dist[open[best]]:
				best = k
		var cur: Vector2i = open[best]
		open.remove_at(best)
		if done.has(cur):
			continue
		done[cur] = true
		if cur.y == to_room:
			var out := []
			var n: Variant = cur
			while n != null:
				out.push_front(n.x)
				n = prev[n]
			return out
		var cd: Dictionary = doors[cur.x]
		for i in doors.size():
			var d: Dictionary = doors[i]
			if i == cur.x or d.airlock:
				continue
			var other := _other_room(d, cur.y)
			if other < 0:
				continue
			var n2 := Vector2i(i, other)
			var c2: float = dist[cur] + door_center(cd).distance_to(door_center(d)) \
				+ (SEALED_COST if _sealed(d, who) else 0.0)
			if c2 < dist.get(n2, INF) and not done.has(n2):
				dist[n2] = c2
				prev[n2] = cur
				open.append(n2)
	return null
