class_name Combat
extends Node
## Combat simulation: clock, weapon charging, firing, projectiles between spaces.
## Knows about spaces and ships, but not about how the UI lays them out.

var spaces: Array[Space] = []
var targets := {}  # Space -> Space it fires at
var ais := {}  # Space -> ShipAI (enemy ships)
var crew_ais := {}  # Space -> CrewAI (every ship; only enemy ships move their crew)
var projectiles: Array = []  # Projectile, Beam and Bomb nodes (each has step(f, rng) and `dead`)
var paused := false
var speed_level := 0
var rng := RandomNumberGenerator.new()
# Teleporter (rules/teleporter.md): parties in transit, keyed by the initiating ship:
# [{crew, from: ShipState, to: ShipState, room, phase: 0 dematerialise / 1 materialise, t}]
var parties := {}
var player_tp_armed := TeleporterRule.NONE  # player's TeleportBox armed mode (SEND / RETRIEVE)
var player_tp_command := {}  # {room, mode}: stored by a click on an enemy room, run while unpaused
var _killed := {}  # ShipState -> true once KillEveryone ran for a destroyed ship (explosion done)
var _destroyed := {}  # ShipState -> true once the hull-0 hooks ran


var _seconds := 0.0  # game seconds in this step

static var verbose := false
static var game_time := 0.0  # game seconds (excluding pause)
## True while the game world is paused (rules/ship_rendering.md "Pause"): every game-world animation
## (crew, fire, breaches, doors, thrusters, weapons, shield hits, damage numbers) holds its frame.
static var world_paused := false


## Seconds a game-world animation advances this frame: 0 while paused (CommandGui::OnLoop skips the
## world's OnLoop while paused; only the HUD keeps updating).
static func world_delta(delta: float) -> float:
	return 0.0 if world_paused else delta


static func log(msg: String) -> void:
	if verbose:
		print("[%6.2f s] %s" % [game_time, msg])


func add_space(s: Space, target: Space = null) -> void:
	spaces.append(s)
	if target:
		targets[s] = target
		s.ship.opponent = target.ship
	crew_ais[s] = CrewAI.new(s.ship)
	if not s.ship.is_player:
		ais[s] = ShipAI.new(s.ship, rng)
		ais[s].crew_ai = crew_ais[s]


func _ready() -> void:
	world_paused = paused


func _exit_tree() -> void:
	world_paused = false


func _process(_delta: float) -> void:
	world_paused = paused  # also set before the views' _process (main / combat order varies)


func _physics_process(delta: float) -> void:
	world_paused = paused
	for s in spaces:  # hostility also changes while paused (an accepted surrender in the event box)
		s.ship.hostile = ais[s].hostile if ais.has(s) else true
	if paused:
		_pause_loop(delta)
		return
	var f := GameClock.factor(delta, speed_level)
	if f <= 0.0:
		return
	_seconds = f / GameClock.BASE
	game_time += _seconds
	for s in spaces:
		if s.ship.is_player:
			# WeaponControl::OnLoop: weapons aimed at a ship that is no longer hostile lose their aim.
			for w in s.ship.weapons:
				if w.target_ship != null and w.target_ship != s.ship and not w.target_ship.hostile:
					w.clear_target()
		s.ship.tick(f)
		_update_teleports(s.ship, _seconds)
		_update_event_arrivals(s.ship, _seconds)
		if s.ship.is_player:
			_update_player_teleport(s.ship)
			_player_hacked_systems(s.ship)
		if crew_ais.has(s):
			var cai: CrewAI = crew_ais[s]
			cai.hostile = ais[s].hostile if ais.has(s) else true
			cai.tick()
		if ais.has(s):
			_tick_ai(s)
		_update_weapons(s)
	_update_deaths()
	_launch_shards()
	_show_system_explosions()
	_update_drones(f)
	for p in projectiles:
		p.step(f, rng)
	_drone_collisions(f)
	for p in projectiles.filter(func(p): return p.dead):
		projectiles.erase(p)
		p.queue_free()
	Hooks.emit(&"sim_tick", self, _seconds)


## CApp::OnLoop while paused (rules/pause.md): WorldManager::PauseLoop instead of OnLoop — only the player ship's
## Ship::PauseLoop runs (door animations, drawn by ShipView, and Door::OnLoop of the outer airlocks). No simulation:
## no charge, firing, crew walking, air, fire, AI, teleport / hack / mind-control commands (queued until unpaused).
func _pause_loop(delta: float) -> void:
	var seconds := GameClock.factor(delta, speed_level) / GameClock.BASE
	for s in spaces:
		if s.ship.is_player and not s.ship.is_destroyed():
			s.ship.env.pause_tick_airlocks(seconds)


func space_of(ship: ShipState) -> Space:
	for s in spaces:
		if s.ship == ship:
			return s
	return null


## Enemy AI (CompleteShip::OnLoop order: ship simulation first, then ShipAI::OnLoop).
func _tick_ai(s: Space) -> void:
	var ai: ShipAI = ais[s]
	var tgt: Space = targets.get(s)
	ai.target = tgt.ship if tgt else null
	# CompleteShip::OnLoop: the AI teleport command runs before ShipAI::OnLoop.
	var cmd := ai.get_teleport_command()
	if not cmd.is_empty():
		initiate_teleport(s.ship, int(cmd.room), int(cmd.mode))
	ai.tick(_seconds)


## The player ship's ShipAI parts that run only while hacked (rules/hacking.md): its mind system is used by
## the hacker against the player's crew (CombatAI::UpdateMindControl), and a hacked teleporter retrieves
## the player's boarders (RequiredEvac / GetTeleportCommand with CanReceive(countHacked)).
func _player_hacked_systems(ship: ShipState) -> void:
	if ship.is_destroyed():
		return
	MindRule.ai_update(ship, true)
	var tp := ship.sys("teleporter")
	var t := ship.opponent
	if tp == null or not tp.hacked or t == null or t.super_shield > 0:
		return
	if not TeleporterRule.can_receive(ship, t, true):
		return
	for c in t.crew:
		if c.is_alive() and c.player_owned and not c.mind_controlled and not c.is_drone():
			initiate_teleport(ship, c.room, TeleporterRule.RETRIEVE)
			return


## Fires the weapons that meet FTL's conditions (rules/targeting.md "Firing").
func _update_weapons(s: Space) -> void:
	var ship := s.ship
	if ship.is_destroyed():
		return
	var wl := ship.crew_level_in("weapons")
	for w in ship.weapons:
		if w.has_target() and w.target_ship.is_destroyed():
			w.clear_target()
		if w.should_fire(wl, ship.missiles):
			var to := space_of(w.target_ship)
			if to:
				fire(s, w, to)
		# Shots of the current volley (one every fire_time, in step with the animation)
		for i in w.tick_volley(_seconds):
			_launch_shot(s, w)
	# Artillery: fires by itself at random rooms when charged (rules/artillery.md).
	for w in ship.artillery:
		if ArtilleryRule.ready_to_fire(ship, w):
			var to := space_of(ship.opponent)
			if to:
				w.set_target(ship.opponent, -1, Vector2.ZERO, false)
				w.pending_points = ArtilleryRule.pick_points(ship, w, rng)
				if not w.pending_points.is_empty():
					w.target_room = ship.opponent.room_at(w.pending_points[0])
					fire(s, w, to)
		for i in w.tick_volley(_seconds):
			_launch_shot(s, w)


## Fire: spends missiles, resets the charge and queues the volley (rules: "Bursts").
func fire(from: Space, w: WeaponState, to: Space) -> void:
	var points: Array[Vector2] = w.pending_points.duplicate()
	if w.is_beam() and points.size() < 2:
		points.clear()  # player beam: start and end of the drag
		points.append(w.target_point)
		points.append(w.target_point2)
	w.start_volley(rng, points)
	Hooks.emit(&"weapon_fired", from.ship, w, to.ship)
	AugmentRule.spend_missiles(from.ship, w.missiles_per_shot(), rng, w)  # EXPLOSIVE_REPLICATOR: 50 % saved
	w.after_fire()
	if not w.is_artillery:
		from.ship.on_weapon_fired()
	var rooms := []
	for pt in (w.volley_points if not w.volley_points.is_empty() else [w.volley_point]):
		rooms.append(to.ship.room_at(pt))
	Combat.log("%s fires %s at rooms %s (%d shots, damage %d, sp %d, speed %d, missiles %d, entry %d deg)" % [
		from.ship.blueprint.name, w.bp.name, str(rooms), w.queued_shots,
		int(w.bp.damage), int(w.bp.sp), int(w.speed()), from.ship.missiles, int(w.volley_entry_angle)])


## One shot of the volley leaves: its own sound, same heading and same entry angle.
## Beams, bombs and flak create their own kind of shot (rules/weapons.md).
func _launch_shot(from: Space, w: WeaponState) -> void:
	var to := space_of(w.volley_target)
	if to == null or from.ship.is_destroyed():
		return
	FtlData.play_random(w.bp.launch_sounds)
	Combat.log("  shot from %s (%d left)" % [w.bp.name, w.queued_shots])
	# CloakingSystem::FiredWeapon: once per volley, when its last projectile leaves (weapons system only).
	if w.queued_shots == 0 and not w.is_artillery:
		CloakRule.fired_weapon(from.ship)
	if w.is_beam():
		var b := Beam.new()
		var p1 := w.next_shot_point()
		var p2 := w.volley_points[1] if w.volley_points.size() > 1 else p1
		b.setup(w, from, to, p1, p2, rng)
		_add_shot(to, b)
	elif w.is_bomb():
		var bomb := Bomb.new()
		bomb.setup(w, from, to, w.next_shot_point(), rng)
		_add_shot(to, bomb)
	elif w.is_flak():
		var center := w.next_shot_point()
		for m in w.bp.get("mini_projectiles", []):
			_add_projectile(from, to, w, flak_point(center, int(w.bp.radius), rng), m.image, m.fake)
	else:
		_add_projectile(from, to, w, w.next_shot_point())


## Flak spread (ProjectileFactory::Update): uniform point in a disc of `radius` around the target,
## angle = (rand % 360)°, distance = radius × sqrt(rand / RAND_MAX).
static func flak_point(center: Vector2, radius: int, r: RandomNumberGenerator) -> Vector2:
	var angle := deg_to_rad(float(r.randi() % 360))
	var dist := sqrt(r.randf()) * radius
	return center + Vector2(cos(angle), sin(angle)) * dist


func _add_projectile(from: Space, to: Space, w: WeaponState, point: Vector2, image := "", fake := false) -> void:
	var p := Projectile.new()
	p.setup(w, from, to, WeaponArt.fire_location(from.ship, w), point, image, fake)
	p.entry_angle = w.volley_entry_angle
	from.world.add_child(p)
	projectiles.append(p)


## CRYSTAL_SHARDS (CheckCrystalAugment -> superBarrage): each queued shard leaves the hit point of the hit ship
## as a CRYSTAL_1 missile (damage forced to 1, no owner, sp 5) toward a random room of its target.
func _launch_shards() -> void:
	for s in spaces:
		var ship := s.ship
		if ship.pending_shards.is_empty():
			continue
		var to := space_of(ship.opponent)
		for sh in ship.pending_shards:
			# Entries with a `weapon` are the flagship's laser barrage (FlagshipRule.prepare_super_barrage: same
			# superBarrage queue, LASER_HEAVY_1, damage 1, owned by the flagship).
			var bp := FtlData.weapon_blueprint(String(sh.get("weapon", "CRYSTAL_1")))
			if to == null or bp.is_empty() or ship.is_destroyed():
				break
			var w := WeaponState.new(bp, 0)
			var p := Projectile.new()
			p.setup(w, s, to, sh.from, ship.opponent.random_room_center(rng))
			p.heading = float(sh.heading)
			p.dmg.damage = int(sh.get("damage", 1))
			p.dmg.owner = int(sh.get("owner", -1))
			p.crystal_shard = not sh.has("weapon")
			s.world.add_child(p)
			projectiles.append(p)
			FtlData.play_random(bp.get("launch_sounds", []))
			Combat.log("%s %s -> %s" % [ship.blueprint.name, "barrage shot" if sh.has("weapon") else "crystal shard",
				ship.opponent.blueprint.name])
		ship.pending_shards.clear()


## ShipManager::OnLoop GetExploded visuals (ShipState._check_exploded did the hull damage): DamageMessage "1" at the
## room centre, explosion1 there (top-left at centre - 16 = centred 32 px frames) and sound sysExplosion.
func _show_system_explosions() -> void:
	for s in spaces:
		if s.ship.pending_explosions.is_empty():
			continue
		for room in s.ship.pending_explosions:
			var at := s.ship.room_rect(int(room)).get_center()
			s.show_number(1, at, Space.MSG_HULL)
			s.show_anim("explosion1", at)
			FtlData.play("sysExplosion")
		s.ship.pending_explosions.clear()


func _add_shot(to: Space, node: Node2D) -> void:
	to.world.add_child(node)
	projectiles.append(node)


# ------------------------------------------------------------ teleporter (rules/teleporter.md)

## CompleteShip::InitiateTeleport(room, command) for `ship` (SEND: its pad -> `room` of its opponent;
## RETRIEVE: its crew in `room` of the opponent -> its pad). Room -1 = random room of the target.
## Returns the party size (0 = nothing happened, no cooldown).
func initiate_teleport(ship: ShipState, room: int, mode: int) -> int:
	var target := ship.opponent
	var tp := ship.sys("teleporter")
	if mode == TeleporterRule.NONE or target == null or tp == null:
		return 0
	if not parties.get(ship, []).filter(func(e): return e.phase == 0).is_empty():
		return 0  # a party is still in flight
	if ship.jumping or target.jumping:
		return 0
	if room < 0:
		room = target.layout.rooms[rng.randi() % target.layout.rooms.size()].id
	var from := ship if mode == TeleporterRule.SEND else target
	var to := target if mode == TeleporterRule.SEND else ship
	var dest := room if mode == TeleporterRule.SEND else tp.room
	var party := TeleporterRule.pick_party(from, tp.room if mode == TeleporterRule.SEND else room,
		mode == TeleporterRule.RETRIEVE)
	if party.is_empty():
		return 0
	TeleporterRule.start_cooldown(ship)
	FtlData.play("teleport")
	var heal := ship.augment_value("TELEPORT_HEAL", 0.0)
	var list: Array = parties.get(ship, [])
	for c in party:
		if heal > 0.0:
			c.hp = minf(c.hp + heal * c.max_hp, c.max_hp)
		TeleporterRule.reset_crew_state(c)
		var e := {"crew": c, "from": from, "to": to, "room": dest, "phase": 0, "t": 0.0}
		from.teleporting[c] = e
		list.append(e)
	parties[ship] = list
	Combat.log("TELEPORT %s %s room %d: %d crew" % [ship.blueprint.name,
		"send to" if mode == TeleporterRule.SEND else "retrieve from", room, party.size()])
	return party.size()


## CheckForTeleport + CompleteShip::OnLoop for the parties started by `ship`: after 0.5 s the crew leaves
## its ship and is placed on the destination (GetAvailableRoom spill rules), then materialises 0.5 s.
func _update_teleports(ship: ShipState, seconds: float) -> void:
	var list: Array = parties.get(ship, [])
	if list.is_empty():
		return
	for e in list.duplicate():
		var c: CrewMember = e.crew
		e.t += seconds
		if e.phase == 0:
			if not c.is_alive():
				e.from.teleporting.erase(c)
				list.erase(e)
				continue
			if e.t < TeleporterRule.ANIM_TIME:
				continue
			e.from.teleporting.erase(c)
			e.from.crew.erase(c)
			e.from.crew_changed()
			if not TeleporterRule.place_arrival(e.to, c, e.room):
				e.from.crew.append(c)  # nowhere to stand: stays home
				list.erase(e)
				continue
			e.phase = 1
			e.t = 0.0
			e.to.teleporting[c] = e
			if c.is_intruder(e.to):
				Hooks.emit(&"boarding", e.from, e.to, c)
		elif e.t >= TeleporterRule.ANIM_TIME or not c.is_alive():
			e.to.teleporting.erase(c)
			list.erase(e)
	parties[ship] = list


## Event boarders (RunState.add_boarders, CrewMember::StartTeleportArrive): materialise 0.5 s in place, no
## sending ship (entries marked "event").
static func _update_event_arrivals(ship: ShipState, seconds: float) -> void:
	for c in ship.teleporting.keys():
		var e: Dictionary = ship.teleporting[c]
		if not e.get("event", false):
			continue
		e.t += seconds
		if e.t >= TeleporterRule.ANIM_TIME or not c.is_alive():
			ship.teleporting.erase(c)


## Player TeleportBox: SetArmed(mode) re-checks CanSend / CanReceive; failing -> disarmed.
## Clicking the armed mode again disarms. Returns true if now armed.
func arm_teleporter(ship: ShipState, mode: int) -> bool:
	if mode == player_tp_armed or mode == TeleporterRule.NONE:
		player_tp_armed = TeleporterRule.NONE
		return false
	var ok := TeleporterRule.can_send(ship, ship.opponent) if mode == TeleporterRule.SEND \
		else TeleporterRule.can_receive(ship, ship.opponent)
	player_tp_armed = mode if ok else TeleporterRule.NONE
	return ok


## Armed + click on an enemy room: the command is stored (run on the next unpaused frame).
func teleport_room_clicked(room: int) -> bool:
	if player_tp_armed == TeleporterRule.NONE or room < 0:
		return false
	player_tp_command = {"room": room, "mode": player_tp_armed}
	player_tp_armed = TeleporterRule.NONE
	return true


## CombatControl::OnLoop + GetTeleportationCommand for the player ship.
func _update_player_teleport(ship: ShipState) -> void:
	var target := ship.opponent
	if target == null or target.is_destroyed():
		player_tp_armed = TeleporterRule.NONE
		player_tp_command = {}
		return
	var holding := not TeleporterRule.crew_of_side(target, true).is_empty()
	if target.is_cloaked() and not holding:
		player_tp_command = {}  # cancelled
	if not holding and not target.hostile:
		player_tp_armed = TeleporterRule.NONE
	if not TeleporterRule.functioning(ship):
		player_tp_armed = TeleporterRule.NONE
	if player_tp_command.is_empty() or target.is_cloaked():
		return  # a kept command waits for the decloak
	var cmd := player_tp_command
	player_tp_command = {}
	initiate_teleport(ship, int(cmd.room), int(cmd.mode))


# ------------------------------------------------------------ deaths and cloning

## Ship destruction (rules/ship_destruction.md §5, §6): at hull 0 the drone / hacking / mind-control
## ShipDestroyed hooks run once; KillEveryone (noClone = false) aboard only when the explosion is over
## (ShipAI::Destroyed / DestroyedDone, 3 s; player ship 6 s). Dead crew go to their side's clone queue;
## clonebays clone (rules/clonebay.md).
func _update_deaths() -> void:
	var ships: Array = spaces.map(func(sp): return sp.ship)
	for ship in ships:
		if ship.is_destroyed() and not _destroyed.has(ship):
			_destroyed[ship] = true
			ship.on_destroyed()
			DroneSystemRule.ship_destroyed(ship)
			HackingRule.stop(ship)
			MindRule.ship_destroyed(ship)
		# WorldManager::OnLoop kills the crew of a destroyed *enemy* ship; the player's ends in a game over.
		if not ship.is_player and ship.destroyed_done() and not _killed.has(ship):
			_killed[ship] = true
			for c in ship.crew:
				c.hp = 0.0
			ship.crew_changed()
			Combat.log("%s explosion done: KillEveryone" % ship.blueprint.name)
	for ship in ships:
		ClonebayRule.collect_dead(ship, ships)
		var c := ClonebayRule.tick(ship, _seconds)
		if c:
			Combat.log("CLONED %s on %s" % [c.race, ship.blueprint.name])
			Hooks.emit(&"crew_cloned", ship, c)


# ------------------------------------------------------------ drones (rules/drones.md)

## Space drones of every ship, in ship then slot order (SpaceManager drone list).
func space_drones() -> Array:
	var out := []
	for s in spaces:
		for d in s.ship.drones:
			if d.is_space() and d.deployed:
				out.append(d)
		var hd: Drone = s.ship.hack_drone
		if hd != null and hd.deployed:
			out.append(hd)
		out.append_array(FlagshipRule.deployed_super_drones(s.ship))  # flagship drone surge (superDrones)
	return out


## SpaceManager::OnLoop, drone part: every deployed space drone moves / aims, then its shot leaves.
func _update_drones(f: float) -> void:
	for d in space_drones():
		d.step(f)
		var shot: Dictionary = d.take_shot()
		if not shot.is_empty():
			_drone_shot(d, shot)


## Spawns a drone's shot in the space it was fired in (rules/drones.md §5, §6, §8).
func _drone_shot(d: Drone, shot: Dictionary) -> void:
	var sp := space_of(shot.ship)
	if sp == null:
		return
	match String(shot.kind):
		"repair":
			# ShipRepairDrone: DamageTarget(iDamage = -1) at a random room centre -> +1 hull.
			d.owner.hull = mini(d.owner.hull + 1, d.owner.max_hull)
			sp.show_text("+1", shot.to, FtlColors.GREEN)
			FtlData.play("repairShip")
			Combat.log("%s hull repair drone: hull %d" % [d.owner.blueprint.name, d.owner.hull])
		"beam":
			if d.weapon == null:
				return
			var b := Beam.new()
			b.setup(d.weapon, sp, sp, shot.to, shot.to2, rng)
			b.owner_ship = d.owner
			b.dmg.owner = 0 if d.owner.is_player else 1
			b.sub_start = shot.from  # the beam starts at the drone, not off-screen
			_add_shot(sp, b)
			FtlData.play_random(d.weapon.bp.launch_sounds)
			Combat.log("%s drone %s beams %s" % [d.owner.blueprint.name, d.bp.name, shot.ship.blueprint.name])
		_:
			if d.weapon == null:
				return
			var p := Projectile.new()
			var tgt: ShipState = shot.get("target")
			p.setup_drone(d.weapon, d.owner, sp, shot.from, shot.to, tgt)
			sp.world.add_child(p)
			projectiles.append(p)
			FtlData.play_random(d.weapon.bp.launch_sounds)
			Combat.log("%s drone %s fires at %s" % [d.owner.blueprint.name, d.bp.name,
				("room %d" % tgt.room_at(shot.to)) if tgt else "a projectile / drone"])


## After the projectiles moved (SpaceManager::UpdateProjectile): projectile vs drone and projectile vs
## projectile collisions (10 px, different owners, same space; beams and bombs never collide), then the
## offers of every live projectile and space drone to the defence drones of that space.
func _drone_collisions(f: float) -> void:
	var drones := space_drones()
	var shots: Array = projectiles.filter(func(p): return p is Projectile and not p.dead and p.dying <= 0.0 		and not p.fake)
	var r2 := Drone.HIT_RADIUS * Drone.HIT_RADIUS
	for p in shots:
		if p.dying > 0.0:
			continue
		var here: ShipState = p.current_space.ship
		for d in drones:
			if d.owner == p.owner_ship or d.space_ship != here or not d.in_space():
				continue
			if p.position.distance_squared_to(d.pos) < r2 and d.hit_by(p.dmg):
				Combat.log("%s hits %s drone %s%s" % [p.weapon.name, d.owner.blueprint.name, d.bp.name,
					(" (ion stun %.0f s)" % d.ion_stun) if p.dmg.ion > 0 else ""])
				p.destroy()
				break
		if p.dying > 0.0:
			continue
		for q in shots:
			if q == p or q.dying > 0.0 or q.owner_ship == p.owner_ship or q.current_space != p.current_space:
				continue
			if p.position.distance_squared_to(q.position) < r2:
				Combat.log("%s and %s collide" % [p.weapon.name, q.weapon.name])
				p.destroy()
				q.destroy()
				break
	# Offers to defence drones: projectiles in list order, then the other space drones.
	var defenders := drones.filter(func(d): return d.kind == Drone.Kind.DEFENSE and d.in_space())
	if defenders.is_empty() or f <= 0.0:
		return
	for p in shots:
		if p.dying > 0.0:
			continue
		var tt: int = p.targetable_type()
		if tt < 0:
			continue
		var v: Vector2 = (p.position - p.last_position) / f
		for d in defenders:
			if d.owner != p.owner_ship and d.space_ship == p.current_space.ship:
				d.offer(p.get_instance_id(), tt, p.position, v)
	for x in drones:
		if not x.valid_target():
			continue
		for d in defenders:
			if d != x and d.owner != x.owner and d.space_ship == x.space_ship:
				d.offer(x.get_instance_id(), x.targetable_type(), x.pos, x.speed_vector(f))
