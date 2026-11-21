extends Node
## Tests for the test-scenario setup (godot/data/test_ships.xml + the scenario lists of main.gd). Run:
##   godot --headless --path godot res://tests/test_test_ship.tscn

const Harness := preload("res://tests/harness.gd")

const Main := preload("res://scripts/main.gd")
const ALL_SYSTEMS := ["shields", "engines", "oxygen", "weapons", "drones", "medbay", "pilot", "sensors",
	"doors", "teleporter", "cloaking", "artillery", "battery", "mind", "hacking"]

var fails := 0


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func _columns(n: Node, out: Array) -> Array:
	for c in n.get_children():
		if c is SystemPowerColumn:
			out.append(c.system_id)
		_columns(c, out)
	return out


func check_ship(bp_name: String, expected: Array) -> void:
	print("\n%s" % bp_name)
	check("blueprint found", FtlData.has_ship_blueprint(bp_name), true)
	var s := ShipState.new(bp_name, true)
	check("layout fed_cruiser", s.blueprint.layout, "fed_cruiser")
	check("18 rooms", s.layout.rooms.size(), 18)
	var ids := s.systems.keys()
	ids.sort()
	var want := expected.duplicate()
	want.sort()
	check("installed systems", ids, want)
	var room_ids: Array = s.layout.rooms.map(func(r): return r.id)
	var rooms := {}
	for id in s.systems:
		var sys: SystemState = s.systems[id]
		if not room_ids.has(sys.room):
			check("%s room %d exists" % [id, sys.room], false, true)
		if rooms.has(sys.room):
			check("%s room %d shared with %s" % [id, sys.room, rooms[sys.room]], false, true)
		rooms[sys.room] = id
	check("each system in its own valid room", rooms.size(), expected.size())
	check("reactor 25", s.reactor_max, 25)
	check("4 weapons loaded", s.weapons.size(), 4)
	check("4 weapon mounts at least", s.mounts.size() >= 4, true)
	check("drone slots 3", s.blueprint.drone_slots, 3)
	check("6 crew", s.crew.size(), 6)
	var races := {}
	for c in s.crew:
		races[c.race] = true
	check("6 different races", races.size(), 6)
	# Interior images: only the ones the blueprint gives, and they must exist.
	for b in s.blueprint.systems:
		if b.img != "":
			check("interior %s exists" % b.img, FtlData.texture("img/ship/interior/" + b.img + ".png") != null, true)
	# Every system: symbol icon, damage, ion, repair; reactor systems take power.
	for id in s.systems:
		var sys: SystemState = s.systems[id]
		if sys.symbol_texture(0.0) == null or FtlData.texture("img/icons/s_%s_overlay.png" % id) == null:
			check("%s icons" % id, false, true)
	var ok_power := true
	var ok_hits := true
	for id in s.systems:
		var sys: SystemState = s.systems[id]
		# Weapons and drones are powered per weapon / per drone (drones: tests/test_drones.gd).
		if sys.uses_reactor() and id != "weapons" and id != "drones":
			# Free the reactor, then one bar must go in.
			for other in s.systems:
				while s.decrease_power(other):
					pass
			for w in s.weapons:
				s.depower_weapon(w)
			if s.increase_power(id) != "ok" or sys.power != (2 if id == "shields" else 1):
				ok_power = false
				print("    power refused: ", id)
		s.damage_system(id, 1)
		var dmg_ok := sys.damage == 1
		s.ion_system(id, 1)
		var ion_ok := sys.ion == 1
		s.repair_system(id, 1)
		sys.ion = 0
		if not (dmg_ok and ion_ok and sys.damage == 0):
			ok_hits = false
			print("    damage/ion/repair failed: ", id)
	check("every reactor system accepts power", ok_power, true)
	check("every system can be damaged, ionized and repaired", ok_hits, true)
	# Manning bonus only where FTL allows it.
	check("drones not boostable", s.is_boostable("drones"), false)
	check("sensors boostable", s.is_boostable("sensors"), true)
	# Systems bar: one column per system except weapons (which has the weapon panel's column).
	var bar := SystemsBar.new()
	bar.setup(s)
	var cols: Array = _columns(bar, [])
	check("systems bar columns", cols.size(), expected.size() - 1)
	check("  no weapons column in the bar", cols.has("weapons"), false)
	var subs: Array = cols.slice(cols.size() - 4)
	check("  subsystems last (pilot, sensors, doors, battery)", subs, ["pilot", "sensors", "doors", "battery"])
	bar.free()


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	check_ship("TEST_SHIP_ALL", ALL_SYSTEMS)
	var clone := ALL_SYSTEMS.duplicate()
	clone.erase("medbay")
	clone.append("clonebay")
	check_ship("TEST_SHIP_ALL_CLONE", clone)

	print("\nScenario lists")
	for n in Main.PLAYER_SHIPS:
		check("player ship %s exists" % n, FtlData.has_ship_blueprint(n), true)
	for n in Main.ENEMY_SHIPS:
		var e := ShipState.new(n, false)
		var ok: bool = e.layout.rooms.size() > 0 and e.max_hull > 0 and e.sys("weapons") != null
		var hull := FtlData.first_texture(["img/ships_glow/" + e.blueprint.img + "_base.png",
			"img/ship/" + e.blueprint.img + "_base.png"])
		check("enemy %s loads (rooms %d, hull %d, weapons %s, image)" % [n, e.layout.rooms.size(), e.max_hull,
			str(e.weapons.map(func(w): return w.bp.name))], ok and hull != null and e.weapons.size() > 0, true)
	for preset in Main.WEAPON_PRESETS:
		var missing := []
		for w in Main.WEAPON_PRESETS[preset]:
			if FtlData.weapon_blueprint(w).is_empty():
				missing.append(w)
		check("preset %s: every weapon exists" % preset, missing, [])

	print("\nPreset replaces the test ship weapons")
	var m := Main.new()
	var s := ShipState.new("TEST_SHIP_ALL", true)
	var free_before := s.reactor_free() + s.weapons_power_used()
	m._replace_weapons(s, Main.WEAPON_PRESETS["Beams"])
	check("4 beams loaded", s.weapons.map(func(w): return w.bp.name), Main.WEAPON_PRESETS["Beams"])
	check("weapons level stays 8", s.sys("weapons").get_level(), 8)
	check("reactor not inflated", s.reactor_max, 25)
	check("reactor accounting consistent", s.reactor_free() + s.weapons_power_used(), free_before)
	m.free()

