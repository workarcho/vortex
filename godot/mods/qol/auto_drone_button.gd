extends Control
## QoL mod: the AUTO toggle of the drone panel (drawn like the weapons panel's AUTOFIRE text button). Added to
## the DronePanel through the `hud_ready` hook; the state lives on the ShipState as meta `qol_drone_auto`.

const META := "qol_drone_auto"
const LABEL := "AUTO"

var ship: ShipState
var mod: Object  # the qol entry (set_auto)
var _hover := false


func setup(s: ShipState, entry: Object, holder_w: float) -> void:
	ship = s
	mod = entry
	var tw := FtlData.ftl_text_width(62, LABEL)
	position = Vector2(holder_w - 11 - tw, HudLayout.AUTOFIRE_Y)
	size = Vector2(tw, 24)
	mouse_filter = Control.MOUSE_FILTER_STOP
	tooltip_text = "Drone autodeploy (QoL): keep drones deployed and powered whenever possible."
	mouse_entered.connect(func(): _hover = true)
	mouse_exited.connect(func(): _hover = false)
	name = "QolDroneAuto"


func is_on() -> bool:
	return bool(ship.get_meta(META, false))


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		mod.set_auto(ship, not is_on())
		accept_event()


func _process(_d: float) -> void:
	visible = mod.button_enabled()
	queue_redraw()


func _draw() -> void:
	var w := size.x
	HudDraw.three_slice(self, "box_weapons_autofire_base.png", Vector2(-11, -10), w + 22, 17, 17)
	var c := FtlColors.YELLOW if is_on() else (Color.WHITE if _hover else HudLayout.BUTTON_ON)
	HudDraw.text(self, 62, LABEL, Vector2(0, 2), c)
