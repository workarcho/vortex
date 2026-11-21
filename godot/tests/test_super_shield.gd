extends Node
## Tests for the Zoltan super shield (rules/augments.md §3, rules/drones.md §7): ENERGY_SHIELD fill on the first
## frame, no recharge in a fight, refill on jumps, neutral drain, InstantCharge, flagship 12, hits (damage, ion,
## ION_ARMOR, pure stun), blocks (teleporter, hacking), ZOLTAN_BYPASS, drone reconciliation. Run:
##   godot --headless --path godot res://tests/test_super_shield.tscn

const Harness := preload("res://tests/harness.gd")

const F := 0.25

var fails := 0
var rng := RandomNumberGenerator.new()


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	FtlData.muted = true
	rng.seed = 5
	test_fill()
	test_hits()
	test_jump()
	test_neutral_and_spawn()
	test_drone_and_flagship()
	test_blocks()


func zoltan() -> ShipState:
	return ShipState.new("PLAYER_SHIP_ENERGY", true)


## Shot that crosses the shield (dodges skipped).
func shoot(s: ShipState, d: Damage) -> String:
	var r := "miss"
	for i in 100:
		r = s.on_projectile_enters_shield(d, rng)
		if r != "miss":
			return r
	return r


func test_fill() -> void:
	print("ENERGY_SHIELD: 5 points on the first frame, value 2 ignored")
	var s := zoltan()
	check("Zoltan cruiser has ENERGY_SHIELD", AugmentRule.has(s, "ENERGY_SHIELD"), true)
	check("before the first frame: 0", s.super_shield, 0)
	s.tick(F)
	check("first frame: 5", [s.super_shield, s.super_shield_max], [5, 5])
	check("shields system power irrelevant", s.sys("shields") != null, true)
	var k := ShipState.new("PLAYER_SHIP_HARD", true)
	k.tick(F)
	check("Kestrel: none", k.super_shield, 0)


func test_hits() -> void:
	print("Hits: damage removes points, ion x2, pure stun absorbed, no recharge")
	var s := zoltan()
	s.tick(F)
	var layers := s.shield_layers
	var d := Damage.new()
	d.damage = 1
	check("laser absorbed by the super shield", shoot(s, d), "super")
	check("5 -> 4", s.super_shield, 4)
	check("normal layers untouched", s.shield_layers, layers)
	check("green number total", s.last_super_hit.total, 1)
	var d2 := Damage.new()
	d2.damage = 2
	d2.shield_piercing = 5
	shoot(s, d2)
	check("piercing ignored: 4 -> 2", s.super_shield, 2)
	var ion := Damage.new()
	ion.ion = 1
	shoot(s, ion)
	check("ion counts double: 2 -> 0", s.super_shield, 0)
	var after := Damage.new()
	after.damage = 1
	check("no points: shots go to normal shields", shoot(s, after) in ["shield", "pass"], true)
	for i in 64 * 60:
		s.tick(F)
	check("no recharge in a fight (60 s)", s.super_shield, 0)
	var t := zoltan()
	t.tick(F)
	var stun := Damage.new()
	stun.stun_chance = 10
	check("pure stun absorbed", shoot(t, stun), "super")
	check("no point lost", t.super_shield, 5)
	check("bubble alpha 5/5", SuperShieldRule.alpha(t), 1.0)


func test_jump() -> void:
	print("Jump: refill to 5 with ENERGY_SHIELD, drone super shield lost")
	var run := RunState.new_run(4, "PLAYER_SHIP_ENERGY")
	run.ship.tick(F)
	run.ship.super_shield = 1
	run._clear_location()
	check("jump refills the Zoltan cruiser", run.ship.super_shield, 5)
	var k := ShipState.new("PLAYER_SHIP_HARD", true)
	k.add_super_shield()
	k.add_super_shield()
	check("drone made 2", k.super_shield, 2)
	SuperShieldRule.jump(k)
	check("drone super shield lost on jump", k.super_shield, 0)


func test_neutral_and_spawn() -> void:
	print("Neutral / surrendered enemy shows 0; InstantCharge; easy-mode removal")
	var e := ShipState.new("ZOLTAN_FIGHTER", false)
	var ai := ShipAI.new(e, rng)
	ai.hostile = false
	e.tick(F)
	ai.tick(F / GameClock.BASE)
	check("neutral: drained the same frame", e.super_shield, 0)
	e.tick(F)
	check("refilled by its own loop next frame", e.super_shield, 5)
	ai.tick(F / GameClock.BASE)
	check("and drained again by its AI", e.super_shield, 0)
	ai.hostile = true
	e.tick(F)
	ai.tick(F / GameClock.BASE)
	check("turns hostile: 5", e.super_shield, 5)
	var g := ShipState.new("ZOLTAN_FIGHTER", false)
	SuperShieldRule.instant_charge(g)
	check("InstantCharge at creation: 5", g.super_shield, 5)
	var plan := {"augments_removed": ["ENERGY_SHIELD"]}
	var h := ShipState.new("ZOLTAN_FIGHTER", false)
	for id in plan.augments_removed:
		AugmentRule.remove(h, id)
	h.tick(F)
	check("easy sector: ENERGY_SHIELD removed -> 0", h.super_shield, 0)
	var dead := ShipState.new("ZOLTAN_FIGHTER", false)
	var dai := ShipAI.new(dead, rng)
	dead.tick(F)
	dead.hull = 0
	dai.tick(F / GameClock.BASE)
	check("hull 0: drained", dead.super_shield, 0)


func test_drone_and_flagship() -> void:
	print("Shield drone on a Zoltan ship, flagship stage 3")
	var s := zoltan()
	s.tick(F)
	s.super_shield = 3
	s.add_super_shield()
	check("drone +1 (3 -> 4)", s.super_shield, 4)
	s.add_super_shield()
	s.add_super_shield()
	check("cap 5", s.super_shield, 5)
	var f := ShipState.new("REBEL_FAT", false)
	SuperShieldRule.flagship_stage(f, 2)
	check("stage 2: nothing", f.super_shield, 0)
	SuperShieldRule.flagship_stage(f, 3)
	check("stage 3: 12 points", [f.super_shield, f.super_shield_max], [12, 12])
	f.tick(F)
	check("not reset by the loop (no ENERGY_SHIELD)", f.super_shield, 12)
	check("alpha 12/12", SuperShieldRule.alpha(f), 1.0)


func test_blocks() -> void:
	print("Teleporter / hacking blocked; ZOLTAN_BYPASS")
	var me := ShipState.new("PLAYER_SHIP_HARD", true)
	var z := ShipState.new("ZOLTAN_FIGHTER", false)
	me.opponent = z
	z.opponent = me
	z.tick(F)
	check("teleporter send blocked", TeleporterRule.super_blocked(me, z), true)
	check("hacking blocked", HackingRule.blocked(me), true)
	AugmentRule.add(me, "ZOLTAN_BYPASS")
	check("bypass: teleporter allowed", TeleporterRule.super_blocked(me, z), false)
	check("bypass: bombs ignore it", AugmentRule.bypasses_super(me), true)
	check("enemy AI teleporter is not blocked", TeleporterRule.super_blocked(z, me), false)
