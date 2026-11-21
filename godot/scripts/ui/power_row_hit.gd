class_name PowerRowHit
extends Control
## Touch column power row hit area (WeaponPanel / DronePanel `vertical`): covers the drawn row (symbol glyph +
## upright bars) in the panel's local coordinates, so it follows the panel's scale / position like the slots.
## Tap (on the lift) = `on_up` (power the next item; the panels route it through TouchPowerToggle: − mode = depower
## the last one), right click = `on_down` (depower the last one) [ours: the row stands in for the PC weapons / drones
## system box]; a long press only shows the system tooltip (SystemBox, W300), it never depowers.

var ship: ShipState
var system_id := "weapons"
var on_up: Callable
var on_down: Callable
var _press_time := -1.0
var hovered := false


func setup(s: ShipState, sys_id: String, rect: Rect2, up: Callable, down: Callable) -> void:
	ship = s
	system_id = sys_id
	position = rect.position
	size = rect.size
	on_up = up
	on_down = down
	mouse_filter = Control.MOUSE_FILTER_STOP


func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null:
		return
	if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
		on_down.call()
		accept_event()
	elif mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			_press_time = 0.0
		elif _press_time >= 0.0:
			_press_time = -1.0
			if Rect2(Vector2.ZERO, size).has_point(mb.position):
				on_up.call()  # on release, like the slots
		accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_ENTER:
		hovered = true
	elif what == NOTIFICATION_MOUSE_EXIT:
		hovered = false


## A second finger tapped while this one was held (TouchGestures): its lift does nothing.
func cancel_press() -> void:
	_press_time = -1.0


func _process(_delta: float) -> void:
	if ship != null and ship.sys(system_id) != null and TooltipService.over(self, Rect2(Vector2.ZERO, size)):
		TooltipService.request(TooltipText.system(ship, system_id), {"width": TooltipService.WRAP_BOX,
			"kind": &"system", "source": self, "ctx": {"ship": ship, "system": system_id}})
