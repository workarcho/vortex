class_name ProfileSlots
extends RefCounted
## [ours] Three player profiles (vanilla has one): each slot is its own PlayerProfile file and its own run save.
## Slot 0 keeps the original names (user://profile.sav, user://continue.sav), slots 1 and 2 use
## profile_<n>.sav / continue_<n>.sav (n = slot + 1). The active slot lives in user://profiles.cfg (`dir` + profiles.cfg).
## The first start without that file seeds slot 0 with every ship unlocked (the profile used while testing).
## Only the real game (title.gd, persist on) calls `start`; tests keep PlayerProfile / SaveGame paths as they set them.

const COUNT := 3

static var dir := "user://"  # tests use their own prefix (never the real files)
static var active := 0


static func cfg_path() -> String:
	return dir + "profiles.cfg"


static func profile_path(i: int) -> String:
	return dir + ("profile.sav" if i == 0 else "profile_%d.sav" % (i + 1))


static func save_path(i: int) -> String:
	return dir + ("continue.sav" if i == 0 else "continue_%d.sav" % (i + 1))


## Title screen boot: read the active slot (first start: seed slot 0 unlocked) and point the save paths at it.
static func start() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(cfg_path()) != OK:
		_use(0)
		var p := PlayerProfile.current()
		p.unlock_everything()
		p.save()
		_write()
		return
	_use(clampi(int(cfg.get_value("profiles", "active", 0)), 0, COUNT - 1))


## Switch to slot `i` (the profile window).
static func select(i: int) -> void:
	_use(clampi(i, 0, COUNT - 1))
	_write()


static func _use(i: int) -> void:
	active = i
	PlayerProfile.path = profile_path(i)
	SaveGame.path = save_path(i)
	PlayerProfile.reset_current()


static func _write() -> void:
	if not PlayerProfile.persist:
		return
	var cfg := ConfigFile.new()
	cfg.set_value("profiles", "active", active)
	cfg.save(cfg_path())


## The profile of slot `i` (the active one is the live PlayerProfile.current()).
static func profile_of(i: int) -> PlayerProfile:
	if i == active:
		return PlayerProfile.current()
	var keep := PlayerProfile.path
	PlayerProfile.path = profile_path(i)
	var p := PlayerProfile.load_file()
	PlayerProfile.path = keep
	return p


static func used(i: int) -> bool:
	return FileAccess.file_exists(profile_path(i))


static func has_run(i: int) -> bool:
	return FileAccess.file_exists(save_path(i))


## UNLOCK ALL on slot `i`.
static func unlock_all(i: int) -> void:
	var p := profile_of(i)
	p.unlock_everything()
	_store(i, p)


## DELETE on slot `i`: profile and run save gone (ScoreKeeper::WipeProfile + deleteAllSaveFiles).
static func wipe(i: int) -> void:
	if not PlayerProfile.persist:
		return
	for f in [profile_path(i), profile_path(i) + ".new", save_path(i), save_path(i) + ".new"]:
		if FileAccess.file_exists(f):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	if i == active:
		PlayerProfile.reset_current()


static func _store(i: int, p: PlayerProfile) -> void:
	var keep := PlayerProfile.path
	PlayerProfile.path = profile_path(i)
	p.save()
	PlayerProfile.path = keep
