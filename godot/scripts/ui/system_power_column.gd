class_name SystemPowerColumn
extends Control
## One system box of the bottom-left bar (FTL SystemBox; rules/hud_layout.md, rules/power.md): the 64×64
## `icons/s_<sys>_<colour><n>.png` symbol at the box location, the power bars (16×6, pitch 8) growing up from
## it, the manning icon and the status icons (lock / hacked / sabotage / fire) above.
## Click = +1 bar, right click = −1 (if `clickable`). The control covers the box and the space above it;
## only the bars + symbol column takes the mouse (`_has_point`).

signal increase_requested(sys_id: String)
signal decrease_requested(sys_id: String)

const ABOVE := 190.0  # px of the control above the box location (bars + manning + status icons)
const MANNED_ICONS := {1: "manning_white", 2: "manning_green", 3: "manning_yellow"}  # skill level 1..3

var ship: ShipState
var system_id := "weapons"
var clickable := true
var loc := Vector2.ZERO  # box location in the 1280×720 frame
var hovered := false
var _time := 0.0
## SystemBox::warning (shields only): warning_needs_upgrade, 2.0 s, no flash, left-aligned at (box.x + 5,
## box.y - 78 - 33) (on fire: - 53 instead of - 33).
var warning := WarningMessage.new("warning_needs_upgrade", Vector2(5, 0), 2.0)


func setup(s: ShipState, sys_id: String, can_click := true, at := Vector2.ZERO) -> void:
	ship = s
	system_id = sys_id
	clickable = can_click
	mouse_filter = Control.MOUSE_FILTER_STOP if can_click else Control.MOUSE_FILTER_IGNORE
	place(at)


## Puts the box at `at` (frame coordinates, parent at the frame origin).
func place(at: Vector2) -> void:
	loc = at
	position = at - Vector2(0, ABOVE)
	size = Vector2(64, ABOVE + 64)
	custom_minimum_size = size


func _process(delta: float) -> void:
	_time += delta
	warning.update(delta)
	# SystemBox::OnLoop / MouseMove: player box with bShowPower -> GenerateTooltip, W300, delayed.
	if ship and ship.is_player and ship.sys(system_id) and TooltipService.over(self, tooltip_rect()):
		TooltipService.request(TooltipText.system(ship, system_id), {"width": TooltipService.WRAP_BOX,
			"kind": &"system", "source": self, "ctx": {"ship": ship, "system": system_id}})
	queue_redraw()


## Mouse area. Touch (a live TouchPowerToggle): the whole column (hit_rect). PC: the vanilla areas only, the
## tooltip column (tooltip_rect) and the click square on the symbol (click_rect) [exe SystemBox::MouseMove].
func _has_point(p: Vector2) -> bool:
	if TouchPowerToggle.live():
		return hit_rect().has_point(p)
	return strictly_inside(tooltip_rect(), p) or strictly_inside(click_rect(), p)


## Touch / layout column: the bars and the symbol (x+16..x+48, from one pitch above the top bar to the symbol's
## bottom). Also the drawn bounds used by the touch layouts.
func hit_rect() -> Rect2:
	var s := ship.sys(system_id) if ship else null
	var n := s.get_level() if s else 1
	var top := ABOVE + bar_y(s, n - 1) - HudLayout.POWER_PITCH  # one pitch above the top bar
	return Rect2(16, top, 32, ABOVE + 48 - top)


## SystemBox::MouseMove `mouseHover` [exe 004d3b30]: loc.x + 21 < mX < loc.x + 42 and loc.y + 21 < mY < loc.y + 42
## (strict) — the system symbol only. Left / right clicks (SystemBox::MouseClick / MouseRightClick) and the hovered
## symbol need it: clicking the bars does nothing on PC.
func click_rect() -> Rect2:
	return Rect2(21, ABOVE + 21, 21, 21)


## SystemBox::OnRender `hitBox` (tooltip area, strict test in MouseMove): x loc.x + 24, w 15, from topPower + 16 to
## loc.y + 31, topPower = RenderPowerBoxes' return (the top item − 20: bars, manning icon, lock / status icons).
## Touch: the whole column (hit_rect).
func tooltip_rect() -> Rect2:
	if TouchPowerToggle.live():
		return hit_rect()
	var top := (_top_item if _top_item >= 0.0 else hit_rect().position.y + HudLayout.POWER_PITCH - 6.0) - 20.0 + 16.0
	return Rect2(24, top, 15, ABOVE + 31 - top)


## The vanilla hit tests are strict on every edge (GenericButton / SystemBox: x < mX < x + w).
static func strictly_inside(r: Rect2, p: Vector2) -> bool:
	return p.x > r.position.x and p.x < r.end.x and p.y > r.position.y and p.y < r.end.y


var _top_item := -1.0  # y (control coordinates) of the top item drawn by draw_box (-1 = not drawn yet)


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_ENTER:
		hovered = TouchPowerToggle.live()  # PC: set by the motion inside click_rect (_gui_input)
	elif what == NOTIFICATION_MOUSE_EXIT:
		hovered = false


## Touch (a live TouchPowerToggle): the tap acts on the lift, inside the column, unless `cancel_press` dropped it
## (a second finger tapped while this one was held: TouchGestures). PC: on the press, as before.
var _touch_pressed := false


func cancel_press() -> void:
	_touch_pressed = false


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and not TouchPowerToggle.live():
		hovered = strictly_inside(click_rect(), event.position)
	if not clickable or not event is InputEventMouseButton:
		return
	if event.button_index == MOUSE_BUTTON_LEFT and TouchPowerToggle.live():
		if event.pressed:
			_touch_pressed = true
		elif _touch_pressed:
			_touch_pressed = false
			# The power tap needs the system symbol, as on PC (the bars only show the tooltip while held).
			if click_rect().has_point(event.position):
				if TouchPowerToggle.removing():  # touch − mode: a tap removes a bar
					decrease_requested.emit(system_id)
				else:
					increase_requested.emit(system_id)
		accept_event()
		return
	if not event.pressed or not strictly_inside(click_rect(), event.position):
		return  # PC: only the symbol square takes the clicks (SystemBox::MouseClick needs mouseHover)
	if event.button_index == MOUSE_BUTTON_LEFT:
		increase_requested.emit(system_id)
		accept_event()
	elif event.button_index == MOUSE_BUTTON_RIGHT:
		decrease_requested.emit(system_id)
		accept_event()


func _draw() -> void:
	var s := ship.sys(system_id) if ship else null
	if s == null:
		return
	var clone := system_id == "clonebay" and ship.is_player
	var top := draw_box(self, ship, s, Vector2(0, ABOVE), _time, true, true, hovered and clickable,
		CloneQueueBox.height_modifier(ship) if clone else 0)
	_top_item = top
	if clone:  # CloneBox::OnRender: queue box above the bars (topPower = RenderPowerBoxes' return = top - 20)
		CloneQueueBox.draw(self, ship, Vector2(0, ABOVE), top - 20.0, _time)
	if warning.running():
		var fire := ship.fires.has(s.room) and not (ship.fires[s.room] as Dictionary).is_empty()
		warning.draw(self, Vector2(warning.position.x, ABOVE - 78 + (-53 if fire else -33)))
	Hooks.emit(&"hud_draw.system_box", self, ship, system_id)


## SystemBox::OnRender + ShipSystem::RenderPowerBoxes / RenderSystemSymbol at box location `l` (in `ci`'s
## coordinates). `show_power` false = symbol only (enemy without sensors). Returns the y of the top item.
## `height_mod` = SystemBox::GetHeightModifier (CloneBox queue): the status icons start that much higher.
static func draw_box(ci: CanvasItem, sh: ShipState, s: SystemState, l: Vector2, time: float, player_ui: bool,
		show_power: bool, hover := false, height_mod := 0) -> float:
	var x := l.x + (64 - HudLayout.POWER_BAR.x) / 2  # = x + 24
	var top := l.y
	if show_power:  # ShipSystem::RenderPowerBoxes (everything above the symbol is drawn only here)
		var n := s.get_level()
		var usable := s.get_level() - s.damage
		var dmg := partial_damage(sh, s)
		for i in n:
			var r := Rect2(x, l.y + bar_y(s, i), HudLayout.POWER_BAR.x, HudLayout.POWER_BAR.y)
			FtlColors.draw_power_bar(ci, r, bar_draw_state(s, i))
			# Repair progress: yellow (255,255,50) on the lowest broken bar, growing from its right edge;
			# damage progress (fire / sabotage): red on the top working bar, growing from its left edge.
			if i == usable and s.repair_progress > 0.0:
				var f := clampf(s.repair_progress / 100.0, 0.0, 1.0)
				ci.draw_rect(Rect2(r.end.x - r.size.x * f, r.position.y, r.size.x * f, r.size.y), FtlColors.YELLOW)
			if i == usable - 1 and dmg > 0.0:
				ci.draw_rect(Rect2(r.position, Vector2(r.size.x * dmg, r.size.y)), FtlColors.RED)
		var bars_top := l.y + bar_y(s, n - 1)  # top bar's top
		top = bars_top - 6
		# Manning icon right above the top bar (rules/hud_layout.md "Manning icon").
		var man := manning_icon(sh, s)
		if not man.is_empty():
			var t := HudDraw.tex("systemUI/%s.png" % man[0])
			if t:
				ci.draw_texture(t, Vector2(l.x, bars_top) + (man[1] as Vector2))
			top -= int(man[2])
		var outline := FtlColors.lock_outline(s)
		if outline.a > 0.0 and n > 0:
			# lockOutline: 2 px, pad gap/2 + 2 = 3 px around the bars (the manning icon is never shown with it:
			# ion / lock / hack all block the boost).
			var o := Rect2(x - 3, bars_top - 3, HudLayout.POWER_BAR.x + 6,
				l.y + bar_y(s, 0) + HudLayout.POWER_BAR.y + 3 - (bars_top - 3))
			FtlColors.draw_bar_outline(ci, Rect2(o.position, o.size), outline, 2.0)
			top = o.position.y
		top -= height_mod  # RenderPowerBoxes(heightMod): after the bars / manning icon / outline, before the icons
		# Status icons stacked above (ShipSystem::RenderPowerBoxes; static images, the exe draws no animation):
		# lock 21 px, hacked 22, sabotage 24 (bOccupied and damage in progress), fire 22 (bOnFire). x = the
		# primitives' offsets: lock +20, hacked +16, sabotage / fire +15.
		var icons := []
		if s.is_ionized() or s.ion < 0:
			icons.append(["icons/locking/s_lock_white.png" if s.ion < 0 else "icons/locking/s_lock.png", 21, 20])
		if s.hack_effect() > 0:
			icons.append(["icons/s_hacked.png", 22, 16])
		if sh != null and s.sabotaged():
			icons.append(["icons/s_sabatoge.png", 24, 15])
		if sh != null and sh.fires.has(s.room) and not (sh.fires[s.room] as Dictionary).is_empty():
			icons.append(["icons/s_fire2.png", 22, 15])
		for ic in icons:
			var t := HudDraw.tex(ic[0])
			top -= int(ic[1])
			if t:
				ci.draw_texture(t, Vector2(l.x + int(ic[2]), top - 4))
	# SystemBox::OnRender: while the lock counter is >= 1 (cooldown or ion) the symbol is replaced by the lock
	# timer (player HUD, or an enemy box that shows its power).
	if show_power and s.ion >= 1:
		draw_lock_timer(ci, s, l)
		return top
	# Symbol: s_<sys>_<colour>1 (2 = hovered).
	var sym := s.symbol_texture(time, 2 if hover else 1)
	if sym == null:
		sym = s.symbol_texture(time)
	if sym:
		ci.draw_texture(sym, l)
	return top


## Top of power bar `i` (0 = lowest) relative to the box location y (SystemControl::GetPowerBars +
## ShipSystem::RenderPowerBoxes(loc, 16, 6, 2)): the column origin is loc.y + 10 − gap = loc.y + 8, bars step up
## by height + gap = 8, and the shields (useShieldGap) add 2·gap = 4 more after every odd bar (layers in pairs).
## The lowest bar spans loc.y + 8 .. + 13, 5 px above the symbol glyph (rows 19..44 of the 64×64 icon).
static func bar_y(s: SystemState, i: int) -> float:
	var y := HudLayout.POWER_BAR_Y0 - HudLayout.POWER_PITCH * i
	if s != null and s.id == "shields" and i > 0:
		y -= HudLayout.SHIELD_PAIR_GAP * (i >> 1)
	return y


## fDamageOverTime / 100 of the top working bar: intruder sabotage and fire damage in progress (0..1).
static func partial_damage(_sh: ShipState, s: SystemState) -> float:
	return clampf(s.damage_progress / 100.0, 0.0, 1.0) if s.damage < s.get_level() else 0.0


## Bar colour state as RenderPowerBoxes draws it: lock counter -1 (system in use) -> untinted white bars; a lock
## >= 1 -> ion blue even while hacked; otherwise SystemState.bar_state.
static func bar_draw_state(s: SystemState, i: int) -> String:
	var st: String = s.bar_state(i)
	if st in ["on", "hack", "ion", "battery"]:
		if s.ion == -1:
			return "white"
		if s.ion > 0:
			return "ion"
	return st


## Lock timer (SystemBox::OnRender, timerCircle / timerLines): `icons/locking/s_ring_<count>_base.png` (systems that
## need reactor power) or `s_octa_<count>_base.png` (subsystems) at the box location, then `s_ring_timer.png` /
## `s_octa_timer.png` through a pie of radius 17 centred at (32, 32) from -85 deg to -85 + 30 k deg,
## k = int(12 - 12 t / 5 + 1) of the current 5 s lock unit: one tick mark vanishes every 5/12 s.
static func draw_lock_timer(ci: CanvasItem, s: SystemState, l: Vector2) -> void:
	var shape := "octa" if s.is_subsystem() else "ring"
	var base := HudDraw.tex("icons/locking/s_%s_%d_base.png" % [shape, clampi(s.ion, 1, 9)])
	if base:
		ci.draw_texture(base, l)
	var lines := HudDraw.tex("icons/locking/s_%s_timer.png" % shape)
	if lines == null:
		return
	var sweep := minf(30.0 * lock_timer_steps(s.ion_timer), 360.0)
	if sweep <= 0.0:
		return
	var c := Vector2(32, 32)
	var pts := PackedVector2Array([l + c])
	var uvs := PackedVector2Array([c / 64.0])
	var steps := maxi(int(sweep / 5.0), 2)
	for j in steps + 1:
		var a := deg_to_rad(-85.0 + sweep * j / steps)
		var p := c + Vector2(cos(a), sin(a)) * 17.0
		pts.append(l + p)
		uvs.append(p / 64.0)
	ci.draw_colored_polygon(pts, Color.WHITE, uvs, lines)


## Pie steps k of the lock timer `t` s into the current 5 s unit (13 at t = 0: full circle).
static func lock_timer_steps(t: float) -> int:
	return int(12.0 - 12.0 * t / SystemState.ION_SECONDS + 1.0)


## RenderPowerBoxes manning icon: [image, offset from (box x, top bar's top), height it takes], or [] when
## none. Shown only for a boostable system that BlockedBoosted(!bLevelBoostable) does not block.
## Level-boostable (sensors, doors): manning_bar_on (manned and intact) / manning_bar_off, the bracketed
## crew icon at (24, −9), 8 px. Others: manning_outline (nobody), manning_white / _green / _yellow
## (skill level 1 / 2 / 3) at (25, −24), 16 px (outline / white) or 24 px (green / yellow, with stars).
static func manning_icon(sh: ShipState, s: SystemState) -> Array:
	if sh == null or not sh.is_boostable(s.id) or blocked_boosted(sh, s):
		return []
	var lvl := sh.crew_level_in(s.key)
	if ShipState.LEVEL_BOOSTABLE.has(s.id):
		return ["manning_bar_on" if lvl > 0 else "manning_bar_off", Vector2(24, -9), 8]
	match lvl:
		2:
			return ["manning_green", Vector2(25, -24), 24]
		3:
			return ["manning_yellow", Vector2(25, -24), 24]
		1:
			return ["manning_white", Vector2(25, -24), 16]
	return ["manning_outline", Vector2(25, -24), 16]


## ShipSystem::BlockedBoosted: intruders in the room (bOccupied), fire, a lock (ion / cooldown / indefinite),
## a hack pulse, any damage, no effective power, a passive hack under attack, or event power loss.
static func blocked_boosted(sh: ShipState, s: SystemState) -> bool:
	if s.ion != 0 or s.hack_effect() > 0 or s.damage > 0 or s.effective_power() <= 0 or s.power_loss > 0:
		return true
	if sh.fires.has(s.room) and not (sh.fires[s.room] as Dictionary).is_empty():
		return true
	for c in sh.crew:
		if c.is_alive() and c.room == s.room and c.is_intruder(sh):
			return true
	return false
