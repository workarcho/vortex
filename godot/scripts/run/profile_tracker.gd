class_name ProfileTracker
extends RefCounted
## Feeds the player profile from the running game (rules/save_and_profile.md §2–§3). Engine-side hook listeners
## (owner "profile", registered by `ensure()` from RunState.new_run / SaveGame.restore; re-registering is
## idempotent). Per-run counters live in `RunState.track` (saved with the run); the profile is updated at the
## points vanilla does it and written when the run ends.
##
## Vanilla (exe): games played on ScoreKeeper::Reset; stat totals with every AddStat (ScoreKeeper.add); sector 5 /
## 8 achievements and unlocks when the sector is reached; the unlock quests (`<unlockShip>`); victory: victories,
## ship victory marker per layout and difficulty, ACH_WIN_EASY / ACH_WIN_NORMAL, the next ship of the unlock chain,
## the Crystal check; the top scores / records / crew records once per run (ScoreKeeper::Save(true)); the save
## file deleted at the run end. Crew records: CrewMember.crew_stats (evasions = dodges while piloting, repairs,
## kills, jumps, masteries).
## Ours (§3): `PlayerProfile.extra` statistics, recorded at the run end from `RunState.track`.

const OWNER := "profile"
const HISTORY_MAX := 50


static func ensure() -> void:
	var hooks: Node = Engine.get_main_loop().root.get_node_or_null("Hooks") if Engine.get_main_loop() is SceneTree \
		else null
	if hooks == null:
		return
	var table := [
		[&"run_started", _on_run_started], [&"sector_entered", _on_sector_entered],
		[&"run_ended", _on_run_ended], [&"crew_died", _on_crew_died], [&"projectile_dodged", _on_dodged],
		[&"beacon_arrived", _on_arrived], [&"combat_ended", _on_combat_ended], [&"sim_tick", _on_tick],
		[&"ship_unlocked", _on_ship_unlocked]]
	for e in table:
		hooks.unlisten(e[0], e[1])
		hooks.listen(e[0], e[1], 0, OWNER)
	for e in [[&"damage_hull", _on_hull_damage]]:
		hooks.remove_filter(e[0], e[1])
		hooks.add_filter(e[0], e[1], 1 << 30, OWNER)  # last: sees the value the others settled on
	AchievementTracker.ensure()


static func profile() -> PlayerProfile:
	return PlayerProfile.current()


static func new_track() -> Dictionary:
	return {"time": 0.0, "damage_dealt": 0, "damage_taken": 0, "ships_destroyed": {}, "crew_lost": 0,
		"enemy_crew_killed": 0, "jumps": 0, "dodges": 0, "max_sector": 1}


static func _live(run: RunState) -> bool:
	return run != null and run.score.track_profile and run.over == ""


# ------------------------------------------------------------------ hooks

## ScoreKeeper::Reset: gamesPlayed + 1; the run's ScoreKeeper feeds the profile totals from now on.
static func _on_run_started(run: RunState) -> void:
	run.score.track_profile = true
	run.track = new_track()
	var p := profile()
	p.games_played += 1
	for i in PlayerProfile.STAT_COUNT:  # counted before this hook (start beacon, start crew)
		p.add_total(i, int(run.score.current[i]))


static func _on_sector_entered(run: RunState, level: int, _desc: Variant) -> void:
	if run.score.track_profile:
		reached_sector(run, level + 1)
		AchievementTracker.advance_world_level(run, level)


## Sector n reached (StarMap::AdvanceWorldLevel → AchievementTracker): ACH_SECTOR_5 (and the Kestrel unlocks the
## Engi), ACH_SECTOR_8 (SetSectorEight: with AE, layout B of ships 0..7 unlocks its layout C). The flag-based
## sector achievements (ACH_NO_REPAIR, ACH_PACIFIST, ...) are AchievementTracker.advance_world_level.
static func reached_sector(run: RunState, n: int) -> void:
	var p := profile()
	run.track["max_sector"] = maxi(int(run.track.get("max_sector", 1)), n)
	var st := PlayerProfile.ship_of(String(run.ship.blueprint.get("name", "")))
	if n >= 5:
		AchievementTracker.award(PlayerProfile.ACH_SECTOR_5)
		if st[0] == PlayerProfile.CHAIN[0]:
			p.unlock_ship(PlayerProfile.CHAIN[1], 0)
	if n >= 8:
		AchievementTracker.award(PlayerProfile.ACH_SECTOR_8)
		if run.engine.ae and st[1] == 1 and st[0] >= 0 and st[0] < 8:
			p.unlock_ship(st[0], 2)


## `<unlockShip id="N"/>` in an event (the ship quests; RunState._unlock_ship → hook `ship_unlocked`): ship N type
## A + its quest marker.
static func _on_ship_unlocked(run: Variant, id: Variant) -> void:
	if run is RunState and run.score.track_profile and int(id) >= 0:
		profile().unlock_ship(int(id), 0)
		if not profile().quests.has(int(id)):  # SetAchievement("<SHIP>_QUEST")
			profile().quests[int(id)] = true
			if GameOptions.achievement_popups:
				AchievementTracker.popup_marker(int(id), "quest")


static func _on_hull_damage(v: Variant, ship: Variant) -> Variant:
	var run := RunState.current
	if not _live(run) or not (v is int) or int(v) <= 0:
		return null
	if ship == run.ship:
		run.track["damage_taken"] = int(run.track.get("damage_taken", 0)) + int(v)
	elif ship == run.ship.opponent:
		run.track["damage_dealt"] = int(run.track.get("damage_dealt", 0)) + int(v)
	return null


static func _on_crew_died(ship: Variant, c: CrewMember) -> void:
	var run := RunState.current
	if not _live(run) or c.is_drone():
		return
	if c.player_owned:
		run.track["crew_lost"] = int(run.track.get("crew_lost", 0)) + 1
		profile().update_crew_records(c)  # its records count even if it never comes back
	elif ship == run.ship or ship == run.ship.opponent:
		run.track["enemy_crew_killed"] = int(run.track.get("enemy_crew_killed", 0)) + 1


## A shot dodged by the player ship: +1 evasion for the crew piloting it.
static func _on_dodged(target: Variant, _weapon: Variant, _pos: Variant) -> void:
	var run := RunState.current
	if not _live(run) or target != run.ship:
		return
	run.track["dodges"] = int(run.track.get("dodges", 0)) + 1
	var pilot := run.ship.active_manning_crew("pilot")
	if pilot != null and pilot.player_owned:
		pilot.crew_stats[0] += 1


## Every arrival after a jump: +1 jump for every living own crew member.
static func _on_arrived(run: RunState, _beacon: Variant) -> void:
	if not _live(run) or run.track.is_empty():
		return
	run.track["jumps"] = int(run.track.get("jumps", 0)) + 1
	for c in run.ship.crew:
		if c.player_owned and not c.is_drone() and c.is_alive():
			c.crew_stats[3] += 1


static func _on_combat_ended(player: Variant, enemy: Variant, reason: Variant) -> void:
	var run := RunState.current
	if not _live(run) or player != run.ship or not enemy is ShipState or String(reason) != "destroyed":
		return
	var cls := TitleState.ship_class(String(enemy.blueprint.get("name", "")))
	if cls == "":
		cls = String(enemy.blueprint.get("name", "?"))
	var d: Dictionary = run.track.get("ships_destroyed", {})
	d[cls] = int(d.get(cls, 0)) + 1
	run.track["ships_destroyed"] = d


static func _on_tick(_combat: Variant, seconds: Variant) -> void:
	var run := RunState.current
	if _live(run):
		run.track["time"] = float(run.track.get("time", 0.0)) + float(seconds)


## Run over (game over / victory): victory bookkeeping, scores, our statistics, profile written, save deleted.
static func _on_run_ended(run: RunState, kind: Variant) -> void:
	if not run.score.track_profile:
		return
	var p := profile()
	var diff := run.score.difficulty
	if run.score.sector >= 8:
		reached_sector(run, run.score.sector)
	if String(kind) == "victory":
		p.victories += 1
		var st := PlayerProfile.ship_of(String(run.ship.blueprint.get("name", "")))
		# BossShip::OnLoop: ACH_WIN_EASY, ACH_WIN_NORMAL (normal / hard); SetVictoryAchievement: the ship's victory
		# marker for this layout and difficulty -> CheckShipAchievements (the next ship of the chain).
		AchievementTracker.award(PlayerProfile.ACH_WIN_EASY)
		if diff >= 1:
			AchievementTracker.award(PlayerProfile.ACH_WIN_NORMAL)
		if st[0] >= 0:
			if p.set_ship_victory(st[0], st[1], diff) and GameOptions.achievement_popups:
				AchievementTracker.popup_marker(st[0], "victory")
			p.check_ship_achievements(st[0])
			p.check_crystal_unlock()
	p.commit_run(run)
	record_extra(run, "victory" if String(kind) == "victory" else String(run.over_cause if run.over_cause != ""
		else "gameover"))
	p.save()
	SaveGame.delete()


## The player leaves a running game for good (Esc RESTART / HANGAR: vanilla Save(true) + deleteAllSaveFiles).
static func abandon(run: RunState) -> void:
	if run == null or not run.score.track_profile or run.over != "" or run.score.saved:
		return
	profile().commit_run(run)
	record_extra(run, "abandoned")
	profile().save()
	SaveGame.delete()


# ------------------------------------------------------------------ our statistics (rules §3)

## Adds a finished run to PlayerProfile.extra. `result`: "victory", "abandoned" or the game over text id
## (gameover_crew / gameover_blowup / ...).
static func record_extra(run: RunState, result: String) -> void:
	var x := profile().extra
	var t: Dictionary = run.track
	var won := result == "victory"
	var lost := not won and result != "abandoned"
	var bp := String(run.ship.blueprint.get("name", ""))
	var st := PlayerProfile.ship_of(bp)
	var key := "%d:%d" % [st[0], st[1]]
	var diff := run.score.difficulty
	var secs := float(t.get("time", 0.0))
	var sector := run.score.sector
	_add(x, "runs", 1)
	_add(x, "wins", 1 if won else 0)
	_add(x, "losses", 1 if lost else 0)
	_add(x, "abandoned", 1 if result == "abandoned" else 0)
	_add(x, "sector_sum", sector)
	_add(x, "damage_dealt", int(t.get("damage_dealt", 0)))
	_add(x, "damage_taken", int(t.get("damage_taken", 0)))
	_add(x, "crew_lost", int(t.get("crew_lost", 0)))
	_add(x, "enemy_crew_killed", int(t.get("enemy_crew_killed", 0)))
	_add(x, "jumps", int(t.get("jumps", 0)))
	_add(x, "dodges", int(t.get("dodges", 0)))
	_add(x, "scrap_collected", run.score.scrap())
	_add(x, "ships_defeated", run.score.ships())
	_add(x, "play_time", secs)
	_max(x, "most_damage_dealt", int(t.get("damage_dealt", 0)))
	_max(x, "most_damage_taken", int(t.get("damage_taken", 0)))
	_max(x, "best_score", run.score.score())
	var sd: Dictionary = x.get("ships_destroyed", {})
	for k in t.get("ships_destroyed", {}):
		sd[k] = int(sd.get(k, 0)) + int(t.ships_destroyed[k])
	x["ships_destroyed"] = sd
	var causes: Dictionary = x.get("results", {})  # deaths by cause (+ victory / abandoned)
	causes[result] = int(causes.get(result, 0)) + 1
	x["results"] = causes
	# Streaks: abandoned runs count as losses (a streak needs every run won).
	if won:
		_add(x, "streak", 1)
	else:
		x["streak"] = 0
	_max(x, "best_streak", int(x.get("streak", 0)))
	# Per ship layout and per difficulty.
	var by_ship: Dictionary = x.get("by_ship", {})
	by_ship[key] = _bucket(by_ship.get(key, {}), won, lost, sector, run.score.score(), secs)
	x["by_ship"] = by_ship
	var by_diff: Dictionary = x.get("by_difficulty", {})
	by_diff[diff] = _bucket(by_diff.get(diff, {}), won, lost, sector, run.score.score(), secs)
	x["by_difficulty"] = by_diff
	if won and (not x.has("fastest_win") or secs < float(x.fastest_win.time)):
		x["fastest_win"] = {"time": secs, "ship": key, "difficulty": diff}
	var hist: Array = x.get("history", [])
	hist.push_front({"ship": key, "difficulty": diff, "result": result, "sector": sector,
		"score": run.score.score(), "time": secs, "date": Time.get_datetime_string_from_system(false, true)})
	while hist.size() > HISTORY_MAX:
		hist.pop_back()
	x["history"] = hist


static func _bucket(b: Dictionary, won: bool, lost: bool, sector: int, score: int, secs: float) -> Dictionary:
	_add(b, "runs", 1)
	_add(b, "wins", 1 if won else 0)
	_add(b, "losses", 1 if lost else 0)
	_add(b, "sector_sum", sector)
	_max(b, "best_score", score)
	if won and (not b.has("fastest_win") or secs < float(b.fastest_win)):
		b["fastest_win"] = secs
	return b


static func _add(d: Dictionary, k: String, v: Variant) -> void:
	d[k] = d.get(k, 0) + v


static func _max(d: Dictionary, k: String, v: Variant) -> void:
	d[k] = maxi(int(d.get(k, 0)), int(v))
