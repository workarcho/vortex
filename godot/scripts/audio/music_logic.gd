class_name MusicLogic
extends RefCounted
## FTL's music state machine (SoundControl playlist / combat part, rules/music.md §3), without any audio: it keeps
## the playlist, the current track index, the combat flag, the start delay and the linear amplitude (0..1, BASS
## BASS_ATTRIB_VOL) of the explore / battle channels with their slides. The `Music` autoload
## (scripts/audio/music_director.gd) turns its events into AudioStreamPlayers; tests drive it directly with `step`.
##
## Events (`take_events()`): {"type": "start", "serial", "name", "loop": bool, "has_combat": bool} when a track
## starts (explore + battle from position 0 together), {"type": "stop", "serial"} when a channel pair is removed
## (fade-out finished, or replaced at the end of the track).

const STOP_FADE := 0.75  # StartPlaylist: StopPlaylist(750)
const START_DELAY := 2.0  # musicDelay after a playlist change
const CROSSFADE := 2.0  # StartCombat / StopCombat slide time
const EXPLORE_BACK := 0.8  # StopCombat: explore volume after a fight
const BOSS_CUT := 0.1  # BossShip::OnLoop: StopPlaylist(100)
const MUSIC_GAIN := 0.75  # SetMusicVolume: 7500 / 10000 of the global stream volume
const SFX_GAIN := 0.9  # SetSoundVolume: 9000 / 10000 of the global sample volume
const DEFAULT_LIST := ["civilian"]  # EventsParser::ProcessBaseNode without <trackList>
const TITLE_LIST := ["title"]

## name -> {"explore": file, "combat": file or ""} (sounds.xml <music>)
var tracks := {}
var playlist: Array = []
var current := -1  # index into playlist of the playing track (-1 = none)
var combat := false  # combatMusic
var delay := -1.0  # musicDelay (s); the next track starts when it runs out
var serial := 0  # id of the playing channel pair (0 = none)
var playing_name := ""
## Channel amplitudes of the playing track: {"a": value, "t": target, "r": rate per second}
var explore := {"a": 0.0, "t": 0.0, "r": 0.0}
var battle := {"a": 0.0, "t": 0.0, "r": 0.0}
## Pairs fading out (StopPlaylist): serial -> {"e": slide, "c": slide}; removed (stop event) at 0.
var outgoing := {}
var _events: Array = []
var _next_serial := 0


func take_events() -> Array:
	var e := _events
	_events = []
	return e


func has_combat_file(track_name: String) -> bool:
	return String((tracks.get(track_name, {}) as Dictionary).get("combat", "")) != ""


## The playlist of a sector description (sector_data.xml <trackList>, file order), ["civilian"] without one.
static func sector_tracks(desc: XmlNode) -> Array:
	var tl := desc.child("trackList") if desc != null else null
	var out := []
	if tl != null:
		for t in tl.children_named("track"):
			if t.text.strip_edges() != "":
				out.append(t.text.strip_edges())
	return out if not out.is_empty() else DEFAULT_LIST.duplicate()


## sounds.xml <music><track><name/><explore/><combat/></track></music> -> `tracks`.
static func parse_tracks(xml_text: String) -> Dictionary:
	var out := {}
	var mus := RegEx.create_from_string("(?s)<music>(.*?)</music>")
	var tr := RegEx.create_from_string("(?s)<track>(.*?)</track>")
	for m in mus.search_all(FtlData.strip_comments(xml_text)):
		for t in tr.search_all(m.get_string(1)):
			var b := t.get_string(1)
			var n := FtlData.tag_value(b, "name").strip_edges()
			if n != "":
				out[n] = {"explore": FtlData.tag_value(b, "explore").strip_edges(),
					"combat": FtlData.tag_value(b, "combat").strip_edges()}
	return out


## Bus gains (linear) for the option values 0..1 (rules/music.md §6).
static func music_gain(music_volume: float) -> float:
	return MUSIC_GAIN * clampf(music_volume, 0.0, 1.0)


static func sfx_gain(sound_volume: float) -> float:
	return SFX_GAIN * clampf(sound_volume, 0.0, 1.0)


# ------------------------------------------------------------------ SoundControl

## StartPlaylist (rules/music.md §3).
func start_playlist(new_list: Array) -> void:
	if new_list == playlist:
		return  # same list: nothing changes
	if playlist.is_empty():
		delay = -1.0
		current = -1
		playlist = new_list.duplicate()
		switch_tracks()
		return
	if current >= 0 and serial != 0 and not new_list.is_empty() and playing_name == String(new_list[0]):
		current = 0  # the new first track is already playing: keep it
		playlist = new_list.duplicate()
		return
	stop_playlist(STOP_FADE)
	delay = START_DELAY
	current = -1
	playlist = new_list.duplicate()


## StopPlaylist(fade): the playing pair slides to 0 and is removed; the playlist is cleared.
func stop_playlist(fade_s: float) -> void:
	if serial != 0:
		var fade := maxf(fade_s, 0.001)
		outgoing[serial] = {"e": {"a": explore.a, "t": 0.0, "r": explore.a / fade},
			"c": {"a": battle.a, "t": 0.0, "r": battle.a / fade}}
		serial = 0
		playing_name = ""
	current = -1
	playlist = []


## SwitchTracks: next track of the playlist (wrapping), both channels from 0, no fade-in.
func switch_tracks() -> void:
	if playlist.is_empty():
		return
	var next := current + 1
	if next >= playlist.size():
		next = 0
	var track_name := String(playlist[next])
	if not tracks.is_empty() and not tracks.has(track_name):
		push_warning("Music: bad track name %s" % track_name)
		return
	if serial != 0:
		_events.append({"type": "stop", "serial": serial})
	_next_serial += 1
	serial = _next_serial
	playing_name = track_name
	var hc := has_combat_file(track_name)
	explore = {"a": 0.0 if combat and hc else 1.0, "t": 0.0, "r": 0.0}
	explore.t = explore.a
	battle = {"a": 1.0 if combat else 0.0, "t": 0.0, "r": 0.0}
	battle.t = battle.a
	current = next
	_events.append({"type": "start", "serial": serial, "name": track_name, "loop": playlist.size() == 1,
		"has_combat": hc})


## StartCombat / StopCombat.
func set_combat(on: bool) -> void:
	if on == combat:
		return
	combat = on
	if serial == 0 or not has_combat_file(playing_name):
		return
	_slide(battle, 1.0 if on else 0.0, CROSSFADE)
	_slide(explore, 0.0 if on else EXPLORE_BACK, CROSSFADE)


## The end of the playing explore channel (EndMusicTrack): the next track starts at once (gapless).
func track_finished(track_serial: int) -> void:
	if track_serial == serial and serial != 0:
		switch_tracks()


## Advances the slides and the start delay by `dt` real seconds (SoundControl::OnLoop; BASS slides).
func step(dt: float) -> void:
	_advance(explore, dt)
	_advance(battle, dt)
	for s in outgoing.keys():
		var o: Dictionary = outgoing[s]
		_advance(o.e, dt)
		_advance(o.c, dt)
		if o.e.a <= 0.0 and o.c.a <= 0.0:
			outgoing.erase(s)
			_events.append({"type": "stop", "serial": s})
	if delay > 0.0:
		delay -= dt
		if delay <= 0.0:
			delay = -1.0
			switch_tracks()


static func _slide(ch: Dictionary, target: float, time: float) -> void:
	ch.t = target
	ch.r = absf(target - float(ch.a)) / time


static func _advance(ch: Dictionary, dt: float) -> void:
	var a: float = ch.a
	var t: float = ch.t
	if a == t:
		return
	var d: float = float(ch.r) * dt
	ch.a = minf(a + d, t) if t > a else maxf(a - d, t)


## WorldManager::CheckMusic (rules/music.md §4): battle music while a hostile living enemy is present, the
## environment is dangerous (sun, asteroids, pulsar, PDS not aimed only at the enemy), the player ship has
## intruders, or it carries a mind-controlled enemy crew member.
static func check_music(player: ShipState, hostile_enemy: bool, hazard: HazardRule) -> bool:
	if hostile_enemy:
		return true
	if hazard != null and hazard.is_dangerous():
		return true
	if player != null:
		for c: CrewMember in player.crew:
			if not c.is_alive():
				continue
			if c.is_intruder(player) or (c.mind_controlled and not c.player_owned):
				return true
	return false
