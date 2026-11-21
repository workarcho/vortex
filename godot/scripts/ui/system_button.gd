class_name SystemButton
extends Control
## Activation button above a system box (FTL CloakingBox / BatteryBox / TeleportBox / HackBox / MindBox),
## ArtilleryBox, DoorBox), drawn with the original `systemUI/button_*` images at the box location + (36, −50)
## (hack −41, teleport / doors (35, −36), artillery (35, −40)) per rules/hud_layout.md "System activation buttons":
## the cooldown box base, the white `_charging_on` fill draining from the top while the effect runs, then the
## button (`_on` / `_select2` / `_off`; hidden while the effect runs). The cooldown after use is NOT drawn here:
## it is the system lock (ring timer + blue bars on the SystemPowerColumn). Teleporter: SEND (top half) and
## RETURN (bottom half). Mouse: left click. Teleporter / hacking / mind: arm, then click a room (main.gd).

var ship: ShipState
var combat: Combat  # teleporter arming; may be null (tests)
var kind := "cloaking"
var loc := Vector2.ZERO  # system box location
var _hover := -1  # hovered half (teleporter) or 0
var warning := ""  # super-shield warning (shown briefly over the button)
var warning_time := 0.0
var _time := 0.0


func setup(s: ShipState, system_id: String, c: Combat, box_loc: Vector2) -> void:
	ship = s
	kind = system_id
	combat = c
	loc = box_loc
	var off := Vector2(36, -50)
	var sz := Vector2(40, 92)
	match kind:
		"teleporter":
			off = Vector2(35, -36)
			sz = Vector2(40, 79)
		"hacking":
			off = Vector2(36, -41)
			sz = Vector2(40, 81)
		"doors":  # DoorBox: buttonOffset = location + (35, −36), button_door_base 40×79
			off = Vector2(35, -36)
			sz = Vector2(40, 79)
		"artillery":  # ArtilleryBox: button_artillery_<P> 23×75 at location + (35, −40), no button
			off = Vector2(35, -40)
			sz = Vector2(23, 75)
	position = loc + off  # image top-left (Button location)
	size = sz
	custom_minimum_size = sz
	mouse_filter = Control.MOUSE_FILTER_IGNORE if kind == "artillery" else Control.MOUSE_FILTER_STOP


func _process(d: float) -> void:
	_time += d
	warning_time = maxf(warning_time - d, 0.0)
	if ship and ship.sys(kind) and TooltipService.over(self, Rect2(Vector2.ZERO, size)):
		var half := _half_at(TooltipService.local_pointer(self))
		var tip := tooltip_for(half)
		if tip != "":
			TooltipService.request(tip, {"kind": &"button", "source": self, "ctx": {"button": kind, "half": half}})
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_hover = _half_at(event.position)
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		press(_half_at(event.position))
		accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		_hover = -1


## Button tooltips (rules/tooltips.md §4.1; {Door,Cloaking,Battery,Teleport,Hack,Mind}Box::MouseMove): only while
## the hovered button is active;  = the hotkey name (DoorBox: Settings "close" X / "open" Z).
func tooltip_for(half: int) -> String:
	var s := ship.sys(kind)
	match kind:
		"doors":
			if not ship.doors_function() or half < 0:
				return ""
			return TooltipText.simple("button", "close_doors" if half == 0 else "open_doors",
				{"key": "close" if half == 0 else "open"})
		"cloaking":
			if CloakRule.ready(ship) and s.effective_power() > 0 and not s.turned_on:
				return TooltipText.simple("button", "cloak_button", {"key": "activate_cloak"})
		"battery":
			if BatteryRule.ready(ship) and s.effective_power() > 0 and not s.turned_on:
				return TooltipText.simple("button", "activate_battery", {"key": "activate_battery"})
		"teleporter":
			if half == 0 and TeleporterRule.can_send(ship, ship.opponent):
				return TooltipText.simple("button", "tele_send", {"key": "send_tele"})
			if half == 1 and TeleporterRule.can_receive(ship, ship.opponent):
				return TooltipText.simple("button", "tele_ret", {"key": "ret_tele"})
		"mind":
			if MindRule.can_use(ship) and MindRule.charged(ship):
				return TooltipText.simple("button", "mind_button", {"key": "mindControl"})
		"hacking":
			if ship.hacking:
				var tgt := ship.hack_target
				if tgt != null and tgt.damage >= tgt.get_level():
					return TooltipText.simple("button", "pulse_button_broken")
				if HackingRule.can_pulse(ship):
					var tip := TooltipText.f("hack_activate", TooltipText.pulse_text(ship))
					if TooltipText.key("start_hacking") != "":
						tip += "
" + TooltipText.f("hotkey", TooltipText.key("start_hacking"))
					return tip
			elif HackingRule.button_active(ship) and not s.is_power_locked():
				return TooltipText.simple("button", "hack_button", {"key": "start_hacking"})
	return ""


func _half_at(p: Vector2) -> int:
	if kind == "doors":  # DoorBox hit boxes: close (10, 10, 20, 20), open (10, 33, 20, 20)
		if Rect2(10, 10, 20, 20).has_point(p):
			return 0
		if Rect2(10, 33, 20, 20).has_point(p):
			return 1
		return -1
	if kind != "teleporter":
		return 0
	return 0 if p.y < size.y / 2 else 1


## Button action (also used by CLI flags): half 0 = send / on, 1 = retrieve.
func press(half := 0) -> bool:
	var ok := false
	match kind:
		"doors":  # DoorBox::MouseClick: top = close all, bottom = open all
			if half < 0 or not ship.doors_function():
				return false
			var n := ship.manipulate_all_doors(half == 1)
			for i in mini(n, 8):
				FtlData.play("doorOpen")
			return true
		"cloaking":
			ok = CloakRule.turn_on(ship)
		"battery":
			ok = BatteryRule.turn_on(ship)
		"teleporter":
			if TeleporterRule.super_blocked(ship, ship.opponent) and TeleporterRule.charged(ship):
				warning = HudDraw.txt("warning_super_shield_teleporter")  # SetArmed refused by super shields
				warning_time = 2.0
			elif combat:
				ok = combat.arm_teleporter(ship, TeleporterRule.SEND if half == 0 else TeleporterRule.RETRIEVE)
		"hacking":
			if ship.hacking:
				ok = HackingRule.initiate_pulse(ship)
			else:
				var r := HackingRule.arm(ship)
				ok = r == "ok" or r == "off"
				if r == "blocked":
					warning = HudDraw.txt("warning_super_shield_hacking")
					warning_time = 2.0
		"mind":
			var r := MindRule.arm(ship)
			ok = r == "ok" or r == "off"
			if r == "blocked":
				warning = HudDraw.txt("warning_super_shield_mind")
				warning_time = 2.0
	if ok and (ship.hack_armed or ship.mind_armed) and combat:
		combat.player_tp_armed = TeleporterRule.NONE
	if not ok and kind != "teleporter":
		FtlData.play("powerUpFail")
	return ok


func _img(rel: String, at := Vector2.ZERO) -> bool:
	return HudDraw.img(self, "systemUI/" + rel, at) != Vector2.ZERO


## Effective power as a button / box level: 0 -> 1, capped at 4 (CloakingBox / HackBox button choice,
## CooldownSystemBox::GetCooldownLevel).
static func level_of(p: int) -> int:
	return clampi(p, 1, 4)


## Cooldown box state of a box (rules/hud_layout.md "System activation buttons"): {level L (-1 = no box),
## fill f (<= 0 = none), button image prefix ("" = no button drawn), active, selected, offset of the box images
## rel. this control ("at"), offset of the button image ("button_at" = the Button's imageStats x / y, added to
## "at")}. Pure: used by _draw and the tests.
static func box_state(ship: ShipState, kind: String, armed_tp := TeleporterRule.NONE) -> Dictionary:
	var s := ship.sys(kind)
	var st := {"level": -1, "fill": -1.0, "button": "", "active": false, "selected": false, "at": Vector2.ZERO,
		"base": "", "button_at": Vector2.ZERO}
	if s == null:
		return st
	var p := s.effective_power()
	match kind:
		"cloaking":  # CloakingBox: L = P; button by P; shown when Ready() or not on
			var ready := CloakRule.ready(ship)
			st.level = level_of(p)
			st.fill = CloakRule.remaining_fraction(ship) if s.turned_on else -1.0
			st.active = ready and p > 0 and s.damage < s.get_level()
			if ready or not s.turned_on:
				st.button = "button_cloaking%d" % level_of(p)
		"battery":  # BatteryBox: L 3, box + button shifted (-1, +1); button only while Ready()
			var ready := BatteryRule.ready(ship)
			st.level = 3
			st.base = "button_battery3_base.png"
			st.at = Vector2(-1, 1)
			st.fill = BatteryRule.cooldown_fraction(ship) if s.turned_on else -1.0
			st.active = ready and p > 0 and s.damage < s.get_level()
			if ready:
				st.button = "button_cloaking3"
		"mind":  # MindBox: L 2; active = CanUse && !locked; selected = armed; hidden while in use
			st.level = 2
			st.fill = MindRule.control_fraction(ship) if ship.mind_in_use else -1.0
			st.active = MindRule.can_use(ship) and not s.is_power_locked()
			st.selected = ship.mind_armed
			if not ship.mind_in_use:
				st.button = "button_cloaking2"
		"hacking":
			if not ship.hacking:  # drone not launched: no cooldown box; hack base 2 px lower, the drone button's
				# image 26 px below that (HackBox ctor: imageStats (0, 26, 40, 81), hit (10, 36, 20, 20)) so its
				# drone icon (image rows 10..30) sits in the base's dark slot
				st.at = Vector2(0, 2)
				st.base = "button_hack_base.png"
				st.button = "button_hack_drone"
				st.button_at = Vector2(0, 26)
				st.active = HackingRule.button_active(ship)
				st.selected = ship.hack_armed
			else:  # pulse buttons on button_cloaking<P>_base, image 9 px above the button offset
				var pulsing := HackingRule.pulsing(ship)
				st.level = level_of(p)
				st.at = Vector2(0, -9)
				st.fill = HackingRule.pulse_fraction(ship) if pulsing and not HackingRule.can_pulse(ship) else -1.0
				st.active = HackingRule.can_pulse(ship)
				if st.active or not pulsing:
					st.button = "button_cloaking%d" % level_of(p)
		"teleporter":  # TeleportBox: plain box, both buttons always drawn
			st.base = "button_teleport_base.png"
	if st.base == "" and int(st.level) >= 0:
		st.base = "button_cloaking%d_base.png" % int(st.level)
	return st


## ArtilleryBox bar height: int(charge / chargeTime · (1.5 − 0.25 P) · baseCooldown) (P = effective power, 0 -> 1).
static func artillery_bar(ship: ShipState) -> int:
	var a := ship.sys("artillery")
	if a == null or ship.artillery.is_empty():
		return 0
	var w: WeaponState = ship.artillery[0]
	var p := maxi(a.effective_power(), 1)
	var mx := w.max_charge(0)
	if mx <= 0.0:
		return 0
	return int(w.charge / mx * ArtilleryRule.cooldown_modifier(p) * w.base_cooldown())


func _draw() -> void:
	if ship == null or ship.sys(kind) == null:
		return
	var s := ship.sys(kind)
	match kind:
		"doors":  # DoorBox::OnRender: box, then the open (bottom) and close (top) buttons, active = DoorsFunction
			_img("button_door_base.png")
			var act := ship.doors_function()
			_img("button_door_top_%s.png" % _state(act, false, _hover == 0))
			_img("button_door_bottom_%s.png" % _state(act, false, _hover == 1))
		"teleporter":  # TeleportBox: during the cooldown lock both buttons are simply inactive (_off)
			var armed := combat.player_tp_armed if combat else TeleporterRule.NONE
			_img("button_teleport_base.png")
			var send_ok := TeleporterRule.can_send(ship, ship.opponent)
			var ret_ok := TeleporterRule.can_receive(ship, ship.opponent)
			_img("button_teleport_top_%s.png" % _state(send_ok, armed == TeleporterRule.SEND, _hover == 0))
			_img("button_teleport_bottom_%s.png" % _state(ret_ok, armed == TeleporterRule.RETRIEVE, _hover == 1))
		"artillery":  # ArtilleryBox: no button; the weapon charge as a 5 px bar in button_artillery_<P>
			_img("button_artillery_%d.png" % level_of(s.effective_power()))
			var h := artillery_bar(ship)
			if h > 0:
				draw_rect(Rect2(9, 59 - h, 5, h), FtlColors.PURPLE_HACK if s.hacked else Color.WHITE)
		_:
			var st := box_state(ship, kind)
			var at: Vector2 = st.at
			if st.base != "":
				_img(st.base, at)
			_draw_fill(int(st.level), float(st.fill), at)
			if st.button != "":
				_img("%s_%s.png" % [st.button, _state(st.active, st.selected, _hover == 0)], at + st.button_at)
	if warning_time > 0.0:
		HudDraw.text(self, 61, warning, Vector2(size.x / 2, -12 * warning.count("\n") - 14),
			Color(HudLayout.RED_WARNING, HudDraw.flash_alpha(_time)), 1)


## CooldownSystemBox fill: rows top..91 of button_cloaking<L>_charging_on.png on the same rows of the box, white;
## n = ceil(f · (3L + 2)) stripes, top = 66 − 4n (whole stripes, vanishing from the top as f falls).
func _draw_fill(lvl: int, f: float, at: Vector2) -> void:
	if lvl < 0 or f <= 0.0:
		return
	var t := HudDraw.tex("systemUI/button_cloaking%d_charging_on.png" % lvl)
	if t == null:
		return
	var top := fill_top(lvl, f)
	var h := t.get_height() - top
	if h > 0:
		draw_texture_rect_region(t, Rect2(at + Vector2(0, top), Vector2(t.get_width(), h)),
			Rect2(0, top, t.get_width(), h), Color.WHITE)


## Top texture row of the fill for level L and fraction f (66 − 4 · ceil(f · (3L + 2))).
static func fill_top(lvl: int, f: float) -> int:
	return 66 - 4 * ceili(f * (3 * lvl + 2))


## Button image suffix: select2 when hovered or armed and usable, on when usable, off otherwise.
static func _state(available: bool, armed: bool, hover: bool) -> String:
	if armed or (hover and available):
		return "select2"
	return "on" if available else "off"
