class_name ScreenShake
extends Node
## FTL's general screen shake (rules/hud_layout.md "Screen shake"; CommandGui::OnLoop / UpdateShake /
## RenderStatic, SpaceManager::GetScreenShake / UpdatePDS).
##
## Sources (the only two in the exe):
##   - the player ship's hull damage: every frame CommandGui::OnLoop reads ShipManager::GetLastDamage (the last
##     DamageHull / DamageArea / DamageBeam / SunDamage value, then cleared); when non-zero the shake timer is SET to
##     min(damage / 5, 1) s (a repair, negative, sets it negative: the shake stops);
##   - an ASB / PDS shot leaving the gun (SpaceManager::queueScreenShake): timer = clamp(timer, 0.05, 1).
## UpdateShake (once per rendered frame, vanilla runs at 60 fps): when the current offset (rounded) has reached the
## desired one, a running timer picks a new desired offset (rand % 6 − 3 on each axis: −3..2 px) reached in 5
## frames, an expired one goes back to (0, 0) in 10 frames; overshooting snaps to the desired offset. The timer
## counts down in real seconds (speed factor × 0.0625), paused or not.
## What moves: the HUD block RenderStatic draws inside the shake translate — top buttons, enemy window and enemy
## ship, crew list, system / weapon / drone bars, pause text, hazard status, ShipStatus (and the flash). The
## background, asteroid layers and the player ship do not shake; focus windows (event box, store, maps) neither.
## No option disables it.
##
## Godot: the offset is added to each target node's position (so every piece keeps hit-testing in the local
## coordinates of its drawing node) and taken out again when the shake ends. A position written by someone else
## (the touch layout) while shaking becomes the node's new base.

const DAMAGE_DIV := 5.0  # DAT_00830ce0: timer = damage / 5
const MAX_TIME := 1.0  # DAT_00830cec
const PDS_MIN := 0.05  # DAT_00830d74
const STEPS_OUT := 5.0  # DAT_00830ce0: frames to reach a new random offset
const STEPS_BACK := 10.0  # DAT_00830ce8: frames to settle back to (0, 0)
const FRAME := 1.0 / 60.0  # one UpdateShake step (vanilla frame)
const MAX_STEPS := 4  # steps per _process at most (long frames)

var timer := 0.0  # CommandGui::fShakeTimer (s)
var desired := Vector2.ZERO  # UpdateShake statics
var current := Vector2.ZERO
var change := Vector2.ZERO
var rng := RandomNumberGenerator.new()
var ship: ShipState = null  # the player ship (GetLastDamage)
var targets := Callable()  # () -> Array of CanvasItem (Node2D / Control) to move
var hazard_source := Callable()  # () -> HazardRule or null (queueScreenShake)
var _acc := 0.0
var _applied := {}  # node -> [base position, offset last applied]


func _init() -> void:
	process_priority = 1000  # after every node that writes its own position this frame
	process_mode = Node.PROCESS_MODE_ALWAYS


func setup(player: ShipState, target_list: Callable, hazard: Callable = Callable()) -> void:
	ship = player
	targets = target_list
	hazard_source = hazard


## CommandGui::OnLoop, GetLastDamage branch: non-zero damage sets the timer to min(damage / 5, 1).
func on_hull_damage(damage: int) -> void:
	if damage != 0:
		timer = minf(float(damage) / DAMAGE_DIV, MAX_TIME)


## CommandGui::OnLoop, GetScreenShake branch (an ASB shot launched): timer clamped to [0.05, 1].
func on_pds_shot() -> void:
	timer = clampf(timer, PDS_MIN, MAX_TIME)


## The current translate (px).
func offset() -> Vector2:
	return current


func active() -> bool:
	return timer > 0.0 or current != Vector2.ZERO or desired != Vector2.ZERO


## One UpdateShake call (one vanilla frame of `dt` real seconds).
func step(dt := FRAME) -> void:
	if current.round() == desired.round():
		if timer <= 0.0:
			if desired.round() == Vector2.ZERO:
				change = Vector2.ZERO
				current = desired
			else:
				desired = Vector2.ZERO
				change = (desired - current) / STEPS_BACK
		else:
			desired = Vector2(float(rng.randi() % 6) - 3.0, float(rng.randi() % 6) - 3.0)
			change = (desired - current) / STEPS_OUT
	var nxt := current + change
	timer -= dt
	var crossed_x := (current.x < desired.x and desired.x <= nxt.x) or (desired.x < current.x and nxt.x <= desired.x)
	var crossed_y := (current.y < desired.y and desired.y <= nxt.y) or (desired.y < current.y and nxt.y <= desired.y)
	current = desired if crossed_x or crossed_y else nxt


func _process(delta: float) -> void:
	if ship != null:
		on_hull_damage(ship.take_last_damage())
	if hazard_source.is_valid():
		var h: HazardRule = hazard_source.call()
		if h != null and h.take_screen_shake():
			on_pds_shot()
	if not active() and _applied.is_empty():
		_acc = 0.0
		return
	_acc += delta
	var n := 0
	while _acc >= FRAME and n < MAX_STEPS:
		_acc -= FRAME
		step(FRAME)
		n += 1
	if n == MAX_STEPS:
		_acc = 0.0
	apply()


## Moves every target by the current offset (and back to its base once the shake is over).
func apply() -> void:
	var off := current
	var live := {}
	if targets.is_valid():
		for n in targets.call():
			if n == null or not is_instance_valid(n) or not (n is Node2D or n is Control):
				continue
			if n is Control and (n as Control).get_parent() is Container:
				continue
			live[n] = true
			var rec: Array = _applied.get(n, [])
			var pos: Vector2 = n.position
			if rec.is_empty():
				if off == Vector2.ZERO:
					continue
				rec = [pos, Vector2.ZERO]
			elif not pos.is_equal_approx(rec[0] + rec[1]):
				rec[0] = pos  # moved by someone else (layout): that is the new unshaken position
			if off == Vector2.ZERO:
				n.position = rec[0]
				_applied.erase(n)
				continue
			n.position = rec[0] + off
			rec[1] = off
			_applied[n] = rec
	for n in _applied.keys():
		if not live.has(n):
			_applied.erase(n)


## Puts every shaken node back at its unshaken position (call before a layout pass reads / writes positions; the
## next frame shakes the freshly laid-out positions).
func restore() -> void:
	for n in _applied.keys():
		if is_instance_valid(n):
			var rec: Array = _applied[n]
			if (n.position as Vector2).is_equal_approx(rec[0] + rec[1]):
				n.position = rec[0]
	_applied.clear()
