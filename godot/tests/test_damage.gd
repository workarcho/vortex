extends Node
## Tests for rules/damage.md. Run:
##   godot --headless --path godot res://tests/test_damage.tscn

const Harness := preload("res://tests/harness.gd")

var fails := 0
var rng := RandomNumberGenerator.new()


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func dmg(weapon_name: String) -> Damage:
	return Damage.from_weapon(FtlData.weapon_blueprint(weapon_name))


func crew_hp_in(s: ShipState, room: int) -> float:
	for c in s.crew:
		if c.room == room:
			return c.hp
	return -1.0


## A ship room without a system.
func empty_room(s: ShipState) -> int:
	for r in s.layout.rooms:
		if s.system_in_room(r.id) == null:
			return r.id
	return -1


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	rng.seed = 1

	print("Normal laser (Burst II) in the manned piloting room")
	var s := ShipState.new("PLAYER_SHIP_HARD", true)
	var pilot := s.sys("pilot").room
	var r := s.apply_damage(pilot, dmg("LASER_BURST_3"), rng)
	check("hull", s.hull, 29)
	check("piloting system damaged", s.sys("pilot").damage, 1)
	check("crew 100 -> 85", crew_hp_in(s, pilot), 85.0)

	print("BOMB_1: system and crew, NOT hull")
	s = ShipState.new("PLAYER_SHIP_HARD", true)
	var wroom := s.sys("weapons").room
	r = s.apply_damage(wroom, dmg("BOMB_1"), rng)
	check("hull intact", s.hull, 30)
	check("weapons -2 bars", s.sys("weapons").damage, 2)
	check("crew 100 -> 70", crew_hp_in(s, wroom), 70.0)

	print("BOMB_HEAL: heals crew")
	s.apply_damage(wroom, dmg("BOMB_HEAL"), rng)
	check("crew back to 100 (cap)", crew_hp_in(s, wroom), 100.0)

	print("LASER_HULL_1 (hullBust): x2 only in a room without a system")
	s = ShipState.new("PLAYER_SHIP_HARD", true)
	s.apply_damage(empty_room(s), dmg("LASER_HULL_1"), rng)
	check("empty room: hull -2", s.hull, 28)
	s = ShipState.new("PLAYER_SHIP_HARD", true)
	s.apply_damage(s.sys("engines").room, dmg("LASER_HULL_1"), rng)
	check("room with system: hull -1", s.hull, 29)
	check("  engines -1", s.sys("engines").damage, 1)

	print("ION_1: only ion to the room's system")
	s = ShipState.new("PLAYER_SHIP_HARD", true)
	s.apply_damage(s.sys("engines").room, dmg("ION_1"), rng)
	check("hull intact", s.hull, 30)
	check("engines undamaged", s.sys("engines").damage, 0)
	check("engines ionized", s.sys("engines").ion, 1)
	check("engines power 1 (startup) -> 0", s.sys("engines").power, 0)

	print("ION_1 absorbed by shield: no layer lost to damage, but shields get ionized")
	s = ShipState.new("PLAYER_SHIP_HARD", true)
	var res := s.on_projectile_enters_shield(dmg("ION_1"), RandomNumberGenerator.new())
	if res == "shield":
		s.shield_absorb(dmg("ION_1"))
	check("  shields ionized (unless dodged)", s.sys("shields").ion > 0 or res == "miss", true)

	print("Fire and breach: mutually exclusive, per hit")
	s = ShipState.new("PLAYER_SHIP_HARD", true)
	var er := empty_room(s)
	r = s.apply_damage(er, dmg("BOMB_FIRE"), rng)
	check("BOMB_FIRE (fire 10): fire", r.fire, true)
	check("  no breach", r.breach, false)
	check("  1 or 2 tiles on fire", s.fires[er].size() in [1, 2], true)
	s = ShipState.new("PLAYER_SHIP_HARD", true)
	r = s.apply_damage(er, dmg("BOMB_BREACH_1"), rng)
	check("BOMB_BREACH_1 (breach 10): breach", r.breach, true)
	check("  1 breached tile", s.breaches[er].size(), 1)

	print("Probability: Burst II (fire 1 = 10%) over 10,000 hits")
	var fires := 0
	for i in 10000:
		s = ShipState.new("PLAYER_SHIP_HARD", true) if i % 500 == 0 else s
		s.fires.clear()
		if s.apply_damage(er, dmg("LASER_BURST_3"), rng).fire:
			fires += 1
		s.hull = s.max_hull
	check("  fire ~10% (9-11%)", fires >= 900 and fires <= 1100, true)
	print("  (%d fires started)" % fires)

