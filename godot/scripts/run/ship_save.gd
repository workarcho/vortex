class_name ShipSave
extends RefCounted
## Ship snapshot for the run save (rules/save_and_profile.md §1.3). ShipState is not saved field by field: a fresh
## ShipState is built from the blueprint (layout, graph, mounts, ellipse ... come from the data) and the saved
## state is put back over it:
## - ship: the SHIP_FIELDS (hull, resources, reactor, shields, fires, breaches, augments, ...), its crew-combat RNG;
## - systems: every SystemState by id (generic: all its script variables, SaveCodec), installed ones re-created;
## - weapons / artillery: blueprint name + their WeaponState variables (targets and volleys in flight dropped);
## - drones: blueprint name, powered / deployed, rebuild timer; deployed drones are re-deployed by `redeploy` once
##   the scene has its combat (crew drones spawn again, space drones start from their ship);
## - crew (both sides, this ship's crew list order) and the clone queue: race / side + every CrewMember variable
##   except the transient combat ones (CREW_SKIP); each one is put back on its own slot (a walk in progress ends on
##   the slot it was heading to);
## - environment: oxygen per room, door states, fire spread timers.
## Not saved (vanilla saves some of these): projectiles in flight, drone flight paths, hacking / mind control pulses,
## crew fights and crystal lockdown shards. A mid-combat save resumes the fight with the ships as they were.

const SHIP_FIELDS := ["ship_title", "hull", "max_hull", "shield_layers", "shield_charger", "weapon_slots",
	"missiles", "fuel", "scrap", "ftl_charge", "autofire", "fires", "breaches", "fire_heading", "reactor_max",
	"reactor_divide", "battery_cap", "augments", "drone_parts", "drone_slots", "super_shield", "super_shield_max",
	"hostile", "cloak_fade", "clone_death_timer", "missiles_saved"]
const WEAPON_SKIP := ["bp", "target_ship", "target_room", "target_point", "target_point2", "pending_points",
	"queued_shots", "shot_timer", "volley_entry_angle", "volley_target", "volley_point", "volley_points",
	"volley_shot", "anim", "fire_anim", "beam_level", "fire_when_ready"]
const CREW_SKIP := ["path", "state", "task", "fire_tile", "selected", "hovered", "_crossing_door", "target",
	"blocking_door", "fighting", "shared_spot", "shoot_timer", "shoot_goal", "punch_time", "punch_goal",
	"punch_hit", "shots", "damage_done", "aim", "shoot_anim", "shot_frame_done", "shots_fired", "medbay_rate",
	"death_sound_done", "last_shots_fired", "drone", "frozen", "skill_up", "resisted", "level_up", "last_level_up"]


static func snapshot(ship: ShipState) -> Dictionary:
	var d := {"blueprint": String(ship.blueprint.get("name", "")), "player": ship.is_player, "fields": {},
		"rng": SaveCodec.rng_state(ship.rng)}
	for f in SHIP_FIELDS:
		d.fields[f] = SaveCodec.encode(ship.get(f))
	var systems := {}
	for id in ship.systems:
		systems[id] = SaveCodec.props_of(ship.systems[id], ["hacked", "sound_effect"])
	d.systems = systems
	d.weapons = ship.weapons.map(func(w): return _weapon(w))
	d.artillery = ship.artillery.map(func(w): return _weapon(w))
	d.drones = ship.drones.map(func(dr): return {"name": String(dr.bp.get("name", "")), "powered": dr.powered,
		"deployed": dr.deployed, "destroyed_timer": dr.destroyed_timer, "slot": dr.slot})
	var crew := []
	for c in ship.crew:
		if c.is_drone():
			continue  # crew drones come back with their drone (redeploy)
		crew.append(crew_snapshot(c))
	d.crew = crew
	d.clone_queue = ship.clone_queue.map(func(c): return crew_snapshot(c))
	d.oxygen = ship.env.oxygen.duplicate()
	d.doors = SaveCodec.encode(ship.env.doors)
	d.spread = ship.env.spread_timers.duplicate()
	return d


static func _weapon(w: WeaponState) -> Dictionary:
	return {"name": String(w.bp.get("name", "")), "p": SaveCodec.props_of(w, WEAPON_SKIP)}


static func crew_snapshot(c: CrewMember) -> Dictionary:
	return {"race": c.race, "player_owned": c.player_owned, "p": SaveCodec.props_of(c, CREW_SKIP)}


## A new player ship from a snapshot.
static func restore(d: Dictionary) -> ShipState:
	var keep := SaveCodec.rng_state(CrewIdentity.rng)  # the constructor rolls names for the blueprint crew
	var ship := ShipState.new(String(d.blueprint), bool(d.get("player", true)))
	SaveCodec.set_rng(CrewIdentity.rng, keep)
	apply(ship, d)
	return ship


## Puts a snapshot over a ship built from the same blueprint (the enemy: ShipGenerator plan applied first).
static func apply(ship: ShipState, d: Dictionary) -> void:
	for f in d.get("fields", {}):
		SaveCodec.decode_into(ship, String(f), d.fields[f])
	SaveCodec.set_rng(ship.rng, d.get("rng"))
	# Systems: exactly the saved set (store purchases add systems, the clonebay replaces the medbay).
	var systems := {}
	for id in d.get("systems", {}):
		var p: Dictionary = d.systems[id]
		var s := SystemState.new(String(id), int(p.get("room", -1)), int(p.get("level", 0)))
		SaveCodec.set_props(s, p)
		systems[id] = s
	ship.systems = systems
	# Weapons / artillery.
	var weapons: Array[WeaponState] = []
	for wd in d.get("weapons", []):
		var bp := FtlData.weapon_blueprint(String(wd.name))
		if bp.is_empty():
			continue
		var w := WeaponState.new(bp, 0)
		SaveCodec.set_props(w, wd.p)
		weapons.append(w)
	ship.weapons = weapons
	var arts: Array = d.get("artillery", [])
	for i in mini(arts.size(), ship.artillery.size()):
		SaveCodec.set_props(ship.artillery[i], arts[i].p)
	# Drones: rebuilt unpowered and undeployed; `redeploy` brings the deployed ones back.
	for dr in ship.drones:
		if dr.deployed:
			DroneSystemRule.set_deployed(ship, dr, false)
	var drones: Array[Drone] = []
	var pending := []
	for dd in d.get("drones", []):
		var bp := FtlData.drone_blueprint(String(dd.name))
		if bp.is_empty():
			continue
		var dr := Drone.new(bp, ship, drones.size())
		dr.destroyed_timer = float(dd.get("destroyed_timer", 0.0))
		drones.append(dr)
		if bool(dd.get("powered", false)):
			pending.append([dr, bool(dd.get("deployed", false))])
	ship.drones = drones
	ship.set_meta(&"save_drones", pending)
	# Crew.
	ship.crew.clear()
	ship.clone_queue.clear()
	ship.teleporting.clear()
	for cd in d.get("crew", []):
		var c := crew_restore(cd)
		ship.crew.append(c)
	for cd in d.get("clone_queue", []):
		ship.clone_queue.append(crew_restore(cd))
	for c in ship.crew:
		_seat(ship, c)
	# Environment.
	for r in d.get("oxygen", {}):
		ship.env.oxygen[r] = float(d.oxygen[r])
	var doors: Variant = SaveCodec.decode(d.get("doors", []))
	if doors is Array and (doors as Array).size() == ship.env.doors.size():
		ship.env.doors = doors
	var spread: Dictionary = d.get("spread", {})
	ship.env.spread_timers = spread.duplicate()
	ship.crew_changed()
	ship._refresh_crew_rooms()
	ship.update_manning_boost()


static func crew_restore(cd: Dictionary) -> CrewMember:
	var c := CrewMember.new(String(cd.race), bool(cd.player_owned))
	SaveCodec.set_props(c, cd.p)
	return c


## The crew member stands on its reserved slot (the slot it was walking to); a slot taken in the meantime (or
## missing) is replaced by the first free one of the room, else of any room.
static func _seat(ship: ShipState, c: CrewMember) -> void:
	if not c.is_alive():
		return
	var room := c.target_room if c.target_room >= 0 else c.room
	var slot := c.slot
	c.slot = -1
	if room < 0 or slot < 0 or slot >= ship.graph.slot_count(room) or _slot_taken(ship, c, room, slot):
		slot = ship.graph.find_slot(room, c) if room >= 0 else -1
		if slot < 0:
			for r in ship.layout.rooms:
				slot = ship.graph.find_slot(r.id, c)
				if slot >= 0:
					room = r.id
					break
	if slot < 0:
		return
	c.place(ship, room, slot)


static func _slot_taken(ship: ShipState, who: CrewMember, room: int, slot: int) -> bool:
	for o in ship.crew:
		if o != who and o.is_alive() and o.target_room == room and o.slot == slot \
				and o.is_intruder(ship) == who.is_intruder(ship):
			return true
	return false


## After the scene built the combat (opponents set): drones that were powered are powered again — a deployed one
## for free (the part was paid before the save), the others like a click (one part each, as they were).
static func redeploy(ship: ShipState) -> void:
	if not ship.has_meta(&"save_drones"):
		return
	var pending: Array = ship.get_meta(&"save_drones")
	ship.remove_meta(&"save_drones")
	for pd in pending:
		var dr: Drone = pd[0]
		if not ship.drones.has(dr):
			continue
		if bool(pd[1]):
			ship.drone_parts += 1  # deployed before the save: no new part
		if DroneSystemRule.power_drone(ship, dr) != "ok" and bool(pd[1]):
			ship.drone_parts -= 1
