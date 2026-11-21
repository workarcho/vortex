class_name Damage
extends RefCounted
## Damage of a hit (FTL's Damage struct). See rules/damage.md.

var damage := 0  # hull (+ system + crew)
var sys_damage := 0  # system only
var pers_damage := 0  # crew only (negative heals)
var ion := 0
var hull_bust := false  # x2 hull damage in rooms without a system
var fire_chance := 0  # tenths (0..10)
var breach_chance := 0
var stun_chance := 0
var stun := 0.0
var lockdown := false
var shield_piercing := 0
var owner := -1  # ownerId: 0 = player, 1 = enemy, -1 = none (tests / debug hits: no owner rules)
var friendly_fire := true  # bFriendlyFire: true for every weapon blueprint (WeaponBlueprint constructor)


static func from_weapon(bp: Dictionary) -> Damage:
	var d := Damage.new()
	d.damage = int(bp.get("damage", 0))
	d.sys_damage = int(bp.get("sys_damage", 0))
	d.pers_damage = int(bp.get("pers_damage", 0))
	d.ion = int(bp.get("ion", 0))
	d.hull_bust = int(bp.get("hull_bust", 0)) > 0
	d.fire_chance = int(bp.get("fire_chance", 0))
	d.breach_chance = int(bp.get("breach_chance", 0))
	d.stun_chance = int(bp.get("stun_chance", 0))
	d.stun = float(bp.get("stun", 0.0))
	d.lockdown = bool(bp.get("lockdown", false))
	d.shield_piercing = int(bp.get("sp", 0))
	return d


## ShipManager::DamageCrew owner rules: crew of the owner's side is skipped only without friendly
## fire (never the case for weapons); a heal (negative total) only reaches crew of the owner's side.
## Returns the HP change to apply (positive = damage); 0.0 = unaffected.
func crew_hp_change(crew_player_owned: bool) -> float:
	var same_side := owner >= 0 and (owner == 0) == crew_player_owned
	if same_side and not friendly_fire:
		return 0.0
	var hp := crew_hp_damage()
	if hp < 0 and owner >= 0 and not same_side:
		return 0.0
	return float(hp)


## Damage to each crew member in the room, in hit points (negative = heal).
func crew_hp_damage() -> int:
	return (maxi(damage, 0) + pers_damage) * 15


## Damage to the room's system, in bars.
func system_damage() -> int:
	return sys_damage + maxi(damage, 0)


func copy() -> Damage:
	var d := Damage.new()
	for p in ["damage", "sys_damage", "pers_damage", "ion", "hull_bust", "fire_chance", "breach_chance",
			"stun_chance", "stun", "lockdown", "shield_piercing", "owner", "friendly_fire"]:
		d.set(p, get(p))
	return d
