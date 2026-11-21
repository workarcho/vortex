extends Node
## Tests for rules/hazards.md (HazardRule) and rules/ftl_drive.md (FtlDrive): flare / pulse timers and warnings,
## sun fires (3–6 unshielded, 1–2 shielded) and damage, pulsar ion (shields + 1 / 2 systems, super shield drain,
## Ion Armor), asteroid generator (immediate first asteroid, alternating ships, intervals by shield level), ion
## storm reactor cap, nebula sensors, the FTL drive rate and ShipFlying. Run:
##   godot --headless --path godot res://tests/test_hazards.tscn

const Harness := preload("res://tests/harness.gd")

var fails := 0


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func count_fires(s: ShipState) -> int:
	var n := 0
	for room in s.fires:
		n += s.fires[room].size()
	return n


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	# --- sun: timer, warning, flare
	var sun := HazardRule.create(HazardRule.Env.SUN, 2, 11, 2)
	check("flare period in [28, 34) s", sun.goal >= 28.0 and sun.goal < 34.0, true)
	check("no warning at arrival", sun.warning(), "")
	var a := ShipState.new("PLAYER_SHIP_HARD", true)
	var t := 0.0
	while sun.flares == 0 and t < 40.0:
		sun.tick(0.1, [a])
		t += 0.1
		if sun.remaining() < 4.9 and sun.remaining() > 0.0:
			check("warning_solar_flare < 5 s before", sun.warning(), "warning_solar_flare")
			break
	while sun.flares == 0 and t < 40.0:
		sun.tick(0.1, [a])
		t += 0.1
	check("a flare happened", sun.flares, 1)
	var bad := {}
	for s in range(1, 60):
		var h := HazardRule.create(HazardRule.Env.SUN, 2, s, 2)
		var sh := ShipState.new("PLAYER_SHIP_HARD", true)
		sh.shield_layers = 0
		var hull0 := sh.hull
		var r := h.sun_damage(sh)
		if r.fires < 3 or r.fires > 6:
			bad["unshielded: 3–6 fires"] = s
		if hull0 - sh.hull != r.hits:
			bad["1 hull per damaged room"] = s
		var sh2 := ShipState.new("PLAYER_SHIP_HARD", true)
		sh2.shield_layers = 1
		var r2 := h.sun_damage(sh2)
		if r2.fires < 1 or r2.fires > 2:
			bad["shielded: 1–2 fires"] = s
		if count_fires(sh2) < 1:
			bad["fires started"] = s
	check("sun damage invariants over 59 seeds", bad, {})

	# --- pulsar
	var pul := HazardRule.create(HazardRule.Env.PULSAR, 2, 3, 2)
	check("pulse period in [11, 18) s", pul.goal >= 11.0 and pul.goal < 18.0, true)
	var p := ShipState.new("PLAYER_SHIP_HARD", true)
	var shp := p.sys("shields").effective_power()
	var hit := pul.pulsar_damage(p)
	check("powered shields: shields + 1 other system", [hit.size(), hit[0], hit[1] != "shields"], [2, "shields", true])
	check("shield ion = power / 2 + 1", p.sys("shields").ion, shp / 2 + 1)
	var p2 := ShipState.new("PLAYER_SHIP_HARD", true)
	while p2.decrease_power("shields"):
		pass
	var hit2 := pul.pulsar_damage(p2)
	check("unpowered shields: 2 distinct systems", [hit2.size(), hit2[0] != hit2[1]], [2, true])
	var p3 := ShipState.new("PLAYER_SHIP_HARD", true)
	p3.super_shield = 5
	p3.super_shield_max = 5
	var hit3 := pul.pulsar_damage(p3)
	check("super shield drained 3–4, no ion", [hit3.size(), p3.super_shield >= 1 and p3.super_shield <= 2], [0, true])
	var resisted := 0
	for s in 100:
		var pa := ShipState.new("PLAYER_SHIP_HARD", true)
		pa.augments.append("ION_ARMOR")
		var hz := HazardRule.create(HazardRule.Env.PULSAR, 2, s, 2)
		if hz.pulsar_damage(pa).is_empty():
			resisted += 1
	check("Ion Armor resists about half (%d / 100)" % resisted, resisted > 30 and resisted < 70, true)
	# DamageMessages queued for the spaces: sun "1" per damaged room, pulsar ion numbers / RESIST / super drain.
	var bad_msg := {}
	for s in range(1, 40):
		var hm := HazardRule.create(HazardRule.Env.SUN, 2, s, 2)
		var sm := ShipState.new("PLAYER_SHIP_HARD", true)
		sm.shield_layers = 0
		var rm := hm.sun_damage(sm)
		if hm.messages.size() != rm.hits or hm.messages.any(func(m): return m[1] != "hull" or m[2] != 1):
			bad_msg["sun: one hull '1' per damaged room"] = s
		var pm := HazardRule.create(HazardRule.Env.PULSAR, 2, s, 2)
		var ps := ShipState.new("PLAYER_SHIP_HARD", true)
		var ph := pm.pulsar_damage(ps)
		if pm.messages.size() != ph.size() or pm.messages.any(func(m): return m[1] != "ion"):
			bad_msg["pulsar: one ion number per ionized system"] = s
		var pr := HazardRule.create(HazardRule.Env.PULSAR, 2, s, 2)
		var pa := ShipState.new("PLAYER_SHIP_HARD", true)
		pa.augments.append("ION_ARMOR")
		if pr.pulsar_damage(pa).is_empty() and (pr.messages.size() != 1 or pr.messages[0][1] != "resist"
				or pr.messages[0][3] != pa.sys("shields").room):
			bad_msg["resisted with powered shields: one RESIST at the shield room"] = s
	check("hazard damage messages over 39 seeds", bad_msg, {})
	var psup := HazardRule.create(HazardRule.Env.PULSAR, 2, 3, 2)
	var p4 := ShipState.new("PLAYER_SHIP_HARD", true)
	p4.super_shield = 5
	p4.super_shield_max = 5
	psup.pulsar_damage(p4)
	check("super shield drain shown at the shield centre", [psup.messages.size(), psup.messages[0][1],
		psup.messages[0][2] == 5 - p4.super_shield, psup.messages[0][3]], [1, "super", true, -1])
	psup._show_messages(null)
	check("messages cleared after showing", psup.messages.size(), 0)

	# --- asteroids
	var ast := HazardRule.create(HazardRule.Env.ASTEROIDS, 2, 5, 2)
	check("asteroids start slow or fast", ast.ast_state in [1, 2], true)
	var pl := ShipState.new("PLAYER_SHIP_HARD", true)
	var en := ShipState.new("REBEL_FAT", false)
	ast.tick(0.016, [pl, en])
	check("first asteroid at once", ast.ast_targets.size(), 1)
	for i in 1500:
		ast.tick(0.05, [pl, en])
	var to_p := ast.ast_targets.count(0)
	var to_e := ast.ast_targets.count(1)
	check("asteroids alternate player / enemy (%d / %d)" % [to_p, to_e], absi(to_p - to_e) <= 1 and to_p > 5, true)
	var ast2 := HazardRule.create(HazardRule.Env.ASTEROIDS, 2, 5, 2)
	for i in 1500:
		ast2.tick(0.05, [pl, null])
	check("asteroids at a gone enemy are discarded", ast2.ast_targets.has(-1), true)
	var ast_lo := HazardRule.create(HazardRule.Env.ASTEROIDS, 2, 9, 0)
	var ast_hi := HazardRule.create(HazardRule.Env.ASTEROIDS, 2, 9, 8)
	for i in 3000:
		ast_lo.tick(0.05, [pl])
		ast_hi.tick(0.05, [pl])
	check("more asteroids with stronger shields (%d < %d)" % [ast_lo.ast_targets.size(), ast_hi.ast_targets.size()],
		ast_lo.ast_targets.size() < ast_hi.ast_targets.size(), true)

	# --- storm and nebula
	var st := ShipState.new("PLAYER_SHIP_HARD", true)
	var cap0 := st.reactor_capacity()
	HazardRule.create(HazardRule.Env.STORM, 2, 1, 2).apply_status(st)
	check("ion storm: reactor ceil(level / 2)", st.reactor_capacity(), ceili(cap0 / 2.0))
	check("ion storm: power within the cap", st.reactor_used() <= st.reactor_capacity(), true)
	var ne := ShipState.new("PLAYER_SHIP_HARD", true)
	HazardRule.create(HazardRule.Env.NEBULA, 2, 1, 2).apply_status(ne)
	check("nebula: sensors at 0", ne.sys("sensors").effective_power() if ne.sys("sensors") else 0, 0)
	check("nebula / storm are not dangerous", [HazardRule.create(3, 2, 1, 2).is_dangerous(),
		HazardRule.create(4, 2, 1, 2).is_dangerous(), sun.is_dangerous()], [false, false, true])

	# --- FTL drive
	var k := ShipState.new("PLAYER_SHIP_HARD", true)
	check("Kestrel flies (engines + manned pilot)", FtlDrive.ship_flying(k), true)
	var e := k.sys("engines")
	var base := (float(e.effective_power() - 1) * 0.35 + 1.25) * 0.0625
	check("engine speed per clock unit", is_equal_approx(FtlDrive.engine_speed(k), base * [1.0, 1.1, 1.17, 1.25][
		k.crew_level_in("engines")]), true)
	k.ftl_charge = 0.0
	FtlDrive.tick(k, 1.0, false)
	check("charge per second = speed × 16 / 85", is_equal_approx(k.ftl_charge, FtlDrive.engine_speed(k) * 16.0 / 85.0),
		true)
	FtlDrive.tick(k, 0.1, true)
	check("safe → full", k.ftl_charge, 1.0)
	k.ftl_charge = 0.0
	k.fuel = 0
	FtlDrive.tick(k, 0.1, false)
	check("no fuel → full", k.ftl_charge, 1.0)
	k.fuel = 5
	k.ftl_charge = 0.0
	while k.decrease_power("engines"):
		pass
	FtlDrive.tick(k, 10.0, false)
	check("no engine power → no charge", k.ftl_charge, 0.0)

	_test_hazard_sounds()


## rules/hazards.md §7b: every hazard sound name resolves in sounds.xml (environWarning's closing tag has a space),
## and over two full cycles of the HUD + hazard the alarm `environWarning` plays exactly once per cycle, 5 s before
## the flare / pulse / volley (WarningMessage::Start while not running; the message loops), the flare / pulse sound
## 1.2 s before; the ASB plays fleetFireLight / fleetFireHeavy at its firing steps.
func _test_hazard_sounds() -> void:
	print("hazard sounds")
	var names := ["environWarning", "solarFlare", "pulsar", "fleetFireHeavy", "fleetFireLight", "hitHull1",
		"lightning1", "nebula"]
	var found := []
	for n in names:
		found.append(FtlData.has_sound(n))
	check("hazard sounds exist in sounds.xml / dlcSounds.xml", found, names.map(func(_n): return true))
	var was_muted := FtlData.muted
	FtlData.muted = true
	FtlData.record_plays = true
	const DT := 1.0 / 60.0
	for env in [HazardRule.Env.SUN, HazardRule.Env.PULSAR, HazardRule.Env.PDS]:
		var run := RunState.new()
		run.hazard = HazardRule.create(env, 0, 5, 2)
		var hud := HazardHud.new()
		hud.setup(run)
		add_child(hud)
		hud.set_process(false)  # driven below, in step with the hazard
		var ship := ShipState.new("PLAYER_SHIP_HARD", true)
		FtlData.play_log.clear()
		var t := 0.0
		var warn_at := []  # remaining() when environWarning played
		var hit_at := []  # remaining() when the flare / pulse sound played
		var cycles := 0
		var guard := 0.0
		while cycles < 2 and guard < 120.0:
			var before := run.hazard.flares
			run.hazard.tick(DT, [ship])
			var rem := run.hazard.remaining()
			hud._process(DT)
			for rec in FtlData.play_log:
				match String(rec.name):
					"environWarning":
						warn_at.append(rem)
					"solarFlare", "pulsar":
						hit_at.append(rem)
			FtlData.play_log.clear()
			if run.hazard.flares != before:
				cycles += 1
			t += DT
			guard += DT
		var label: String = ["", "", "sun", "", "", "pulsar", "pds"][env]
		print("    %s: alarm at %s, hit sound at %s s left" % [label, str(warn_at), str(hit_at)])
		check("%s: two cycles ran" % label, cycles, 2)
		check("%s: environWarning once per cycle" % label, warn_at.size(), 2)
		check("%s: environWarning at 5 s left" % label, warn_at.all(func(r): return r < 5.0 and r >= 5.0 - 2 * DT),
			true)
		if env != HazardRule.Env.PDS:
			check("%s: flare / pulse sound once per cycle, 1.2 s before" % label,
				[hit_at.size(), hit_at.all(func(r): return r < 1.2 and r >= 1.2 - 2 * DT)], [2, true])
		hud.queue_free()
	# ASB firing steps: one fleetFire sound per queued shot (Heavy = a real volley shot, Light = decoy / dodged).
	var pds := HazardRule.create(HazardRule.Env.PDS, 0, 5, 2)
	var p := ShipState.new("PLAYER_SHIP_HARD", true)
	FtlData.play_log.clear()
	for i in 1800:  # 30 s
		pds.tick(DT, [p])
	var fire := FtlData.play_log.filter(func(r): return String(r.name).begins_with("fleetFire"))
	check("pds: a fleetFire sound per shot", fire.size(), pds.pds_shots)
	check("pds: Heavy for each volley shot that failed its dodge, Light for the rest",
		[fire.filter(func(r): return r.name == "fleetFireHeavy").size(), fire.all(func(r): return r.name in [
		"fleetFireHeavy", "fleetFireLight"])], [pds.pds_volley_hits, true])
	FtlData.record_plays = false
	FtlData.play_log.clear()
	FtlData.muted = was_muted
