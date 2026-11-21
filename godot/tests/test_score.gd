extends Node
## Tests for the run score and the game over window (rules/score_and_game_over.md): the ScoreKeeper formula and
## counters, the game over cause order, stat tracking through RunState, the window geometry and its commands.
## Uses the user's FTL data. Run:
##   godot --headless --path godot res://tests/test_score.tscn

const Harness := preload("res://tests/harness.gd")

var fails := 0


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


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
	print("Score formula (§2)")
	check("easy: 3 ships, 10 beacons, 157 scrap", ScoreKeeper.formula(3, 10, 157, 0), 317)
	check("normal ×1.25 truncated", ScoreKeeper.formula(3, 10, 157, 1), 396)
	check("hard ×1.5 truncated", ScoreKeeper.formula(3, 10, 157, 2), 475)
	check("empty run", ScoreKeeper.formula(0, 0, 0, 1), 0)
	check("multipliers", [ScoreKeeper.multiplier(0), ScoreKeeper.multiplier(1), ScoreKeeper.multiplier(2)],
		[1.0, 1.25, 1.5])

	print("Counters (§1)")
	var k := ScoreKeeper.new()
	k.reset(1)
	k.add_defeated_ship()
	k.add_explored_location()
	k.add_explored_location()
	k.add_scrap_collected(30)
	k.add_scrap_collected(-12)  # losses never count
	k.add_crew(3)
	check("current stats", [k.ships(), k.beacons(), k.scrap(), k.crew()], [1, 2, 30, 3])
	check("score = 1.25 × (20 + 20 + 30)", k.score(), 87)
	check("crew adds no score", k.score() == ScoreKeeper.formula(1, 2, 30, 1), true)
	check("sector score (no multiplier)", k.sector_score(), 70)
	k.set_sector(2)
	check("set_sector clears the sector counters only", [k.sector, k.sector_score(), k.score()], [2, 0, 87])
	k.add_explored_location()
	check("sector counters restart", k.sector_score(), 10)
	k.reset(2)
	check("reset", [k.beacons(), k.difficulty, k.victory, k.sector], [0, 2, false, 1])

	print("Cause selection (§3)")
	check("nothing", ScoreKeeper.game_over_cause(false, false), "")
	check("crew dead", ScoreKeeper.game_over_cause(true, false), "gameover_crew")
	check("crew dead wins over blow-up", ScoreKeeper.game_over_cause(true, true), "gameover_crew")
	check("explosion over", ScoreKeeper.game_over_cause(false, true), "gameover_blowup")
	check("base lost", ScoreKeeper.game_over_cause(false, false, true), "gameover_fedbase")
	check("tutorial replaces", ScoreKeeper.game_over_cause(false, true, false, true), "gameover_tutorial")
	check("tutorial alone is no game over", ScoreKeeper.game_over_cause(false, false, false, true), "")

	print("RunState tracking")
	var r := RunState.new_run(4242, "PLAYER_SHIP_HARD", EventEngine.Difficulty.HARD)
	var start_crew := r.ship.crew.filter(func(c): return c.player_owned and not c.is_drone()).size()
	check("start beacon explored, start crew hired", [r.score.beacons(), r.score.crew(), r.score.difficulty],
		[1, start_crew, 2])
	close_dialogs(r)
	r.enemy = {}
	var nb := -1
	for b in r.map.beacons:
		if b.id != r.current_beacon and r.map.connected(r.current_beacon, b.id) and not b.get("fleet", false):
			nb = b.id
			break
	var scrap0 := r.score.scrap()
	r.jump_to(nb)
	check("jump explores a beacon", r.score.beacons(), 2)
	var ev := r.engine.new_event("TEST")
	ev.res.scrap = 25
	r.apply_effects(ev)
	check("event scrap counted", r.score.scrap() - scrap0, 25)
	var ev2 := r.engine.new_event("TEST")
	ev2.res.scrap = -10
	r.apply_effects(ev2)
	check("scrap loss not counted", r.score.scrap() - scrap0, 25)
	r.ship.augments.append("SCRAP_COLLECTOR")
	var ev3 := r.engine.new_event("TEST")
	ev3.res.scrap = 20
	r.apply_effects(ev3)
	check("raw amount counted (no collector bonus)", r.score.scrap() - scrap0, 45)
	r.game_over("gameover_crew")
	check("game over cause kept", [r.over, r.over_cause, r.score.victory], ["gameover", "gameover_crew", false])
	check("over text from data", r.over_text == FtlData.tr_id("gameover_crew"), true)

	print("Window (§4, §5)")
	var box := RunEndBox.new()
	add_child(box)
	var got := []
	box.setup(r, func(c): got.append(c))
	box.build()
	var L := box.layout
	check("title from data", box.labels.title, FtlData.tr_id("gameover_title_gameover"))
	check("width 471 + 10n, ≥ 481", [int(L.width) >= 481, (int(L.width) - 471) % 10], [true, 0])
	check("centred, y 199", [int(L.x), int(L.y)], [640 - int(L.width) / 2, 199])
	var bt: Dictionary = L.buttons
	check("STATS at x + 202, y + 247, width w − 405", [bt.stats.position, bt.stats.size.x],
		[Vector2(int(L.x) + 202, 446), float(int(L.width) - 405)])
	check("RESTART at x + 16, y + 283", bt.restart.position, Vector2(int(L.x) + 16, 482))
	check("QUIT ends 16 px before the right edge", bt.quit.end.x, float(int(L.x) + int(L.width) - 16))
	check("gaps fill the bottom row", int(L.gaps[0]) + int(L.gaps[1]) + int(L.gaps[2]),
		int(L.width) - 10 - [bt.restart, bt.hangar, bt.mainmenu, bt.quit].reduce(func(a, b): return a + b.size.x + 22, 0))
	var wide := ScoreKeeper.button_layout({"stats": 60, "restart": 200, "hangar": 200, "mainmenu": 200,
		"quit": 200}, 100)
	check("wide buttons widen the box", [wide.width, wide.middle], [901, 43])
	box.press("restart")
	box.press("hangar")
	box.press("mainmenu")
	box.press("quit")
	check("commands", got, ["restart", "hangar", "mainmenu", "quit"])
	box.press("stats")
	check("STATS opens the session stats", [box.stats_view.visible, box.stats_view.right,
		int(box.stats_view.session.score)], [true, 0, r.score.score()])
	check("STATS sends no command", got.size(), 4)
	var rv := RunState.new_run(77)
	rv.end_run("victory", "x")
	check("victory flag", rv.score.victory, true)
	box.run = rv
	box.build()
	check("victory title", box.labels.title, FtlData.tr_id("gameover_title_victory"))

