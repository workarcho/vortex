class_name CommandHud
extends Control
## Top-centre buttons and the pause overlay (FTL CommandGui / FTLButton; rules/hud_layout.md).
## `front == false`: FTL drive button (base, charge bars, "FTL DRIVE", status line, pilot / engines
## pull-out), the SHIP button (off: upgrades are blocked in combat), the MENU wrench, the intruder
## warning. `front == true`: the pause overlay (Text_pause1/2.png + hint), drawn above the panels.
## Run mode (`run` set): FTLButton states (rules/ftl_drive.md §4): charging = bars only (+ CHARGING when pilot and
## engines work, `_off` bars otherwise, no JUMP text); charged = JUMP lit + READY! when the button is active and
## pilot + engines work, else the inactive grey JUMP (red with a strike line when out of fuel); the pilot / engines
## pull-out while either is down; ENGINES CRITICAL (red base / pull-out / label flash) while the engines are
## destroyed. The STORE button at a store beacon (rules/hud_layout.md). Sandbox: the drive shows its charge and JUMP
## stays disabled. SHIP / MENU are inert.

var ship: ShipState
var combat: Combat
var run: RunState = null  # run mode only
var front := false
const STORE_BASE := Vector2(702, 22)
const STORE_HIT := Rect2(708, 25, 90, 49)
var _t := 0.0
var _pullout := -40.0  # FTL pull-out slide (−40 hidden .. 0 shown)
var _menu_hover := false
var _ship_hover := false
## CommandGui upgradeWarning: `warning_in_danger` ("IN DANGER") for 2 s, red, centred, no flash; started by a click
## on the inactive SHIP button (CommandGui::LButtonDown, main.gd).
var danger_warning := WarningMessage.new("warning_in_danger", HudLayout.IN_DANGER, 2.0, true, false,
	HudLayout.RED_WARNING)
## Touch UI (main.gd `_touch_layout`): the ENGINES CRITICAL warning moved (text only) to clear the hazard status / column.
var engines_warning_shift := Vector2.ZERO
var _eng_warn_t := -1.0  # enginesDown WarningWithLines: s since Start (loops), < 0 = stopped
## ShipStatus boardingMessage (`warning_intruders`, loop, flash, sound `warning`): started (sound once) when
## ShipManager::IntrudersArrived (a living intruder aboard that is not still materialising), stopped when the
## intruder count drops to 0.
var intruder_warning := false
## Touch UI (main.gd `_touch_intruder_msg`): where the intruder warning's centre-top goes in this HUD's own
## coordinates (over the player ship as laid out); Vector2.INF = the PC place HudLayout.INTRUDER_MSG.
var intruder_msg_at := Vector2.INF
## ShipStatus / FTLButton bBossFight (a flagship stage at the beacon; main.gd sets it every frame): the intruder
## warning is drawn 120 px further left (ShipStatus::OnRender translates by (−120, 0)) and the ENGINES CRITICAL
## warning moves by (−85, −35) (FTLButton::OnRender), both clear of the larger boss TARGET box.
var boss_fight := false
const BOSS_INTRUDER_SHIFT := Vector2(-120, 0)
const BOSS_ENGINES_SHIFT := Vector2(-85, -35)
## Touch UI pause overlay (set by main.gd `_touch_pause_tick`): `touch_pause` true = no "Press Spacebar" hint;
## `pause_title` / `pause_text` = FTL iPad text ids of the current selection mode (paused_targeting ...),
## "" = the plain PAUSED image.
var touch_pause := false
var pause_title := ""
var pause_text := ""


func setup(s: ShipState, c: Combat, is_front: bool) -> void:
	ship = s
	combat = c
	front = is_front
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(d: float) -> void:
	_t += d
	danger_warning.update(d)
	# FTLButton::OnRender: enginesDown starts (looping, sound `warning`) while the engines have no health left.
	if ship != null and not front and engines_destroyed():
		if _eng_warn_t < 0.0:
			_eng_warn_t = 0.0
			FtlData.play("warning")
		else:
			_eng_warn_t += d
	else:
		_eng_warn_t = -1.0
	if ship != null and not front:
		if not intruder_warning and intruders_arrived(ship):
			intruder_warning = true
			FtlData.play("warning")
		elif intruder_warning and ship.intruders().is_empty():
			intruder_warning = false
	var want := 0.0 if _pullout_needed() else -40.0
	_pullout = move_toward(_pullout, want, 20.0 * 16.0 * d / 4.0)  # ~80 px/s [inferred unit]
	var m := TooltipService.local_mouse(self)
	_menu_hover = Rect2(_menu_pos(), Vector2(55, 55)).has_point(m)
	_ship_hover = HudLayout.SHIP_HIT.has_point(m)
	if not front and ship != null:
		_tooltip(TooltipService.local_pointer(self))
	queue_redraw()


## CommandGui / FTLButton tooltips (rules/tooltips.md §4.1): JUMP, pilot / engine indicators, SHIP, STORE, MENU.
func _tooltip(m: Vector2) -> void:
	if TooltipService.hud_blocked:
		return
	var tip := ""
	var k := &"button"
	var active := run != null and run.ftl_button_active()
	if HudLayout.FTL_BARS.has_point(m):
		# FTLButton::OnRender: inactive -> only the out-of-fuel tooltip; active -> pilot / engines reasons when either
		# is down, else the jump tooltip once charged (none while charging).
		k = &"ftl"
		if not active:
			tip = TooltipText.ftl_button(ship) if ship.fuel <= 0 else ""
		elif not (_pilot_ok() and _engines_ok()):
			tip = TooltipText.ftl_button(ship)
		elif ship.ftl_charge >= 1.0:
			tip = TooltipText.simple("ftl", "jump_button", {"key": "jump"})
	elif not active and run != null:
		pass  # FTLButton: the pull-out icon tooltips only while the button is active
	elif _pullout > -40.0 and Rect2(HudLayout.FTL_PULLOUT + Vector2(15, 23 + _pullout), Vector2(22, 22)).has_point(m):
		tip = TooltipText.pilot_tooltip(ship)
		k = &"ftl"
	elif _pullout > -40.0 and Rect2(HudLayout.FTL_PULLOUT + Vector2(40, 22 + _pullout), Vector2(22, 22)).has_point(m):
		tip = TooltipText.engine_tooltip(ship)
		k = &"ftl"
	elif HudLayout.SHIP_HIT.has_point(m):
		tip = TooltipText.simple("button", "ship_info", {"key": "ship_info"})
	elif store_shown() and STORE_HIT.has_point(m):
		tip = TooltipText.simple("button", "open_store", {"key": "store"})
	elif menu_rect().has_point(m):
		tip = TooltipText.simple("button", "open_options")
	if tip != "":
		TooltipService.request(tip, {"kind": k, "source": self})


## FTLButton::OnRender indicators: piloting / engines SystemFunctions and not hack-pulsed (FtlDrive).
func _pilot_ok() -> bool:
	return FtlDrive.pilot_indicator(ship)


func _engines_ok() -> bool:
	return FtlDrive.engines_indicator(ship)


## Frame rect covered by the ENGINES CRITICAL warning (lines + both text lines), before engines_warning_shift.
const ENGINES_WARNING_BOUNDS := Rect2(608, 107, 180, 90)


## ShipManager::GetSystemHealth(engines) == 0: every engine bar destroyed (enginesDown warning).
func engines_destroyed() -> bool:
	var e := ship.sys("engines")
	return e != null and e.get_level() - e.damage <= 0


## The enginesDown warning is in its red half (FTLButton: FTL_base_red / FTL_pullout_red / red "FTL Drive").
func _eng_red() -> bool:
	return _eng_warn_t >= 0.0 and HudDraw.flash_on(_eng_warn_t)


## What the FTL button shows (FTLButton::OnRender), for tests and screenshots: "charging" (bars + CHARGING),
## "charging_off" (`_off` bars, no text: pilot or engines down), "ready" (JUMP lit + READY!), "inactive" (grey
## JUMP: charged but not usable), "no_fuel" (red JUMP + strike line).
func ftl_state() -> String:
	var both := _pilot_ok() and _engines_ok()
	if ship.ftl_charge < 1.0:
		return "charging" if both else "charging_off"
	if run != null and run.ftl_button_active() and both:
		return "ready"
	return "no_fuel" if run != null and ship.fuel <= 0 else "inactive"


func _pullout_needed() -> bool:
	return not (_pilot_ok() and _engines_ok())


func _draw() -> void:
	if ship == null:
		return
	if front:
		_draw_pause()
		return
	_draw_ftl()
	# SHIP button: active outside danger (run mode, ShipManagement.can_open); off = upgrades blocked.
	HudDraw.img(self, "statusUI/top_ship_%s.png" % ("off" if not ship_button_active() else ("select2" if _ship_hover
		else "on")), HudLayout.SHIP_BUTTON)
	if store_shown():
		var sp := STORE_BASE
		HudDraw.img(self, "statusUI/top_store_base.png", sp)
		var hot := STORE_HIT.has_point(TooltipService.local_mouse(self))
		HudDraw.text(self, 62, HudDraw.txt("button_store"), sp + Vector2(51, 16), HudLayout.BUTTON_TEXT_LIGHT if hot
			else HudLayout.BUTTON_TEXT, 1)
	HudDraw.img(self, "statusUI/top_optionswrench_select2.png" if _menu_hover
		else "statusUI/top_optionswrench_on.png", _menu_pos())
	danger_warning.draw(self)
	if intruder_warning:
		HudDraw.text(self, 52, HudDraw.txt("warning_intruders"), HudLayout.INTRUDER_MSG
			+ (BOSS_INTRUDER_SHIFT if boss_fight else Vector2.ZERO) if intruder_msg_at == Vector2.INF else intruder_msg_at,
			Color(HudLayout.RED_WARNING, HudDraw.flash_alpha(_t)), 1)
	Hooks.emit(&"hud_draw.command", self, ship)


## ShipManager::IntrudersArrived: an intruder aboard that is alive and no longer in its teleport-arrive animation.
static func intruders_arrived(s: ShipState) -> bool:
	return s.crew.any(func(c): return c.is_alive() and c.is_intruder(s) and not s.teleporting.has(c))


## SHIP button usable (rules/ship_management.md §1): run mode, no hostile ship, nothing modal.
func ship_button_active() -> bool:
	return run != null and run.mgmt.can_open(run)


## STORE button shown at a store beacon outside danger (run mode).
func store_shown() -> bool:
	return run != null and run.store() != null and not run.in_danger() and run.over == ""


## Screen (canvas) point -> this HUD's frame coordinates, where FTL_JUMP_HIT / SHIP_HIT / STORE_HIT / menu_rect
## live (touch UI: the top buttons are drawn ×TOUCH_TOPLEFT_SCALE; PC: identity).
func hud_point(screen: Vector2) -> Vector2:
	return get_global_transform().affine_inverse() * screen


## The pointer (screen point) is over the top buttons as drawn (FTL drive + pull-out, SHIP, STORE, MENU: the
## frame rect TOP_BUTTONS, in this HUD's own coordinates). main.gd `_over_hud_panel` (touch UI).
func hud_hit(screen: Vector2) -> bool:
	return is_visible_in_tree() and TOP_BUTTONS.has_point(hud_point(screen))


## Frame rect of the FTL drive / SHIP / MENU (+ STORE) buttons incl. the pilot / engines pull-out.
const TOP_BUTTONS := Rect2(520, 0, 300, 115)


## MENU wrench hit box (main.gd opens the Options screen on a click).
func menu_rect() -> Rect2:
	return Rect2(_menu_pos(), Vector2(55, 55))


func _menu_pos() -> Vector2:
	return Vector2(STORE_BASE.x + 117, STORE_BASE.y) if store_shown() else HudLayout.MENU_BUTTON


func _draw_ftl() -> void:
	var red := _eng_red()
	# Pull-out (under the base) with the pilot / engine icons; off2 blinks (alpha = blink / 0.75).
	if _pullout > -40.0:
		var p := HudLayout.FTL_PULLOUT + Vector2(0, _pullout)
		HudDraw.img(self, "buttons/FTL/FTL_pullout_red.png" if red else "buttons/FTL/FTL_pullout.png", p)
		var blink := fmod(_t, 0.75) / 0.75
		_pull_icon("FTL_pilot", _pilot_ok(), p + Vector2(15, 23), blink)
		_pull_icon("FTL_engine", _engines_ok(), p + Vector2(40, 22), blink)
	if red:
		HudDraw.img(self, "buttons/FTL/FTL_base_red.png", HudLayout.FTL_BASE - Vector2(6, 6))
	else:
		HudDraw.img(self, "buttons/FTL/FTL_base.png", HudLayout.FTL_BASE)
	HudDraw.text(self, 51, HudDraw.txt("ftl_drive"), HudLayout.FTL_LABEL, HudLayout.RED_WARNING if red
		else HudLayout.BUTTON_ON, 1)
	var r := HudLayout.FTL_BARS
	var state := ftl_state()
	# Status line (FTLButton::OnRender): COLOR_BUTTON_ON with its blue scaled by 1 - ftl_blink / 0.75
	# (ftl_blink ping-pongs over 0.75 s), i.e. pulsing toward yellow.
	var k := absf(fmod(_t, 1.5) / 0.75 - 1.0)
	var c := Color(HudLayout.BUTTON_ON.r, HudLayout.BUTTON_ON.g, HudLayout.BUTTON_ON.b * (1.0 - k))
	match state:
		"charging", "charging_off":
			# Charging: only the bars (width floor(charge × 74)); the JUMP text is not drawn.
			var bars := "buttons/FTL/FTL_loadingbars.png" if state == "charging" \
				else "buttons/FTL/FTL_loadingbars_off.png"
			HudDraw.img_cropped(self, bars, r.position, floorf(r.size.x * clampf(ship.ftl_charge, 0.0, 1.0)))
			if state == "charging":
				HudDraw.text(self, 61, HudDraw.txt("ftl_charging"), HudLayout.FTL_STATUS, c, 1)
		"ready":
			# TextButton active colour (235,245,0) fill, text (37,74,77) / hover (62,125,131).
			var hot := r.has_point(TooltipService.local_mouse(self))
			_draw_button_fill(r, READY_FILL)
			HudDraw.text(self, 62, HudDraw.txt("button_jump"), Vector2(r.get_center().x, r.position.y + 4),
				READY_TEXT_HOT if hot else READY_TEXT, 1)
			HudDraw.text(self, 61, HudDraw.txt("ftl_ready"), HudLayout.FTL_STATUS, c, 1)
		_:
			# Inactive TextButton: COLOR_BUTTON_OFF fill (COLOR_RED_WARNING when out of fuel), COLOR_BUTTON_TEXT label;
			# out of fuel adds a 2 px COLOR_BUTTON_TEXT line through the middle. No status line.
			var no_fuel := state == "no_fuel"
			_draw_button_fill(r, HudLayout.RED_WARNING if no_fuel else HudLayout.BUTTON_OFF)
			HudDraw.text(self, 62, HudDraw.txt("button_jump"), Vector2(r.get_center().x, r.position.y + 4),
				HudLayout.BUTTON_TEXT, 1)
			if no_fuel:
				draw_rect(Rect2(r.position.x + 2, r.get_center().y - 1, r.size.x - 4, 2), HudLayout.BUTTON_TEXT)
	if _eng_warn_t >= 0.0:
		var spec: Array = HudLayout.ENGINES_WARNING
		if engines_warning_shift == Vector2.ZERO:
			if boss_fight:  # FTLButton::OnRender, bBossFight: translated (−85, −35) (inside a 500 × 500 scissor)
				spec = [spec[0] + BOSS_ENGINES_SHIFT, spec[1], spec[2]]
			HudDraw.warning_with_lines(self, spec, HudDraw.txt("warning_engine"), _eng_warn_t)
		else:  # touch UI, moved off the hazard status / column: the two text lines only (lines would point nowhere)
			var o: Vector2 = spec[0] + spec[2] + engines_warning_shift
			var wc := Color(HudLayout.RED_WARNING, HudDraw.flash_alpha(_eng_warn_t))
			HudDraw.text_with_glow(self, HudDraw.txt("warning_warning"), o, wc)
			HudDraw.text_with_glow(self, HudDraw.txt("warning_engine"), o + Vector2(0, 23), wc)


const READY_FILL := Color(0.92156863, 0.9607843, 0.0)  # TextButton active colour of the lit JUMP button
const READY_TEXT := Color8(37, 74, 77)
const READY_TEXT_HOT := Color8(62, 125, 131)


## TextButton base shape: the rect with its four corners cut by 2 px (chamfered, as on the original button).
func _draw_button_fill(r: Rect2, c: Color) -> void:
	draw_rect(Rect2(r.position.x + 2, r.position.y, r.size.x - 4, r.size.y), c)
	draw_rect(Rect2(r.position.x, r.position.y + 2, r.size.x, r.size.y - 4), c)
	draw_rect(Rect2(r.position.x + 1, r.position.y + 1, r.size.x - 2, r.size.y - 2), c)


func _pull_icon(base: String, ok: bool, p: Vector2, blink: float) -> void:
	if ok:
		HudDraw.img(self, "buttons/FTL/%s_on.png" % base, p)
		return
	HudDraw.img(self, "buttons/FTL/%s_off1.png" % base, p)
	HudDraw.img(self, "buttons/FTL/%s_off2.png" % base, p, Color(1, 1, 1, blink))


## CommandGui::RenderPause: Text_pause1 centred at (640, 558), Text_pause2 on top with a 0.75 s
## ping-pong alpha; hint text (font 5) centred at (640, 580).
func _draw_pause() -> void:
	if combat == null or not combat.paused:
		return
	if touch_pause:
		# FTL iPad: the selection mode's title (TARGETING, ROOM SELECTION ...) + its instruction, else PAUSED.
		if pause_title != "":
			HudDraw.text(self, 62, HudDraw.txt(pause_title), HudLayout.PAUSE_TEXT - Vector2(0, 12), Color.WHITE, 1)
			if pause_text != "":
				HudDraw.text(self, 5, HudDraw.txt(pause_text), HudLayout.PAUSE_HINT, Color.WHITE, 1)
			return
		var tp := HudDraw.tex("Text_pause1.png")
		if tp:
			var q := HudLayout.PAUSE_TEXT - tp.get_size() / 2
			draw_texture(tp, q.round())
			HudDraw.img(self, "Text_pause2.png", q.round(), Color(1, 1, 1, absf(fmod(_t, 1.5) / 0.75 - 1.0)))
		else:
			HudDraw.text(self, 62, HudDraw.txt("paused"), HudLayout.PAUSE_TEXT - Vector2(0, 12), Color.WHITE, 1)
		return
	var t1 := HudDraw.tex("Text_pause1.png")
	if t1:
		var p := HudLayout.PAUSE_TEXT - t1.get_size() / 2
		draw_texture(t1, p.round())
		var a := absf(fmod(_t, 1.5) / 0.75 - 1.0)
		HudDraw.img(self, "Text_pause2.png", p.round(), Color(1, 1, 1, a))
	else:
		HudDraw.text(self, 62, HudDraw.txt("paused"), HudLayout.PAUSE_TEXT - Vector2(0, 12), Color.WHITE, 1)
	HudDraw.text(self, 5, HudDraw.txt("paused_text").replace("\\1", "Spacebar"), HudLayout.PAUSE_HINT,
		Color.WHITE, 1)
