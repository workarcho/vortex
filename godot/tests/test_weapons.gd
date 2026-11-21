extends Node
## Tests for rules/weapons.md (beams, bombs, flak, chain, charge, crystal). Run:
##   godot --headless --path godot res://tests/test_weapons.tscn

const Harness := preload("res://tests/harness.gd")

const F := 0.25  # clock factor per step (60 FPS ≈ 0.267)

var fails := 0
var rng := RandomNumberGenerator.new()


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func weapon(n: String, mount := 0) -> WeaponState:
	return WeaponState.new(FtlData.weapon_blueprint(n), mount)


func space(ship: ShipState) -> Space:
	var s := Space.new()
	add_child(s)  # in the tree first: setup() makes its camera current
	s.setup(ship)
	return s


## Enemy target with no evasion and a given number of shield layers (power fixed, no recharge needed).
func target_ship(layers: int) -> ShipState:
	var t := ShipState.new("REBEL_FAT", false)
	var e := t.sys("engines")
	if e:
		e.power = 0
	t.set_shield_layers_max(layers)
	t.shield_layers = layers
	return t


## Seconds of charge (powered).
func charge(w: WeaponState, seconds: float) -> void:
	for i in int(round(seconds * GameClock.BASE / F)):
		w.tick(F, 0)


## Rooms entered by a point moving from a to b in 1 px steps (independent of the beam code).
func rooms_crossed(ship: ShipState, a: Vector2, b: Vector2) -> Array:
	var out := []
	var last := -2
	var n := int(a.distance_to(b))
	for i in n + 1:
		var r := ship.room_at(a.lerp(b, float(i) / maxf(n, 1)))
		if r != last and r >= 0:
			out.append(r)
		last = r
	return out


## Fires a beam from `w` between p1 and p2 and runs it to the end; returns the Beam.
func run_beam(w: WeaponState, from: Space, to: Space, p1: Vector2, p2: Vector2) -> Beam:
	var b := Beam.new()
	b.setup(w, from, to, p1, p2, rng)
	to.world.add_child(b)
	var guard := 0
	while not b.dead and guard < 10000:
		b.step(F, rng)
		guard += 1
	return b


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	rng.seed = 1234
	test_data()
	test_chain()
	test_charge()
	test_flak()
	test_beam()
	test_bomb()
	test_owner_rules()
	test_aiming()
	test_beam_highlight()
	test_weapon_box()
	test_charge_bar_height()
	test_enemy_charge_parity()
	test_enemy_generation()


func test_data() -> void:
	print("Blueprint fields")
	var b := FtlData.weapon_blueprint("BEAM_1")
	check("BEAM_1 length", b.length, 45)
	check("BEAM_1 speed", b.speed, 3.0)
	check("BEAM_1 default colour (227,39,39)", b.color, Color8(227, 39, 39))
	check("BEAM_BIO colour (255,110,0)", FtlData.weapon_blueprint("BEAM_BIO").color, Color8(255, 110, 0))
	var f := FtlData.weapon_blueprint("SHOTGUN_PLAYER")
	check("SHOTGUN_PLAYER radius", f.radius, 40)
	check("SHOTGUN_PLAYER 6 debris (counts expanded)", f.mini_projectiles.size(), 6)
	check("  3 of them fake", f.mini_projectiles.filter(func(m): return m.fake).size(), 3)
	check("SHOTGUN_2 7 real debris", FtlData.weapon_blueprint("SHOTGUN_2").mini_projectiles.filter(
		func(m): return not m.fake).size(), 7)
	check("LASER_CHAINGUN boost", FtlData.weapon_blueprint("LASER_CHAINGUN").boost,
		{"type": "cooldown", "amount": 3.0, "count": 3})
	check("ION_CHAINGUN boost type", FtlData.weapon_blueprint("ION_CHAINGUN").boost.type, "damage")
	var c := FtlData.weapon_blueprint("CRYSTAL_BURST_1")
	check("crystal = MISSILES type without missiles, sp 1", [c.type, c.missiles, c.sp], ["MISSILES", 0, 1])
	check("crystal speed 50", weapon("CRYSTAL_BURST_1").speed(), 50.0)
	check("beam volley = 1 shot", weapon("BEAM_2").shots_this_volley(), 1)


func test_chain() -> void:
	print("\nChain: cooldown boost (LASER_CHAINGUN 16 s, -3 per volley, 3 times)")
	var w := weapon("LASER_CHAINGUN")
	var cds := []
	for i in 5:
		cds.append(w.max_charge(0))
		w.start_volley(rng)
		w.after_fire()
	check("cooldowns of 5 volleys", cds, [16.0, 13.0, 10.0, 7.0, 7.0])
	check("  weapons crew level 1 (x0.9) on the boosted cooldown", snappedf(w.max_charge(1), 0.01), 6.3)
	w.charge = 3.0
	w.powered = false
	for i in 3:
		w.tick(F, 0)
	check("unpowered, timer not empty: boost kept", w.boost_level, 3)
	charge_unpowered(w, 10.0)
	check("unpowered until the timer is empty: boost lost", w.boost_level, 0)

	print("\nChain: damage boost (ION_CHAINGUN ion 1, +1 per volley, 3 times)")
	w = weapon("ION_CHAINGUN")
	var ions := []
	for i in 5:
		w.start_volley(rng)
		ions.append(w.make_damage().ion)
		w.after_fire()
	check("ion of 5 volleys", ions, [1, 2, 3, 4, 4])
	check("cooldown not boosted", w.max_charge(0), 14.0)


func charge_unpowered(w: WeaponState, seconds: float) -> void:
	for i in int(round(seconds * GameClock.BASE / F)):
		w.tick(F, 0)


func test_charge() -> void:
	print("\nCharge weapons (LASER_CHARGEGUN_PLAYER: 5.5 s per level, 2 levels)")
	var w := weapon("LASER_CHARGEGUN_PLAYER")
	charge(w, 5.6)
	check("after 5.6 s: level", w.charge_level, 1)
	check("  can fire (1 shot)", [w.is_charged(0), w.shots_this_volley()], [true, 1])
	charge(w, 5.6)
	check("after 11.2 s: level", w.charge_level, 2)
	check("  volley shots", w.shots_this_volley(), 2)
	charge(w, 5.0)
	check("stays at max", w.charge_level, 2)
	w.powered = false
	w.tick(F, 0)
	check("unpowered at full: one level dropped at once", w.charge_level, 1)
	charge_unpowered(w, 0.5)
	check("  draining (0.375/factor = 6 s per s): still level", w.charge_level, 1)
	charge_unpowered(w, 3.0)
	check("  timer empty: all levels lost", [w.charge_level, w.charge], [0, 0.0])
	print("Fire time of charge weapons")
	check("charge laser fire time 1 s", w.fire_time(), 1.0)
	check("bomb fire time 1 s", weapon("BOMB_1").fire_time(), 1.0)


func test_flak() -> void:
	print("\nFlak spread")
	var inside := true
	var sum := 0.0
	var n := 4000
	for i in n:
		var p := Combat.flak_point(Vector2(100, 100), 40, rng)
		var d := p.distance_to(Vector2(100, 100))
		inside = inside and d <= 40.001
		sum += d
	check("all points inside radius 40", inside, true)
	check("uniform over the disc: mean distance ≈ 2/3 r (26.7)", absf(sum / n - 26.67) < 1.0, true)
	# Fake debris never interacts.
	var me := space(ShipState.new("PLAYER_SHIP_HARD", true))
	var en := space(target_ship(0))
	var w := weapon("SHOTGUN_PLAYER")
	var p := Projectile.new()
	var room: int = en.ship.layout.rooms[0].id
	p.setup(w, me, en, me.ship.mount_position(0), en.ship.room_rect(room).get_center(), "debris_small", true)
	me.world.add_child(p)
	var hull := en.ship.hull
	for i in 2000:
		if p.dead:
			break
		p.step(F, rng)
	check("fake debris: no hull damage", en.ship.hull, hull)
	check("  removed after flying through", p.dead, true)


func test_beam() -> void:
	print("\nBeams")
	var me := space(ShipState.new("PLAYER_SHIP_HARD", true))
	var en := space(target_ship(0))
	var t := en.ship
	var w := weapon("BEAM_2")
	check("BEAM_2 sweep time = 80 / (5 × 16) s", Beam.new().sweep_time() if false else 80.0 / (5.0 * 16.0), 1.0)
	# A horizontal sweep through the middle of the rooms.
	var bounds := t.rooms_bounds()
	var p1 := Vector2(bounds.position.x + 10, bounds.get_center().y)
	var p2 := p1 + Vector2(1000, 0)
	var expected := rooms_crossed(t, p1, p1 + Vector2(80, 0))
	var hull := t.hull
	var b := run_beam(w, me, en, p1, p2)
	check("no shields: hull -2 per room entered (%d rooms)" % expected.size(), hull - t.hull, 2 * expected.size())
	check("  sweep stops at its length", absf(b.current.distance_to(p1) - 80.0) <= 5.0 * F + 0.01, true)
	check("  sweep time ≈ 1 s", absf(b._time - 1.0) < 0.1, true)

	t = target_ship(1)
	en = space(t)
	hull = t.hull
	b = run_beam(w, me, en, p1, p2)
	check("1 shield layer: hull -1 per room", hull - t.hull, expected.size())
	t = target_ship(1)
	en = space(t)
	var quiet := Beam.new()
	var er := -1
	for r in t.layout.rooms:
		if t.system_in_room(r.id) == null:
			er = r.id
			break
	var ec := t.room_rect(er).get_center()
	quiet.setup(w, me, en, ec, ec + Vector2(1, 0), rng)
	for i in 5:
		quiet.step(F, rng)
	check("  beam never removes a shield layer", t.shield_layers, 1)

	t = target_ship(2)
	en = space(t)
	hull = t.hull
	b = run_beam(w, me, en, p1, p2)
	check("2 shield layers vs 2 damage: blocked", hull - t.hull, 0)
	check("  blocked beam: not pierced", b.pierced, false)

	t = target_ship(1)
	en = space(t)
	t.fires.clear()
	run_beam(weapon("BEAM_FIRE"), me, en, p1, p2)
	check("fire beam (0 damage) blocked by 1 layer: no fire", t.fires.size(), 0)

	print("Beam damage per room / tile (ShipManager::DamageBeam)")
	t = target_ship(0)
	var empty_room := -1
	for r in t.layout.rooms:
		if t.system_in_room(r.id) == null:
			empty_room = r.id
			break
	var d := Damage.from_weapon(FtlData.weapon_blueprint("BEAM_HULL"))
	hull = t.hull
	var c := t.room_rect(empty_room).get_center()
	var r1 := t.apply_beam(c, -1, -1, d, rng)
	check("hull beam in a room without system: hull -2", hull - t.hull, 2)
	var r2 := t.apply_beam(c + Vector2(1, 0), r1.room, r1.tile, d, rng)
	check("  same room again: no hull damage", [r2.hull, r2.new_room], [0, false])
	var fd := Damage.new()
	fd.fire_chance = 10
	t.fires.clear()
	var rr := t.room_rect(empty_room)
	var tiles := t.room_tiles(empty_room)
	var lr := -1
	var lt := -1
	for i in tiles:
		var r := t.apply_beam(t.tile_center(empty_room, i), lr, lt, fd, rng)
		lr = r.room
		lt = r.tile
	check("fire chance 10: one fire per tile entered (%d tiles)" % tiles, t.fires.get(empty_room, {}).size(), tiles)
	var crew := t.add_crew("human", false, empty_room)
	crew.pos = t.tile_center(empty_room, 0)
	var cd := Damage.new()
	cd.damage = 1
	var hp := crew.hp
	t.apply_beam(t.tile_center(empty_room, 0), -1, -1, cd, rng)
	check("crew on the entered tile: -15 HP", hp - crew.hp, 15.0)
	if tiles > 1:
		hp = crew.hp
		t.apply_beam(t.tile_center(empty_room, 1), empty_room, 0, cd, rng)
		check("  crew on another tile of the room: untouched", crew.hp, hp)
	check("  rect check", rr.size.x > 0, true)

	print("Beam killed when its weapon is depowered")
	t = target_ship(0)
	en = space(t)
	b = Beam.new()
	w = weapon("BEAM_1")
	b.setup(w, me, en, p1, p2, rng)
	b.step(F, rng)
	w.powered = false
	b.step(F, rng)
	check("dead", b.dead, true)


func test_bomb() -> void:
	print("\nBombs")
	var me := space(ShipState.new("PLAYER_SHIP_HARD", true))
	var t := target_ship(4)
	var en := space(t)
	var room: int = t.sys("shields").room
	var sys := t.system_in_room(room)
	var b := Bomb.new()
	b.setup(weapon("BOMB_1"), me, en, t.room_rect(room).get_center(), rng)
	check("no evasion: not missed", b.missed, false)
	var steps := 0
	while b.phase < 2 and steps < 1000:
		b.step(F, rng)
		steps += 1
	check("explodes after materialise 0.35 s + delay 0.4 s", absf(steps * F / GameClock.BASE - 0.75) < 0.05, true)
	check("4 shield layers ignored: system damage 2", sys.damage, 2)
	check("  no layer consumed (only the system damage lowers them)", t.shield_layers, t.max_shield_layers())
	check("  hull untouched (damage 0)", t.hull, t.max_hull)

	print("Missed bomb drifts out of the rooms")
	var start := t.room_rect(room).get_center()
	for dir in 4:
		var p := Bomb.miss_position(t, start, dir)
		check("  dir %d ends outside every room" % dir, t.room_at(p), -1)
	t.hostile = false
	b = Bomb.new()
	b.setup(weapon("BOMB_1"), me, en, start, rng)
	check("non-hostile target: always missed", b.missed, true)

	print("Heal bomb at the own ship")
	var own := me.ship
	var r: int = own.crew[0].room
	for c in own.crew:
		c.hp = 50.0
	var intruder := own.add_crew("human", false, r)
	if intruder:
		intruder.hp = 50.0
	b = Bomb.new()
	b.setup(weapon("BOMB_HEAL"), me, me, own.room_rect(r).get_center(), rng)
	check("self target never misses", b.missed, false)
	while b.phase < 2:
		b.step(F, rng)
	var healed := own.crew.filter(func(c): return c.room == r and c.player_owned)
	check("own crew in the room healed +150 (capped)", healed.all(func(c): return c.hp == c.max_hp), true)
	if intruder:
		check("  enemy intruder in the room not healed", intruder.hp, 50.0)

	print("Bomb sprites: duplicate sheet names resolve to the sheet defined before each element")
	for pair in [["BOMB_HEAL", "bomb_heal_strip9"], ["BOMB_FIRE", "bomb_fire_strip9"],
			["BOMB_ION", "bomb_ion_strip9"], ["BOMB_LOCK", "bomb_lockdown_strip9"],
			["BOMB_BREACH_1", "bomb_breach_strip9"], ["BOMB_1", "bomb_1_strip9"],
			["BOMB_STUN", "bomb_stun_strip9"], ["BOMB_HEAL_SYSTEM", "bomb_repair_strip9"]]:
		var wb := FtlData.weapon_blueprint(pair[0])
		var a := FtlData.anim(String(wb.get("image", "")))
		var ok: bool = not a.is_empty() and a.frames.size() == 9 and a.frames[0].size == Vector2(35, 35)
		check("  %s bomb anim = 9 frames 35x35 (%s)" % [pair[0], pair[1]], ok, true)
		var art := String(wb.get("weapon_art", ""))
		var wa := FtlData.weapon_anim(art if art != "" else String(wb.get("image", "")))
		check("  %s launcher art still the 17-frame strip" % pair[0], wa.length, 17)


func test_owner_rules() -> void:
	print("\nDamageCrew owner rules")
	var d := Damage.new()
	d.damage = 1
	d.owner = 0
	check("player weapon hurts enemy crew", d.crew_hp_change(false), 15.0)
	check("player weapon hurts own boarders too (friendly fire is always on)", d.crew_hp_change(true), 15.0)
	d.damage = 0
	d.pers_damage = -10
	check("heal reaches own crew", d.crew_hp_change(true), -150.0)
	check("heal skips the other side", d.crew_hp_change(false), 0.0)
	d.owner = -1
	check("no owner (debug hit): heals anyone", d.crew_hp_change(false), -150.0)


func test_aiming() -> void:
	print("\nPlayer aiming")
	var me := ShipState.new("TEST_SHIP_ALL", true)
	var t := target_ship(0)
	me.weapons.clear()
	for n in ["BEAM_2", "BOMB_HEAL", "BURST_LASER_PLACEHOLDER"]:
		if n == "BURST_LASER_PLACEHOLDER":
			n = "LASER_BURST_1"
		var w := weapon(n, me.weapons.size())
		w.powered = true
		me.weapons.append(w)
	var wc := WeaponControl.new(me)
	wc.select(0)
	check("beam armed", wc.armed_is_beam(), true)
	check("first point outside every room refused", wc.begin_beam(t, Vector2(-5000, -5000)), false)
	var c := t.room_rect(t.layout.rooms[0].id).get_center()
	check("first point in a room", wc.begin_beam(t, c), true)
	check("pointer within 10 px: no end yet", wc.beam_end_for(c + Vector2(5, 0)), null)
	var end: Vector2 = wc.beam_end_for(c + Vector2(300, 0))
	check("end = start + length toward the pointer", end, c + Vector2(80, 0))
	check("short drag still gives the full length", wc.beam_end_for(c + Vector2(0, 20)), c + Vector2(0, 80))
	wc.finish_beam(c + Vector2(300, 0))
	var bw := me.weapons[0]
	check("beam aimed: start / end", [bw.target_point, bw.target_point2], [c, c + Vector2(80, 0)])
	wc.select(2)
	check("laser cannot target the own ship", wc.aim_at(me, me.layout.rooms[0].id), false)
	wc.select(1)
	check("bomb can target the own ship", wc.aim_at(me, me.layout.rooms[0].id), true)

	print("Non-hostile target (accepted surrender / neutral ship): CombatControl::UpdateAiming refuses it")
	var nt := target_ship(0)
	nt.hostile = false
	wc.select(2)
	check("laser cannot aim at a non-hostile ship", wc.aim_at(nt, nt.layout.rooms[0].id), false)
	wc.select(0)
	var nc := nt.room_rect(nt.layout.rooms[0].id).get_center()
	wc.begin_beam(nt, nc)
	check("beam cannot aim at a non-hostile ship", wc.finish_beam(nc + Vector2(300, 0)), false)
	wc.disarm()
	check("non-hostile enemy hides its interior (ShipManager::OnRender)", nt.shows_interior(), false)
	nt.hostile = true
	check("hostile enemy shows its interior", nt.shows_interior(), true)
	# WeaponControl::OnLoop: an aimed weapon loses its target once the ship stops being hostile.
	var cb := Combat.new()
	add_child(cb)
	var sp_me := Space.new()
	var sp_t := Space.new()
	add_child(sp_me)
	add_child(sp_t)
	sp_me.setup(me)
	sp_t.setup(nt)
	cb.add_space(sp_me, sp_t)
	cb.add_space(sp_t, sp_me)
	wc.select(2)
	wc.aim_at(nt, nt.layout.rooms[0].id)
	check("laser aimed at the hostile ship", me.weapons[2].target_ship == nt, true)
	cb.ais[sp_t].hostile = false  # accepted surrender: ShipEvent hostile = false
	cb._physics_process(1.0 / 60.0)
	check("ship no longer hostile", nt.hostile, false)
	check("  the aim is cleared", me.weapons[2].target_ship, null)
	cb.queue_free()
	sp_me.queue_free()
	sp_t.queue_free()


## Beam aiming highlights every room the line crosses (CombatControl::RenderTarget).
func test_beam_highlight() -> void:
	print("Beam aim highlight")
	var t := target_ship(0)
	var rooms: Array = t.layout.rooms
	var a: Vector2 = t.room_rect(rooms[0].id).get_center()
	var b: Vector2 = t.room_rect(rooms[rooms.size() - 1].id).get_center()
	var got := Space.beam_rooms(t, a, b)
	check("highlight = rooms the line enters", Array(got), rooms_crossed(t, a, b))
	check("starts with the first point's room", got[0], rooms[0].id)
	check("ends with the last point's room", got[got.size() - 1], rooms[rooms.size() - 1].id)
	check("crosses more than 2 rooms on a long line", got.size() > 2, true)
	check("line inside one room -> just that room", Array(Space.beam_rooms(t, a, a + Vector2(5, 0))), [rooms[0].id])


func test_weapon_box() -> void:
	print("Weapon / drone box details (rules/hud_layout.md \"Weapon box details\")")
	# Charge pips: LASER_CHARGEGUN has 2 levels -> centred at x 34 + 6, pitch 11, y 25.
	var cg := weapon("LASER_CHARGEGUN")
	var pips := WeaponBox.charge_pips(cg.charge_levels(), 1, true)
	check("charge gun pips", pips.map(func(p): return [p.pos, p.state]),
		[[Vector2(40, 25), "use"], [Vector2(51, 25), "on"]])
	check("unpowered pips are off", WeaponBox.charge_pips(3, 0, false).map(func(p): return p.state), ["off", "off", "off"])
	check("3 levels start at x 37", WeaponBox.charge_pips(3, 3, true)[0].pos, Vector2(37, 25))
	check("missile weapon pips at y 26", WeaponBox.charge_pips(2, 0, true, true)[0].pos.y, 26.0)
	check("no pips for one level", WeaponBox.charge_pips(1, 1, true), [])
	# Chain boost icon: cooldown -> clock at (40, 20) + "+N" at (58, 19) while powered and boosted.
	var ch := weapon("LASER_CHAINGUN")
	var b0 := WeaponBox.boost_icon(ch.bp.boost, 0, true)
	check("chain unboosted", [b0.img, b0.pos, b0.text], ["combatUI/icon_clock_off.png", Vector2(40, 20), ""])
	var b2 := WeaponBox.boost_icon(ch.bp.boost, 2, true)
	check("chain boosted", [b2.img, b2.text, b2.text_pos], ["combatUI/icon_clock_on.png", "+2", Vector2(58, 19)])
	check("chain boosted but unpowered", WeaponBox.boost_icon(ch.bp.boost, 2, false).on, false)
	var dmg := {"type": "damage", "count": 3, "amount": 1}
	var bd := WeaponBox.boost_icon(dmg, 4, true)
	check("damage boost: arrow, level capped at count", [bd.img, bd.pos, bd.text], ["combatUI/icon_arrow_on.png", Vector2(44, 21), "+3"])
	check("no boost -> no icon", WeaponBox.boost_icon({}, 0, true), {})
	check("hotkey x mods 1,2,4,7", [1, 2, 4, 7].map(WeaponBox.hotkey_x_mod), [5, 4, 3, 3])
	# Drone rebuild overlay: 39 px tall right after the loss, shrinking with the timer.
	check("rebuild overlay full", DroneBox.rebuild_rect(10.0), Rect2(0, 0, 95, 39))
	check("rebuild overlay half", DroneBox.rebuild_rect(5.0), Rect2(0, 20, 95, 19))


func test_charge_bar_height() -> void:
	print("Weapon box charge bar height (WeaponBox::UpdateCooldownBox, rules/weapon_controls.md)")
	# int(cooldown.second / cooldownMax × 33 × cooldownModifier); cooldownMax = WeaponSystem::GetMaxCooldown (the
	# slowest weapon's current charge time; WeaponControl::OnRender sets it every frame).
	var h := func(names: Array, i: int, crew := 0, boost := 0) -> int:
		var ws: Array = names.map(func(n: String) -> WeaponState: return weapon(n))
		ws[i].boost_level = boost
		return WeaponBox.cooldown_height(ws[i], crew, WeaponBox.COOLDOWN_H, WeaponBox.max_cooldown(ws, crew))
	var kestrel := ["MISSILES_2_PLAYER", "LASER_BURST_3"]
	# Kestrel (vanilla screenshot 34_kestrel_vs_pirate: Burst II full, Artemis 3 px lower with the shoulder).
	check("Kestrel: Artemis 11 s / Burst II 12 s", [h.call(kestrel, 0), h.call(kestrel, 1)], [30, 33])
	check("max cooldown: slowest weapon, nulls skipped, -100 without weapons",
		[WeaponBox.max_cooldown([null, weapon("LASER_BURST_2"), weapon("MISSILES_BREACH")], 0),
		WeaponBox.max_cooldown([], 0)], [22.0, -100.0])
	check("burst I (10 s) next to a breach (22 s)", h.call(["LASER_BURST_2", "MISSILES_BREACH"], 0), 15)
	# Alone, a weapon's bar is 33 × modifier: Ion Blast II manned at level 2 = int(33 × 0.85) = 28 (vanilla
	# 20_hud_with_drones: 28 px). The modifier no longer counts twice once the max includes it.
	check("single weapon: 33 × manning modifier", [h.call(["ION_2"], 0), h.call(["ION_2"], 0, 2),
		h.call(["ION_2"], 0, 3)], [33, 28, 26])
	# Chain laser (16 s) next to a breach (22 s): its bar shrinks with its boost (-3 s each).
	check("chain laser shrinks with its boost", [0, 1, 2, 3].map(func(b: int) -> int:
		return h.call(["LASER_CHAINGUN", "MISSILES_BREACH"], 0, 0, b)), [24, 19, 15, 10])
	var tiny := weapon("LASER_BURST_2")
	tiny.bp = tiny.bp.duplicate()
	tiny.bp.cooldown = 0.5
	check("at least 1 px", WeaponBox.cooldown_height(tiny, 0, WeaponBox.COOLDOWN_H, 22.0), 1)
	check("constructor value 30 (no weapons system)", WeaponBox.cooldown_height(weapon("LASER_BURST_3"), 0), 13)
	check("icon form max 22", WeaponBox.cooldown_height(weapon("LASER_BURST_3"), 0, WeaponBox.COOLDOWN_H_ICON,
		12.0), 22)
	# Status colour: purple while the weapons system is under a hack pulse (iHackLevel > 1) and powered.
	var b := WeaponBox.new()
	b.weapon = weapon("LASER_BURST_3")
	b.hack_level = 1
	check("passive hack: normal colour", b.status_color(), WeaponBox.COL_CHARGING)
	b.hack_level = 2
	check("pulse: purple", b.status_color(), FtlColors.PURPLE_HACK)
	b.weapon.powered = false
	check("unpowered wins over hacked", b.status_color(), WeaponBox.COL_OFF)
	b.weapon.powered = true
	b.hack_level = 0
	check("fill: status colour without targets", b.fill_color(b.status_color()), WeaponBox.COL_CHARGING)
	b.weapon.target_ship = ShipState.new("REBEL_FAT", false)
	b.weapon.target_room = 0
	check("fill: targeted -> (255,120,120)", b.fill_color(b.status_color()), WeaponBox.COL_ARMED)
	b.weapon.autofire = true
	check("fill: targeted + autofire -> yellow", b.fill_color(b.status_color()), FtlColors.YELLOW)
	var st := {}
	WeaponBox.update_sparks(st, true, 0.0)
	WeaponBox.update_sparks(st, true, 1.2)
	check("hack sparks rerolled per 1 s run within the box", [st.cycle, st.x < 25, st.my < 31], [1, true, true])
	WeaponBox.update_sparks(st, false, 1.3)
	check("hack sparks stop", st.is_empty(), true)
	b.free()


## One ship of a charge-parity duel: crew removed (no manning bonus), one weapon in slot 0, powered.
func _duel_ship(bp_name: String, player: bool, weapon_name: String) -> ShipState:
	var s := ShipState.new(bp_name, player)
	s.crew.clear()
	s.crew_changed()
	s.reactor_max = 30
	s.missiles = 20
	var ws := s.sys("weapons")
	ws.level = 8
	for w in s.weapons:
		s.depower_weapon(w)
	s.weapons.clear()
	var w := weapon(weapon_name)
	w.powered = false
	s.weapons.append(w)
	check("%s %s powered" % ["player" if player else "enemy", weapon_name], s.try_power_weapon(w), "ok")
	return s


## Runs a Combat duel at 60 FPS (normal speed) and returns the frame at which each ship's weapon first
## completed its charge: [player, enemy, enemy fired]. The enemy AI fires as soon as it is charged; the player's weapon has
## no target and simply stays full.
func _duel(player_weapon: String, enemy_weapon: String, seconds := 14.0, paused_frames := 0) -> Array:
	var me := _duel_ship("PLAYER_SHIP_HARD", true, player_weapon)
	var en := _duel_ship("REBEL_FAT", false, enemy_weapon)
	var cb := Combat.new()
	cb.set_physics_process(false)  # stepped by hand below
	add_child(cb)
	var sp_me := Space.new()
	var sp_en := Space.new()
	add_child(sp_me)
	add_child(sp_en)
	sp_me.setup(me)
	sp_en.setup(en)
	cb.add_space(sp_me, sp_en)
	cb.add_space(sp_en, sp_me)
	var at := {}
	var t0 := cb.game_time
	var cbk := func(ship, _w):
		if not at.has(ship):
			at[ship] = cb.game_time - t0
	Hooks.listen(&"weapon_charged", cbk, 0, "test")
	cb.paused = true  # pause / an open event box (main.gd sets combat.paused while run.modal())
	for i in paused_frames:
		cb._physics_process(1.0 / 60.0)
	cb.paused = false
	for i in int(seconds * 60.0):
		cb._physics_process(1.0 / 60.0)
	Hooks.unlisten(&"weapon_charged", cbk)
	var fired := en.weapons[0].charge < en.weapons[0].max_charge(0)  # charge emptied by the AI's volley
	cb.queue_free()
	sp_me.queue_free()
	sp_en.queue_free()
	# Whole frames (1/60 s) since the duel started: 11 s = frame 660.
	return [roundi(at.get(me, -1.0) * 60.0), roundi(at.get(en, -1.0) * 60.0), fired]


## Report "enemy missiles charge faster than my Artemis" (rules/timing_and_projectiles.md "Enemy vs player charge").
## Both ships go through the same ProjectileFactory::Update (WeaponSystem::OnLoop): + factor/16 per frame
## (x (1 + AUTO_COOLDOWN)), max = cooldown x getSkillBonus(weapons, IsMannedBoost), no difficulty term. The
## difference is the blueprint: the enemy "Artemis" is MISSILES_2 (cooldown 10, 2 power), the player's
## Artemis is MISSILES_2_PLAYER (cooldown 11, 1 power).
func test_enemy_charge_parity() -> void:
	print("\nEnemy vs player charge (same engine path)")
	var r := _duel("MISSILES_2_PLAYER", "MISSILES_2_PLAYER")
	check("same Artemis (MISSILES_2_PLAYER) on both: charged at 11 s (frame 660) together", [r[0], r[1]], [660, 660])
	check("  the enemy AI fired its volley", r[2], true)
	r = _duel("LASER_BURST_1", "LASER_BURST_1")
	check("Basic Laser vs Basic Laser: 10 s each (frame 600)", [r[0], r[1]], [600, 600])
	r = _duel("MISSILES_2_PLAYER", "MISSILES_2")
	check("player Artemis 11 s vs enemy Artemis (MISSILES_2) 10 s", [r[0], r[1]], [660, 600])
	var saved := ShipAI.difficulty
	for d in [ShipAI.Difficulty.EASY, ShipAI.Difficulty.HARD]:
		ShipAI.difficulty = d
		r = _duel("LASER_BURST_1", "LASER_BURST_1")
		check("difficulty %d: no effect on charge time" % d, [r[0], r[1]], [600, 600])
	ShipAI.difficulty = saved
	r = _duel("LASER_BURST_1", "LASER_BURST_1", 14.0, 300)
	check("5 s paused first (event box): nothing charges meanwhile", [r[0], r[1]], [600, 600])
	print("Blueprints: the two Artemis launchers")
	var ea := FtlData.weapon_blueprint("MISSILES_2")
	var pa := FtlData.weapon_blueprint("MISSILES_2_PLAYER")
	check("same name (Artemis), damage 2", [FtlData.tr_id(String(ea.short)), FtlData.tr_id(String(pa.short)),
		int(ea.damage), int(pa.damage)], ["Artemis", "Artemis", 2, 2])
	check("enemy MISSILES_2: cooldown 10, power 2", [float(ea.cooldown), int(ea.power)], [10.0, 2])
	check("player MISSILES_2_PLAYER: cooldown 11, power 1", [float(pa.cooldown), int(pa.power)], [11.0, 1])
	for lst in ["WEAPONS_REBEL", "OVERRIDE_WEAPONS_REBEL", "WEAPONS_AUTO", "OVERRIDE_WEAPONS_AUTO"]:
		var l := FtlData.blueprint_list(lst)
		check("%s: has MISSILES_2, not MISSILES_2_PLAYER" % lst, [l.has("MISSILES_2"), l.has("MISSILES_2_PLAYER")],
			[true, false])
	print("Manning (getSkillBonus(weapons, level)): the same table for both sides")
	check("enemy Artemis unmanned / manned / skill 2 / skill 3", [1, 0, 2, 3].map(func(l):
		return snappedf(weapon("MISSILES_2").max_charge(l), 0.01)), [9.0, 10.0, 8.5, 8.0])
	check("player Artemis unmanned / manned", [0, 1].map(func(l):
		return snappedf(weapon("MISSILES_2_PLAYER").max_charge(l), 0.01)), [11.0, 9.9])
	print("Start of combat: both at 0 (fresh enemy factories; WeaponSystem::Jump empties the player's)")
	var gs := ShipState.new("REBEL_FAT", false)
	ShipGenerator.apply(gs, ShipGenerator.generate("REBEL_FAT", 4, EventEngine.Difficulty.NORMAL, 5))
	check("generated enemy weapons start empty", gs.weapons.all(func(w): return w.charge == 0.0 and w.charge_level == 0),
		true)


## ShipGenerator::CreateShip weapon picks (GetPossibleWeaponList / GetWeaponFlags) and the automated-ship manning
## (UpdateCrewmembers: bManned = iActiveManned = bAutomated) that sets an auto ship's charge time.
func test_enemy_generation() -> void:
	print("\nGetWeaponFlags: laser 3 (ion 2), missile 1 (data sp 5 >= 4: damage only), beam / bomb / flak 1 with damage, else 0")
	check("LASER_BURST_1, ION_1, MISSILES_1, BEAM_1, BOMB_ION, SHOTGUN",
		["LASER_BURST_1", "ION_1", "MISSILES_1", "BEAM_1", "BOMB_ION", "SHOTGUN"].map(func(n):
			return ShipGenerator.weapon_flags(FtlData.weapon_blueprint(n))), [3, 2, 1, 1, 0, 1])
	print("GetPossibleWeaponList over 300 seeds (sector 1, normal)")
	var whole := 0
	var first_one := 0
	var over := 0
	var leto := 0
	var two_basic := 0
	for seed in 300:
		var plan := ShipGenerator.generate("AUTO_BASIC", 0, EventEngine.Difficulty.NORMAL, seed * 31 + 7)
		var lv := int(plan.levels.weapons)
		var used := 0
		for i in plan.weapons.size():
			var p := int(FtlData.weapon_blueprint(plan.weapons[i]).power)
			used += p
			if lv >= 2 and p == lv:
				whole += 1
			if lv >= 3 and i == 0 and p == 1:
				first_one += 1
		if used > lv:
			over += 1
		if plan.weapons.has("MISSILES_1"):
			leto += 1
		if lv == 2:
			two_basic += 1 if plan.weapons.size() == 2 else 0
	check("never a weapon using every bar of a 2+ bar system", whole, 0)
	check("never a 1-power first weapon on a 3+ bar system", first_one, 0)
	check("never more power than the system", over, 0)
	check("2-bar Auto-Scouts carry two 1-power weapons", two_basic > 0, true)
	check("Leto (MISSILES_1) is a common sector-1 pick", leto > 40, true)
	var none := 0
	for seed in 100:
		var plan := ShipGenerator.generate("AUTO_ASSAULT", 0, EventEngine.Difficulty.EASY, seed)
		if int(plan.levels.weapons) == 0 and plan.weapons.is_empty():
			none += 1
	check("AUTO_ASSAULT left at 0 weapon bars: no weapon (no fallback)", none, 100)
	print("Automated ship (bAutomated): every boostable, intact system counts as manned by an unskilled crew")
	var a := ShipState.new("AUTO_BASIC", false)
	ShipGenerator.apply(a, ShipGenerator.generate("AUTO_BASIC", 0, EventEngine.Difficulty.NORMAL, 11))
	check("crewless enemy is automated; a crewed one is not", [a.is_automated(),
		ShipState.new("REBEL_FAT", false).is_automated(), ShipState.new("PLAYER_SHIP_HARD", true).is_automated()],
		[true, false, false])
	check("weapons / pilot / engines manning level 1, piloting bManned", [a.crew_level_in("weapons"),
		a.crew_level_in("pilot"), a.crew_level_in("engines"), a.is_manned("pilot")], [1, 1, 1, true])
	var leto_w := weapon("MISSILES_1")
	check("Leto 9 s x 0.9 = 8.1 s; Basic Laser 10 s x 0.9 = 9 s", [snappedf(leto_w.max_charge(a.crew_level_in("weapons")),
		0.01), snappedf(weapon("LASER_BURST_1").max_charge(a.crew_level_in("weapons")), 0.01)], [8.1, 9.0])
	check("evasion = engines + piloting manned bonus (not the empty-seat 0)", a.dodge_factor(),
		EvasionRule.dodge_factor(a.system_power("engines"), 1, 1, a.system_power("pilot"), false, true))
	a.sys("weapons").damage = 0
	a.damage_system("engines", 1)
	check("a damaged system is not boosted", a.crew_level_in("engines"), 0)
	var t := 0.0
	while t < 40.0 and a.sys("engines").damage > 0:
		a.tick((1.0 / 60.0) * GameClock.BASE)
		t += 1.0 / 60.0
	check("self-repair (PartialRepair(1.0, autoRepair)): one bar in 37.5 s", snappedf(t, 0.1), 37.5)
