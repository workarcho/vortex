extends Node
## Desktop-only visual preview of mobile screens (rules/ui_layout_strategy.md).
## `--device=phone|fold_cover|fold_inner|<W>x<H>` (landscape size in dp) resizes the window to that screen's
## physical size on this monitor (1 dp = 1/160 in): px = dp × monitor DPI / 160. `--device-dpi=N` overrides the
## DPI Windows reports (it reports the logical DPI, 96 × scale, not the real panel density), to calibrate.
## `--device-scale=N` (default 3) enlarges that size, since the phone is held close to the face; the window is
## shrunk (aspect kept) if it would not fit the screen.
## The mouse stands in for a finger: the game runs in the touch input profile unless `--input=` is given (title.gd,
## main.gd; TooltipService: hover only while a mouse button is held). A plain `--device=` opens the combat sandbox
## against a harmless enemy (main.gd `--harmless-enemy`: no weapons / drones, never escapes or surrenders);
## `--menu`, `--hangar`, `--run` still go where they say. Nothing changes without `--device=`.
## This is a visualisation aid only: it is NOT part of the routine verification after changes.

## Landscape window sizes in dp (approximate; from the panel resolution ÷ Android density).
const DEVICES := {
	"phone": Vector2(915, 412),       # typical 6.7" phone, 2400×1080 px at 2.625
	"fold_cover": Vector2(905, 369),  # Galaxy Z Fold cover screen, 2376×968 px at 2.625
	"fold_inner": Vector2(823, 707),  # Galaxy Z Fold inner screen, 2160×1856 px at 2.625
}


## True when `--device=` is on the command line (also headless; the window is only resized with a display).
func active() -> bool:
	return Array(OS.get_cmdline_user_args()).any(func(a): return a.begins_with("--device="))


## The touch UI is the default on a real phone/tablet build and in the --device preview (an explicit --input= wins).
func touch_default() -> bool:
	return active() or OS.has_feature("mobile")


var _watchdog: Thread


## Screenshot runs (`--screenshot=` with a display): vsync off, and a watchdog thread that kills the process
## `--wait` + 30 s later. If Windows stops presenting the window (occluded / other desktop) the main loop can
## block in the buffer swap; the window then stays grey forever and the calling script never returns.
func _screenshot_guard() -> void:
	var args := OS.get_cmdline_user_args()
	if DisplayServer.get_name() == "headless" or not Array(args).any(func(a): return a.begins_with("--screenshot=")):
		return
	var wait := 5.0
	for a in args:
		if a.begins_with("--wait="):
			wait = maxf(wait, a.get_slice("=", 1).to_float())
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var limit_ms := int((wait + 30.0) * 1000.0)
	_watchdog = Thread.new()
	_watchdog.start(func() -> void:
		OS.delay_msec(limit_ms)
		printerr("screenshot watchdog: no exit after %d ms, killing the process" % limit_ms)
		OS.kill(OS.get_process_id()))


func _ready() -> void:
	_screenshot_guard()
	var dev := ""
	var dpi := 0.0
	var scale := 3.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--device="):
			dev = a.get_slice("=", 1)
		elif a.begins_with("--device-dpi="):
			dpi = a.get_slice("=", 1).to_float()
		elif a.begins_with("--device-scale="):
			scale = maxf(a.get_slice("=", 1).to_float(), 0.1)
	if dev == "" or DisplayServer.get_name() == "headless":
		return
	var dp := Vector2.ZERO
	if DEVICES.has(dev):
		dp = DEVICES[dev]
	elif dev.contains("x"):
		dp = Vector2(dev.get_slice("x", 0).to_float(), dev.get_slice("x", 1).to_float())
	if dp.x <= 0.0 or dp.y <= 0.0:
		push_warning("--device: unknown device '%s' (use %s or WxH in dp)" % [dev, ", ".join(DEVICES.keys())])
		return
	if dpi <= 0.0:
		dpi = DisplayServer.screen_get_dpi()
	var px := dp * dpi / 160.0 * scale
	var usable := Vector2(DisplayServer.screen_get_usable_rect().size) - Vector2(16, 48)  # borders, title bar
	px *= minf(1.0, minf(usable.x / px.x, usable.y / px.y))
	var w := get_window()
	w.mode = Window.MODE_WINDOWED
	w.size = Vector2i(px.round())
	w.move_to_center()
	w.title = "%s — %s preview (%d×%d dp, %d dpi, ×%.1f)" % [w.title, dev, dp.x, dp.y, dpi, px.x / (dp.x * dpi / 160.0)]
