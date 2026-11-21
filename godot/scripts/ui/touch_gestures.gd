class_name TouchGestures
extends RefCounted
## Combat taps (touch input profile only; rules/ui_layout_strategy.md "Touch gestures (combat)"). UI-agnostic like
## CrewControl: main.gd `_input` hands it the presses / lifts of the one finger (Godot's emulated left mouse; on
## desktop the left button) in 1280×720 frame coordinates; the weapon / system side lives in main.gd (callables).
##
## - Tap = click. While the finger is down it hovers like a cursor (crew hover, room outline, tooltips after the
##   TooltipService hold); the lift is the click on what is under it now. No one-finger drag box, no second
##   finger except the held-finger gestures below, no right-button stand-in (a desktop right button only reaches
##   the GUI).
## - Selection mode: a tap that selects something needing a follow-up (crew, an armed weapon / teleporter / hacking /
##   mind control) puts main.gd in selection mode (auto-pause + CANCEL button, `main._touch_selection_tick`).
##   With crew selected (`finger_release`):
##     tap a crew sprite / crew box  -> that crew becomes the selection (tapping exactly the selection = cancel)
##     tap the LOCKDOWN button       -> crew power (selection kept)
##     tap a HUD control             -> the control acts (power, doors buttons ...); selection kept
##     tap a door                    -> door toggles; selection kept
##     tap a room                    -> the selected crew aboard that ship walk there (the PC right click), selection
##                                      ends; no path / no selected crew aboard that ship = nothing, selection kept
##     tap empty space (no room)     -> cancel (deselect)
##   With something armed (targeting itself = main.gd's Space room_clicked on the press, unchanged):
##     tap an enemy room (target)    -> fires / sends / hacks; the system disarms itself -> mode ends
##     tap a HUD control             -> the control acts (another weapon box re-arms, the same one disarms ...)
##     tap a crew box (crew list)    -> disarm, the tap selects that crew instead
##     tap an own room               -> as PC (bombs / mind control may target it), else nothing, still armed
##     tap empty space (no room)     -> cancel (disarm); not while a beam's first point is placed
##   With nothing selected: tap a door = toggle, tap a crew = select (mode starts), tap the floor = nothing.

##
## Held finger = − (temporary power mode, TouchPowerToggle): the first finger (index 0) resting — down for ≥ HOLD_MS
## and not drifting more than TooltipService.TOUCH_SLOP before that — makes `held_minus()` true (the toggle shows −).
## A second finger (index 1) landing then is a − tap: its landing cancels the held finger's tap (main.gd
## `_touch_hold_cancel`: no click on its lift) and its lift is dispatched as a normal tap at its point with − mode
## forced (main.gd `_touch_minus_tap`). A second finger landing earlier (near-simultaneous two-finger tap) is
## ignored, as before. Desktop stand-in (one pointer): Ctrl held = a resting finger (no delay); the left click is the
## second finger's tap. (Not the right button: Godot routes every press to the control holding the mouse focus while a
## button is down, so a held right button would swallow the left click.)
##
## Multi-select [ours], same held finger (or Ctrl) as the modifier:
##   second finger DRAGS (from a point `can_box` accepts: anywhere but a tap control, main._touch_interactive_at)
##     -> the PC drag box (CrewControl's own DRAG_DRAW / DRAG_SELECT thresholds and white rectangle); its lift
##        replaces the selection (CrewControl.select_potential(false), as the PC left release) -> selection mode.
##        Desktop: Ctrl + left drag.
##   second finger TAPS a crew sprite / crew box -> that crew toggles in / out of the selection (instead of the −
##     tap; − taps elsewhere are unchanged). Desktop: Ctrl + left click. Something armed is disarmed first (arming
##     and crew selection are exclusive).

enum { PASS, CONSUME, GUI, HOLD_CANCEL, MINUS_TAP }  # handle(): main's own path / handled / GUI only / − hold

const HOLD_MS := 150  # first finger down (still) this long before a second finger's tap counts as a − tap

var hold_down := false  # finger 0 (or the desktop right button) is down
var hold_ms := 0  # Time.get_ticks_msec() when it landed
var hold_pos := Vector2.ZERO
var hold_still := true  # it did not drift beyond the slop before HOLD_MS
var hold_used := false  # a second finger already tapped in − mode (the held finger's tap is cancelled)
var second_minus := false  # finger 1 landed while held: its lift is a − tap

var crew: CrewControl
var is_armed: Callable  # () -> bool: weapon / teleporter / hacking / mind control armed (main.weapons_armed)
var disarm: Callable  # (): CombatControl::MouseRClick's disarm part
var over_hud: Callable  # (screen) -> bool: a HUD control (not a ship view) is under the point
var beam_pending: Callable  # () -> bool: a beam's first point is placed (its second tap may be anywhere)
var can_box: Callable  # (screen) -> bool: a held-finger / Ctrl drag box may start here (main._touch_box_start)
var second_box := false  # finger 1 (held-finger mode) landed where a box may start: CrewControl tracks it as a drag
var ctrl_box := false  # desktop stand-in: a Ctrl + left press started a possible box (the mouse drives it)

var tap_pending := false  # one finger pressed on the combat view: its lift is the click
var press_armed := false  # something was armed when the finger landed (the press was a target click)
var last_result := ""  # what the last lift did (tests / debug): select / switch / cancel / move / door / ...


func _init(cc: CrewControl, armed_fn := Callable(), disarm_fn := Callable(), hud_fn := Callable(),
		beam_fn := Callable()) -> void:
	crew = cc
	is_armed = armed_fn
	disarm = disarm_fn
	over_hud = hud_fn
	beam_pending = beam_fn


func _armed() -> bool:
	return bool(is_armed.call()) if is_armed.is_valid() else false


func _hud(screen: Vector2) -> bool:
	return bool(over_hud.call(screen)) if over_hud.is_valid() else false


## Routes one event. Only the first finger counts: other ScreenTouch / ScreenDrag indices are consumed (ignored),
## the right mouse button goes to the GUI only (its own right click: weapon / drone box depower, system column −1).
## Held finger rules: see the header (HOLD_CANCEL = cancel the held finger's tap, MINUS_TAP = tap at the event's
## position in − mode).
func handle(event: InputEvent) -> int:
	if event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.index == 0:
			_hold(st.pressed, st.position)
			return PASS
		if st.index == 1:
			if st.pressed and held_minus():
				second_minus = true
				second_box = _box_ok(st.position)
				if second_box:
					_box_start(st.position)
				if not hold_used:
					hold_used = true
					tap_pending = false
					return HOLD_CANCEL
			elif not st.pressed and second_minus:
				second_minus = false
				if second_box:
					second_box = false
					if _box_finish(st.position):
						return CONSUME
				return MINUS_TAP
		return CONSUME
	if event is InputEventScreenDrag:
		var sd := event as InputEventScreenDrag
		if sd.index == 0:
			_hold_moved(sd.position)
			return PASS
		if sd.index == 1 and second_box:
			crew.pointer_moved(sd.position, false)  # the box follows the second finger
		return CONSUME
	if event is InputEventMouseMotion and second_box:
		return CONSUME  # the held finger's emulated motion must not move the second finger's box
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index != MOUSE_BUTTON_LEFT:
		return GUI
	return PASS


func _hold(down: bool, p: Vector2) -> void:
	hold_down = down
	second_minus = second_minus and down
	if down:
		hold_ms = Time.get_ticks_msec()
		hold_pos = p
		hold_still = true
		hold_used = false


func _hold_moved(p: Vector2) -> void:
	if hold_down and Time.get_ticks_msec() - hold_ms < HOLD_MS and p.distance_to(hold_pos) > TooltipService.TOUCH_SLOP:
		hold_still = false


## The first finger rests (≥ HOLD_MS, still), or Ctrl is held (desktop stand-in): taps act in − mode
## (TouchPowerToggle shows −).
func held_minus() -> bool:
	if Input.is_key_pressed(KEY_CTRL):
		return true
	return hold_down and hold_still and Time.get_ticks_msec() - hold_ms >= HOLD_MS


## Held-finger / Ctrl modifier for crew taps: a second finger's tap (TouchPowerToggle.forced) or Ctrl held.
static func toggle_mod() -> bool:
	return TouchPowerToggle.forced or Input.is_key_pressed(KEY_CTRL)


func _box_ok(screen: Vector2) -> bool:
	return can_box.is_valid() and bool(can_box.call(screen))


## A possible drag box starts at `screen` (CrewControl's PC drag: rectangle / potential set by its thresholds).
func _box_start(screen: Vector2) -> void:
	crew.mouse_down = true
	crew.first_mouse = screen
	crew.current_mouse = screen


## The box's finger / button lifts at `screen`: if it moved at least DRAG_DRAW (the rectangle was shown) the box
## replaces the selection (PC SelectCrew without shift) and true is returned; otherwise false (it was a tap).
func _box_finish(screen: Vector2) -> bool:
	crew.pointer_moved(screen, false)  # mouse_down still set: the drag potential set at the lift point
	var boxed := crew.first_mouse.distance_squared_to(screen) >= CrewControl.DRAG_DRAW
	crew.mouse_down = false
	if not boxed:
		return false
	if not crew.potential.is_empty() and _armed() and disarm.is_valid():
		disarm.call()
	crew.select_potential(false)
	crew.potential.clear()  # the lifted finger hovers nothing
	crew._apply_hover()
	last_result = "box"
	return true


## Finger lands on the combat view. Returns true if it hit the crew-list UI (consumed: the GUI does not get it).
func finger_press(screen: Vector2) -> bool:
	crew.mouse_down = false
	ctrl_box = false
	press_armed = _armed()
	if press_armed and toggle_mod() and crew.crew_at(screen) != null and (crew.box_at(screen) >= 0 or not _hud(screen)):
		# Held finger / Ctrl + crew while armed: the tap toggles crew, so disarm first (no target click).
		if disarm.is_valid():
			disarm.call()
		press_armed = false
	if press_armed and crew.box_at(screen) >= 0:
		# A crew box while something is armed: switch to crew selection (the lift selects that crew).
		if disarm.is_valid():
			disarm.call()
		press_armed = false
		crew.pointer_moved(screen, false)
	if press_armed and crew.button_at(screen) >= 0:
		# A stations button (touch UI: drawn over the TARGET window's corner) wins over targeting: one tap, one
		# button; the weapon stays armed.
		press_armed = false
	tap_pending = true
	if press_armed:
		return false  # targeting: Space.room_clicked (press) / the GUI decide
	if Input.is_key_pressed(KEY_CTRL) and _box_ok(screen):
		ctrl_box = true  # desktop stand-in for held finger + drag: main's mouse motion drives CrewControl's drag
		_box_start(screen)
	var b := crew.button_at(screen)
	if b == 0:
		crew.save_stations()
	elif b == 1:
		crew.return_stations()
	return b >= 0 or crew.box_at(screen) >= 0 or crew.power_button_at(screen) >= 0


## Finger lifts: the click on what is under the finger now (see the header for the selection-mode rules).
func finger_release(screen: Vector2) -> void:
	if not tap_pending:
		return
	tap_pending = false
	if press_armed:
		press_armed = false
		# Still armed after the press = the press was no target. Empty space (no room on either ship, no HUD) cancels.
		if _armed() and not _hud(screen) and not (beam_pending.is_valid() and bool(beam_pending.call())) \
				and room_at(screen).is_empty():
			if disarm.is_valid():
				disarm.call()
			last_result = "cancel"
		return
	if ctrl_box:
		ctrl_box = false
		if _box_finish(screen):
			return
	crew.mouse_down = false
	if crew.frozen:
		return  # a weapon / drone box drag ended here
	crew.pointer_moved(screen, false)  # hover at the lift point (the finger may not have sent a motion)
	var pb := crew.power_button_at(screen)
	if pb >= 0:
		crew.activate_power(crew.roster[pb])
		last_result = "power"
		return
	var on_box := crew.box_at(screen) >= 0
	var hud := not on_box and _hud(screen)
	if toggle_mod() and not hud:
		var tc := crew.crew_at(screen)
		if tc != null:
			crew.toggle_selected(tc)  # held finger / Ctrl + crew = add / remove (selection mode follows)
			last_result = "toggle"
			return
	var sel := crew.selected_crew()
	if sel.is_empty():
		if hud:
			return  # the GUI control acts
		if crew.hovered_door >= 0:
			crew.toggle_door(crew.hovered_door)
			last_result = "door"
			return
		crew.select_potential(false)
		last_result = "select" if not crew.selected_crew().is_empty() else ""
		return
	# Crew selection mode.
	if not crew.potential.is_empty() and not hud:
		var same := crew.potential.size() == sel.size() and crew.potential.all(func(c): return sel.has(c))
		if same:
			crew.deselect_all()  # tapping the selection again cancels it
			last_result = "cancel"
		else:
			crew.select_potential(false)
			last_result = "switch"
		return
	if hud:
		return
	var di := crew._door_at(screen)
	if di >= 0:
		crew.toggle_door(di)
		last_result = "door"
		return
	if room_at(screen).is_empty():
		crew.deselect_all()
		last_result = "cancel"
		return
	if crew.right_press(screen):
		crew.deselect_all()
		last_result = "move"
	else:
		last_result = "no_move"


## [ship, room] under a screen point (own ship first), or [].
func room_at(screen: Vector2) -> Array:
	for s: ShipState in crew.ships():
		var w: Variant = crew.locate(s, screen)
		if w == null:
			continue
		var r := s.room_at(w)
		if r >= 0:
			return [s, r]
	return []
