class_name DroneSystemRule
extends RefCounted
## Drone system, system 4 (rules/drones.md §2, §11): DroneSystem::PowerDrone / DePowerDrone / OnLoop /
## ForceDecreasePower / CheckMaxPower / Jump, DroneControl::SelectArmament (player toggle).
## State lives on ShipState (`drones` = one Drone per slot, `drone_parts`); the system's `power` is the
## sum of the powered drones' power (like weapons).

const RECOVERY_AUG := "DRONE_RECOVERY"
const ENEMY_MAX_DRONES := 3  # prototype: drones an enemy takes from its blueprint list


## Builds the drones of a ship from its blueprint: <droneList drones="parts"> with <drone name=".."/>
## entries (player) or load="LIST" (enemies: drones of the list, in list order, while their power fits
## the drone system level).
static func load_drones(ship: ShipState) -> void:
	var text := FtlData.ship_blueprint_text(ship.blueprint.name)
	var dl := RegEx.create_from_string("<droneList\\b([^>]*?)(/>|>([\\s\\S]*?)</droneList>)").search(text)
	ship.drone_slots = int(ship.blueprint.get("drone_slots", 0))
	if dl == null:
		return
	var a := FtlData.attrs(dl.get_string(1))
	ship.drone_parts = int(a.get("drones", "0"))
	var names: Array = []
	for m in RegEx.create_from_string("<drone\\s+name=\"([^\"]+)\"").search_all(dl.get_string(3)):
		names.append(m.get_string(1))
	var ds := ship.sys("drones")
	if names.is_empty() and a.has("load") and ds != null:
		var budget := ds.get_level()
		for n in FtlData.blueprint_list(String(a.load)):
			var b := FtlData.drone_blueprint(n)
			if b.is_empty() or int(b.power) > budget or names.size() >= ENEMY_MAX_DRONES:
				continue
			names.append(n)
			budget -= int(b.power)
	set_drones(ship, names)


## Replaces the ship's drones (tests / presets). Undeploys the old ones first.
static func set_drones(ship: ShipState, names: Array) -> void:
	for d in ship.drones:
		if d.powered:
			depower_drone(ship, d)
		if d.deployed:
			set_deployed(ship, d, false)
	ship.drones.clear()
	for n in names:
		var b := FtlData.drone_blueprint(String(n).strip_edges())
		if not b.is_empty():
			ship.drones.append(Drone.new(b, ship, ship.drones.size()))
	ship.drone_slots = maxi(ship.drone_slots, ship.drones.size())
	_sync(ship)


## Bars used by the powered drones.
## DroneSystem::SwapDrones: slots a and b exchange their drones (the order is the depower order).
static func swap_drones(ship: ShipState, a: int, b: int) -> bool:
	if a == b or a < 0 or b < 0 or a >= ship.drones.size() or b >= ship.drones.size():
		return false
	var da := ship.drones[a]
	ship.drones[a] = ship.drones[b]
	ship.drones[b] = da
	ship.drones[a].slot = a
	ship.drones[b].slot = b
	return true


## Reactor + battery bars used by the powered drones (each costs its power minus its zoltan bonus).
static func power_used(ship: ShipState) -> int:
	var n := 0
	for d in ship.drones:
		if d.powered:
			n += d.required_power() - d.bonus_power
	return n


## Bars a drone still needs to be powered (RawIncreasePower: reactor + battery + bonus + n <= usable max).
static func _fits(ship: ShipState, s: SystemState, d: Drone) -> bool:
	return s.max_power() - power_used(ship) - s.bonus_power >= d.required_power() - d.bonus_power


static func _sync(ship: ShipState) -> void:
	var s := ship.sys("drones")
	if s:
		ship._set_power(s, power_used(ship))


## DroneSystem::PowerDrone. Returns "ok", "rebuilding", "no_parts", "no_system_power", "reactor" or "no_system".
## A drone that is not deployed costs one drone part and is deployed; re-powering a deployed one is free.
static func power_drone(ship: ShipState, d: Drone) -> String:
	var s := ship.sys("drones")
	if s == null:
		return "no_system"
	if d.powered:
		return "ok"
	if d.rebuilding():
		return ship.power_failed("drones", "rebuilding")
	if ship.drone_parts < 1 and not d.deployed:
		return ship.power_failed("drones", "no_parts")
	if not _fits(ship, s, d):
		return ship.power_failed("drones", "no_system_power")
	if ship.power_free() < d.required_power() - d.bonus_power:
		return ship.power_failed("drones", "reactor")  # DroneSystem::PowerDrone -> RawIncreasePower
	d.powered = true
	if not d.deployed:
		ship.drone_parts -= 1
		d.destroyed_timer = 0.0
		if not set_deployed(ship, d, true):
			d.powered = false
			ship.drone_parts += 1
			return "no_target"
		FtlData.play("droneLaunch")
	else:
		d.on_repowered()
	_sync(ship)
	Hooks.emit(&"drone_powered", ship, d)
	return "ok"


## DroneSystem::DePowerDrone: the bars go back; the drone stays deployed (drifts / freezes).
static func depower_drone(ship: ShipState, d: Drone) -> void:
	if not d.powered:
		return
	d.powered = false
	d.on_depowered()
	_sync(ship)
	Hooks.emit(&"drone_depowered", ship, d, false)


## Player right click / Shift+5-7 / box click on a powered drone (DroneControl::DeselectArmament).
static func player_depower(ship: ShipState, d: Drone) -> void:
	if not d.powered:
		return
	depower_drone(ship, d)
	Hooks.emit(&"drone_depowered", ship, d, true)


## Drone::SetDeployed. Crew drones appear in the drone-system room / are removed. Returns false if a
## crew drone found no room to stand in.
static func set_deployed(ship: ShipState, d: Drone, on: bool) -> bool:
	if on:
		d.deployed = true
		d.on_deploy()
		if d.is_crew() and not d.spawn_crew():
			d.deployed = false
			return false
		Hooks.emit(&"drone_deployed", ship, d)
		return true
	d.on_undeploy()
	d.deployed = false
	return true


## DroneControl::SelectArmament (player box click): depower if powered, else power with the UI checks.
## Returns "off", "ok" or the reason it failed ("locked", "no_parts", "no_target", "rebuilding",
## "no_system_power", "reactor").
static func player_toggle(ship: ShipState, d: Drone) -> String:
	if d.powered:
		player_depower(ship, d)
		return "off"
	var s := ship.sys("drones")
	if s == null:
		return "no_system"
	if s.is_locked() or s.hacked:
		return ship.power_failed("drones", "locked")
	if ship.drone_parts < 1 and not d.deployed:
		return "no_parts"
	if not d.deployed and not d.can_be_deployed():
		return "no_target"
	if d.rebuilding():
		return "rebuilding"
	return power_drone(ship, d)


## DroneSystem::OnLoop, slot order (bonus-power repowering is not modelled).
static func tick(ship: ShipState, seconds: float) -> void:
	var s := ship.sys("drones")
	if s == null or ship.drones.is_empty():
		return
	var hack := 2 if s.hacked else 0  # SetHacked(hackEffect): an actively hacked system stuns its drones
	for d in ship.drones:
		d.set_hacked(hack, seconds)
		if d.destroyed_timer > 0.0:
			d.destroyed_timer = maxf(d.destroyed_timer - seconds, 0.0)
			if d.destroyed_timer <= 0.0:
				Hooks.emit(&"drone_ready", ship, d)  # rebuilt: can be deployed again
		d.check_crew()
		if d.dead and d.deployed:
			# Step 4: destroyed -> undeployed, depowered, 10 s rebuild (if requested); the part is gone.
			d.destroyed_timer = Drone.REBUILD_TIME if d.rebuild_on_death else 0.0
			set_deployed(ship, d, false)
			d.dead = false
			depower_drone(ship, d)
			Hooks.emit(&"drone_destroyed", ship, d)
			Combat.log("%s drone %s destroyed%s" % [ship.blueprint.name, d.bp.name,
				" (rebuild 10 s)" if d.destroyed_timer > 0.0 else ""])
		elif d.dead:
			d.dead = false
		elif not d.can_be_deployed() and (d.powered or (ship.is_player and d.deployed)):
			recall(ship, d)  # step 5
		if d.crew != null:
			d.crew.frozen = not d.powered
			if d.hack_level >= 2:
				d.crew.stun = maxf(d.crew.stun, 0.5)
	check_max_power(ship)


## DroneSystem::UpdateBonusPower (rules/races.md "Weapons and drones"): the system's zoltan bonus is spread in slot
## order (each drone min(remaining, its power)). A powered drone whose bonus shrank is depowered and flagged for a
## re-power next frame; an unpowered drone fully covered by bonus is powered (if deployable / deployed).
static func update_bonus(ship: ShipState) -> void:
	var s := ship.sys("drones")
	if s == null:
		return
	for d in ship.drones:  # repowerList from the previous frame
		if d.has_meta("bonus_repower"):
			d.remove_meta("bonus_repower")
			if not d.powered and not s.is_power_locked() and (d.deployed or d.can_be_deployed()):
				power_drone(ship, d)
	var remaining := s.bonus_power
	for d in ship.drones:
		var nb := mini(remaining, d.required_power())
		remaining -= nb
		var old := d.bonus_power
		d.bonus_power = nb
		if d.powered and nb < old:
			depower_drone(ship, d)
			d.set_meta("bonus_repower", true)
		elif not d.powered and nb > 0 and nb == d.required_power() and not d.rebuilding() \
				and (d.deployed or (d.can_be_deployed() and ship.drone_parts > 0)) and not s.is_power_locked():
			power_drone(ship, d)
	check_max_power(ship)


## Recall (OnLoop step 5 / Jump): DRONE_RECOVERY refund for a recoverable deployed live drone, player
## drones undeployed, then depowered. Enemy drones stay deployed (re-powering them costs no part).
static func recall(ship: ShipState, d: Drone) -> void:
	if ship.has_augment(RECOVERY_AUG) and d.can_be_recovered() and d.deployed and not d.dead:
		ship.drone_parts += 1
	if ship.is_player and d.deployed:
		set_deployed(ship, d, false)
	depower_drone(ship, d)


## CheckMaxPower / AddDamage: depower powered drones from the last slot while over the usable maximum.
static func check_max_power(ship: ShipState) -> void:
	var s := ship.sys("drones")
	if s == null:
		return
	for i in range(ship.drones.size() - 1, -1, -1):
		if power_used(ship) + s.bonus_power <= s.max_power():
			break
		if ship.drones[i].powered:
			depower_drone(ship, ship.drones[i])
	_sync(ship)


## ForceDecreasePower(n) (ion): from the last slot, each powered drone is depowered whole and its power
## subtracted from n, until n < 1. Not re-powered when the lock ends.
static func force_decrease(ship: ShipState, n: int) -> void:
	var left := n
	for i in range(ship.drones.size() - 1, -1, -1):
		if left < 1:
			break
		var d := ship.drones[i]
		if d.powered:
			left -= d.required_power()
			depower_drone(ship, d)


## Reactor overuse: the last powered drone loses its power.
static func depower_last(ship: ShipState) -> bool:
	for i in range(ship.drones.size() - 1, -1, -1):
		if ship.drones[i].powered:
			depower_drone(ship, ship.drones[i])
			return true
	return false


## DroneSystem::Jump (no FTL jump yet; called by tests): every space drone (and any undeployable drone)
## is recalled as in step 5. Crew drones stay where they are.
static func jump(ship: ShipState) -> void:
	for d in ship.drones:
		if (not d.can_be_deployed() or d.recall_on_jump()) and (d.deployed or d.powered):
			recall(ship, d)


## ShipDestroyed: every drone unpowered and un-hacked.
static func ship_destroyed(ship: ShipState) -> void:
	for d in ship.drones:
		d.hack_level = 0
		depower_drone(ship, d)
