class_name FlagshipRule
extends RefCounted
## The Rebel Flagship's three stages (rules/flagship.md): BossShip::StartStage (a fresh ship per stage from
## BOSS_<stage>_<EASY|NORMAL|HARD>[_DLC], crew carried over room by room, 10 drone parts, stage 3 = 12-point super
## shield), BossShip::OnLoop (crew snapshot, the 20–30 s power timer, the power surges: stage 2 drone surge
## (PrepareSuperDrones), stage 3 laser barrage (PrepareSuperBarrage) / super shield every 4th surge), the incoming
## fire warning (BossShip::IncomingFire) and the boss stalemate (ShipAI::OnLoop with bBoss).
## Pure rules on a ShipState plus the fight state dictionary kept in RunState.boss (LastStand).

const STAGE1_CREW_ROOMS := [0, 1, 2, 3, 4, 5, 6, 9, 10, 14, 18]  # StartStage(1): one crew member in each
const CREW_RACE := "human"  # StartStage: AddCrewMember("human", ...)
const DRONE_PARTS := 10  # StartStage: ModifyDroneCount(10)
const POWER_MIN_MS := 20000  # BossShip ctor: powerTimer minTime / maxTime (ms, TimerHelper / 1000)
const POWER_MAX_MS := 30000
const INCOMING_FIRE := 5.0  # IncomingFire: < 5 s left on the power timer (stage 2 / 3)
const SUPER_DRONES := 7  # PrepareSuperDrones: created once, COMBAT_1 / COMBAT_BEAM at 50 %
const SURGE_DRONES := [4, 6, 7]  # drones activated per surge: easy / normal / hard
const SURGE_LIFESPAN := 2  # shots per surge drone
const BARRAGE_SHOTS := 7  # PrepareSuperBarrage: LASER_HEAVY_1 x 7, damage forced to 1
const BARRAGE_WEAPON := "LASER_HEAVY_1"
const BARRAGE_DAMAGE := 1
const SHIELD_EVERY := 4  # stage 3: powerCount % 4 == 3 -> PowerSuperShields instead of the barrage
const STALEMATE_JUMP := 120.0  # ShipAI::OnLoop, bBoss: JumpLeave once fStalemateTimer >= 120
const STALEMATE_ESCAPE := 90.0  # stalemate: escaping, escapeTimer = max(escapeTimer, 90)
const STALEMATE_HIT_CAP := 60.0  # the boss's hull changed: timer = min(timer, 60)
const JUMP_TIME := 2.0  # ShipManager::JumpLeave: jumpAnimation


## BOSS_<stage>_<EASY|NORMAL|HARD>, "_DLC" with AE content (StartStage).
static func blueprint_name(stage: int, difficulty: int, ae: bool) -> String:
	var diff: String = ["_EASY", "_NORMAL", "_HARD"][clampi(difficulty, 0, 2)]
	return "BOSS_%d%s%s" % [clampi(stage, 1, 3), diff, "_DLC" if ae else ""]


## Crew per room for a stage (StartStage): stage 1 = one in each STAGE1_CREW_ROOMS room; later stages = the counts
## recorded during the previous stage (dead crew stay dead, survivors come back healed), trimmed to the room count.
static func stage_crew(stage: int, counts: Array, room_count: int) -> Array:
	var out := []
	if stage == 1:
		out.resize(room_count)
		out.fill(0)
		for r in STAGE1_CREW_ROOMS:
			if r < room_count:
				out[r] = 1
		return out
	out = counts.duplicate()
	while out.size() > room_count:
		out.pop_back()
	return out


## BossShip::StartStage: the stage's ship. Not invincible only in stage 3 (stages 1 / 2 jump away at hull 0).
static func build(stage: int, difficulty: int, ae: bool, counts: Array) -> ShipState:
	var es := ShipState.new(blueprint_name(stage, difficulty, ae), false)
	for c in es.crew.duplicate():
		es.crew.erase(c)
	var crew := stage_crew(stage, counts, es.layout.rooms.size())
	var races := []
	for room in crew.size():
		for i in int(crew[room]):
			if es.add_crew(CREW_RACE, false, room) != null:
				races.append(CREW_RACE)
	es.blueprint.crew = races  # bAutomated = false: crewed (an empty list reads as automated elsewhere)
	es.drone_parts = DRONE_PARTS
	es.set_meta("flagship_stage", stage)
	if stage == 3:
		SuperShieldRule.flagship_stage(es, stage)
	es.save_crew_positions()
	es.crew_changed()
	return es


static func stage_of(ship: ShipState) -> int:
	return int(ship.get_meta("flagship_stage", 0)) if ship != null else 0


## bInvincible: hull 0 plays the jump-out explosion (4 s) instead of the destruction.
static func invincible(ship: ShipState) -> bool:
	var st := stage_of(ship)
	return st == 1 or st == 2


# ------------------------------------------------------------------ power timer (TimerHelper)

## TimerHelper::Start(-1): goal = (min + rand % (max - min)) / 1000 s.
static func start_timer(state: Dictionary, rng: RandomNumberGenerator) -> void:
	state.power_time = 0.0
	state.power_goal = _goal(rng)
	state.power_count = 0


static func _goal(rng: RandomNumberGenerator) -> float:
	return float(POWER_MIN_MS + int(rng.randi() & 0x7fffffff) % (POWER_MAX_MS - POWER_MIN_MS)) / 1000.0


## BossShip::IncomingFire: the POWER SURGE warning (SpaceStatus::SetIncomingFire) in stages 2 / 3.
static func incoming_fire(state: Dictionary) -> bool:
	return int(state.get("stage", 1)) != 1 and \
		float(state.get("power_goal", 30.0)) - float(state.get("power_time", 0.0)) < INCOMING_FIRE


## BossShip::OnLoop for one unpaused frame while the ship is neither dying nor jumping: crew snapshot, then
## TimerHelper::Done (surge, new goal) before TimerHelper::Update. Returns the surge started ("" none).
static func loop(state: Dictionary, es: ShipState, seconds: float, rng: RandomNumberGenerator,
		difficulty: int) -> String:
	tick_super_drones(es)
	if es.is_destroyed() or es.jumping:
		return ""
	state.crew_counts = crew_counts(es)
	var surge := ""
	if float(state.power_time) > float(state.power_goal):  # Done(): loop timer -> restart with a new goal
		state.power_time = 0.0
		state.power_goal = _goal(rng)
		match int(state.stage):
			2:
				prepare_super_drones(es, difficulty, rng)
				surge = "drones"
			3:
				if int(state.power_count) % SHIELD_EVERY == SHIELD_EVERY - 1:
					SuperShieldRule.power(es, SuperShieldRule.FLAGSHIP_POINTS)
					surge = "shield"
				else:
					prepare_super_barrage(es, rng)
					surge = "barrage"
				state.power_count = int(state.power_count) + 1
	state.power_time = float(state.power_time) + seconds
	if surge != "":
		Combat.log("FLAGSHIP stage %d power surge: %s" % [int(state.stage), surge])
	return surge


## ShipManager::CountCrewShipId per room: the flagship's own living crew in each room.
static func crew_counts(es: ShipState) -> Array:
	var out := []
	out.resize(es.layout.rooms.size())
	out.fill(0)
	for c in es.crew:
		if c.is_alive() and not c.player_owned and not c.is_drone() and c.room >= 0 and c.room < out.size():
			out[c.room] += 1
	return out


# ------------------------------------------------------------------ surges

## PrepareSuperBarrage: 7 LASER_HEAVY_1 blasts from the ship centre, random heading, damage 1, each toward a random
## room of the target (ShipManager::superBarrage, released by GetNextShot -> Combat._launch_shards).
static func prepare_super_barrage(es: ShipState, rng: RandomNumberGenerator) -> void:
	if es.opponent == null:
		return
	var b := es.rooms_bounds()
	var center := Vector2(floorf(b.position.x + b.size.x / 2.0), floorf(b.position.y + b.size.y / 2.0))
	for i in BARRAGE_SHOTS:
		es.pending_shards.append({"from": center, "heading": float(int(rng.randi() & 0x7fffffff) % 360),
			"weapon": BARRAGE_WEAPON, "damage": BARRAGE_DAMAGE, "owner": 1})


static func super_drones(ship: ShipState) -> Array:
	return ship.get_meta("super_drones", []) if ship != null else []


## Deployed surge drones (SpaceManager drone list: they arrive through newDroneArrivals).
static func deployed_super_drones(ship: ShipState) -> Array:
	return super_drones(ship).filter(func(d): return d.deployed)


## PrepareSuperDrones: 7 drones created the first time (COMBAT_1 or COMBAT_BEAM, 50/50, no power needed); each
## surge powers and deploys the first 4 / 6 / 7 (easy / normal / hard) toward the target with a 2-shot lifespan.
static func prepare_super_drones(es: ShipState, difficulty: int, rng: RandomNumberGenerator) -> void:
	var list := super_drones(es)
	if list.is_empty():
		for i in SUPER_DRONES:
			var n := "COMBAT_1" if int(rng.randi() & 0x7fffffff) % 2 == 1 else "COMBAT_BEAM"
			var bp := FtlData.drone_blueprint(n).duplicate()
			bp.power = 0
			list.append(Drone.new(bp, es, 100 + i))
		es.set_meta("super_drones", list)
	var n: int = SURGE_DRONES[clampi(difficulty, 0, 2)]
	for i in mini(n, list.size()):
		var d: Drone = list[i]
		d.powered = true
		if not d.deployed or d.dead:
			d.deployed = true
			d.on_deploy()
		d.target_ship = es.opponent
		d.lifespan = SURGE_LIFESPAN
	FtlData.play("droneLaunch")


## ShipManager::SaveSuperDrones (ExportBattleState, mid-fight save): per surge drone its blueprint name, the drone
## state (SaveState: flight data, not kept here like other drones), deployed, destroyed, powered. Ours also keeps
## the shots left (lifespan) and the target side.
static func save_super_drones(ship: ShipState) -> Array:
	return super_drones(ship).map(func(d): return {"name": String(d.bp.get("name", "")), "deployed": d.deployed,
		"dead": d.dead, "powered": d.powered, "lifespan": d.lifespan})


## ShipManager::LoadSuperDrones (ImportBattleState): a drone per entry from its blueprint (power requirement 0),
## SetDeployed / SetDestroyed / SetPowered from the save, and a deployed one goes back into space through
## newDroneArrivals (our `on_deploy`, aimed at the opponent). Call once the opponent is set (ShipSave.redeploy).
static func load_super_drones(ship: ShipState, saved: Array) -> void:
	var list := []
	for e in saved:
		var bp := FtlData.drone_blueprint(String(e.get("name", "")))
		if bp.is_empty():
			continue
		bp = bp.duplicate()
		bp.power = 0
		var d := Drone.new(bp, ship, 100 + list.size())
		d.powered = bool(e.get("powered", false))
		if bool(e.get("deployed", false)) and not bool(e.get("dead", false)):
			d.deployed = true
			d.on_deploy()  # resets lifespan: restored below
			d.target_ship = ship.opponent
		d.lifespan = int(e.get("lifespan", SURGE_LIFESPAN))
		list.append(d)
	ship.set_meta("super_drones", list)


## Surge drones that used their shots (or were shot down) leave space; a dying flagship's are depowered.
static func tick_super_drones(es: ShipState) -> void:
	for d in super_drones(es):
		if es.is_destroyed():
			d.powered = false
		if d.dead and d.deployed:
			d.on_undeploy()
			d.deployed = false
			d.dead = false
			d.powered = false
		elif d.dead:
			d.dead = false


# ------------------------------------------------------------------ stalemate (ShipAI::OnLoop, bBoss)

## Stalemate trigger (WorldManager::OnLoop): the player cannot leave (engines or piloting without power, or no
## fuel) and none of the player's crew are aboard the flagship. While it holds the flagship counts up; a hull change
## caps the timer at 60 s; at 120 s it jumps (JumpLeave). It also starts escaping (escapeTimer >= 90 s of engine
## charge). Returns true when the jump starts.
static func stalemate(state: Dictionary, es: ShipState, player: ShipState, seconds: float) -> bool:
	if es.is_destroyed() or es.jumping or player == null:
		return false
	var e := player.sys("engines")
	var p := player.sys("pilot")
	var stuck := e == null or p == null or e.get_level() - e.power_loss <= 0 or p.get_level() - p.power_loss <= 0 \
		or player.fuel < 1
	if stuck:
		for c in es.crew:
			if c.is_alive() and c.player_owned:
				stuck = false
				break
	if not stuck:
		state.stalemate = 0.0
		state.last_hull = es.hull
		return false
	if not bool(state.get("escaping", false)):
		state.escaping = true
		state.escape_timer = maxf(float(state.get("escape_timer", 15.0)), STALEMATE_ESCAPE)
	state.stalemate = float(state.get("stalemate", 0.0)) + seconds
	if es.hull != int(state.get("last_hull", es.hull)):
		state.stalemate = minf(float(state.stalemate), STALEMATE_HIT_CAP)
	state.last_hull = es.hull
	if FtlDrive.ship_flying(es):
		state.escape_timer = float(state.escape_timer) - seconds
	return float(state.stalemate) >= STALEMATE_JUMP or float(state.escape_timer) < 0.0
