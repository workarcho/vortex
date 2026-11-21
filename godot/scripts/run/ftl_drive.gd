class_name FtlDrive
extends RefCounted
## FTL drive charge (rules/ftl_drive.md): ShipManager::OnLoop charges `jump_timer` (0..85) by
## EngineSystem::GetEngineSpeed × the clock factor while the ship can fly (ShipFlying: engines and piloting
## functioning, neither hacked); full when safe (ShipManager::SetSafe) or out of fuel. Pure rules; the charge is
## kept as `ShipState.ftl_charge` = jump_timer / 85 (0..1).


static func _t() -> Dictionary:
	return RunTuning.section("ftl_drive")


## ShipManager::SystemFunctions(engines) = ShipSystem::Functioning: effective power > 0 (power + zoltan bonus +
## battery; a fully damaged or unpowered engine gives 0). No hacking check (FTLButton::MouseClick / jump hotkey).
static func engines_function(ship: ShipState) -> bool:
	var e := ship.sys("engines")
	return e != null and e.effective_power() > 0


## ShipManager::SystemFunctions(piloting) = ShipSystem::Functioning's piloting case: bManned and effective power
## > 0. The autopilot (piloting level 2 / 3) only affects evasion: an empty seat never jumps. An automated
## (crewless) ship counts as manned (ShipManager::UpdateCrewmembers sets bManned = bAutomated first).
static func pilot_function(ship: ShipState) -> bool:
	var p := ship.sys("pilot")
	if p == null or p.effective_power() <= 0:
		return false
	var automated: bool = not ship.is_player and ship.blueprint.crew.is_empty()
	return automated or ship.is_manned("pilot")


## FTLButton::OnRender's engines / pilot indicators: functioning and not hack-pulsed (IsSystemHacked < 2).
## Both true = JUMP can light up and the pull-out stays hidden.
static func engines_indicator(ship: ShipState) -> bool:
	return engines_function(ship) and ship.sys("engines").hack_effect() < 2


static func pilot_indicator(ship: ShipState) -> bool:
	return pilot_function(ship) and ship.sys("pilot").hack_effect() < 2


## Engines and piloting both SystemFunctions: required to open the star map (FTLButton::MouseClick / OnTouch,
## CommandGui::KeyDown "jump" hotkey), with a full charge and an active button.
static func jump_systems_ok(ship: ShipState) -> bool:
	return engines_function(ship) and pilot_function(ship)


## ShipManager::ShipFlying: engines functioning (power > 0) and not hack-pulsed; piloting manned, powered and
## not hack-pulsed (ShipSystem::Functioning: the pilot system needs bManned).
static func ship_flying(ship: ShipState) -> bool:
	var e := ship.sys("engines")
	var p := ship.sys("pilot")
	if e == null or p == null:
		return false
	if e.hack_effect() >= 2 or p.hack_effect() >= 2:
		return false
	# ShipManager::UpdateCrewmembers starts each frame with every system's bManned = bAutomated, so an automated
	# (crewless) enemy's piloting counts as manned (auto rebels charge their FTL and escape).
	return engines_function(ship) and pilot_function(ship)


## EngineSystem::GetEngineSpeed per clock unit: ((bars − 1) × 0.35 + 1.25) × 0.0625 × (1 + FTL_BOOSTER value)
## × 3 when `boost` (ShipManager::bBoostFTL) × manning (engines skill 1/2/3 → ×1.1/1.17/1.25), capped at 1.2.
static func engine_speed(ship: ShipState, boost_ftl := false) -> float:
	var e := ship.sys("engines")
	if e == null:
		return 0.0
	var t := _t()
	var bars := e.effective_power()
	var v := (float(bars - 1) * float(t.per_bar) + float(t.base)) * float(t.scale)
	var boost := String(t.get("boost_aug", "FTL_BOOSTER"))
	if ship.has_augment(boost):
		v *= 1.0 + ship.augment_value(boost, 0.0)
	if boost_ftl:
		v *= float(t.get("boost_mult", 3.0))
	var m: Array = t.manning
	var lvl := clampi(ship.crew_level_in("engines"), 0, m.size() - 1)
	v *= float(m[lvl])
	return minf(v, float(t.cap))


## Seconds to charge from 0 with the current engines (for tests / tooltips).
static func seconds_to_full(ship: ShipState) -> float:
	var sp := engine_speed(ship) * GameClock.BASE
	return float(_t().timer_max) / sp if sp > 0.0 else INF


## One step of `seconds` real (game) seconds. `safe`: no hostile ship and no hostile environment
## (WorldManager::OnLoop → ShipManager::SetSafe: full). `boost`: no hostile ship (SetBoostFTL(true): ×3 speed,
## so a hazard / intruder beacon without an enemy still charges, three times faster). The charge only grows while
## ShipFlying; it never drains (a pilot leaving or the engines going down just freezes it).
static func tick(ship: ShipState, seconds: float, safe: bool, boost := false) -> void:
	if safe or ship.fuel <= 0:
		ship.ftl_charge = 1.0
		return
	if ship.ftl_charge >= 1.0 or not ship_flying(ship):
		return
	var timer_max := float(_t().timer_max)
	var timer := ship.ftl_charge * timer_max + engine_speed(ship, boost) * seconds * GameClock.BASE
	ship.ftl_charge = minf(timer / timer_max, 1.0)
