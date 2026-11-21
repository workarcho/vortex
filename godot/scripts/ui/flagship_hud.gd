class_name FlagshipHud
extends Control
## The flagship's "POWER SURGE DETECTED" warning (rules/flagship.md): SpaceStatus::incomingFire, a WarningMessage
## `warning_power_surge` at SpaceStatus position + (2, 12) = (692, 84), centred, COLOR_RED_WARNING, flashing,
## 3 s looping, sound `surgeWarning` on Start, warning line. CommandGui::OnLoop calls SetIncomingFire every frame
## with the enemy ship's IncomingFire() (BossShip: < 5 s left on the power timer in stages 2 / 3): true -> Start
## (no-op while running), false -> Stop.

const POS := Vector2(692, 84)

var run: RunState
var warning := WarningMessage.new("warning_power_surge", POS, 3.0, true, true, HudLayout.RED_WARNING)


func setup(r: RunState) -> void:
	run = r
	position = Vector2.ZERO
	size = HudLayout.FRAME
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func incoming() -> bool:
	if run == null or run.enemy.is_empty() or not run.enemy.get("boss", false):
		return false
	if bool(run.enemy.get("done", false)) or not bool(run.enemy.get("hostile", false)):
		return false
	return FlagshipRule.incoming_fire(run.boss)


func _process(delta: float) -> void:
	if incoming():
		if not warning.running():
			FtlData.play("surgeWarning")
		warning.start()
		warning.update(delta)
		if not warning.running():
			warning.start()  # SetLoop(true): the tracker loops while the surge is pending
	else:
		warning.stop()
	queue_redraw()


func _draw() -> void:
	warning.draw(self)
