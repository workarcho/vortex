class_name SectorTree
extends RefCounted
## The run's 8-sector map (rules/starmap.md §1: StarMap::GenerateSectorMap / AddSectorColumn /
## GetRandomSectorChoice / EventGenerator::GetSectorDescription). Generated once per run from its own seed.
##
## Sector = {id, pos: Vector2, level, cls ("CIVILIAN" / "HOSTILE" / "NEBULA"), desc, name, short, links: [ids of the
##   next column], visited: bool}

var sectors: Array = []
var columns: Array = []  # column -> [sector ids]
var seed := 0
var rng := RandomNumberGenerator.new()
var used_unique := {}  # sectorDescription names already used (unique="true")


func sector(id: int) -> Dictionary:
	return sectors[id]


func final_id() -> int:
	return columns[-1][0] if not columns.is_empty() else -1


## GenerateSectorMap: column 0 (civilian, STANDARD_SPACE renamed by the run), 6 AddSectorColumn columns, the
## final sector (hostile, FINAL) linked from every sector of column 6.
static func generate(tree_seed: int, db: EventDB, ae := true) -> SectorTree:
	var t := SectorTree.new()
	t.seed = tree_seed
	t.rng.seed = tree_seed
	var tun := RunTuning.section("sectors")
	var fp: Array = tun.first_pos
	t.roll_class()  # drawn, then forced to civilian
	var s0 := t._add(Vector2(float(fp[0]), float(fp[1])), 0, "CIVILIAN")
	s0.desc = RunTuning.name_of("first_sector")
	s0.name = FtlData.tr_id(RunTuning.name_of("first_sector_name"))
	s0.short = s0.name
	t.columns.append([s0.id])
	for c in int(tun.columns):
		t._add_column(db, ae, tun)
	var last: Array = t.columns[-1]
	var fin := t._add(Vector2(t.sectors[last[0]].pos.x + float(tun.x_step), float(fp[1])),
		int(tun.final_level), "HOSTILE")
	t._describe(fin, db, ae, String(tun.final))
	for id in last:
		t.sectors[id].links.append(fin.id)
	t.columns.append([fin.id])
	return t


## GetRandomSectorChoice: r % 10: 0–1 nebula, 6–9 hostile, else civilian.
func roll_class() -> String:
	var tun := RunTuning.section("sectors")
	var r := int(rng.randi() % int(tun.class_roll))
	if r < int(tun.nebula_below):
		return "NEBULA"
	if r >= int(tun.hostile_from):
		return "HOSTILE"
	return "CIVILIAN"


func _add(pos: Vector2, level: int, cls: String) -> Dictionary:
	var s := {"id": sectors.size(), "pos": pos, "level": level, "cls": cls, "desc": "", "name": "", "short": "",
		"links": [], "visited": false}
	sectors.append(s)
	return s


## AddSectorColumn: n = 2..4 sectors (≠ previous count; 2 after the single first sector), vertically centred,
## linked without crossings, each with a rolled class and description.
func _add_column(db: EventDB, ae: bool, tun: Dictionary) -> void:
	var prev: Array = columns[-1]
	var p := prev.size()
	var n := 2 + int(rng.randi() % 3)
	while n == p:
		n = 2 + int(rng.randi() % 3)
	var y0 := 0.0
	if p == 1:
		n = 2
		y0 = 50.0
	else:
		y0 = float((4 - n) * 50 / 2)
	var x: float = sectors[prev[0]].pos.x + float(tun.x_step)
	var level: int = sectors[prev[0]].level + 1
	var col := []
	var mk := func() -> int:
		var s := _add(Vector2(x, y0 + float(tun.y_step) * col.size()), level, roll_class())
		col.append(s.id)
		return s.id
	if p == 4 and n == 2:
		var a: int = mk.call()
		var b: int = mk.call()
		sectors[prev[0]].links.append(a)
		sectors[prev[1]].links.append(a)
		sectors[prev[2]].links.append(b)
		sectors[prev[3]].links.append(b)
	elif p == 2 and n == 4:
		for i in 2:
			var a: int = mk.call()
			var b: int = mk.call()
			sectors[prev[i]].links.append(a)
			sectors[prev[i]].links.append(b)
	else:
		var carry := -1
		for i in p:
			if carry >= 0:
				sectors[prev[i]].links.append(carry)
			if i == p - 1 and n <= p:
				break
			var s: int = mk.call()
			sectors[prev[i]].links.append(s)
			carry = s
			if n > p and i == 0:
				var s2: int = mk.call()
				sectors[prev[0]].links.append(s2)
				carry = s2
	for id in col:
		_describe(sectors[id], db, ae)
	columns.append(col)


## GetSectorDescription(class, level): candidates of <sectorType name=CLASS> (OVERRIDE_CLASS with AE), drop
## minSector > level and used unique ones, uniform pick; unique → used; random name of its nameList.
func _describe(s: Dictionary, db: EventDB, ae: bool, forced := "") -> void:
	var pick := forced
	if pick == "":
		var key: String = "OVERRIDE_" + s.cls if ae and db.sector_types.has("OVERRIDE_" + s.cls) else s.cls
		var cands := []
		for nm in db.sector_types.get(key, []):
			var d: XmlNode = db.sectors.get(nm)
			if d == null or used_unique.has(nm) or int(d.attr("minSector", "0")) > int(s.level):
				continue
			cands.append(nm)
		if cands.is_empty():
			cands = [RunTuning.name_of("first_sector")]
		pick = cands[int(rng.randi() % cands.size())]
	var desc: XmlNode = db.sectors.get(pick)
	if desc and desc.attr("unique") == "true":
		used_unique[pick] = true
	s.desc = pick
	s.name = pick
	s.short = pick
	var nl := desc.child("nameList") if desc else null
	var names := nl.children_named("name") if nl else []
	if not names.is_empty():
		var nm: XmlNode = names[int(rng.randi() % names.size())]
		s.name = FtlData.tr_id(nm.attr("id"))
		s.short = FtlData.tr_id(nm.attr("short", nm.attr("id")))


## StarMap::NeighboringSector: the next sectors reachable from `from`.
func neighbours(from: int) -> Array:
	return sectors[from].links if from >= 0 and from < sectors.size() else []
