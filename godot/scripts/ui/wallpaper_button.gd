class_name WallpaperButton
extends Control
## [ours] Main menu corner button "CREATE HTML WALLPAPER" (PC only; title.gd does not build it on touch / mobile /
## web): makes the local Wallpaper Engine wallpaper with WallpaperMaker (scripts/autobattle/wallpaper_maker.gd)
## or, when it already exists for this build, opens its folder. Bottom-left corner, drawn like ProfileView's
## corner button (MenuDraw.text_button); while it builds the label shows the progress and the button is off.
## Messages go to the title screen's toast (`toast` callable). Frame coordinates (1280x720).

const CORNER_X := 14.0
const CORNER_BOTTOM := 12.0  # gap to the frame's bottom edge
const CORNER_H := 30.0

var menu: Control  # the main menu: the button shows with it
var maker: WallpaperMaker
var toast: Callable = func(_t: String) -> void: pass
var button := {}
var hot := false
var _pressed := false


func setup(menu_view: Control, toast_fn: Callable, m: WallpaperMaker = null) -> void:
	menu = menu_view
	toast = toast_fn
	maker = m if m != null else WallpaperMaker.new(WallpaperMaker.default_template_dir(),
		WallpaperMaker.default_dest_dir(), FtlData.root)
	position = Vector2.ZERO
	size = HudLayout.FRAME
	mouse_filter = Control.MOUSE_FILTER_STOP
	_layout()


func _layout() -> void:
	var label := FtlData.tr_id("wallpaper_button")
	var st := "on"
	if maker.running:
		label = FtlData.tr_id("wallpaper_button_busy").replace("\\1", str(int(maker.progress() * 100)))
		st = "off"
	var w := FtlData.ftl_text_width(62, label) + 28
	button = {"rect": Rect2(CORNER_X, HudLayout.FRAME.y - CORNER_BOTTOM - CORNER_H, w, CORNER_H), "font": 62,
		"label": label, "state": st}


func _process(_d: float) -> void:
	if maker.running and maker.poll():
		_finished()
	var show := menu != null and menu.visible
	if visible != show:
		visible = show
	if visible:
		_layout()
		queue_redraw()


func _has_point(p: Vector2) -> bool:
	return (button.rect as Rect2).has_point(p) if not button.is_empty() else false


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		var h := (button.rect as Rect2).has_point(e.position) and not TooltipService.touch
		if h and not hot and not maker.running:
			FtlData.play("hoverBeep")
		hot = h
		accept_event()
	elif e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		var inside := (button.rect as Rect2).has_point(e.position)
		if e.pressed:
			_pressed = inside
		elif inside and _pressed:
			activate()
		if not e.pressed:
			_pressed = false
		accept_event()


## The button's action (tests call it directly). Returns WallpaperMaker.run()'s result.
func activate() -> String:
	var r := maker.run()
	match r:
		WallpaperMaker.OPENED:
			toast.call(FtlData.tr_id("wallpaper_opened").replace("\\1", maker.dest_dir))
		WallpaperMaker.STARTED:
			toast.call(FtlData.tr_id("wallpaper_creating"))
			if not maker.threaded and maker.poll():
				_finished()
		WallpaperMaker.NO_TEMPLATE:
			toast.call(FtlData.tr_id("wallpaper_no_template"))
		WallpaperMaker.NO_DATA:
			toast.call(FtlData.tr_id("wallpaper_failed").replace("\\1", "no FTL data"))
	_layout()
	return r


func _finished() -> void:
	if maker.ok:
		toast.call(FtlData.tr_id("wallpaper_created").replace("\\1", maker.dest_dir))
	else:
		toast.call(FtlData.tr_id("wallpaper_failed").replace("\\1", maker.error))
	_layout()


func _draw() -> void:
	if not button.is_empty():
		MenuDraw.text_button(self, button, hot and not maker.running)
