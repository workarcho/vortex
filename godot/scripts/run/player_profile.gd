class_name PlayerProfile
extends RefCounted
## The player profile, our ae_prof.sav (rules/save_and_profile.md §2): ship unlocks, achievements, top scores
## (overall and per ship layout), the four ScoreKeeper stats (profile total + best run), games played / victories,
## the five crew records, and `extra` (our own statistics, ProfileTracker / rules §3).
##
## ScoreKeeper::Save (exe): file version, AchievementTracker::SaveProfile, unlocked[12 ships] bits per layout,
## topScores, shipScores[ship][layout], per stat {max, total}, gamesPlayed, victories, crewStats[5] {value, name,
## species, male}; written to ae_prof.new.sav then renamed. Ours: one Godot binary Variant (`to_save`), same
## write-then-rename. Top score lists keep 5 entries, best first; a score is inserted before the first lower one
## (ScoreKeeper::AddTopScore: equal scores keep the older one first).

const VERSION := 1
const KIND := "ftl-proto-profile"
const TOP_MAX := 5
const STAT_COUNT := 4  # ScoreKeeper.Stat: ships, beacons, scrap, crew
## Crew records (ScoreKeeper crewStats): text ids of the Stats screen rows.
const CREW_RECORDS := ["crew_evasions", "crew_repairs", "crew_kills", "crew_jumps", "crew_masteries"]
## Unlock chain (ShipSelect UnlockArrows, text_misc `ship_unlock_sector5` / `ship_unlock_victory`): the display
## order SHIP_BLUEPRINT_ORDER; the Kestrel unlocks the Engi by reaching sector 5, every next ship of the list is
## unlocked by a victory with the previous one. Lanius: 5 type A unlocked (ScoreKeeper::UnlockShip); Crystal: its
## quest, or victories with type A and B of every other ship except the Lanius (`alt_unlock_crystal`).
const CHAIN := [0, 3, 4, 7, 2, 5, 6, 1]
const LANIUS := 9
const CRYSTAL := 8
## Profile achievements with a hard-wired trigger (ProfileTracker); the others are stored when something sets them.
const ACH_SECTOR_5 := "ACH_SECTOR_5"
const ACH_SECTOR_8 := "ACH_SECTOR_8"
const ACH_WIN_EASY := "ACH_WIN_EASY"
const ACH_WIN_NORMAL := "ACH_WIN_NORMAL"
const ACH_UNLOCK_ALL := "ACH_UNLOCK_ALL"
const ACH_SCRAP := "ACH_SCRAP"
const ACH_SHIPS := "ACH_SHIPS"
const ACH_SCRAP_TOTAL := 10000
const ACH_SHIPS_TOTAL := 1000

static var path := "user://profile.sav"
## Write to disk (the real game; tests use their own path). Off: the profile still lives in memory.
static var persist := false
static var _current: PlayerProfile = null

var unlocked := {}  # "id:type" -> true (Kestrel A always)
var achievements := {}  # achievement id -> difficulty it was earned on (best: 0 easy .. 2 hard)
var victories_by_ship := {}  # ship id (int) -> {type (int): best difficulty} (the S_V victory marker / dots)
var quests := {}  # ship id -> true: its unlock quest completed (S_Q marker)
var top_scores: Array = []  # TopScore dicts, best first
var ship_scores := {}  # "id:type" -> [TopScore], best first
var stat_total := [0, 0, 0, 0]
var stat_max := [0, 0, 0, 0]
var games_played := 0
var victories := 0
var crew_records: Array = []  # [{value, name, race, male}] x5
var extra := {}  # our statistics (ProfileTracker)
var new_flags := {}  # "new_high" / "new_ship_best" of the last committed run (game over window, not saved)
## CAchievement::newAchievement: achievements earned since the last new game (hangar "New!" label; not saved,
## cleared by AchievementTracker::ResetFlags at the next run start). Keys: achievement ids and "<SHIP>_VICTORY".
var fresh := {}


func _init() -> void:
	_defaults()


func _defaults() -> void:
	unlocked = {"0:0": true}
	achievements = {}
	victories_by_ship = {}
	quests = {}
	top_scores = []
	ship_scores = {}
	stat_total = [0, 0, 0, 0]
	stat_max = [0, 0, 0, 0]
	games_played = 0
	victories = 0
	crew_records = []
	for i in CREW_RECORDS.size():
		crew_records.append({"value": 0, "name": "", "race": "", "male": true})
	extra = {}


## The profile of this process (loaded on first use).
static func current() -> PlayerProfile:
	if _current == null:
		_current = load_file()
	return _current


## Tests: forget the in-memory profile (the next `current()` reads `path` again).
static func reset_current(p: PlayerProfile = null) -> void:
	_current = p


static func load_file() -> PlayerProfile:
	var p := PlayerProfile.new()
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			var v: Variant = f.get_var(false)
			f.close()
			if v is Dictionary and String(v.get("kind", "")) == KIND:
				p.from_save(v)
	# AchievementTracker::LoadProfile: CheckShipAchievements(i, hidePopups) for every ship (layout B for two ship
	# achievements, the next ship of the chain for a victory).
	for id in TitleState.SHIP_BLUEPRINTS.size():
		p.check_ship_achievements(id, true)
	return p


func save() -> bool:
	if not persist:
		return false
	var tmp := path + ".new"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("profile save failed: %s" % error_string(FileAccess.get_open_error()))
		return false
	f.store_var(to_save(), false)
	f.close()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	return DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp), ProjectSettings.globalize_path(path)) == OK


## DELETE PROFILE (OptionsScreen confirm_wipe_profile, ScoreKeeper::WipeProfile).
func wipe() -> void:
	_defaults()
	save()


const FIELDS := ["unlocked", "achievements", "victories_by_ship", "quests", "top_scores", "ship_scores",
	"stat_total", "stat_max", "games_played", "victories", "crew_records", "extra"]


func to_save() -> Dictionary:
	var d := {"kind": KIND, "version": VERSION}
	for f in FIELDS:
		d[f] = SaveCodec.encode(get(f))
	return d


func from_save(d: Dictionary) -> void:
	for f in FIELDS:
		if d.has(f):
			SaveCodec.decode_into(self, f, d[f])
	unlocked["0:0"] = true
	while crew_records.size() < CREW_RECORDS.size():
		crew_records.append({"value": 0, "name": "", "race": "", "male": true})


# ------------------------------------------------------------------ ships

## (ship id, layout) of a player blueprint name; [-1, -1] for any other ship.
static func ship_of(bp: String) -> Array:
	for t in [2, 1, 0]:
		for id in TitleState.SHIP_BLUEPRINTS.size():
			if TitleState.blueprint_of(id, t) == bp:
				return [id, t]
	return [-1, -1]


## ScoreKeeper::GetShipUnlocked (without forceUnlockAll).
func is_unlocked(id: int, type: int) -> bool:
	return unlocked.has("%d:%d" % [id, type])


## Every hangar layout of the data (TitleState.layout_exists): [[id, type], ...].
static func all_layouts() -> Array:
	var out := []
	for id in TitleState.SHIP_BLUEPRINTS.size():
		for t in 3:
			if TitleState.layout_exists(id, t):
				out.append([id, t])
	return out


## [ours] UNLOCK ALL (profile window): every layout of the data unlocked in this profile. Sets the bits directly
## (no ACH_UNLOCK_ALL: nothing was earned).
func unlock_everything() -> void:
	for l in all_layouts():
		unlocked["%d:%d" % [l[0], l[1]]] = true


## [ours] Share of the hangar layouts this profile has unlocked, 0..100 (the profile window).
func unlock_percent() -> int:
	var all := all_layouts()
	if all.is_empty():
		return 0
	var n := 0
	for l in all:
		if is_unlocked(l[0], l[1]):
			n += 1
	return int(floor(100.0 * n / all.size()))


## ScoreKeeper::UnlockShip(shipId, layout, save, hidePopup): sets the bit; all ten type A → ACH_UNLOCK_ALL; exactly
## five type A (and not the Lanius itself) → the Lanius A; then, unless hidden, the "Ship Unlocked!" / "Layout
## Unlocked!" popup (AchievementTracker::UnlockShip; none for a layout C of ships 8 / 9). Returns true when it was
## newly unlocked.
func unlock_ship(id: int, type: int, hide_popup := false) -> bool:
	if id < 0 or id >= TitleState.SHIP_BLUEPRINTS.size() or type < 0 or type > 2:
		return false
	var key := "%d:%d" % [id, type]
	if unlocked.has(key):
		return false
	unlocked[key] = true
	var a_count := 0
	for i in TitleState.SHIP_BLUEPRINTS.size():
		if is_unlocked(i, 0):
			a_count += 1
	if a_count == TitleState.SHIP_BLUEPRINTS.size():
		AchievementTracker.award_raw(self, ACH_UNLOCK_ALL, 0)
	if a_count == 5 and id != LANIUS:
		unlock_ship(LANIUS, 0, hide_popup)
	if not hide_popup and not (type == 2 and (id == CRYSTAL or id == LANIUS)):
		AchievementTracker.popup_unlock(id, type)
	return true


# ------------------------------------------------------------------ achievements

func has_achievement(id: String) -> bool:
	return achievements.has(id)


## AchievementTracker::SetAchievement (profile part, no ship gating / popup; AchievementTracker.award does those):
## an achievement is earned once; a multiDifficulty one (achievements.xml) is earned again on a higher difficulty
## and then stores that difficulty (vanilla keeps the best difficulty). Returns true when it was (re)earned.
func set_achievement(id: String, difficulty: int) -> bool:
	return earn(id, difficulty, bool(MenuDraw.achievement(id).get("multi", true)))


func earn(id: String, difficulty: int, multi: bool) -> bool:
	if achievements.has(id) and (not multi or int(achievements[id]) >= difficulty):
		return false
	achievements[id] = difficulty
	fresh[id] = true
	return true


## The three ship achievements of a ship (achievements.xml `<ship>` = its layout A blueprint), in file order.
static func ship_achievement_ids(ship_id: int) -> Array:
	var out := []
	if ship_id < 0 or ship_id >= TitleState.SHIP_BLUEPRINTS.size():
		return out
	for a in MenuDraw.achievements():
		if String(a.ship) == TitleState.SHIP_BLUEPRINTS[ship_id]:
			out.append(String(a.id))
	return out


## AchievementTracker::CheckShipAchievements(shipId, hidePopups): two of the ship's three achievements unlock its
## layout B; its victory marker unlocks the next ship of the chain (not for ships 0, 1, 8, 9: the Kestrel's next
## ship comes from sector 5, the Federation is the last, the Crystal / Lanius are not in the chain).
func check_ship_achievements(ship_id: int, hide_popups := false) -> void:
	var n := 0
	for id in ship_achievement_ids(ship_id).slice(0, 3):
		if has_achievement(id):
			n += 1
	if n >= 2:
		unlock_ship(ship_id, 1, hide_popups)
	if ship_victory(ship_id) >= 0 and not ship_id in [0, 1, CRYSTAL, LANIUS]:
		var i := CHAIN.find(ship_id)
		if i >= 0 and i + 1 < CHAIN.size():
			unlock_ship(CHAIN[i + 1], 0, hide_popups)


## Ship victory marker (AchievementTracker::SetVictoryAchievement → SetAchievement("<SHIP>_VICTORY")): best
## difficulty per layout (CAchievement shipDifficulties). Returns true when this layout's entry was raised.
func set_ship_victory(id: int, type: int, difficulty: int) -> bool:
	var v: Dictionary = victories_by_ship.get(id, {})
	var raised := not v.has(type) or int(v[type]) < difficulty
	if raised:
		v[type] = difficulty
		fresh[TitleState.SHIP_BLUEPRINTS[id] + "_VICTORY"] = true
	victories_by_ship[id] = v
	return raised


func ship_victory(id: int, type := -1) -> int:
	var v: Dictionary = victories_by_ship.get(id, {})
	if type >= 0:
		return int(v.get(type, -1))
	var best := -1
	for t in v:
		best = maxi(best, int(v[t]))
	return best


## CheckCrystalUnlock: victories with layouts A and B of every ship but the Lanius (and the Crystal itself).
func check_crystal_unlock() -> void:
	for id in TitleState.SHIP_BLUEPRINTS.size():
		if id == LANIUS or id == CRYSTAL:
			continue
		if ship_victory(id, 0) < 0 or ship_victory(id, 1) < 0:
			return
	unlock_ship(CRYSTAL, 0)


# ------------------------------------------------------------------ stats and scores

## ScoreKeeper::AddDefeatedShips / AddScrapCollected: totals; ACH_SHIPS at 1000 ships, ACH_SCRAP at 10000 scrap.
func add_total(stat: int, amount: int) -> void:
	stat_total[stat] = int(stat_total[stat]) + amount
	if stat == 0 and int(stat_total[0]) >= ACH_SHIPS_TOTAL:
		AchievementTracker.award_raw(self, ACH_SHIPS, AchievementTracker.difficulty)
	elif stat == 2 and int(stat_total[2]) >= ACH_SCRAP_TOTAL:
		AchievementTracker.award_raw(self, ACH_SCRAP, AchievementTracker.difficulty)


## ScoreKeeper::UpdateCrewStat: each record keeps the best value with that crew member's name / race / gender.
func update_crew_records(c: CrewMember) -> void:
	for i in CREW_RECORDS.size():
		var v := int(c.crew_stats[i]) if i < c.crew_stats.size() else 0
		if v > int(crew_records[i].value):
			crew_records[i] = {"value": v, "name": c.name_long if c.name_long != "" else c.display_name(),
				"race": c.race, "male": c.male}


## The TopScore of a run (ScoreKeeper currentScore).
static func score_entry(run: RunState) -> Dictionary:
	var bp := String(run.ship.blueprint.get("name", ""))
	var st := ship_of(bp)
	return {"name": run.ship.ship_title, "blueprint": bp, "ship_id": st[0], "type": st[1],
		"sector": run.score.sector, "score": run.score.score(), "victory": run.score.victory,
		"difficulty": run.score.difficulty, "ae": run.engine.ae}


## ScoreKeeper::AddTopScore into a list: insert before the first lower score, keep TOP_MAX. Returns the index, or
## -1 when it did not make the list.
static func insert_score(list: Array, entry: Dictionary) -> int:
	var at := list.size()
	for i in list.size():
		if int(entry.score) > int(list[i].score):
			at = i
			break
	list.insert(at, entry)
	while list.size() > TOP_MAX:
		list.pop_back()
	return at if at < TOP_MAX else -1


## ScoreKeeper::Save(newHighscore = true), once per run (bSavedScore): records (max per stat), the top score
## lists, and the crew records of every crew member. Called at the run end and when the player abandons the run
## (RESTART / HANGAR).
func commit_run(run: RunState) -> void:
	if run == null or run.score.saved:
		return
	run.score.saved = true
	for i in STAT_COUNT:
		stat_max[i] = maxi(int(stat_max[i]), int(run.score.current[i]))
	var e := score_entry(run)
	new_flags = {}
	if insert_score(top_scores, e) >= 0:
		new_flags["new_high"] = true
	if int(e.ship_id) >= 0:
		var key := "%d:%d" % [int(e.ship_id), int(e.type)]
		var l: Array = ship_scores.get(key, [])
		if insert_score(l, e) >= 0:
			new_flags["new_ship_best"] = true
		ship_scores[key] = l
	for c in run.ship.crew + run.ship.clone_queue:
		if c.player_owned and not c.is_drone():
			update_crew_records(c)
	if run.ship.opponent != null:
		for c in run.ship.opponent.crew:
			if c.player_owned and not c.is_drone():
				update_crew_records(c)


func ship_best(id: int, type: int) -> Array:
	return ship_scores.get("%d:%d" % [id, type], [])
