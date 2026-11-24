extends Node

const Harness := preload("res://tests/harness.gd")
## `--autobattle` demo (scripts/autobattle/autobattle.gd): a few short rounds headless at high speed
## (Engine.time_scale + a faster physics tick). Checks: rounds end and the next one starts, both ships power systems, fire and take damage,
## the round's AI wiring (left ship = player side with its own ShipAI and AI-driven crew), the layout fills canvases of
## other shapes (16:9, ultrawide) with the halves meeting in the middle and the backdrop covering the canvas, no
## menus / event boxes, and nothing written to user://. Run:
##   godot --headless --path godot res://tests/test_autobattle.tscn

const SCENE := preload("res://autobattle.tscn")
const ROUNDS := 3
const REAL_TIMEOUT := 240.0

var fails := 0


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func _ready() -> void:
	Harness.run(self, _run)


## user:// files (recursive) -> [modified time, size].
static func _user_files(dir := "user://") -> Dictionary:
	var out := {}
	var d := DirAccess.open(dir)
	if d == null:
		return out
	d.include_hidden = true
	for f in d.get_files():
		var p := dir.path_join(f)
		out[p] = [FileAccess.get_modified_time(p), FileAccess.get_size(p)]
	for sub in d.get_directories():
		if sub == "logs" or sub == "shader_cache" or sub == "vulkan":
			continue  # engine-owned caches
		out.merge(_user_files(dir.path_join(sub)))
	return out


func _frames(n := 3) -> void:
	for i in n:
		await get_tree().process_frame


func _check_layout(ab: Node, label: String) -> void:
	var vis := get_viewport().get_visible_rect().size
	var half := roundf(vis.x / 2.0)
	var l: Space = ab.left
	var r: Space = ab.right
	check(label + ": left half at x 0", l.position.x, 0.0)
	check(label + ": left half width", l.size.x, half)
	check(label + ": right half starts mid-canvas", r.position.x, half)
	check(label + ": right half reaches the edge", r.position.x + r.size.x, vis.x)
	check(label + ": halves full height", [l.size.y, r.size.y], [vis.y, vis.y])
	var bd: Control = ab.backdrop
	var cover := Rect2(bd.position, bd.size * bd.scale)
	check(label + ": backdrop covers the canvas", cover.grow(0.5).encloses(Rect2(Vector2.ZERO, vis)), true)
	var rh: Control = ab.right_hud
	check(label + ": right HUD on the right edge",
		absf(rh.position.x + AutobattleHud.WIDTH * rh.scale.x - (vis.x - ab.EDGE)) <= 1.0, true)
	check(label + ": ships turned to face each other", [l.fixed_rotation <= 0.0, r.fixed_rotation > 0.0], [true, true])


func _run() -> void:
	FtlData.muted = true
	var before := _user_files()
	get_tree().root.size = Vector2i(1280, 720)
	var ab: Node = SCENE.instantiate()
	ab.seed_value = 4242
	ab.round_time = 25.0
	ab.player_chance = 0.5
	add_child(ab)
	await _frames()
	print("round wiring")
	var c: Combat = ab.combat
	check("left ship is the player side", ab.left.ship.is_player, true)
	check("right ship is the enemy side", ab.right.ship.is_player, false)
	check("both ships have a ShipAI", [c.ais.has(ab.left), c.ais.has(ab.right)], [true, true])
	check("left crew AI on", c.crew_ais[ab.left].ai_on, true)
	check("crew AIs drive every crew", [c.crew_ais[ab.left].all_ai, c.crew_ais[ab.right].all_ai], [true, true])
	check("left crew player-owned", ab.left.ship.crew.all(func(m): return m.player_owned), true)
	check("rooms never blacked out", ShipView.reveal_all, true)
	check("aspect expand", get_tree().root.content_scale_aspect, Window.CONTENT_SCALE_ASPECT_EXPAND)
	_check_layout(ab, "16:9")
	get_tree().root.size = Vector2i(2560, 720)  # 32:9 (e.g. 5120 × 1440)
	await _frames()
	_check_layout(ab, "32:9")
	get_tree().root.size = Vector2i(1720, 720)  # 21:9 (3440 × 1440)
	await _frames()
	_check_layout(ab, "21:9")
	get_tree().root.size = Vector2i(1280, 720)
	await _frames()
	await _ui_modes(ab)

	# ×7 speed: GameClock caps one step at 0.5 factor units (1/32 s), so the steps are made shorter and more
	# frequent (240 Hz × time scale 7 = 7/240 s each) instead of just scaling a 60 Hz step.
	print("rounds at ×7 speed")
	var ticks := Engine.physics_ticks_per_second
	var steps := Engine.max_physics_steps_per_frame
	Engine.physics_ticks_per_second = 240
	Engine.max_physics_steps_per_frame = 32
	Engine.time_scale = 7.0
	var t0 := Time.get_ticks_msec()
	var st: Dictionary = ab.stats
	var objs := []
	var seen := 0
	while int(st.rounds_ended) < ROUNDS and (Time.get_ticks_msec() - t0) / 1000.0 < REAL_TIMEOUT:
		await get_tree().process_frame
		if int(st.rounds_started) != seen:
			seen = int(st.rounds_started)
			objs.append(Performance.get_monitor(Performance.OBJECT_COUNT))
	print("  objects at each round start: ", objs)
	# The next round starts after the end wait.
	while int(st.rounds_started) <= ROUNDS and (Time.get_ticks_msec() - t0) / 1000.0 < REAL_TIMEOUT:
		await get_tree().process_frame
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = ticks
	Engine.max_physics_steps_per_frame = steps
	print("  matchups: ", st.matchups, "  reasons: ", st.reasons, "  fired: ", st.fired)
	check("rounds ended", int(st.rounds_ended) >= ROUNDS, true)
	check("next round started after each end", int(st.rounds_started) >= ROUNDS + 1, true)
	check("every end has a reason", (st.reasons as Array).all(func(x): return x in ["destroyed", "crew", "time"]), true)
	check("both sides powered systems", [st.powered[true], st.powered[false]], [true, true])
	check("both sides fired", [int(st.fired[true]) > 0, int(st.fired[false]) > 0], [true, true])
	check("both sides took damage", [st.damaged[true], st.damaged[false]], [true, true])
	check("new round is live", ab.end_reason, "")
	check("one Combat at a time", ab.get_children().filter(func(n): return n is Combat).size(), 1)
	check("no event box / menus", ab.find_children("*", "EventBox", true, false).size()
		+ ab.find_children("*", "EndBox", true, false).size(), 0)
	_check_layout(ab, "after rounds")
	ab.queue_free()
	await _frames()
	check("reveal_all reset on exit", ShipView.reveal_all, false)
	var after := _user_files()
	print("  user:// files: %d before, %d after" % [before.size(), after.size()])
	check("nothing written to user://", after == before, true)


## Interface option (Wallpaper Engine combo / --autobattle-ui / ftl/autobattle/ui): full, hull only, none.
func _ui_modes(ab: Node) -> void:
	print("interface: full / hull only / none")
	check("project setting default", ProjectSettings.get_setting("ftl/autobattle/ui"), "full")
	check("parse", [ab.parse_ui_mode("FULL"), ab.parse_ui_mode("Hull only"), ab.parse_ui_mode("none"),
		ab.parse_ui_mode("bogus"), ab.parse_ui_mode(null)], ["full", "hull", "none", "", ""])
	check("starts with the full UI", [ab.ui_mode, ab.left_hud.mode, ab.overlay.visible], ["full", "full", true])
	var z_full: float = ab.zoom
	check("full: the HUD column is kept clear", ab.left_hud.column_width() > 0.0, true)
	ab.set_ui_mode("hull")
	await _frames()
	check("hull only: both HUDs", [ab.left_hud.mode, ab.right_hud.mode], ["hull", "hull"])
	check("hull only: no round banner", ab.overlay.visible, false)
	check("hull only: no column, a top band", [ab.left_hud.column_width(), ab.left_hud.top_height() > 0.0],
		[0.0, true])
	check("hull only: ships at least as large", ab.zoom >= z_full, true)
	_check_layout(ab, "hull only")
	ab.set_ui_mode("none")
	await _frames()
	check("none: nothing drawn, no band", [ab.left_hud.mode, ab.left_hud.top_height(), ab.overlay.visible],
		["none", 0.0, false])
	_check_layout(ab, "none")
	ab.set_ui_mode("nonsense")
	check("unknown value ignored", ab.ui_mode, "none")
	ab.set_ui_mode("full")
	await _frames()
	check("back to full", [ab.left_hud.mode, ab.overlay.visible, ab.zoom], ["full", true, z_full])
	var shell := FileAccess.get_file_as_string("res://web/wallpaper_shell.html")
	check("web shell passes the uimode combo as window.vortexUi",
		shell.contains("p.uimode") and shell.contains("window.vortexUi"), true)
