class_name MedbayRule
extends RefCounted
## Medbay healing (rules/medbay.md): MedbaySystem::GetHealingSpeed, CrewMember::SetMedbay/CanHeal/
## UpdateHealth and the medbay branch of ShipManager::UpdateCrewmembers.
##
## Every frame each own (non-intruder) crew member standing in the medbay room gets a heal rate:
## all of them, wherever they stand in the room, no manning bonus, also while fighting.

const HP_PER_SPEED := 6.4  # HP/s per unit of healing speed (0.4 per frame-factor x 16)
const HACKED_SPEED := -2.0  # healing speed while the medbay is actively hacked (-12.8 HP/s)


## Healing speed of a medbay running on `power` bars: 1 -> 1.0, 2 -> 1.5, 3 -> 3.0
## ((p - 1) x 1.5 above 1). Actively hacked: -2 whatever the power.
static func healing_speed(power: int, hacked: bool) -> float:
	if hacked:
		return HACKED_SPEED
	var f := float(power)
	if f > 1.0:
		f = (f - 1.0) * 1.5
	return f


static func hp_per_second(power: int, hacked: bool) -> float:
	return healing_speed(power, hacked) * HP_PER_SPEED


## CrewMember::CanHeal: hurt, or suffocating (if it can), or standing in fire, or fighting a crew
## member (not a door). Otherwise a positive rate is dropped (nothing to heal).
static func can_heal(ship: ShipState, c: CrewMember) -> bool:
	if c.hp < c.max_hp:
		return true
	if c.can_suffocate() and ship.env.oxygen.get(c.room, 100.0) <= ShipEnvironment.SUFFOCATE_BELOW:
		return true
	if ship.env.fires_in(c.room) > 0:
		return true
	return c.target != null


## Sets `medbay_rate` (HP/s, may be negative) on every crew member of the ship.
## The medbay acts when it functions (effective power > 0) or is actively hacked.
static func update(ship: ShipState) -> void:
	var m := ship.sys("medbay")
	for c in ship.crew:
		c.medbay_rate = 0.0
		if m != null and c.is_alive() and not c.is_intruder(ship) and c.room != m.room:
			# NANO_MEDBAY: every other room heals at the augment value (0.25), no power needed.
			var nano := AugmentRule.nano_speed(ship, c.room) * HP_PER_SPEED
			if nano > 0.0 and can_heal(ship, c):
				c.medbay_rate = nano * (0.2 if c.is_drone() else 1.0)
			continue
		if m == null or not c.is_alive() or c.is_intruder(ship) or c.room != m.room:
			continue
		var power := m.effective_power()
		if power <= 0 and not m.hacked:
			continue
		var rate := hp_per_second(power, m.hacked)
		if c.is_drone():
			rate *= 0.2  # crew drones heal at 0.2 x (rules/medbay.md)
		if rate < 0.0 or can_heal(ship, c):
			c.medbay_rate = rate
