extends Node
## Tests for rules/backgrounds.md (SpaceImages, RunState.space, SpaceBackdrop clouds): image lists from the data,
## event <img> / textList planet= / back= / <fleet>, background and planet picks (differ from the current image,
## planet inside the screen, rotation 0 / 180), kept per beacon and restored on a revisit, reproducible per seed,
## danger-zone fleet grid, ASB planet, pulsar background, nebula cloud grid. Run:
##   godot --headless --path godot res://tests/test_backgrounds.tscn

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
	var lists: Dictionary = db.image_lists
	# --- image lists (ProcessImageList): paths only, ui="ipad" variants skipped
	check("BACKGROUND list (4 entries, no ipad paths)", lists.get("BACKGROUND", []).size(), 4)
	check("BACKGROUND entries are stars/ paths",
		lists.get("BACKGROUND", []).all(func(p): return String(p).begins_with("stars/")), true)
	check("PLANET list keeps its 12 entries (w/h ignored)", lists.get("PLANET", []).size(), 12)
	check("BG_DARK list", lists.get("BG_DARK", []), ["stars/bg_dullstars.png", "stars/bg_dullstars2.png"])

	# --- events: defaults, <img>, textList planet= / back=, <fleet>
	var eng := EventEngine.new()
	eng.rng.seed = 5
	var ev := eng.new_event("X")
	check("default lists", [ev.back, ev.planet], ["BACKGROUND", "PLANET"])
	var n := XmlNode.parse('<FTL><event><text>hi</text><img back="BG_DARK" planet="NONE"/></event></FTL>').children[0]
	ev = eng.create_event(n, "IMG")
	check("<img back planet>", [ev.back, ev.planet], ["BG_DARK", "NONE"])
	n = XmlNode.parse('<FTL><event><fleet>fed</fleet><text>x</text></event></FTL>').children[0]
	check("<fleet>fed</fleet> = 2", eng.create_event(n, "F").fleet_pos, 2)
	check("<fleet>battle</fleet> = 3", eng.create_event(XmlNode.parse(
		'<FTL><event><fleet>battle</fleet></event></FTL>').children[0], "B").fleet_pos, 3)
	# textList entries: text_NOTHING_1 has planet="NONE" back="BG_DARK"; other entries keep the defaults or set planet.
	var seen := {}
	for s in 40:
		eng.used_text.clear()
		eng.rng.seed = s
		var e2 := eng.create_event(XmlNode.parse('<FTL><event><text load="NOTHING"/></event></FTL>').children[0], "N")
		seen["%s|%s" % [e2.back, e2.planet]] = true
	check("textList planet/back override (NONE + BG_DARK seen)", seen.has("BG_DARK|NONE"), true)
	check("textList entry without images keeps the defaults", seen.has("BACKGROUND|PLANET"), true)

	# --- SwitchBackground / SwitchPlanet
	var rng := RandomNumberGenerator.new()
	var bad := {}
	var backs := {}
	for s in 200:
		rng.seed = s
		var cur := "stars/bg_darknebula.png"
		var b := SpaceImages.switch_background(lists, "BACKGROUND", cur, rng)
		backs[b] = true
		if b == cur or not b in lists.BACKGROUND:
			bad["background differs from the current one"] = s
		var p := SpaceImages.switch_planet(lists, "PLANET", "stars/planet_red.png", rng)
		if p.is_empty() or p.img == "stars/planet_red.png":
			bad["planet differs from the current one"] = s
		elif p.pos.x < 0 or p.pos.y < 0 or p.pos.x + p.size.x > 1280 or p.pos.y + p.size.y > 720:
			bad["planet inside 1280×720"] = [s, p]
		elif not p.rot in [0, 180]:
			bad["rotation 0 / 180"] = s
	check("background / planet picks", bad, {})
	check("the 3 other BACKGROUND images all occur", backs.size(), 3)
	check("planet NONE", SpaceImages.switch_planet(lists, "NONE", "", rng), {})
	check("unknown background list keeps the old one (\"\")", SpaceImages.switch_background(lists, "NOPE", "", rng), "")
	var pds := SpaceImages.pds_planet(lists, rng)
	check("ASB planet from PLANET_POPULATED at (600, 247)", [String(pds.img).contains("populated"), pds.pos],
		[true, Vector2i(600, 247)])

	# --- danger zone grid
	var fl := SpaceImages.danger_zone(1, rng)
	check("9 fleet ships", fl.size(), 9)
	var grid_ok := true
	for i in 9:
		var p: Vector2i = fl[i].pos
		if p.x < (i / 3) * 1280 / 3 or p.x >= (i / 3 + 1) * 1280 / 3 or p.y < (i % 3) * 240 or p.y >= (i % 3 + 1) * 240:
			grid_ok = false
		if String(fl[i].img).contains("fed"):
			grid_ok = false
	check("rebel ships on the 3 × 3 grid", grid_ok, true)
	check("federation zone = fed ships", SpaceImages.danger_zone(2, rng).all(
		func(f): return String(f.img).contains("fleetfed")), true)
	check("danger 0 = no ships", SpaceImages.danger_zone(0, rng), [])

	# --- RunState: per beacon, kept on revisit, reproducible per seed
	var r := RunState.new_run(4242)
	var start_space: Dictionary = r.space.duplicate(true)
	check("start beacon has a space", start_space.has("back") and start_space.has("planet"), true)
	var r2 := RunState.new_run(4242)
	check("same seed → same start space", r2.space.back == start_space.back
		and r2.space.planet == start_space.planet, true)
	var first: int = r.map.beacons[r.current_beacon].links[0]
	r.phase = RunState.Phase.IDLE
	r.dialog = {}
	r.jump_to(first)
	var s1: Dictionary = r.space.duplicate(true)
	check("new beacon: background differs from the previous one",
		s1.back != start_space.back or r.env == HazardRule.Env.PULSAR, true)
	r.phase = RunState.Phase.IDLE
	r.dialog = {}
	r.jump_to(r.map.start)
	check("revisit restores the beacon's background + planet",
		[r.space.back, r.space.planet] == [start_space.back, start_space.planet], true)
	r.phase = RunState.Phase.IDLE
	r.dialog = {}
	r.jump_to(first)
	check("revisit restores the other beacon too", [r.space.back, r.space.planet] == [s1.back, s1.planet], true)
	# Different seeds give different spaces somewhere among a few runs.
	var distinct := {}
	for sd in [1, 2, 3, 4, 5, 6]:
		var rr := RunState.new_run(sd)
		distinct[str([rr.space.back, rr.space.planet.get("img", ""), rr.space.planet.get("pos", 0)])] = true
	check("seeds vary the start space", distinct.size() > 1, true)

	# --- pulsar / ASB / fleet in RunState._choose_space
	var rp := RunState.new_run(77)
	var b: Dictionary = rp.beacon()
	rp.env = HazardRule.Env.PULSAR
	rp._choose_space(b)
	check("pulsar: currentBack = bg_dullstars", rp.space_back, SpaceImages.PULSAR_BACK)
	rp.env = HazardRule.Env.PDS
	rp._choose_space(b)
	check("ASB outside the danger zone: populated planet", String(rp.space.pds_planet.get("img", "")).contains(
		"populated"), true)
	b.fleet = true
	rp._choose_space(b)
	check("overtaken beacon: danger zone 1, no ASB planet",
		[rp.space.danger, rp.space.fleet.size(), rp.space.pds_planet], [1, 9, {}])

	# --- SpaceBackdrop: nebula clouds (SetNebula grid, pre-simulated), pulsar background, sandbox default
	var bd := SpaceBackdrop.new()
	add_child(bd)
	var neb := HazardRule.create(HazardRule.Env.NEBULA, 2, 3, 0)
	var sp := SpaceBackdrop.sandbox_space()
	bd.setup(sp, neb, null)
	check("nebula: clouds exist after the pre-simulation", bd.clouds.size() >= 12, true)
	check("nebula: clouds kept in the space dict (rebuilds continue them)", sp.get("clouds_state") == bd.clouds, true)
	var in_grid := true
	for c in bd.clouds:
		if c.pos.x < 35 or c.pos.x > 1215 or c.pos.y < 160 or c.pos.y > 700:
			in_grid = false
	check("cloud points on the 4 × 3 grid", in_grid, true)
	check("clouds fade between 0 and 1", bd.clouds.all(func(c): return c.alpha >= 0.0 and c.alpha <= 1.0), true)
	var bd2 := SpaceBackdrop.new()
	add_child(bd2)
	bd2.setup(SpaceBackdrop.sandbox_space(), HazardRule.create(HazardRule.Env.NEBULA, 2, 3, 0), null)
	check("same seed → same clouds", str(bd2.clouds) == str(bd.clouds), true)
	var bp := SpaceBackdrop.new()
	add_child(bp)
	bp.setup(SpaceBackdrop.sandbox_space(), HazardRule.create(HazardRule.Env.PULSAR, 2, 3, 0), null)
	check("pulsar draws bg_dullstars", bp.back_path(), SpaceImages.PULSAR_BACK)
	var bs := SpaceBackdrop.new()
	add_child(bs)
	bs.setup(SpaceBackdrop.sandbox_space(), null, null)
	check("sandbox default background", bs.back_path(), "stars/bg_darknebula.png")
	check("glow alpha triangle", [SpaceBackdrop.glow_alpha(0.0, 7.0), SpaceBackdrop.glow_alpha(3.5, 7.0),
		SpaceBackdrop.glow_alpha(5.25, 7.0)], [0.0, 1.0, 0.5])

