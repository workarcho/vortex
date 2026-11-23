class_name RunState
extends RefCounted
## A run (rules/starmap.md, rules/events.md, rules/store.md, rules/ftl_drive.md, rules/hazards.md,
## rules/ship_destruction.md §6): seed, the 8-sector tree, the current sector's beacon map and rebel fleet,
## resources (on the player ShipState: fuel / scrap / missiles / drone parts), cargo, the event dialog, the event
## ship, the store, the beacon's hazard and the run end. Pure rules: the UI reads this state and sends intents
## (`apply`); the combat scene reports the enemy ship's fate through `check_combat`.

enum Phase { IDLE, DIALOG, MESSAGE }

## Box codes of store intents: section × 3 + box (0..11); resources and repair below.
const BOX_FUEL := 100
const BOX_MISSILES := 101
const BOX_DRONES := 102
const BOX_REPAIR_ONE := 110
const BOX_REPAIR_ALL := 111
const RES_BOXES := {BOX_FUEL: "fuel", BOX_MISSILES: "missiles", BOX_DRONES: "drones"}

## The active run, kept across scene rebuilds (main.gd reloads the scene on arrival / new event ship).
static var current: RunState = null

var seed := 0
var rng := RandomNumberGenerator.new()  # run stream: sector seeds, stores, no-fuel seeds
var engine: EventEngine
var ship: ShipState  # the player ship (persists across beacons)
var cargo: Array = []  # the 4 cargo boxes, positional: weapon / drone names, "" = empty box (ShipInventory)
var mgmt := ShipManagement.new()  # ship screens + equipment inventory (rules/ship_management.md)
var sector := 0  # worldLevel (0-based)
var sector_desc := ""
var sector_name := ""
var tree: SectorTree
var sector_id := 0  # current sector in the tree
var map: StarMap
var fleet: RebelFleet
var current_beacon := -1
var selected := -1  # potentialLoc: beacon picked on the map (hover on PC, tap on touch)
var map_open := false
## CommandGui leaveCrewDialog (ConfirmWindow `confirm_leave_crew`): the FTL button / jump hotkey with own crew
## aboard the enemy ship asks first; YES opens the star map, NO closes it (rules/ftl_drive.md §4.4).
var leave_crew_open := false
var choosing_sector := false  # sector map open in choice mode (bChoosingNewSector)
var selected_sector := -1
var phase := Phase.IDLE
var dialog := {}  # LocationEvent on screen
var dialog_choices: Array = []  # [{index (in dialog.choices), text, enabled, blue, preview, event}]
var dialog_rewards: Array = []  # reward box of the open event [[kind, amount or name]] (applied on the choice)
var highlighted := -1  # touch: first tap on a choice
var messages: Array = []  # message boxes (quests, last stand placeholder, ...)
var enemy := {}  # event ship: {ship_ev, blueprint, plan, hostile, surrendered, escaping, escape_timer, done, ...}
var enemy_serial := 0  # bumped when a new event ship appears (the scene is rebuilt)
var arrival_serial := 0  # bumped on every arrival (the scene is rebuilt)
var distress := false  # out of fuel: distress beacon toggle
var store_open := false
var store_pending := false  # open the store when the arrival dialog closes
var store_selected := -1  # touch: selected box code
var store_page := 0
var store_tab := 0  # 0 buy, 1 sell
var store_message := ""  # last purchase result ("scrap", "max_weapons", ...)
var hazard: HazardRule = null  # the current beacon's environment
## The current location's backdrop (rules/backgrounds.md; drawn by SpaceBackdrop): {back (img path, "" = none),
## planet ({} or {img, pos, size, rot}), fleet ([{img, pos}]), danger (0..3), pds_planet ({} or as planet),
## cloud_seed}. Picked at arrival from `space_rng`, an own stream re-seeded per arrival from (run seed, sector,
## beacon, visit) so every beacon of a seed gets its own space without touching the gameplay streams; a beacon
## keeps its background + planet in `beacon().space` for later visits.
var space := {}
var space_rng := RandomNumberGenerator.new()
var space_back := ""  # SpaceManager::currentBack (path): the next pick must differ from it
var space_planet := ""  # SpaceManager::currentPlanet (path, "" = none)
var env := -1
var _arrival_env_done := false  # show_event of the arrival event: its environment was set by _arrive
var over := ""  # "" running, "gameover", "victory"
var frozen_settings := {}  # Settings.freeze_run() snapshot taken when the run started (gameplay settings)
var over_text := ""
var over_cause := ""  # GameOver text id (gameover_crew / gameover_blowup / gameover_win ...; rules/score_and_game_over.md)
var score := ScoreKeeper.new()  # run score + stats (rules/score_and_game_over.md §1–2)
var stats := {"beacons": 0, "ships": 0, "scrap": 0, "scrap_spent": 0, "crew_hired": 0, "sectors": 1}
var crew_seed := -1  # WorldManager::lastSelectedCrewSeed (event crew loss pick; -1 = roll on the next loss)
var clone_text := ""  # clone text of the last crew loss with a clonebay installed (replaces the dialog)
var lost_crew_flag := false  # vanilla "lost_crew" flag set here too (AchievementTracker counts it from crew_removed)
## Quests and the Crystal secret sector (rules/events.md §2.4 / §2.6, rules/starmap.md "Quests", "Secret sector").
## Run-level state to serialize (beacon `quest` flags live on the map beacons):
var delayed_quests: Array[String] = []  # StarMap::delayedQuests: quest events placed (force) at the next sector start
var secret_sector := false  # StarMap::bSecretSector: the current sector is CRYSTAL_HOME (sector number shown "?")
var ruwen_flag := false  # AchievementTracker flag "ruwen": a crew member named name_Ruwen joined this run
var unlocked_ships: Array[int] = []  # <unlockShip id> earned this run (ScoreKeeper::UnlockShip; profile: ProfileTracker)
## Save / profile (rules/save_and_profile.md): every variable here except SaveGame.RUN_SKIP is saved by name, so a
## new plain-data field needs nothing else. `track` = this run's ProfileTracker counters.
var track := {}
## The Last Stand's boss state (StarMap bossLevel / boss path + BossShip stage, timers; LastStand, rules/flagship.md).
## Empty outside sector 8.
var boss := {}
var log: Array[String] = []


## New run (StarMap::NewGame): player ship `ship_name`, the sector tree, first sector = STANDARD_SPACE renamed
## "Civilian Sector", START_GAME at the start beacon, which is shown at once.
static func new_run(run_seed: int, ship_name := "PLAYER_SHIP_HARD", difficulty := EventEngine.Difficulty.NORMAL,
		desc := "", ae := true) -> RunState:
	var r := RunState.new()
	# Gameplay settings are frozen into the run before anything is built (rules/hooks.md "Settings").
	r.frozen_settings = Settings.freeze_run()
	r.seed = run_seed
	r.rng.seed = run_seed
	r.engine = EventEngine.new()
	r.engine.difficulty = difficulty
	r.engine.ae = ae  # hangar "Advanced Edition Content" (Settings::bDlcEnabled)
	# Crew names / genders / colours (rules/crew_appearance.md): own stream, seeded from the run seed so a seed
	# replays the same crew; the identities live on the CrewMembers of `r.ship` for the whole run.
	CrewIdentity.rng.seed = hash([run_seed, "crew"])
	r.ship = ShipState.new(ship_name, true)
	r.ship.ship_title = TitleState.ship_title(ship_name)
	r.tree = SectorTree.generate(int(r.rng.randi() & 0x7fffffff), r.engine.db, r.engine.ae)
	r.sector_id = 0
	r.tree.sectors[0].visited = true
	r.score.reset(int(difficulty))  # ScoreKeeper::Reset + SetSector(1) (EventEngine.Difficulty 0 easy / 1 / 2 hard)
	r.enter_sector(0, desc if desc != "" else RunTuning.name_of("first_sector"), true)
	r.score.add_crew(r.ship.crew.filter(func(c): return c.player_owned and not c.is_drone()).size())  # start crew
	ProfileTracker.ensure()  # profile listeners (rules/save_and_profile.md §2)
	Hooks.emit(&"run_started", r)
	return r


## Sector entry: currentSectorSeed = rand() from the run stream, map + events generated from it, a new fleet.
func enter_sector(level: int, desc_name: String, first_of_run := false) -> void:
	sector = level
	engine.level = level
	sector_desc = desc_name
	var desc: XmlNode = engine.db.sectors.get(desc_name)
	var sector_seed := int(rng.randi() & 0x7fffffff)
	map = StarMap.generate(sector_seed, desc, engine, RunTuning.name_of("start_game") if first_of_run else "")
	var fm: Variant = Hooks.filter(&"map_generated", map, self, level)
	if fm is StarMap:
		map = fm
	_place_sector_quests()
	fleet = RebelFleet.start(engine.rng)
	if ship.has_augment("FLEET_DISTRACTION") and level < 7:
		fleet.pursuit_delay -= 1  # AE: the sector's first event has modifyPursuit −1
	if first_of_run:
		sector_name = engine.tr_text(RunTuning.name_of("first_sector_name"))
	elif secret_sector or tree == null or sector_id < 0:
		var nl := desc.child("nameList") if desc else null
		var names := nl.children_named("name") if nl else []
		sector_name = engine.tr_text(names[0].attr("id")) if not names.is_empty() else desc_name
	elif tree != null and sector_id >= 0:
		sector_name = tree.sectors[sector_id].name
	else:
		var nl := desc.child("nameList") if desc else null
		var names := nl.children_named("name") if nl else []
		sector_name = engine.tr_text(names[0].attr("id")) if not names.is_empty() else desc_name
	current_beacon = map.start
	selected = -1
	Hooks.emit(&"sector_entered", self, level, desc_name)
	_arrive(false)


# ------------------------------------------------------------------ queries

func modal() -> bool:
	return map_open or leave_crew_open or choosing_sector or store_open or phase != Phase.IDLE or over != "" or mgmt.open


func beacon() -> Dictionary:
	return map.beacon(current_beacon)


func has_hostile() -> bool:
	return not enemy.is_empty() and enemy.hostile and not enemy.done


func ftl_ready() -> bool:
	return ship.ftl_charge >= 1.0


## FTL button active (CommandGui::OnLoop): not during the run end; in combat only with fuel.
func ftl_button_active() -> bool:
	return over == "" and (not has_hostile() or ship.fuel > 0)


## WorldManager::HostileEnvironment: a dangerous hazard (SpaceManager::DangerousEnvironment: sun, pulsar,
## asteroids, PDS aimed at the player) or hostile crew aboard (iIntruderCount: boarders, boarding drones, own crew
## mind-controlled by the enemy; ContainsMindControlledEnemy: an enemy boarder we mind-control).
func hostile_environment() -> bool:
	if hazard != null and hazard.is_dangerous():
		return true
	for c in ship.crew:
		if c.is_alive() and (c.is_intruder(ship) or not c.player_owned):
			return true
	return false


## WorldManager::OnLoop → ShipManager::SetSafe: no hostile ship and no hostile environment = FTL always full.
func ftl_safe() -> bool:
	return not has_hostile() and not hostile_environment()


## CommandGui::dangerLocation (WorldManager::OnLoop): a hostile ship, else HostileEnvironment. Blocks the SHIP
## (upgrade) button and hides / disables the STORE button.
func in_danger() -> bool:
	return has_hostile() or hostile_environment()


## ShipManager::CountPlayerCrew on the enemy ship: own (player-side) crew aboard it (alive, not drones [inferred]).
func crew_aboard_enemy() -> int:
	if ship.opponent == null:
		return 0
	return ship.opponent.crew.filter(func(c): return c.is_alive() and c.player_owned and not c.is_drone()).size()


## The FTL button opens the star map (FTLButton::MouseClick / OnTouch, CommandGui::KeyDown "jump"): button active,
## drive charged, engines and piloting functioning (ShipManager::SystemFunctions: a manned, powered pilot seat and
## powered engines), and nothing modal in front. Holds with or without an enemy.
func can_open_map() -> bool:
	return phase == Phase.IDLE and not store_open and ftl_ready() and ftl_button_active() 		and FtlDrive.jump_systems_ok(ship)


## The map's potentialLoc is valid: a neighbour of the current beacon, fuel ≥ 1.
func can_target(id: int) -> bool:
	if id < 0 or id == current_beacon or ship.fuel < 1:
		return false
	# FTL_JUMPER (StarMap::MouseMove/OnTouch): any visited beacon is a valid target too.
	return map.connected(current_beacon, id) or (AugmentRule.has(ship, "FTL_JUMPER") and map.beacons[id].visited > 0)


## The map's jump: vanilla does not re-check here (the open map pauses the game, so nothing can change), the
## engines / pilot test is repeated anyway so no path can jump without them.
func can_jump() -> bool:
	return can_target(selected) and ftl_ready() and phase == Phase.IDLE and FtlDrive.jump_systems_ok(ship)


func at_exit() -> bool:
	return current_beacon == map.exit


## Out of fuel: wait / distress buttons instead of jumping (not while a hostile ship is present).
func can_wait() -> bool:
	if LastStand.active(self):
		return LastStand.can_wait(self)  # StarMap::OnLoop: in the boss level also with fuel, no ship present
	return ship.fuel < 1 and not has_hostile() and phase == Phase.IDLE


## Last sector reached (the Last Stand: no NEXT SECTOR).
func is_last_sector() -> bool:
	return LastStand.active(self) or (tree != null and sector_id == tree.final_id())


func environment() -> int:
	return env


func store() -> RunStore:
	return beacon().shop if map != null else null


# ------------------------------------------------------------------ intents

func apply(intent: Dictionary) -> bool:
	var arg := int(intent.get("arg", -1))
	if over != "":
		return false
	if LastStand.waiting(self) and String(intent.type) in LastStand.WAIT_BLOCKED:
		return false  # boss-level WAIT animation running (StarMap waiting: map input ignored)
	match String(intent.type):
		RunIntent.OPEN_MAP:
			if not can_open_map() or leave_crew_open:
				return false
			if crew_aboard_enemy() > 0:  # CommandGui::LButtonDown / KeyDown: ask before leaving them behind
				leave_crew_open = true
				return true
			map_open = true
			selected = -1
			return true
		RunIntent.LEAVE_CREW_CONFIRM:
			if not leave_crew_open:
				return false
			leave_crew_open = false
			if arg == 1:  # YES: the star map opens (no re-check: the window paused the game)
				map_open = true
				selected = -1
			return true
		RunIntent.CLOSE_MAP:
			map_open = false
			selected = -1
			return true
		RunIntent.SELECT_BEACON:
			if not map_open:
				return false
			selected = arg if can_target(arg) else -1
			return selected == arg
		RunIntent.CONFIRM_JUMP:
			if not map_open or not can_jump():
				return false
			jump_to(selected)
			return true
		RunIntent.NEXT_SECTOR:
			if not map_open or not at_exit() or phase != Phase.IDLE or ship.fuel < 1 or is_last_sector():
				return false
			if secret_sector:
				leave_secret_sector()  # no sector choice from the secret sector
				return true
			map_open = false
			choosing_sector = true
			selected_sector = -1
			return true
		RunIntent.SELECT_SECTOR:
			if not choosing_sector:
				return false
			selected_sector = arg if arg in tree.neighbours(sector_id) else -1
			return selected_sector == arg
		RunIntent.CONFIRM_SECTOR:
			if not choosing_sector or selected_sector < 0:
				return false
			go_to_sector(selected_sector)
			return true
		RunIntent.CLOSE_SECTOR_MAP:
			choosing_sector = false
			selected_sector = -1
			return true
		RunIntent.WAIT:
			if not can_wait():
				return false
			wait()
			return true
		RunIntent.TOGGLE_DISTRESS:
			if ship.fuel >= 1:
				return false
			distress = not distress
			return true
		RunIntent.HIGHLIGHT_CHOICE:
			if phase != Phase.DIALOG:
				return false
			highlighted = arg
			return true
		RunIntent.CHOOSE:
			return choose(arg)
		RunIntent.CONTINUE:
			if phase != Phase.MESSAGE:
				return false
			messages.pop_front()
			if messages.is_empty():
				phase = Phase.IDLE
				_after_dialog()
			return true
		RunIntent.OPEN_STORE:
			if store() == null or phase != Phase.IDLE or map_open or in_danger():
				return false
			store_open = true
			store_selected = -1
			store_message = ""
			store_tab = 0  # TabbedWindow::Open → SetTab(0): always the BUY tab
			return true
		RunIntent.CLOSE_STORE:
			if store() != null:
				store().confirm(false, self)
			store_open = false
			store_selected = -1
			return true
		RunIntent.STORE_SELECT:
			if not store_open:
				return false
			store_selected = arg
			return true
		RunIntent.STORE_BUY:
			return store_buy(arg) == "ok"
		RunIntent.STORE_CONFIRM:
			if not store_open:
				return false
			store_message = store().confirm(arg == 1, self)
			return store_message == "ok"
		RunIntent.STORE_PAGE:
			store_page = clampi(arg, 0, 1)
			store_selected = -1
			return store_open
		RunIntent.STORE_TAB:
			store_tab = clampi(arg, 0, 1)
			store_selected = -1
			return store_open
		RunIntent.STORE_SELL:
			if not store_open:
				return false
			var items := RunStore.sellable(self)
			if arg < 0 or arg >= items.size():
				return false
			store_message = RunStore.sell(items[arg], self)
			store_selected = -1
			return store_message == "ok"
	return mgmt.apply(self, intent)  # ship screens / equipment / sell by drag (ShipManagement)


## A store box by code: buy (sections), one unit (resources), repair.
func store_buy(code: int) -> String:
	var st := store()
	if not store_open or st == null or not st.pending_confirm.is_empty():
		return "none"
	var res := ""
	if RES_BOXES.has(code):
		res = st.buy_resource(RES_BOXES[code], self)
	elif code == BOX_REPAIR_ONE or code == BOX_REPAIR_ALL:
		res = st.repair(code == BOX_REPAIR_ALL, self)
	else:
		var o := st.offer(code / 3, code % 3)
		res = st.buy(code / 3, code % 3, self)
		if res == "ok" and String(o.get("kind", "")) == "crew":
			stats.crew_hired = int(stats.crew_hired) + 1
			score.add_crew()  # CrewStoreBox::Purchase
	store_message = res
	if res == "ok":
		store_selected = -1
	elif res == "scrap":
		FtlData.play("powerUpFail")
	return res


# ------------------------------------------------------------------ jumping (§5) and the fleet (§4)

## GetNewLocation + JumpLeave + JumpArrive: the fleet advances (from the beacon being left), fuel −1, the
## beacon becomes current (visited, neighbours known), the old location is cleared, FTL charge 0, then the
## location's event.
func jump_to(id: int) -> void:
	var to: Variant = Hooks.filter(&"before_jump", id, self)
	if Hooks.is_cancel(to):
		return
	id = int(to)
	map_open = false
	selected = -1
	beacon()["ship_left"] = has_hostile()  # map: red triangle on a visited beacon with a hostile ship left alive
	_advance_fleet(beacon())
	ship.fuel = maxi(ship.fuel - 1, 0)
	current_beacon = id
	stats.beacons = int(stats.beacons) + 1
	_log("jump to beacon %d (fuel %d, fleet x %d)" % [id, ship.fuel, int(fleet.center.x)])
	_clear_location()
	_arrive(true)


## UpdateDangerZone (+ TurnIntoFleetLocation of every newly covered beacon).
func _advance_fleet(leaving: Dictionary) -> void:
	if LastStand.active(self):
		LastStand.update_boss(self)  # boss level: no fleet move / sweep, the flagship's turn instead
		return
	var nebula_sector := false
	var d: XmlNode = engine.db.sectors.get(sector_desc)
	if tree != null and sector_id >= 0:
		nebula_sector = tree.sectors[sector_id].cls == "NEBULA"
	elif d:
		nebula_sector = sector_desc.contains("NEBULA")
	fleet.advance(bool(leaving.get("nebula", false)), nebula_sector)
	for bid in fleet.newly_covered(map):
		RebelFleet.overtake(map, bid, engine)


## Out of fuel, Wait (StarMap wait button → ShipManager::Wait): the fleet makes one move, then SetupNoFuel puts
## NO_FUEL / NO_FUEL_DISTRESS / NO_FUEL_FLEET(_DLC) (overtaken) on the current beacon, seeded by a fresh
## fuelEventSeed, and the ship "arrives" again at the same beacon.
func wait() -> void:
	if LastStand.wait(self):
		return
	map_open = false
	selected = -1
	_advance_fleet(beacon())
	var b := beacon()
	var names: Dictionary = RunTuning.section("fleet").names
	var n := String(names.no_fuel_distress if distress else names.no_fuel)
	if b.fleet:
		n = String(names.no_fuel_fleet)
		if engine.ae and engine.db.has_event_or_list(n + "_DLC"):
			n += "_DLC"
	b.event = engine.base_event(n, int(rng.randi() & 0x7fffffff))
	b.event_fresh = true
	_log("wait (fuel 0): %s, fleet x %d" % [n, int(fleet.center.x)])
	_clear_location(true)
	_arrive(false)


## WorldManager::ClearLocation: own crew still aboard the ship at the beacon (CountCrew(enemy, true) > 0 -> flag
## `lost_crew`) die with it: KillEveryone(noClone = true) -> never cloned, gone from the crew list
## (rules/teleporter.md "Crew left behind"). The "leave crew behind?" confirm comes before (ftl_drive.md §4.4).
func _lose_crew_left_aboard(es: ShipState) -> void:
	if es == null or es == ship:
		return
	for c in es.crew.duplicate():
		if not c.player_owned or c.is_drone() or not c.is_alive():
			continue
		ClonebayRule.kill_no_clone(c)
		c.death_sound_done = true
		es.crew.erase(c)
		es.teleporting.erase(c)
		ship.clone_queue.erase(c)
		lost_crew_flag = true  # AchievementTracker "lost_crew"
		Hooks.emit(&"crew_removed", ship, c, false)
		_log("crew %s left behind aboard the %s: lost" % [c.display_name(), es.blueprint.get("name", "ship")])
	es.crew_changed()


## `waited`: ShipManager::Wait (out of fuel) instead of JumpLeave + JumpArrive: its lock clearing is unconditional.
func _clear_location(waited := false) -> void:
	enemy = {}
	store_open = false
	store_pending = false
	mgmt.on_jump(self)  # Equipment::Jump: over-capacity items are left behind
	_lose_crew_left_aboard(ship.opponent)
	ship.opponent = null
	ship.teleporting.clear()
	ship.jumping = false
	ship.ftl_charge = 0.0
	# JumpArrive empties the timer; the first ShipManager::OnLoop after it (before WorldManager's SetSafe refills it)
	# sees it empty, so a safe beacon rings jumpReady again once the game runs. ShipManager::Wait leaves the timer
	# alone (out of fuel it stays full: no ring).
	if not waited:
		ship.last_jump_ready = false
	ship.reactor_divide = 1
	var sens := ship.sys("sensors")
	if sens and (env in [HazardRule.Env.NEBULA, HazardRule.Env.STORM] \
			or (hazard != null and hazard.has_env(HazardRule.Env.NEBULA))):  # also a nebula added by an outcome
		ship.set_power_loss("sensors", 0)
	ship._check_reactor()
	DroneSystemRule.jump(ship)
	CloakRule.jump(ship)
	BatteryRule.jump(ship)
	ArtilleryRule.jump(ship)
	MindRule.jump(ship)
	HackingRule.stop(ship)
	ClonebayRule.jump_heal(ship)
	AugmentRule.jump_weapons(ship)  # WeaponSystem::Jump: charge lost unless WEAPON_PREIGNITE (powered ones)
	SuperShieldRule.jump(ship)  # Shields::Jump: ENERGY_SHIELD refills to 5, a drone super shield is lost
	# JumpArrive with bWasSafe (the beacon left was safe at some point) / Wait: mind control ready, ion locks on
	# shields, engines, weapons and piloting cleared; bWasSafe reset.
	ship.arrive_locks(waited)
	# JumpArrive (not Wait): CrewMember::Jump on every crew member aboard -> ResetPower (vtable 0x33): a crystal's
	# lockdown is fully recharged on arrival. This is the only refill; being safe / out of combat does not touch it.
	if not waited:
		for c in ship.crew:
			c.reset_power()
	for w in ship.weapons:
		w.clear_target()
	for c in ship.crew.duplicate():
		if c.player_owned and not c.is_alive():
			ship.crew.erase(c)
	ship.crew_changed()
	hazard = null
	env = -1
	crew_seed = -1  # choiceHistory cleared on the jump


func _arrive(count_visit: bool) -> void:
	crew_seed = -1  # CreateLocation clears choiceHistory -> lastSelectedCrewSeed = -1
	var b := beacon()
	if count_visit:
		b.visited += 1
		b.quest = false  # StarMap::GetNewLocation: questLoc cleared on arrival
		b.known = true
		for n in b.links:
			map.beacons[n].known = true
	arrival_serial += 1
	# WorldManager::CreateLocation: the beacon's event; a revisited beacon has nothing left [inferred] except
	# its store; a fresh event (fleet, no fuel) fires again.
	var ev: Dictionary = b.event
	if b.visited > 1 and not b.event_fresh:
		ev = engine.new_event("REVISIT")
		ev.store = b.event.get("store", false)
		ev.choices = [{"text": engine.tr_text("continue"), "req": "", "lvl": 1, "max_lvl": 1 << 30,
			"max_group": -1, "blue": false, "hidden": true, "event": {}}]
	b.event_fresh = false
	ev = LastStand.location_event(self, b, ev)  # the flagship's beacon: BOSS_TEXT_n + the next stage
	if not b.get("fleet", false):
		score.add_explored_location()  # CreateLocation, unless overtaken (fleetPosition 1)
	# Environment: the event's <environment>, else the nebula of the beacon (ModifyEnvironment).
	env = int(ev.get("environment", -1))
	var own_env: bool = not ev.get("flagship", false)  # BossShip::GetEvent: only its own (empty) environment
	if env < 0 and b.nebula and own_env:
		env = HazardRule.Env.NEBULA
	if env < 0 and b.event.get("environment", -1) != -1 and own_env:
		env = int(b.event.environment)
	b.env = env
	if env >= 0:
		var sh := ship.sys("shields")
		hazard = HazardRule.create(env, int(ev.get("env_target", 2)), int(rng.randi() & 0x7fffffff),
			sh.get_level() if sh else 0)
		hazard.apply_status(ship)
	_choose_space(b)
	if hazard != null and hazard.env == HazardRule.Env.PDS:
		hazard.pds_origin = HazardRule.pds_origin_for(space)  # the ASB gun: planet, or the fleet's gun ship
	Hooks.emit(&"beacon_arrived", self, current_beacon)
	_arrival_env_done = true  # CreateLocation called ModifyEnvironment once (above); UpdateLocation is for later events
	show_event(ev)
	_arrival_env_done = false
	if b.event.get("store", false) or ev.get("store", false):
		_open_store_later()
	_update_ftl_safe()


## WorldManager::CreateLocation's images (rules/backgrounds.md §3): the first arrival draws the background
## (SwitchBackground) and the planet (SwitchPlanet) from the location event's lists and keeps them on the
## beacon; later arrivals restore them (SwitchImages). Every arrival then sets the fleet danger zone
## (SetDangerZone, fleetPosition of the location event; 1 on a beacon the fleet overtook) and, at an ASB beacon
## outside the danger zone, the populated planet (SetPlanetaryDefense). The pulsar replaces the background
## (SetPulsarLevel). Nebula clouds are seeded here and simulated by the view.
func _choose_space(b: Dictionary) -> void:
	var lists: Dictionary = engine.db.image_lists
	var lev: Dictionary = b.event
	space_rng.seed = hash([seed, "space", sector, sector_id, current_beacon, int(b.get("visited", 0))])
	var loc: Dictionary = b.get("space", {})
	if loc.is_empty():
		var back := SpaceImages.switch_background(lists, String(lev.get("back", SpaceImages.DEFAULT_BACK)),
			space_back, space_rng)
		var planet := SpaceImages.switch_planet(lists, String(lev.get("planet", SpaceImages.DEFAULT_PLANET)),
			space_planet, space_rng)
		loc = {"back": back, "planet": planet}
		if back != "" or not planet.is_empty():  # both unset: the next visit draws again
			b.space = loc
	if String(loc.back) != "":
		space_back = loc.back
	var planet_now: Dictionary = loc.planet
	var danger := int(lev.get("fleet_pos", 0))
	if danger == 0 and b.get("fleet", false):
		danger = 1  # StarMap::TurnIntoFleetLocation: fleetPosition = 1
	space = {"back": space_back, "planet": planet_now, "danger": danger,
		"fleet": SpaceImages.danger_zone(danger, space_rng), "pds_planet": {},
		"cloud_seed": int(space_rng.randi() & 0x7fffffff)}
	if env == HazardRule.Env.PDS and danger == 0:
		space.pds_planet = SpaceImages.pds_planet(engine.db.image_lists, space_rng)
		if not space.pds_planet.is_empty():
			planet_now = space.pds_planet
	space_planet = String(planet_now.get("img", ""))
	if env == HazardRule.Env.PULSAR:
		space_back = SpaceImages.PULSAR_BACK
	var fs: Variant = Hooks.filter(&"space_chosen", space, self, current_beacon)
	if fs is Dictionary:
		space = fs


func _open_store_later() -> void:
	var b := beacon()
	if b.shop == null:
		var rarity := {}
		for k in engine.db.rarity:
			rarity[k] = engine.db.rarity[k].duplicate()
			for n in engine.crew_rarity:
				if rarity[k].has(n):
					rarity[k][n] = engine.crew_rarity[n]
		b.shop = RunStore.generate(rng, ship, sector, engine.ae, rarity)
		var fs: Variant = Hooks.filter(&"store_generated", b.shop, self)
		if fs is RunStore:
			b.shop = fs
		_log("store generated: %s" % str(b.shop.sections.map(func(s): return RunStore.KINDS[s.type])))
	# The store does not open by itself: the arrival event text shows first and the HUD STORE button appears
	# (vanilla 1.6.14 screenshot 69; rules/store.md §1). store_pending stays false.


## After the arrival dialog: the store window opens (WorldManager::CreateStore → SetStore(open)).
func _after_dialog() -> void:
	if store_pending and phase == Phase.IDLE and not has_hostile() and store() != null:
		store_pending = false
		store_open = true
		store_selected = -1


# ------------------------------------------------------------------ sectors (§1)

## SelectNewSector + AdvanceWorldLevel + GenerateMap of the chosen neighbour.
func go_to_sector(id: int) -> void:
	choosing_sector = false
	selected_sector = -1
	if not id in tree.neighbours(sector_id):
		return
	_travel_to_sector(id)


## The jump into sector `id` of the tree (fuel −1, location cleared, AdvanceWorldLevel + GenerateMap); the final
## sector starts the Last Stand placeholder.
func _travel_to_sector(id: int) -> void:
	map_open = false
	secret_sector = false
	ship.fuel = maxi(ship.fuel - 1, 0)
	_clear_location()
	sector_id = id
	var s: Dictionary = tree.sectors[id]
	s.visited = true
	stats.sectors = int(stats.sectors) + 1
	stats.beacons = int(stats.beacons) + 1
	score.set_sector(int(s.level) + 1)
	_log("sector %d: %s (%s, %s)" % [s.level + 1, s.name, s.desc, s.cls])
	if id == tree.final_id():
		enter_last_stand()
		return
	enter_sector(int(s.level), String(s.desc))


# ------------------------------------------------------------------ quests + secret sector

## GenerateMap's tail (rules/starmap.md §2): ROCK_HOME with crystalAlienFound flags the ROCK_CRYSTAL_BEACON beacon
## as a quest; then the delayed quests of the previous sector are placed with AddQuest(force) from the start beacon
## (one that still finds no beacon is delayed again while worldLevel ≤ 5). Sector stream, after the events.
func _place_sector_quests() -> void:
	var t := RunTuning.section("quests")
	if sector_desc == String(t.rock_home) and crystal_alien_found():
		var id := map.mark_event_quest(String(t.rock_beacon))
		_log("rock home: crystal beacon %d marked as a quest" % id)
	var pending := delayed_quests.duplicate()
	delayed_quests.clear()
	var fc := Vector2(float(RebelFleet._t().start_x), float(RebelFleet._t().start_y))  # unused with force
	for q in pending:
		var id := map.add_quest(engine, q, map.start, fc, true)
		if id == StarMap.QUEST_NONE and sector <= int(t.max_delay_level):
			delayed_quests.append(q)
		_log("delayed quest %s -> beacon %d" % [q, id])


## WorldManager::OnLoop: crystalAlienFound = the player has a crystal crew member (HasEquipment("crystal")) and the
## run flag "ruwen" is set (ShipManager::AddCrewMember sets it for a crew member named name_Ruwen, the stasis pod
## crew of ZOLTAN_CREW_STUDY). Checked when a sector map is generated.
func crystal_alien_found() -> bool:
	_note_crew_names()
	return ruwen_flag and equipment_level(String(RunTuning.section("quests").crystal_race)) > 0


## The "ruwen" flag stand-in: set once any own crew member carries the localized name_Ruwen name (checked whenever
## an event is shown and at sector generation, instead of inside the crew-adding code).
func _note_crew_names() -> void:
	if ruwen_flag or ship == null:
		return
	var nm := engine.tr_text(String(RunTuning.section("quests").ruwen_name))
	for c in ship.crew:
		if c.player_owned and not c.is_drone() and (c.name_long == nm or c.display_name() == nm):
			ruwen_flag = true
			_log("run flag ruwen set")
			return


## WorldManager::UpdateLocation / CreateLocation, event `<quest event="X"/>`: AddQuest(X, force = false) from the
## current beacon against the fleet's current centre; the event text gets " \n\n" + added_quest (placed),
## added_quest_sector (worldLevel < 6; queued in delayed_quests unless the quest event did not exist) or no_time.
## Returns the beacon id or StarMap.QUEST_NONE / QUEST_NO_EVENT.
func add_event_quest(ev: Dictionary) -> int:
	var t := RunTuning.section("quests")
	var q := String(ev.quest)
	var fc := fleet.center if fleet != null else Vector2(float(RebelFleet._t().start_x), 0)
	var id := map.add_quest(engine, q, current_beacon, fc, false)
	if id == StarMap.QUEST_NONE and sector <= int(t.max_delay_level):
		delayed_quests.append(q)
	var key := String(t.text_added) if id >= 0 else \
		(String(t.text_next_sector) if sector <= int(t.max_delay_level) else String(t.text_no_time))
	ev.text = String(ev.get("text", "")) + " \n\n" + engine.tr_text(key)
	Hooks.emit(&"quest_added", self, q, id)
	_log("quest %s -> beacon %d (%s)" % [q, id, key])
	return id


## UpdateLocation, `<unlockShip id=N/>`: not yet unlocked (TitleState.unlocked stand-in for
## ScoreKeeper::GetShipUnlocked) → unlocked, " \n\n" + unlock_ship_N appended. Recorded in `unlocked_ships` either
## way for the profile (hook `ship_unlocked`).
func _unlock_ship(ev: Dictionary) -> void:
	var id := int(ev.get("unlock_ship", -1))
	if id < 0:
		return
	if not TitleState.new().unlocked(id, 0):
		ev.text = String(ev.get("text", "")) + " \n\n" + engine.tr_text("unlock_ship_%d" % id)
	if not id in unlocked_ships:
		unlocked_ships.append(id)
		Hooks.emit(&"ship_unlocked", self, id)
	_log("ship %d unlocked" % id)


## `<secretSector/>` → CommandGui::SetSecretSector → next CommandGui::OnLoop: StarMap::StartSecretSector
## (bSecretSector, currentSector = the CRYSTAL_HOME sector, ACH_ROCK_CRYSTAL) and the ship jumps at once to
## dummyNewSector (JumpLeave: fuel −1): a new map of CRYSTAL_HOME at the SAME worldLevel (no AdvanceWorldLevel, no
## sector choice). The event's own text box is hidden by the jump and replaced by the new start beacon's event.
func start_secret_sector() -> void:
	map_open = false
	choosing_sector = false
	ship.fuel = maxi(ship.fuel - 1, 0)
	_clear_location()
	secret_sector = true
	stats.beacons = int(stats.beacons) + 1
	_log("secret sector: %s at sector %d (achievement ACH_ROCK_CRYSTAL)" % [
		RunTuning.section("quests").secret_sector, sector + 1])
	Hooks.emit(&"secret_sector_entered", self)
	enter_sector(sector, String(RunTuning.section("quests").secret_sector))


## NEXT SECTOR at the secret sector's exit (StarMap::MouseClick endButton with bSecretSector): AdvanceWorldLevel
## (unless worldLevel is 7), then a uniformly random tree sector of the new level (any column member, not only
## neighbours; run stream), visited, entered directly — no sector choice. bSecretSector cleared.
func leave_secret_sector() -> void:
	var lv := sector + 1 if sector != int(RunTuning.section("quests").final_level) else sector
	var cands := []
	for s in tree.sectors:
		if int(s.level) == lv:
			cands.append(s.id)
	if cands.is_empty():
		return
	_travel_to_sector(int(cands[rng.randi() % cands.size()]))


## The Last Stand is not implemented: a placeholder message, then the placeholder victory.
## Sector 8, the Last Stand (LastStand, rules/flagship.md): the boss-level map, the flagship's path to the base.
func enter_last_stand() -> void:
	LastStand.enter(self, int(tree.sectors[tree.final_id()].level) if tree != null else int(
		RunTuning.section("sectors").final_level))


func end_run(kind: String, text := "") -> void:
	if over != "":
		return
	over = kind
	score.victory = kind == "victory"  # ScoreKeeper::SetVictory
	over_text = text
	Hooks.emit(&"run_ended", self, kind)
	map_open = false
	store_open = false
	choosing_sector = false
	_log("run over: %s" % kind)


# ------------------------------------------------------------------ events

## WorldManager::UpdateLocation (005f57d0) + CreateChoiceBox: the effects applied when the event is shown (ship /
## hostile flip, status effects, store, hull damage / repair, map reveal, pursuit, environment, boarders, quest,
## ship unlock, secret sector), then the choice box. The event's ModifyResources part (resources, items, crew,
## upgrade, system: `apply_effects`) waits for the choice (`choose`, WorldManager::PauseLoop 005f6268) — except for
## an event without text (no box), which CreateChoiceBox applies at once (005f0fd5). The reward box lists the event
## as resolved, before it is applied (`event_rewards`; rules/events.md §3.4).
func show_event(ev: Dictionary) -> void:
	highlighted = -1
	if not ev.is_empty():
		var fe: Variant = Hooks.filter(&"event_resolved", ev, self)
		ev = {} if Hooks.is_cancel(fe) else fe
	if ev.is_empty() or not ev.get("content", false):
		_close_dialog()
		if ev.get("secret_sector", false) and map != null and tree != null:
			start_secret_sector()  # a bare <secretSector/> event (CRYSTAL_TEST) still sets the flag
		return
	dialog = ev
	clone_text = ""
	# UpdateLocation -> ModifyEnvironment(event.environment): a later event / choice outcome ADDS its environment to
	# the beacon's (rules/hazards.md §0b; e.g. BOARDERS_ASTEROID_GHOST, ZOLTAN_DISTRESS_MANTIS: asteroids; REBEL_PDS
	# hacked: SetPlanetaryDefense again with target all / enemy). The arrival event's own was set by _arrive.
	var ev_env := int(ev.get("environment", -1))
	if _arrival_env_done:
		_arrival_env_done = false
	elif ev_env >= 0:
		var shs := ship.sys("shields")
		var fresh := hazard == null
		if fresh:
			env = ev_env
			hazard = HazardRule.create(ev_env, int(ev.get("env_target", 2)), int(rng.randi() & 0x7fffffff),
				shs.get_level() if shs else 0)
			if map != null and current_beacon >= 0 and current_beacon < map.beacons.size():
				map.beacons[current_beacon].env = env
		else:
			hazard.add_environment(ev_env, int(ev.get("env_target", 2)), shs.get_level() if shs else 0)
		if ev_env in [HazardRule.Env.NEBULA, HazardRule.Env.STORM]:
			hazard.apply_status(ship)  # the event's nebula / storm status effects (CheckStatusEffects); a ship built
			# later gets them in build_enemy_ship
		elif fresh:
			hazard.apply_status(ship)
		if ev_env == HazardRule.Env.PDS:
			hazard.pds_origin = HazardRule.pds_origin_for(space)
	# UpdateLocation order: ship / hostile, CheckStatusEffects, CreateStore, PossibleDamage, reveal, pursuit,
	# environment (above: the hazard must exist before the ship is built), AddBoarders, quest, unlock, secret sector.
	if not ev.ship.is_empty():
		if ev.ship.get("hostile_only", false):
			if not enemy.is_empty():
				enemy.hostile = bool(ev.ship.hostile)
		else:
			_spawn_enemy(ev.ship)
	for st in ev.status:
		_status(st)
	var located := []  # reward-box entries of these effects (hull, intruders)
	for d in ev.damage:
		_damage(d)
		if int(d.amount) != 0:
			located.append(["hull", -int(d.amount)])  # stuff.hullDamage = the sum of the damage amounts
	if not ev.boarders.is_empty() and int(ev.boarders.get("amount", 0)) > 0:
		located.append(["boarders", int(ev.boarders.amount)])  # stuff.intruders: boarders.amount > 0
		# UpdateLocation / CreateLocation: boarders added while the player has a Zoltan super shield -> the event
		# text gets " \n\n" + intruder_energy ("they must have a super shield bypass").
		if add_boarders(ev.boarders) > 0 and ship.super_shield > 0:
			ev.text = String(ev.text) + " \n\n" + engine.tr_text("intruder_energy")
	if int(ev.get("modify_pursuit", 0)) != 0 and fleet != null:
		fleet.pursuit_delay += int(ev.modify_pursuit)
	if ev.get("reveal_map", false) and map != null:
		map.revealed = true  # bMapRevealed
		for b in map.beacons:
			b.known = true
	_note_crew_names()
	if ev.quest != "" and map != null:
		add_event_quest(ev)
	_unlock_ship(ev)
	if ev.store and map != null and beacon().shop == null:
		_open_store_later()
	if String(ev.get("text", "")) == "":
		# CreateChoiceBox (005f0fd5): main text "" (and not loading a game) -> ModifyResources at once; a returned
		# DUMMY clone event (crew loss with a clonebay and a clone text) replaces the event: its box is shown.
		apply_effects(ev)
		if clone_text != "":
			_show_clone_box({})
			return
	else:
		_prepare_crew(ev)
		dialog_rewards = event_rewards(ev) + located
	dialog_choices = choice_views(ev)
	if String(dialog.get("text", "")) == "":
		# ChoiceBox::SetChoices (004edfb0, via CreateChoiceBox -> CommandGui::NewLocation): bOpen = true, then
		# bOpen = false when the main text (after the quest / unlock / intruder appends) is "": an outcome without
		# text (e.g. `<event><ship hostile="true"/></event>`, the attack / refuse choices) opens no box; its
		# effects are applied all the same (above).
		_log("event %s (no text: no box)" % ev.name)
		var secret: bool = ev.get("secret_sector", false)
		_close_dialog()
		if secret and map != null and tree != null:
			start_secret_sector()
		return
	phase = Phase.DIALOG
	_log("event %s" % ev.name)
	if ev.get("secret_sector", false) and map != null and tree != null:
		start_secret_sector()  # the jump replaces this box with the secret sector's start event


func choose(i: int) -> bool:
	if phase != Phase.DIALOG or i < 0 or i >= dialog_choices.size():
		return false
	var v: Dictionary = dialog_choices[i]
	if not v.enabled:
		return false
	_log("choice %d: %s" % [i + 1, v.text])
	Hooks.emit(&"choice_chosen", self, i, v)
	# WorldManager::PauseLoop (005f6268): a choice picked -> ModifyResources(lastLocationEvent): the open event's
	# resources, items, crew, upgrade and system are applied now (the HUD counters change here), then
	# UpdateLocation(chosen event). A crew loss with a clonebay and a clone text returns the DUMMY clone event: it
	# is shown first, its single (hidden-reward) choice leading to the chosen event (bExtraChoice).
	clone_text = ""
	apply_effects(dialog)
	if clone_text != "":
		_show_clone_box(v.event)
		return true
	show_event(v.event)
	return true


## The DUMMY event of a crew loss with a clonebay (ModifyResources, EVENT_CLONED): the clone text, one hidden
## `continue` choice leading to `next` (the chosen event; {} = closes), no rewards of its own.
func _show_clone_box(next: Dictionary) -> void:
	dialog = engine.new_event("DUMMY")
	dialog.text = clone_text
	dialog.content = true
	dialog.choices = [{"text": engine.tr_text("continue"), "req": "", "lvl": 1, "max_lvl": 1 << 30,
		"max_group": -1, "blue": false, "hidden": true, "event": next}]
	clone_text = ""
	dialog_choices = choice_views(dialog)
	dialog_rewards = []
	phase = Phase.DIALOG
	_log("event DUMMY (clone text)")


func _close_dialog() -> void:
	dialog = {}
	dialog_choices = []
	dialog_rewards = []
	phase = Phase.MESSAGE if not messages.is_empty() else Phase.IDLE
	_update_ftl_safe()
	_after_dialog()


## WorldManager::CreateChoiceBox (rules/events.md §3.3): req outside [lvl, max_lvl] removed; per max_group the
## last qualifying choice wins; met reqs are blue; unaffordable item_modify costs are greyed (not with steal);
## if all are greyed the first is enabled. A choice whose event gives a system (`<system>`) adds its warning to
## `ev.system_note` and is greyed when the system is owned or does not fit (`system_choice`).
func choice_views(ev: Dictionary) -> Array:
	var kept := []
	var group_last := {}
	for i in ev.choices.size():
		var c: Dictionary = ev.choices[i]
		if c.req != "":
			var lv := equipment_level(c.req)
			if lv < int(c.lvl) or lv > int(c.max_lvl):
				continue
		if int(c.max_group) != -1:
			group_last[int(c.max_group)] = i
		kept.append(i)
	var out := []
	var note := ""
	for i in kept:
		var c: Dictionary = ev.choices[i]
		if int(c.max_group) != -1 and group_last[int(c.max_group)] != i:
			continue
		var sc := system_choice(c.event)
		if String(sc.text) != "":
			note += (" \n\n" if note != "" else "") + String(sc.text)
		out.append({"index": i, "text": c.text, "enabled": affordable(c.event) and not sc.grey,
			"blue": c.req != "" and c.blue, "preview": "" if c.hidden else preview(c.event),
			"preview_res": {} if c.hidden else preview_res(c.event), "event": c.event})
	if note != "":
		ev["system_note"] = " \n\n" + note  # TextString::operator+= on the box's main text
	else:
		ev.erase("system_note")
	if not out.is_empty() and out.all(func(v): return not v.enabled):
		out[0].enabled = true
	return out


## WorldManager::CreateChoiceBox, per choice whose event has a systemId [exe]: owned -> `new_system_owned`
## (greyed); a subsystem -> nothing; medbay with a clonebay -> `new_system_medbay`, clonebay with a medbay ->
## `new_system_clonebay` (not greyed: they replace each other); CanFitSystem false (8 main systems) ->
## `new_system_full` (greyed); else by GetSystemCount (main systems): 7 -> `new_system_last`, 6 ->
## `new_system_penultimate`, otherwise `new_system_update` (\1 = 7 - count). Returns {text, grey}.
func system_choice(ev: Dictionary) -> Dictionary:
	var id := String(ev.get("system", "")) if not ev.is_empty() else ""
	if id == "":
		return {"text": "", "grey": false}
	if ship.sys(id) != null:
		return {"text": FtlData.tr_id("new_system_owned"), "grey": true}
	if id in SystemState.SUBSYSTEMS:
		return {"text": "", "grey": false}
	if id == "medbay" and ship.sys("clonebay") != null:
		return {"text": FtlData.tr_id("new_system_medbay"), "grey": false}
	if id == "clonebay" and ship.sys("medbay") != null:
		return {"text": FtlData.tr_id("new_system_clonebay"), "grey": false}
	if not can_fit_system(id):
		return {"text": FtlData.tr_id("new_system_full"), "grey": true}
	var n := main_system_count()
	if n == 7:
		return {"text": FtlData.tr_id("new_system_last"), "grey": false}
	if n == 6:
		return {"text": FtlData.tr_id("new_system_penultimate"), "grey": false}
	return {"text": FtlData.tr_id("new_system_update").replace("\\1", str(7 - n)), "grey": false}


## ShipManager::GetSystemCount: systems that need power (subsystems not counted).
func main_system_count() -> int:
	var n := 0
	for id in ship.systems:
		if not id in SystemState.SUBSYSTEMS:
			n += 1
	return n


## ShipManager::CanFitSystem(id): medbay with a clonebay (or clonebay with a medbay) always fits; otherwise fewer
## than 8 main systems. The count ignores whether `id` itself is a subsystem (CanFitSubsystem: < 4 subsystems is
## the store's check for those).
func can_fit_system(id: String) -> bool:
	if (id == "medbay" and ship.sys("clonebay") != null) or (id == "clonebay" and ship.sys("medbay") != null):
		return true
	return main_system_count() < 8


func affordable(ev: Dictionary) -> bool:
	if ev.is_empty() or ev.get("steal", false):
		return true
	var have := {"fuel": ship.fuel, "missiles": ship.missiles, "drones": ship.drone_parts, "scrap": ship.scrap}
	for k in EventEngine.RES_KEYS:
		var v := int(ev.res[k])
		if v < 0 and have[k] < -v:
			return false
	return true


## Reward preview after a choice text ("[Scrap: -15]"), not shown for hidden choices.
func preview(ev: Dictionary) -> String:
	if ev.is_empty():
		return ""
	var parts := []
	for k in EventEngine.RES_KEYS:
		var v := int(ev.res[k])
		if v != 0:
			parts.append("%s: %s%d" % [RES_LABEL[k], "+" if v > 0 else "", v])
	return "" if parts.is_empty() else "[" + ", ".join(parts) + "]"


## The same preview as resource amounts for the choice's ResourceBox (ui/resource_box.gd).
func preview_res(ev: Dictionary) -> Dictionary:
	var out := {}
	if ev.is_empty():
		return out
	for k in EventEngine.RES_KEYS:
		if int(ev.res[k]) != 0:
			out[k] = int(ev.res[k])
	return out


const RES_LABEL := {"fuel": "Fuel", "missiles": "Missiles", "drones": "Drone Parts", "scrap": "Scrap"}


## ShipObject::HasEquipment: system level, weapon / drone / augment count, crew race count, or the best of a
## blueprintList.
func equipment_level(req: String) -> int:
	var s := ship.sys(req)
	if s:
		return s.get_level()
	var n := 0
	for w in ship.weapons:
		if w.bp.name == req:
			n += 1
	for d in ship.drones:
		if d.bp.get("name", "") == req:
			n += 1
	n += ship.augments.count(req) + cargo.count(req)
	for c in ship.crew:
		if c.is_alive() and c.player_owned and c.race == req:
			n += 1
	if n == 0:
		var list := FtlData.blueprint_list(req)
		for e in list:
			if e != req:
				n = maxi(n, equipment_level(e))
	return n


## WorldManager::ModifyResources (005f0290): fuel / missiles / drone parts / scrap, weapon / augment / drone, item
## removed, upgrade, system, crew gained / lost (clone text). Called when a choice of the event's box is picked
## (`choose`), or at once for an event without text (`show_event`). Returns what actually changed (log / tests; the
## box shows `event_rewards`).
func apply_effects(ev: Dictionary) -> Array:
	var out := []
	if ev.is_empty() or not ev.has("res"):
		return out
	for k in EventEngine.RES_KEYS:
		var v := int(ev.res[k])
		if v == 0:
			continue
		match k:
			"fuel":
				var nv := maxi(ship.fuel + v, 0)
				v = nv - ship.fuel
				ship.fuel = nv
			"missiles":
				var nv := maxi(ship.missiles + v, 0)
				v = nv - ship.missiles
				ship.missiles = nv
			"drones":
				var nv := maxi(ship.drone_parts + v, 0)
				v = nv - ship.drone_parts
				ship.drone_parts = nv
			"scrap":
				# ModifyScrapCount(income = true): SCRAP_COLLECTOR / REPAIR_ARM (+2 hull) on gains.
				score.add_scrap_collected(v)  # raw event gain, before the augment bonus
				var nv := maxi(ship.scrap + AugmentRule.scrap_income(ship, v), 0)
				v = nv - ship.scrap
				ship.scrap = nv
				if v > 0:
					stats.scrap = int(stats.scrap) + v
		if v != 0:
			out.append([k, v])
	for kind in ["weapon", "drone", "augment"]:
		if ev[kind] != "":
			out.append(give_item(kind, ev[kind]))
	if not ev.crew.is_empty():
		if int(ev.crew.amount) < 0:
			# WorldManager::ModifyResources keeps the picked blueprint between iterations: one crew is lost
			# whatever the amount (a traitor copy per iteration is not in vanilla data).
			out.append_array(_lose_crew(ev.crew))
		# CreateEvent: the event's skill levels ((max / 2) * level), or RandomSkills(worldLevel) when it names none;
		# rolled once for the blueprint (every copy gets them). Drawn from CrewIdentity.rng at application so the
		# event streams of a seed are unchanged (the exe draws from the global RNG at creation).
		# A box shown first rolled the blueprint (skills + first identity) for its reward list (`_prepare_crew`).
		var pend: Dictionary = ev.get("crew_pending", {})
		var skills: Dictionary = pend.get("skills", ev.crew.get("skills", {}))
		if skills.is_empty() and int(ev.crew.amount) > 0 and not pend.has("skills"):
			skills = RunStore.random_skills(engine.level if engine != null else 0, CrewIdentity.rng)
		for i in maxi(int(ev.crew.amount), 0):
			if int(ev.crew.amount) > 0:
				# AddCrewMember with the event's blueprint: a fixed name when the tag has `id` (e.g. name_Charlie),
				# else a random unused name, gender and colours (CrewIdentity); placed via the pilot room.
				var ident: Dictionary = pend.get("ident", {}) if i == 0 else {}
				if ident.is_empty():
					ident = _crew_ident(ev.crew)
				score.add_crew()  # ModifyResources: once per iteration
				var c := ship.add_crew(ev.crew.race, true, -1, ident)
				if c:
					set_crew_skills(c, skills)
					var rw := crew_reward(c, false)
					rw["skills"] = skills.duplicate()  # ChoiceBox crew item: skill icons of the blueprint
					out.append(["crew", ev.crew.race, rw])
		_note_crew_names()  # AddCrewMember sets the "ruwen" flag (the crew joins on the choice)
	if not ev.remove_crew.is_empty():
		out.append_array(_lose_crew(ev.remove_crew))
	if ev.remove != "":
		_remove_item(ev.remove)
		out.append(["removed", ev.remove])
	if not ev.upgrade.is_empty():
		_upgrade(ev.upgrade.system, int(ev.upgrade.amount))
		out.append(["upgrade", ev.upgrade.system])
	if String(ev.get("system", "")) != "":
		# ModifyResources: AddSystem(systemId) whenever the event has one (no fit check here: the choice was
		# greyed); the reward box shows `<system>_installed` whatever AddSystem did.
		install_system(String(ev.system))
		out.append(["system", String(ev.system)])
	return out


## The identity of an event crew member: a fixed name when the tag has `id` (gender from the name list), else {}
## (AddCrewMember rolls a random unused name, gender and colours).
func _crew_ident(spec: Dictionary) -> Dictionary:
	if String(spec.get("name", "")) == "":
		return {}
	var ident := CrewIdentity.roll(spec.race, CrewIdentity.rng, CrewIdentity.used_names(ship))
	ident.name = String(spec.name)
	var pool: Dictionary = FtlData.crew_names().names
	if pool.has(ident.name):
		ident.male = bool(pool[ident.name])
	return ident


## A box about to show a crew gain: the event's CrewBlueprint (CreateEvent: name, gender, colours, skills) exists
## before the choice, so the reward box can show it; rolled here (CrewIdentity stream, same draws as at application)
## and kept in `ev.crew_pending` for `apply_effects` (the first copy).
func _prepare_crew(ev: Dictionary) -> void:
	if ev.crew.is_empty() or int(ev.crew.amount) <= 0 or ev.has("crew_pending"):
		return
	var skills: Dictionary = ev.crew.get("skills", {})
	if skills.is_empty():
		skills = RunStore.random_skills(engine.level if engine != null else 0, CrewIdentity.rng)
	var ident := _crew_ident(ev.crew)
	if ident.is_empty():
		ident = CrewIdentity.roll(ev.crew.race, CrewIdentity.rng, CrewIdentity.used_names(ship))
	ev["crew_pending"] = {"ident": ident, "skills": skills}


## The reward box of a shown event (CreateChoiceBox -> CommandGui::NewLocation(…, event->stuff)): the event's
## ResourceEvent as resolved, BEFORE ModifyResources applies it on the choice [exe]: the raw fuel / missiles / drone
## parts / scrap amounts (no augment bonus, no clamping), the weapon / drone / augment named by the event, the crew
## blueprint gained, the crew member that will be lost (SelectRandomCrew with lastSelectedCrewSeed, the same pick
## ModifyResources makes), the item removed, the upgrade alert (computed now, on the ship before the upgrade) and the
## system. Hull and intruder entries come from `show_event` (UpdateLocation applied them already).
func event_rewards(ev: Dictionary) -> Array:
	var out := []
	for k in EventEngine.RES_KEYS:
		if int(ev.res[k]) != 0:
			out.append([k, int(ev.res[k])])
	for kind in ["weapon", "drone", "augment"]:
		if ev[kind] != "":
			out.append([kind, ev[kind]])
	var lose: Dictionary = ev.remove_crew if not ev.remove_crew.is_empty() else (
		ev.crew if not ev.crew.is_empty() and int(ev.crew.amount) < 0 else {})
	if not lose.is_empty():
		var c := select_random_crew(String(lose.get("race", "")))
		if c != null:
			var rw := crew_reward(c, true)
			if bool(lose.get("traitor", false)):
				rw.traitor = true
			out.append(["crew_lost", c.race, rw])
	var pend: Dictionary = ev.get("crew_pending", {})
	if not pend.is_empty():
		var ident: Dictionary = pend.ident
		out.append(["crew", ev.crew.race, {"name": String(ident.get("name", "")), "lost": false,
			"race": String(ev.crew.race), "male": bool(ident.get("male", true)),
			"colors": (ident.get("colors", []) as Array).duplicate(), "skills": (pend.skills as Dictionary).duplicate()}])
	if ev.remove != "":
		out.append(["removed", ev.remove])
	if not ev.upgrade.is_empty():
		var up := upgrade_result(ev.upgrade.system, int(ev.upgrade.amount))
		if not up.is_empty():
			out.append(["upgrade", ev.upgrade.system, up.flag, up.amount])
	if String(ev.get("system", "")) != "":
		out.append(["system", String(ev.system)])
	return out


## WorldManager::AddBoarders -> CompleteShip::AddBoarders (rules/events.md "Boarders"): only while the player has
## fewer than 15 intruders and amount > 0. All boarders go to ONE random room (random % roomCount); each one is
## placed there (a full room spills like any intruder placement) and the next one targets the room the previous
## one ended in. Each gets BoardingGoal(2) (never retreats: no ship to go back to) and plays the teleport
## materialise animation (StartTeleportArrive) — unless `breach`: then no animation, a hull breach in the room and
## 1 hull damage (DamageHull(1, false): none while jumping). Returns the number of boarders placed.
func add_boarders(b: Dictionary) -> int:
	var amount := int(b.get("amount", 0))
	if amount <= 0 or ship.intruders().size() >= 15 or ship.layout.rooms.is_empty():
		return 0
	var breach := bool(b.get("breach", false))
	var room: int = ship.layout.rooms[rng.randi() % ship.layout.rooms.size()].id
	var n := 0
	for i in amount:
		var c := ship.add_crew(String(b.get("race", "human")), false, room)
		if c == null:
			continue
		n += 1
		room = c.room
		c.boarding_health_limit = -100.0  # BoardingGoal(2): never retreats by health (ShipAI.evac_room)
		if not breach:
			ship.teleporting[c] = {"crew": c, "from": null, "to": ship, "room": room, "phase": 1, "t": 0.0,
				"event": true}
	if breach:
		var free := []
		for t in ship.room_tiles(room):
			if not ship.breaches.get(room, {}).has(t):
				free.append(t)
		if not free.is_empty():
			ship.add_breach(room, free[rng.randi() % free.size()])
		if not ship.jumping:
			ship.take_hull_damage(1)
	_log("boarders: %d %s in room %d%s" % [n, String(b.get("race", "")), room, " (breach)" if breach else ""])
	return n


## A weapon / drone / augment for the player (rules/ship_management.md §6): free slot, else the first empty cargo
## box, else the over-capacity box (the equipment window opens; lost at the next jump), else 25 scrap
## (EQUIP_FULL / AUGMENT_FULL). ShipInventory.add_reward.
func give_item(kind: String, name: String) -> Array:
	return mgmt.inv.add_reward(self, kind, name)


## ShipManager::SelectRandomCrew pool (CrewMemberFactory::GetCrewList(player, no drones)): player-owned
## non-drone crew aboard either ship (away team and mind-controlled crew included; dead bodies in their death
## animation excluded) plus the clone queue, in a stable order.
func crew_loss_pool() -> Array:
	var out := []
	var ships := [ship]
	if ship.opponent != null:
		ships.append(ship.opponent)
	for s in ships:
		for c in s.crew:
			if c.player_owned and not c.is_drone() and c.is_alive() and not out.has(c):
				out.append(c)
	for c in ship.clone_queue:
		if not out.has(c):
			out.append(c)
	return out


## SelectRandomCrew(seed, racePref): exact species preference with a fallback to everyone (`random`, `traitor`
## or none match no species -> uniform). Its own generator seeded by `crew_seed` (rolled from the run stream on
## the first loss of a location, reset when the location changes) so the dialog preview names the victim.
func select_random_crew(pref: String) -> CrewMember:
	var pool := crew_loss_pool()
	if pool.is_empty():
		return null
	var keep := pool.filter(func(c): return c.race == pref)
	if not keep.is_empty():
		pool = keep
	if crew_seed < 0:
		crew_seed = int(rng.randi() & 0x7fffffff)
	var r := RandomNumberGenerator.new()
	r.seed = crew_seed
	return pool[r.randi() % pool.size()]


## WorldManager::ModifyResources crew loss (rules/events.md "Crew removal and loss"). `spec` = {race, clone, text,
## traitor}. With a clonebay installed: a clone text replaces the dialog (`clone_text`), and `clone` = an instant
## Clone() into the clonebay room (skill loss, cloneArrive; no death). Otherwise Kill(noClone): the crew vanishes
## at once (no death animation / sound / body, never queued). A traitor leaves a hostile copy in the pilot room.
func _lose_crew(spec: Dictionary) -> Array:
	var c := select_random_crew(String(spec.get("race", "")))
	if c == null:
		return []
	var reward := crew_reward(c, true)
	var on := ship.ship_of(c)
	if ship.sys("clonebay") != null:
		if String(spec.get("text", "")) != "":
			clone_text = String(spec.text)
		if bool(spec.get("clone", false)):
			if on != null:
				on.crew.erase(c)
				on.teleporting.erase(c)
				on.crew_changed()
			ship.clone_queue.erase(c)
			c.mind_controlled = false
			ClonebayRule.clone(ship, c)
			Hooks.emit(&"crew_removed", ship, c, true)
			_log("crew %s cloned (event)" % c.display_name())
			return [] if clone_text != "" else [["crew_cloned", c.race, crew_reward(c, false)]]
	ClonebayRule.kill_no_clone(c)
	c.death_sound_done = true  # Kill(true): no death animation, no sound, removed at once
	if on != null:
		on.crew.erase(c)
		on.teleporting.erase(c)
		on.crew_changed()
	ship.clone_queue.erase(c)
	lost_crew_flag = true  # AchievementTracker "lost_crew"
	Hooks.emit(&"crew_removed", ship, c, false)
	_log("crew %s lost (event)" % c.display_name())
	if bool(spec.get("traitor", false)):
		var pilot := ship.sys("pilot")
		var t := ship.add_crew(c.race, false, pilot.room if pilot else -1,
			{"name": c.name_long, "male": c.male, "colors": c.color_choices})
		if t:
			t.skills = c.skills.duplicate()
			if t.race == "anaerobic":
				ship.env.oxygen[t.room] = 0.0  # an anaerobic traitor empties its room
			reward.traitor = true
	return [["crew_lost", c.race, reward]] if clone_text == "" else []


## What the event box shows for a crew gained / lost (ResourceBox crew item: portrait + name).
static func crew_reward(c: CrewMember, lost: bool) -> Dictionary:
	return {"name": c.name_long if c.name_long != "" else c.display_name(), "lost": lost, "race": c.race, "male": c.male, "colors": c.color_choices.duplicate()}


func _remove_item(name: String) -> void:
	for i in ship.weapons.size():
		if ship.weapons[i].bp.name == name:
			ship.depower_weapon(ship.weapons[i])
			ship.weapons.remove_at(i)
			return
	if name in ship.augments:
		AugmentRule.remove(ship, name)  # e.g. the STASIS_POD quest item
	elif name in cargo:
		cargo[cargo.find(name)] = ""  # the cargo boxes keep their positions
		ShipInventory._trim_cargo(self)


## Event crew skills (CreateEvent skillLevel.first = (max / 2) * level, then CrewMember::InitializeSkills):
## {skill: level 0..2} -> progress, capped at the skill's maximum.
static func set_crew_skills(c: CrewMember, skills: Dictionary) -> void:
	for k in skills:
		if k in CrewMember.SKILLS:
			var cap := c.skill_cap(k)
			c.skills[k] = float(mini(int(cap / 2.0 * int(skills[k])), cap))


## ShipManager::UpgradeSystem(id, amount) [exe]: n = CanUpgrade(id, amount); nothing when n <= 0; the reactor
## (`reactor`, id 17) gains n bars, a system n levels (ShipSystem::UpgradeSystem). `all` (id 16) is passed on
## as id 16 for every system in ModifyResources' loop, which no system matches: nothing (unused by vanilla data).
func _upgrade(sys_id: String, amount: int) -> void:
	var n := can_upgrade(sys_id, amount)
	if n <= 0:
		return
	if sys_id == "reactor":
		ship.reactor_max += n
	else:
		ship.sys(sys_id).level += n


## ShipManager::CanUpgrade(id, amount): reactor min(amount, 25 - reactor bars); an installed system
## min(amount, maxLevel - level); otherwise 0.
func can_upgrade(sys_id: String, amount: int) -> int:
	if sys_id == "reactor":
		return mini(amount, UpgradeSession.REACTOR_MAX - ship.reactor_max)
	var s := ship.sys(sys_id)
	if s == null:
		return 0
	return mini(amount, UpgradeSession.max_level(ship, sys_id) - s.level)


## The reward box's upgrade alert (WorldManager::CreateChoiceBox, upgradeSuccessFlag) [exe]: amount > 0 only;
## HasSystem(id) or reactor -> n = CanUpgrade(id, amount) on the ship as it is when the box opens: n < 1 -> flag 2
## (`upgrade_fail_max`), else flag 1 (`upgrade_success`, \2 = n); missing -> flag 3 (`upgrade_fail_missing`).
## A box with text is built before ModifyResources (applied on the choice), so the alert describes the upgrade
## about to happen (`event_rewards`). Returns {flag, amount} or {} (amount <= 0).
func upgrade_result(sys_id: String, amount: int) -> Dictionary:
	if amount <= 0:
		return {}
	if sys_id == "reactor" or ship.sys(sys_id) != null:
		var n := can_upgrade(sys_id, amount)
		return {"flag": 2, "amount": amount} if n < 1 else {"flag": 1, "amount": n}
	return {"flag": 3, "amount": amount}


## ShipManager::AddSystem on the player ship (RunStore.install_system). Returns true when added.
func install_system(id: String) -> bool:
	var ok := RunStore.install_system(ship, id)
	_log("system %s %s" % [id, "installed" if ok else "not installed"])
	return ok


## PossibleDamage: hull always (negative = repair), then the system's room: system damage + fire / breach.
func _damage(d: Dictionary) -> void:
	var amount := int(d.amount)
	var before := ship.hull
	ship.hull = clampi(ship.hull - amount, 0, ship.max_hull)
	ship.last_damage = before - ship.hull  # ShipManager::DamageHull: iLastDamage = the clamped change (screen shake)
	var sys_id := String(d.system)
	var room := -1
	if sys_id == "random":
		var l := ship.system_list()
		if not l.is_empty():
			sys_id = l[engine.r(l.size())]
	if sys_id == "room":
		room = ship.layout.rooms[engine.r(ship.layout.rooms.size())].id
		sys_id = ""
	var s := ship.sys(sys_id) if sys_id != "" else null
	if s:
		room = s.room
		if amount > 0:
			ship.damage_system(sys_id, amount)
	if room < 0:
		return
	var eff := String(d.effect)
	if eff == "random":
		eff = "fire" if engine.r(2) == 0 else "breach"
	if eff == "fire" or eff == "all":
		ship.ignite(room, engine.r(ship.room_tiles(room)))
	if eff == "breach" or eff == "all":
		ship.add_breach(room, engine.r(ship.room_tiles(room)))


## StatusEffect on the player ship: limit (cap at amount), loss (−amount), divide, clear (power loss bars).
## Enemy-targeted effects are kept on the enemy record and applied when its ShipState is built.
func _status(st: Dictionary) -> void:
	if String(st.target) != "player":
		if not enemy.is_empty():
			enemy.status = enemy.get("status", []) + [st]
		return
	apply_status_to(ship, st)


static func apply_status_to(s_ship: ShipState, st: Dictionary) -> void:
	var s := s_ship.sys(String(st.system))
	if s == null:
		return
	var lv := s.get_level()
	match String(st.type):
		"limit":
			s_ship.set_power_loss(s.id, maxi(lv - int(st.amount), 0))
		"loss":
			s_ship.set_power_loss(s.id, mini(int(st.amount), lv))
		"divide":
			s_ship.set_power_loss(s.id, lv - lv / maxi(int(st.amount), 1))
		"clear":
			s_ship.set_power_loss(s.id, 0)


# ------------------------------------------------------------------ event ship and combat outcome (§5)

func _spawn_enemy(ship_ev: Dictionary) -> void:
	var setup := engine.setup_ship(ship_ev)
	var plan := ShipGenerator.generate(setup.blueprint, sector, engine.difficulty, int(ship_ev.seed), ship_ev.node,
		engine.ae, engine.crew_rarity_table())
	enemy = {"ship_ev": ship_ev, "blueprint": setup.blueprint, "plan": plan, "hostile": bool(ship_ev.hostile),
		"surrendered": false, "done": false, "outcome": "", "has_surrender": setup.has_surrender,
		"surrender_threshold": setup.surrender_threshold, "escape_threshold": setup.escape_threshold,
		"has_escape": setup.has_escape, "escape_timer": float(setup.escape_timer), "escaping": false,
		"escaped": false, "status": []}
	enemy_serial += 1
	ship.ftl_charge = 0.0
	store_open = false
	_log("event ship %s (%s, %s, crew %d, weapons %s)" % [ship_ev.template, setup.blueprint, "hostile" if
		ship_ev.hostile else "neutral", plan.crew.size(), str(plan.weapons)])


## The event ship's ShipState (ShipGenerator plan applied, beacon status effects / environment).
func build_enemy_ship() -> ShipState:
	if enemy.get("boss", false):
		return LastStand.build_ship(self)
	var es := ShipState.new(enemy.blueprint, false)
	if enemy.has("plan"):
		ShipGenerator.apply(es, enemy.plan)
	Hooks.emit(&"enemy_ship_built", self, es)
	for st in enemy.get("status", []):
		apply_status_to(es, st)
	if hazard != null:
		hazard.apply_status(es)
	return es


## WorldManager::OnLoop per frame for the event ship (`es` = its ShipState in the combat scene), rules/events.md
## §5.4: surrender → escape (timer counts while the ship can fly: engines + piloting; FTL_JAMMER halves) → dead
## crew → destroyed → got away. Returns the outcome started ("" none).
func check_combat(es: ShipState, seconds := 0.0) -> String:
	if enemy.get("boss", false):
		return LastStand.check_combat(self, es, seconds)
	if enemy.is_empty() or enemy.done or es == null:
		return ""
	# ShipAI::OnLoop(hostile) returns at the top (stand-down) for a non-hostile ship, so a ship made neutral
	# (accepted surrender, <ship hostile="false"/>) neither counts its escape timer down nor calls JumpLeave;
	# `escaping` itself stays set (it resumes if an event makes the ship hostile again). While any box / menu is
	# open (CommandGui::IsPaused: menu_pause) the game runs WorldManager::PauseLoop, so the timer is frozen too.
	if enemy.escaping and not enemy.escaped and not es.is_destroyed() and seconds > 0.0 and enemy.hostile \
			and not modal():
		if FtlDrive.ship_flying(es):
			var rate := 1.0
			var tun := RunTuning.section("escape")
			if ship.has_augment(String(tun.get("jammer_aug", "FTL_JAMMER"))):
				rate = float(tun.get("jammer_rate", 0.5))
			enemy.escape_timer = float(enemy.escape_timer) - seconds * rate
			if float(enemy.escape_timer) < 0.0:
				enemy.escaped = true
				es.jumping = true
				enemy.jump_left = 2.0  # JumpLeave: jumpAnimation 2.0 s; ShipAI::Escaped() once it is done
	if enemy.escaped and float(enemy.get("jump_left", 0.0)) > 0.0:
		enemy.jump_left = float(enemy.jump_left) - seconds
	if phase != Phase.IDLE:
		return ""
	if enemy.escaped and float(enemy.get("jump_left", 0.0)) <= 0.0:
		return combat_outcome("gotaway")
	if es.destroyed_done():
		return combat_outcome("destroyed")
	if not enemy.hostile or es.is_destroyed():
		return ""
	if enemy.has_surrender and not enemy.surrendered and es.hull >= 1 and es.hull <= int(enemy.surrender_threshold):
		return combat_outcome("surrender")
	if not enemy.escaping and not enemy.surrendered and es.hull >= 1 and es.hull <= int(enemy.escape_threshold):
		enemy.escaping = true
		if not enemy.get("has_escape", false):
			enemy.escaping = false  # CancelEscape: no escape event → never flees
			enemy.escape_threshold = -100
			return ""
		return combat_outcome("escape")
	# CompleteShip::DeadCrew: CrewMemberFactory::GetCrewCount(enemy side) = the enemy's living crew anywhere,
	# its boarders on our ship included (rules/teleporter.md "Boarders on a ship that stops being hostile").
	var enemy_crew := func(c): return c.is_alive() and not c.player_owned and not c.is_drone()
	var alive := es.crew.filter(enemy_crew) + (ship.crew.filter(enemy_crew) if ship != null else [])
	if alive.is_empty() and not es.blueprint.crew.is_empty():
		return combat_outcome("deadCrew")
	return ""


## Shows the ship's outcome event: destroyed / deadCrew / gotaway end the fight, surrender and escape are
## normal events (accepting a surrender usually makes the ship non-hostile).
func combat_outcome(kind: String) -> String:
	if enemy.is_empty():
		return ""
	var ev := engine.ship_outcome_event(enemy.ship_ev, kind)
	if kind == "surrender":
		enemy.surrendered = true
	elif kind != "escape":
		enemy.done = true
		enemy.hostile = false
		enemy.outcome = kind
		if kind == "destroyed" or kind == "deadCrew":
			stats.ships = int(stats.ships) + 1
			score.add_defeated_ship()
	Hooks.emit(&"combat_outcome", self, kind)  # WorldManager::OnLoop outcome checks (AchievementTracker)
	_log("combat outcome %s" % kind)
	show_event(ev)
	return kind


# ------------------------------------------------------------------ FTL drive and hazards

## Per unpaused frame: FTL drive (rules/ftl_drive.md §1): full when safe, ×3 (SetBoostFTL) without a hostile ship.
func tick(seconds: float) -> void:
	_update_ftl_safe()
	if not boss.is_empty():
		LastStand.tick(self)
	FtlDrive.tick(ship, seconds, ftl_safe(), not has_hostile())
	ship.update_jump_ready_sound()  # jumpReady once when the drive becomes full


## WorldManager::OnLoop: no hostile ship and not HostileEnvironment -> ShipManager::SetSafe (FTL full, teleporter /
## cloaking / battery cooldowns cleared, bWasSafe). Mind control, hacking and the rest keep their timers.
func _update_ftl_safe() -> void:
	if ftl_safe():
		ship.set_safe()


## Game over (CommandGui::CheckGameover) reported by the scene: results screen.
func game_over(text_id: String) -> void:
	over_cause = text_id
	end_run("gameover", FtlData.tr_id(text_id).replace("\\n", "\n"))


func _log(s: String) -> void:
	log.append(s)
	print("[run] ", s)
