class_name AchievementTracker
extends RefCounted
## FTL's AchievementTracker (rules/save_and_profile.md §4): the per-run flags (gameFlags), the trigger conditions of
## the general achievements and of the 30 ship achievements, CheckShipAchievements (through PlayerProfile) and the
## "Achievement Unlocked!" popups (AchievementPopup). Engine-side hook listeners (owner "achievements"), registered
## by `ensure()` from ProfileTracker.ensure; every check below names the exe function it comes from.
##
## SetAchievement (exe): an achievement with a `<ship>` only counts while the run's ship (currentShip) is that ship
## in any layout (`<ship>`, `<ship>_2`, `<ship>_3`); it is earned once, a multiDifficulty one again on a higher
## difficulty (storing the new difficulty: the best one); then the popup is queued (unless the popups option is
## off) and, for a ship achievement, CheckShipAchievements runs (two of three -> layout B).
## Flags live in `RunState.track.ach` (saved with the run); counters that vanilla keeps on live objects
## (shotsFiredAtTarget per weapon, killedByBeam, hitByBeam) are kept here and are not saved.

const OWNER := "achievements"
## CrewMemberFactory::IsRace: requirements of the blue "race" choices (WorldManager::blueRaceChoices).
const RACES := ["human", "engi", "mantis", "slug", "rock", "energy", "crystal", "anaerobic"]
const ROCK_SHIPS := ["ROCK_SCOUT", "ROCK_ASSAULT", "ROCK_FIGHT"]  # WorldManager::OnLoop "destroyed_rock"
const SLICE_WINDOW := 5.0  # s of unpaused time (ShipManager::OnLoop hitByBeam)
const NO_MISSILE_WEAPON := "MISSILE_CHARGEGUN"  # counts as a missile weapon for ACH_ROCK_MISSILES

static var current_ship := ""  # AchievementTracker::currentShip: the run's player blueprint
static var difficulty := 0  # Settings::settings.difficulty of the run
static var popups: Array = []  # recentlyUnlocked: [{header, name, img, dim, sound}], oldest first
static var _volleys := {}  # weapon instance id -> volleys this beacon (ProjectileFactory::shotsFiredAtTarget)
static var _beam_kills := {}  # beam instance id -> crew killed by it (ShipManager::killedByBeam)
static var _beam_hits := {}  # ship instance id -> {room: unpaused time of the last beam hit} (hitByBeam)
static var _clock := 0.0  # unpaused seconds (CFPS::GetUnpausedTime)


static func ensure() -> void:
	var hooks: Node = Engine.get_main_loop().root.get_node_or_null("Hooks") if Engine.get_main_loop() is SceneTree \
		else null
	if hooks == null:
		return
	var table := [
		[&"run_started", _on_run_started], [&"run_loaded", _on_run_loaded], [&"beacon_arrived", _on_arrived],
		[&"choice_chosen", _on_choice], [&"store_bought", _on_store], [&"upgrades_applied", _on_upgrades],
		[&"weapon_fired", _on_weapon_fired], [&"drone_powered", _on_drone_powered],
		[&"teleport_initiated", _on_teleport], [&"crew_died", _on_crew_died], [&"crew_removed", _on_crew_removed],
		[&"crew_killed", _on_crew_killed], [&"dodge_rolled", _on_dodge_rolled], [&"projectile_dodged", _on_dodged],
		[&"projectile_hit", _on_projectile_hit], [&"beam_damage", _on_beam_damage],
		[&"combat_outcome", _on_outcome], [&"sim_tick", _on_tick], [&"resource_changed", _on_resource],
		[&"secret_sector_entered", _on_secret_sector]]
	for e in table:
		hooks.unlisten(e[0], e[1])
		hooks.listen(e[0], e[1], 1, OWNER)  # after ProfileTracker (priority 0): run.track exists


# ------------------------------------------------------------------ SetAchievement

## Layout index of `this_bp` for the ship `base` (AchievementTracker::GetShipMarker): 0 / 1 / 2, or -1.
static func layout_of(base: String, this_bp: String) -> int:
	if this_bp == base:
		return 0
	if this_bp == base + "_2":
		return 1
	if this_bp == base + "_3":
		return 2
	return -1


## True if `id` can still be earned in this run (ship gating; not yet earned on this difficulty).
static func open(id: String) -> bool:
	var a := MenuDraw.achievement(id)
	if a.is_empty():
		return false
	if String(a.ship) != "" and layout_of(String(a.ship), current_ship) < 0:
		return false
	var p := PlayerProfile.current()
	return not p.has_achievement(id) or (bool(a.multi) and int(p.achievements[id]) < difficulty)


## AchievementTracker::SetAchievement(id): ship gating with the run's ship, then the profile.
static func award(id: String) -> bool:
	var a := MenuDraw.achievement(id)
	if a.is_empty():
		return false  # not in achievements.xml (ACH_LANIUS_SUFFOCATION is commented out): nothing happens
	if String(a.ship) != "" and layout_of(String(a.ship), current_ship) < 0:
		return false
	return award_raw(PlayerProfile.current(), id, difficulty)


## SetAchievement without the ship gating (profile-wide triggers: totals, ACH_UNLOCK_ALL).
static func award_raw(p: PlayerProfile, id: String, diff: int) -> bool:
	var a := MenuDraw.achievement(id)
	if not p.earn(id, diff, bool(a.get("multi", true))):
		return false
	if GameOptions.achievement_popups:
		popup_achievement(id)
	_hook(&"achievement_earned", [id, diff])
	var base := String(a.get("ship", ""))
	if base != "":
		p.check_ship_achievements(TitleState.SHIP_BLUEPRINTS.find(base), false)
	return true


static func _hook(name: StringName, args: Array) -> void:
	var hooks: Node = Engine.get_main_loop().root.get_node_or_null("Hooks") if Engine.get_main_loop() is SceneTree \
		else null
	if hooks:
		hooks.callv(&"emit", [name] + args)


# ------------------------------------------------------------------ popups (AchievementTracker::OnLoop / OnRender)

## Queues the popup of an achievement (recentlyUnlocked; header "ach_unlocked", sound "achievement").
static func popup_achievement(id: String) -> void:
	var a := MenuDraw.achievement(id)
	_push({"header": "", "name": FtlData.tr_id(id + "_name"), "img": String(a.get("img", "")), "dim": 64,
		"sound": "achievement"})


## Popup of a ship victory / quest marker (32 px; title victory_ach_title / quest_ach_title with the ship class).
static func popup_marker(ship_id: int, kind: String) -> void:
	var cls := TitleState.ship_class(TitleState.SHIP_BLUEPRINTS[ship_id])
	var img := "achievements/S_%s_on.png" % ("V" if kind == "victory" else "Q")
	_push({"header": "", "name": TooltipText.f(kind + "_ach_title", cls), "img": img, "dim": 32,
		"sound": "achievement"})


## AchievementTracker::UnlockShip(shipId, layout): the shipUnlocks entry — header "ship_unlocked" (layout A) or
## "layout_unlocked", name = the ship class, icon `achievements/<layout file>_1.png` (its first ship achievement),
## sound "unlock" (a non-empty header).
static func popup_unlock(ship_id: int, layout: int) -> void:
	var bp: String = TitleState.SHIP_BLUEPRINTS[ship_id]
	var img := ""
	for a in MenuDraw.achievements():
		if String(a.ship) == bp:
			img = String(a.img)
			break
	_push({"header": "ship_unlocked" if layout == 0 else "layout_unlocked", "name": TitleState.ship_class(bp),
		"img": img, "dim": 64, "sound": "unlock"})


static func _push(e: Dictionary) -> void:
	popups.append(e)
	AchievementPopup.ensure()


# ------------------------------------------------------------------ flags (SetFlag / GetFlag / GetFlagValue)

static func _state(run: RunState) -> Dictionary:
	if not run.track.has("ach"):
		run.track["ach"] = {"flags": {}, "min_hull": run.ship.hull, "base_crew": -1, "base_hull": -1,
			"base_killed": 0, "dmg_cloaked": 0, "dmg_uncloaked": false, "failed_dodges": 0, "enemy_hostile": false}
	return run.track.ach


static func set_flag(run: RunState, f: String) -> void:
	var fl: Dictionary = _state(run).flags
	fl[f] = int(fl.get(f, 0)) + 1


static func flag(run: RunState, f: String) -> int:
	return int(_state(run).flags.get(f, 0))


static func _live(run: Variant) -> bool:
	return run is RunState and run.score.track_profile and run.over == "" and not run.track.is_empty()


static func _run_of(ship: Variant) -> RunState:
	var run := RunState.current
	if not _live(run) or ship == null or (ship != run.ship and ship != run.ship.opponent):
		return null
	return run


# ------------------------------------------------------------------ run / sector / beacon

## WorldManager::CreateNewGame -> ResetFlags (flags cleared, newAchievement cleared); currentShip set.
static func _on_run_started(run: RunState) -> void:
	_set_run(run)
	run.track.erase("ach")
	_state(run)
	PlayerProfile.current().fresh.clear()
	_beacon_reset(run)


static func _on_run_loaded(run: RunState) -> void:
	_set_run(run)


static func _set_run(run: RunState) -> void:
	current_ship = String(run.ship.blueprint.get("name", ""))
	difficulty = run.score.difficulty
	_volleys.clear()
	_beam_kills.clear()
	_beam_hits.clear()


## StarMap::AdvanceWorldLevel (worldLevel = `level`, 0-based, after the increment): from sector 5 on, every new
## sector: ACH_SECTOR_5, ACH_NO_REPAIR (no "store_repair"), ACH_NO_UPGRADES (no "system_upgrade"), ACH_PACIFIST (no
## "teleported", "offensive_drone" or "fired_shot"), ACH_ENERGY_MANPOWER (no "reactor_upgrade"), ACH_FED_UPGRADE
## (no "weapon_upgrade"); from sector 8 on SetSectorEight. ProfileTracker calls it from `sector_entered`.
static func advance_world_level(run: RunState, level: int) -> void:
	if not _live(run) or level < 4:
		return
	award(PlayerProfile.ACH_SECTOR_5)
	if flag(run, "suffocated_crew") > 9:
		award("ACH_LANIUS_SUFFOCATION")  # commented out in achievements.xml: no effect
	if flag(run, "store_repair") == 0:
		award("ACH_NO_REPAIR")
	if flag(run, "system_upgrade") == 0:
		award("ACH_NO_UPGRADES")
	if flag(run, "teleported") == 0 and flag(run, "offensive_drone") == 0 and flag(run, "fired_shot") == 0:
		award("ACH_PACIFIST")
	if flag(run, "reactor_upgrade") == 0:
		award("ACH_ENERGY_MANPOWER")
	if flag(run, "weapon_upgrade") == 0:
		award("ACH_FED_UPGRADE")
	if level > 6:
		sector_eight(run)


## AchievementTracker::SetSectorEight: ACH_SECTOR_8, ACH_LANIUS_OXYGEN (no "higho2"), ACH_NO_MISSILES (no
## "used_missile"), ACH_NO_DRONES (no "used_drone"), ACH_NO_BUYING (no "store_purchase"), ACH_NO_DEATH (no
## "lost_crew"), ACH_STEALTH_TACTICAL (no "env_danger"). The AE layout C unlock is in ProfileTracker.reached_sector.
static func sector_eight(run: RunState) -> void:
	award(PlayerProfile.ACH_SECTOR_8)
	if flag(run, "higho2") == 0:
		award("ACH_LANIUS_OXYGEN")
	if flag(run, "used_missile") == 0:
		award("ACH_NO_MISSILES")
	if flag(run, "used_drone") == 0:
		award("ACH_NO_DRONES")
	if flag(run, "store_purchase") == 0:
		award("ACH_NO_BUYING")
	if flag(run, "lost_crew") == 0:
		award("ACH_NO_DEATH")
	if flag(run, "env_danger") == 0:
		award("ACH_STEALTH_TACTICAL")


## StarMap::StartSecretSector: ACH_ROCK_CRYSTAL.
static func _on_secret_sector(run: RunState) -> void:
	if _live(run):
		award("ACH_ROCK_CRYSTAL")


## Arrival (WorldManager::CreateLocation + ModifyEnvironment + ShipManager::JumpArrive): environment flags
## ("nebula" for a nebula or an ion storm, "env_danger" for asteroids / sun / pulsar / ion storm), ACH_SLUG_NEBULA
## (30 nebula beacons; the exe's sector test `worldLevel < 9` never fails), and the per-beacon baselines.
static func _on_arrived(run: RunState, _beacon: Variant) -> void:
	if not _live(run):
		return
	match run.env:
		HazardRule.Env.NEBULA:
			set_flag(run, "nebula")
		HazardRule.Env.STORM:
			set_flag(run, "env_danger")
			set_flag(run, "nebula")
		HazardRule.Env.ASTEROIDS, HazardRule.Env.SUN, HazardRule.Env.PULSAR:
			set_flag(run, "env_danger")
	if flag(run, "nebula") >= 30 and run.sector < 9:
		award("ACH_SLUG_NEBULA")
	_beacon_reset(run)


## CreateLocation: playerCrewCount, playerHull, killedCrew (ACH_MANTIS_SLAUGHTER); JumpArrive: minBeaconHealth;
## WeaponSystem::Jump: shotsFiredAtTarget = 0.
static func _beacon_reset(run: RunState) -> void:
	var st := _state(run)
	st.base_crew = player_crew_count(run)
	st.base_hull = run.ship.hull
	st.base_killed = flag(run, "killed_crew")
	st.min_hull = run.ship.hull
	st.dmg_uncloaked = false
	_volleys.clear()
	_beam_kills.clear()
	_beam_hits.clear()


## CrewMemberFactory::GetPlayerCrewCount: living player crew (not drones) on either ship.
static func player_crew_count(run: RunState) -> int:
	var n := 0
	for s in [run.ship, run.ship.opponent]:
		if s == null:
			continue
		for c in s.crew:
			if c.player_owned and not c.is_drone() and c.is_alive():
				n += 1
	return n


## ShipManager::CountCrew(ship, false): the ship's own crew aboard it; (ship, true): the other side's crew
## aboard it (boarders). Drones excluded, living only.
static func count_crew(ship: ShipState, boarders: bool) -> int:
	if ship == null:
		return 0
	var n := 0
	for c in ship.crew:
		if c.is_alive() and not c.is_drone() and (c.player_owned == ship.is_player) != boarders:
			n += 1
	return n


# ------------------------------------------------------------------ flag sources

## WorldManager::PauseLoop: a chosen blue choice whose requirement is a race (blueRaceChoices) -> "blue_race";
## 4 of them before sector 6 (worldLevel < 5) -> ACH_FED_DIPLOMACY.
static func _on_choice(run: RunState, _i: Variant, v: Variant) -> void:
	if not _live(run) or not v is Dictionary or not bool(v.get("blue", false)):
		return
	var choices: Array = run.dialog.get("choices", [])
	var idx := int(v.get("index", -1))
	if idx < 0 or idx >= choices.size() or not String(choices[idx].get("req", "")) in RACES:
		return
	set_flag(run, "blue_race")
	if flag(run, "blue_race") >= 4 and run.sector < 5:
		award("ACH_FED_DIPLOMACY")


## StoreBox::Purchase -> "store_purchase"; RepairStoreBox::Purchase -> "store_repair".
static func _on_store(run: RunState, what: Variant) -> void:
	if _live(run):
		set_flag(run, "store_repair" if String(what) == "repair" else "store_purchase")


## UpgradeBox::Accept / ReactorButton::Accept / Upgrades::Close: "system_upgrade", "weapon_upgrade",
## "reactor_upgrade" (UpgradeSession.commit).
static func _on_upgrades(run: RunState, flags: Variant) -> void:
	if _live(run):
		for f in flags:
			set_flag(run, String(f))


## ProjectileFactory::GetProjectile (player, artillery included) -> "fired_shot"; WeaponSystem::OnLoop
## SpendMissiles > 0 (player weapons) -> "used_missile"; ProjectileFactory::Update: shotsFiredAtTarget + 1 per
## volley (both ships; reset on the jump).
static func _on_weapon_fired(ship: Variant, w: Variant, _to: Variant) -> void:
	var run := _run_of(ship)
	if run == null or not w is WeaponState:
		return
	_volleys[w.get_instance_id()] = int(_volleys.get(w.get_instance_id(), 0)) + 1
	if ship != run.ship:
		return
	set_flag(run, "fired_shot")
	if not w.is_artillery and w.missiles_per_shot() > 0:
		set_flag(run, "used_missile")


## DroneSystem::PowerDrone (player): "used_drone" (a drone deployed), "offensive_drone" (COMBAT / BOARDER).
static func _on_drone_powered(ship: Variant, d: Variant) -> void:
	var run := _run_of(ship)
	if run == null or ship != run.ship or not d is Drone:
		return
	set_flag(run, "used_drone")
	if String(d.bp.get("type", "")) in ["COMBAT", "BOARDER"]:
		set_flag(run, "offensive_drone")


## TeleportSystem::InitiateTeleport (player) -> "teleported".
static func _on_teleport(ship: Variant) -> void:
	var run := _run_of(ship)
	if run != null and ship == run.ship:
		set_flag(run, "teleported")


## CrewAnimation::OnUpdate (death): player crew -> "lost_crew", enemy crew -> "killed_crew" (drones excluded);
## CrewMember::OnLoop: an enemy suffocating -> "suffocated_crew"; CrewMember::DirectModifyHealth: a burning enemy
## fighting a player crew member dies on its own ship -> ACH_ROCK_FIRE.
static func _on_crew_died(ship: Variant, c: Variant) -> void:
	var run := _run_of(ship)
	if run == null or not c is CrewMember or c.is_drone():
		return
	if c.player_owned:
		set_flag(run, "lost_crew")
		return
	set_flag(run, "killed_crew")
	var s: ShipState = ship
	if s != run.ship and s.sys("oxygen") != null and float(s.env.oxygen.get(c.room, 100.0)) <= 5.0 \
			and c.can_suffocate():
		set_flag(run, "suffocated_crew")
	if s == run.ship.opponent and _burning(s, c) and c.fighting and c.target != null and c.target.player_owned:
		award("ACH_ROCK_FIRE")
	_check_slaughter(run)


static func _burning(s: ShipState, c: CrewMember) -> bool:
	return c.can_burn() and s.env.fires_in(c.room) > 0  # CrewMember iOnFire


## WorldManager::ModifyResources KillCrew (event crew loss) -> "lost_crew".
static func _on_crew_removed(ship: Variant, c: Variant, _cloned: Variant) -> void:
	var run := _run_of(ship)
	if run != null and c is CrewMember and c.player_owned and not c.is_drone():
		set_flag(run, "lost_crew")


## CrewMember::OnLoop, a kill: a player crew member aboard the enemy kills a burning enemy -> ACH_ROCK_FIRE; a
## player boarding drone with 4+ targets destroyed (kills + sabotaged systems) kills again -> ACH_BOARDING_DRONE.
static func _on_crew_killed(ship: Variant, killer: Variant, victim: Variant) -> void:
	var run := _run_of(ship)
	if run == null or not killer is CrewMember or not victim is CrewMember:
		return
	if killer.player_owned and ship == run.ship.opponent and not victim.is_drone() and _burning(ship, victim):
		award("ACH_ROCK_FIRE")
	if killer.player_owned and killer.is_drone() and killer.drone_kind.begins_with("boarder") \
			and killer.targets_destroyed > 3:
		award("ACH_BOARDING_DRONE")


## ShipManager::GetDodged (player): a failed roll while flying with engines at 8+ power counts; 5 in a row ->
## ACH_BAD_DODGING; any dodge resets the count.
static func _on_dodge_rolled(ship: Variant, dodged: Variant) -> void:
	var run := _run_of(ship)
	if run == null or ship != run.ship:
		return
	var st := _state(run)
	if bool(dodged):
		st.failed_dodges = 0
		return
	var e := run.ship.sys("engines")
	if FtlDrive.ship_flying(run.ship) and e != null and e.effective_power() > 7:
		st.failed_dodges = int(st.failed_dodges) + 1
		if int(st.failed_dodges) >= 5:
			award("ACH_BAD_DODGING")


## ShipManager::DamageArea, a miss while cloaked: damageCloaked += the shot's damage (ACH_STEALTH_AVOID).
static func _on_dodged(ship: Variant, w: Variant, _pos: Variant) -> void:
	var run := _run_of(ship)
	if run == null or ship != run.ship or not run.ship.is_cloaked() or not w is Dictionary:
		return
	var st := _state(run)
	st.dmg_cloaked = int(st.dmg_cloaked) + int(w.get("damage", 0))


## ShipManager::DamageArea: a crystal shard that takes the enemy's hull to 0 -> ACH_CRYSTAL_SHARD.
static func _on_projectile_hit(ship: Variant, _w: Variant, _room: Variant, r: Variant) -> void:
	var run := _run_of(ship)
	if run == null or ship != run.ship.opponent or not r is Dictionary:
		return
	if bool(r.get("shard", false)) and ship.hull < 1:
		award("ACH_CRYSTAL_SHARD")


## ShipManager::DamageBeam: hitByBeam[room] = now (ACH_SLICE_DICE); killedByBeam[beam] += crew killed; 3 kills by
## one beam without hull damage and with crew damage (the Anti-Bio Beam) -> ACH_SLUG_BIO.
static func _on_beam_damage(ship: Variant, beam: Object, r: Variant) -> void:
	var run := _run_of(ship)
	if run == null or not r is Dictionary or int(r.get("room", -1)) < 0:
		return
	var hits: Dictionary = _beam_hits.get(ship.get_instance_id(), {})
	hits[int(r.room)] = _clock
	_beam_hits[ship.get_instance_id()] = hits
	var k := int(r.get("killed", 0))
	if k <= 0 or ship != run.ship.opponent:
		return
	var key := beam.get_instance_id()
	_beam_kills[key] = int(_beam_kills.get(key, 0)) + k
	var d: Variant = beam.get("dmg")
	if int(_beam_kills[key]) > 2 and d is Damage and d.damage == 0 and d.pers_damage > 0:
		award("ACH_SLUG_BIO")


static func _on_resource(ship: Variant, kind: Variant, _old: Variant, v: Variant) -> void:
	var run := _run_of(ship)
	if run != null and ship == run.ship and StringName(kind) == &"scrap" and int(v) > 599:
		award("ACH_LANIUS_SCRAP")


# ------------------------------------------------------------------ fight outcomes (WorldManager::OnLoop)

## The enemy ship's outcome (RunState.combat_outcome):
## - deadCrew (CompleteShip::DeadCrew): no own crew aboard the player ship and exactly one aboard the enemy ->
##   ACH_MANTIS_SURVIVOR; "dead_crew" + 1, 20 by sector 6 (worldLevel < 6) -> ACH_MANTIS_CREW_DEAD;
## - destroyed (ShipAI::Destroyed): no player weapon fired twice at this beacon, the enemy fired nothing, the
##   Weapon Pre-Igniter and < 2 artillery volleys -> ACH_ONE_VOLLEY; no weapon volley, no offensive drone deployed,
##   1+ artillery volley -> ACH_FED_PATIENCE; no weapon or artillery volley -> ACH_ONLY_DRONES; the enemy was never
##   damaged while the player was uncloaked -> ACH_STEALTH_DESTROY; super shield up -> ACH_ENERGY_SHIELDS; no
##   non-missile weapon fired, no offensive drone deployed, the enemy carries a defence drone (not anti-drone) ->
##   ACH_ROCK_MISSILES; a rock ship -> "destroyed_rock" + 1, 10 -> ACH_CRYSTAL_CLASH;
## - destroyed / gotaway with own crew left aboard -> "lost_crew";
## - destroyed / deadCrew with no own crew aboard the player ship -> ACH_INVADE_SHIP.
static func _on_outcome(run: RunState, kind: Variant) -> void:
	if not _live(run):
		return
	var me := run.ship
	var e := me.opponent
	var k := String(kind)
	if (k == "destroyed" or k == "gotaway") and count_crew(e, true) > 0:
		set_flag(run, "lost_crew")
	if k == "deadCrew":
		if count_crew(me, false) < 1 and count_crew(e, true) == 1:
			award("ACH_MANTIS_SURVIVOR")
		set_flag(run, "dead_crew")
		if flag(run, "dead_crew") >= 20 and run.sector < 6:
			award("ACH_MANTIS_CREW_DEAD")
	if k == "destroyed" and e != null:
		_destroyed_checks(run, me, e)
	if (k == "destroyed" or k == "deadCrew") and count_crew(me, false) < 1:
		award("ACH_INVADE_SHIP")


static func _destroyed_checks(run: RunState, me: ShipState, e: ShipState) -> void:
	var shots := 0  # player weapons' shotsFiredAtTarget
	var twice := false
	var non_missile := false
	for w in me.weapons:
		var n := int(_volleys.get(w.get_instance_id(), 0))
		shots += n
		twice = twice or n > 1
		if n > 0 and String(w.bp.get("type", "")) != "MISSILES" and String(w.bp.get("name", "")) != NO_MISSILE_WEAPON:
			non_missile = true
	var art := 0
	for w in me.artillery:
		art += int(_volleys.get(w.get_instance_id(), 0))
	var offensive := false
	for d in me.drones:
		if d.deployed and String(d.bp.get("type", "")) in ["COMBAT", "BOARDER"]:
			offensive = true
	var enemy_shots := 0
	for w in e.weapons:
		enemy_shots += int(_volleys.get(w.get_instance_id(), 0))
	var defense := false
	for d in e.drones:
		if String(d.bp.get("type", "")) == "DEFENSE" and int(d.bp.get("target_type", 1)) != 3:
			defense = true
	if not twice and enemy_shots == 0 and me.has_augment("WEAPON_PREIGNITE") and art < 2:
		award("ACH_ONE_VOLLEY")
	if not offensive and shots == 0 and art > 0:
		award("ACH_FED_PATIENCE")
	if art == 0 and shots == 0:
		award("ACH_ONLY_DRONES")
	if not bool(_state(run).dmg_uncloaked):
		award("ACH_STEALTH_DESTROY")
	if me.super_shield > 0:
		award("ACH_ENERGY_SHIELDS")
	if not non_missile and not offensive and defense:
		award("ACH_ROCK_MISSILES")
	var bp := String(e.blueprint.get("name", ""))
	for r in ROCK_SHIPS:
		if bp.contains(r):
			set_flag(run, "destroyed_rock")
			if flag(run, "destroyed_rock") > 9:
				award("ACH_CRYSTAL_CLASH")
			break


# ------------------------------------------------------------------ every frame (ShipManager / WorldManager OnLoop)

static func _on_tick(_combat: Variant, seconds: Variant) -> void:
	var run := RunState.current
	if not _live(run):
		return
	_clock += float(seconds)
	check_frame(run)


## The per-frame checks; tests call it directly.
static func check_frame(run: RunState) -> void:
	var me := run.ship
	var st := _state(run)
	var e: ShipState = me.opponent
	if e != null and (e.is_destroyed() or run.enemy.is_empty()):
		e = null
	# ShipManager::OnLoop (player): minBeaconHealth -> ACH_TOUGH_SHIP (hull 1 at this beacon, then full again).
	st.min_hull = mini(int(st.min_hull), me.hull)
	if me.hull == me.max_hull and int(st.min_hull) == 1:
		award("ACH_TOUGH_SHIP")
	# Cloak: enemyDamagedUncloaked (ACH_STEALTH_DESTROY), damageCloaked (ACH_STEALTH_AVOID: 9 in one cloak).
	if e != null:
		if e.hull == e.max_hull:
			st.dmg_uncloaked = false
		elif not me.is_cloaked():
			st.dmg_uncloaked = true
	if me.is_cloaked():
		if int(st.dmg_cloaked) >= 9:
			award("ACH_STEALTH_AVOID")
	else:
		st.dmg_cloaked = 0
	# Hacking pulse + battery + mind control at once -> ACH_LANIUS_ADVANCED; 600 scrap -> ACH_LANIUS_SCRAP.
	var bat := me.sys("battery")
	if me.sys("hacking") != null and bat != null and me.sys("mind") != null and HackingRule.pulsing(me) \
			and bat.turned_on and me.mind_in_use:
		award("ACH_LANIUS_ADVANCED")
	if me.scrap > 599:
		award("ACH_LANIUS_SCRAP")
	# 11 systems -> ACH_FULL_ARSENAL; 29 bars in reactor systems -> ACH_ENERGY_POWER.
	if me.systems.size() > 10:
		award("ACH_FULL_ARSENAL")
	if open("ACH_ENERGY_POWER"):
		var pw := 0
		for s: SystemState in me.systems.values():
			if s.uses_reactor():
				pw += s.effective_power()
		if pw > 28:
			award("ACH_ENERGY_POWER")
	# DroneSystem::OnLoop: 3 powered drones -> ACH_ROBOTIC.
	if open("ACH_ROBOTIC") and me.drones.filter(func(d): return d.powered).size() > 2:
		award("ACH_ROBOTIC")
	# CrewMemberFactory::OnLoop: six species among the player crew -> ACH_UNITED_FEDERATION.
	if open("ACH_UNITED_FEDERATION"):
		var races := {}
		for s in [me, e]:
			if s != null:
				for c in s.crew:
					if c.player_owned and not c.is_drone() and c.is_alive():
						races[c.race] = true
		if races.size() > 5:
			award("ACH_UNITED_FEDERATION")
	# WorldManager::OnLoop: O2 above 20 % after the start beacon -> "higho2" (ACH_LANIUS_OXYGEN).
	if flag(run, "higho2") == 0 and not _start_beacon(run) and me.oxygen_percentage() > 20:
		set_flag(run, "higho2")
	_check_slaughter(run)
	_check_hostile(run, e)
	if e == null:
		return
	# Enemy ShipManager::OnLoop: 4 locked systems -> ACH_IONED; all rooms hit by beams within 5 s -> ACH_SLICE_DICE.
	if open("ACH_IONED"):
		var locked := 0
		for s: SystemState in e.systems.values():
			if s.is_power_locked():
				locked += 1
		if locked > 3:
			award("ACH_IONED")
	var hits: Dictionary = _beam_hits.get(e.get_instance_id(), {})
	if not hits.is_empty() and not e.layout.rooms.is_empty():
		var all := true
		for r in e.layout.rooms:
			if not hits.has(int(r.id)) or _clock - float(hits[int(r.id)]) >= SLICE_WINDOW:
				all = false
				break
		if all:
			award("ACH_SLICE_DICE")
	# ShipManager::UpdateEnvironment (enemy): O2 < 5 % on a crewed hostile ship -> ACH_SUFFOCATE; every tile on
	# fire -> ACH_BURNING.
	if e.hostile and e.sys("oxygen") != null and not e.blueprint.crew.is_empty() and e.oxygen_percentage() < 5:
		award("ACH_SUFFOCATE")
	if open("ACH_BURNING"):
		var burning: bool = not e.layout.rooms.is_empty()
		for r in e.layout.rooms:
			if e.env.fires_in(int(r.id)) != e.room_tiles(int(r.id)):
				burning = false
				break
		if burning:
			award("ACH_BURNING")
	# ShipManager::CheckVision (enemy): every room visible while the player's sensors show nothing -> ACH_SLUG_VISION.
	if open("ACH_SLUG_VISION") and not e.layout.rooms.is_empty():
		var sen := me.sys("sensors")
		var blind := sen == null or sen.hack_effect() >= 2 or sen.effective_power() < 2
		if blind and e.blacked_out_rooms().is_empty():
			award("ACH_SLUG_VISION")
	# ShipManager::UpdateCrewmembers: 4 enemy crew in a locked-down room (either ship) -> ACH_CRYSTAL_LOCKDOWN.
	if open("ACH_CRYSTAL_LOCKDOWN"):
		for s in [me, e]:
			var counts := {}
			for c in s.crew:
				if c.is_alive() and not c.player_owned and c.room >= 0:
					counts[c.room] = int(counts.get(c.room, 0)) + 1
			for room in counts:
				if int(counts[room]) > 3 and LockdownRule.room_locked(s, int(room)):
					award("ACH_CRYSTAL_LOCKDOWN")


## StarMap::StartBeacon: the first sector and a single beacon visited so far.
static func _start_beacon(run: RunState) -> bool:
	if run.sector > 0 or run.map == null:
		return false
	var visits := 0
	for b in run.map.beacons:
		visits += int(b.get("visited", 0))
	return visits == 1


## WorldManager::OnLoop: since the arrival the player kept its crew count and hull and 5 enemy crew died ->
## ACH_MANTIS_SLAUGHTER.
static func _check_slaughter(run: RunState) -> void:
	var st := _state(run)
	if int(st.base_crew) < 0 or flag(run, "killed_crew") - int(st.base_killed) < 5:
		return
	if player_crew_count(run) == int(st.base_crew) and run.ship.hull == int(st.base_hull):
		award("ACH_MANTIS_SLAUGHTER")


## WorldManager::UpdateLocation: an event makes the hostile ship peaceful while no own crew is aboard the player
## ship -> ACH_INVADE_SHIP.
static func _check_hostile(run: RunState, e: ShipState) -> void:
	var st := _state(run)
	var hostile := e != null and bool(run.enemy.get("hostile", false)) and not bool(run.enemy.get("done", false))
	if bool(st.enemy_hostile) and not hostile and e != null and not bool(run.enemy.get("done", false)) \
			and count_crew(run.ship, false) < 1:
		award("ACH_INVADE_SHIP")
	st.enemy_hostile = hostile
