class_name ScoreKeeper
extends RefCounted
## Run score and statistics. Implemented from rules/score_and_game_over.md (§1 tracking, §2 formula, §3 cause,
## §4 window geometry). Pure rules: RunState feeds it, RunEndBox / StatsView show it.

enum Stat { SHIPS, BEACONS, SCRAP, CREW }

## Text ids of the four stats (rules §1 table), in Stat order.
const STAT_IDS := ["defeated_stat", "beacons_stat", "scrap_stat", "crew_stat"]
## Score multiplier per difficulty (0 easy, 1 normal, 2 hard).
const MULTIPLIER := [1.0, 1.25, 1.5]

## The run's ScoreKeeper feeds the profile totals (RunState.new_run / a loaded run set it; standalone keepers in
## tests do not).
var track_profile := false
var current := [0, 0, 0, 0]  # this run
var sector_stats := [0, 0, 0, 0]  # since the last sector change
var sector := 1  # sector number of the current score (1-based)
var difficulty := 1
var victory := false
var saved := false  # bSavedScore: this run's score is already in the profile's top scores (PlayerProfile.commit_run)


## New game (ScoreKeeper::Reset + StartGame): counters cleared, sector 1, not won.
func reset(diff: int) -> void:
	current = [0, 0, 0, 0]
	sector_stats = [0, 0, 0, 0]
	sector = 1
	difficulty = clampi(diff, 0, 2)
	victory = false
	saved = false


func add(stat: int, amount := 1) -> void:
	current[stat] = int(current[stat]) + amount
	sector_stats[stat] = int(sector_stats[stat]) + amount
	if track_profile:
		PlayerProfile.current().add_total(stat, amount)  # profile totals (Stats screen) follow the run live


func add_defeated_ship() -> void:
	add(Stat.SHIPS)


func add_explored_location() -> void:
	add(Stat.BEACONS)


## Only gains count (the raw event amount).
func add_scrap_collected(amount: int) -> void:
	if amount > 0:
		add(Stat.SCRAP, amount)


func add_crew(amount := 1) -> void:
	add(Stat.CREW, amount)


## New sector: the sector counters restart.
func set_sector(n: int) -> void:
	sector_stats = [0, 0, 0, 0]
	sector = n


func ships() -> int:
	return int(current[Stat.SHIPS])


func beacons() -> int:
	return int(current[Stat.BEACONS])


func scrap() -> int:
	return int(current[Stat.SCRAP])


func crew() -> int:
	return int(current[Stat.CREW])


static func multiplier(diff: int) -> float:
	return float(MULTIPLIER[clampi(diff, 0, 2)])


## int(multiplier × (ships × 20 + beacons × 10 + scrap)), the product in float32 then truncated.
static func formula(n_ships: int, n_beacons: int, n_scrap: int, diff: int) -> int:
	var sum := n_ships * 20 + n_beacons * 10 + n_scrap
	var p := PackedFloat32Array([multiplier(diff) * float(sum)])
	return int(p[0])


func score() -> int:
	return formula(ships(), beacons(), scrap(), difficulty)


func sector_score() -> int:
	return int(sector_stats[Stat.SHIPS]) * 20 + int(sector_stats[Stat.BEACONS]) * 10 + int(sector_stats[Stat.SCRAP])


## CommandGui::CheckGameover text id, first match: dead crew, finished explosion, base lost; the tutorial
## replaces any of them. "" = the run goes on.
static func game_over_cause(crew_dead: bool, blown_up: bool, base_lost := false, tutorial := false) -> String:
	var id := ""
	if crew_dead:
		id = "gameover_crew"
	elif blown_up:
		id = "gameover_blowup"
	elif base_lost:
		id = "gameover_fedbase"
	if id != "" and tutorial:
		id = "gameover_tutorial"
	return id


## GameOver::OpenText geometry. `widths` = auto widths of {stats, restart, hangar, mainmenu, quit}; `title_w` =
## the title's width in font 64. Returns {width, x, y, middle (10-px copies), buttons: {name: Rect2},
## gaps: [g1, g2, g3]} in screen pixels.
static func button_layout(widths: Dictionary, title_w: int) -> Dictionary:
	var bottom := ["restart", "hangar", "mainmenu", "quit"]
	var sum := 10
	for b in bottom:
		sum += int(widths[b]) + 22
	var req := maxi(481, int(widths.stats) + 405)
	req = maxi(req, title_w + 224)
	req = maxi(req, sum)
	var n := (req - 462) / 10
	var w := 471 + 10 * n
	var x := 640 - w / 2
	var y := 199
	var left := w - sum
	var g1 := (left + 1) / 3
	var g2 := (left - g1 + 1) / 2
	var g3 := left - g1 - g2
	var gaps := [g1, g2, g3]
	var rects := {"stats": Rect2(x + 202, y + 247, w - 405, 24)}
	var bx := x + 16
	for i in bottom.size():
		var bw := int(widths[bottom[i]])
		rects[bottom[i]] = Rect2(bx, y + 283, bw, 24)
		if i < 3:
			bx += bw + 22 + int(gaps[i])
	return {"width": w, "x": x, "y": y, "middle": n, "buttons": rects, "gaps": gaps}
