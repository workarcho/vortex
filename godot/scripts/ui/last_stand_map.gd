class_name LastStandMap
extends RefCounted
## The beacon map's Last Stand extras (StarMap::OnRender / RenderLabels / GetLocationText in the boss level,
## rules/flagship.md "Map"), drawn by StarMapView through these static helpers. Map-window coordinates are relative
## to the window's top-left `F` (StarMap position).

const PATH_COLOR := Color8(230, 100, 100)  # DrawConnection while preparing; solid 9 px GL_DrawLine while jumping
const PATH_WIDTH := 9.0
const BOSS_IMG := "img/map/map_icon_boss.png"
const SLIDE := 0.375  # px per speed-factor unit (6 x 0.0625), applied twice per frame (drawn for both beacons)
const SLIDE_RESET := 20.0  # px out: back to the start of the hop
const FADE_FROM := 10.0
const JUMPS_BOX := "img/map/boss_jumps_box.png"
const WARNING_POS := Vector2(375, -72)  # bossJumpingWarning (centred, flashing, red, looping 5 s)
const MESSAGE_AT := Vector2(-340, 150)  # pc_boss box: WindowFrame(7, 0, 323, text h + 30) left of the map
const INSET_RIGHT := 740.0  # final_sector_wait inset: side_text_right at (740, 467), middle at (740 - w, 470)


## The flagship's beacon this frame (-1 when not the boss level).
static func boss_beacon(run: RunState) -> int:
	return LastStand.boss_beacon(run) if LastStand.active(run) else -1


## Flagship path (drawn after the current-beacon connections): the next hop only.
static func draw_path(v: Control, run: RunState, o: Vector2) -> void:
	var a := boss_beacon(run)
	var b := LastStand.next_hop(run)
	if a < 0 or b < 0:
		return
	var pa: Vector2 = o + run.map.beacons[a].pos
	var pb: Vector2 = o + run.map.beacons[b].pos
	if bool(run.boss.get("jumping", false)):
		v.draw_line(pa, pb, PATH_COLOR, PATH_WIDTH)
	else:
		v.call("_connection", pa, pb, PATH_COLOR)


## Advances the slide offset (px from the beacon toward the next hop) of a jumping flagship; `f` = speed factor.
static func step_slide(slide: float, run: RunState, f: float) -> float:
	var a := boss_beacon(run)
	var b := LastStand.next_hop(run)
	if a < 0 or b < 0 or not bool(run.boss.get("jumping", false)) or LastStand.waiting(run):
		return 0.0  # the WAIT animation positions the marker itself (wait_position)
	var hop := (run.map.beacons[b].pos as Vector2).distance_to(run.map.beacons[a].pos)
	slide += 2.0 * SLIDE * f
	if slide > SLIDE_RESET or slide > hop:
		slide = 0.0
	return slide


## The flagship's position while the WAIT animation runs and it is jumping (UpdateDangerZone: bossPosition =
## beacon + progress x 0.6 x hop, drawn at full alpha, no idle slide); null otherwise.
static func wait_position(run: RunState) -> Variant:
	var a := boss_beacon(run)
	var b := LastStand.next_hop(run)
	if a < 0 or b < 0 or not LastStand.waiting(run) or not bool(run.boss.get("jumping", false)):
		return null
	var pa: Vector2 = run.map.beacons[a].pos
	var pb: Vector2 = run.map.beacons[b].pos
	return pa + (pb - pa) * (LastStand.wait_progress(run) * LastStand.WAIT_SLIDE)


## Flagship marker: map_icon_boss.png at (-10, -32) in a frame rotated by `angle` (orbit like the player's marker)
## while idle; while jumping it slides toward the next hop, facing it, fading once > 10 px out; during the WAIT
## animation it moves 60 % of the hop over the 2 s instead (`wait_position`).
static func draw_marker(v: Control, run: RunState, o: Vector2, angle: float, slide: float) -> void:
	var a := boss_beacon(run)
	if a < 0:
		return
	var t := FtlData.texture(BOSS_IMG)
	var sp: Vector2 = o + run.map.beacons[a].pos
	var b := LastStand.next_hop(run)
	if not bool(run.boss.get("jumping", false)) or b < 0:
		if t:
			v.draw_set_transform(sp, deg_to_rad(angle))
			v.draw_texture(t, Vector2(-10, -32))
			v.draw_set_transform(Vector2.ZERO)
		return
	var dir := ((run.map.beacons[b].pos as Vector2) - (run.map.beacons[a].pos as Vector2)).normalized()
	var pos := sp + dir * slide
	var alpha := 1.0 if slide <= FADE_FROM else pow(1.0 - (slide - FADE_FROM) / FADE_FROM, 2.0)
	var wp: Variant = wait_position(run)
	if wp != null:
		pos = o + (wp as Vector2)
		alpha = 1.0
	var h := rad_to_deg(acos(clampf(dir.x, -1.0, 1.0)))
	if dir.y < 0.0:
		h = -h
	if t:
		# Translate(pos - (20, 0) + dir * 20), Translate(21, 0), Rotate(h + 90), Translate(-21, 0).
		var xf := Transform2D(0.0, pos + Vector2(-20, 0) + dir * 20.0) * Transform2D(0.0, Vector2(21, 0)) \
			* Transform2D(deg_to_rad(h + 90.0), Vector2.ZERO) * Transform2D(0.0, Vector2(-21, 0))
		v.draw_set_transform_matrix(xf)
		v.draw_texture(t, Vector2(-10, -32), Color(1, 1, 1, alpha))
		v.draw_set_transform_matrix(Transform2D.IDENTITY)


## "Turns until the base is destroyed" box (once the flagship reached the base): boss_jumps_box.png in 3 parts at
## y −82 (h 78) above the window, label font 52 centred, the number 4 − arrivedAtBase in font 24.
static func draw_turns_box(v: Control, run: RunState, F: Vector2) -> void:
	if not LastStand.active(run) or int(run.boss.get("arrived", 0)) < 1:
		return
	var label := FtlData.tr_id("boss_jumps")
	var w := 200
	while w < 600 and FtlData.ftl_wrap(52, label, w + 12).size() * FtlData.ftl_line_height(52) > 50:
		w += 10
	var t := FtlData.texture(JUMPS_BOX)
	if t:
		var tw := float(t.get_width())
		var th := float(t.get_height())
		v.draw_texture_rect_region(t, Rect2(F + Vector2(629 - w, -82), Vector2(26, 78)), Rect2(0, 0, 26, th))
		v.draw_texture_rect_region(t, Rect2(F + Vector2(655 - w, -82), Vector2(w, 78)), Rect2(26, 0, 1, th))
		v.draw_texture_rect_region(t, Rect2(F + Vector2(655, -82), Vector2(tw - 27, 78)), Rect2(27, 0, tw - 27, th))
	FtlData.draw_ftl_text(v, 52, label, F + Vector2(655 - w / 2.0, -65), Color.WHITE, 1, w + 12)
	var n := LastStand.turns_left(run)
	FtlData.draw_ftl_text(v, 24, str(n), F + Vector2(700 if n == 1 else 696, -68), Color.WHITE)


## FLAGSHIP JUMPING warning: drawn while the flagship is preparing its jump (bossJumping).
static func draw_warning(v: Control, run: RunState, F: Vector2, warning: WarningMessage) -> void:
	if LastStand.active(run) and bool(run.boss.get("jumping", false)):
		warning.draw(v, F + WARNING_POS)


## pc_boss explanation box, left of the map window, every frame of the boss level.
static func draw_message(v: Control, run: RunState, F: Vector2) -> void:
	if not LastStand.active(run):
		return
	var text := FtlData.tr_id("pc_boss").replace("\\n", "\n")
	var lines := FtlData.ftl_wrap(10, text, 300)
	var h := roundf(lines.size() * FtlData.ftl_line_height(10)) + 30
	var at := F + MESSAGE_AT
	WindowFrame.draw(v, Rect2(at + Vector2(7, 0), Vector2(323, h)))
	FtlData.draw_ftl_text(v, 10, text, at + Vector2(20, 15), Color.WHITE, 0, 300)


## Width of the final_sector_wait text (font 7, measured at width 1000).
static func inset_text_width() -> int:
	return FtlData.ftl_text_width(7, FtlData.tr_id("final_sector_wait"))


## WAIT button of the boss-level inset: RenderLeftInsetButton(740 − textW, 470): x = right − (button w + 33),
## button at (x + 19, 470 + 16), TextButton button_wait 95×36 (font 63).
static func wait_rect(F: Vector2) -> Rect2:
	var right := INSET_RIGHT - inset_text_width()
	return Rect2(F + Vector2(right - (95 + 33) + 19, 470 + 16), Vector2(95, 36))


## The boss-level wait inset (StarMap::OnRender, waitButton active and not out of fuel).
static func draw_wait_inset(v: Control, F: Vector2, state: String) -> void:
	var tw := float(inset_text_width())
	var right := INSET_RIGHT - tw
	var rt := FtlData.texture("img/map/side_text_right.png")
	if rt:
		v.draw_texture(rt, F + Vector2(INSET_RIGHT, 467))
	var mt := FtlData.texture("img/map/side_text_middle.png")
	if mt:
		v.draw_texture_rect(mt, Rect2(F + Vector2(right, 470), Vector2(tw, 60)), false)
	var lt := FtlData.texture("img/map/side_text_jump.png")
	var x := right - (95 + 33)
	if lt:
		var lw := float(lt.get_width())
		var lh := float(lt.get_height())
		v.draw_texture_rect_region(lt, Rect2(F + Vector2(x, 470), Vector2(27, lh)), Rect2(0, 0, 27, lh))
		v.draw_texture_rect_region(lt, Rect2(F + Vector2(x + 27, 470), Vector2(maxf(right - x - 49, 0), lh)),
			Rect2(27, 0, 1, lh))
		v.draw_texture_rect_region(lt, Rect2(F + Vector2(right - 22, 470), Vector2(22, lh)), Rect2(28, 0, minf(22, lw - 28), lh))
	ShipScreen.text_button(v, wait_rect(F), FtlData.tr_id("button_wait"), state)
	var text := FtlData.tr_id("final_sector_wait")
	FtlData.draw_ftl_text(v, 7, text, F + Vector2(right, 503 - floorf(FtlData.ftl_line_height(7) * 0.5)), Color.WHITE)
