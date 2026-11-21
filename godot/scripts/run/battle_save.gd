class_name BattleSave
extends RefCounted
## The battle part of the run save (rules/save_and_profile.md §1.4): what WorldManager::SaveGame writes after the
## ships so a mid-fight Save+Quit resumes exactly — SpaceManager::SaveSpace (every projectile in flight),
## ShipManager::ExportBattleState (drones in space, hacking, mind control, weapon factories with their targets and
## queued volley shots), the Shields / Ship::SaveState parts of ExportShip that ShipSave leaves out (shield up / down
## animations, crystal lockdown shards), CompleteShip::SaveState / CrewMember::SaveState (crew teleporting) and
## ShipAI::Save. Vanilla drops (so do we): anti-personnel drone shots (CrewLaser: GetType 0, written as type 0 and
## not loaded), crew fights in progress (re-acquired from positions), shield hit ripples, damage numbers, smoke.
##
## Objects are written as references the loader resolves in the rebuilt scene:
## ShipState {"__ship": key}, Space {"__space": key}, WeaponState {"__weapon": [key, "w" | "a" | "d", index]},
## Drone {"__drone": [key, index | "hack"]}, CrewMember {"__crew": [key, index among the non-drone crew of the
## ship it stands on]} / crew drone {"__crew": [owner key, "d", drone index]}, SystemState {"__sys": [key, id]},
## Damage {"__dmg": props}, Texture2D {"__tex": FtlData path}, animation dicts {"__anim": name}. A property holding
## anything else (nodes, untracked objects, code-built animations) is not saved and keeps its constructor value.

const PROJECTILE_CLASSES := ["Projectile", "PdsShot", "Beam", "Bomb"]
## ProjectileFactory::SaveState parts that ShipSave leaves out (targets, queued volley, WeaponAnimation).
const WEAPON_FIELDS := ["target_ship", "target_room", "target_point", "target_point2", "pending_points",
	"queued_shots", "shot_timer", "volley_entry_angle", "volley_target", "volley_point", "volley_points",
	"volley_shot", "fire_anim", "beam_level", "fire_when_ready", "current_ship"]
## Drone properties not taken from the save (identity / power, handled by ShipSave.redeploy; stale target ids).
const DRONE_SKIP := ["bp", "kind", "slot", "owner", "weapon", "rng", "powered", "bonus_power", "deployed", "crew",
	"destroyed_timer", "hack_level", "hack_time", "target_id", "shot_at_id", "has_target", "target_type"]
## ShipState battle fields: Shields::Save animations, Ship::SaveState lockdowns, HackingSystem::SaveState,
## MindSystem::Save (+ the controlled crew, from CrewMember bMindControlled).
const SHIP_FIELDS := ["shield_up_t", "shield_down_t", "shield_down_point", "shield_down_super", "super_up_t",
	"super_up_loc", "lockdowns", "hacking", "hack_target", "hack_queued", "hack_blocked", "hack_elapsed",
	"hack_duration", "shield_excess_hack", "mind_list", "mind_in_use", "mind_elapsed", "mind_duration",
	"mind_can_use", "mind_blocked"]
## ShipAI::Save: surrendered, escaping, thresholds, escape timer, stalemate, times teleported, crew needed.
const AI_FIELDS := ["surrendered", "escaping", "surrender_threshold", "escape_threshold", "escape_timer",
	"jump_requested", "stalemate_timer", "times_teleported", "crew_needed"]

var ships := {}  # key ("player" / "enemy") -> ShipState
var spaces := {}  # key -> Space
var _cut := false


func _init(combat: Combat, player: ShipState, enemy: ShipState) -> void:
	ships["player"] = player
	if enemy != null:
		ships["enemy"] = enemy
	for k in ships:
		spaces[k] = combat.space_of(ships[k]) if combat != null else null


# ------------------------------------------------------------ save

## The battle Variant. `enemy` = null: only the player's battle state and the projectiles not tied to the enemy
## (WorldManager::SaveGame without an enemy ship).
static func snapshot(combat: Combat, player: ShipState, enemy: ShipState = null) -> Dictionary:
	var b := BattleSave.new(combat, player, enemy)
	var d := {"projectiles": [], "ships": {}, "parties": [], "arrivals": []}
	for p in combat.projectiles:
		var e := b._projectile(p)
		if not e.is_empty():
			d.projectiles.append(e)
	for k in b.ships:
		d.ships[k] = b._ship(b.ships[k])
	for initiator in combat.parties:
		var ik: Variant = b._ship_key(initiator)
		if ik == null:
			continue
		for e in combat.parties[initiator]:
			b._cut = false
			var enc: Variant = b.enc(e)
			if not b._cut:
				d.parties.append([ik, enc])
	for k in b.ships:
		var s: ShipState = b.ships[k]
		for c in s.teleporting:
			var e: Dictionary = s.teleporting[c]
			if e.get("event", false):
				b._cut = false
				var ce: Variant = b.enc(c)
				var ee: Variant = b.enc(e)
				if not b._cut:
					d.arrivals.append([k, ce, ee])
	if enemy != null:
		var sp: Space = b.spaces.get("enemy")
		if sp != null and combat.ais.has(sp):
			d.ai = b.dump(combat.ais[sp], [], AI_FIELDS)
	return d


func _projectile(p: Node) -> Dictionary:
	var cls := SaveCodec.class_of(p)
	if not cls in PROJECTILE_CLASSES or p.dead:
		return {}
	# Shots of a ship that is not saved (the enemy is gone) go with it.
	for n in ["owner_ship", "target_ship"]:
		var s: Variant = p.get(n)
		if s != null and _ship_key(s) == null:
			return {}
	return {"cls": cls, "pos": p.position, "z": p.z_index, "p": dump(p, ["source_line"])}


func _ship(s: ShipState) -> Dictionary:
	var d := {"fields": dump(s, [], SHIP_FIELDS), "weapons": [], "artillery": [], "drones": []}
	for w in s.weapons:
		d.weapons.append(dump(w, [], WEAPON_FIELDS))
	for w in s.artillery:
		d.artillery.append(dump(w, [], WEAPON_FIELDS))
	for dr in s.drones:
		var e := {"deployed": dr.deployed, "powered": dr.powered, "p": dump(dr, DRONE_SKIP)}
		if dr.crew != null and dr.crew.is_alive():
			var at: Variant = _crew_ship_key(dr.crew)
			if at != null:
				e.crew = {"at": at, "p": SaveCodec.props_of(dr.crew, ShipSave.CREW_SKIP + ["drone_kind"]),
					"kind": dr.crew.drone_kind}
		d.drones.append(e)
	if s.hack_drone != null:
		d.hack_drone = {"deployed": s.hack_drone.deployed, "powered": s.hack_drone.powered,
			"p": dump(s.hack_drone, DRONE_SKIP)}
	return d


## Script variables of `o` (only `only` when given, minus `skip`) encoded; properties holding something that
## cannot be referenced are left out.
func dump(o: Object, skip: Array = [], only: Array = []) -> Dictionary:
	var p := {}
	for prop in o.get_property_list():
		if not (int(prop.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		var n := String(prop.name)
		if n in skip or (not only.is_empty() and not n in only):
			continue
		_cut = false
		var v: Variant = enc(o.get(n))
		if not _cut:
			p[n] = v
	_cut = false
	return p


func enc(v: Variant) -> Variant:
	match typeof(v):
		TYPE_ARRAY:
			var out := []
			for x in v:
				out.append(enc(x))
			return out
		TYPE_DICTIONARY:
			var an := _anim_name(v)
			if an != "":
				return {"__anim": an}
			var d := {}
			for k in v:
				d[enc(k)] = enc(v[k])
			return d
		TYPE_OBJECT:
			return _enc_object(v)
		TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID:
			_cut = true
			return null
	return v


func _enc_object(o: Object) -> Variant:
	if o == null or not is_instance_valid(o):
		return null
	if o is RandomNumberGenerator:
		return SaveCodec.encode(o)
	if o is ShipState:
		var k: Variant = _ship_key(o)
		if k == null:
			_cut = true
		return {"__ship": k}
	if o is Space:
		for k in spaces:
			if spaces[k] == o:
				return {"__space": k}
	elif o is WeaponState:
		for k in ships:
			var s: ShipState = ships[k]
			if s.weapons.has(o):
				return {"__weapon": [k, "w", s.weapons.find(o)]}
			if s.artillery.has(o):
				return {"__weapon": [k, "a", s.artillery.find(o)]}
			for i in s.drones.size():
				if s.drones[i].weapon == o:
					return {"__weapon": [k, "d", i]}
	elif o is Drone:
		for k in ships:
			var s: ShipState = ships[k]
			if s.hack_drone == o:
				return {"__drone": [k, "hack"]}
			if s.drones.has(o):
				return {"__drone": [k, s.drones.find(o)]}
	elif o is CrewMember:
		var c := o as CrewMember
		if c.is_drone() and c.drone != null:
			for k in ships:
				if ships[k].drones.has(c.drone):
					return {"__crew": [k, "d", ships[k].drones.find(c.drone)]}
		else:
			for k in ships:
				var i := _crew_list(k).find(c)
				if i >= 0:
					return {"__crew": [k, i]}
	elif o is SystemState:
		for k in ships:
			for id in ships[k].systems:
				if ships[k].systems[id] == o:
					return {"__sys": [k, id]}
	elif o is Damage:
		return {"__dmg": SaveCodec.props_of(o)}
	elif o is Texture2D:
		for rel in FtlData._tex_cache:
			if FtlData._tex_cache[rel] == o:
				return {"__tex": rel}
	_cut = true
	return null


static func _anim_name(d: Dictionary) -> String:
	if not d.has("texture") or not d.has("frames"):
		return ""
	for n in FtlData._anim_cache:
		if is_same(FtlData._anim_cache[n], d):
			return String(n)
	return ""


func _ship_key(s: Variant) -> Variant:
	for k in ships:
		if ships[k] == s:
			return k
	return null


## The non-drone crew standing on ship `k`, in list order (the order ShipSave restores them in).
func _crew_list(k: String) -> Array:
	return ships[k].crew.filter(func(c): return not c.is_drone())


func _crew_ship_key(c: CrewMember) -> Variant:
	for k in ships:
		if ships[k].crew.has(c):
			return k
	return null


# ------------------------------------------------------------ load

## WorldManager::LoadGame battle part, once the scene built the combat (ShipSave.redeploy done): projectiles,
## battle state of both ships, teleports and the enemy AI. `d` = the `battle` Variant ({} = nothing to do).
static func apply(combat: Combat, d: Dictionary, player: ShipState, enemy: ShipState = null) -> void:
	if d.is_empty() or combat == null:
		return
	var b := BattleSave.new(combat, player, enemy if d.get("ships", {}).has("enemy") else null)
	for k in d.get("ships", {}):
		if b.ships.has(k):
			b._load_ship(b.ships[k], d.ships[k])
	for e in d.get("projectiles", []):
		var p: Node2D = b._load_projectile(e)
		if p != null:
			combat.projectiles.append(p)
	for pe in d.get("parties", []):
		var initiator: Variant = b.ships.get(pe[0])
		var e: Variant = b.dec(pe[1])
		if initiator == null or not e is Dictionary or e.get("crew") == null or e.get("from") == null \
				or e.get("to") == null:
			continue
		var list: Array = combat.parties.get(initiator, [])
		list.append(e)
		combat.parties[initiator] = list
		(e.from if int(e.phase) == 0 else e.to).teleporting[e.crew] = e
	for ae in d.get("arrivals", []):
		var s: Variant = b.ships.get(ae[0])
		var c: Variant = b.dec(ae[1])
		if s != null and c is CrewMember:
			s.teleporting[c] = b.dec(ae[2])
	if d.has("ai") and b.ships.has("enemy"):
		var sp: Space = b.spaces.get("enemy")
		if sp != null and combat.ais.has(sp):
			b.load_into(combat.ais[sp], d.ai)


func _load_ship(s: ShipState, d: Dictionary) -> void:
	var weapons: Array = d.get("weapons", [])
	for i in mini(weapons.size(), s.weapons.size()):
		load_into(s.weapons[i], weapons[i])
	var arts: Array = d.get("artillery", [])
	for i in mini(arts.size(), s.artillery.size()):
		load_into(s.artillery[i], arts[i])
	var drones: Array = d.get("drones", [])
	for i in mini(drones.size(), s.drones.size()):
		_load_drone(s, s.drones[i], drones[i])
	if d.has("hack_drone"):
		var hd := HackingRule.drone(s)
		hd.deployed = bool(d.hack_drone.get("deployed", false))
		hd.powered = bool(d.hack_drone.get("powered", false))
		load_into(hd, d.hack_drone.p)
	load_into(s, d.get("fields", {}))
	for c in s.mind_list:  # the controlled crew (their bMindControlled came with the crew snapshot)
		c.mind_controlled = true


## SpaceDrone::LoadState over the drone ShipSave.redeploy re-powered: its flight state; a deployed drone that was
## unpowered (drifting) is deployed again without power; its crew drone / delivered boarder stands where it stood.
func _load_drone(s: ShipState, dr: Drone, e: Dictionary) -> void:
	if not bool(e.get("deployed", false)):
		return
	if not dr.deployed:
		if not DroneSystemRule.set_deployed(s, dr, true):
			return
		dr.powered = false
	load_into(dr, e.p)
	if not e.has("crew"):
		return
	var at: ShipState = ships.get(e.crew.at)
	if at == null:
		return
	var c: CrewMember = dr.crew
	if c == null:  # a delivered boarding drone (redeploy put the pod back at its start)
		c = CrewMember.new("human", s.is_player)
		c.make_drone(String(e.crew.kind))
		c.drone = dr
		dr.crew = c
	else:
		for o in ships.values():
			if o != at and o.crew.has(c):
				o.crew.erase(c)
				o.crew_changed()
	SaveCodec.set_props(c, e.crew.p)
	if not at.crew.has(c):
		at.crew.append(c)
	ShipSave._seat(at, c)
	at.crew_changed()


func _load_projectile(e: Dictionary) -> Node2D:
	var p: Node2D
	match String(e.cls):
		"Projectile":
			p = Projectile.new()
		"PdsShot":
			p = PdsShot.new()
		"Beam":
			p = Beam.new()
		"Bomb":
			p = Bomb.new()
		_:
			return null
	load_into(p, e.p)
	p.position = e.pos
	p.z_index = int(e.z)
	var world_space: Space = null
	if p is Projectile:
		world_space = p.current_space
		if p.dmg == null:
			p.dmg = Damage.new()
	elif p is Beam:
		world_space = p.dest_space
		if p.weapon == null:
			p.weapon = WeaponState.new(p.bp, 0)
		p._smoke_anim = Beam._fire_smoke_anim()
		if p.source_space != null and p.source_space != p.dest_space and not p.dead:
			p.source_line = Node2D.new()
			p.source_line.z_index = -1
			p.source_line.draw.connect(p._draw_source)
			p.source_space.world.add_child(p.source_line)
	elif p is Bomb:
		world_space = p.dest_space
	if world_space == null or world_space.world == null:
		p.free()
		return null
	world_space.world.add_child(p)
	return p


## Assigns a `dump` onto an object (references resolved; unknown names ignored; typed containers re-typed).
func load_into(o: Object, p: Dictionary) -> void:
	var known := {}
	for prop in o.get_property_list():
		if int(prop.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE:
			known[String(prop.name)] = true
	for n in p:
		if not known.has(String(n)):
			continue
		_assign(o, String(n), dec(p[n]))


static func _assign(o: Object, n: String, val: Variant) -> void:
	var cur: Variant = o.get(n)
	if cur is Array and val is Array and (cur as Array).is_typed():
		var fresh: Array = (cur as Array).duplicate()
		fresh.clear()
		for x in val:
			fresh.append(x)
		o.set(n, fresh)
	elif cur is Dictionary and val is Dictionary and (cur as Dictionary).is_typed():
		var fd: Dictionary = (cur as Dictionary).duplicate()
		fd.clear()
		for k in val:
			fd[k] = val[k]
		o.set(n, fd)
	elif cur is RandomNumberGenerator and val is RandomNumberGenerator:
		(cur as RandomNumberGenerator).seed = val.seed
		(cur as RandomNumberGenerator).state = val.state
	elif cur is float and val is int:
		o.set(n, float(val))
	elif cur is int and val is float:
		o.set(n, int(val))
	else:
		o.set(n, val)


func dec(v: Variant) -> Variant:
	match typeof(v):
		TYPE_ARRAY:
			var out := []
			for x in v:
				out.append(dec(x))
			return out
		TYPE_DICTIONARY:
			if v.size() == 1:
				var k: String = String(v.keys()[0])
				if k.begins_with("__"):
					return _dec_ref(k, v[k], v)
			var d := {}
			for k in v:
				d[dec(k)] = dec(v[k])
			return d
	return v


func _dec_ref(k: String, a: Variant, raw: Dictionary) -> Variant:
	match k:
		"__rng":
			return SaveCodec.decode(raw)
		"__ship":
			return ships.get(a)
		"__space":
			return spaces.get(a)
		"__anim":
			return FtlData.anim(String(a))
		"__tex":
			return FtlData.texture(String(a))
		"__dmg":
			var dm := Damage.new()
			SaveCodec.set_props(dm, a)
			return dm
		"__weapon":
			var s: ShipState = ships.get(a[0])
			if s == null:
				return null
			var i := int(a[2])
			match String(a[1]):
				"w":
					return s.weapons[i] if i < s.weapons.size() else null
				"a":
					return s.artillery[i] if i < s.artillery.size() else null
				"d":
					return s.drones[i].weapon if i < s.drones.size() else null
			return null
		"__drone":
			var s: ShipState = ships.get(a[0])
			if s == null:
				return null
			if String(a[1]) == "hack":
				return HackingRule.drone(s)
			var i := int(a[1])
			return s.drones[i] if i < s.drones.size() else null
		"__crew":
			var s: ShipState = ships.get(a[0])
			if s == null:
				return null
			if a.size() == 3:
				var i := int(a[2])
				return s.drones[i].crew if i < s.drones.size() else null
			var list := _crew_list(String(a[0]))
			var j := int(a[1])
			return list[j] if j < list.size() else null
		"__sys":
			var s: ShipState = ships.get(a[0])
			return s.systems.get(a[1]) if s != null else null
	var d := {}
	d[k] = dec(a)
	return d
