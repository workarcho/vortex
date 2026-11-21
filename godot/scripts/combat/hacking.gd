class_name HackingRule
extends RefCounted
## Hacking system, system 15 (rules/hacking.md): HackingSystem::OnLoop / StartHacking / InitiatePulse /
## CanHack / CanPulse / StopHacking, the per-frame room and door hack levels of ShipManager::OnLoop
## (Ship::SetHackLevel), and the SetHackingLevel overrides of shields, teleporter and mind control.
## State lives on ShipState (`hacking`, `hack_target`, `hack_drone`, ...). The target is a SystemState of
## `ship.opponent`; its `hack_level` / `under_attack` are what every other rule reads (`SystemState.hacked`
## = actively hacked, level 2 under attack).

const EFFECT_TIMER := [10.0, 4.0, 7.0, 10.0]  # HACKING_EFFECT_TIMER[effective power] (s)
const COOLDOWN_LOCKS := 4  # LockSystem(4) after a pulse: 4 x 5 s = 20 s
const DRONE_BP := "DRONE_HACKING"


## The hacking system that drives this ship's hack: its own, or the debug virtual one.
static func system(ship: ShipState) -> SystemState:
	var s := ship.sys("hacking")
	return s if s != null else ship.hack_virtual


## Debug (main.gd --hack / Tests menu): gives a ship without a hacking system a detached one (level 3,
## power 3; not in `systems`, so it is never drawn, damaged or powered from the reactor).
static func ensure_virtual(ship: ShipState) -> SystemState:
	var s := system(ship)
	if s == null:
		s = SystemState.new("hacking", -1, 3)
		s.power = 3
		s.user_power = 3
		ship.hack_virtual = s
	return s


## The embedded HackingDrone (created on first use).
static func drone(ship: ShipState) -> Drone:
	if ship.hack_drone == null:
		var bp := FtlData.drone_blueprint(DRONE_BP)
		if bp.is_empty():
			bp = {"name": DRONE_BP, "type": "HACKING", "power": 1, "speed": 28.0, "drone_image": "drone_hack"}
		ship.hack_drone = Drone.new(bp, ship, -1)
	return ship.hack_drone


## Functioning: effective power > 0 (not destroyed, not unpowered).
static func functioning(s: SystemState) -> bool:
	return s != null and s.effective_power() > 0 and s.damage < s.get_level()


## bCanHack: a current target that exists, is alive and hostile.
static func has_target(ship: ShipState) -> bool:
	var t := ship.opponent
	return t != null and not t.is_destroyed() and t.hostile


## bBlocked: the target has super-shield layers, or (enemy) this ship is jumping.
static func blocked(ship: ShipState) -> bool:
	var t := ship.opponent
	return (t != null and t.super_shield > 0) or (not ship.is_player and ship.jumping)


## CanHack: not already hacking, the system functions, a hostile target.
static func can_hack(ship: ShipState) -> bool:
	var s := system(ship)
	return s != null and not ship.hacking and functioning(s) and has_target(ship)


## Player HackBox: the button works with drone parts > 0 and CanHack.
static func button_active(ship: ShipState) -> bool:
	return ship.drone_parts > 0 and can_hack(ship)


## HackBox click while not hacking: blocked -> "blocked" (SUPER SHIELDS PREVENT HACKING); locked (ion /
## cooldown / hacked) -> "locked"; else armed ("ok"). Clicking again disarms ("off").
static func arm(ship: ShipState) -> String:
	if ship.hack_armed:
		ship.hack_armed = false
		return "off"
	if not button_active(ship):
		return "no"
	if blocked(ship):
		return "blocked"
	if system(ship).is_power_locked():
		return "locked"
	ship.hack_armed = true
	return "ok"


## StartHacking(system): ignored while blocked or locked; clears the armed state. `sys` may be null (a
## room without a system: nothing is queued).
static func start_hacking(ship: ShipState, sys: SystemState) -> bool:
	ship.hack_armed = false
	var s := system(ship)
	if s == null or blocked(ship) or s.is_power_locked():
		return false
	if sys == null:
		return false
	ship.hack_queued = sys
	return true


## Armed + click on an enemy room (CombatControl::SelectTarget). Returns true if the click was consumed.
static func room_clicked(ship: ShipState, room: int) -> bool:
	if not ship.hack_armed or room < 0 or ship.opponent == null:
		return false
	start_hacking(ship, ship.opponent.system_in_room(room))
	return true


## Room of the current (or queued) target system.
static func target_room(ship: ShipState) -> int:
	var t := ship.hack_target if ship.hack_target != null else ship.hack_queued
	return t.room if t else -1


## CanPulse: hacking, powered, target not completely destroyed, drone attached, the system not locked
## (no ion / cooldown, not itself under a pulse).
static func can_pulse(ship: ShipState) -> bool:
	var s := system(ship)
	var t := ship.hack_target
	return s != null and ship.hacking and s.effective_power() > 0 and t != null and t.damage < t.get_level() \
		and ship.hack_drone != null and ship.hack_drone.arrived() and not s.is_power_locked()


## Pulse running (iLockCount == -1 on the hacking system while hacking).
static func pulsing(ship: ShipState) -> bool:
	var s := system(ship)
	return s != null and ship.hacking and s.ion == -1


## InitiatePulse: LockSystem(-1), effect timer restarted, sound hackStart.
static func initiate_pulse(ship: ShipState) -> bool:
	if not can_pulse(ship):
		return false
	system(ship).lock_system(-1)
	ship.hack_elapsed = 0.0
	ship.hack_duration = EFFECT_TIMER[clampi(system(ship).effective_power(), 0, 3)]
	FtlData.play("hackStart")
	Combat.log("%s hacking pulse on %s %s (%.0f s)" % [ship.blueprint.name, ship.opponent.blueprint.name,
		ship.hack_target.id, ship.hack_duration])
	return true


## Pulse progress for the UI: 1 - elapsed / duration while pulsing.
static func pulse_fraction(ship: ShipState) -> float:
	if not pulsing(ship) or ship.hack_duration <= 0.0:
		return 0.0
	return clampf(1.0 - ship.hack_elapsed / ship.hack_duration, 0.0, 1.0)


## ShipSystem::Jump on the target: level 0, not under attack.
static func _clear_target(ship: ShipState) -> void:
	if ship.hack_target != null:
		ship.hack_target.clear_hack()


## StopHacking / Jump / ShipDestroyed: target cleared, the drone removed silently, no hacking.
static func stop(ship: ShipState) -> void:
	_clear_target(ship)
	ship.hack_target = null
	ship.hack_queued = null
	ship.hack_armed = false
	ship.hacking = false
	var s := system(ship)
	if s != null and s.ion == -1:
		s.lock_system(0)
	var d := ship.hack_drone
	if d != null and d.deployed:
		d.on_undeploy()
		d.deployed = false
		d.dead = false


## HackingSystem::OnLoop (called from ShipState.tick of the hacking ship).
static func tick(ship: ShipState, seconds: float) -> void:
	var s := system(ship)
	if s == null:
		return
	if s == ship.hack_virtual and s.tick_ion(seconds):
		pass  # the virtual system is not in `systems`: its lock timer is advanced here
	ship.hack_blocked = blocked(ship)
	var d := drone(ship)
	d.powered = s.effective_power() > 0
	d.hack_level = 2 if s.hacked else 0  # Drone::SetHacked: a hacked hacking system stuns its drone
	var t := ship.opponent
	if t == null or t.is_destroyed():
		if ship.hacking or ship.hack_queued != null:
			stop(ship)
		return
	# Drone shot down (or popped by a super shield) while hacking: target cleared, part already spent.
	if d.deployed and d.dead:
		Combat.log("%s hacking drone destroyed" % ship.blueprint.name)
		_clear_target(ship)
		ship.hack_target = null
		ship.hacking = false
		d.on_undeploy()
		d.deployed = false
		d.dead = false
	# Launch the queued hack.
	if ship.hack_queued != null and functioning(s):
		_clear_target(ship)
		ship.hack_target = ship.hack_queued
		ship.hack_queued = null
		if d.deployed:
			d.on_undeploy()
		d.deployed = true
		d.on_deploy()
		ship.drone_parts = maxi(ship.drone_parts - 1, 0)  # GetSpendDrone: one part per launch
		ship.hacking = true
		FtlData.play("droneLaunch")
		Combat.log("%s launches a hacking drone at %s %s" % [ship.blueprint.name, t.blueprint.name,
			ship.hack_target.id])
	# Duration by effective power; a running pulse is rescaled proportionally.
	var dur: float = EFFECT_TIMER[clampi(s.effective_power(), 0, 3)]
	var is_pulsing := s.ion == -1
	if dur != ship.hack_duration:
		if is_pulsing and ship.hack_duration > 0.0:
			ship.hack_elapsed = ship.hack_elapsed / ship.hack_duration * dur
		ship.hack_duration = dur
	var target := ship.hack_target
	if not ship.hacking or s.effective_power() <= 0 or s.hacked or target == null:
		if is_pulsing:
			s.lock_system(COOLDOWN_LOCKS)  # aborted pulse -> 20 s cooldown
		_clear_target(ship)
		return
	if is_pulsing:
		target.under_attack = true
		target.hack_level = 2
		ship.hack_elapsed += seconds
		if ship.hack_elapsed > ship.hack_duration:
			s.lock_system(COOLDOWN_LOCKS)
	elif d.arrived():
		target.under_attack = true
		target.hack_level = 1


## ShipManager::OnLoop part (start of the hacked ship's frame): every door / room hack level reset, then
## each hacked system's level applied to its room and doors (doors system under a pulse: every door).
## Hacked doors are held closed. Also runs the SetHackingLevel transitions (entering / leaving level 2).
static func update_ship(ship: ShipState) -> void:
	for d in ship.env.doors:
		d.hacked = 0
	ship.room_hack.clear()
	for s: SystemState in ship.systems.values():
		var now := s.hacked
		if now != s.hack_prev:
			s.hack_prev = now
			_on_level_change(ship, s, now)
		var lvl := s.hack_effect()
		if lvl <= 0:
			continue
		ship.room_hack[s.room] = maxi(int(ship.room_hack.get(s.room, 0)), lvl)
		var all_doors := s.id == "doors" and lvl >= 2
		for d in ship.env.doors:
			if all_doors or d.left == s.room or d.right == s.room:
				d.hacked = maxi(int(d.hacked), lvl)
	for d in ship.env.doors:
		if d.hacked > 0 and d.forced <= 0.0:
			d.open = false


## SetHackingLevel overrides (shields, teleporter, mind) on entering / leaving an active pulse.
static func _on_level_change(ship: ShipState, s: SystemState, now_hacked: bool) -> void:
	match s.id:
		"shields":
			if now_hacked:
				# Shields::SetHackingLevel: a partial charge is drained first (bExcessChargeHack), else the
				# 2 s countdown to the first lost layer starts.
				var partial := ship.shield_charger > 0.0 and ship.shield_layers < ship.max_shield_layers()
				ship.shield_excess_hack = partial
				if not partial:
					ship.shield_charger = ShipState.SHIELD_CHARGE_TIME
			else:
				ship.shield_excess_hack = false
				ship.shield_charger = 0.0
		"teleporter":
			if now_hacked:
				s.lock_system(0)  # TeleportSystem::SetHackingLevel: cooldown cleared, charge 100 %
		"mind":
			MindRule.on_hacked(ship, now_hacked)


## Whether any system of `ship` is under an active pulse (hackLoop sound).
static func any_hacked(ship: ShipState) -> bool:
	for s: SystemState in ship.systems.values():
		if s.hacked:
			return true
	return false


# ------------------------------------------------------------ landing point (PickDestination)

## HackingDrone::PickDestination (algorithm per xftl doc/hacking): a random side; scan lines (tile rows
## for left/right, tile columns for top/bottom) across the ship from that side; each line's first room
## tile gives a landing point on its outer edge. Land on the target room directly if a line reaches it
## first (random among those), else the landing point closest to the target room's centre.
## Returns {point: Vector2 (target-local), dir: Vector2 (inward flight direction)}.
static func pick_landing(t: ShipState, room: int, rng: RandomNumberGenerator) -> Dictionary:
	var side := rng.randi() % 4  # 0 from the left, 1 right, 2 top, 3 bottom
	var b := t.rooms_bounds()
	var T := float(ShipState.T)
	var dir: Vector2 = [Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN, Vector2.UP][side]
	var cands := []  # [point, room]
	var lines := int(round((b.size.y if side < 2 else b.size.x) / T))
	var steps := int(round((b.size.x if side < 2 else b.size.y) / T))
	for li in lines:
		for k in steps:
			var idx := k if side % 2 == 0 else steps - 1 - k
			var c := Vector2.ZERO
			if side < 2:
				c = Vector2(b.position.x + (idx + 0.5) * T, b.position.y + (li + 0.5) * T)
			else:
				c = Vector2(b.position.x + (li + 0.5) * T, b.position.y + (idx + 0.5) * T)
			var r := t.room_at(c)
			if r >= 0:
				cands.append([c - dir * (T / 2.0), r])
				break
	if cands.is_empty():
		return {"point": t.shield_center, "dir": dir}
	var direct := cands.filter(func(e): return e[1] == room)
	if not direct.is_empty():
		return {"point": direct[rng.randi() % direct.size()][0], "dir": dir}
	var centre := t.room_rect(room).get_center() if room >= 0 else t.shield_center
	var best: Array = cands[0]
	for e in cands:
		if (e[0] as Vector2).distance_to(centre) < (best[0] as Vector2).distance_to(centre):
			best = e
	return {"point": best[0], "dir": dir}


# ------------------------------------------------------------ enemy AI (CombatAI::OnLoop)

## CombatAI hacking: skipped while either ship is jumping or the target is dying. Attached -> pulse as
## soon as allowed; else with drone parts, StartHacking on a uniformly random system id (rand % 16) the
## target has (re-rolled every frame until launched).
static func ai_update(ship: ShipState, rng: RandomNumberGenerator) -> void:
	var s := system(ship)
	var t := ship.opponent
	if s == null or t == null or t.is_destroyed() or ship.jumping or t.jumping:
		return
	if ship.hacking:
		initiate_pulse(ship)
		return
	if ship.drone_parts <= 0 or ship.hack_queued != null:
		return
	var id: String = SystemState.ORDER[rng.randi() % SystemState.ORDER.size()]
	if t.sys(id) != null:
		start_hacking(ship, t.sys(id))
