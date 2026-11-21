class_name ProfileView
extends Control
## [ours] Profile picker of the title screen (ProfileSlots; vanilla has a single profile): a corner button at the
## top left of the main menu ("PROFILE n"; the unlock share only inside the window) opens a window with the three slots. Each slot shows its ship unlock
## share, achievements and whether it has a saved run, with SELECT, UNLOCK ALL and DELETE (both confirmed in a
## ConfirmWindow). Drawn in frame coordinates (1280x720); hit tests in local coordinates.

const CORNER_AT := Vector2(14, 12)  # top-left corner button; width = label + 28
const CORNER_H := 30.0
const PANEL := Rect2(330, 120, 620, 440)
const ROW_H := 118.0
const ROW_BOX_H := 108.0
const BTN_W := 160.0
const BTN_H := 28.0

var title: TitleState
var menu: Control  # the main menu: the corner button shows with it
var opened := false
var buttons := {}  # name -> {rect, label, font, state}
var hot := ""
var _pressed := ""
var confirm: ConfirmWindow
var _confirm_action := ""  # "unlock:<i>" / "delete:<i>"
var _cache := {}  # slot -> {pct, ach, ach_total, run, used}


func setup(t: TitleState, menu_view: Control) -> void:
	title = t
	menu = menu_view
	position = Vector2.ZERO
	size = HudLayout.FRAME
	mouse_filter = Control.MOUSE_FILTER_STOP
	confirm = ConfirmWindow.new("profile_unlock_confirm", 420)
	confirm.yes_id = "button_confirm"
	confirm.no_id = "button_cancel"
	confirm.visible = false
	add_child(confirm)
	confirm.answered.connect(_on_confirm)
	refresh()


func refresh() -> void:
	_cache.clear()
	var achs := MenuDraw.achievements()
	for i in ProfileSlots.COUNT:
		var p := ProfileSlots.profile_of(i)
		var n := 0
		for a in achs:
			if p.has_achievement(String(a.id)):
				n += 1
		_cache[i] = {"pct": p.unlock_percent(), "ach": n, "ach_total": achs.size(), "run": ProfileSlots.has_run(i),
			"used": ProfileSlots.used(i)}
	_build_buttons()
	queue_redraw()


func row_rect(i: int) -> Rect2:
	return Rect2(PANEL.position.x + 12, PANEL.position.y + 12 + i * ROW_H, PANEL.size.x - 24, ROW_BOX_H)


func _build_buttons() -> void:
	buttons.clear()
	if not opened:
		var a := ProfileSlots.active
		var label := FtlData.tr_id("profile_button").replace("\\1", str(a + 1)).replace("\\2", str(_cache[a].pct))
		buttons["corner"] = {"rect": Rect2(CORNER_AT, Vector2(FtlData.ftl_text_width(62, label) + 28, CORNER_H)),
			"font": 62, "label": label}
		return
	for i in ProfileSlots.COUNT:
		var r := row_rect(i)
		var x := r.end.x - BTN_W - 10
		var y := r.position.y + (ROW_BOX_H - 3 * BTN_H - 2 * 7) / 2.0
		var act := i == ProfileSlots.active
		var c: Dictionary = _cache[i]
		buttons["select:%d" % i] = {"rect": Rect2(x, y, BTN_W, BTN_H), "font": 62,
			"label": FtlData.tr_id("profile_active" if act else "profile_select"), "state": "selected" if act else "on"}
		buttons["unlock:%d" % i] = {"rect": Rect2(x, y + BTN_H + 7, BTN_W, BTN_H), "font": 62,
			"label": FtlData.tr_id("profile_unlock_all"), "state": "off" if int(c.pct) >= 100 else "on"}
		buttons["delete:%d" % i] = {"rect": Rect2(x, y + 2 * (BTN_H + 7), BTN_W, BTN_H), "font": 62,
			"label": FtlData.tr_id("profile_delete"), "state": "on" if c.used or c.run else "off"}
	buttons["close"] = {"rect": Rect2(PANEL.get_center().x - 70, PANEL.end.y - 44, 140, BTN_H), "font": 62,
		"label": FtlData.tr_id("profile_close")}


func _process(_d: float) -> void:
	var show := menu != null and menu.visible
	if visible != show:
		visible = show
		if not show and opened:
			_close()
	if visible:
		queue_redraw()


## Only the corner button catches the pointer while the window is closed; open, the whole frame does.
func _has_point(p: Vector2) -> bool:
	return opened or (buttons.has("corner") and (buttons["corner"].rect as Rect2).has_point(p))


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		var h := MenuDraw.button_at(buttons, e.position) if not TooltipService.touch else ""
		if h != hot and h != "" and String(buttons[h].get("state", "on")) != "off":
			FtlData.play("hoverBeep")
		hot = h
		accept_event()
	elif e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed:
			press(e.position)
		else:
			release(e.position)
		accept_event()


func _unhandled_key_input(e: InputEvent) -> void:
	if visible and opened and e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE:
		if confirm.visible:
			confirm.visible = false
		else:
			_close()
		get_viewport().set_input_as_handled()


func press(p: Vector2) -> void:
	if confirm.visible:
		confirm.click(p)
		_pressed = ""
		return
	_pressed = MenuDraw.button_at(buttons, p)


func release(p: Vector2) -> void:
	var b := MenuDraw.button_at(buttons, p)
	if b != "" and b == _pressed and String(buttons[b].get("state", "on")) != "off":
		activate(b)
	_pressed = ""


## A button's action (tests call it directly).
func activate(b: String) -> void:
	if b == "corner":
		opened = true
		refresh()
	elif b == "close":
		_close()
	elif b.begins_with("select:"):
		ProfileSlots.select(b.get_slice(":", 1).to_int())
		refresh()
	elif b.begins_with("unlock:") or b.begins_with("delete:"):
		_confirm_action = b
		confirm.text_id = "profile_unlock_confirm" if b.begins_with("unlock:") else "profile_delete_confirm"
		confirm.visible = true


func _on_confirm(yes: bool) -> void:
	confirm.visible = false
	if not yes:
		return
	var i := _confirm_action.get_slice(":", 1).to_int()
	if _confirm_action.begins_with("unlock:"):
		ProfileSlots.unlock_all(i)
	else:
		ProfileSlots.wipe(i)
	refresh()


func _close() -> void:
	opened = false
	confirm.visible = false
	hot = ""
	refresh()


func _draw() -> void:
	if not opened:
		if buttons.has("corner"):
			MenuDraw.text_button(self, buttons["corner"], hot == "corner")
		return
	draw_rect(Rect2(Vector2.ZERO, HudLayout.FRAME), Color(0, 0, 0, 0.6))
	MenuDraw.options_frame(self, PANEL, FtlData.tr_id("profiles_title"))
	for i in ProfileSlots.COUNT:
		var r := row_rect(i)
		var act := i == ProfileSlots.active
		draw_rect(r, Color(0, 0, 0, 0.45))
		draw_rect(r, MenuDraw.COL_SELECT if act else Color(1, 1, 1, 0.35), false, 2.0 if act else 1.0)
		var c: Dictionary = _cache[i]
		var x := r.position.x + 14
		FtlData.draw_ftl_text(self, 24, FtlData.tr_id("profile_name").replace("\\1", str(i + 1)),
			Vector2(x, r.position.y + 8), MenuDraw.COL_SELECT if act else Color.WHITE)
		if not c.used and not c.run:
			FtlData.draw_ftl_text(self, 14, FtlData.tr_id("profile_empty"), Vector2(x, r.position.y + 44),
				Color(1, 1, 1, 0.6))
			continue
		FtlData.draw_ftl_text(self, 14, FtlData.tr_id("profile_unlocked").replace("\\1", str(c.pct)),
			Vector2(x, r.position.y + 40), Color.WHITE)
		FtlData.draw_ftl_text(self, 14, FtlData.tr_id("profile_achievements").replace("\\1", str(c.ach))
			.replace("\\2", str(c.ach_total)), Vector2(x, r.position.y + 60), Color.WHITE)
		if c.run:
			FtlData.draw_ftl_text(self, 14, FtlData.tr_id("profile_saved_run"), Vector2(x, r.position.y + 80),
				MenuDraw.COL_SELECT)
	for nm in buttons:
		MenuDraw.text_button(self, buttons[nm], hot == nm and not confirm.visible)
	if confirm.visible:  # the confirm window (a child) draws over this dim
		draw_rect(Rect2(Vector2.ZERO, HudLayout.FRAME), Color(0, 0, 0, 0.5))
