class_name CrewRoster
extends RefCounted
## The Crew tab rules (rules/ship_management.md §5, CrewManifest): the player's crew in list order (9 boxes),
## rename (max 15 characters, CrewMember::SetName), dismiss (only with more than one crew; Kill(true): gone, no
## clone) and the over-capacity lock (a 9th crew member). Names come from the crew-identity work
## (`CrewMember.set_name` / `name` / `name_long`, rules/crew_appearance.md); the helpers below fall back to the
## race title while those fields do not exist.

const BOXES := 9
const MAX_CREW := 8
const NAME_MAX := 15


## Crew shown in the manifest, in crew-list order (player-owned, alive, no crew drones, not boarding elsewhere).
static func members(ship: ShipState) -> Array:
	return ship.own_crew()


static func is_over_capacity(ship: ShipState) -> bool:
	return members(ship).size() > MAX_CREW


static func can_dismiss(ship: ShipState) -> bool:
	return members(ship).size() > 1


## Short display name (GetName), else the race title.
static func display_name(c: CrewMember) -> String:
	for prop in ["name", "name_short", "crew_name"]:
		if prop in c and String(c.get(prop)) != "":
			return String(c.get(prop))
	if c.has_meta("crew_name"):
		return String(c.get_meta("crew_name"))
	return race_title(c.race)


## Long name (GetLongName), else the display name.
static func long_name(c: CrewMember) -> String:
	if "name_long" in c and String(c.get("name_long")) != "":
		return String(c.get("name_long"))
	return display_name(c)


static func race_title(race: String) -> String:
	var t := FtlData.tr_id("crew_%s_title" % race) if FtlData else race
	return t if t != "crew_%s_title" % race else race.capitalize()


## CrewMember::SetName(text, false) from the rename box: trimmed to 15 characters; empty text keeps the name.
static func rename(c: CrewMember, text: String) -> bool:
	var t := text.strip_edges().substr(0, NAME_MAX)
	if t == "" or c == null:
		return false
	if c.has_method("set_name"):
		c.call("set_name", t)
	elif "name" in c:
		c.set("name", t)
	else:
		c.set_meta("crew_name", t)  # TODO(crew identity): CrewMember names not available yet
	return true


## Dismiss (ConfirmWindow yes → CrewMember::Kill(true)): removed for good, never cloned.
static func dismiss(ship: ShipState, c: CrewMember) -> bool:
	if c == null or not c in members(ship) or not can_dismiss(ship):
		return false
	c.hp = 0.0
	ship.crew.erase(c)
	ship.clone_queue.erase(c)
	ship.crew_changed()
	return true
