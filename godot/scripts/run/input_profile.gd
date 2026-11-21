class_name InputProfile
extends RefCounted
## Maps gestures to intents (rules/starmap.md §7, rules/events.md §6). The views report raw gestures
## (hover / press / release on a beacon or a choice, key presses); the profile decides which intents they
## mean and sends them to the run. Two profiles:
## - "pc": FTL PC. Map: hover over a reachable beacon selects it (potentialLoc), left click jumps at once.
##   Dialog: hover highlights, click applies the choice; keys 1–9 apply.
## - "touch": select then confirm (FTL's own OnTouch scheme). Map: tap a beacon = select (shown + JUMP button),
##   the JUMP button confirms. Dialog: tap = highlight, tap the highlighted choice again = apply; the first
##   0.3 s after a box opens ignore taps (fingers land where the previous screen's button was).
##   Combat taps (tap = click, selection mode with auto-pause + CANCEL, PAUSE button) are in TouchGestures
##   / TouchCombatButtons (scripts/ui/touch_gestures.gd; rules/ui_layout_strategy.md "Touch gestures (combat)").

const PC := "pc"
const TOUCH := "touch"
const TOUCH_GUARD := 0.3  # s

var mode := PC
var run: RunState
var dialog_opened_at := 0.0  # Time.get_ticks_msec()/1000 when the current box opened


func _init(m := PC) -> void:
	mode = m if m in [PC, TOUCH] else PC


func is_touch() -> bool:
	return mode == TOUCH


func _send(type: String, arg := -1) -> bool:
	return run != null and run.apply(RunIntent.make(type, arg))


# ------------------------------------------------------------------ beacon map

func beacon_hover(id: int) -> void:
	if mode == PC:
		_send(RunIntent.SELECT_BEACON, id)


func beacon_click(id: int) -> void:
	if mode == PC:
		if _send(RunIntent.SELECT_BEACON, id):
			_send(RunIntent.CONFIRM_JUMP)
	else:
		_send(RunIntent.SELECT_BEACON, id)


## The touch map JUMP button (StarMapView: TouchCombatButtons look, lit while a beacon is selected); touch only.
func jump_button() -> void:
	_send(RunIntent.CONFIRM_JUMP)


func close_map() -> void:
	_send(RunIntent.CLOSE_MAP)


func ftl_button() -> void:
	_send(RunIntent.OPEN_MAP)


func next_sector() -> void:
	_send(RunIntent.NEXT_SECTOR)


func wait_button() -> void:
	_send(RunIntent.WAIT)


func distress_button() -> void:
	_send(RunIntent.TOGGLE_DISTRESS)


# ------------------------------------------------------------------ sector map (choice mode)

## PC: hover a neighbouring sector = potential, click = go at once (keys 1 / 2 too). Touch: tap selects, the
## JUMP button confirms.
func sector_hover(id: int) -> void:
	if mode == PC:
		_send(RunIntent.SELECT_SECTOR, id)


func sector_click(id: int) -> void:
	if mode == PC:
		if _send(RunIntent.SELECT_SECTOR, id):
			_send(RunIntent.CONFIRM_SECTOR)
	else:
		_send(RunIntent.SELECT_SECTOR, id)


func sector_key(i: int) -> void:
	var n: Array = run.tree.neighbours(run.sector_id) if run != null else []
	if i >= 0 and i < n.size() and _send(RunIntent.SELECT_SECTOR, n[i]):
		_send(RunIntent.CONFIRM_SECTOR)


func sector_jump_button() -> void:
	_send(RunIntent.CONFIRM_SECTOR)


func close_sector_map() -> void:
	_send(RunIntent.CLOSE_SECTOR_MAP)


# ------------------------------------------------------------------ store (rules/store.md §6)

## PC: a click on an active box buys at once (hover shows the info). Touch (the exe's iPad path): tap selects
## (info box), a second tap on the selected box buys (the store view has no BUY button; `store_buy_button` stays for
## scripts); inactive boxes can be selected too so the info box shows why (improvement over the exe).
func store_hover(code: int) -> void:
	if mode == PC and run != null and run.store_open:
		run.store_selected = code


func store_click(code: int) -> void:
	if mode == PC or (run != null and run.store_selected == code):
		_send(RunIntent.STORE_BUY, code)
	else:
		_send(RunIntent.STORE_SELECT, code)


func store_buy_button() -> void:
	if run != null and run.store_selected >= 0:
		_send(RunIntent.STORE_BUY, run.store_selected)


func store_close() -> void:
	_send(RunIntent.CLOSE_STORE)


func store_open() -> void:
	_send(RunIntent.OPEN_STORE)


func store_confirm(yes: bool) -> void:
	_send(RunIntent.STORE_CONFIRM, 1 if yes else 0)


func store_page(p: int) -> void:
	_send(RunIntent.STORE_PAGE, p)


func store_tab(t: int) -> void:
	_send(RunIntent.STORE_TAB, t)


## Sell tab: PC click on an item sells it; touch: tap selects, SELL button (or a second tap) sells.
func sell_click(i: int) -> void:
	if mode == PC or (run != null and run.store_selected == 200 + i):
		_send(RunIntent.STORE_SELL, i)
	else:
		_send(RunIntent.STORE_SELECT, 200 + i)


# ------------------------------------------------------------------ event dialog

func dialog_opened() -> void:
	dialog_opened_at = Time.get_ticks_msec() / 1000.0


func _guarded() -> bool:
	return mode == TOUCH and Time.get_ticks_msec() / 1000.0 - dialog_opened_at < TOUCH_GUARD


func choice_hover(i: int) -> void:
	if mode == PC:
		_send(RunIntent.HIGHLIGHT_CHOICE, i)


func choice_click(i: int) -> void:
	if _guarded():
		return
	if mode == PC or run.highlighted == i:
		_send(RunIntent.CHOOSE, i)
	else:
		_send(RunIntent.HIGHLIGHT_CHOICE, i)


## Keys 1–9 (both profiles).
func choice_key(i: int) -> void:
	_send(RunIntent.CHOOSE, i)


func message_continue() -> void:
	if not _guarded():
		_send(RunIntent.CONTINUE)


# ------------------------------------------------------------------ title: main menu + hangar (rules/main_menu.md)
# PC: a button acts on mouse press (CApp::OnLButtonDown → MouseClick), hover lights it and beeps. Touch: a button
# acts when the finger lifts on it (GenericButton::OnTouch → bActivated on TOUCH_UP); no hover. Touch only: a drag
# over the hangar ship swipes ships (horizontal) or layouts (vertical) once it passes 10 px (ShipBuilder::OnTouch).

const SWIPE_MIN := 10.0  # px (distance² > 100)

var title: TitleState


func _send_title(intent: Dictionary) -> bool:
	return title != null and title.apply(intent)


func title_press(intent: Dictionary) -> bool:
	return _send_title(intent) if mode == PC else false


func title_release(intent: Dictionary) -> bool:
	return _send_title(intent) if mode == TOUCH else false


## Touch drag over the hangar ship; `d` = release − press. Horizontal → next / previous ship, vertical → layout.
func hangar_swipe(d: Vector2) -> bool:
	if mode != TOUCH or title == null or d.length() <= SWIPE_MIN:
		return false
	if absf(d.x) >= absf(d.y):
		return _send_title(TitleState.make(TitleState.PREV_SHIP if d.x > 0 else TitleState.NEXT_SHIP))
	for k in [1, 2]:
		var t := posmod(title.ship_type + (k if d.y < 0 else -k), 3)
		if _send_title(TitleState.make(TitleState.SET_TYPE, t)):
			return true
	return false


## ShipBuilder::OnKeyDown (both profiles): Right / Left cycle ships, Up / Down cycle unlocked layouts, Esc = back.
func hangar_key(keycode: int) -> bool:
	if title == null:
		return false
	match keycode:
		KEY_RIGHT:
			return _send_title(TitleState.make(TitleState.NEXT_SHIP))
		KEY_LEFT:
			return _send_title(TitleState.make(TitleState.PREV_SHIP))
		KEY_UP, KEY_DOWN:
			var step := 1 if keycode == KEY_UP else -1
			for k in [1, 2]:
				if _send_title(TitleState.make(TitleState.SET_TYPE, posmod(title.ship_type + step * k, 3))):
					return true
			return false
		KEY_ESCAPE:
			return _send_title(TitleState.make(TitleState.HANGAR_BACK))
	return false
