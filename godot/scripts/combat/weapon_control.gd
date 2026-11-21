class_name WeaponControl
extends RefCounted
## Player weapon selection and targeting (rules/targeting.md).
## UI-agnostic: any interface (mouse, touch, gamepad) calls these methods.

signal changed
## Click feedback: `reason` = "" (success / depower), "no_missiles", "no_power" (weapons system short),
## "reactor" (the rule layer set ShipState.failed_powerup: NOT ENOUGH POWER) or "locked" (sound only).
signal message(reason: String, sound: String)

var ship: ShipState
var armed := -1  # index of the armed weapon (selected for aiming), -1 = none
var failed_weapon: WeaponState = null  # the weapon of the last refused power click (message text)
# Beam aiming (CombatControl::UpdateAiming/SelectTarget): first point = click inside a room, second =
# start + length toward the pointer once it is more than BEAM_MIN_DRAG px away.
const BEAM_MIN_DRAG := 10.0
var beam_ship: ShipState = null  # ship of the first beam point (null = no beam aim in progress)
var beam_start := Vector2.ZERO


func _init(s: ShipState) -> void:
	ship = s


func weapon(i: int) -> WeaponState:
	return ship.weapons[i] if i >= 0 and i < ship.weapons.size() else null


## Click/tap on box i (or key 1-4).
func select(i: int) -> void:
	var w := weapon(i)
	if w == null:
		return
	beam_ship = null
	if w.powered:
		armed = i
		w.clear_target()  # ClearAiming: the previous target is cleared
	else:
		armed = -1
		var r := ship.try_power_weapon(w)
		failed_weapon = w if r != "ok" else null
		message.emit("" if r == "ok" else r, "powerUpSystem" if r == "ok" else "powerUpFail")
	changed.emit()


## Drag-swap of two weapon boxes (WeaponControl::SwapArmaments): the weapons exchange slots (and so
## their depower order and hull mounts); the armed slot follows the armed weapon.
func swap(a: int, b: int) -> void:
	if not ship.swap_weapons(a, b):
		return
	if armed == a:
		armed = b
	elif armed == b:
		armed = a
	changed.emit()


## Right click / long press on box i: depower.
func depower(i: int) -> void:
	var w := weapon(i)
	if w and w.powered:
		ship.depower_weapon(w)
		w.clear_target()
		message.emit("", "powerDownSystem")
	if armed == i:
		armed = -1
	changed.emit()


## Right click elsewhere: disarm (without depowering).
func disarm() -> void:
	armed = -1
	beam_ship = null
	changed.emit()


## The armed weapon is a beam (needs a start point and a direction).
func armed_is_beam() -> bool:
	var w := weapon(armed)
	return w != null and w.is_beam()


## Bombs may target the own ship (CombatControl::CanTargetSelf: weapon type 3).
func armed_can_target_self() -> bool:
	var w := weapon(armed)
	return w != null and w.is_bomb()


## First beam point: must be inside a room of the target ship. Returns true if it was taken.
func begin_beam(target: ShipState, p: Vector2) -> bool:
	if not armed_is_beam() or target.is_destroyed() or target.room_at(p) < 0:
		return false
	beam_ship = target
	beam_start = p
	changed.emit()
	return true


## Beam end point for a pointer position: start + length toward the pointer, or null while the pointer is
## within BEAM_MIN_DRAG px of the start (the beam keeps its full length whatever the drag distance).
func beam_end_for(pointer: Vector2) -> Variant:
	var w := weapon(armed)
	if w == null or beam_ship == null or pointer.distance_to(beam_start) <= BEAM_MIN_DRAG:
		return null
	return beam_start + (pointer - beam_start).normalized() * float(w.bp.get("length", 0))


## Second beam point (click or drag release): aims the armed beam. Returns true if it was aimed.
func finish_beam(pointer: Vector2, invert_auto := false) -> bool:
	var end: Variant = beam_end_for(pointer)
	if end == null:
		return false
	return aim_beam(beam_ship, beam_start, end, invert_auto)


## Aims the armed beam from `start` to `end` on `target` (both points in that ship's coordinates).
func aim_beam(target: ShipState, start: Vector2, end: Vector2, invert_auto := false) -> bool:
	var w := weapon(armed)
	if w == null or not w.is_beam() or target.is_destroyed() or (target != ship and not target.hostile):
		return false
	var auto := ship.autofire != invert_auto
	w.set_target(target, target.room_at(start), start, auto, end)
	armed = -1
	beam_ship = null
	changed.emit()
	return true


## Click on an enemy room with an armed weapon. invert_auto = Shift.
func aim_at(target: ShipState, room: int, invert_auto := false) -> bool:
	var w := weapon(armed)
	if w == null or room < 0 or target.is_destroyed():
		return false
	if target != ship and not target.hostile:
		return false  # CombatControl::UpdateAiming: only a hostile target can be aimed at
	if target == ship and not w.is_bomb():
		return false
	if w.is_beam():
		# No drag (keyboard / CLI): from the room centre toward the centre of the ship's rooms.
		var c := target.room_rect(room).get_center()
		var to := target.rooms_bounds().get_center()
		var dir := (to - c).normalized() if to.distance_to(c) > 1.0 else Vector2.RIGHT
		return aim_beam(target, c, c + dir * float(w.bp.get("length", 0)), invert_auto)
	var auto := ship.autofire != invert_auto
	w.set_target(target, room, target.room_rect(room).get_center(), auto)
	armed = -1
	changed.emit()
	return true


## The AUTOFIRE button / hotkey / touch box: WeaponControl::SetAutofiring(!autoFiring, simple = false) — turning it
## on also disarms the armed weapon (armedSlot = -1); `autofireOn` / `autofireOff`. (A save load restores the
## state with simple = true: no sound; ShipState.set_autofire.)
func toggle_autofire() -> void:
	ship.set_autofire(not ship.autofire)
	if ship.autofire:
		armed = -1
		beam_ship = null
	FtlData.play("autofireOn" if ship.autofire else "autofireOff")
	changed.emit()
