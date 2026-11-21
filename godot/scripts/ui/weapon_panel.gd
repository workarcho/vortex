class_name WeaponPanel
extends Control
## Weapons panel (FTL WeaponControl / ArmamentControl; rules/hud_layout.md): holder image
## box_weapons_bottom<slots>.png at (weapons system box x + 32, 607), the label tab with "WEAPONS", one
## WeaponBox per slot at (16 + 97·i, 16), the AUTOFIRE text button (> 2 slots) and the panel warnings.
## The weapons system box (SystemPowerColumn, bars only) sits at the system box location left of it.
## Only draws and forwards actions to the WeaponControl.
## Touch UI (`vertical`, main.gd `_touch_layout`): the same pieces stacked in a column — a horizontal weapons
## power row on top (system symbol at the left, the bars side by side, sized for the system's maximum level),
## the slots one under another (each box unchanged, 95×39) inside a tight 9-sliced holder frame, AUTOFIRE right
## under it. Local size `v_size` (width = max(power row, framed slot, AUTOFIRE)); main.gd positions and scales
## the panel. No SystemPowerColumn there (no manning / status icons or repair progress yet); the row's hit area
## is a PowerRowHit (`power_hit`: tap = power the next weapon (− mode: depower the last), right click = depower
## the last, system tooltip). All hit areas are child Controls, so they follow the panel's scale and position.

var control: WeaponControl
var column: SystemPowerColumn
var boxes: Array[WeaponBox] = []
var autofire_btn: Control
var power_hit: PowerRowHit = null  # vertical (touch): the power row's hit area
var drag: ArmamentDrag
var reactor: ReactorColumn = null  # the reactor column (NOT ENOUGH POWER comes from ShipState.failed_powerup)
var slots := 4
## WeaponControl::missileMessage / systemMessage (rules/power.md "Related click feedback"): font 59, centred,
## 2.0 s, no flash; each stops the other. The system message's text depends on why the weapon did not fit.
var missile_msg := WarningMessage.new("warning_no_missiles", Vector2(203, -25), 2.0, true)
var system_msg := WarningMessage.new("warning_no_system_power", Vector2(220, -45), 2.0, true)
var _time := 0.0
var _auto_hover := false
var vertical := false

# Vertical (touch) layout, panel-local px at scale 1 (main.gd scales the whole panel).
# Power row: the symbol's solid glyph (s_<sys>_<colour>1.png, alpha > 0.5: x / y 19..44 of 64) sets the row; its
# soft glow (alpha ≤ 0.5, out to 5..59) may spill over the neighbours.
const V_ROW_H := 26
const V_SYMBOL_OFF := Vector2(-19, -19)  # 64×64 symbol drawn here so its glyph starts at the row origin
const V_BARS_X := 30  # first bar (6×16: the 16×6 PC bar turned upright), pitch 8, centred on the glyph
const V_BAR := Vector2(6, 16)
# Packed as tightly as the art allows (mobile layout rule: no spacing beyond what the art needs).
const V_PAD := 3  # holder border (2) + padding (1) around the slot boxes
const V_BOX_GAP := 1
const V_FRAME_GAP := 1  # power row bottom -> holder border top (the holder glow overlaps the symbol's)
const V_AUTOFIRE_GAP := 0  # holder border bottom -> AUTOFIRE solid outline top (touching)
# box_weapons_autofire_base.png (37 × 50, drawn as caps 17 | 1 stretched | 19, `draw_autofire`, total width text + 33):
# the solid outline spans x 7 .. w − 11 and y 8..37 (outside it only a faint glow, alpha ≤ 0.2).
const V_AUTOFIRE_TRIM := Vector2(7, 8)  # solid outline's left / top inset
const V_AUTOFIRE_TRIM_R := 10.0  # right inset
const V_AUTOFIRE_H := 30.0  # solid outline height
const AUTOFIRE_MARGIN := 8.0  # AUTOFIRE TextButton width = text width + 8
const AUTOFIRE_BASE_EXTRA := 33.0  # base art width = text width + 33 (p.x − 11 .. p.x + text + 8 + 14)
const AUTOFIRE_BASE_OFFSET := Vector2(11, 10)  # button position inside its base art
const AUTOFIRE_OFF := Color8(164, 171, 160)  # COLOR_BUTTON_OFF
var v_size := Vector2(128, 300)
var v_row := Vector2.ZERO  # power row origin
var v_row_w := 0.0
var v_max_level := 8
var v_auto_k := 1.0  # AUTOFIRE scale: its visible base is exactly as wide as the holder


## `box_loc` = the weapons system box location (frame coordinates).
## `vertical` = the touch column layout (box_loc unused; the owner places the panel).
func setup(ctrl: WeaponControl, box_loc := Vector2(202, HudLayout.SYSTEM_BOX_Y), vert := false) -> void:
	control = ctrl
	vertical = vert
	slots = clampi(control.ship.weapon_slots, 2, 4)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if vertical:
		_v_layout()
	else:
		position = Vector2(box_loc.x + HudLayout.HOLDER_X, HudLayout.ARMAMENT_Y)
		size = Vector2(SystemsBar.holder_width(slots), 88)

	if not vertical:
		column = SystemPowerColumn.new()
		column.setup(control.ship, "weapons", false, box_loc - position)
		add_child(column)
	else:
		power_hit = PowerRowHit.new()
		power_hit.setup(control.ship, "weapons", v_row_rect(), TouchPowerToggle.route0(_row_power_up, _row_power_down),
			_row_power_down)
		add_child(power_hit)

	# Box click: touch − mode (TouchPowerToggle) depowers instead of power / arm.
	drag = ArmamentDrag.new(TouchPowerToggle.route(control.select, control.depower), control.swap, control.depower)
	for i in control.ship.weapon_slots:
		var b := WeaponBox.new()
		b.index = i
		b.weapon = control.weapon(i)
		b.drag = drag
		b.position = HudLayout.BOX_ORIGIN + Vector2(HudLayout.BOX_STEP * i, 0)
		if vertical:
			b.position = v_frame().position + Vector2(V_PAD, V_PAD + (HudLayout.BOX_SIZE.y + V_BOX_GAP) * i)
		add_child(b)
		boxes.append(b)
	drag.boxes = boxes

	# AUTOFIRE (ships with > 2 weapon slots; rules/weapon_controls.md, rules/hud_layout.md): a TextButton
	# (text width + 8) × 24 whose right edge is at 311 / 408, y 63, on a 3-slice base (WeaponControl::OnLanguageChange).
	autofire_btn = Control.new()
	var tw := FtlData.ftl_text_width(62, HudDraw.txt("button_autofire"))
	autofire_btn.position = Vector2(HudLayout.AUTOFIRE_RIGHT.get(slots, 408) - tw - AUTOFIRE_MARGIN,
		HudLayout.AUTOFIRE_Y)
	if vertical:
		var ar := v_autofire_rect()
		autofire_btn.position = ar.position
		autofire_btn.size = ar.size
		# Warnings centred under the column (font 59 text is wider than the column; it overhangs both sides).
		missile_msg.position = Vector2(v_size.x / 2, v_size.y + 10)
		system_msg.position = Vector2(v_size.x / 2, v_size.y + 30)
	if not vertical:
		autofire_btn.size = Vector2(tw + AUTOFIRE_MARGIN, 24)
	autofire_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	autofire_btn.visible = control.ship.weapon_slots > 2
	autofire_btn.gui_input.connect(_autofire_input)
	autofire_btn.mouse_entered.connect(func(): _auto_hover = true)
	autofire_btn.mouse_exited.connect(func(): _auto_hover = false)
	add_child(autofire_btn)

	control.message.connect(_on_message)
	Hooks.emit(&"hud_ready", "weapon_panel", self, control.ship)


func _autofire_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		control.toggle_autofire()  # toggles on press (CombatControl::MouseClick)
		autofire_btn.accept_event()


## Click feedback (WeaponControl::SelectArmament): "reactor" shows nothing here (the rule layer set
## ShipState.failed_powerup: NOT ENOUGH POWER over the reactor); "locked" = fail sound only (SystemLocked).
func _on_message(reason: String, sound: String) -> void:
	FtlData.play(sound)
	match reason:
		"no_missiles":
			system_msg.stop()
			missile_msg.start()
		"no_power":
			missile_msg.stop()
			var w := control.failed_weapon
			if not system_msg.running():
				system_msg.text_id = system_message_id(control.ship.sys("weapons"), control.ship.weapons_power_used(),
					w.power_cost() if w else 1)
			system_msg.start()


## WeaponControl / DroneControl systemMessage text (rules/power.md "Related click feedback"): the system level
## is below the item's power -> warning_needs_upgrade; the system's free bars (level - power in use) are short,
## or it is undamaged -> warning_no_system_power; otherwise damage is what blocks it -> warning_system_broken.
static func system_message_id(s: SystemState, used: int, required: int) -> String:
	if s == null:
		return "warning_no_system_power"
	if s.get_level() < required:
		return "warning_needs_upgrade"
	if s.get_level() - used < required or s.damage == 0:
		return "warning_no_system_power"
	return "warning_system_broken"


func _process(delta: float) -> void:
	_time += delta
	var ship := control.ship
	var wl := ship.crew_level_in("weapons")
	var auto := ship.autofire != Input.is_key_pressed(KEY_SHIFT)
	var ws := ship.sys("weapons")
	var hl := ws.hack_effect() if ws != null else 0  # WeaponSystem::OnLoop -> ProjectileFactory::SetHacked
	# WeaponControl::OnRender (with a weapons system): every box's cooldownMax = WeaponSystem::GetMaxCooldown.
	var cm := WeaponBox.max_cooldown(ship.weapons, wl) if ws != null else WeaponBox.COOLDOWN_MAX
	for b in boxes:
		b.hack_level = hl
		b.cooldown_max = cm
		b.weapon = control.weapon(b.index)  # slot order may change (drag swap)
		b.crew_level = wl
		b.selected = control.armed == b.index
		b.auto_armed = b.selected and auto
	if autofire_btn.visible and TooltipService.over(autofire_btn, Rect2(Vector2.ZERO, autofire_btn.size)):
		TooltipService.request(TooltipText.simple("button", "tooltip_autofire", {"key": "autofire",
			"key2": "force_autofire"}), {"kind": &"button", "source": autofire_btn, "ctx": {"button": "autofire"}})
	missile_msg.update(delta)
	system_msg.update(delta)
	queue_redraw()


func _draw() -> void:
	if vertical:
		_draw_power_row()
		draw_vertical_holder(self, v_frame())
	else:
		draw_holder(self, slots, HudDraw.txt("weapons_label"))
	if autofire_btn.visible and vertical:
		_draw_v_autofire()
	elif autofire_btn.visible:
		draw_autofire(self, autofire_btn.position, control.ship.autofire, _auto_hover)
	missile_msg.draw(self)
	system_msg.draw(self)
	Hooks.emit(&"hud_draw.weapon_panel", self, control.ship)


## Holder image + label tab (ArmamentControl::CreateHolderTab) + label text at (19, 60).
static func draw_holder(ci: CanvasItem, n_slots: int, label: String) -> void:
	var holder := "box_weapons_bottom%d.png" % clampi(n_slots, 2, 4)
	var hw := SystemsBar.holder_width(n_slots)
	HudDraw.img(ci, holder, Vector2.ZERO)
	var t := HudDraw.tex("box_weapons_bottom_label.png")
	var tw := FtlData.ftl_text_width(62, label)
	if t:
		var y := HudLayout.LABEL_TAB_Y
		ci.draw_texture_rect_region(t, Rect2(18, y, 3, 27), Rect2(0, 0, 3, 27))
		ci.draw_texture_rect_region(t, Rect2(21, y, tw - 11, 27), Rect2(3, 0, 1, 27))
		ci.draw_texture_rect_region(t, Rect2(tw + 10, y, 35, 27), Rect2(4, 0, 35, 27))
		ci.draw_texture_rect_region(t, Rect2(tw + 45, y, maxf(hw - (tw + 45) - 13, 0), 27), Rect2(39, 0, 1, 27))
	HudDraw.text(ci, 62, label, HudLayout.LABEL_TEXT, HudLayout.BUTTON_TEXT_LIGHT)


## Vertical (touch) layout, packed as tightly as the art allows: width = max(power row for the weapons system's
## maximum level, framed slot box); power row at the top-left, holder V_FRAME_GAP under it and right-aligned (the
## column's right edge is the holder border, flush against the TARGET art), AUTOFIRE scaled to the holder width
## right under it. The maximum level is the ship's `max=` or the system blueprint's maxPower (8 in vanilla).
func _v_layout() -> void:
	v_max_level = v_level_max(control.ship, "weapons")
	v_row_w = v_row_width(v_max_level)
	v_size.x = ceilf(maxf(v_row_w, v_holder_w()))
	v_row = Vector2.ZERO
	var tw := FtlData.ftl_text_width(62, HudDraw.txt("button_autofire"))
	v_auto_k = v_holder_w() / (tw + AUTOFIRE_BASE_EXTRA - V_AUTOFIRE_TRIM.x - V_AUTOFIRE_TRIM_R)
	var bottom := v_frame().end.y
	if control.ship.weapon_slots > 2:
		bottom += v_autofire_rect().size.y
	v_size.y = ceilf(bottom)
	size = v_size


## Vertical (touch) holder border rect (2 px border included) around the weapon boxes, panel-local.
func v_frame() -> Rect2:
	var n := maxi(control.ship.weapon_slots if control else 4, 1)
	return Rect2(v_size.x - v_holder_w(), V_ROW_H + V_FRAME_GAP, v_holder_w(), v_holder_h(n))


## Visible AUTOFIRE base (vertical): the holder's width, right under the holder border.
func v_autofire_rect() -> Rect2:
	var f := v_frame()
	return Rect2(f.position.x, f.end.y + V_AUTOFIRE_GAP, f.size.x, V_AUTOFIRE_H * v_auto_k)


## The pointer (screen point) is over the panel as drawn (vertical: power row, holder, AUTOFIRE; else the
## panel rect), tested in the panel's own coordinates. main.gd `_over_hud_panel` (touch UI).
func hud_hit(screen: Vector2) -> bool:
	var rects: Array[Rect2] = [Rect2(Vector2.ZERO, size)]  # typed: an untyped literal failed panel_hit's argument
	if vertical:
		rects = v_blocks()
	return panel_hit(self, screen, rects)


static func panel_hit(c: Control, screen: Vector2, rects: Array[Rect2]) -> bool:
	if not c.is_visible_in_tree():
		return false
	var p := c.get_global_transform().affine_inverse() * screen
	return rects.any(func(r: Rect2) -> bool: return r.has_point(p))


## Vertical power row rect (symbol glyph + bars for the maximum level), panel-local: its hit area.
func v_row_rect() -> Rect2:
	return Rect2(v_row, Vector2(v_row_w, V_ROW_H))


## Power row tap: power the first unpowered weapon in slot order (WeaponControl.select on an unpowered box).
func _row_power_up() -> void:
	for i in control.ship.weapons.size():
		var w := control.weapon(i)
		if w != null and not w.powered:
			control.select(i)
			return
	FtlData.play("powerUpFail")


## Power row right click / − mode tap: depower the last powered weapon in slot order.
func _row_power_down() -> void:
	for i in range(control.ship.weapons.size() - 1, -1, -1):
		var w := control.weapon(i)
		if w != null and w.powered:
			control.depower(i)
			return


## Panel-local rects actually drawn (power row, holder + AUTOFIRE): what the player ship's nose must not cross.
func v_blocks() -> Array[Rect2]:
	var f := v_frame()
	return [Rect2(v_row, Vector2(v_row_w, V_ROW_H)), Rect2(f.position, Vector2(f.size.x, v_size.y - f.position.y))]


## AUTOFIRE (vertical): the PC base 3-slice + text drawn at v_auto_k so the visible base spans the holder.
func _draw_v_autofire() -> void:
	var ar := v_autofire_rect()
	draw_set_transform(ar.position - V_AUTOFIRE_TRIM * v_auto_k, 0.0, Vector2(v_auto_k, v_auto_k))
	draw_autofire(self, AUTOFIRE_BASE_OFFSET, control.ship.autofire, _auto_hover)
	draw_set_transform(Vector2.ZERO)


## The AUTOFIRE button at button position `p` (WeaponControl::OnLanguageChange / SetAutofiring, OnRender):
## base `box_weapons_autofire_base.png` (37 × 50) in three parts — left cap texels 0..17 at p − (11, 10), the
## middle texel column 17 stretched to (text width − 3) at p.x + 6, right cap texels 18..37 (19 px) at
## p.x + button width − 5 — then the TextButton (text width + 8) × 24, corner inset 4, font 62: plate
## COLOR_BUTTON_SELECT while autofire is on, COLOR_BUTTON_OFF while off, hovered = that colour 40 % of the way to
## white (SetSelectedColor), label COLOR_BUTTON_TEXT.
static func draw_autofire(ci: CanvasItem, p: Vector2, on: bool, hover: bool) -> void:
	var label := HudDraw.txt("button_autofire")
	var tw := FtlData.ftl_text_width(62, label)
	var bw := tw + AUTOFIRE_MARGIN
	var t := HudDraw.tex("box_weapons_autofire_base.png")
	if t:
		var y := p.y - 10
		ci.draw_texture_rect_region(t, Rect2(p.x - 11, y, 17, 50), Rect2(0, 0, 17, 50))
		ci.draw_texture_rect_region(t, Rect2(p.x + 6, y, maxf(tw - 3, 0), 50), Rect2(17, 0, 1, 50))
		ci.draw_texture_rect_region(t, Rect2(p.x + bw - 5, y, 19, 50), Rect2(18, 0, 19, 50))
	var fill := MenuDraw.COL_SELECT if on else AUTOFIRE_OFF
	if hover:
		fill = fill.lerp(Color.WHITE, 0.4)
	MenuDraw.text_button(ci, {"rect": Rect2(p, Vector2(bw, 24)), "label": label, "font": 62, "fill": fill}, false)


## Vertical (touch) power row of `sys_id`: its symbol (or lock timer) at the left, then one upright bar per
## system level left to right (ShipSystem::RenderPowerBoxes colours / states, turned 90°). Shared with DronePanel.
func _draw_power_row() -> void:
	draw_power_row(self, control.ship.sys("weapons"), v_row, _time, control.ship)


static func draw_power_row(ci: CanvasItem, s: SystemState, origin: Vector2, time: float, sh: ShipState = null) -> void:
	if s == null:
		return
	var l := origin + V_SYMBOL_OFF
	if s.ion >= 1:
		SystemPowerColumn.draw_lock_timer(ci, s, l)
	else:
		var sym := s.symbol_texture(time)
		if sym:
			ci.draw_texture(sym, l)
	# The PC column's states (SystemPowerColumn.draw_box), turned 90°: bar i left to right; the repair progress
	# (yellow) on the lowest broken bar grows up from its bottom, the damage progress (fire / sabotage, red) on the
	# top working bar grows down from its top; the lock outline (ion / lock / hack) around the bars; then, right of
	# the last bar, the manning icon and the lock / hacked / sabotage / fire icons in a row.
	var n := s.get_level()
	var usable := n - s.damage
	var dmg := SystemPowerColumn.partial_damage(sh, s)
	var y := origin.y + (V_ROW_H - V_BAR.y) / 2
	for i in n:
		var r := Rect2(origin.x + V_BARS_X + 8 * i, y, V_BAR.x, V_BAR.y)
		FtlColors.draw_power_bar(ci, r, SystemPowerColumn.bar_draw_state(s, i))
		if i == usable and s.repair_progress > 0.0:
			var f := clampf(s.repair_progress / 100.0, 0.0, 1.0)
			ci.draw_rect(Rect2(r.position.x, r.end.y - r.size.y * f, r.size.x, r.size.y * f), FtlColors.YELLOW)
		if i == usable - 1 and dmg > 0.0:
			ci.draw_rect(Rect2(r.position, Vector2(r.size.x, r.size.y * dmg)), FtlColors.RED)
	var x := origin.x + V_BARS_X + 8 * n  # right of the last bar (+ 2 px)
	var outline := FtlColors.lock_outline(s)
	if outline.a > 0.0 and n > 0:
		FtlColors.draw_bar_outline(ci, Rect2(origin.x + V_BARS_X - 3, y - 3, 8 * n - 2 + 6, V_BAR.y + 6), outline,
			2.0)
		x += 2
	var mid := origin.y + V_ROW_H / 2.0
	var man := SystemPowerColumn.manning_icon(sh, s)
	if not man.is_empty():
		var t := HudDraw.tex("systemUI/%s.png" % man[0])
		if t:
			ci.draw_texture(t, Vector2(x, roundf(mid - t.get_height() / 2.0)))
			x += t.get_width() + 1
	var icons := []
	if s.is_ionized() or s.ion < 0:
		icons.append("icons/locking/s_lock_white.png" if s.ion < 0 else "icons/locking/s_lock.png")
	if s.hack_effect() > 0:
		icons.append("icons/s_hacked.png")
	if sh != null and s.sabotaged():
		icons.append("icons/s_sabatoge.png")
	if sh != null and sh.fires.has(s.room) and not (sh.fires[s.room] as Dictionary).is_empty():
		icons.append("icons/s_fire2.png")
	for ic in icons:
		var t := HudDraw.tex(ic)
		if t:
			ci.draw_texture(t, Vector2(x, roundf(mid - t.get_height() / 2.0)))
			x += t.get_width() + 1


## Vertical column sizes shared with DronePanel.
static func v_level_max(ship: ShipState, sys_id: String) -> int:
	var sy := ship.sys(sys_id)
	var m := maxi(UpgradeSession.max_level(ship, sys_id), sy.get_level() if sy else 1)
	return m if m > 0 else 8


static func v_row_width(max_level: int) -> float:
	return V_BARS_X + 8 * max_level - 2


static func v_holder_w() -> float:
	return HudLayout.BOX_SIZE.x + 2 * V_PAD


static func v_holder_h(n: int) -> float:
	return 2 * V_PAD + HudLayout.BOX_SIZE.y * n + V_BOX_GAP * (n - 1)


## The PC holder image (box_weapons_bottom4.png, 419 wide: glow 10 px left / top and 7 px right, 2 px border at
## x 10..411 / y 10..60, label notch under the bottom-left) 9-sliced around `frame` (the border rect) for the
## vertical touch column: 16 px corners from the image's top corners, 1 px edge / centre samples stretched; the
## bottom row is the top row mirrored (the image's own bottom-left carries the label notch). No label tab. The
## border lands exactly on `frame` on every side (no interior strip beyond the slots).
static func draw_vertical_holder(ci: CanvasItem, frame: Rect2) -> void:
	var t := HudDraw.tex("box_weapons_bottom4.png")
	if t == null:
		return
	const M := 16.0  # corner / edge thickness incl. the 10 px glow
	const G := 10.0  # glow outside the border (left, top; bottom = mirrored top)
	var tw := float(t.get_width())
	var gr := tw - 412.0  # glow right of the border (7 px)
	var d := Rect2(frame.position - Vector2(G, G), frame.size + Vector2(G + gr, 2 * G))
	var mid_w := maxf(d.size.x - 2 * M, 0.0)
	var mid_h := maxf(d.size.y - 2 * M, 0.0)
	# Middle band: left edge, centre, right edge (sampled at row 30).
	ci.draw_texture_rect_region(t, Rect2(d.position + Vector2(0, M), Vector2(M, mid_h)), Rect2(0, 30, M, 1))
	ci.draw_texture_rect_region(t, Rect2(d.position + Vector2(M, M), Vector2(mid_w, mid_h)), Rect2(200, 30, 1, 1))
	ci.draw_texture_rect_region(t, Rect2(d.position + Vector2(M + mid_w, M), Vector2(M, mid_h)),
		Rect2(tw - M, 30, M, 1))
	# Top row, then the same row mirrored about the bottom edge.
	for flip in [false, true]:
		if flip:
			ci.draw_set_transform(Vector2(d.position.x, d.end.y), 0.0, Vector2(1, -1))
		else:
			ci.draw_set_transform(d.position)
		ci.draw_texture_rect_region(t, Rect2(0, 0, M, M), Rect2(0, 0, M, M))
		ci.draw_texture_rect_region(t, Rect2(M, 0, mid_w, M), Rect2(200, 0, 1, M))
		ci.draw_texture_rect_region(t, Rect2(M + mid_w, 0, M, M), Rect2(tw - M, 0, M, M))
	ci.draw_set_transform(Vector2.ZERO)


## A box is being dragged (crew hover / drag selection frozen meanwhile).
func dragging() -> bool:
	return drag.dragging and drag.slot >= 0
