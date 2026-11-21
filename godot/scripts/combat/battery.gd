class_name BatteryRule
extends RefCounted
## Backup battery, system 12 (rules/battery.md): BatterySystem::SetTurnedOn/OnLoop/Jump and
## ShipManager::CheckBatteryPower. The battery is a subsystem (its power = level - damage, no reactor);
## while on it gives the ship 2 x its power extra bars for 30 s. Bars are taken from the reactor first
## and from the battery only when the reactor is exhausted (ShipState._set_power); when the battery
## ends, its bars are stripped (CheckBatteryPower) and re-powered from the reactor where possible.

const DURATION := 30.0  # s (TimerHelper min = max = 30)
const BARS_PER_POWER := 2
const COOLDOWN_UNITS := 4.0  # lock units (5 s each) after it ends, x BATTERY_BOOSTER value (0.5)
const HACK_REACTOR_LOSS := 2  # PowerManager::SetHacked: reactor maximum -2 while actively hacked


## Ready() = not locked and not on (the button's availability).
static func ready(ship: ShipState) -> bool:
	var b := ship.sys("battery")
	return b != null and not b.is_locked() and not b.hacked and not b.turned_on


## SetTurnedOn(true, force). Returns true if it was switched on now.
static func turn_on(ship: ShipState, force := false) -> bool:
	var b := ship.sys("battery")
	if b == null or b.turned_on:
		return false
	if (b.is_locked() or b.hacked) and not force:
		return false
	if b.effective_power() <= 0:  # not Functioning
		return false
	FtlData.play("batteryStart")
	b.turned_on = true
	b.lock_system(-1)  # indefinite lock while running (white frame)
	b.timer = 0.0
	b.timer_goal = DURATION
	ship.battery_cap = BARS_PER_POWER * b.effective_power()
	return true


## SetTurnedOn(false) while on: cooldown lock AddLock(int(4 x BATTERY_BOOSTER)) = 20 s (10 s).
static func turn_off(ship: ShipState) -> void:
	var b := ship.sys("battery")
	if b == null:
		return
	if b.turned_on:
		FtlData.play("batteryStop")
		b.add_lock(int(ship.augment_value("BATTERY_BOOSTER", 1.0) * COOLDOWN_UNITS))
		b.turned_on = false
	ship.battery_cap = 0


## BatterySystem::OnLoop (after the lock timer, which ShipState.tick runs) + CheckBatteryPower.
static func tick(ship: ShipState, seconds: float) -> void:
	var b := ship.sys("battery")
	if b == null:
		ship.battery_cap = 0
		ship.reactor_hacked = 0
		check_battery_power(ship)
		return
	if b.turned_on and b.effective_power() <= 0:
		turn_off(ship)
	# Actively hacked: reactor -2 and the battery is forced off (cooldown starts).
	ship.reactor_hacked = HACK_REACTOR_LOSS if b.hacked else 0
	if b.hacked and b.turned_on:
		turn_off(ship)
	if b.turned_on:
		b.timer_goal = DURATION
		b.timer += seconds
		if b.timer >= DURATION:
			turn_off(ship)
	ship.battery_cap = BARS_PER_POWER * b.effective_power() if b.turned_on else 0
	check_battery_power(ship)


## BatterySystem::Jump: off (cooldown added), then every lock is cleared -> ready at the next beacon.
static func jump(ship: ShipState) -> void:
	var b := ship.sys("battery")
	if b == null:
		return
	turn_off(ship)
	b.lock_system(0)
	check_battery_power(ship)


## BatteryBox::GetCooldownFraction: ready -> -1 (no bar); running -> 1 - elapsed/30; cooldown -> 0.
static func cooldown_fraction(ship: ShipState) -> float:
	var b := ship.sys("battery")
	if b == null or ready(ship):
		return -1.0
	if b.turned_on:
		return 1.0 - b.timer / DURATION
	return 0.0


## ShipManager::CheckBatteryPower: if the systems hold more battery bars than the battery gives, remove
## exactly `excess` of them chosen uniformly at random (selection sampling over the bars, walking the
## system list in blueprint order). A removal on shields holding >= 2 battery bars counts as 2.
static func check_battery_power(ship: ShipState) -> void:
	var excess := ship.battery_used() - ship.battery_cap
	if excess <= 0:
		return
	var remaining := ship.battery_used()
	for id in ship.system_list():
		var s := ship.sys(id)
		var i := 0
		while i < s.battery and excess > 0 and remaining > 0:
			if ship.rng.randi() % remaining < excess:
				var removed := remove_battery_power(ship, s)
				excess -= removed
				remaining -= removed
			else:
				remaining -= 1
				i += 1


## ShipSystem/Shields/WeaponSystem::RemoveBatteryPower. Returns the battery bars actually removed (>= 1).
static func remove_battery_power(ship: ShipState, s: SystemState) -> int:
	var before := s.battery
	match s.id:
		"weapons":
			# Depower whole weapons from the last slot until >= 1 bar is freed, then re-power (from the
			# last slot) every weapon that was powered before, if the reactor has room.
			var was: Array = ship.weapons.map(func(w): return w.powered)
			var freed := 0
			for i in range(ship.weapons.size() - 1, -1, -1):
				var w := ship.weapons[i]
				if w.powered:
					freed += w.power_cost()
					ship._set_weapon_powered(w, false)
					if freed >= 1:
						break
			for i in range(ship.weapons.size() - 1, -1, -1):
				if was[i] and not ship.weapons[i].powered:
					ship.try_power_weapon(ship.weapons[i])
		"shields":
			# Shields::ForceDecreasePower: 1 bar, and another if that left it odd -> a whole layer.
			ship._set_power(s, s.power - 1)
			if s.power % 2 == 1 and not s.is_locked():
				ship._set_power(s, s.power - 1)
			ship._clamp_shields()
			ship._on_unlocked(s)  # CheckForRepower (pairs, reactor permitting)
			ship._clamp_shields()
		"drones":
			ship._set_power(s, s.power - 1)
		_:
			ship._set_power(s, s.power - 1)
			ship._on_unlocked(s)  # CheckForRepower: back to lastUserPower from the reactor
	return maxi(before - s.battery, 1)
