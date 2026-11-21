class_name MainMenuView
extends Control
## The title screen (rules/main_menu.md §1): MainMenu::OnRender = `main_menus/main_base2.png` at (0,0) (opaque),
## the glowing logo `main_FTL2.png` at (820,60) with a 3 s looping triangle alpha, the seven image buttons in a
## column (y 275 + 58·i), and the version line (font 10, right-aligned to x 1265, y 700). The 1.6.9 exe puts every
## button at x 800; the 1.6.14 screenshot (work/refs/vanilla/35) right-aligns them: x = 1200 − image width.
## Buttons are `main_menus/<name>_{off,on,select2}.png`: off = inactive, on = idle, select2 = hovered.
## Gestures go to the InputProfile (press on PC, release on touch); hover plays `hoverBeep` (PC only).

const BUTTONS := [  # [image name, intent, y]
	["continue", TitleState.MENU_CONTINUE, 275],
	["start", TitleState.MENU_NEW_GAME, 333],
	["tutorial", TitleState.MENU_TUTORIAL, 391],
	["stats", TitleState.MENU_STATS, 449],
	["options", TitleState.MENU_OPTIONS, 507],
	["credits", TitleState.MENU_CREDITS, 565],
	["quit", TitleState.MENU_QUIT, 623],
]
const BUTTON_RIGHT := 1200  # right edge of every button image [screenshot 35]
const LOGO_POS := Vector2(820, 60)
const GLOW_TIME := 3.0  # glowTracker: 3 s, looping; alpha = (1.5 − |t − 1.5|) / 1.5
const VERSION := "1.6.9"  # the exe's version number in text `version` ("Version \1")
const VERSION_RIGHT := 1265.0
const VERSION_Y := 700.0

var title: TitleState
var profile: InputProfile
var hovered := -1
var _t := 0.0
var _pressed := -1


func setup(t: TitleState, p: InputProfile) -> void:
	title = t
	profile = p
	position = Vector2.ZERO
	size = HudLayout.FRAME
	mouse_filter = Control.MOUSE_FILTER_STOP


func _process(delta: float) -> void:
	_t = fmod(_t + delta, GLOW_TIME)
	if disabled_hover and is_visible_in_tree():  # MainMenu::MouseMove: inactive Continue -> no_load
		TooltipService.request(tooltip_text_now(), {"kind": &"menu", "source": self})
	queue_redraw()


var disabled_hover := false


func tooltip_text_now() -> String:
	return TooltipText.simple("menu", "no_load") if disabled_hover else ""


func glow_alpha() -> float:
	return (GLOW_TIME / 2.0 - absf(_t - GLOW_TIME / 2.0)) / (GLOW_TIME / 2.0)


func button_active(i: int) -> bool:
	return BUTTONS[i][1] != TitleState.MENU_CONTINUE or title.continue_enabled()


func button_rect(i: int) -> Rect2:
	var t := FtlData.texture("img/main_menus/%s_on.png" % BUTTONS[i][0])
	var sz := t.get_size() if t else Vector2(200, 62)
	return Rect2(Vector2(BUTTON_RIGHT - sz.x, BUTTONS[i][2]), sz)


## GenericButton::MouseMove: inside = strictly within the hit box.
func button_at(p: Vector2) -> int:
	for i in BUTTONS.size():
		var r := button_rect(i)
		if p.x > r.position.x and p.x < r.end.x and p.y > r.position.y and p.y < r.end.y:
			return i
	return -1


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		hover(e.position)
	elif e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed:
			press(e.position)
		else:
			release(e.position)


func hover(p: Vector2) -> void:
	var h := button_at(p) if not profile.is_touch() else -1
	if h != hovered:
		if h >= 0 and button_active(h):
			FtlData.play("hoverBeep")  # MouseControl: newHover on an active button
		hovered = h
	disabled_hover = h >= 0 and not button_active(h)


func press(p: Vector2) -> void:
	var i := button_at(p)
	_pressed = i
	if i >= 0 and button_active(i):
		profile.title_press(TitleState.make(BUTTONS[i][1]))


func release(p: Vector2) -> void:
	var i := button_at(p)
	if i >= 0 and i == _pressed and button_active(i):
		profile.title_release(TitleState.make(BUTTONS[i][1]))
	_pressed = -1



func _draw() -> void:
	var bg := FtlData.texture("img/main_menus/main_base2.png")
	if bg:
		draw_texture(bg, Vector2.ZERO)
	else:
		draw_rect(Rect2(Vector2.ZERO, HudLayout.FRAME), Color(0.02, 0.03, 0.06))
	var logo := FtlData.texture("img/main_menus/main_FTL2.png")
	if logo:
		draw_texture(logo, LOGO_POS, Color(1, 1, 1, glow_alpha()))
	for i in BUTTONS.size():
		var st := "off" if not button_active(i) else ("select2" if i == hovered else "on")
		var t := FtlData.texture("img/main_menus/%s_%s.png" % [BUTTONS[i][0], st])
		if t:
			draw_texture(t, button_rect(i).position)
	var v := FtlData.tr_id("version").replace("\\1", VERSION)
	FtlData.draw_ftl_text(self, 10, v, Vector2(VERSION_RIGHT, VERSION_Y), Color.WHITE, FtlFont.Align.RIGHT)
