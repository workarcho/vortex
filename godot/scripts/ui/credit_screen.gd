class_name CreditScreen
extends Control
## FTL's CreditScreen (rules/score_and_game_over.md "Credits"): the scrolling credits that GameOver::SetVictory(true)
## starts before the victory window (RunEndBox owns one, like GameOver owns `credits`). CreditScreen::Start reads
## data/credits.txt (one Kickstarter backer per line) and builds the crew line; CreditScreen::OnRender draws the
## stars/bg_darknebula.png backdrop (opaque, tinted 0.5), then every credit line whose y is inside (-50, 720) after
## the scroll, and advances the timers (`step`); CreditScreen::Done ends it once the last line is past.
## Esc skips (GameOver::KeyDown); touch: a finger held 2 s skips (CreditScreen::OnTouch / Done), with the
## `touch_skip` hint top-right while a finger is down. All positions are FTL's 1280 x 720 frame.

const BG := "img/stars/bg_darknebula.png"
const NAMES_FILE := "data/credits.txt"
const PAUSE_SHIP := 5.0  # Start with a ship name: pausing = 5 (the text fades in during the first second)
const START_NO_SHIP := -70.0  # Start without a ship name (main menu): scroll = -70, no pause
const SCROLL_SPEED := 3.5  # px per speed-factor unit (x 16 per s = 56 px/s)
const HOLD_AT := -720.0  # the scroll stops once at -720 (the victory page has left) ...
const HOLD_TIME := 3.0  # ... for 3 s
const SHOW_TOP := -50.0  # a line is drawn while -50 < scroll + y < 720
const SHOW_BOTTOM := 720.0
const TOUCH_SKIP := 2.0  # s a finger must stay down to skip
const SKIP_FADE := 0.75  # touch_skip hint: alpha = min(timer / 0.75, 1), box alpha 0.75 x that
const CENTER_X := 640.0
## The victory page (only with a ship name): [y, text id ("@ship" / "@crew" = Start's strings), font, wrap width
## (0 = easy_printCenter, else easy_printNewlinesCentered)].
const SHIP_LINES := [[150, "thank_ship", 14, 0], [190, "@ship", 20, 0], [270, "thank_crew", 14, 0],
	[310, "@crew", 18, 900], [510, "credit_victory", 14, 750]]
## The fixed credits, same layout.
const LINES := [[775, "game_from", 14, 0], [815, "subset_games", 18, 0], [925, "created_by", 14, 0],
	[965, "matthew_justin", 18, 0], [1075, "addition_code", 14, 0], [1115, "andrew_church", 18, 0],
	[1205, "music_by", 14, 0], [1245, "ben_prunty", 18, 0], [1335, "writing_by", 14, 0], [1375, "tom_jubert", 18, 0],
	[1460, "guest_writer", 14, 0], [1500, "chris_a", 18, 0], [1590, "additional_art", 14, 0], [1630, "bryan_ma", 18, 0],
	[1720, "editing", 14, 0], [1760, "alison_w", 18, 0], [1850, "additional_testing", 14, 0],
	[1890, "family_friends", 18, 750], [2090, "credits_loc_riotloc", 18, 750], [2180, "credits_loc_project", 14, 750],
	[2220, "credits_loc_project_names", 18, 750], [2320, "credits_loc_fr", 14, 750],
	[2360, "credits_loc_fr_names", 18, 750], [2460, "credits_loc_it", 14, 750], [2500, "credits_loc_it_names", 18, 750],
	[2600, "credits_loc_de", 14, 750], [2640, "credits_loc_de_names", 18, 750], [2706, "credits_loc_es", 14, 750],
	[2746, "credits_loc_es_names", 18, 750], [2846, "credits_loc_pl", 14, 750], [2886, "credits_loc_pl_names", 18, 750],
	[2986, "credits_loc_pt_BR", 14, 750], [3026, "credits_loc_pt_BR_names", 18, 750], [3126, "credits_loc_ru", 14, 750],
	[3166, "credits_loc_ru_names", 18, 750], [3366, "kickstarter", 14, 750]]
## Backer names: three columns (CSWTCH_234), a row every 40 px from y 3446, font 14 centred.
const NAME_X := [270.0, 640.0, 1010.0]
const NAME_Y := 3446
const NAME_ROW := 40
## After the names (y + rows x 40): font 12 centred. "font" is not in 1.6.9's text files: TextLibrary::GetText
## returns "Could not find: font" for it, which is what vanilla prints.
const TAIL := [[3546, "third_party"], [3586, "folder"], [3666, "bass"], [3716, "rapidxml"], [3766, "freetype"],
	[3866, "font"]]
const END_Y := 3906  # Done: scroll < -(rows x 40 + 3906)

var ship_name := ""
var crew_string := ""
var names := PackedStringArray()
var scroll := 0.0
var pausing := 0.0
var showing := false
var touches := 0
var touch_time := 0.0
var skip_timer := 0.0
var _clock := 0.0


func _init() -> void:
	position = Vector2.ZERO
	size = HudLayout.FRAME
	mouse_filter = Control.MOUSE_FILTER_STOP  # GameOver::MouseClick does nothing while the credits run


## CreditScreen::Start(shipName, crewNames).
func start(ship: String, crew: Array) -> void:
	names = load_names()
	ship_name = ship
	scroll = 0.0
	if ship == "":
		scroll = START_NO_SHIP
		pausing = 0.0
	else:
		crew_string = crew_text(crew)
		pausing = PAUSE_SHIP
	touches = 0
	skip_timer = 0.0
	showing = true
	visible = true


## data/credits.txt split on '\n', a trailing '\r' dropped from each line.
static func load_names() -> PackedStringArray:
	var out := PackedStringArray()
	var raw := FtlData.text(NAMES_FILE)
	if raw == "":
		return out
	var lines := raw.split("\n")
	if not lines.is_empty() and lines[-1] == "":
		lines.remove_at(lines.size() - 1)  # getline: no entry after the final newline
	for l in lines:
		out.append(l.trim_suffix("\r"))
	return out


## Start's crew line: name, then `crewlist_comma` before all but the last two, `crewlist_and` before the last.
static func crew_text(crew: Array) -> String:
	var s := ""
	for i in crew.size():
		s += String(crew[i])
		if i < crew.size() - 2:
			s += FtlData.tr_id("crewlist_comma")
		elif i == crew.size() - 2:
			s += FtlData.tr_id("crewlist_and")
	return s


## TextLibrary::GetText: a missing id reads "Could not find: <id>".
static func text_of(id: String) -> String:
	var t := FtlData.tr_id(id)
	return "Could not find: " + id if t == id else t.replace("\\n", "\n")


## Text alpha (OnRender): 1 once pausing <= 4, else 5 - pausing (the 1 s fade-in after Start with a ship).
func text_alpha() -> float:
	return 1.0 if pausing <= 4.0 else clampf(5.0 - pausing, 0.0, 1.0)


## OnRender's timers for one frame of `seconds` (speed factor = 16 x seconds): pausing counts down; below 0 the
## credits scroll up 3.5 px per factor unit, holding 3 s once when they reach -720; the touch hint timer.
func step(seconds: float) -> void:
	_clock += seconds
	var f := seconds * GameClock.BASE
	pausing -= f * 0.0625
	if pausing < 0.0:
		var last := scroll
		var s := scroll - f * SCROLL_SPEED
		if s > HOLD_AT or last <= HOLD_AT:
			scroll = s
		else:
			scroll = HOLD_AT
			pausing = HOLD_TIME
	if touches < 1:
		skip_timer = maxf(skip_timer - f * 0.0625, 0.0)
	else:
		skip_timer = 1.0


## CreditScreen::Done: the last line has scrolled away, or a finger has been held 2 s.
func done() -> bool:
	if scroll < -float(floori(names.size() / 3.0) * NAME_ROW + END_Y):
		return true
	return touches > 0 and _clock >= touch_time + TOUCH_SKIP


## GameOver::KeyDown: Esc while the credits run.
func skip() -> void:
	showing = false
	visible = false


func _input(event: InputEvent) -> void:
	if not showing or not is_visible_in_tree():
		return
	var k := event as InputEventKey
	if k != null and k.pressed and not k.echo and k.keycode == KEY_ESCAPE:
		skip()
		get_viewport().set_input_as_handled()
		return
	var t := event as InputEventScreenTouch
	if t != null:
		on_touch(t.pressed)


## CreditScreen::OnTouch: the first finger down records the time; up / cancel counts down.
func on_touch(down: bool) -> void:
	if down:
		if touches == 0:
			touch_time = _clock
		touches += 1
	else:
		touches = maxi(touches - 1, 0)


func _process(_d: float) -> void:
	if showing:
		queue_redraw()


func _draw() -> void:
	if not showing:
		return
	draw_rect(HudLayout.cover_rect(self, TooltipService.touch), Color.BLACK)
	var bg := FtlData.texture(BG)
	if bg:
		# GL_DisableBlend around RenderImage: drawn opaque, colour (0.5, 0.5, 0.5).
		draw_texture(bg, Vector2.ZERO, Color(0.5, 0.5, 0.5, 1.0))
	var col := Color(1, 1, 1, text_alpha())
	draw_set_transform(Vector2(0, float(int(scroll))))
	if ship_name != "":
		for l in SHIP_LINES:
			var txt := ship_name if l[1] == "@ship" else (crew_string if l[1] == "@crew" else text_of(l[1]))
			_line(float(l[0]), txt, int(l[2]), int(l[3]), col)
	for l in LINES:
		_line(float(l[0]), text_of(l[1]), int(l[2]), int(l[3]), col)
	for i in names.size():
		var y := float(floori(i / 3.0) * NAME_ROW + NAME_Y)
		if _shown(y):
			FtlData.draw_ftl_text(self, 14, names[i], Vector2(NAME_X[i % 3], y), col, FtlFont.Align.CENTER)
	var rows := floori(names.size() / 3.0) * NAME_ROW
	for l in TAIL:
		_line(float(rows + int(l[0])), text_of(l[1]), 12, 0, col)
	draw_set_transform(Vector2.ZERO)
	if skip_timer > 0.0:
		var a := minf(skip_timer / SKIP_FADE, 1.0)
		var msg := FtlData.tr_id("touch_skip")
		var w := float(FtlData.ftl_text_width(12, msg))
		var h := float(FtlData.ftl_line_height(12))
		draw_rect(Rect2(HudLayout.FRAME.x - (20.0 + w), 0, 20.0 + w, h + 20.0), Color(0, 0, 0, SKIP_FADE * a))
		FtlData.draw_ftl_text(self, 12, msg, Vector2(HudLayout.FRAME.x - (10.0 + w), 10), Color(1, 1, 0, a))


func _shown(y: float) -> bool:
	return scroll + y > SHOW_TOP and scroll + y < SHOW_BOTTOM


func _line(y: float, text: String, font: int, wrap: int, col: Color) -> void:
	if _shown(y):
		FtlData.draw_ftl_text(self, font, text, Vector2(CENTER_X, y), col, FtlFont.Align.CENTER, wrap)
