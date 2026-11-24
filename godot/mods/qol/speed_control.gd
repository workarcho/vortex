extends Control
## QoL mod "Game speed": the − [1.25x] + control under the scrap counter. A child of the ShipStatusHud (added
## through the `hud_ready` hook), so it follows that block's touch scale; placed under the scrap box, or under the
## evade / O2 box when the touch layout moves that box there (ShipStatusHud.evade_offset). Clicks / taps reach it
## through the `input_event` filter (main.gd handles the pointer before the GUI): `hit()` tests the pointer in this
## node's local coordinates. Every frame it applies the chosen speed while the world runs (qol.apply_speed).

const PC_POS := Vector2(406, 50)  # under top_scrap.png (377, 0, 135×55), centred on the scrap count
const BTN_PC := Vector2(20, 20)
const BTN_TOUCH := Vector2(30, 30)
const LABEL_W := 54.0
const GAP := 4.0  # below the moved evade / O2 box (touch)

var mod: Object  # the qol entry
var main: Node  # main.gd (combat, run, input_mode)
var status: Control  # ShipStatusHud (evade_offset)
var touch := false
var _hover := 0  # -1 minus, 1 plus, 0 none
var _pressed := false  # the press was ours: its release is consumed too


func setup(entry: Object, main_node: Node, status_hud: Control) -> void:
	mod = entry
	main = main_node
	status = status_hud
	touch = main != null and String(main.get("input_mode")) == InputProfile.TOUCH
	name = "QolGameSpeed"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layout()


func _btn() -> Vector2:
	return BTN_TOUCH if touch else BTN_PC


func _layout() -> void:
	var b := _btn()
	size = Vector2(b.x * 2 + LABEL_W, b.y)
	var off: Vector2 = status.get("evade_offset") if status != null else Vector2.ZERO
	if off == Vector2.ZERO:
		position = PC_POS + Vector2((BTN_PC.x * 2 + LABEL_W - size.x) / 2, 0)
	else:  # touch: the evade / O2 box (104×56 at EVADE_BOX) now sits under the scrap box
		var ev := HudLayout.EVADE_BOX + off
		position = Vector2(ev.x + (104 - size.x) / 2, ev.y + 56 + GAP)


func minus_rect() -> Rect2:
	return Rect2(Vector2.ZERO, _btn())


func plus_rect() -> Rect2:
	return Rect2(Vector2(size.x - _btn().x, 0), _btn())


## -1 / 1 for the − / + button under a point in this node's local coordinates, else 0.
func button_at(p: Vector2) -> int:
	if minus_rect().has_point(p):
		return -1
	if plus_rect().has_point(p):
		return 1
	return 0


## The pointer event `e` (viewport coordinates, as main.gd gets it) in local coordinates.
func local_point(e: InputEvent) -> Vector2:
	return (make_input_local(e) as InputEventMouse).position


func _world_running() -> bool:
	if main == null:
		return false
	var c: Variant = main.get("combat")
	var r: Variant = main.get("run")
	if c == null or c.paused:
		return false
	return r == null or not r.modal()


func _modal() -> bool:
	var r: Variant = main.get("run") if main != null else null
	return r != null and r.modal()


## input_event filter (qol.gd): true when the event was this control's (consumed).
func handle(e: InputEvent) -> bool:
	if not is_visible_in_tree() or _modal():
		return false
	if e is InputEventMouseMotion:
		_hover = button_at(local_point(e))
		return false
	if not (e is InputEventMouseButton) or (e as InputEventMouseButton).button_index != MOUSE_BUTTON_LEFT:
		return false
	var mb := e as InputEventMouseButton
	var b := button_at(local_point(e))
	if mb.pressed:
		if b == 0:
			return false
		_pressed = true
		if mod.speed_step(b):
			FtlData.play("powerUpSystem" if b > 0 else "powerDownSystem")
		queue_redraw()
		return true
	if _pressed:
		_pressed = false
		return true
	return false


func _process(_d: float) -> void:
	visible = mod.speed_buttons_enabled()
	mod.apply_speed(_world_running())
	_layout()
	queue_redraw()


func _exit_tree() -> void:
	if mod != null:
		mod.restore_speed()


func _draw() -> void:
	var b := _btn()
	var dark := Color(0, 0, 0, 0.6)
	var idx: int = mod.speed_index
	for d in [-1, 1]:
		var r := minus_rect() if d < 0 else plus_rect()
		var can: bool = idx + d >= 0 and idx + d < mod.SPEED_STEPS.size()
		var c := HudLayout.BUTTON_OFF if not can else (Color.WHITE if _hover == d else HudLayout.BUTTON_ON)
		draw_rect(r, dark)
		draw_rect(r.grow(-1), c, false, 2.0)
		var mid := r.get_center()
		var arm := b.x * 0.25
		draw_line(mid - Vector2(arm, 0), mid + Vector2(arm, 0), c, 2.0)
		if d > 0:
			draw_line(mid - Vector2(0, arm), mid + Vector2(0, arm), c, 2.0)
	var lr := Rect2(Vector2(b.x, 0), Vector2(LABEL_W, b.y))
	draw_rect(lr, dark)
	var col := HudLayout.RESOURCE_TEXT if is_equal_approx(mod.speed(), 1.0) else FtlColors.YELLOW
	HudDraw.text(self, 62, mod.speed_label(mod.speed()), Vector2(lr.get_center().x, b.y / 2 - 8), col, 1)
