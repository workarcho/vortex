class_name EvasionRule
extends RefCounted
## Evasion rule. Implemented from rules/evasion.md (not from the decompiled code).

enum Skill { PILOT, ENGINES, SHIELDS, WEAPONS, REPAIR, COMBAT }

## Evasion (%) per effective engines level 1..8.
const ENGINE_TABLE := [5, 10, 15, 20, 25, 28, 31, 35]
const CLOAK_BONUS := 60


## Skill bonus. level: 0 = nobody, 1..3 = crew member's level.
static func skill_bonus(skill: int, level: int) -> float:
	match skill:
		Skill.PILOT, Skill.ENGINES:
			return [0.0, 5.0, 7.0, 10.0][clampi(level, 0, 3)]
		Skill.SHIELDS:
			return [1.0, 1.1, 1.2, 1.3][clampi(level, 0, 3)]
		Skill.WEAPONS:
			return [1.0, 0.9, 0.85, 0.8][clampi(level, 0, 3)]
		Skill.REPAIR, Skill.COMBAT:
			return [1.0, 1.0, 1.1, 1.2][clampi(level, 0, 3)]
	return 0.0


## Evasion provided by the engines (includes the engines crew member's bonus).
static func engine_dodge(engine_power: int, engine_crew: int) -> int:
	var base := 0
	if engine_power >= 1 and engine_power <= 8:
		base = ENGINE_TABLE[engine_power - 1]
	return base + int(skill_bonus(Skill.ENGINES, engine_crew))


## Total ship evasion.
## pilot_crew / engine_crew: manning bonus level (0 = no bonus, 1..3 = skill level).
## piloting_power: piloting system power (for autopilot).
## piloted: someone is in the piloting room (presence, not bonus); null = same as pilot_crew > 0.
static func dodge_factor(engine_power: int, engine_crew: int, pilot_crew: int,
		piloting_power: int, cloaked := false, piloted: Variant = null) -> int:
	var result := 0
	var engines_on := engine_power > 0
	var has_pilot: bool = pilot_crew > 0 if piloted == null else piloted
	if engines_on and piloting_power > 0:
		var raw := float(engine_dodge(engine_power, engine_crew)) + skill_bonus(Skill.PILOT, pilot_crew)
		if has_pilot:
			result = int(raw)
		elif piloting_power == 2:
			result = int(raw * 0.5)
		elif piloting_power >= 3:
			result = int(raw * 0.8)
	if cloaked:
		result += CLOAK_BONUS
	return result


## Per-projectile roll: dodges if an integer in [0, 99] is less than the evasion.
static func roll_dodge(dodge: int, rng: RandomNumberGenerator) -> bool:
	if dodge <= 0:
		return false
	return rng.randi() % 100 < dodge
