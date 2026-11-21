class_name ReactorColumn
extends Control
## Reactor bars (SystemControl::RenderPowerBar): one 28×7 bar per unit at x 12, pitch 9, growing up from
## y 696 (rules/hud_layout.md). Bottom first: free backup-battery bars (tiny green in an orange frame), free
## reactor bars (COLOR_GREEN, white in the "not enough power" flash), then empty outlines for used power.
## Placed at the frame origin (draws in frame coordinates), mouse-transparent.
##
## NOT ENOUGH POWER (rules/power.md "Power-up failure warning"; SystemControl::notEnoughPower): every frame the
## ship's `failed_powerup` flag is read and cleared (PowerManager::GetFailedPowerup, player ship only); if it was
## set the warning starts (no restart while running): text `warning_no_power` in font 59, COLOR_BUTTON_ON with the
## white backglow, at (6, 74 px above the column top), 2.31 s, flashing every 0.66 s; the free reactor bars flash
## white in the bright half. The flag is set by the RULE layer (ShipState.power_failed: clicks, weapon / drone
## power, automatic re-power), so the warning also appears with no click.

const NO_POWER_TIME := 2.31
const TEXT_X := 6
const TEXT_ABOVE := 74

var ship: ShipState
var no_power := WarningMessage.new("warning_no_power", Vector2.ZERO, NO_POWER_TIME, false, true)
var starts := 0  # times the warning started (tests)


func setup(s: ShipState) -> void:
	ship = s
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	position = Vector2.ZERO
	size = Vector2(60, HudLayout.FRAME.y)


func _process(d: float) -> void:
	poll(d)
	queue_redraw()


## SystemControl::OnLoop part: consume the flag, start the warning, advance it.
func poll(d: float) -> void:
	if ship == null:
		return
	no_power.update(d)
	if ship.take_failed_powerup():
		if not no_power.running():
			starts += 1
		no_power.start()


## Total bars drawn (reactor + battery), free reactor bars, free battery bars.
func counts() -> Vector3i:
	return Vector3i(ship.reactor_max + ship.battery_cap, maxi(ship.reactor_free(), 0),
		maxi(ship.battery_free(), 0) if ship.battery_cap > 0 else 0)


## Bar i (0 = bottom): GetPowerBars(28, 7, 2) primitive at systemPowerPosition (12, 304) of SystemControl
## (0, 382) moved up 9 px per bar -> top y 686 - 9 i (matches the vanilla screenshots).
static func bar_rect(i: int) -> Rect2:
	return Rect2(HudLayout.REACTOR_X, HudLayout.REACTOR_BAR_TOP - HudLayout.REACTOR_PITCH * i,
		HudLayout.REACTOR_BAR.x, HudLayout.REACTOR_BAR.y)


## Reactor bars lost to a hacked battery / ion storm divide (level - PowerManager::GetMaxPower), drawn on top.
func lost_bars() -> int:
	return maxi(ship.reactor_max - ship.reactor_capacity(), 0)


## Top y of the reactor column with n bars (SystemPower hit rect: y 696 - 9 n).
static func top_y(n: int) -> float:
	return HudLayout.REACTOR_BOTTOM - HudLayout.REACTOR_PITCH * n


## Text top-left of the warning for a column of n bars: (6, 622 - 9n).
static func warning_pos(n: int) -> Vector2:
	return Vector2(TEXT_X, top_y(n) - TEXT_ABOVE)


func _draw() -> void:
	if ship == null:
		return
	var c := counts()
	var white := no_power.flash_on()
	var lost := lost_bars()
	for i in c.x:
		var r := bar_rect(i)
		if i < c.z:  # free battery bar: `tiny` green inside an orange `empty` outline
			draw_rect(r.grow(-2), FtlColors.GREEN)
			FtlColors.draw_bar_outline(self, r, FtlColors.BATTERY)
		elif i >= c.x - lost:  # reactor bars lost to hacking / ion storm (above max + battery): `damaged`
			FtlColors.draw_bar_damaged(self, r, FtlColors.LOST)
		elif i < c.z + c.y:
			draw_rect(r, Color.WHITE if white else FtlColors.GREEN)
		else:
			FtlColors.draw_bar_outline(self, r, Color.WHITE)  # SystemControl::RenderPowerBar: `empty`, white
	no_power.draw(self, warning_pos(c.x))
	Hooks.emit(&"hud_draw.reactor", self, ship)
