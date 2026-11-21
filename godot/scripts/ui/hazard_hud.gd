class_name HazardHud
extends Control
## Beacon hazard HUD = FTL SpaceStatus at position (690, 72) (rules/hud_layout.md "Space hazard status",
## rules/hazards.md §8), plus the full-screen sun / pulsar flash (orange (248,129,33) / blue (133,231,237), a³).
## - Icon `warnings/danger_*.png` (60×58) at (660, 72); the storm's second icon 72 px to the right.
## - Text (SpaceStatus::RenderWarningText): `warning_environment_danger` ("DANGER!") in font 52, COLOR_RED_WARNING,
##   centred at (690 + offset, 123) (offset 36 with two icons) on `backglow_warning_red.png` stretched to the
##   text size at (x − w/2, y − 1); PDS aimed at the enemy only: `warning_pds_allies` in (120,255,120) on the
##   green glow. Drawn whenever an effect is shown (every hazard).
## - Hover (SpaceStatus::MouseMove): hit boxes (655, 72, 70, 73) and, for the storm, (727, 72, 70, 73) load
##   `tooltip_<name>` through the TooltipService (delayed, at the cursor; kind `hazard`).
## - Flare / pulse / PDS lock message (`warning_solar_flare` / `warning_ion_pulse` / `warning_pds_locked`):
##   WarningMessage centred at (825, 30), red, flashing, shown while < 5 s are left; its Start plays `environWarning`.

const POS := Vector2(690, 72)
const ICON_DX := -30.0
const ICON2_DX := 72.0
const TEXT_DY := 51.0
const TEXT2_OFFSET := 36.0
const HITBOX := Rect2(-35, 0, 70, 73)  # relative to POS
const HITBOX2 := Rect2(37, 0, 70, 73)
const ICONS := {1: "danger_asteroids", 2: "danger_star", 3: "danger_nebula", 4: "danger_storm", 5: "danger_pulsar",
	6: "danger_pds", 9: "danger_pds_green"}
const ALLIES_GREEN := Color8(120, 255, 120)
const FLARE_RECT := Rect2(-360, -640, 2000, 2000)  # flareImage 500x500 at (-360, -640), GL_Scale(4, 4)

var run: RunState
var warning := WarningMessage.new("warning_solar_flare", Vector2(825, 30), 3.0, true, true, HudLayout.RED_WARNING)
var _t := 0.0
## Set by main during the jump-away (before JumpArrive): the HUD keeps showing the space being left, although
## RunState already holds the new beacon's hazard (vanilla clears the location only at JumpArrive).
var hold := false
var _hazard: HazardRule
## Touch UI (main.gd `_touch_hazard`): where the status (icons + DANGER! text) is drawn — a transform of its frame
## coordinates (POS ...); the hit boxes follow it. The full-screen flash and the flare message stay put. PC:
## identity.
var status_xf := Transform2D.IDENTITY


## The hazard shown: run.hazard, frozen while `hold` is set.
func _hz() -> HazardRule:
	if not hold:
		_hazard = run.hazard if run != null else null
	return _hazard


func setup(r: RunState) -> void:
	run = r
	set_anchors_preset(Control.PRESET_FULL_RECT)
	size = HudLayout.FRAME
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(d: float) -> void:
	_t += d
	visible = run != null and _hz() != null
	if not visible:
		return
	var w := _hz().warning()
	if w != "" and _hz().env in [HazardRule.Env.SUN, HazardRule.Env.PULSAR, HazardRule.Env.PDS]:
		warning.text_id = w
		if not warning.running():
			FtlData.play("environWarning")  # SpaceStatus warningMessage SetSound: played by WarningMessage::Start
		warning.start()
		# SetLoop(true): the 3 s tracker wraps and keeps running while < 5 s are left, so Start (and its sound)
		# happens once per cycle. Wrapped here rather than through update(), which ends the message at its length.
		warning.t = fmod(warning.t + d, warning.length)
	else:
		warning.stop()
	var id := hovered_tooltip(_mouse())
	if id != "" and not TooltipService.hud_blocked:
		TooltipService.request(TooltipText.simple("hazard", id), {"kind": &"hazard", "source": self,
			"ctx": {"id": id}})
	queue_redraw()


func _mouse() -> Vector2:
	return TooltipService.local_pointer(self)


## Text id of the tooltip under `m` (frame coordinates), "" if none.
func hovered_tooltip(m: Vector2) -> String:
	if run == null or _hz() == null:
		return ""
	m = status_xf.affine_inverse() * m  # hit boxes where the status is drawn
	var fx: Array = _hz().hud_effects()
	# SpaceManager::dangerZone: the location event's fleetPosition ≠ 0 (an overtaken beacon, or any event with a
	# <fleet> background) — the ASB is then the fleet's (tooltip_PDS_FLEET).
	var dz := int(run.space.get("danger", 0)) != 0
	if not dz and run.map != null and run.current_beacon >= 0 and run.current_beacon < run.map.beacons.size():
		dz = bool((run.map.beacons[run.current_beacon] as Dictionary).get("fleet", false))
	if int(fx[0]) != 0 and _inside(HITBOX, m):
		return _hz().hud_tooltip(int(fx[0]), dz)
	if int(fx[1]) == 4 and _inside(HITBOX2, m):
		return _hz().hud_tooltip(4)
	return ""


## MouseMove test: strictly inside (x < mX < x + w, y < mY < y + h).
static func _inside(hb: Rect2, m: Vector2) -> bool:
	var r := Rect2(POS + hb.position, hb.size)
	return m.x > r.position.x and m.x < r.end.x and m.y > r.position.y and m.y < r.end.y


func _draw() -> void:
	var h := _hz()
	if h == null:
		return
	var a := h.flash_alpha()
	if a > 0.0:
		# CommandGui::RenderStatic: flareImage (stars/planet_sun_flare.png, 500x500 primitive) at (-360, -640) scaled
		# x4, colour (248,129,33) (sun) / COLOR_BLUE_ION (133,231,237) (pulsar), alpha = GetFlashOpacity (a^3).
		var c := Color8(248, 129, 33) if h.env == HazardRule.Env.SUN else Color8(133, 231, 237)
		var flare := HudDraw.tex("stars/planet_sun_flare.png")
		if flare:
			draw_texture_rect(flare, FLARE_RECT, false, Color(c, a))
		else:
			draw_rect(Rect2(Vector2.ZERO, size), Color(c, a))
	var fx: Array = h.hud_effects()
	var e1 := int(fx[0])
	var e2 := int(fx[1])
	if e1 == 0:
		return
	draw_set_transform_matrix(status_xf)
	var icon_p := POS + Vector2(ICON_DX, 0)
	var t1 := HudDraw.tex("warnings/%s.png" % ICONS.get(e1, "danger_nebula"))
	if t1:
		draw_texture(t1, icon_p)
	if e2 != 0:
		var t2 := HudDraw.tex("warnings/%s.png" % ICONS.get(e2, "danger_storm"))
		if t2:
			draw_texture(t2, icon_p + Vector2(ICON2_DX, 0))
	_draw_text(e1, TEXT2_OFFSET if e2 != 0 else 0.0)
	draw_set_transform_matrix(Transform2D.IDENTITY)
	if warning.running():
		warning.draw(self)


## SpaceStatus::RenderWarningText.
func _draw_text(effect: int, offset: float) -> void:
	var allies := effect == 9
	var s := HudDraw.txt("warning_pds_allies" if allies else "warning_environment_danger")
	var p := POS + Vector2(offset, TEXT_DY)
	var w := FtlData.ftl_text_width(52, s)
	var hgt := (s.count("\n") + 1) * FtlData.ftl_line_height(52)
	var glow := HudDraw.tex("warnings/backglow_warning_green.png" if allies else "warnings/backglow_warning_red.png")
	if glow:
		draw_texture_rect(glow, Rect2(p.x - int(w / 2), p.y - 1, w, hgt), false)
	HudDraw.text(self, 52, s, p, ALLIES_GREEN if allies else HudLayout.RED_WARNING, 1)


## The storm's second icon is shown (two icons side by side).
func two_icons() -> bool:
	var h := _hz()
	return h != null and int(h.hud_effects()[1]) != 0


## Frame-coordinate bounds of the status (icons + text + hit boxes) before `status_xf`; `two` = the storm's
## second icon too.
static func status_bounds(two: bool) -> Rect2:
	var r := Rect2(POS + HITBOX.position, HITBOX.size)
	return r.merge(Rect2(POS + HITBOX2.position, HITBOX2.size)) if two else r
