class_name UpgradeSession
extends RefCounted
## The Upgrades tab (rules/ship_management.md §4): temporary levels per system and for the reactor, bought with
## scrap taken at once (Upgrades / UpgradeBox / ReactorButton). Right click refunds the last temporary level,
## Undo refunds them all, `commit` (Upgrades::Close: Accept, Esc or a tab switch) applies them to the ship.
## Pure rules; costs from the system blueprint `<upgradeCost>` levels (later data files win).

## Upgrades::systemOrder (first entry [inferred] shields); our ids (pilot = piloting).
const ORDER := ["shields", "engines", "medbay", "clonebay", "oxygen", "weapons", "drones", "pilot", "sensors", "doors",
	"teleporter", "cloaking", "artillery", "battery", "mind", "hacking"]
const SUBSYSTEMS := ["pilot", "sensors", "doors", "battery"]
const BOXES := 12  # top + bottom row boxes in total
const REACTOR_MAX := 25

var temp := {}  # system id -> temporary levels bought this session
var reactor_temp := 0
static var _info_cache := {}


## {costs: [int], max: int, title, desc} of a system blueprint.
static func system_info(id: String) -> Dictionary:
	if _info_cache.has(id):
		return _info_cache[id]
	var out := {"costs": [], "max": 0, "title": FtlData.blueprint_title(id, "system"), "desc": "", "start": 1}
	for file in ["data/blueprints.xml", "data/dlcBlueprints.xml", "data/dlcBlueprintsOverwrite.xml"]:
		var src := FtlData.strip_comments(FtlData.text(file))
		var m := RegEx.create_from_string("<systemBlueprint\\s+name=\"" + id +
			"\"[^>]*>([\\s\\S]*?)</systemBlueprint>").search(src)
		if m == null:
			continue
		var b := m.get_string(1)
		var costs := []
		for lm in RegEx.create_from_string("<level>\\s*(\\d+)\\s*</level>").search_all(
				FtlData.tag_value(b, "upgradeCost")):
			costs.append(int(lm.get_string(1)))
		var info := FtlData.item_info("system", id)
		out = {"costs": costs, "max": int(FtlData.tag_value(b, "maxPower")),
			"title": FtlData.blueprint_title(id, "system"), "desc": info.get("desc", ""),
			"start": int(FtlData.tag_value(b, "startPower"))}
	_info_cache[id] = out
	return out


## ShipSystem maxLevel: the ship blueprint's `max=` when given, else the system blueprint's maxPower.
static func max_level(ship: ShipState, id: String) -> int:
	var text := FtlData.ship_blueprint_text(String(ship.blueprint.get("name", "")))
	var m := RegEx.create_from_string("<" + id + "\\s[^>]*\\bmax=\"(\\d+)\"").search(text)
	if m:
		return int(m.get_string(1))
	return int(system_info(id).max)


## The boxes of the tab in order: [{id, top: bool}] for installed systems (top row = needs power), then "" ids
## for placeholders (one bottom placeholder per missing subsystem, top placeholders up to 12 boxes).
static func layout(ship: ShipState) -> Array:
	var top := []
	var bottom := []
	for id in ORDER:
		var installed := ship.sys(id) != null
		if id in SUBSYSTEMS:
			bottom.append({"id": id if installed else "", "top": false})
		elif installed:
			top.append({"id": id, "top": true})
	while top.size() + bottom.size() < BOXES:
		top.append({"id": "", "top": true})
	return top + bottom


func level_of(ship: ShipState, id: String) -> int:
	var s := ship.sys(id)
	return (s.level if s else 0) + int(temp.get(id, 0))


## Cost of the next level: upgradeCosts[current + temp − 1]; −1 when maxed / not installed.
func cost_next(ship: ShipState, id: String) -> int:
	var s := ship.sys(id)
	if s == null:
		return -1
	var n := s.level + int(temp.get(id, 0))
	if n >= max_level(ship, id):
		return -1
	var costs: Array = system_info(id).costs
	if n - 1 < 0 or n - 1 >= costs.size():
		return -1
	return int(costs[n - 1])


## ReactorButton::GetReactorCost: 30 up to 4 bars, then floor(n / 5)·5 + 15.
static func reactor_cost(n: int) -> int:
	return 30 if n <= 4 else n / 5 * 5 + 15


func reactor_level(ship: ShipState) -> int:
	return ship.reactor_max + reactor_temp


func reactor_cost_next(ship: ShipState) -> int:
	var n := reactor_level(ship)
	return reactor_cost(n) if n < REACTOR_MAX else -1


## Left click / tap: "ok", "max" or "scrap" (not enough: nothing changes).
func buy(ship: ShipState, id: String) -> String:
	var c := reactor_cost_next(ship) if id == "reactor" else cost_next(ship, id)
	if c < 0:
		return "max"
	if ship.scrap < c:
		return "scrap"
	ship.scrap -= c
	if id == "reactor":
		reactor_temp += 1
	else:
		temp[id] = int(temp.get(id, 0)) + 1
	return "ok"


## Right click: refund the last temporary level (the same cost one level down). Returns the scrap refunded.
func refund(ship: ShipState, id: String) -> int:
	if id == "reactor":
		if reactor_temp <= 0:
			return 0
		reactor_temp -= 1
		var c := reactor_cost(reactor_level(ship))
		ship.scrap += c
		return c
	if int(temp.get(id, 0)) <= 0:
		return 0
	temp[id] = int(temp[id]) - 1
	var s := ship.sys(id)
	var costs: Array = system_info(id).costs
	var idx := s.level + int(temp[id]) - 1
	var c2 := int(costs[idx]) if idx >= 0 and idx < costs.size() else 0
	ship.scrap += c2
	if int(temp[id]) == 0:
		temp.erase(id)
	return c2


## Undo button: every temporary level of every box and the reactor.
func undo_all(ship: ShipState) -> int:
	var total := 0
	while reactor_temp > 0:
		total += refund(ship, "reactor")
	for id in temp.keys():
		while int(temp.get(id, 0)) > 0:
			total += refund(ship, id)
	return total


func has_pending() -> bool:
	return reactor_temp > 0 or not temp.is_empty()


## Upgrades::Close: apply the temporary levels (ShipSystem::UpgradeSystem, reactor currentPower.second += temp).
## Returns the achievement flags set (system_upgrade / weapon_upgrade / reactor_upgrade).
func commit(ship: ShipState) -> Array:
	var flags := []
	for id in temp:
		var s := ship.sys(id)
		if s and int(temp[id]) > 0:
			s.level += int(temp[id])
			if not "system_upgrade" in flags:
				flags.append("system_upgrade")
			if id == "weapons" and not "weapon_upgrade" in flags:
				flags.append("weapon_upgrade")
	if reactor_temp > 0:
		ship.reactor_max += reactor_temp
		flags.append("reactor_upgrade")
	temp.clear()
	reactor_temp = 0
	if not flags.is_empty():
		ship._check_reactor()
	return flags
