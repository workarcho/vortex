extends Node
## Tests for rules/ship_rendering.md §4 / rules/crew.md "Console slot and facing": for every ship blueprint (player
## A/B/C, enemies, pirates, bosses), with every listed system installed, each manned station (boostable system)
## has its console slot inside the room, the art under it matches (enemy computer1.png on the slot; player
## interior image whose rooms.xml glow sits on the console tile and faces the console direction), and a crew
## member placed there mans it facing the console. Player systems without `img` use the exe's default interior
## image "room_" + name (ShipSystem::ShipSystem). Also the
## hangar HIDE ROOMS view (hull only) and the hangar air (lanius drain). Uses the user's FTL data. Run:
##   godot --headless --path godot res://tests/test_room_consoles.tscn

const Harness := preload("res://tests/harness.gd")
const FILES := ["data/blueprints.xml", "data/dlcBlueprints.xml", "data/dlcBlueprintsOverwrite.xml",
	"data/autoBlueprints.xml", "data/dlcPirateBlueprints.xml", "data/bosses.xml"]

var fails := 0


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func _ready() -> void:
	Harness.run(self, _run)


func _blueprint_names() -> Array:
	var out := []
	var re := RegEx.create_from_string("<shipBlueprint\\s+name=\"([^\"]+)\"\\s+layout=\"([^\"]+)\"")
	for f in FILES:
		if not FileAccess.file_exists(FtlData.root.path_join(f)):
			continue
		for m in re.search_all(FtlData.text(f)):
			var n := m.get_string(1)
			# Skip names without a layout file (unfinished PLAYER_SHIP_ANAEROBIC_3).
			if not out.has(n) and FtlData.has_ship_blueprint(n) and FileAccess.file_exists(FtlData.root.path_join("data/%s.txt" % m.get_string(2))):
				out.append(n)
	return out


## Every system the blueprint lists, installed as ShipGenerator / a store purchase would (start = true).
func _full_ship(bp: String, player: bool) -> ShipState:
	var s := ShipState.new(bp, player)
	s.blueprint = s.blueprint.duplicate(true)
	for b in s.blueprint.systems:
		if s.sys(b.id) == null and not (b.id == "artillery" and player and not b.start):
			b.start = true
			s.systems[b.id] = SystemState.new(b.id, int(b.room), maxi(int(b.power), 1))
	s.graph = ShipGraph.new(s)  # fresh console cache for the added systems
	return s


func _run() -> void:
	var names := _blueprint_names()
	check("blueprints found (player, enemy, pirate, boss)", names.size() > 80, true)
	var stations := 0
	var bad_slot := []
	var bad_art := []
	var bad_face := []
	var bare := []
	var view := ShipView.new()  # never in the tree: console_art only reads the ship
	for bp in names:
		var player := String(bp).begins_with("PLAYER_SHIP")
		var s := _full_ship(bp, player)
		view.ship = s
		for b in s.blueprint.systems:
			var sy := s.sys(b.id)
			if sy == null:
				continue
			var slot := s.graph.console_slot(sy.room)
			if slot < 0:
				continue
			stations += 1
			var dir := s.graph.console_dir(sy.room)
			if slot >= s.graph.slot_count(sy.room):
				bad_slot.append("%s %s slot %d" % [bp, b.id, slot])
			var art := view.console_art(sy)
			match art.kind:
				"computer":
					if player or art.slot != slot or art.dir != dir:
						bad_art.append("%s %s computer %s" % [bp, b.id, art])
				"interior":
					if not player or art.slot != slot or art.dir != dir:
						bad_art.append("%s %s glow %s vs console %d %s" % [bp, b.id, art, slot, dir])
				"bare":
					if not player:
						bad_art.append("%s %s enemy without console" % [bp, b.id])
					bare.append("%s:%s" % [bp, b.id])
				_:
					bad_art.append("%s %s no art %s" % [bp, b.id, art])
			# A crew member standing on the console mans it facing the console (CrewMember::SetCurrentSystem).
			var c: CrewMember = null
			for m in s.crew:
				if m.is_alive() and not m.is_drone():
					c = m
					break
			if c == null:
				continue
			c.facing = "up" if dir != "up" else "down"
			c.place(s, sy.room, slot)
			for _i in 3:
				s.tick_crew_only(1.0 / 16.0)
			if dir != "" and (c.task != CrewMember.Task.MAN or c.facing != dir):
				bad_face.append("%s %s task %d facing %s want %s" % [bp, b.id, c.task, c.facing, dir])
	view.free()
	check("manned stations checked", stations > 500, true)
	check("every console slot lies inside its room", bad_slot, [])
	check("console art sits on the console slot and faces its direction", bad_art, [])
	check("crew on the console man it facing the console", bad_face, [])
	# A player system without `img` gets the default "room_" + name (ShipSystem::ShipSystem), so the only stations
	# without a lit console are doors / sensors, whose room_doors* / room_sensors* images have no rooms.xml glow.
	print("  player stations without a glow layout (doors / sensors): ", bare.size())
	check("only doors / sensors stations lack a console glow",
		bare.filter(func(x): return not (x.ends_with(":doors") or x.ends_with(":sensors"))), [])
	check("Kestrel A: every station has its interior console except doors / sensors",
		bare.filter(func(x): return x.begins_with("PLAYER_SHIP_HARD:")), ["PLAYER_SHIP_HARD:doors",
		"PLAYER_SHIP_HARD:sensors"])
	check("Mantis A pilot room (no img) draws the default room_pilot console",
		bare.has("PLAYER_SHIP_MANTIS:pilot"), false)
	check("Lanius A: all stations drawn but doors / sensors",
		bare.filter(func(x): return x.begins_with("PLAYER_SHIP_ANAEROBIC:")).size(), 2)

	print("Default interior image (ShipSystem::ShipSystem \"room_\" + name; empty img keeps it)")
	var fed := ShipState.new("PLAYER_SHIP_FED", true)
	var no_img := []
	for id in ["pilot", "shields", "weapons", "sensors", "medbay"]:
		no_img.append(ShipView.interior_image(id, fed.system_by_id(id)))
	check("Fed A pilot / shields / weapons / sensors / medbay (no img)", no_img,
		["room_pilot", "room_shields", "room_weapons", "room_sensors", "room_medbay"])
	check("Fed A oxygen keeps its img", ShipView.interior_image("oxygen", fed.system_by_id("oxygen")),
		"room_oxygen_4")
	check("Fed A artillery (no img) -> room_artillery", ShipView.interior_image("artillery",
		fed.system_by_id("artillery")), "room_artillery")
	check("clonebay never gets a default image", ShipView.interior_image("clonebay", {}), "")
	var missing := []
	for bp in names:
		if not String(bp).begins_with("PLAYER_SHIP"):
			continue
		var ps := ShipState.new(bp, true)
		for b in ps.blueprint.systems:
			var n := ShipView.interior_image(b.id, b)
			if n != "" and b.id not in ["teleporter"] and FtlData.texture("img/ship/interior/%s.png" % n) == null:
				missing.append("%s:%s" % [bp, n])
	check("every player system's interior image exists (teleporter draws pads instead)", missing, [])

	print("Hangar HIDE ROOMS (ShipManager::bShowRoom false: RenderWeapons + Ship::OnRenderJump(0))")
	var k := ShipState.new("PLAYER_SHIP_HARD", true)
	var hv := ShipView.new()
	hv.setup(k)
	add_child(hv)
	await get_tree().process_frame
	await get_tree().process_frame
	check("rooms shown: the interior pass runs", hv.drew_interior, true)
	hv.hide_interior = true
	hv.queue_redraw()
	await get_tree().process_frame
	await get_tree().process_frame
	check("HIDE ROOMS: hull only (no floor image, rooms, doors, symbols or crew)", hv.drew_interior, false)
	hv.queue_free()

	print("Hangar air (ShipBuilder::OnLoop runs ShipManager::OnLoop: lanius drain their rooms)")
	var l := ShipState.new("PLAYER_SHIP_ANAEROBIC", true)
	var lan_rooms := {}
	for c in l.crew:
		if c.race == "anaerobic":
			lan_rooms[c.room] = true
	check("Lanius A: two lanius in two rooms", lan_rooms.size(), 2)
	for _i in 20 * 16:
		l.tick_crew_only(1.0 / 16.0)
	var low := []
	for r in l.layout.rooms:
		if l.env.room_o2(r.id) <= 5.0:
			low.append(r.id)
	low.sort()
	var want: Array = lan_rooms.keys()
	want.sort()
	check("after 20 s in the hangar exactly the lanius rooms are at <= 5 % (stripes)", low, want)
	var cfg := {"oxygen": l.env.oxygen.duplicate()}
	var run_ship := ShipState.new("PLAYER_SHIP_ANAEROBIC", true)
	TitleState.apply_to_ship(run_ship, cfg)
	check("the run starts with the hangar ship's oxygen (WorldManager::StartGame gets that ShipManager)",
		run_ship.env.room_o2(want[0]) <= 5.0, true)

	print("Systems added later (ShipManager::AddSystem: store purchase / event reward; start=\"false\" entries)")
	var st := ShipState.new("PLAYER_SHIP_STEALTH", true)
	check("Stealth A starts without shields", st.sys("shields") == null, true)
	check("buying shields installs them", RunStore.install_system(st, "shields"), true)
	var sv := ShipView.new()
	sv.ship = st
	check("Stealth A bought shields: blueprint img room_shields_2 (start=\"false\" entry)",
		ShipView.interior_image("shields", st.system_by_id("shields")), "room_shields_2")
	check("Stealth A bought shields: console glow on the manning slot",
		sv.console_art(st.sys("shields")).kind, "interior")
	check("Stealth A bought shields: listed with the ship's systems", st.system_list().has("shields"), true)
	var ld := ShipSave.restore(ShipSave.snapshot(st))
	sv.ship = ld
	check("after save / load: the bought shields keep their console", sv.console_art(ld.sys("shields")).kind,
		"interior")
	check("after save / load: listed with the ship's systems", ld.system_list().has("shields"), true)
	check("after save / load: the blueprint entry is the installed one",
		ShipView.interior_image("shields", ld.system_by_id("shields")), "room_shields_2")
	# A start="false" entry without img (Stealth A teleporter / battery, Kestrel A drones ...) gets the default.
	RunStore.install_system(st, "battery")
	check("Stealth A bought battery (no img) -> room_battery",
		ShipView.interior_image("battery", st.system_by_id("battery")), "room_battery")
	var ke := ShipState.new("PLAYER_SHIP_HARD", true)
	RunStore.install_system(ke, "drones")
	check("Kestrel A bought drones (no img): default room_drones image",
		ShipView.interior_image("drones", ke.system_by_id("drones")), "room_drones")
	sv.free()
	var again := ShipState.new("PLAYER_SHIP_STEALTH", true)
	check("installing on one ship leaves the blueprint of a new ship alone", again.sys("shields") == null
		and again.system_by_id("shields").is_empty(), true)
