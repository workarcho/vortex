class_name ShipStatusHud
extends Control
## Top-left ship status (FTL ShipStatus; rules/hud_layout.md), drawn last above everything: hull frame +
## label + segmented hull bar (colour by absolute hull), shield frame + bubbles + recharge / super-shield
## bars, evade / O2 box, fuel / missiles / drone parts / scrap counters (font 0), and the hull / shields /
## O2 warnings with their lines. Full-frame, mouse-transparent.

const HULL_WARNING_TIME := 6.0

var ship: ShipState
var _t := 0.0
var _hull_warn := ""  # warning_hull_75/50/25 text while running
var _hull_warn_time := 0.0
var _hull_band := 0  # 0 = above 75 %, 1 below 75, 2 below 50, 3 below 25
var _hull_loop := false  # the 25 % warning loops
## Touch UI (main.gd `_touch_layout`): the evade / O2 box drawn this far from its PC place (frame px; the
## tooltip and the O2 warning lines stay at the PC place).
var evade_offset := Vector2.ZERO


## Resource change popups (ShipStatus::RenderResources): each frame the four counts are compared with last
## frame's; a change spawns a DamageMessage(1.0 s, delta, showSign) at fuel (180,104), missiles (247,104),
## drone parts (314,104), scrap (465,70): x jittered by rand(−10..10), white, sinking 10 px over its life (bFloatDown = symbol);
## `numbers/Text_plus|minus.png` at (−50, −46), digits `numbers/Text_<d>_L.png` from (−32, −46), 16 px apart.
## Several changes give several overlapping messages. They run on the HUD clock (also while paused).
## Kept in static state keyed by the ship so a scene rebuild (arrival after a jump) does not lose the change.
const POPUP_POS := {"fuel": Vector2(180, 104), "missiles": Vector2(247, 104), "drone_parts": Vector2(314, 104),
	"scrap": Vector2(465, 70)}
const POPUP_TIME := 1.0
const POPUP_RISE := 10.0
static var _last := {}  # ship instance id -> {kind: last count}
static var popups: Array = []  # [{ship, kind, delta, pos, t}]


func setup(s: ShipState) -> void:
	ship = s
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hull_band = _band()
	if not _last.has(ship.get_instance_id()):
		_last[ship.get_instance_id()] = _counts(ship)


static func _counts(s: ShipState) -> Dictionary:
	return {"fuel": s.fuel, "missiles": s.missiles, "drone_parts": s.drone_parts, "scrap": s.scrap,
		"saved": s.missiles_saved}


## Compares the counts with the last frame's and spawns the popups (pure, testable).
static func poll_resources(s: ShipState) -> Array:
	var id := s.get_instance_id()
	var now := _counts(s)
	var last: Dictionary = _last.get(id, now)
	var spawned := []
	for k in now:
		if int(now[k]) != int(last.get(k, now[k])):
			# EXPLOSIVE_REPLICATOR save (event 12): a "0" message at the missile counter.
			var kind: String = "missiles" if k == "saved" else k
			var m := {"ship": id, "kind": kind, "delta": 0 if k == "saved" else int(now[k]) - int(last[k]),
				"t": 0.0, "pos": POPUP_POS[kind] + Vector2(randi() % 21 - 10, 0)}
			popups.append(m)
			spawned.append(m)
	_last[id] = now
	return spawned


static func tick_popups(delta: float) -> void:
	for i in range(popups.size() - 1, -1, -1):
		popups[i].t += delta
		if popups[i].t >= POPUP_TIME:
			popups.remove_at(i)


func _draw_popups() -> void:
	for m in popups:
		if int(m.ship) != ship.get_instance_id():
			continue
		var p: Vector2 = m.pos + Vector2(0, float(m.t) / POPUP_TIME * POPUP_RISE)  # signed messages float down
		var d := int(m.delta)
		var sign := HudDraw.tex("numbers/Text_plus.png" if d > 0 else "numbers/Text_minus.png")
		if sign and d != 0:
			draw_texture(sign, p + Vector2(-50, -46))
		var x := -32.0
		for ch in str(absi(d)):
			var t := HudDraw.tex("numbers/Text_%s_L.png" % ch)
			if t:
				draw_texture(t, p + Vector2(x, -46))
			x += 16.0


func _band() -> int:
	var r := float(ship.hull) / maxf(ship.max_hull, 1)
	return 3 if r <= 0.25 else (2 if r <= 0.5 else (1 if r <= 0.75 else 0))


func _process(d: float) -> void:
	_t += d
	tick_popups(d)
	poll_resources(ship)
	_hull_warn_time = maxf(_hull_warn_time - d, 0.0)
	var b := _band()
	if b > _hull_band:  # crossed 75 / 50 / 25 % going down (ShipStatus::OnLoop)
		_hull_warn = HudDraw.txt(["", "warning_hull_75", "warning_hull_50", "warning_hull_25"][b])
		_hull_warn_time = HULL_WARNING_TIME
		_hull_loop = b == 3  # 25 %: SetLoop(true), runs until the hull is back above 25 %
		FtlData.play("warning")
	elif b < 3 and _hull_loop:  # healed above 25 %: SetLoop(false) + Stop
		_hull_loop = false
		_hull_warn_time = 0.0
	if _hull_loop:
		_hull_warn_time = HULL_WARNING_TIME
	_hull_band = b
	var id := status_tooltip(TooltipService.local_pointer(self), ship.super_shield > 0, evade_offset)
	if id != "" and not TooltipService.hud_blocked:
		TooltipService.request(TooltipText.simple("ship_status", id), {"instant": true, "kind": &"ship_status",
			"source": self, "ctx": {"id": id}})
	queue_redraw()


## The pointer (screen point) is over the status block as drawn (hull, shields, resources, scrap, evade / O2:
## the frame's top-left 520 × 140 in this HUD's own coordinates). main.gd `_over_hud_panel` (touch UI).
func hud_hit(screen: Vector2) -> bool:
	var m := get_global_transform().affine_inverse() * screen
	return is_visible_in_tree() and (m.y < 140 and m.x < 520
		or status_tooltip(m, ship != null and ship.super_shield > 0, evade_offset) != "")


## ShipStatus::OnMouseMove hit test (rules/tooltips.md §4.1), checked in this order; instant tooltips.
static func status_tooltip(m: Vector2, super_shield := false, evade_off := Vector2.ZERO) -> String:
	var inr := func(x: float, y: float, w: float, h: float) -> bool:
		return m.x >= x and m.x < x + w and m.y >= y and m.y < y + h
	if inr.call(6, 8, 368, 37):
		return "tooltip_hull"
	if m.x >= 261 and m.x <= 319 and m.y >= 51 and m.y <= 74:
		return "tooltip_droneCount"
	if m.x >= 191 and m.x <= 252:
		if m.y >= 51 and m.y <= 74:
			return "tooltip_missileCount"
	elif inr.call(121, 51, 65, 24):
		return "tooltip_fuelCount"
	if inr.call(383, 12, 121, 33):
		return "tooltip_scrapCount"
	if m.x >= 7 and m.x <= 127 and m.y >= 51 and m.y <= 75:
		return "tooltip_shieldDisplay"
	if inr.call(8 + evade_off.x, 96 + evade_off.y, 90, 20):  # evade / O2 box (touch UI: moved, evade_offset)
		return "tooltip_evadeDisplay"
	if inr.call(8 + evade_off.x, 118 + evade_off.y, 90, 20):
		return "tooltip_oxygenDisplay"
	if super_shield and inr.call(30, 77, 98, 11):
		return "tooltip_energyShieldDisplay"
	return ""


## Shields warning (ShipStatus::RenderShields): loops while GetSystemHealth(shields) < 2 (level − damage; event
## power loss / ion do not count) and GetSystemPowerMax(shields) > 1 (level).
func shields_warning() -> bool:
	return ShipStatusHud.shields_critical(ship)


static func shields_critical(sh: ShipState) -> bool:
	var s := sh.sys("shields")
	return s != null and s.get_level() > 1 and s.get_level() - s.damage < 2


func oxygen_warning() -> bool:
	return ship.env.average_oxygen() < 25.0 and not String(ship.blueprint.name).contains("ANAEROBIC")


func _draw() -> void:
	if ship == null:
		return
	_draw_hull()
	_draw_shields()
	_draw_evade_oxygen()
	_draw_resources()
	_draw_popups()
	if _hull_warn_time > 0.0:
		HudDraw.warning_with_lines(self, HudLayout.HULL_WARNING, _hull_warn, _t)
	if shields_warning():
		HudDraw.warning_with_lines(self, HudLayout.SHIELDS_WARNING, HudDraw.txt("warning_shields"), _t)
	if oxygen_warning():
		HudDraw.warning_with_lines(self, HudLayout.O2_WARNING, HudDraw.txt("warning_oxygen"), _t)
	Hooks.emit(&"hud_draw.ship_status", self, ship)


func _draw_hull() -> void:
	var red := _hull_warn_time > 0.0 and HudDraw.flash_on(_t)
	HudDraw.img(self, "statusUI/top_hull_red.png" if red else "statusUI/top_hull.png", HudLayout.HULL_FRAME)
	# Segmented bar (top_hull_bar_mask.png) cropped to 360·hull/max, tinted by absolute hull points.
	var col := HudLayout.HULL_GREEN if ship.hull >= 20 else (HudLayout.HULL_YELLOW if ship.hull >= 10
		else HudLayout.HULL_RED)
	col = Hooks.filter(&"hud_hull_color", col, ship, "player")
	var frac: float = Hooks.filter(&"hud_hull_fraction", clampf(float(ship.hull) / maxf(ship.max_hull, 1), 0.0, 1.0),
		ship, "player")
	var w := HudLayout.HULL_FILL_W * clampf(frac, 0.0, 1.0)
	HudDraw.img_cropped(self, "statusUI/top_hull_bar_mask.png", HudLayout.HULL_FILL, w, col)
	# Label: 4-slice of top_hull_label.png sized to the "HULL" text, then the text.
	var label := HudDraw.txt("status_hull")
	var tw := FtlData.ftl_text_width(62, label)
	var t := HudDraw.tex("statusUI/top_hull_red_label.png" if red else "statusUI/top_hull_label.png")
	if t:
		var h := t.get_height()
		draw_texture_rect_region(t, Rect2(0, 0, 16, h), Rect2(0, 0, 16, h))
		draw_texture_rect_region(t, Rect2(16, 0, maxf(tw - 15, 0), h), Rect2(16, 0, 1, h))
		draw_texture_rect_region(t, Rect2(tw + 1, 0, 34, h), Rect2(17, 0, 34, h))
		draw_texture_rect_region(t, Rect2(tw + 35, 0, maxf(HudLayout.HULL_LABEL_END - tw - 35, 0), h),
			Rect2(51, 0, 1, h))
	HudDraw.text(self, 62, label, HudLayout.HULL_TEXT, HudLayout.BUTTON_TEXT)


func _draw_shields() -> void:
	var sh := ship.sys("shields")
	var hacked := sh != null and sh.hack_effect() > 1
	var frame := "statusUI/top_shields4_on.png" if ship.shield_layers > 0 else "statusUI/top_shields4_off.png"
	if shields_warning() and HudDraw.flash_on(_t):
		frame = "statusUI/top_shields4_red.png"
	HudDraw.img(self, frame, HudLayout.SHIELDS_FRAME)
	if hacked and fmod(_t, 0.5) < 0.25:
		HudDraw.img(self, "statusUI/top_shields4_purple.png", HudLayout.SHIELDS_FRAME + Vector2(12, 6))
	var mx := mini(ship.max_shield_layers(), 4)
	for i in mx:
		var on := i < ship.shield_layers
		var img := "on" if on else "off"
		if hacked:
			img = "hacked_charged" if on else "hacked"
		HudDraw.img(self, "statusUI/top_shieldsquare1_%s.png" % img,
			HudLayout.SHIELD_BUBBLE + Vector2(HudLayout.SHIELD_STEP * i, 0))
	if ship.super_shield > 0:
		for k in mini(ship.super_shield, 5):
			HudDraw.img(self, "statusUI/energy_shield_bar2.png" if k == 2 else "statusUI/energy_shield_bar.png",
				HudLayout.ENERGY_SHIELD + Vector2(3 + 18 * k, 3))
	elif mx > 0:
		HudDraw.img(self, "statusUI/energy_shield_box.png", HudLayout.ENERGY_SHIELD)
		if ship.shield_layers < ship.max_shield_layers():
			var r := clampf(ship.shield_charger / ShipState.SHIELD_CHARGE_TIME, 0.0, 1.0)
			draw_rect(Rect2(HudLayout.ENERGY_SHIELD + Vector2(3, 3), Vector2(roundf(92 * r), 6)),
				FtlColors.PURPLE_HACK if hacked else Color8(27, 132, 255))


func _draw_evade_oxygen() -> void:
	var dodge := ship.dodge_factor()
	var o2_red := oxygen_warning() and HudDraw.flash_on(_t)
	var img := "top_evade_oxygen"
	if dodge == 0:
		img = "top_evade_oxygen_both_red" if o2_red else "top_evade_oxygen_up_red"
	elif o2_red:
		img = "top_evade_oxygen_down_red"
	HudDraw.img(self, "statusUI/%s.png" % img, HudLayout.EVADE_BOX + evade_offset)
	var flash := fmod(_t, 0.5) < 0.25
	var ox := ship.sys("oxygen")
	var o2_hacked := ox != null and ox.hack_effect() > 1
	var eng := ship.sys("engines")
	var pil := ship.sys("pilot")
	var ev_hacked := (eng != null and eng.hack_effect() > 1) or (pil != null and pil.hack_effect() > 1)
	if o2_hacked and flash:
		HudDraw.img(self, "statusUI/top_evade_oxygen_down_purple.png", HudLayout.EVADE_BOX + evade_offset)
	if ev_hacked and flash:
		HudDraw.img(self, "statusUI/top_evade_oxygen_up_purple.png", HudLayout.EVADE_BOX + evade_offset)
	# Value right-aligned at x 82, "%" left-aligned at the same x (font 10).
	var c1 := FtlColors.PURPLE_HACK if ev_hacked and flash else HudLayout.BUTTON_ON
	var c2 := FtlColors.PURPLE_HACK if o2_hacked and flash else HudLayout.BUTTON_ON
	var x := HudLayout.EVADE_TEXT_X
	HudDraw.text(self, 10, str(dodge), Vector2(x, HudLayout.EVADE_TEXT_Y) + evade_offset, c1, 2)
	HudDraw.text(self, 10, "%", Vector2(x, HudLayout.EVADE_TEXT_Y) + evade_offset, c1)
	HudDraw.text(self, 10, str(int(ship.env.average_oxygen())), Vector2(x, HudLayout.O2_TEXT_Y) + evade_offset, c2, 2)
	HudDraw.text(self, 10, "%", Vector2(x, HudLayout.O2_TEXT_Y) + evade_offset, c2)


func _draw_resources() -> void:
	var c := HudLayout.RESOURCE_TEXT
	HudDraw.img(self, "statusUI/top_fuel_on_red.png" if ship.fuel < 4 else "statusUI/top_fuel_on.png", HudLayout.FUEL)
	HudDraw.text(self, 0, str(ship.fuel), HudLayout.FUEL_TEXT, c, 1)
	HudDraw.img(self, "statusUI/top_missiles_on_red.png" if ship.missiles <= 0 else "statusUI/top_missiles_on.png",
		HudLayout.MISSILES)
	HudDraw.text(self, 0, str(ship.missiles), HudLayout.MISSILES_TEXT, c, 1)
	HudDraw.img(self, "statusUI/top_drones_on_red.png" if ship.drone_parts <= 0 else "statusUI/top_drones_on.png",
		HudLayout.DRONES)
	HudDraw.text(self, 0, str(ship.drone_parts), HudLayout.DRONES_TEXT, c, 1)
	HudDraw.img(self, "statusUI/top_scrap.png", HudLayout.SCRAP)
	HudDraw.text(self, 0, str(ship.scrap), HudLayout.SCRAP_TEXT, c, 1)
