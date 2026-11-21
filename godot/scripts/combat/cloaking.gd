class_name CloakRule
extends RefCounted
## Cloaking, system 10 (rules/cloaking.md): CloakingSystem::SetTurnedOn/OnLoop/FiredWeapon/Jump.
## Duration = effective power x 5 s (the goal follows the current power, keeping the elapsed fraction);
## while on the system is locked indefinitely (-1); when it ends: AddLock(4) = 20 s cooldown.
## Effects elsewhere: +60 evasion (ShipState.dodge_factor), opposing weapons do not charge
## (ShipState.tick / ArtilleryRule), teleports blocked (TeleporterRule), AI holds fire (ShipAI).

const SECONDS_PER_POWER := 5.0
const COOLDOWN_UNITS := 4  # lock units of 5 s
const FIRE_COST := 0.2  # fraction of the full duration burnt per volley (without CLOAK_FIRE)


## CanCloak / Ready: has cloaking, not locked (or hacked), not already on.
static func ready(ship: ShipState) -> bool:
	var c := ship.sys("cloaking")
	return c != null and not c.is_locked() and not c.hacked and not c.turned_on


## SetTurnedOn(true). Returns true if it was switched on now.
static func turn_on(ship: ShipState) -> bool:
	var c := ship.sys("cloaking")
	if c == null or c.turned_on or c.is_locked() or c.hacked:
		return false
	if c.effective_power() <= 0:  # not Functioning
		return false
	c.sound_effect = "cloak"  # played by the next CloakingSystem::OnLoop: a cloak started while paused is heard at unpause
	c.turned_on = true
	c.lock_system(-1)
	c.timer = 0.0
	c.timer_goal = c.effective_power() * SECONDS_PER_POWER
	return true


## SetTurnedOn(false) while on: "decloak" sound and AddLock(4) (20 s; min(count + 4, 5) if ionized).
static func turn_off(ship: ShipState) -> void:
	var c := ship.sys("cloaking")
	if c == null or not c.turned_on:
		return
	c.sound_effect = "decloak"
	c.add_lock(COOLDOWN_UNITS)
	c.turned_on = false


## CloakingSystem::OnLoop (the lock timer already ran in ShipState.tick).
static func tick(ship: ShipState, seconds: float) -> void:
	var c := ship.sys("cloaking")
	if c == null:
		return
	if c.turned_on and c.hacked:  # hacked with an active pulse
		turn_off(ship)
	if c.turned_on and c.effective_power() <= 0:
		turn_off(ship)
	set_max_time(c, c.effective_power() * SECONDS_PER_POWER)
	if c.turned_on:
		c.timer += seconds
		if c.timer > c.timer_goal:
			turn_off(ship)
	# soundeffect: SetTurnedOn only stores "cloak" / "decloak"; OnLoop plays it once and clears it.
	if c.sound_effect != "":
		FtlData.play(c.sound_effect)
		c.sound_effect = ""


## TimerHelper::SetMaxTime: a new goal rescales the elapsed time (the elapsed fraction is kept).
static func set_max_time(c: SystemState, goal: float) -> void:
	if goal <= 0.0:
		return
	if c.timer_goal > 0.0 and not is_equal_approx(goal, c.timer_goal):
		c.timer = c.timer / c.timer_goal * goal
	c.timer_goal = goal


## FiredWeapon: once per volley of the weapons system (after its last projectile): 20 % of the full
## duration, unless the ship has CLOAK_FIRE. Also applied when not cloaked (harmless).
static func fired_weapon(ship: ShipState) -> void:
	var c := ship.sys("cloaking")
	if c == null or ship.has_augment("CLOAK_FIRE"):
		return
	c.timer += c.timer_goal * FIRE_COST


## CloakingSystem::Jump: decloak with the cooldown (carries to the next beacon).
static func jump(ship: ShipState) -> void:
	turn_off(ship)


## CloakingBox bar: 1 - timer progress while on; cooldown fraction while locked; -1 when ready.
static func remaining_fraction(ship: ShipState) -> float:
	var c := ship.sys("cloaking")
	if c == null or not c.turned_on or c.timer_goal <= 0.0:
		return -1.0
	return clampf(1.0 - c.timer / c.timer_goal, 0.0, 1.0)
