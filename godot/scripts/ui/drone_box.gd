class_name DroneBox
extends Control
## One drone slot (FTL DroneBox / ArmamentBox, 95×39, box offset 0, name at (26, 3), no wrap): power bars up
## from (4, 28), short name in font 7, `ui_icons/icon_drones.png` at (34, 10) while deployed, red rebuild overlay
## (DroneBox::RenderBox, rules/hud_layout.md "Weapon box details"). Same frame as WeaponBox. Click = power /
## deploy, right click = depower (no hold action); events go to the panel's ArmamentDrag.

const X_OFFSET := 0
const NAME_OFFSET := Vector2(26, 3)
const NAME_WIDTH := 10049  # DroneBox passes nameWidth 10049: drone names never wrap
const DRONE_ICON := "ui_icons/icon_drones.png"  # 32×32 at (34, 10), status colour, only while deployed
const DRONE_ICON_POS := Vector2(34, 10)
# DroneBox::StatusColor: empty 190; powered + hacked (hack level > 1) purple; powered green; rebuilding red; else 150.
const COL_ON := Color8(120, 255, 120)
const COL_REBUILD := Color8(255, 100, 100)

var index := 0
var drone: Drone = null  # null = empty slot
var drag: ArmamentDrag = null
var dragged := false
var drag_offset := Vector2.ZERO
var hovered := false
var sparks := {}  # ArmamentBox hackAnimation while DroneBox::GetHacked (WeaponBox.update_sparks)
var _time := 0.0


func _init() -> void:
	size = HudLayout.BOX_SIZE
	custom_minimum_size = HudLayout.BOX_SIZE


func has_item() -> bool:
	return drone != null


func set_drone(d: Drone) -> void:
	drone = d


func _process(delta: float) -> void:
	_time += delta
	z_index = 1 if dragged else 0
	WeaponBox.update_sparks(sparks, drone != null and drone.hack_level > 1, _time)
	if drone and not dragged and not (drag and drag.dragging) and TooltipService.over(self, Rect2(Vector2.ZERO, size)):
		TooltipService.request(TooltipText.drone_box(drone, index), {"width": TooltipService.WRAP_BOX,
			"kind": &"drone", "source": self, "ctx": {"drone": drone, "slot": index}})
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_ENTER:
		hovered = true
	elif what == NOTIFICATION_MOUSE_EXIT:
		hovered = false


func _gui_input(event: InputEvent) -> void:
	if drag and drag.input(index, event):
		accept_event()


func status_color() -> Color:
	if drone == null:
		return WeaponBox.COL_EMPTY
	if drone.powered:
		return FtlColors.PURPLE_HACK if drone.hack_level > 1 else COL_ON
	if drone.rebuilding():
		return COL_REBUILD
	return WeaponBox.COL_OFF


## Rebuild overlay (DroneBox::RenderBox, under the frame): red α 0.25 over the whole box width, height
## 39 · destroyedTimer / 10 from the bottom (full right after the loss, shrinking as the timer runs out).
static func rebuild_rect(destroyed_timer: float) -> Rect2:
	var h := float(int(clampf(destroyed_timer / Drone.REBUILD_TIME, 0.0, 1.0) * 39.0))
	return Rect2(0, 39 - h, 95, h)


func _draw() -> void:
	if dragged:
		WeaponBox.draw_empty(self, X_OFFSET)
		draw_set_transform(drag_offset)
	if drone == null:
		WeaponBox.draw_empty(self, X_OFFSET)
		return
	var col := status_color()
	if drone.rebuilding():
		draw_rect(rebuild_rect(drone.destroyed_timer), Color(1, 0, 0, 0.25))
	WeaponBox.draw_frame(self, X_OFFSET, col, hovered and not dragged, str(index + 5))
	for i in drone.required_power():
		var r := Rect2(X_OFFSET + 4, 28 - 8 * i, 16, 7)
		if i >= drone.required_power() - drone.bonus_power:
			draw_rect(r, FtlColors.BONUS)  # zoltan bonus bars (DroneBox::GetBonusPower), on top
		elif drone.powered:
			draw_rect(r, FtlColors.GREEN)
		else:
			draw_rect(r.grow(-0.5), Color.WHITE, false, 1.0)
	HudDraw.text(self, 7, drone.short_name(), NAME_OFFSET, col, 0, NAME_WIDTH)
	if drone.deployed:
		HudDraw.img(self, DRONE_ICON, DRONE_ICON_POS, col)
	if not drone.rebuilding() and drone.powered and drone.stunned():
		HudDraw.text(self, 61, "STUNNED", Vector2(NAME_OFFSET.x, 26), FtlColors.BLUE)
	WeaponBox.draw_sparks(self, sparks)
	Hooks.emit(&"hud_draw.drone_box", self, drone)
