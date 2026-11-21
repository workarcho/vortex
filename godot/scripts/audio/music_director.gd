extends Node
## Music player (autoload `Music`, rules/music.md). `MusicLogic` holds FTL's SoundControl state; this node plays
## its tracks: one AudioStreamPlayer (bus `Music`) per track, its stream an AudioStreamSynchronized of the explore
## and battle Ogg files, so both parts run sample-locked and the crossfade only changes the two sub-stream volumes.
## Files come from the user's ftl-data (`audio/music/`), loaded on first use and cached.
##
## Drivers (rules/music.md §4): the title scene calls `open_main_menu()`; `sector_entered` (rules/hooks.md) starts
## the sector's <trackList>; main.gd calls `check_world()` every frame (also while paused) = CheckMusic; the
## filter hook `music_combat` lets mods change that decision; `boss_destroyed()` (final boss, not implemented yet)
## and `run_ended` "victory" (title music after 25 s on the victory screen). Defeat changes nothing.
## Runs with process mode ALWAYS: pausing never stops or ducks the music. No playback with `FtlData.muted`
## (--mute, tests) or headless unless `force_audio`; the state machine runs regardless.

const MUSIC_BUS := &"Music"
const SFX_BUS := &"SFX"
const VICTORY_TITLE_DELAY := 25.0  # GameOver::OnLoop: title music once the victory screen is open 25 s

var logic := MusicLogic.new()
var force_audio := false  # tests: play even headless / muted
var victory_timer := -1.0  # s left until the title music on the victory screen (-1 = off)
var _players := {}  # serial -> {"player": AudioStreamPlayer, "sync": AudioStreamSynchronized or null}
var _streams := {}  # file name -> AudioStreamOggVorbis (null = missing)
var _tracks_loaded := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	ensure_buses()
	GameOptions.apply_volumes()
	Hooks.listen(&"sector_entered", _on_sector_entered, 0, "music")
	Hooks.listen(&"run_ended", _on_run_ended, 0, "music")


## Adds the `Music` and `SFX` buses (both sending to Master) when the bus layout lacks them.
static func ensure_buses() -> void:
	for b in [MUSIC_BUS, SFX_BUS]:
		if AudioServer.get_bus_index(b) < 0:
			AudioServer.add_bus()
			var i := AudioServer.bus_count - 1
			AudioServer.set_bus_name(i, b)
			AudioServer.set_bus_send(i, &"Master")


func _load_tracks() -> void:
	if _tracks_loaded:
		return
	_tracks_loaded = true
	if FtlData.root != "":
		logic.tracks = MusicLogic.parse_tracks(FtlData.text("data/sounds.xml") + FtlData.text("data/dlcSounds.xml"))


# ------------------------------------------------------------------ public API (SoundControl)

func start_playlist(names: Array) -> void:
	_load_tracks()
	logic.start_playlist(names)
	_flush()


func stop_playlist(fade_s: float) -> void:
	logic.stop_playlist(fade_s)
	_flush()


func set_combat(on: bool) -> void:
	logic.set_combat(on)


## MainMenu::Open: title music (keeps playing into the hangar), battle mode off.
func open_main_menu() -> void:
	victory_timer = -1.0
	start_playlist(MusicLogic.TITLE_LIST)
	set_combat(false)


## BossShip::OnLoop when the final boss dies (not while jumping away): music cut in 0.1 s + victory stinger.
## Stub: nothing calls it until the Last Stand boss exists.
func boss_destroyed() -> void:
	stop_playlist(MusicLogic.BOSS_CUT)
	FtlData.play("victory")


## WorldManager::CheckMusic, once per frame from the game scene (also while the game is paused).
func check_world(player: ShipState, hostile_enemy: bool, hazard: HazardRule) -> void:
	var want := MusicLogic.check_music(player, hostile_enemy, hazard)
	var f: Variant = Hooks.filter(&"music_combat", want, player, hostile_enemy, hazard)
	if f is bool:
		want = f
	set_combat(want)
	if logic.playlist.is_empty() and logic.serial == 0 and logic.delay <= 0.0 and victory_timer < 0.0 \
			and not _in_run():
		start_playlist(MusicLogic.DEFAULT_LIST)  # combat sandbox (no sector): civilian


func _in_run() -> bool:
	var s := FrameHost.top_scene(get_tree()) if is_inside_tree() else null
	return s != null and s.get("run") != null


func _on_sector_entered(run: RunState, _level: int, desc_name: String) -> void:
	victory_timer = -1.0
	var desc: XmlNode = run.engine.db.sectors.get(desc_name) if run != null and run.engine != null else null
	start_playlist(MusicLogic.sector_tracks(desc))


func _on_run_ended(_run: RunState, kind: String) -> void:
	if kind == "victory":
		victory_timer = VICTORY_TITLE_DELAY


# ------------------------------------------------------------------ playback

func _process(delta: float) -> void:
	if victory_timer > 0.0:
		victory_timer -= delta
		if victory_timer <= 0.0:
			victory_timer = -1.0
			start_playlist(MusicLogic.TITLE_LIST)
	logic.step(delta)
	_flush()
	_apply_volumes()


func audio_enabled() -> bool:
	if force_audio:
		return true
	return not FtlData.muted and FtlData.root != "" and DisplayServer.get_name() != "headless"


func _flush() -> void:
	for e in logic.take_events():
		if e.type == "start":
			_start(e)
		elif e.type == "stop":
			_stop(int(e.serial))


func _start(e: Dictionary) -> void:
	if not audio_enabled():
		return
	var t: Dictionary = logic.tracks.get(e.name, {})
	var ex := _ogg(String(t.get("explore", "")))
	if ex == null:
		return
	var cb := _ogg(String(t.get("combat", "")))
	ex.loop = e.loop
	var stream: AudioStream = ex
	var sync: AudioStreamSynchronized = null
	if cb != null:
		cb.loop = e.loop
		sync = AudioStreamSynchronized.new()
		sync.stream_count = 2
		sync.set_sync_stream(0, ex)
		sync.set_sync_stream(1, cb)
		stream = sync
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.bus = MUSIC_BUS
	p.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(p)
	var s := int(e.serial)
	p.finished.connect(func(): logic.track_finished(s))
	_players[s] = {"player": p, "sync": sync}
	_set_amps(s, logic.explore.a, logic.battle.a)
	p.play(0.0)


func _stop(s: int) -> void:
	var d: Dictionary = _players.get(s, {})
	_players.erase(s)
	if not d.is_empty():
		(d.player as AudioStreamPlayer).stop()
		(d.player as Node).queue_free()


func _apply_volumes() -> void:
	if _players.is_empty():
		return
	if FtlData.muted and not force_audio:
		for s in _players.keys():
			_stop(s)
		return
	_set_amps(logic.serial, logic.explore.a, logic.battle.a)
	for s in logic.outgoing:
		_set_amps(s, logic.outgoing[s].e.a, logic.outgoing[s].c.a)


static func amp_db(a: float) -> float:
	return linear_to_db(a) if a > 0.0001 else -80.0


func _set_amps(s: int, e: float, c: float) -> void:
	var d: Dictionary = _players.get(s, {})
	if d.is_empty():
		return
	var sync: AudioStreamSynchronized = d.sync
	if sync != null:
		sync.set_sync_stream_volume(0, amp_db(e))
		sync.set_sync_stream_volume(1, amp_db(c))
	else:
		(d.player as AudioStreamPlayer).volume_db = amp_db(e)


func _ogg(file: String) -> AudioStreamOggVorbis:
	if file == "":
		return null
	if not _streams.has(file):
		var path := FtlData.root.path_join("audio/music").path_join(file)
		_streams[file] = AudioStreamOggVorbis.load_from_file(path) if FileAccess.file_exists(path) else null
	return _streams[file]


## Test helper: the playing player of the current track (null without audio).
func current_player() -> AudioStreamPlayer:
	var d: Dictionary = _players.get(logic.serial, {})
	return d.get("player")


func current_sync() -> AudioStreamSynchronized:
	var d: Dictionary = _players.get(logic.serial, {})
	return d.get("sync")


## Tests: back to the boot state (no playlist, no players).
func reset() -> void:
	for s in _players.keys():
		_stop(s)
	logic = MusicLogic.new()
	victory_timer = -1.0
	_tracks_loaded = false
