class_name SystemsBar
extends Control
## Bottom-left system power UI (FTL SystemControl; rules/hud_layout.md): reactor wires + reactor bars, one
## SystemPowerColumn per reactor system at its CreateSystemBoxes location (plain boxes every 36 px, boxes
## with a cooldown button every 54), the weapons box slot (its column lives in the WeaponPanel), the drone
## system box after the weapons panel, and the subsystems group (pilot, sensors, doors, battery) at
## (1015, 633) over box_subsystems4.png. Full-frame, mouse-transparent; children take the clicks.

## Reactor systems in SystemControl order (only present ones; weapons / drones handled apart).
const BAR_ORDER := ["shields", "engines", "medbay", "clonebay", "oxygen", "teleporter", "cloaking", "artillery",
	"mind", "hacking"]
## Boxes with a cooldown button (advance 54): CloakingBox, TeleportBox, HackBox, MindBox.
const WIDE_BOXES := ["teleporter", "cloaking", "mind", "hacking"]
## Systems with an activation button above their box (+ BatteryBox in the subsystems group).
const BUTTON_SYSTEMS := ["cloaking", "battery", "teleporter", "hacking", "mind", "doors", "artillery"]
const HOLDER_W := {2: 225, 3: 322, 4: 419}  # box_weapons_bottom<N>.png widths
const STACK_UP := 100  # drones panel lifted above the weapons panel when it would hit the subsystems

var ship: ShipState
var combat: Combat = null  # set before setup(): the teleporter buttons arm through it
var buttons := {}  # system id -> SystemButton
var columns := {}  # system id -> SystemPowerColumn
var box_x := {}  # system id -> box x (incl. "weapons", "drones")
var main_ids: Array = []  # reactor systems drawn in the bar, in order (no weapons)
var sub_ids: Array = []
var weapons_loc := Vector2.ZERO  # weapons system box location (its column is in the WeaponPanel)
var drones_loc := Vector2.ZERO
var drones_stacked := false  # no room right of the weapons panel: drones panel above it
var sub_spacing := 0
var reactor: ReactorColumn
var _signature := ""  # installed systems + slots the boxes were built for (rebuild when it changes)
## Touch UI (main.gd `_touch_layout`): set before setup(); the subsystem columns, buttons and box are drawn in
## `sub_group` (a child Control at the frame origin) so the owner can move them apart from the bar.
var detach_subsystems := false
var sub_group: Control = null
## Touch phone column layout (main.gd `_touch_layout_band`): the weapons / drones boxes are drawn in the column, so
## the wire ends at the last bar box (its cap) instead of running on under their PC slots.
var wire_main_only := false

## The boxes were rebuilt because the ship's systems changed (store purchase, removal): the owner re-places the
## weapons / drones panels (their box locations moved).
signal rebuilt


func setup(s: ShipState) -> void:
	ship = s
	position = Vector2.ZERO
	size = HudLayout.FRAME
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	reactor = ReactorColumn.new()
	reactor.setup(ship)
	add_child(reactor)
	if detach_subsystems:
		sub_group = Control.new()
		sub_group.size = HudLayout.FRAME
		sub_group.mouse_filter = Control.MOUSE_FILTER_IGNORE
		sub_group.draw.connect(_draw_sub_group)
		add_child(sub_group)
	_build_boxes()


## What the box layout depends on: the installed systems (ids + rooms) and the weapon / drone slot counts.
static func layout_signature(sh: ShipState) -> String:
	var ids := sh.systems.keys()
	ids.sort()
	return "%s|%d|%d" % [",".join(PackedStringArray(ids)), sh.weapon_slots, sh.drone_slots]


## SystemControl::CreateSystemBoxes again (the game re-creates the boxes when a system is added or removed):
## drops the columns / buttons and lays them out for the current systems. The reactor column is kept.
func rebuild() -> void:
	for c in columns.values():
		c.get_parent().remove_child(c)
		c.queue_free()
	for b in buttons.values():
		b.get_parent().remove_child(b)
		b.queue_free()
	columns.clear()
	buttons.clear()
	main_ids.clear()
	sub_ids.clear()
	box_x.clear()
	drones_stacked = false
	_build_boxes()
	rebuilt.emit()


func _build_boxes() -> void:
	_signature = layout_signature(ship)
	_layout()
	for id in main_ids:
		var loc := Vector2(box_x[id], HudLayout.SYSTEM_BOX_Y)
		# Drones are powered per drone in the DronePanel: their box only shows the bars.
		add_child(_column(id, loc, id != "drones"))
		if BUTTON_SYSTEMS.has(id):
			_add_button(id, loc)
	if ship.sys("drones") != null:
		add_child(_column("drones", drones_loc, false))
	# CreateSystemBoxes: every subsystem slot advances 36 + spacing whether installed or not; the DoorBox slot
	# advances 15 px more (room for its door control box), the BatteryBox 18.
	var x := HudLayout.SUBSYSTEMS.x
	for id in SystemState.SUBSYSTEMS:
		if ship.sys(id) != null:
			var loc := Vector2(x, HudLayout.SUBSYSTEMS.y)
			var parent: Control = sub_group if sub_group != null else self
			parent.add_child(_column(id, loc, false))
			if BUTTON_SYSTEMS.has(id):
				_add_button(id, loc, parent)
		x += HudLayout.SUBSYSTEM_STEP + sub_spacing + (15 if id == "doors" else 18 if id == "battery" else 0)


func _layout() -> void:
	for id in BAR_ORDER:
		if ship.sys(id) != null:
			main_ids.append(id)
	for id in SystemState.SUBSYSTEMS:
		if ship.sys(id) != null:
			sub_ids.append(id)
	var has_w := ship.sys("weapons") != null
	box_x = HudLayout.system_box_xs(main_ids, WIDE_BOXES, has_w, ship.weapon_slots, ship.sys("drones") != null)
	if not has_w:
		box_x["weapons"] = box_x.get("drones", HudLayout.SYSTEM_FIRST_X + 36)
	weapons_loc = Vector2(box_x["weapons"], HudLayout.SYSTEM_BOX_Y)
	drones_loc = Vector2(box_x.get("drones", 0), HudLayout.SYSTEM_BOX_Y)
	if ship.sys("drones") != null:
		var holder_end := drones_loc.x + HudLayout.HOLDER_X + holder_width(ship.drone_slots)
		if holder_end > HudLayout.SUBSYSTEMS.x:
			# Ships with many systems (test ships): FTL would overlap the subsystems; stack the drones
			# panel above the right end of the weapons panel instead.
			drones_stacked = true
			var w_end := weapons_loc.x + HudLayout.HOLDER_X + holder_width(ship.weapon_slots)
			drones_loc = Vector2(w_end - holder_width(ship.drone_slots) - HudLayout.HOLDER_X,
				HudLayout.SYSTEM_BOX_Y - STACK_UP)
	# SystemControl::UpdateSubSystemBox: wider label -> spacing.
	var lw := FtlData.ftl_text_width(62, HudDraw.txt("subsystems_label"))
	sub_spacing = (lw - 140) / 3 if lw > 140 else 0


static func holder_width(slots: int) -> int:
	return HOLDER_W.get(clampi(slots, 2, 4), 419)


func _add_button(id: String, loc: Vector2, parent: Control = null) -> void:
	var b := SystemButton.new()
	b.setup(ship, id, combat, loc)
	buttons[id] = b
	(parent if parent != null else self).add_child(b)


func _column(id: String, loc: Vector2, clickable: bool) -> SystemPowerColumn:
	var col := SystemPowerColumn.new()
	col.setup(ship, id, clickable, loc)
	col.increase_requested.connect(_increase)
	col.decrease_requested.connect(_decrease)
	columns[id] = col
	return col


## SystemBox::MouseClick (rules/power.md "Triggers"): a locked (ion / lock) system ignores the click (no sound,
## no message); otherwise +1 with powerUpSystem / powerUpFail. NOT ENOUGH POWER is not started here: the rule
## layer sets ShipState.failed_powerup and the ReactorColumn shows it. Shields: a click that would need half a
## layer (power = usable max - 1, odd level) first starts the shields box's warning_needs_upgrade.
func _increase(id: String) -> void:
	var s := ship.sys(id)
	if s == null or s.is_locked():
		return
	if id == "shields" and s.power == s.max_power() - 1 and s.get_level() % 2 == 1 and columns.has(id):
		(columns[id] as SystemPowerColumn).warning.start()
	var r := ship.increase_power(id)
	FtlData.play("powerUpSystem" if r == "ok" else "powerUpFail")


func _decrease(id: String) -> void:
	if ship.decrease_power(id):
		FtlData.play("powerDownSystem")


func _process(_d: float) -> void:
	if ship != null and layout_signature(ship) != _signature:
		rebuild()  # a system was installed / removed (hook system_installed / system_removed)
	if ship != null and not TooltipService.hud_blocked:
		var m := TooltipService.local_pointer(self)
		var c := reactor.counts() if reactor else Vector3i(ship.reactor_max, 0, 0)
		var rr := Rect2(HudLayout.REACTOR_X, ReactorColumn.top_y(c.x), HudLayout.REACTOR_BAR.x,
			HudLayout.REACTOR_BOTTOM - ReactorColumn.top_y(c.x))
		# Touch: the subsystems are drawn by the moved sub_group (its own transform).
		var sub := (TooltipService.local_pointer(sub_group) if sub_group != null else m) - HudLayout.SUBSYSTEMS
		if rr.has_point(m):  # SystemControl::SystemPower rect
			TooltipService.request(TooltipText.simple("reactor", "tooltip_powerTotal"), {"kind": &"reactor",
				"source": self})
		elif not sub_ids.is_empty() and sub.x > 7 and sub.x < 157 + 3 * sub_spacing and sub.y > 44 and sub.y < 84:
			TooltipService.request(TooltipText.simple("subsystems", "tooltip_subsystems"), {"kind": &"subsystems",
				"source": self})
	queue_redraw()
	if sub_group != null:
		sub_group.queue_redraw()


## The pointer (screen point) is over the bar as drawn: the bottom strip up to bar_right() in the bar's own
## coordinates, or the detached subsystems' solid art in sub_group's. main.gd `_over_hud_panel` (touch UI).
func hud_hit(screen: Vector2) -> bool:
	if not is_visible_in_tree():
		return false
	var m := get_global_transform().affine_inverse() * screen
	if m.y > HudLayout.ARMAMENT_Y and m.x < bar_right():
		return true
	for col: SystemPowerColumn in columns.values():  # tall bar columns reach above the strip
		if col.is_visible_in_tree() and col.hit_rect().has_point(col.get_global_transform().affine_inverse() * screen):
			return true
	for b: SystemButton in buttons.values():  # (a button may be drawn away from its box: the touch doors buttons)
		if b.is_visible_in_tree() and b._has_point(b.get_global_transform().affine_inverse() * screen):
			return true
	return sub_group != null and not sub_ids.is_empty() \
		and subsystem_bounds().has_point(sub_group.get_global_transform().affine_inverse() * screen)


## Right edge (frame x) of what the bottom bar itself draws: the reactor and the visible system boxes / buttons
## that are its own children (not the detached subsystems).
func bar_right() -> float:
	var r := HudLayout.REACTOR_X + HudLayout.REACTOR_BAR.x
	for c: Control in columns.values() + buttons.values():
		if c.get_parent() == self and c.visible:
			r = maxf(r, c.position.x + c.size.x)
	return r


## Frame-coordinate bounds of the solid art (alpha > 0.5) the subsystem group draws: the box (box_subsystems4.png
## solid x 6..163, y 6..33), each subsystem's symbol glyph (box location + 19..45) with its bars and manning icon
## above (top bar − 24), and the buttons (solid x 6..33, from y 6, or 19 for button_battery3_base.png; 67 tall)
## except those in `skip` or drawn away from the group (`touch_rects` set: the phone column layout's doors buttons).
func subsystem_bounds(skip: Array = []) -> Rect2:
	var r := Rect2(HudLayout.SUBSYSTEM_BOX + Vector2(6, 6), Vector2(158 + 3 * sub_spacing, 28))
	for id in sub_ids:
		var col: SystemPowerColumn = columns.get(id)
		var sy := ship.sys(id)
		if col == null or sy == null:
			continue
		var top := col.loc.y + SystemPowerColumn.bar_y(sy, maxi(sy.get_level() - 1, 0)) - 24.0
		r = r.merge(Rect2(col.loc.x + 19, top, 26, col.loc.y + 45 - top))
		if buttons.has(id) and not skip.has(id) and (buttons[id] as SystemButton).touch_rects.is_empty():
			var b: Control = buttons[id]
			var inset := 19.0 if id == "battery" else 6.0
			r = r.merge(Rect2(b.position + Vector2(6, inset), Vector2(28, 67)))
	return r


# ---------------------------------------------------------------- wires and subsystem box (back layer)

func _draw() -> void:
	if ship == null:
		return
	var c := reactor.counts() if reactor else Vector3i(ship.reactor_max, ship.reactor_free(), 0)
	var lit := c.y + c.z > 0
	# Reactor wire (hatched edge + outline): dim along the whole column, bright along the free bars
	# (wire_left_mask stencil; WIRE_MASK_BOTTOM checked against the original HUD).
	# RenderPowerBar: wire_full under the stencil of wire_left_mask moved up 9 px per bar (dim: all bars, +1 px;
	# bright: the free bars), drawn where the mask is NOT (STENCIL_USE 0): the mask's slanted lower end gives
	# the wire its finished end at the column top for any reactor size.
	# The stencil is not cleared between the passes: the bright pass draws outside BOTH masks, so the dim mask
	# (raised by the whole column) hides the wire's top end; without it a white stub showed at y 407..431 − 9·free
	# whenever 1–2 bars were free.
	var dim := HudLayout.REACTOR_PITCH * c.x - 1
	_wire_full([dim], Color(1, 1, 1, 0.5))
	if lit:
		_wire_full([dim, HudLayout.REACTOR_PITCH * (c.y + c.z)], Color.WHITE)
	# SystemControl::RenderPowerBar: box k draws the wire piece that leads to box k + 1 (its "/" stub ends under
	# the next icon), so the LAST box draws none (the line stops at its stub: nothing under the weapons panel
	# without a drone system); the piece into the last box is the cap. A weapons box followed by the drones box
	# draws the long wire_456 piece under the weapons panel. The first box's stub is part of wire_full.
	var chain: Array = main_ids.duplicate()
	if ship.sys("weapons") != null and not wire_main_only:
		chain.append("weapons")
	if ship.sys("drones") != null and not drones_stacked and not wire_main_only:
		chain.append("drones")
	for k in chain.size() - 1:
		var id: String = chain[k]
		var last := k == chain.size() - 2
		var rel := ""
		var at := Vector2(box_x.get(id, 0), HudLayout.SYSTEM_BOX_Y) + HudLayout.BOX_WIRE
		if id == "weapons":
			rel = {2: "wireUI/wire_456_2weapon_cap.png", 3: "wireUI/wire_456_3weapon_cap.png"}.get(
				ship.weapon_slots, "wireUI/wire_456_cap.png")
		elif WIDE_BOXES.has(id):
			rel = "wireUI/wire_54_cap.png" if last else "wireUI/wire_54.png"
		else:
			rel = "wireUI/wire_36_cap.png" if last else "wireUI/wire_36.png"
		HudDraw.img(self, rel, at, Color(1, 1, 1, 0.5))
		if lit:
			HudDraw.img(self, rel, at)
	# Subsystems box + label (touch UI: drawn by sub_group).
	if not sub_ids.is_empty() and sub_group == null:
		_subsystem_box(self)
	Hooks.emit(&"hud_draw.systems_bar", self, ship)


var _wire_cache := {}  # mask shifts (px) -> ImageTexture of wire_full minus the masks


## wire_full.png at WIRE_FULL with wire_left_mask.png (opaque pixels) cut out at WIRE_MASK − (0, shift) for every
## shift (stencil bits accumulate over the passes of a frame).
func _wire_full(shifts: Array, color: Color) -> void:
	var key := str(shifts)
	var t: Texture2D = _wire_cache.get(key)
	if t == null:
		t = masked_wire(shifts)
		if t == null:
			return
		_wire_cache[key] = t
	draw_texture(t, HudLayout.WIRE_FULL, color)


static func masked_wire(shifts: Array) -> ImageTexture:
	var img := masked_wire_image(shifts)
	return ImageTexture.create_from_image(img) if img != null else null


## The pixels of masked_wire (read from the files: a texture's image is empty under the headless renderer).
static func masked_wire_image(shifts: Array) -> Image:
	var img := Image.load_from_file(FtlData.root.path_join("img/wireUI/wire_full.png"))
	if img == null:
		return null
	img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	var m := Image.load_from_file(FtlData.root.path_join("img/wire_left_mask.png"))
	if m != null:
		m.decompress()
		m.convert(Image.FORMAT_RGBA8)
	for shift in shifts:
		if m == null:
			break
		var off := Vector2i(HudLayout.WIRE_MASK - HudLayout.WIRE_FULL) - Vector2i(0, int(shift))
		for y in m.get_height():
			var wy := y + off.y
			if wy < 0 or wy >= img.get_height():
				continue
			for x in m.get_width():
				var wx := x + off.x
				if wx < 0 or wx >= img.get_width() or m.get_pixel(x, y).a < 0.5:
					continue
				img.set_pixel(wx, wy, Color(0, 0, 0, 0))
	return img


func _draw_sub_group() -> void:
	if not sub_ids.is_empty():
		_subsystem_box(sub_group)


## box_subsystems4.png, its middle stretched by sub_spacing per gap, and the SUBSYSTEMS label.
func _subsystem_box(ci: CanvasItem) -> void:
	var p := HudLayout.SUBSYSTEM_BOX
	if sub_spacing <= 0:
		HudDraw.img(ci, "box_subsystems4.png", p)
	else:
		HudDraw.three_slice(ci, "box_subsystems4.png", p, 170 + 3 * sub_spacing, 60, 60)
	HudDraw.text(ci, 62, HudDraw.txt("subsystems_label"),
		HudLayout.SUBSYSTEM_LABEL + Vector2(1.5 * sub_spacing, 0), HudLayout.BUTTON_TEXT_LIGHT, 1)
