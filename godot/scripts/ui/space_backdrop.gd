class_name SpaceBackdrop
extends Control
## The beacon's space behind the ships (rules/backgrounds.md §4–§6): SpaceManager::OnRenderBackground (the
## background image, or the nebula clouds) and SpaceManager::OnRenderForeground (planet, or the sun / pulsar, then
## the rebel fleet of a danger zone). CommandGui::RenderStatic draws them first, before the asteroid scrollers and
## the player ship; while the player jumps the foreground is scaled 1 − 0.05·k about the player ship's centre.
## Every image is tinted (r, g, g): unpaused r = 1, g = 1 − 0.5·(1 − hull)²; paused by the player
## (CommandGui::bPaused, not a menu / event box) r = 0.4 + 0.4·(1 − hull), g = 0.4. The fleet's ASB gun ship is
## drawn untinted.
##
## `space` = RunState.space (or `sandbox_space()`); the hazard gives the environment (sun, pulsar, nebula / storm,
## ASB). Touch UI: `mirror` (MirroredBackground) draws the background image, mirrored into the extra width of wide
## screens; this node then draws the rest (clouds, planet, ...) at their 1280×720 frame positions.

const SUN_IMG := "stars/planet_sun1.png"
const SUN_GLOW := "stars/planet_sun2.png"
const SUN_POS := Vector2(100, 109)
const SUN_ROT := 132.0
const SUN_GLOW_SCALE := 4.0
const PULSAR_CENTER := Vector2(463, 203)
const PULSAR_BLACK := "effects/pulsar_black.png"
const PULSAR_WHITE := "effects/pulsar_white.png"
const PULSAR_BACK_WAVE := "effects/pulsar_backL.png"
const PULSAR_FRONT_WAVE := "effects/pulsar_frontL.png"
const PULSAR_WAVE_SCALE := 3.0
const GLOW_PERIODS := [7.0, 5.0, 10.0]  # sunGlow1 / 2 / 3 loop times (s)
const CLOUD_IMG := "stars/nebula_large_c.png"
const CLOUD_STORM := "stars/nebula_large_b.png"
const CLOUD_BRIGHT := "stars/nebula_large_a.png"
const LIGHTNING := "stars/lightning.png"
const CLOUD_W := 199.0
const CLOUD_H := 155.0
const LIGHTNING_W := 85.0
const LIGHTNING_H := 155.0
const LIGHTNING_TIME := 0.25  # lightningFlash tracker (s)
const FOREGROUND_JUMP_ZOOM := 0.05  # RenderStatic: foreground scale 1 − 0.05·k
## SetNebula runs OnLoopNebulas 800 times at once; each step advances by the frame's speed factor
## ([inferred] a 60 fps frame: 16/60).
const PRESIM_STEPS := 800
const PRESIM_FACTOR := GameClock.BASE / 60.0

var space := {}
var env := -1
var hazard: HazardRule = null
var ship: ShipState = null  # player ship (hull tint)
var player_paused := Callable()  # () -> bool: the player's own pause (dark tint)
var jump_source: AsteroidLayers = null  # jump_k / jump_center / jump_unpaused (set by main.gd every jump frame)
var mirror: Control = null  # MirroredBackground (touch UI) that draws the background image
var clouds: Array = []  # NebulaCloud state dictionaries (shared with `space` so a scene rebuild keeps them)
var _rng := RandomNumberGenerator.new()
var _presim := false


## The combat sandbox (no run): the first BACKGROUND image, no planet.
static func sandbox_space() -> Dictionary:
	return {"back": SpaceImages.SANDBOX_BACK, "planet": {}, "danger": 0, "fleet": [], "pds_planet": {},
		"cloud_seed": 1}


func setup(sp: Dictionary, hz: HazardRule, player: ShipState) -> void:
	space = sp
	hazard = hz
	env = hz.env if hz != null else -1
	ship = player
	set_anchors_preset(Control.PRESET_FULL_RECT)  # the 1280×720 hud_root frame
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR  # GL images are filtered (clouds / sun glow scaled ×3–4)
	if nebula():
		if space.has("clouds_state"):
			clouds = space.clouds_state
			_rng.state = int(space.get("clouds_rng", 0))
		else:
			_make_clouds(int(space.get("cloud_seed", 1)))
			space.clouds_state = clouds
	if not space.has("glow_t"):
		space.glow_t = 0.0
	_sync_mirror()


func nebula() -> bool:
	return env == HazardRule.Env.NEBULA or env == HazardRule.Env.STORM


## The image OnRenderBackground draws (pulsar: bg_dullstars), "" = none.
func back_path() -> String:
	if env == HazardRule.Env.PULSAR:
		return SpaceImages.PULSAR_BACK
	return String(space.get("back", ""))


## The planet on screen ({} = none): the ASB's populated planet replaces the beacon's.
func planet() -> Dictionary:
	if env == HazardRule.Env.PDS and not (space.get("pds_planet", {}) as Dictionary).is_empty():
		return space.pds_planet
	return space.get("planet", {})


func tint() -> Color:
	var h := 1.0
	if ship != null:
		h = clampf(float(ship.hull) / maxf(ship.max_hull, 1), 0.0, 1.0)
	var unpaused := jump_source != null and jump_source.jump_unpaused
	if not unpaused and player_paused.is_valid() and bool(player_paused.call()):
		return Color((1.0 - h) * 0.4 + 0.4, 0.4, 0.4, 1.0)
	var g := 1.0 - (1.0 - h) * (1.0 - h) * 0.5
	return Color(1.0, g, g, 1.0)


## AnimationTracker::GetAlphaLevel of a looping tracker: 0 → 1 → 0 over its period.
static func glow_alpha(t: float, period: float) -> float:
	var half := period * 0.5
	var c := fmod(t, period)
	return (half - absf(c - half)) / half


func _process(delta: float) -> void:
	var dt := delta if jump_source != null and jump_source.jump_unpaused else Combat.world_delta(delta)
	space.glow_t = float(space.get("glow_t", 0.0)) + dt
	if nebula() and dt > 0.0:
		_loop_clouds(dt * GameClock.BASE)
		space.clouds_rng = _rng.state
	_sync_mirror()
	queue_redraw()


func _sync_mirror() -> void:
	if mirror == null:
		return
	var t: Texture2D = null
	if not nebula() and back_path() != "":
		t = HudDraw.tex(back_path())
	if mirror.get("texture") != t:
		mirror.set("texture", t)
	var c := tint()
	if mirror.get("tint") != c:
		mirror.set("tint", c)


# ------------------------------------------------------------------ nebula clouds (SetNebula / OnLoopNebulas)

## SpaceManager::SetNebula: 12 points on a 4 × 3 grid from (100, 200), columns 350 apart, rows 230 apart; the
## middle row jitters x by r % 131 − 65, the middle columns jitter y by r % 81 − 40. The points are taken in a
## random order, one cloud each; then OnLoopNebulas runs 800 times.
func _make_clouds(seed_value: int) -> void:
	_rng.seed = seed_value
	clouds = []
	var pts := []
	for col in 4:
		var xj := 0
		for row in 3:
			if row == 1:
				xj = int(_rng.randi() % 131) - 65
			elif row == 2:
				xj = 0
			var yj := 0
			if col != 0 and col != 3:
				yj = int(_rng.randi() % 81) - 40
			pts.append(Vector2(100 + col * 350 + xj, 200 + row * 230 + yj))
	while not pts.is_empty():
		var i := int(_rng.randi() % pts.size())
		var p: Vector2 = pts[i]
		pts.remove_at(i)
		clouds.append(_new_cloud(p))
	_presim = true
	for i in PRESIM_STEPS:
		_loop_clouds(PRESIM_FACTOR)
	_presim = false


## NebulaCloud constructor: alpha 0 (+0.05 per factor unit), scale 3 or 4 (+0.003), trigger 0.6–0.9, lightning
## timer 100–300 factor units (storm only).
func _new_cloud(p: Vector2) -> Dictionary:
	var sc := float(_rng.randi() % 2 + 3)
	var trig := float(_rng.randi() % 301 + 600) / 1000.0
	var ft := float(_rng.randi() % 201 + 100)
	return {"pos": p, "alpha": 0.0, "scale": sc, "d_alpha": 0.05, "d_scale": 0.003, "new_cloud": false,
		"trigger": trig, "flash_timer": ft, "lightning": env == HazardRule.Env.STORM, "flash": -1.0, "rot": 0.0}


## SpaceManager::OnLoopNebulas: each cloud steps; a fading cloud below its trigger spawns its successor at the
## same point (inserted before it, so drawn under it); a cloud below alpha 0 is removed.
func _loop_clouds(sf: float) -> void:
	var i := 0
	while i < clouds.size():
		var c: Dictionary = clouds[i]
		_cloud_step(c, sf)
		if float(c.alpha) < float(c.trigger) and not c.new_cloud and float(c.d_alpha) < 0.0:
			c.new_cloud = true
			clouds.insert(i, _new_cloud(c.pos))
			c = clouds[i]
		if float(c.alpha) < 0.0:
			clouds.remove_at(i)
			i -= 1
		i += 1


## NebulaCloud::OnLoop (sf = speed factor units, 16 per second).
func _cloud_step(c: Dictionary, sf: float) -> void:
	c.alpha = float(c.alpha) + sf * float(c.d_alpha)
	c.scale = float(c.scale) + sf * float(c.d_scale)
	if float(c.alpha) > 1.0:
		c.d_alpha = -0.002
		c.alpha = 1.0
	elif float(c.alpha) < float(c.trigger) and float(c.d_alpha) < 0.0:
		c.d_alpha = -0.01
	c.flash_timer = float(c.flash_timer) - sf
	if float(c.flash) >= 0.0:
		c.flash = float(c.flash) + sf / GameClock.BASE
	if float(c.flash_timer) < 0.0 and c.lightning:
		c.rot = float(_rng.randi() % 4) * 90.0
		c.flash = 0.0
		c.flash_timer = 1e6
		var vol := float(_rng.randi() % 101 + 900) / 1000.0
		var n := int(_rng.randi() % 4) + 1
		if not _presim:
			FtlData.play("lightning%d" % n, vol)
	if float(c.flash) >= LIGHTNING_TIME:
		c.flash = -1.0
		c.flash_timer = float(_rng.randi() % 201 + 100)


# ------------------------------------------------------------------ drawing

func _draw() -> void:
	var col := tint()
	if nebula():
		# No background image: the cleared (black) screen, then the clouds.
		var vis := Rect2(Vector2.ZERO, Vector2(_visible_width(), size.y))
		draw_rect(vis, Color.BLACK)
		_draw_clouds(col)
		return
	if mirror == null:
		var bp := back_path()
		var bt := HudDraw.tex(bp) if bp != "" else null
		if bt != null:
			draw_texture(bt, Vector2.ZERO, Color(col.r, col.g, col.b, 1.0))
	_draw_foreground(col)


func _visible_width() -> float:
	if get_viewport() == null:
		return size.x
	return maxf(size.x, get_viewport_rect().size.x / maxf(get_global_transform().get_scale().x, 0.001))


func _draw_clouds(col: Color) -> void:
	var img := HudDraw.tex(CLOUD_IMG)
	var storm := HudDraw.tex(CLOUD_STORM)
	var bright := HudDraw.tex(CLOUD_BRIGHT)
	var bolt := HudDraw.tex(LIGHTNING)
	for c in clouds:
		var s := float(c.scale)
		var a := clampf(float(c.alpha), 0.0, 1.0)
		var cc := Color(col.r, col.g, col.b, a)
		var p: Vector2 = c.pos
		var t := storm if c.lightning else img
		if float(c.flash) >= 0.0:
			t = bright
			if bolt != null:
				var o := Vector2(p.x - s * LIGHTNING_W * 0.5, p.y - s * LIGHTNING_H * 0.5)
				var ctr := o + Vector2(LIGHTNING_W, LIGHTNING_H) * s * 0.5
				draw_set_transform(ctr, deg_to_rad(float(c.rot)), Vector2(s, s))
				draw_texture_rect(bolt, Rect2(-LIGHTNING_W * 0.5, -LIGHTNING_H * 0.5, LIGHTNING_W, LIGHTNING_H),
					false, cc)
				draw_set_transform(Vector2.ZERO)
		if t != null:
			# OnRenderBackground: translate (pos − 199·scale/2) on both axes (sic), scale, blit 199×155.
			var half := CLOUD_W * s * 0.5
			draw_texture_rect(t, Rect2(p.x - half, p.y - half, CLOUD_W * s, CLOUD_H * s), false, cc)


func _draw_foreground(col: Color) -> void:
	var base := Transform2D.IDENTITY
	if jump_source != null and jump_source.jump_k > 0.0:
		var s := 1.0 - FOREGROUND_JUMP_ZOOM * clampf(jump_source.jump_k, 0.0, 1.0)
		var c := jump_source.jump_center
		base = Transform2D(0.0, Vector2(s, s), 0.0, c * (1.0 - s))
	var gt := float(space.get("glow_t", 0.0))
	if env == HazardRule.Env.SUN:
		_draw_sun(base, col, gt)
	elif env == HazardRule.Env.PULSAR:
		_draw_pulsar(base, col, gt)
	else:
		var pl := planet()
		var t := HudDraw.tex(String(pl.get("img", ""))) if not pl.is_empty() else null
		if t != null:
			var sz := t.get_size()
			var ctr := Vector2(pl.pos) + sz * 0.5
			_image(base, t, ctr, float(pl.get("rot", 0)), Vector2.ONE, Color(col.r, col.g, col.b, 1.0))
	# OnRenderFleet
	if int(space.get("danger", 0)) != 0:
		draw_set_transform_matrix(base)
		for f in space.get("fleet", []):
			var ft := HudDraw.tex(String(f.img))
			if ft != null:
				draw_texture(ft, Vector2(f.pos) - Vector2(SpaceImages.FLEET_OFFSET, SpaceImages.FLEET_OFFSET),
					Color(col.r, col.g, col.b, 1.0))
		if env == HazardRule.Env.PDS:
			var big := HudDraw.tex(SpaceImages.FLEET_BIG)
			if big != null:
				draw_texture(big, Vector2(SpaceImages.FLEET_BIG_POS))
	draw_set_transform(Vector2.ZERO)


## An image centred at `ctr`, rotated (degrees, about its centre) and scaled, under `base`.
func _image(base: Transform2D, t: Texture2D, ctr: Vector2, rot_deg: float, sc: Vector2, color: Color) -> void:
	draw_set_transform_matrix(base * Transform2D(deg_to_rad(rot_deg), sc, 0.0, ctr))
	draw_texture(t, -t.get_size() * 0.5, color)
	draw_set_transform(Vector2.ZERO)


## OnRenderForeground, sun: planet_sun2 ×4 from the origin (alpha 0.1 + 0.9·glow1), planet_sun1 at (100, 109)
## rotated 132° (alpha 0.7 + 0.3·glow2), planet_sun2 ×4 again (alpha 0.05 + 0.35·glow3).
func _draw_sun(base: Transform2D, col: Color, gt: float) -> void:
	var glow := HudDraw.tex(SUN_GLOW)
	var sun := HudDraw.tex(SUN_IMG)
	var g1 := glow_alpha(gt, GLOW_PERIODS[0])
	var g2 := glow_alpha(gt, GLOW_PERIODS[1])
	var g3 := glow_alpha(gt, GLOW_PERIODS[2])
	if glow != null:
		draw_set_transform_matrix(base)
		draw_texture_rect(glow, Rect2(Vector2.ZERO, glow.get_size() * SUN_GLOW_SCALE), false,
			Color(col.r, col.g, col.b, g1 * 0.9 + 0.1))
	if sun != null:
		_image(base, sun, SUN_POS + sun.get_size() * 0.5, SUN_ROT, Vector2.ONE,
			Color(col.r, col.g, col.b, g2 * 0.3 + 0.7))
	if glow != null:
		draw_set_transform_matrix(base)
		draw_texture_rect(glow, Rect2(Vector2.ZERO, glow.get_size() * SUN_GLOW_SCALE), false,
			Color(col.r, col.g, col.b, g3 * 0.35 + 0.05))
	draw_set_transform(Vector2.ZERO)


## OnRenderForeground, pulsar (centre (463, 203)): shock wave back (scale 3·p, alpha 1 − p; p = progress of the
## 1 s flash tracker), pulsar_black, pulsar_white (alpha glow1), shock wave front.
func _draw_pulsar(base: Transform2D, col: Color, gt: float) -> void:
	var p := 0.0
	if hazard != null and hazard.flash >= 0.0:
		p = clampf(hazard.flash / HazardRule.FLASH_LEN, 0.0, 1.0)
	var c3 := Color(col.r, col.g, col.b, 1.0)
	var wave_back := HudDraw.tex(PULSAR_BACK_WAVE)
	var wave_front := HudDraw.tex(PULSAR_FRONT_WAVE)
	var black := HudDraw.tex(PULSAR_BLACK)
	var white := HudDraw.tex(PULSAR_WHITE)
	var ws := Vector2.ONE * (PULSAR_WAVE_SCALE * p)
	if wave_back != null and p > 0.0:
		_image(base, wave_back, PULSAR_CENTER, 0.0, ws, Color(c3, 1.0 - p))
	if black != null:
		draw_set_transform_matrix(base)
		draw_texture(black, (PULSAR_CENTER - (black.get_size() / 2.0).floor()).floor(), c3)
	if white != null:
		draw_set_transform_matrix(base)
		draw_texture(white, (PULSAR_CENTER - (white.get_size() / 2.0).floor()).floor(),
			Color(c3, glow_alpha(gt, GLOW_PERIODS[0])))
	if wave_front != null and p > 0.0:
		_image(base, wave_front, PULSAR_CENTER, 0.0, ws, Color(c3, 1.0 - p))
	draw_set_transform(Vector2.ZERO)
