class_name WeaponBox
extends Control
## One weapon slot of the weapons panel (FTL WeaponBox / ArmamentBox, 95×39; rules/hud_layout.md): grey
## background from x 8, 2 px status-coloured outline, hotkey frame (83, 24), power bars (16×7, pitch 8) up
## from (12, 28), charge bar on the left edge, short name at (34, 3) in font 7 (easy_printAutoNewlines, wrap 55,
## left-aligned), `Missile.png` at (39, 10), charge-level pips and the chain boost icon (WeaponBox::RenderBox,
## rules/hud_layout.md "Weapon box details"). Mouse events go to the panel's ArmamentDrag (click on release, drag
## to swap, right click = depower); never changes game state by itself.

const X_OFFSET := 8  # ArmamentBox boxOffset for weapons
const NAME_OFFSET := Vector2(34, 3)
const NAME_WIDTH := 55
const MISSILE_ICON := "Missile.png"  # 32×32, drawn at (39, 10) in the status colour
const MISSILE_POS := Vector2(39, 10)
const PIP_ORIGIN := Vector2i(34, 19)  # RenderBox local point for the charge pips and the boost icon
const PIP_STEP := 11
# WeaponBox::StatusColor
const COL_EMPTY := Color8(190, 190, 190)
const COL_OFF := Color8(150, 150, 150)
const COL_CHARGING := Color8(243, 255, 230)
const COL_READY := Color8(120, 255, 120)
const COL_ARMED := Color8(255, 120, 120)
# WeaponBox::UpdateCooldownBox (rules/hud_layout.md "Weapon box charge bar"): cooldownMax (constructor value; every
# frame WeaponControl::OnRender overwrites it with WeaponSystem::GetMaxCooldown, see `cooldown_max`) and the box /
# icon maximum heights (consts 0x82fa24 / 0x82fa28).
const COOLDOWN_MAX := 30.0
const MAX_COOLDOWN_START := -100.0  # WeaponSystem::GetMaxCooldown start value (const 0x837fe0)
const COOLDOWN_H := 33.0
const COOLDOWN_H_ICON := 22.0
const SPARK_W := 69  # ArmamentBox::OnLoop hackAnimation MaskX(0, 69) / MaskY(rand % 31, 39)
const SPARK_H := 39

var index := 0
var weapon: WeaponState = null  # null = empty slot
var crew_level := 0
## WeaponBox::cooldownMax (+0x1c4): 30 from the constructor, then set every frame by the panel (WeaponControl::OnRender
## before the boxes render) to `max_cooldown` of the ship's weapons.
var cooldown_max := COOLDOWN_MAX
var selected := false
var auto_armed := false  # armed and will autofire (yellow)
var drag: ArmamentDrag = null
var dragged := false  # being dragged: drawn at drag_offset, the slot shows empty (RenderDragging)
var drag_offset := Vector2.ZERO
var hovered := false
var flash_power := 0.0  # s left of the "not enough power" red flash on the power bars
var hack_level := 0  # ProjectileFactory::iHackLevel = the weapons system's IsSystemHacked (set by the panel)
var sparks := {}  # hackAnimation state (stun_spark_big while GetHacked), see update_sparks
var _time := 0.0


func _init() -> void:
	size = HudLayout.BOX_SIZE
	custom_minimum_size = HudLayout.BOX_SIZE


func has_item() -> bool:
	return weapon != null


func _process(delta: float) -> void:
	_time += delta
	flash_power = maxf(flash_power - delta, 0.0)
	# ArmamentControl::OnLoop: hovered non-empty box, not being dragged -> description + hotkey lines, W300.
	if weapon and not dragged and not (drag and drag.dragging) and TooltipService.over(self, Rect2(Vector2.ZERO, size)):
		TooltipService.request(TooltipText.weapon_box(weapon, index), {"width": TooltipService.WRAP_BOX,
			"kind": &"weapon", "source": self, "ctx": {"weapon": weapon, "slot": index}})
	z_index = 1 if dragged else 0
	update_sparks(sparks, weapon != null and hack_level > 1, _time)  # WeaponBox::GetHacked
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
	if weapon == null:
		return COL_EMPTY
	if selected:
		return FtlColors.YELLOW if auto_armed else COL_ARMED
	if not weapon.powered:
		return COL_OFF
	if hack_level > 1:
		return FtlColors.PURPLE_HACK
	if weapon.is_charged(crew_level):
		return COL_READY
	return COL_CHARGING


func _draw() -> void:
	if dragged:
		draw_empty(self)  # the slot stays empty; the box follows the cursor
		draw_set_transform(drag_offset)
	if weapon == null:
		draw_empty(self)
		return
	var col := status_color()
	draw_frame(self, X_OFFSET, col, hovered and not dragged, str(index + 1))
	# Power bars (16×7, gap 1) up from (xOffset + 4, 28); red flash when power is lacking.
	for i in weapon.power_cost():
		var r := Rect2(X_OFFSET + 4, 28 - 8 * i, 16, 7)
		if i >= weapon.power_cost() - weapon.bonus_power:
			draw_rect(r, FtlColors.BONUS)  # zoltan bonus bars (WeaponBox::GetBonusPower), on top
		elif weapon.powered:
			draw_rect(r, FtlColors.GREEN)
		else:
			draw_rect(r.grow(-0.5), Color.WHITE, false, 1.0)
		if flash_power > 0.0 and fmod(_time, 0.75) < 0.375:
			draw_rect(r, Color(1, 0, 0, 0.8))
	# Charge bar (UpdateCooldownBox + RenderBox): its height follows the weapon's charge time.
	draw_cooldown_box(self, cooldown_height(weapon, crew_level, COOLDOWN_H, cooldown_max), weapon.ratio(crew_level),
		col, fill_color(col))
	# Name (font 7, wraps at 55; RenderLabels).
	HudDraw.text(self, 7, weapon.short_name(), NAME_OFFSET, col, 0, NAME_WIDTH)
	# Missile icon (moved up 4 px when charge pips share the box).
	if weapon.uses_missiles():
		var dy := -4.0 if weapon.charge_levels() >= 2 else 0.0
		HudDraw.img(self, MISSILE_ICON, MISSILE_POS + Vector2(0, dy), col)
	for p in charge_pips(weapon.charge_levels(), weapon.charge_level, weapon.powered, weapon.uses_missiles()):
		HudDraw.img(self, "combatUI/icon_chain_%s.png" % p.state, p.pos, Color.WHITE if p.state == "off" else col)
	var bi := boost_icon(weapon.bp.get("boost", {}), weapon.boost_level, weapon.powered)
	if not bi.is_empty():
		HudDraw.img(self, bi.img, bi.pos, col if bi.on else Color.WHITE)
		if bi.text != "":
			HudDraw.text(self, 7, bi.text, bi.text_pos, Color.WHITE)
	draw_sparks(self, sparks)
	Hooks.emit(&"hud_draw.weapon_box", self, weapon, crew_level)


## Fill colour of the charge bar (WeaponBox::RenderBox): the status colour, unless the weapon has targets
## (ProjectileFactory::targets not empty): (255, 120, 120), or COLOR_YELLOW when it is autofiring.
func fill_color(col: Color) -> Color:
	if weapon == null or not weapon.has_target():
		return col
	return FtlColors.YELLOW if weapon.autofire else COL_ARMED


## Rounds to a 32-bit float (the exe computes the charge bar height in single precision).
static func f32(x: float) -> float:
	return PackedFloat32Array([x])[0]


## WeaponBox::UpdateCooldownBox: height = int(cooldown.second / cooldownMax × maxHeight × cooldownModifier),
## at least 1. cooldown.second = the current charge time (blueprint cooldown − chain boost, × modifier) and
## cooldownModifier = the manning skill bonus (artillery: 1.5 − 0.25 × power). cooldownMax = `max_cooldown` of the
## ship's weapons (WeaponControl::OnRender, every frame): the slowest weapon's bar is 33 × modifier tall and the
## others are in proportion (Kestrel: Burst II 12 s 33 px, Artemis 11 s 30 px); a chain laser's bar shrinks as its
## boost lowers its charge time (unless it is the slowest). `max_h` = 33 (weapon box) or 22 (icon form).
static func cooldown_height(w: WeaponState, crew_level: int, max_h := COOLDOWN_H, cooldown_max := COOLDOWN_MAX) -> int:
	var second := f32(w.max_charge(crew_level))
	var m := f32(w.charge_modifier(crew_level))
	return maxi(int(f32(f32(f32(second / f32(cooldown_max)) * max_h) * m)), 1)


## WeaponSystem::GetMaxCooldown: the largest cooldown.second (current charge time) of the system's weapons, powered
## or not; MAX_COOLDOWN_START (−100) without weapons. `weapons` may hold nulls (empty slots, skipped).
static func max_cooldown(weapons: Array, crew_level: int) -> float:
	var m := MAX_COOLDOWN_START
	for w in weapons:
		if w != null:
			m = maxf(m, f32((w as WeaponState).max_charge(crew_level)))
	return m


## The cooldown box primitives of UpdateCooldownBox (forIcon = false, p = (0, 0)) and the bar of RenderBox:
## outline (0, y, 10, h + 6) 2 px with y = 33 − h; when y > 0 a 45° shoulder from (1, y) up to the right
## (triangle (1, y), (t + 1, y − t), (t + 1, y), t = min(y, 8)) plus, when y < 8, the rect (t + 1, 0, 8 − t, t)
## that fills the corner up to the box top; all in the status colour. The fill rect (3, −h, 4, h) is drawn
## translated to (0, 36) and scaled by the charge fraction, i.e. it grows up from y 36.
static func draw_cooldown_box(ci: CanvasItem, h: int, frac: float, col: Color, fill: Color) -> void:
	var y := int(COOLDOWN_H - h)
	ci.draw_rect(Rect2(1, y + 1, 8, h + 4), col, false, 2.0)
	if y != 0:
		var t := mini(y, 8)
		ci.draw_colored_polygon(PackedVector2Array([Vector2(t + 1, y), Vector2(t + 1, y - t), Vector2(1, y)]), col)
		if t != 8:
			ci.draw_rect(Rect2(t + 1, y - t, 8 - t, t), col)
	var fh := float(h) * clampf(frac, 0.0, 1.0)
	if fh > 0.0:
		ci.draw_rect(Rect2(3, 36 - fh, 4, fh), fill)


## ArmamentBox::OnLoop hackAnimation (stun_spark_big, 1 s, 70×70 frames) while the box is hacked (GetHacked:
## hack level > 1): after each run it restarts with a random horizontal mirror, position (rand % 25, 0) and the
## rows rand % 31 .. +39 of the frame (columns 0..69); stopped when no longer hacked. The masked region is drawn
## at the position [inferred: Animation::InitPrimitives not decoded].
static func update_sparks(st: Dictionary, on: bool, t: float) -> void:
	if not on:
		st.clear()
		return
	if st.is_empty():
		st.merge({"start": t, "el": 0.0, "cycle": 0, "mirror": false, "x": 0, "my": 0})
	st.el = t - float(st.start)
	var cycle := int(float(st.el) / 1.0)
	if cycle != int(st.cycle):
		st.cycle = cycle
		st.mirror = randi() % 2 == 1
		st.x = randi() % 25
		st.my = randi() % 31


static func draw_sparks(ci: CanvasItem, st: Dictionary) -> void:
	if st.is_empty():
		return
	var a := FtlData.anim("stun_spark_big")
	if a.is_empty():
		return
	var frames: Array = a.frames
	var src: Rect2 = frames[mini(int(fmod(float(st.el), 1.0) * frames.size()), frames.size() - 1)]
	var reg := Rect2(src.position + Vector2(0, int(st.my)), Vector2(SPARK_W, SPARK_H))
	var dst := Rect2(Vector2(int(st.x), 0), reg.size)
	if st.mirror:
		dst = Rect2(dst.position + Vector2(dst.size.x, 0), Vector2(-dst.size.x, dst.size.y))
	ci.draw_texture_rect_region(a.texture, dst, reg)



## Empty slot: emptyBackground (0, 0, 95, 39) + 2 px outline from the box offset, COL_EMPTY.
static func draw_empty(ci: CanvasItem, x_offset := X_OFFSET) -> void:
	ci.draw_rect(Rect2(0, 0, 95, 39), Color(0.39, 0.39, 0.39, 0.5))
	ci.draw_rect(Rect2(x_offset + 1, 1, 93 - x_offset, 37), COL_EMPTY, false, 2.0)


## Filled box: background (xOffset, 0, 95 − xOffset, 39) at (100,100,100,0.25), hover glow, outline lines
## (x = xOffset+1, top y 1, right x 94, bottom y 38, 2 px) and the hotkey frame (83, 24, 12, 15).
static func draw_frame(ci: CanvasItem, x_offset: int, col: Color, hover: bool, key := "") -> void:
	ci.draw_rect(Rect2(x_offset, 0, 95 - x_offset, 39), Color(0.39, 0.39, 0.39, 0.25))
	if hover:
		var g := HudDraw.tex("bar_weapon_minibox_glow.png")
		if g:
			ci.draw_texture(g, Vector2(-10, -10), col)
	ci.draw_line(Vector2(x_offset + 1, 0), Vector2(x_offset + 1, 39), col, 2.0)
	ci.draw_line(Vector2(x_offset, 1), Vector2(95, 1), col, 2.0)
	ci.draw_line(Vector2(94, 0), Vector2(94, 39), col, 2.0)
	ci.draw_line(Vector2(x_offset, 38), Vector2(95, 38), col, 2.0)
	if key != "":
		ci.draw_rect(Rect2(83, 25, 11, 13), col, false, 2.0)
		HudDraw.text(ci, 5, key, Vector2(83 + hotkey_x_mod(int(key)), 25), col)


## RenderLabels: the hotkey digit (font 5) is printed at x 83 + mod: 5 for "1", 3 for "4" and "7", else 4.
static func hotkey_x_mod(key: int) -> int:
	if key == 1:
		return 5
	if key == 4 or key == 7:
		return 3
	return 4


## Charge-level pips (WeaponBox::RenderBox, only when chargeLevels >= 2): one `icon_chain_<state>.png` (11×9)
## per level, centred for 4 levels from x 34 (x = 34 + ((4 − levels)·6 >> 1) + 11·i), y 25 (26 for missile
## weapons). State: "use" for the stored levels (i < chargeLevel), else "on" when powered, "off" when not.
## "use"/"on" are tinted with the status colour, "off" is white.
static func charge_pips(levels: int, charge_level: int, powered: bool, missiles := false) -> Array:
	var out := []
	if levels < 2:
		return out
	var y := PIP_ORIGIN.y + (7 if missiles else 6)
	var x0 := PIP_ORIGIN.x + (((4 - levels) * 6) >> 1)
	for i in levels:
		var st := "use" if i < charge_level else ("on" if powered else "off")
		out.append({"pos": Vector2(x0 + PIP_STEP * i, y), "state": st})
	return out


## Chain boost icon (WeaponBox::RenderBox, by `<boost><type>`): cooldown -> clock (13×13) at (40, 20), damage
## -> arrow (9×12) at (44, 21). "_on" (status colour) plus "+N" in font 7 (white) at (58, 19) / (55, 20) while
## powered with boost level >= 1, else "_off" (white) without text. N = GetBoostLevel (damage: capped at count).
static func boost_icon(boost: Dictionary, boost_level: int, powered: bool) -> Dictionary:
	if boost.is_empty():
		return {}
	var t := String(boost.get("type", ""))
	var lvl := boost_level
	if t == "damage":
		lvl = mini(lvl, int(boost.get("count", 0)))
	var on := powered and lvl >= 1
	var o := Vector2(PIP_ORIGIN)
	match t:
		"cooldown":
			return {"img": "combatUI/icon_clock_%s.png" % ("on" if on else "off"), "pos": o + Vector2(6, 1),
				"on": on, "text": "+%d" % lvl if on else "", "text_pos": o + Vector2(24, 0)}
		"damage":
			return {"img": "combatUI/icon_arrow_%s.png" % ("on" if on else "off"), "pos": o + Vector2(10, 2),
				"on": on, "text": "+%d" % lvl if on else "", "text_pos": o + Vector2(21, 1)}
	return {}
