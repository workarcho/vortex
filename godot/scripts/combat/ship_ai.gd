class_name ShipAI
extends RefCounted
## Enemy ship AI: power re-allocation every frame + weapon firing and targeting
## (rules/combat_ai.md: ShipAI::OnLoop / CheckPowerLevels, CombatAI::UpdateWeapons / PrioritizeSystem).
## One instance per enemy ship, ticked by Combat right after the ship's simulation step.
##
## Also: battery switched on every frame, cloak as soon as it is ready (50 % "fire while cloaked" roll),
## hold fire vs a cloaked target, boarding (boardingAI requests, GetTeleportCommand, evacuation).
## Drones: powered in the round-robin (DroneSystem::ForceIncreasePower, rules/drones.md §11).
## Hacking (HackingRule.ai_update) and mind control (MindRule.ai_update) per rules/hacking.md and
## rules/mind_control.md. Not modelled yet (no-ops): events (surrender/escape events, jump).
## See "Implementation notes" in rules/combat_ai.md.

enum Difficulty { EASY, NORMAL, HARD }

## Settings.difficulty (global, like the game's settings). Set by main.gd --difficulty=.
static var difficulty: int = Difficulty.NORMAL

## CombatAI::system_targets (easy/normal bias), fixed in the constructor.
const SYSTEM_TARGETS := ["shields", "engines", "weapons", "oxygen", "drones"]
const SYSTEM_BIAS_EASY := 20  # % chance to aim at a SYSTEM_TARGETS system
const SYSTEM_BIAS_NORMAL := 33
const HARD_KEY_CHANCE := 25  # r < 25: random key target
const HARD_SYSTEM_CHANCE := 50  # r < 50: random installed system
const HARD_DODGE_MIN := 26  # target dodge % for engines / piloting to be key targets
const HARD_OXYGEN_MAX := 50.0  # target oxygen % below which oxygen is a key target
const HURT_ALWAYS := 0.25  # crew below this health fraction -> power the medbay
const HURT_CALM := 0.99  # ... or below this one while the ship is calm
const ESCAPE_TIMER_DEFAULT := 15.0

var ship: ShipState
var target: ShipState = null  # ship it fights (the player)
var rng: RandomNumberGenerator
var hostile := true

# Escape / surrender / stalemate state (section 4). Only the constructor defaults and the escape
# countdown are implemented; triggering needs events and jumping (TODO).
var surrender_threshold := 0
var escape_threshold := 0
var escape_timer := ESCAPE_TIMER_DEFAULT
var escaping := false
var surrendered := false
var jump_requested := false  # escape timer ran out (no jump implemented yet)
var stalemate_timer := 0.0
var broken_systems := 0  # systems with every bar destroyed (counted in the fill step; for evacuation)

var charge_goals := {}  # WeaponState -> goal charge level (SelectChargeGoal)

# Cloaking (section 6) and boarding (section 5, rules/teleporter.md).
var firing_while_cloaked := false  # bFiringWhileCloaked, rolled 50 % on each cloak activation
var crew_ai: CrewAI = null  # this ship's crew AI (set by Combat)
var boarding_ai := 0  # blueprint <boardingAI>: 0 none, 1 sabotage, 2 invasion
var crew_needed := 0  # iCrewNeeded: crew that stay home
var times_teleported := 0  # iTimesTeleported
var teleport_request := 0  # iTeleportRequest (> 0 board with n crew, < 0 evacuate)
var teleport_target := -1  # iTeleportTarget: room of the opponent to retrieve from
const BOARD_HEALTH_LIMIT := [0.0, 0.25, -100.0]  # BoardingGoal fHealthLimit by boarding AI type
const MAX_BOARDINGS := 2

# Power plan built every frame (see check_power_levels).
var _plan := {}  # system id -> bars (reactor systems except weapons)
var _bplan := {}  # system id -> how many of those bars come from the battery
var _wplan: Array[bool] = []  # weapon slot -> powered
var _wbat := 0  # weapon bars taken from the battery
var _dplan: Array[bool] = []  # drone slot -> powered
var _dbat := 0  # drone bars taken from the battery
var _dparts := 0  # drone parts left in the plan (an undeployed drone costs one)


func _init(s: ShipState, random: RandomNumberGenerator) -> void:
	ship = s
	rng = random
	# ShipAI constructor defaults (event ships override them in WorldManager::CreateShip; no events yet).
	surrender_threshold = rng.randi() % 5 + 1
	escape_threshold = rng.randi() % 5 + 1
	if escape_threshold == surrender_threshold:
		escape_threshold -= 1
	# boardingAI (BlueprintManager::ProcessShipBlueprint: "sabotage" 1, "invasion" 2).
	var bai := FtlData.tag_value(FtlData.ship_blueprint_text(ship.blueprint.name), "boardingAI").strip_edges()
	boarding_ai = 1 if bai == "sabotage" else (2 if bai == "invasion" else 0)
	var n: int = ship.blueprint.get("crew", []).size()
	crew_needed = n - [0, n / 2, (3 * n) / 4][boarding_ai]
	# CrewAI::OnInit (0x6017d0): with boardingAI != 0, every crew member aboard (GetCrewList) gets
	# BoardingGoal(boardingAI); with 0 they keep the CrewMember default (fHealthLimit 0.25).
	if boarding_ai != 0:
		for c in ship.crew:
			c.boarding_health_limit = BOARD_HEALTH_LIMIT[boarding_ai]


## ShipAI::OnLoop, after the ship's own simulation step. `seconds` = game seconds of this frame.
func tick(seconds: float) -> void:
	if not hostile or ship.hull <= 0:
		_stand_down()
		SuperShieldRule.drain(ship)  # DrainSuperShields: a neutral / surrendered Zoltan shows 0
		return
	# TODO stalemate bookkeeping (needs events).
	if ship.sys("battery"):
		BatteryRule.turn_on(ship)  # every frame: fires as soon as it is ready
	update_boarding()
	check_power_levels()
	update_weapons()
	update_cloak()
	HackingRule.ai_update(ship, rng)  # CombatAI::OnLoop: hacking after cloaking (rules/hacking.md)
	_update_escape(seconds)
	MindRule.ai_update(ship, true)  # UpdateMindControl(true) at the end of ShipAI::OnLoop


# ------------------------------------------------------------ cloaking (CombatAI::OnLoop)

## Cloak as soon as it can (no reaction to incoming fire); each activation rolls bFiringWhileCloaked.
func update_cloak() -> void:
	if CloakRule.ready(ship) and CloakRule.turn_on(ship):
		firing_while_cloaked = rng.randi() % 2 == 0


# ------------------------------------------------------------ boarding (section 5)

## Boarding request bookkeeping (ShipAI::OnLoop): while it has boarded fewer than 2 times, request
## max(0, crew aboard - iCrewNeeded); evacuation request from `evac_room` (WorldManager::OnLoop:
## SetEvacRequest(other ship's CrewAI::ReadyForEvac(RequiredEvac()))). Passed to the crew AI (no Zoltan
## super shields are modelled).
func update_boarding() -> void:
	if ship.sys("teleporter") == null:
		return
	if times_teleported < MAX_BOARDINGS and teleport_request >= 0:
		teleport_request = maxi(0, ship.own_crew().size() - crew_needed)
	if target != null:
		var room := evac_room(target, required_evac())
		if room != -1:
			teleport_request = -1
			teleport_target = room
	if crew_ai:
		crew_ai.set_teleport_request(teleport_request)


## CrewAI::ReadyForEvac(force) (0x601ab0) of the ship `on` (the player's CrewAI, whose list is every crew
## member aboard the player ship, in crew-list order): the room of the first non-drone intruder there whose
## HP fraction is <= its own boardingGoal.fHealthLimit (`boarding_health_limit`), or of the first intruder at
## all when `force`; -1 if none. It does not ask which ship sent the intruder: every intruder is enemy-side
## crew (iShipId 1), so event boarders (BoardingGoal(2), limit -100: never by health) and the boarders of an
## earlier ship are retrieved only by a forced evacuation (RequiredEvac) of the current ship. Dead intruders
## still in their death animation are not skipped (their HP fraction 0 is <= a 0.25 limit).
static func evac_room(on: ShipState, force: bool) -> int:
	for c in on.crew:
		if c.is_drone() or not c.is_intruder(on):
			continue
		if force or c.hp / c.max_hp <= c.boarding_health_limit:
			return c.room
	return -1


## RequiredEvac: boardingAI 1 and (escaping with < 15 s left, or > 2 destroyed systems), or surrendered.
func required_evac() -> bool:
	if ship.hull <= 0:
		return false
	if boarding_ai == 1 and ((escaping and escape_timer < 15.0) or broken_systems > 2):
		return true
	var tp := ship.sys("teleporter")
	if tp and tp.hacked:
		return true  # own teleporter hacked under attack: forced retrieve (rules/hacking.md)
	return surrendered


## ShipAI::GetTeleportCommand (run by Combat before tick): {room, mode} or {}.
## Send (to a random room, -1) when the request is positive, the crew AI has enough crew on the pad and
## the teleporter can send; retrieve from iTeleportTarget when evacuating.
func get_teleport_command() -> Dictionary:
	if ship.sys("teleporter") == null or target == null or target.is_cloaked() or not hostile \
			or ship.hull <= 0:
		return {}
	if teleport_request > 0 and crew_ai != null and crew_ai.ready_for_teleport() \
			and TeleporterRule.can_send(ship, target):
		teleport_request -= TeleporterRule.prepared_crew(ship)
		if teleport_request <= 0:
			teleport_request = 0
			times_teleported += 1
		return {"room": -1, "mode": TeleporterRule.SEND}
	if teleport_request < 0 and TeleporterRule.can_receive(ship, target, true):
		teleport_request = 0
		return {"room": teleport_target, "mode": TeleporterRule.RETRIEVE}
	return {}


# ------------------------------------------------------------ power (CheckPowerLevels)

## Rebuild the whole power allocation (section 2). The steps (shutdown, then increases) run on a
## side-effect-free plan; only the net result is written to the ship at the end. In the exe the
## shutdown + re-power is harmless because SetPowered only flips a flag; here a real depower would
## clear weapon targets and clamp shield layers (ShipState._clamp_shields), so a shield that ends
## the frame with the same power would lose its charged layers. Planning first avoids that.
func check_power_levels() -> void:
	_shutdown_plan()
	_inc("oxygen")
	_inc("teleporter")
	_inc("clonebay")
	if crew_hurt():
		_inc("medbay")
	while true:
		var drones_ok := false
		if hostile and not escaping:
			var wi := _pick_weapon_to_power()
			if wi >= 0:
				_try_power_weapon(wi)  # if it does not fit, no other weapon is tried this pass
			drones_ok = _inc("drones")
		var shields_ok := _inc("shields")
		var cloak_ok := _inc("cloaking")
		var engines_ok := _inc("engines")
		if not (drones_ok or shields_ok or cloak_ok or engines_ok):
			break
	# Fill the rest, in the ship's system list order (blueprint order).
	broken_systems = 0
	for id in _system_list():
		var s := ship.sys(id)
		if s.get_level() > 0 and s.damage >= s.get_level():
			broken_systems += 1
		while _inc(id):
			pass
	_apply_plan()


## Systems in blueprint order (ShipManager system list).
func _system_list() -> Array:
	var out := []
	for b in ship.blueprint.get("systems", []):
		if b.start and ship.sys(b.id) != null and not out.has(b.id):
			out.append(b.id)
	return out


## Locked (ion) or hacked systems refuse power changes.
func _frozen(s: SystemState) -> bool:
	return s.is_locked() or s.hacked


## ShutdownAllPower: everything that accepts it goes to 0; frozen systems keep their bars.
func _shutdown_plan() -> void:
	_plan.clear()
	_bplan.clear()
	for id in ship.systems:
		var s: SystemState = ship.systems[id]
		if not s.uses_reactor() or id == "weapons" or id == "drones":
			continue
		_plan[id] = s.power if _frozen(s) else 0
		_bplan[id] = s.battery if _frozen(s) else 0
	_wplan.clear()
	var wsys := ship.sys("weapons")
	var keep := wsys != null and _frozen(wsys)
	_wbat = wsys.battery if keep else 0
	for w in ship.weapons:
		_wplan.append(w.powered if keep else false)
	_dplan.clear()
	var dsys := ship.sys("drones")
	var dkeep := dsys != null and _frozen(dsys)
	_dbat = dsys.battery if dkeep else 0
	_dparts = ship.drone_parts
	for d in ship.drones:
		_dplan.append(d.powered if dkeep else false)


func _plan_weapons_used() -> int:
	var used := 0
	for i in ship.weapons.size():
		if _wplan[i]:
			used += ship.weapons[i].power_cost()
	return used


## Battery bars needed to add `k` bars to the plan (reactor first, then battery), or -1 if they do not fit.
func _plan_drones_used() -> int:
	var used := 0
	for i in ship.drones.size():
		if _dplan[i]:
			used += ship.drones[i].required_power()
	return used


func _take(k: int) -> int:
	var reactor_used := _plan_weapons_used() - _wbat + _plan_drones_used() - _dbat
	var battery_used := _wbat + _dbat
	for id in _plan:
		reactor_used += _plan[id] - _bplan[id]
		battery_used += _bplan[id]
	var from_reactor := clampi(ship.reactor_capacity() - reactor_used, 0, k)
	var from_battery := k - from_reactor
	if from_battery > ship.battery_cap - battery_used:
		return -1
	return from_battery


## IncreaseSystemPower(id) on the plan. Returns false when the system refuses.
func _inc(id: String) -> bool:
	var s := ship.sys(id)
	if s == null or not s.uses_reactor() or _frozen(s):
		return false
	match id:
		"weapons":
			for i in ship.weapons.size():  # WeaponSystem: first unpowered weapon that fits, slot order
				if not _wplan[i] and _try_power_weapon(i):
					return true
			return false
		"drones":
			return _try_power_drone()
		"shields":
			var p: int = _plan[id]
			var step := 2 - (p & 1)  # 2 bars per layer (rules/power.md)
			if p + step > s.max_power():
				return false
			var b := _take(step)
			if b < 0:
				return false
			_plan[id] = p + step
			_bplan[id] += b
			return true
		_:
			if _plan[id] + 1 > s.max_power():
				return false
			var b := _take(1)
			if b < 0:
				return false
			_plan[id] += 1
			_bplan[id] += b
			return true


## WeaponSystem::PowerWeapon on the plan (same checks as ShipState.try_power_weapon).
func _try_power_weapon(i: int) -> bool:
	var wsys := ship.sys("weapons")
	if wsys == null or _frozen(wsys) or _wplan[i]:
		return false
	var w := ship.weapons[i]
	if w.uses_missiles() and ship.missiles < 1:
		return false
	if wsys.max_power() - _plan_weapons_used() < w.power_cost():
		return false
	var b := _take(w.power_cost())
	if b < 0:
		return false
	_wplan[i] = true
	_wbat += b
	return true


## DroneSystem::ForceIncreasePower on the plan: the first unpowered drone (slot order) that is deployed
## or can be deployed (and is not rebuilding) gets PowerDrone's checks; a new deployment uses a part.
func _try_power_drone() -> bool:
	var dsys := ship.sys("drones")
	if dsys == null or _frozen(dsys):
		return false
	for i in ship.drones.size():
		var d := ship.drones[i]
		if _dplan[i] or d.rebuilding() or not (d.deployed or d.can_be_deployed()):
			continue
		if not d.deployed and _dparts < 1:
			return false
		if dsys.max_power() - _plan_drones_used() < d.required_power():
			return false
		var b := _take(d.required_power())
		if b < 0:
			return false
		_dplan[i] = true
		_dbat += b
		if not d.deployed:
			_dparts -= 1
		return true
	return false


## Round-robin weapon pick: an unpowered weapon still firing its volley, else the most charged one.
## The comparison is against the best charge so far truncated to whole seconds (as in the exe), so a
## later weapon wins a near-tie if its charge exceeds the truncated best; exact ties keep the earlier slot.
func _pick_weapon_to_power() -> int:
	if ship.sys("weapons") == null:
		return -1
	var best := -1
	var best_whole := -1
	for i in ship.weapons.size():
		if _wplan[i]:
			continue
		var w := ship.weapons[i]
		if w.queued_shots > 0:  # stands in for "firing animation still playing"
			return i
		if float(best_whole) < w.charge:
			best_whole = int(w.charge)
			best = i
	return best


## Write the plan to the ship; only systems/weapons whose power actually changed are touched.
func _apply_plan() -> void:
	for id in _plan:
		var s := ship.sys(id)
		s.power = _plan[id]
		s.battery = _bplan[id]
		s.user_power = s.power
	for i in ship.weapons.size():
		var w := ship.weapons[i]
		if w.powered != _wplan[i]:
			ship._set_weapon_powered(w, _wplan[i])
	var wsys := ship.sys("weapons")
	if wsys:
		wsys.power = _plan_weapons_used()
		wsys.battery = _wbat
		wsys.user_power = wsys.power
	# Drones: depower first, then power (PowerDrone deploys and spends a part when needed).
	for i in ship.drones.size():
		if ship.drones[i].powered and not _dplan[i]:
			DroneSystemRule.depower_drone(ship, ship.drones[i])
	for i in ship.drones.size():
		if _dplan[i] and not ship.drones[i].powered:
			DroneSystemRule.power_drone(ship, ship.drones[i])
	ship._clamp_shields()  # only lowers layers if the shields really ended the frame with less power


## CrewAI bHurtCrew: someone below 25 % health, or below 99 % while the ship is calm.
func crew_hurt() -> bool:
	var calm := is_calm()
	for c in ship.crew:
		if not c.is_alive() or c.is_intruder(ship) or c.is_drone():
			continue
		var f := c.hp / c.max_hp
		if f < HURT_ALWAYS or (calm and f < HURT_CALM):
			return true
	return false


## CrewAI bCalmShip: no fire, no breach, no damaged system, no boarders.
func is_calm() -> bool:
	if not ship.fires.is_empty() or not ship.breaches.is_empty() or not ship.intruders().is_empty():
		return false
	for s in ship.systems.values():
		if s.damage > 0:
			return false
	return true


## DeactiveWeapons (not hostile, or own hull <= 0).
func _stand_down() -> void:
	for w in ship.weapons:
		if w.powered:
			ship._set_weapon_powered(w, false)
	for d in ship.drones:
		DroneSystemRule.depower_drone(ship, d)
	var a := ship.sys("artillery")
	if a and not _frozen(a):
		ship._set_power(a, 0)
		a.user_power = 0
	var tp := ship.sys("teleporter")
	if tp:
		ship.force_unlock(tp)  # TeleportSystem::ForceReady: LockSystem(0)
	teleport_request = 0
	if crew_ai:
		crew_ai.set_teleport_request(0)
	if ship.hacking:
		HackingRule.stop(ship)  # StopHacking
	MindRule.ai_update(ship, false)  # release if in use


# ------------------------------------------------------------ weapons (UpdateWeapons)

## Decide which weapons fire this frame. A firing weapon gets its target ship and per-shot points
## (`pending_points`) and `fire_when_ready`; Combat._update_weapons launches it in the same frame.
func update_weapons() -> void:
	if ship.is_cloaked() and not firing_while_cloaked:
		return  # holds fire while cloaked (keeps charging)
	if target == null or target.is_destroyed():
		return
	if _target_cloaked():
		return
	var wl := ship.crew_level_in("weapons")
	for w in ship.weapons:
		var goal := charge_goal(w)
		var level := w.current_charge_level(wl)
		# ReadyToFire
		if level < 1 or not w.powered or ship.missiles < w.missiles_per_shot():
			continue
		# IsChargedGoal
		if w.charge_levels() >= 1 and level < goal:
			continue
		# Multi-charge not yet full: per-frame roll rand % (max - current + 1) == 0
		if w.charge_levels() >= 2 and level != w.charge_levels():
			if rng.randi() % (w.charge_levels() - level + 1) != 0:
				continue
		# Fire ignores the call while the previous volley still has queued shots.
		if w.queued_shots > 0:
			continue
		var points := pick_points(num_targets_required(w, wl))
		w.set_target(target, target.room_at(points[0]), points[0], false)
		w.pending_points = points
		charge_goals[w] = select_charge_goal(w)  # re-rolled right after Fire


## SelectChargeGoal: uniform 1..chargeLevels.
func select_charge_goal(w: WeaponState) -> int:
	return rng.randi() % maxi(w.charge_levels(), 1) + 1


func charge_goal(w: WeaponState) -> int:
	if not charge_goals.has(w):
		charge_goals[w] = select_charge_goal(w)  # rolled when the weapon is created
	return charge_goals[w]


## NumTargetsRequired: blueprint shots (beam: 2 = start and end), or the charge level for multi-charge.
func num_targets_required(w: WeaponState, wl: int) -> int:
	if w.charge_levels() >= 2:
		return maxi(w.current_charge_level(wl), 1)
	if w.is_beam():
		return 2  # the blueprint parser forces beam shots to 2: sweep start and end (rules/weapons.md)
	return int(w.bp.shots)


## n distinct room centers on the target (one per shot; the first is the first shot).
## The exe keeps picking until n distinct points exist; if the target has fewer rooms than n
## that would never end, so here repeats are allowed once every room has been used.
func pick_points(n: int) -> Array[Vector2]:
	var points: Array[Vector2] = []
	var room_count: int = target.layout.rooms.size()
	var guard := 0
	while points.size() < n:
		var p := _pick_point()
		guard += 1
		if points.has(p) and points.size() < room_count and guard < 1000:
			continue
		points.append(p)
	return points


## One point: PrioritizeSystem, then the room of that system or a uniformly random room.
func _pick_point() -> Vector2:
	var sys_id := prioritize_system()
	var r := rng.randi()  # the exe always rolls the random room, even when a system was chosen
	var rooms: Array = target.layout.rooms
	var room_id: int = rooms[r % rooms.size()].id
	if sys_id != "":
		room_id = target.sys(sys_id).room
	return target.room_rect(room_id).get_center()


## CombatAI::PrioritizeSystem. Returns a system id of the target, or "" for a random room.
func prioritize_system() -> String:
	if difficulty != Difficulty.HARD:
		var chance := SYSTEM_BIAS_EASY if difficulty == Difficulty.EASY else SYSTEM_BIAS_NORMAL
		if rng.randi() % 100 < chance and target != null:
			var id: String = SYSTEM_TARGETS[rng.randi() % SYSTEM_TARGETS.size()]
			if target.sys(id) != null:
				return id
		return ""
	var keys := key_targets()
	var r := rng.randi() % 100
	if not keys.is_empty() and r < HARD_KEY_CHANCE:
		return keys[rng.randi() % keys.size()]
	if r < HARD_SYSTEM_CHANCE:
		var all := target.systems.keys()
		if all.is_empty():
			return ""
		return all[rng.randi() % all.size()]
	return ""


## Hard difficulty "key targets" built from the target's installed systems.
func key_targets() -> Array:
	var keys := []
	for id in target.systems:
		var s: SystemState = target.systems[id]
		var add := false
		match id:
			"shields", "drones", "weapons":
				add = s.effective_power() > 0
			"engines", "pilot":
				add = target.dodge_factor() >= HARD_DODGE_MIN
			"oxygen":
				add = target.env.average_oxygen() < HARD_OXYGEN_MAX
			"doors":
				add = not target.fires.is_empty() or not target.intruders().is_empty()
			"cloaking":
				add = not s.is_locked()
			"teleporter":
				add = not ship.intruders().is_empty()  # the AI ship itself is boarded
			"artillery":
				add = not target.artillery.is_empty() and target.artillery[0].charge > 4.0
			"battery":
				add = s.turned_on
			"clonebay":
				add = ClonebayRule.progress(target) > 0.0
			"mind":
				add = target.mind_in_use
			"hacking":
				add = target.hacking
			# medbay, sensors: never.
		if add:
			keys.append(id)
	return keys


## The target is cloaked -> hold fire (it keeps charging; its own charge is frozen by ShipState.tick).
func _target_cloaked() -> bool:
	return target != null and target.is_cloaked()


# ------------------------------------------------------------ escape (section 4, partial)

## Escape countdown while escaping; only runs while engines and piloting function (JumpCharging).
## TODO: thresholds -> escape/surrender events, stalemate, FTL_JAMMER, the jump itself.
func _update_escape(seconds: float) -> void:
	if not escaping or jump_requested:
		return
	var e := ship.sys("engines")
	var p := ship.sys("pilot")
	if e == null or p == null or e.effective_power() <= 0 or p.effective_power() <= 0 or e.hacked or p.hacked:
		return
	escape_timer -= seconds
	if escape_timer < 0.0:
		jump_requested = true
