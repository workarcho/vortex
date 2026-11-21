class_name TitleState
extends RefCounted
## Title flow rules (rules/main_menu.md): the main menu (MainMenu) and the hangar (ShipBuilder). No UI: the
## views report gestures to the InputProfile, which sends intents here (`apply`). The scene (scripts/title.gd)
## consumes `pending` (quit / options / toast / start) and builds the run from `run_config()`.

enum Screen { MENU, HANGAR }

# ------------------------------------------------------------------ intents
const MENU_CONTINUE := "menu_continue"
const MENU_NEW_GAME := "menu_new_game"
const MENU_TUTORIAL := "menu_tutorial"
const MENU_STATS := "menu_stats"
const MENU_OPTIONS := "menu_options"
const MENU_CREDITS := "menu_credits"
const MENU_QUIT := "menu_quit"
const HANGAR_BACK := "hangar_back"  # ShipBuilder::Close (Esc on PC, the back button on touch)
const NEXT_SHIP := "next_ship"  # CycleShipNext (right arrow button / Right key)
const PREV_SHIP := "prev_ship"  # CycleShipPrevious (left arrow button / Left key)
const SET_TYPE := "set_type"  # {arg: 0 A / 1 B / 2 C}: SwapType
const RANDOM_SHIP := "random_ship"
const SET_DIFFICULTY := "set_difficulty"  # {arg: 0 easy / 1 normal / 2 hard}
const SET_AE := "set_ae"  # {arg: 0 disabled / 1 enabled}
const TOGGLE_ROOMS := "toggle_rooms"  # SHOW ROOMS / HIDE ROOMS
const RENAME_SHIP := "rename_ship"  # {text}
const RENAME_CREW := "rename_crew"  # {arg: crew index, text}
const CREW_LOOK := "crew_look"  # {arg: crew index, dir: −1 / +1}: customize arrows (gender / colours)
const START := "start"
## ConfirmWindow `confirm_new_game` answer {arg: 1 yes / 0 no} (MainMenu::MouseClick with a save present).
const NEW_GAME_CONFIRM := "new_game_confirm"

## ShipBuilder SHIP_BLUEPRINTS (shipId order) and SHIP_BLUEPRINT_ORDER (display order of the cycle).
const SHIP_BLUEPRINTS := ["PLAYER_SHIP_HARD", "PLAYER_SHIP_STEALTH", "PLAYER_SHIP_MANTIS", "PLAYER_SHIP_CIRCLE",
	"PLAYER_SHIP_FED", "PLAYER_SHIP_JELLY", "PLAYER_SHIP_ROCK", "PLAYER_SHIP_ENERGY", "PLAYER_SHIP_CRYSTAL",
	"PLAYER_SHIP_ANAEROBIC"]
const SHIP_ORDER := [0, 3, 4, 7, 2, 5, 6, 1, 9, 8]
const LANIUS := 9  # needs Advanced Edition content (like every type C)
const SHIP_NAME_MAX := 16  # TextInput(0x10)
const CREW_NAME_MAX := 15  # CrewRoster rename limit
const SAVE_FILE := "user://continue.sav"  # SaveGame.path (rules/save_and_profile.md §1)
const UNLOCK_SETTING := "ftl/hangar/unlock_all_ships"

var screen := Screen.MENU
var ship_id := 0
var ship_type := 0
var difficulty := 1  # Settings::difficulty: 0 easy, 1 normal, 2 hard
var ae := true  # Settings::bDlcEnabled
var show_rooms := true
var ship_name := ""
var crew: Array = []  # identity dictionaries {race, name, male, colors}, blueprint order
var preview: ShipState = null  # the hangar's ShipManager (rebuilt by SwitchShip)
var pending := ""  # last outcome for the scene: quit / options / stats / toast:<text> / start / continue
var unlock_all := false
var confirm_new_game := false  # the "new game deletes your save" window is open


func _init() -> void:
	unlock_all = bool(ProjectSettings.get_setting(UNLOCK_SETTING, false))


func apply(intent: Dictionary) -> bool:
	var t := String(intent.get("type", ""))
	var arg := int(intent.get("arg", -1))
	if screen == Screen.MENU:
		match t:
			MENU_NEW_GAME:
				if confirm_new_game:
					return false
				if continue_enabled():  # MainMenu: a save exists -> ConfirmWindow first (YES deletes it)
					confirm_new_game = true
					pending = "confirm_new_game"
					return true
				open_hangar()
				return true
			NEW_GAME_CONFIRM:
				if not confirm_new_game:
					return false
				confirm_new_game = false
				if arg == 1:
					open_hangar()
					pending = "delete_save"
				return true
			MENU_CONTINUE:
				if not continue_enabled():
					return false
				pending = "continue"
				return true
			MENU_OPTIONS:
				pending = "options"
				return true
			MENU_QUIT:
				pending = "quit"
				return true
			MENU_STATS:
				pending = "stats"
				return true
			MENU_TUTORIAL, MENU_CREDITS:
				pending = "toast:%s is not implemented yet" % t.trim_prefix("menu_").capitalize()
				return true
		return false
	match t:
		HANGAR_BACK:
			screen = Screen.MENU
			preview = null
			return true
		NEXT_SHIP, PREV_SHIP:
			var n := cycle(1 if t == NEXT_SHIP else -1)
			if n == ship_id:
				return false
			switch_ship(n, ship_type)
			return true
		SET_TYPE:
			if arg == ship_type or not type_available(arg):
				return false
			switch_ship(ship_id, arg)
			return true
		RANDOM_SHIP:
			var pool := []
			for i in 30:  # every (ship, type) the profile has unlocked
				if unlocked(i % 10, i / 10):
					pool.append(i)
			if pool.is_empty():
				return false
			var pick: int = pool[randi() % pool.size()]
			switch_ship(pick % 10, pick / 10)
			return true
		SET_DIFFICULTY:
			if arg < 0 or arg > 2 or arg == difficulty:
				return false
			difficulty = arg
			return true
		SET_AE:
			if (arg == 1) == ae:
				return false
			ae = arg == 1
			return true
		TOGGLE_ROOMS:
			show_rooms = not show_rooms
			return true
		RENAME_SHIP:
			var s := String(intent.get("text", "")).strip_edges().left(SHIP_NAME_MAX)
			if s == "":
				return false
			ship_name = s
			return true
		RENAME_CREW:
			var s := String(intent.get("text", "")).strip_edges().left(CREW_NAME_MAX)
			if s == "" or arg < 0 or arg >= crew.size():
				return false
			crew[arg].name = s
			_sync_preview_crew()
			return true
		CREW_LOOK:
			if arg < 0 or arg >= crew.size():
				return false
			_cycle_look(arg, int(intent.get("dir", 1)))
			_sync_preview_crew()
			return true
		START:
			if not can_start():
				return false
			pending = "start"
			return true
	return false


static func make(type: String, arg := -1, extra := {}) -> Dictionary:
	var d := {"type": type, "arg": arg}
	d.merge(extra)
	return d


# ------------------------------------------------------------------ menu

## MainMenu::OnLoop: continueButton.SetActive(FileHelper::fileExists(save file)).
func continue_enabled() -> bool:
	return SaveGame.exists()


## MainMenu::MouseClick (start): with a save -> confirm window (it deletes the save); without -> ShipBuilder::Open.
func open_hangar() -> void:
	screen = Screen.HANGAR
	pending = ""
	if preview == null:
		switch_ship(ship_id, ship_type)


# ------------------------------------------------------------------ hangar

static func blueprint_of(id: int, type: int) -> String:
	return SHIP_BLUEPRINTS[id] + ["", "_2", "_3"][type]


## ScoreKeeper::GetShipUnlocked: the layout must exist in the data and be unlocked in the player profile
## (PlayerProfile, rules/save_and_profile.md §2.2); the project setting `ftl/hangar/unlock_all_ships` (default OFF,
## a dev switch like ScoreKeeper::forceUnlockAll) unlocks every existing layout. A profile's UNLOCK ALL
## (ProfileSlots) unlocks them in the profile itself.
func unlocked(id: int, type: int) -> bool:
	if not layout_exists(id, type):
		return false
	return unlock_all or PlayerProfile.current().is_unlocked(id, type)


## A hangar layout: in range, has a blueprint in the data, and is not a C of the Crystal / Lanius.
static func layout_exists(id: int, type: int) -> bool:
	if id < 0 or id >= SHIP_BLUEPRINTS.size() or type < 0 or type > 2:
		return false
	if type == 2 and (id == 8 or id == LANIUS):
		return false  # no C in the hangar (CheckTypes moves the button off-screen; PLAYER_SHIP_ANAEROBIC_3 unused)
	return FtlData.has_ship_blueprint(blueprint_of(id, type))


## CheckTypes: B / C usable when unlocked; the crystal and lanius have no C (button moved off-screen).
func type_available(type: int) -> bool:
	return unlocked(ship_id, type)


func has_type_c() -> bool:
	return ship_id != 8 and ship_id != 9


## GetNextShipId / CycleShipPrevious: walk SHIP_ORDER from the current ship, skipping ships whose current type
## is locked; 10 tries, then stay.
func cycle(dir: int) -> int:
	var pos := SHIP_ORDER.find(ship_id)
	for i in SHIP_ORDER.size():
		pos = posmod(pos + dir, SHIP_ORDER.size())
		var id: int = SHIP_ORDER[pos]
		if unlocked(id, ship_type):
			return id
	return ship_id


## SwitchShip: new ShipManager from the blueprint, its name in the name box, crew boxes rebuilt.
func switch_ship(id: int, type: int) -> void:
	if not unlocked(id, type):
		type = 0
	ship_id = id
	ship_type = type
	preview = ShipState.new(blueprint_of(id, type), true)
	preview.shield_layers = 0  # the hangar shows the ship without its bubble
	preview.shield_up_t = -1.0
	ship_name = ship_title(blueprint_of(id, type))
	crew.clear()
	for c in preview.crew:
		crew.append({"race": c.race, "name": c.name_long, "male": c.male, "colors": c.color_choices.duplicate()})


## The blueprint's <name> text (e.g. "The Kestrel").
static func ship_title(bp: String) -> String:
	var t := FtlData._text_field(FtlData.ship_blueprint_text(bp), "name")
	return t if t != "" else bp


static func ship_class(bp: String) -> String:
	return FtlData._text_field(FtlData.ship_blueprint_text(bp), "class")


## Layout B/C or the lanius need AE content (ShipBuilder::OnRender: tint 0.5 + advanced_warning, START off).
func needs_ae() -> bool:
	return ship_id == LANIUS or ship_type == 2


func can_start() -> bool:
	return screen == Screen.HANGAR and preview != null and (ae or not needs_ae())


func _cycle_look(i: int, dir: int) -> void:
	var id: Dictionary = crew[i]
	var race := String(id.race)
	var layers := FtlData.crew_colors(race)
	var cols: Array = id.colors
	if race == "human":
		# human: gender flips with the first colour layer wrap [inferred]
		var n := (layers[0] as Array).size() if not layers.is_empty() else 1
		var c0 := int(cols[0]) if not cols.is_empty() else 0
		c0 += dir
		if c0 < 0 or c0 >= n:
			id.male = not bool(id.male)
			c0 = posmod(c0, n)
		if not cols.is_empty():
			cols[0] = c0
	elif not layers.is_empty():
		cols[0] = posmod(int(cols[0]) + dir, (layers[0] as Array).size())


func _sync_preview_crew() -> void:
	if preview == null:
		return
	for i in mini(crew.size(), preview.crew.size()):
		CrewIdentity.apply(preview.crew[i], crew[i])


## What main.gd needs to start the run (Start → the existing `--run` flow).
func run_config() -> Dictionary:
	return {"ship": blueprint_of(ship_id, ship_type), "difficulty": difficulty, "ae": ae, "ship_name": ship_name,
		"crew": crew.duplicate(true)}


## Gives a new run's player ship the hangar's ship name and crew identities (blueprint order).
static func apply_to_ship(ship: ShipState, cfg: Dictionary) -> void:
	if cfg.has("ship_name"):
		ship.ship_title = String(cfg.ship_name)
	var ids: Array = cfg.get("crew", [])
	for i in mini(ids.size(), ship.crew.size()):
		if String(ids[i].get("race", "")) == ship.crew[i].race:
			CrewIdentity.apply(ship.crew[i], ids[i])
