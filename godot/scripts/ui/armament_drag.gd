class_name ArmamentDrag
extends RefCounted
## Mouse logic shared by the weapon and drone panels (ArmamentControl, rules/weapon_controls.md):
## left press over a non-empty box records it; release with < 7 px movement = box click (power / arm);
## moving >= 7 px starts a drag, hovering another non-empty box swaps the two at once and the drag goes
## on as that slot (the press point shifts by the slot offset so the ghost stays under the cursor).
## Right press on a non-empty box = depower. No hold action (vanilla FTL has none; the touch prototype's 0.5 s
## hold-to-depower is gone on PC and touch): a long press only shows the tooltip and the lift still clicks. Touch
## depowers through the − mode / held-finger second tap (TouchPowerToggle).
##
## Boxes are Controls with `index`, `has_item() -> bool`, `drag_offset: Vector2` and `dragged: bool`.

const DRAG_DIST := 7.0  # Point::Distance from the press point

var boxes: Array = []
var on_click: Callable  # (slot)
var on_swap: Callable  # (a, b)
var on_depower: Callable  # (slot)
var slot := -1  # draggingBox
var press := Vector2.ZERO  # global press point
var dragging := false  # bDragging


func _init(click: Callable, swap: Callable, depower: Callable) -> void:
	on_click = click
	on_swap = swap
	on_depower = depower


## `global` is an event's global_position: viewport coordinates, i.e. AFTER the box's CanvasLayer offset (the touch
## HUD band on tall screens) and scale. Each box is hit-tested in its own local rect through its canvas transform
## (get_global_rect() leaves the layer offset out, which missed every swap target on the open Fold).
func box_at(global: Vector2) -> int:
	for b in boxes:
		var local: Vector2 = (b as CanvasItem).get_global_transform_with_canvas().affine_inverse() * global
		if Rect2(Vector2.ZERO, b.size).has_point(local):
			return b.index
	return -1


## Called by a box's _gui_input. Returns true if the event was used.
func input(box_index: int, event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			if boxes[box_index].has_item():
				on_depower.call(box_index)
			return true
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return false
		if mb.pressed:
			if boxes[box_index].has_item():
				slot = box_index
				press = mb.global_position
				dragging = false
			return true
		release(mb.global_position)
		return true
	if event is InputEventMouseMotion and slot >= 0:
		motion(event.global_position)
		return true
	return false


func motion(global: Vector2) -> void:
	if slot < 0:
		return
	if not dragging and global.distance_to(press) >= DRAG_DIST:
		dragging = true
	if not dragging:
		return
	var target := box_at(global)
	if target >= 0 and target != slot and boxes[target].has_item():
		on_swap.call(slot, target)
		press += boxes[target].global_position - boxes[slot].global_position
		boxes[slot].dragged = false
		boxes[slot].drag_offset = Vector2.ZERO
		slot = target
	boxes[slot].dragged = true
	# The ghost is drawn in the box's own coordinates (the touch column draws ×1.5): canvas delta -> box-local.
	boxes[slot].drag_offset = (boxes[slot] as CanvasItem).get_global_transform().affine_inverse().basis_xform(
		global - press)


func release(_global: Vector2) -> void:
	if slot < 0:
		return
	var s := slot
	var was_drag := dragging
	cancel()
	if not was_drag:
		on_click.call(s)


func cancel() -> void:
	if slot >= 0:
		boxes[slot].dragged = false
		boxes[slot].drag_offset = Vector2.ZERO
	slot = -1
	dragging = false

