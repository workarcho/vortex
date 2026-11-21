extends Node
## Tests for rules/augments.md: the augment registry (count x value stacking, max 3, store reasons) and the
## numeric effect of every active vanilla augment. Super shield and event crew removal have their own scenes
## (test_super_shield.tscn, test_crew_removal.tscn). Run:
##   godot --headless --path godot res://tests/test_augments.tscn

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
	check(name + " ≈ %s (%.3f)" % [want, got], absf(got - want) <= eps, true)


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	FtlData.muted = true
	rng.seed = 7
	test_registry()
	test_stacking()
	test_resists()
	test_ion_armor()
	test_crystal()
	test_crew_rates()
	test_medbay_and_o2()
	test_repairs()
	test_scrap()
	test_charge_and_shields()
	test_jump_and_ftl()
	test_missiles()
	test_misc()


func kestrel() -> ShipState:
	var s := ShipState.new("PLAYER_SHIP_HARD", true)
	s.augments.clear()
	return s


## Ticks the ship until `cond` holds (max `limit` s); returns the seconds spent.
func run_until(s: ShipState, cond: Callable, limit := 60.0) -> float:
	var t := 0.0
	while not cond.call() and t < limit:
		s.tick(F)
		t += F / GameClock.BASE
	return t


func test_registry() -> void:
	print("Registry: 32 augments, values, stacking, max 3")
	check("32 active augments", AugmentRule.ALL.size(), 32)
	var missing := AugmentRule.ALL.filter(func(id): return FtlData.item_info("augment", id).is_empty())
	check("all have an <augBlueprint>", missing, [])
	check("1.f parses as 1.0 (FIRE_EXTINGUISHERS)", AugmentRule.data_value("FIRE_EXTINGUISHERS"), 1.0)
	check("TELEPORT_HEAL 1.f", AugmentRule.data_value("TELEPORT_HEAL"), 1.0)
	var s := kestrel()
	check("no augment: value 0", AugmentRule.value(s, "SCRAP_COLLECTOR"), 0.0)
	check("augment_value default without it", s.augment_value("BATTERY_BOOSTER", 1.0), 1.0)
	check("add 1", AugmentRule.add(s, "SCRAP_COLLECTOR"), true)
	near("SCRAP_COLLECTOR x1 = 0.1", AugmentRule.value(s, "SCRAP_COLLECTOR"), 0.1, 1e-6)
	check("stackable: can add a second", AugmentRule.can_add(s, "SCRAP_COLLECTOR"), "")
	AugmentRule.add(s, "SCRAP_COLLECTOR")
	check("count 2", AugmentRule.count(s, "SCRAP_COLLECTOR"), 2)
	near("SCRAP_COLLECTOR x2 = 0.2 (linear)", AugmentRule.value(s, "SCRAP_COLLECTOR"), 0.2, 1e-6)
	check("non-stackable owned: have_<id>", AugmentRule.can_add(s, "SCRAP_COLLECTOR") == "" and
		AugmentRule.can_add(s, "ROCK_ARMOR") == "", true)
	AugmentRule.add(s, "ROCK_ARMOR")
	check("3 augments: max_augments", AugmentRule.can_add(s, "FTL_BOOSTER"), "max_augments")
	check("4th refused (AddAugmentation)", AugmentRule.add(s, "FTL_BOOSTER"), false)
	check("still 3", s.augments.size(), 3)
	var t := kestrel()
	AugmentRule.add(t, "ROCK_ARMOR")
	check("non-stackable twice in the store: have_ROCK_ARMOR", AugmentRule.can_add(t, "ROCK_ARMOR"), "have_ROCK_ARMOR")
	# Enemies obey the same limit.
	var e := ShipState.new("ZOLTAN_FIGHTER", false)
	check("Zoltan fighter has ENERGY_SHIELD", AugmentRule.has(e, "ENERGY_SHIELD"), true)
	for id in ["ROCK_ARMOR", "O2_MASKS", "SLUG_GEL", "NANO_MEDBAY"]:
		AugmentRule.add(e, id)
	check("enemy capped at 3", e.augments.size(), 3)
	# Filter hook: mods may rebalance a value.
	var cb := func(v, _ship, id): return 0.5 if id == "SCRAP_COLLECTOR" else null
	Hooks.add_filter(&"augment_value", cb)
	check("augment_value filter", AugmentRule.value(s, "SCRAP_COLLECTOR"), 0.5)
	Hooks.remove_filter(&"augment_value", cb)
	# QoL "Start with scanners": the data patch puts ADV_SCANNERS in the player blueprint's <aug> list.
	var patched: String = load("res://mods/qol/qol.gd").add_scanners(
		"<shipBlueprint name=\"PLAYER_SHIP_X\" layout=\"x\">\n</shipBlueprint>")
	check("QoL scanners patch adds an <aug>", patched.contains("<aug name=\"ADV_SCANNERS\"/>"), true)



## rules/augments.md "Stacking": exactly the 6 <stackable> augments can be owned twice; the 5 with an effect
## scale linearly with the count; a non-stackable duplicate is refused by the store and by event rewards.
func test_stacking() -> void:
	print("Stacking: which augments stack and how")
	var want := ["ION_ARMOR", "SCRAP_COLLECTOR", "AUTO_COOLDOWN", "SHIELD_RECHARGE", "FTL_BOOSTER", "STASIS_POD"]
	var got := AugmentRule.ALL.filter(func(id): return AugmentRule.stackable(id))
	check("<stackable>true set", got, want)
	# Stacking augment: two FTL_BOOSTERs = x1.5 FTL charge (EngineSystem::GetEngineSpeed: 1 + 0.25 x count).
	var base := FtlDrive.engine_speed(kestrel())
	var b := kestrel()
	for i in 2:
		check("FTL_BOOSTER copy %d allowed" % (i + 1), AugmentRule.can_add(b, "FTL_BOOSTER"), "")
		AugmentRule.add(b, "FTL_BOOSTER")
	near("FTL_BOOSTER x2 -> x1.5", FtlDrive.engine_speed(b) / base, 1.5, 0.01)
	# ION_ARMOR: a third copy changes nothing (chance int(15) out of 10 = always, as with two).
	var ia := kestrel()
	for i in 3:
		AugmentRule.add(ia, "ION_ARMOR")
	check("ION_ARMOR x3 always", rate(2000, func(): return AugmentRule.ion_resist(ia, rng)), 1.0)
	# STASIS_POD: stackable, but no engine effect at any count.
	var sp := kestrel()
	AugmentRule.add(sp, "STASIS_POD")
	check("STASIS_POD stacks in the store", AugmentRule.can_add(sp, "STASIS_POD"), "")
	# Non-stacking duplicate: store refuses, event reward gives AUGMENT_FULL (25 scrap), nothing added.
	var run := RunState.new_run(5)
	run.ship.augments.clear()
	AugmentRule.add(run.ship, "CREW_STIMS")
	check("store: have_CREW_STIMS", AugmentRule.can_add(run.ship, "CREW_STIMS"), "have_CREW_STIMS")
	var sc := run.ship.scrap
	check("reward of an owned non-stackable -> AUGMENT_FULL 25 scrap",
		[run.give_item("augment", "CREW_STIMS"), run.ship.scrap - sc], [["scrap", 25], 25])
	check("still one CREW_STIMS", [AugmentRule.count(run.ship, "CREW_STIMS"), run.ship.augments.size()], [1, 1])
	near("its value is not doubled", AugmentRule.value(run.ship, "CREW_STIMS"), 0.25, 1e-6)
	check("reward of an owned stackable is installed", run.give_item("augment", "AUTO_COOLDOWN"),
		["augment", "AUTO_COOLDOWN"])
	check("second copy installed", run.give_item("augment", "AUTO_COOLDOWN"), ["augment", "AUTO_COOLDOWN"])
	near("AUTO_COOLDOWN x2 charge_mult 1.2", AugmentRule.charge_mult(run.ship), 1.2, 1e-6)

func rate(n: int, f: Callable) -> float:
	var k := 0
	for i in n:
		if f.call():
			k += 1
	return float(k) / n


func test_resists() -> void:
	print("ROCK_ARMOR / SYSTEM_CASING: 15 % resists, RESIST in the summary")
	var s := kestrel()
	AugmentRule.add(s, "ROCK_ARMOR")
	AugmentRule.add(s, "SYSTEM_CASING")
	near("ROCK_ARMOR rate 15 %", rate(20000, func(): return AugmentRule.resist(s, "ROCK_ARMOR", rng)), 0.15, 0.01)
	near("SYSTEM_CASING rate 15 %", rate(20000, func(): return AugmentRule.resist(s, "SYSTEM_CASING", rng)), 0.15, 0.01)
	var none := kestrel()
	check("no augment: never", AugmentRule.resist(none, "ROCK_ARMOR", rng), false)
	# Forced resist (7 copies = 105 %) through apply_damage: hull and system untouched.
	var f := kestrel()
	for i in 7:
		f.augments.append("ROCK_ARMOR")
		f.augments.append("SYSTEM_CASING")
	var d := Damage.new()
	d.damage = 2
	var room := f.sys("weapons").room
	var hull := f.hull
	var r := f.apply_damage(room, d, rng)
	check("rock armor: hull untouched", f.hull, hull)
	check("system casing: system untouched", f.sys("weapons").damage, 0)
	check("summary lists both resists", r.resisted.has("ROCK_ARMOR") and r.resisted.has("SYSTEM_CASING"), true)
	# Hull damage over many hits ≈ 85 %.
	var g := kestrel()
	AugmentRule.add(g, "ROCK_ARMOR")
	var lost := 0
	for i in 2000:
		g.hull = g.max_hull
		var d1 := Damage.new()
		d1.damage = 1
		g.apply_damage(g.sys("pilot").room, d1, rng)
		lost += g.max_hull - g.hull
	near("rock armor: 85 % of hits land", lost / 2000.0, 0.85, 0.03)
	# Beam: one roll per room entered.
	var b := kestrel()
	for i in 7:
		b.augments.append("ROCK_ARMOR")
	var db := Damage.new()
	db.damage = 1
	var c := b.room_rect(b.sys("shields").room).get_center()
	var rb := b.apply_beam(c, -1, -1, db, rng)
	check("beam resisted by rock armor", [rb.hull, rb.resisted.has("ROCK_ARMOR")], [0, true])


func test_ion_armor() -> void:
	print("ION_ARMOR: 50 % per copy, always with two (room, shield, super shield)")
	var s := kestrel()
	AugmentRule.add(s, "ION_ARMOR")
	near("one copy 50 %", rate(20000, func(): return AugmentRule.ion_resist(s, rng)), 0.5, 0.015)
	AugmentRule.add(s, "ION_ARMOR")
	check("two copies always", rate(2000, func(): return AugmentRule.ion_resist(s, rng)), 1.0)
	var d := Damage.new()
	d.ion = 1
	var r := s.apply_damage(s.sys("engines").room, d, rng)
	check("room ion resisted: system not ionized", [s.sys("engines").ion, r.ion, r.resisted], [0, 0, ["ION_ARMOR"]])
	# Shield hit: the layer is still popped by damage only; ion part ignored.
	s.shield_layers = 2
	var d2 := Damage.new()
	d2.ion = 2
	var res := ""
	for i in 50:  # skip dodges
		res = s.on_projectile_enters_shield(d2, rng)
		if res != "miss":
			break
	check("ion hit absorbed by the shield", res, "shield")
	s.shield_absorb(d2)
	check("shields not ionized", s.sys("shields").ion, 0)
	# Super shield: the ion term is 0 instead of 2 x ion.
	s.super_shield = 5
	s.super_shield_max = 5
	var h := SuperShieldRule.hit(s, d2, rng)
	check("super shield ion term 0 with ION_ARMOR", [h.lost, h.resisted, s.super_shield], [0, true, 5])
	var n := kestrel()
	n.super_shield = 5
	n.super_shield_max = 5
	check("without: 2 x ion", SuperShieldRule.hit(n, d2, rng).lost, 4)


func test_crystal() -> void:
	print("CRYSTAL_SHARDS: 10 % shard after a hull hit, needs a target")
	var s := kestrel()
	AugmentRule.add(s, "CRYSTAL_SHARDS")
	check("no target: never", AugmentRule.crystal_check(s, Vector2.ZERO, rng), false)
	s.opponent = ShipState.new("REBEL_FAT", false)
	near("rate 10 %", rate(20000, func(): return AugmentRule.crystal_check(s, Vector2.ZERO, rng)), 0.1, 0.01)
	check("shards queued", s.pending_shards.size() > 1500, true)
	s.pending_shards.clear()
	for i in 10:
		s.augments.append("CRYSTAL_SHARDS")  # forced (110 %)
	var d := Damage.new()
	d.damage = 1
	s.apply_damage(s.sys("pilot").room, d, rng)
	check("hull hit queues a shard", s.pending_shards.size(), 1)
	s.pending_shards.clear()
	var d0 := Damage.new()
	d0.ion = 1
	s.apply_damage(s.sys("pilot").room, d0, rng)
	check("no hull damage: no shard", s.pending_shards.size(), 0)


func test_crew_rates() -> void:
	print("CREW_STIMS / DRONE_SPEED: x1.25 move, 0.7 s walk cycle")
	var s := kestrel()
	var c: CrewMember = s.crew[0]
	check("no stims: x1", AugmentRule.move_mult(s, c), 1.0)
	AugmentRule.add(s, "CREW_STIMS")
	near("stims x1.25", AugmentRule.move_mult(s, c), 1.25, 1e-6)
	near("stims walk 0.7 s", AugmentRule.walk_time(s, c), 0.7, 1e-6)
	var dr := CrewMember.new("human", true)
	dr.make_drone("battle")
	check("drone not stimmed", AugmentRule.move_mult(s, dr), 1.0)
	AugmentRule.add(s, "DRONE_SPEED")
	near("DRONE_SPEED x1.25 for drones", AugmentRule.move_mult(s, dr), 1.25, 1e-6)
	check("drone walk cycle unchanged", AugmentRule.walk_time(s, dr), 1.0)
	# Walking distance in the simulation.
	var a := kestrel()
	var b := kestrel()
	AugmentRule.add(b, "CREW_STIMS")
	var target: int = a.sys("shields").room
	a.crew[0].move_to_room(a, target)
	b.crew[0].move_to_room(b, target)
	var ta := run_until(a, func(): return not a.crew[0].is_walking())
	var tb := run_until(b, func(): return not b.crew[0].is_walking())
	near("same walk in 1/1.25 of the time", tb / ta, 0.8, 0.03)
	# Crew uses its owner's augments aboard the enemy ship.
	var e := ShipState.new("REBEL_FAT", false)
	e.opponent = b
	check("owner of a boarder = its home ship", AugmentRule.crew_owner(e, b.crew[1]), b)


func test_medbay_and_o2() -> void:
	print("NANO_MEDBAY 0.25 outside the medbay, O2_MASKS halves suffocation")
	var s := ShipState.new("PLAYER_SHIP_HARD", true)
	s.augments.clear()
	AugmentRule.add(s, "NANO_MEDBAY")
	var c: CrewMember = s.crew[0]  # pilot, not in the medbay
	c.hp = 50.0
	MedbayRule.update(s)
	near("nano heal 0.25 x 6.4 = 1.6 HP/s", c.medbay_rate, 1.6, 1e-4)
	check("nano speed in the medbay room is 0", AugmentRule.nano_speed(s, s.sys("medbay").room), 0.0)
	s.sys("medbay").hacked = true
	check("hacked medbay: no nano", AugmentRule.nano_speed(s, c.room), 0.0)
	s.sys("medbay").hacked = false
	s.set_power_loss("medbay", 9)
	check("unpowered medbay still nano", AugmentRule.nano_speed(s, c.room), 0.25)
	var none := kestrel()
	none.crew[0].hp = 50.0
	MedbayRule.update(none)
	check("no augment: no heal outside", none.crew[0].medbay_rate, 0.0)
	# O2 masks.
	var hp_loss := func(masks: bool) -> float:
		var t := kestrel()
		if masks:
			AugmentRule.add(t, "O2_MASKS")
		var cc: CrewMember = t.crew[0]
		t.env.oxygen[cc.room] = 0.0
		t.env._tick_crew(1.0)
		return 100.0 - cc.hp
	near("no masks: 6.4 HP/s", hp_loss.call(false), 6.4, 1e-3)
	near("masks: 3.2 HP/s", hp_loss.call(true), 3.2, 1e-3)


func test_repairs() -> void:
	print("SLUG_GEL breach seals in ~16.7 s, FIRE_EXTINGUISHERS fire out in 12.5 s")
	var s := kestrel()
	AugmentRule.add(s, "SLUG_GEL")
	for c in s.crew:
		c.hp = 0.0  # nobody repairs
	s.crew.clear()
	var room: int = s.sys("weapons").room
	s.add_breach(room, 0)
	var t := run_until(s, func(): return s.breaches.is_empty(), 40.0)
	near("slug gel seal", t, 100.0 / 6.0, 0.1)
	var f := kestrel()
	AugmentRule.add(f, "FIRE_EXTINGUISHERS")
	f.crew.clear()
	var r2: int = f.sys("shields").room
	f.ignite(r2, 0)
	var t2 := run_until(f, func(): return not f.fires.get(r2, {}).has(0), 40.0)
	near("extinguishers: 12.5 s", t2, 12.5, 0.1)
	var g := kestrel()
	g.crew.clear()
	g.add_breach(room, 0)
	run_until(g, func(): return false, 20.0)
	check("no slug gel: breach stays", g.breaches.has(room), true)


func test_scrap() -> void:
	print("SCRAP_COLLECTOR +10 % per copy, REPAIR_ARM -15 % while damaged and +2 hull per gain")
	var s := kestrel()
	check("no augments: 10", AugmentRule.scrap_income(s, 10), 10)
	AugmentRule.add(s, "SCRAP_COLLECTOR")
	check("collector: 10 -> 11", AugmentRule.scrap_income(s, 10), 11)
	AugmentRule.add(s, "SCRAP_COLLECTOR")
	check("collector x2: 10 -> 12", AugmentRule.scrap_income(s, 10), 12)
	check("losses untouched", AugmentRule.scrap_income(s, -10), -10)
	var r := kestrel()
	AugmentRule.add(r, "REPAIR_ARM")
	check("repair arm at full hull: 20 (no penalty)", AugmentRule.scrap_income(r, 20), 20)
	check("hull stays at max", r.hull, r.max_hull)
	r.hull = r.max_hull - 5
	check("repair arm damaged: 20 -> 17", AugmentRule.scrap_income(r, 20), 17)
	check("+2 hull", r.hull, r.max_hull - 3)
	AugmentRule.add(r, "SCRAP_COLLECTOR")
	r.hull = 10
	check("both: 20 x 0.95 = 19", AugmentRule.scrap_income(r, 20), 19)
	# Through an event reward (RunState.apply_effects).
	var run := RunState.new()
	run.ship = kestrel()
	AugmentRule.add(run.ship, "SCRAP_COLLECTOR")
	var before := run.ship.scrap
	var ev := EventEngine.new(EventDB.new()).new_event("X")
	ev.res.scrap = 30
	var out := run.apply_effects(ev)
	check("event scrap 30 -> 33", run.ship.scrap - before, 33)
	check("reward line shows the real gain", out, [["scrap", 33]])


func test_charge_and_shields() -> void:
	print("AUTO_COOLDOWN +10 % weapon charge, SHIELD_RECHARGE +15 % layer charge")
	var charge_after := func(n: int) -> float:
		var s := kestrel()
		for i in n:
			AugmentRule.add(s, "AUTO_COOLDOWN")
		var w: WeaponState = s.weapons[0]
		s.try_power_weapon(w)
		w.charge = 0.0
		for i in 64:  # 1 s
			s.tick(F)
		return w.charge
	near("1 s -> 1.0 s of charge", charge_after.call(0), 1.0, 0.01)
	near("x1 -> 1.1", charge_after.call(1), 1.1, 0.01)
	near("x2 -> 1.2", charge_after.call(2), 1.2, 0.01)
	var shield_time := func(n: int) -> float:
		var s := kestrel()
		for i in n:
			AugmentRule.add(s, "SHIELD_RECHARGE")
		s.shield_layers = 0
		s.shield_charger = 0.0
		return run_until(s, func(): return s.shield_layers >= 1, 10.0)
	var t0: float = shield_time.call(0)
	near("shield recharge x1.15 faster", t0 / shield_time.call(1), 1.15, 0.03)
	near("x2: x1.30", t0 / shield_time.call(2), 1.30, 0.03)
	# Artillery charge uses the same multiplier (ArtilleryRule.tick).
	var a := kestrel()
	AugmentRule.add(a, "AUTO_COOLDOWN")
	AugmentRule.add(a, "AUTO_COOLDOWN")
	near("charge_mult with 2 copies", AugmentRule.charge_mult(a), 1.2, 1e-6)


func test_jump_and_ftl() -> void:
	print("WEAPON_PREIGNITE, FTL_BOOSTER, FTL_JUMPER")
	var s := kestrel()
	s.weapons[0].charge = 3.0
	AugmentRule.jump_weapons(s)
	check("no preignite: charge lost", s.weapons[0].charge, 0.0)
	AugmentRule.add(s, "WEAPON_PREIGNITE")
	var w0: WeaponState = s.weapons[0]
	var w1: WeaponState = s.weapons[1]
	s.try_power_weapon(w0)
	s.depower_weapon(w1)
	w1.charge = 2.0
	AugmentRule.jump_weapons(s)
	check("powered weapon arrives charged", w0.is_charged(s.crew_level_in("weapons")), true)
	# WeaponSystem::Jump calls ForceCoolup on every weapon when the augment is present; ForceCoolup returns at once
	# for an unpowered one, and the "cooldown = 0" branch only runs without the augment.
	check("unpowered weapon keeps its (draining) charge", w1.charge, 2.0)
	var base := FtlDrive.engine_speed(kestrel())
	var b := kestrel()
	AugmentRule.add(b, "FTL_BOOSTER")
	near("FTL_BOOSTER x1.25", FtlDrive.engine_speed(b) / base, 1.25, 0.01)
	var run := RunState.new_run(3)
	var far := -1
	for bc in run.map.beacons:
		if bc.id != run.current_beacon and not run.map.connected(run.current_beacon, bc.id):
			far = bc.id
			break
	run.map.beacons[far].visited = 1
	check("visited non-neighbour: not a target", run.can_target(far), false)
	AugmentRule.add(run.ship, "FTL_JUMPER")
	check("FTL_JUMPER: visited beacon is a target", run.can_target(far), true)
	run.map.beacons[far].visited = 0
	check("FTL_JUMPER: unvisited stays out", run.can_target(far), false)


func test_missiles() -> void:
	print("EXPLOSIVE_REPLICATOR: 50 % of missile spends saved, drone parts never")
	var s := kestrel()
	s.missiles = 1000
	AugmentRule.add(s, "EXPLOSIVE_REPLICATOR")
	var saved := 0
	for i in 1000:
		if AugmentRule.spend_missiles(s, 1, rng):
			saved += 1
	near("saved ≈ 50 %", saved / 1000.0, 0.5, 0.05)
	check("missiles spent = not saved", s.missiles, saved)
	check("save counter for the '0' popup", s.missiles_saved, saved)
	var n := kestrel()
	n.missiles = 5
	AugmentRule.spend_missiles(n, 1, rng)
	check("no replicator: spent", n.missiles, 4)
	check("bombs / drones: drone parts are not a missile spend", AugmentRule.spend_missiles(s, 0, rng), false)


func test_misc() -> void:
	print("Other augments: battery, teleport heal, scrambler, hacking stun, life scanner, bypass, stasis pod")
	var s := kestrel()
	AugmentRule.add(s, "BATTERY_BOOSTER")
	check("battery booster lock 0.5 x 4 = 2 charges", int(s.augment_value("BATTERY_BOOSTER", 1.0) * 4), 2)
	AugmentRule.add(s, "TELEPORT_HEAL")
	check("teleport heal value 1.0 (full)", s.augment_value("TELEPORT_HEAL", 0.0), 1.0)
	var e := ShipState.new("REBEL_FAT", false)
	e.opponent = s
	check("scrambler absent: enemy drones fine", AugmentRule.drones_disrupted(e), false)
	AugmentRule.add(s, "DEFENSE_SCRAMBLER")
	check("DEFENSE_SCRAMBLER disrupts the enemy's drones", AugmentRule.drones_disrupted(e), true)
	# Hacking stun: crew in a room under the opponent's pulse.
	var h := kestrel()
	var o := ShipState.new("REBEL_FAT", false)
	h.opponent = o
	o.opponent = h
	AugmentRule.add(o, "HACKING_STUN")
	var sys := h.sys("weapons")
	sys.under_attack = true
	sys.hacked = true
	var c: CrewMember = h.crew.filter(func(x): return x.room == sys.room)[0] if h.crew.any(
		func(x): return x.room == sys.room) else h.crew[0]
	c.room = sys.room
	AugmentRule.tick(h, 0.01)
	check("crew in the hacked room stunned 0.2", c.stun, AugmentRule.HACK_STUN)
	# Life scanner: crew of the enemy drawn in its blacked-out rooms.
	var p := kestrel()
	var en := ShipState.new("REBEL_FAT", false)
	en.opponent = p
	p.opponent = en
	check("no life scanner", AugmentRule.life_scanner(en), false)
	AugmentRule.add(p, "LIFE_SCANNER")
	check("life scanner (player ship) shows enemy crew", AugmentRule.life_scanner(en), true)
	# Zoltan bypass: teleporter blocked by a super shield unless the sender has it.
	en.super_shield = 3
	check("super shield blocks the teleporter", TeleporterRule.super_blocked(p, en), true)
	AugmentRule.add(p, "ZOLTAN_BYPASS")
	check("ZOLTAN_BYPASS: not blocked", TeleporterRule.super_blocked(p, en), false)
	# Stasis pod: an inert quest item.
	var sp := kestrel()
	AugmentRule.add(sp, "STASIS_POD")
	check("stasis pod has no rate effect", [AugmentRule.charge_mult(sp), AugmentRule.shield_recharge_mult(sp),
		AugmentRule.scrap_income(sp, 10)], [1.0, 1.0, 10])
	check("stasis pod value is ignored by the engine", AugmentRule.VALUE_IGNORED.has("STASIS_POD"), true)
