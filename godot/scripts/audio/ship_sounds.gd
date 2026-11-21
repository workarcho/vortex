extends RefCounted
## The sound loops of the exe that follow a count of things going on (clean room, FTL 1.6.9; rules/crew.md
## "Crew sound loops", rules/fire_and_oxygen.md, rules/starmap.md). Pure counting helpers; main.gd feeds the loops
## every frame (update_loops).
##
## Sound loops go through FtlData.update_sound_loop (SoundControl::UpdateSoundLoop: count clamped to the sounds.xml
## count, volume x count / count max, 0 fades out over 500 ms) and are paused with the game (PauseLoops), except
## `distress`.


## ShipManager::UpdateCrewmembers (0x0049ee10), player ship only (iShipId == 0), every crew member on the ship's
## list that is alive and aboard it:
##   - repairingSounds[GetUniqueRepairing()] += 1 while RepairingSystem() (a system or a breach: currentRepair set,
##     not a fire, not an intruder, not fighting) and not stunned. GetUniqueRepairing: "repair", AnaerobicAlien
##     (Lanius) "shrikeRepair", RockAlien / CrystalAlien "" (no sound). The map always holds "repair" and
##     "shrikeRepair" (0), so both are updated (stopped) every frame.
##   - extinguish += FireFightingSoundEffect(): not stunned and RepairingFire() (on a fire, not frozen, not
##     fighting); Rock / Crystal override it to false.
##   - healing += 1 for a non-drone crew member the medbay heals (SetMedbay(rate) with rate > 0: medbay room or
##     NANO_MEDBAY).
## Returns {"repair", "shrikeRepair", "extinguish", "healing"} -> count.
static func crew_loop_counts(ship: ShipState) -> Dictionary:
	var out := {"repair": 0, "shrikeRepair": 0, "extinguish": 0, "healing": 0}
	if ship == null or not ship.is_player:
		return out
	for c in ship.crew:
		if not c.is_alive():
			continue
		if not c.is_drone() and c.medbay_rate > 0.0:
			out.healing += 1  # the medbay branch runs whatever the stun
		if c.stun > 0.0 or c.fighting:
			continue
		if c.task in [CrewMember.Task.REPAIR_SYSTEM, CrewMember.Task.BREACH] and not c.is_intruder(ship):
			var key := unique_repairing(c)
			if key != "":
				out[key] += 1
		elif c.task == CrewMember.Task.FIRE and not c.frozen and not c.race in ["rock", "crystal"]:
			out.extinguish += 1
	return out


## CrewMember::GetUniqueRepairing (vtable 0x26): "repair"; AnaerobicAlien "shrikeRepair"; Rock / Crystal "".
static func unique_repairing(c: CrewMember) -> String:
	if c.drone_kind != "":
		return "repair"
	match c.race:
		"anaerobic":
			return "shrikeRepair"
		"rock", "crystal":
			return ""
	return "repair"


## Spreader<Fire>::UpdateSpread (0x007355b0), player ship only: count = every burning tile of the ship
## (CounterRoom: Fire::Present, health > 0) -> Spreadable::UpdateSound -> UpdateSoundLoop("fire", count).
static func fire_count(ship: ShipState) -> int:
	if ship == null or not ship.is_player:
		return 0
	var n := 0
	for room in ship.fires:
		for tile in ship.fires[room]:
			if float(ship.fires[room][tile].get("health", 0.0)) > 0.0:
				n += 1
	return n


## CrewMemberFactory::OnLoop (0x0045e090): UpdateSoundLoop("brawling", n), n = every crew member of the game
## (both ships, either side; out of game only when clone-ready) in the punch animation (CrewAnimation status 1)
## and not dead.
static func brawl_count(ships: Array) -> int:
	var n := 0
	for s in ships:
		if s == null:
			continue
		for c in (s as ShipState).crew:
			if c.is_alive() and c.punch_time >= 0.0:
				n += 1
	return n


## StarMap::OnLoop (0x005d13a0, only while the map is open): UpdateSoundLoop("distress", outOfFuel (fuel < 1) and
## the DISTRESS toggle on ? 1 : 0); StarMap::Close / SetOpen(false) set it to 0. Not paused by the menu pause.
static func distress_count(run: RunState) -> int:
	if run == null or not run.map_open:
		return 0
	return 1 if run.ship.fuel < 1 and run.distress else 0


## Every frame from main.gd: PauseLoops, then the crew / fire / brawl loops while the game runs (their OnLoops do
## not run while paused: the counts freeze and the channels are paused). A destroyed player ship stops them.
## (distress is fed separately by main.gd with distress_count, every frame.)
static func update_loops(player: ShipState, ships: Array, paused: bool) -> void:
	FtlData.pause_loops(paused)
	if paused:
		return
	var alive := player != null and not player.is_destroyed()
	var counts := crew_loop_counts(player) if alive else {}
	for key in ["extinguish", "healing", "repair", "shrikeRepair"]:
		FtlData.update_sound_loop(key, counts.get(key, 0))
	FtlData.update_sound_loop("fire", fire_count(player) if alive else 0)
	FtlData.update_sound_loop("brawling", brawl_count(ships))


const LOOPS := ["extinguish", "healing", "repair", "shrikeRepair", "fire", "brawling", "distress"]


## The game scene goes away: every loop above stops at once.
static func stop_loops() -> void:
	for n in LOOPS:
		FtlData.stop_sound_loop(n)
