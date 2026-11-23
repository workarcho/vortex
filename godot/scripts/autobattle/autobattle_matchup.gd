class_name AutobattleMatchup
extends RefCounted
## Autobattle demo (scripts/autobattle/autobattle.gd): one round's random matchup — two ships, a sector level and a
## difficulty, and a beacon backdrop. Ships come from the normal enemy generator (ShipGenerator on a blueprint of a
## random fleet list, filtered by min / maxSector like EventEngine.setup_ship); now and then the left ship is a
## player ship layout (A / B / C), upgraded a little with the sector level.
##
## The fight engine has two sides (player = iShipId 0, enemy = 1: crew ownership, intruders, damage owner), so the
## LEFT ship is always the player side. An enemy-blueprint left ship is converted with `to_player_side` (its crew
## becomes player-owned; `enemy_art` keeps the enemy art and enemy blueprint traits; `ai_driven` lets its ShipAI use
## mind control). The RIGHT ship is always a normal enemy ShipState.

## Hostile fleet lists of the vanilla events (auto_blueprint="..."), boss and civilian lists left out.
const FLEETS := ["SHIPS_PIRATE", "SHIPS_REBEL", "SHIPS_AUTO", "SHIPS_MANTIS", "SHIPS_LANIUS", "SHIPS_ZOLTAN",
	"SHIPS_ROCK", "SHIPS_CIRCLE", "SHIPS_CRYSTAL", "SHIPS_JELLY", "SHIPS_REBEL_ELITE"]
## Player ship layouts used for the left ship (`PLAYER_CHANCE` of the rounds); "_2" / "_3" = layouts B / C.
const PLAYER_SHIPS := ["PLAYER_SHIP_HARD", "PLAYER_SHIP_STEALTH", "PLAYER_SHIP_MANTIS", "PLAYER_SHIP_CIRCLE",
	"PLAYER_SHIP_FED", "PLAYER_SHIP_JELLY", "PLAYER_SHIP_ROCK", "PLAYER_SHIP_ENERGY", "PLAYER_SHIP_CRYSTAL",
	"PLAYER_SHIP_ANAEROBIC"]
const PLAYER_LAYOUTS := ["", "_2", "_3"]
const PLAYER_CHANCE := 0.25
## Weapons a player ship may get in its empty slots at higher sectors.
const EXTRA_WEAPONS := ["LASER_BURST_1", "LASER_BURST_2", "LASER_HEAVY_1", "ION_1", "ION_2", "BEAM_1", "BEAM_2",
	"MISSILES_1", "MISSILES_2_PLAYER", "SHOTGUN_PLAYER", "LASER_BURST_3", "BOMB_1"]
const LEVELS := 8  # sector levels 0..7 (shown 1..8)


## {level, difficulty, left: ShipState, right: ShipState, left_fleet, right_fleet, space}. Sets ShipAI.difficulty
## (global, like the game's setting) before the ships are built: the enemy's initial crew placement reads it.
static func roll(rng: RandomNumberGenerator, player_chance := PLAYER_CHANCE) -> Dictionary:
	var level := rng.randi() % LEVELS
	var difficulty := rng.randi() % 3  # EventEngine.Difficulty EASY / NORMAL / HARD (= ShipAI.Difficulty)
	ShipAI.difficulty = difficulty
	var out := {"level": level, "difficulty": difficulty}
	if rng.randf() < player_chance:
		var bp := player_blueprint(rng)
		out.left = build_player_ship(bp, level, rng)
		out.left_fleet = "PLAYER"
	else:
		var fleet: String = FLEETS[rng.randi() % FLEETS.size()]
		out.left = build_enemy(enemy_blueprint(fleet, level, difficulty, rng), level, difficulty, rng)
		to_player_side(out.left)
		out.left_fleet = fleet
	var rf: String = FLEETS[rng.randi() % FLEETS.size()]
	out.right = build_enemy(enemy_blueprint(rf, level, difficulty, rng), level, difficulty, rng)
	out.right_fleet = rf
	out.space = backdrop(rng)
	return out


## A random player layout that exists in the data (A always does).
static func player_blueprint(rng: RandomNumberGenerator) -> String:
	var base: String = PLAYER_SHIPS[rng.randi() % PLAYER_SHIPS.size()]
	var bp: String = base + String(PLAYER_LAYOUTS[rng.randi() % PLAYER_LAYOUTS.size()])
	return bp if FtlData.has_ship_blueprint(bp) else base


## EventEngine.setup_ship's auto_blueprint pick: the list's entries whose min / maxSector allow the level.
static func enemy_blueprint(fleet: String, level: int, difficulty: int, rng: RandomNumberGenerator) -> String:
	var entries := FtlData.blueprint_list(fleet)
	if entries.is_empty() and FtlData.has_ship_blueprint(fleet):
		entries = [fleet]
	var s := maxi(level - (1 if difficulty == EventEngine.Difficulty.EASY else 0), 0)
	var cands := []
	for e in entries:
		var body := FtlData.ship_blueprint_text(e)
		if body == "":
			continue
		var mn := FtlData.tag_value(body, "minSector")
		var mx := FtlData.tag_value(body, "maxSector")
		if (mn == "" or int(mn) <= s) and (mx == "" or s <= int(mx)):
			cands.append(e)
	if cands.is_empty():
		cands = entries.filter(func(e): return FtlData.has_ship_blueprint(e))
	return String(cands[rng.randi() % cands.size()]) if not cands.is_empty() else "REBEL_FAT"


## A generated enemy ship (RunState.build_enemy_ship without the event parts).
static func build_enemy(bp: String, level: int, difficulty: int, rng: RandomNumberGenerator) -> ShipState:
	var plan := ShipGenerator.generate(bp, level, difficulty, int(rng.randi() & 0x7fffffff))
	var s := ShipState.new(bp, false)
	ShipGenerator.apply(s, plan)
	return s


## Moves an enemy-built ship to the player side (iShipId 0) for the fight: crew player-owned, enemy art kept.
static func to_player_side(s: ShipState) -> void:
	s.is_player = true
	s.enemy_art = true
	s.ai_driven = true
	for c in s.crew:
		c.player_owned = true
	s.crew_changed()


## A player layout with sector-scaled upgrades: reactor +level, `level` random system upgrades (blueprint maxima),
## empty weapon slots filled with a chance of level / 8 each. Driven by its ShipAI like the enemy-art ships.
static func build_player_ship(bp: String, level: int, rng: RandomNumberGenerator) -> ShipState:
	var s := ShipState.new(bp, true)
	s.ai_driven = true
	s.reactor_max += level + 2
	var ids := s.systems.keys()
	for i in level * 2:
		if ids.is_empty():
			break
		var id: String = ids[rng.randi() % ids.size()]
		var sy := s.sys(id)
		if sy.level < UpgradeSession.max_level(s, id):
			sy.level += 1
	var ws := s.sys("weapons")
	if ws != null:
		for slot in range(s.weapons.size(), s.weapon_slots):
			if rng.randi() % LEVELS >= level:
				continue
			var bp_w := FtlData.weapon_blueprint(String(EXTRA_WEAPONS[rng.randi() % EXTRA_WEAPONS.size()]))
			if bp_w.is_empty():
				continue
			var w := WeaponState.new(bp_w, s.weapons.size())
			w.powered = false
			s.weapons.append(w)
		s.missiles = maxi(s.missiles, 8)
	s.drone_parts = maxi(s.drone_parts, 6)
	return s


## A beacon backdrop: a BACKGROUND image and (2 in 3) a PLANET, as RunState draws them for a beacon.
static func backdrop(rng: RandomNumberGenerator) -> Dictionary:
	var lists: Dictionary = EventDB.shared().image_lists
	var back := SpaceImages.switch_background(lists, SpaceImages.DEFAULT_BACK, "", rng)
	if back == "":
		back = SpaceImages.SANDBOX_BACK
	var planet := {}
	if rng.randi() % 3 != 0:
		planet = SpaceImages.switch_planet(lists, SpaceImages.DEFAULT_PLANET, "", rng)
	return {"back": back, "planet": planet, "danger": 0, "fleet": [], "pds_planet": {}, "cloud_seed": rng.randi()}
