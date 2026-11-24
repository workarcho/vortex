extends Node
## Playtest follow-ups checked against the 1.6.9 exe: ion on subsystems (sensors vision), event ship surrender /
## escape thresholds, cooldowns carried into a beacon whose event box is still open (SetSafe), skill training only
## with a ship around, teleport animation under blackout, clone death sound, QoL heal / repair lines and scanners
## on the type C ships. Run:
##   godot --headless --path godot res://tests/test_playtest_vanilla.tscn

const Harness := preload("res://tests/harness.gd")

const DT := 1.0 / 60.0
const F := DT * GameClock.BASE

var fails := 0
var rng := RandomNumberGenerator.new()


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func run(s: ShipState, seconds: float) -> void:
	var t := 0.0
	while t < seconds - 1e-6:
		s.tick(F)
		t += DT


func close_dialogs(r: RunState) -> void:
	for i in 10:
		if r.phase == RunState.Phase.DIALOG:
			var first := r.dialog_choices.find_custom(func(v): return v.enabled)
			r.choose(maxi(first, 0))
		elif r.phase == RunState.Phase.MESSAGE:
			r.apply(RunIntent.make(RunIntent.CONTINUE))


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	FtlData.muted = true
	rng.seed = 1234
	_ion_subsystems()
	_surrender()
	_cloak_cooldown_across_jump()
	_skill_training()
	_teleport_blackout()
	_clone_death_sound()
	_qol_lines()


## ShipSystem::IonDamage -> ForceDecreasePower: a subsystem (bNeedsPower false) loses powerState.first, which
## CheckMaxPower keeps at the usable maximum only while unlocked.
func _ion_subsystems() -> void:
	print("Ion on sensors (weapon ion and pulsar)")
	var s := ShipState.new("PLAYER_SHIP_HARD", true)
	run(s, DT)
	var sens := s.sys("sensors")
	check("sensors not manned on the Kestrel at start", sens.manning_boost, 0)
	check("sensors level 1: own interior visible", [s.sensors_provide(1), s.blacked_out_rooms().is_empty()], [true, true])
	var d := Damage.new()
	d.ion = 1
	s.apply_damage(sens.room, d, rng)
	check("ion 1 (weapon): sensors locked, power 0", [sens.ion, sens.effective_power()], [1, 0])
	check("  own interior no longer provided (DoSensorsProvide(1))", s.sensors_provide(1), false)
	var blk := s.blacked_out_rooms()
	check("  rooms without crew blacked out", blk.is_empty(), false)
	var crewed := s.crew.filter(func(c): return c.is_alive()).map(func(c): return c.room)
	check("  rooms with own crew still lit", crewed.any(func(r): return blk.has(r)), false)
	run(s, 4.9)
	check("still dark at 4.9 s", s.sensors_provide(1), false)
	run(s, 0.2)
	check("lock over after 5 s: vision back (CheckMaxPower -> usable maximum)", [sens.ion, sens.effective_power(),
		s.sensors_provide(1)], [0, 1, true])

	print("Ion on a level 2 sensors (1 bar left)")
	var s2 := ShipState.new("PLAYER_SHIP_HARD", true)
	s2.sys("sensors").level = 2
	run(s2, DT)
	check("level 2: enemy interior provided (> 1)", s2.sensors_provide(2), true)
	s2.ion_system("sensors", 1)
	check("ion 1: power 1 -> own interior yes, enemy interior no", [s2.sensors_provide(1), s2.sensors_provide(2)],
		[true, false])
	s2.damage_system("sensors", 2)  # usable max 0: power clamped to 0
	run(s2, DT)
	s2.sys("sensors").damage = 0  # repaired during the lock: stays clamped until the lock ends
	run(s2, DT)
	check("  bar broken and repaired while locked: still 0 (only clamped down while locked)",
		s2.sys("sensors").effective_power(), 0)
	run(s2, 5.1)
	check("  after the lock: full level 2 again", s2.sys("sensors").effective_power(), 2)

	print("Pulsar ion on sensors (ShipManager::PulsarDamage -> the same IonDamage)")
	var hit_sensors := false
	for seed in 200:
		var p := ShipState.new("PLAYER_SHIP_HARD", true)
		p.set_power_loss("shields", p.sys("shields").get_level())  # no shield power: two random systems
		run(p, DT)
		var pul := HazardRule.create(HazardRule.Env.PULSAR, 2, seed, 2)
		var hit: Array = pul.pulsar_damage(p)
		if hit.has("sensors"):
			hit_sensors = true
			check("pulsar hit sensors (seed %d): ion 1, power 0, own interior dark" % seed,
				[p.sys("sensors").ion, p.sys("sensors").effective_power(), p.sensors_provide(1)], [1, 0, false])
			break
	check("some pulsar seed ions the sensors", hit_sensors, true)

	print("Ion on piloting: no evasion while locked")
	var k := ShipState.new("PLAYER_SHIP_HARD", true)
	run(k, DT)
	var before := k.dodge_factor()
	k.ion_system("pilot", 1)
	check("piloting effective power 0 while ioned", k.sys("pilot").effective_power(), 0)
	check("  evasion 0 (was %d)" % before, k.dodge_factor(), 0)


## WorldManager::CreateShip: escape L/2 + SelectAmount, then surrender L/2 + SelectAmount; `chance` is the chance
## of none (EventsParser::PullMinMax -> RandomAmount::chanceNone).
func _surrender() -> void:
	print("Surrender / escape thresholds")
	var r := RunState.new_run(2024)
	close_dialogs(r)
	var eng := r.engine
	var pirate: XmlNode = eng.db.ships["PIRATE"]
	var counts := {}
	for seed in 400:
		var t: int = int(eng.setup_ship({"template": "PIRATE", "node": pirate, "seed": seed}).surrender_threshold)
		counts[t] = int(counts.get(t, 0)) + 1
	var keys := counts.keys()
	keys.sort()
	check("sector 1 PIRATE (<surrender chance=0.5 min=3 max=4>): thresholds only 0, 3, 4", keys, [0, 3, 4])
	var none := float(counts.get(0, 0)) / 400.0
	check("  about half never surrender (%.2f)" % none, none > 0.4 and none < 0.6, true)
	eng.level = 6
	var high := int(eng.setup_ship({"template": "PIRATE", "node": pirate, "seed": 5}).surrender_threshold)
	check("  sector 7: + level/2 = 3 (got %d)" % high, high in [3, 6, 7], true)
	eng.level = 0
	var bare := ""
	for n in eng.db.ships:
		var node: XmlNode = eng.db.ships[n]
		if node != null and node.child("surrender") == null and node.child("escape") == null:
			bare = n
			break
	check("a ship template without <surrender> / <escape> exists", bare != "", true)
	if bare != "":
		eng.level = 4
		var st := eng.setup_ship({"template": bare, "node": eng.db.ships[bare], "seed": 1})
		check("  no <surrender>: threshold level/2 = 2, no event", [st.surrender_threshold, st.has_surrender],
			[2, false])
		eng.level = 0
	var vals := {}
	for i in 60:
		vals[eng.select_amount(3, 0)] = true
	check("SelectAmount min 3 max 0: swapped by PullMinMax -> [0, 3], not always 3", vals.size() > 1, true)

	print("Silent surrender (no surrender event): no escape afterwards")
	var ev := {"template": "PIRATE", "node": pirate, "hostile": true, "seed": 3}
	r._spawn_enemy(ev)
	var es := r.build_enemy_ship()
	r.enemy.has_surrender = false
	r.enemy.surrender_threshold = 2
	r.enemy.has_escape = true
	r.enemy.escape_threshold = 1
	es.hull = 3
	check("above both thresholds: nothing", r.check_combat(es, 0.1), "")
	es.hull = 2
	check("at the surrender threshold without an event: no box", r.check_combat(es, 0.1), "")
	check("  but surrendered is set", r.enemy.surrendered, true)
	es.hull = 1
	check("  escape threshold reached later: ShipAI::Escape refuses (surrendered)", [r.check_combat(es, 0.1),
		r.enemy.escaping], ["", false])
	_escape(r, pirate)


## Escape: <escape chance min max timer> read like <surrender> (chance = never flees); SetEscapeTimer (<= 0 -> 15 s);
## ShipAI::OnLoop counts down 1 s/s (0.5 with FTL_JAMMER) only while JumpCharging = ShipFlying (engines and piloting
## Functioning, neither under a hack pulse); timer < 0 -> JumpLeave.
func _escape(r: RunState, pirate: XmlNode) -> void:
	print("Escape thresholds and countdown")
	var eng := r.engine
	eng.level = 0
	var fleeing := 0
	var top := -1000
	for seed in 400:
		var st := eng.setup_ship({"template": "PIRATE", "node": pirate, "seed": seed})
		if int(st.escape_threshold) >= 1:
			fleeing += 1
		top = maxi(top, int(st.escape_threshold))
	var frac := float(fleeing) / 400.0
	check("sector 1 PIRATE <escape chance=0.5 min=2 max=4>: about half can flee (%.2f), never above hull 4" % frac,
		[frac > 0.4 and frac < 0.6, top <= 4], [true, true])
	check("  no timer attribute: 15 s", float(eng.setup_ship({"template": "PIRATE", "node": pirate, "seed": 1}).escape_timer),
		15.0)
	if eng.db.ships.has("PIRATE_FUEL"):
		check("  timer=\"80\" (PIRATE_FUEL): 80 s", float(eng.setup_ship({"template": "PIRATE_FUEL",
			"node": eng.db.ships["PIRATE_FUEL"], "seed": 1}).escape_timer), 80.0)
	var r2 := RunState.new_run(99)
	close_dialogs(r2)
	r2._spawn_enemy({"template": "PIRATE", "node": pirate, "hostile": true, "seed": 4})
	var es := r2.build_enemy_ship()
	r2.enemy.escaping = true
	r2.enemy.escape_timer = 10.0
	es.tick(F)
	check("enemy can fly (engines + manned piloting)", FtlDrive.ship_flying(es), true)
	r2.check_combat(es, 1.0)
	check("countdown 1 s per s", float(r2.enemy.escape_timer), 9.0)
	es.ion_system("pilot", es.sys("pilot").get_level())  # every bar (a level-2 piloting hit by 1 ion still works)
	r2.check_combat(es, 1.0)
	check("ionized piloting: not JumpCharging, timer frozen (ENEMY FTL DELAYED)", float(r2.enemy.escape_timer), 9.0)
	es.sys("pilot").lock_system(0)
	es.ion_system("engines", es.sys("engines").effective_power())
	check("engines fully ionized: frozen too", [FtlDrive.ship_flying(es), r2.check_combat(es, 1.0),
		float(r2.enemy.escape_timer)], [false, "", 9.0])
	es.sys("engines").lock_system(0)
	es.check_for_repower(es.sys("engines"))
	if not FtlDrive.engines_function(es):
		es.increase_power("engines", false)
	r2.ship.augments.append("FTL_JAMMER")
	var before := float(r2.enemy.escape_timer)
	r2.check_combat(es, 1.0)
	check("FTL_JAMMER on the player: 0.5 s per s", before - float(r2.enemy.escape_timer), 0.5)


## ShipManager::JumpLeave -> CloakingSystem::Jump (on: decloak + AddLock(4)); JumpArrive clears no cloak lock; only
## SetSafe (WorldManager::OnLoop, not run while the arrival event box is open) does.
func _cloak_cooldown_across_jump() -> void:
	print("Cloak cooldown across a jump")
	for fight in [true, false]:
		var r := RunState.new_run(77, "PLAYER_SHIP_STEALTH")
		close_dialogs(r)
		var cl := r.ship.sys("cloaking")
		check("stealth ship has cloaking", cl != null, true)
		if cl == null:
			return
		check("cloak on at the start beacon", CloakRule.turn_on(r.ship), true)
		r.ship.cloak_fade = ShipState.CLOAK_FADE
		var to: int = int(r.map.links_of(r.current_beacon)[0])
		r.map.beacons[to].event = r.engine.base_event("PIRATE_CHOICE")
		r.jump_to(to)
		check("JumpLeave: decloaked, AddLock(4) = 20 s cooldown", [cl.turned_on, cl.ion], [false, 4])
		check("  hull not drawn cloaked at the new beacon (tracker done during the jump)", r.ship.cloak_fade, 0.0)
		check("  PIRATE_CHOICE box open, ship not hostile yet", [r.phase == RunState.Phase.DIALOG, r.has_hostile()],
			[true, false])
		check("  no SetSafe under the box: cooldown kept, FTL drive empty", [cl.ion, r.ship.ftl_charge], [4, 0.0])
		if fight:
			r.choose(1)  # "fight": <ship hostile="true"/>
			close_dialogs(r)
			check("fight chosen: hostile, cooldown still running", [r.has_hostile(), cl.ion], [true, 4])
		else:
			r.choose(0)  # pay: the ship stays neutral
			close_dialogs(r)
			check("paid off: no hostile ship -> SetSafe clears the cooldown", [r.has_hostile(), cl.ion], [false, 0])


## EventSystem 7 (ShipManager::GetDodged) / 8 (Shields::CollisionReal) feed CrewMember::CheckSkills.
func _skill_training() -> void:
	print("Skill training needs a ship around")
	var s: ShipState = null
	var pc: CrewMember = null
	var sc: CrewMember = null
	for bp in ["PLAYER_SHIP_HARD", "PLAYER_SHIP_FED", "PLAYER_SHIP_CIRCLE", "PLAYER_SHIP_STEALTH", "PLAYER_SHIP_MANTIS",
			"PLAYER_SHIP_JELLY", "PLAYER_SHIP_ENERGY", "PLAYER_SHIP_ROCK"]:
		s = ShipState.new(bp, true)
		run(s, DT)
		pc = s.active_manning_crew("pilot")
		sc = s.active_manning_crew("shields")
		if pc != null and sc != null:
			break
	check("a start ship with pilot and shields manned (%s)" % s.blueprint.name, [pc != null, sc != null], [true, true])
	if pc == null or sc == null:
		return
	var r := RandomNumberGenerator.new()
	r.seed = 9
	var dodged := 0
	for i in 400:
		if s.roll_dodged(r):
			dodged += 1
	check("asteroid-style dodges with no ship and no intruders (%d)" % dodged, [dodged > 0,
		int(pc.skills.get("pilot", 0))], [true, 0])
	var d := Damage.new()
	d.damage = 1
	s.shield_layers = 2
	s.on_projectile_enters_shield(d, r)
	check("shield hit with no ship around: no shields training", int(sc.skills.get("shields", 0)), 0)
	var e := ShipState.new("REBEL_FAT", false)
	s.opponent = e
	e.opponent = s
	e.hostile = false  # a neutral ship still counts (current_target / bEnemyPresent)
	for i in 400:
		s.roll_dodged(r)
	check("with a (neutral) ship at the beacon: dodges train piloting", int(pc.skills.get("pilot", 0)) > 0, true)
	var ion := Damage.new()
	ion.ion = 1
	s.shield_layers = 2
	var before := int(sc.skills.get("shields", 0))
	var res := s.on_projectile_enters_shield(ion, r)
	if res == "shield":
		check("ion-only shot absorbed: no training (iDamage 0)", int(sc.skills.get("shields", 0)), before)
	s.shield_layers = 2
	for i in 20:
		s.shield_layers = 2
		if s.on_projectile_enters_shield(d, r) == "shield":
			break
	check("damage absorbed with a ship present: shields train", int(sc.skills.get("shields", 0)) > before, true)
	e.hull = 0
	e.explosion = null
	check("ship destroyed (explosion pending): still a target", s.has_target_ship(), true)
	e.jumping = true
	check("ship jumped away: no target", s.has_target_ship(), false)


func _teleport_blackout() -> void:
	print("Teleport animation follows the crew blackout gate")
	var v := ShipView.new()
	v.drew_interior = true
	v._blk = {3: true}
	check("blacked-out room hides crew (and their teleport)", [v.crew_hidden(3), v.crew_hidden(2)], [true, false])
	v.drew_interior = false
	check("interior not drawn (cloaked enemy): hidden", v.crew_hidden(2), true)
	v.free()


func _clone_death_sound() -> void:
	print("Clone death sound")
	var s := ShipState.new("TEST_SHIP_ALL_CLONE", true)
	s.reactor_max = 40
	var c := s.crew[0]
	c.hp = 0.0
	c.death_sound_done = true  # the view played the first death sound
	s.crew_changed()
	var t := 0.0
	while t < 13.5 and not c.is_alive():
		s.tick(F)
		ClonebayRule.collect_dead(s, [s])
		ClonebayRule.tick(s, DT)
		t += DT
	check("cloned", c.is_alive(), true)
	check("  its next death plays the death sound again", c.death_sound_done, false)


func _qol_lines() -> void:
	print("QoL weapon lines and scanners")
	var qol: Object = Mods.entry("qol")
	check("qol mod loaded", qol != null, true)
	if qol == null:
		return
	var lines := []
	for g in qol.weapon_stat_groups(FtlData.weapon_blueprint("BOMB_HEAL")):
		lines += g
	check("heal bomb: 'Crew Healing: 150', no negative crew damage", [lines.has("Crew Healing: 150"),
		lines.any(func(l): return String(l).contains("-150"))], [true, false])
	lines = []
	for g in qol.weapon_stat_groups(FtlData.weapon_blueprint("BOMB_HEAL_SYSTEM")):
		lines += g
	check("repair bomb: a System Repair line", lines.any(func(l): return String(l).begins_with("System Repair: ")),
		true)
	RunState.current = null  # the runs above froze the gameplay settings (Settings.freeze_run)
	Settings.thaw()
	Settings.reset_user()
	FtlData.clear_data_cache()
	Settings.set_group_enabled("qol_scanners", true)
	check("start with scanners: type C ships (dlcBlueprintsOverwrite.xml) too",
		[ShipState.new("PLAYER_SHIP_ROCK_3", true).has_augment("ADV_SCANNERS"),
		ShipState.new("PLAYER_SHIP_ROCK", true).has_augment("ADV_SCANNERS")], [true, true])
	Settings.set_group_enabled("qol_scanners", false)
	Settings.reset_user()
	FtlData.clear_data_cache()
