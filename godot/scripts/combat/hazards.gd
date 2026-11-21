class_name HazardRule
extends RefCounted
## Beacon environmental hazards (rules/hazards.md): sun flares, asteroids, pulsar ion pulses, ion storm, nebula
## and the ASB/PDS volley. One instance per beacon (kept by the run across scene rebuilds); `tick` runs every
## unpaused frame with the ships in the space; asteroids are real projectiles added to the Combat.
## Timers are real (game) seconds. Not tied to combat: they run with or without an enemy.
## Stacking (rules/hazards.md §0b): like SpaceManager, every environment is its own flag; each event's
## <environment> is ADDED by WorldManager::ModifyEnvironment (`add_environment`), nothing clears them until the
## beacon is left. Sun, pulsar and ASB share one flash timer (the last one set gives its period); an active ASB
## suspends the sun / pulsar block; asteroids and nebula / storm run alongside anything.

enum Env { NONE = -1, ASTEROIDS = 1, SUN = 2, NEBULA = 3, STORM = 4, PULSAR = 5, PDS = 6 }

const WARN_LEAD := 5.0
const SOUND_LEAD := 1.2
const FLASH_LEAD := 0.5
const FLASH_LEN := 1.0
const PERIODS := {Env.SUN: [28.0, 34.0], Env.PULSAR: [11.0, 18.0], Env.PDS: [20.0, 25.0]}
## Asteroid generator table by player shield level / 2: [idle, slow, fast] lengths (s), [slow, fast] intervals (ms).
const AST_STATES := [[[5, 10], [8, 16], [5, 8]], [[5, 10], [8, 16], [5, 8]], [[5, 10], [10, 20], [5, 10]],
	[[12, 15], [16, 28], [8, 13]], [[12, 15], [16, 30], [8, 11]]]
const AST_RATES := [[[1800, 2200], [1400, 1600]], [[1800, 2200], [1400, 1600]], [[1000, 1800], [900, 1300]],
	[[900, 1400], [900, 1300]], [[720, 1350], [540, 950]]]
const AST_SPEED := 35.0  # units per clock factor = 560 px/s
const AST_SPIN := 160.0  # deg/s
## ASB (SpaceManager::SetPlanetaryDefense / UpdatePDS / OnInit): the populated planet's top-left, the fleet's gun
## ship rect (fleet_big.png at (550, 447), w = 2·334 − 100, h = 132 + 25), the decoy side point x, timers.
const PDS_PLANET_POS := Vector2i(600, 247)
const PDS_FLEET_GUN := Rect2i(550, 447, 568, 157)
const PDS_DECOY_X := -400.0
const PDS_QUEUE_GAP := 0.5

var env := Env.NONE  # the first environment of the beacon (map / achievements use it)
var envs := {}  # every environment set at this beacon (Env -> true): SpaceManager's independent flags
var target := 2  # PDS only: 0 player, 1 enemy, 2 all
var period: Array = [28.0, 34.0]  # flashTimer min / max (s): of the last sun / pulsar / PDS set
var screen_shake_queued := false  # SpaceManager::queueScreenShake (an ASB shot left the gun; ScreenShake reads it)
var rng := RandomNumberGenerator.new()
var timer := 0.0  # flash timer (sun / pulsar / PDS volley)
var goal := 30.0
var sound_done := false
var flash := -1.0  # s into the 1.0 s screen flash (-1 = none)
var flares := 0  # sun flares / pulsar pulses so far
# asteroids
var ast_state := 0  # 0 idle, 1 slow, 2 fast
var ast_state_timer := 0.0
var ast_spawn_timer := -1.0
var ast_level := 0
var ast_next := 0  # round-robin ship index
var asteroids_spawned := 0
var ast_targets: Array[int] = []  # ship index of every asteroid launched (tests)
var pds_timer := 2.0  # randomPDSTimer: s to the next ASB firing step
var pds_on := true  # bPDS: false once an enemy-only ASB has no enemy left (UpdatePDS)
var pds_queue: Array = []  # pdsQueue: shot specs waiting to be launched (launched last-first, 0.5 s apart)
## The ASB gun in screen (1280×720 frame) coordinates: the populated planet's centre, or the fleet's gun ship
## centre in a danger zone (`pds_origin_for`). Converted to player-ship coordinates at launch.
var pds_origin := Vector2(PDS_PLANET_POS) + Vector2(64, 64)
var pds_shots := 0  # ASB shots launched (real + decoys; tests)
var pds_volley_hits := 0  # volley shots aimed for real (dodge failed; tests)
var log: Array[String] = []
## DamageMessages of the last flare / pulse, shown by `tick` through the Combat's spaces: [ship, kind, value, room]
## (kind "hull" white number at the room centre, "ion" ion-blue number, "resist" ion-blue RESIST, "super" green
## number at the shield centre; room -1 = the shield centre).
var messages: Array = []


## WorldManager::ModifyEnvironment on arrival. `player_shield_level`: shield system level (asteroid table).
static func create(env_id: int, env_target: int, seed: int, player_shield_level: int) -> HazardRule:
	var h := HazardRule.new()
	h.target = env_target
	h.rng.seed = seed
	h.add_environment(env_id, env_target, player_shield_level)
	return h


## WorldManager::ModifyEnvironment(envFlag, envTarget): sets one more environment flag at this beacon (the arrival
## event's, then any later event / choice outcome with an <environment>). Asteroids = StartAsteroids (generator
## re-initialised from the player's shield level); sun / pulsar = SetFireLevel / SetPulsarLevel (flash timer period
## [28, 34) / [11, 18) s, restarted); PDS = SetPlanetaryDefense (re-target + restart, `set_planetary_defense`);
## nebula = SetNebula; storm = SetStorm (+ nebula). Nothing is cleared.
func add_environment(env_id: int, env_target: int, player_shield_level: int) -> void:
	if env_id < 1 or env_id > Env.PDS:
		return
	if env == Env.NONE:
		env = env_id as Env
	envs[env_id] = true
	match env_id:
		Env.ASTEROIDS:
			ast_level = clampi(player_shield_level / 2, 0, 4)
			ast_state = 2 - int(rng.randi() & 1)
			ast_state_timer = _draw(AST_STATES[ast_level][ast_state])
			ast_spawn_timer = -1.0
		Env.SUN, Env.PULSAR:
			period = PERIODS[env_id]
			_new_goal()
		Env.PDS:
			set_planetary_defense(env_target)
		Env.STORM:
			envs[Env.NEBULA] = true  # SetStorm -> SetNebula(true)


## True when `e` was set at this beacon (for PDS: and the battery is still up, bPDS).
func has_env(e: int) -> bool:
	if e == Env.PDS:
		return envs.has(Env.PDS) and pds_on
	return envs.has(e)


## The environment the backdrop shows (SpaceManager::OnRenderBackground / OnRenderForeground): nebula clouds (storm
## lightning) hide planet, sun and pulsar; else the sun, else the pulsar, else the (ASB) planet.
func visual_env() -> int:
	for e in [Env.STORM, Env.NEBULA, Env.SUN, Env.PULSAR, Env.PDS, Env.ASTEROIDS]:
		if envs.has(e):
			return e
	return Env.NONE


## SpaceManager::GetScreenShake: returns queueScreenShake and clears it.
func take_screen_shake() -> bool:
	var q := screen_shake_queued
	screen_shake_queued = false
	return q


func _draw(r: Array) -> float:
	return float(int(r[0]) + int(rng.randi() % (int(r[1]) - int(r[0]) + 1)))


func _new_goal() -> void:
	var p: Array = period
	var lo := int(p[0] * 1000)
	var hi := int(p[1] * 1000)
	goal = float(lo + int(rng.randi() % (hi - lo))) / 1000.0
	timer = 0.0
	sound_done = false


## SpaceManager::DangerousEnvironment: an ASB aimed only at the enemy makes the beacon safe whatever else is there;
## otherwise sun, running asteroids, ASB or pulsar.
func is_dangerous() -> bool:
	if has_env(Env.PDS) and target == 1:
		return false
	return has_env(Env.SUN) or has_env(Env.ASTEROIDS) or has_env(Env.PDS) or has_env(Env.PULSAR)


## Seconds before the next flare / pulse / volley (INF without one).
func remaining() -> float:
	return goal - timer if has_env(Env.SUN) or has_env(Env.PULSAR) or has_env(Env.PDS) else INF


## SpaceStatus::OnLoop: [currentEffect, currentEffect2] for the HUD icons. Asteroids 1, sun 2, pulsar 5, PDS 6
## (9 = aimed only at the enemy: green "ALLIES!"), nebula 3 (+ 4 with the ion storm), none 0. ONE icon when several
## environments stack, by priority: asteroids > ASB > sun > pulsar > nebula (the storm's second icon only with the
## nebula one).
func hud_effects() -> Array:
	if has_env(Env.ASTEROIDS):
		return [1, 0]
	if has_env(Env.PDS):
		return [9 if target == 1 else 6, 0]
	if has_env(Env.SUN):
		return [2, 0]
	if has_env(Env.PULSAR):
		return [5, 0]
	if has_env(Env.NEBULA):
		return [3, 4 if has_env(Env.STORM) else 0]
	return [0, 0]


## SpaceStatus::MouseMove tooltip text id for an effect (`tooltip_<name>`), "" for none. `danger_zone` = the PDS
## of a fleet-overtaken beacon (tooltip_PDS_FLEET).
func hud_tooltip(effect: int, danger_zone := false) -> String:
	match effect:
		1:
			return "tooltip_asteroids"
		2:
			return "tooltip_sun"
		3:
			return "tooltip_nebula"
		4:
			return "tooltip_storm"
		5:
			return "tooltip_pulsar"
		6, 9:
			if danger_zone:
				return "tooltip_PDS_FLEET"
			return ["tooltip_PDS_PLAYER", "tooltip_PDS_ENEMY", "tooltip_PDS_ALL"][clampi(target, 0, 2)]
	return ""


## Warning text id while < 5 s are left (warning_solar_flare / warning_ion_pulse / warning_pds_locked), else "".
## SpaceStatus::OnLoop: running asteroids leave the message alone (never started here); sun / pulsar text first
## (also while an ASB drives the shared timer), else the ASB lock.
func warning() -> String:
	if has_env(Env.ASTEROIDS) or remaining() >= WARN_LEAD:
		return ""
	if has_env(Env.SUN):
		return "warning_solar_flare"
	if has_env(Env.PULSAR):
		return "warning_ion_pulse"
	if has_env(Env.PDS):
		return "warning_pds_locked"
	return ""


## Status effects at arrival (CheckStatusEffects): nebula = sensors limited to 0, ion storm = also the reactor
## divided by 2. Applied to every ship given (both sides).
func apply_status(ship: ShipState) -> void:
	if has_env(Env.NEBULA):
		var s := ship.sys("sensors")
		if s:
			ship.set_power_loss("sensors", s.get_level())
	if has_env(Env.STORM):
		ship.reactor_divide = 2
		ship._check_reactor()


## One frame. `ships`: [player, enemy or null] (index = asteroid round robin); `combat` adds asteroid shots.
func tick(seconds: float, ships: Array, combat: Combat = null) -> void:
	if flash >= 0.0:
		flash += seconds
		if flash > FLASH_LEN:
			flash = -1.0
	# SpaceManager::OnLoop: an ASB (bPDS) runs UpdatePDS INSTEAD of the sun / pulsar block.
	if has_env(Env.PDS):
		_tick_pds(seconds, ships, combat)
	elif has_env(Env.SUN) or has_env(Env.PULSAR):
		timer += seconds
		var rem := goal - timer
		if rem < SOUND_LEAD and not sound_done:
			sound_done = true
			FtlData.play("solarFlare" if has_env(Env.SUN) else "pulsar")  # the sun's sound wins
		if rem < FLASH_LEAD and flash < 0.0:
			flash = 0.0
		if timer >= goal:
			flares += 1
			for s in ships:
				if s != null and not s.jumping and not s.is_destroyed():
					if has_env(Env.PULSAR):
						pulsar_damage(s)  # the pulsar's damage wins
					else:
						sun_damage(s)
			_new_goal()
			_show_messages(combat)
	if has_env(Env.ASTEROIDS):
		_tick_asteroids(seconds, ships, combat)


## ShipManager::SunDamage: 3–6 fires (no shield layer, no super shield) else 1–2, in random rooms; each room with
## fires rolls 33 % × fires for 1 system + 1 hull damage.
func sun_damage(ship: ShipState) -> Dictionary:
	var count := 3 + int(rng.randi() % 4) if ship.shield_layers < 1 and ship.super_shield < 1 \
		else 1 + int(rng.randi() % 2)
	var rooms: Array = ship.layout.rooms
	var per_room := {}
	var i := 0
	while i < count:
		var amount := 1 if i == count - 1 else 1 + int(rng.randi() % 2)
		var room: int = rooms[rng.randi() % rooms.size()].id
		for k in amount:
			ship.ignite(room, int(rng.randi() % maxi(ship.room_tiles(room), 1)))
		per_room[room] = int(per_room.get(room, 0)) + amount
		i += amount
	var hits := 0
	var ids := per_room.keys()
	ids.sort()
	for room in ids:
		if int(rng.randi() % 100) < 33 * int(per_room[room]):
			var s := ship.system_in_room(room)
			if s:
				ship.damage_system(s.id, 1)
			ship.take_hull_damage(1)
			messages.append([ship, "hull", 1, room])  # DamageMessage "1" at the room centre
			hits += 1
	log.append("sun: %d fires, %d hits on %s" % [count, hits, ship.blueprint.name])
	return {"fires": count, "hits": hits}


## ShipManager::PulsarDamage: ION_ARMOR resists 50 %; super shield loses 3–4 points (nothing else); powered
## shields get ion power/2+1 plus one other system, else two systems; each ion = power/2 + 1.
func pulsar_damage(ship: ShipState) -> Array:
	var hit := []
	if ship.has_augment("ION_ARMOR"):
		var chance := int(ship.augment_value("ION_ARMOR", 0.5) * 10.0)
		if 1 + int(rng.randi() % 10) <= chance:
			log.append("pulsar: resisted by %s" % ship.blueprint.name)
			# RESIST (ion blue) at the shield room when shields are powered or a super shield is up, else at two
			# distinct random systems (picked as below).
			var shr := ship.sys("shields")
			if shr != null and (shr.effective_power() > 0 or ship.super_shield > 0):
				messages.append([ship, "resist", 0, shr.room])
			else:
				var rids := ship.system_list()
				var rprev := ""
				for k in 2:
					if rids.size() < 2 and rprev != "":
						break
					var rid: String = rids[rng.randi() % rids.size()]
					var g := 0
					while rid == rprev and g < 50:
						rid = rids[rng.randi() % rids.size()]
						g += 1
					messages.append([ship, "resist", 0, ship.sys(rid).room])
					rprev = rid
			return hit
	var n := 2
	var prev := ""
	var sh := ship.sys("shields")
	if sh != null:
		if ship.super_shield >= 1:
			var drain := mini(3 + int(rng.randi() % 2), ship.super_shield)
			ship.damage_super_shield(drain)
			messages.append([ship, "super", drain, -1])  # Shields::PulsarDamage: green number at the shield
			return hit
		if sh.effective_power() > 0:
			messages.append([ship, "ion", sh.effective_power() / 2 + 1, sh.room])
			ship.ion_system("shields", sh.effective_power() / 2 + 1)
			hit.append("shields")
			prev = "shields"
			n = 1
	var ids := ship.system_list()
	for k in n:
		if ids.size() < 2 and prev != "":
			break
		var id: String = ids[rng.randi() % ids.size()]
		var guard := 0
		while id == prev and guard < 50:
			id = ids[rng.randi() % ids.size()]
			guard += 1
		var s := ship.sys(id)
		messages.append([ship, "ion", s.effective_power() / 2 + 1, s.room])
		ship.ion_system(id, s.effective_power() / 2 + 1)
		hit.append(id)
		prev = id
	log.append("pulsar: ion %s on %s" % [str(hit), ship.blueprint.name])
	return hit


func _tick_asteroids(seconds: float, ships: Array, combat: Combat) -> void:
	ast_state_timer -= seconds
	if ast_state_timer < 0.0:
		ast_state = (1 + int(rng.randi() % 2)) if ast_state == 0 else 0
		ast_state_timer = _draw(AST_STATES[ast_level][ast_state])
	if ast_state == 0:
		return
	if ast_spawn_timer <= 0.0:
		var idx := ast_next
		ast_next = (ast_next + 1) % maxi(ships.size(), 1)
		var ship: ShipState = ships[idx] if idx < ships.size() else null
		ast_targets.append(idx if ship != null else -1)
		if ship != null and not ship.is_destroyed() and combat != null:
			_spawn_asteroid(ship, idx == 0, combat)
		ast_spawn_timer = _draw(AST_RATES[ast_level][ast_state - 1]) / 1000.0
	else:
		ast_spawn_timer -= seconds


func _spawn_asteroid(ship: ShipState, player: bool, combat: Combat) -> void:
	var sp := combat.space_of(ship)
	if sp == null:
		return
	var center := ship.shield_center
	var side := int(rng.randi() % 4) if player else 1
	var off := float(rng.randi() % 1200) - 600.0
	var start: Vector2 = center + [Vector2(-900, off), Vector2(900, off), Vector2(off, -700), Vector2(off, 700)][side]
	var p := Projectile.new()
	p.setup_asteroid(sp, start, ship.random_room_center(rng), int(rng.randi() % 10), float(rng.randi() % 360))
	combat._add_shot(sp, p)
	asteroids_spawned += 1


## SetPlanetaryDefense(true, target) again (a choice outcome with `<environment type="PDS" target=...>`, e.g.
## REBEL_PDS hacked: all / enemy): new target, volley timer restarted, firing step re-rolled; the gun stays.
func set_planetary_defense(new_target: int) -> void:
	if env == Env.NONE:
		env = Env.PDS
	envs[Env.PDS] = true
	target = new_target
	pds_on = true
	period = PERIODS[Env.PDS]
	_new_goal()
	pds_timer = 2.0 + float(rng.randi() % 200) / 100.0


## The ASB gun (screen coordinates) for a location's backdrop (RunState.space): the fleet's gun ship centre in a
## danger zone (fleetPosition ≠ 0), else the populated planet's centre (else the beacon's planet; else the default
## planet spot). Integer halves as in UpdatePDS.
static func pds_origin_for(space: Dictionary) -> Vector2:
	if int(space.get("danger", 0)) != 0:
		return Vector2(PDS_FLEET_GUN.position + PDS_FLEET_GUN.size / 2)
	var pl: Dictionary = space.get("pds_planet", {})
	if pl.is_empty():
		pl = space.get("planet", {})
	if pl.is_empty() or not pl.has("pos"):
		return Vector2(PDS_PLANET_POS) + Vector2(64, 64)
	var sz := Vector2i(pl.get("size", Vector2i.ZERO))
	return Vector2(Vector2i(pl.pos) + sz / 2)


## ShipManager::GetDodged: a non-hostile or jumping ship always dodges; else the evasion roll.
func _pds_dodged(s: ShipState) -> bool:
	if not s.hostile or s.jumping:
		return true
	return s.roll_dodged(rng)


## ASB / PDS (rules/hazards.md §6, SpaceManager::UpdatePDS). An enemy-only battery switches off for good once there
## is no enemy (or it is destroyed). The volley timer ([20, 25) s) only counts up; every firing step
## (randomPDSTimer: 2–4 s after arrival, then 2–5 s, 0.5 s while shots are queued) with an empty queue queues one
## shot per targeted ship: when the volley is due (checked, and re-rolled, only here) and the ship fails its dodge
## (GetDodged), a real shot at a random room centre (sound fleetFireHeavy), otherwise a decoy flying off to the left
## in the player's space (fleetFireLight; a dodged volley shot carries MISS). Then the last queued shot is launched
## from the gun with a smoke puff. `ships` = [player, enemy or null]; `combat` adds the shots (none in pure tests).
func _tick_pds(seconds: float, ships: Array, combat: Combat = null) -> void:
	if not pds_on:
		return
	if target == 1 and (ships.size() < 2 or ships[1] == null or (ships[1] as ShipState).destroyed_done()):
		pds_on = false
		log.append("pds: no enemy left, battery off")
		return
	timer += seconds
	pds_timer -= seconds
	if pds_timer >= 0.0:
		return
	if pds_queue.is_empty():
		var volley := timer > goal
		if volley:
			flares += 1
			_new_goal()
		for i in ships.size():
			var s: ShipState = ships[i]
			if s == null or not (i == target or target == 2):
				continue
			if volley and not _pds_dodged(s):
				var pt := s.random_room_center(rng)
				pds_queue.append({"ship": i, "point": pt, "decoy": false, "missed": false, "roll": rng.randi() % 90})
				pds_volley_hits += 1
				FtlData.play("fleetFireHeavy")
			else:
				var side := Vector2(PDS_DECOY_X, float(rng.randi() % 800))
				pds_queue.append({"ship": 0, "point": side, "decoy": true, "missed": volley, "roll": rng.randi() % 90})
				FtlData.play("fleetFireLight")
		if pds_queue.is_empty():
			return
	var shot: Dictionary = pds_queue.pop_back()
	_launch_pds(shot, ships, combat)
	screen_shake_queued = true  # UpdatePDS: queueScreenShake = true with every launched shot
	pds_shots += 1
	pds_timer = PDS_QUEUE_GAP if not pds_queue.is_empty() else 2.0 + float(rng.randi() % 300) / 100.0


## Launches a queued ASB shot from the gun (in player-ship coordinates: screen origin − the player ship's screen
## position) and its smoke puff, both in the player's space.
func _launch_pds(shot: Dictionary, ships: Array, combat: Combat) -> void:
	log.append("pds: %s shot at ship %d%s" % ["decoy" if shot.decoy else "volley", int(shot.ship),
		" (missed)" if shot.missed else ""])
	if combat == null or ships.is_empty() or ships[0] == null:
		return
	var ps := combat.space_of(ships[0])
	var target_ship: ShipState = ships[int(shot.ship)] if int(shot.ship) < ships.size() else null
	var ts := combat.space_of(target_ship) if target_ship != null else null
	if ps == null or ts == null:
		return
	var screen_ship: Vector2 = ps.fixed_origin if ps.fixed_origin != null else HudLayout.PLAYER_SHIP
	var start := pds_origin - screen_ship
	var p := PdsShot.new()
	p.setup_pds(ps, ts, start, shot.point, bool(shot.decoy), bool(shot.missed), int(shot.roll))
	combat._add_shot(ps, p)
	combat._add_shot(ps, PdsShot.Smoke.new(start))


## Shows the queued DamageMessages on the ships' spaces (none without a Combat, e.g. in the rules tests).
func _show_messages(combat: Combat) -> void:
	if combat != null:
		for m in messages:
			var ship: ShipState = m[0]
			var sp := combat.space_of(ship)
			if sp == null:
				continue
			var at: Vector2 = ship.shield_center if int(m[3]) < 0 else ship.room_rect(int(m[3])).get_center()
			match String(m[1]):
				"hull":
					sp.show_number(int(m[2]), at, Space.MSG_HULL)
				"ion":
					sp.show_number(int(m[2]), at, Space.MSG_ION)
				"resist":
					sp.show_resist(at, AugmentRule.RESIST_ROOM_COLOR)
				"super":
					sp.show_number(int(m[2]), at, AugmentRule.SUPER_DAMAGE_COLOR)
	messages.clear()


## Screen flash alpha (sun orange / pulsar blue), a³ of the 1 s flash.
func flash_alpha() -> float:
	if flash < 0.0:
		return 0.0
	var a := 1.0 - absf(flash / FLASH_LEN * 2.0 - 1.0)
	return a * a * a
