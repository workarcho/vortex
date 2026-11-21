class_name SystemState
extends RefCounted
## A ship system: level, assigned power, damage and ion (rules/power.md).
## Reactor allocation is done by ShipState; only the system's own state lives here.

const ION_SECONDS := 5.0
const ION_MAX := 5
const SUBSYSTEMS := ["pilot", "sensors", "doors", "battery"]
## FTL's id order (for initial power-up and for listing).
const ORDER := ["shields", "engines", "oxygen", "weapons", "drones", "medbay", "pilot", "sensors",
	"doors", "teleporter", "cloaking", "artillery", "battery", "clonebay", "mind", "hacking"]

var id := ""
var room := -1
var level := 0  # purchased bars
var damage := 0  # broken bars
var power := 0  # bars assigned (reactor + battery; weapons: sum of powered weapons)
var battery := 0  # how many of `power` come from the backup battery (always the top bars)
var user_power := 0  # what the player had set (to re-power after ion)
var power_loss := 0  # bars lost to events (from the top)
# Hacking (rules/hacking.md): iHackEffect (0 none, 1 passive = drone attached, 2 pulse) and bUnderAttack.
var hack_level := 0
var under_attack := false
var hack_prev := false  # `hacked` seen last frame (SetHackingLevel transitions, HackingRule.update_ship)
## Actively hacked = IsSystemHacked >= 2 (pulse running). Setting it (tests, old debug paths) sets both
## the level (2 / 0) and bUnderAttack; the hacking system sets them through HackingRule.
var hacked: bool:
	get:
		return under_attack and hack_level >= 2
	set(v):
		hack_level = 2 if v else 0
		under_attack = v
var ion := 0  # lock counter iLockCount: ion charges / cooldown units (5 s each); -1 = indefinite lock
var ion_timer := 0.0
# Systems with an on/off state and a timer (battery, cloaking, clonebay progress; rules/battery.md,
# rules/cloaking.md, rules/clonebay.md).
var turned_on := false
var timer := 0.0  # elapsed seconds (TimerHelper currTime)
var timer_goal := 0.0  # seconds (TimerHelper maxTime)
var sound_effect := ""  # CloakingSystem::soundeffect: set by SetTurnedOn, played by the next OnLoop (rules/pause.md)
var lock_total := 0.0  # s of the last lock set (UI cooldown bars only)
## Partial repair / damage (ShipSystem fRepairOverTime / fDamageOverTime, 0..100 of a bar; rules/crew.md, damage.md).
## damage_progress is shared by fire and intruder sabotage. ShipSystem::OnLoop (`loop_progress`) resets
## damage_progress on a frame without damage while no intruder is in the room (bOccupied) and repair_progress on
## a frame without repair while no friendly crew is in the room (bFriendlies).
var repair_progress := 0.0
var damage_progress := 0.0
var damaged_last_frame := false
var repaired_last_frame := false
## bExploded: damage over time (fire / sabotage) just broke the last working bar; ShipState._check_exploded turns
## it into 1 hull damage (ShipSystem::DamageOverTime / GetExploded, rules/damage.md "System explosion").
var exploded := false
var occupied := false  # bOccupied: a live intruder (GetIntruder) in the system's room
var friendlies := false  # bFriendlies: a live non-intruder crew member / drone in the room
var override_level := -1  # tests
var manning_boost := 0  # +1 while a level-boostable system (sensors, doors) is manned and intact
var ion_stunned := false  # the lock comes from ion damage (not a cooldown): floor sparks (rules/ship_rendering.md §7)
## Zoltan bonus power (iBonusPower, rules/races.md "Zoltan"): set every frame by ShipState.update_bonus_power;
## counts in the effective power and the usable maximum; drawn yellow above the reactor / battery bars.
var bonus_power := 0
var last_bonus_power := 0


func _init(sys_id: String, room_id: int, lvl: int) -> void:
	id = sys_id
	room = room_id
	level = lvl


## ShipSystem::DamageOverTime(amount): progress += amount; at 100 it resets and true is returned (the caller breaks
## one bar). Marks the frame as damaged either way.
func damage_over_time(amount: float) -> bool:
	damaged_last_frame = true
	damage_progress += amount
	if damage_progress >= 100.0:
		damage_progress = 0.0
		return true
	return false


## ShipSystem::PartialRepair(amount already scaled): only while damaged; at 100 it resets and true is returned
## (the caller restores one bar). Marks the frame as repaired.
func partial_repair(amount: float) -> bool:
	if damage <= 0:
		return false
	repaired_last_frame = true
	repair_progress += amount
	if repair_progress >= 100.0:
		repair_progress = 0.0
		return true
	return false


## ShipSystem::OnLoop progress part (after ShipManager set bOccupied / bFriendlies from the crew counts).
func loop_progress() -> void:
	if not damaged_last_frame and not occupied:
		damage_progress = 0.0
	if not repaired_last_frame and not friendlies:
		repair_progress = 0.0
	damaged_last_frame = false
	repaired_last_frame = false


## Sabotage icon (RenderPowerBoxes): intruders in the room, damage in progress, not completely destroyed.
func sabotaged() -> bool:
	return occupied and damage_progress != 0.0 and damage < get_level()


func is_subsystem() -> bool:
	return SUBSYSTEMS.has(id)


func uses_reactor() -> bool:
	return not is_subsystem()


func get_level() -> int:
	return override_level if override_level >= 0 else level


## Usable maximum = level - damage - event loss.
func max_power() -> int:
	return maxi(get_level() - damage - power_loss, 0)


## Visual state of bar i (0 = bottom), per ShipSystem::RenderPowerBoxes.
## "on", "ion", "hack", "free", "lost" (light-blue X), "broken" (red X)
func bar_state(i: int) -> String:
	var lvl := get_level()
	var usable := lvl - damage
	if i < effective_power():
		if bonus_power > 0 and i >= power and i < power + bonus_power and not is_subsystem():
			return "bonus"  # zoltan bars sit above the reactor and battery bars, always yellow
		if hacked:
			return "hack"
		if is_ionized():
			return "ion"
		if i >= power - battery and battery > 0:
			return "battery"
		return "on"
	if i >= usable:
		return "broken"
	if i >= lvl - power_loss:
		return "lost"
	return "free"


const SYMBOL_FLASH_PERIOD := 0.75  # s, flash tracker loop
const SYMBOL_FLASH_THRESHOLD := 0.5


## Symbol color per ShipSystem::RenderSystemSymbol (rules/power.md "System symbol"):
## "green", "grey", "orange", "red" or "blue". `time` drives the ion/hack flash.
func symbol_color(time: float) -> String:
	if is_ionized() or hacked:
		var alpha := 1.0 - fmod(time, SYMBOL_FLASH_PERIOD) / SYMBOL_FLASH_PERIOD
		if alpha > SYMBOL_FLASH_THRESHOLD:
			return "blue"
	if damage >= get_level():
		return "red"
	if damage > 0:
		return "orange"
	return "grey" if effective_power() == 0 else "green"


## Tint of the in-room symbol per ShipSystem::OnRender (rules/power.md "System symbol in the room").
func room_symbol_tint(time: float) -> Color:
	if is_ionized() or hacked:
		var alpha := 1.0 - fmod(time, SYMBOL_FLASH_PERIOD) / SYMBOL_FLASH_PERIOD
		if alpha > SYMBOL_FLASH_THRESHOLD:
			return Color8(133, 231, 237)  # COLOR_BLUE_ION
	if damage >= get_level():
		return Color8(255, 0, 0)  # COLOR_RED_PLAIN
	if damage > 0:
		return Color8(255, 153, 76)  # COLOR_ORANGE
	return Color8(125, 125, 125)  # COLOR_GRAY


## Power-UI icon texture (RenderSystemSymbol; n = 1 normal, 2 selected).
func symbol_texture(time: float, n := 1) -> Texture2D:
	var c := symbol_color(time)
	return FtlData.first_texture(["img/icons/s_%s_%s%d.png" % [id, c, n],
		"img/icons/s_%s_%s1.png" % [id, c]])


## Power the system runs with (subsystems: their maximum).
func effective_power() -> int:
	return (max_power() if is_subsystem() else power + bonus_power) + manning_boost


## IsSystemHacked: the hack level while under attack, else 0.
func hack_effect() -> int:
	return hack_level if under_attack and hack_level > 0 else 0


## ShipSystem::Jump on a hacked target: level 0, not under attack.
func clear_hack() -> void:
	hack_level = 0
	under_attack = false


## GetLocked: lock counter, or an active hack pulse (power cannot be changed).
func is_power_locked() -> bool:
	return ion != 0 or hacked


## GetLocked without the hacking part: lock counter > 0 (ion / cooldown) or indefinite (-1).
func is_locked() -> bool:
	return ion != 0


## Lock counter > 0 (ion damage or a cooldown lock): blue bars and frame (RenderPowerBoxes).
func is_ionized() -> bool:
	return ion > 0


## ShipSystem::LockSystem(n): sets the counter (does not add) and restarts the 5 s unit timer.
func lock_system(n: int) -> void:
	ion_stunned = false
	ion = n
	ion_timer = 0.0
	lock_total = maxi(ion, 0) * ION_SECONDS


## ShipSystem::AddLock(n): from -1 or 0 the counter becomes n, else min(count + n, 5); timer restarted.
func add_lock(n: int) -> void:
	ion_stunned = false
	if ion <= 0:
		ion = n
	else:
		ion = mini(ion + n, ION_MAX)
	ion_timer = 0.0
	lock_total = maxi(ion, 0) * ION_SECONDS


## Seconds left on a positive lock (0 when unlocked or locked indefinitely).
func lock_remaining() -> float:
	if ion <= 0:
		return 0.0
	return (ion - 1) * ION_SECONDS + (ION_SECONDS - ion_timer)


## Advances the ion timer. Returns true if it unlocked in this step.
func tick_ion(seconds: float) -> bool:
	if ion <= 0:
		return false
	ion_timer += seconds
	if ion_timer >= ION_SECONDS:
		ion_timer -= ION_SECONDS
		ion -= 1
		return ion == 0
	return false


func add_ion(amount: int) -> void:
	ion_stunned = true
	if ion <= 0:
		ion = amount
		ion_timer = 0.0
	else:
		ion = mini(ion + amount, ION_MAX)
