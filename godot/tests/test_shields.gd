extends Node
## Tests for rules/weapon_visuals.md "Shield bubble animations" (scale-in trigger/timing, shieldsUp /
## shieldsDown sounds, layer-pop dissolve, super-shield wave). Run:
##   godot --headless --path godot res://tests/test_shields.tscn

const Harness := preload("res://tests/harness.gd")

const F := 0.25  # clock factor per step (1/64 s)

var fails := 0
var rng := RandomNumberGenerator.new()


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func near(name: String, got: float, want: float, eps := 0.02) -> void:
	check(name + " ≈ %s" % want, absf(got - want) <= eps, true)


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	FtlData.muted = true
	rng.seed = 99
	test_spawn()
	test_scale_in()
	test_collapse()
	test_pop()
	test_super()
	test_ellipse_and_bubbles()


## Ticks the ship until `cond` holds (max `limit` s); returns the seconds spent.
func run_until(s: ShipState, cond: Callable, limit := 30.0) -> float:
	var t := 0.0
	while not cond.call() and t < limit:
		s.tick(F)
		t += F / GameClock.BASE
	return t


func test_spawn() -> void:
	print("Spawn / InstantCharge: full size, no sound")
	var me := ShipState.new("PLAYER_SHIP_HARD", true)
	check("Kestrel starts with 1 layer", me.shield_layers, 1)
	check("scale 1 at spawn", me.shield_up_scale(), 1.0)
	check("no sound at spawn", me.shield_sounds, [] as Array[String])
	var e := ShipState.new("REBEL_FAT", false)
	e.set_shield_layers_max(2)
	check("InstantCharge: scale 1", e.shield_up_scale(), 1.0)
	check("InstantCharge: no sound", e.shield_sounds.size(), 0)


func test_scale_in() -> void:
	print("Scale-in when the first layer charges")
	var me := ShipState.new("PLAYER_SHIP_HARD", true)
	me.decrease_power("shields")
	check("depowered: 0 layers", me.shield_layers, 0)
	check("depower with a layer up: shieldsDown", me.shield_sounds, ["shieldsDown"] as Array[String])
	me.shield_sounds.clear()
	me.increase_power("shields")
	check("repowered: still 0 layers", me.shield_layers, 0)
	run_until(me, func(): return me.shield_layers > 0)
	check("layer 0 -> 1: shieldsUp sound", me.shield_sounds, ["shieldsUp"] as Array[String])
	check("grow starts at scale 0", me.shield_up_scale() < 0.15, true)
	var t := run_until(me, func(): return me.shield_up_scale() >= 1.0)
	near("grow lasts 0.15 s", t, ShipState.SHIELD_UP_TIME, 0.02)
	# Half-way: linear.
	me.shield_up_t = 0.0
	run_until(me, func(): return me.shield_up_t >= 0.075)
	near("linear: scale 0.5 at 0.075 s", me.shield_up_scale(), 0.5, 0.05)
	print("No grow / sound for layer 1 -> 2")
	var e := ShipState.new("REBEL_FAT", false)
	e.set_shield_layers_max(2)
	e.shield_layers = 1
	run_until(e, func(): return e.shield_layers >= 2)
	check("1 -> 2: no sound", e.shield_sounds.size(), 0)
	check("1 -> 2: scale stays 1", e.shield_up_scale(), 1.0)
	print("Never started (spawned with 0 layers): scale 0")
	var z := ShipState.new("REBEL_FAT", false)
	z.set_shield_layers_max(1)
	z.shield_up_t = -1.0
	z.shield_layers = 0
	check("never started: scale 0", z.shield_up_scale(), 0.0)


func test_collapse() -> void:
	print("Max layers drop to 0")
	var me := ShipState.new("PLAYER_SHIP_HARD", true)
	me.ion_system("shields", 1)
	check("ion below 2 bars: 0 layers", me.shield_layers, 0)
	check("ion collapse: shieldsDown", me.shield_sounds, ["shieldsDown"] as Array[String])
	me.shield_sounds.clear()
	me.ion_system("shields", 1)
	check("already 0 layers: no sound", me.shield_sounds.size(), 0)
	# Ion wears off -> power back -> recharge from 0 -> grow + shieldsUp.
	run_until(me, func(): return me.shield_layers > 0, 60.0)
	check("after the ion: layer back", me.shield_layers, 1)
	check("after the ion: shieldsUp", me.shield_sounds, ["shieldsUp"] as Array[String])
	check("after the ion: grow running", me.shield_up_scale() < 1.0, true)
	print("Hack drain to 0: no sound")
	var e := ShipState.new("REBEL_FAT", false)
	e.set_shield_layers_max(1)
	var sh := e.sys("shields")
	sh.hacked = true
	run_until(e, func(): return e.shield_layers == 0, 10.0)
	check("hack drained the layer", e.shield_layers, 0)
	check("hack drain: no sound", e.shield_sounds.size(), 0)


func test_pop() -> void:
	print("Layer popped by a shot")
	var me := ShipState.new("PLAYER_SHIP_HARD", true)
	for s in me.systems.values():
		if s.id == "engines" or s.id == "pilot":
			s.power = 0
	me.set_shield_layers_max(2)
	var d := Damage.new()
	d.damage = 1
	var hit := me.shield_center + Vector2(me.shield_axes.x, 0)
	check("2 layers: absorbed", me.on_projectile_enters_shield(d, rng, hit), "shield")
	check("pop leaves 1 layer: no shieldsDown", me.shield_sounds.size(), 0)
	check("dissolve started at the hit point", [me.shield_down_t, me.shield_down_point], [0.0, hit])
	check("normal layer ghost", me.shield_down_super, false)
	var t := run_until(me, func(): return me.shield_down_t < 0.0)
	near("dissolve lasts 0.5 s", t, ShipState.SHIELD_DOWN_TIME, 0.02)
	check("last layer: absorbed", me.on_projectile_enters_shield(d, rng, hit), "shield")
	check("last layer popped: shieldsDown", me.shield_sounds, ["shieldsDown"] as Array[String])
	check("no scale-out on a pop: scale stays 1", me.shield_up_scale(), 1.0)
	var ion := Damage.new()
	ion.ion = 1
	me.set_shield_layers_max(1)
	me.shield_sounds.clear()
	me.shield_down_t = -1.0
	me.on_projectile_enters_shield(ion, rng, hit)
	check("ion-only hit removes no layer: no dissolve", me.shield_down_t, -1.0)


func test_super() -> void:
	print("Super shield")
	var me := ShipState.new("PLAYER_SHIP_HARD", true)
	for s in me.systems.values():
		if s.id == "engines" or s.id == "pilot":
			s.power = 0
	var loc := Vector2(123, 45)
	me.add_super_shield(loc)
	check("wave starts at the drone", [me.super_up_t, me.super_up_loc], [0.0, loc])
	var t := run_until(me, func(): return me.super_up_t < 0.0)
	near("wave lasts 0.5 s", t, ShipState.SUPER_UP_TIME, 0.02)
	me.add_super_shield()
	check("no location: no wave", me.super_up_t, -1.0)
	me.shield_layers = 0
	var d := Damage.new()
	d.damage = 1
	check("super hit", me.on_projectile_enters_shield(d, rng, loc), "super")
	check("super hit with 0 normal layers: shieldsDown", me.shield_sounds, ["shieldsDown"] as Array[String])
	check("super ghost", me.shield_down_super, true)


## Ship::GetBaseEllipse (enemy centre + 110) and the TARGET window bubble images.
func test_ellipse_and_bubbles() -> void:
	print("Shield ellipse centre and enemy bubble images")
	var e := ShipState.new("REBEL_FAT", false)
	var b := e.rooms_bounds()
	var lay: Vector4 = e.layout.ellipse
	check("enemy ellipse centre = rooms centre + layout offset + (0, 110)", e.shield_center,
		Vector2(floorf(b.position.x + b.size.x / 2), floorf(b.position.y + b.size.y / 2)) + Vector2(lay.z, lay.w + 110))
	var p := ShipState.new("PLAYER_SHIP_HARD", true)
	var pb := p.rooms_bounds()
	var pl: Vector4 = p.layout.ellipse
	check("player ellipse: no +110", p.shield_center,
		Vector2(floorf(pb.position.x + pb.size.x / 2), floorf(pb.position.y + pb.size.y / 2)) + Vector2(pl.z, pl.w))
	check("charged layer = filled bubble (shield1)", EnemyWindow.shield_image(true, false), "box_hostiles_shield1")
	check("missing layer = empty ring (shield2)", EnemyWindow.shield_image(false, false), "box_hostiles_shield2")
	check("hacked charged = purple filled", EnemyWindow.shield_image(true, true), "box_hostiles_shield2_hacked_charged")
