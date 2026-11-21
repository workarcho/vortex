class_name DronePanel
extends Control
## Drones panel (FTL DroneControl): same holder images and label tab as the weapons panel ("DRONES"), at
## (drone system box x + 32, 607); one DroneBox per slot. Click a box = power / deploy
## (DroneSystemRule.player_toggle: one part per deployment), right click = depower. The drone system's
## box (bars) stays in the systems bar; the parts count is in the top-left resources.
## Touch UI (`vertical`, main.gd `_touch_layout`): the weapons column's style (WeaponPanel vertical helpers) —
## the drone system's power row on top (sized for its maximum level), the slots stacked in a tight holder;
## main.gd places it under the weapons column and hides the systems bar's drones box.

var ship: ShipState
var boxes: Array[DroneBox] = []
var drag: ArmamentDrag
var reactor: ReactorColumn = null
var slots := 2
## DroneControl::droneMessage / noTargetMessage / systemMessage (rules/power.md "Related click feedback"):
## font 59, centred, 2.0 s, no flash. A locked / hacked drone system gives the fail sound only (no text); the
## reactor case is NOT ENOUGH POWER through ShipState.failed_powerup.
var drone_msg := WarningMessage.new("warning_no_drones", Vector2(112, -25), 2.0, true)
var target_msg := WarningMessage.new("warning_no_enemy_ship", Vector2(124, -60), 2.0, true)
var system_msg := WarningMessage.new("warning_no_system_power", Vector2(115, -45), 2.0, true)
var _time := 0.0
var vertical := false
var v_size := Vector2.ZERO
var v_row_w := 0.0
var power_hit: PowerRowHit = null  # vertical (touch): the power row's hit area


## Power row tap: deploy / power the first unpowered drone in slot order (as its box click).
func _row_power_up() -> void:
	for i in ship.drones.size():
		if ship.drones[i] != null and not ship.drones[i].powered:
			toggle(i)
			return
	FtlData.play("powerUpFail")


## Power row right click / − mode tap: depower the last powered drone in slot order.
func _row_power_down() -> void:
	for i in range(ship.drones.size() - 1, -1, -1):
		if ship.drones[i] != null and ship.drones[i].powered:
			depower(i)
			return


## `box_loc` = the drone system box location (frame coordinates).
func setup(s: ShipState, box_loc := Vector2(638, HudLayout.SYSTEM_BOX_Y), vert := false) -> void:
	ship = s
	vertical = vert
	slots = clampi(maxi(ship.drone_slots, ship.drones.size()), 2, 4)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if vertical:
		_v_layout()
	else:
		position = Vector2(box_loc.x + HudLayout.HOLDER_X, box_loc.y - HudLayout.SYSTEM_BOX_Y + HudLayout.ARMAMENT_Y)
		size = Vector2(SystemsBar.holder_width(slots), 88)
	# Box click: touch − mode depowers; touch + mode never removes power (TouchPowerToggle).
	drag = ArmamentDrag.new(TouchPowerToggle.route(_box_tap, depower), swap, depower)
	for i in maxi(ship.drone_slots, ship.drones.size()):
		var b := DroneBox.new()
		b.index = i
		b.set_drone(ship.drones[i] if i < ship.drones.size() else null)
		b.drag = drag
		b.position = HudLayout.BOX_ORIGIN + Vector2(HudLayout.BOX_STEP * i, 0)
		if vertical:
			b.position = v_frame().position + Vector2(WeaponPanel.V_PAD,
				WeaponPanel.V_PAD + (HudLayout.BOX_SIZE.y + WeaponPanel.V_BOX_GAP) * i)
		add_child(b)
		boxes.append(b)
	drag.boxes = boxes
	if vertical:  # the power row's hit area (PowerRowHit; follows the panel's scale like the slots)
		power_hit = PowerRowHit.new()
		power_hit.setup(ship, "drones", Rect2(Vector2.ZERO, Vector2(v_row_w, WeaponPanel.V_ROW_H)),
			TouchPowerToggle.route0(_row_power_up, _row_power_down), _row_power_down)
		add_child(power_hit)
	Hooks.emit(&"hud_ready", "drone_panel", self, ship)


## Box click: `toggle`, except that the touch + mode leaves a powered drone alone (+ never removes power).
func _box_tap(i: int) -> void:
	if TouchPowerToggle.adding() and i < ship.drones.size() and ship.drones[i] != null and ship.drones[i].powered:
		return
	toggle(i)


## Box click / key 5-7 (DroneControl::SelectArmament).
func toggle(i: int) -> void:
	if i >= ship.drones.size():
		return
	var r := DroneSystemRule.player_toggle(ship, ship.drones[i])
	match r:
		"ok":
			FtlData.play("powerUpSystem")
		"off":
			FtlData.play("powerDownSystem")
		_:
			FtlData.play("powerUpFail")
			match r:
				"no_parts":
					target_msg.stop()
					system_msg.stop()
					drone_msg.start()
				"no_target":
					drone_msg.stop()
					system_msg.stop()
					target_msg.start()
				"no_system_power":
					drone_msg.stop()
					target_msg.stop()
					if not system_msg.running():
						system_msg.text_id = WeaponPanel.system_message_id(ship.sys("drones"),
							DroneSystemRule.power_used(ship), ship.drones[i].required_power())
					system_msg.start()


## Right click / Shift+5-7 (DeselectArmament).
func depower(i: int) -> void:
	if i < ship.drones.size() and ship.drones[i].powered:
		DroneSystemRule.player_depower(ship, ship.drones[i])
		FtlData.play("powerDownSystem")


## DroneControl::SwapArmaments -> DroneSystem::SwapDrones: the two slots exchange their drones.
func swap(a: int, b: int) -> void:
	if DroneSystemRule.swap_drones(ship, a, b):
		boxes[a].set_drone(ship.drones[a])
		boxes[b].set_drone(ship.drones[b])


func dragging() -> bool:
	return drag.dragging and drag.slot >= 0


func _process(delta: float) -> void:
	_time += delta
	drone_msg.update(delta)
	target_msg.update(delta)
	system_msg.update(delta)
	queue_redraw()


func _draw() -> void:
	if vertical:
		WeaponPanel.draw_power_row(self, ship.sys("drones"), Vector2.ZERO, _time, ship)
		WeaponPanel.draw_vertical_holder(self, v_frame())
	else:
		WeaponPanel.draw_holder(self, slots, HudDraw.txt("drones_label"))
	drone_msg.draw(self)
	target_msg.draw(self)
	system_msg.draw(self)
	Hooks.emit(&"hud_draw.drone_panel", self, ship)


func _box_count() -> int:
	return maxi(maxi(ship.drone_slots, ship.drones.size()), 1)


## Vertical (touch) layout: width = max(power row for the drone system's maximum level, framed slot box);
## power row at the top-left, the holder right-aligned under it (WeaponPanel spacing constants).
func _v_layout() -> void:
	v_row_w = WeaponPanel.v_row_width(WeaponPanel.v_level_max(ship, "drones"))
	v_size.x = ceilf(maxf(v_row_w, WeaponPanel.v_holder_w()))
	v_size.y = ceilf(v_frame().end.y)
	size = v_size
	for m in [drone_msg, target_msg, system_msg]:
		m.position = Vector2(v_size.x / 2, v_size.y + 10)


## Vertical (touch) holder border rect around the drone boxes, panel-local.
func v_frame() -> Rect2:
	var hw := WeaponPanel.v_holder_w()
	return Rect2(v_size.x - hw, WeaponPanel.V_ROW_H + WeaponPanel.V_FRAME_GAP, hw,
		WeaponPanel.v_holder_h(_box_count()))


## The pointer (screen point) is over the panel as drawn, in its own coordinates (WeaponPanel.hud_hit).
func hud_hit(screen: Vector2) -> bool:
	var rects: Array[Rect2] = [Rect2(Vector2.ZERO, size)]  # typed: an untyped literal failed panel_hit's argument
	if vertical:
		rects = v_blocks()
	return WeaponPanel.panel_hit(self, screen, rects)


## Panel-local rects actually drawn (power row, holder).
func v_blocks() -> Array[Rect2]:
	return [Rect2(Vector2.ZERO, Vector2(v_row_w, WeaponPanel.V_ROW_H)), v_frame()]
