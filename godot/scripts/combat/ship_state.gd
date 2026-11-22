class_name ShipState
extends RefCounted
## Logical state of a ship (no drawing at all). Drawn by ShipView, driven by Combat.

const T := 35
const SHIELD_CHARGE_TIME := 2.0

var blueprint := {}
var ship_title := ""  # player ship name (hangar name box; blueprint <name> by default)
var layout := {}
var is_player := true
var origin := Vector2.ZERO  # corner of the room grid (local coordinates of the space)

var hull := 0
var max_hull := 0
## ShipManager::iLastDamage: the last hull change from DamageHull / DamageArea / DamageBeam / SunDamage (negative =
## repair), read and cleared once per frame by the player's screen shake (ScreenShake, CommandGui::OnLoop).
var last_damage := 0
var explosion: ShipExplosion = null  # set when the hull reaches 0 (rules/ship_destruction.md)
var shield_layers := 0
var shield_charger := 0.0
# Shield bubble animation trackers (rules/weapon_visuals.md "Shield bubble animations"), real seconds since
# Start; < 0 = not running. Visual only: no rule reads them. ShipView draws them.
const SHIELD_UP_TIME := 0.15  # shieldsUp: bubble scale-in 0 -> 1
const SHIELD_DOWN_TIME := 0.5  # shieldsDown: popped-layer dissolve (player ship)
const SUPER_UP_TIME := 0.5  # superShieldUp: green wave from the drone (player ship)
var shield_up_t := -1.0  # never started = scale 0 (set to SHIELD_UP_TIME = full size by InstantCharge)
var shield_down_t := -1.0
var shield_down_point := Vector2.ZERO
var shield_down_super := false  # the popped point was a super-shield point (green ghost)
var super_up_t := -1.0
var super_up_loc := Vector2.ZERO
var shield_sounds: Array[String] = []  # last shieldsUp / shieldsDown sounds played (tests; capped)
var weapons: Array[WeaponState] = []
var weapon_slots := 4
var missiles := 0:
	set(v):
		_resource_set(&"missiles", missiles, v)
		missiles = v
var fuel := 0:  # fuel_count (−1 per jump in run mode, RunState)
	set(v):
		_resource_set(&"fuel", fuel, v)
		fuel = v
var scrap := 0:  # scrap (event rewards, store)
	set(v):
		_resource_set(&"scrap", scrap, v)
		scrap = v
var ftl_charge := 0.0  # FTL drive charge 0..1 (run mode: RunState.tick [placeholder]; sandbox: 0)
var last_jump_ready := false  # ShipManager::lastJumpReady (jumpReady sound; not saved: false after a load)
var last_engine_status := false  # ShipManager::lastEngineStatus: GetDodgeFactor > 0 last frame (enginesOff)
var autofire := false  # AUTOFIRE button of the weapons panel
var mounts: Array = []
var crew_rooms: Array[int] = []  # rooms with a living crew member (recomputed from `crew`)
var crew: Array[CrewMember] = []
var fires := {}  # room_id -> {tile_index: {death: s (-1 = no timer), health: 0..100}}
var breaches := {}  # room_id -> {tile_index: {health: 0..100}}
var lockdowns: Array = []  # crystal lockdown shards (Ship::lockdowns, LockdownRule)
var env: ShipEnvironment  # oxygen, doors, fire spread
var graph: ShipGraph  # slots and door pathfinding (rules/crew.md)
var hostile := true  # crew fight only aboard a hostile ship (ShipManager hostile flag)
var rng := RandomNumberGenerator.new()  # crew combat rolls (target pick, hit damage, timers)

const HUMAN_HP := 100.0
const ENEMY_ELLIPSE_DY := 110.0  # Ship::GetBaseEllipse: enemy ellipse centre y + 110
const REPAIRABLE_HEALTH := 100.0  # fire / breach health (Repairable)
## Systems that accept the manning bonus (rules/crew.md "Manning").
const BOOSTABLE := ["shields", "engines", "weapons", "pilot", "sensors", "doors", "artillery"]
## Skill used when actively manning each system (sensors/doors: always level 1).
const MAN_SKILL := {"pilot": "pilot", "engines": "engines", "shields": "shields", "weapons": "weapons"}
const STUN_MIN := 3.0  # s, when the stunChance roll succeeds
var fire_heading := 0.0  # degrees: 0 = right, 270 = up

# Power (rules/power.md)
var reactor_max := 0
var reactor_divide := 1  # status effect "divide reactor" (ion storm: 2), rules/hazards.md §4
var reactor_hacked := 0  # PowerManager iHacked: 2 while the battery is actively hacked (rules/battery.md)
var battery_cap := 0  # bars the backup battery provides while on (2 x its power; rules/battery.md)
## PowerManager failedPowerup (rules/power.md "Power-up failure warning"): set whenever the REACTOR refuses a
## power step (player click, weapon/drone power, automatic re-power); read-and-cleared by the player HUD
## (ReactorColumn) every frame, which then shows NOT ENOUGH POWER. Never read for enemy ships.
var failed_powerup := false
var systems := {}  # id -> SystemState
var augments: Array = []  # <aug name=".."/> of the blueprint (tests may add more)

# Opponent and special systems (rules/cloaking.md, teleporter.md, artillery.md, clonebay.md)
var opponent: ShipState = null  # the ship it fights (set by Combat; weapons' currentShipTarget)
var artillery: Array[WeaponState] = []  # one ProjectileFactory per artillery system
var teleporting := {}  # CrewMember -> true while it plays its 0.5 s teleport animation aboard this ship
var clone_queue: Array = []  # dead crew of this side waiting for the clonebay, oldest death first
var clone_death_timer := 0.0  # s the clonebay has been unable to clone with a non-empty queue
var cloak_fade := 0.0  # Ship::cloakingTracker time, 0..CLOAK_FADE (forward while cloaked)
var jumping := false  # FTL jump in progress (no jump yet; blocks teleports)
## ShipManager::bWasSafe: set by SetSafe (every frame at a beacon with no hostile ship and no hostile environment),
## read and cleared by JumpArrive / Wait (`arrive_locks`): rules/ftl_drive.md §4.3, rules/mind_control.md.
var was_safe := false

# Drones (rules/drones.md): one Drone per slot, drone parts, Zoltan super shield layers (shield drone)
var drones: Array[Drone] = []
var drone_parts := 0:  # drone_count (ship-wide; one per deployment)
	set(v):
		_resource_set(&"drone_parts", drone_parts, v)
		drone_parts = v
var drone_slots := 0
var super_shield := 0  # Shields power.super.first
var super_shield_max := 0  # power.super.second (5 once a layer was added)
var last_super_hit := {}  # last super-shield collision {lost, resisted} (visuals: green number / RESIST)
var shield_ion_resisted := false  # ION_ARMOR won the roll on the last normal-shield hit (no ion to the shields)
var missiles_saved := 0  # EXPLOSIVE_REPLICATOR saves (event 12: the HUD's "0" popup at the missile counter)
var pending_shards: Array = []  # CRYSTAL_SHARDS shots queued by a hit (superBarrage), launched by Combat
## Systems that blew up this frame (ShipSystem::GetExploded): room ids, drawn by Combat as a "1" hull number,
## explosion1 and the sysExplosion sound (rules/damage.md "System explosion").
var pending_explosions: Array = []
const DRONE_BODY_TIME := 1.0  # s: a dead crew drone's explosion strip (explosion1_strip10, 1.0 s, no fade)

# Hacking (rules/hacking.md, HackingRule): this ship's hacking system state and its drone.
var hack_drone: Drone = null  # the embedded HackingDrone (created on first launch)
var hacking := false  # bHacking: drone launched and alive
var hack_target: SystemState = null  # currentSystem (a system of `opponent`)
var hack_queued: SystemState = null  # queuedSystem (StartHacking, launched on the next frame)
var hack_armed := false  # player UI waiting for a room click
var hack_blocked := false  # bBlocked: the target has super shields (or this enemy is jumping)
var hack_elapsed := 0.0  # effectTimer.first (s into the pulse)
var hack_duration := 10.0  # effectTimer.second
var hack_virtual: SystemState = null  # debug: a hacking system not in the blueprint (main.gd --hack)
var shield_excess_hack := false  # Shields bExcessChargeHack: the pulse first drains a partial charge
## Room::iHackLevel per room (rebuilt every frame from the hacked systems) and rooms under a pulse
## (Room fHacked: floor sparks).
var room_hack := {}
# Mind control (rules/mind_control.md, MindRule): this ship's mind system state.
var mind_list: Array = []  # controlledCrew
var mind_queue: Array = []  # queued crew (QueueMindControl)
var mind_armed := false
var mind_in_use := false  # controlTimer elapsed != duration
var mind_elapsed := 14.0
var mind_duration := 14.0
var mind_can_use := false  # bCanUse
var mind_blocked := false  # bBlocked (super shields)

# Shield ellipse (local coordinates)
var shield_center := Vector2.ZERO
var shield_axes := Vector2.ZERO


func _init(bp_name: String, player: bool) -> void:
	is_player = player
	blueprint = FtlData.ship_blueprint(bp_name)
	layout = FtlData.ship_layout(blueprint.layout)
	origin = Vector2(layout.x_offset, layout.y_offset) * T
	max_hull = blueprint.hull
	hull = max_hull
	fire_heading = 0.0 if player else 270.0
	weapon_slots = blueprint.weapon_slots
	missiles = blueprint.missiles
	if player:  # new-game resources [inferred: FTL starts a run with 16 fuel]
		fuel = 16
		scrap = 30
	mounts = FtlData.weapon_mounts(blueprint.layout)
	reactor_max = blueprint.max_power

	for s in blueprint.systems:
		if s.start:
			systems[s.id] = SystemState.new(s.id, s.room, s.power)
	env = ShipEnvironment.new(self)
	graph = ShipGraph.new(self)

	_place_initial_crew()
	# ShipManager::OnInit: AddInitialCrew, then SaveCrewPositions -> the starting stations are the saved
	# stations ("return to stations" works without pressing save first; rules/crew_controls.md).
	save_crew_positions()

	# Ellipse (Ship::GetBaseEllipse): layout ELLIPSE offset + ship-graph centre (integer centre of the rooms'
	# box), and 110 px lower on enemy ships (iShipId != 0).
	var e: Vector4 = layout.get("ellipse", Vector4(200, 200, 0, 0))
	shield_axes = Vector2(e.x, e.y)
	var b := rooms_bounds()
	var gc := Vector2(floorf(b.position.x + b.size.x / 2.0), floorf(b.position.y + b.size.y / 2.0))
	shield_center = gc + Vector2(e.z, e.w) + (Vector2.ZERO if player else Vector2(0, ENEMY_ELLIPSE_DY))

	_load_weapons()
	_load_artillery()
	DroneSystemRule.load_drones(self)
	for m in RegEx.create_from_string("<aug\\s+name=\"([^\"]+)\"").search_all(_blueprint_text()):
		AugmentRule.add(self, m.get_string(1))  # max 3 (ShipObject::AddAugmentation)
	_startup_power()
	shield_layers = max_shield_layers()
	# Shields constructor / InstantCharge: a ship that starts with layers shows the bubble at full size.
	shield_up_t = SHIELD_UP_TIME if shield_layers > 0 else -1.0


## ShipManager::AddInitialCrew (rules/crew_ai.md "Initial placement"): crew i (blueprint order) goes
## to the room of the i-th system of the list below that the ship has (console slot first); crew
## beyond the list go to a random room.
func _place_initial_crew() -> void:
	var order := ["pilot"]
	if is_player:
		order += ["engines", "weapons", "shields"]
	elif ShipAI.difficulty == ShipAI.Difficulty.HARD:
		order += ["artillery", "artillery", "engines", "weapons", "shields"]
	else:
		order += ["artillery", "artillery", "shields", "weapons", "engines"]
	order += ["oxygen", "sensors", "doors", "cloaking", "medbay", "drones", "hacking", "teleporter",
		"artillery"]
	var rooms := []
	for id in order:
		var s := sys(id)
		# One artillery system at most here, so later artillery entries are dropped.
		if s and not rooms.has(s.room):
			rooms.append(s.room)
	var race_rng: RandomNumberGenerator = null
	for i in blueprint.crew.size():
		var race: String = blueprint.crew[i]
		if race == "random":
			# crewCount class="random" (pirate blueprints) on a ship built without ShipGenerator (scenario /
			# --enemy-ship): one GetRandomCrew(1) draw per crew member, as CreateShip does (ShipGenerator._crew_races).
			if race_rng == null:
				race_rng = RandomNumberGenerator.new()
				race_rng.randomize()
			race = ShipGenerator.random_race({}, race_rng)
		var c := CrewMember.new(race, is_player)
		var room: int = rooms[i] if i < rooms.size() else -1
		var slot := graph.find_slot(room, c) if room >= 0 else -1
		if slot < 0:
			var free := []
			for r in layout.rooms:
				if graph.find_slot(r.id, c) >= 0:
					free.append(r.id)
			if free.is_empty():
				break
			room = free[randi() % free.size()]
			slot = graph.find_slot(room, c)
		c.place(self, room, slot)
		# AddInitialCrew -> GetCrewBlueprint: random unused name + gender, colours rolled (rules/crew_appearance.md §6).
		CrewIdentity.assign(c, null, CrewIdentity.used_names(self))
		crew.append(c)
	_refresh_crew_rooms()


## A crew member of the given side appears aboard. Own crew (event rewards, store hires; rules/crew.md "New crew
## placement"): ShipManager::AddCrewMember with roomId −1 = the pilot room, then Ship::GetAvailableRoom
## (`available_room`). Intruders (debug boarding, no teleporter yet): `room_id`, or a random room with a free slot
## of their side when -1 or full. Returns it, or null if no slot is free.
## `ident` (CrewIdentity dictionary: store box / event crew) keeps a pre-rolled name, gender and colours; empty =
## a random unused name and colours (AddCrewMember with an empty name).
func add_crew(race: String, player_owned: bool, room_id := -1, ident := {}) -> CrewMember:
	var c := CrewMember.new(race, player_owned)
	if ident.is_empty():
		CrewIdentity.assign(c, null, CrewIdentity.used_names(self))
	else:
		CrewIdentity.apply(c, ident)
	var room := room_id
	if not c.is_intruder(self):
		if room < 0 and sys("pilot") != null:
			room = sys("pilot").room
		room = available_room(room, c)
		if room < 0 or graph.find_slot(room, c) < 0:
			return null
	elif room < 0 or graph.find_slot(room, c) < 0:
		var free := []
		for r in layout.rooms:
			if graph.find_slot(r.id, c) >= 0:
				free.append(r.id)
		if free.is_empty():
			return null
		room = free[rng.randi() % free.size()]
	c.place(self, room, graph.find_slot(room, c))
	c.ai_task = {"id": CrewAI.IDLE, "room": room, "sys": ""}
	crew.append(c)
	_refresh_crew_rooms()
	return c


## Ship::GetAvailableRoom (rules/crew.md "New crew placement") for crew `c` of this ship's side: the preferred
## room if it has a free slot; else the first room with a free slot among the rooms its doors lead to (door
## order; preferred −1 = the airlock rooms); else (preferred −1) the lowest room id with a free slot, or the room
## whose centre is nearest the preferred room's centre (ties: lowest id). −1 / the preferred room if all are full.
func available_room(preferred: int, c: CrewMember) -> int:
	if preferred >= 0 and graph.find_slot(preferred, c) >= 0:
		return preferred
	for d in env.doors:  # ShipGraph::GetConnectedRooms(preferred, false)
		var other := -2
		if int(d.left) == preferred:
			other = int(d.right)
		elif int(d.right) == preferred:
			other = int(d.left)
		if other >= 0 and graph.find_slot(other, c) >= 0:
			return other
	var ids := []
	for r in layout.rooms:
		ids.append(int(r.id))
	ids.sort()
	if preferred < 0:
		for id in ids:
			if graph.find_slot(id, c) >= 0:
				return id
		return -1
	var from := room_rect(preferred).get_center()
	var best := -1
	var best_d := 0  # stored truncated to int, compared against the next room's float distance
	for id in ids:
		if graph.find_slot(id, c) < 0:
			continue
		var dist := from.distance_to(room_rect(id).get_center())
		if best != -1 and float(best_d) <= dist:
			continue
		best = id
		best_d = int(dist)
	return best if best != -1 else preferred


## Living crew of this ship's own side (no intruders).
func own_crew() -> Array:
	return crew.filter(func(c): return c.is_alive() and not c.is_intruder(self) and not c.is_drone())


## Living intruders aboard.
func intruders() -> Array:
	return crew.filter(func(c): return c.is_alive() and c.is_intruder(self))


## ShipManager::DoSensorsProvide(feature): no sensors or a hack pulse on them -> false; else by effective power
## (manning +1 included): 1 = own interior (> 0), 2 = enemy interior (> 1), 3 = enemy system power bars (> 3),
## 4 = enemy weapon charge (> 2).
func sensors_provide(feature: int) -> bool:
	var s := sys("sensors")
	if s == null or s.hack_effect() > 1:
		return false
	var p := s.effective_power()
	match feature:
		1:
			return p > 0
		2:
			return p > 1
		3:
			return p > 3
		4:
			return p > 2
	return false


## ShipManager::DoorsFunction: doors system present, working, not ionized and not hacked.
func doors_function() -> bool:
	var ds := sys("doors")
	return ds != null and ds.effective_power() > 0 and not ds.hacked and not ds.is_locked()


## ShipManager::ManipulateAllDoors (door control box buttons, hotkeys Z = open / X = close): needs a working
## doors system (DoorsFunction, not locked). Open: every interior door not hacked opens; only when none was
## closed (second press) the airlocks open too. Close: interior doors (not hacked) and every airlock close.
## Returns how many doors changed ("doorOpen" plays that many times, at most 8).
func manipulate_all_doors(open: bool) -> int:
	if not doors_function():
		return 0
	var changed := 0
	var inner_changed := false
	for i in env.doors.size():
		var d: Dictionary = env.doors[i]
		if d.airlock or d.hacked > 0:
			continue
		var was: bool = d.open
		env.set_door(i, open)
		if d.open != was:
			changed += 1
			inner_changed = true
	if not open or not inner_changed:
		for i in env.doors.size():
			var d: Dictionary = env.doors[i]
			if not d.airlock:
				continue
			var was: bool = d.open
			env.set_door(i, open)
			if d.open != was:
				changed += 1
	env.update_door_sounds(true)  # SoundControl::ignoreSounds: the caller plays "doorOpen" x min(changed, 8)
	return changed


## The ship's crew list holds `c`, or the opponent's does (the ship it stands on), else null.
func ship_of(c: CrewMember) -> ShipState:
	if crew.has(c):
		return self
	if opponent != null and opponent.crew.has(c):
		return opponent
	return null


func _load_weapons() -> void:
	var names: Array = []
	# Explicit blueprint list (player) or "load" list (enemies)
	var bp_text := _blueprint_text()
	for m in RegEx.create_from_string("<weapon\\s+name=\"([^\"]+)\"").search_all(bp_text):
		names.append(m.get_string(1))
	if names.is_empty():
		var load := RegEx.create_from_string("<weaponList[^>]*load=\"([^\"]+)\"").search(bp_text)
		if load and sys("weapons"):
			# Prototype: the first laser in the list that fits the weapons level.
			var ws_sys := sys("weapons")
			var list := FtlData.blueprint_list(load.get_string(1))
			for n in list:
				var w := FtlData.weapon_blueprint(n) if FtlData.has_weapon_blueprint(n) else {}
				if not w.is_empty() and w.type == "LASER" and w.power <= ws_sys.level:
					names.append(n)
					break
			# None fits (e.g. weapons level 0, as on AUTO_ASSAULT): take the cheapest weapon of the
			# list and raise the weapons level to its power, so every test enemy can shoot.
			if names.is_empty():
				var best := {}
				for n in list:
					var w := FtlData.weapon_blueprint(n) if FtlData.has_weapon_blueprint(n) else {}
					if not w.is_empty() and w.power > 0 and (best.is_empty() or w.power < best.power):
						best = w
				if not best.is_empty():
					names.append(best.name)
					ws_sys.level = maxi(ws_sys.level, int(best.power))
	for i in names.size():
		var w := FtlData.weapon_blueprint(names[i])
		if not w.is_empty():
			var ws := WeaponState.new(w, i)
			ws.powered = false
			weapons.append(ws)


## Startup power-up (rules/power.md "Startup power-up"): once, when the ship is created, system by
## system in blueprint order, from the reactor. Shields: full even power (IncreasePower + the
## ForceIncreasePower loop). Weapons and drones: unpowered. Player: 1 bar for every other system
## (iRequiredPower 1); enemy: the full level. Subsystems run on their own level.
func _startup_power() -> void:
	for b in blueprint.get("systems", []):
		if not b.start:
			continue
		var s := sys(b.id)
		if s == null or not s.uses_reactor() or b.id == "weapons" or b.id == "drones" or s.power > 0:
			continue
		if b.id == "shields":
			while increase_power("shields") == "ok":
				pass
			continue
		var want := 1 if is_player else s.get_level()
		while s.power < want and increase_power(b.id) == "ok":
			pass


## Artillery systems: a ProjectileFactory each, built from the blueprint's weapon (rules/artillery.md).
## Mount (ShipManager::RenderWeapons): the weapons list padded to 4 entries, then the artillery weapons, so artillery
## n uses mount max(weapons, 4) + n (FED cruiser: the 5th mount; flagship: mounts 4-7).
func _load_artillery() -> void:
	for b in blueprint.get("systems", []):
		if b.id != "artillery" or not b.start or String(b.get("weapon", "")) == "":
			continue
		var w := FtlData.weapon_blueprint(b.weapon)
		if w.is_empty():
			continue
		var ws := WeaponState.new(w, maxi(weapons.size(), 4) + artillery.size())
		ws.powered = false
		ws.is_artillery = true
		artillery.append(ws)


## System ids in blueprint order (ShipManager vSystemList = creation order).
func system_list() -> Array:
	var out := []
	for b in blueprint.get("systems", []):
		if b.start and sys(b.id) != null and not out.has(b.id):
			out.append(b.id)
	return out


func has_augment(aug: String) -> bool:
	return AugmentRule.has(self, aug)


## Augment value through the registry (AugmentRule.value: count x <value>, filtered); `default` without it.
func augment_value(aug: String, default := 1.0) -> float:
	return AugmentRule.value(self, aug) if AugmentRule.has(self, aug) else default


func _blueprint_text() -> String:
	return FtlData.ship_blueprint_text(blueprint.name)


# ------------------------------------------------------------ systems and reactor

## Resource setters (fuel / missiles / drone_parts / scrap): notify `resource_changed(ship, kind, old, new)`
## (rules/hooks.md) on every real change; the HUD popups (ShipStatusHud) follow the values themselves.
func _resource_set(kind: StringName, old: int, v: int) -> void:
	if old != v and is_inside_tree_safe():
		Hooks.emit(&"resource_changed", self, kind, old, v)


## Hooks is an autoload: only reachable inside a running SceneTree (not from --check-only / bare scripts).
static func is_inside_tree_safe() -> bool:
	return Engine.get_main_loop() is SceneTree

func sys(id: String) -> SystemState:
	return systems.get(id)


## Blueprint system (raw dictionary).
func system_by_id(id: String) -> Dictionary:
	for s in blueprint.get("systems", []):
		if s.id == id and s.start:
			return s
	return {}


## Power a system is running on right now.
func system_power(id: String) -> int:
	var s := sys(id)
	return s.effective_power() if s else 0


## Reactor bars in use (battery bars excluded).
func reactor_used() -> int:
	var used := 0
	for s in systems.values():
		if s.uses_reactor():
			used += s.power - s.battery
	return used


## PowerManager::GetMaxPower: reactor - hacked (battery under attack).
func reactor_capacity() -> int:
	var cap := maxi(reactor_max - reactor_hacked, 0)
	if reactor_divide > 1:  # ion storm status effect (divide reactor 2): ceil(level / 2) (rules/hazards.md §4)
		cap = mini(cap, ceili(float(reactor_max) / reactor_divide))
	return cap


func reactor_free() -> int:
	return reactor_capacity() - reactor_used()


func battery_used() -> int:
	var used := 0
	for s in systems.values():
		used += s.battery
	return used


func battery_free() -> int:
	return battery_cap - battery_used()


## Bars a system can still take: free reactor + free battery (PowerManager::IncreasePower check).
func power_free() -> int:
	return maxi(reactor_free(), 0) + maxi(battery_free(), 0)


## Sets a system's total power. Bars added come from the reactor first, then the battery; bars removed
## free battery bars first (PowerManager::IncreasePower / DecreasePower, rules/battery.md).
func _set_power(s: SystemState, n: int) -> void:
	var old := s.power
	if n < old:
		s.battery = maxi(s.battery - (old - n), 0)
	elif n > old:
		var add := n - old
		var from_reactor := clampi(reactor_free(), 0, add)
		s.battery += add - from_reactor
	s.power = n


## Add 1 bar to a system (not weapons). Returns "ok", "locked", "max" or "reactor".
func increase_power(id: String, user := true) -> String:
	var s := sys(id)
	if s == null or not s.uses_reactor() or id == "weapons" or id == "drones":
		return "max"  # weapons and drones are powered per item (try_power_weapon / DroneSystemRule)
	if s.is_power_locked():  # ion / cooldown lock, or an active hack pulse (GetLocked)
		return power_failed(id, "locked")
	# Shields: 2 at a time (1 if left odd, zoltan bonus included). Others: 1 at a time.
	var step := (2 - ((s.power + s.bonus_power) & 1)) if id == "shields" else 1
	if s.power + s.bonus_power + step > s.max_power():
		return power_failed(id, "max")
	if power_free() < step:
		return power_failed(id, "reactor")  # PowerManager::IncreasePower: sets failedPowerup
	_set_power(s, s.power + step)
	if user:
		s.user_power = s.power + s.bonus_power
	return "ok"


## A power step was refused: the reactor case sets `failed_powerup` (PowerManager::IncreasePower); every case
## is reported to mods (`power_up_failed`). Returns `reason`.
func power_failed(id: String, reason: String) -> String:
	if reason == "reactor":
		failed_powerup = true
	Hooks.emit(&"power_up_failed", self, id, reason)
	return reason


## PowerManager::GetFailedPowerup: returns the flag and clears it.
func take_failed_powerup() -> bool:
	var f := failed_powerup
	failed_powerup = false
	return f


func decrease_power(id: String, user := true) -> bool:
	var s := sys(id)
	if s == null or id == "weapons" or id == "drones" or s.power <= 0 or s.is_power_locked():
		return false
	_set_power(s, s.power - 1)
	if id == "shields":
		_normalize_shields()  # goes down 2 at a time
	if user:
		s.user_power = s.power + s.bonus_power
	_clamp_shields()
	return true


## Damage to a system: breaks bars and removes power if it no longer fits.
func damage_system(id: String, amount: int) -> void:
	var s := sys(id)
	if s == null:
		return
	var a: Variant = Hooks.filter(&"damage_system", amount, self, id)
	if Hooks.is_cancel(a):
		return
	amount = int(a)
	var before := s.damage
	s.damage = mini(s.damage + amount, s.get_level())
	_check_max_power(s)
	if s.damage > before:
		Hooks.emit(&"system_damaged", self, id, s.damage - before)


func repair_system(id: String, amount: int) -> void:
	var s := sys(id)
	if s == null:
		return
	# One bar at a time: ShipSystem::PartialRepair calls CheckForRepower after every repaired bar
	# (except weapons and drones, which are re-powered per item by the player).
	for i in maxi(amount, 0):
		if s.damage <= 0:
			break
		s.damage -= 1
		Hooks.emit(&"system_repaired", self, id, s.damage)
		check_for_repower(s)
	if amount < 0:  # negative amount = damage (BOMB_HEAL_SYSTEM path keeps its old meaning)
		s.damage = maxi(s.damage - amount, 0)


## Events: the system loses n usable bars (SetPowerLoss). n = 0 gives them back.
func set_power_loss(id: String, n: int) -> void:
	var s := sys(id)
	if s == null:
		return
	s.power_loss = maxi(n, 0)
	_check_max_power(s)
	_on_unlocked(s)  # CheckForRepower: normal systems regain what they had


## Ions: lock the system and remove power (weapons: from the last slot).
func ion_system(id: String, amount: int) -> void:
	var s := sys(id)
	if s == null or amount <= 0:
		return
	s.add_ion(amount)
	if id == "weapons":
		var remaining := amount
		for i in range(weapons.size() - 1, -1, -1):
			var w := weapons[i]
			if w.powered:
				remaining -= w.power_cost()
				_set_weapon_powered(w, false)
			if remaining < 1:
				break
	elif id == "drones":
		DroneSystemRule.force_decrease(self, amount)
	else:
		_set_power(s, maxi(s.power - amount, 0))
	_clamp_shields()


## If the assigned power exceeds the usable maximum, power is removed.
## Weapons: from the last slot, depowering each powered weapon entirely (even 0-power ones).
func _check_max_power(s: SystemState) -> void:
	s.bonus_power = mini(s.bonus_power, s.max_power())  # AddDamage / SetPowerCap clamp the zoltan bonus at once
	if s.id == "weapons":
		for i in range(weapons.size() - 1, -1, -1):
			if weapons_power_used() + s.bonus_power <= s.max_power():
				break
			if weapons[i].powered:
				_set_weapon_powered(weapons[i], false)
	elif s.id == "drones":
		DroneSystemRule.check_max_power(self)
	else:
		_set_power(s, clampi(s.max_power() - s.bonus_power, 0, s.power))
	_clamp_shields()


func _clamp_shields() -> void:
	_normalize_shields()
	_check_shields_collapse(max_shield_layers())
	shield_layers = mini(shield_layers, max_shield_layers())


## Shields::OnLoop: layers > 0 but the max drops to 0 (depower / damage / ion) -> StartReverse + `shieldsDown`.
## The reverse scale-out is invisible (no white bubble at max 0), so only the sound is modelled.
func _check_shields_collapse(mx: int) -> void:
	if mx <= 0 and shield_layers > 0:
		shield_layers = 0
		shield_sound("shieldsDown")


## Plays a shield sound and remembers it (tests read `shield_sounds`).
func shield_sound(sound: String) -> void:
	shield_sounds.append(sound)
	Combat.log("%s: %s" % [blueprint.get("name", "?"), sound])
	if shield_sounds.size() > 16:
		shield_sounds.remove_at(0)
	FtlData.play(sound)


## Shields::CollisionReal: a shot removed a layer (or super-shield points) at `at` (ship-local): starts the
## player-ship dissolve and plays `shieldsDown` when no normal layer is left.
func shield_popped(at: Vector2, super_point: bool) -> void:
	shield_down_t = 0.0
	shield_down_point = at
	shield_down_super = super_point
	if shield_layers <= 0:
		shield_sound("shieldsDown")


## Shields animation trackers (AnimationTracker::Update, non-looping), advanced by real seconds.
func _tick_shield_anims(seconds: float) -> void:
	if shield_up_t >= 0.0:
		shield_up_t = minf(shield_up_t + seconds, SHIELD_UP_TIME)
	if shield_down_t >= 0.0:
		shield_down_t += seconds
		if shield_down_t >= SHIELD_DOWN_TIME:
			shield_down_t = -1.0
	if super_up_t >= 0.0:
		super_up_t += seconds
		if super_up_t >= SUPER_UP_TIME or super_shield < 1:
			super_up_t = -1.0


## Bubble scale-in factor (RenderBase: shieldsUp Progress; 0 if never started).
func shield_up_scale() -> float:
	return clampf(shield_up_t / SHIELD_UP_TIME, 0.0, 1.0) if shield_up_t >= 0.0 else 0.0


## Shields::OnLoop: shield power is never left odd (unless ionized).
func _normalize_shields() -> void:
	var s := sys("shields")
	if s == null:
		return
	if s.user_power % 2 == 1:
		s.user_power -= 1
	if (s.power + s.bonus_power) % 2 == 1 and s.power > 0 and not s.is_locked():
		_set_power(s, s.power - 1)


## Tests: set shields to n layers (level nx2), powered and charged.
func set_shield_layers_max(n: int) -> void:
	var s := sys("shields")
	if s == null:
		return
	s.override_level = n * 2
	s.damage = 0
	reactor_max += maxi(n * 2 - s.power, 0) if not is_player else 0
	s.power = n * 2
	s.battery = 0
	s.user_power = s.power
	shield_layers = n
	shield_charger = 0.0
	shield_up_t = SHIELD_UP_TIME  # InstantCharge: full size at once, no sound


## ShipManager::bAutomated: a crewless enemy (blueprint crewCount amount 0, or the flagship after its crew died).
func is_automated() -> bool:
	return not is_player and blueprint.get("crew", []).is_empty()


## Manning bonus level of a system (0 = none, 1..3 = skill level of the crew actively manning it).
## Requires a boostable, undamaged system (IsMannedBoost) and a crew member idle on its console. On an automated
## ship ShipManager::UpdateCrewmembers sets every system's bManned / iActiveManned to bAutomated (= 1) each frame
## [exe 0x49ee10], so all its boostable, intact systems count as manned by an unskilled crew member: weapons charge
## ×0.9, piloting / engines evasion bonus, shields recharge bonus, sensors / doors +1 level.
func crew_level_in(id: String) -> int:
	var s := sys(id)
	if s == null or s.damage > 0 or not is_boostable(id):
		return 0
	if is_automated():
		return 1
	var c := active_manning_crew(id)
	if c == null:
		return 0
	return c.skill_level(MAN_SKILL[id]) if MAN_SKILL.has(id) else 1


## Systems whose manning adds +1 effective power (ShipSystem ctor bLevelBoostable: sensors 7, doors 8).
const LEVEL_BOOSTABLE := ["sensors", "doors"]


## GetEffectivePower's manning term: +1 for a level-boostable system actively manned and fully intact.
## Refreshed every frame from the crew (ShipManager::OnLoop sets iActiveManned).
func update_manning_boost() -> void:
	for id in LEVEL_BOOSTABLE:
		var s := sys(id)
		if s != null:
			s.manning_boost = 1 if crew_level_in(id) > 0 else 0


func is_boostable(id: String) -> bool:
	if id == "pilot":
		var e := sys("engines")
		return e != null and e.effective_power() > 0  # follows "engines functioning"
	if id == "artillery":
		return not is_player  # bBoostable = (iShipId != 0)
	return BOOSTABLE.has(id)


## Any own crew in the system's room who can man it (alive, not stunned) -> bManned. Always true on an automated
## ship (bManned = bAutomated).
func is_manned(id: String) -> bool:
	var s := sys(id)
	if s == null:
		return false
	if is_automated():
		return true
	for c in crew:
		if c.is_alive() and c.stun <= 0.0 and c.room == s.room and not c.is_intruder(self) and not c.is_drone():
			return true
	return false


## Crew member standing idle on the console slot of a system (not moving, repairing or fighting).
func active_manning_crew(id: String) -> CrewMember:
	var s := sys(id)
	if s == null:
		return null
	var console := graph.console_slot(s.room)
	if console < 0:
		return null
	for c in crew:
		if c.is_alive() and c.stun <= 0.0 and c.target_room == s.room and c.slot == console and not c.is_intruder(self) \
				and c.is_on_slot(self) and not c.is_busy() and not c.is_drone():
			return c
	return null


# ------------------------------------------------------------ crew orders

## Player order: every given crew member aboard this ship walks to the room (an order into a full room
## is ignored). The ship's own crew, or the player's boarders on an enemy ship (rules/crew_controls.md).
## Returns how many accepted the order.
func order_crew_move(members: Array, room_id: int) -> int:
	var n := 0
	var movers := members.filter(func(c): return crew.has(c) and (c.player_owned or not c.is_intruder(self)))
	# Rule `crew_move_destination` (rules/hooks.md): [[crew, room], ...] for the order; vanilla = everyone to
	# the clicked room.
	var plan: Array = Hooks.rule(&"crew_move_destination", _vanilla_move_plan, self, movers, room_id)
	for e in plan:
		var c: CrewMember = e[0]
		if c.move_to_room(self, int(e[1])):
			n += 1
	return n


static func _vanilla_move_plan(_ship: ShipState, movers: Array, room_id: int) -> Array:
	return movers.map(func(c): return [c, room_id])


## ShipManager::SaveCrewPositions ("save stations", rules/crew_controls.md): every crew of this side
## (not only the selected ones) aboard remembers its slot (the destination slot while walking).
## `elsewhere` = this side's crew currently aboard another ship: their saved station is cleared.
func save_crew_positions(elsewhere: Array = []) -> void:
	for c in own_crew():
		c.saved_room = c.target_room
		c.saved_slot = c.slot
	for c in elsewhere:
		c.saved_room = -1
		c.saved_slot = -1


## ShipManager::RestoreCrewPositions ("return to stations"): only crew aboard (no mind control yet).
## Every slot is freed, crew with a saved station walk to it, then the others re-take a free slot in
## their current room. Returns true if anyone had a saved station.
func restore_crew_positions() -> bool:
	var movers := own_crew().filter(func(c): return not teleporting.has(c))
	var any := false
	for c in movers:
		c.slot = -1  # free every slot first
	var rest := []
	for c in movers:
		if c.saved_room >= 0 and c.saved_slot >= 0:
			any = true
			var taken := graph.taken_slots(c.saved_room, c, false)
			if not taken.has(c.saved_slot) and c.walk_to_slot(self, c.saved_room, c.saved_slot):
				continue
		rest.append(c)
	for c in rest:
		var room: int = c.room if c.room >= 0 else c.target_room
		var s := graph.find_slot(room, c)
		if s < 0 or not c.walk_to_slot(self, room, s):
			# Room full (should not happen): any free slot of its old destination.
			c.walk_to_slot(self, c.target_room, graph.find_slot(c.target_room, c))
	return any


func selected_crew() -> Array:
	return crew.filter(func(c): return c.selected and c.is_alive())


func deselect_all() -> void:
	for c in crew:
		c.selected = false


## Living crew member whose sprite contains the point (local coordinates), or null.
func crew_at(p: Vector2, radius := 15.0) -> CrewMember:
	var best: CrewMember = null
	var best_d := radius
	for c in crew:
		if not c.is_alive() or c.is_intruder(self):
			continue
		var d := c.pos.distance_to(p)
		if d <= best_d:
			best = c
			best_d = d
	return best


## Crew step = ShipManager::UpdateCrewmembers: first every crew member's OnLoop (attack with the
## target chosen last frame, movement, work, health incl. the medbay rate set last frame) and its new
## medbay rate; then target selection for everyone (so a crew that just arrived is already fighting
## when CrewAI runs).
func _tick_crew(seconds: float) -> void:
	for d in env.doors:
		if d.crew_pass > 0.0:
			d.crew_pass = maxf(d.crew_pass - seconds, 0.0)
	var deaths := false
	# ShipManager::DestroyBoardingDrones (from UpdateCrewmembers while the ship's target is missing or not
	# hostile): the other side's crew drones aboard get -1000 HP. Only with a known non-hostile opponent here
	# (a ship with no opponent at all is a test / sandbox setup).
	if opponent != null and not opponent.hostile:
		for c in crew:
			if c.is_alive() and c.is_drone() and c.player_owned != is_player:  # owner side, not mind control
				c.hp = 0.0
				deaths = true
	for c in crew:
		if not c.is_alive():
			if c.dead_time == 0.0:
				Hooks.emit(&"crew_died", self, c)  # first frame dead (any cause)
			if not c.blast_done and c.race == "energy" and not c.is_drone():
				c.blast_done = true
				if zoltan_blast(c):
					deaths = true
			c.dead_time += seconds
			continue
		c.blast_done = false  # alive again (cloned): the next death explodes again
		c.tick_power(seconds)  # crystal lockdown cooldown (charges while stunned / fighting too)
		c.tick_level_up(seconds)
		if teleporting.has(c):
			continue  # teleport animation: no movement, work, attack or health tick (rules/teleporter.md)
		if c.frozen:
			c.task = CrewMember.Task.NONE
			continue  # unpowered crew drone: frozen in place (rules/drones.md §10)
		if c.stun > 0.0:
			c.stun = maxf(c.stun - seconds, 0.0)
		if CrewCombat.update_attack(self, c, seconds):
			deaths = true
		# CREW_STIMS / DRONE_SPEED of the crew's owner: x1.25 move speed (GetMoveSpeed).
		c.update_movement(self, seconds * AugmentRule.move_mult(AugmentRule.crew_owner(self, c), c))
		c.update_task(self, seconds)
		if c.drone_kind == "boarder_ion":
			CrewCombat.update_ion_drone(self, c, seconds)  # its charge / discharge / door attack (rules/drones.md §9)
		if c.medbay_rate != 0.0:
			var old_hp := c.hp
			c.hp = clampf(c.hp + c.medbay_rate * seconds, 0.0, c.max_hp)
			c.check_low_health_sound(old_hp)  # hacked medbay damages
			if not c.is_alive():
				deaths = true
	if deaths:
		crew_changed()
	_remove_dead_crew()
	MedbayRule.update(self)
	CrewCombat.update_targets(self)
	_refresh_crew_rooms()


## Zoltan death explosion (EnergyAlien::GetRoomDamage -> DamageArea -> DamageCrew, rules/races.md): 15 HP to every
## crew member in the zoltan's room not owned by its side; nothing else. Returns true if someone died.
func zoltan_blast(z: CrewMember) -> bool:
	var killed := false
	for o in crew:
		if o == z or not o.is_alive() or o.room != z.room or o.player_owned == z.player_owned:
			continue
		var old_hp := o.hp
		o.hp = maxf(o.hp - CrewMember.ZOLTAN_BLAST, 0.0)
		o.check_low_health_sound(old_hp)
		if not o.is_alive():
			killed = true
	return killed


## Zoltan bonus power (ShipManager::OnLoop + ShipSystem::SetBonusPower, rules/races.md "Zoltan"): every frame each
## system gets +1 per zoltan of this ship's side standing or walking in its room (`permanent` = those on their slot).
func update_bonus_power() -> void:
	var amount := {}
	var permanent := {}
	for c in crew:
		if c.race != "energy" or c.is_drone() or c.player_owned != is_player or c.room < 0:
			continue
		amount[c.room] = amount.get(c.room, 0) + 1
		if c.is_on_slot(self):
			permanent[c.room] = permanent.get(c.room, 0) + 1
	for s: SystemState in systems.values():
		set_bonus_power(s, amount.get(s.room, 0), permanent.get(s.room, 0))
		if s.bonus_power < s.last_bonus_power:
			check_for_repower(s)  # ShipSystem::OnLoop: the bonus dropped -> CheckForRepower
		s.last_bonus_power = s.bonus_power


## ShipSystem::SetBonusPower (and the WeaponSystem / DroneSystem overrides).
func set_bonus_power(s: SystemState, amount: int, permanent: int) -> void:
	if s.is_subsystem():
		s.bonus_power = 0  # piloting, sensors, doors, battery: bNeedsPower false
		return
	var b := mini(amount, s.max_power())  # never above the working bars; ion / hacking not checked
	if s.id == "weapons" or s.id == "drones":
		s.bonus_power = b
		if s.id == "weapons":
			_update_weapon_bonus(s)
		else:
			DroneSystemRule.update_bonus(self)
		return
	s.bonus_power = b
	# A zoltan standing in the room raises the remembered power wish (one walking through does not).
	var effective := s.power + b
	if s.user_power < effective - maxi(b - permanent, 0):
		s.user_power = effective
	# CheckMaxPower: reactor / battery steps go back while reactor + battery + bonus exceed the usable max.
	if s.power + b > s.max_power():
		_set_power(s, maxi(s.max_power() - b, 0))
		_clamp_shields()


## WeaponSystem::UpdateBonusPower: the bonus is spread in slot order (min(remaining, weapon power)). Powered weapon
## whose bonus grew -> bars back to the reactor; shrank -> depowered and re-powered next frame (repowerList);
## unpowered weapon fully covered by bonus -> powered; over the max -> depower from the last slot.
func _update_weapon_bonus(s: SystemState) -> void:
	for w in weapons:  # repowerList from the previous frame
		if w.has_meta("bonus_repower"):
			w.remove_meta("bonus_repower")
			if not w.powered and not s.is_power_locked():
				try_power_weapon(w)
	var remaining := s.bonus_power
	for w in weapons:
		var nb := mini(remaining, w.power_cost())
		remaining -= nb
		var old := w.bonus_power
		w.bonus_power = nb
		if w.powered and nb < old:
			_set_weapon_powered(w, false)
			w.set_meta("bonus_repower", true)
		elif not w.powered and nb > 0 and nb == w.power_cost() and not s.is_power_locked() \
				and not (w.uses_missiles() and missiles < 1):
			_set_weapon_powered(w, true)
	_check_max_power(s)
	_set_power(s, weapons_power_used())


## Hangar preview (ShipBuilder::OnLoop runs ShipManager::OnLoop on the shown ship): only the crew part matters
## there — the starting crew stand on their consoles and man them, so they play the typing animation.
func tick_crew_only(seconds: float) -> void:
	_tick_crew(seconds)
	update_manning_boost()


## Bodies leave the crew list when the death animation and its fade are over (0.75 s + 1.0 s; crew
## drones: their 1.0 s explosion), ShipManager::UpdateCrewmembers (rules/crew.md "Crew animations"). Crew
## a clonebay will clone are left to ClonebayRule.collect_dead (it takes them at 0.75 s into the queue).
func _remove_dead_crew() -> void:
	var gone := false
	for c in crew.duplicate():
		if c.is_alive():
			continue
		var limit := DRONE_BODY_TIME if c.is_drone() else CrewMember.DEATH_ANIM + CrewMember.DEATH_FADE
		if c.dead_time < limit or (not c.is_drone() and clone_ready(c)):
			continue
		crew.erase(c)
		teleporting.erase(c)
		gone = true
	if gone:
		crew_changed()


## CrewMember clone_ready: its own side's ship has a clonebay installed and it may be cloned.
func clone_ready(c: CrewMember) -> bool:
	if c.has_meta("no_clone"):
		return false
	var home: ShipState = self if c.player_owned == is_player else opponent
	return home != null and home.sys("clonebay") != null


## Skill progress for the crew actively manning a system (player ship only).
func _gain_manning_skill(id: String) -> void:
	if not is_player:
		return
	var c := active_manning_crew(id)
	if c and MAN_SKILL.has(id):
		c.add_skill(MAN_SKILL[id])


## A weapon fired a volley (weapons skill).
func on_weapon_fired() -> void:
	_gain_manning_skill("weapons")


# ------------------------------------------------------------ weapons

func weapons_capacity() -> int:
	var s := sys("weapons")
	return s.max_power() if s else 0


## Reactor + battery bars used by the powered weapons (each costs its power minus its zoltan bonus).
func weapons_power_used() -> int:
	var used := 0
	for w in weapons:
		if w.powered:
			used += w.power_cost() - w.bonus_power
	return used


func _set_weapon_powered(w: WeaponState, on: bool) -> void:
	w.powered = on
	if not on:
		w.clear_target()
	var s := sys("weapons")
	if s:
		_set_power(s, weapons_power_used())


## Try to power a weapon. Returns "ok", "locked", "no_missiles", "no_power" or "reactor".
func try_power_weapon(w: WeaponState) -> String:
	if w.powered:
		return "ok"
	var s := sys("weapons")
	if s == null:
		return "no_power"
	if s.is_power_locked():
		return power_failed("weapons", "locked")
	if w.uses_missiles() and missiles < 1:
		return power_failed("weapons", "no_missiles")
	if weapons_capacity() - weapons_power_used() - s.bonus_power < w.power_cost() - w.bonus_power:
		return power_failed("weapons", "no_power")
	if power_free() < w.power_cost() - w.bonus_power:
		return power_failed("weapons", "reactor")  # WeaponSystem::PowerWeapon -> RawIncreasePower
	_set_weapon_powered(w, true)
	return "ok"


## WeaponSystem::SwapWeapons: slots a and b exchange their weapons. The order is the depower order
## (last slot first, _check_max_power) and the hull mount belongs to the slot (ShipManager::RenderWeapons
## uses GetWeaponMount(slot)), so the weapons also exchange mounts. Returns false if a slot is empty.
func swap_weapons(a: int, b: int) -> bool:
	if a == b or a < 0 or b < 0 or a >= weapons.size() or b >= weapons.size():
		return false
	var wa := weapons[a]
	var wb := weapons[b]
	weapons[a] = wb
	weapons[b] = wa
	var m := wa.mount_index
	wa.mount_index = wb.mount_index
	wb.mount_index = m
	return true


func depower_weapon(w: WeaponState) -> void:
	var s := sys("weapons")
	if s and s.hacked:
		return  # GetLocked: an active hack pulse freezes the system's power
	_set_weapon_powered(w, false)


func set_autofire(on: bool) -> void:
	autofire = on
	for w in weapons:
		w.set_autofire(on)


# ------------------------------------------------------------ geometry

## Room containing the point (local coordinates), or -1.
func room_at(p: Vector2) -> int:
	for r in layout.rooms:
		if room_rect(r.id).has_point(p):
			return r.id
	return -1


func max_shield_layers() -> int:
	return system_power("shields") / 2


## ShipManager::GetOxygenPercentage: round(average room O2), 0 without an oxygen system (rules/crew_ai.md).
func oxygen_percentage() -> int:
	if sys("oxygen") == null:
		return 0
	return roundi(env.average_oxygen())


func dodge_factor() -> int:
	if is_destroyed():
		return 0
	var e := sys("engines")
	var p := sys("pilot")
	if (e and e.hacked) or (p and p.hacked):
		return 0  # GetDodgeFactor: engines or piloting under a hack pulse (rules/hacking.md)
	return int(Hooks.rule(&"evasion", _vanilla_dodge, self))


## Vanilla GetDodgeFactor (default of the `evasion` rule; mods may wrap or replace it).
func _vanilla_dodge(_ship: ShipState = null) -> int:
	return EvasionRule.dodge_factor(system_power("engines"), crew_level_in("engines"),
		crew_level_in("pilot"), system_power("pilot"), is_cloaked(), is_manned("pilot"))


## ShipManager::IsCloaked: the cloaking system is on (rules/cloaking.md).
func is_cloaked() -> bool:
	var c := sys("cloaking")
	return c != null and c.turned_on


const CLOAK_FADE := 0.5  # s, cloakingTracker
const CLOAK_HULL_ALPHA := 0.75


## Hull alpha (Ship::OnRenderBase): cloaked 0.75 x (1 - 0.5 x fade progress); 1.0 at once when not.
func cloak_alpha() -> float:
	if not is_cloaked():
		return 1.0
	return CLOAK_HULL_ALPHA * (1.0 - 0.5 * cloak_fade / CLOAK_FADE)


## Sensors view (ShipManager::OnLoop / UpdateCrewmembers / CheckVision, rules/ship_rendering.md §8): rooms of
## this ship the player cannot see -> {room_id: true}. Own ship: all rooms when the player's sensors are missing,
## under a hack pulse or at 0 power. Enemy ship: all rooms unless the player's sensors give >= 2 power (not
## hacked). Rooms holding player-owned or mind-controlled crew are always seen.
func blacked_out_rooms() -> Dictionary:
	var viewer: ShipState = self if is_player else opponent
	var blind := true
	if viewer != null and viewer.is_player:
		var s := viewer.sys("sensors")
		var p := s.effective_power() if s != null and not s.hacked else 0
		blind = p <= 0 if viewer == self else p < 2
	var out := {}
	if not blind:
		return out
	for r in layout.rooms:
		out[r.id] = true
	for c in crew:
		if c.is_alive() and (c.player_owned or c.mind_controlled):
			out.erase(c.room)
		# Slug telepathy (UpdateCrewmembers tempVision): a player-owned slug reveals the rooms touching its room.
		if c.is_alive() and c.player_owned and c.is_telepathic() and not c.is_drone() and c.room >= 0:
			for n in graph.room_neighbors(c.room):
				out.erase(n)
	# Hacked enemy systems (ShipManager::OnLoop: IsSystemHacked >= 1 on an enemy ship sets tempVision for the
	# system's room; CheckVision un-blacks it): the hacking drone shows the player the room it is attached to.
	if not is_player:
		for hs: SystemState in systems.values():
			if hs.hack_effect() > 0 and hs.room >= 0:
				out.erase(hs.room)
	return out


## Life detection of the player (ShipManager::OnRender, CombatControl::UpdateAiming / UpdateTarget): the player
## ship has a slug crew member (HasEquipment("slug"): species in its crew list, aboard either ship) or LIFE_SCANNER.
## Crew in blacked-out rooms of either ship are then drawn as life signs (outline only, no drones) and mind control
## may target blacked-out rooms. Any ShipState of the fight answers for the player.
func player_detects_life() -> bool:
	var me: ShipState = self if is_player else opponent
	if me == null:
		return false
	if AugmentRule.life_scanner(me):
		return true
	for s: ShipState in [me, me.opponent]:
		if s == null:
			continue
		for c in s.crew:
			if c.player_owned and c.race == "slug" and not c.is_drone() and c.is_alive():
				return true
	return false


## ShipManager::OnRender interior gate: rooms, crew and effects are drawn only for a ship that is not cloaked
## (or the player's own ship), or that has player crew aboard. A cloaked enemy shows only its hull.
## ShipManager::OnRender: the interior (rooms, systems, crew…) of an enemy ship is drawn only while it is
## hostile and not cloaked, or when player crew are aboard; otherwise only bubble, weapons and hull.
func shows_interior() -> bool:
	if is_player or (hostile and not is_cloaked()):
		return true
	for c in crew:
		if c.is_alive() and c.player_owned:
			return true
	return false


## Cloak overlay image alpha = tracker progress (fades out over 0.5 s after decloaking).
func cloak_overlay_alpha() -> float:
	return cloak_fade / CLOAK_FADE


## Ship::GetCloakAlpha(false): 1 − 0.5 × tracker progress (1.0 uncloaked, 0.5 once cloaked, fading both ways over
## 0.5 s). Used for weapon art, the player floor image, thrusters, room floors, O2 stripes, blackout, warning
## lights and doors (rules/cloaking.md "Visuals"). Hull uses `cloak_alpha`, the overlay `cloak_overlay_alpha`.
func cloak_interior_alpha() -> float:
	return 1.0 - 0.5 * cloak_fade / CLOAK_FADE


func is_destroyed() -> bool:
	return hull <= 0


## Ship::DestroyedDone: destroyed and its explosion finished (3 s, player 6 s; rules/ship_destruction.md).
func destroyed_done() -> bool:
	return is_destroyed() and explosion != null and explosion.done


## ShipManager::OnLoop at hull < 1 (rules/ship_destruction.md §1, §5), once: the explosion starts, weapons are
## unpowered (WeaponSystem::ShipDestroyed), shield power goes to 0 (Shields::ShipDestroyed; layers dropped too),
## super shields drained (ShipAI stand-down). Drones / hacking / mind control: Combat._update_deaths.
func on_destroyed() -> void:
	if explosion != null:
		return
	explosion = ShipExplosion.new(blueprint.get("img", ""), blueprint.layout, is_player)
	explosion.start()
	for w in weapons:
		if w.powered:
			_set_weapon_powered(w, false)
	var sh := sys("shields")
	if sh:
		_set_power(sh, 0)
		sh.user_power = 0
	shield_layers = 0
	shield_charger = 0.0
	super_shield = 0
	Combat.log("%s DESTROYED: explosion %.1f s, %d gibs" % [blueprint.name, explosion.duration,
		explosion.gibs.size()])


func room_rect(room_id: int) -> Rect2:
	for r in layout.rooms:
		if r.id == room_id:
			var rr: Rect2i = r.rect
			return Rect2(origin + Vector2(rr.position) * T, Vector2(rr.size) * T)
	return Rect2()


func rooms_bounds() -> Rect2:
	var b := Rect2()
	var first := true
	for r in layout.rooms:
		var rect := room_rect(r.id)
		b = rect if first else b.merge(rect)
		first = false
	return b


func random_room_center(rng: RandomNumberGenerator) -> Vector2:
	var r: Dictionary = layout.rooms[rng.randi() % layout.rooms.size()]
	return room_rect(r.id).get_center()


func hull_position() -> Vector2:
	return origin + layout.img_rect.position


func mount_position(index: int) -> Vector2:
	if index < mounts.size():
		return hull_position() + mounts[index].pos
	return shield_center


func inside_shield(p: Vector2) -> bool:
	var d := (p - shield_center) / shield_axes
	return d.length_squared() <= 1.0


# ------------------------------------------------------------ simulation

func tick(f: float) -> void:
	if is_destroyed():
		# ShipManager::OnLoop on a dying ship runs only Ship::OnLoop (the explosion): everything else is frozen.
		on_destroyed()
		explosion.step(f, rooms_bounds())
		return
	var seconds := f / GameClock.BASE
	# ShipManager::OnLoop: door / room hack levels rebuilt from the hacked systems (SetHackLevel), plus the
	# SetHackingLevel transitions of shields, teleporter and mind control (rules/hacking.md).
	HackingRule.update_ship(self)
	_tick_crew(seconds)
	loop_system_progress()
	if is_automated():
		_auto_repair(seconds)
	update_manning_boost()
	update_bonus_power()  # zoltans (rules/races.md)
	LockdownRule.tick(self, seconds)  # crystal lockdown shards
	for s in systems.values():
		if s.tick_ion(seconds):
			_on_unlocked(s)
	HackingRule.tick(self, seconds)
	MindRule.tick(self, seconds)
	DroneSystemRule.tick(self, seconds)
	CloakRule.tick(self, seconds)
	# ShipManager::SetTarget -> ProjectileFactory::SetCurrentShip: the target ship (none once the enemy is gone).
	var cur_target: ShipState = opponent if opponent != null and not opponent.destroyed_done() else null
	for w in weapons:
		w.set_current_ship(cur_target)
	var wlevel := crew_level_in("weapons")
	# ProjectileFactory::Update: a weapon whose target ship is cloaked does not charge (frozen); the
	# hacked-weapon discharge still runs.
	var ws := sys("weapons")
	var whacked := ws != null and ws.hacked
	if not opponent_cloaked() or whacked:
		var rate := AugmentRule.charge_mult(self)  # AUTO_COOLDOWN
		for w in weapons:
			var was := w.is_charged(wlevel)
			w.tick(f, wlevel, whacked, rate)
			if not was and w.is_charged(wlevel):
				Hooks.emit(&"weapon_charged", self, w)
	ArtilleryRule.tick(self, f)
	_tick_shield_anims(seconds)
	_tick_shields(f)
	env.tick(seconds)
	_check_exploded()  # sabotage (crew tick) / fire (env tick) finished off a system: hull -1
	AugmentRule.tick(self, seconds)  # SLUG_GEL, FIRE_EXTINGUISHERS, opponent's HACKING_STUN
	BatteryRule.tick(self, seconds)  # ends with ShipManager::CheckBatteryPower
	_check_reactor()
	cloak_fade = clampf(cloak_fade + (seconds if is_cloaked() else -seconds), 0.0, CLOAK_FADE)
	update_engine_sound()


## ShipManager::OnLoop (0x004a1ddb): `enginesOff` on the player ship when GetDodgeFactor drops from > 0 to 0
## (lastEngineStatus starts false, so a ship that starts with no evasion stays silent). Nothing plays on the way
## back up: `enginesOn` (sounds.xml) is referenced nowhere in the exe (rules/evasion.md). Returns true when it played.
func update_engine_sound() -> bool:
	var on := dodge_factor() > 0
	var off := is_player and last_engine_status and not on
	if off:
		FtlData.play("enginesOff")
	last_engine_status = on
	return off


## ShipManager::OnLoop (0x004a1ce0), after the jump timer step: `jumpReady` once when jump_timer becomes full
## (lastJumpReady false -> true). Any ship in the exe, but only the player's timer ever fills (an enemy keeps
## its fuel 16 and never charges). Called by RunState.tick after FtlDrive.tick. Returns true when it played.
func update_jump_ready_sound() -> bool:
	var ready := ftl_charge >= 1.0
	var rang := ready and not last_jump_ready
	if rang:
		FtlData.play("jumpReady")
	last_jump_ready = ready
	return rang


## ShipManager::OnLoop crew counts -> ShipSystem bOccupied (live intruders in the room) / bFriendlies (live
## non-intruders, drones included), then the progress part of ShipSystem::OnLoop (SystemState.loop_progress).
func loop_system_progress() -> void:
	var intruders := {}
	var friends := {}
	for c in crew:
		if c.is_alive() and c.room >= 0:
			if c.is_intruder(self):
				intruders[c.room] = true
			else:
				friends[c.room] = true
	for s in systems.values():
		s.occupied = intruders.has(s.room)
		s.friendlies = friends.has(s.room)
		s.loop_progress()


## ShipManager::OnLoop, per system after ShipSystem::OnLoop: a system that NeedsRepairing on an automated ship gets
## PartialRepair(1.0, autoRepair = true) every frame [exe 0x4a05b0]: 1.0 × 0.5 × factor (8 /s) ÷ 3 (autoRepair),
## × 0.5 while under a hacking attack -> one bar per 37.5 s, every damaged system at once.
const AUTO_REPAIR_RATE := 8.0 / 3.0


func _auto_repair(seconds: float) -> void:
	for s in systems.values():
		if s.damage > 0 and s.partial_repair(AUTO_REPAIR_RATE * seconds * (0.5 if s.under_attack else 1.0)):
			repair_system(s.id, 1)


func opponent_cloaked() -> bool:
	return opponent != null and opponent.is_cloaked()


## Reactor overuse (rules/power.md "Reactor"): while more reactor bars are in use than available, one
## bar is removed from a random system (weapons: the last powered weapon).
func _check_reactor() -> void:
	var guard := 0
	while reactor_free() < 0 and guard < 100:
		guard += 1
		var cands := []
		for s in systems.values():
			if s.uses_reactor() and s.power - s.battery > 0 and not s.is_locked():
				cands.append(s)
		if cands.is_empty():
			return
		var s: SystemState = cands[rng.randi() % cands.size()]
		if s.id == "weapons":
			for i in range(weapons.size() - 1, -1, -1):
				if weapons[i].powered:
					_set_weapon_powered(weapons[i], false)
					break
		elif s.id == "drones":
			DroneSystemRule.depower_last(self)
		else:
			s.power -= 1  # a reactor bar (battery bars stay on top)
			s.battery = mini(s.battery, s.power)
			_clamp_shields()


## When ion ends, normal systems regain the power they had; weapons and drones do not.
func _on_unlocked(s: SystemState) -> void:
	check_for_repower(s)


## ShipSystem::CheckForRepower (rules/power.md "Automatic re-power"): give the system back the power the
## player had set (`user_power`), one step at a time. Runs after each repaired bar, when an ion/lock ends,
## when bonus power drops and when an event power loss is removed. If the REACTOR refuses a step, the
## system FORGETS the rest: user_power becomes the current power, so later repairs never re-power it.
func check_for_repower(s: SystemState) -> void:
	if s == null or s.id == "weapons" or s.id == "drones" or not s.uses_reactor():
		return
	while true:
		# Wish and room in effective units (reactor + battery + zoltan bonus).
		if s.power + s.bonus_power >= s.user_power or s.is_power_locked():
			return
		var room := s.max_power() - s.power - s.bonus_power  # usable bars not yet powered
		if room <= 0:
			return  # nothing usable yet (still damaged): keep the wish for the next repaired bar
		if s.id == "shields" and room < 2 - ((s.power + s.bonus_power) & 1):
			return  # shields need a whole layer's worth before trying
		Hooks.emit(&"repower_attempted", self, s.id)
		var r := increase_power(s.id, false)  # a reactor refusal sets failed_powerup -> NOT ENOUGH POWER
		if r != "ok":
			s.user_power = s.power + s.bonus_power  # reactor full: the wish is dropped (lastUserPower = current)
			Hooks.emit(&"repower_failed", self, s.id, r)
			return


func _tick_shields(f: float) -> void:
	SuperShieldRule.loop(self)  # Shields::OnLoop: ENERGY_SHIELD fill (5 on the first frame, no recharge)
	_normalize_shields()
	var mx := max_shield_layers()
	_check_shields_collapse(mx)
	var sh := sys("shields")
	if sh and sh.hacked:
		# Shields::OnLoop under a hack pulse: no recharge; the charger counts down 1/s from 2.0 and every
		# time it reaches 0 a layer is lost (1 layer / 2 s). A partial charge present when the pulse started
		# is drained first without losing a layer (bExcessChargeHack).
		shield_layers = mini(shield_layers, mx)
		shield_charger -= f / GameClock.BASE
		if shield_charger <= 0.0:
			if not shield_excess_hack:
				shield_layers = maxi(shield_layers - 1, 0)
			shield_excess_hack = false
			shield_charger = SHIELD_CHARGE_TIME
		return
	if shield_layers >= mx:
		shield_layers = mx
		shield_charger = 0.0
		return
	var layers_factor := 1.0 + maxf(shield_layers - 1, 0) / 6.0
	var skill := EvasionRule.skill_bonus(EvasionRule.Skill.SHIELDS, crew_level_in("shields"))
	shield_charger += skill * AugmentRule.shield_recharge_mult(self) * f * layers_factor * 0.0625  # SHIELD_RECHARGE
	if shield_charger > SHIELD_CHARGE_TIME:
		if shield_layers == 0:  # first layer after none: bubble scale-in + sound (layer 1 -> 2 etc.: neither)
			shield_up_t = 0.0
			shield_sound("shieldsUp")
		shield_layers += 1
		shield_charger = 0.0


## Evasion roll (ShipManager::GetDodged; also used by bombs): a dodge trains pilot and engines.
func roll_dodged(rng: RandomNumberGenerator) -> bool:
	if EvasionRule.roll_dodge(dodge_factor(), rng):
		_gain_manning_skill("pilot")
		_gain_manning_skill("engines")
		Hooks.emit(&"dodge_rolled", self, true)
		return true
	Hooks.emit(&"dodge_rolled", self, false)  # ACH_BAD_DODGING (AchievementTracker)
	return false


## A projectile crosses the shield edge. Returns "miss", "shield" or "pass".
## `at` = the crossing point (ship-local) for the layer-pop dissolve (default: the shield centre).
func on_projectile_enters_shield(d: Damage, rng: RandomNumberGenerator, at := Vector2.INF) -> String:
	if roll_dodged(rng):
		return "miss"
	var p := at if at != Vector2.INF else shield_center
	if super_shield > 0:
		var h := SuperShieldRule.hit(self, d, rng)  # damage + 2 x ion (ION_ARMOR: ion part 0)
		if int(h.lost) > 0:
			shield_popped(p, true)
		return "super"
	if shield_layers > d.shield_piercing:
		_gain_manning_skill("shields")
		# ION_ARMOR (Shields::CollisionReal): the ion part of a shield hit is ignored on a successful roll.
		shield_ion_resisted = d.ion > 0 and AugmentRule.ion_resist(self, rng)
		if shield_ion_resisted:
			Hooks.emit(&"augment_resisted", self, "ION_ARMOR", -1)
		if d.damage > 0:  # only damage removes a layer; ion is handled separately (shield_absorb)
			shield_layers -= 1
			shield_charger = 0.0
			shield_popped(p, false)
		return "shield"
	return "pass"


## Shields::CollisionReal with super-shield layers: the projectile is absorbed and the super shield
## loses damage + 2 x ion (never below 0); normal layers are untouched.
func damage_super_shield(amount: int) -> void:
	super_shield = maxi(super_shield - maxi(amount, 0), 0)


## Shields::AddSuperShield: +1 layer (max 5; the maximum becomes 5 the first time).
## With a location (the drone, ship-local) the superShieldUp wave starts there.
func add_super_shield(loc := Vector2.INF) -> void:
	super_shield = mini(super_shield + 1, Drone.SUPER_SHIELD_MAX)
	if super_shield_max == 0:
		super_shield_max = Drone.SUPER_SHIELD_MAX
	if loc != Vector2.INF:
		super_up_t = 0.0
		super_up_loc = loc
		Combat.log("%s: super shield %d, wave from %s" % [blueprint.get("name", "?"), super_shield, loc])


## ShipSystem::DamageOverTime reaching 100 (fire: ShipManager::CheckSpreadDamage; sabotage: CrewMember::UpdateRepair
## -> ShipSystem::PartialDamage(0.5)): one bar breaks (AddDamage(1)) and bExploded = "it was not completely destroyed
## before and is now" (healthState.first == 0). The flag costs the ship 1 hull in `_check_exploded`
## (rules/damage.md "System explosion"). Weapon / event damage (DamageSystem -> AddDamage) never sets it.
func damage_system_over_time(s: SystemState) -> void:
	if s == null:
		return
	var was_destroyed := s.damage >= s.get_level()
	damage_system(s.id, 1)
	s.exploded = not was_destroyed and s.damage >= s.get_level()


## ShipManager::OnLoop, per system: ShipSystem::GetExploded (returns and clears bExploded) -> DamageHull(1, force =
## false) (0 while the ship is jumping), plus a "1" DamageMessage at the room centre, the explosion1 animation there
## and sound sysExplosion (queued in `pending_explosions` for Combat). At 1 hull this destroys the ship.
func _check_exploded() -> void:
	for s in systems.values():
		if not s.exploded:
			continue
		s.exploded = false
		if not jumping:
			take_hull_damage(1)
		pending_explosions.append(s.room)
		Combat.log("%s: %s completely destroyed by damage over time, hull -1 (%d)" % [blueprint.get("name", "?"),
			s.id, hull])


## ShipSystem::LockSystem(0): clears the lock counter (cooldown, ion or the indefinite -1) and, if there was one,
## CheckForRepower (skipped for weapons / drones).
func force_unlock(s: SystemState) -> void:
	if s == null or s.ion == 0:
		return
	s.lock_system(0)
	_on_unlocked(s)


## ShipManager::SetSafe (WorldManager::OnLoop, every frame with no hostile ship and not HostileEnvironment; RunState):
## bWasSafe, FTL drive full, TeleportSystem::ForceReady (LockSystem(0)), CloakingSystem / BatterySystem::ForceReady
## (LockSystem(0) only while the lock count is > 0, so a running cloak / battery (-1) is not cut short). Nothing else:
## mind control, hacking, drones, weapons, artillery and every other lock (ion) keep running on their own timers.
func set_safe() -> void:
	was_safe = true
	ftl_charge = 1.0
	force_unlock(sys("teleporter"))
	for id in ["cloaking", "battery"]:
		var s := sys(id)
		if s != null and s.ion > 0:
			force_unlock(s)


## ShipManager::JumpArrive (only when bWasSafe was set at the beacon just left) and ShipManager::Wait (always):
## MindSystem::ForceReady and LockSystem(0) on shields, engines, weapons and piloting (clears their ion locks).
## Then bWasSafe = false.
func arrive_locks(force := false) -> void:
	if was_safe or force:
		for id in ["mind", "shields", "engines", "weapons", "pilot"]:
			force_unlock(sys(id))
	was_safe = false


func take_hull_damage(amount: int) -> void:
	var a: Variant = Hooks.filter(&"damage_hull", amount, self)
	if Hooks.is_cancel(a):
		return
	hull = clampi(hull - int(a), 0, max_hull)
	last_damage = int(a)  # iLastDamage = the damage dealt (DamageArea / DamageBeam: not clamped to the hull left)


# ------------------------------------------------------------ hits (rules/damage.md)

func system_in_room(room_id: int) -> SystemState:
	for s in systems.values():
		if s.room == room_id:
			return s
	return null


func room_tiles(room_id: int) -> int:
	var r := room_rect(room_id)
	return int(r.size.x / T) * int(r.size.y / T)


## Apply a hit to a room. Returns a summary for floating numbers and the log.
func apply_damage(room_id: int, d: Damage, rng: RandomNumberGenerator) -> Dictionary:
	var out := {"room": room_id, "hull": 0, "system": 0, "ion": 0, "crew": 0, "fire": false, "breach": false,
		"resisted": []}
	if room_id < 0 or is_destroyed():
		return out
	# 1. Crew in the room
	for c in crew:
		if c.room != room_id or not c.is_alive():
			continue
		_damage_crew_member(c, d, rng)
		out.crew += 1
	_refresh_crew_rooms()
	# ResistDamage, rolled once per hit before fire / breach (ROCK_ARMOR hull, SYSTEM_CASING system; §2).
	var hull_resist := AugmentRule.resist(self, "ROCK_ARMOR", rng)
	var sys_resist := AugmentRule.resist(self, "SYSTEM_CASING", rng)
	# 2. Fire (2 random tiles) or else a breach (1 unbreached tile) — mutually exclusive
	if rng.randi() % 10 < d.fire_chance:
		for i in 2:
			ignite(room_id, rng.randi() % room_tiles(room_id))
		out.fire = true
	elif rng.randi() % 10 < d.breach_chance:
		var free := []
		for t in room_tiles(room_id):
			if not breaches.get(room_id, {}).has(t):
				free.append(t)
		if hull_resist and d.breach_chance < 10:
			free.clear()  # ROCK_ARMOR also blocks a rolled breach (unless breachChance 10)
		if not free.is_empty():
			add_breach(room_id, free[rng.randi() % free.size()])
			out.breach = true
			hull_resist = false  # the breach went through: the hull resist is void
	# 3. The room's system
	var s := system_in_room(room_id)
	if s:
		var sd := d.system_damage()
		if sd > 0 and sys_resist:
			out.resisted.append("SYSTEM_CASING")
		elif sd > 0:
			damage_system(s.id, sd)
			out.system = sd
		elif sd < 0:
			repair_system(s.id, -sd)  # BOMB_HEAL_SYSTEM (sysDamage -8) [inferred]
		if d.ion > 0 and AugmentRule.ion_resist(self, rng):
			out.resisted.append("ION_ARMOR")  # DamageSystem: the ion damage to the system is 0
		elif d.ion > 0:
			ion_system(s.id, d.ion)
			out.ion = d.ion
	# 4. Hull (x2 with hullBust in a room without a system)
	if d.damage > 0 and hull_resist:
		out.resisted.append("ROCK_ARMOR")
	elif d.damage > 0:
		var hull_dmg := d.damage * (2 if d.hull_bust and s == null else 1)
		take_hull_damage(hull_dmg)
		out.hull = hull_dmg
		AugmentRule.crystal_check(self, room_rect(room_id).get_center(), rng)  # CRYSTAL_SHARDS
	for id in out.resisted:
		Hooks.emit(&"augment_resisted", self, id, room_id)
	# 5. Lockdown (BOMB_LOCK: Ship::LockdownRoom from the room centre, rules/races.md "Crystal").
	out["lockdown"] = d.lockdown
	if d.lockdown:
		LockdownRule.lockdown_room(self, room_id, room_rect(room_id).get_center())
	Hooks.emit(&"room_damaged", self, room_id, out)
	return out


## One crew member hit by `d` (ShipManager::DamageCrew): stun, stun roll, then damage / heal per the
## owner rules of Damage.crew_hp_change.
func _damage_crew_member(c: CrewMember, d: Damage, rng: RandomNumberGenerator) -> void:
	if d.owner >= 0 and not d.friendly_fire and (d.owner == 0) == c.player_owned:
		return
	c.stun = maxf(c.stun, d.stun)
	if rng.randi() % 10 < d.stun_chance:
		c.stun = maxf(c.stun, STUN_MIN)
	var hp: Variant = Hooks.filter(&"damage_crew", d.crew_hp_change(c.player_owned), c, self, d)
	if Hooks.is_cancel(hp):
		return
	var old_hp := c.hp
	c.hp = clampf(c.hp - float(hp), 0.0, c.max_hp)
	c.check_low_health_sound(old_hp)
	Hooks.emit(&"crew_damaged", self, c, float(hp))


## Tile index of a point inside a room (row-major, like tile_center), or -1.
func tile_at(room_id: int, p: Vector2) -> int:
	var r := room_rect(room_id)
	if room_id < 0 or not r.has_point(p):
		return -1
	var w := int(r.size.x / T)
	return int((p.y - r.position.y) / T) * w + int((p.x - r.position.x) / T)


## Beam damage between two consecutive sweep points (ShipManager::DamageBeam, rules/weapons.md):
## entering a new room -> system and hull damage once for that room; entering a new tile -> fire roll
## (that tile), breach roll (that tile) and damage to the crew standing on that tile.
## `last_room` / `last_tile`: where the previous point was (-1 = nowhere). Returns a summary.
func apply_beam(p: Vector2, last_room: int, last_tile: int, d: Damage, rng: RandomNumberGenerator) -> Dictionary:
	var out := {"room": -1, "tile": -1, "hull": 0, "system": 0, "ion": 0, "crew": 0, "fire": false,
		"breach": false, "new_room": false, "resisted": []}
	if is_destroyed() or not hostile:
		return out
	var room_id := room_at(p)
	if room_id < 0:
		return out
	var tile := tile_at(room_id, p)
	out.room = room_id
	out.tile = tile
	if room_id != last_room:
		out.new_room = true
		# ResistDamage once per room entered (DamageBeam): ROCK_ARMOR hull, SYSTEM_CASING system.
		var hull_resist := AugmentRule.resist(self, "ROCK_ARMOR", rng)
		var sys_resist := AugmentRule.resist(self, "SYSTEM_CASING", rng)
		var s := system_in_room(room_id)
		if s:
			var sd := d.system_damage()
			if sd > 0 and sys_resist:
				out.resisted.append("SYSTEM_CASING")
			elif sd > 0:
				damage_system(s.id, sd)
				out.system = sd
			if d.ion > 0 and AugmentRule.ion_resist(self, rng):
				out.resisted.append("ION_ARMOR")
			elif d.ion > 0:
				ion_system(s.id, d.ion)
				out.ion = d.ion
		if d.damage > 0 and hull_resist:
			out.resisted.append("ROCK_ARMOR")
		elif d.damage > 0:
			var hull_dmg := d.damage * (2 if d.hull_bust and s == null else 1)
			take_hull_damage(hull_dmg)
			out.hull = hull_dmg
			AugmentRule.crystal_check(self, p, rng)  # CRYSTAL_SHARDS
		for id in out.resisted:
			Hooks.emit(&"augment_resisted", self, id, room_id)
	if room_id != last_room or tile != last_tile:
		if rng.randi() % 10 < d.fire_chance:
			ignite(room_id, tile)
			out.fire = true
		if rng.randi() % 10 < d.breach_chance and not breaches.get(room_id, {}).has(tile):
			add_breach(room_id, tile)
			out.breach = true
		for c in crew:
			if c.is_alive() and c.room == room_id and tile_at(room_id, c.pos) == tile:
				_damage_crew_member(c, d, rng)
				out.crew += 1
				if not c.is_alive():
					out["killed"] = int(out.get("killed", 0)) + 1  # DamageBeam killedByBeam (ACH_SLUG_BIO)
		_refresh_crew_rooms()
	return out


## Projectile absorbed by the shield: ions go to the shields system (the collision already removed the layer).
func shield_absorb(d: Damage) -> void:
	if d.ion > 0 and not shield_ion_resisted:
		ion_system("shields", d.ion)
	shield_ion_resisted = false


## Start a fire on a tile (Fire::Spread = SetDamage(100)): a tile already burning is back at full health (a
## partly extinguished fire hit again starts over); its burn-out timer is kept.
func ignite(room_id: int, tile: int) -> void:
	if not fires.has(room_id):
		fires[room_id] = {}
	if fires[room_id].has(tile):
		fires[room_id][tile].health = REPAIRABLE_HEALTH
	else:
		fires[room_id][tile] = {"death": -1.0, "health": REPAIRABLE_HEALTH}


## Put out a fire tile (crew extinguished it).
func extinguish(room_id: int, tile: int) -> void:
	if fires.has(room_id):
		fires[room_id].erase(tile)
		if fires[room_id].is_empty():
			fires.erase(room_id)
	env.spread_timers.erase(env.tile_global(room_id, tile))


## Open a hull breach on a tile (if one is already there, nothing changes).
func add_breach(room_id: int, tile: int) -> void:
	if not breaches.has(room_id):
		breaches[room_id] = {}
	if not breaches[room_id].has(tile):
		breaches[room_id][tile] = {"health": REPAIRABLE_HEALTH}
		# Ship::BreachSpecificHull / BreachRandomHull: a new breach in a room with air plays "airLoss" (then the
		# caller's "hullBreach").
		if env.oxygen.get(room_id, 0.0) > 0.0:
			env.play_sound("airLoss")


## Close a breach (crew repaired it).
func seal_breach(room_id: int, tile: int) -> void:
	if breaches.has(room_id):
		breaches[room_id].erase(tile)
		if breaches[room_id].is_empty():
			breaches.erase(room_id)


## Call when crew health changes (deaths).
func crew_changed() -> void:
	for c in crew:
		if not c.is_alive():
			c.selected = false
			c.path.clear()
			c.state = CrewMember.State.IDLE
			c.task = CrewMember.Task.NONE
			c.target = null
			c.fighting = false
			c.blocking_door = -1
	_refresh_crew_rooms()


func _refresh_crew_rooms() -> void:
	crew_rooms.clear()
	for c in crew:
		if c.is_alive() and not crew_rooms.has(c.room):
			crew_rooms.append(c.room)


## Center of tile `tile` (row-major index) of a room.
func tile_center(room_id: int, tile: int) -> Vector2:
	var r := room_rect(room_id)
	var w := int(r.size.x / T)
	return r.position + Vector2((tile % w) + 0.5, (tile / w) + 0.5) * T


## ShipManager::GetLastDamage: returns iLastDamage and clears it.
func take_last_damage() -> int:
	var d := last_damage
	last_damage = 0
	return d
