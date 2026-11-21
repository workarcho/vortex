class_name GameOptions
extends RefCounted
## The vanilla options (Settings::settings of FTL; rules/main_menu.md §3) — separate from the mod/QoL `Settings`
## autoload. Static values, loaded from / saved to `user://ftl_options.cfg` only when `persist` is true (test
## scenes never set it). `apply()` pushes the ones we implement to the engine: fullscreen, vertical sync, frame
## limit, sound volume (SFX bus) and music volume (Music bus, `apply_volumes`). The others are stored for the systems that will read them:
## `event_choice` (0 brief delay, 1 no delay, 2 disable hotkeys — Settings::dialogKeys), `show_paths`,
## `colorblind`, `dynamic_bg`, `achievement_popups`, `focus_pause`.
## Ours (not FTL): `fold_layout` — the combat layout on tall touch canvases (open Galaxy Fold): "split" (default) or
## "pan" (main.gd `fold_layout()`; CLI `--fold-layout=` overrides it; shown in the window in touch mode only).
## Ours (not FTL): `phone_layout` — the combat layout on 720-high touch canvases (phone, closed Fold): "column"
## (default) or "pan" (main.gd `phone_layout()`; CLI `--phone-layout=` overrides it; touch mode only).
## Ours (not FTL): `window_size` — PC window size, an index into WINDOW_SIZES (16:9: 720p, 1080p, 1440p, 4K); applied
## when windowed (shrunk to the screen, aspect kept); a `--resolution` command line wins at startup. PC only.

const PATH := "user://ftl_options.cfg"
const EVENT_CHOICE_IDS := ["event_choice_brief_delay", "event_choice_no_delay", "event_choice_disable_hotkeys"]
const FULLSCREEN_IDS := ["fullscreen_0", "fullscreen_1", "fullscreen_2", "fullscreen_3"]
const FOLD_LAYOUTS := ["split", "pan"]  # fold_layout values, cycle order (text ids fold_layout_<value>, text_ours.xml)
const PHONE_LAYOUTS := ["column", "pan"]  # phone_layout values, cycle order (text ids phone_layout_<value>)
const WINDOW_SIZES := [Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(2560, 1440), Vector2i(3840, 2160)]

static var persist := false
static var fullscreen := 0  # 0 off, 1 stretch, 2 borders, 3 native (every non-zero value = Godot fullscreen)
static var vsync := true
static var frame_limit := true  # 60 fps cap
static var dynamic_bg := true
static var colorblind := false
static var event_choice := 0
static var show_paths := true
static var achievement_popups := true
static var focus_pause := true
static var sound_volume := 1.0  # 0..1 (SoundControl::GetSoundVolume)
static var music_volume := 1.0
static var fold_layout := "split"  # ours: tall touch canvas combat layout (FOLD_LAYOUTS)
static var phone_layout := "column"  # ours: phone (720-high) touch canvas combat layout (PHONE_LAYOUTS)
static var window_size := 0  # ours: PC window size (WINDOW_SIZES index)
static var _applied_size := -1  # window_size last pushed to the window (a manual resize is kept until it changes)
static var _loaded := false

const KEYS := ["fullscreen", "vsync", "frame_limit", "dynamic_bg", "colorblind", "event_choice", "show_paths",
	"achievement_popups", "focus_pause", "sound_volume", "music_volume", "fold_layout", "phone_layout", "window_size"]


static func load_file() -> void:
	_loaded = true
	if not persist:
		return
	var cf := ConfigFile.new()
	if cf.load(PATH) != OK:
		return
	for k in KEYS:
		if cf.has_section_key("options", k):
			set_value(k, cf.get_value("options", k))


static func save() -> void:
	if not persist:
		return
	var cf := ConfigFile.new()
	for k in KEYS:
		cf.set_value("options", k, get_value(k))
	cf.save(PATH)


static func get_value(k: String) -> Variant:
	match k:
		"fullscreen": return fullscreen
		"vsync": return vsync
		"frame_limit": return frame_limit
		"dynamic_bg": return dynamic_bg
		"colorblind": return colorblind
		"event_choice": return event_choice
		"show_paths": return show_paths
		"achievement_popups": return achievement_popups
		"focus_pause": return focus_pause
		"sound_volume": return sound_volume
		"music_volume": return music_volume
		"fold_layout": return fold_layout
		"phone_layout": return phone_layout
		"window_size": return window_size
	return null


static func set_value(k: String, v: Variant) -> void:
	match k:
		"fullscreen": fullscreen = clampi(int(v), 0, 3)
		"vsync": vsync = bool(v)
		"frame_limit": frame_limit = bool(v)
		"dynamic_bg": dynamic_bg = bool(v)
		"colorblind": colorblind = bool(v)
		"event_choice": event_choice = clampi(int(v), 0, 2)
		"show_paths": show_paths = bool(v)
		"achievement_popups": achievement_popups = bool(v)
		"focus_pause": focus_pause = bool(v)
		"sound_volume": sound_volume = clampf(float(v), 0.0, 1.0)
		"music_volume": music_volume = clampf(float(v), 0.0, 1.0)
		"fold_layout": fold_layout = str(v) if FOLD_LAYOUTS.has(str(v)) else FOLD_LAYOUTS[0]
		"phone_layout": phone_layout = str(v) if PHONE_LAYOUTS.has(str(v)) else PHONE_LAYOUTS[0]
		"window_size": window_size = clampi(int(v), 0, WINDOW_SIZES.size() - 1)


## Pushes the implemented options to the engine (skipped headless: no window to change).
static func apply() -> void:
	if not _loaded:
		load_file()
	apply_volumes()
	Engine.max_fps = 60 if frame_limit else 0
	if DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED)
	var want := DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen != 0 else DisplayServer.WINDOW_MODE_WINDOWED
	if OS.has_feature("mobile"):
		# Phones / tablets: always immersive full screen (Android: WINDOW_MODE_FULLSCREEN hides the status and
		# navigation bars, WINDOWED shows them again — the PC option's default "off" must not turn them back on).
		want = DisplayServer.WINDOW_MODE_FULLSCREEN
	if DisplayServer.window_get_mode() != want and not (want == DisplayServer.WINDOW_MODE_WINDOWED
			and DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_MAXIMIZED):
		DisplayServer.window_set_mode(want)
	_apply_window_size()


## PC windowed: the chosen 16:9 size, shrunk to the usable screen (aspect kept), centred. Only when the option
## changed since the last push; skipped on mobile, in the --device preview and when `--resolution` was given at
## startup.
static func _apply_window_size() -> void:
	if OS.has_feature("mobile") or DevicePreview.active() or window_size == _applied_size:
		return
	var first := _applied_size < 0
	_applied_size = window_size
	if first and OS.get_cmdline_args().has("--resolution"):
		return
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		return
	var want := Vector2(WINDOW_SIZES[window_size])
	var usable := Vector2(DisplayServer.screen_get_usable_rect().size) - Vector2(16, 48)  # borders, title bar
	want *= minf(1.0, minf(usable.x / want.x, usable.y / want.y))
	DisplayServer.window_set_size(Vector2i(want.round()))
	var scr := DisplayServer.screen_get_usable_rect()
	DisplayServer.window_set_position(scr.position + (scr.size - Vector2i(want.round())) / 2)


## Sound / music volumes (rules/music.md §6), applied live on every slider change (OptionsScreen::OnLoop): the
## `SFX` bus = 0.9 × sound volume (every FtlData sound), the `Music` bus = 0.75 × music volume (the Music
## autoload); the two are independent and Master stays at 0 dB. Muted below 0.001.
static func apply_volumes() -> void:
	_set_bus(&"SFX", MusicLogic.sfx_gain(sound_volume))
	_set_bus(&"Music", MusicLogic.music_gain(music_volume))


static func _set_bus(bus_name: StringName, gain: float) -> void:
	var bus := AudioServer.get_bus_index(bus_name)
	if bus < 0:
		return
	AudioServer.set_bus_volume_db(bus, linear_to_db(maxf(gain, 0.0001)))
	AudioServer.set_bus_mute(bus, gain <= 0.001)


## One option line of the window (text id with \1 filled), e.g. "Vertical Sync: On".
static func line(k: String) -> String:
	match k:
		"fullscreen": return _fmt("fullscreen", FtlData.tr_id(FULLSCREEN_IDS[fullscreen]))
		"vsync": return _fmt("v_sync", _on_off(vsync))
		"frame_limit": return _fmt("frame_limit", _on_off(frame_limit))
		"dynamic_bg": return _fmt("dynamic_back", _on_off(dynamic_bg))
		"colorblind": return _fmt("colorblind", _en_dis(colorblind))
		"language": return FtlData.tr_id("change_language")
		"event_choice": return _fmt("event_choice", FtlData.tr_id(EVENT_CHOICE_IDS[event_choice]))
		"show_paths": return _fmt("show_paths", _en_dis(show_paths))
		"achievement_popups": return _fmt("achievement_popup", _en_dis(achievement_popups))
		"focus_pause": return _fmt("window_focus", _on_off(focus_pause))
		"hotkeys": return FtlData.tr_id("configure_controls")
		"fold_layout": return _fmt("fold_layout", FtlData.tr_id("fold_layout_" + fold_layout))
		"phone_layout": return _fmt("phone_layout", FtlData.tr_id("phone_layout_" + phone_layout))
		"window_size": return _fmt("window_size", "%dx%d" % [WINDOW_SIZES[window_size].x, WINDOW_SIZES[window_size].y])
	return k


## Click on an option line: cycles / toggles it (OptionsScreen::MouseClick); returns false for the lines that
## open something instead (language, hotkeys).
static func cycle(k: String) -> bool:
	match k:
		"fullscreen": fullscreen = 0 if fullscreen != 0 else 3
		"vsync": vsync = not vsync
		"frame_limit": frame_limit = not frame_limit
		"dynamic_bg": dynamic_bg = not dynamic_bg
		"colorblind": colorblind = not colorblind
		"event_choice": event_choice = (event_choice + 1) % 3
		"show_paths": show_paths = not show_paths
		"achievement_popups": achievement_popups = not achievement_popups
		"focus_pause": focus_pause = not focus_pause
		"fold_layout": fold_layout = FOLD_LAYOUTS[(FOLD_LAYOUTS.find(fold_layout) + 1) % FOLD_LAYOUTS.size()]
		"phone_layout": phone_layout = PHONE_LAYOUTS[(PHONE_LAYOUTS.find(phone_layout) + 1) % PHONE_LAYOUTS.size()]
		"window_size": window_size = (window_size + 1) % WINDOW_SIZES.size()
		_: return false
	save()
	apply()
	return true


static func _fmt(id: String, v: String) -> String:
	return FtlData.tr_id(id).replace("\\1", v)


static func _on_off(b: bool) -> String:
	return FtlData.tr_id("on" if b else "off")


static func _en_dis(b: bool) -> String:
	return FtlData.tr_id("enabled" if b else "disabled")
