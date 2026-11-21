class_name CrewControl
extends RefCounted
## Player crew selection, move orders, crew list and stations (rules/crew_controls.md: CrewControl,
## CrewBox, ShipManager::Save/RestoreCrewPositions). UI-agnostic: screen positions in, state out.
##
## The UI provides two callables:
##   to_world(ship, screen: Vector2) -> Vector2   screen point in that ship's coordinates
##   view_rect(ship) -> Rect2                      screen rect showing that ship (empty when hidden)
## Distances are compared squared, like Point::RelativeDistance.

const DRAG_DRAW := 50  # dist² from the press point: the white drag rectangle is drawn
const DRAG_SELECT := 82  # dist²: the drag rectangle replaces the potential set
const DOOR_CLICK := 49  # dist² below which a release over a hovered door toggles it
const CREW_HALF := 17.0  # hover hit box: int(35 + 0.5) / 2 * 2 = 34 px square
const BOX_HALF := 17.5  # 35×35 crew box intersected by the drag rectangle
const BOX_ORIGIN := Vector2(10, 155)  # crew list (CrewBox), 1280×720 frame
const BOX_SIZE := Vector2(86, 27)
const BOX_STEP := 30.0
const BUTTON_SIZE := Vector2(20, 20)
const MESSAGE_TIME := 3.0  # crewMessage tracker length unknown [inferred]

var player: ShipState
var enemy: ShipState
var to_world: Callable
var view_rect: Callable

var roster: Array[CrewMember] = []  # crew list order (GetCrewPortraitList), stable across ships
var potential: Array = []  # potentialSelectedCrew
var mouse_down := false
var first_mouse := Vector2.ZERO
var current_mouse := Vector2.ZERO
var hovered_door := -1  # door of the player ship under the pointer (only with nobody selected)
var hovered_box := -1  # crew list entry under the pointer
var hovered_button := -1  # 0 = save stations, 1 = return to stations
var power_box := -1  # crew box whose skill shape (and LOCKDOWN button) is shown
var hover_ship: ShipState = null  # ship / room under the pointer (own ship first)
var hover_room := -1
var highlight_cleared := false  # right click hides the room highlight until the next move
var frozen := false  # a weapon / drone box is being dragged: hover and drag selection frozen
var message := ""
var message_time := 0.0


func _init(p: ShipState, e: ShipState, world_fn: Callable, rect_fn: Callable) -> void:
	player = p
	enemy = e
	to_world = world_fn
	view_rect = rect_fn
	update_roster()


func ships() -> Array:
	return [player, enemy] if enemy else [player]


## SelectPotentialCrew filter: the player's crew, alive, not mind controlled. Crew drones are not crew.
static func controllable(c: CrewMember) -> bool:
	return c.player_owned and c.is_alive() and not c.is_drone() and not c.mind_controlled


## Keeps the crew list: the player's crew on both ships in a stable order; dead crew stay until their
## ship drops them (or while the clonebay queue holds them); crew in teleport transit are kept.
func update_roster() -> void:
	var present := []
	for s: ShipState in ships():
		for c: CrewMember in s.crew:
			if c.player_owned and not c.is_drone():
				present.append(c)
	var kept: Array[CrewMember] = []
	for c in roster:
		if present.has(c) or c.is_alive() or player.clone_queue.has(c):
			kept.append(c)
	for c in present:
		if not kept.has(c):
			kept.append(c)
	roster = kept


func selected_crew() -> Array:
	return roster.filter(func(c): return c.selected and c.is_alive())


func ship_of(c: CrewMember) -> ShipState:
	for s: ShipState in ships():
		if s.crew.has(c):
			return s
	return null


# ------------------------------------------------------------------ geometry
# Crew list geometry (box_rect, button_rect, power_button_rect, CrewList.skill_rect) is in the crew list's own
# coordinates (the 1280×720 frame on PC). `list_xf` maps them to the screen: the CrewList keeps it equal to its
# canvas transform (touch UI: ×1.2 and moved up), so every *_at(screen) test hits what is drawn.
var list_xf := Transform2D.IDENTITY
## Touch UI: the save / return stations buttons stacked in a doors-style box whose image top-left is here (list
## coordinates; buttons at (10, 10) / (10, 33)); null = under the last crew box (PC).
var button_box: Variant = null
## Touch UI with an enemy: the two stations buttons as free rects (list coordinates), enlarged in the TARGET
## window's bottom-right corner (main.gd `_touch_station_rects`); wins over `button_box` when set.
var button_rects: Array = []


## Screen point -> crew list coordinates.
func to_list(screen: Vector2) -> Vector2:
	return list_xf.affine_inverse() * screen


func box_rect(i: int) -> Rect2:
	return Rect2(BOX_ORIGIN + Vector2(0, BOX_STEP * i), BOX_SIZE)


## Save (0) / return (1) stations buttons, under the last crew box (touch: in `button_box`).
func button_rect(k: int) -> Rect2:
	if button_rects.size() == 2:
		return button_rects[k]
	if button_box != null:
		return Rect2((button_box as Vector2) + Vector2(10, 10 + 23 * k), BUTTON_SIZE)
	var last := box_rect(maxi(roster.size() - 1, 0))
	var x := last.position.x + (14.0 if k == 0 else 53.0)
	return Rect2(Vector2(x, last.end.y + 10), BUTTON_SIZE)


## The pointer is over the crew list UI as drawn: a crew box, a stations button or (touch) the buttons box's
## solid art (button_door_base.png x 6..33, y 6..72). main.gd `_over_hud_panel`.
func hud_hit(screen: Vector2) -> bool:
	if box_at(screen) >= 0 or button_at(screen) >= 0:
		return true
	return button_box != null and Rect2((button_box as Vector2) + Vector2(6, 6), Vector2(28, 67)).has_point(
		to_list(screen))


func box_at(screen: Vector2) -> int:
	var p := to_list(screen)
	for i in roster.size():
		if box_rect(i).has_point(p):
			return i
	return -1


func button_at(screen: Vector2) -> int:
	var p := to_list(screen)
	for k in 2:
		if button_rect(k).has_point(p):
			return k
	return -1


## World point of `screen` on `ship`, or null when the point is outside that ship's view.
func locate(ship: ShipState, screen: Vector2) -> Variant:
	if ship == null:
		return null
	var r: Rect2 = view_rect.call(ship)
	if not r.has_point(screen):
		return null
	return to_world.call(ship, screen)


## Nearest controllable crew whose 34 px hit box contains the world point (CrewMember::ContainsPoint).
func crew_under(ship: ShipState, w: Vector2) -> CrewMember:
	var best: CrewMember = null
	var best_d := INF
	for c in ship.crew:
		if not controllable(c):
			continue
		var d := c.pos - w
		if absf(d.x) <= CREW_HALF and absf(d.y) <= CREW_HALF and d.length_squared() < best_d:
			best = c
			best_d = d.length_squared()
	return best


func _dist2() -> float:
	return first_mouse.distance_squared_to(current_mouse)


## Screen rectangle of the drag (empty when no drag rectangle is shown).
func drag_rect() -> Rect2:
	if not mouse_down or frozen or _dist2() < DRAG_DRAW:
		return Rect2()
	return Rect2(first_mouse, current_mouse - first_mouse).abs()


## [ship, room] to outline as the move destination, or [] (rules/crew_controls.md "Room hover outline").
func move_highlight() -> Array:
	if mouse_down or highlight_cleared or hovered_door >= 0 or hover_room < 0 or selected_crew().is_empty():
		return []
	return [hover_ship, hover_room]


# ------------------------------------------------------------------ mouse

## CrewControl::MouseMove. `armed` = a weapon / teleporter is armed (WeaponsArmed): no crew hover.
func pointer_moved(screen: Vector2, armed := false) -> void:
	current_mouse = screen
	highlight_cleared = false
	_update_hover_room(screen)
	hovered_button = button_at(screen)
	var bi := box_at(screen)
	if bi >= 0:
		power_box = bi
	elif power_box < 0 or power_box >= roster.size() \
			or not CrewList.skill_rect(box_rect(power_box), roster[power_box].has_power()).has_point(to_list(screen)):
		power_box = -1
	if frozen or armed:
		return
	potential.clear()
	hovered_door = -1
	hovered_box = box_at(screen)
	if mouse_down and _dist2() >= DRAG_SELECT:
		_drag_select()
	else:
		if hovered_box >= 0 and controllable(roster[hovered_box]):
			potential.append(roster[hovered_box])
		for s: ShipState in ships():
			var w: Variant = locate(s, screen)
			if w != null:
				var c := crew_under(s, w)
				if c and not potential.has(c):
					potential.append(c)
	if selected_crew().is_empty():
		hovered_door = _door_at(screen)
	_apply_hover()


func _update_hover_room(screen: Vector2) -> void:
	hover_ship = null
	hover_room = -1
	for s: ShipState in ships():
		if s != player and s.is_destroyed():
			continue  # CombatControl::UpdateTarget: no selectedRoom on a dying target
		var w: Variant = locate(s, screen)
		if w == null:
			continue
		var r := s.room_at(w)
		if r >= 0:
			hover_ship = s
			hover_room = r
			return


## Player-ship door under the pointer; hacked doors are never hover-detected.
func _door_at(screen: Vector2) -> int:
	var w: Variant = locate(player, screen)
	if w == null:
		return -1
	var ds := player.sys("doors")
	if ds and ds.hacked:
		return -1
	var di := ShipView.door_index_at(player, w)
	if di >= 0 and int(player.env.doors[di].get("hacked", 0)) > 0:
		return -1
	return di


func _drag_select() -> void:
	var rect := Rect2(first_mouse, current_mouse - first_mouse).abs()
	for s: ShipState in ships():
		var vr: Rect2 = view_rect.call(s)
		if not rect.intersects(vr):
			continue
		var clip := rect.intersection(vr)
		var a: Vector2 = to_world.call(s, clip.position)
		var b: Vector2 = to_world.call(s, clip.end)
		var wr := Rect2(a, b - a).abs()
		for c: CrewMember in s.crew:
			if controllable(c) and wr.intersects(Rect2(c.pos - Vector2(BOX_HALF, BOX_HALF), Vector2(35, 35))):
				potential.append(c)
	for i in roster.size():
		if rect.intersects(list_xf * box_rect(i)) and controllable(roster[i]) and not potential.has(roster[i]):
			potential.append(roster[i])


func _apply_hover() -> void:
	for s: ShipState in ships():
		for c: CrewMember in s.crew:
			c.hovered = potential.has(c)
	for c in roster:
		c.hovered = potential.has(c)


## CrewControl::LButton (+ the stations buttons). Returns true if the press hit the crew list UI.
func left_press(screen: Vector2, _shift := false, armed := false) -> bool:
	if armed:
		return false
	current_mouse = screen
	var b := button_at(screen)
	if b == 0:
		save_stations()
	elif b == 1:
		return_stations()
	mouse_down = true
	first_mouse = screen
	return b >= 0 or box_at(screen) >= 0 or power_button_at(screen) >= 0


## CrewControl::LButtonUp: door toggle (short click on a hovered door), else SelectCrew(shift).
func left_release(screen: Vector2, shift := false) -> void:
	if not mouse_down:
		return
	current_mouse = screen
	mouse_down = false
	if _dist2() < DOOR_CLICK and hovered_door >= 0:
		toggle_door(hovered_door)
		return
	var pb := power_button_at(screen)
	if pb >= 0:
		activate_power(roster[pb])  # CrewBox LOCKDOWN button
		return
	select_potential(shift)


## SelectCrew(keep_current): without shift the selection is replaced by the potential set (empty floor =
## deselect everyone); with shift the potential set is added.
func select_potential(keep := false) -> void:
	if not keep:
		deselect_all()
	for c in potential:
		if controllable(c):
			c.selected = true


## Controllable crew under a screen point: its crew-list box first, else the nearest crew sprite on either ship
## (the hover rule of `pointer_moved`). Null when none.
func crew_at(screen: Vector2) -> CrewMember:
	var bi := box_at(screen)
	if bi >= 0:
		return roster[bi] if controllable(roster[bi]) else null
	for s: ShipState in ships():
		var w: Variant = locate(s, screen)
		if w != null:
			var c := crew_under(s, w)
			if c:
				return c
	return null


## Touch multi-select [ours] (TouchGestures: held finger / Ctrl + tap): `c` in or out of the selection.
func toggle_selected(c: CrewMember) -> void:
	if c != null and controllable(c):
		c.selected = not c.selected


func deselect_all() -> void:
	for c in roster:
		c.selected = false
	for s: ShipState in ships():
		for c: CrewMember in s.crew:
			c.selected = false


## CrewControl::RButton (only when nothing was armed): hovered door (nobody selected) = toggle; else the
## selected crew aboard the ship under the pointer walk to the room. Returns true if something happened.
func right_press(screen: Vector2) -> bool:
	highlight_cleared = true
	var sel := selected_crew()
	if sel.is_empty():
		var d := _door_at(screen)
		if d >= 0:
			toggle_door(d)
			return true
		return false
	_update_hover_room(screen)
	if hover_room < 0:
		return false
	var members := sel.filter(func(c): return hover_ship.crew.has(c))
	return hover_ship.order_crew_move(members, hover_room) > 0


## Door::Manipulate: needs a working doors system (ShipManager::DoorsFunction).
func toggle_door(di: int) -> bool:
	if not player.doors_function():
		return false
	var d: Dictionary = player.env.doors[di]
	player.env.set_door(di, not d.open)
	player.env.update_door_sounds()  # doorOpen / doorClose when the shown state changes (Door::Manipulate)
	return true


# ------------------------------------------------------------------ keys

## CrewControl::KeyDown: F1–F8 (Shift toggles), Q all, '/' save stations, Enter return to stations.
func hotkey(keycode: int, shift := false) -> bool:
	if keycode >= KEY_F1 and keycode <= KEY_F8:
		var i := keycode - KEY_F1
		if i >= roster.size() or not controllable(roster[i]):
			return true
		if shift:
			roster[i].selected = not roster[i].selected
		else:
			deselect_all()
			roster[i].selected = true
		return true
	match keycode:
		KEY_Q:
			for c in roster:
				c.selected = controllable(c)
			return true
		KEY_SLASH, KEY_KP_DIVIDE:
			save_stations()
			return true
		KEY_ENTER, KEY_KP_ENTER:
			return_stations()
			return true
		KEY_P:  # `lockdown`: every selected crew whose power is ready activates it
			for c in selected_crew():
				activate_power(c)
			return true
	return false


# ------------------------------------------------------------------ special power (crystal lockdown)

const POWER_BUTTON := Vector2(64, 14)  # LOCKDOWN button at (box.x + w + 11, box.y + 7), shown on hover


## LOCKDOWN button of crew box i (only meaningful for crew with a power).
func power_button_rect(i: int) -> Rect2:
	var r := box_rect(i)
	return Rect2(r.position + Vector2(r.size.x + 11, 7), POWER_BUTTON)


## Crew box whose LOCKDOWN button is under the pointer (its skill shape is shown), or -1.
func power_button_at(screen: Vector2) -> int:
	if power_box >= 0 and power_box < roster.size() and roster[power_box].has_power() \
			and power_button_rect(power_box).has_point(to_list(screen)):
		return power_box
	return -1


## CrewMember::ActivatePower on the ship the crew stands on (CrewBox click / P).
func activate_power(c: CrewMember) -> bool:
	if not controllable(c) or not c.power_ready():
		return false
	var s := ship_of(c)
	return s != null and c.activate_power(s)


# ------------------------------------------------------------------ stations

func save_stations() -> void:
	var elsewhere := []
	if enemy:
		elsewhere = enemy.crew.filter(func(c): return controllable(c))
	player.save_crew_positions(elsewhere)
	_message("stations_saved", "Stations Saved!")


func return_stations() -> void:
	if player.restore_crew_positions():
		_message("return_stations", "Return to Stations!")
	else:
		_message("no_stations", "No Stations Saved!")


func _message(id: String, fallback: String) -> void:
	var t := FtlData.tr_id(id)
	message = fallback if t == id else t
	message_time = MESSAGE_TIME


func tick(delta: float) -> void:
	if message_time > 0.0:
		message_time = maxf(message_time - delta, 0.0)
	update_roster()
	for c in roster:
		if not c.is_alive() or c.mind_controlled:  # mind-controlled crew leave the selection
			c.selected = false
			c.hovered = false
