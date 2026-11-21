class_name AsteroidLayers
extends Control
## The asteroid field background (rules/hazards.md §2 "Visuals"): SpaceManager's three `Scroller`s
## (`asteroids/asteroid_back1/2/3.png`, tiles 546×309 / 388×446 / 476×439, speeds 4 / 5 / 6) drawn by
## SpaceManager::OnRenderAsteroids between the beacon background and the player ship while the asteroid
## generator runs. Each layer tiles a 3840×3600 region from (−1280, −720), shifted left by `current_x`
## (Scroller::OnLoop: current_x −= 0.5 · speed · speedFactor, i.e. 32 / 40 / 48 px/s; wraps to the tile width).
## Tint: (1, g, g, 1) with g = 1 − 0.5 · (1 − hull fraction)² (redder as the player hull drops); while paused
## (0.4 + 0.4 · (1 − hull), 0.4, 0.4). Scrolling stops while the game is paused (world time).
##
## The enemy window shows the same layers: CombatControl::RenderTarget draws box_hostiles2.png (≈ 82 % opaque,
## tinted (1, 0.7, 0.7)) over the already-drawn full-screen layers, so they show through the box. There is no
## separate asteroid pass for the target box (CompleteShip::OnRenderSpace, which would draw one, is never called).
##
## Player jump (CommandGui::RenderStatic, rules/hazards.md §2): while jumpAnimation runs the layers are scaled
## 1 − 0.3·k about the player ship's centre (k = jump shrink factor, main.gd `_jump_step`), and a second instance
## (`front`, only the nearest layer asteroid_back3 — OnRenderAsteroids(layers = 1)) is drawn over the shrinking
## player ship, only while k > 0. The `alpha` argument of OnRenderAsteroids is unused [exe]: full opacity.

const IMAGES := ["asteroids/asteroid_back1.png", "asteroids/asteroid_back2.png", "asteroids/asteroid_back3.png"]
const TILES := [Vector2(546, 309), Vector2(388, 446), Vector2(476, 439)]
const SPEEDS := [4.0, 5.0, 6.0]
const SCROLL_FACTOR := 0.5
const REGION := Rect2(-1280, -720, 3840, 3600)
const JUMP_ZOOM := 0.3  # RenderStatic: asteroid scale 1 − 0.3·k

var run: RunState
var ship: ShipState  # player ship (hull tint)
var combat: Combat  # paused tint
var scroll := [0.0, 0.0, 0.0]  # Scroller::current_x per layer
## Front copy over the player ship (jump only): draws layer 3 with `source`'s scroll and tint.
var front := false
var source: AsteroidLayers = null
## Jump state, set by main.gd every jump frame: k (0 = no jump) and the player ship centre (this node's coords).
var jump_k := 0.0
var jump_center := Vector2.ZERO
## While the player jumps away the world clock is held (the map's pause), but the space keeps moving in vanilla
## (gamePaused is the player's pause only): scroll on real time and use the unpaused tint.
var jump_unpaused := false
## The location this node was built for (RunState.arrival_serial) and whether its generator ran: between a new
## arrival and the scene rebuild (the jump-away animation) the old field stays on screen (ClearLocation comes at
## JumpArrive in vanilla), although RunState already holds the new beacon's hazard.
var _serial := -1
var _built_active := false


func setup(r: RunState, player: ShipState, c: Combat) -> void:
	run = r
	ship = player
	combat = c
	set_anchors_preset(Control.PRESET_FULL_RECT)
	size = HudLayout.FRAME
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_serial = r.arrival_serial if r != null else -1


## The front layer over the player ship during a jump (shares `src`'s scrollers).
func setup_front(src: AsteroidLayers) -> void:
	front = true
	source = src
	set_anchors_preset(Control.PRESET_FULL_RECT)
	size = HudLayout.FRAME
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## SpaceStatus / OnRenderAsteroids gate: the beacon's asteroid generator is running.
func active() -> bool:
	if run == null:
		return false
	if run.arrival_serial == _serial or _serial < 0:
		_built_active = run.hazard != null and run.hazard.has_env(HazardRule.Env.ASTEROIDS)
	return _built_active


## RenderStatic's asteroid scale for jump factor k.
static func jump_scale(k: float) -> float:
	return 1.0 - JUMP_ZOOM * clampf(k, 0.0, 1.0)


func _process(delta: float) -> void:
	if front:
		visible = source != null and source.visible and source.jump_k > 0.0
		if visible:
			queue_redraw()
		return
	visible = active()
	if not visible:
		return
	var sf := (delta if jump_unpaused else Combat.world_delta(delta)) * GameClock.BASE
	for i in 3:
		scroll[i] -= SCROLL_FACTOR * SPEEDS[i] * sf
		if scroll[i] < 0.0:
			scroll[i] = TILES[i].x
	queue_redraw()


func tint() -> Color:
	var h := 1.0
	if ship != null:
		h = clampf(float(ship.hull) / maxf(ship.max_hull, 1), 0.0, 1.0)
	if combat != null and combat.paused and not jump_unpaused:
		return Color((1.0 - h) * 0.4 + 0.4, 0.4, 0.4, 1.0)
	var g := 1.0 - (1.0 - h) * (1.0 - h) * 0.5
	return Color(1.0, g, g, 1.0)


## CSurface::GL_TilePixelImage: columns k·tile + scroll − tile (k = 0 .. size/tile + 2), rows from −1.
func _draw() -> void:
	var src := source if front else self
	if src == null:
		return
	var col := src.tint()
	# Jump zoom: x' = c + (x − c)·s about the player ship centre; `view` = the screen in layer coordinates.
	var s := jump_scale(src.jump_k) if src.jump_k > 0.0 else 1.0
	var c := src.jump_center
	var view := Rect2(Vector2.ZERO, size)
	if s != 1.0:
		draw_set_transform(c * (1.0 - s), 0.0, Vector2(s, s))
		view = Rect2(c - c / s, size / s)
	for i in range(2 if front else 0, 3):
		var tex := HudDraw.tex(IMAGES[i])
		if tex == null:
			continue
		var t: Vector2 = TILES[i]
		var cols := int(REGION.size.x / t.x + 1.0) + 2
		var rows := int(REGION.size.y / t.y + 1.0) + 3
		for k in cols:
			var x: float = REGION.position.x + k * t.x + src.scroll[i] - t.x
			if x > view.end.x or x + t.x < view.position.x:
				continue
			for j in range(-1, rows - 1):
				var y: float = REGION.position.y + j * t.y
				if y > view.end.y or y + t.y < view.position.y:
					continue
				draw_texture_rect(tex, Rect2(x, y, t.x, t.y), false, col)
	if s != 1.0:
		draw_set_transform(Vector2.ZERO)
