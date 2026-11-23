extends Node2D
## `--autobattle` (autobattle.tscn): a screensaver / live-wallpaper demo. Two AI ships fight each other forever,
## round after round, side by side across the whole canvas (no TARGET window, no menus, no event boxes, no saving).
##
## Sides: the fight engine (Combat, ShipState, CrewMember) has a player side (iShipId 0) and an enemy side (1) — crew
## ownership, intruders, damage owner, clone queues all hang on it. Rather than a second "enemy vs enemy" mode, the
## LEFT ship is the player side and gets its own ShipAI + an AI-driven CrewAI (exactly what the right / enemy ship
## gets from Combat.add_space): power, weapons and targeting, drones, shields, cloaking, battery, boarding, hacking,
## mind control (ShipState.ai_driven), crew stations / repair / fire fighting / healing / venting / intruders
## (CrewAI.ai_on + all_ai). AutobattleMatchup builds both ships with the normal enemy generator; an enemy-built left
## ship keeps its enemy art (ShipState.enemy_art) and is turned to face right, the right one faces left.
##
## Layout: each ship in its own Space (SubViewportContainer) covering half of the canvas, turned with the Space's
## fixed rotation, both at the same zoom, centred vertically; shots leave one half towards the middle and enter the
## other half from the middle (entry angle / beam side point forced toward the opponent, `_aim_entries`). HUDs on
## the left / right edges (AutobattleHud), the beacon backdrop covers the canvas. Re-laid out on every resize; the
## window uses aspect EXPAND (FrameHost sets KEEP on PC) so ultrawide windows are filled.
##
## Round end: a ship destroyed (explosion shown), a side with no crew left (not automated ships), or the time limit
## (ships without weapons never stall). A few seconds later the next round starts. Sandbox AI never escapes or
## surrenders (those are run events).
##
## CLI: --autobattle [--mute] [--log] [--seed=N] [--round-time=S] [--player-chance=F] [--screenshot=PNG [--wait=S]]
##      plus Godot's own --fullscreen / --resolution WxH. Esc quits; the mouse cursor hides after 3 s idle.

const ROUND_TIME := 210.0  # s of game time before a round is called off
const DESTROYED_WAIT := 7.0  # s after the hull reaches 0 (enemy explosion 3 s, player-side 6 s)
const CREW_WAIT := 4.0
const TIMEOUT_WAIT := 3.0
const CURSOR_IDLE := 3.0
const ENTRY_SPREAD := 22.0  # degrees around the direction of the opponent (shots entering a half)
const BEAM_SPREAD := 160.0  # px across that direction (beam side points)
const MID_GAP := 8.0  # canvas px kept free between a ship area and the middle line
const EDGE := 8.0  # HUD distance from the canvas edges
const V_MARGIN := 16.0  # canvas px above / below the ships
const ZOOM_MIN := 0.5
const ZOOM_MAX := 2.5

## Counters read by the tests (reset when the scene starts).
static var stats := {}

var round_time := ROUND_TIME
var player_chance := AutobattleMatchup.PLAYER_CHANCE
var seed_value := -1  # -1 = random

var rng := RandomNumberGenerator.new()
var layer: CanvasLayer
var root_ctrl: Control
var backdrop: SpaceBackdrop
var overlay: Control  # round banner (top centre)
var left_hud: AutobattleHud
var right_hud: AutobattleHud
var combat: Combat
var left: Space
var right: Space
var matchup := {}
var round_no := 0
var round_t := 0.0
var end_reason := ""  # "" while fighting; destroyed / crew / time
var end_text := ""
var end_timer := 0.0
var zoom := 1.0
var _crew_start := {}  # side (is_player) -> crew count at the round start
var _idle := 0.0
var _shot := ""
var _wait := 8.0
var _saved_difficulty := 0
var _saved_aspect := Window.CONTENT_SCALE_ASPECT_EXPAND


func _ready() -> void:
	stats = {"rounds_started": 0, "rounds_ended": 0, "reasons": [], "fired": {true: 0, false: 0},
		"powered": {true: false, false: false}, "damaged": {true: false, false: false}, "matchups": []}
	# Wallpaper builds: override.cfg (PC) or the `wallpaper` feature tag override in project.godot (web).
	if ProjectSettings.get_setting_with_override("ftl/autobattle/mute") == true:
		FtlData.muted = true
	for a in OS.get_cmdline_user_args():
		if a == "--mute":
			FtlData.muted = true
		elif a == "--log":
			Combat.verbose = true  # combat log (shots, hits, AI actions) on stdout
		elif a.begins_with("--seed="):
			seed_value = int(a.trim_prefix("--seed="))
		elif a.begins_with("--round-time="):
			round_time = maxf(float(a.trim_prefix("--round-time=")), 5.0)
		elif a.begins_with("--player-chance="):
			player_chance = clampf(float(a.trim_prefix("--player-chance=")), 0.0, 1.0)
		elif a.begins_with("--screenshot="):
			_shot = a.trim_prefix("--screenshot=")
		elif a.begins_with("--wait="):
			_wait = float(a.trim_prefix("--wait="))
	if seed_value >= 0:
		rng.seed = seed_value
	else:
		rng.randomize()
	_saved_difficulty = ShipAI.difficulty
	_saved_aspect = get_tree().root.content_scale_aspect
	get_tree().root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND  # fill ultrawide (PC host: KEEP)
	RenderingServer.set_default_clear_color(Color.BLACK)
	ShipView.reveal_all = true  # both interiors in full (no sensors blackout)
	TooltipService.hud_blocked = true
	Hooks.listen(&"weapon_fired", _on_weapon_fired, 0, "autobattle")
	layer = CanvasLayer.new()
	add_child(layer)
	root_ctrl = Control.new()
	root_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root_ctrl)
	backdrop = SpaceBackdrop.new()
	root_ctrl.add_child(backdrop)
	left_hud = AutobattleHud.new()
	right_hud = AutobattleHud.new()
	root_ctrl.add_child(left_hud)
	root_ctrl.add_child(right_hud)
	overlay = Control.new()
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.draw.connect(_draw_overlay)
	root_ctrl.add_child(overlay)
	get_viewport().size_changed.connect(_layout)
	start_round()
	if _shot != "":
		_screenshot.call_deferred()


func _exit_tree() -> void:
	Hooks.unlisten(&"weapon_fired", _on_weapon_fired)
	ShipView.reveal_all = false
	TooltipService.hud_blocked = false
	ShipAI.difficulty = _saved_difficulty
	if is_inside_tree():
		get_tree().root.content_scale_aspect = _saved_aspect
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_clear_round(false)


# ------------------------------------------------------------------ rounds

func start_round() -> void:
	_clear_round()
	round_no += 1
	round_t = 0.0
	end_reason = ""
	end_text = ""
	matchup = AutobattleMatchup.roll(rng, player_chance)
	var ls: ShipState = matchup.left
	var rs: ShipState = matchup.right
	combat = Combat.new()
	combat.rng.seed = rng.randi()
	add_child(combat)
	left = Space.new()
	right = Space.new()
	for sp in [left, right]:
		sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
		root_ctrl.add_child(sp)
		root_ctrl.move_child(sp, backdrop.get_index() + 1 + (1 if sp == right else 0))
	left.setup(ls)
	right.setup(rs)
	combat.add_space(left, right)
	combat.add_space(right, left)
	# The left (player-side) ship gets what Combat.add_space gives an enemy: its ShipAI and an AI-driven crew.
	var lai := ShipAI.new(ls, combat.rng)
	lai.crew_ai = combat.crew_ais[left]
	combat.ais[left] = lai
	combat.crew_ais[left].ai_on = true
	for cai: CrewAI in combat.crew_ais.values():
		cai.all_ai = true  # player-owned crew (at home or boarding) are AI-driven too
	if not ls.enemy_art and ls.sys("teleporter") != null and lai.boarding_ai == 0:
		# Player layouts have no <boardingAI>: board like a "sabotage" enemy (half the crew may go).
		var n := ls.own_crew().size()
		lai.boarding_ai = 1
		lai.crew_needed = n - n / 2
	backdrop.setup(matchup.space, null, null)
	backdrop.set_anchors_preset(Control.PRESET_TOP_LEFT)  # setup() anchors it full-rect: _layout scales it
	var diff: String = ["Easy", "Normal", "Hard"][int(matchup.difficulty)]
	left_hud.setup(ls, false, "%s · sector %d · %s" % [_fleet_name(matchup.left_fleet), int(matchup.level) + 1, diff])
	right_hud.setup(rs, true, "%s · sector %d · %s" % [_fleet_name(matchup.right_fleet), int(matchup.level) + 1, diff])
	_crew_start = {true: _side_crew(true), false: _side_crew(false)}
	stats.rounds_started += 1
	stats.matchups.append([ls.blueprint.name, rs.blueprint.name, int(matchup.level), int(matchup.difficulty)])
	print("autobattle round %d: %s (%s) vs %s (%s), sector %d, %s" % [round_no, ls.blueprint.name,
		matchup.left_fleet, rs.blueprint.name, matchup.right_fleet, int(matchup.level) + 1, diff])
	_layout()


func _clear_round(free_nodes := true) -> void:
	for n in [combat, left, right]:
		if free_nodes and n != null and is_instance_valid(n) and n.get_parent() != null:
			n.get_parent().remove_child(n)  # out of the tree at once: the old combat must not step again
			n.queue_free()
	# The round's ShipStates hold reference cycles (opponent, environment / graph / drones back to the ship): break
	# them once the nodes are gone, or a screensaver running for hours would keep every round's ships.
	var ships := []
	for sp in [left, right]:
		if sp != null and is_instance_valid(sp) and sp.ship != null:
			ships.append(sp.ship)
	if not ships.is_empty():
		_release_ships.call_deferred(ships)
	combat = null
	left = null
	right = null


static func _release_ships(ships: Array) -> void:
	for s: ShipState in ships:
		s.opponent = null
		s.drones.clear()
		s.hack_drone = null
		s.crew.clear()
		s.env = null
		s.graph = null


static func _fleet_name(f: String) -> String:
	if f == "PLAYER":
		return "Player layout"
	return FtlData.readable_name(f.trim_prefix("SHIPS_")) + " fleet"


## Living crew of one side, anywhere (both ships, teleporting, clone queue); drones left out.
func _side_crew(side: bool) -> int:
	var n := 0
	for sp in [left, right]:
		for c in sp.ship.crew:
			if c.player_owned == side and c.is_alive() and not c.is_drone():
				n += 1
		if sp.ship.is_player == side:
			n += sp.ship.clone_queue.size()
	for k in combat.parties:
		for p in combat.parties[k]:
			var c: CrewMember = p.crew
			if c.player_owned == side and c.is_alive() and not c.is_drone() and not (p.to as ShipState).crew.has(c) \
					and not (p.from as ShipState).crew.has(c):
				n += 1
	return n


func _physics_process(delta: float) -> void:
	if combat == null:
		return
	_aim_entries()
	for sp in [left, right]:
		if sp.ship.reactor_used() > 0:
			stats.powered[sp.ship.is_player] = true
		if sp.ship.hull < sp.ship.max_hull:
			stats.damaged[sp.ship.is_player] = true
	if end_reason == "":
		round_t += delta
		_check_end()
	else:
		end_timer -= delta
		if end_timer <= 0.0:
			start_round()


func _check_end() -> void:
	for sp in [left, right]:
		if sp.ship.is_destroyed():
			_end("destroyed", "%s DESTROYED" % _name(sp.ship), DESTROYED_WAIT)
			return
	for side in [true, false]:
		if int(_crew_start.get(side, 0)) > 0 and _side_crew(side) == 0:
			var s: ShipState = left.ship if side else right.ship
			_end("crew", "%s: ALL CREW LOST" % _name(s), CREW_WAIT)
			return
	if round_t >= round_time:
		_end("time", "TIME UP: DRAW", TIMEOUT_WAIT)


func _end(reason: String, text: String, wait: float) -> void:
	end_reason = reason
	end_text = text
	end_timer = wait
	stats.rounds_ended += 1
	stats.reasons.append(reason)
	print("autobattle round %d ended after %.1f s: %s" % [round_no, round_t, text])


static func _name(s: ShipState) -> String:
	var cls := TitleState.ship_class(String(s.blueprint.get("name", "")))
	return (cls if cls != "" else FtlData.readable_name(String(s.blueprint.get("name", "")))).to_upper()


func _on_weapon_fired(from: ShipState, w: WeaponState, to: ShipState) -> void:
	if combat == null or left == null or (from != left.ship and from != right.ship):
		return
	stats.fired[from.is_player] += 1
	var dest := left if to == left.ship else right
	# Combat.fire: the volley's entry angle was just rolled (0..359); keep its spread, around the opponent's side.
	w.volley_entry_angle = fposmod(_toward_opponent(dest) + (fposmod(w.volley_entry_angle, 360.0) / 360.0 * 2.0
		- 1.0) * ENTRY_SPREAD, 360.0)


## World angle (degrees) of the direction, in `sp`'s world, that points at the other ship on screen.
func _toward_opponent(sp: Space) -> float:
	var screen_dir := Vector2.RIGHT if sp == left else Vector2.LEFT
	return rad_to_deg(screen_dir.rotated(sp.fixed_rotation).angle())


## Beams: their off-screen start in the target space (Beam.side_point, one of four sides) moved to the side facing
## the opponent, once per beam (the beam re-reads it every step).
func _aim_entries() -> void:
	for p in combat.projectiles:
		if p is Beam and not p.has_meta("ab_side") and p.dest_space != p.source_space:
			p.set_meta("ab_side", true)
			var a := deg_to_rad(_toward_opponent(p.dest_space))
			var dir := Vector2.from_angle(a)
			p.sub_start = p.target_ship.shield_center + dir * Beam.SIDE_DISTANCE \
				+ dir.orthogonal() * combat.rng.randf_range(-BEAM_SPREAD, BEAM_SPREAD)


# ------------------------------------------------------------------ layout

## Ship turn: an enemy-art hull points up; the left one is turned to face right, the right one to face left.
static func ship_rotation(s: ShipState, on_left: bool) -> float:
	if s.player_art():
		return 0.0  # player layouts already face right (only ever on the left)
	return -PI / 2 if on_left else PI / 2


## World bounds of a ship as drawn: shield ellipse, hull image and rooms.
static func ship_bounds(s: ShipState) -> Rect2:
	var r := Rect2(s.shield_center - s.shield_axes, s.shield_axes * 2).merge(s.rooms_bounds())
	var img: Rect2 = s.layout.img_rect
	if img.size.x > 0 and img.size.y > 0:
		r = r.merge(Rect2(s.hull_position(), img.size))
	return r


## HUD scale: 1 on a 720-tall canvas, larger on taller ones (quarter steps).
static func hud_scale(vis: Vector2) -> float:
	return clampf(floorf(minf(vis.y / 720.0, vis.x / 1280.0) * 4.0) / 4.0, 1.0, 3.0)


## Safe area in screen pixels (project settings ftl/autobattle/margin_left|right|top|bottom, e.g. from the
## wallpaper build's override.cfg): keeps the HUDs and ships clear of desktop icons / a side taskbar. The backdrop
## still covers the whole canvas. Returned in canvas units (left, top, right, bottom).
func safe_margins(vis: Vector2) -> Array:
	var win := Vector2(get_window().size)
	var f := vis.x / win.x if win.x > 0.0 else 1.0
	var out := []
	var web := _web_margins
	for k in ["left", "top", "right", "bottom"]:
		var v: Variant = ProjectSettings.get_setting_with_override("ftl/autobattle/margin_" + k)  # feature overrides
		if web.has(k):  # Wallpaper Engine sliders (web build, window.vortexMargins) win
			v = web[k]
		out.append(maxf(float(v) if v != null else 0.0, 0.0) * f)
	return out


func _layout() -> void:
	if left == null or not is_inside_tree():
		return
	var full := get_viewport().get_visible_rect().size
	var m := safe_margins(full)
	var off := Vector2(m[0], m[1])
	var vis := Vector2(maxf(full.x - m[0] - m[2], 320.0), maxf(full.y - m[1] - m[3], 240.0))
	root_ctrl.position = Vector2.ZERO
	root_ctrl.size = full
	# Backdrop: the 1280 × 720 beacon picture scaled to cover the whole canvas, centred.
	var cs := maxf(full.x / HudLayout.FRAME.x, full.y / HudLayout.FRAME.y)
	backdrop.size = HudLayout.FRAME
	backdrop.scale = Vector2(cs, cs)
	backdrop.position = ((full - HudLayout.FRAME * cs) / 2.0).round()
	overlay.position = Vector2.ZERO
	overlay.size = full
	var k := hud_scale(vis)
	left_hud.scale = Vector2(k, k)
	right_hud.scale = Vector2(k, k)
	left_hud.position = (off + Vector2(EDGE, EDGE)).round()
	right_hud.position = (off + Vector2(vis.x - EDGE - AutobattleHud.WIDTH * k, EDGE)).round()
	# Ships: each in its half, clear of its HUD column, both at the zoom the tighter one allows.
	var half := roundf(vis.x / 2.0)
	var col := EDGE + (maxf(left_hud.column_width(), right_hud.column_width()) + 8.0) * k
	var area_w := maxf(half - col - MID_GAP, 100.0)
	var area_h := maxf(vis.y - 2.0 * V_MARGIN, 100.0)
	var z := ZOOM_MAX
	var info := []
	for sp: Space in [left, right]:
		var rot := ship_rotation(sp.ship, sp == left)
		var b := ship_bounds(sp.ship)
		var bs := b.size if is_zero_approx(fmod(absf(rot), PI)) else Vector2(b.size.y, b.size.x)
		z = minf(z, minf(area_w / bs.x, area_h / bs.y))
		info.append([sp, rot, b])
	z = clampf(z, ZOOM_MIN, ZOOM_MAX)
	z = floorf(z * 8.0) / 8.0 if z >= 1.0 else floorf(z * 16.0) / 16.0  # clean pixel-art steps
	zoom = z
	for e in info:
		var sp: Space = e[0]
		var rot: float = e[1]
		var b: Rect2 = e[2]
		var on_left := sp == left
		var split := off.x + half  # the halves meet at the centre of the safe area; each covers the canvas edge
		sp.position = Vector2(0 if on_left else split, 0)
		sp.size = Vector2(split if on_left else full.x - split, full.y)
		var cx := off.x + col + area_w / 2.0 if on_left else MID_GAP + area_w / 2.0
		var centre := Vector2(roundf(cx), roundf(off.y + vis.y / 2.0))
		sp.fixed_rotation = rot
		sp.set_fixed_origin((centre - b.get_center().rotated(-rot) * z).round(), z)


# ------------------------------------------------------------------ frame: cursor, keys, music, banner

var _web_margins := {}
var _web_poll := 0.0


## Web wallpaper: Wallpaper Engine's margin sliders arrive in window.vortexMargins (web/wallpaper_shell.html).
func _poll_web_margins(delta: float) -> void:
	if not OS.has_feature("web"):
		return
	_web_poll -= delta
	if _web_poll > 0.0:
		return
	_web_poll = 0.5
	var raw: Variant = JavaScriptBridge.eval("JSON.stringify(window.vortexMargins || {})", true)
	var d: Variant = JSON.parse_string(String(raw)) if raw != null else null
	if d is Dictionary and d != _web_margins:
		_web_margins = d
		_layout()


func _process(delta: float) -> void:
	_poll_web_margins(delta)
	_idle += delta / maxf(Engine.time_scale, 0.001)
	if _idle > CURSOR_IDLE and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE and DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
	if combat != null:
		var live := end_reason == "" and not left.ship.is_destroyed() and not right.ship.is_destroyed()
		Music.check_world(left.ship, live, null)
	overlay.queue_redraw()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion or event is InputEventMouseButton or event is InputEventScreenTouch:
		_idle = 0.0
		if Input.mouse_mode == Input.MOUSE_MODE_HIDDEN:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		get_tree().quit()


func _draw_overlay() -> void:
	if combat == null:
		return
	var vis := overlay.size
	var k := hud_scale(vis)
	var cx := vis.x / 2.0
	overlay.draw_set_transform(Vector2(cx, EDGE), 0.0, Vector2(k, k))
	var left_s := maxf(round_time - round_t, 0.0)
	var clock := "%d:%02d" % [int(left_s) / 60, int(left_s) % 60]
	HudDraw.text(overlay, 12, "ROUND %d" % round_no, Vector2(0, 0), Color.WHITE, 1)
	HudDraw.text(overlay, 10, clock, Vector2(0, 22), FtlColors.GREY, 1)
	if end_text != "":
		var col := FtlColors.YELLOW if end_reason == "time" else FtlColors.ORANGE
		HudDraw.text(overlay, 18, end_text, Vector2(0, 48), col, 1)
		HudDraw.text(overlay, 10, "Next round in %d" % ceili(maxf(end_timer, 0.0)), Vector2(0, 90), FtlColors.GREY, 1)
	overlay.draw_set_transform(Vector2.ZERO)


## --screenshot=PNG [--wait=S]: saves the window after S real seconds and quits.
func _screenshot() -> void:
	await get_tree().create_timer(_wait, true, false, true).timeout
	await RenderingServer.frame_post_draw
	FrameHost.window_image(get_tree()).save_png(_shot)
	print("screenshot: %s (canvas %s, zoom %.3f, round %d: %s vs %s)" % [_shot,
		get_viewport().get_visible_rect().size, zoom, round_no, left.ship.blueprint.name if left else "-",
		right.ship.blueprint.name if right else "-"])
	get_tree().quit()
