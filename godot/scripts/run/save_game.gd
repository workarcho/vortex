class_name SaveGame
extends RefCounted
## The run save, our continue.sav (rules/save_and_profile.md §1). Vanilla writes it (WorldManager::SaveGame) when
## the player leaves a running game: Esc menu MAIN MENU (command 5) and SAVE+QUIT (command 8), the window's close
## request (CApp::OnRequestExit) and the app being suspended (CApp::OnSuspend, mobile); never during the tutorial
## or after a game over. Every frame of a game over, RESTART and HANGAR delete it (FileHelper::deleteAllSaveFiles).
## The main menu's Continue is active while the file exists (MainMenu::OnLoop: fileExists).
##
## Format (ours): one Godot binary Variant (`FileAccess.store_var`, objects never decoded) =
## {version, kind: "ftl-proto-run", setup (hangar run_config), run: RunState variables (SaveCodec; every variable
## of RunState except RUN_SKIP, so new plain-data fields — quests, ... — are saved without touching this file),
## engine (EventEngine streams and pools), ship (ShipSave), enemy_ship (ShipSave of the event ship, mid-combat),
## crew_rng (CrewIdentity stream), inventory (ShipInventory)}. Written to `<path>.new` and renamed, like
## ScoreKeeper::Save's ae_prof.new.sav.

const VERSION := 1
const KIND := "ftl-proto-run"
## RunState variables not saved: rebuilt (ship, engine, mgmt), debug (log) or open-window state (vanilla loads
## into the game with no window open; the event box / messages are kept).
const RUN_SKIP := ["ship", "engine", "mgmt", "log", "map_open", "leave_crew_open", "choosing_sector",
	"selected_sector", "store_open", "store_pending", "store_selected", "store_page", "store_tab", "store_message",
	"highlighted", "selected"]
const ENGINE_FIELDS := ["level", "difficulty", "ae", "used_unique", "used_text", "crew_rarity"]

## user:// file. Tests point it elsewhere.
static var path := "user://continue.sav"
## Write to disk at all (the real game: set by title.gd; tests set it for their own path). Off = nothing is written
## or deleted, `exists()` reads the disk still.
static var persist := false
static var last_error := ""


static func exists() -> bool:
	return FileAccess.file_exists(path)


## FileHelper::deleteAllSaveFiles.
static func delete() -> void:
	if not persist:
		return
	for p in [path, path + ".new"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


## The whole save as a Variant (no file).
static func build(run: RunState, enemy_ship: ShipState = null, setup := {}) -> Dictionary:
	var d := {"version": VERSION, "kind": KIND, "setup": SaveCodec.encode(setup)}
	d.run = SaveCodec.props_of(run, RUN_SKIP)
	var eng := {"rng": SaveCodec.rng_state(run.engine.rng)}
	for f in ENGINE_FIELDS:
		eng[f] = SaveCodec.encode(run.engine.get(f))
	d.engine = eng
	d.ship = ShipSave.snapshot(run.ship)
	# WorldManager::SaveGame → CommandGui::ConfirmUpgrades: upgrades bought in an open upgrade window count.
	var up := run.mgmt.upgrades
	for id in up.temp:
		if d.ship.systems.has(id):
			d.ship.systems[id].level = int(d.ship.systems[id].get("level", 0)) + int(up.temp[id])
	if up.reactor_temp > 0:
		d.ship.fields.reactor_max = int(d.ship.fields.reactor_max) + up.reactor_temp
	d.inventory = SaveCodec.encode(run.mgmt.inv)
	d.crew_rng = SaveCodec.rng_state(CrewIdentity.rng)
	if enemy_ship != null and not run.enemy.is_empty() and not run.enemy.get("done", false) \
			and not enemy_ship.is_destroyed():
		d.enemy_ship = ShipSave.snapshot(enemy_ship)
	return d


## WorldManager::SaveGame. Returns true when written. Not after the run ended (game over / victory).
static func save_run(run: RunState, enemy_ship: ShipState = null, setup := {}) -> bool:
	last_error = ""
	if run == null or run.over != "":
		return false
	if not persist:
		return false
	var data := build(run, enemy_ship, setup)
	var tmp := path + ".new"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		last_error = "open %s: %s" % [tmp, error_string(FileAccess.get_open_error())]
		push_warning("save failed: " + last_error)
		return false
	f.store_var(data, false)
	f.close()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var err := DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp), ProjectSettings.globalize_path(path))
	if err != OK:
		last_error = "rename: %s" % error_string(err)
		return false
	return true


## Reads the save file. {} when missing / unreadable / another format.
static func read() -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var v: Variant = f.get_var(false)
	f.close()
	if not v is Dictionary or String(v.get("kind", "")) != KIND or int(v.get("version", 0)) > VERSION:
		return {}
	return v


## WorldManager::LoadGame from the file. null when there is nothing to load.
static func load_run() -> RunState:
	var d := read()
	if d.is_empty():
		return null
	return restore(d)


## A RunState from a save Variant (`build`). The event ship's snapshot is kept on `run.enemy.saved_ship` until the
## scene builds that ship (`take_enemy_ship`).
static func restore(d: Dictionary) -> RunState:
	var r := RunState.new()
	r.engine = EventEngine.new()
	var eng: Dictionary = d.get("engine", {})
	for f in ENGINE_FIELDS:
		if eng.has(f):
			SaveCodec.decode_into(r.engine, f, eng[f])
	SaveCodec.set_rng(r.engine.rng, eng.get("rng"))
	SaveCodec.set_rng(CrewIdentity.rng, d.get("crew_rng"))
	r.ship = ShipSave.restore(d.ship)
	SaveCodec.set_props(r, d.get("run", {}))
	var inv: Variant = SaveCodec.decode(d.get("inventory"))
	if inv is ShipInventory:
		r.mgmt.inv = inv
	if d.has("enemy_ship") and not r.enemy.is_empty():
		r.enemy["saved_ship"] = d.enemy_ship
	# Gameplay settings frozen when the run started stay frozen (rules/hooks.md "Settings").
	if not r.frozen_settings.is_empty():
		Settings.freeze_from(r.frozen_settings)
	r.score.saved = false
	ProfileTracker.ensure()
	Hooks.emit(&"run_loaded", r)
	return r


## The hangar setup the run was started with (title.gd / main.gd run_setup).
static func setup_of(d: Dictionary) -> Dictionary:
	var s: Variant = SaveCodec.decode(d.get("setup", {}))
	return s if s is Dictionary else {}


## The event ship for the scene: the saved one (state put back over the ShipGenerator ship) once after a load,
## else a fresh `build_enemy_ship`.
static func take_enemy_ship(run: RunState) -> ShipState:
	var es := run.build_enemy_ship()
	if run.enemy.has("saved_ship"):
		ShipSave.apply(es, run.enemy.saved_ship)
		run.enemy.erase("saved_ship")
	return es
