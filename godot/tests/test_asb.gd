extends Node
## Tests for the anti-ship battery (rules/hazards.md §6: SpaceManager::UpdatePDS / SetPlanetaryDefense, PDSFire) and
## the beacon map's rebel-fleet warnings (rules/starmap.md §3–4: fleetChanging, GetLocationText). Run:
##   godot --headless --path godot res://tests/test_asb.tscn

const Harness := preload("res://tests/harness.gd")

const DT := 1.0 / 60.0
const F := DT * GameClock.BASE

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
	FtlData.muted = true
	_test_timers()
	_test_targets()
	_test_retarget_and_origin()
	_test_shots_in_combat()
	_test_map_warnings()


func space(ship: ShipState) -> Space:
	var sp := Space.new()
	add_child(sp)
	sp.setup(ship)
	return sp


## Firing steps 2–4 s after arrival, then 2–5 s; decoys until the volley is due; volley due → one shot per target.
func _test_timers() -> void:
	print("ASB timers")
	var p := ShipState.new("PLAYER_SHIP_HARD", true)
	var bad := {}
	for s in range(1, 40):
		var h := HazardRule.create(HazardRule.Env.PDS, 0, s, 2)
		if h.pds_timer < 2.0 or h.pds_timer >= 4.0:
			bad["first step in [2, 4) s"] = s
		if h.goal < 20.0 or h.goal >= 25.0:
			bad["volley period [20, 25) s"] = s
		var t := 0.0
		var last := 0.0
		var steps := 0
		while t < 19.0:
			var before := h.pds_shots
			h.tick(0.05, [p])
			t += 0.05
			if h.pds_shots != before:
				if steps > 0 and (t - last < 1.99 or t - last > 5.06):
					bad["ambient steps 2–5 s apart"] = s
				last = t
				steps += 1
		if h.pds_volley_hits != 0 or h.flares != 0:
			bad["no volley before the period"] = s
		if not h.log.all(func(l): return l.begins_with("pds: decoy")):
			bad["ambient shots are decoys"] = s
	check("ASB timers (seeds 1..39)", bad, {})
	# The warning shows < 5 s before the volley and stays until the firing step consumes it.
	var w := HazardRule.create(HazardRule.Env.PDS, 0, 3, 2)
	w.timer = w.goal - 4.0
	check("warning_pds_locked < 5 s", w.warning(), "warning_pds_locked")
	w.timer = w.goal + 3.0
	check("still locked after the period (not consumed yet)", w.warning(), "warning_pds_locked")
	# A volley: the next firing step re-rolls the period and fires (real shot unless dodged).
	var hits := 0
	var missed := 0
	for s in range(1, 60):
		var v := HazardRule.create(HazardRule.Env.PDS, 0, s, 2)
		v.timer = v.goal + 0.01
		v.pds_timer = 0.01
		v.tick(0.05, [p])
		hits += v.pds_volley_hits
		if v.log.size() == 1 and v.log[0].ends_with("(missed)"):
			missed += 1
		if v.flares != 1 or v.timer != 0.0 and v.timer > 0.06:
			bad["volley consumed + period re-rolled"] = s
	check("volley: one shot per step (hit or MISS)", hits + missed, 59)
	check("volley: most shots not dodged", hits > 40, true)
	# A non-hostile ship always dodges (GetDodged): the volley becomes a MISS decoy.
	var friendly := ShipState.new("PLAYER_SHIP_HARD", true)
	friendly.hostile = false
	var fv := HazardRule.create(HazardRule.Env.PDS, 0, 5, 2)
	fv.timer = fv.goal + 0.01
	fv.pds_timer = 0.01
	fv.tick(0.05, [friendly])
	check("non-hostile: volley dodged", [fv.pds_volley_hits, fv.log], [0, ["pds: decoy shot at ship 0 (missed)"]])


func _test_targets() -> void:
	print("ASB targets")
	var p := ShipState.new("PLAYER_SHIP_HARD", true)
	var e := ShipState.new("REBEL_FAT", false)
	var all := HazardRule.create(HazardRule.Env.PDS, 2, 9, 2)
	all.pds_timer = 0.01
	all.tick(0.05, [p, e])
	check("target all: two shots queued, one launched", [all.pds_shots, all.pds_queue.size()], [1, 1])
	check("  next one 0.5 s later", is_equal_approx(all.pds_timer, 0.5), true)
	all.tick(0.49, [p, e])
	check("  not yet", all.pds_shots, 1)
	all.tick(0.02, [p, e])
	check("  launched", [all.pds_shots, all.pds_queue.size()], [2, 0])
	check("  then 2–5 s", all.pds_timer >= 1.9 and all.pds_timer < 5.0, true)
	var en := HazardRule.create(HazardRule.Env.PDS, 1, 9, 2)
	check("enemy only: HUD 9 (ALLIES!), not dangerous", [en.hud_effects(), en.is_dangerous()], [[9, 0], false])
	en.tick(0.05, [p, e])
	check("  battery on with an enemy", en.pds_on, true)
	en.tick(0.05, [p, null])
	check("  enemy gone: battery off for good", [en.pds_on, en.hud_effects(), en.warning()], [false, [0, 0], ""])
	en.tick(0.05, [p, e])
	check("  stays off", en.pds_on, false)
	var pl := HazardRule.create(HazardRule.Env.PDS, 0, 9, 2)
	check("player: HUD 6, dangerous", [pl.hud_effects(), pl.is_dangerous()], [[6, 0], true])
	check("tooltips", [pl.hud_tooltip(6), pl.hud_tooltip(6, true), en.hud_tooltip(9), all.hud_tooltip(6)],
		["tooltip_PDS_PLAYER", "tooltip_PDS_FLEET", "tooltip_PDS_ENEMY", "tooltip_PDS_ALL"])


func _test_retarget_and_origin() -> void:
	print("ASB retarget / gun position")
	var h := HazardRule.create(HazardRule.Env.PDS, 0, 4, 2)
	h.timer = 15.0
	h.set_planetary_defense(2)
	check("SetPlanetaryDefense again: target, timer restarted", [h.target, h.timer, h.pds_timer >= 2.0 and
		h.pds_timer < 4.0], [2, 0.0, true])
	check("gun: fleet ship centre in a danger zone", HazardRule.pds_origin_for({"danger": 1}), Vector2(834, 525))
	check("gun: populated planet centre", HazardRule.pds_origin_for({"danger": 0, "pds_planet": {"pos":
		Vector2i(600, 247), "size": Vector2i(129, 130)}}), Vector2(664, 312))
	# A choice outcome re-targets the battery (REBEL_PDS hacked).
	var r := RunState.new_run(77)
	r.hazard = HazardRule.create(HazardRule.Env.PDS, 0, 4, 2)
	r.env = HazardRule.Env.PDS
	var ev := r.engine.base_event("REBEL_PDS")
	var c2: Dictionary = ev.choices[1].event
	check("REBEL_PDS hacked outcome: PDS all", [int(c2.environment), int(c2.env_target)], [6, 2])
	r.show_event(c2)
	check("  run's battery now targets all", r.hazard.target, 2)


## A real volley shot at the enemy flies from the gun in the player's space, crosses into the enemy's space, hits
## the room for 3 hull (no shields), grows to ×8; decoys fly off to x = −400 and never hit.
func _test_shots_in_combat() -> void:
	print("ASB shots")
	var p := ShipState.new("PLAYER_SHIP_HARD", true)
	var e := ShipState.new("REBEL_FAT", false)
	var cb := Combat.new()
	add_child(cb)
	cb.rng.seed = 99
	var ps := space(p)
	var es := space(e)
	ps.set_fixed_origin(HudLayout.PLAYER_SHIP)
	cb.add_space(ps, es)
	cb.add_space(es, ps)
	cb.paused = true
	var h := HazardRule.create(HazardRule.Env.PDS, 1, 21, 2)
	h.pds_origin = HazardRule.pds_origin_for({"danger": 1})
	e.shield_layers = 4
	var shot: PdsShot = null
	for s in range(1, 200):  # first seed whose volley shot is not dodged
		h = HazardRule.create(HazardRule.Env.PDS, 1, s, 2)
		h.pds_origin = HazardRule.pds_origin_for({"danger": 1})
		h.timer = h.goal + 0.01
		h.pds_timer = 0.01
		h.tick(0.05, [p, e], cb)
		if h.pds_volley_hits == 1:
			shot = cb.projectiles.filter(func(x): return x is PdsShot)[0]
			break
		for x in cb.projectiles:
			x.queue_free()
		cb.projectiles.clear()
	if shot == null:
		check("a volley shot", false, true)
		return
	check("shot starts at the gun (player coords)", shot.position, Vector2(834, 525) - HudLayout.PLAYER_SHIP)
	check("  in the player's space, under the ship", [shot.current_space == ps, shot.z_index], [true, -1])
	check("  heading 135..224 (leaves to the left)", shot.heading >= 135.0 and shot.heading < 225.0, true)
	check("  smoke puff at the gun", cb.projectiles.any(func(x): return x is PdsShot.Smoke), true)
	check("  first speed 60", shot.speed_units, 60.0)
	var hull0 := e.hull
	var t := 0.0
	var crossed := false
	while t < 6.0 and not shot.hit_target and not shot.dead:
		shot.step(F, cb.rng)
		t += DT
		crossed = crossed or shot.current_space == es
	check("  crossed into the enemy's space", crossed, true)
	check("  hit the room through 4 shield layers: 3 hull", hull0 - e.hull, 3)
	check("  scale ~×8 at the target", absf(shot.current_scale - 8.0) < 1.0, true)
	check("  speed = 20 + 3 × scale", is_equal_approx(shot.speed_units, 20.0 + 3.0 * shot.current_scale), true)
	check("  drawn over the ship after the hit", shot.z_index, 5)
	# A decoy (ambient step) at the player.
	var d := HazardRule.create(HazardRule.Env.PDS, 0, 8, 2)
	d.pds_origin = HazardRule.pds_origin_for({"danger": 0})
	d.pds_timer = 0.01
	d.tick(0.05, [p, e], cb)
	var decoys := cb.projectiles.filter(func(x): return x is PdsShot and x.decoy)
	check("decoy launched in the player's space", decoys.size() == 1 and decoys[0].current_space == ps, true)
	if decoys.size() == 1:
		var dec: PdsShot = decoys[0]
		check("  aimed at x = −400", dec.target.x, -400.0)
		var ph := p.hull
		t = 0.0
		while t < 6.0 and not dec.dead:
			dec.step(F, cb.rng)
			t += DT
		check("  flew off without damage", [dec.dead, p.hull], [true, ph])
	for x in cb.projectiles:
		x.queue_free()
	cb.projectiles.clear()


func _test_map_warnings() -> void:
	print("fleet warnings on the beacon map")
	var r := RunState.new_run(5)
	var v := StarMapView.new()
	add_child(v)
	var pr := InputProfile.new(InputProfile.PC)
	pr.run = r
	v.setup(r, pr)
	# Put the fleet's next edge just past a non-current beacon.
	var cur := r.map.beacon(r.current_beacon)
	var target := -1
	for b in r.map.beacons:
		if b.id != r.current_beacon and not b.exit and (b.pos as Vector2).x > 300:
			target = b.id
			break
	var bp: Vector2 = r.map.beacon(target).pos
	var m := r.fleet.next_move(bool(cur.get("nebula", false)), v._nebula_sector())
	r.fleet.center = Vector2(bp.x - r.fleet.radius() - m * 0.5, bp.y)
	check("beacon not covered now", r.fleet.covers(bp), false)
	check("beacon flagged fleetChanging", v._fleet_changing().has(target), true)
	check("hover text map_rebels_loc", v._location_text(target, v._fleet_changing()).begins_with(
		FtlData.tr_id("map_rebels_loc")), true)
	r.ship.fuel = 0
	check("out of fuel: no flags (RenderLabels skipped)", v._fleet_changing().has(target), false)
	r.ship.fuel = 3
	# The preview is not capped at x 60.
	r.fleet.center.x = 40.0
	check("next centre uncapped", v._next_fleet_center().x, 40.0 + r.fleet.next_move(bool(cur.get("nebula",
		false)), v._nebula_sector()))
	# Nebula suffix: map_nebula_fleet_loc only in a nebula sector (bNebulaMap), whatever the beacon.
	var neb := -1
	for b in r.map.beacons:
		if b.nebula and b.id != r.current_beacon:
			neb = b.id
	if neb >= 0:
		r.map.beacon(neb).fleet = true
		var txt := v._location_text(neb, {})
		check("overtaken nebula beacon, civilian sector: map_nebula_loc", txt.contains(FtlData.tr_id(
			"map_nebula_loc")) and not txt.contains(FtlData.tr_id("map_nebula_fleet_loc")), v._nebula_sector() == false)
	v.queue_free()
