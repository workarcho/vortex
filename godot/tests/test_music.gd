extends Node
## Music (rules/music.md): playlist order and cycling, the StartPlaylist sector-change decisions, the CheckMusic
## battle conditions, the explore/battle crossfade volumes over time, the volume mapping to the Music / SFX buses,
## the sector_entered / run_ended drivers and the Music autoload's synchronized player. Silent: FtlData.muted, and
## the one playback check runs headless (dummy audio driver). Run:
##   godot --headless --path godot res://tests/test_music.tscn

const Harness := preload("res://tests/harness.gd")

var fails := 0


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func near(name: String, got: float, want: float, eps := 0.001) -> void:
	check(name, want if absf(got - want) <= eps else snappedf(got, 0.001), want)


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	FtlData.muted = true
	Music.reset()
	_data()
	_playlist()
	_sector_change()
	_crossfade()
	_conditions()
	_volumes()
	_drivers()
	await _player()
	Music.reset()


func _fake() -> MusicLogic:
	var m := MusicLogic.new()
	for n in ["a", "b", "c", "civilian", "cosmos", "engi"]:
		m.tracks[n] = {"explore": n + "_E.ogg", "combat": n + "_B.ogg"}
	m.tracks["title"] = {"explore": "title.ogg", "combat": ""}
	return m


static func _starts(ev: Array) -> Array:
	return ev.filter(func(e): return e.type == "start").map(func(e): return e.name)


func _data() -> void:
	print("Data: sounds.xml <music>, sector <trackList>")
	var t := MusicLogic.parse_tracks(FtlData.text("data/sounds.xml"))
	check("civilian explore", t.get("civilian", {}).get("explore"), "bp_MUS_CivilEXPLORE.ogg")
	check("civilian combat", t.get("civilian", {}).get("combat"), "bp_MUS_CivilBATTLE.ogg")
	check("title has no combat", t.get("title", {}).get("combat"), "")
	check("18 tracks", t.size(), 18)
	var root := XmlNode.parse("<sectorDescription name=\"X\"><trackList><track>engi</track><track>cosmos</track>"
		+ "<track>hacking</track></trackList></sectorDescription><sectorDescription name=\"Y\"/>")
	var descs := root.children_named("sectorDescription")
	check("two descs parsed", descs.size(), 2)
	if descs.size() == 2:
		check("trackList file order", MusicLogic.sector_tracks(descs[0]), ["engi", "cosmos", "hacking"])
		check("no trackList -> civilian", MusicLogic.sector_tracks(descs[1]), ["civilian"])
	check("no desc -> civilian", MusicLogic.sector_tracks(null), ["civilian"])


func _playlist() -> void:
	print("Playlist order and gapless cycling")
	var m := _fake()
	m.start_playlist(["a", "b", "c"])
	var ev := m.take_events()
	check("empty list: first track at once", _starts(ev), ["a"])
	check("multi-entry: no loop flag", ev[0].loop, false)
	var order := []
	for i in 4:
		m.track_finished(m.serial)
		var e2 := m.take_events()
		check("old pair removed at track end %d" % i, e2[0].type, "stop")
		order.append_array(_starts(e2))
	check("cycle in file order", order, ["b", "c", "a", "b"])
	var old := m.serial
	m.track_finished(old - 1)
	check("stale end callback ignored", m.serial, old)
	var one := _fake()
	one.start_playlist(["engi"])
	check("1-entry list loops", one.take_events()[0].loop, true)
	check("explore starts at 1.0", one.explore.a, 1.0)
	check("battle starts at 0.0", one.battle.a, 0.0)


func _sector_change() -> void:
	print("New sector: same list / same first track / fade + 2 s")
	var m := _fake()
	m.start_playlist(["civilian", "cosmos"])
	m.take_events()
	var s := m.serial
	m.step(30.0)
	m.start_playlist(["civilian", "cosmos"])
	check("same list: no events", m.take_events(), [])
	check("same list: same track", m.serial, s)
	m.track_finished(s)  # now cosmos
	m.take_events()
	s = m.serial
	m.start_playlist(["cosmos", "engi"])
	check("first track already playing: no events", m.take_events(), [])
	check("first track already playing: continues", m.serial, s)
	check("index reset to 0", m.current, 0)
	m.track_finished(s)
	check("then the new list goes on", _starts(m.take_events()), ["engi"])
	# different first track: StopPlaylist(750) + 2 s delay
	m.start_playlist(["a", "b"])
	check("fade: no immediate start", m.take_events(), [])
	check("nothing current", m.serial, 0)
	m.step(0.375)
	var o: Dictionary = m.outgoing.values()[0]
	near("fade-out half way", o.e.a, 0.5)
	m.step(0.375)
	var ev := m.take_events()
	check("pair removed after 0.75 s", ev.size() == 1 and ev[0].type == "stop", true)
	m.step(1.2)
	check("still silent at 1.95 s", m.take_events(), [])
	m.step(0.1)
	check("new first track after 2 s", _starts(m.take_events()), ["a"])


func _crossfade() -> void:
	print("Explore / battle crossfade (2 s, linear)")
	var m := _fake()
	m.start_playlist(["a", "b"])
	m.take_events()
	m.set_combat(true)
	m.step(1.0)
	near("1 s: battle 0.5", m.battle.a, 0.5)
	near("1 s: explore 0.5", m.explore.a, 0.5)
	m.step(1.0)
	near("2 s: battle 1.0", m.battle.a, 1.0)
	near("2 s: explore 0.0", m.explore.a, 0.0)
	m.set_combat(true)
	check("StartCombat twice: no new slide", m.battle.t, 1.0)
	m.set_combat(false)
	m.step(1.0)
	near("back 1 s: explore 0.4", m.explore.a, 0.4)
	near("back 1 s: battle 0.5", m.battle.a, 0.5)
	m.step(5.0)
	near("back: explore rests at 0.8", m.explore.a, 0.8)
	near("back: battle 0", m.battle.a, 0.0)
	m.track_finished(m.serial)
	m.take_events()
	check("next track: explore 1.0 again", m.explore.a, 1.0)
	m.set_combat(true)
	m.step(2.0)
	m.track_finished(m.serial)
	m.take_events()
	check("track started in battle: explore 0", m.explore.a, 0.0)
	check("track started in battle: battle 1", m.battle.a, 1.0)
	var t := _fake()
	t.start_playlist(["title"])
	t.take_events()
	t.set_combat(true)
	t.step(3.0)
	check("title (no battle file): explore stays 1", t.explore.a, 1.0)
	check("title: combat flag still set", t.combat, true)
	t.start_playlist(["a"])
	t.step(2.0)
	t.take_events()
	check("combat flag kept across playlists: explore 0", t.explore.a, 0.0)
	check("combat flag kept across playlists: battle 1", t.battle.a, 1.0)
	var b := _fake()
	b.start_playlist(["a", "b"])
	b.take_events()
	b.stop_playlist(MusicLogic.BOSS_CUT)
	check("boss cut: playlist cleared", b.playlist, [])
	b.step(0.1)
	check("boss cut: removed after 0.1 s", b.take_events().size(), 1)
	b.start_playlist(["title"])
	check("after the cut the title starts at once", _starts(b.take_events()), ["title"])


func _conditions() -> void:
	print("CheckMusic conditions")
	var me := ShipState.new("PLAYER_SHIP_HARD", true)
	check("nothing: explore", MusicLogic.check_music(me, false, null), false)
	check("hostile living enemy", MusicLogic.check_music(me, true, null), true)
	check("nebula: explore", MusicLogic.check_music(me, false, HazardRule.create(HazardRule.Env.NEBULA, 2, 1, 0)),
		false)
	check("storm: explore", MusicLogic.check_music(me, false, HazardRule.create(HazardRule.Env.STORM, 2, 1, 0)),
		false)
	for env in [HazardRule.Env.SUN, HazardRule.Env.PULSAR, HazardRule.Env.ASTEROIDS]:
		check("env %d: battle" % env, MusicLogic.check_music(me, false, HazardRule.create(env, 2, 1, 0)), true)
	for tg in [0, 2]:
		check("PDS target %d: battle" % tg,
			MusicLogic.check_music(me, false, HazardRule.create(HazardRule.Env.PDS, tg, 1, 0)), true)
	check("PDS at the enemy only: explore",
		MusicLogic.check_music(me, false, HazardRule.create(HazardRule.Env.PDS, 1, 1, 0)), false)
	var intr := me.add_crew("human", false)
	check("intruder aboard: battle", MusicLogic.check_music(me, false, null), true)
	intr.mind_controlled = true  # an enemy crew member under our mind control, aboard
	check("mind-controlled enemy aboard: battle", MusicLogic.check_music(me, false, null), true)
	me.crew.erase(intr)
	check("intruder gone: explore", MusicLogic.check_music(me, false, null), false)


func _volumes() -> void:
	print("Volume mapping (Music = 0.75 x music, SFX = 0.9 x sound)")
	check("music gain 1.0", MusicLogic.music_gain(1.0), 0.75)
	check("sfx gain 1.0", MusicLogic.sfx_gain(1.0), 0.9)
	var mb := AudioServer.get_bus_index(&"Music")
	var sb := AudioServer.get_bus_index(&"SFX")
	check("Music bus exists", mb >= 0, true)
	check("SFX bus exists", sb >= 0, true)
	if mb < 0 or sb < 0:
		return
	check("Music sends to Master", AudioServer.get_bus_send(mb), &"Master")
	var sv := GameOptions.sound_volume
	var mv := GameOptions.music_volume
	GameOptions.set_value("music_volume", 0.5)
	GameOptions.set_value("sound_volume", 0.2)
	GameOptions.apply_volumes()
	near("Music bus = 0.375", db_to_linear(AudioServer.get_bus_volume_db(mb)), 0.375)
	near("SFX bus = 0.18", db_to_linear(AudioServer.get_bus_volume_db(sb)), 0.18)
	near("Master untouched (dB)", AudioServer.get_bus_volume_db(0), 0.0)
	GameOptions.set_value("music_volume", 0.0)
	GameOptions.apply_volumes()
	check("music 0: Music muted", AudioServer.is_bus_mute(mb), true)
	check("music 0: SFX not muted", AudioServer.is_bus_mute(sb), false)
	GameOptions.set_value("sound_volume", sv)
	GameOptions.set_value("music_volume", mv)
	GameOptions.apply_volumes()


func _drivers() -> void:
	print("Drivers: menu, sector_entered, run_ended")
	Music.reset()
	Music.open_main_menu()
	check("menu: title", Music.logic.playing_name, "title")
	var r := RunState.new_run(7)
	check("new run: title fades out", Music.logic.serial, 0)
	check("new run: civilian list", Music.logic.playlist, ["civilian", "cosmos", "milkyway", "lostship"])
	Music.logic.step(2.0)
	Music.logic.take_events()
	check("civilian after 2 s", Music.logic.playing_name, "civilian")
	var s := Music.logic.serial
	Hooks.emit(&"sector_entered", r, 1, "STANDARD_SPACE")
	check("same sector type: untouched", Music.logic.serial, s)
	Hooks.emit(&"sector_entered", r, 2, "ENGI_SECTOR")
	check("engi sector list", Music.logic.playlist, ["engi", "cosmos", "hacking"])
	Hooks.emit(&"sector_entered", r, 7, "FINAL")
	check("last stand list", Music.logic.playlist, ["laststand"])
	Hooks.emit(&"run_ended", r, "victory")
	check("victory: title in 25 s", Music.victory_timer, 25.0)
	Music.reset()
	Hooks.emit(&"run_ended", r, "gameover")
	check("defeat: nothing", Music.victory_timer, -1.0)


func _player() -> void:
	print("Music autoload: synchronized explore/battle player (headless, dummy driver)")
	Music.reset()
	Music.force_audio = true
	Music.start_playlist(["civilian", "cosmos"])
	var p := Music.current_player()
	var sync := Music.current_sync()
	check("player created", p != null, true)
	if p == null:
		Music.force_audio = false
		return
	check("on the Music bus", p.bus, &"Music")
	check("synchronized pair", sync != null and sync.stream_count == 2, true)
	check("explore 0 dB", sync.get_sync_stream_volume(0), 0.0)
	check("battle silent", sync.get_sync_stream_volume(1), -80.0)
	check("pause-proof", p.process_mode, Node.PROCESS_MODE_ALWAYS)
	Music.set_combat(true)
	Music._process(1.0)
	near("battle half way (dB)", sync.get_sync_stream_volume(1), linear_to_db(0.5))
	Music._process(1.0)
	check("explore silent after 2 s", sync.get_sync_stream_volume(0), -80.0)
	Music.start_playlist(["engi"])
	Music._process(0.8)
	await get_tree().process_frame
	check("old player freed after the fade", is_instance_valid(p), false)
	Music.force_audio = false
