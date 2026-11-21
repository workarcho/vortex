extends Node
## Tests for rules/ship_destruction.md (hull 0 trigger, explosion timeline, gibs, what freezes, KillEveryone,
## projectiles on the wreck). Run:
##   godot --headless --path godot res://tests/test_destruction.tscn

const Harness := preload("res://tests/harness.gd")

const DT := 1.0 / 60.0

var fails := 0


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func near(name: String, got: float, want: float, tol := 0.05) -> void:
	check("%s ~= %.3f [%.3f]" % [name, want, got], absf(got - want) <= tol, true)


func space(ship: ShipState) -> Space:
	var sp := Space.new()
	add_child(sp)  # in the tree first: setup() makes its camera current
	sp.setup(ship)
	return sp


func make_combat(player: ShipState, enemy: ShipState) -> Combat:
	var cb := Combat.new()
	var ps := space(player)
	var es := space(enemy)
	cb.add_space(ps, es)
	cb.add_space(es, ps)
	return cb


func run_combat(cb: Combat, seconds: float) -> void:
	var t := 0.0
	while t < seconds - 1e-6:
		cb._physics_process(DT)
		t += DT


func run(s: ShipState, seconds: float) -> void:
	var t := 0.0
	while t < seconds - 1e-6:
		s.tick(DT * GameClock.BASE)
		t += DT


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	FtlData.muted = true
	test_gib_data()
	test_timeline()
	test_frozen_and_hooks()
	test_kill_everyone()
	test_projectiles_on_wreck()


func test_gib_data() -> void:
	print("Gibs from the layout xml (§3.1)")
	var g := FtlData.ship_explosion("kestral")
	check("kestral: 6 gibs", g.size(), 6)
	check("  gib1 x, y", g[0].pos, Vector2(-5, 114))
	check("  gib1 velocity / direction / angular", [g[0].velocity, g[0].direction, g[0].angular],
		[Vector2(0.6, 1), Vector2(60, 120), Vector2(-0.4, -0.1)])
	check("rebel_squat: 4 gibs (glowOffset children ignored)", FtlData.ship_explosion("rebel_squat").size(), 4)
	var ex := ShipExplosion.new("kestral", "kestral", true)
	check("player ship: 6 s", ex.duration, ShipExplosion.PLAYER_TIME)
	check("enemy ship: 3 s", ShipExplosion.new("rebel_squat", "rebel_squat", false).duration, 3.0)
	check("gib textures found (img/ship/kestral_gibN.png)", ex.gibs.all(func(x): return x.tex != null), true)
	check("enemy gibs from ships_glow", ShipExplosion.new("rebel_squat", "rebel_squat", false).gibs.all(
		func(x): return x.tex != null), true)
	# Ranges: speed = [0.6, 1] x 2.5 px per factor unit, direction 270 - [60, 120] = [150, 210] deg.
	var ok_speed := true
	var ok_dir := true
	var ok_rot := true
	for k in 200:
		var e2 := ShipExplosion.new("kestral", "kestral", true)
		var g1: Dictionary = e2.gibs[0]
		var sp: float = g1.vel.length()
		ok_speed = ok_speed and sp >= 1.5 - 1e-4 and sp <= 2.5 + 1e-4
		var a := fposmod(rad_to_deg(g1.vel.angle()), 360.0)
		ok_dir = ok_dir and a >= 150.0 - 0.01 and a <= 210.0 + 0.01
		ok_rot = ok_rot and g1.rot_speed >= -0.2 - 1e-6 and g1.rot_speed <= -0.05 + 1e-6
	check("  gib1 speed in [1.5, 2.5] px/factor (velocity x 2.5)", ok_speed, true)
	check("  gib1 heading in [150, 210] deg (270 - direction: moves left)", ok_dir, true)
	check("  gib1 rotation speed in [-0.2, -0.05] deg/factor (angular x 0.5)", ok_rot, true)


func test_timeline() -> void:
	print("\nTimeline (§3.2): crackle 0-1.5 s, boom, gibs move, done at 3 s")
	var e := ShipState.new("REBEL_FAT", false)
	e.hull = 0
	run(e, DT)
	var ex := e.explosion
	check("hull 0: explosion started", [ex != null, ex.running, ex.done], [true, true, false])
	var start: Array = ex.gibs.map(func(g): return g.pos)
	run(e, 0.5)
	check("burning: small explosions spawned", ex.anims.size() > 0, true)
	check("  no boom yet, gibs still", [ex.final_boom, ex.gibs.map(func(g): return g.pos) == start], [false, true])
	check("  at most 25 alive", ex.anims.size() <= ShipExplosion.MAX_SMALL, true)
	run(e, 1.05)  # t ~ 1.57
	check("after 1.5 s: final boom (hull hidden)", ex.final_boom, true)
	var big := ex.anims.filter(func(a): return a.scale == ShipExplosion.BOOM_SCALE)
	check("  2 or 3 boom explosions at scale 2", big.size() in [2, 3], true)
	run(e, 0.5)
	var moved := false
	for i in ex.gibs.size():
		moved = moved or ex.gibs[i].pos != start[i]
	check("  gibs drifting", moved, true)
	# Gib speed: velocity x 2.5 px per factor unit = x 40 px/s.
	var g0: Dictionary = ex.gibs[0]
	var before: Vector2 = g0.pos
	run(e, 0.25)
	near("  gib1 displacement over 0.25 s = |vel| x 16 x 0.25", (g0.pos - before).length(),
		g0.vel.length() * 16.0 * 0.25, 0.5)
	check("not done before 3 s", [ex.done, e.destroyed_done()], [false, false])
	run(e, 0.8)  # t ~ 3.1
	check("done after 3 s (DestroyedDone)", [ex.done, e.destroyed_done()], [true, true])
	var frozen: Vector2 = g0.pos
	run(e, 0.5)
	check("  gibs frozen once done", g0.pos, frozen)
	var p := ShipState.new("PLAYER_SHIP_HARD", true)
	p.hull = 0
	run(p, 3.2)
	check("player ship: not done at 3.2 s", p.destroyed_done(), false)
	run(p, 3.0)
	check("  done at 6 s", p.destroyed_done(), true)


func test_frozen_and_hooks() -> void:
	print("\nDying ship frozen, ShipDestroyed hooks (§2, §5)")
	var p := ShipState.new("PLAYER_SHIP_HARD", true)
	var e := ShipState.new("REBEL_FAT", false)
	var cb := make_combat(p, e)
	run_combat(cb, 2.0)
	var w: WeaponState = e.weapons[0] if not e.weapons.is_empty() else null
	check("enemy shields up before", e.shield_layers > 0, true)
	e.hull = 0
	run_combat(cb, DT)
	check("weapons unpowered", e.weapons.all(func(x): return not x.powered), true)
	check("shields: power 0, no layers", [e.sys("shields").power, e.shield_layers], [0, 0])
	var c := e.crew[0]
	var pos := c.pos
	var hp := c.hp
	c.hp = hp - 10.0
	var o2: float = e.env.oxygen.get(c.room, 0.0)
	run_combat(cb, 1.0)
	check("crew alive and frozen (no walk, no heal)", [c.is_alive(), c.pos, c.hp], [true, pos, hp - 10.0])
	check("oxygen frozen", e.env.oxygen.get(c.room, 0.0), o2)
	if w:
		check("weapon charge frozen", w.powered, false)
	check("player weapons drop the target", p.weapons.all(func(x): return not x.has_target()), true)


func test_kill_everyone() -> void:
	print("\nKillEveryone when the explosion is over (§5, §6)")
	var p := ShipState.new("PLAYER_SHIP_HARD", true)
	var e := ShipState.new("REBEL_FAT", false)
	var cb := make_combat(p, e)
	# A player boarder aboard the enemy, an enemy boarder aboard the player ship.
	var mine := p.crew[0]
	p.crew.erase(mine)
	e.crew.append(mine)
	mine.place(e, e.layout.rooms[0].id, 0)
	var theirs := e.crew[0]
	e.crew.erase(theirs)
	p.crew.append(theirs)
	theirs.place(p, p.layout.rooms[0].id, 0)
	p.crew_changed()
	e.crew_changed()
	e.hull = 0
	run_combat(cb, 1.0)
	check("during the explosion everyone aboard lives", e.crew.all(func(x): return x.is_alive()), true)
	run_combat(cb, 2.2)
	check("explosion done: everyone aboard the wreck dead (incl. our boarder)",
		[e.crew.all(func(x): return not x.is_alive()), mine.is_alive()], [true, false])
	check("enemy boarder on the player ship survives", theirs.is_alive(), true)
	p.hull = 0
	run_combat(cb, 7.0)
	check("player ship done: its crew is not killed (game over instead)", p.destroyed_done() and
		p.crew.any(func(x): return x.is_alive() and x.player_owned), true)


func test_projectiles_on_wreck() -> void:
	print("\nProjectiles in flight still hit the wreck until it is done (§2)")
	var p := ShipState.new("PLAYER_SHIP_HARD", true)
	var e := ShipState.new("REBEL_FAT", false)
	var cb := make_combat(p, e)
	e.hull = 0
	run_combat(cb, DT)
	check("dying ship: no evasion, no shield layers", [e.dodge_factor(), e.shield_layers], [0, 0])
	var d := Damage.new()
	d.damage = 1
	check("a shot reaching the shield passes", e.on_projectile_enters_shield(d, RandomNumberGenerator.new()), "pass")
	check("its hit changes nothing (hull stays 0)", [e.apply_damage(e.layout.rooms[0].id, d,
		RandomNumberGenerator.new()).hull, e.hull], [0, 0])
