class_name StatsView
extends Control
## The stats screen (ScoreKeeper, rules/main_menu.md §4). Left half = TOP SCORES / SHIP BEST
## (`scoreUI/score_main_left_1|2.png` at (0,0)), right half = STATS / ACHIEVEMENTS (`score_main_right_1|2.png`
## at (645,0)). The active tab is baked into the image; the other one is a Button (`scoreUI/tab_*`) at
## topscores (43,38), shipbest (338,38), stats (651,38), achieve (838,38). Tab labels font 64 COLOR_BUTTON_TEXT
## centred at x 188 / 477 / 753 / 1023, y 46. CLOSE TextButton (1086,627) 138×46 font 64 over
## `score_close_box.png` (−15,−15) [exe].
## SHIP BEST: ship class (font 24) centred at (217,91); LIST + arrows around (141,157); A/B/C (250,155) +45,
## 36×34 font 63; the ship's achievements at (410,118) + 70 [screenshot 37]. ACHIEVEMENTS: three headings (font
## 24; exe y 113 / +160 / +330, drawn 14 px higher to match the screenshot) and rows of seven 64 px icons from (704,163), 70 px apart, rows 170 px apart (ScoreKeeper::Open lists).
## Data: PlayerProfile (rules/save_and_profile.md §2): top scores (ScoreKeeper::RenderTopScores rows), records,
## totals, crew records and achievements. "MORE STATS" (ours, §3): a separate page with our statistics, shown when
## a mod returns true from the filter `stats_more_button` (the QoL mod's "Extended statistics" group).

signal closed

const ACH_ROWS := [
	["ACH_SECTOR_5", "ACH_SECTOR_8", "ACH_WIN_EASY", "ACH_WIN_NORMAL", "ACH_UNLOCK_ALL", "ACH_SCRAP", "ACH_SHIPS"],
	["ACH_PACIFIST", "ACH_NO_UPGRADES", "ACH_NO_REPAIR", "ACH_NO_MISSILES", "ACH_NO_DRONES", "ACH_NO_BUYING",
		"ACH_NO_DEATH"],
	["ACH_BURNING", "ACH_BAD_DODGING", "ACH_BOARDING_DRONE", "ACH_ONE_VOLLEY", "ACH_INVADE_SHIP", "ACH_SLICE_DICE",
		"ACH_SUFFOCATE"],
]
const ACH_HEADINGS := ["progression_heading", "distance_heading", "skill_heading"]
const ACH_AT := Vector2(704, 163)
const STATS := ["defeated_stat", "beacons_stat", "scrap_stat", "crew_stat"]
const CREW_STATS := ["crew_evasions", "crew_repairs", "crew_kills", "crew_jumps", "crew_masteries"]
const LIST_CENTER := Vector2(141, 157)  # shipListCenter = (43 + 98, 80 + 77)

var title: TitleState
var left := 0  # 0 TOP SCORES, 1 SHIP BEST (activatedLeft)
var right := 1  # 0 STATS, 1 ACHIEVEMENTS (activatedRight)
var ship_id := 0
var ship_type := 0
var hover := ""
var buttons := {}
var ship_list: ShipListView
## Game-over mode (ScoreKeeper::Open(true) / OnRender(lastPlaythrough), rules/score_and_game_over.md §6):
## {ships, beacons, scrap, crew, score}; empty = main-menu mode.
var session := {}
var more := false  # our "MORE STATS" page is shown instead of the two halves


func setup(t: TitleState) -> void:
	title = t
	position = Vector2.ZERO
	size = HudLayout.FRAME
	mouse_filter = Control.MOUSE_FILTER_STOP
	ship_list = ShipListView.new()
	ship_list.visible = false
	add_child(ship_list)
	ship_list.setup(t)
	ship_list.picked.connect(func(id, ty):
		ship_id = id
		ship_type = ty
		_build())


func open() -> void:
	visible = true
	more = false
	ship_list.visible = false
	_build()


## From the game over window: TOP SCORES + STATS pages, the STATS page showing this run (`data` as `session`).
func open_session(data: Dictionary) -> void:
	session = data
	left = 0
	right = 0
	open()


func close() -> void:
	if visible:
		visible = false
		closed.emit()


func _build() -> void:
	buttons.clear()
	buttons["tab_left"] = {"rect": Rect2(338, 38, 291, 53) if left == 0 else Rect2(43, 38, 302, 53),
		"image": "scoreUI/tab_shipbest" if left == 0 else "scoreUI/tab_topscores"}
	buttons["tab_right"] = {"rect": Rect2(838, 38, 387, 53) if right == 0 else Rect2(651, 38, 193, 53),
		"image": "scoreUI/tab_achieve" if right == 0 else "scoreUI/tab_stats"}
	buttons["close"] = {"rect": Rect2(1086, 627, 138, 46), "label": FtlData.tr_id("button_close"), "font": 64,
		"base": "scoreUI/score_close_box.png"}
	if more_enabled():
		var ml := "BACK" if more else "MORE STATS"
		var mw := FtlData.ftl_text_width(62, ml) + 16
		buttons["more"] = {"rect": Rect2(1060 - mw, 638, mw, 28), "label": ml, "font": 62}
	if more:
		for k in ["tab_left", "tab_right"]:
			buttons.erase(k)
		queue_redraw()
		return
	if left == 1:
		var lab := FtlData.tr_id("ship_list_button")
		var lw := FtlData.ftl_text_width(62, lab) + 8
		var x := LIST_CENTER.x - lw / 2.0 - 37
		buttons["prev"] = {"rect": Rect2(x, LIST_CENTER.y, 32, 28), "arrow": true}
		buttons["list"] = {"rect": Rect2(x + 37, LIST_CENTER.y, lw, 28), "label": lab, "font": 62}
		buttons["next"] = {"rect": Rect2(x + 37 + lw + 5, LIST_CENTER.y, 32, 28), "arrow": true, "mirror": true}
		for k in 3:
			var avail := title == null or title.unlocked(ship_id, k)
			if k == 2 and (ship_id == 8 or ship_id == TitleState.LANIUS):
				continue
			buttons["type%d" % k] = {"rect": Rect2(250 + 45 * k, 155, 36, 34),
				"label": FtlData.tr_id("typebutton_" + "abc"[k]), "font": 63,
				"state": "selected" if k == ship_type else ("on" if avail else "off")}
	queue_redraw()


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		var h := MenuDraw.button_at(buttons, e.position)
		if h != hover and h != "":
			FtlData.play("hoverBeep")
		hover = h
		queue_redraw()
	elif e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT and e.pressed:
		click(e.position)
	accept_event()


func _unhandled_key_input(e: InputEvent) -> void:
	if visible and not ship_list.visible and e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()


## ScoreKeeper::MouseClick: tabs switch pages, arrows cycle the ship (CycleLeft / CycleRight over the display
## order), LIST opens the ship list, A/B/C pick the layout, CLOSE closes.
func click(p: Vector2) -> String:
	var nm := MenuDraw.button_at(buttons, p)
	match nm:
		"tab_left":
			left = 1 - left
		"tab_right":
			right = 1 - right
		"close":
			close()
			return nm
		"more":
			more = not more
		"prev", "next":
			var pos := TitleState.SHIP_ORDER.find(ship_id)
			ship_id = TitleState.SHIP_ORDER[posmod(pos + (1 if nm == "next" else -1), 10)]
			if ship_type == 2 and (ship_id == 8 or ship_id == TitleState.LANIUS):
				ship_type = 0
		"list":
			ship_list.open(ship_id, ship_type)
		_:
			if nm.begins_with("type") and buttons[nm].state != "off":
				ship_type = int(nm.trim_prefix("type"))
	_build()
	return nm


func _draw() -> void:
	draw_rect(HudLayout.cover_rect(self, TooltipService.touch), Color(0, 0, 0, 0.75))  # MainMenu tint behind the screen
	if more:
		_draw_more()
		_draw_buttons()
		return
	MenuDraw.img(self, "scoreUI/score_main_left_%d.png" % (left + 1), Vector2.ZERO)
	MenuDraw.img(self, "scoreUI/score_main_right_%d.png" % (right + 1), Vector2(645, 0))
	for nm in ["tab_left", "tab_right"]:
		var b: Dictionary = buttons[nm]
		MenuDraw.image_button(self, String(b.image), b.rect, "on", hover == nm)
	var labels := [["stats_topscores", 188], ["stats_shipbest", 477], ["stats_stats", 753],
		["stats_achievements", 1023]]
	for l in labels:
		FtlData.draw_ftl_text(self, 64, FtlData.tr_id(l[0]), Vector2(l[1], 46), MenuDraw.COL_TEXT,
			FtlFont.Align.CENTER)
	if left == 1:
		_draw_ship_best()
	else:
		render_top_scores(PlayerProfile.current().top_scores, Vector2(112, 88),
			0 if PlayerProfile.current().new_flags.has("new_high") and not session.is_empty() else -1)
	if right == 1:
		_draw_achievements()
	elif not session.is_empty():
		_draw_session()
	else:
		_draw_stats()
	_draw_buttons()


func _draw_buttons() -> void:
	for nm in buttons:
		var b: Dictionary = buttons[nm]
		if b.has("image"):
			continue
		if b.has("arrow"):
			MenuDraw.image_button(self, "customizeUI/button_arrow", b.rect, "on", hover == nm, b.get("mirror", false))
			continue
		if b.has("base"):
			MenuDraw.img(self, String(b.base), (b.rect as Rect2).position - Vector2(15, 15))
		MenuDraw.text_button(self, b, hover == nm)


## ScoreKeeper::SetupTopShip: the first three ship achievements at (410, 118), 70 px apart.
func ship_best_achievements() -> Array:
	return MenuDraw.ship_achievements(ship_id).slice(0, 3)


func ship_best_rects() -> Array:
	var out := []
	for i in ship_best_achievements().size():
		out.append(Rect2(410 + 70 * i, 118, 64, 64))
	return out


## ScoreKeeper::Open lists (ACH_ROWS) as achievement entries {id, img, dim, unlocked} and their 64 px rects.
func page_achievements() -> Array:
	var out := []
	for r in 3:
		for i in ACH_ROWS[r].size():
			var a := MenuDraw.achievement(ACH_ROWS[r][i])
			if a.is_empty():
				continue
			out.append({"id": a.id, "img": a.img, "dim": 64, "unlocked": PlayerProfile.current().has_achievement(
				String(a.id)), "at": ACH_AT + Vector2(70 * i, 170 * r)})
	return out


var ach_hover := -1  # ScoreKeeper::selectedAch (ACHIEVEMENTS page)
var ship_ach_hover := -1  # ScoreKeeper::selectedShipAch (SHIP BEST page)


func _process(_d: float) -> void:
	if is_visible_in_tree() and not ship_list.visible:
		hover_tooltips(TooltipService.local_pointer(self))


## ScoreKeeper::MouseMove: on the ACHIEVEMENTS page every icon, on the SHIP BEST page the ship's three icons
## (64×64 strict) get AchievementTracker::SetTooltip (instant); the hovered one is drawn with style 1. Touch: the
## same tooltip while the finger is held (TooltipService). Returns the requested tooltip text ("" none).
func hover_tooltips(m: Vector2) -> String:
	var a := -1
	var sa := -1
	if not more:
		if right == 1:
			var achs := page_achievements()
			a = MenuDraw.achievement_hover(self, achs, achs.map(func(x): return Rect2(x.at, Vector2(64, 64))), m)
		if left == 1:
			sa = MenuDraw.achievement_hover(self, ship_best_achievements(), ship_best_rects(), m,
				TitleState.blueprint_of(ship_id, ship_type))
	if a != ach_hover or sa != ship_ach_hover:
		ach_hover = a
		ship_ach_hover = sa
		queue_redraw()
	return TooltipService.text


func _draw_ship_best() -> void:
	var bp := TitleState.blueprint_of(ship_id, ship_type)
	FtlData.draw_ftl_text(self, 24, TitleState.ship_class(bp), Vector2(217, 91), Color.WHITE, FtlFont.Align.CENTER)
	# ScoreKeeper::OnRender: CAchievement::OnRender(pos, selectedShipAch == i ? 1 : 0, showNew = true).
	var achs := ship_best_achievements()
	var rects := ship_best_rects()
	for i in achs.size():
		MenuDraw.draw_achievement(self, achs[i], rects[i].position, false, 1 if ship_ach_hover == i else 0, true)
	render_top_scores(PlayerProfile.current().ship_best(ship_id, ship_type), Vector2(112, 204), -1)


func _draw_achievements() -> void:
	for r in 3:
		FtlData.draw_ftl_text(self, 24, FtlData.tr_id(ACH_HEADINGS[r]), Vector2(ACH_AT.x, 99 + [0, 160, 330][r]),
			Color.WHITE)
	# ScoreKeeper::OnRender: CAchievement::OnRender(pos, selectedAch == i ? 1 : 0, showNew = true).
	var achs := page_achievements()
	for i in achs.size():
		MenuDraw.draw_achievement(self, achs[i], achs[i].at, false, 1 if ach_hover == i else 0, true)


## STATS page (main menu, ScoreKeeper::OnRender without lastPlaythrough): records (best run per stat), crew records
## (value + crew name), totals (profile totals, games played, victories). Same rows as the game-over mode.
func _draw_stats() -> void:
	var p := PlayerProfile.current()
	FtlData.draw_ftl_text(self, 24, FtlData.tr_id("records_heading"), Vector2(695, 100), Color.WHITE)
	for i in 4:
		_row("most_" + STATS[i], str(int(p.stat_max[i])), 150 + 20 * i)
	_draw_crew_records(240)
	FtlData.draw_ftl_text(self, 24, FtlData.tr_id("total_heading"), Vector2(695, 395), Color.WHITE)
	for i in 4:
		_row("total_" + STATS[i], str(int(p.stat_total[i])), 445 + 20 * i)
	_row("total_games", str(p.games_played), 525)
	_row("total_victories", str(p.victories), 545)


## Crew records: heading, then per record the label, the value and the crew member's name ("-" when none).
func _draw_crew_records(y: float) -> void:
	var p := PlayerProfile.current()
	FtlData.draw_ftl_text(self, 24, FtlData.tr_id("crew_heading"), Vector2(695, y), Color.WHITE)
	for i in CREW_STATS.size():
		var rec: Dictionary = p.crew_records[i] if i < p.crew_records.size() else {}
		var v := int(rec.get("value", 0))
		var ry := y + 45 + 21 * i
		_row(CREW_STATS[i], str(v) if v > 0 else "-", ry)
		if v > 0:
			FtlData.draw_ftl_text(self, 13, String(rec.get("name", "")), Vector2(1040, ry), MenuDraw.COL_SELECT,
				FtlFont.Align.CENTER)


static func _fill(id: String, v: Variant) -> String:
	return FtlData.tr_id(id).replace("\\1", str(v))


## ScoreKeeper::RenderTopScores: one row per score, 116 px apart, row baseline y = position.y + 97 + 116 i: the mini
## ship at (x, y − 97), "#n" (font 53) at (x − 51, y − 52), the ship name (font 24) centred at (x + 350, y − 96),
## SCORE / SECTOR / difficulty lines (font 14) centred at x + 350, y − 59 / − 35 / − 12, "Victory" (x + 205) and
## "Advanced" (x + 430) in font 12 yellow at y, "New!" (font 12) at (x + 200, y − 49) on the newest score.
func render_top_scores(list: Array, pos: Vector2, newest: int) -> void:
	for i in list.size():
		var e: Dictionary = list[i]
		var y := pos.y + 97 + 116 * i
		if y > 712:
			break
		if int(e.get("ship_id", -1)) >= 0:
			var mini := ShipListView.mini_texture(int(e.ship_id), maxi(int(e.get("type", 0)), 0))
			if mini:
				draw_texture(mini, Vector2(pos.x, y - 97))
		FtlData.draw_ftl_text(self, 53, _fill("stats_ranking", i + 1), Vector2(pos.x - 51, y - 52), Color.WHITE)
		var cx := pos.x + 350
		FtlData.draw_ftl_text(self, 24, String(e.get("name", "")), Vector2(cx, y - 96), Color.WHITE,
			FtlFont.Align.CENTER)
		FtlData.draw_ftl_text(self, 14, _fill("scorelist_score", int(e.get("score", 0))), Vector2(cx, y - 59),
			Color.WHITE, FtlFont.Align.CENTER)
		FtlData.draw_ftl_text(self, 14, _fill("scorelist_sector", int(e.get("sector", 1))), Vector2(cx, y - 35),
			Color.WHITE, FtlFont.Align.CENTER)
		var diff: String = ["easy", "normal", "hard"][clampi(int(e.get("difficulty", 1)), 0, 2)]
		FtlData.draw_ftl_text(self, 14, FtlData.tr_id(diff), Vector2(cx, y - 12), Color.WHITE, FtlFont.Align.CENTER)
		if bool(e.get("victory", false)):
			FtlData.draw_ftl_text(self, 12, FtlData.tr_id("victory"), Vector2(pos.x + 205, y), MenuDraw.COL_SELECT)
		if bool(e.get("ae", false)):
			FtlData.draw_ftl_text(self, 12, FtlData.tr_id("advanced"), Vector2(pos.x + 430, y), MenuDraw.COL_SELECT)
		if i == newest:
			FtlData.draw_ftl_text(self, 12, FtlData.tr_id("new_score"), Vector2(pos.x + 200, y - 49),
				MenuDraw.COL_SELECT)


## STATS page in game-over mode (ScoreKeeper::OnRender(lastPlaythrough), rules/score_and_game_over.md §6): session
## records (no profile: this run is the record), crew records, "Session Stats:" with this run's values and the
## final score. Labels at x 700, values centred at x 1165, headings at x 695.
func _draw_session() -> void:
	var vals := [int(session.get("ships", 0)), int(session.get("beacons", 0)), int(session.get("scrap", 0)),
		int(session.get("crew", 0))]
	FtlData.draw_ftl_text(self, 24, FtlData.tr_id("records_heading"), Vector2(695, 100), Color.WHITE)
	var prof := PlayerProfile.current()
	for i in 4:
		_row("most_" + STATS[i], str(maxi(vals[i], int(prof.stat_max[i]))), 150 + 20 * i)
	_draw_crew_records(240)
	FtlData.draw_ftl_text(self, 24, FtlData.tr_id("stats_heading"), Vector2(695, 395), Color.WHITE)
	for i in 4:
		_row(STATS[i], str(vals[i]), 445 + 20 * i)
	_row("final_score", str(int(session.get("score", 0))), 545)


func _row(id: String, value: String, y: float) -> void:
	FtlData.draw_ftl_text(self, 13, FtlData.tr_id(id), Vector2(700, y), Color.WHITE)
	FtlData.draw_ftl_text(self, 13, value, Vector2(1165, y), Color.WHITE, FtlFont.Align.CENTER)


# ------------------------------------------------------------------ MORE STATS (ours, rules/save_and_profile.md §3)

## The "MORE STATS" button: off unless a mod turns it on (QoL "Extended statistics").
static func more_enabled() -> bool:
	return Hooks.filter(&"stats_more_button", false) == true


## Our statistics page (PlayerProfile.extra): three columns in the options-frame look.
func _draw_more() -> void:
	var cols := more_lines(PlayerProfile.current())
	var titles := ["OVERALL", "COMBAT", "SHIPS AND DIFFICULTY"]
	for c in 3:
		var panel := Rect2(40 + 405 * c, 70, 390, 540)
		MenuDraw.options_frame(self, panel, titles[c])
		var y := panel.position.y + 12
		for line in cols[c]:
			if y > panel.end.y - 16:
				break
			if line is String:
				FtlData.draw_ftl_text(self, 13, line, Vector2(panel.position.x + 12, y), MenuDraw.COL_SELECT)
			else:
				FtlData.draw_ftl_text(self, 13, String(line[0]), Vector2(panel.position.x + 12, y), Color.WHITE)
				FtlData.draw_ftl_text(self, 13, String(line[1]), Vector2(panel.end.x - 12, y), Color.WHITE,
					FtlFont.Align.RIGHT)
			y += 20


static func _pct(w: int, n: int) -> String:
	return "-" if n <= 0 else "%d%%" % roundi(100.0 * w / n)


static func _time(secs: float) -> String:
	var s := int(secs)
	if s >= 3600:
		return "%d:%02d:%02d" % [s / 3600, (s / 60) % 60, s % 60]
	return "%d:%02d" % [s / 60, s % 60]


static func _ship_label(key: String) -> String:
	var parts := key.split(":")
	if parts.size() != 2 or int(parts[0]) < 0 or int(parts[0]) >= TitleState.SHIP_BLUEPRINTS.size():
		return key
	var cls := TitleState.ship_class(TitleState.SHIP_BLUEPRINTS[int(parts[0])])
	return "%s %s" % [cls if cls != "" else TitleState.SHIP_BLUEPRINTS[int(parts[0])], "ABC"[clampi(int(parts[1]), 0, 2)]]


## The page's lines per column: a String = sub-heading, [label, value] = a row. Pure (tests read it).
static func more_lines(p: PlayerProfile) -> Array:
	var x := p.extra
	var runs := int(x.get("runs", 0))
	var wins := int(x.get("wins", 0))
	var c1 := []
	c1.append(["Runs played", str(runs)])
	c1.append(["Victories", str(wins)])
	c1.append(["Losses", str(int(x.get("losses", 0)))])
	c1.append(["Abandoned", str(int(x.get("abandoned", 0)))])
	c1.append(["Win rate", _pct(wins, runs)])
	c1.append(["Current win streak", str(int(x.get("streak", 0)))])
	c1.append(["Best win streak", str(int(x.get("best_streak", 0)))])
	c1.append(["Average sector reached", "-" if runs == 0 else "%.1f" % (float(x.get("sector_sum", 0)) / runs)])
	c1.append(["Best score", str(int(x.get("best_score", 0)))])
	var fw: Dictionary = x.get("fastest_win", {})
	c1.append(["Fastest victory", "-" if fw.is_empty() else _time(float(fw.time))])
	c1.append(["Time played (in game)", _time(float(x.get("play_time", 0.0)))])
	var fav := ""
	var fav_n := 0
	var by_ship: Dictionary = x.get("by_ship", {})
	for k in by_ship:
		if int(by_ship[k].get("runs", 0)) > fav_n:
			fav_n = int(by_ship[k].runs)
			fav = String(k)
	c1.append(["Favourite ship", "-" if fav == "" else _ship_label(fav)])
	c1.append(["Scrap collected", str(int(x.get("scrap_collected", 0)))])
	c1.append(["Jumps", str(int(x.get("jumps", 0)))])
	c1.append("How runs ended")
	var res: Dictionary = x.get("results", {})
	var res_names := {"victory": "Victory", "gameover_crew": "Crew killed", "gameover_blowup": "Ship destroyed",
		"gameover_fedbase": "Federation base lost", "abandoned": "Abandoned"}
	for k in res:
		c1.append([res_names.get(k, String(k)), str(int(res[k]))])
	var c2 := []
	c2.append(["Hull damage dealt", str(int(x.get("damage_dealt", 0)))])
	c2.append(["Hull damage taken", str(int(x.get("damage_taken", 0)))])
	c2.append(["Most damage dealt in a run", str(int(x.get("most_damage_dealt", 0)))])
	c2.append(["Most damage taken in a run", str(int(x.get("most_damage_taken", 0)))])
	c2.append(["Ships defeated", str(int(x.get("ships_defeated", 0)))])
	c2.append(["Enemy crew killed", str(int(x.get("enemy_crew_killed", 0)))])
	c2.append(["Own crew deaths", str(int(x.get("crew_lost", 0)))])
	c2.append(["Shots dodged", str(int(x.get("dodges", 0)))])
	c2.append("Ships destroyed by class")
	var sd: Dictionary = x.get("ships_destroyed", {})
	var keys := sd.keys()
	keys.sort_custom(func(a, b): return int(sd[a]) > int(sd[b]))
	for k in keys.slice(0, 12):
		c2.append([String(k), str(int(sd[k]))])
	var c3 := []
	c3.append("Difficulty  (wins / runs)")
	var by_diff: Dictionary = x.get("by_difficulty", {})
	for d in 3:
		var b: Dictionary = by_diff.get(d, {})
		c3.append([["Easy", "Normal", "Hard"][d], "%d / %d  %s" % [int(b.get("wins", 0)), int(b.get("runs", 0)),
			_pct(int(b.get("wins", 0)), int(b.get("runs", 0)))]])
	c3.append("Ships  (wins / runs)")
	var ks := by_ship.keys()
	ks.sort_custom(func(a, b): return int(by_ship[a].get("runs", 0)) > int(by_ship[b].get("runs", 0)))
	for k in ks:
		var b: Dictionary = by_ship[k]
		c3.append([_ship_label(String(k)), "%d / %d  %s" % [int(b.get("wins", 0)), int(b.get("runs", 0)),
			_pct(int(b.get("wins", 0)), int(b.get("runs", 0)))]])
	return [c1, c2, c3]
