class_name StarMapView
extends Control
## Beacon map overlay, drawn per rules/starmap.md "Map rendering" (StarMap::OnRender / RenderLabels /
## DrawConnection): zone background (tinted 0.75), nebula clouds, hover (yellow) and current-beacon (green) dotted
## connections, beacon icons by state, the ship marker orbiting the current beacon, the rebel fleet over the
## beacons, the out-of-fuel overlay, the frame with its title / sector tabs, buttons, the target box on the
## potential beacon, labels on top and the instant hover tooltip. Presentation only: gestures go to the
## InputProfile (PC: hover selects a connected beacon, click jumps; touch: tap selects (and shows its onward
## connections like a hover), the JUMP button confirms). Pure map rules (connections, icons, orbit) live in StarMap.
##
## Touch only [ours] (rules/starmap.md "Implementation notes"): no beacon tooltip at the finger (it would sit under
## it); the same text is shown in a fixed info panel (FtlTooltip box look) right of the map, stacked on the JUMP
## button (TouchCombatButtons look: FTL_base.png + JUMP text rect, ×JUMP_SCALE) whose bottom lines up with the
## CANCEL plate. The panel shows the selected (last tapped) beacon, or the beacon under a held finger until it lifts.

const WIN := Rect2(340, 83, 752, 534)  # map frame (zone_N.png 752×534) at CommandGui::LinkMap's (340, 83)
const PICK_PC := 10.0  # px (squared < 100)
const PICK_TOUCH := 31.6  # squared < 1000
const COL_ON := Color8(235, 245, 229)  # COLOR_BUTTON_ON
const COL_BTN_TEXT := Color8(25, 49, 51)  # COLOR_BUTTON_TEXT
const COL_LINK_CURRENT := Color8(120, 255, 120)
const COL_LINK_HOVER := Color8(255, 255, 50)  # COLOR_YELLOW
const COL_EXIT_TEXT := Color8(46, 252, 51)
const COL_HOT := Color8(255, 230, 94)
## Buttons in the map frame (StarMap ctor) [exe]: closeButton "button_cancel" 124×30 at (597, 541) with
## main_menus/button_cancel_base.png at (−24, −8) (the 103×32 "button_close" at (800, 552) is the sector map's
## closeSectorButton); next sector 226×36 with side_nextsector.png at (−19, −8); wait 95×36; distress at (666, 486).
const CLOSE_RECT := Rect2(WIN.position + Vector2(597, 541), Vector2(124, 30))
const NEXT_RECT := Rect2(WIN.position + Vector2(514, 12), Vector2(226, 36))
const WAIT_RECT := Rect2(WIN.position + Vector2(471, 486), Vector2(95, 36))
const DISTRESS_RECT := Rect2(WIN.position + Vector2(666, 486), Vector2(56, 32))
const JUMP_SCALE := 1.2  # touch JUMP = the combat touch buttons' size (CommandHud touch scale) [ours]
const TOUCH_GAP := 4.0  # px between the map frame, the JUMP base and the info panel [ours]
const INFO_WRAP_MIN := 120  # info panel wrap floor on narrow canvases [ours]
const HAZARD_ENVS := [1, 2, 4, 5, 6]

var run: RunState
var profile: InputProfile
var _hover := -1  # hoverLoc (PC: beacon under the mouse; touch: the last tapped beacon, persists)
var _press := ""  # what the left press started on: "b<id>", "close", "jump", "next", "wait", "distress"
var _finger := -1  # touch: beacon under the held finger (-1 when none / lifted)
var ship_angle := 360.0  # shipRotation[0] (degrees)
var show_paths := true  # settings.ini `showpaths` (default on); `--set=showpaths=false` turns it off
var _target_t := 0.0  # targetBoxTimer (1 s loop), restarted when potentialLoc changes
var _target_of := -1
var _distress_t := 0.0  # distressAnim (1 s loop)
var _last_selected := -1
var _cli_hover := ""  # --map-hover=BEACON|near|far (screenshots)
## Last Stand (LastStandMap): flagship marker orbit (shipRotation[1]), its jump slide, FLAGSHIP JUMPING warning.
var boss_angle := 360.0
var boss_slide := 0.0
var boss_warning := WarningMessage.new("warning_boss_jump", Vector2.ZERO, 5.0, true, true, HudLayout.RED_WARNING)


func setup(r: RunState, p: InputProfile) -> void:
	run = r
	profile = p
	position = Vector2.ZERO
	size = HudLayout.FRAME
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	mouse_filter = Control.MOUSE_FILTER_STOP
	var sp: Variant = Settings.raw("showpaths")
	show_paths = sp == null or bool(sp)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--map-hover="):
			_cli_hover = a.trim_prefix("--map-hover=")


func origin() -> Vector2:
	var o: Array = RunTuning.section("map").get("origin", [45, 40])
	return WIN.position + Vector2(float(o[0]), float(o[1]))


func screen_pos(id: int) -> Vector2:
	return origin() + run.map.beacon(id).pos


func scanners() -> bool:
	return run.ship.has_augment("ADV_SCANNERS")


func out_of_fuel() -> bool:
	return run.ship.fuel < 1


func _process(d: float) -> void:
	visible = run != null and run.map_open
	mouse_filter = Control.MOUSE_FILTER_STOP if visible else Control.MOUSE_FILTER_IGNORE
	if not visible:
		_hover = -1
		_finger = -1
		_last_selected = -1
		return
	if _cli_hover != "":
		_apply_cli_hover()
	ship_angle = StarMap.marker_step(ship_angle, d, out_of_fuel())
	if LastStand.waiting(run):
		LastStand.step_wait(run, d)  # StarMap::OnLoop -> UpdateDangerZone while `waiting` runs (closes the map)
		if not run.map_open:
			return
	if LastStand.active(run):
		boss_angle = StarMap.marker_step(boss_angle, d, false)
		boss_slide = LastStandMap.step_slide(boss_slide, run, d * GameClock.BASE)
		boss_warning.start()  # StarMap ctor: Start + SetLoop(true)
		boss_warning.update(d)
		if not boss_warning.running():
			boss_warning.start()
	_distress_t = fmod(_distress_t + d, 1.0)
	if run.selected != _target_of:
		_target_of = run.selected
		_target_t = 0.0
	else:
		_target_t = fmod(_target_t + d, 1.0)
	# Touch: a selection made elsewhere (CLI) becomes the hovered beacon too.
	if profile.is_touch() and run.selected >= 0 and run.selected != _last_selected:
		_hover = run.selected
	_last_selected = run.selected
	_tooltip()
	queue_redraw()


## StarMap::OnLoop / MouseMove tooltips: the hovered beacon (instant, not while out of fuel; at the beacon when the
## pointer is elsewhere: touch / CLI hover), WAIT / DISTRESS while out of fuel (delayed).
func _tooltip() -> void:
	var m := TooltipService.local_pointer(self)
	if profile.is_touch() and not out_of_fuel():
		return  # touch: the beacon text is in the fixed info panel (_draw_touch_info), not at the finger
	if _hover >= 0 and not out_of_fuel():
		var opts := {"instant": true, "kind": &"beacon", "source": self, "ctx": {"beacon": _hover}}
		var bp := screen_pos(_hover)
		if profile.is_touch() or m.distance_to(bp) > PICK_PC * 2:
			opts["anchor"] = get_global_transform() * (bp + Vector2(12, 12))
		var changing := _fleet_changing()
		TooltipService.request(TooltipText.rule("beacon", func(t: String) -> String: return t,
			[_location_text(_hover, changing)]), opts)
	elif out_of_fuel():
		var h := _hit(m)
		if h == "wait" or h == "distress":
			TooltipService.request(TooltipText.simple("button", "tooltip_map_" + h), {"kind": &"button",
				"source": self})


func _apply_cli_hover() -> void:
	var v := _cli_hover
	_cli_hover = ""
	var id := -1
	var links := run.map.links_of(run.current_beacon)
	if v == "near":
		id = int(links[0]) if not links.is_empty() else -1
	elif v == "far":  # the beacon farthest (in jumps) from the current one
		var best := 0
		for b in run.map.beacons:
			var n := run.map.path(run.current_beacon, b.id).size()
			if n > best:
				best = n
				id = b.id
	else:
		id = int(v)
	_hover = id
	profile.beacon_hover(id)
	print("map hover %s -> beacon %d (selected %d)" % [v, id, run.selected])


func beacon_at(p: Vector2) -> int:
	var best := -1
	var lim := PICK_TOUCH if profile.is_touch() else PICK_PC
	var bd := lim * lim
	for b in run.map.beacons:
		var d := screen_pos(b.id).distance_squared_to(p)
		if d < bd:
			bd = d
			best = b.id
	return best


## Touch JUMP base rect: right of the map frame, bottom on the CANCEL plate's bottom (button_cancel_base.png).
func _jump_rect() -> Rect2:
	var sz := TouchCombatButtons.BASE_SIZE * JUMP_SCALE
	var cb := FtlData.texture("img/main_menus/button_cancel_base.png")
	var bottom: float = CLOSE_RECT.position.y - 8 + (float(cb.get_height()) if cb else CLOSE_RECT.size.y + 16)
	return Rect2(Vector2(WIN.end.x + TOUCH_GAP, bottom - sz.y).round(), sz.round())


## Touch: the beacon the info panel describes (finger-held beacon, else the selected / last tapped one); -1 = none
## (PC, out of fuel: FTL shows no beacon text then).
func info_beacon() -> int:
	if not profile.is_touch() or out_of_fuel():
		return -1
	return _finger if _finger >= 0 else _hover


## The beacon tooltip text (the `beacon` tooltip rule + the `tooltip` filter, as TooltipService would show it).
func info_text(id: int) -> String:
	if id < 0:
		return ""
	var t := TooltipText.rule("beacon", func(x: String) -> String: return x, [_location_text(id, _fleet_changing())])
	var ft: Variant = Hooks.filter(&"tooltip", t, self, &"beacon", {"beacon": id})
	return "" if Hooks.is_cancel(ft) else String(ft)


## Info panel wrap width: what fits between the JUMP column's x and the visible canvas' right edge (≤ 275).
func _info_wrap() -> int:
	var right := HudLayout.cover_rect(self, true).end.x if is_inside_tree() else HudLayout.FRAME.x
	var avail := int(right - _jump_rect().position.x - TOUCH_GAP) - int(FtlTooltip.PAD.x)
	return clampi(avail, INFO_WRAP_MIN, TooltipService.WRAP)


## Info panel rect (touch): FtlTooltip box at least as wide as JUMP, left on JUMP's x, bottom TOUCH_GAP above it.
func info_rect() -> Rect2:
	var body := info_text(info_beacon())
	if body == "":
		return Rect2()
	var sz := FtlTooltip.box_size("", body, _info_wrap())
	var jr := _jump_rect()
	sz.x = maxf(sz.x, jr.size.x)
	return Rect2(Vector2(jr.position.x, jr.position.y - TOUCH_GAP - sz.y), sz)


## Touch JUMP state: "" (PC), "off" (no jumpable beacon selected / out of fuel), "on" (lit), "hot" (lit, held).
func jump_state() -> String:
	if not profile.is_touch():
		return ""
	if run.selected < 0 or out_of_fuel():
		return "off"
	return "hot" if _hover_hit() == "jump" else "on"


func _hit(p: Vector2) -> String:
	if LastStand.waiting(run):
		return ""  # StarMap::MouseMove / OnTouch return early while `waiting` runs
	if CLOSE_RECT.has_point(p):
		return "close"
	if profile.is_touch() and run.selected >= 0 and not out_of_fuel() and _jump_rect().has_point(p):
		return "jump"
	if out_of_fuel() and WAIT_RECT.has_point(p):
		return "wait"
	if _boss_wait_shown() and LastStandMap.wait_rect(WIN.position).has_point(p):
		return "wait"  # boss level: the final_sector_wait inset
	if out_of_fuel() and DISTRESS_RECT.has_point(p):
		return "distress"
	if _next_shown() and NEXT_RECT.has_point(p):
		return "next"
	var b := beacon_at(p)
	return "b%d" % b if b >= 0 else ""


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if not profile.is_touch():
			var b := beacon_at(event.position)
			if b != _hover:
				_hover = b
				profile.beacon_hover(b)
		else:  # a held finger previews the beacon under it (button-less motion = lifted / off-screen)
			_finger = beacon_at(event.position) if event.button_mask != 0 else -1
		accept_event()
		return
	var mb := event as InputEventMouseButton
	if mb == null:
		return
	accept_event()
	if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
		profile.close_map()
		return
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if profile.is_touch():
		_finger = beacon_at(mb.position) if mb.pressed else -1
	var h := _hit(mb.position)
	if mb.pressed:
		_press = h
		return
	if h != _press or h == "":
		_press = ""
		return
	_press = ""
	match h:
		"close":
			profile.close_map()
		"jump":
			profile.jump_button()
		"next":
			profile.next_sector()
		"wait":
			profile.wait_button()
		"distress":
			profile.distress_button()
		_:
			var id := int(h.substr(1))
			if profile.is_touch():
				_hover = id  # OnTouch: hoverLoc = the tapped beacon until the next tap
			profile.beacon_click(id)


## Image centred on `center`.
func _img(rel: String, center: Vector2, color := Color.WHITE) -> void:
	var t := FtlData.texture("img/" + rel)
	if t:
		draw_texture(t, (center - t.get_size() / 2.0).round(), color)


## DrawConnection: dotted_line.png (12×4) as quads every 10 px, 4 px thick, u 1/12..11/12, vertex alpha 1.0 at
## `a` fading linearly to 0.3 at `b`.
func _connection(a: Vector2, b: Vector2, color: Color) -> void:
	var len := a.distance_to(b)
	if len < 1.0:
		return
	var t := FtlData.texture("img/map/dotted_line.png")
	var dir := (b - a) / len
	var nrm := Vector2(-dir.y, dir.x) * 2.0
	var x := 0.0
	while x < len:
		var w := minf(10.0, len - x)
		var p0 := a + dir * x
		var p1 := a + dir * (x + w)
		var c0 := Color(color, lerpf(1.0, 0.3, x / len))
		var c1 := Color(color, lerpf(1.0, 0.3, (x + w) / len))
		var u0 := 1.0 / 12.0
		var u1 := (1.0 + w) / 12.0
		if t:
			draw_polygon(PackedVector2Array([p0 - nrm, p1 - nrm, p1 + nrm, p0 + nrm]),
				PackedColorArray([c0, c1, c1, c0]),
				PackedVector2Array([Vector2(u0, 0), Vector2(u1, 0), Vector2(u1, 1), Vector2(u0, 1)]), t)
		else:
			draw_line(p0, p0 + dir * minf(5.0, w), c0, 4.0)
		x += 10.0


## Target box: map_targetbox.png (one corner bracket) 4× mirrored about the beacon at (o − 20) with
## o = round((1 − cos 2πt) · 2.5): the corners pulse inward 0..5 px over the 1 s timer.
func _target_box(c: Vector2) -> void:
	var t := FtlData.texture("img/map/map_targetbox.png")
	var o := roundf((1.0 - cos(TAU * _target_t)) * 0.5 * 5.0)
	if t == null:
		draw_arc(c, 20 - o, 0, TAU, 24, Color.GREEN, 2.0)
		return
	for s in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
		draw_set_transform(c, 0.0, s)
		draw_texture(t, Vector2(o - 20, o - 20))
	draw_set_transform(Vector2.ZERO)


## Location.flashTracker: 2 s loop from a per-beacon phase (FTL: rand % 2001 / 1000 s; here a hash of the map seed
## and beacon id so no game RNG is drawn); GetAlphaLevel = triangle wave 0 → 1 → 0.
func _flash(id: int) -> float:
	var phase := float(absi(hash(run.map.seed * 31 + id)) % 2001) / 1000.0
	var t := fmod(Time.get_ticks_msec() / 1000.0 + phase, 2.0)
	return t if t < 1.0 else 2.0 - t


## Label box (RenderLabels): map_box_<c>_1 (19×32) + _2 stretched to (textW − 8) + _3 (15×32), top-left at
## (x − 1, y − 33) of the beacon, text font 51 at (x + 14, y − 25); alpha 0.5 + 0.5 · flash.
func _label(text: String, colour: String, text_col: Color, at: Vector2, alpha: float) -> void:
	var w := FtlData.ftl_text_width(51, text)
	var l := FtlData.texture("img/map/map_box_%s_1.png" % colour)
	var m := FtlData.texture("img/map/map_box_%s_2.png" % colour)
	var r := FtlData.texture("img/map/map_box_%s_3.png" % colour)
	var p := (at + Vector2(-1, -33)).round()
	var tint := Color(1, 1, 1, alpha)
	if l and m and r:
		var mw := maxf(w - 8, 0)
		draw_texture(l, p, tint)
		draw_texture_rect(m, Rect2(p + Vector2(l.get_width(), 0), Vector2(mw, m.get_height())), false, tint)
		draw_texture(r, p + Vector2(l.get_width() + mw, 0), tint)
	FtlData.draw_ftl_text(self, 51, text, (at + Vector2(14, -25)).round(), Color(text_col, alpha))


## GetLocationText (rules/starmap.md §3, priority order) + nebula / hazard suffixes.
func _location_text(id: int, changing: Dictionary) -> String:
	var b: Dictionary = run.map.beacon(id)
	var ev: Dictionary = b.event
	var intel := run.map.intel_visible(id, scanners())
	var s := ""
	if id == run.current_beacon:
		s = "map_current_loc"
	elif id == LastStandMap.boss_beacon(run):
		s = "map_boss_loc"
	elif b.exit:
		s = "map_base_loc" if LastStand.active(run) else "map_exit_loc"
	elif changing.has(id):
		s = "map_rebels_loc"
	elif b.fleet:
		s = "map_fleet_loc"
	elif b.shop != null and id != LastStandMap.boss_beacon(run):
		s = "map_store_loc"
	elif ev.get("repair", false):
		s = "map_repair_loc"
	elif b.visited > 0 and b.get("ship_left", false):
		s = "map_hostile_loc"
	elif b.visited > 0:
		s = "map_nothing_loc"
	elif b.known and ev.get("distress", false):
		s = "map_distress_loc"
	elif not ev.get("ship", {}).is_empty() and intel:
		s = "map_ship_loc"
	elif b.get("quest", false):
		s = "map_quest_loc"
	elif b.known and ev.get("store", false):
		s = "map_merchant_loc"
	else:
		s = "map_unvisited_loc"
	s = FtlData.tr_id(s)
	if b.nebula:
		# bNebulaMap (a nebula sector: the fleet is prepared, 51 instead of 32 per jump), not the beacon's fleet flag.
		s += "\n" + FtlData.tr_id("map_nebula_fleet_loc" if _nebula_sector() else "map_nebula_loc")
	var e := int(ev.get("environment", -1))
	if e in HAZARD_ENVS and intel:
		var key: String = {1: "map_asteroid_loc", 2: "map_sun_loc", 4: "map_ion_loc", 5: "map_pulsar_loc",
			6: "map_pds_loc"}[e]
		if e == 6 and b.fleet:
			key = "map_pds_fleet"
		s += "\n" + FtlData.tr_id(key)
	return s


## Boss level: WAIT with fuel as long as no ship is at the beacon (StarMap::OnLoop waitButton active).
func _boss_wait_shown() -> bool:
	return LastStand.active(run) and not out_of_fuel() and run.can_wait()


func _next_shown() -> bool:
	return run.at_exit() and not out_of_fuel() and not run.is_last_sector()


## The fleet centre after the next jump (GetNextDangerMove from the current beacon, capped at x 60).
## Not capped at x 60 (OnRender / RenderLabels add the move to the centre as is; only UpdateDangerZone caps it, so
## the preview can reach up to one move further than the fleet will).
func _next_fleet_center() -> Vector2:
	var f := run.fleet
	var m := f.next_move(bool(run.beacon().get("nebula", false)), _nebula_sector())
	return Vector2(f.center.x + m, f.center.y)


## StarMap::bNebulaMap: the current sector is a nebula sector.
func _nebula_sector() -> bool:
	if run.tree != null and run.sector_id >= 0:
		return run.tree.sectors[run.sector_id].cls == "NEBULA"
	return run.sector_desc.contains("NEBULA")


## fleetChanging (warning disc, map_rebels_loc, labels suppressed): RenderLabels flags every beacon not yet overtaken
## inside the zone after the next move (squared distance < 767²) — only while the labels are drawn: not out of
## fuel, not in the last stand (there UpdateBoss sets the flags: beacon `fleet_changing`, kept until overtaken).
func _fleet_changing() -> Dictionary:
	var out := {}
	if run.fleet == null:
		return out
	for b in run.map.beacons:
		if b.get("fleet_changing", false) and not b.fleet:
			out[b.id] = true
	if out_of_fuel() or run.is_last_sector():
		return out
	var nc := _next_fleet_center()
	var r := run.fleet.radius()
	for b in run.map.beacons:
		if not b.fleet and (b.pos as Vector2).distance_squared_to(nc) < r * r:
			out[b.id] = true
	return out


## Image blitted into `dest`, clipped to the map window (the stencil).
func _blit_clipped(t: Texture2D, dest: Rect2, color := Color.WHITE) -> void:
	var c := dest.intersection(WIN)
	if t == null or c.size.x <= 0 or c.size.y <= 0:
		return
	var k := t.get_size() / dest.size
	draw_texture_rect_region(t, c, Rect2((c.position - dest.position) * k, c.size * k), color)


## Rebel fleet (drawn over the beacons): red wash up to the predicted edge − 181 with
## map_warningcircle_point.png there (when a move exists), map_warningcircle.png at the current edge, and
## map_warningcircle_tile.png tiled leftwards from centre + 586, from centre.y − 498 down, all clipped to the map.
func _draw_fleet(o: Vector2) -> void:
	if run.fleet == null:
		return
	var r := run.fleet.radius()
	var c := o + run.fleet.center
	var nc := o + _next_fleet_center()
	var edge_img := FtlData.texture("img/map/map_warningcircle.png")
	var point_img := FtlData.texture("img/map/map_warningcircle_point.png")
	var tile := FtlData.texture("img/map/map_warningcircle_tile.png")
	if nc.x > c.x:
		# Width clamped at 0: a fleet still left of the window gives a negative size (engine error in intersection).
		var wash := Rect2(WIN.position.x, WIN.position.y, maxf(0.0, nc.x + r - 181 - WIN.position.x), WIN.size.y)
		wash = wash.intersection(WIN)
		if wash.size.x > 0:
			draw_rect(wash, Color8(246, 128, 125, 21))
		_blit_clipped(point_img, Rect2(nc + Vector2(r - 181, -498), Vector2(200, 996)))
	_blit_clipped(edge_img, Rect2(c + Vector2(r - 181, -498), Vector2(200, 996)))
	if tile:
		var tw := tile.get_width()
		var th := tile.get_height()
		var x := c.x + r - 181 - tw
		while x + tw > WIN.position.x:
			var y := c.y - 498
			while y < WIN.end.y:
				_blit_clipped(tile, Rect2(x, y, tw, th))
				y += th
			x -= tw


func _draw() -> void:
	if run == null or not run.map_open:
		return
	var F := WIN.position
	var o := origin()
	var scn := scanners()
	var nofuel := out_of_fuel()
	var changing := _fleet_changing()
	# 1. Zone background, tinted 0.75 (inside the mapBorder mask; the outline is drawn over it in step 7).
	WindowFrame.draw(self, WIN)
	var zone := FtlData.texture("img/map/zone_%d.png" % (run.sector % 3 + 1))
	if zone:
		draw_texture(zone, F, Color(0.75, 0.75, 0.75))
	else:
		draw_rect(WIN, Color8(20, 24, 40))
	# 2. Nebula clouds (alpha not traced).
	for cl in run.map.clouds:
		var t := FtlData.texture("img/" + String(cl.img))
		if t:
			draw_texture(t, (o + (cl.rect as Rect2).position).round(), Color(1, 1, 1, 0.9))
	# 3. Connections: hovered beacon's (yellow), then the current beacon's (green).
	var hov := _finger if profile.is_touch() and _finger >= 0 else _hover
	for e in run.map.visible_connections(run.current_beacon, hov, show_paths):
		_connection(screen_pos(e[0]), screen_pos(e[1]),
			COL_LINK_CURRENT if e[2] == StarMap.LINK_CURRENT else COL_LINK_HOVER)
	LastStandMap.draw_path(self, run, o)  # the flagship's next hop
	var boss_b := LastStandMap.boss_beacon(run)
	# 4. Beacons.
	var hz := FtlData.texture("img/map/map_icon_hazard.png")
	var circle := FtlData.texture("img/tutorial/player_circle.png")
	for b in run.map.beacons:
		var sp: Vector2 = o + b.pos
		if changing.has(b.id) and circle:
			draw_set_transform(sp, 0.0, Vector2(0.75, 0.75))
			draw_texture_rect(circle, Rect2(Vector2(-15, -14) / 0.75, Vector2(40, 40)), false,
				Color(1, 1, 1, _flash(b.id)))
			draw_set_transform(Vector2.ZERO)
		if b.nebula:
			draw_circle(sp, 10.0, Color8(50, 50, 255, 128))
		var env := int(b.event.get("environment", -1))
		if hz and env in HAZARD_ENVS and run.map.intel_visible(b.id, scn) and b.id != boss_b:
			draw_texture(hz, sp + Vector2(-21, -21), Color(1, 1, 1, 0.5))
		var ic: Array = run.map.beacon_icon(b.id, scn)
		var sh := FtlData.texture("img/map/" + String(ic[0]))
		var it := FtlData.texture("img/map/" + String(ic[1]))
		if sh:
			draw_texture(sh, sp + Vector2(-16, -16))
		if it:
			for k in (3 if b.id == run.selected else 1):
				draw_texture(it, sp + Vector2(-16, -16))
		if b.id == run.current_beacon:
			_draw_ship_marker(sp, nofuel)
	LastStandMap.draw_marker(self, run, o, boss_angle, boss_slide)  # after the player's marker
	# 5. Rebel fleet over the beacons.
	_draw_fleet(o)
	# 6. Out of fuel / waiting (boss-level WAIT animation): dark overlay over the map.
	var waiting := LastStand.waiting(run)
	if nofuel or waiting:
		draw_rect(WIN, Color(0, 0, 0, 0.4))
	# 7. Frame outline (over the zone image), tabs, texts, buttons.
	WindowFrame.draw_outline(self, WIN)
	_draw_tabs()
	LastStandMap.draw_turns_box(self, run, F)
	LastStandMap.draw_warning(self, run, F, boss_warning)
	_draw_buttons(nofuel)
	# 8. Target box on potentialLoc; out-of-fuel message.
	if run.selected >= 0:
		_target_box(screen_pos(run.selected))
	if waiting:
		# waitingMessage (InitNoFuelText): x = 385 - (w - 12) / 2, i.e. centred 16 px right of fuelMessage.
		_img("map/map_fuel_text_waiting.png", F + Vector2(WIN.size.x / 2 + 16, 62))
	elif nofuel:
		_img("map/map_fuel_text_nofuel.png", F + Vector2(WIN.size.x / 2, 62))
	LastStandMap.draw_message(self, run, F)  # pc_boss box
	# 9. Labels (skipped while out of fuel).
	if not nofuel:
		for b in run.map.beacons:
			_draw_label(b, o + b.pos, changing)


## Ship marker: map_icon_ship.png (64×64) at (−10, −32) in the beacon frame rotated by ship_angle → orbit r 22,
## nose-first, counter-clockwise; out of fuel with the distress beacon on, map_icon_ship_fuel.png during the first
## half of each 1 s distressAnim loop.
func _draw_ship_marker(sp: Vector2, nofuel: bool) -> void:
	var fuel_sprite := nofuel and run.distress and _distress_t < 0.5
	var t := FtlData.texture("img/map/map_icon_ship_fuel.png" if fuel_sprite else "img/map/map_icon_ship.png")
	if t == null:
		draw_circle(sp + StarMap.marker_offset(ship_angle), 6.0, Color.CYAN)
		return
	draw_set_transform(sp, deg_to_rad(ship_angle))
	draw_texture(t, Vector2(-10, -32))
	draw_set_transform(Vector2.ZERO)


func _draw_label(b: Dictionary, sp: Vector2, changing: Dictionary) -> void:
	var l := label_for(b, changing)
	if not l.is_empty():
		_label(FtlData.tr_id(String(l[0])), String(l[1]), COL_EXIT_TEXT if l[1] == "green" else COL_ON, sp,
			0.5 + 0.5 * _flash(b.id))


## RenderLabels' choice for a beacon: [text id, box colour] or [] (rules/starmap.md "Labels"). Exit always (green);
## other labels none on beacons inside the fleet's next zone (fleetChanging) or overtaken (also inside it); then
## quest (purple, needs no `known`), repair, store (generated, or known / revealed), distress (known / revealed).
func label_for(b: Dictionary, changing: Dictionary) -> Array:
	var known: bool = b.known or run.map.revealed
	var ev: Dictionary = b.event
	if b.exit:
		if LastStand.active(run):
			return [] if b.fleet else ["map_icon_base", "purple"]  # the Federation base
		return ["map_icon_exit", "green"]
	if changing.has(b.id) or b.fleet or b.id == LastStandMap.boss_beacon(run):
		return []
	if b.get("quest", false):
		return ["map_icon_quest", "purple"]
	if ev.get("repair", false):
		return ["map_icon_repair", "white"]
	if b.shop != null or (known and ev.get("store", false)):
		return ["map_icon_store", "white"]
	if known and ev.get("distress", false):
		return ["map_icon_distress", "white"]
	return []


## The sector tab's number: worldLevel + 1, or "?" in the secret sector (OnRender: bSecretSector).
func sector_number_text() -> String:
	return "?" if run.secret_sector else str(run.sector + 1)


## Title tab (side_beaconmap.png 72×45 in 3 parts at (−7, −7), middle stretched to the title width) with
## map_title (font 63, COLOR_BUTTON_TEXT) at (14, 1); sector tab (side_sector.png 497×55 at (−7, 514): first 100 px,
## column 100 stretched, rest) with map_sector (font 63) at (6, 531), the sector number and name in font 14
## (COLOR_BUTTON_ON) centred at y 529.
func _draw_tabs() -> void:
	var F := WIN.position
	var title := FtlData.tr_id("map_title")
	var tw := FtlData.ftl_text_width(63, title)
	var tt := FtlData.texture("img/map/side_beaconmap.png")
	if tt:
		var h := tt.get_height()
		draw_texture_rect_region(tt, Rect2(F + Vector2(-7, -7), Vector2(27, h)), Rect2(0, 0, 27, h))
		draw_texture_rect_region(tt, Rect2(F + Vector2(20, -7), Vector2(maxf(tw - 12, 0), h)), Rect2(27, 0, 1, h))
		draw_texture_rect_region(tt, Rect2(F + Vector2(tw + 8, -7), Vector2(44, h)), Rect2(28, 0, 44, h))
	FtlData.draw_ftl_text(self, 63, title, F + Vector2(14, 1), COL_BTN_TEXT)
	var lab := FtlData.tr_id("map_sector")
	var lw := FtlData.ftl_text_width(63, lab)
	var sname := run.sector_name
	var nw := FtlData.ftl_text_width(14, sname) + 8
	var x0 := lw + 67
	var avail := 459 - x0
	var extra := maxi(nw - avail, 0)
	avail = maxi(avail, nw)
	var st := FtlData.texture("img/map/side_sector.png")
	if st:
		var h := st.get_height()
		draw_texture_rect_region(st, Rect2(F + Vector2(-7, 514), Vector2(100, h)), Rect2(0, 0, 100, h))
		if extra > 0:
			draw_texture_rect_region(st, Rect2(F + Vector2(93, 514), Vector2(extra, h)), Rect2(100, 0, 1, h))
		draw_texture_rect_region(st, Rect2(F + Vector2(93 + extra, 514), Vector2(st.get_width() - 100, h)),
			Rect2(100, 0, st.get_width() - 100, h))
	# Legend boxes (multi-rect primitive, colour (0.208, 0.294, 0.349)): 38 px for the number, the name area for
	# the name; y 536..555 with 3 one-pixel rows stepping in above / below (rounded corners).
	var box_col := Color(0.208, 0.294, 0.349)
	for bx in [[lw + 18, 38], [x0, avail]]:
		var x := F.x + float(bx[0])
		var w := float(bx[1])
		for i in range(1, 4):
			draw_rect(Rect2(x + i, F.y + 536 - i, w - 2 * i, 1), box_col)
			draw_rect(Rect2(x + i, F.y + 555 + i, w - 2 * i, 1), box_col)
		draw_rect(Rect2(x, F.y + 536, w, 20), box_col)
	FtlData.draw_ftl_text(self, 63, lab, F + Vector2(6, 531), COL_BTN_TEXT)
	# Sector number; "?" in the secret sector (OnRender: bSecretSector).
	FtlData.draw_ftl_text(self, 14, sector_number_text(), F + Vector2(lw + 37, 529), COL_ON, 1)
	FtlData.draw_ftl_text(self, 14, sname, F + Vector2(avail / 2.0 + x0, 529), COL_ON, 1)


func _draw_buttons(nofuel: bool) -> void:
	var h := _hover_hit()
	var cb := FtlData.texture("img/main_menus/button_cancel_base.png")
	if cb:
		draw_texture(cb, CLOSE_RECT.position + Vector2(-24, -8))
	ShipScreen.text_button(self, CLOSE_RECT, FtlData.tr_id("button_cancel"), "off" if LastStand.waiting(run)
		else ("hot" if h == "close" else "on"))  # closeButton inactive while waiting
	if _next_shown():
		var t := FtlData.texture("img/map/side_nextsector.png")
		if t:
			draw_texture(t, NEXT_RECT.position + Vector2(-19, -8))
		_button(NEXT_RECT, FtlData.tr_id("button_nextsector"), h == "next")
	if nofuel:
		var can := run.can_wait()
		var wt := FtlData.texture("img/map/map_fuel_WAIT_%s.png" % ("off" if not can else ("select2" if h == "wait"
			else "on")))
		if wt:
			draw_texture(wt, WAIT_RECT.position + (WAIT_RECT.size - wt.get_size()) / 2.0)
		var dt := FtlData.texture("img/map/map_fuel_%s_%s.png" % ["ON" if run.distress else "OFF",
			"select2" if h == "distress" else "on"])
		if dt:
			draw_texture(dt, DISTRESS_RECT.position)
		if run.distress:
			_img("map/map_fuel_redlight.png", DISTRESS_RECT.position + Vector2(78, 16))
	elif _boss_wait_shown():
		LastStandMap.draw_wait_inset(self, WIN.position, "hot" if h == "wait" else "on")
	if profile.is_touch():
		_draw_touch_info()


## Touch: JUMP (TouchCombatButtons look: lit when a jumpable beacon is selected, dim otherwise) and the beacon
## info panel above it (FtlTooltip box).
func _draw_touch_info() -> void:
	var st := jump_state()
	TouchCombatButtons.draw_jump_look(self, _jump_rect().position, JUMP_SCALE,
		TouchCombatButtons.label("button_jump", "JUMP"), "off" if st == "off" else "lit", st == "hot")
	draw_set_transform(Vector2.ZERO)
	var r := info_rect()
	if r.size.x > 0:
		FtlTooltip.draw_box(self, r.position, "", info_text(info_beacon()), _info_wrap())


func _hover_hit() -> String:
	return _hit(TooltipService.local_mouse(self))


func _button(r: Rect2, text: String, hot: bool) -> void:
	ShipScreen.text_button(self, r, text, "hot" if hot else "on")  # TextButton plate + COLOR_BUTTON_TEXT label