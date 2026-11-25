extends Node2D
## Combat prototype: Kestrel vs. rebel ship.
## Targeting as in FTL: tap weapon (power/arm) -> tap enemy room.
## Two views: "side by side" (wide screens) and "one at a time" (phone).

const ShipSounds := preload("res://scripts/audio/ship_sounds.gd")

var combat: Combat
var player_space: Space
var enemy_space: Space
var weapon_control: WeaponControl
var weapon_panel: WeaponPanel
var hud_root: Control  # 1280×720 frame holding the whole HUD
var command_hud: CommandHud  # FTL / SHIP / MENU buttons
var pause_overlay: CommandHud
var enemy_window: EnemyWindow  # enemy status + system boxes (front)
var end_box: EndBox  # "destroyed" event box / GAME OVER (rules/ship_destruction.md)
var leave_crew_dialog: ConfirmWindow  # CommandGui leaveCrewDialog (run mode; rules/ftl_drive.md §4.4)
var victory_shown := false
var game_over_shown := false
var enemy_window_back: EnemyWindow  # enemy window frame (under the enemy ship)
var ship_status: ShipStatusHud
var debug_layer: CanvasLayer
var debug_panel: PanelContainer
var debug_button: Button
static var debug_visible := false  # debug overlay shown (F12 / DEBUG button; kept across restarts)
var single_view := false
var showing_enemy := false
var btn_pause: Button
var btn_view: Button
var btn_me: Button
var btn_enemy: Button
var btn_enemy_shields: Button
var btn_sensors: Button
var systems_bar: SystemsBar
var drone_panel: DronePanel
var crew_control: CrewControl
var crew_list: CrewList
var top_bar: HBoxContainer
var tests_menu: MenuButton
var pointer_locked := false  # CLI pointer flags (--hover-crew, --drag-box, ...): real mouse motion ignored
var options: OptionsScreen  # Options screen (Settings registry; Esc / F10 / MENU / debug "Options")
var _options_paused := false  # the Options screen paused the game (unpaused when it closes)
var pause_menu: PauseMenuView  # FTL's Esc menu (MenuScreen; Esc / MENU wrench)
var vanilla_options: VanillaOptionsView  # FTL's options window (pause menu OPTIONS)
var _menu_paused := false  # the Esc menu paused the game
var _combat_live := false  # combat_started emitted and combat_ended not yet (rules/hooks.md)
static var enemy_shield_layers := 3  # test: enemy shield layers (kept across restarts)
static var sensors_level := -1  # test: player sensors level override (-1 = the ship's own level)

# ------------------------------------------------------------------ test scenario (kept across restarts)
## Player ships of the scenario menu (--player-ship=NAME). TEST_SHIP_* live in godot/data/test_ships.xml.
const PLAYER_SHIPS := ["PLAYER_SHIP_HARD", "TEST_SHIP_ALL", "TEST_SHIP_ALL_CLONE", "TEST_SHIP_MAX"]
## Enemy ships of the scenario menu (--enemy-ship=NAME): one per faction, all with layout and image.
const ENEMY_SHIPS := ["REBEL_FAT", "MANTIS_FIGHTER", "CIRCLE_SCOUT", "ZOLTAN_FIGHTER", "ROCK_FIGHT",
	"JELLY_BUTTON", "CRYSTAL_SCOUT", "AUTO_ASSAULT", "ANAEROBIC_SCOUT"]
## Player weapon presets (--weapons=PRESET); vanilla weapon blueprint names. "Blueprint" = the ship's own.
const WEAPON_PRESETS := {
	"Blueprint": [],
	"Lasers": ["LASER_BURST_3", "LASER_HEAVY_2", "LASER_BURST_2", "LASER_HEAVY_1"],
	"Ion + lasers": ["ION_2", "ION_STUN", "LASER_BURST_3", "LASER_HEAVY_1"],
	"Missiles": ["MISSILES_2_PLAYER", "MISSILES_BREACH", "MISSILES_3", "MISSILES_HULL"],
	"Beams": ["BEAM_1", "BEAM_2", "BEAM_FIRE", "BEAM_HULL"],
	"Bombs": ["BOMB_1", "BOMB_FIRE", "BOMB_ION", "BOMB_BREACH_1"],
	"Flak": ["SHOTGUN_PLAYER", "SHOTGUN_2", "LASER_BURST_2", "MISSILES_2_PLAYER"],
	"Chain + charge": ["LASER_CHAINGUN", "LASER_CHARGEGUN_PLAYER", "ION_CHARGEGUN", "LASER_HULL_1"],
	"Crystal": ["CRYSTAL_BURST_1", "CRYSTAL_HEAVY_1", "CRYSTAL_BURST_2", "CRYSTAL_HEAVY_2"],
	"Mixed": ["LASER_BURST_3", "ION_1", "MISSILES_2_PLAYER", "BEAM_1"],
}
## Player drone presets (--drones=PRESET); vanilla drone blueprint names. "Blueprint" = the ship's own.
const DRONE_PRESETS := {
	"Blueprint": [],
	"combat+defense": ["COMBAT_1", "DEFENSE_1"],
	"beam+anti": ["COMBAT_BEAM", "ANTI_DRONE"],
	"repair+AP": ["REPAIR", "BATTLE"],
	"boarding": ["BOARDER", "BOARDER_ION"],
	"hull+shield": ["SHIP_REPAIR", "DRONE_SHIELD_PLAYER"],
	"combat2+defense2": ["COMBAT_2", "DEFENSE_2"],
	"beam2+fire": ["COMBAT_BEAM_2", "COMBAT_FIRE"],
}
const TEST_DRONE_PARTS := 10  # drone parts given with a drone preset
static var drone_preset := "Blueprint"  # "custom" after --player-drones=
static var player_drone_names: Array = []  # empty = the blueprint's drones
static var enemy_drone_names: Array = []  # --enemy-drones=: replaces the enemy's drones
static var player_ship_name := "PLAYER_SHIP_HARD"
static var enemy_ship_name := "REBEL_FAT"
static var weapon_preset := "Blueprint"  # "custom" after --player-weapons=
## --harmless-enemy[=0|1] (sandbox): the enemy has no weapons, no drones, no boarding and never escapes or
## surrenders (calm HUD inspection). On by default with `--device=` (DevicePreview); later enemy flags
## (--power-enemy-weapons=, --enemy-drones=) still add their weapons / drones.
static var harmless_enemy := false
static var player_weapon_names: Array = []  # empty = the blueprint's weapons
static var _scenario_cli_done := false  # scenario flags are read once; menu changes win afterwards

# ------------------------------------------------------------------ game loop (run mode, `--run`)
# The combat sandbox stays the default; `--run` plays a run (rules/starmap.md, rules/events.md): the rules
# live in RunState (scripts/run/), this scene only shows them. The scene is rebuilt (reloaded) on every
# arrival and whenever a new event ship appears; the player ShipState and the run persist (statics).
static var run_mode := false
static var input_mode := InputProfile.PC
static var _run_cli_done := false
static var _cli_done_once := false  # run mode: screenshot / test flags are applied on the first build only
## Hangar choices for the next new run (TitleState.run_config: ship, difficulty, ae, ship_name, crew); set by the
## title scene before it loads this one. Empty = the CLI / sandbox defaults.
static var run_setup := {}
var run: RunState = null
var profile: InputProfile
var star_map_view: StarMapView
var sector_map_view: SectorMapView
var store_view: StoreView
var ship_screen: ShipScreen  # ship management window (rules/ship_management.md)
var hazard_hud: HazardHud
var asteroid_layers: AsteroidLayers
var asteroid_front: AsteroidLayers  # asteroid_back3 again over the player ship, only while jumping
var space_backdrop: SpaceBackdrop  # beacon background + planet / sun / pulsar / fleet (rules/backgrounds.md)
var screen_shake: ScreenShake  # CommandGui::UpdateShake: the HUD shakes on player hull damage / ASB shots
var run_end_box: RunEndBox
var event_box: EventBox
var focus_dim: ColorRect  # tint under full-focus windows (ship screens, beacon map)
var _jump_phase := ""  # "" / "leave" / "arrive" (jump animation after a beacon-map jump)
var _jump_t := 0.0
var _map_was_open := false
var has_enemy := true  # false in run mode at a beacon without an event ship (enemy views hidden)
var _built_arrival := -1
var _built_enemy := -1
var _built_sector := ""  # _sector_key() of the built location: a change = a sector jump (animated like a map jump)
var _modal_paused := false


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color8(10, 12, 24))
	# Difficulty first: the enemy's initial crew placement depends on it (rules/crew_ai.md).
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--difficulty="):
			_parse_difficulty(a.trim_prefix("--difficulty="))
	if not _scenario_cli_done:
		_scenario_cli_done = true
		_parse_scenario_cli()
	if not _run_cli_done:
		_run_cli_done = true
		_parse_run_cli()
	if run_mode:
		_ensure_run()
	_build()
	if run_mode and _cli_done_once:
		_apply_view()
		return
	_cli_done_once = true
	_handle_cli()


## --run [--seed=N] [--input=pc|touch] [--sector-desc=NAME] (and --sandbox = the default combat sandbox).
func _parse_run_cli() -> void:
	if DevicePreview.touch_default():
		input_mode = InputProfile.TOUCH  # mobile preview: the mouse is a finger (an explicit --input= wins)
	for a in OS.get_cmdline_user_args():
		if a == "--run" or a == "--last-stand" or a.begins_with("--boss-stage="):
			run_mode = true  # the Last Stand debug flags imply a run (LastStand.cli)
		elif a == "--sandbox":
			run_mode = false
		elif a.begins_with("--input="):
			input_mode = a.trim_prefix("--input=")


## Creates the run once (new run after a game over), then applies the run's CLI actions to the rules in
## argument order: --choose=N (repeatable, 1-based), --jump=BEACON|ship (debug jump, any beacon; "ship" = the
## nearest beacon whose event brings a ship), --map (opens the beacon map; closes a pending start dialog with
## choice 1 first), --select=BEACON (selects on the map; touch screenshots).
func _ensure_run() -> void:
	if RunState.current != null:
		run = RunState.current
		return
	var seed := randi() & 0x7fffffff
	var desc := ""
	var difficulty: int = [EventEngine.Difficulty.EASY, EventEngine.Difficulty.NORMAL,
		EventEngine.Difficulty.HARD][ShipAI.difficulty]
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed=") and not _run_seed_override:
			seed = int(a.trim_prefix("--seed="))
		elif a.begins_with("--sector-desc="):
			desc = a.trim_prefix("--sector-desc=")
	run = RunState.new_run(seed, player_ship_name, difficulty, desc, bool(run_setup.get("ae", true)))
	if not run_setup.is_empty():
		TitleState.apply_to_ship(run.ship, run_setup)
	RunState.current = run
	print("run: seed %d, sector %s (%s), %d beacons, start %d, exit %d" % [seed, run.sector_name, run.sector_desc,
		run.map.beacons.size(), run.map.start, run.map.exit])
	var p := InputProfile.new(input_mode)
	p.run = run
	var run_args: PackedStringArray = OS.get_cmdline_user_args() if not _run_seed_override else PackedStringArray()
	for a in run_args:
		_run_cli_partb(a, p)
		if a == "--list-beacons":
			for b in run.map.beacons:
				var ev: Dictionary = b.event
				print("beacon %d %s links %s: %s%s, %d choices%s" % [b.id, str(b.pos), str(b.links), ev.get("name", ""),
					" +ship" if not ev.get("ship", {}).is_empty() else "", ev.get("choices", []).size(),
					" EXIT" if b.exit else ""])
		elif a.begins_with("--choose="):
			var ok := run.choose(int(a.trim_prefix("--choose=")) - 1)
			print("choose %s: %s" % [a.trim_prefix("--choose="), "ok" if ok else "refused"])
		elif a.begins_with("--jump="):
			var v := a.trim_prefix("--jump=")
			var id := _find_ship_beacon() if v == "ship" else int(v)
			_debug_close_dialogs()
			if id >= 0 and id < run.map.beacons.size():
				run.jump_to(id)
				print("jump %s -> beacon %d: %s" % [v, id, run.dialog.get("name", "-")])
		elif a.begins_with("--event="):  # debug: show a named event at the current beacon (then --choose=N)
			_debug_close_dialogs()
			run.show_event(run.engine.base_event(a.trim_prefix("--event=")))
			print("event %s: %s" % [a.trim_prefix("--event="), run.dialog.get("name", "-")])
		elif a == "--map":
			_debug_close_dialogs()
			print("map open: %s" % run.apply(RunIntent.make(RunIntent.OPEN_MAP)))
		elif a.begins_with("--select="):
			# --select=BEACON | near (first neighbour): a click on that beacon through the input profile
			# (touch: selects and shows JUMP; pc: jumps at once)
			var v := a.trim_prefix("--select=")
			var links := run.map.links_of(run.current_beacon)
			p.beacon_click(int(links[0]) if v == "near" and not links.is_empty() else int(v))
			print("select beacon %s: selected %d" % [v, run.selected])


## Part B run flags (applied to the rules in argument order, with the part A ones):
## --fuel=N, --scrap=N, --hull-player=N, --ftl=F (charge 0..1), --fleet=X (danger-zone centre x) /
## --fleet-advance=N (N fleet moves), --store (debug jump to the nearest store beacon; its store opens),
## --store-select=CODE (store box code through the profile: touch selects, pc buys), --store-tab=1,
## --sector-map (debug jump to the exit, close dialogs, open the map and press NEXT SECTOR),
## --choose-sector=N (1-based neighbour through the profile), --env=N (hazard on the current beacon),
## --wait (out of fuel: WAIT), --distress, --end=gameover|victory (results screen).
func _run_cli_partb(a: String, p: InputProfile) -> void:
	var v := a.get_slice("=", 1)
	LastStand.cli(run, a)  # --last-stand, --boss-stage=1|2|3, --boss-turns=N, --boss-surge (rules/flagship.md)
	if a.begins_with("--fuel="):
		run.ship.fuel = int(v)
	elif a.begins_with("--scrap="):
		run.ship.scrap = int(v)
	elif a.begins_with("--hull-player="):
		run.ship.hull = int(v)
	elif a.begins_with("--ftl="):
		run.ship.ftl_charge = float(v)
	elif a.begins_with("--fleet="):
		run.fleet.center.x = float(v)
		for bid in run.fleet.newly_covered(run.map):
			RebelFleet.overtake(run.map, bid, run.engine)
	elif a.begins_with("--fleet-advance="):
		for i in int(v):
			run._advance_fleet(run.beacon())
	elif a == "--store" or a == "--store-arrive":  # --store-arrive: stop at the arrival event (no STORE click)
		var best := -1
		var bn := 1 << 30
		for b in run.map.beacons:
			if b.event.get("store", false) and b.id != run.current_beacon:
				var n := run.map.path(run.current_beacon, b.id).size()
				if n > 0 and n < bn:
					bn = n
					best = b.id
		_debug_close_dialogs()
		if best >= 0:
			run.jump_to(best)
			if a == "--store":
				_debug_close_dialogs()
				p.store_open()  # the store does not open by itself: the HUD STORE button
		print("store beacon %d: open %s, sections %s" % [best, run.store_open, str(run.store().sections.map(
			func(s): return RunStore.KINDS[s.type])) if run.store() else "-"])
	elif a.begins_with("--store-select="):
		p.store_click(int(v))
		print("store select %s: selected %d, message %s, scrap %d" % [v, run.store_selected, run.store_message,
			run.ship.scrap])
	elif a.begins_with("--store-hover="):  # PC hover on a store box code (info box, highlight; no purchase)
		p.store_hover(int(v))
	elif a.begins_with("--store-page="):  # (--store-pointer=X,Y is read by StoreView.setup)
		p.store_page(int(v))
	elif a.begins_with("--store-tab="):
		p.store_tab(int(v))
	elif a == "--sector-map":
		_debug_close_dialogs()
		run.jump_to(run.map.exit)
		_debug_close_dialogs()
		run.enemy = {}
		run.ship.ftl_charge = 1.0
		run.apply(RunIntent.make(RunIntent.OPEN_MAP))
		print("next sector: %s" % run.apply(RunIntent.make(RunIntent.NEXT_SECTOR)))
	elif a.begins_with("--choose-sector="):
		p.sector_click(int(run.tree.neighbours(run.sector_id)[int(v) - 1]))
		print("sector: %d %s (%s)" % [run.sector + 1, run.sector_name, run.sector_desc])
	elif a.begins_with("--env="):
		var sh := run.ship.sys("shields")
		run.env = int(v)
		run.hazard = HazardRule.create(int(v), 2, 7, sh.get_level() if sh else 0)
		run.hazard.apply_status(run.ship)
	elif a.begins_with("--asb="):
		# --asb=player|enemy|all|fleet: an ASB on the current beacon (fleet = the fleet's battery aimed at the
		# player in a danger zone, else the populated planet's), its gun placed as on arrival.
		var fleet := v == "fleet"
		run.env = HazardRule.Env.PDS
		run.hazard = HazardRule.create(HazardRule.Env.PDS, {"player": 0, "enemy": 1}.get(v, 0 if fleet else 2), 7, 0)
		run.space = run.space.duplicate()
		if fleet:
			run.space.danger = 1
			run.space.fleet = SpaceImages.danger_zone(1, run.space_rng)
			run.space.pds_planet = {}
		else:
			run.space.danger = 0
			run.space.fleet = []
			run.space.pds_planet = SpaceImages.pds_planet(run.engine.db.image_lists, run.space_rng)
		run.hazard.pds_origin = HazardRule.pds_origin_for(run.space)
		print("asb %s: target %d, gun at %s" % [v, run.hazard.target, str(run.hazard.pds_origin)])
	elif a.begins_with("--hazard-timer=") and run.hazard != null:
		# Screenshots: the next flare / pulse / volley comes S s from now (warning, sound and flash lead it).
		run.hazard.timer = maxf(run.hazard.goal - float(v), 0.0)
	elif a == "--close-dialogs":  # screenshots: dismiss the arrival event (HUD tooltips are inert under it)
		_debug_close_dialogs()
	elif a == "--wait":
		_debug_close_dialogs()
		var ok := run.apply(RunIntent.make(RunIntent.WAIT))
		run.step_wait(LastStand.WAIT_TIME)  # the 2 s map animation at once
		print("wait: %s, event %s" % [ok, run.dialog.get("name", "-")])
	elif a.begins_with("--ship-screen="):
		_debug_close_dialogs()
		print("ship screen %s: %s" % [v, run.apply(ShipManagement.make(RunIntent.OPEN_SHIP_SCREEN, {"arg": int(v)}))])
	elif a.begins_with("--give="):
		# --give=weapon|drone|augment|crew:NAME (repeatable): an event-style reward (slot → cargo → over box).
		var kind := v.get_slice(":", 0)
		var nm := v.get_slice(":", 1)
		if kind == "crew":
			run.ship.add_crew(nm, true)
			print("give crew %s: %d crew" % [nm, run.ship.own_crew().size()])
		else:
			print("give %s %s: %s" % [kind, nm, str(run.give_item(kind, nm))])
	elif a == "--loaded":
		_debug_loaded()
	elif a == "--distress":
		run.apply(RunIntent.make(RunIntent.TOGGLE_DISTRESS))
	elif a.begins_with("--end="):
		if v.begins_with("gameover_"):  # --end=gameover_crew|gameover_blowup: the real cause text
			run.game_over(v)
		else:
			run.end_run(v, "Debug end of run.")


## --loaded (run mode, e.g. with --last-stand / --boss-stage): a late-game ship for testing — every system the
## layout has room for (clonebay / artillery excepted) at its maximum, reactor maxed, full hull, a strong
## weapon / drone loadout, 8 crew, plenty of resources, everything powered.
const LOADED_WEAPONS := ["LASER_BURST_3", "BEAM_2", "ION_2", "LASER_BURST_2"]
const LOADED_DRONES := ["DEFENSE_2", "COMBAT_2"]
const LOADED_CREW := ["human", "engi", "mantis", "rock", "energy", "slug", "crystal", "anaerobic"]


func _debug_loaded() -> void:
	var s := run.ship
	for id in SystemState.ORDER:
		if id != "clonebay" and id != "artillery" and s.sys(id) == null:
			run.install_system(id)
	s.reactor_max = UpgradeSession.REACTOR_MAX
	for id in SystemState.ORDER:
		var sy := s.sys(id)
		if sy != null:
			sy.level = maxi(sy.level, UpgradeSession.max_level(s, id))
			sy.damage = 0
	s.hull = s.max_hull
	_replace_weapons(s, LOADED_WEAPONS)
	_replace_drones(s, LOADED_DRONES)
	var crew := s.own_crew().size()
	for i in range(crew, LOADED_CREW.size()):
		s.add_crew(LOADED_CREW[i], true)
	s.scrap = 999
	s.fuel = 30
	s.missiles = 30
	s.drone_parts = 30
	for id in SystemState.ORDER:
		if id != "weapons" and id != "drones" and s.sys(id) != null:
			for i in 8:
				if s.increase_power(id, true) != "":
					break
	for w in s.weapons:
		s.try_power_weapon(w)
	print("loaded: reactor %d, %d crew, weapons %s" % [s.reactor_max, s.own_crew().size(),
		str(s.weapons.map(func(w): return w.bp.get("name", "?")))])


func _debug_close_dialogs() -> void:
	for i in 8:
		if run.phase == RunState.Phase.DIALOG:
			run.choose(maxi(run.dialog_choices.find_custom(func(v): return v.enabled), 0))
		elif run.phase == RunState.Phase.MESSAGE:
			run.apply(RunIntent.make(RunIntent.CONTINUE))


## Debug: the beacon nearest to the current one (by path) whose event spawns a hostile ship on arrival.
func _find_ship_beacon() -> int:
	var best := -1
	var best_n := 1 << 30
	for b in run.map.beacons:
		var s: Dictionary = b.event.get("ship", {})
		if b.id == run.current_beacon or s.is_empty() or s.get("hostile_only", false) or not s.get("hostile", false):
			continue
		var n := run.map.path(run.current_beacon, b.id).size()
		if n > 0 and n < best_n:
			best_n = n
			best = b.id
	return best


## FTL combat HUD (rules/hud_layout.md), laid out in the 1280×720 frame (canvas_items stretch scales it):
## background → player ship (full frame) → enemy window frame → enemy ship (inside the window) → top
## buttons + enemy status → crew list → systems bar → weapons / drones → pause → ship status (last).
## The prototype's debug controls live in a toggleable overlay (F12 or the DEBUG corner button).
func _build() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	hud_root = Control.new()
	hud_root.position = Vector2.ZERO
	hud_root.size = HudLayout.FRAME
	hud_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(hud_root)

	# Beacon space (rules/backgrounds.md): background image / nebula clouds, then planet / sun / pulsar / fleet;
	# set up below once the player ship exists. Touch UI: the background image is drawn by MirroredBackground
	# (fills wider screens with the mirrored image), the rest keeps its 1280×720 frame position.
	space_backdrop = SpaceBackdrop.new()
	if input_mode == InputProfile.TOUCH:
		var mbg: Control = preload("res://scripts/ui/mirrored_background.gd").new()
		mbg.size = HudLayout.FRAME
		hud_root.add_child(mbg)
		space_backdrop.mirror = mbg
	hud_root.add_child(space_backdrop)

	combat = Combat.new()
	add_child(combat)
	player_space = Space.new()
	enemy_space = Space.new()
	asteroid_layers = AsteroidLayers.new()  # asteroid field scrollers: above the background, under the ships
	hud_root.add_child(asteroid_layers)
	hud_root.add_child(player_space)
	asteroid_front = AsteroidLayers.new()  # RenderStatic: OnRenderAsteroids(1 layer) after RenderPlayerShip (jump)
	hud_root.add_child(asteroid_front)
	enemy_window_back = EnemyWindow.new()
	hud_root.add_child(enemy_window_back)
	hud_root.add_child(enemy_space)
	if run != null:
		# Run mode: the run's persistent player ship; the event ship if there is one, else a hidden placeholder
		# that is not part of the combat (no enemy at this beacon).
		_built_arrival = run.arrival_serial
		_built_enemy = run.enemy_serial
		_built_sector = _sector_key()
		has_enemy =not run.enemy.is_empty() and not run.enemy.done
		player_space.setup(run.ship)
		# A continued run builds the saved event ship once (SaveGame.take_enemy_ship), else a fresh one.
		var es := SaveGame.take_enemy_ship(run) if has_enemy else ShipState.new(enemy_ship_name, false)
		if not has_enemy:
			es.crew.clear()
		enemy_space.setup(es)
		combat.add_space(player_space, enemy_space if has_enemy else null)
		if has_enemy:
			combat.add_space(enemy_space, player_space)
			combat.ais[enemy_space].hostile = run.enemy.hostile
		ShipSave.redeploy(run.ship)  # continued run: drones that were powered (opponents set now)
		if has_enemy:
			ShipSave.redeploy(es)
		# Continued run: projectiles in flight, drones in space, volleys, teleports ... (BattleSave, once).
		BattleSave.apply(combat, SaveGame.take_battle(run), run.ship, es if has_enemy else null)
	else:
		player_space.setup(ShipState.new(player_ship_name, true))
		enemy_space.setup(ShipState.new(enemy_ship_name, false))
		if harmless_enemy:
			_strip_armament(enemy_space.ship)
		if not player_weapon_names.is_empty():
			_replace_weapons(player_space.ship, player_weapon_names)
		combat.add_space(player_space, enemy_space)
		combat.add_space(enemy_space, player_space)
		if harmless_enemy:
			_calm_ai(combat.ais[enemy_space])
		if not player_drone_names.is_empty():
			_replace_drones(player_space.ship, player_drone_names)
		if not enemy_drone_names.is_empty():
			_replace_drones(enemy_space.ship, enemy_drone_names)

	enemy_window_back.setup(enemy_space.ship, player_space.ship, false)
	asteroid_layers.setup(run, player_space.ship, combat)
	asteroid_front.setup_front(asteroid_layers)
	space_backdrop.setup(run.space if run != null and not run.space.is_empty() else SpaceBackdrop.sandbox_space(),
		run.hazard if run != null else null, player_space.ship)
	space_backdrop.jump_source = asteroid_layers  # foreground jump zoom + "space runs on" while jumping away
	space_backdrop.player_paused = func() -> bool:  # CommandGui::bPaused: the player's pause, not a menu / box
		return combat.paused and not (_modal_paused or _menu_paused or _options_paused)
	command_hud = CommandHud.new()
	command_hud.setup(player_space.ship, combat, false)
	command_hud.run = run
	hud_root.add_child(command_hud)
	enemy_window = EnemyWindow.new()
	enemy_window.setup(enemy_space.ship, player_space.ship, true)
	enemy_window.run = run  # escape message (FTL charging / delayed / imminent)
	hud_root.add_child(enemy_window)
	# Touch UI: the enlarged TARGET window follows the canvas width (once: _rebuild runs _build again).
	if input_mode == InputProfile.TOUCH and not get_viewport().size_changed.is_connected(_on_viewport_resized):
		get_viewport().size_changed.connect(_on_viewport_resized)

	# Crew selection / orders / crew list (rules/crew_controls.md), drawn above the spaces.
	crew_control = CrewControl.new(player_space.ship, enemy_space.ship, _space_to_world, _space_rect)
	crew_list = CrewList.new()
	crew_list.setup(crew_control)
	hud_root.add_child(crew_list)

	# Systems bar, weapons and drones panels (bottom row, rules/hud_layout.md SystemControl / ArmamentControl).
	weapon_control = WeaponControl.new(player_space.ship)
	systems_bar = SystemsBar.new()
	systems_bar.combat = combat
	systems_bar.detach_subsystems = input_mode == InputProfile.TOUCH  # touch UI: subsystems moved (_touch_layout)
	systems_bar.setup(player_space.ship)
	hud_root.add_child(systems_bar)
	_build_armament_panels()
	systems_bar.rebuilt.connect(_build_armament_panels)  # a system bought / removed: boxes moved
	pause_overlay = CommandHud.new()
	pause_overlay.setup(player_space.ship, combat, true)
	hud_root.add_child(pause_overlay)
	ship_status = ShipStatusHud.new()
	ship_status.setup(player_space.ship)
	hud_root.add_child(ship_status)  # ShipStatus is drawn last, above everything
	end_box = EndBox.new()
	end_box.visible = false
	end_box.restart = _restart
	hud_root.add_child(end_box)  # victory / game over placeholders (rules/ship_destruction.md §6, §7)
	leave_crew_dialog = ConfirmWindow.new("confirm_leave_crew", 300)
	leave_crew_dialog.touch = input_mode == InputProfile.TOUCH
	leave_crew_dialog.visible = false
	hud_root.add_child(leave_crew_dialog)
	if run != null:
		profile = InputProfile.new(input_mode)
		profile.run = run
		event_box = EventBox.new()
		event_box.setup(run, profile)
		hud_root.add_child(event_box)
		star_map_view = StarMapView.new()
		star_map_view.setup(run, profile)
		hud_root.add_child(star_map_view)
		sector_map_view = SectorMapView.new()
		sector_map_view.setup(run, profile)
		hud_root.add_child(sector_map_view)
		store_view = StoreView.new()
		store_view.setup(run, profile)
		hud_root.add_child(store_view)
		ship_screen = ShipScreen.new()
		ship_screen.setup(run, profile)
		hud_root.add_child(ship_screen)
		if store_view.has_method("embed_sell_view"):  # store SELL tab = Equipment in store mode (NOTES.md)
			var sv := EquipmentView.new()
			sv.setup(run, profile)
			store_view.embed_sell_view(sv)
		hazard_hud = HazardHud.new()
		hazard_hud.setup(run)
		hud_root.add_child(hazard_hud)
		hud_root.move_child(hazard_hud, ship_status.get_index())  # under the top HUD and the boxes
		var flagship_hud := FlagshipHud.new()  # POWER SURGE DETECTED (SpaceStatus incomingFire, rules/flagship.md)
		flagship_hud.setup(run)
		hud_root.add_child(flagship_hud)
		hud_root.move_child(flagship_hud, ship_status.get_index())
		# Full-focus windows (ship screens, beacon map): CommandGui::RenderStatic tints the scene, the HUD and
		# the PAUSED text × 0.15 but not ShipStatus (top-left), which is drawn after the tint is removed.
		focus_dim = ColorRect.new()
		focus_dim.color = Color(0, 0, 0, 0.85)
		focus_dim.size = HudLayout.FRAME
		focus_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
		focus_dim.visible = false
		hud_root.add_child(focus_dim)
		hud_root.move_child(focus_dim, ship_status.get_index())
		run_end_box = RunEndBox.new()
		run_end_box.setup(run, _on_run_end_command)
		hud_root.add_child(run_end_box)

	screen_shake = ScreenShake.new()
	screen_shake.setup(player_space.ship, _screen_shake_targets, func() -> HazardRule:
		return run.hazard if run != null else null)
	add_child(screen_shake)
	_build_debug()
	if input_mode == InputProfile.TOUCH:  # touch UI: full-frame windows centred in the canvas (wide / tall screens)
		# The band offset first, then the windows (_touch_center_band re-centres them with the new offset).
		if not get_viewport().size_changed.is_connected(_touch_center_band):
			get_viewport().size_changed.connect(_touch_center_band)
		_touch_center_band()
	if run == null:
		_set_enemy_shields(enemy_shield_layers)  # sandbox test setting (run mode: the blueprint's shields)
	else:
		btn_enemy_shields.text = "Enemy shields: ship"
	_set_sensors(sensors_level)
	print("scenario: player %s (weapons: %s, drones: %s), enemy %s" % [player_ship_name, weapon_preset,
		drone_preset, enemy_ship_name])
	enemy_space.room_clicked.connect(_on_enemy_room_clicked)
	enemy_space.mouse_released.connect(_on_enemy_mouse_released)
	player_space.room_clicked.connect(_on_player_room_clicked)
	Hooks.emit(&"hud_ready", "hud", hud_root, player_space.ship)
	_apply_view()


## Weapons and drones panels at the systems bar's box locations (re-run when the bar rebuilds its boxes; the new
## panels take the old ones' place in the HUD order).
func _build_armament_panels() -> void:
	var at := systems_bar.get_index() + 1
	if weapon_panel != null and is_instance_valid(weapon_panel) and weapon_panel.get_parent() == hud_root:
		at = weapon_panel.get_index()
		hud_root.remove_child(weapon_panel)
		weapon_panel.queue_free()
	if drone_panel != null and is_instance_valid(drone_panel) and drone_panel.get_parent() == hud_root:
		hud_root.remove_child(drone_panel)
		drone_panel.queue_free()
	drone_panel = null
	weapon_panel = WeaponPanel.new()
	# Touch UI: the vertical weapons column between the ships (placed by _touch_layout), not the bottom box.
	# (Open-Fold "split" layout: the PC boxes, placed by _touch_layout_split.)
	var want := _armament_vertical()  # pan: PC boxes too
	var vert: bool = want[0]
	weapon_panel.setup(weapon_control, systems_bar.weapons_loc, vert)
	weapon_panel.reactor = systems_bar.reactor
	weapon_panel.visible = player_space.ship.sys("weapons") != null
	hud_root.add_child(weapon_panel)
	hud_root.move_child(weapon_panel, at)
	var touch := input_mode == InputProfile.TOUCH
	if player_space.ship.sys("drones") != null and player_space.ship.drone_slots > 0:
		drone_panel = DronePanel.new()
		# Touch UI: a vertical drones column under the weapons column (placed by _touch_layout).
		# (Split: the vertical drones column, attached to the TARGET window, under the PC weapons box row.)
		var dvert: bool = want[1]
		drone_panel.setup(player_space.ship, systems_bar.drones_loc, dvert)
		drone_panel.reactor = systems_bar.reactor
		hud_root.add_child(drone_panel)
		hud_root.move_child(drone_panel, at + 1)
		if systems_bar.columns.has("drones"):
			# Its power row is in the vertical drones column; a PC box (pan, after a layout switch) shows it again.
			systems_bar.columns["drones"].visible = not dvert
	if touch and _touch_sig != "":  # rebuilt after the first layout: place the columns again
		_touch_layout()


## CommandGui::RenderStatic's shaken block (rules/hud_layout.md "Screen shake"): everything drawn inside the
## UpdateShake translate — FTL / SHIP / MENU buttons, enemy window and ship, crew list, system / weapon / drone
## bars, pause text, hazard / flagship status, ShipStatus — plus the touch-only HUD pieces. Not the background,
## asteroid layers, player ship or focus windows.
func _screen_shake_targets() -> Array:
	var out: Array = [enemy_window_back, enemy_space, command_hud, enemy_window, crew_list, systems_bar,
		weapon_panel, drone_panel, pause_overlay, hazard_hud, ship_status, touch_buttons, touch_power, pan_arrows]
	if hud_root != null:
		for c in hud_root.get_children():
			if c is FlagshipHud:
				out.append(c)
	return out


func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(130, 44)
	b.add_theme_font_size_override("font_size", 18)
	b.pressed.connect(cb)
	return b


## Debug overlay (prototype controls, not FTL): a top bar with Pause / View / Restart / Enemy shields /
## Sensors / Tests ▾, hidden by default; F12 or the small DEBUG corner button toggles it.
func _build_debug() -> void:
	debug_layer = CanvasLayer.new()
	debug_layer.layer = 10
	add_child(debug_layer)
	debug_panel = PanelContainer.new()
	debug_panel.position = Vector2.ZERO
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.8)
	style.set_content_margin_all(4)
	debug_panel.add_theme_stylebox_override("panel", style)
	debug_layer.add_child(debug_panel)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	debug_panel.add_child(top)
	top_bar = top
	btn_pause = _button("Pause", _toggle_pause)
	btn_view = _button("View: side by side", _toggle_view)
	btn_me = _button("My ship", func(): _show_enemy(false))
	btn_enemy = _button("Enemy", func(): _show_enemy(true))
	btn_enemy_shields = _button("", _cycle_enemy_shields)
	btn_enemy_shields.custom_minimum_size.x = 220
	btn_sensors = _button("", _cycle_sensors)
	btn_sensors.custom_minimum_size.x = 150
	tests_menu = _tests_menu()
	for b in [btn_pause, btn_view, btn_me, btn_enemy, _button("Restart", _restart), btn_enemy_shields,
			btn_sensors, tests_menu, _button("Options", open_options)]:
		b.focus_mode = Control.FOCUS_NONE  # Space / Enter are game hotkeys, not button activation
		top.add_child(b)
	debug_panel.visible = debug_visible
	debug_button = Button.new()
	debug_button.text = "DEBUG"
	debug_button.focus_mode = Control.FOCUS_NONE
	debug_button.add_theme_font_size_override("font_size", 10)
	debug_button.position = Vector2(1226, 2)
	debug_button.size = Vector2(50, 18)
	debug_button.modulate = Color(1, 1, 1, 0.45)
	debug_button.pressed.connect(toggle_debug)
	debug_layer.add_child(debug_button)
	pause_menu = PauseMenuView.new()
	pause_menu.visible = false
	pause_menu.command.connect(_on_menu_command)
	debug_layer.add_child(pause_menu)
	vanilla_options = VanillaOptionsView.new()
	vanilla_options.visible = false
	vanilla_options.mod_options.connect(open_options)
	debug_layer.add_child(vanilla_options)
	options = OptionsScreen.new()
	options.visible = false
	options.closed.connect(_on_options_closed)
	debug_layer.add_child(options)


## Options screen (rules/hooks.md "Settings"): pauses the game while open.
func open_options() -> void:
	if options == null or options.visible:
		return
	if not combat.paused:
		combat.paused = true
		_options_paused = true
	options.show_screen()


## Esc menu (MenuScreen, rules/main_menu.md §6): pauses the game while open.
func open_menu() -> void:
	if pause_menu == null or pause_menu.visible:
		return
	if not combat.paused:
		combat.paused = true
		_menu_paused = true
	var diff := ShipAI.difficulty
	var ae := run.engine.ae if run != null else bool(run_setup.get("ae", true))
	pause_menu.open(diff, ae, player_ship_name)


## Esc menu commands (CApp::OnLoop, rules/save_and_profile.md §1.1): CONTINUE closes; MAIN MENU saves the run and
## goes to the title; SAVE+QUIT saves and quits the game; HANGAR (title in the hangar) and RESTART (same setup, new
## seed) abandon the run: its score goes into the profile and the save is deleted; OPTIONS opens FTL's options.
func _on_menu_command(c: String) -> void:
	match c:
		"continue":
			pause_menu.visible = false
			if _menu_paused:
				combat.paused = false
				_menu_paused = false
		"options":
			vanilla_options.show_screen()
		"mainmenu":
			save_run_now()  # command 5: WorldManager::SaveGame unless the run is over
			RunState.current = null
			FrameHost.change_scene(get_tree(), "res://title.tscn")
		"save":
			save_run_now()  # command 8: save, then exit the game
			RunState.current = null
			get_tree().quit()
		"hangar":
			ProfileTracker.abandon(run)  # command 6: Save(true) + deleteAllSaveFiles
			SaveGame.delete()
			RunState.current = null
			load("res://scripts/title.gd").open_hangar_next = true
			FrameHost.change_scene(get_tree(), "res://title.tscn")
		"reset":
			ProfileTracker.abandon(run)  # command 0: Save(true) + deleteAllSaveFiles
			SaveGame.delete()
			RunState.current = null
			_run_seed_override = run_mode
			FrameHost.reload_scene(get_tree())


## WorldManager::SaveGame + ScoreKeeper::Save from the run scene (Esc menu, window close, app paused). Nothing in
## the sandbox, after the run ended, or when saving is off (SaveGame.persist: the real game only).
func save_run_now() -> bool:
	if run == null or not run_mode:
		return false
	var es: ShipState = enemy_space.ship if has_enemy and enemy_space != null else null
	var ok := SaveGame.save_run(run, es, run_setup, combat)
	PlayerProfile.current().save()
	return ok


## CApp::OnRequestExit (window closed) / CApp::OnSuspend (mobile: app sent to the background or closed): the run is
## saved so it can be continued (rules/save_and_profile.md §1.1).
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED:
		if is_inside_tree():
			save_run_now()


func _on_options_closed() -> void:
	if _options_paused:
		combat.paused = false
		_options_paused = false


func toggle_debug() -> void:
	debug_visible = not debug_visible
	debug_panel.visible = debug_visible


## Mouse over the debug controls (they are not part of the game input).
func _over_debug(pos: Vector2) -> bool:
	if tests_menu.get_popup().visible:
		return true
	if debug_button.get_global_rect().has_point(pos):
		return true
	return debug_panel.visible and debug_panel.get_global_rect().has_point(pos)


## Debug actions in a drop-down, so they take no screen space (a row of buttons made the
## layout wider than the window and pushed the enemy ship off-screen).
func _tests_menu() -> MenuButton:
	var m := MenuButton.new()
	m.text = "Tests ▾"
	m.flat = false
	m.custom_minimum_size = Vector2(110, 44)
	m.add_theme_font_size_override("font_size", 18)
	var actions := [
		["Ion 1 → enemy weapons", func(): _hit(enemy_space.ship, "weapons", 1, true)],
		["Dmg 1 → enemy weapons", func(): _hit(enemy_space.ship, "weapons", 1, false)],
		["Ion 1 → my weapons", func(): _hit(player_space.ship, "weapons", 1, true)],
		["Dmg 1 → my weapons", func(): _hit(player_space.ship, "weapons", 1, false)],
		["Event −1 → my shields", func(): _toggle_loss(player_space.ship, "shields")],
		["Hack → my engines", func(): _toggle_hack(player_space.ship, "engines")],
		["Hack → enemy shields", func(): _toggle_hack(enemy_space.ship, "shields")],
		["Doors: open all", func(): player_space.ship.env.set_all_doors(true)],
		["Doors: close all", func(): player_space.ship.env.set_all_doors(false, true)],
		["Doors: vent (airlocks open)", func(): player_space.ship.env.set_all_doors(true, true)],
		["Fire → my weapons", func(): _test_fire(player_space.ship, "weapons")],
		["Board 2 → my ship", func(): _board(player_space.ship, 2)],
		["Board 2 → enemy ship", func(): _board(enemy_space.ship, 2)],
		["Repair all", _repair_all],
	]
	var popup := m.get_popup()
	popup.add_theme_font_size_override("font_size", 16)
	# Scenario (each change rebuilds the scene, like Restart)
	popup.add_submenu_node_item("Player ship", _choice_menu(PLAYER_SHIPS, player_ship_name,
		func(v: String): player_ship_name = v))
	popup.add_submenu_node_item("Player weapons", _choice_menu(WEAPON_PRESETS.keys(), weapon_preset,
		_set_weapon_preset))
	popup.add_submenu_node_item("Player drones", _choice_menu(DRONE_PRESETS.keys(), drone_preset,
		_set_drone_preset))
	popup.add_submenu_node_item("Enemy ship", _choice_menu(ENEMY_SHIPS, enemy_ship_name,
		func(v: String): enemy_ship_name = v))
	popup.add_separator()
	for i in actions.size():
		popup.add_item(actions[i][0], i)
	popup.id_pressed.connect(func(id: int): actions[id][1].call())
	return m


## Radio sub-menu: picking an entry calls `apply` with it and restarts the scene.
func _choice_menu(options: Array, current: String, apply: Callable) -> PopupMenu:
	var sub := PopupMenu.new()
	sub.add_theme_font_size_override("font_size", 16)
	for i in options.size():
		sub.add_radio_check_item(options[i], i)
		sub.set_item_checked(i, options[i] == current)
	sub.id_pressed.connect(func(id: int):
		apply.call(options[id])
		_restart())
	return sub


static func _set_weapon_preset(preset: String) -> void:
	weapon_preset = preset
	player_weapon_names = WEAPON_PRESETS.get(preset, []).duplicate()


static func _set_drone_preset(preset: String) -> void:
	drone_preset = preset
	player_drone_names = DRONE_PRESETS.get(preset, []).duplicate()


## Scenario flags, read once per run (before the scene is built; the menu wins after that):
## --player-ship=NAME  --enemy-ship=NAME  --weapons=PRESET  --player-weapons=WEAPON,WEAPON
func _parse_scenario_cli() -> void:
	harmless_enemy = DevicePreview.active()
	if DevicePreview.active():  # mobile preview: the HUD's worst case (data/test_ships.xml TEST_SHIP_MAX) + drones
		player_ship_name = "TEST_SHIP_MAX"
		_set_drone_preset("combat+defense")
	for a in OS.get_cmdline_user_args():
		if a == "--harmless-enemy" or a.begins_with("--harmless-enemy="):
			harmless_enemy = a.get_slice("=", 1) not in ["0", "false", "off"]
		elif a.begins_with("--player-ship="):
			var n := a.trim_prefix("--player-ship=")
			if FtlData.has_ship_blueprint(n):
				player_ship_name = n
			else:
				push_warning("--player-ship: unknown blueprint " + n)
		elif a.begins_with("--enemy-ship="):
			var n := a.trim_prefix("--enemy-ship=")
			if FtlData.has_ship_blueprint(n):
				enemy_ship_name = n
			else:
				push_warning("--enemy-ship: unknown blueprint " + n)
		elif a.begins_with("--weapons="):
			var preset := a.trim_prefix("--weapons=")
			if WEAPON_PRESETS.has(preset):
				_set_weapon_preset(preset)
			else:
				push_warning("--weapons: unknown preset %s (%s)" % [preset, ", ".join(WEAPON_PRESETS.keys())])
		elif a.begins_with("--player-weapons="):
			# test: replace the player's weapons (e.g. ION_1,LASER_HULL_1)
			weapon_preset = "custom"
			player_weapon_names = Array(a.trim_prefix("--player-weapons=").split(","))
		elif a.begins_with("--drones="):
			var preset := a.trim_prefix("--drones=")
			if DRONE_PRESETS.has(preset):
				_set_drone_preset(preset)
			else:
				push_warning("--drones: unknown preset %s (%s)" % [preset, ", ".join(DRONE_PRESETS.keys())])
		elif a.begins_with("--player-drones="):
			# test: replace the player's drones (e.g. COMBAT_1,DEFENSE_2)
			drone_preset = "custom"
			player_drone_names = Array(a.trim_prefix("--player-drones=").split(","))
		elif a.begins_with("--enemy-drones="):
			enemy_drone_names = Array(a.trim_prefix("--enemy-drones=").split(","))


## Test: ion or direct damage to a system (as if a weapon had hit it).
func _hit(ship: ShipState, sys_id: String, amount: int, is_ion: bool) -> void:
	var before := _weapons_line(ship)
	if is_ion:
		ship.ion_system(sys_id, amount)
	else:
		ship.damage_system(sys_id, amount)
	Combat.log("%s %s %d on %s: %s  →  %s" % ["ION" if is_ion else "DAMAGE", ship.blueprint.name,
		amount, sys_id, before, _weapons_line(ship)])


func _weapons_line(ship: ShipState) -> String:
	var parts := []
	for i in ship.weapons.size():
		var w := ship.weapons[i]
		parts.append("%d:%s(%d)%s" % [i + 1, w.bp.name, w.power_cost(), "ON" if w.powered else "off"])
	var s := ship.sys("weapons")
	return "[%s] cap %d/%d ion %d reactor free %d" % [", ".join(parts), ship.weapons_power_used(),
		s.max_power(), s.ion, ship.reactor_free()]


func _toggle_loss(ship: ShipState, sys_id: String) -> void:
	var s := ship.sys(sys_id)
	if s:
		ship.set_power_loss(sys_id, 0 if s.power_loss > 0 else 1)


## Test: a real hack of `victim`'s system by the other ship (its hacking system, or a debug virtual one when
## it has none; rules/hacking.md): the drone is placed attached at once and a pulse starts. Toggles: a
## second call stops that hack.
func _toggle_hack(victim: ShipState, sys_id: String) -> void:
	var attacker := victim.opponent
	var s := victim.sys(sys_id)
	if s == null or attacker == null:
		return
	if attacker.hacking and attacker.hack_target == s:
		HackingRule.stop(attacker)
		return
	_debug_hack(attacker, sys_id, true)
	HackingRule.initiate_pulse(attacker)


## Debug hack launch (also --hack=): the attacker gets a virtual hacking system if it has none and at least
## one drone part, then StartHacking on the victim's system. `attached`: the drone is launched and placed
## on the hull at once (no flight). Returns false if refused.
func _debug_hack(attacker: ShipState, sys_id: String, attached := false) -> bool:
	var victim := attacker.opponent
	var s := victim.sys(sys_id) if victim else null
	if s == null:
		push_warning("hack: no %s system to hack" % sys_id)
		return false
	HackingRule.ensure_virtual(attacker)
	attacker.drone_parts = maxi(attacker.drone_parts, 1)
	if attacker.hacking:
		HackingRule.stop(attacker)
	if not HackingRule.start_hacking(attacker, s):
		return false
	if attached:
		HackingRule.tick(attacker, 0.0)  # launch now
		var d := HackingRule.drone(attacker)
		var land := HackingRule.pick_landing(victim, s.room, attacker.rng)
		d.space_ship = victim
		d.move_ship = victim
		d.pos = land.point
		d.last_pos = d.pos
		d.heading = rad_to_deg(land.dir.angle())
		d.pod_phase = 2
		d.land_time = 2.0
		HackingRule.tick(attacker, 0.0)  # passive effect
	return true


## Test: fire on 2 random tiles of a system's room.
func _test_fire(ship: ShipState, sys_id: String) -> void:
	var s := ship.sys(sys_id)
	if s:
		for i in 2:
			ship.ignite(s.room, randi() % ship.room_tiles(s.room))


## Test boarding (no teleporter yet): n crew of the other side appear aboard `ship`, in `room` (or a
## random room with free intruder slots). Races cycle through the other side's blueprint crew unless
## --board-race= is given. Enemy boarders are driven by the boarded ship's CrewAI.
static var board_race := ""


func _board(ship: ShipState, n: int, room := -1) -> void:
	var other := enemy_space.ship if ship.is_player else player_space.ship
	var races: Array = other.blueprint.crew if not other.blueprint.crew.is_empty() else ["human"]
	for i in n:
		var race: String = board_race if board_race != "" else races[i % races.size()]
		# --board-race=BOARDER / BOARDER_ION: a delivered boarding drone (BoarderDrone / IonDrone) instead of crew.
		var drone_kind: String = {"BOARDER": "boarder", "BOARDER_ION": "boarder_ion"}.get(race.to_upper(), "")
		var c := ship.add_crew("battle" if drone_kind == "boarder" else (drone_kind if drone_kind != "" else race),
			not ship.is_player, room)
		if c and drone_kind != "":
			c.make_drone(drone_kind)
		Combat.log("BOARD %s: %s %s" % [ship.blueprint.name, race,
			("room %d" % c.room) if c else "no free slot"])


## Test: set a system's power to n bars (weapons: n weapons powered in slot order).
func _set_system_power(ship: ShipState, sys_id: String, n: int) -> void:
	if sys_id == "weapons":
		for i in ship.weapons.size():
			if i < n:
				ship.try_power_weapon(ship.weapons[i])
			else:
				ship.depower_weapon(ship.weapons[i])
		return
	var s := ship.sys(sys_id)
	if s == null:
		return
	while s.power > n and ship.decrease_power(sys_id):
		pass
	while s.power < n and ship.increase_power(sys_id) == "ok":
		pass


## One status line for the screenshot runs: reactor, battery, cloak, teleporter, artillery, clonebay.
func _systems_line(ship: ShipState) -> String:
	var parts := ["reactor %d/%d" % [ship.reactor_used(), ship.reactor_capacity()]]
	var b := ship.sys("battery")
	if b:
		parts.append("battery %s cap %d used %d lock %d" % ["ON" if b.turned_on else "off", ship.battery_cap,
			ship.battery_used(), b.ion])
	var c := ship.sys("cloaking")
	if c:
		parts.append("cloak %s %.1f/%.1f s lock %d evasion %d" % ["ON" if c.turned_on else "off", c.timer,
			c.timer_goal, c.ion, ship.dodge_factor()])
	var t := ship.sys("teleporter")
	if t:
		parts.append("teleporter power %d lock %d (%.1f s) prepared %d" % [t.effective_power(), t.ion,
			t.lock_remaining(), TeleporterRule.prepared_crew(ship)])
	for w in ship.artillery:
		parts.append("artillery %s %.1f/%.1f s" % [w.bp.name, w.charge, w.max_charge(0)])
	if ship.sys("clonebay"):
		parts.append("clonebay queue %d progress %.2f" % [ship.clone_queue.size(), ClonebayRule.progress(ship)])
	if not ship.drones.is_empty():
		parts.append("drones parts %d super %d: %s" % [ship.drone_parts, ship.super_shield, ", ".join(
			ship.drones.map(func(d): return "%s %s%s%s" % [d.bp.name, "ON" if d.powered else "off",
				" deployed" if d.deployed else "", (" rebuild %.1f" % d.destroyed_timer) if d.rebuilding() else ""]))])
	parts.append("power: " + ", ".join(ship.system_list().map(func(id): return "%s %d%s" % [id,
		ship.sys(id).effective_power(), ("(+%db)" % ship.sys(id).battery) if ship.sys(id).battery > 0 else ""])))
	var hs := HackingRule.system(ship)
	if hs:
		var d := ship.hack_drone
		parts.append("hacking %s target %s drone %s pulse %s (%.1f/%.1f s) lock %d parts %d" % [
			"ON" if ship.hacking else "off", ship.hack_target.id if ship.hack_target else "-",
			("attached" if d.arrived() else "flying") if d and d.deployed else "-",
			"ON" if HackingRule.pulsing(ship) else "off", ship.hack_elapsed, ship.hack_duration, hs.ion,
			ship.drone_parts])
	if ship.sys("mind"):
		parts.append("mind %s %.1f/%.1f s controlled %s lock %d" % ["IN USE" if ship.mind_in_use else "idle",
			ship.mind_elapsed, ship.mind_duration, str(ship.mind_list.map(func(c): return c.race)),
			ship.sys("mind").ion])
	var hk := ship.system_list().filter(func(id): return ship.sys(id).hack_effect() > 0)
	if not hk.is_empty():
		parts.append("hacked: " + ", ".join(hk.map(func(id): return "%s L%d" % [id, ship.sys(id).hack_effect()])))
	return "; ".join(parts)


func _repair_all() -> void:
	for ship in [player_space.ship, enemy_space.ship]:
		ship.fires.clear()
		ship.breaches.clear()
		for s in ship.systems.values():
			s.damage = 0
			s.hacked = false
		for id in ship.systems:
			ship.set_power_loss(id, 0)


func _cycle_sensors() -> void:
	var s := player_space.ship.sys("sensors")
	_set_sensors((s.get_level() if s else 0) % 4 + 1)


## n < 0: keep the ship's own sensors level.
func _set_sensors(n: int) -> void:
	sensors_level = n
	var s := player_space.ship.sys("sensors")
	if s and n >= 0:
		s.override_level = n
	var lvl := s.get_level() if s else 0
	enemy_space.show_power = player_space.ship.sensors_provide(3)
	btn_sensors.text = "Sensors: %d" % lvl


func _on_enemy_room_clicked(room: int, button: int, shift: bool) -> void:
	if button == MOUSE_BUTTON_RIGHT:
		weapon_control.disarm()
		combat.player_tp_armed = TeleporterRule.NONE
		_disarm_systems()
	elif button == MOUSE_BUTTON_LEFT and not enemy_space.ship.hostile:
		# CombatControl: weapons / beams / hacking / mind control never target a non-hostile ship, but the armed
		# teleporter does (UpdateTarget / SelectTarget have no hostile check; it stays armed only while
		# CanReceiveTeleport = own crew aboard): retrieving boarders from a crewless / surrendered ship.
		combat.teleport_room_clicked(room)
	elif button == MOUSE_BUTTON_LEFT and HackingRule.room_clicked(player_space.ship, room):
		pass  # hacking armed: launch the drone at this room's system
	elif button == MOUSE_BUTTON_LEFT and MindRule.room_clicked(player_space.ship, enemy_space.ship, room):
		pass  # mind control armed: the crew in this room
	elif button == MOUSE_BUTTON_LEFT and combat.teleport_room_clicked(room):
		pass  # teleporter armed: this room is the send target / the room to retrieve from
	elif weapon_control.armed_is_beam():
		# Beam: first click (in a room) = start, second click = direction (fixed length).
		if weapon_control.beam_ship == null:
			weapon_control.begin_beam(enemy_space.ship, enemy_space.mouse_world)
		else:
			weapon_control.finish_beam(enemy_space.mouse_world, shift)
	elif weapon_control.armed >= 0 and room >= 0:
		weapon_control.aim_at(enemy_space.ship, room, shift)


## Beam aiming by drag: releasing far enough from the start point confirms the beam.
func _on_enemy_mouse_released(button: int, shift: bool) -> void:
	if button == MOUSE_BUTTON_LEFT and weapon_control.beam_ship == enemy_space.ship:
		weapon_control.finish_beam(enemy_space.mouse_world, shift)


func _on_player_room_clicked(room: int, button: int, shift: bool) -> void:
	if button == MOUSE_BUTTON_RIGHT:
		weapon_control.disarm()
		_disarm_systems()
	elif button == MOUSE_BUTTON_LEFT and MindRule.room_clicked(player_space.ship, player_space.ship, room):
		pass  # mind control armed: intruders in an own room
	elif weapon_control.armed_can_target_self() and room >= 0:
		weapon_control.aim_at(player_space.ship, room, shift)  # bombs can target the own ship


func space_of(ship: ShipState) -> Space:
	return player_space if ship == player_space.ship else enemy_space


func _space_to_world(ship: ShipState, screen: Vector2) -> Vector2:
	var sp := space_of(ship)
	return sp.to_world(screen - sp.get_global_rect().position)


## Screen rect of a ship's view (empty while hidden in the one-at-a-time view).
func _space_rect(ship: ShipState) -> Rect2:
	var sp := space_of(ship)
	return sp.get_global_rect() if sp.is_visible_in_tree() else Rect2()


## World point of a ship -> screen (CLI pointer flags, tests).
func world_to_screen(ship: ShipState, w: Vector2) -> Vector2:
	var sp := space_of(ship)
	return sp.get_global_rect().position + sp.viewport.get_canvas_transform() * w


## CombatControl::WeaponsArmed: a weapon, the teleporter, hacking or mind control is armed.
func weapons_armed() -> bool:
	return weapon_control.armed >= 0 or combat.player_tp_armed != TeleporterRule.NONE \
		or player_space.ship.hack_armed or player_space.ship.mind_armed


## Right click: HackBox / MindBox disarmed (CombatControl::MouseRClick).
func _disarm_systems() -> void:
	player_space.ship.hack_armed = false
	player_space.ship.mind_armed = false


func _boxes_dragging() -> bool:
	return weapon_panel.dragging() or (drone_panel != null and drone_panel.dragging())


## Mouse and keys, before the GUI (CommandGui::LButtonDown/LButtonUp/RButtonDown/MouseMove/KeyDown;
## rules/crew_controls.md, rules/weapon_controls.md). The top bar and its menus are prototype-only.
func _input(event: InputEvent) -> void:
	if options != null and options.visible:
		return  # the Options screen (GUI) takes everything; it closes itself on Esc / F10
	if (pause_menu != null and pause_menu.visible) or (vanilla_options != null and vanilla_options.visible):
		return  # the Esc menu / FTL options window (GUI) take everything
	var fe: Variant = Hooks.filter(&"input_event", event, self)
	if Hooks.is_cancel(fe):
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F10:
		open_options()
		get_viewport().set_input_as_handled()
		return
	event = _hud_event(event)  # touch UI on a tall screen: viewport -> HUD layer coordinates
	if _pan_input(event):  # open-Fold "pan" layout: arrows / two-finger drag / Shift + wheel pan the ship scene
		get_viewport().set_input_as_handled()
		return
	if run != null:
		if _run_input(event):
			get_viewport().set_input_as_handled()
			return
		if run.modal() and (event is InputEventMouse or event is InputEventScreenTouch
				or event is InputEventScreenDrag):
			return  # the beacon map / event box (GUI) gets the mouse; nothing reaches the ship
	if event is InputEventKey and event.pressed and not event.echo:
		if _hotkey(event as InputEventKey):
			get_viewport().set_input_as_handled()
		return
	if _touch() and _touch_gesture_input(event):
		return
	if not event is InputEventMouse:
		return
	var pos: Vector2 = event.position
	if event is InputEventMouseMotion:
		if pointer_locked:
			return
		crew_control.frozen = _boxes_dragging()
		crew_control.pointer_moved(pos, weapons_armed())
		return
	var mb := event as InputEventMouseButton
	if _over_debug(pos):
		return
	if _touch() and _touch_buttons_input(mb):
		return
	if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed and command_hud.menu_rect().has_point(command_hud.hud_point(pos)):
		open_menu()  # MENU wrench: FTL's Esc menu
		get_viewport().set_input_as_handled()
		return
	if mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			# Touch: one finger hovers, its lift is the click; no drag box (TouchGestures).
			var hit := _gestures().finger_press(pos) if _touch() \
				else crew_control.left_press(pos, mb.shift_pressed, weapons_armed())
			if hit:
				get_viewport().set_input_as_handled()
		elif _touch():
			_gestures().finger_release(pos)
		else:
			crew_control.left_release(pos, mb.shift_pressed)
	elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
		# CombatControl::MouseRClick first: disarm everything (a hovered weapon / drone box still gets its
		# right click = depower). If something was armed, crew and system right clicks are skipped.
		var was_armed := weapons_armed()
		weapon_control.disarm()
		combat.player_tp_armed = TeleporterRule.NONE
		_disarm_systems()
		if was_armed:
			if get_viewport().gui_get_hovered_control() is SystemPowerColumn:
				get_viewport().set_input_as_handled()
		else:
			crew_control.right_press(pos)


# ------------------------------------------------------------------ touch gestures (combat)
# rules/ui_layout_strategy.md "Touch gestures (combat)": tap = click; a tap that selects crew or arms a weapon /
# system starts the selection mode (auto-pause + CANCEL), the next tap on a target performs the action and ends it;
# PAUSE toggles the player's pause. Tap rules: TouchGestures; buttons: TouchCombatButtons; this is the glue.

var _touch_gestures: TouchGestures
var touch_buttons: TouchCombatButtons  # PAUSE / CANCEL (touch combat; created by _touch_selection_tick)
var touch_power: TouchPowerToggle  # power mode + / − (touch combat; created by _touch_layout under the crew box)
var _power_pressed := false  # a finger pressed the power toggle: its lift is consumed too
var touch_selecting := false  # selection mode active (as of the last tick)
var _select_paused := false  # the selection mode paused the game: it unpauses when the mode ends


## Touch input profile (the run's profile, or --input=touch / --device= in the sandbox).
func _touch() -> bool:
	return profile.is_touch() if profile != null else input_mode == InputProfile.TOUCH


## The combat tap tracker for the current CrewControl (recreated after a rebuild).
func _gestures() -> TouchGestures:
	if _touch_gestures == null or _touch_gestures.crew != crew_control:
		_touch_gestures = TouchGestures.new(crew_control, weapons_armed, _touch_disarm, _touch_over_hud,
			func() -> bool: return weapon_control.beam_ship != null)
		_touch_gestures.can_box = _touch_box_start
	return _touch_gestures


## Held finger (or Ctrl) + drag = crew drag box (TouchGestures): may start anywhere except on a control that acts
## on a tap (`_touch_interactive_at`; those keep their own behaviour), so odd ship layouts can be boxed from the HUD
## margins (reactor, subsystems box, ship status ...).
func _touch_box_start(p: Vector2) -> bool:
	return not _touch_interactive_at(p)


## A control that acts on a tap is under the screen point (touch UI): PAUSE / CANCEL, + / −, crew boxes / LOCKDOWN
## / stations buttons, the top buttons (FTL JUMP, SHIP, STORE, MENU), system power columns and system buttons
## (doors: its two buttons), weapon / drone boxes, their power rows, AUTOFIRE, and the enemy ship view (targeting).
## Tooltip-only art is not (reactor, ship status, labels, frames, pull-out icons, enemy window frame / status),
## nor is the player ship view or space. Each piece answers in its own coordinates.
func _touch_interactive_at(p: Vector2) -> bool:
	if touch_buttons != null and touch_buttons.button_at(p) != "":
		return true
	if touch_power != null and touch_power.visible and touch_power.button_at(p) != "":
		return true
	if crew_control.box_at(p) >= 0 or crew_control.button_at(p) >= 0 or crew_control.power_button_at(p) >= 0:
		return true
	if command_hud.is_visible_in_tree():
		var m := command_hud.hud_point(p)
		if Rect2(HudLayout.FTL_BASE, Vector2(98, 55)).has_point(m) or HudLayout.SHIP_HIT.has_point(m) \
				or command_hud.menu_rect().has_point(m) or (command_hud.store_shown() and CommandHud.STORE_HIT.has_point(m)):
			return true
	for col: SystemPowerColumn in systems_bar.columns.values():
		if col.is_visible_in_tree() and col.hit_rect().has_point(col.get_global_transform().affine_inverse() * p):
			return true
	for b: SystemButton in systems_bar.buttons.values():
		var bl := b.get_global_transform().affine_inverse() * p
		if b.is_visible_in_tree() and Rect2(Vector2.ZERO, b.size).has_point(bl) and b._half_at(bl) >= 0:
			return true
	for panel: Control in [weapon_panel, drone_panel]:
		if panel == null or not is_instance_valid(panel) or not panel.is_visible_in_tree():
			continue
		for box: Control in panel.boxes:
			if box.is_visible_in_tree() and Rect2(Vector2.ZERO, box.size).has_point(
					box.get_global_transform().affine_inverse() * p):
				return true
		if not panel.vertical:
			if panel.hud_hit(p):
				return true  # PC-style bottom panel (touch single view): the whole panel
			continue
		var rects: Array[Rect2] = [Rect2(Vector2(panel.v_row) if panel is WeaponPanel else Vector2.ZERO,
			Vector2(panel.v_row_w, WeaponPanel.V_ROW_H))]
		if panel is WeaponPanel:
			rects.append((panel as WeaponPanel).v_autofire_rect())
		if WeaponPanel.panel_hit(panel, p, rects):
			return true
	return enemy_space.is_visible_in_tree() and enemy_space.get_global_rect().has_point(p)


## Touch mode: extra fingers are ignored (consumed) and non-left mouse buttons reach only the GUI (no crew order,
## no disarm). Returns true when the event was dealt with here (the rest of `_input` is skipped).
func _touch_gesture_input(event: InputEvent) -> bool:
	if crew_control == null:
		return false
	if event is InputEventMouseButton and _over_debug(event.position):
		return false
	# The held finger was cancelled by a second finger's − tap: its own emulated left release does nothing.
	if _held_cancelled and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT \
			and not event.pressed and not _minus_dispatching:
		_held_cancelled = false
		get_viewport().set_input_as_handled()
		return true
	match _gestures().handle(event):
		TouchGestures.CONSUME:
			get_viewport().set_input_as_handled()
		TouchGestures.GUI:
			pass  # e.g. a desktop right click on a weapon / drone box (depower) or a system column (−1)
		TouchGestures.HOLD_CANCEL:
			_touch_hold_cancel()
			get_viewport().set_input_as_handled()
		TouchGestures.MINUS_TAP:
			_touch_minus_tap.call_deferred((event as InputEventScreenTouch).position)
			get_viewport().set_input_as_handled()
		_:
			return false
	return true


var _held_cancelled := false  # the held finger's tap was cancelled: swallow its lift
var _minus_dispatching := false  # _touch_minus_tap is pushing its synthetic tap


## A second finger landed while the first one rests (TouchGestures `held_minus`): the held finger can no longer
## click. Its pending clicks are dropped (crew tap, weapon / drone box, power rows, system columns) and a synthetic
## release frees the GUI's mouse focus so the second finger's tap reaches what is under it; its real lift is swallowed.
func _touch_hold_cancel() -> void:
	_gestures().tap_pending = false
	for p in [weapon_panel, drone_panel]:
		if p != null and is_instance_valid(p):
			p.drag.cancel()
			if p.power_hit != null:
				p.power_hit.cancel_press()
	for c in systems_bar.columns.values():
		c.cancel_press()
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and not _gestures().hold_down:
		return
	_held_cancelled = true
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = false
	e.position = _view_point(_gestures().hold_pos)  # pushed events are in viewport coordinates
	e.global_position = e.position
	_minus_dispatching = true
	get_viewport().push_input(e, true)
	_minus_dispatching = false


## The second finger's lift: a normal tap at `p` with − forced (TouchPowerToggle.forced), as the emulated mouse
## would send it (motion with the button held, press, release).
func _touch_minus_tap(p: Vector2) -> void:
	p = _view_point(p)  # HUD layer -> viewport coordinates (pushed events)
	TouchPowerToggle.forced = true
	_minus_dispatching = true
	var m := InputEventMouseMotion.new()
	m.position = p
	m.global_position = p
	m.button_mask = MOUSE_BUTTON_MASK_LEFT
	get_viewport().push_input(m, true)
	for down in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = down
		e.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		e.position = p
		e.global_position = p
		get_viewport().push_input(e, true)
	_minus_dispatching = false
	TouchPowerToggle.forced = false


func _exit_tree() -> void:
	FtlData.set_loop("airLeak", false)  # leaving combat mid-vent must not leave the loop running
	FtlData.set_loop("cloneBroken", false)
	FtlData.set_loop("nebula", false)
	ShipSounds.stop_loops()  # crew / fire / brawling / distress loops
	FtlData.pause_loops(false)
	TooltipService.offset = Vector2.ZERO  # the touch HUD's tall-screen centring (_touch_center_band) ends here


## CombatControl::MouseRClick's disarm part: weapons, teleporter, hacking, mind control.
func _touch_disarm() -> void:
	weapon_control.disarm()
	combat.player_tp_armed = TeleporterRule.NONE
	_disarm_systems()


## A HUD control (not a ship view) is under the point: the PAUSE / CANCEL buttons, or the GUI's hovered control
## (set by the finger's motion) when it is not a Space.
func _touch_over_hud(p: Vector2) -> bool:
	if touch_buttons != null and touch_buttons.button_at(p) != "":
		return true
	var c := get_viewport().gui_get_hovered_control()
	return c != null and not c is Space


## Selection mode: crew selected, or a weapon / teleporter / hacking / mind control armed (or a beam half aimed).
func _touch_selection_wanted() -> bool:
	return weapons_armed() or weapon_control.beam_ship != null or not crew_control.selected_crew().is_empty()


## Per frame (touch only): keeps arming and crew selection exclusive (arming wins), enters / leaves the selection
## mode (auto-pause unless already paused; unpause on leaving only if the mode paused it) and places the buttons.
func _touch_selection_tick() -> void:
	if not _touch() or crew_control == null or weapon_control == null or hud_root == null:
		return
	if touch_buttons == null:
		touch_buttons = TouchCombatButtons.new()
		hud_root.add_child(touch_buttons)
		hud_root.move_child(touch_buttons, pause_overlay.get_index() + 1)
	if weapons_armed() and not crew_control.selected_crew().is_empty():
		crew_control.deselect_all()  # one pending action at a time: arming replaces the crew selection
	var modal := run != null and (run.modal() or run.mgmt.open)
	var on := _touch_selection_wanted() and not modal
	if on and not touch_selecting:
		if not combat.paused:
			combat.paused = true
			_select_paused = true
	elif not on and touch_selecting:
		_end_select_pause()
	touch_selecting = on
	touch_buttons.visible = not modal and not single_view and command_hud.visible
	touch_buttons.cancel_shown = on
	touch_buttons.paused = combat.paused
	if touch_power != null:
		touch_power.visible = touch_buttons.visible and (crew_list.touch_button_box != null
			or not crew_list.touch_station_rects.is_empty())  # placed by _touch_layout
	var t := command_hud.scale.x
	# A pair rect taller than one base = the split layout's stacked pair (PAUSE at the bottom, CANCEL above).
	touch_buttons.stacked = _touch_pause_at.size.y > TouchCombatButtons.BASE_SIZE.y * t + 1.0
	if _touch_pause_at.has_area():  # _touch_layout found it a free spot: CANCEL is the pair's right base
		touch_buttons.place(_touch_pause_at.end.x - TouchCombatButtons.BASE_SIZE.x * t, _touch_pause_at.end.y, t)
	else:
		touch_buttons.place(command_hud.position.x + HudLayout.FTL_BASE.x * t, _touch_height(), t)


## The selection mode ended: undo its auto-pause. A box / menu opened meanwhile takes the pause over (it unpauses
## when it closes).
func _end_select_pause() -> void:
	if _select_paused and combat.paused:
		if run != null and run.modal():
			_modal_paused = true
		elif pause_menu != null and pause_menu.visible:
			_menu_paused = true
		elif options != null and options.visible:
			_options_paused = true
		else:
			combat.paused = false
	_select_paused = false


## CANCEL: drop the crew selection and every armed system; the mode ends (unpauses if it paused).
func touch_cancel() -> void:
	_touch_disarm()
	crew_control.deselect_all()
	_gestures().tap_pending = false
	_touch_selection_tick()


## PAUSE: the player's pause toggle (_toggle_pause also takes the pause away from the selection mode).
func touch_pause() -> void:
	_toggle_pause()
	_touch_selection_tick()


## Left press / release on PAUSE / CANCEL (acts on the press, like the JUMP button). Returns true when consumed.
func _touch_buttons_input(mb: InputEventMouseButton) -> bool:
	if touch_buttons == null or mb.button_index != MOUSE_BUTTON_LEFT:
		return false
	# One tap reaches ONE button: PAUSE / CANCEL (drawn on top) win over the power toggle.
	if not mb.pressed:
		var was: String = touch_buttons.pressed_button
		touch_buttons.pressed_button = ""
		if was != "":
			_power_pressed = false
			get_viewport().set_input_as_handled()
			return true
		return _touch_power_input(mb)
	var b: String = touch_buttons.button_at(mb.position)
	if b == "":
		return _touch_power_input(mb)
	touch_buttons.pressed_button = b
	_gestures().tap_pending = false
	if b == "pause":
		touch_pause()
	else:
		touch_cancel()
	get_viewport().set_input_as_handled()
	return true


## Left press / release on the power mode toggle (+ / −; acts on the press). Returns true when consumed.
func _touch_power_input(mb: InputEventMouseButton) -> bool:
	if touch_power == null:
		return false
	if not mb.pressed:
		if _power_pressed:
			_power_pressed = false
			get_viewport().set_input_as_handled()
			return true
		return false
	var b := touch_power.button_at(mb.position)
	if b == "":
		return false
	_power_pressed = true
	_gestures().tap_pending = false
	touch_power.press(b)
	get_viewport().set_input_as_handled()
	return true


## Touch power mode: true while the − (remove power) button is lit.
func touch_power_minus() -> bool:
	return touch_power != null and touch_power.minus


## Hotkeys: 1-4 weapons (Shift = depower), 5-7 drones (Shift = depower), V autofire, Space pause,
## F1-F8 / Q / '/' / Enter crew (CrewControl.hotkey).
func _hotkey(k: InputEventKey) -> bool:
	if k.unicode == 47:  # '/' (Shift+7 on some layouts): save stations
		return crew_control.hotkey(KEY_SLASH)
	match k.keycode:
		KEY_1, KEY_2, KEY_3, KEY_4:
			var i := k.keycode - KEY_1
			if k.shift_pressed:
				weapon_control.depower(i)
			else:
				combat.player_tp_armed = TeleporterRule.NONE  # arming by key disarms the teleporter
				weapon_control.select(i)
			return true
		KEY_5, KEY_6, KEY_7:
			if drone_panel:
				var i := k.keycode - KEY_5
				if k.shift_pressed:
					drone_panel.depower(i)
				else:
					drone_panel.toggle(i)
			return true
		KEY_V:
			if player_space.ship.weapon_slots != 2:
				weapon_control.toggle_autofire()
			return true
		KEY_Z, KEY_X:  # DoorBox::KeyDown: Settings hotkeys "open" (Z) / "close" (X), only while doors work
			var b: SystemButton = systems_bar.buttons.get("doors") if systems_bar else null
			if b != null:
				b.press(1 if k.keycode == KEY_Z else 0)
			return true
		KEY_SPACE:
			_toggle_pause()
			return true
		KEY_F12:
			toggle_debug()
			return true
		KEY_ESCAPE:
			open_menu()
			return true
	return crew_control.hotkey(k.keycode, k.shift_pressed)


## FTL button JUMP hit box (FTLButton, rules/hud_layout.md: (536, 35, 73, 30)).
const FTL_JUMP_HIT := Rect2(536, 35, 73, 30)


## Run-mode input before everything else: keys 1–9 on the event box, Esc closes the map, the FTL button opens
## it (through the InputProfile). Returns true when consumed.
func _run_input(event: InputEvent) -> bool:
	if event is InputEventKey and event.pressed and not event.echo:
		var k := (event as InputEventKey).keycode
		if k == KEY_F12:
			return false
		if k >= KEY_1 and k <= KEY_9 and event_box.visible:
			return event_box.key(k - KEY_1)
		if (k == KEY_1 or k == KEY_2) and run.choosing_sector:
			profile.sector_key(k - KEY_1)
			return true
		if (k == KEY_1 or k == KEY_2) and run.store_open:
			profile.store_page(k - KEY_1)
			return true
		if k == KEY_ESCAPE and run.map_open:
			profile.close_map()
			return true
		if k == KEY_ESCAPE and run.choosing_sector:
			profile.close_sector_map()
			return true
		if ship_screen != null and run.mgmt.open:
			return ship_screen.key(event as InputEventKey)
		if k in [KEY_U, KEY_C, KEY_I] and run.mgmt.can_open(run):  # ship_info / ship_crew / ship_inv [inferred keys]
			run.apply(ShipManagement.make(RunIntent.OPEN_SHIP_SCREEN, {"arg": [KEY_U, KEY_C, KEY_I].find(k)}))
			return true
		if (k == KEY_ESCAPE or k == KEY_X) and run.store_open:
			profile.store_close()
			return true
		if run.leave_crew_open:  # the confirm window takes the keys (Esc = NO)
			if k == KEY_ESCAPE:
				run.apply(RunIntent.make(RunIntent.LEAVE_CREW_CONFIRM, 0))
			return true
		if k == KEY_J and not run.modal():  # CommandGui::KeyDown: Settings hotkey "jump" (default 'j', ResetHotkeys)
			profile.ftl_button()
			return true
		return run.modal()  # no ship hotkeys under a box / the map
	var mb := event as InputEventMouseButton
	if run.leave_crew_open and leave_crew_dialog != null:  # ConfirmWindow::MouseClick: every click goes to it
		if mb and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			var ans := leave_crew_dialog.click(leave_crew_dialog.get_global_transform().affine_inverse() * mb.position)
			if ans >= 0:
				run.apply(RunIntent.make(RunIntent.LEAVE_CREW_CONFIRM, ans))
		return event is InputEventMouseButton or event is InputEventScreenTouch
	if mb and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and not run.modal() \
			and FTL_JUMP_HIT.has_point(command_hud.hud_point(mb.position)) and not _over_debug(mb.position):
		profile.ftl_button()
		return true
	if mb and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and not run.modal() 			and HudLayout.SHIP_HIT.has_point(command_hud.hud_point(mb.position)) and run.mgmt.can_open(run):
		run.apply(ShipManagement.make(RunIntent.OPEN_SHIP_SCREEN, {"arg": 0}))  # SHIP button
		return true
	if mb and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and not run.modal() and run.in_danger() \
			and HudLayout.SHIP_HIT.has_point(command_hud.hud_point(mb.position)):
		command_hud.danger_warning.start()  # CommandGui::LButtonDown: inactive SHIP button -> "IN DANGER" (2 s)
		return true
	if mb and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and not run.modal() \
			and command_hud.store_shown() and CommandHud.STORE_HIT.has_point(command_hud.hud_point(mb.position)):
		profile.store_open()
		return true
	return false


## Jump animation (ShipManager::JumpLeave / JumpArrive, CommandGui::RenderStatic; rules/starmap.md "Jump
## animation") [exe]: jumpAnimation is a 2 s tracker; k = min(1, 4·progress) (4·p ≤ 1, else 1); the player ship
## is drawn scaled 1 − 0.75·k about its centre (full shrink in 0.5 s, then held). Leave: progress 0 → 1 with the
## `jumpLeave` sound, then the new location is built (JumpArrive, `jumpArrive` sound) and the tracker runs in
## reverse (1 → 0: the ship stays small 1.5 s and grows back in the last 0.5 s). The asteroid field is scaled
## (1 − 0.3k) about the same centre and its nearest layer is drawn again over the ship (AsteroidLayers); the
## foreground (planet / sun, × (1 − 0.05k)) is not drawn by the prototype. CombatControl::OnRenderCombat is skipped
## while bJumping: the enemy window, the enemy ship and the aiming marks are hidden for the whole animation.
## While the tracker runs the ship is drawn by Ship::OnRenderJump (hull + thrusters fading out, glowing_star glare;
## ShipView.set_jump_frame). Arrival order: the new location's event box is already open (menu_pause: world paused,
## PAUSED shown) but focus windows are not rendered while the ship is jumping (bJumping, cleared when the reverse
## run ends) — so the ship arrives first and the box appears 2 s after JumpArrive (rules/starmap.md).
func _jump_step(delta: float) -> void:
	_jump_t += delta
	focus_dim.visible = false  # no focus window is drawn while jumping
	var p := clampf(_jump_t / 2.0, 0.0, 1.0)
	if _jump_phase == "arrive":
		p = 1.0 - p
		event_box.hold = true
		if run.modal() and not combat.paused:
			combat.paused = true
			_modal_paused = true
		pause_overlay.visible = run.modal()  # CommandGui::RenderPause: menu_pause from the (hidden) open box
	else:
		pause_overlay.visible = false
	var k := minf(1.0, 4.0 * p)
	if player_space != null:
		var c := player_space.size / 2.0
		if player_space.view != null and player_space.view.hull_tex != null:
			c = world_to_screen(player_space.ship, player_space.view.position + player_space.view.hull_tex.get_size()
				/ 2.0) - player_space.get_global_rect().position
		player_space.pivot_offset = c
		player_space.scale = Vector2.ONE * (1.0 - 0.75 * k)
		if player_space.view != null:
			player_space.view.set_jump_frame(p * 2.0)  # tracker time: forward on leave, 2 → 0 on arrival
		if asteroid_layers != null:
			asteroid_layers.jump_k = k
			asteroid_layers.jump_center = player_space.position + c
			asteroid_layers.jump_unpaused = _jump_phase == "leave"  # the map closed: the space runs on
	_set_combat_ui_jumping(true)
	if hazard_hud != null:
		hazard_hud.hold = _jump_phase == "leave"  # keep the old space's hazard icon until JumpArrive
	if _jump_t < 2.0:
		return
	if _jump_phase == "leave":
		_rebuild()
		FtlData.play("jumpArrive")
		_jump_phase = "arrive"
		_jump_t = 0.0
		_jump_step(0.0)
	else:
		_jump_phase = ""
		_map_was_open = false
		event_box.hold = false  # bJumping cleared: the event box is rendered from now on
		if player_space != null:
			player_space.scale = Vector2.ONE
			if player_space.view != null:
				player_space.view.set_jump_frame(-1.0)
		if asteroid_layers != null:
			asteroid_layers.jump_k = 0.0
			asteroid_layers.jump_unpaused = false
		if hazard_hud != null:
			hazard_hud.hold = false
		_set_combat_ui_jumping(false)


## CommandGui::RenderStatic renders CombatControl (the target window with the enemy ship) only while the player
## ship is not jumping. `on` hides it; off restores the normal visibility (_apply_view).
func _set_combat_ui_jumping(on: bool) -> void:
	if enemy_space == null or enemy_window == null or enemy_window_back == null:
		return
	if on:
		enemy_space.visible = false
		enemy_window.visible = false
		enemy_window_back.visible = false
	else:
		_apply_view()


## Which sector the run is in (tree sector, level, secret sector): differs from `_built_sector` after a sector jump.
func _sector_key() -> String:
	return "%d|%d|%s" % [run.sector_id, run.sector, run.secret_sector] if run != null else ""


## Run mode, every frame: rebuild the scene after an arrival / a new event ship, pause under the map and the
## event box, [placeholder] FTL charge, the event ship's hostility, the combat outcome (surrender, dead crew,
## destroyed -> reward event).
func _run_process(delta: float) -> bool:
	if _jump_phase != "":
		_jump_step(delta)
		return false
	# Waiting (out of fuel / last stand) "arrives" at the same beacon without leaving it (CommandGui::OnLoop:
	# GetWaitLocation -> ShipManager::Wait, no JumpLeave): no jump animation / sounds, the location is just rebuilt.
	if run.arrival_serial != _built_arrival and run.arrival_serial != run.wait_arrival_serial \
			and (_map_was_open or _sector_key() != _built_sector) and player_space != null:
		# A jump picked on the beacon map, or a sector jump (sector map choice: StarMap::OnLoop readyToTravel with
		# potentialLoc = dummyNewSector; the secret sector event: CommandGui::OnLoop secretSector -> dummyNewSector):
		# CommandGui::OnLoop runs ShipManager::JumpLeave for every new location alike, before it is built.
		_jump_phase = "leave"
		_jump_t = 0.0
		FtlData.play("jumpLeave")
		event_box.hold = true
		return false
	if run.arrival_serial != _built_arrival or run.enemy_serial != _built_enemy:
		_rebuild()
		return false
	_map_was_open = run.map_open
	if run.modal():
		if not combat.paused:
			combat.paused = true
			_modal_paused = true
	elif _modal_paused:
		combat.paused = false
		_modal_paused = false
	# CommandGui::RenderPause: an open focus window sets menu_pause, which shows PAUSED too (under the box).
	pause_overlay.visible = true
	focus_dim.visible = run.mgmt.open or run.map_open or run.choosing_sector or run.leave_crew_open
	leave_crew_dialog.visible = run.leave_crew_open
	var seconds := 0.0 if combat.paused else GameClock.factor(delta, combat.speed_level) / GameClock.BASE
	if not combat.paused:
		run.tick(seconds)
		if run.hazard != null:
			# AsteroidGenerator numberOfShips: the ships that arrived (a destroyed / fled enemy stays counted,
			# its asteroids are discarded).
			var hz_ships: Array = [player_space.ship]
			if has_enemy:
				hz_ships.append(null if victory_shown or bool(run.enemy.get("escaped", false)) else enemy_space.ship)
			run.hazard.tick(seconds, hz_ships, combat)
	if has_enemy and combat.ais.has(enemy_space):
		combat.ais[enemy_space].hostile = bool(run.enemy.get("hostile", false))
		# ShipAI::escaping / escapeTimer live in the run (RunState.check_combat); the AI reads them for its power
		# priorities (CheckPowerLevels: no weapons / drones while escaping) and RequiredEvac (< 15 s left).
		combat.ais[enemy_space].escaping = bool(run.enemy.get("escaping", false))
		combat.ais[enemy_space].escape_timer = float(run.enemy.get("escape_timer", 15.0))
		var outcome := run.check_combat(enemy_space.ship, seconds)
		if outcome != "":
			print("combat outcome: %s, rewards %s" % [outcome, str(run.dialog_rewards)])
		if bool(run.enemy.get("escaped", false)) and not victory_shown:
			# JumpLeave: 2 s fade + glare (ShipView._draw_jump). One clock: the jumpAnimation advances in
			# ShipManager::OnLoop (game time, frozen while paused), the same RunState.enemy.jump_left that opens the
			# gotaway event, so the ship can't vanish while the game is paused and the event still pending.
			var left := float(run.enemy.get("jump_left", 0.0))
			if enemy_space.view.jump_time < 0.0:
				enemy_space.view.start_jump()
			enemy_space.view.set_jump_frame(clampf(ShipView.JUMP_TIME - left, 0.0, ShipView.JUMP_TIME))
			if left <= 0.0:
				_enemy_escaped()
	return true


## The enemy jumped away (ShipAI::Escaped -> WorldManager: gotaway event, SetTarget(null), the location's ship
## no longer present): like a destroyed enemy (`_check_end`), its ship and TARGET window leave and the layout
## goes back to the no-enemy state (`victory_shown` = "the enemy is gone": player origin x 350, touch layout
## without the TARGET column, `_apply_view` keeps it hidden, hazards / music / combat hooks see no enemy).
func _enemy_escaped() -> void:
	victory_shown = true
	enemy_space.visible = false
	enemy_window.visible = false
	enemy_window_back.visible = false
	enemy_space.ship.jumping = true
	for w in player_space.ship.weapons:
		w.clear_target()
	weapon_control.disarm()  # nothing left to aim at (touch: ends the targeting selection mode)
	if not single_view:
		if input_mode == InputProfile.TOUCH:
			_touch_layout()
		else:
			player_space.set_fixed_origin(player_origin())
	print("ENEMY ESCAPED: %s" % enemy_space.ship.blueprint.name)


## Run mode: rebuild the scene in place for the new location (ClearLocation + CreateLocation): every child
## (spaces, combat, HUD, debug overlay) is replaced; the run, the player ShipState and running CLI timers stay.
func _rebuild() -> void:
	if _combat_live:
		_combat_live = false
		Hooks.emit(&"combat_ended", player_space.ship, enemy_space.ship, "left")
	for c in get_children():
		remove_child(c)
		c.queue_free()
	victory_shown = false
	game_over_shown = false
	drone_panel = null
	# Lazily created HUD nodes (touch layouts): the old ones are only queued for deletion, so `== null` would still
	# be false while _build lays out the new HUD — the layout would reuse the doomed node and the piece vanish at the
	# end of the frame (the + / − power toggle was missing at every location reached in run mode until the next
	# relayout).
	touch_power = null
	touch_buttons = null
	pan_arrows = null
	_ppan_backing = null
	screen_shake = null
	_modal_paused = false
	_build()
	_apply_view()


func _process(delta: float) -> void:
	# Tooltips (TooltipService): the combat HUD is inert under full-focus windows and menus.
	TooltipService.hud_blocked = (run != null and run.modal()) or (pause_menu != null and pause_menu.visible) 		or (options != null and options.visible) or (vanilla_options != null and vanilla_options.visible)
	# Sandbox (no profile): --input=touch / --device still give the touch tooltips and finger-only hover.
	TooltipService.touch = profile.is_touch() if profile != null else input_mode == InputProfile.TOUCH
	if run != null:
		TooltipText.ae = run.engine.ae
	_check_music()
	# distress (StarMap::OnLoop / Close, scripts/audio/ship_sounds.gd): every frame, also through jump / rebuild
	# frames, so closing the map stops it at once.
	FtlData.update_sound_loop("distress", ShipSounds.distress_count(run))
	if run != null and not _run_process(delta):
		return
	_check_end()
	_touch_layout_tick()
	_touch_selection_tick()  # touch: selection mode auto-pause, PAUSE / CANCEL buttons
	_update_combat_hooks()
	btn_pause.text = "Resume" if combat.paused else "Pause"
	crew_control.tick(delta)
	player_space.view.hovered_door = crew_control.hovered_door  # door_highlight under the hovered door
	var hl := crew_control.move_highlight() if not weapons_armed() else []
	player_space.move_highlight_room = hl[1] if not hl.is_empty() and hl[0] == player_space.ship else -1
	enemy_space.move_highlight_room = hl[1] if not hl.is_empty() and hl[0] == enemy_space.ship else -1
	# Crosshairs on the enemy ship, and highlight of the room under the cursor if a weapon is armed.
	var marks := []
	var own_marks := []
	for i in player_space.ship.weapons.size():
		var w := player_space.ship.weapons[i]
		if not w.has_target():
			continue
		var m := {"room": w.target_room, "label": str(i + 1), "slot": i, "auto": w.autofire,
			"point": w.target_point, "radius": int(w.bp.get("radius", 0))}
		if w.is_beam():
			m["beam"] = [w.target_point, w.target_point2]
		if w.target_ship == enemy_space.ship:
			marks.append(m)
		elif w.target_ship == player_space.ship:
			own_marks.append(m)
	enemy_space.aim_marks = marks
	player_space.aim_marks = own_marks
	var me := player_space.ship
	# CombatControl::UpdateAiming: no aiming (room highlight / target) on a ship that is not hostile, except the
	# armed teleporter (UpdateTarget highlights its room with no hostile check: retrieving from a neutral ship).
	enemy_space.highlight_hover = combat.player_tp_armed != TeleporterRule.NONE or (enemy_space.ship.hostile \
		and (weapon_control.armed >= 0 or me.hack_armed or me.mind_armed))
	player_space.highlight_hover = weapon_control.armed_can_target_self() or me.mind_armed
	# Sensors under a hack pulse count as unpowered: no view of the enemy's power (CheckVision).
	# CombatControl::RenderTarget: bShowPower = DoSensorsProvide(3) (effective sensors > 3, i.e. level 3 manned
	# or level 4) and the target not cloaked.
	enemy_space.show_power = me.sensors_provide(3) and not enemy_space.ship.is_cloaked()
	enemy_window.show_power = enemy_space.show_power
	enemy_window.touch = _touch()  # escape message inside the TARGET frame in the touch layout
	# hackLoop: while the player's own pulse runs or any of its systems is under a pulse. Like every sound loop it is
	# silent while the game is paused (CApp::OnLoop -> SoundControl::OnLoop(IsPaused) -> PauseLoops; rules/pause.md).
	FtlData.set_loop("hackLoop", (HackingRule.pulsing(me) or HackingRule.any_hacked(me)) and not combat.paused)
	# airLeak (OxygenSystem::OnLoop, player ship only): while a breach / open airlock drains a room above 1 %.
	FtlData.set_loop("airLeak", me.env.leaking_o2 and not combat.paused and not me.is_destroyed(), 0.5)
	# cloneBroken (CloneSystem::OnLoop, player ship only): while the clone death timer runs (queue waiting, clone
	# power 0, no BACKUP_DNA); UpdateSoundLoop(0) fades it out over 500 ms.
	FtlData.set_loop("cloneBroken", ClonebayRule.dying(me) and not combat.paused and not me.is_destroyed(), 0.5)
	# nebula (SpaceManager::OnLoop: UpdateSoundLoop("nebula", bNebula && !lowend ? 1 : 0)): the ambient loop of a
	# nebula / ion storm beacon (silent while paused like every loop; rules/hazards.md §5).
	FtlData.set_loop("nebula", run != null and run.hazard != null and run.hazard.has_env(HazardRule.Env.NEBULA)
		and not combat.paused, 0.5)
	# Count-driven loops (scripts/audio/ship_sounds.gd): extinguish / healing / repair / shrikeRepair
	# (ShipManager::UpdateCrewmembers), fire (Spreader<Fire>::UpdateSpread), brawling (CrewMemberFactory::OnLoop),
	# PauseLoops pauses them (all loops but distress) while paused.
	ShipSounds.update_loops(me, combat.spaces.map(func(s): return s.ship), combat.paused)
	# Beam being aimed: start point and the fixed-length line toward the pointer.
	var preview := []
	if weapon_control.beam_ship == enemy_space.ship:
		preview.append(weapon_control.beam_start)
		var end: Variant = weapon_control.beam_end_for(
			debug_pointer if debug_pointer != null else enemy_space.mouse_world)
		if end != null:
			preview.append(end)
		enemy_space.beam_preview_color = weapon_control.weapon(weapon_control.armed).bp.color
		enemy_space.beam_preview_auto = player_space.ship.autofire != Input.is_key_pressed(KEY_SHIFT)
	enemy_space.beam_preview = preview
	# Flak armed: translucent red disc of its radius on the hovered room centre (CombatControl::RenderTarget).
	var armed_w: WeaponState = weapon_control.weapon(weapon_control.armed) if weapon_control.armed >= 0 else null
	enemy_space.hover_radius = int(armed_w.bp.get("radius", 0)) if armed_w and not armed_w.is_beam() else 0
	_combat_tooltips()


## CombatControl tooltips (rules/tooltips.md §4.1–4.2): crew under the cursor (own ship, then enemy; blacked-out
## rooms give nothing), space drones, hacking / mind-control aim (instant). Box lower by 10 px while aiming.
func _combat_tooltips() -> void:
	var me := player_space.ship
	TooltipService.aim_shift = me.hack_armed or me.mind_armed
	if TooltipService.hud_blocked or _boxes_dragging():
		return
	var p := TooltipService.pointer()
	if _over_hud_panel(p):
		return
	# Space drones (SpaceManager::GetSelectedDrone): within 20 px of the drone [inferred radius].
	for d: Drone in combat.space_drones():
		var sp_ship: ShipState = d.space_ship
		if sp_ship == null or not space_of(sp_ship).is_visible_in_tree() or not _space_rect(sp_ship).has_point(p):
			continue
		if _space_to_world(sp_ship, p).distance_to(d.pos) <= 20.0:
			var tip := TooltipText.space_drone(d, d.owner == me)
			if tip != "":
				TooltipService.request(tip, {"kind": &"space_drone", "source": self, "ctx": {"drone": d}})
	# Crew in rooms: own ship first, then the enemy (CombatControl::GetCrewTooltip); the later one wins.
	for s: ShipState in [me, enemy_space.ship]:
		if s == null or not _space_rect(s).has_point(p) or (s != me and not has_enemy):
			continue
		var w := _space_to_world(s, p)
		var dark := s.blacked_out_rooms()
		var list := []
		for c: CrewMember in s.crew:
			var alive := c.is_alive() or c.dead_time < CrewMember.DEATH_ANIM
			var d := c.pos - w
			if alive and absf(d.x) <= CrewControl.CREW_HALF and absf(d.y) <= CrewControl.CREW_HALF 					and not dark.has(c.room):
				list.append(c)
		if not list.is_empty():
			TooltipService.request(TooltipText.crew_room(list, {"ship": s}), {"kind": &"crew_room", "source": self,
				"ctx": {"crew": list, "ship": s}})
	# Aiming (instant): hacking -> hack_potential; mind control blocked by blackout / super shield.
	var e := enemy_space.ship
	if me.hack_armed and e != null and _space_rect(e).has_point(p):
		var r := e.room_at(_space_to_world(e, p))
		var sys := e.system_in_room(r) if r >= 0 else null
		if sys != null:
			TooltipService.request(TooltipText.f("hack_potential", TooltipText.t("hack_" + sys.id)),
				{"instant": true, "kind": &"aim_block", "source": self})
	if me.mind_armed:
		for s: ShipState in [me, e]:
			if s == null or not _space_rect(s).has_point(p):
				continue
			var r := s.room_at(_space_to_world(s, p))
			if r < 0:
				continue
			var tip := ""
			if MindRule.blocked_by_blackout(s, r):  # no life detection there (slug crew / LIFE_SCANNER)
				tip = "mind_blocked_blackout"
			elif s == e and e.super_shield > 0 and not me.has_augment("ZOLTAN_BYPASS"):
				tip = "mind_blocked_shield"
			if tip != "":
				TooltipService.request(TooltipText.simple("aim_block", tip), {"instant": true, "kind": &"aim_block",
					"source": self})


## The pointer is over a HUD panel (weapons / drones / systems / crew list / top bar): no ship tooltips there.
## Touch UI: the pieces as drawn (each through its own canvas transform), not the PC bottom strip, so the
## TARGET window's lower part (enemy crew, drones) keeps its tooltips.
func _over_hud_panel(p: Vector2) -> bool:
	if input_mode == InputProfile.TOUCH and not single_view:
		return _over_touch_hud(p)
	if crew_control.box_at(p) >= 0 or p.y < 140 and p.x < 520:
		return true
	return p.y > HudLayout.ARMAMENT_Y and p.x < 1240


## Each HUD piece answers in its own coordinates (`hud_hit`), so any later layout keeps this right.
func _over_touch_hud(p: Vector2) -> bool:
	if crew_control.hud_hit(p) or ship_status.hud_hit(p) or command_hud.hud_hit(p) or systems_bar.hud_hit(p):
		return true
	if touch_power != null and touch_power.button_at(p) != "":
		return true
	return weapon_panel.hud_hit(p) or (drone_panel != null and is_instance_valid(drone_panel)
		and drone_panel.hud_hit(p))


## combat_started / combat_ended (rules/hooks.md): a fight starts when a hostile, living enemy ship is present and
## no box / map is open (run mode: after the arrival dialog closes); it ends when the enemy is destroyed, escapes,
## stops being hostile, or the player ship is destroyed.
func _update_combat_hooks() -> void:
	var e := enemy_space.ship
	var me := player_space.ship
	var hostile: bool = combat.ais[enemy_space].hostile if combat.ais.has(enemy_space) else false
	var fighting := has_enemy and enemy_space.visible and hostile and not e.is_destroyed() and not me.is_destroyed() \
		and not e.jumping
	if not _combat_live and fighting and (run == null or not run.modal()):
		_combat_live = true
		Hooks.emit(&"combat_started", me, e, combat)
	elif _combat_live and not fighting:
		_combat_live = false
		var why := "peace"
		if me.is_destroyed():
			why = "player_destroyed"
		elif e.is_destroyed():
			why = "destroyed"
		elif e.jumping or not enemy_space.visible:
			why = "escaped"
		Hooks.emit(&"combat_ended", me, e, why)


## WorldManager::CheckMusic every frame, also while paused or under a box (rules/music.md §4): battle music
## while a hostile living enemy is here, the environment is dangerous, or the ship has intruders / mind-controlled
## enemies (MusicLogic.check_music).
func _check_music() -> void:
	if combat == null or player_space == null or enemy_space == null:
		return
	var e := enemy_space.ship
	var hostile: bool = combat.ais[enemy_space].hostile if combat.ais.has(enemy_space) else false
	var live := has_enemy and enemy_space.visible and e != null and hostile and not e.is_destroyed() \
		and not e.jumping
	Music.check_world(player_space.ship, live, run.hazard if run != null else null)


## CLI pointer flags (screenshots of hover / drag box / room outline without a real mouse).
func _cli_pointer(a: String) -> void:
	var v := a.split("=")[1]
	if a.begins_with("--hover-crew="):
		var i := int(v)
		if i < crew_control.roster.size():
			var c := crew_control.roster[i]
			var s := crew_control.ship_of(c)
			if s:
				crew_control.pointer_moved(world_to_screen(s, c.pos), weapons_armed())
	elif a.begins_with("--hover-room="):
		var p := v.split(":")
		var ship := enemy_space.ship if p[0] == "enemy" else player_space.ship
		var room := int(p[1])
		crew_control.pointer_moved(world_to_screen(ship, ship.room_rect(room).get_center() + Vector2(0, 8)),
			weapons_armed())
		space_of(ship).hovered_room = room
	elif a.begins_with("--pointer="):
		var p := v.split(",")
		crew_control.pointer_moved(Vector2(float(p[0]), float(p[1])), weapons_armed())
		TooltipService.debug_pointer = Vector2(float(p[0]), float(p[1]))  # tooltips in screenshots
	elif a.begins_with("--drag-box="):
		var p := v.split(",")
		crew_control.pointer_moved(Vector2(float(p[0]), float(p[1])), weapons_armed())
		crew_control.left_press(Vector2(float(p[0]), float(p[1])), false, weapons_armed())
		crew_control.pointer_moved(Vector2(float(p[2]), float(p[3])), weapons_armed())
	print("pointer %s: potential %s, selected %s, highlight %s" % [a, crew_control.potential.map(
		func(c): return crew_control.roster.find(c)), crew_control.selected_crew().map(
		func(c): return crew_control.roster.find(c)), crew_control.move_highlight().slice(1)])


## --equip-drag: press on box `kind:n` of the ship screen's equipment tab and keep the drag going.
func _debug_equip_drag(kind: String, n: int) -> void:
	if ship_screen == null or ship_screen.equip_view == null:
		print("equip drag: no ship screen")
		return
	var kinds := {"weapon": ShipInventory.WEAPON, "drone": ShipInventory.DRONE, "aug": ShipInventory.AUG,
		"cargo": ShipInventory.CARGO, "over": ShipInventory.OVER, "over_aug": ShipInventory.OVER_AUG}
	var ev := ship_screen.equip_view
	var b := Vector2i(int(kinds.get(kind, ShipInventory.WEAPON)), n)
	var c := ev.box_rect(b).get_center()
	ev.press(c)
	ev.motion(c + Vector2(20, 0))
	print("equip drag %s:%d: dragging %s" % [kind, n, ev.dragging()])


## Test: cycle 0 → 1 → 2 → 3 → 4 shield layers on the enemy ship.
func _cycle_enemy_shields() -> void:
	_set_enemy_shields((enemy_shield_layers + 1) % 5)


func _set_enemy_shields(n: int) -> void:
	enemy_shield_layers = n
	enemy_space.ship.set_shield_layers_max(n)
	btn_enemy_shields.text = "Enemy shields: %d" % n


func _toggle_pause() -> void:
	combat.paused = not combat.paused
	_select_paused = false  # the player's pause from now on (touch selection mode: no auto-unpause)
	btn_pause.text = "Resume" if combat.paused else "Pause"


func _toggle_view() -> void:
	single_view = not single_view
	_apply_view()


func _show_enemy(e: bool) -> void:
	showing_enemy = e
	_apply_view()


## Enemy ship view: the opaque interior of box_hostiles2.png (the frame is drawn under it).
const ENEMY_VIEW := Rect2(882, 54, 380, 529)
## Stencil of the enemy view (CombatControl::DrawHostileBox), drawn at HudLayout.ENEMY_FRAME.position: opaque
## frame px x 14..389, y 29..532 (screen 886..1261 × 74..577) with cut corners — narrower than ENEMY_VIEW.
const ENEMY_MASK := "img/combatUI/box_hostiles_mask.png"
## Debug "one at a time" view: the shown ship fitted between the top and bottom HUD rows.
const SINGLE_VIEW := Rect2(110, 150, 1170, 440)


## Screen point of the player ship's world origin: (350, 170) + layout shifts (CommandGui::LinkShip /
## ClearLocation); x 200 while a ship is at the beacon, 150 against a boss (CommandGui::AddEnemyShip; snaps,
## no slide). Back to 350 once the enemy is destroyed (a crew-killed derelict keeps it at 200).
func player_origin() -> Vector2:
	var lay: Dictionary = player_space.ship.layout
	var o := HudLayout.PLAYER_SHIP
	if has_enemy and not victory_shown and enemy_space != null and enemy_space.ship != null:
		var bp: String = enemy_space.ship.blueprint.get("name", "")
		o.x = HudLayout.PLAYER_SHIP_X_BOSS if bp.begins_with("BOSS_") else HudLayout.PLAYER_SHIP_X_ENEMY
	return o + Vector2(lay.get("horizontal", 0), lay.get("vertical", 0))


## Screen point of the enemy ship's world origin (CombatControl::AddEnemyShip: origin (747, 0) + target
## (308 − shipBox.w / 2 + 20, 45 + vertical_shift + 85); shipBox = the rooms' box).
func enemy_origin() -> Vector2:
	var e := enemy_space.ship
	var b := e.rooms_bounds()
	return HudLayout.COMBAT_ORIGIN + Vector2(HudLayout.ENEMY_TARGET_X - b.size.x / 2 - b.position.x,
		HudLayout.ENEMY_TARGET_Y + e.layout.get("vertical", 0))


# ------------------------------------------------------------------ touch UI: enlarged TARGET window
## The touch UI (input_mode TOUCH) scales the whole enemy TARGET window — frame, status, system boxes and the
## enemy space (ship, shots, crosshairs, beams, drones, asteroids) — into the free canvas right of the player
## ship (aspect "expand" widens the canvas on phones: ~1600 × 720). One uniform transform maps the PC frame
## coordinates (HudLayout.ENEMY_FRAME, ENEMY_VIEW, ENEMY_STATUS ...) to the canvas; the enemy space keeps its
## world coordinates and uses camera zoom, so every pointer path (room clicks, beam drag, teleporter / mind /
## hack targeting, crew and system tooltips) follows it through Space.to_world / the Controls' transforms.
## The right-hand HUD (subsystems bar, top buttons) is ignored for now (they will move) and draws on top.
## The player space is scaled the same way (camera zoom, `_touch_layout`), and the weapons panel becomes a
## vertical column between the ships (WeaponPanel `vertical`); the bottom weapon box is not shown.
## Scale quantum (weapons column, player ship): clean eighths (1, 1.125, 1.25 ...) so the nearest-filtered
## pixel art repeats rows / columns in a regular pattern. TARGET: TOUCH_ENEMY_SCALES, never below 1.
const TOUCH_ENEMY_STEP := 0.125


## Touch UI: frame coordinates (1280 × 720 PC frame) -> canvas, for the TARGET window: the frame art
## (TOUCH_ENEMY_ART, the opaque part of box_hostiles2.png) flush with the right canvas edge and as tall as the
## layout height allows, at the largest clean scale (TOUCH_ENEMY_SCALES: eighths and thirds — both repeat
## nearest-filtered rows / columns in a regular pattern), at most TOUCH_ENEMY_MAX_W of the canvas width (narrow
## canvases keep room for the weapons column and the player ship); centred vertically. Phone (~1600 × 720):
## ×4/3 -> art 517 × 716, y 2..718 (touches top and bottom within 2 px). The escape warning (frame y − 15) is
## above the canvas top then.
func touch_enemy_transform() -> Transform2D:
	var f := HudLayout.ENEMY_FRAME
	var art := TOUCH_ENEMY_ART
	var vis := get_viewport().get_visible_rect().size
	var h := _touch_height()
	var fit := minf(vis.x * TOUCH_ENEMY_MAX_W / art.size.x, h / art.size.y)
	var s := 1.0
	for c in TOUCH_ENEMY_SCALES:
		if c <= fit + 0.0001:
			s = maxf(s, c)
	# Tall canvas: the art's bottom on the canvas bottom (bottom-right corner); else centred vertically.
	var art_top := roundf(h - art.size.y * s) if _touch_tall() else roundf((h - art.size.y * s) / 2)
	var pos := Vector2(roundf(vis.x - art.end.x * s), art_top - art.position.y * s)
	return Transform2D(0.0, Vector2(s, s), 0.0, pos - f.position * s)


## Touch UI layout, computed from the visible canvas (recomputed on resize and when what it depends on changes,
## `_touch_layout_tick`): TARGET window from the right edge (touch_enemy_transform) -> the vertical weapons
## column (WeaponPanel `vertical`) flush against the frame art's left edge, top at TOUCH_COL_TOP -> the player
## ship scaled by the largest clean step (TOUCH_SHIP_SCALES) at which its hull image (opaque pixels, row by row)
## fits between the left canvas edge (engines) and the weapons column (nose; rows below the column may reach on
## to the TARGET art) while its ROOMS stay clear of the HUD and the column (_touch_fit_ship); the hull art may
## overlap the HUD and the shield ellipse is ignored. No enemy: the column goes to the canvas edge. The column scale is the largest of
## TOUCH_WEAPON_SCALES that fits the height and leaves a ship that fits at all. Mobile layout rule:
## everything packed as tightly as the art allows. Numbers: NOTES.md.
const TOUCH_ENEMY_MAX_W := 0.42
const TOUCH_ENEMY_ART := Rect2(6, 5, 388, 537)  # box_hostiles2.png opaque (used) rect, of 410 × 555
const TOUCH_ENEMY_SCALES := [1.0, 1.125, 1.25, 4.0 / 3.0, 1.375, 1.5, 1.625, 5.0 / 3.0, 1.75, 1.875, 2.0]
const TOUCH_COL_TOP := 0.0  # canvas y of the weapons column top (the power row's opaque top)
const TOUCH_TOP_BUTTONS := CommandHud.TOP_BUTTONS  # FTL drive / ship / menu (+ store) buttons, incl. pullout
## Touch HUD scale, CLI `--hud-scale=N` (touch layouts; default TOUCH_HUD_SCALE_DEFAULT): the top-left block +
## crew list + top buttons, the systems bar + subsystems + power toggle, PAUSE / CANCEL, the stations buttons
## (TOUCH_STATION_SIZE ∝ it) and the weapons / drones column or boxes (exactly N: TOUCH_WEAPON_SCALES /
## TOUCH_SPLIT_PANEL_SCALES = [N]; the TARGET window and the ship shrink to make room). Absent: phone / Fold as before.
## These are variables (set once from the command line), named like the constants they replaced.
const TOUCH_HUD_SCALE_DEFAULT := 1.2
var TOUCH_WEAPON_SCALES: Array = [_cli_hud_scale()] if _cli_hud_scale_set() else [1.5, 1.25, 1.0]
const TOUCH_SUB_BOTTOM := 14.0  # subsystems' solid art ends this far above the layout bottom (no drones: they stay low)
var TOUCH_SYSBAR_SCALE := _cli_hud_scale()  # bottom-left systems bar (reactor + wires + boxes) and the subsystems
var TOUCH_TOPLEFT_SCALE := _cli_hud_scale()  # ship status, crew list, top buttons (_touch_top_left), PAUSE / CANCEL


## Tests: a HUD scale as if `--hud-scale=` were given (> 0; set before main is instantiated).
static var hud_scale_override := 0.0


static func _cli_hud_scale_set() -> bool:
	return hud_scale_override > 0.0 \
		or Array(OS.get_cmdline_user_args()).any(func(a: String) -> bool: return a.begins_with("--hud-scale="))


## `--hud-scale=N` (N > 0), else TOUCH_HUD_SCALE_DEFAULT.
static func _cli_hud_scale() -> float:
	if hud_scale_override > 0.0:
		return hud_scale_override
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--hud-scale=") and a.trim_prefix("--hud-scale=").to_float() > 0.0:
			return a.trim_prefix("--hud-scale=").to_float()
	return TOUCH_HUD_SCALE_DEFAULT


## HUD scale of the tall-canvas layouts when the player's option picks them (GameOptions.fold_layout) and no
## `--hud-scale` is given: the scale split (frozen) and pan were tuned at. Phone / band canvases keep their default.
const TOUCH_FOLD_HUD_SCALE := 1.5


## The option drives a tall-canvas touch layout without `--hud-scale`: the HUD is ×TOUCH_FOLD_HUD_SCALE.
func _fold_option_hud() -> bool:
	return input_mode == InputProfile.TOUCH and not _cli_hud_scale_set() and fold_layout_from_option() \
		and is_inside_tree() and _touch_tall()


## Effective touch HUD scale "given" (exact panel scales): `--hud-scale` / a test override, or the option's tall
## layouts (_fold_option_hud).
func _hud_scale_set() -> bool:
	return _cli_hud_scale_set() or _fold_option_hud()


func _hud_scale() -> float:
	if _cli_hud_scale_set():
		return _cli_hud_scale()
	return TOUCH_FOLD_HUD_SCALE if _fold_option_hud() else TOUCH_HUD_SCALE_DEFAULT


## Re-reads the touch HUD scale variables (start of every _touch_layout: the canvas can turn tall / short and the
## option can change while playing).
func _touch_hud_refresh() -> void:
	var s := _hud_scale()
	var given := _hud_scale_set()
	TOUCH_WEAPON_SCALES = [s] if given else [1.5, 1.25, 1.0]
	TOUCH_SYSBAR_SCALE = s
	TOUCH_TOPLEFT_SCALE = s
	TOUCH_SPLIT_PANEL_SCALES = [s] if given else [1.25, 1.0]

## Evade / O2 box (solid art x 8..97, y 96..137 at EVADE_BOX) moved under the scrap box, in the hull bar + scrap
## block: centred on the scrap box's solid art (x 383..504, centre 443.5) -> solid x 399..488, solid top 2 px under
## its solid bottom (45) -> y 47..88 (overhangs the 65-high hull block a little; right of the drone parts box).
const TOUCH_EVADE_OFFSET := Vector2(399 - 8, 47 - 96)
## Crew save / return stations buttons: a doors-style box (button_door_base.png, solid x 6..33, y 6..72) left of the
## subsystems, this far (canvas px) from their solid art, its top level with the doors button's.
const TOUCH_CREW_BOX_GAP := 2.0
## Crew list moved up: first box top (CrewControl.BOX_ORIGIN y 155) 2 px under the shields' solid bottom (y 87).
const TOUCH_CREW_SHIFT_Y := 89.0 - 155.0
const TOUCH_DRONE_GAP := 6.0  # px at ×1 between AUTOFIRE and the drones power row (kept apart on purpose)
## Player ship scales (eighths and thirds, like the TARGET window), tried largest first.
const TOUCH_SHIP_SCALES := [2.5, 7.0 / 3.0, 2.25, 2.0, 1.875, 1.75, 5.0 / 3.0, 1.625, 1.5, 1.375, 4.0 / 3.0, 1.25,
	1.125, 1.0, 0.875, 0.75]
const TOUCH_ROOM_WALL := 3.0  # world px around each room rect counted as its wall (rooms must not meet the HUD)
const TOUCH_FIT_STEP := 4.0  # canvas px between the hull top positions scanned by _touch_fit_ship
const TOUCH_PAUSE_GAP := 2.0  # canvas px kept between PAUSE / CANCEL and any other HUD piece
const TOUCH_STATION_SIZE := 60.0  # crew stations buttons in the TARGET corner: the 20×20 art ×3 (phone ≈ 31 dp)
const TOUCH_STATION_GAP := 4.0
const TOUCH_STATION_PAD := 6.0  # inside the TARGET frame art's bottom-right corner
var _touch_pause_at := Rect2()  # last layout: PAUSE + CANCEL pair (canvas / HUD layer coordinates)
var _touch_sig := ""  # inputs of the last _touch_layout (see _touch_signature)
var touch_ship_zoom := 1.0  # last layout: player ship scale
var touch_weapon_scale := 1.0  # last layout: weapons column scale
var _hull_rows_for: Texture2D = null  # hull texture _hull_rows was computed for
var _hull_rows: Array[Vector2i] = []  # per hull image row: leftmost / rightmost opaque x (-1, -1 = empty row)


## Touch UI, tall screens (visible canvas higher than the 720 layout height, e.g. the open Fold ~1280 × 1100): the
## whole combat HUD layer (both ship spaces, TARGET window, column, buttons, overlays: everything under hud_root)
## moves down by (visible h − 720) / 2 as ONE CanvasLayer offset; Controls keep hit-testing in local coordinates,
## main._input converts its events once (_hud_event), pushed synthetic events go back (_view_point), the tooltip
## layer gets the same offset (TooltipService.pointer() is in its layer's coordinates), centred windows take it
## out again (HudLayout.frame_offset) and the mirrored background is moved up so it fills from the canvas top.
func _touch_center_band() -> void:
	var layer := hud_root.get_parent() as CanvasLayer
	if layer == null:
		_touch_center_windows()
		return
	var vis := get_viewport().get_visible_rect().size
	var off := Vector2(0, floorf(maxf(vis.y - _touch_height(), 0.0) / 2)) if not single_view else Vector2.ZERO
	layer.offset = off
	TooltipService.offset = off
	if space_backdrop != null and space_backdrop.mirror != null:
		space_backdrop.mirror.position = -off
		# Tall layout (no band): the beacon space (nebula clouds, planet / sun ...) stays centred vertically, where
		# the band put it.
		space_backdrop.position = Vector2(0, floorf((vis.y - HudLayout.FRAME.y) / 2)) \
			if _touch_tall() and not single_view else Vector2.ZERO
	# The centred windows take this offset out again (HudLayout.frame_offset reads the layer's offset): re-centre
	# them NOW, after every change of it. Centring them before the band was set (at _ready, or on a resize whose
	# size_changed reached _touch_center_windows first) left them a whole band offset too low on tall canvases.
	_touch_center_windows()


## Viewport -> HUD layer coordinates for main's own pointer handling (identity unless _touch_center_band moved it).
func _hud_event(event: InputEvent) -> InputEvent:
	var layer := hud_root.get_parent() as CanvasLayer if hud_root != null else null
	if layer == null or layer.offset == Vector2.ZERO:
		return event
	if event is InputEventMouse or event is InputEventScreenTouch or event is InputEventScreenDrag:
		return event.xformed_by(layer.transform.affine_inverse())
	return event


## HUD layer point -> viewport (for events main pushes back into the viewport).
func _view_point(p: Vector2) -> Vector2:
	var layer := hud_root.get_parent() as CanvasLayer if hud_root != null else null
	return layer.transform * p if layer != null else p


## Layout height: the visible canvas, at most the 720-high HUD frame (canvases a little taller than 720 keep the HUD
## in a 720 band, centred by _touch_center_band); tall canvases (_touch_tall, the open Fold) use the whole height.
func _touch_height() -> float:
	var vh := get_viewport().get_visible_rect().size.y
	return vh if _touch_tall() else minf(vh, HudLayout.FRAME.y)


## Tall canvas (visible height ≥ TOUCH_TALL_MIN_H, e.g. the open Fold ~1280 × 1100): the combat HUD is spread over
## the whole canvas with its pieces pushed to the edges (_touch_layout_tall) instead of the centred 720 band.
## Phone (1600 × 720) and PC never are.
const TOUCH_TALL_MIN_H := 800.0
## Tall layout: px (× column scale) between the weapons and drones columns side by side, and canvas px kept between
## the column's bottom and the TARGET frame art.
const TOUCH_TALL_GAP := 6.0


func _touch_tall() -> bool:
	return get_viewport().get_visible_rect().size.y >= TOUCH_TALL_MIN_H


## Canvas y shift of the systems bar (drawn for the 720 frame, bottom at y 720): tall canvases put it on the canvas
## bottom (bottom-left corner).
func _touch_sysbar_dy() -> float:
	return maxf(_touch_height() - HudLayout.FRAME.y, 0.0)


## Everything the touch layout depends on besides the ship blueprints: canvas size, enemy shown, crew count
## (crew list height), installed systems and their levels (systems bar height), reactor size, drone panel.
func _touch_signature() -> String:
	var sh := player_space.ship
	var lv := 0
	for id in systems_bar.main_ids:
		var sy := sh.sys(id)
		lv = lv * 9 + (sy.get_level() if sy else 0)
	return "%s|%s|%d|%s|%d|%d|%s|%s|%s|%.3f|%s" % [get_viewport().get_visible_rect().size, _touch_enemy_present(),
		crew_control.roster.size(), SystemsBar.layout_signature(sh), lv, sh.reactor_max,
		drone_panel != null and is_instance_valid(drone_panel), weapon_panel.visible, fold_layout(), _hud_scale(),
		phone_layout()]


## An enemy ship is at the beacon and its TARGET window is up: not destroyed (victory), not jumped away
## (escaped: its ship is marked `jumping` once the JumpLeave animation is done). A jump / new event ship
## rebuilds the scene (has_enemy is recomputed). The touch layout switches on every change of this.
func _touch_enemy_present() -> bool:
	if not has_enemy or victory_shown or enemy_space == null:
		return false
	return not (run != null and bool(run.enemy.get("escaped", false)) and enemy_space.ship.jumping)


## Per frame (cheap): re-runs the touch layout when one of its inputs changed (crew joined, system bought ...).
func _touch_layout_tick() -> void:
	if input_mode == InputProfile.TOUCH and not single_view and _touch_sig != "" and _touch_signature() != _touch_sig:
		_touch_layout()
	_touch_pause_tick()
	_touch_intruder_msg()


## Touch UI: the intruder warning (CommandHud, ShipStatus boardingMessage at frame (730, 210) on PC, i.e. over the
## player ship next to the PC TARGET window) follows the player ship as laid out — the PC place ×t lands on the
## TARGET window in the split layout. Centred on the player ship's rooms (canvas, through the turned / zoomed /
## panned view), at the PC height ×t or the rooms' top if lower; kept clear of the crew list on the left and of the
## TARGET art (touch_enemy shown, not the pan layouts: one scene) / the canvas edge on the right. PC: the vanilla place.
func _touch_intruder_msg() -> void:
	if command_hud == null:
		return
	if not _touch() or single_view or player_space == null or player_space.ship == null:
		command_hud.intruder_msg_at = Vector2.INF
		return
	var sh := player_space.ship
	var rb := Rect2()
	var first := true
	for room in sh.layout.rooms:
		var rr := sh.room_rect(room.id)
		for c in [rr.position, rr.end, Vector2(rr.position.x, rr.end.y), Vector2(rr.end.x, rr.position.y)]:
			var p := world_to_screen(sh, c)
			rb = Rect2(p, Vector2.ZERO) if first else rb.expand(p)
			first = false
	if first:
		command_hud.intruder_msg_at = Vector2.INF
		return
	var to_hud := command_hud.get_global_transform()
	var t := to_hud.get_scale().x
	var half := FtlData.ftl_text_width(52, HudDraw.txt("warning_intruders")) * t / 2.0
	var g := TOUCH_SPLIT_GAP
	var left := g
	var n := crew_control.roster.size() if crew_control != null else 0
	if n > 0 and crew_list != null:
		var cr := crew_control.box_rect(0).merge(crew_control.box_rect(n - 1))
		var crew_r := (crew_list.get_global_transform() * cr).end.x
		left = crew_r + g
	var right := get_viewport().get_visible_rect().size.x - g
	if _touch_enemy_present() and enemy_window != null and _touch_kind not in ["pan", "phone_pan"]:
		var art_l := (enemy_window.get_global_transform() * (HudLayout.ENEMY_FRAME.position + TOUCH_ENEMY_ART.position)).x
		if art_l > rb.get_center().x:
			right = minf(right, art_l - g)
	var cx := rb.get_center().x
	cx = maxf(minf(cx, right - half), left + half) if right - left >= 2 * half else (left + right) / 2.0
	var y := maxf(HudLayout.INTRUDER_MSG.y * t, rb.position.y)
	command_hud.intruder_msg_at = (to_hud.affine_inverse() * Vector2(cx, y)).round()


## Touch UI pause overlay text (FTL iPad strings, text_misc.xml): the selection mode's title + instruction
## (weapon / beam targeting, teleporter send / retrieve, hacking, mind control, crew selected = choose a room);
## AUTO-PAUSED when the selection mode paused with none of those; plain PAUSED (no Spacebar hint) otherwise.
func _touch_pause_tick() -> void:
	if pause_overlay == null:
		return
	pause_overlay.touch_pause = _touch()
	var ids := ["", ""]
	if _touch():
		var me := player_space.ship
		if weapon_control.armed >= 0 or weapon_control.beam_ship != null:
			ids = ["paused_targeting", "paused_targeting_text_beam" if weapon_control.armed_is_beam()
				else "paused_targeting_text"]
		elif combat.player_tp_armed != TeleporterRule.NONE:
			ids = ["paused_teleport", "paused_teleport_text_out" if combat.player_tp_armed == TeleporterRule.SEND
				else "paused_teleport_text_in"]
		elif me.hack_armed:
			ids = ["paused_hacking", "paused_hacking_text"]
		elif me.mind_armed:
			ids = ["paused_mind", "paused_mind_text"]
		elif not crew_control.selected_crew().is_empty():
			ids = ["paused_room", "paused_room_text"]
		elif _select_paused:
			ids = ["auto_paused", "auto_paused_text"]
	pause_overlay.pause_title = ids[0]
	pause_overlay.pause_text = ids[1]


var _touch_kind := ""  # last _touch_layout_kind laid out ("" before the first touch layout)


## Which touch combat layout the canvas / option / flags call for now: "pan", "split", "tall" (edges) or "band"
## (phone and canvases under TOUCH_TALL_MIN_H).
func _touch_layout_kind() -> String:
	if _touch_phone_pan():
		return "phone_pan"
	if _touch_pan():
		return "pan"
	if _touch_split():
		return "split"
	return "tall" if _touch_tall() else "band"


## [weapons vertical, drones vertical] the current touch layout wants: the touch columns (phone, edges), the PC
## boxes (pan: both; split: weapons box + the vertical drones column); PC: boxes.
func _armament_vertical() -> Array:
	var touch := input_mode == InputProfile.TOUCH
	var wv := touch and not _touch_split() and not _touch_pan()
	return [wv, wv or (touch and _touch_split())]


func _touch_layout() -> void:
	if enemy_space == null or single_view or weapon_panel == null or crew_control == null or systems_bar == null:
		return
	if screen_shake != null:
		screen_shake.restore()  # lay out the unshaken HUD (the shake resumes on the new positions)
	_touch_sig = _touch_signature()
	_touch_hud_refresh()
	# Layout switch (option changed in combat, fold / unfold): nothing carries over from the previous layout — pan
	# offset / arrows / parallax (_pan_reset), panels of the other kind (rebuilt), turned ship, scaled subsystems,
	# moved pause text / top buttons (reset below; each layout sets what it uses).
	var kind := _touch_layout_kind()
	if kind != _touch_kind:
		if _touch_kind in ["pan", "phone_pan"] or kind in ["pan", "phone_pan"]:
			_pan_reset()
		print("touch layout: %s -> %s (HUD ×%.3f)" % [_touch_kind if _touch_kind != "" else "-", kind,
			TOUCH_SYSBAR_SCALE])
		_touch_kind = kind
	var want := _armament_vertical()
	if weapon_panel.vertical != want[0] or (drone_panel != null and is_instance_valid(drone_panel)
			and drone_panel.vertical != want[1]):
		_build_armament_panels()  # PC boxes / touch columns as this layout wants them; lays out again
		return
	if kind != "pan" and kind != "phone_pan":
		if pan_arrows != null:
			pan_arrows.visible = false
		pause_overlay.scale = Vector2.ONE  # (pan moves / scales the pause text and may move the top buttons)
		pause_overlay.position = Vector2.ZERO
		command_hud.position = Vector2.ZERO
	var vis := get_viewport().get_visible_rect().size
	var h := _touch_height()
	var xf := touch_enemy_transform()
	_place_touch_enemy(xf)
	var target_left := (xf * (HudLayout.ENEMY_FRAME.position + TOUCH_ENEMY_ART.position)).x
	# The column: weapons on top, then (TOUCH_DRONE_GAP lower) the drones column; both right-aligned against the
	# TARGET art. [panel, local y offset at ×1].
	var stack := []
	var stack_h := 0.0
	var stack_w := 0.0
	for p in [weapon_panel, drone_panel]:
		if p != null and is_instance_valid(p) and p.visible and p.vertical:
			if not stack.is_empty():
				stack_h += TOUCH_DRONE_GAP
			stack.append([p, stack_h])
			stack_h += p.v_size.y
			stack_w = maxf(stack_w, p.v_size.x)
	# Subsystems (pilot, sensors, doors, battery: the systems bar's sub_group) under the stack, at the systems
	# bar's scale, right edge on the TARGET art too.
	var sub_b := systems_bar.subsystem_bounds() if systems_bar.sub_group != null and not systems_bar.sub_ids.is_empty() \
		else Rect2()
	var sub_h := sub_b.size.y * TOUCH_SYSBAR_SCALE
	var hud := _touch_hud_rects(h)
	player_space.fixed_rotation = 0.0  # only the split layout turns the player ship (and rescales the subsystems)
	if systems_bar.sub_group != null:
		systems_bar.sub_group.scale = Vector2.ONE
	if kind == "pan":  # open-Fold "pan" layout (--fold-layout=pan): PC HUD + one wide panned ship scene
		_touch_layout_pan()
		return
	if kind == "phone_pan":  # phone "pan" layout (--phone-layout=pan): the same idea packed into 720 px
		_touch_layout_phone_pan()
		return
	if kind == "split":
		_touch_layout_split(sub_b, sub_h, hud)
		return
	if _touch_tall():
		_touch_layout_tall(xf, stack, sub_b, sub_h, hud)
		return
	var col_widest := (target_left if _touch_enemy_present() else vis.x) - stack_w * (TOUCH_WEAPON_SCALES[0] as float)
	var hz := _touch_hazard(col_widest)
	if hz.has_area():
		hud.append(hz)  # the ship's rooms keep clear of the hazard status too
	_touch_engines_warning(col_widest, hz)
	# One layout attempt for a TARGET / column right edge `tl`: {fit, cs, col_top, pause}. `zmax` caps the ship
	# scale, `inside` keeps the whole hull art on the canvas (no-enemy layout).
	var hull_mid_y := _touch_hull_pos().y + _touch_hull_rows().size() / 2.0  # world y of the hull image's middle
	var attempt := func(tl: float, zmax: float, inside: bool) -> Dictionary:
		var col_right := tl
		var cands := []
		for c in TOUCH_WEAPON_SCALES:  # largest first
			# Narrow canvases (fold inner): a column reaching left over the FTL / ship / menu buttons starts under them.
			var top := TOUCH_COL_TOP if col_right - stack_w * c >= TOUCH_TOP_BUTTONS.end.x else TOUCH_TOP_BUTTONS.end.y
			# Height: the stack at c, then TOUCH_DRONE_GAP·c and the subsystems at TOUCH_SYSBAR_SCALE (fixed).
			var hfit := floorf((h - top - sub_h) / maxf(stack_h + (TOUCH_DRONE_GAP if sub_h > 0 else 0.0), 1.0)
				/ TOUCH_ENEMY_STEP + 0.01) * TOUCH_ENEMY_STEP
			var c2 := maxf(1.0, minf(c, hfit))
			var blocks: Array[Rect2] = []
			for e in stack:
				var at := Vector2(col_right - e[0].v_size.x * c2, top + e[1] * c2)
				for b: Rect2 in e[0].v_blocks():
					blocks.append(Rect2(at + b.position * c2, b.size * c2))
			if sub_h > 0:
				# Same place as below (pinned to the bottom unless the stack reaches lower).
				var sa := Vector2(col_right - sub_b.size.x * TOUCH_SYSBAR_SCALE,
					maxf(top + (stack_h + TOUCH_DRONE_GAP) * c2, h - sub_h - TOUCH_SUB_BOTTOM)).round()
				blocks.append(Rect2(sa, Vector2(sub_b.size.x * TOUCH_SYSBAR_SCALE, sub_h)))
				# Crew buttons box + the power toggle under it (solid art y 6 .. BELOW + 57); with the TARGET window
				# up the buttons are in its corner and the toggle alone sits by the subsystems.
				# The toggle alone sits by the subsystems; the big stations buttons are in the TARGET corner, or (no
				# enemy) left of the toggle.
				var ta := _touch_toggle_at(sa, sub_b)
				blocks.append(Rect2(ta + Vector2(6, 6) * TOUCH_SYSBAR_SCALE,
					Vector2(28, CrewList.BOX_BODY_H - 6) * TOUCH_SYSBAR_SCALE))
				if not _touch_enemy_present():
					var sr: Array = _touch_station_rects_by_toggle(ta)
					blocks.append((sr[0] as Rect2).merge(sr[1]))
			# PAUSE / CANCEL: a free spot clear of every HUD piece and block (rooms avoid it too).
			var pr := _touch_pause_rect(hud, blocks, tl, h)
			var hud2: Array[Rect2] = hud.duplicate()
			hud2.append(pr)
			var f2 := _touch_fit_ship(blocks, tl, h, hud2, zmax, inside)
			if f2.is_empty():
				continue
			var cand := {"fit": f2, "cs": c2, "col_top": top, "pause": pr}
			if cands.is_empty() and top == TOUCH_COL_TOP:
				return cand  # wide canvas (phone): the largest column whose ship fits (column first, then the ship)
			cands.append(cand)
		# Narrow canvas (open Fold): the largest column had to start under the top buttons, which pushes the nose
		# (and the ship) down. Every column scale competes: the bigger ship, then the ship nearer the band's
		# vertical centre, then the bigger column.
		var best := {}
		var bz := 0.0
		var bd := 0.0
		for cd in cands:
			var z: float = cd.fit.zoom
			var d := absf(cd.fit.origin.y + hull_mid_y * z - h / 2)  # hull middle vs band middle			# cands are in falling column scale: equal ship and centring keep the bigger column.
			if best.is_empty() or z > bz + 0.001 or (absf(z - bz) <= 0.001 and d < bd - 0.5):
				best = cd
				bz = z
				bd = d
		return best
	var res: Dictionary = attempt.call(target_left, INF, false)
	if not _touch_enemy_present():
		# No enemy: the column goes to the canvas edge; the ship stays wholly on the canvas and at most one
		# TOUCH_SHIP_SCALES step above what it gets in combat (same ship, TARGET window shown).
		var cap := INF
		if not res.is_empty():
			var i := TOUCH_SHIP_SCALES.find(res.fit.zoom)
			cap = TOUCH_SHIP_SCALES[maxi(i - 1, 0)] if i >= 0 else res.fit.zoom
			print("touch layout: no enemy; in combat the ship would be ×%.3f -> cap ×%.3f" % [res.fit.zoom, cap])
		target_left = vis.x
		res = attempt.call(target_left, cap, true)
	var col_right := target_left
	var fit: Dictionary = res.get("fit", {})
	var cs: float = res.get("cs", 1.0)
	var col_top: float = res.get("col_top", TOUCH_COL_TOP)
	if res.has("pause"):
		_touch_pause_at = res.pause
	var panel_at := []
	for e in stack:
		panel_at.append(Vector2(col_right - e[0].v_size.x * cs, col_top + e[1] * cs).round())
	# Subsystems: always at the bottom (where they sit with a drones column too), within the right thumb's reach.
	var sub_at := Vector2.ZERO
	if sub_h > 0:
		sub_at = Vector2(col_right - sub_b.size.x * TOUCH_SYSBAR_SCALE,
			maxf(col_top + (stack_h + TOUCH_DRONE_GAP) * cs, h - sub_h - TOUCH_SUB_BOTTOM)).round()
	_touch_apply(xf, stack, cs, panel_at, sub_b, sub_h, sub_at, fit)


## Applies a touch layout: column panels (`stack` entries [panel, y] at canvas `panel_at`, scale `cs`), the
## systems bar ×TOUCH_SYSBAR_SCALE (on the canvas bottom: _touch_sysbar_dy) with its subsystems at `sub_at`, the
## top-left block, the crew stations buttons / power toggle, the band and the player ship (`fit`: origin, zoom).
func _touch_apply(xf: Transform2D, stack: Array, cs: float, panel_at: Array, sub_b: Rect2, sub_h: float,
		sub_at: Vector2, fit: Dictionary) -> void:
	var vis := get_viewport().get_visible_rect().size
	var h := _touch_height()
	if fit.is_empty():  # nothing fits even at the smallest TOUCH_SHIP_SCALES step: the PC position at ×1
		fit = {"origin": player_origin(), "zoom": 1.0}
	touch_weapon_scale = cs
	touch_ship_zoom = fit.zoom
	for i in stack.size():
		stack[i][0].scale = Vector2(cs, cs)
		stack[i][0].position = panel_at[i]
	# The whole systems bar (reactor, wires, system columns and buttons) ×TOUCH_SYSBAR_SCALE about the frame's
	# bottom-left corner, like the PC bar's anchor (moved down onto the canvas bottom on tall canvases).
	var k := TOUCH_SYSBAR_SCALE
	var pivot := Vector2(0, HudLayout.FRAME.y)
	systems_bar.pivot_offset = pivot
	systems_bar.scale = Vector2(k, k)
	systems_bar.position = Vector2(0, _touch_sysbar_dy())
	if sub_h > 0:
		# sub_group lives in the scaled, moved bar: canvas = bar.position + (q + Δ − pivot)·k + pivot must put sub_b's
		# top-left at sub_at.
		systems_bar.sub_group.position = pivot - sub_b.position + (sub_at - systems_bar.position - pivot) / k
	_touch_top_left()
	# Crew stations buttons (crew list local coordinates: the list is ×TOUCH_TOPLEFT_SCALE, shifted up): enlarged
	# in the TARGET window's bottom-right corner while it is shown, else in the doors-style box by the subsystems.
	crew_list.touch_button_box = null
	var st := []
	if _touch_enemy_present():
		st = _touch_station_rects(xf)
	elif sub_h > 0:
		st = _touch_station_rects_by_toggle(_touch_toggle_at(sub_at, sub_b))
	var local_st := []
	for r: Rect2 in st:
		local_st.append(Rect2((r.position - crew_list.position) / TOUCH_TOPLEFT_SCALE, r.size / TOUCH_TOPLEFT_SCALE))
	crew_list.touch_station_rects = local_st
	if sub_h > 0:
		var cb := _touch_crew_box(sub_at, sub_b)
		if st.is_empty():
			crew_list.touch_button_box = (cb - crew_list.position) / TOUCH_TOPLEFT_SCALE
		# Power mode toggle (+ / −) right under it, same scale (TouchPowerToggle).
		if touch_power == null:
			touch_power = TouchPowerToggle.new()
			touch_power.held_fn = func() -> bool: return _gestures().held_minus()  # held finger = − for now
			hud_root.add_child(touch_power)
			hud_root.move_child(touch_power, crew_list.get_index() + 1)
		touch_power.scale = Vector2(TOUCH_TOPLEFT_SCALE, TOUCH_TOPLEFT_SCALE)
		touch_power.position = (cb + Vector2(0, TouchPowerToggle.BELOW * TOUCH_TOPLEFT_SCALE)).round() \
			if st.is_empty() else _touch_toggle_at(sub_at, sub_b)
	if touch_power != null:
		touch_power.visible = sub_h > 0
	_touch_center_band()
	player_space.position = Vector2.ZERO
	player_space.size = Vector2(vis.x, h)  # the whole band (shots fly to its right edge, as over the PC frame)
	player_space.set_fixed_origin(fit.origin, fit.zoom)
	var cols := ""
	for e in stack:
		cols += " %s %s at %s" % ["weapons" if e[0] == weapon_panel else "drones", e[0].v_size, e[0].position]
	if sub_h > 0:
		cols += " subsystems %s ×%.2f at %s" % [sub_b.size, k, sub_at]
	cols += " pause+cancel %s" % _touch_pause_at
	print("touch layout: canvas %s, TARGET ×%.3f at %s, column ×%.3f:%s, ship ×%.3f origin %s" % [vis,
		xf.get_scale().x, (xf * HudLayout.ENEMY_FRAME.position).round(), cs, cols, fit.zoom, fit.origin])


## ENGINES CRITICAL (CommandHud, ×TOUCH_TOPLEFT_SCALE) moved left (text only, no lines) when it would reach over
## the hazard status `hz` or the weapons column / TARGET window (canvas x `col_left`).
func _touch_engines_warning(col_left: float, hz: Rect2) -> void:
	var ew := Rect2(CommandHud.ENGINES_WARNING_BOUNDS.position * TOUCH_TOPLEFT_SCALE,
		CommandHud.ENGINES_WARNING_BOUNDS.size * TOUCH_TOPLEFT_SCALE)
	var ew_right := col_left
	if hz.has_area() and hz.position.y < ew.end.y and hz.end.y > ew.position.y:
		ew_right = minf(ew_right, hz.position.x)
	command_hud.engines_warning_shift = Vector2(floorf((ew_right - 2 - ew.end.x) / TOUCH_TOPLEFT_SCALE), 0) \
		if ew.end.x > ew_right - 2 else Vector2.ZERO


## Tall canvas layout (_touch_tall, open Fold ~1280 × 1100; first visual draft): no band, every piece pushed to a
## canvas edge — top-left block (hull, shields, resources, scrap, evade / O2) and crew list at the canvas origin
## (_touch_top_left, unchanged), top buttons + hazard status in the top row, the systems bar in the bottom-left
## corner (_touch_sysbar_dy), the TARGET window in the bottom-right corner (touch_enemy_transform, art bottom on the
## canvas bottom), the weapons / drones column(s) in the top-right corner above it (_touch_tall_column), the
## subsystems on the canvas bottom with their right edge on the TARGET art (no enemy: on the canvas's right edge),
## the crew box / power toggle / stations buttons left of them as on the phone, PAUSE / CANCEL by
## _touch_pause_rect (scanning up from the canvas bottom), and the player ship fitted in what is left
## (_touch_fit_ship; the TARGET art is one more block, so hull rows above it may reach the column).
func _touch_layout_tall(xf: Transform2D, stack: Array, sub_b: Rect2, sub_h: float, hud: Array[Rect2]) -> void:
	var vis := get_viewport().get_visible_rect().size
	var h := _touch_height()
	var k := TOUCH_SYSBAR_SCALE
	var enemy := _touch_enemy_present()
	var art := Rect2(xf * (HudLayout.ENEMY_FRAME.position + TOUCH_ENEMY_ART.position),
		TOUCH_ENEMY_ART.size * xf.get_scale().x)
	var sub_y := roundf(h - sub_h - TOUCH_SUB_BOTTOM)
	var free_bottom := (sub_y if sub_h > 0 else h) - TOUCH_TALL_GAP  # column bottom limit without the TARGET window
	var col := _touch_tall_column(stack, art.position.y - TOUCH_TALL_GAP if enemy else free_bottom, vis.x)
	var hz := _touch_hazard(col.left)
	if hz.has_area():
		hud.append(hz)
	_touch_engines_warning(col.left, hz)
	# One plan: with or without the TARGET window (`with_target`), ship capped at `zmax`, whole hull on the canvas
	# when `inside`.
	var plan := func(with_target: bool, zmax: float, inside: bool) -> Dictionary:
		var c2: Dictionary = col if with_target == enemy else _touch_tall_column(stack,
			art.position.y - TOUCH_TALL_GAP if with_target else free_bottom, vis.x)
		var tl := art.position.x if with_target else vis.x
		var blocks: Array[Rect2] = []
		blocks.append_array(c2.blocks)
		if with_target:
			blocks.append(art)
		var sa := Vector2.ZERO
		if sub_h > 0:
			sa = Vector2(roundf(tl - sub_b.size.x * k), sub_y)
			blocks.append(Rect2(sa, Vector2(sub_b.size.x * k, sub_h)))
			var ta := _touch_toggle_at(sa, sub_b)
			blocks.append(Rect2(ta + Vector2(6, 6) * k, Vector2(28, CrewList.BOX_BODY_H - 6) * k))
			if not with_target:
				var sr: Array = _touch_station_rects_by_toggle(ta)
				blocks.append((sr[0] as Rect2).merge(sr[1]))
		var pr := _touch_pause_rect(hud, blocks, tl, h)
		var hud2: Array[Rect2] = hud.duplicate()
		hud2.append(pr)
		return {"fit": _touch_fit_ship(blocks, vis.x, h, hud2, zmax, inside), "col": c2, "sub_at": sa, "pause": pr}
	var cap := INF
	if not enemy:
		# As on the phone: at most one TOUCH_SHIP_SCALES step above the in-combat scale, whole hull on the canvas.
		var r0: Dictionary = plan.call(true, INF, false)
		if not r0.fit.is_empty():
			var i := TOUCH_SHIP_SCALES.find(r0.fit.zoom)
			cap = TOUCH_SHIP_SCALES[maxi(i - 1, 0)] if i >= 0 else r0.fit.zoom
			print("touch layout (tall): no enemy; in combat the ship would be ×%.3f -> cap ×%.3f" % [r0.fit.zoom, cap])
	var res: Dictionary = plan.call(enemy, cap, not enemy)
	_touch_pause_at = res.pause
	print("touch layout (tall): column %s, top %s" % ["side by side" if res.col.side else "stacked", res.col.top])
	_touch_apply(xf, stack, res.col.cs, res.col.at, sub_b, sub_h, res.sub_at, res.fit)


## Tall layout: the weapons / drones column(s) in the canvas's top-right corner (right edge on `right`), ending
## above canvas y `bottom`. Largest TOUCH_WEAPON_SCALES step first; at each step the usual stack (weapons, drones
## TOUCH_DRONE_GAP lower) is tried first, then the two side by side (weapons left, drones on the right edge,
## TOUCH_TALL_GAP apart, tops level). Top at TOUCH_COL_TOP unless the column reaches left over the top buttons
## (then under them). {cs, side, top, at: Array[Vector2] (per stack entry), blocks: Array[Rect2], left}.
func _touch_tall_column(stack: Array, bottom: float, right: float) -> Dictionary:
	var build := func(c: float, side: bool) -> Dictionary:
		var at := []
		var w := 0.0
		var hh := 0.0
		if side:
			for i in stack.size():
				var v: Vector2 = stack[i][0].v_size
				w += v.x * c + (TOUCH_TALL_GAP * c if i > 0 else 0.0)
				hh = maxf(hh, v.y * c)
		else:
			for e in stack:
				w = maxf(w, e[0].v_size.x * c)
				hh = maxf(hh, (e[1] + e[0].v_size.y) * c)
		var top := TOUCH_COL_TOP if right - w >= TOUCH_TOP_BUTTONS.end.x else TOUCH_TOP_BUTTONS.end.y
		var x := right
		var pos := {}
		var order := range(stack.size())
		if side:
			order.reverse()  # drones on the right edge, weapons left of them
		for i in order:
			var v: Vector2 = stack[i][0].v_size
			if side:
				pos[i] = Vector2(x - v.x * c, top).round()
				x -= (v.x + TOUCH_TALL_GAP) * c
			else:
				pos[i] = Vector2(right - v.x * c, top + stack[i][1] * c).round()
		var blocks: Array[Rect2] = []
		for i in stack.size():
			at.append(pos[i])
			for b: Rect2 in stack[i][0].v_blocks():
				blocks.append(Rect2(pos[i] + b.position * c, b.size * c))
		return {"cs": c, "side": side, "top": top, "at": at, "blocks": blocks, "left": right - w,
			"fits": top + hh <= bottom}
	for c in TOUCH_WEAPON_SCALES:
		for side in ([false, true] if stack.size() > 1 else [false]):
			var r: Dictionary = build.call(c, side)
			if r.fits:
				return r
	return build.call(1.0, stack.size() > 1)


## Open-Fold layout variant `--fold-layout=split` (tall canvases only; visual experiment, taps untested; the default
## `edges` is _touch_layout_tall): the player ship turned to face up (Space.fixed_rotation = PI / 2) on the left, a
## right-hand column from the top: subsystems (+ the + / − toggle left of them) -> TARGET window -> weapons ->
## drones as their PC boxes (horizontal holders, the system power column left of each). NOTES.md "split".
func _touch_split() -> bool:
	return _touch_tall() and fold_layout() == "split"  # (fold_layout: --fold-layout=, cached; tests set it)


const TOUCH_SPLIT_GAP := 6.0  # canvas px between the right column's pieces (and around the top buttons)
const TOUCH_SPLIT_MAX_W := 0.5  # TARGET art at most this share of the canvas width (the left half is the ship's)
# PC weapons / drones boxes, largest that fits first (`--hud-scale=N`: exactly N, the TARGET window shrinks instead).
## TARGET scales below ×1 the split layout falls back to (after every TOUCH_ENEMY_SCALES step) when the column does
## not fit the height otherwise: only with a large `--hud-scale` (Fold ×1.5: the subsystems row must go under the
## wider top buttons).
const TOUCH_SPLIT_SMALL_TARGET := [0.875, 0.75, 2.0 / 3.0]
var TOUCH_SPLIT_PANEL_SCALES: Array =[_cli_hud_scale()] if _cli_hud_scale_set() else [1.25, 1.0]


## Panel-local top-left of the system power column of a PC weapons / drones panel (box location − holder origin,
## SystemPowerColumn.ABOVE up).
func _touch_split_col_off() -> Vector2:
	return Vector2(-HudLayout.HOLDER_X, HudLayout.SYSTEM_BOX_Y - HudLayout.ARMAMENT_Y - SystemPowerColumn.ABOVE)


## Panel-local rect (×1) of a PC weapons / drones panel as drawn: the holder (0, 0, holder w, 88) merged with its
## system power column's bars (current level; the weapons column is the panel's child, the drones column the
## systems bar's, moved next to the panel by _touch_layout_split).
func _touch_split_unit(p: Control) -> Rect2:
	if p.get("vertical"):
		return Rect2(Vector2.ZERO, p.get("v_size"))  # the touch column (split: the drones)
	var r := Rect2(Vector2.ZERO, p.size)
	var col: SystemPowerColumn = (p as WeaponPanel).column if p is WeaponPanel else systems_bar.columns.get("drones")
	if col != null:
		var hr := col.hit_rect()
		r = r.merge(Rect2(_touch_split_col_off() + hr.position, hr.size))
	return r


## Split ship position (_touch_fit_ship_rot): the leftmost valid hull position (whole hull art still on the canvas,
## rooms clear of the crew list / HUD), rooms centre nearest the canvas's vertical middle among equally-left rows.
## false = the first rule (rooms centre nearest the left area's centre).
const TOUCH_SPLIT_SHIP_LEFT := true
const TOUCH_SPLIT_SUB_RATIO := 5.0 / 6.0  # split subsystems scale / HUD scale (×1.25 at --hud-scale=1.5, ×1 at 1.2)
const TOUCH_SPLIT_SUB_TOP_GAP := 2.0  # canvas px between the split subsystems' solid art and the top buttons


## Split layout: the hazard status (HazardHud: DANGER! icon(s) + text) in the top row right of the MENU wrench's
## solid right `left` (+ 2), 2 px under the canvas top, at the largest of TOUCH_TOPLEFT_SCALE / 1.25 / 1 / 0.75
## (never above the HUD scale) that ends 2 px before `right` (Fold ×1.5 HUD: one icon ×1.5, 105 × 110; the storm's
## two ×1, 142 × 73); the subsystems go under it where they meet. Sets its status_xf (tooltip hit boxes follow);
## returns its canvas rect (empty without a hazard).
func _touch_split_hazard(left: float, right: float) -> Rect2:
	if hazard_hud == null or run == null or run.hazard == null:
		return Rect2()
	var b := HazardHud.status_bounds(hazard_hud.two_icons())
	var s := 0.75
	for c: float in [TOUCH_TOPLEFT_SCALE, 1.25, 1.0, 0.75]:
		if c <= TOUCH_TOPLEFT_SCALE + 0.001 and b.size.x * c <= right - left - 4:
			s = c
			break
	var at := Vector2(left + 2, 2).round()
	hazard_hud.status_xf = Transform2D(0.0, Vector2(s, s), 0.0, at - b.position * s)
	return Rect2(at, b.size * s)


## Split layout alerts under the JUMP (FTL drive) button, between it and the TARGET window: the hazard status at
## TOUCH_SPLIT_ALERT_SCALE, its left edge on the FTL base's, top 2 px under the pull-out; ENGINES CRITICAL (text
## only, CommandHud.engines_warning_shift) top-aligned with it, right edge 4 px left of the hazard status (no hazard:
## centred under the JUMP button). Returns the hazard rect (empty without a hazard).
const TOUCH_SPLIT_ALERT_SCALE := 1.0
func _touch_split_alerts() -> Rect2:
	var t := TOUCH_TOPLEFT_SCALE
	var y0 := roundf((HudLayout.FTL_PULLOUT.y + 49.0) * t + 2)  # FTL_pullout.png 75×49
	var jump := Rect2(HudLayout.FTL_BASE * t, Vector2(98, 55) * t)
	var hz := Rect2()
	if hazard_hud != null and run != null and run.hazard != null:
		var b := HazardHud.status_bounds(hazard_hud.two_icons())
		var s := TOUCH_SPLIT_ALERT_SCALE
		var at := Vector2(jump.position.x, y0).round()
		hazard_hud.status_xf = Transform2D(0.0, Vector2(s, s), 0.0, at - b.position * s)
		hz = Rect2(at, b.size * s)
	# ENGINES CRITICAL: two centred lines drawn from frame (709, 142) + shift (HudLayout.ENGINES_WARNING) ×t.
	var spec: Array = HudLayout.ENGINES_WARNING
	var o: Vector2 = spec[0] + spec[2]
	var tw := FtlData.ftl_text_width(59, HudDraw.txt("warning_engine")) * t
	var cx := hz.position.x - 4 - tw / 2 if hz.has_area() else jump.get_center().x
	command_hud.engines_warning_shift = Vector2(roundf(cx / t - o.x), roundf(y0 / t - o.y))
	return hz


## Split layout: PAUSE + CANCEL STACKED (TouchCombatButtons.stacked: PAUSE at the bottom, CANCEL above; one canvas
## rect of one base × two bases + GAP) as LOW as possible: scanning up from 2 px above the canvas bottom
## (TOUCH_FIT_STEP), the first height with a spot TOUCH_PAUSE_GAP clear of every HUD rect and block; there the left
## edge nearest the gap after the systems bar (SystemsBar.bar_right ×TOUCH_SYSBAR_SCALE + TOUCH_SPLIT_GAP), or only
## `fixed_x` (_touch_layout_split also tries right of the weapons power bars; empty rect when nothing is free within
## 200 px of the bottom there). Else _touch_pause_rect.
func _touch_split_pause(hud: Array[Rect2], blocks: Array[Rect2], h: float, fixed_x := NAN) -> Rect2:
	var t := TOUCH_TOPLEFT_SCALE
	var b := TouchCombatButtons.BASE_SIZE
	var size := Vector2(b.x, 2 * b.y + TouchCombatButtons.GAP) * t  # stacked: PAUSE at the bottom, CANCEL above
	var vw := get_viewport().get_visible_rect().size.x
	var pref := roundf(systems_bar.bar_right() * TOUCH_SYSBAR_SCALE + TOUCH_SPLIT_GAP)
	var obst: Array[Rect2] = []
	for o: Rect2 in hud + blocks:
		obst.append(o.grow(TOUCH_PAUSE_GAP))
	var y := h - size.y - 2
	while y >= 0.0:
		# Free x intervals of the stacked pair at this height; the one nearest `pref` (the gap after the bar).
		var forbid := []
		for o in obst:
			if o.end.y > y and o.position.y < y + size.y:
				forbid.append(Vector2(o.position.x - size.x, o.end.x))
		forbid.sort_custom(func(p: Vector2, q: Vector2) -> bool: return p.x < q.x)
		var best := INF
		var x := 0.0
		var hi := vw - size.x
		for f: Vector2 in forbid + [Vector2(INF, INF)]:
			var x1 := minf(f.x, hi)
			if x1 >= x:
				if not is_nan(fixed_x):  # only that left edge
					if fixed_x >= x and fixed_x <= x1:
						best = fixed_x
				else:
					var c := clampf(pref, x, x1)
					if best == INF or absf(c - pref) < absf(best - pref):
						best = c
			x = maxf(x, f.y)
			if x > hi:
				break
		if best != INF:
			return Rect2(Vector2(best, y).round(), size)
		y -= TOUCH_FIT_STEP
		if not is_nan(fixed_x) and y < h - size.y - 200:
			return Rect2()  # nothing near the bottom at that x
	return _touch_pause_rect(hud, blocks, vw, h)


## Split layout drones placements (vertical touch column attached to the TARGET window), all tried by
## _touch_layout_split: "left_bottom" / "left_top" = right edge TOUCH_SPLIT_GAP left of the TARGET art, bottom / top
## level with the art's; "under" = right edge on the canvas edge between the TARGET art and the weapons box (the
## TARGET gives up that height); "by_weapons" = on the canvas bottom, right edge TOUCH_SPLIT_GAP left of the weapons.
const TOUCH_SPLIT_DRONE_MODES := ["left_bottom", "left_top", "under", "by_weapons"]


## Solid pieces of the detached subsystems in frame coordinates (what systems_bar.subsystem_bounds merges): the box,
## per subsystem its glyph + bars + manning icon (top bar − 24), its button.
func _touch_split_sub_pieces() -> Array[Rect2]:
	var sb := systems_bar
	var out: Array[Rect2] = [Rect2(HudLayout.SUBSYSTEM_BOX + Vector2(6, 6), Vector2(158 + 3 * sb.sub_spacing, 28))]
	for id in sb.sub_ids:
		var col: SystemPowerColumn = sb.columns.get(id)
		var sy := player_space.ship.sys(id)
		if col == null or sy == null:
			continue
		var top := col.loc.y + SystemPowerColumn.bar_y(sy, maxi(sy.get_level() - 1, 0)) - 24.0
		out.append(Rect2(col.loc.x + 19, top, 26, col.loc.y + 45 - top))
		if sb.buttons.has(id):
			var b: Control = sb.buttons[id]
			out.append(Rect2(b.position + Vector2(6, 19.0 if id == "battery" else 6.0), Vector2(28, 67)))
	return out


## Split layout (see _touch_split), third trial:
## - subsystems (+ the + / − toggle TOUCH_CREW_BOX_GAP left of them, bottoms level) at the HUD scale, right edge on
##   the canvas edge, as high as their solid pieces (_touch_split_sub_pieces + the toggle) allow: TOUCH_SPLIT_GAP
##   clear of the top buttons (up to the MENU wrench's solid right) and the hazard status — the bars right of the
##   wrench stand in the top row, whatever reaches left of it goes below the top buttons' level;
## - the weapons PC box on the canvas bottom, right edge on the canvas edge; the TARGET window (art right edge flush)
##   between the subsystems and the weapons, centred vertically as far as that allows: largest TOUCH_ENEMY_SCALES
##   step with art ≤ TOUCH_SPLIT_MAX_W of the width (then TOUCH_SPLIT_SMALL_TARGET), boxes at TOUCH_SPLIT_PANEL_SCALES;
## - the drones as the touch VERTICAL column (power row on top, slots stacked) at the box scale: every
##   TOUCH_SPLIT_DRONE_MODES placement is laid out and the one giving the turned player ship the largest scale wins
##   (then the larger TARGET, then the earlier mode);
## - top-left block, crew list, top buttons, systems bar as in `edges`; crew stations buttons (60 × 60) in the TARGET
##   corner; PAUSE / CANCEL by _touch_pause_rect; the ship by _touch_fit_ship_rot (hull art left of the TARGET art,
##   rooms clear of every HUD piece). No enemy: same places, TARGET hidden (stations by the toggle: not tuned).
func _touch_layout_split(sub_b: Rect2, sub_h: float, hud: Array[Rect2]) -> void:
	var vis := get_viewport().get_visible_rect().size
	var h := _touch_height()
	var k := TOUCH_SYSBAR_SCALE
	var g := TOUCH_SPLIT_GAP
	var t := TOUCH_TOPLEFT_SCALE
	var enemy := _touch_enemy_present()
	var art0 := TOUCH_ENEMY_ART
	var wp: Control = weapon_panel if weapon_panel != null and weapon_panel.visible else null
	var dp: Control = drone_panel if drone_panel != null and is_instance_valid(drone_panel) and drone_panel.visible \
		else null
	# Top buttons: the FTL drive (+ pull-out / CHARGING, the whole TOP_BUTTONS height) and SHIP + MENU (button art
	# y 22..77) up to the wrench's solid right (solid art x 7..47 of its 55 px button); the hazard status right of it.
	var menu := command_hud.menu_rect()
	var menu_r := (menu.position.x + 47.0) * t
	var tb := TOUCH_TOP_BUTTONS
	var tops: Array[Rect2] = [
		Rect2(Vector2(tb.position.x, 0) * t, Vector2(HudLayout.SHIP_BUTTON.x - tb.position.x, tb.end.y) * t),
		Rect2(Vector2(HudLayout.SHIP_BUTTON.x, 0) * t, Vector2(menu_r / t - HudLayout.SHIP_BUTTON.x, menu.end.y) * t)]
	var hz := _touch_split_alerts()  # hazard status + ENGINES CRITICAL under the JUMP button
	if hz.has_area():
		hud.append(hz)
		tops.append(hz)
	# Subsystems at ks = the HUD scale × TOUCH_SPLIT_SUB_RATIO: pieces relative to sa (sub_b's top-left), placed as high
	# as they stay TOUCH_SPLIT_SUB_TOP_GAP clear of `tops` (the pilot's manning icon just under the wrench).
	var ks := k * TOUCH_SPLIT_SUB_RATIO
	var sa := Vector2.ZERO
	var sub_rects: Array[Rect2] = []
	if sub_h > 0:
		var pieces: Array[Rect2] = []
		for r in _touch_split_sub_pieces():
			pieces.append(Rect2((r.position - sub_b.position) * ks, r.size * ks))
		pieces.append(Rect2(Vector2(-TOUCH_CREW_BOX_GAP - 28.0 * ks, (sub_b.size.y - CrewList.BOX_BODY_H + 6) * ks),
			Vector2(28, CrewList.BOX_BODY_H - 6) * ks))  # the toggle's solid art (x 6..34, y 6..57 of its image)
		var x0 := vis.x - sub_b.size.x * ks
		var y := 0.0
		var sg := TOUCH_SPLIT_SUB_TOP_GAP
		for p in pieces:
			y = maxf(y, -p.position.y)
			for o in tops:
				if x0 + p.position.x < o.end.x + sg and x0 + p.end.x > o.position.x - sg:
					y = maxf(y, o.end.y + sg - p.position.y)
		sa = Vector2(x0, y).round()
		for p in pieces:
			sub_rects.append(Rect2(sa + p.position, p.size))
	var tops2: Array[Rect2] = tops.duplicate()
	tops2.append_array(sub_rects)
	# Top of a piece spanning canvas x left..right placed at y or lower: under every top piece it would meet.
	var top_at := func(left: float, right: float, y: float) -> float:
		for r: Rect2 in tops2:
			if left < r.end.x + g and right > r.position.x - g:
				y = maxf(y, r.end.y + g)
		return y
	var build := func(s: float, c: float, mode: String) -> Dictionary:
		var aw := art0.size * s
		var art_min: float = top_at.call(vis.x - aw.x, vis.x, 0.0)
		var w_top := h
		var w_left := vis.x
		var t_floor := h  # the weapons piece under the TARGET: the holder top (the power bars stand further left)
		var pa := {}
		if wp != null:
			var u := _touch_split_unit(wp)
			w_top = h - u.size.y * c
			w_left = vis.x - u.size.x * c
			pa[wp] = Vector2(vis.x - u.end.x * c, w_top - u.position.y * c)
			t_floor = w_top
			var col: SystemPowerColumn = (wp as WeaponPanel).column
			if col != null and pa[wp].x + (_touch_split_col_off().x + col.hit_rect().end.x) * c < vis.x - aw.x - g:
				t_floor = (pa[wp] as Vector2).y
		var dv: Vector2 = (dp.get("v_size") as Vector2) * c if dp != null else Vector2.ZERO
		var floor_y := t_floor - g - (dv.y + g if dp != null and mode == "under" else 0.0)
		var art_max := floor_y - aw.y
		var art_top := clampf(roundf(h / 2 - aw.y / 2), art_min, maxf(art_max, art_min))
		var ok := art_max >= art_min
		if dp != null:
			var at := Vector2.ZERO
			match mode:
				"left_bottom":
					at = Vector2(vis.x - aw.x - g - dv.x, art_top + aw.y - dv.y)
				"left_top":
					at = Vector2(vis.x - aw.x - g - dv.x, art_top)
				"under":
					at = Vector2(vis.x - dv.x, art_top + aw.y + g)
				_:
					at = Vector2(w_left - g - dv.x, h - dv.y)
			pa[dp] = at
			ok = ok and at.x >= 0.0 and at.y + dv.y <= h + 0.01 \
				and at.y >= (top_at.call(at.x, at.x + dv.x, 0.0) as float) - 0.01
		return {"s": s, "c": c, "mode": mode, "art_top": art_top, "pa": pa, "ok": ok}
	var scales := TOUCH_ENEMY_SCALES.duplicate()
	scales.reverse()
	scales.append_array(TOUCH_SPLIT_SMALL_TARGET)  # only reached when nothing fits at ×1 (large --hud-scale)
	var best := {}
	var frozen := _touch_split_frozen()
	if frozen:
		best = _touch_split_frozen_layout(sub_b, ks, hud, wp, dp)
		sa = best.sa
	for mode: String in ([] if frozen else (TOUCH_SPLIT_DRONE_MODES if dp != null else ["none"])):
		var res := {}
		for sv: float in scales:
			if art0.size.x * sv > vis.x * TOUCH_SPLIT_MAX_W + 0.01 and sv > 1.0:
				continue
			for cv: float in TOUCH_SPLIT_PANEL_SCALES:
				var r: Dictionary = build.call(sv, cv, mode)
				if r.ok:
					res = r
					break
			if not res.is_empty():
				break
		if res.is_empty():
			continue
		# TARGET grown in sixteenths past its step while it still fits (its bottom then reaches the weapons row; a
		# 1/16 scale repeats nearest-filtered rows / columns in a regular 16-px pattern).
		while true:
			var nxt := floorf(float(res.s) * 16.0 + 1.0001) / 16.0
			if art0.size.x * nxt > vis.x * TOUCH_SPLIT_MAX_W + 0.01:
				break
			var r2: Dictionary = build.call(nxt, res.c, mode)
			if not r2.ok:
				break
			res = r2
		# Blocks, PAUSE and the ship for this placement.
		var s: float = res.s
		var c: float = res.c
		var aw: Vector2 = art0.size * s
		var art := Rect2(Vector2(roundf(vis.x - aw.x), roundf(res.art_top)), aw)
		var blocks: Array[Rect2] = sub_rects.duplicate()
		if enemy:
			blocks.append(art)
		var pa := {}
		for p: Control in res.pa:
			var at: Vector2 = (res.pa[p] as Vector2).round()
			pa[p] = at
			var u := _touch_split_unit(p)
			blocks.append(Rect2(at + u.position * c, u.size * c))
		var wbr := -INF  # canvas right of the weapons power column's bars (PC panel child, hit_rect x 16..48)
		if wp != null and (wp as WeaponPanel).column != null:
			wbr = (pa[wp] as Vector2).x + (_touch_split_col_off().x + (wp as WeaponPanel).column.hit_rect().end.x) * c
		# PAUSE candidates (_touch_split_pause): the lowest spot nearest the gap after the systems bar, and the lowest
		# spot right of the weapons power bars; the one leaving the bigger ship wins, then the lower one.
		var pr := Rect2()
		var fit := {}
		var z := -1.0
		for px: float in [NAN, wbr + TOUCH_SPLIT_GAP]:
			if not is_nan(px) and not is_finite(px):
				continue
			var pr1 := _touch_split_pause(hud, blocks, h, px)
			if not pr1.has_area():
				continue
			var obst: Array[Rect2] = hud.duplicate()
			obst.append(pr1)
			obst.append_array(blocks)
			var fit1 := _touch_fit_ship_rot(art.position.x - g, h, obst)
			var z1: float = fit1.get("zoom", 0.0)
			if z1 > z + 0.001 or (absf(z1 - z) <= 0.001 and pr1.end.y > pr.end.y + 0.5):
				pr = pr1
				fit = fit1
				z = z1
		print("touch layout (split): drones %s -> TARGET ×%.3f, ship ×%.3f" % [mode, s, z])
		# A TARGET of ×1 or more beats any smaller one; then the bigger ship, then the bigger TARGET.
		var big := s >= 0.999
		var best_big: bool = not best.is_empty() and best.s >= 0.999
		if best.is_empty() or (big and not best_big) or (big == best_big and (z > best.z + 0.001
				or (absf(z - best.z) <= 0.001 and s > best.s + 0.001))):
			best = {"z": z, "s": s, "c": c, "mode": mode, "art": art, "pa": pa, "blocks": blocks, "pause": pr, "fit": fit}
	if best.is_empty():  # nothing fits: the first mode at ×1 anyway
		var r: Dictionary = build.call(1.0, TOUCH_SPLIT_PANEL_SCALES.back(), TOUCH_SPLIT_DRONE_MODES[0])
		var aw1: Vector2 = art0.size
		var pa1 := {}
		for p: Control in r.pa:
			pa1[p] = (r.pa[p] as Vector2).round()
		best = {"z": 0.0, "s": 1.0, "c": r.c, "mode": r.mode, "art": Rect2(Vector2(vis.x - aw1.x, r.art_top), aw1),
			"pa": pa1, "blocks": sub_rects, "pause": _touch_pause_rect(hud, sub_rects, vis.x, h), "fit": {}}
	var s: float = best.s
	var c: float = best.c
	var art: Rect2 = best.art
	var xf := Transform2D(0.0, Vector2(s, s), 0.0, art.position - art0.position * s - HudLayout.ENEMY_FRAME.position * s)
	_place_touch_enemy(xf)
	_touch_pause_at = best.pause  # (ENGINES CRITICAL: placed by _touch_split_alerts)
	player_space.fixed_rotation = PI / 2
	_touch_apply(xf, [], c, [], sub_b, sub_h, sa, best.fit)
	var pivot := Vector2(0, HudLayout.FRAME.y)
	if sub_h > 0:
		# Subsystems at ks (sub_group ×ks/k inside the ×k bar): sub_b's top-left on sa; the toggle left of them.
		var q := ks / k
		systems_bar.sub_group.scale = Vector2(q, q)
		systems_bar.sub_group.position = (sa - systems_bar.position - pivot) / k + pivot - sub_b.position * q
		if touch_power != null:
			touch_power.scale = Vector2(ks, ks)
			touch_power.position = Vector2(sa.x - TOUCH_CREW_BOX_GAP - 34.0 * ks,
				sa.y + sub_b.size.y * ks - CrewList.BOX_BODY_H * ks).round()
			if frozen:
				touch_power.position = Vector2(vis.x, 0) + TOUCH_SPLIT_FROZEN.toggle
	# The weapons PC box and the vertical drones column (after _touch_apply, which places only `stack` columns).
	for p: Control in best.pa:
		p.scale = Vector2(c, c)
		p.position = best.pa[p]
	print("touch layout (split): drones %s, TARGET ×%.3f art %s, boxes ×%.3f at %s, subsystems ×%.3f at %s, ship ×%.3f (turned) origin %s" % [
		best.mode, s, art, c, best.pa.values(), ks, sa, best.fit.get("zoom", 1.0), best.fit.get("origin")])
	print("touch layout (split): %s, pause %s" % ["FROZEN (split5 slots)" if frozen else "fitted", best.pause])


## Frozen split layout (`--fold-layout=split --hud-scale=1.5` on the open Fold, canvas 1280 × ~1099: the user-approved
## fifth trial, measured on TEST_SHIP_MAX = every vanilla maximum, + the TARGET grown to 21/16). Every HUD piece
## keeps the slot it has there whatever the ship carries (fewer subsystems / weapons / drones leave their slot
## partly empty); only the player ship is fitted to its own hull (_touch_fit_ship_rot, rooms clear of the RESERVED
## slots). x of right-hand pieces from the canvas's right edge (vis.x + x), y of bottom pieces from its bottom.
const TOUCH_SPLIT_FROZEN := {
	"sub_origin": Vector2(-1510, -633.25),  # canvas of subsystem frame (0, 0) (sub_group at ×1.25), x from the right
	"toggle": Vector2(-269, 172),  # + / − toggle image top-left, x from the right
	"target_s": 21.0 / 16.0,
	"target": Vector2(-509, 249),  # TARGET art top-left, x from the right (art 509 × 705)
	"weapons": Vector2(-628, -138),  # PC weapons panel (holder) top-left, from the right / bottom
	"drones": Vector2(-667, 249),  # vertical drones column top-left, x from the right (left of the TARGET)
	"pause": Rect2(548, -326, 147, 168),  # stacked PAUSE + CANCEL, y from the bottom
	"slots": [Rect2(-262, 118, 262, 125),  # reserved: subsystems + toggle,
		Rect2(-652, -156, 652, 156),  # weapons row (4 slots, level-8 power bars), from the right / bottom
		Rect2(-667, 249, 152, 228)],  # drones column (3 slots), x from the right
	"boxes": 1.5,
}


func _touch_split_frozen() -> bool:
	if not _touch_split() or absf(TOUCH_SYSBAR_SCALE - 1.5) > 0.01:
		return false
	var vis := get_viewport().get_visible_rect().size
	return absf(vis.x - 1280.0) < 1.0 and absf(vis.y - 1099.0) <= 8.0


## The frozen split layout as a _touch_layout_split `best`: TARGET, panels, PAUSE, reserved blocks and the ship fit.
func _touch_split_frozen_layout(sub_b: Rect2, ks: float, hud: Array[Rect2], wp: Control, dp: Control) -> Dictionary:
	var vis := get_viewport().get_visible_rect().size
	var h := _touch_height()
	var f := TOUCH_SPLIT_FROZEN
	var right := Vector2(vis.x, 0)
	var s: float = f.target_s
	var aw := TOUCH_ENEMY_ART.size * s
	var art := Rect2(right + (f.target as Vector2), aw)
	var pa := {}
	if wp != null:
		pa[wp] = Vector2(vis.x, h) + (f.weapons as Vector2)
	if dp != null:
		pa[dp] = right + (f.drones as Vector2)
	var blocks: Array[Rect2] = []
	var sl: Array = f.slots
	blocks.append(Rect2(right + (sl[0] as Rect2).position, (sl[0] as Rect2).size))
	blocks.append(Rect2(Vector2(vis.x, h) + (sl[1] as Rect2).position, (sl[1] as Rect2).size))
	blocks.append(Rect2(right + (sl[2] as Rect2).position, (sl[2] as Rect2).size))
	if _touch_enemy_present():
		blocks.append(art)
	var pr := Rect2(Vector2((f.pause as Rect2).position.x, h + (f.pause as Rect2).position.y), (f.pause as Rect2).size)
	var obst: Array[Rect2] = hud.duplicate()
	obst.append(pr)
	obst.append_array(blocks)
	var fit := _touch_fit_ship_rot(art.position.x - TOUCH_SPLIT_GAP, h, obst)
	var sa := (right + (f.sub_origin as Vector2) + sub_b.position * ks).round()
	return {"z": fit.get("zoom", 0.0), "s": s, "c": f.boxes, "mode": "frozen", "art": art, "pa": pa,
		"blocks": blocks, "pause": pr, "fit": fit, "sa": sa}


## Split layout: the player ship turned to face up (camera PI / 2: world +x -> canvas up, world +y -> canvas right).
## Largest TOUCH_SHIP_SCALES step at which the turned opaque hull art fits left of `right_limit` and inside the
## canvas height with its rooms (+ TOUCH_ROOM_WALL) clear of every rect in `obst`; among the valid positions (hull
## top every TOUCH_FIT_STEP px, exact x intervals) the one whose rooms centre is nearest (right_limit / 2, h / 2)
## wins. {origin (the turned view's fixed_origin), zoom} or {} when nothing fits.
func _touch_fit_ship_rot(right_limit: float, h: float, obst: Array[Rect2]) -> Dictionary:
	var rows := _touch_hull_rows()
	var hp := _touch_hull_pos()
	var sh := player_space.ship
	var lmin := INF
	var rmax := -INF
	var rfirst := -1
	var rlast := -1
	for i in rows.size():
		var r: Vector2i = rows[i]
		if r.x >= 0:
			lmin = minf(lmin, r.x)
			rmax = maxf(rmax, r.y + 1)
			if rfirst < 0:
				rfirst = i
			rlast = i
	if rfirst < 0:
		return {}
	# Hull image px (u, v) -> canvas P + (v, rmax − u)·z, P = top-left of the turned art's box (u = rmax at its top).
	var rooms: Array[Rect2] = []
	var rb := Rect2()
	for room in sh.layout.rooms:
		var rr := sh.room_rect(room.id).grow(TOUCH_ROOM_WALL)
		rr.position -= hp
		var t := Rect2(rr.position.y, rmax - rr.end.x, rr.size.y, rr.size.x)
		rooms.append(t)
		rb = t if rooms.size() == 1 else rb.merge(t)
	var aim := Vector2(right_limit / 2, h / 2)
	for zv in TOUCH_SHIP_SCALES:
		var z: float = zv
		var x0 := -rfirst * z
		var x1 := right_limit - (rlast + 1) * z
		var y1 := h - (rmax - lmin) * z
		if x1 < x0 or y1 < 0:
			continue
		var want := aim.x - rb.get_center().x * z
		var best := Vector2.INF
		var bd := INF
		var py := 0.0
		while py <= y1 + 0.01:
			var forbid := []
			for t in rooms:
				var ry0 := py + t.position.y * z
				var ry1 := py + t.end.y * z
				for o in obst:
					if ry1 > o.position.y and ry0 < o.end.y:
						forbid.append(Vector2(o.position.x - t.end.x * z, o.end.x - t.position.x * z))
			forbid.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
			var segs := []
			var x := x0
			for f: Vector2 in forbid:
				if f.y <= x:
					continue
				if f.x > x:
					segs.append(Vector2(x, minf(f.x, x1)))
				x = maxf(x, f.y)
				if x > x1:
					break
			if x <= x1:
				segs.append(Vector2(x, x1))
			for sg: Vector2 in segs:
				if sg.y < sg.x:
					continue
				# Leftmost hull position first (TOUCH_SPLIT_SHIP_LEFT), rooms centre nearest the area's vertical middle
				# among equally-left ones; else (old rule) rooms centre nearest `aim`.
				var p := Vector2(sg.x if TOUCH_SPLIT_SHIP_LEFT else clampf(want, sg.x, sg.y), py)
				var d := (p + rb.get_center() * z).distance_squared_to(aim)
				if TOUCH_SPLIT_SHIP_LEFT:
					d = roundf(p.x) * 1e6 + absf(p.y + rb.get_center().y * z - aim.y)
				if d < bd:
					bd = d
					best = p
			py += TOUCH_FIT_STEP
		if best != Vector2.INF:
			return {"origin": (best + Vector2(-hp.y, rmax + hp.x) * z).floor(), "zoom": z}
	return {}


## Canvas top-left of the crew buttons box image (button_door_base.png at TOUCH_SYSBAR_SCALE) for subsystems
## whose solid bounds `sub_b` (frame px) are drawn from canvas `sub_at`: its solid right edge TOUCH_CREW_BOX_GAP
## left of them, its top level with the doors button's (else with the subsystems' solid top).
func _touch_crew_box(sub_at: Vector2, sub_b: Rect2) -> Vector2:
	var k := TOUCH_SYSBAR_SCALE
	var door: Control = systems_bar.buttons.get("doors")
	var y := sub_at.y + ((door.position.y - sub_b.position.y) * k if door != null else -6.0 * k)
	return Vector2(sub_at.x - TOUCH_CREW_BOX_GAP - 34.0 * k, y).round()


## Canvas top-left of the power toggle (+ / −) when the crew buttons are in the TARGET corner: in the crew box's
## spot left of the subsystems, its solid bottom (art row BOX_BODY_H) level with the subsystems' solid bottom.
func _touch_toggle_at(sub_at: Vector2, sub_b: Rect2) -> Vector2:
	var k := TOUCH_SYSBAR_SCALE
	return Vector2(_touch_crew_box(sub_at, sub_b).x, sub_at.y + sub_b.size.y * k - CrewList.BOX_BODY_H * k).round()


## The crew save / return stations buttons, enlarged (the 20×20 art ×3 = TOUCH_STATION_SIZE, nearest) in the
## TARGET window's bottom-right corner (`xf` = touch_enemy_transform), right of the enemy system icons row:
## side by side, TOUCH_STATION_PAD inside the frame art's bottom-right, TOUCH_STATION_GAP apart, when they clear
## the icons (last box location + 45 = its glyph's right edge); else stacked at the right edge above the icons
## and their power bars (8 px per level + 24). Canvas rects [save, return].
func _touch_station_rects(xf: Transform2D) -> Array:
	var f := HudLayout.ENEMY_FRAME.position
	var b := TOUCH_STATION_SIZE
	var g := TOUCH_STATION_GAP
	var art_br := xf * (f + TOUCH_ENEMY_ART.end)
	var right := art_br.x - TOUCH_STATION_PAD
	var bottom := art_br.y - TOUCH_STATION_PAD
	var boxes: Array = enemy_window.system_boxes() if enemy_window != null else []
	var icons_r := -INF
	var lvl := 0
	for e in boxes:
		icons_r = maxf(icons_r, (xf * (e[1] as Vector2 + Vector2(45, 0))).x)
		var sy := enemy_space.ship.sys(e[0])
		lvl = maxi(lvl, sy.get_level() if sy else 0)
	if right - (2 * b + g) >= icons_r + g:
		return [Rect2(right - 2 * b - g, bottom - b, b, b), Rect2(right - b, bottom - b, b, b)]
	if right - b >= icons_r + g:
		return [Rect2(right - b, bottom - 2 * b - g, b, b), Rect2(right - b, bottom - b, b, b)]
	var icons_top := (xf * Vector2(0, HudLayout.ENEMY_SYSTEMS.y - HudLayout.POWER_PITCH * lvl - 24.0)).y - g
	return [Rect2(right - b, icons_top - 2 * b - g, b, b), Rect2(right - b, icons_top - b, b, b)]


## No enemy (no TARGET window): the big stations buttons side by side left of the + / − toggle whose image is at
## `toggle_at` (canvas): their right edge TOUCH_STATION_GAP left of the toggle's solid art (x 6), their bottom
## level with its solid bottom (art row BOX_BODY_H). Canvas rects [save, return].
func _touch_station_rects_by_toggle(toggle_at: Vector2) -> Array:
	var k := TOUCH_SYSBAR_SCALE
	var b := TOUCH_STATION_SIZE
	var right := toggle_at.x + 6 * k - TOUCH_STATION_GAP
	var bottom := toggle_at.y + CrewList.BOX_BODY_H * k
	return [Rect2(right - 2 * b - TOUCH_STATION_GAP, bottom - b, b, b), Rect2(right - b, bottom - b, b, b)]


## Touch UI: the hazard status (HazardHud: DANGER! icon(s) + text, PC at (655..725 / 797, 72..145)) moved off the
## ×1.2 JUMP button. First choice: right of the MENU wrench's solid art (+2 px), top level with the top buttons,
## at TOUCH_TOPLEFT_SCALE; it must end 2 px before `col_left` (the weapons column at its widest). Else under the
## SHIP + MENU buttons (2 px below their solid bottom, y 77 × 1.2), right edge on the wrench's, left of the FTL
## pull-out (x 610 × 1.2), at ×1.2 or ×1 (the storm's two icons). Its tooltip hit boxes follow (status_xf).
## Returns its canvas rect (empty without a hazard). Phone: there are only ~30 px between the wrench and the
## column, so it goes under SHIP / MENU.
func _touch_hazard(col_left: float) -> Rect2:
	if hazard_hud == null or run == null or run.hazard == null:
		return Rect2()
	var t := TOUCH_TOPLEFT_SCALE
	var b := HazardHud.status_bounds(hazard_hud.two_icons())
	var menu_r := (command_hud.menu_rect().position.x + 47.0) * t  # wrench solid art x 7..47
	var at := Vector2.ZERO
	var s := t
	if menu_r + 2 + b.size.x * t <= col_left - 2:
		at = Vector2(menu_r + 2, HudLayout.MENU_BUTTON.y * t)
	else:
		var pull_r := (HudLayout.FTL_PULLOUT.x + 75.0) * t + 2
		if menu_r - b.size.x * s < pull_r:
			s = 1.0
		at = Vector2(menu_r - b.size.x * s, (HudLayout.SHIP_BUTTON.y + 55.0) * t + 2)
	at = at.round()
	hazard_hud.status_xf = Transform2D(0.0, Vector2(s, s), 0.0, at - b.position * s)
	return Rect2(at, b.size * s)


## Touch UI top-left block ×TOUCH_TOPLEFT_SCALE about the frame origin: ship status (hull, shields, resources,
## scrap), the crew list and the top buttons (FTL drive / SHIP / MENU: the back CommandHud). The evade / O2 box
## continues the shields + resources row (TOUCH_EVADE_OFFSET) and the crew list moves up into the freed space
## (TOUCH_CREW_SHIFT_Y). At ×1.2 the MENU wrench's solid right edge is at 749 × 1.2 = 899 (left of the column).
func _touch_top_left() -> void:
	var t := TOUCH_TOPLEFT_SCALE
	ship_status.scale = Vector2(t, t)
	ship_status.evade_offset = TOUCH_EVADE_OFFSET
	crew_list.scale = Vector2(t, t)
	crew_list.position = Vector2(0, TOUCH_CREW_SHIFT_Y * t)
	command_hud.scale = Vector2(t, t)


## Opaque extent of each hull image row (alpha > 0.1): [Vector2i(leftmost x, rightmost x)], (-1, -1) for an
## empty row. Cached per hull texture. No hull image: one full-width row per px of the rooms box.
func _touch_hull_rows() -> Array[Vector2i]:
	var tex: Texture2D = player_space.view.hull_tex
	if tex != null and tex == _hull_rows_for and not _hull_rows.is_empty():
		return _hull_rows
	_hull_rows_for = tex
	_hull_rows = []
	var im := tex.get_image() if tex != null else null
	if im != null and im.is_compressed():
		im.decompress()
	if im == null:
		var b := player_space.ship.rooms_bounds()
		for y in int(b.size.y):
			_hull_rows.append(Vector2i(0, int(b.size.x) - 1))
		return _hull_rows
	var w := im.get_width()
	for y in im.get_height():
		var l := 0
		while l < w and im.get_pixel(l, y).a <= 0.1:
			l += 1
		if l == w:
			_hull_rows.append(Vector2i(-1, -1))
			continue
		var r := w - 1
		while im.get_pixel(r, y).a <= 0.1:
			r -= 1
		_hull_rows.append(Vector2i(l, r))
	return _hull_rows


## World point of the hull image's top-left (the rooms box when there is no hull image).
func _touch_hull_pos() -> Vector2:
	var tex: Texture2D = player_space.view.hull_tex
	return player_space.ship.hull_position() if tex != null else player_space.ship.rooms_bounds().position


## Canvas rects of the touch HUD (besides the column / subsystems blocks of `_touch_layout`) that the player
## ship's rooms must stay clear of, from the solid art (alpha > 0.5) of each piece:
## - top-left block ×TOUCH_TOPLEFT_SCALE: hull bar + label (0,0)-(375,46), shields (7,50,121,38) incl. the
##   energy-shield box (30,77,98,12), resources (132,50,193,26), scrap (383,11,122,35), evade / O2 box (frame
##   EVADE solid + TOUCH_EVADE_OFFSET);
## - the crew list boxes (×TOUCH_TOPLEFT_SCALE, shifted up), the top buttons (CommandHud.TOP_BUTTONS ×1.2);
## - (PAUSE / CANCEL are placed by _touch_pause_rect and added per layout attempt);
## - the systems bar ×TOUCH_SYSBAR_SCALE about the frame's bottom-left: every bar system's box (symbol .. 24 px
##   above its top bar; 90 px wide with a cooldown button), the reactor column + wire (90 px wide from its top bar)
##   and the bottom wire line.
func _touch_hud_rects(h: float) -> Array[Rect2]:
	var t := TOUCH_TOPLEFT_SCALE
	var out: Array[Rect2] = []
	for r in [Rect2(0, 0, 375, 46), Rect2(7, 50, 121, 39), Rect2(132, 50, 193, 26), Rect2(383, 11, 122, 35),
			Rect2(Vector2(8, 96) + TOUCH_EVADE_OFFSET, Vector2(90, 42)), CommandHud.TOP_BUTTONS]:
		out.append(Rect2(r.position * t, r.size * t))
	var n := crew_control.roster.size()
	if n > 0:
		var cr := crew_control.box_rect(0).merge(crew_control.box_rect(n - 1))
		out.append(Rect2(Vector2(0, TOUCH_CREW_SHIFT_Y * t) + cr.position * t, cr.size * t))
	var k := TOUCH_SYSBAR_SCALE
	var pivot := Vector2(0, HudLayout.FRAME.y)
	var sh := player_space.ship
	var frame_rects: Array[Rect2] = []
	var right := 90.0
	for id in systems_bar.main_ids:
		var sy := sh.sys(id)
		var x: float = systems_bar.box_x[id]
		var top := HudLayout.SYSTEM_BOX_Y - HudLayout.POWER_PITCH * (sy.get_level() if sy else 1) - 24.0
		var w := 90.0 if SystemsBar.WIDE_BOXES.has(id) else 64.0
		frame_rects.append(Rect2(x, top, w, HudLayout.FRAME.y - top))
		right = maxf(right, x + w)
	var rc := systems_bar.reactor.counts().x if systems_bar.reactor else sh.reactor_max
	var rtop := ReactorColumn.top_y(rc) - 4.0
	frame_rects.append(Rect2(0, rtop, 90, HudLayout.FRAME.y - rtop))
	frame_rects.append(Rect2(0, HudLayout.FRAME.y - 30, right, 30))
	var dy := Vector2(0, _touch_sysbar_dy())  # tall canvas: the bar sits on the canvas bottom
	for r in frame_rects:
		out.append(Rect2((r.position - pivot) * k + pivot + dy, r.size * k))
	return out


## PAUSE + CANCEL pair (TouchCombatButtons: two FTL bases ×TOUCH_TOPLEFT_SCALE, CANCEL right of PAUSE) as one
## canvas rect: the first free spot, scanning up from the layout bottom (TOUCH_FIT_STEP rows) and, per row, the x
## nearest the PC-derived place (PAUSE left of the FTL drive's x, CANCEL under it), clear of every HUD rect and
## column / subsystems / crew-box block by TOUCH_PAUSE_GAP and left of `right_limit` (the TARGET art). Never on
## top of another button: the toggle's hit box can't be covered.
func _touch_pause_rect(hud: Array[Rect2], blocks: Array[Rect2], right_limit: float, h: float) -> Rect2:
	var t := TOUCH_TOPLEFT_SCALE
	var bs := TouchCombatButtons.BASE_SIZE * t
	var size := Vector2(2 * bs.x + TouchCombatButtons.GAP * t, bs.y)
	var pref := HudLayout.FTL_BASE.x * t - (TouchCombatButtons.BASE_SIZE.x + TouchCombatButtons.GAP) * t
	var obst: Array[Rect2] = []
	for r in hud + blocks:
		obst.append(r.grow(TOUCH_PAUSE_GAP))
	var y := h - size.y
	while y >= 0.0:
		var forbid := []
		for o in obst:
			if o.end.y > y and o.position.y < y + size.y:
				forbid.append(Vector2(o.position.x - size.x, o.end.x))
		forbid.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
		var best := INF
		var x := 0.0
		var hi := right_limit - TOUCH_PAUSE_GAP - size.x
		for f: Vector2 in forbid + [Vector2(INF, INF)]:
			var x1 := minf(f.x, hi)
			if x1 >= x:
				var c := clampf(pref, x, x1)
				if best == INF or absf(c - pref) < absf(best - pref):
					best = c
			x = maxf(x, f.y)
			if x > hi:
				break
		if best != INF:
			return Rect2(Vector2(best, y).round(), size)
		y -= TOUCH_FIT_STEP
	return Rect2(Vector2(pref, h - size.y), size)  # nowhere free: the old place


## Player ship fit, largest TOUCH_SHIP_SCALES step first. At a step z the hull image must fit between the left
## canvas edge (its leftmost opaque px: the engines) and, row by row, the left edge of the column blocks drawn at
## that height (`blocks`) or `right_limit` (the TARGET art / canvas edge) where there is none; the hull art may
## overlap the HUD, but the ROOMS (each room rect grown by TOUCH_ROOM_WALL for the walls) must stay clear of
## every HUD rect (`hud`) and block and inside the layout height. All valid hull positions are scanned
## (TOUCH_FIT_STEP rows of the hull top, exact forbidden x intervals per row); the one whose rooms centre is
## nearest the centroid of all valid rooms centres wins (rooms centred in the free area). `zmax` caps the step;
## `inside` (no-enemy layout) also keeps every opaque hull row inside the layout height (left / right are the
## engines / nose limits above). {} = no step fits; else {origin (fixed_origin), zoom}.
func _touch_fit_ship(blocks: Array[Rect2], right_limit: float, h: float, hud: Array[Rect2], zmax := INF,
		inside := false) -> Dictionary:
	var rows := _touch_hull_rows()
	var hp := _touch_hull_pos()
	var sh := player_space.ship
	var n := rows.size()
	var lmin := INF
	var rmax := -INF
	var rfirst := -1  # first / last opaque hull row
	var rlast := -1
	for i in n:
		var r: Vector2i = rows[i]
		if r.x >= 0:
			lmin = minf(lmin, r.x)
			rmax = maxf(rmax, r.y + 1)
			if rfirst < 0:
				rfirst = i
			rlast = i
	if n == 0 or lmin == INF:
		return {}
	var obst: Array[Rect2] = hud.duplicate()
	obst.append_array(blocks)
	# Rooms relative to the hull image top-left (world px), grown for the walls.
	var rooms: Array[Rect2] = []
	var rb := Rect2()
	for r in sh.layout.rooms:
		var rr := sh.room_rect(r.id).grow(TOUCH_ROOM_WALL)
		rr.position -= hp
		rooms.append(rr)
		rb = rr if rooms.size() == 1 else rb.merge(rr)
	for zv in TOUCH_SHIP_SCALES:
		var z: float = zv
		if z > zmax + 0.0001 or (rmax - lmin) * z > right_limit or rb.size.y * z > h:
			continue
		var segs := []  # [py, x0, x1]: valid hull top-left x intervals at hull top y py
		var py := -rb.position.y * z  # rooms top at 0
		var py_end := h - rb.end.y * z  # rooms bottom at h
		if inside:
			py = maxf(py, -rfirst * z)  # hull art top at 0 at the highest
			py_end = minf(py_end, h - (rlast + 1) * z)
			py = ceilf(py)
		while py <= py_end + 0.01:
			var xmax := INF
			for i in n:
				var r: Vector2i = rows[i]
				if r.x < 0:
					continue
				var y0: float = py + i * z
				var lim := right_limit
				for b in blocks:
					if y0 + z > b.position.y and y0 < b.end.y:
						lim = minf(lim, b.position.x)
				xmax = minf(xmax, lim - (r.y + 1) * z)
			var xmin := -lmin * z
			if xmax >= xmin:
				var forbid := []  # open intervals of hull x where a room meets an obstacle
				for rr in rooms:
					var ry0 := py + rr.position.y * z
					var ry1 := py + rr.end.y * z
					for o in obst:
						if ry1 > o.position.y and ry0 < o.end.y:
							forbid.append(Vector2(o.position.x - rr.end.x * z, o.end.x - rr.position.x * z))
				forbid.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
				var x := xmin
				for f: Vector2 in forbid:
					if f.y <= x:
						continue
					if f.x > x:
						segs.append([py, x, minf(f.x, xmax)])
					x = maxf(x, f.y)
					if x > xmax:
						break
				if x <= xmax:
					segs.append([py, x, xmax])
			py += TOUCH_FIT_STEP
		var valid := segs.filter(func(s) -> bool: return s[2] >= s[1])
		if valid.is_empty():
			continue
		# Centroid of the valid positions (length-weighted segments; a point counts as 1 px).
		var cen := Vector2.ZERO
		var wsum := 0.0
		for s in valid:
			var w := maxf(s[2] - s[1], 1.0)
			cen += Vector2((s[1] + s[2]) / 2, s[0]) * w
			wsum += w
		cen /= wsum
		var best := Vector2.INF
		for s in valid:
			var p := Vector2(clampf(cen.x, s[1], s[2]), s[0])
			if best == Vector2.INF or p.distance_squared_to(cen) < best.distance_squared_to(cen):
				best = p
		return {"origin": (Vector2(floorf(best.x), roundf(best.y)) - hp * z).floor(), "zoom": z}
	return {}


## Touch UI: applies the TARGET transform to the window layers and the enemy space (camera zoom = scale).
func _place_touch_enemy(xf: Transform2D) -> void:
	var s := xf.get_scale().x
	for w in [enemy_window, enemy_window_back]:
		# Explicit frame size: the back layer can end up 0 × 0, and a moved 0-size Control is culled (not drawn).
		w.size = HudLayout.FRAME
		w.position = xf.origin
		w.scale = Vector2(s, s)
	var view_pos := (xf * ENEMY_VIEW.position).round()
	enemy_space.position = view_pos
	enemy_space.size = (ENEMY_VIEW.size * s).round()
	enemy_space.set_fixed_origin(xf * enemy_origin() - view_pos, s)


## Window resized (device / fold change): the touch TARGET window follows the visible canvas width.
## Touch UI (wide / tall screens): the 1280×720 windows (event box, maps, store, ship screen, run end, Esc menu,
## options) keep their FTL layout, centred in the visible canvas (HudLayout.frame_offset); they hit-test in local
## coordinates, so moving them is enough. The combat HUD keeps its own touch layout (`_touch_layout`); the focus
## tint covers the whole canvas. EndBox centres itself on open. PC: never called.
func _touch_center_windows() -> void:
	# Per window: its own CanvasLayer's offset is taken out (the HUD band moves hud_root's layer; the Esc menu and
	# options live on debug_layer, which has none).
	for w in [event_box, star_map_view, sector_map_view, store_view, ship_screen, run_end_box, pause_menu,
			vanilla_options, options]:
		if w != null and is_instance_valid(w) and (w as Control).is_inside_tree():
			(w as Control).position = HudLayout.frame_offset(w, true)
	if end_box != null and end_box.visible:
		end_box.position = HudLayout.frame_offset(end_box, true)
	if focus_dim != null:
		var r := HudLayout.cover_rect(focus_dim.get_parent() as CanvasItem, true)
		focus_dim.position = r.position
		focus_dim.size = r.size


func _on_viewport_resized() -> void:
	if input_mode == InputProfile.TOUCH and not single_view and enemy_space != null:
		_touch_layout()


func _apply_view() -> void:
	btn_view.text = "View: one at a time" if single_view else "View: side by side"
	btn_me.visible = single_view
	btn_enemy.visible = single_view
	var enemy_shown := has_enemy and not victory_shown
	enemy_window.visible = not single_view and enemy_shown
	enemy_window_back.visible = not single_view and enemy_shown
	enemy_space.legacy_hud = single_view
	if not single_view:  # FTL layout
		player_space.visible = true
		enemy_space.visible = enemy_shown
		player_space.position = Vector2.ZERO
		player_space.size = HudLayout.FRAME
		player_space.set_fixed_origin(player_origin())
		# Vanilla stencil: the enemy ship (bubble included) only shows inside box_hostiles_mask.png (Space.CLIP_SHADER).
		enemy_space.set_clip_mask(FtlData.texture(ENEMY_MASK),
			Rect2(ENEMY_VIEW.position - HudLayout.ENEMY_FRAME.position, ENEMY_VIEW.size))
		if input_mode == InputProfile.TOUCH:
			_touch_layout()
			return
		enemy_space.position = ENEMY_VIEW.position
		enemy_space.size = ENEMY_VIEW.size
		enemy_space.set_fixed_origin(enemy_origin() - ENEMY_VIEW.position)
		return
	player_space.visible = not showing_enemy or not enemy_shown
	enemy_space.visible = showing_enemy and enemy_shown
	enemy_space.set_clip_mask(null)
	for sp in [player_space, enemy_space]:
		sp.position = SINGLE_VIEW.position
		sp.size = SINGLE_VIEW.size
		sp.set_fixed_origin(null)


## Run results screen → NEW RUN: a fresh run (new seed) and the scene reloaded.
func _restart_run() -> void:
	RunState.current = null
	_run_seed_override = true
	FrameHost.reload_scene(get_tree())


## Game over window commands (CApp::OnLoop, rules/score_and_game_over.md §5): RESTART = a new run with the same
## hangar setup (new seed), HANGAR / MAIN MENU = the title scene, QUIT = quit.
func _on_run_end_command(c: String) -> void:
	match c:
		"restart":
			_restart_run()
		"hangar", "mainmenu":
			_on_menu_command(c)
		"quit":
			get_tree().quit()


static var _run_seed_override := false  # after NEW RUN the --seed flag no longer applies


func _restart() -> void:
	if run_mode and game_over_shown:
		RunState.current = null  # game over: a new run
	FrameHost.reload_scene(get_tree())


## End of the fight (rules/ship_destruction.md §6, §7). Game over (CommandGui::CheckGameover): no player crew
## left (gameover_crew) first, else the player ship's explosion is over (gameover_blowup). Victory
## (ShipAI::Destroyed): the enemy's explosion is over -> enemy ship and window removed (ClearLocation), the
## `destroyed` event box opens.
func _check_end() -> void:
	var me := player_space.ship
	var e := enemy_space.ship
	if not game_over_shown:
		var text_id := ScoreKeeper.game_over_cause(not _player_crew_left(), me.destroyed_done())
		if text_id != "" and not LastStand.already_won(run):  # CommandGui alreadyWon (flagship dying / dead)
			game_over_shown = true
			if run != null:
				run.game_over(text_id)  # run results screen (RunEndBox)
			else:
				end_box.open(EndBox.Mode.GAME_OVER, text_id)
			print("GAME OVER: ", text_id)
			return
	if not victory_shown and not game_over_shown and e.destroyed_done():
		victory_shown = true
		enemy_space.visible = false
		enemy_window.visible = false
		enemy_window_back.visible = false
		if not single_view:  # CommandGui::ClearLocation: the player ship snaps back to x 350
			if input_mode == InputProfile.TOUCH:
				_touch_layout()  # touch UI: its own placement (the enemy window is gone)
			else:
				player_space.set_fixed_origin(player_origin())
		print("VICTORY: %s destroyed" % e.blueprint.name)
		if run == null:  # run mode: RunState.check_combat opens the ship's `destroyed` event with its rewards
			end_box.open(EndBox.Mode.VICTORY, "event_DESTROYED_DEFAULT_1_text")


## CompleteShip::DeadCrew (player): a living player crew member anywhere (drones excluded), or one waiting
## in the clone queue [inferred].
func _player_crew_left() -> bool:
	var me := player_space.ship
	if not me.clone_queue.is_empty():
		return true
	for sp in [player_space, enemy_space]:
		for c in sp.ship.crew:
			if c.player_owned and c.is_alive() and not c.is_drone():
				return true
	for k in combat.parties:
		for p in combat.parties[k]:
			var c: CrewMember = p.crew
			if c.player_owned and c.is_alive():
				return true
	return false


# ------------------------------------------------------------------ testing without opening the editor
# godot --path . -- --screenshot=<png> [--wait=s] [--single] [--enemy] [--log] [--mute]
#   [--player-ship=NAME] [--enemy-ship=NAME] [--weapons=PRESET] [--player-weapons=WEAPON,WEAPON]
#   (scenario flags: read once per run, before the scene is built; see _parse_scenario_cli)
#   [--difficulty=easy|normal|hard]
#   [--autofire] [--aim=WEAPON:ROOM,...]  (simulates tapping the weapon, then the room;
#    WEAPON:me:ROOM = own room (bombs), WEAPON:ROOM>ROOM = beam from one room toward another)
#   [--arm=WEAPON] (leaves a weapon armed)  [--depower=WEAPON]
#   [--move-crew=INDEX:ROOM] (repeatable; player crew order)  [--select-crew=INDEX,INDEX]
#   [--board=me|enemy:N[:ROOM]] (repeatable; N crew of the other side appear aboard)  [--board-race=RACE]
#     (RACE BOARDER / BOARDER_ION = a delivered boarding / ion boarding drone)
#   [--power=me|enemy:SYSTEM:N] (repeatable; set a system's power bars, enemy AI may change it again)
#   [--cloak=me|enemy[@S]] [--battery=me|enemy[@S]] (switch on: at once, or S seconds after start)
#   [--teleport=send:ROOM[@S]] [--teleport=return:ROOM[@S]] (player teleporter; default S = 2)
#   [--drones=PRESET] [--player-drones=NAME,NAME] [--enemy-drones=NAME,NAME] (scenario; DRONE_PRESETS)
#   [--enemy-super=N] [--player-super=N] (Zoltan super shield of N points, PowerSuperShields)
#   [--drone-parts=N] [--deploy=SLOT[,SLOT][@S]] (click the player's drone boxes, 1-based)
#   Pointer simulation (rules/crew_controls.md; real mouse motion is then ignored), applied at 0.2 s:
#   [--hover-crew=I] (pointer on crew-list entry I's sprite, 0-based)  [--hover-room=me|enemy:ROOM]
#   [--pointer=X,Y] (screen, 1280×720 frame)  [--drag-box=X1,Y1,X2,Y2] (left press at 1, held at 2)
#   [--equip-drag=weapon|drone|aug|cargo|over|over_aug:N] (ship screen equipment tab: hold a drag from box N)
#   [--swap-weapons=A,B] (drag box A onto box B, 1-based)  [--save-stations] [--return-stations@S]

var pending_hits: Array = []
var boards: Array = []
var scheduled: Array = []  # [seconds, Callable]: --cloak / --battery / --teleport actions
var hit_at := 1.0
var debug_pointer: Variant = null  # --beam-preview: fixed pointer on the enemy ship


func _apply_hits_later() -> void:
	await get_tree().create_timer(hit_at).timeout
	for h in pending_hits:
		_hit(h[0], h[1], h[2], h[3])


func _replace_enemy_weapons(names: Array) -> void:
	_replace_weapons(enemy_space.ship, names)


## Test drones: installs the drone system if the ship has none started (the blueprint's own drones room,
## e.g. the Kestrel's room 1), raises its level and the reactor to fit them, gives TEST_DRONE_PARTS parts.
func _replace_drones(ship: ShipState, names: Array) -> void:
	var need := 0
	for n in names:
		var b := FtlData.drone_blueprint(String(n).strip_edges())
		need += int(b.get("power", 0))
	var s := ship.sys("drones")
	if s == null:
		var entry := {}
		for b in ship.blueprint.get("systems", []):
			if b.id == "drones":
				entry = b
		if entry.is_empty():
			push_warning("%s has no drone system room: drones ignored" % ship.blueprint.name)
			return
		entry.start = true
		s = SystemState.new("drones", entry.room, maxi(int(entry.power), need))
		ship.systems["drones"] = s
		ship.reactor_max += need
	elif s.get_level() < need:
		ship.reactor_max += need - s.get_level()
		s.level = need
	ship.drone_slots = maxi(ship.drone_slots, names.size())
	DroneSystemRule.set_drones(ship, names)
	ship.drone_parts = maxi(ship.drone_parts, TEST_DRONE_PARTS)


## --harmless-enemy: no weapons (their power goes back to the reactor) and no drones (nor drone parts).
func _strip_armament(ship: ShipState) -> void:
	ship.weapons.clear()
	var s := ship.sys("weapons")
	if s != null:
		s.power = 0
		s.battery = 0
	DroneSystemRule.set_drones(ship, [])
	ship.drone_parts = 0


## --harmless-enemy: the AI never boards, escapes or surrenders.
func _calm_ai(ai: ShipAI) -> void:
	ai.boarding_ai = 0
	ai.escaping = false
	ai.escape_threshold = -100
	ai.surrender_threshold = -100


func _replace_weapons(ship: ShipState, names: Array) -> void:
	var s := ship.sys("weapons")
	if s == null:
		return
	ship.weapons.clear()
	s.power = 0  # the old weapons' power goes back to the reactor
	s.battery = 0
	for n in names:
		if ship.weapons.size() >= ship.weapon_slots:
			break
		var w := FtlData.weapon_blueprint(String(n).strip_edges())
		if not w.is_empty():
			var ws := WeaponState.new(w, ship.weapons.size())
			ws.powered = false
			ship.weapons.append(ws)
	if s.get_level() < 4:  # small ships (Kestrel, enemies): room to power the test weapons
		s.override_level = 4
		ship.reactor_max += 4
	for w in ship.weapons:
		ship.try_power_weapon(w)


func _parse_difficulty(v: String) -> void:
	match v:
		"easy":
			ShipAI.difficulty = ShipAI.Difficulty.EASY
		"hard":
			ShipAI.difficulty = ShipAI.Difficulty.HARD
		_:
			ShipAI.difficulty = ShipAI.Difficulty.NORMAL


func _handle_cli() -> void:
	var shot := ""
	var wait := 0.5
	var burst := 1  # --burst=N:SECONDS: N screenshots SECONDS apart (shot_1.png .. shot_N.png)
	var burst_step := 0.1
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--burst="):
			var b := a.trim_prefix("--burst=").split(":")
			burst = maxi(int(b[0]), 1)
			burst_step = float(b[1]) if b.size() > 1 else 0.1
		elif a.begins_with("--screenshot="):
			shot = a.trim_prefix("--screenshot=")
		elif a.begins_with("--wait="):
			wait = float(a.trim_prefix("--wait="))
		elif a == "--log":
			Combat.verbose = true
		elif a == "--mute":
			FtlData.muted = true
		elif a == "--single":
			single_view = true
		elif a == "--enemy":
			showing_enemy = true
		elif a.begins_with("--enemy-shields="):
			_set_enemy_shields(int(a.trim_prefix("--enemy-shields=")))
		elif a.begins_with("--enemy-super=") or a.begins_with("--player-super="):
			# test: a Zoltan super shield of N points (PowerSuperShields(N); 0 removes it)
			var sp := enemy_space if a.begins_with("--enemy-super=") else player_space
			SuperShieldRule.power(sp.ship, int(a.get_slice("=", 1)))
			sp.view.queue_redraw()
		elif a.begins_with("--sensors="):
			_set_sensors(int(a.trim_prefix("--sensors=")))
		elif a.begins_with("--ion=") or a.begins_with("--damage="):
			# --ion=enemy:weapons:1  /  --damage=me:weapons:2
			var is_ion := a.begins_with("--ion=")
			var p := a.split("=")[1].split(":")
			var target := enemy_space.ship if p[0] == "enemy" else player_space.ship
			pending_hits.append([target, p[1], int(p[2]), is_ion])
		elif a.begins_with("--loss="):
			# --loss=me:shields:1  (event power loss)
			var p := a.split("=")[1].split(":")
			(enemy_space.ship if p[0] == "enemy" else player_space.ship).set_power_loss(p[1], int(p[2]))
		elif a.begins_with("--hack="):
			# --hack=me|enemy:SYSTEM[@S]: a real hack of that ship's system by the other ship (drone launched
			# and flying; a virtual hacking system is given to an attacker without one), at once or after S s
			var v := a.trim_prefix("--hack=").split("@")
			var p := v[0].split(":")
			var victim := enemy_space.ship if p[0] == "enemy" else player_space.ship
			var sys_id := p[1] if p.size() > 1 else "shields"
			var act := func():
				var ok := _debug_hack(victim.opponent, sys_id)
				print("hack %s %s: %s" % [victim.blueprint.name, sys_id, "launched" if ok else "refused"])
			if v.size() > 1:
				scheduled.append([float(v[1]), act])
			else:
				act.call()
		elif a.begins_with("--hack-pulse="):
			# --hack-pulse=me|enemy[@S]: the hack on that ship (by the other ship) pulses, at once or after S s
			var v := a.trim_prefix("--hack-pulse=").split("@")
			var victim := enemy_space.ship if v[0] == "enemy" else player_space.ship
			var act := func():
				var ok := HackingRule.initiate_pulse(victim.opponent)
				print("hack pulse on %s: %s" % [victim.blueprint.name, "started" if ok else "refused"])
			if v.size() > 1:
				scheduled.append([float(v[1]), act])
			else:
				act.call()
		elif a.begins_with("--mind=") or a.begins_with("--enemy-mind="):
			# --mind=me|enemy:ROOM[@S]: the player's mind system on the crew in ROOM of that ship (arm MIND,
			# click the room); --enemy-mind=me|enemy:ROOM[@S]: the enemy's mind system. Default S = 0.5.
			var by_enemy := a.begins_with("--enemy-mind=")
			var v := a.split("=")[1].split("@")
			var p := v[0].split(":")
			var on := enemy_space.ship if p[0] == "enemy" else player_space.ship
			var room := int(p[1]) if p.size() > 1 else 0
			var user := enemy_space.ship if by_enemy else player_space.ship
			scheduled.append([float(v[1]) if v.size() > 1 else 0.5, func():
				var r := MindRule.arm(user)
				var ok := r == "ok" and MindRule.room_clicked(user, on, room)
				print("mind control by %s on %s room %d: %s" % [user.blueprint.name, on.blueprint.name, room,
					"queued" if ok else r])])
		elif a.begins_with("--doors="):
			# --doors=open | closed | vent [@S] (at once, or S seconds after start: door animation screenshots)
			var dv := a.trim_prefix("--doors=").split("@")
			var mode := dv[0]
			var env := player_space.ship.env
			if dv.size() > 1:
				scheduled.append([float(dv[1]), func(): env.set_all_doors(mode != "closed", mode != "open")])
			else:
				env.set_all_doors(mode != "closed", mode != "open")
		elif a.begins_with("--choose-at=") and run != null:
			# --choose-at=N@S: pick choice N (1-based) of the box open S seconds after start (screenshots).
			var cv := a.trim_prefix("--choose-at=").split("@")
			var ci := int(cv[0]) - 1
			scheduled.append([float(cv[1]) if cv.size() > 1 else 1.0, func():
				print("choose-at %d: %s" % [ci + 1, "ok" if run.choose(ci) else "refused"])])
		elif a.begins_with("--fire=") or a.begins_with("--breach="):
			# --fire=me:weapons  /  --breach=me:oxygen
			var p := a.split("=")[1].split(":")
			var ship := enemy_space.ship if p[0] == "enemy" else player_space.ship
			var room := ship.sys(p[1]).room
			if a.begins_with("--fire="):
				_test_fire(ship, p[1])
			else:
				ship.add_breach(room, 0)
		elif a.begins_with("--move-crew="):
			# --move-crew=INDEX:ROOM (repeatable): order player crew member INDEX (0-based) to ROOM
			var p := a.trim_prefix("--move-crew=").split(":")
			var ship := player_space.ship
			var idx := int(p[0])
			if idx >= 0 and idx < ship.crew.size():
				var ok := ship.order_crew_move([ship.crew[idx]], int(p[1]))
				print("move crew %d -> room %d: %s" % [idx, int(p[1]), "ok" if ok > 0 else "ignored"])
		elif a.begins_with("--crew-hp=enemy:"):
			# --crew-hp=enemy:INDEX|all:HP[@S]: the enemy ship's own crew (not boarders), after S s (default 0);
			# e.g. enemy:all:0@4 kills the whole crew -> deadCrew outcome (repro: retrieving boarders afterwards)
			var at := a.trim_prefix("--crew-hp=enemy:").split("@")
			var p := at[0].split(":")
			var set_hp := func():
				var own: Array = enemy_space.ship.crew.filter(func(c): return not c.player_owned)
				for i in own.size():
					if p[0] == "all" or int(p[0]) == i:
						own[i].hp = float(p[1])
			if at.size() > 1:
				scheduled.append([float(at[1]), set_hp])
			else:
				set_hp.call()
		elif a.begins_with("--crew-hp="):
			# --crew-hp=INDEX:HP (repeatable): set player crew member INDEX's health (e.g. to watch medbay healing)
			var p := a.trim_prefix("--crew-hp=").split(":")
			var idx := int(p[0])
			if idx >= 0 and idx < player_space.ship.crew.size():
				player_space.ship.crew[idx].hp = float(p[1])
		elif a.begins_with("--select-crew="):
			# --select-crew=INDEX,INDEX (shows the selection highlight)
			for i in a.trim_prefix("--select-crew=").split(","):
				if int(i) < player_space.ship.crew.size():
					player_space.ship.crew[int(i)].selected = true
		elif a.begins_with("--options"):
			# --options[@S]: open the Options screen (screenshots); --set=ID=VALUE expands nothing, see Settings
			var at := float(a.split("@")[1]) if "@" in a else 0.0
			scheduled.append([at, func():
				for g in Settings.group_ids():
					options.expanded[g] = Settings.group_raw(g)
				open_options()])
		elif a.begins_with("--pause-menu"):
			# --pause-menu[=hangar|reset][@S]: open FTL's Esc menu (rules/main_menu.md §6; screenshots); =hangar /
			# =reset also presses that button (its "all progress will be lost" confirm opens)
			var at := float(a.split("@")[1]) if "@" in a else 0.0
			var press := a.split("@")[0].trim_prefix("--pause-menu").trim_prefix("=")
			scheduled.append([at, func() -> void:
				open_menu()
				if pause_menu.buttons.has(press):
					pause_menu.click((pause_menu.buttons[press].rect as Rect2).get_center())])
		elif a.begins_with("--power-fail"):
			# --power-fail[@S]: the player's reactor refuses a power step: oxygen +1 with the reactor full (rule
			# layer -> ShipState.failed_powerup -> NOT ENOUGH POWER; rules/power.md)
			var at := float(a.split("@")[1]) if "@" in a else 0.0
			scheduled.append([at, func():
				var me := player_space.ship
				var keep := me.reactor_max
				me.reactor_max = me.reactor_used()
				var o2 := me.sys("oxygen")
				if o2 and o2.power >= o2.max_power():
					me.decrease_power("oxygen")
					me.reactor_max = me.reactor_used()
				print("power fail: oxygen + -> %s" % me.increase_power("oxygen"))
				me.reactor_max = keep])
		elif a.begins_with("--pause"):
			# --pause[@S]: pause the game at once or after S s (pause overlay screenshots)
			var at := float(a.split("@")[1]) if "@" in a else 0.0
			scheduled.append([at, func(): if not combat.paused: _toggle_pause()])
		elif a.begins_with("--hull="):
			# --hull=me|enemy:N[@S]: set the hull points at once or after S s (HUD warnings / hull colours;
			# 0 = destroyed: explosion, then victory box / game over, rules/ship_destruction.md)
			var v := a.trim_prefix("--hull=").split("@")
			var p := v[0].split(":")
			var ship := enemy_space.ship if p[0] == "enemy" else player_space.ship
			var act := func():
				ship.hull = clampi(int(p[1]), 0, ship.max_hull)
				print("hull %s = %d" % [ship.blueprint.name, ship.hull])
			if v.size() > 1:
				scheduled.append([float(v[1]), act])
			else:
				act.call()
		elif a.begins_with("--hull-damage="):
			# --hull-damage=me|enemy:N[@S]: N hull damage through ShipState.take_hull_damage at once or after S s
			# (records iLastDamage: the player's hull damage starts the screen shake, rules/hud_layout.md)
			var v := a.trim_prefix("--hull-damage=").split("@")
			var p := v[0].split(":")
			var ship := enemy_space.ship if p[0] == "enemy" else player_space.ship
			var act := func(): ship.take_hull_damage(int(p[1]))
			if v.size() > 1:
				scheduled.append([float(v[1]), act])
			else:
				act.call()
		elif a == "--debug":
			if not debug_visible:
				toggle_debug()
		elif a.begins_with("--ftl-button") and run != null:
			# --ftl-button[@S]: the FTL / JUMP button pressed through the input profile after S s (default 0.5)
			var v := a.split("@")
			scheduled.append([float(v[1]) if v.size() > 1 else 0.5, func():
				profile.ftl_button()
				print("ftl button: map %s, leave-crew window %s" % [run.map_open, run.leave_crew_open])])
		elif a.begins_with("--click=") and run != null:
			# --click=BEACON|near[@S]: a click on a beacon of the open map through the input profile after S s
			# (pc: jump at once -> arrival and scene rebuild; touch: select)
			var v := a.trim_prefix("--click=").split("@")
			scheduled.append([float(v[1]) if v.size() > 1 else 0.5, func():
				var links := run.map.links_of(run.current_beacon)
				var id := int(links[0]) if v[0] == "near" and not links.is_empty() else int(v[0])
				profile.beacon_click(id)
				print("click beacon %d: current %d, selected %d, dialog %s" % [id, run.current_beacon, run.selected,
					run.dialog.get("name", "-")])])
		elif a.begins_with("--enemy-escape") and run != null:
			# --enemy-escape[=TIMER][@S]: the event ship starts escaping (escape timer TIMER s, default 15) after S s
			var v := a.trim_prefix("--enemy-escape").trim_prefix("=").split("@")
			scheduled.append([float(v[1]) if v.size() > 1 else 0.5, func():
				if not run.enemy.is_empty():
					run.enemy.escaping = true
					run.enemy.escape_timer = float(v[0]) if v[0] != "" else 15.0
				print("enemy escaping, timer %s" % str(run.enemy.get("escape_timer", "-")))])
		elif a.begins_with("--race-crew="):
			# --race-crew=me|enemy:RACE:SYSTEM|ROOM[:foe] (repeatable): a crew member of that race on a slot of the room
			# (rules/races.md screenshots: zoltan bonus bar, lanius O2 drain); `foe` = owned by the other side.
			var p := a.trim_prefix("--race-crew=").split(":")
			var ship := enemy_space.ship if p[0] == "enemy" else player_space.ship
			var rs := ship.sys(p[2])
			var room := rs.room if rs != null else int(p[2])
			var owned := (p[0] != "enemy") != (p.size() > 3 and p[3] == "foe")
			var c := CrewMember.new(p[1], owned)
			var slot := ship.graph.find_slot(room, c)
			if slot >= 0:
				CrewIdentity.assign(c, null, CrewIdentity.used_names(ship))
				c.place(ship, room, slot)
				ship.crew.append(c)
				ship.crew_changed()
		elif a.begins_with("--lockdown="):
			# --lockdown=me|enemy:SYSTEM|ROOM[@S]: crystal lockdown of the room (LockdownRule), at once or after S s
			var lv := a.trim_prefix("--lockdown=").split("@")
			var p := lv[0].split(":")
			var ship := enemy_space.ship if p[0] == "enemy" else player_space.ship
			var rs := ship.sys(p[1])
			var room := rs.room if rs != null else int(p[1])
			scheduled.append([float(lv[1]) if lv.size() > 1 else 0.0, func():
				LockdownRule.lockdown_room(ship, room, ship.room_rect(room).get_center())
				FtlData.play("lockdown1")])
		elif a.begins_with("--board-race="):
			board_race = a.trim_prefix("--board-race=")
		elif a.begins_with("--power="):
			# --power=me|enemy:SYSTEM:N (rules/power.md; e.g. teleporter 3 for a 10 s cooldown)
			var p := a.trim_prefix("--power=").split(":")
			var ship := enemy_space.ship if p[0] == "enemy" else player_space.ship
			_set_system_power(ship, p[1], int(p[2]))
		elif a.begins_with("--cloak=") or a.begins_with("--battery="):
			# --cloak=me|enemy[@S]  /  --battery=me|enemy[@S]
			var is_cloak := a.begins_with("--cloak=")
			var v := a.split("=")[1].split("@")
			var ship := enemy_space.ship if v[0] == "enemy" else player_space.ship
			var act := func():
				var ok := CloakRule.turn_on(ship) if is_cloak else BatteryRule.turn_on(ship)
				print("%s %s: %s" % ["cloak" if is_cloak else "battery", ship.blueprint.name,
					"on" if ok else "refused"])
			if v.size() > 1:
				scheduled.append([float(v[1]), act])
			else:
				act.call()  # at once, in command-line order (e.g. before --power=)
		elif a.begins_with("--teleport="):
			# --teleport=send:ROOM[@S] / --teleport=return:ROOM[@S]: arm the player teleporter and
			# click the enemy room (send = crew standing in the teleporter room)
			var v := a.trim_prefix("--teleport=").split("@")
			var p := v[0].split(":")
			var mode := TeleporterRule.SEND if p[0] == "send" else TeleporterRule.RETRIEVE
			var room := int(p[1]) if p.size() > 1 else -1
			var at := float(v[1]) if v.size() > 1 else 2.0
			scheduled.append([at, func():
				var armed := combat.arm_teleporter(player_space.ship, mode)
				if armed:
					_on_enemy_room_clicked(room, MOUSE_BUTTON_LEFT, false)  # the real click path
				var ok := armed and not combat.player_tp_command.is_empty()
				print("teleport %s room %d: %s" % [p[0], room, "ordered" if ok else "refused"])])
		elif a.begins_with("--board="):
			# --board=me|enemy:N[:ROOM]  (N crew of the other side appear aboard that ship)
			boards.append(a.trim_prefix("--board=").split(":"))
		elif a.begins_with("--hit-at="):
			hit_at = float(a.trim_prefix("--hit-at="))
		elif a.begins_with("--power-enemy-weapons="):
			# test: replace the enemy's weapons with the given list (all powerable)
			_replace_enemy_weapons(a.trim_prefix("--power-enemy-weapons=").split(","))
		elif a.begins_with("--difficulty="):
			# --difficulty=easy|normal|hard (enemy AI targeting, rules/combat_ai.md)
			_parse_difficulty(a.trim_prefix("--difficulty="))
		elif a == "--autofire":
			weapon_control.toggle_autofire()
		elif a.begins_with("--depower="):
			weapon_control.depower(int(a.trim_prefix("--depower=")) - 1)
		elif a.begins_with("--aim="):
			# WEAPON:ROOM (enemy room), WEAPON:me:ROOM (own room: bombs), WEAPON:ROOM>ROOM (beam from the
			# centre of the first room toward the centre of the second, full length)
			for pair in a.trim_prefix("--aim=").split(","):
				var p := pair.split(":")
				weapon_control.select(int(p[0]) - 1)
				if p.size() >= 3 and p[1] == "me":
					weapon_control.aim_at(player_space.ship, int(p[2]))
				elif ">" in p[1]:
					var rr := p[1].split(">")
					var e := enemy_space.ship
					var c := e.room_rect(int(rr[0])).get_center()
					var w := weapon_control.weapon(int(p[0]) - 1)
					var dir := (e.room_rect(int(rr[1])).get_center() - c).normalized()
					weapon_control.aim_beam(e, c, c + dir * float(w.bp.get("length", 0)) if w else c)
				else:
					weapon_control.aim_at(enemy_space.ship, int(p[1]))
		elif a.begins_with("--deploy="):
			# --deploy=SLOT[,SLOT][@S]: click the player's drone boxes (1-based), at once or after S s
			var v := a.trim_prefix("--deploy=").split("@")
			var act := func():
				for i in v[0].split(","):
					var idx := int(i) - 1
					if idx >= 0 and idx < player_space.ship.drones.size():
						var r := DroneSystemRule.player_toggle(player_space.ship, player_space.ship.drones[idx])
						print("deploy drone %d (%s): %s" % [idx + 1, player_space.ship.drones[idx].bp.name, r])
			if v.size() > 1:
				scheduled.append([float(v[1]), act])
			else:
				act.call()
		elif a.begins_with("--drone-parts="):
			player_space.ship.drone_parts = int(a.trim_prefix("--drone-parts="))
		elif a.begins_with("--arm="):
			weapon_control.select(int(a.trim_prefix("--arm=")) - 1)
		elif a.begins_with("--hover-crew=") or a.begins_with("--hover-room=") or a.begins_with("--pointer=") 				or a.begins_with("--drag-box="):
			pointer_locked = true
			var arg := a
			scheduled.append([0.2, func(): _cli_pointer(arg)])
		elif a.begins_with("--equip-drag="):
			# --equip-drag=weapon|drone|aug|cargo|over|over_aug:N (0-based box): press on that equipment box of the
			# open ship screen and hold the drag (screenshots of the drag highlights; pair with --pointer=X,Y).
			var ep := a.trim_prefix("--equip-drag=").split(":")
			scheduled.append([0.2, func(): _debug_equip_drag(ep[0], int(ep[1]) if ep.size() > 1 else 0)])
		elif a.begins_with("--swap-weapons="):
			var p := a.trim_prefix("--swap-weapons=").split(",")
			weapon_control.swap(int(p[0]) - 1, int(p[1]) - 1)
			print("swap weapons %s: %s" % [a.trim_prefix("--swap-weapons="), _weapons_line(player_space.ship)])
		elif a == "--save-stations":
			crew_control.save_stations()
		elif a.begins_with("--return-stations"):
			var at := float(a.split("@")[1]) if "@" in a else 0.0
			scheduled.append([at, crew_control.return_stations])
		elif a.begins_with("--beam-preview="):
			# WEAPON:A>B: arm the beam, place its first point at room A's centre and hold the pointer on
			# room B's centre (screenshots of the beam aim line and its room highlight)
			var p := a.trim_prefix("--beam-preview=").split(":")
			var rr := p[1].split(">")
			var e := enemy_space.ship
			weapon_control.select(int(p[0]) - 1)
			weapon_control.begin_beam(e, e.room_rect(int(rr[0])).get_center())
			debug_pointer = e.room_rect(int(rr[1])).get_center()
	for p in boards:
		_board(enemy_space.ship if p[0] == "enemy" else player_space.ship,
			int(p[1]) if p.size() > 1 else 2, int(p[2]) if p.size() > 2 else -1)
	_apply_view()
	if not pending_hits.is_empty():
		_apply_hits_later()
	for sc in scheduled:
		get_tree().create_timer(sc[0]).timeout.connect(sc[1])
	if shot != "":
		await get_tree().create_timer(wait).timeout
		for k in range(1, burst):
			await RenderingServer.frame_post_draw
			FrameHost.window_image(get_tree()).save_png(shot.get_basename() + "_%d.png" % k)
			await get_tree().create_timer(burst_step).timeout
		await RenderingServer.frame_post_draw
		FrameHost.window_image(get_tree()).save_png(
			shot if burst <= 1 else shot.get_basename() + "_%d.png" % burst)
		print("screenshot: ", shot, "  player hull=", player_space.ship.hull,
			" enemy=", enemy_space.ship.hull, " missiles=", player_space.ship.missiles)
		print("enemy crew (room, CrewAI task, room, system): ", enemy_space.ship.crew.map(
			func(c): return [c.room, c.ai_task.id, c.ai_task.room, c.ai_task.sys]),
			"  fires: ", enemy_space.ship.fires.keys())
		for sp in [player_space, enemy_space]:
			print("%s crew [race, room, hp, intruder, fighting, task]: %s" % [sp.ship.blueprint.name,
				str(sp.ship.crew.map(func(c): return [c.race, c.room, snappedf(c.hp, 0.1),
					c.is_intruder(sp.ship), c.fighting, c.task]))])
			print("  %s" % _systems_line(sp.ship))
		get_tree().quit()


# ------------------------------------------------------------------ open Fold: "pan" layout (visual draft)
## `--fold-layout=edges|split|pan` (tall touch canvases only, e.g. `--device=fold_inner`; default edges): which
## open-Fold combat layout _touch_layout uses. Read once from the command line; unknown values keep edges.
## Without the flag the player's option decides (GameOptions.fold_layout, Options window GAMEPLAY "Unfolded Screen
## Layout": split (default) / pan); the flag (or a test setting `_fold_layout_cli`) overrides it. "" = no override.
static var _fold_layout_cli := ""
static var _fold_cli_parsed := false


static func _fold_parse_cli() -> void:
	if _fold_cli_parsed:
		return
	_fold_cli_parsed = true
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--fold-layout="):
			var v := a.trim_prefix("--fold-layout=")
			if v in ["edges", "split", "pan"]:
				_fold_layout_cli = v
			else:
				push_warning("--fold-layout=%s: expected edges|split|pan, using the option" % v)


static func fold_layout() -> String:
	_fold_parse_cli()
	if _fold_layout_cli != "":
		return _fold_layout_cli
	return GameOptions.fold_layout if GameOptions.FOLD_LAYOUTS.has(GameOptions.fold_layout) else "split"


## True when the player's option (not `--fold-layout=` / a test) picks the tall-canvas layout.
static func fold_layout_from_option() -> bool:
	_fold_parse_cli()
	return _fold_layout_cli == ""


## `--phone-layout=column|pan` (720-high touch canvases: phone, closed Fold cover): which phone combat layout
## _touch_layout uses — `column` (the TARGET flush right + vertical weapons / drones column, _touch_layout's band
## code) or `pan` (_touch_layout_phone_pan). Without the flag the player's option decides (GameOptions.phone_layout,
## Options window GAMEPLAY "Phone Screen Layout": Column (default) / Pan); the flag (or a test setting
## `_phone_layout_cli`) overrides it. "" = no override.
static var _phone_layout_cli := ""
static var _phone_cli_parsed := false


static func _phone_parse_cli() -> void:
	if _phone_cli_parsed:
		return
	_phone_cli_parsed = true
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--phone-layout="):
			var v := a.trim_prefix("--phone-layout=")
			if v in GameOptions.PHONE_LAYOUTS:
				_phone_layout_cli = v
			else:
				push_warning("--phone-layout=%s: expected column|pan, using the option" % v)


static func phone_layout() -> String:
	_phone_parse_cli()
	if _phone_layout_cli != "":
		return _phone_layout_cli
	return GameOptions.phone_layout if GameOptions.PHONE_LAYOUTS.has(GameOptions.phone_layout) else "column"


## Phone "pan" layout (_touch_layout_phone_pan): touch combat on a canvas under TOUCH_TALL_MIN_H (phone ~1600 × 720,
## closed Fold ~1766 × 720) with phone_layout() == "pan".
func _touch_phone_pan() -> bool:
	return input_mode == InputProfile.TOUCH and not single_view and not _touch_tall() and phone_layout() == "pan"


## Leaving / entering the pan layout: the scene goes back to its left end (no pan offset carried over), the arrows
## are hidden until the pan layout shows them again, the backdrop parallax is undone, a running pan animation and
## two-finger drag are dropped.
func _pan_reset() -> void:
	if _pan_tween != null and _pan_tween.is_valid():
		_pan_tween.kill()
	_pan_tween = null
	pan_pos = 0.0
	_pan_range = 0.0
	_pan_scene = {}
	_pan_touches.clear()
	_pan_arrow_spots = {}
	if pan_arrows != null:
		pan_arrows.visible = false
	if _ppan_backing != null:
		_ppan_backing.visible = false  # phone pan only (shown again by _ppan_backing_set)
	if space_backdrop != null:
		space_backdrop.position.x = 0.0


## Open-Fold "pan" layout (`--fold-layout=pan`, tall touch canvas only; first visual draft, taps untested): the PC
## HUD where it is on PC (no TARGET window), and the two ships side by side in ONE wide scene that pans
## horizontally (arrows at the canvas edges, two-finger drag; desktop: Shift + wheel, wheel left / right, ← / →).
## Phone, PC and the other fold layouts never get here.
func _touch_pan() -> bool:
	return input_mode == InputProfile.TOUCH and not single_view and _touch_tall() and fold_layout() == "pan" \
		or _touch_phone_pan()  # the phone pan layout shares the scene / arrows / panning (_pan_apply, _pan_input)


const PAN_ARROWS_SCRIPT := preload("res://scripts/ui/pan_arrows.gd")
const PAN_GAP := 60.0  # PC px (× ship scale) between the two ships' bounds (shield ellipse, hull, rooms)
const PAN_MARGIN := 40.0  # PC px (× ship scale) of space right of the enemy's bounds (scene end)
const PAN_STEP := 120.0  # canvas px per wheel tick / arrow key
const PAN_PARALLAX := 0.2  # beacon backdrop (planet / sun ...) moves this fraction of the scene's pan
const PAN_STATUS_TOP := 64.0  # canvas y the enemy status block never goes above (top HUD row)
var pan_pos := 0.0  # 0 = scene's left end (player ship) ... 1 = right end (enemy ship)
var pan_arrows: Control  # PanArrows (scripts/ui/pan_arrows.gd)
var _pan_range := 0.0  # canvas px the scene is wider than the canvas
var _pan_scene := {}  # last pan layout: {z, k, po, eo, er, split, enemy} (canvas px at pan 0)
var _pan_cli_done := false
var _pan_tween: Tween
var _pan_touches := {}  # finger index -> canvas position (two-finger drag)
var _pan_arrow_spots := {}  # --hud-scale: {"y": {left, right}, "scale": {left, right}} (_pan_hud_scaled); {} = centred


## World-space bounds of a ship as drawn: shield ellipse, hull image and rooms.
func _pan_ship_rect(s: ShipState) -> Rect2:
	var r := Rect2(s.shield_center - s.shield_axes, s.shield_axes * 2).merge(s.rooms_bounds())
	var img: Rect2 = s.layout.img_rect
	if img.size.x > 0 and img.size.y > 0:
		r = r.merge(Rect2(s.hull_position(), img.size))
	return r


## The pan layout (_touch_pan), second draft. HUD ×k = `--hud-scale` (absent: canvas width / 1280, Fold ×1), each
## piece on its corner / edge:
## - top-left block (ship status, crew list) at the origin, top buttons in the top row (moved left only if they would
##   leave the canvas);
## - subsystems (+ the + / − toggle left of them, bottoms level) at the top right, beside the MENU wrench, at
##   ks = k − 0.25 (≥ 1; no flag: k), as high as their solid pieces clear the top buttons (bars right of the wrench
##   stand in the top row) — the split layout's rule (_pan_sub_pieces = its piece list); PAUSE / CANCEL right-aligned
##   under them;
## - systems bar bottom-left; the weapons and drones PC boxes (power column, label, AUTOFIRE) side by side on the
##   bottom edge, right-aligned, at the largest box scale kb (k, k − 1/8 … 0.75) that keeps them clear of the systems
##   bar — with the big crew stations buttons (TOUCH_STATION_SIZE pair) in the bottom-right corner beside them, else
##   (larger kb) with the stations above the drones box's right end;
## - the enemy ship in its full TARGET window (frame, status, info, system icons; touch_enemy_transform's frame
##   placement, _place_touch_enemy) inside the scene: window scale = the ship scale z (smaller step if the art does
##   not fit between the top buttons and the bottom row), art PAN_GAP × z right of the player's bounds, centred in
##   that height; the scene ends so that at pan 1 the window sits left of the top-right stack (subsystems / PAUSE).
## Scene / ship scale z, panning, arrows: as before (_pan_apply).
const PAN_PC_TOP_H := 115.0  # PC frame: the top HUD row's height (top buttons incl. pullout, CommandHud.TOP_BUTTONS)
const PAN_PC_BOTTOM_H := 140.0  # PC frame: the bottom HUD row's height (system boxes, weapons / drones boxes)
const PAN_HUD_GAP := 6.0  # canvas px between HUD pieces / from the canvas edge
const PAN_ARROW_MIN := 0.75  # smallest pan arrow scale (an arrow squeezed by its edge's HUD pieces)
const PAN_BOX_MIN := 0.75  # smallest weapons / drones box scale
const PAN_HOLDER_GLOW := 12.0  # PC weapons holder: rows of glow / transparency above its solid border (measured, ×1)
const PAN_GLUE := 2.0  # canvas px between glued pieces (drones on the weapons, TARGET window between HUD pieces)


func _touch_layout_pan() -> void:
	var vis := get_viewport().get_visible_rect().size
	var h := vis.y
	var g := PAN_HUD_GAP
	var hs := _hud_scale_set()
	var k := _hud_scale() if hs else vis.x / HudLayout.FRAME.x
	var enemy := _touch_enemy_present()
	# Top-left block, top buttons.
	for c: Control in [ship_status, crew_list, command_hud]:
		c.scale = Vector2(k, k)
	crew_list.position = Vector2.ZERO
	ship_status.evade_offset = Vector2.ZERO
	command_hud.engines_warning_shift = Vector2.ZERO
	var tb := CommandHud.TOP_BUTTONS
	command_hud.position = Vector2(minf(0.0, roundf(vis.x - g - tb.end.x * k)), 0)
	var menu_r := command_hud.position.x + (command_hud.menu_rect().position.x + 47.0) * k  # wrench solid right
	# Top buttons as the split layout counts them: FTL drive (+ pull-out) up to the SHIP button, then SHIP + MENU (their
	# own height) up to the wrench's solid right; the hazard status right of the wrench (_pan_hazard).
	var cx := command_hud.position.x
	var menu := command_hud.menu_rect()
	var tops: Array[Rect2] = [
		Rect2(cx + tb.position.x * k, 0, (HudLayout.SHIP_BUTTON.x - tb.position.x) * k, tb.end.y * k),
		Rect2(cx + HudLayout.SHIP_BUTTON.x * k, 0, menu_r - cx - HudLayout.SHIP_BUTTON.x * k, menu.end.y * k)]
	var hz := _pan_hazard(menu_r, vis.x, k)
	if hz.has_area():
		tops.append(hz)
	# Systems bar bottom-left at k.
	systems_bar.pivot_offset = Vector2.ZERO
	systems_bar.scale = Vector2(k, k)
	systems_bar.position = Vector2(0, h - HudLayout.FRAME.y * k)
	var bar_pos := systems_bar.position
	# Subsystems + toggle, top right: the split layout's rule (round 4) — ks = HUD scale × TOUCH_SPLIT_SUB_RATIO (≥ 1),
	# as high as their solid pieces stay TOUCH_SPLIT_SUB_TOP_GAP clear of the top buttons / hazard (the pilot's
	# manning icon just under the wrench row).
	var ks := maxf(1.0, k * TOUCH_SPLIT_SUB_RATIO)
	var sub_rects: Array[Rect2] = []
	var sa := Vector2.ZERO
	var toggle_at := Vector2.INF
	var sub_b := Rect2()
	if systems_bar.sub_group != null and not systems_bar.sub_ids.is_empty():
		sub_b = systems_bar.subsystem_bounds()
		var pieces: Array[Rect2] = []
		for r in _pan_sub_pieces():
			pieces.append(Rect2((r.position - sub_b.position) * ks, r.size * ks))
		var tog := Rect2(Vector2(-TOUCH_CREW_BOX_GAP - 28.0 * ks, (sub_b.size.y - CrewList.BOX_BODY_H + 6) * ks),
			Vector2(28, CrewList.BOX_BODY_H - 6) * ks)  # the toggle's solid art (x 6..34, y 6..57 of its image)
		pieces.append(tog)
		var reach := sub_b.size.x * ks
		for p in pieces:
			reach = maxf(reach, p.end.x)  # the battery button reaches past subsystem_bounds
		var x0 := vis.x - g - reach
		var y := 0.0
		var tg := TOUCH_SPLIT_SUB_TOP_GAP
		for p in pieces:
			y = maxf(y, -p.position.y)
			for o in tops:
				if x0 + p.position.x < o.end.x + tg and x0 + p.end.x > o.position.x - tg:
					y = maxf(y, o.end.y + tg - p.position.y)
		sa = Vector2(x0, y).round()
		for p in pieces:
			sub_rects.append(Rect2(sa + p.position, p.size))
		systems_bar.sub_group.scale = Vector2(ks / k, ks / k)
		systems_bar.sub_group.position = (sa - bar_pos) / k - sub_b.position * (ks / k)
		toggle_at = (sa + tog.position - Vector2(6, 6) * ks).round()
	# Bottom row: systems bar bottom-left (k); its solid pieces (frame coordinates -> canvas) for what sits above it.
	var bar_xf := func(r: Rect2) -> Rect2: return Rect2(bar_pos + r.position * k, r.size * k)
	var bar_right := 90.0
	var bar_pieces: Array[Rect2] = []
	var me := player_space.ship
	for id in systems_bar.main_ids:
		if id == "weapons" or id == "drones":
			continue
		var x: float = systems_bar.box_x.get(id, 0)
		var w := 90.0 if SystemsBar.WIDE_BOXES.has(id) else 64.0
		var sy := me.sys(id)
		var top := HudLayout.SYSTEM_BOX_Y - HudLayout.POWER_PITCH * (sy.get_level() if sy else 1) - 24.0
		bar_pieces.append(bar_xf.call(Rect2(x, top, w, HudLayout.FRAME.y - top)))
		bar_right = maxf(bar_right, x + w)
		if systems_bar.buttons.has(id):
			var bt: Control = systems_bar.buttons[id]
			bar_pieces.append(bar_xf.call(Rect2(bt.position, bt.size)))
	var rc := systems_bar.reactor.counts().x if systems_bar.reactor else me.reactor_max
	var rtop := ReactorColumn.top_y(rc) - 4.0
	bar_pieces.append(bar_xf.call(Rect2(0, rtop, 90, HudLayout.FRAME.y - rtop)))
	bar_right *= k
	# PAUSE + CANCEL STACKED (TouchCombatButtons.stacked, set by _touch_selection_tick for a rect taller than one base):
	# PAUSE at the bottom, CANCEL in the slot above it, same x.
	var pair := Vector2(TouchCombatButtons.BASE_SIZE.x, TouchCombatButtons.BASE_SIZE.y * 2 + TouchCombatButtons.GAP) * k
	# Weapons PC box on the bottom edge at k, PAN_HUD_GAP right of the systems bar (pushed left if it would leave the
	# canvas); drones PC box above it, right edge on the canvas edge (PC's drones above-right of the weapons).
	var wp: Control = weapon_panel if weapon_panel != null and weapon_panel.visible else null
	var dp: Control = drone_panel if drone_panel != null and is_instance_valid(drone_panel) and drone_panel.visible \
		else null
	var b := TOUCH_STATION_SIZE
	var sg := TOUCH_STATION_GAP
	var box_rects: Array[Rect2] = []  # holders and power columns, canvas
	var w_right := bar_right
	var w_top := h  # weapons holder top
	var col_off := Vector2(-HudLayout.HOLDER_X, HudLayout.SYSTEM_BOX_Y - HudLayout.ARMAMENT_Y - SystemPowerColumn.ABOVE)
	if wp != null:
		var u := _pan_unit(wp)
		var x := minf(bar_right + g - u.position.x * k, vis.x - g - u.end.x * k)
		# Glued to the canvas bottom: its lowest piece (holder, AUTOFIRE, power column) PAN_HUD_GAP above it (the PC
		# frame's own bottom margin would only push the drones / TARGET window up).
		var low := u.end.y
		var af: Control = (wp as WeaponPanel).autofire_btn
		if af != null:
			low = maxf(low, af.position.y + af.size.y)
		var at := Vector2(x, h - g - low * k).round()
		wp.pivot_offset = Vector2.ZERO
		wp.scale = Vector2(k, k)
		wp.position = at
		var holder := Rect2(at, wp.size * k)
		box_rects.append(holder)
		var col: SystemPowerColumn = (wp as WeaponPanel).column
		if col != null:
			var hr := col.hit_rect()
			box_rects.append(Rect2(at + (col_off + hr.position) * k, hr.size * k))
		w_right = at.x + u.end.x * k
		w_top = holder.position.y
	# Crew stations pair, bottom-right corner: side by side right of the weapons if there is room, else stacked.
	var st: Array[Rect2] = []
	if w_right + g + 2 * b + sg + g <= vis.x:
		st = [Rect2(vis.x - g - 2 * b - sg, h - g - b, b, b), Rect2(vis.x - g - b, h - g - b, b, b)]
	elif w_right + g + b + g <= vis.x:
		st = [Rect2(vis.x - g - b, h - g - 2 * b - sg, b, b), Rect2(vis.x - g - b, h - g - b, b, b)]
	else:  # no room beside the weapons: above their right end
		st = [Rect2(vis.x - g - 2 * b - sg, w_top - g - b, b, b), Rect2(vis.x - g - b, w_top - g - b, b, b)]
	var corner := st[1].end.y >= h - g - 0.5
	if dp != null:
		var u := _pan_unit(dp)
		# Glued on the weapons holder's solid top (PAN_GLUE apart; its rect starts PAN_HOLDER_GLOW higher), still clear
		# of the weapons' power column and the stations.
		var bottom := w_top + (PAN_HOLDER_GLOW * k if wp != null else 0.0) - PAN_GLUE  # the drones unit's bottom
		var at := Vector2(vis.x - g - u.end.x * k, 0)
		var dr := Rect2(at + u.position * k, u.size * k)
		for r in box_rects + st:
			if r.position.x < at.x + u.end.x * k + PAN_GLUE and r.end.x + PAN_GLUE > dr.position.x 					and r.position.y < w_top - 0.5:  # pieces reaching above the weapons holder's top
				bottom = minf(bottom, r.position.y - PAN_GLUE)
		at.y = roundf(bottom - u.end.y * k)
		at = at.round()
		dp.pivot_offset = Vector2.ZERO
		dp.scale = Vector2(k, k)
		dp.position = at
		box_rects.append(Rect2(at, dp.size * k))  # holder and power column apart (the TARGET window fits tighter)
		var dcol: SystemPowerColumn = systems_bar.columns.get("drones")
		if dcol != null:
			var hr := dcol.hit_rect()
			box_rects.append(Rect2(at + (col_off + hr.position) * k, hr.size * k))
		var col: Control = systems_bar.columns.get("drones")
		if col != null:  # the bar's drones power column, left of its box (same place as in the panel's frame)
			col.scale = Vector2.ONE
			col.position = (at + col_off * k - bar_pos) / k
	# The free right strip (right of the TARGET window at pan 1, left of the right pan arrow): PAUSE + CANCEL
	# (stacked) right-aligned in it, glued on the drones holder's solid top (else the weapons holder's; else the canvas
	# bottom), and the pause overlay text (TARGETING / ROOM SELECTION ... + instruction, PAUSED) centred above them,
	# PAN_HUD_GAP apart. The strip is as wide as the pair / the widest text at the text scale kt (HUD scale, down to
	# ×1 when the strip left by the subsystems is narrower); the TARGET window's pan-1 place leaves room for it.
	var strip_r := roundf(vis.x - (PAN_ARROWS_SCRIPT.EDGE + PAN_ARROWS_SCRIPT.SIZE.x) * k - g)
	var sub_left := vis.x
	for r in sub_rects:
		sub_left = minf(sub_left, r.position.x)
	var text_w := _pan_pause_text_width()
	var kt := clampf((strip_r - sub_left) / maxf(text_w, 1.0), minf(1.0, k), k)
	var strip_w := maxf(pair.x, ceilf(text_w * kt))
	var strip_l := strip_r - strip_w
	var glue_top := h
	var holder: Rect2 = box_rects[2] if dp != null and box_rects.size() > 2 else (box_rects[0] if wp != null 		else Rect2(0, h, vis.x, 0))
	glue_top = holder.position.y + (PAN_HOLDER_GLOW * k if holder.size.y > 0 else -g) - PAN_GLUE
	_touch_pause_at = Rect2(Vector2(strip_r - pair.x, roundf(glue_top - pair.y)), pair.round())
	# Pause overlay text: frame block y 526 .. 592 (Text_pause1 / title from PAUSE_TEXT − 32, hint at PAUSE_HINT)
	# mapped so its bottom is PAN_HUD_GAP above the pair and its centre on the strip's centre.
	var tb_bottom := Vector2(HudLayout.PAUSE_TEXT.x, HudLayout.PAUSE_HINT.y + 12)
	var text_at := Vector2(strip_l + strip_w / 2, _touch_pause_at.position.y - g)
	pause_overlay.scale = Vector2(kt, kt)
	pause_overlay.position = (text_at - tb_bottom * kt).round()
	var text_rect := Rect2(strip_l, text_at.y - (tb_bottom.y - HudLayout.PAUSE_TEXT.y + 32) * kt, strip_w,
		(tb_bottom.y - HudLayout.PAUSE_TEXT.y + 32) * kt)
	touch_weapon_scale = k
	var kb := k
	var local_st := []
	for r in st:
		local_st.append(Rect2((r.position - crew_list.position) / k, r.size / k))
	crew_list.touch_button_box = null
	crew_list.touch_station_rects = local_st
	if toggle_at != Vector2.INF:
		if touch_power == null:
			touch_power = TouchPowerToggle.new()
			touch_power.held_fn = func() -> bool: return _gestures().held_minus()  # held finger = − for now
			hud_root.add_child(touch_power)
			hud_root.move_child(touch_power, crew_list.get_index() + 1)
		touch_power.scale = Vector2(ks, ks)
		touch_power.position = toggle_at
	# Pan arrows: each in the largest free stretch of its canvas edge (left: between the crew list's stations
	# buttons and the reactor; right: between PAUSE / CANCEL and the stations / boxes), scale ≤ k, ≥ PAN_ARROW_MIN.
	var strip := (PAN_ARROWS_SCRIPT.EDGE + PAN_ARROWS_SCRIPT.SIZE.x) * k
	var left_obst: Array[Rect2] = [Rect2(0, 0, 1, crew_control.button_rect(0).end.y * k), _touch_pause_at]
	left_obst.append_array(bar_pieces)
	var right_obst: Array[Rect2] = []
	right_obst.append_array(sub_rects)
	right_obst.append_array(box_rects)
	right_obst.append_array(st)
	var ys := {}
	var scs := {}
	for side in ["left", "right"]:
		var lo := h / 2
		var hi := h / 2
		var ivs: Array = [[0.0, h]]
		for o: Rect2 in (left_obst if side == "left" else right_obst):
			if not (o.position.x < strip if side == "left" else o.end.x > vis.x - strip):
				continue
			var nxt := []
			for iv in ivs:  # cut [o.top, o.bottom] out of the free intervals
				if o.position.y > iv[0]:
					nxt.append([iv[0], minf(iv[1], o.position.y)])
				if o.end.y < iv[1]:
					nxt.append([maxf(iv[0], o.end.y), iv[1]])
			ivs = nxt
		for iv in ivs:
			if iv[1] - iv[0] > hi - lo:
				lo = iv[0]
				hi = iv[1]
		ys[side] = roundf((lo + hi) / 2)
		scs[side] = clampf((hi - lo - 2 * g) / PAN_ARROWS_SCRIPT.SIZE.y, PAN_ARROW_MIN, k)
	_pan_arrow_spots = {"y": ys, "scale": scs}
	var arrow_rects: Array[Rect2] = []  # canvas rects of both arrows (HUD: the player's rooms keep clear of them)
	for side in ["left", "right"]:
		var sc: float = scs[side]
		var asz: Vector2 = PAN_ARROWS_SCRIPT.SIZE * sc
		var ax: float = PAN_ARROWS_SCRIPT.EDGE * sc if side == "left" else vis.x - PAN_ARROWS_SCRIPT.EDGE * sc - asz.x
		arrow_rects.append(Rect2(Vector2(ax, ys[side] - asz.y / 2), asz))
	# Scene. z_band (the PC 720 band's scale between the scaled rows, as before) caps the TARGET window; the player
	# ship is fitted to its own hull at pan 0 like the phone pan layout: _touch_fit_ship against every fixed HUD
	# piece (rooms clear of them, hull art may pass under), the largest TOUCH_SHIP_SCALES step with the whole hull
	# on the canvas, or ONE step more with hull rows past the canvas top / bottom; capped by the list (×2.5).
	var band_h := h - ((k - 1.0) * (PAN_PC_TOP_H + PAN_PC_BOTTOM_H) if hs else 0.0)
	var z_band := TOUCH_SHIP_SCALES[TOUCH_SHIP_SCALES.size() - 1] as float
	for c: float in TOUCH_SHIP_SCALES:
		if c <= band_h / HudLayout.FRAME.y + 0.001:
			z_band = c
			break
	var hud: Array[Rect2] = []
	for arr in [tops, bar_pieces, sub_rects, box_rects, st, arrow_rects]:
		hud.append_array(arr)
	hud.append_array([_touch_pause_at, text_rect])
	# Top-left block at its PC place ×k (ship status: hull bar, shields, resources, scrap, evade / O2) and the crew
	# boxes (the stations buttons are in the bottom-right corner).
	for r in [Rect2(0, 0, 375, 46), Rect2(7, 50, 121, 39), Rect2(132, 50, 193, 26), Rect2(383, 11, 122, 35),
			Rect2(8, 96, 90, 42)]:
		hud.append(Rect2(r.position * k, r.size * k))
	var n_crew := crew_control.roster.size()
	if n_crew > 0:
		var cr := crew_control.box_rect(0).merge(crew_control.box_rect(n_crew - 1))
		hud.append(Rect2(crew_list.position + cr.position * k, cr.size * k))
	var fit := _touch_fit_ship([], vis.x, h, hud, INF, true)
	if not fit.is_empty():
		var fi := TOUCH_SHIP_SCALES.find(fit.zoom)
		var f2 := _touch_fit_ship([], vis.x, h, hud, TOUCH_SHIP_SCALES[maxi(fi - 1, 0)] if fi >= 0 else fit.zoom)
		if not f2.is_empty() and f2.zoom > fit.zoom + 0.001:
			fit = f2
	else:
		fit = _touch_fit_ship([], vis.x, h, hud)
	if fit.is_empty():  # nothing fits: the old band placement
		var band_y := roundf((h - HudLayout.FRAME.y * z_band) / 2)
		fit = {"origin": player_origin() * z_band + Vector2(0, band_y), "zoom": z_band}
	var z: float = fit.zoom
	touch_ship_zoom = z
	var po: Vector2 = fit.origin
	var pr := _pan_ship_rect(player_space.ship)
	var p_right := po.x + pr.end.x * z
	# TARGET window in the scene: at pan 1 it ends `reserve` px before the canvas edge (left of the subsystems); its
	# scale = the largest step ≤ z whose art fits between the top buttons and the bottom-row pieces under it there.
	var reserve := maxf(g, vis.x - strip_l + g)  # the free right strip (PAUSE / CANCEL, pause text)
	for r in sub_rects:
		reserve = maxf(reserve, vis.x - r.position.x + g)
	# Its vertical room at pan 1 (x range wl .. vis.x − reserve): PAN_GLUE under the top pieces over that range (top
	# buttons as split counts them, hazard, subsystems), PAN_GLUE over the bottom pieces under it (drones holder /
	# power column, weapons, stations, systems bar).
	var art := TOUCH_ENEMY_ART
	var room := func(c: float) -> Vector2:
		var wl := vis.x - reserve - art.size.x * c
		var wr := vis.x - reserve
		var t := 0.0
		for r in tops + sub_rects:
			if r.position.x < wr and r.end.x > wl:
				t = maxf(t, r.end.y + PAN_GLUE)
		var bt := h
		var under: Array[Rect2] = [_touch_pause_at, text_rect]
		under.append_array(box_rects + st + bar_pieces)
		for r in under:
			if r.position.x < wr and r.end.x > wl:
				bt = minf(bt, r.position.y - PAN_GLUE)
		return Vector2(t, bt)
	var ws := TOUCH_SHIP_SCALES[TOUCH_SHIP_SCALES.size() - 1] as float
	for c: float in TOUCH_SHIP_SCALES:
		var rm: Vector2 = room.call(c)
		if c <= z_band + 0.001 and art.size.y * c <= rm.y - rm.x:
			ws = c
			break
	var rm2: Vector2 = room.call(ws)
	var wtop := rm2.x
	var wbot2 := rm2.y
	var art_frame := HudLayout.ENEMY_FRAME.position + art.position
	var art_at := Vector2(roundf(p_right + PAN_GAP * z), roundf((wtop + wbot2) / 2 - art.size.y * ws / 2))
	# At pan 0 the window must not run under the right pan arrow: if it would reach the arrow's column, it starts
	# just past the canvas edge instead (off screen until panned).
	var ra: Rect2 = arrow_rects[1]
	if art_at.x < vis.x and art_at.x + art.size.x * ws > ra.position.x - g:
		art_at.x = vis.x
	var xf := Transform2D(0.0, Vector2(ws, ws), 0.0, art_at - art_frame * ws)
	var scene_w := art_at.x + art.size.x * ws + reserve if enemy else vis.x
	_pan_range = maxf(roundf(scene_w - vis.x), 0.0)
	_pan_scene = {"z": z, "k": k, "po": po, "xf": xf, "enemy": enemy}
	if not _pan_cli_done:
		_pan_cli_done = true
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--pan="):  # debug / screenshots: initial pan position 0 (player) .. 1 (enemy)
				pan_pos = clampf(float(a.trim_prefix("--pan=")), 0.0, 1.0)
	if pan_arrows == null:
		pan_arrows = PAN_ARROWS_SCRIPT.new()
		hud_root.add_child(pan_arrows)
	if pan_arrows.get_index() < ship_status.get_index() - 1:
		hud_root.move_child(pan_arrows, ship_status.get_index() - 1)  # squeezed arrows may overlap HUD pieces: on top
	enemy_window.status_only = false
	_pan_apply()
	print("touch layout (pan): canvas %s, HUD ×%.3f, subsystems ×%.3f at %s, pause+cancel %s, boxes ×%.3f %s, stations %s %s, ships ×%.3f, player origin %s, TARGET ×%.3f art at %s, scene w %d, pan range %d, arrows %s, pan %.2f"
		% [vis, k, ks, sa, _touch_pause_at, kb, box_rects, "corner" if corner else "above drones", st, z, po, ws,
		art_at, roundi(scene_w), roundi(_pan_range), _pan_arrow_spots, pan_pos])


## Pan layout: the hazard status (HazardHud) in the top row right of the MENU wrench's solid right `left` (+ 2),
## 2 px under the canvas top, at the largest of k / 1.25 / 1 / 0.75 (never above the HUD scale k) that ends 2 px
## before `right` — the split layout's _touch_split_hazard rule at the pan HUD scale. Sets its status_xf; returns its
## canvas rect (empty without a hazard).
func _pan_hazard(left: float, right: float, k: float) -> Rect2:
	if hazard_hud == null or run == null or run.hazard == null:
		return Rect2()
	var b := HazardHud.status_bounds(hazard_hud.two_icons())
	var s := 0.75
	for c: float in [k, 1.25, 1.0, 0.75]:
		if c <= k + 0.001 and b.size.x * c <= right - left - 4:
			s = c
			break
	var at := Vector2(left + 2, 2).round()
	hazard_hud.status_xf = Transform2D(0.0, Vector2(s, s), 0.0, at - b.position * s)
	return Rect2(at, b.size * s)


## Pan layout: the widest pause overlay text at ×1 (touch titles font 62, instructions font 5, Text_pause1.png).
func _pan_pause_text_width() -> float:
	var w := 0.0
	var tp := HudDraw.tex("Text_pause1.png")
	if tp != null:
		w = tp.get_width()
	for id in ["paused_targeting", "paused_teleport", "paused_hacking", "paused_mind", "paused_room", "auto_paused",
			"paused"]:
		w = maxf(w, FtlData.ftl_text_width(62, HudDraw.txt(id)))
	for id in ["paused_targeting_text_beam", "paused_targeting_text", "paused_teleport_text_out",
			"paused_teleport_text_in", "paused_hacking_text", "paused_mind_text", "paused_room_text", "auto_paused_text"]:
		w = maxf(w, FtlData.ftl_text_width(5, HudDraw.txt(id)))
	return w


## Subsystems' solid pieces (frame coordinates in sub_group): the SUBSYSTEMS box, each subsystem's bars (top = its
## highest bar − 24) and buttons. Same list as the split layout's _touch_split_sub_pieces (copied: the layouts
## evolve separately).
func _pan_sub_pieces() -> Array[Rect2]:
	var sb := systems_bar
	var out: Array[Rect2] = [Rect2(HudLayout.SUBSYSTEM_BOX + Vector2(6, 6), Vector2(158 + 3 * sb.sub_spacing, 28))]
	for id in sb.sub_ids:
		var col: SystemPowerColumn = sb.columns.get(id)
		var sy := player_space.ship.sys(id)
		if col == null or sy == null:
			continue
		var top := col.loc.y + SystemPowerColumn.bar_y(sy, maxi(sy.get_level() - 1, 0)) - 24.0
		out.append(Rect2(col.loc.x + 19, top, 26, col.loc.y + 45 - top))
		if sb.buttons.has(id):
			var bt: Control = sb.buttons[id]
			out.append(Rect2(bt.position + Vector2(6, 19.0 if id == "battery" else 6.0), Vector2(28, 67)))
	return out


## Panel-local extent of a PC weapons / drones box with its system power column (left of the holder, ABOVE high).
func _pan_unit(p: Control) -> Rect2:
	var r := Rect2(Vector2.ZERO, p.size)
	var col: SystemPowerColumn = (p as WeaponPanel).column if p is WeaponPanel else systems_bar.columns.get("drones")
	if col != null:
		var hr := col.hit_rect()
		r = r.merge(Rect2(Vector2(-HudLayout.HOLDER_X, HudLayout.SYSTEM_BOX_Y - HudLayout.ARMAMENT_Y
			- SystemPowerColumn.ABOVE) + hr.position, hr.size))
	return r


## Phone "pan" layout (_touch_phone_pan: `--phone-layout=pan` / Options "Phone Screen Layout: Pan"; canvases under
## TOUCH_TALL_MIN_H, phone ~1600 × 720, closed Fold ~1766 × 720). The open-Fold pan idea (one wide ship scene panned
## horizontally, the enemy inside its full TARGET window; _pan_apply / _pan_input / pan arrows) packed into 720 px:
## - HUD ×k = TOUCH_TOPLEFT_SCALE (1.2 by default, `--hud-scale`): top-left block + crew list in the phone
##   arrangement (_touch_top_left: evade / O2 after the scrap box, crew list moved up), top buttons at the frame
##   origin, hazard status right of the MENU wrench (_pan_hazard);
## - subsystems + the + / − toggle in the top-right corner (the pan rule: ×max(1, k × 5/6), 6 from the edge, as high
##   as their solid pieces clear the top buttons / hazard);
## - ONE bottom row glued to the canvas bottom (PC-like): systems bar ×k bottom-left, then the weapons PC box, then
##   the drones PC box (PPAN_ROW_GAP apart), then the crew stations pair (TOUCH_STATION_SIZE, side by side, else
##   stacked) in the bottom-right corner; boxes at the largest kb ≤ k (eighths, ≥ PPAN_BOX_MIN) for which the row
##   fits; else the drones box above the weapons' right end (the Fold rule) at kb = k;
## - the free right strip under the subsystems: PAUSE / CANCEL stacked, glued on the bottom row, the pause text
##   above them (the Fold pan rule), the right pan arrow at the canvas edge; the left arrow on the left edge between
##   the crew list and the reactor, or (no room there) beside the right one;
## - the TARGET window at pan 1: right edge left of the strip / subsystems, as big as the height between the top
##   pieces and the bottom row over its x range allows (largest TOUCH_SHIP_SCALES step), centred in it;
## - the player ship at pan 0: _touch_fit_ship (largest step whose rooms clear every HUD piece, hull art inside the
##   canvas width, rooms centred in the free area); the TARGET art PAN_GAP × z right of its bounds; scene end =
##   the TARGET at its pan-1 place.
const PPAN_BOX_MIN := 1.0  # smallest box scale for the one-row arrangement (else the drones go above the weapons)
const PPAN_ROW_GAP := 6.0  # canvas px between the bottom row's pieces


func _touch_layout_phone_pan() -> void:
	var vis := get_viewport().get_visible_rect().size
	var h := _touch_height()
	var g := PAN_HUD_GAP
	var k := TOUCH_TOPLEFT_SCALE
	var enemy := _touch_enemy_present()
	var me := player_space.ship
	# Top-left block + crew list (phone arrangement), top buttons at the frame origin.
	_touch_top_left()
	command_hud.position = Vector2.ZERO
	var tops: Array[Rect2] = []  # top-anchored pieces' solid art (canvas)
	for r in [Rect2(0, 0, 375, 46), Rect2(7, 50, 121, 39), Rect2(132, 50, 193, 26), Rect2(383, 11, 122, 35),
			Rect2(Vector2(8, 96) + TOUCH_EVADE_OFFSET, Vector2(90, 42))]:
		tops.append(Rect2(r.position * k, r.size * k))
	var crew_r := Rect2()
	var n := crew_control.roster.size()
	if n > 0:
		var cr := crew_control.box_rect(0).merge(crew_control.box_rect(n - 1))
		crew_r = Rect2(Vector2(0, TOUCH_CREW_SHIFT_Y * k) + cr.position * k, cr.size * k)
		tops.append(crew_r)
	var tb := CommandHud.TOP_BUTTONS
	var menu := command_hud.menu_rect()
	var menu_r := (menu.position.x + 47.0) * k  # wrench solid right
	tops.append(Rect2(tb.position.x * k, 0, (HudLayout.SHIP_BUTTON.x - tb.position.x) * k, tb.end.y * k))
	tops.append(Rect2(HudLayout.SHIP_BUTTON.x * k, 0, menu_r - HudLayout.SHIP_BUTTON.x * k, menu.end.y * k))
	var hz := _pan_hazard(menu_r, vis.x, k)
	if hz.has_area():
		tops.append(hz)
	# Systems bar bottom-left ×k; its solid pieces (frame -> canvas).
	systems_bar.pivot_offset = Vector2.ZERO
	systems_bar.scale = Vector2(k, k)
	systems_bar.position = Vector2(0, h - HudLayout.FRAME.y * k)
	var bar_pos := systems_bar.position
	var bar_xf := func(r: Rect2) -> Rect2: return Rect2(bar_pos + r.position * k, r.size * k)
	var bar_right := 90.0
	var bar_pieces: Array[Rect2] = []
	for id in systems_bar.main_ids:
		if id == "weapons" or id == "drones":
			continue
		var x: float = systems_bar.box_x.get(id, 0)
		var w := 90.0 if SystemsBar.WIDE_BOXES.has(id) else 64.0
		var sy := me.sys(id)
		var top := HudLayout.SYSTEM_BOX_Y - HudLayout.POWER_PITCH * (sy.get_level() if sy else 1) - 24.0
		bar_pieces.append(bar_xf.call(Rect2(x, top, w, HudLayout.FRAME.y - top)))
		bar_right = maxf(bar_right, x + w)
		if systems_bar.buttons.has(id):
			var bt: Control = systems_bar.buttons[id]
			bar_pieces.append(bar_xf.call(Rect2(bt.position, bt.size)))
	var rc := systems_bar.reactor.counts().x if systems_bar.reactor else me.reactor_max
	var rtop := ReactorColumn.top_y(rc) - 4.0
	bar_pieces.append(bar_xf.call(Rect2(0, rtop, 90, HudLayout.FRAME.y - rtop)))
	bar_pieces.append(bar_xf.call(Rect2(0, HudLayout.FRAME.y - 30, bar_right, 30)))  # bottom wire line
	var bar_r := bar_pos.x + bar_right * k
	# Subsystems + toggle, top right (the pan rule).
	var ks := maxf(1.0, k * TOUCH_SPLIT_SUB_RATIO)
	var sub_rects: Array[Rect2] = []
	var sa := Vector2.ZERO
	var toggle_at := Vector2.INF
	if systems_bar.sub_group != null and not systems_bar.sub_ids.is_empty():
		var sub_b := systems_bar.subsystem_bounds()
		var pieces: Array[Rect2] = []
		for r in _pan_sub_pieces():
			pieces.append(Rect2((r.position - sub_b.position) * ks, r.size * ks))
		var tog := Rect2(Vector2(-TOUCH_CREW_BOX_GAP - 28.0 * ks, (sub_b.size.y - CrewList.BOX_BODY_H + 6) * ks),
			Vector2(28, CrewList.BOX_BODY_H - 6) * ks)  # the toggle's solid art
		pieces.append(tog)
		var reach := sub_b.size.x * ks
		for p in pieces:
			reach = maxf(reach, p.end.x)
		var x0 := vis.x - g - reach
		var y := 0.0
		for p in pieces:
			y = maxf(y, -p.position.y)
			for o in tops:
				if x0 + p.position.x < o.end.x + TOUCH_SPLIT_SUB_TOP_GAP and x0 + p.end.x > o.position.x - TOUCH_SPLIT_SUB_TOP_GAP:
					y = maxf(y, o.end.y + TOUCH_SPLIT_SUB_TOP_GAP - p.position.y)
		sa = Vector2(x0, y).round()
		for p in pieces:
			sub_rects.append(Rect2(sa + p.position, p.size))
		systems_bar.sub_group.scale = Vector2(ks / k, ks / k)
		systems_bar.sub_group.position = (sa - bar_pos) / k - sub_b.position * (ks / k)
		toggle_at = (sa + tog.position - Vector2(6, 6) * ks).round()
	var sub_left := vis.x
	var sub_bottom := 0.0
	for r in sub_rects:
		sub_left = minf(sub_left, r.position.x)
		sub_bottom = maxf(sub_bottom, r.end.y)
	_touch_engines_warning(sub_left, hz)
	# Bottom row: weapons PC box, drones PC box, stations, at the largest box scale kb that fits in one row.
	var wp: Control = weapon_panel if weapon_panel != null and weapon_panel.visible else null
	var dp: Control = drone_panel if drone_panel != null and is_instance_valid(drone_panel) and drone_panel.visible \
		else null
	var wu := _pan_unit(wp) if wp != null else Rect2()
	var du := _pan_unit(dp) if dp != null else Rect2()
	var w_low := wu.end.y
	if wp != null and (wp as WeaponPanel).autofire_btn != null:
		var af: Control = (wp as WeaponPanel).autofire_btn
		w_low = maxf(w_low, af.position.y + af.size.y)
	var b := TOUCH_STATION_SIZE
	var sg := TOUCH_STATION_GAP
	var rg := PPAN_ROW_GAP
	var kb := k
	var one_row := false
	var st_side := true
	var steps: Array = [k]
	for c: float in TOUCH_SHIP_SCALES:
		if c < k - 0.001 and c >= PPAN_BOX_MIN - 0.001:
			steps.append(c)
	for c: float in steps:
		var row_r := bar_r + (rg + wu.size.x * c if wp != null else 0.0) + (rg + du.size.x * c if dp != null else 0.0)
		if row_r + rg + 2 * b + sg + g <= vis.x:
			kb = c
			one_row = true
			break
		if row_r + rg + b + g <= vis.x:
			kb = c
			one_row = true
			st_side = false
			break
	var box_rects: Array[Rect2] = []  # holders (incl. their glow rows) and power columns, canvas
	var holders: Array[Rect2] = []
	var col_off := Vector2(-HudLayout.HOLDER_X, HudLayout.SYSTEM_BOX_Y - HudLayout.ARMAMENT_Y - SystemPowerColumn.ABOVE)
	var w_right := bar_r
	var w_top := h
	if wp != null:
		var at := Vector2(bar_r + rg - wu.position.x * kb, h - g - w_low * kb).round()
		wp.pivot_offset = Vector2.ZERO
		wp.scale = Vector2(kb, kb)
		wp.position = at
		holders.append(Rect2(at, wp.size * kb))
		var col: SystemPowerColumn = (wp as WeaponPanel).column
		if col != null:
			var hr := col.hit_rect()
			box_rects.append(Rect2(at + (col_off + hr.position) * kb, hr.size * kb))
		w_right = at.x + wu.end.x * kb
		w_top = at.y
	var st: Array[Rect2] = []
	if not one_row:  # (as the Fold pan) stations beside / stacked right of the weapons, else above their right end
		st_side = w_right + g + 2 * b + sg + g <= vis.x
		if not st_side and w_right + g + b + g > vis.x:
			st.assign([Rect2(vis.x - g - 2 * b - sg, w_top - g - b, b, b), Rect2(vis.x - g - b, w_top - g - b, b, b)])
	if st.is_empty():
		if st_side:
			st.assign([Rect2(vis.x - g - 2 * b - sg, h - g - b, b, b), Rect2(vis.x - g - b, h - g - b, b, b)])
		else:
			st.assign([Rect2(vis.x - g - b, h - g - 2 * b - sg, b, b), Rect2(vis.x - g - b, h - g - b, b, b)])
	if dp != null:
		var at := Vector2.ZERO
		if one_row:
			at = Vector2(w_right + rg - du.position.x * kb, h - g - du.end.y * kb).round()
		else:  # above the weapons holder's solid top, right edge 6 from the canvas edge, clear of what reaches up there
			var bottom := w_top + (PAN_HOLDER_GLOW * kb if wp != null else 0.0) - PAN_GLUE
			at = Vector2(vis.x - g - du.end.x * kb, 0)
			var dr := Rect2(at + du.position * kb, du.size * kb)
			for r in box_rects + st:
				if r.position.x < dr.end.x + PAN_GLUE and r.end.x + PAN_GLUE > dr.position.x and r.position.y < w_top - 0.5:
					bottom = minf(bottom, r.position.y - PAN_GLUE)
			at = Vector2(at.x, bottom - du.end.y * kb).round()
		dp.pivot_offset = Vector2.ZERO
		dp.scale = Vector2(kb, kb)
		dp.position = at
		holders.append(Rect2(at, dp.size * kb))
		var dcol: Control = systems_bar.columns.get("drones")
		if dcol != null:  # the bar's drones power column, left of its box (same place as in the panel's frame)
			var hr: Rect2 = (dcol as SystemPowerColumn).hit_rect()
			box_rects.append(Rect2(at + (col_off + hr.position) * kb, hr.size * kb))
			dcol.scale = Vector2(kb / k, kb / k)
			dcol.position = (at + col_off * kb - bar_pos) / k
	box_rects.append_array(holders)
	touch_weapon_scale = kb
	var extra: Array[Rect2] = []
	if wp != null and (wp as WeaponPanel).autofire_btn != null and (wp as WeaponPanel).autofire_btn.visible:
		var af: Control = (wp as WeaponPanel).autofire_btn
		extra.append(Rect2(wp.position + (af.position + Vector2(-2, -1)) * kb, (af.size + Vector2(4, 2)) * kb))
	_ppan_backing_set(holders, kb, wp if wp != null else dp, extra)
	# Pan arrows: the left one on the left edge between the crew list and the bar (largest free stretch), else beside
	# the right one; the right one on the right edge between the subsystems and the bottom row.
	var aw := (PAN_ARROWS_SCRIPT.EDGE + PAN_ARROWS_SCRIPT.SIZE.x) * k  # an arrow's edge strip
	var free_iv := func(obst: Array[Rect2], x0: float, x1: float) -> Vector2:  # largest free y stretch over x0..x1
		var ivs: Array = [[0.0, h]]
		for o in obst:
			if o.position.x >= x1 or o.end.x <= x0:
				continue
			var nxt := []
			for iv in ivs:
				if o.position.y > iv[0]:
					nxt.append([iv[0], minf(iv[1], o.position.y)])
				if o.end.y < iv[1]:
					nxt.append([maxf(iv[0], o.end.y), iv[1]])
			ivs = nxt
		var best := Vector2(h / 2, h / 2)
		for iv in ivs:
			if iv[1] - iv[0] > best.y - best.x:
				best = Vector2(iv[0], iv[1])
		return best
	var right_obst: Array[Rect2] = []
	right_obst.append_array(sub_rects)
	right_obst.append_array(box_rects)
	right_obst.append_array(st)
	var riv: Vector2 = free_iv.call(right_obst, vis.x - aw, vis.x)
	var rsc := clampf((riv.y - riv.x - 2 * g) / PAN_ARROWS_SCRIPT.SIZE.y, PAN_ARROW_MIN, k)
	var left_obst: Array[Rect2] = []
	left_obst.append_array(tops)
	left_obst.append_array(bar_pieces)
	var liv: Vector2 = free_iv.call(left_obst, 0.0, aw)
	var lsc := clampf((liv.y - liv.x - 2 * g) / PAN_ARROWS_SCRIPT.SIZE.y, PAN_ARROW_MIN, k)
	var left_beside := liv.y - liv.x - 2 * g < PAN_ARROWS_SCRIPT.SIZE.y * PAN_ARROW_MIN
	var ry := roundf((riv.x + riv.y) / 2)
	var arrow_y := {"left": roundf((liv.x + liv.y) / 2), "right": ry}
	var arrow_sc := {"left": lsc, "right": rsc}
	var arrow_x := {}
	if left_beside:  # both on the right edge, the left one above the right one, centred in its free stretch
		var sc2 := clampf((riv.y - riv.x - 3 * g) / (2 * PAN_ARROWS_SCRIPT.SIZE.y), PAN_ARROW_MIN, k)
		var ah := PAN_ARROWS_SCRIPT.SIZE.y * sc2
		var mid := (riv.x + riv.y) / 2
		arrow_sc = {"left": sc2, "right": sc2}
		arrow_y = {"left": roundf(mid - g / 2 - ah / 2), "right": roundf(mid + g / 2 + ah / 2)}
		arrow_x.left = roundf(vis.x - (PAN_ARROWS_SCRIPT.EDGE + PAN_ARROWS_SCRIPT.SIZE.x) * sc2)
		rsc = sc2
	var strip_r := roundf(vis.x - (PAN_ARROWS_SCRIPT.EDGE + PAN_ARROWS_SCRIPT.SIZE.x) * rsc - g)
	var arrow_rects: Array[Rect2] = []
	for id in ["left", "right"]:
		var sc: float = arrow_sc[id]
		var s := PAN_ARROWS_SCRIPT.SIZE * sc
		var ax: float = arrow_x.get(id, PAN_ARROWS_SCRIPT.EDGE * sc if id == "left" else vis.x - PAN_ARROWS_SCRIPT.EDGE * sc - s.x)
		arrow_rects.append(Rect2(Vector2(ax, float(arrow_y[id]) - s.y / 2).round(), s.round()))
	_pan_arrow_spots = {"y": arrow_y, "scale": arrow_sc, "x": arrow_x}
	# PAUSE + CANCEL stacked, right-aligned in the strip, glued on the bottom row pieces under it (holders: on their
	# solid top); the pause text centred above them, at kt (k, down to 1 when the strip under the subsystems is narrow).
	var pair := Vector2(TouchCombatButtons.BASE_SIZE.x, TouchCombatButtons.BASE_SIZE.y * 2 + TouchCombatButtons.GAP) * k
	var strip_l := strip_r - pair.x
	var glue := h - g
	for r in box_rects + st:
		if r.position.x < strip_r and r.end.x > strip_l:
			glue = minf(glue, r.position.y + (PAN_HOLDER_GLOW * kb if holders.has(r) else 0.0) - PAN_GLUE)
	_touch_pause_at = Rect2(Vector2(strip_l, roundf(glue - pair.y)), pair.round())
	# Pause text (TARGETING / ROOM SELECTION ... + instruction, PAUSED) at ×k where PC FTL has it: bottom centre,
	# right above the weapons box (centred on its holder; no weapons: on the free part of the bottom row), PAN_HUD_GAP
	# over the highest bottom-row piece under it. The ship's rooms keep clear of it.
	var kt := k
	var text_w := ceilf(_pan_pause_text_width() * kt)
	var tb_bottom := Vector2(HudLayout.PAUSE_TEXT.x, HudLayout.PAUSE_HINT.y + 12)
	var text_h := (tb_bottom.y - HudLayout.PAUSE_TEXT.y + 32) * kt
	var tcx := (holders[0].get_center().x if wp != null else (bar_r + strip_l) / 2)
	var tl := clampf(tcx - text_w / 2, bar_r, strip_l - g - text_w)
	var tbot := h
	for r in box_rects + st + bar_pieces:
		if r.position.x < tl + text_w and r.end.x > tl:
			tbot = minf(tbot, r.position.y + (PAN_HOLDER_GLOW * kb if holders.has(r) else 0.0) - g)
	var text_rect := Rect2(roundf(tl), roundf(tbot - text_h), text_w, ceilf(text_h))
	var text_at := Vector2(text_rect.get_center().x, text_rect.end.y)
	pause_overlay.scale = Vector2(kt, kt)
	pause_overlay.position = (text_at - tb_bottom * kt).round()
	# Crew stations buttons and the + / − toggle.
	var local_st := []
	for r in st:
		local_st.append(Rect2((r.position - crew_list.position) / k, r.size / k))
	crew_list.touch_button_box = null
	crew_list.touch_station_rects = local_st
	if toggle_at != Vector2.INF:
		if touch_power == null:
			touch_power = TouchPowerToggle.new()
			touch_power.held_fn = func() -> bool: return _gestures().held_minus()  # held finger = − for now
			hud_root.add_child(touch_power)
			hud_root.move_child(touch_power, crew_list.get_index() + 1)
		touch_power.scale = Vector2(ks, ks)
		touch_power.position = toggle_at
	if touch_power != null:
		touch_power.visible = toggle_at != Vector2.INF
	# Every fixed HUD piece: the player's rooms keep clear of them at pan 0.
	var hud: Array[Rect2] = []
	hud.append_array(tops)
	hud.append_array(bar_pieces)
	hud.append_array(sub_rects)
	hud.append_array(box_rects)
	hud.append_array(st)
	hud.append_array([_touch_pause_at, text_rect])
	hud.append_array(arrow_rects)
	# Ship scale: the largest step with the whole hull art on the canvas at pan 0 (`inside`), or ONE step more with
	# the hull's top / bottom rows allowed past the canvas edges (rooms still clear of the HUD) — tall hulls (Lanius,
	# Kestrel's engine pods) would otherwise stay small, and an unbounded step pushes the hull far under both rows.
	var fit := _touch_fit_ship([], vis.x, h, hud, INF, true)
	if not fit.is_empty():
		var i := TOUCH_SHIP_SCALES.find(fit.zoom)
		var f2 := _touch_fit_ship([], vis.x, h, hud, TOUCH_SHIP_SCALES[maxi(i - 1, 0)] if i >= 0 else fit.zoom)
		if not f2.is_empty() and f2.zoom > fit.zoom + 0.001:
			fit = f2
	else:
		fit = _touch_fit_ship([], vis.x, h, hud)
	if fit.is_empty():
		fit = {"origin": player_origin(), "zoom": 1.0}
	var z: float = fit.zoom
	touch_ship_zoom = z
	var po: Vector2 = fit.origin
	var pr := _pan_ship_rect(me)
	var p_right := po.x + pr.end.x * z
	# TARGET window at pan 1: right edge `reserve` before the canvas edge (left of the strip / subsystems / arrows).
	var reserve := g
	for r in sub_rects + [Rect2(strip_l, 0, strip_r - strip_l, 1)] + arrow_rects:
		if r.position.x > vis.x / 2:  # (the left arrow may be on the left edge)
			reserve = maxf(reserve, vis.x - r.position.x + g)
	var art := TOUCH_ENEMY_ART
	var under: Array[Rect2] = [_touch_pause_at, text_rect]
	under.append_array(box_rects + st + bar_pieces)
	var room := func(c: float) -> Vector2:
		var wl := vis.x - reserve - art.size.x * c
		var wr := vis.x - reserve
		var t := 0.0
		for r in tops + sub_rects:
			if r.position.x < wr and r.end.x > wl:
				t = maxf(t, r.end.y + PAN_GLUE)
		var bt := h
		for r in under:
			if r.position.x < wr and r.end.x > wl:
				bt = minf(bt, r.position.y + (PAN_HOLDER_GLOW * kb if holders.has(r) else 0.0) - PAN_GLUE)
		return Vector2(t, bt)
	var ws := TOUCH_SHIP_SCALES[TOUCH_SHIP_SCALES.size() - 1] as float
	for c: float in TOUCH_SHIP_SCALES:
		var rm: Vector2 = room.call(c)
		if art.size.y * c <= rm.y - rm.x and vis.x - reserve - art.size.x * c >= 0.0:
			ws = c
			break
	var rm2: Vector2 = room.call(ws)
	var art_frame := HudLayout.ENEMY_FRAME.position + art.position
	var art_at := Vector2(roundf(p_right + PAN_GAP * z), roundf((rm2.x + rm2.y) / 2 - art.size.y * ws / 2))
	var xf := Transform2D(0.0, Vector2(ws, ws), 0.0, art_at - art_frame * ws)
	var scene_w := art_at.x + art.size.x * ws + reserve if enemy else vis.x
	_pan_range = maxf(roundf(scene_w - vis.x), 0.0)
	_pan_scene = {"z": z, "k": k, "po": po, "xf": xf, "enemy": enemy}
	if not _pan_cli_done:
		_pan_cli_done = true
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--pan="):  # debug / screenshots: initial pan position 0 (player) .. 1 (enemy)
				pan_pos = clampf(float(a.trim_prefix("--pan=")), 0.0, 1.0)
	if pan_arrows == null:
		pan_arrows = PAN_ARROWS_SCRIPT.new()
		hud_root.add_child(pan_arrows)
	if pan_arrows.get_index() < ship_status.get_index() - 1:
		hud_root.move_child(pan_arrows, ship_status.get_index() - 1)  # drawn above the HUD pieces
	enemy_window.status_only = false
	_touch_center_band()
	_pan_apply()
	print(("touch layout (phone pan): canvas %s, HUD ×%.3f, subsystems ×%.3f at %s, boxes ×%.3f %s (%s), stations %s,"
		+ " pause+cancel %s, text ×%.3f %s, arrows %s, ship ×%.3f origin %s, TARGET ×%.3f art at %s (pan 0), scene w %d,"
		+ " pan range %d, pan %.2f") % [vis, k, ks, sa, kb, box_rects, "one row" if one_row else "drones above", st,
		_touch_pause_at, kt, text_rect, _pan_arrow_spots, z, po, ws, art_at, roundi(scene_w), roundi(_pan_range),
		pan_pos])


## Phone pan: a dark backing (PPAN_BACKING) inside the weapons / drones holders' solid border (image x 10 .. w − 7,
## y 10 .. 60, × kb), drawn right under the boxes: the big player ship's hull art may pass under the bottom row and
## would show through the translucent holder art (box names unreadable). `holders` = the holders' canvas rects.
const PPAN_BACKING := Color(0.02, 0.04, 0.05, 0.85)
var _ppan_backing: Control
var _ppan_backs: Array[Rect2] = []


func _ppan_backing_set(holders: Array[Rect2], kb: float, below: Control, extra: Array[Rect2] = []) -> void:
	_ppan_backs.clear()
	for r in holders:
		_ppan_backs.append(Rect2(r.position + Vector2(10, 10) * kb, Vector2(r.size.x / kb - 17, 50) * kb))
	_ppan_backs.append_array(extra)  # (AUTOFIRE)
	if _ppan_backing == null:
		_ppan_backing = Control.new()
		_ppan_backing.name = "PhonePanBacking"
		_ppan_backing.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ppan_backing.draw.connect(func() -> void:
			for r in _ppan_backs:
				_ppan_backing.draw_rect(r, PPAN_BACKING))
		hud_root.add_child(_ppan_backing)
	var target := _ppan_backing.get_index()
	for p: Control in [below, weapon_panel, drone_panel]:
		if p != null and is_instance_valid(p) and p.get_parent() == hud_root:
			target = mini(target, p.get_index())
	if target < _ppan_backing.get_index():
		hud_root.move_child(_ppan_backing, target)
	_ppan_backing.visible = true
	_ppan_backing.queue_redraw()


## Places the scene for the current pan_pos: the player space (whole canvas), the TARGET window with the enemy
## space inside it (_place_touch_enemy with the window transform shifted by the pan), the arrows and the backdrop
## parallax.
func _pan_apply() -> void:
	if _pan_scene.is_empty() or player_space == null:
		return
	var vis := get_viewport().get_visible_rect().size
	var off := roundf(clampf(pan_pos, 0.0, 1.0) * _pan_range)
	var z: float = _pan_scene.z
	var k: float = _pan_scene.k
	var shift := Vector2(off, 0)
	player_space.position = Vector2.ZERO
	player_space.size = vis
	player_space.set_fixed_origin(_pan_scene.po - shift, z)
	var enemy: bool = _pan_scene.enemy
	enemy_window.visible = enemy
	enemy_window_back.visible = enemy
	enemy_space.visible = enemy
	if enemy:
		var xf: Transform2D = _pan_scene.xf
		xf.origin -= shift
		_place_touch_enemy(xf)
	if pan_arrows != null:
		pan_arrows.visible = enemy
		pan_arrows.set("art_scale", k)
		pan_arrows.set("canvas_w", vis.x)
		pan_arrows.set("mid_y", roundf(vis.y / 2))
		pan_arrows.set("pan", pan_pos)
		pan_arrows.set("can_pan", _pan_range > 0.0)
		pan_arrows.set("side_y", _pan_arrow_spots.get("y", {}))
		pan_arrows.set("side_scale", _pan_arrow_spots.get("scale", {}))
		pan_arrows.set("side_x", _pan_arrow_spots.get("x", {}))  # phone pan: the left arrow may sit by the right one
		pan_arrows.queue_redraw()
	if space_backdrop != null:
		space_backdrop.position.x = -roundf(off * PAN_PARALLAX)


func _pan_set(v: float) -> void:
	pan_pos = clampf(v, 0.0, 1.0)
	_pan_apply()


## Animated pan to `v` (arrow buttons).
func _pan_to(v: float) -> void:
	if _pan_tween != null and _pan_tween.is_valid():
		_pan_tween.kill()
	_pan_tween = create_tween()
	_pan_tween.tween_method(_pan_set, pan_pos, clampf(v, 0.0, 1.0), 0.35).set_trans(Tween.TRANS_SINE) \
		.set_ease(Tween.EASE_IN_OUT)


## Pan layout input (main._input, HUD-layer coordinates): arrow buttons (tap: pan to that end), two-finger
## horizontal drag (the fingers' average motion), trackpad / Android pan gesture, desktop Shift + wheel or
## wheel left / right (PAN_STEP per tick), ← / → keys (PAN_STEP). True = consumed.
func _pan_input(event: InputEvent) -> bool:
	if not _touch_pan() or _pan_range <= 0.0 or (run != null and run.modal()):
		return false
	var step := PAN_STEP / _pan_range
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed and pan_arrows != null:
			var id: String = pan_arrows.call("arrow_at", mb.position)
			if id != "":
				_pan_to(0.0 if id == "left" else 1.0)
				return true
		var d := 0
		if mb.button_index == MOUSE_BUTTON_WHEEL_RIGHT \
				or (mb.shift_pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			d = 1
		elif mb.button_index == MOUSE_BUTTON_WHEEL_LEFT \
				or (mb.shift_pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP):
			d = -1
		if d != 0:
			if mb.pressed:
				_pan_set(pan_pos + d * step * maxf(mb.factor, 1.0))
			return true
	elif event is InputEventPanGesture:
		_pan_set(pan_pos + (event as InputEventPanGesture).delta.x * 0.25 * step)
		return true
	elif event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed:
			_pan_touches[st.index] = st.position
		else:
			_pan_touches.erase(st.index)
		return _pan_touches.size() >= 2
	elif event is InputEventScreenDrag:
		var sd := event as InputEventScreenDrag
		_pan_touches[sd.index] = sd.position
		if _pan_touches.size() >= 2:
			_pan_set(pan_pos - sd.relative.x / _pan_touches.size() / _pan_range)
			return true
	elif event is InputEventKey:
		var kk := event as InputEventKey
		if kk.pressed and (kk.keycode == KEY_LEFT or kk.keycode == KEY_RIGHT):
			_pan_set(pan_pos + (step if kk.keycode == KEY_RIGHT else -step))
			return true
	return false
