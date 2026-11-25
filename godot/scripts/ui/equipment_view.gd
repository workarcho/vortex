class_name EquipmentView
extends Control
## Equipment screen (rules/ship_management.md §2, §3): weapon / drone slots, 3 augment slots, 4 cargo boxes, the
## over-capacity drop boxes, drag & drop with the accept / block highlights, and — in store mode (the store's SELL
## tab, `StoreView.sell_view`) — the sell drop box. One drag state machine for mouse and touch: mouse drags at
## once on press, touch after > 9 px (finger offset kept); release on an accepted box = EQUIP_MOVE (move / swap),
## on the sell box = EQUIP_SELL, anywhere else = nothing. Touch extras [ours]: tap an item then tap a target box,
## and a SELL button for the selected item in store mode.
## Mod hooks (rules/hooks.md): `equipment_move` (a drop / tap-tap move), `equipment_box_draw` (where and how each box
## is drawn), `equipment_draw_dragged` (the item following the pointer). With no filter the vanilla path is unchanged.

const P := ShipScreen.P
const ITEM_BOX := Vector2(109, 76)
const AUG_BOX := Vector2(235, 40)
const DROP_AT := Vector2(-275, 100)
const TOUCH_DRAG := 9.0
const STORE_TAB_BUY_HIT := Rect2(5, 7, 150, 36)
const STORE_CLOSE := Rect2(468, 470, 103, 32)
const STORE_CLOSE_BASE := Vector2(445, 463)
const COL_GREEN := Color8(100, 255, 100)
const COL_RED := Color8(255, 50, 50)
## Drag overlay (EquipmentBox::OnRender): box_overlay_red.png drawn with overlayColor / 255, alpha 0.5.
const OVERLAY_IMG := "upgradeUI/Equipment/box_overlay_red.png"
const OVERLAY_ALPHA := 0.5
## Box labels (EquipmentBox::RenderLabels, see augment_label / item_label).
const LABEL_COL := Color.WHITE  # COLOR_WHITE / 255, every state
const AUG_LABEL_FONT := 13
const AUG_LABEL_AT := Vector2(117, 14)
const ITEM_LABEL_FONT := 6
const ITEM_LABEL_AT := Vector2(60, 58)
## Icon centres (EquipmentBox::OnRender translates (63, 35) for a weapon, (60, 32) otherwise, then RenderIcon:
## weapon blueprint icon at that origin, drone + (0, 3) → (60, 35)) [exe 0052b3d0 / 0052af90].
const WEAPON_ICON_AT := Vector2(63, 35)
const DRONE_ICON_AT := Vector2(60, 35)

var run: RunState
var profile: InputProfile
var screen: ShipScreen = null  # null in store mode
var store_mode := false
var _press := ShipInventory.NONE  # drag candidate
var _press_pos := Vector2.ZERO
var _grab := Vector2.ZERO  # finger / cursor offset from the box origin
var _dragging := false
var _cursor := Vector2(-1000, -1000)
var _selected := ShipInventory.NONE  # touch: tapped item (info, tap-tap move, SELL button)
var _art := {}
## Tests: what the last _draw put in the boxes ([box, item name] per box drawn with its item) and the dragged item
## drawn at the pointer ({} = none). Hit-tests and drawing are in this node's local coordinates.
var drawn_items: Array = []
var drawn_dragged := {}


func setup(r: RunState, p: InputProfile, s: ShipScreen = null) -> void:
	run = r
	profile = p
	screen = s
	store_mode = s == null
	position = Vector2.ZERO
	size = HudLayout.FRAME
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	mouse_filter = Control.MOUSE_FILTER_STOP


func _process(_d: float) -> void:
	if store_mode:
		# StoreView.embed_sell_view places us at W; we draw and hit-test in absolute frame coordinates (the sell box
		# lies left of the window), so we cover the whole frame.
		position = Vector2.ZERO
		size = HudLayout.FRAME
		var on := run != null and run.mgmt.store_mode(run) and run.over == ""
		mouse_filter = Control.MOUSE_FILTER_STOP if on else Control.MOUSE_FILTER_IGNORE
		if on:
			queue_redraw()
	if run != null and not run.mgmt.equipment_active(run):
		_cancel()


func inv() -> ShipInventory:
	return run.mgmt.inv


# ------------------------------------------------------------------ layout

func box_rect(b: Vector2i) -> Rect2:
	var ship := run.ship
	match b.x:
		ShipInventory.WEAPON:
			var n := ship.weapon_slots
			return Rect2(P + Vector2(63 + (4 - n) * 58 + 117 * b.y, 70), ITEM_BOX)
		ShipInventory.DRONE:
			var n2 := ship.drone_slots
			return Rect2(P + Vector2(63 + (4 - n2) * 58 + 117 * b.y, 180), ITEM_BOX)
		ShipInventory.AUG:
			return Rect2(P + Vector2(330, 293 + 60 * b.y), AUG_BOX)
		ShipInventory.CARGO:
			return Rect2(P + Vector2(30 + 130 * (b.y % 2), 293 + 80 * (b.y / 2)), ITEM_BOX)
		ShipInventory.OVER:
			return over_drop_rect(false)
		ShipInventory.OVER_AUG:
			return over_drop_rect(true)
	return Rect2()


## Where the item of a box is drawn (the over boxes' item sits in their drop box's body band:
## item box + (80, ·), augment box + (19, ·) [band offsets inferred]).
func item_rect(b: Vector2i) -> Rect2:
	if b.x == ShipInventory.OVER:
		var d := over_drop_rect(false)
		return Rect2(d.position + Vector2(80, _over_body_y(false) + 12), ITEM_BOX)
	if b.x == ShipInventory.OVER_AUG:
		var d2 := over_drop_rect(true)
		return Rect2(d2.position + Vector2(19, _over_body_y(true) + 12), AUG_BOX)
	return box_rect(b)


const SELL_BODY := 34.0
const OVER_BODY := 100.0
const OVER_AUG_BODY := 65.0


func _sell_title() -> String:
	return FtlData.tr_id("sell_box_title")


func _sell_lines() -> Array:
	return ShipScreen.text_lines("sell_box_text")


func sell_rect() -> Rect2:
	return StoreSellBox.rect(P + DROP_AT)  # DropBox(isSellBox) geometry (store agent: store_sell_box.gd)


## Over-capacity drop boxes at P + (−275, 100); below the sell box in store mode and stacked when both are
## active [ours: the exe draws both at the same spot].
func over_drop_rect(aug: bool) -> Rect2:
	var y := P.y + DROP_AT.y + (sell_rect().size.y + 10 if store_mode else 0.0)
	if aug and inv().over_active:
		y += _over_height(false) + 10
	return Rect2(Vector2(P.x + DROP_AT.x, y), Vector2(272, _over_height(aug)))


func _over_title(aug: bool) -> String:
	return FtlData.tr_id("overcapacity_%s_title" % ("aug" if aug else "item"))


func _over_lines(aug: bool, n: int) -> Array:
	return ShipScreen.text_lines("overcapacity_%s_text%d" % ["aug" if aug else "item", n])


func _over_body(aug: bool) -> float:
	return OVER_AUG_BODY if aug else OVER_BODY


## Body band top, relative to the drop box.
func _over_body_y(aug: bool) -> float:
	return ShipScreen.drop_box_height(_over_title(aug), _over_lines(aug, 1), 0, []) - 10


func _over_height(aug: bool) -> float:
	return ShipScreen.drop_box_height(_over_title(aug), _over_lines(aug, 1), _over_body(aug), _over_lines(aug, 2))


func boxes() -> Array:
	var out := []
	for b in ShipInventory.all_boxes(run):
		if inv().valid(run, b):
			out.append(b)
	return out


func box_at(p: Vector2) -> Vector2i:
	for b in boxes():
		if box_rect(b).has_point(p):
			return b
	return ShipInventory.NONE


func sell_button_rect() -> Rect2:
	return Rect2(P + Vector2(600 + 80, 330), Vector2(140, 36))


# ------------------------------------------------------------------ input

func _gui_input(event: InputEvent) -> void:
	accept_event()
	if event is InputEventMouseMotion:
		motion(event.position)
		return
	var mb := event as InputEventMouseButton
	if mb == null or mb.button_index != MOUSE_BUTTON_LEFT:
		if mb and mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT:
			_cancel()
		return
	if mb.pressed:
		press(mb.position)
	else:
		release(mb.position)


func press(p: Vector2) -> void:
	_cursor = p
	if store_mode and profile.is_touch() and _selected != ShipInventory.NONE and sell_button_rect().has_point(p):
		_sell(_selected)
		_selected = ShipInventory.NONE
		return
	var b := box_at(p)
	if b == ShipInventory.NONE or inv().item_at(run, b).is_empty():
		_press = ShipInventory.NONE
		if b != ShipInventory.NONE and _selected != ShipInventory.NONE and profile.is_touch():
			_try_move(_selected, b)  # tap-tap move [ours]
			_selected = ShipInventory.NONE
			return
		if not _chrome_click(p):
			_selected = ShipInventory.NONE
		return
	_press = b
	_press_pos = p
	_grab = p - item_rect(b).position
	if b.x == ShipInventory.OVER or b.x == ShipInventory.OVER_AUG:
		_grab = (Vector2(117, 20) if b.x == ShipInventory.OVER_AUG else Vector2(50, 33))  # dragBoxCenter
	_dragging = not profile.is_touch()  # Equipment::MouseClick: no threshold with the mouse


func motion(p: Vector2) -> void:
	_cursor = p
	if _press != ShipInventory.NONE and not _dragging and p.distance_to(_press_pos) > TOUCH_DRAG:
		_dragging = true


func release(p: Vector2) -> void:
	_cursor = p
	var src := _press
	var was_drag := _dragging
	_press = ShipInventory.NONE
	_dragging = false
	if src == ShipInventory.NONE:
		return
	if not was_drag:
		# A tap without movement: select (info box); a tap on another box with a selection = move [ours].
		if _selected != ShipInventory.NONE and _selected != src and profile.is_touch():
			if _try_move(_selected, src):
				_selected = ShipInventory.NONE
				return
		_selected = src
		return
	if store_mode and sell_rect().has_point(p):
		_sell(src)
		_selected = ShipInventory.NONE
		return
	var t := box_at(p)
	if t != ShipInventory.NONE and _try_move(src, t):
		_selected = t if profile.is_touch() else ShipInventory.NONE  # TOUCH_UP keeps the moved item selected
		return


func _try_move(s: Vector2i, t: Vector2i) -> bool:
	if not inv().accepts(run, s, t):
		return false
	# Hook `equipment_move`: a mod may do the move itself (true) or refuse it (cancel); false = the vanilla move.
	var done: Variant = Hooks.filter(&"equipment_move", false, self, run, s, t)
	if Hooks.is_cancel(done):
		return false
	if done == true:
		return true
	return run.apply(ShipManagement.make(RunIntent.EQUIP_MOVE, {"src": s, "dst": t}))


func _sell(b: Vector2i) -> void:
	run.apply(ShipManagement.make(RunIntent.EQUIP_SELL, {"src": b}))


func _cancel() -> void:
	_press = ShipInventory.NONE
	_dragging = false


func dragging() -> bool:
	return _dragging and _press != ShipInventory.NONE


## The box whose item is being dragged (NONE when no drag).
func drag_source() -> Vector2i:
	return _press if dragging() else ShipInventory.NONE


## Pointer offset from the dragged box's top-left (the grab point).
func grab_offset() -> Vector2:
	return _grab


func _chrome_click(p: Vector2) -> bool:
	if store_mode:
		if Rect2(P + STORE_TAB_BUY_HIT.position, STORE_TAB_BUY_HIT.size).has_point(p):
			profile.store_tab(0)
			return true
		if Rect2(P + STORE_CLOSE.position, STORE_CLOSE.size).has_point(p):
			profile.store_close()
			return true
		return false
	return screen.chrome_click(p)


# ------------------------------------------------------------------ drawing

func _draw() -> void:
	if run == null:
		return
	if store_mode and not run.mgmt.store_mode(run):
		return
	if not store_mode and not run.mgmt.open:
		return
	var mouse := _cursor if profile.is_touch() else TooltipService.local_pointer(self)
	if store_mode and get_parent() is StoreView and (get_parent() as StoreView).debug_pointer != Vector2.INF:
		mouse = (get_parent() as StoreView).debug_pointer  # --store-pointer (screenshots of the SELL tab hover)
	if not store_mode:  # store mode: StoreView already drew the dim scene, store_sell_main, tab texts and CLOSE
		ShipScreen.img(self, "upgradeUI/Equipment/equipment_main.png", P + Vector2(0, -7))
	var dk := ShipScreen.COL_DARK
	FtlData.draw_ftl_text(self, 62, FtlData.tr_id("equipment_frame_weapons"), P + Vector2(18, 44), dk)
	FtlData.draw_ftl_text(self, 62, FtlData.tr_id("equipment_frame_drones"), P + Vector2(18, 154), dk)
	FtlData.draw_ftl_text(self, 62, FtlData.tr_id("equipment_frame_cargo"), P + Vector2(18, 264), dk)
	FtlData.draw_ftl_text(self, 62, FtlData.tr_id("equipment_frame_augments"), P + Vector2(307, 264), dk)
	drawn_items.clear()
	drawn_dragged = {}
	var drag := dragging()
	var hover := box_at(mouse) if not profile.is_touch() or drag else ShipInventory.NONE
	# Sell box (store mode), over-capacity drop boxes.
	var info_box := _selected if _selected != ShipInventory.NONE else hover
	if drag:
		info_box = _press
	if store_mode:
		var over_sell := drag and sell_rect().has_point(mouse)
		var has_item := info_box != ShipInventory.NONE and not inv().item_at(run, info_box).is_empty()
		StoreSellBox.draw(self, sell_rect().position, over_sell, str(inv().sell_value(run, info_box)) if has_item
			else "")
	for aug in [false, true]:
		if (inv().over_aug_active if aug else inv().over_active):
			var d := over_drop_rect(aug)
			var hot: bool = drag and d.has_point(mouse)
			ShipScreen.drop_box(self, d.position, false, hot, _over_title(aug), _over_lines(aug, 1), _over_body(aug),
				_over_lines(aug, 2))
	for b in boxes():
		_draw_box(b, hover, drag)
	if run.ship.sys("weapons") == null:
		FtlData.draw_ftl_text(self, 63, FtlData.tr_id("equipment_no_system"), P + Vector2(301, 93),
			ShipScreen.COL_TEXT, 1)
	if run.ship.sys("drones") == null:
		FtlData.draw_ftl_text(self, 63, FtlData.tr_id("equipment_no_system"), P + Vector2(301, 203),
			ShipScreen.COL_TEXT, 1)
	_draw_info(info_box)
	if store_mode:
		_draw_store_chrome(mouse)
	else:
		screen.draw_chrome(self, mouse if not profile.is_touch() else Vector2(-1, -1))
	if drag:
		_draw_dragged(mouse, hover)


## The dragged item at the pointer (Equipment::OnRender: translate currentMouse, then the source box's RenderIcon):
## a weapon / drone is its bare icon (no box, no label, untinted) centred on the pointer; an augment
## (AugmentEquipBox::RenderIcon = OnRender(false) + RenderLabels) is its whole box — `box_augment_on` (`_selected`
## while that source box glows) + title — with its top-left at the pointer. Mouse: exactly at the cursor
## (MouseClick keeps no grab offset). Touch [ours]: keeps the finger's grab point on the item.
func _draw_dragged(mouse: Vector2, hover: Vector2i) -> void:
	var it := inv().item_at(run, _press)
	if it.is_empty():
		return
	# Hook `equipment_draw_dragged`: cancel = a mod drew the dragged item itself.
	if Hooks.is_cancel(Hooks.filter(&"equipment_draw_dragged", true, self, _press, mouse, _grab)):
		return
	drawn_dragged = it.duplicate()
	var aug := String(it.kind) == "augment"
	var at := mouse - _grab
	if not profile.is_touch():
		at = mouse - (Vector2.ZERO if aug else (WEAPON_ICON_AT if it.kind == "weapon" else DRONE_ICON_AT))
	if aug:
		var glow := hover == _press and drag_target_ok(_press, _press)
		ShipScreen.img(self, "upgradeUI/Equipment/box_augment_%s.png" % ("selected" if glow else "on"), at)
		augment_label(self, FtlData.blueprint_title(String(it.name), "augment"), at)
		return
	_draw_item(it, Rect2(at, ITEM_BOX), 1.0, false)


func _box_type(b: Vector2i, it: Dictionary) -> String:
	match b.x:
		ShipInventory.WEAPON:
			return "weapons"
		ShipInventory.DRONE:
			return "drones"
		ShipInventory.AUG, ShipInventory.OVER_AUG:
			return "augment"
	if it.is_empty():
		return "base"
	return "weapons" if it.kind == "weapon" else "drones"


## While dragging the item of `s`, is box `t` a target (Equipment::OnLoop @00524fb0: not blocked)? Other boxes:
## `ShipInventory.accepts`. The source box still holds the item in the exe, so OnLoop tests it like any box: a
## weapon / drone source passes its own CanHoldWeapon / CanHoldDrone (weapon slot, or a cargo box holding that
## kind), a cargo source passes the cargo ↔ cargo rule, the over-capacity augment box passes (overAugBox == dragged
## box, CanHoldAugment), and an augment slot fails (CanHoldAugment but not IsEmpty) — blocked, which for an
## augment box only means no hover glow (its overlay is never drawn).
func drag_target_ok(s: Vector2i, t: Vector2i) -> bool:
	if s != t:
		return inv().accepts(run, s, t)
	var k := String(inv().item_at(run, s).get("kind", ""))
	if (k == "weapon" and inv().can_hold_weapon(run, t)) or (k == "drone" and inv().can_hold_drone(run, t)):
		return true
	return ShipInventory.is_cargo(s) or s.x == ShipInventory.OVER_AUG


## How one box renders (EquipmentBox::OnRender @0052b3d0 + Equipment::OnLoop @00524fb0 + MouseMove @00525580):
## {img: box image path, empty: drawn as an empty box (no item / the drag source), overlay: Color (alpha 0 = none)}.
## - The box image is always drawn untinted (its primitives are created with colour (1, 1, 1, 1)).
## - Image: `off` / `off_selected` when empty or it is the drag source (GetType(forcedEmpty) → an emptied cargo box
##   is `base`), else `on` / `selected`; `_selected` variants while bGlow. bGlow (MouseMove): not dragging → the
##   hovered box if it holds an item; dragging → the hovered box unless blocked (the source box included).
## - Overlay (only while dragging): `box_overlay_red.png` (white, alpha 51/255 = 0.2) drawn with overlayColor / 255
##   at alpha 0.5 — an effective 10 % wash. overlayColor = COLOR_RED on blocked boxes; COLOR_GREEN on every other
##   box when a weapon or drone is dragged (filled slots and the source too); white (= no overlay) for an augment /
##   cargo-swap-only drag. Never on augment boxes (GetType 3): those keep their normal look in every drag.
func box_look(b: Vector2i, hover: Vector2i, drag: bool) -> Dictionary:
	var it := inv().item_at(run, b)
	var source := drag and b == _press
	var empty := it.is_empty() or source  # the source's item travels with the cursor
	var glow := false
	var overlay := Color(1, 1, 1, 0)
	if not drag:
		glow = (b == hover and not it.is_empty()) or b == _selected  # _selected: touch tap selection [ours]
	else:
		var ok := drag_target_ok(_press, b)
		glow = ok and b == hover
		var col := Color.WHITE
		var dk := String(inv().item_at(run, _press).get("kind", ""))
		if not ok:
			col = COL_RED
		elif dk == "weapon" or dk == "drone":
			col = COL_GREEN
		if col != Color.WHITE and not ShipInventory.can_hold_augment(b):
			overlay = Color(col, OVERLAY_ALPHA)
	var ty := _box_type(b, {} if empty else it)
	var st := ("off_selected" if glow else "off") if empty else ("selected" if glow else "on")
	if ty == "base" and st == "on":
		st = "off"
	return {"img": "upgradeUI/Equipment/box_%s_%s.png" % [ty, st], "empty": empty, "overlay": overlay}


func _draw_box(b: Vector2i, hover: Vector2i, drag: bool) -> void:
	var look := box_look(b, hover, drag)
	var at := item_rect(b).position
	if Hooks.has_filters(&"equipment_box_draw"):
		# Hook `equipment_box_draw`: {pos, look} of this box; a mod may move it (e.g. a reorder preview).
		var v: Variant = Hooks.filter(&"equipment_box_draw", {"pos": at, "look": look}, self, b, hover, drag)
		if Hooks.is_cancel(v):
			return
		if v is Dictionary:
			at = v.get("pos", at)
			look = v.get("look", look)
	draw_box_at(b, at, look)


## Draws box `b` with `look` (box_look) at top-left `at`: box image, its item unless look.empty, the overlay.
## `record`: list the item in `drawn_items` (false for a card drawn at the pointer).
func draw_box_at(b: Vector2i, at: Vector2, look: Dictionary, record := true) -> void:
	var r := Rect2(at, item_rect(b).size)
	ShipScreen.img(self, look.img, r.position)
	if not look.empty:
		var it := inv().item_at(run, b)
		_draw_item(it, r, 1.0)
		if record and not it.is_empty():
			drawn_items.append([b, String(it.name)])
	var ov: Color = look.get("overlay", Color(1, 1, 1, 0))
	if ov.a > 0.0:
		ShipScreen.img(self, OVERLAY_IMG, r.position, ov)


## Item art + label inside a box rect (EquipmentBox::OnRender / RenderIcon / RenderLabels [exe]): weapon art (charged
## frame, rotated + mirrored) centred at box + WEAPON_ICON_AT, drone icon (DroneBlueprint::RenderIcon) at box +
## DRONE_ICON_AT, augment title.
func _draw_item(it: Dictionary, r: Rect2, alpha: float, label := true) -> void:
	if it.is_empty():
		return
	var title := FtlData.blueprint_title(String(it.name), String(it.kind))
	var white := Color(1, 1, 1, alpha)
	match String(it.kind):
		"weapon":
			var a := _weapon_art(String(it.name))
			if not a.is_empty():
				var src: Rect2 = a.frames[clampi(int(a.get("charged", 0)), 0, a.frames.size() - 1)]
				WeaponIcon.draw(self, a.texture, src, r.position + WEAPON_ICON_AT, white)  # rotate 90° + mirror
			# EquipmentBox::RenderLabels: weapons and drones show the short title; no power pips here.
			if label:
				_label(StoreView.short_name({"kind": "weapon", "name": it.name}), r, alpha)
		"drone":
			WeaponIcon.draw_drone(self, String(it.name), r.position + DRONE_ICON_AT, white)
			if label:
				_label(FtlData.blueprint_short(String(it.name), "drone"), r, alpha)
		"augment":
			augment_label(self, title, r.position, alpha)


func _label(text: String, r: Rect2, alpha: float) -> void:
	item_label(self, text, r.position, alpha)


## EquipmentBox::RenderLabels [exe 0052c0f0]: the label is printed in COLOR_WHITE (alpha 1) in every state
## (normal / hovered / selected / blocked; empty boxes print nothing), one easy_printCenter line, no wrapping or
## truncation. Augment: full title, font 13 (JustinFont12Bold, 19 px, baseline 12) centred at box + (117, 14).
static func augment_label(ci: CanvasItem, title: String, box: Vector2, alpha := 1.0) -> void:
	FtlData.draw_ftl_text(ci, AUG_LABEL_FONT, title, box + AUG_LABEL_AT, Color(LABEL_COL, alpha), 1)


## Weapon / drone (short title): font 6 (→ 9, JustinFont8) centred at box + (60, 58) [exe RenderLabels]; the same
## call the store's equipment boxes make at (59, 58) (StoreBox::OnRender).
static func item_label(ci: CanvasItem, text: String, box: Vector2, alpha := 1.0) -> void:
	FtlData.draw_ftl_text(ci, ITEM_LABEL_FONT, text, box + ITEM_LABEL_AT, Color(LABEL_COL, alpha), 1)


func _power(n: int, r: Rect2, alpha: float) -> void:
	for i in n:
		draw_rect(Rect2(r.position + Vector2(r.size.x - 16, 46 - 6 * i), Vector2(10, 4)), Color(COL_GREEN, alpha))


func _weapon_art(nm: String) -> Dictionary:
	if not _art.has(nm):
		var bp := FtlData.weapon_blueprint(nm)
		var wa := FtlData.weapon_anim(String(bp.get("weapon_art", "")).strip_edges())
		var sheet: Dictionary = wa.sheet.duplicate() if wa.get("sheet", {}).has("texture") else {}
		if not sheet.is_empty():
			sheet["charged"] = int(wa.get("charged_frame", 0))  # Blueprint::RenderIcon: the charged frame
		_art[nm] = sheet
	return _art[nm]


func _draw_info(b: Vector2i) -> void:
	if b == ShipInventory.NONE:
		return
	var it := inv().item_at(run, b)
	if it.is_empty():
		return
	var at := P + Vector2(600, -25)
	# exe InfoBox (EquipmentBox::SetBlueprint: stat lines, TIP frame) at infoBox.location = P + (600, −25).
	var sysid := "weapons" if it.kind == "weapon" else "drones"
	var ctx := {"context": "store" if store_mode else "equipment", "owned": true,
		"sell_price": inv().sell_value(run, b)}
	var d := ItemInfoBox.content(String(it.kind), String(it.name), run.ship.sys(sysid) != null, run.engine.ae, ctx)
	if not d.is_empty():
		ItemInfoBox.draw(self, at, d)
	if store_mode and profile.is_touch() and b == _selected:
		ShipScreen.text_button(self, sell_button_rect(), "SELL (%d)" % inv().sell_value(run, b), "on")


## Store mode: we take the input over the whole frame, so the hovered BUY tab / CLOSE button highlights are ours.
func _draw_store_chrome(mouse: Vector2) -> void:
	if profile.is_touch():
		return
	if Rect2(P + STORE_TAB_BUY_HIT.position, STORE_TAB_BUY_HIT.size).has_point(mouse):
		ShipScreen.img(self, "upgradeUI/Equipment/tabButtons/sell_buy_select2.png", P)
		FtlData.draw_ftl_text(self, 63, FtlData.tr_id("store_tab_buy"), P + Vector2(86, 8), ShipScreen.COL_DARK, 1)
	var cr := Rect2(P + STORE_CLOSE.position, STORE_CLOSE.size)
	if cr.has_point(mouse):
		draw_rect(cr, ShipScreen.COL_HOT)
		FtlData.draw_ftl_text(self, 63, FtlData.tr_id("button_close"), Vector2(cr.get_center().x, cr.position.y + 6),
			ShipScreen.COL_DARK, 1)
