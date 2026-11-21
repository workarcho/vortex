class_name CrewManifestView
extends Control
## Crew tab (rules/ship_management.md §5, CrewManifest): `crew_main.png` at P + (0, −7), `rename_note`, 9
## `CrewEquipBox`es (100×67 at P + (75 + 170·col, 88 + 133·row); third row shifted +87 px while the 9th box is
## empty), portrait, short name (font 6, centred at box + (50, 49)), skill levels beside the box [inferred], the
## DISMISS button (box + (4, 70), 92×12) with its confirmation window, the rename text input (max 15
## characters; click on the name) and the over-capacity drop box with the window lock for a 9th crew member.

const P := ShipScreen.P
const BOX := Vector2(100, 67)
const ROW_SHIFT := 87.0
const CONFIRM := Rect2(470, 250, 340, 170)
const SKILLS := ["pilot", "engines", "shields", "weapons", "repair", "combat"]

## Portrait hook for the crew-appearance work (layers / colours): Callable(ci, crew, centre: Vector2, scale: float).
## Unset: `CrewPortrait.draw_icon` (crew-appearance helper) is used.
static var portrait_drawer := Callable()

var run: RunState
var profile: InputProfile
var screen: ShipScreen
var _hover := -1
var _hover_part := ""  # "box", "name", "dismiss"


func setup(r: RunState, p: InputProfile, s: ShipScreen) -> void:
	run = r
	profile = p
	screen = s
	position = Vector2.ZERO
	size = HudLayout.FRAME
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED


func box_rect(i: int) -> Rect2:
	var col := i % 3
	var row := i / 3
	var x := 75.0 + 170 * col
	if row == 2 and CrewRoster.members(run.ship).size() < CrewRoster.BOXES:
		x += ROW_SHIFT
	return Rect2(P + Vector2(x, 88 + 133 * row), BOX)


static func name_rect(b: Rect2) -> Rect2:
	return Rect2(b.position + Vector2(0, 46), Vector2(100, 20))


static func dismiss_rect(b: Rect2) -> Rect2:
	return Rect2(b.position + Vector2(0, 66), Vector2(100, 20))


func confirm_rects() -> Array:
	return [Rect2(CONFIRM.position + Vector2(40, 120), Vector2(110, 32)),
		Rect2(CONFIRM.position + Vector2(190, 120), Vector2(110, 32))]


## [index, part] under p (part: "name", "dismiss", "box").
func hit(p: Vector2) -> Array:
	var crew := CrewRoster.members(run.ship)
	for i in mini(crew.size(), CrewRoster.BOXES):
		var b := box_rect(i)
		if name_rect(b).has_point(p):
			return [i, "name"]
		if CrewRoster.can_dismiss(run.ship) and dismiss_rect(b).has_point(p):
			return [i, "dismiss"]
		if b.has_point(p):
			return [i, "box"]
	return [-1, ""]


func _gui_input(event: InputEvent) -> void:
	accept_event()
	if event is InputEventMouseMotion:
		var h := hit(event.position)
		_hover = h[0]
		_hover_part = h[1]
		return
	var mb := event as InputEventMouseButton
	if mb and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		click(mb.position)


## A click / tap at p.
func click(p: Vector2) -> void:
	var m := run.mgmt
	if m.dismiss_pending != null:  # the ConfirmWindow takes every input
		var cr := confirm_rects()
		if (cr[0] as Rect2).has_point(p):
			screen.send(RunIntent.CREW_DISMISS_CONFIRM, {"arg": 1})
		elif (cr[1] as Rect2).has_point(p):
			screen.send(RunIntent.CREW_DISMISS_CONFIRM, {"arg": 0})
		return
	var h := hit(p)
	var crew := CrewRoster.members(run.ship)
	if m.renaming != null:
		m.commit_rename()  # the next click commits the rename
		if h[1] != "name":
			return
	if h[0] < 0:
		screen.chrome_click(p)
		return
	var c: CrewMember = crew[h[0]]
	match String(h[1]):
		"name":
			m.start_rename(c)
		"dismiss":
			screen.send(RunIntent.CREW_DISMISS, {"crew": c})


## Text input of the active rename (letters, digits, space, Backspace, Enter commits, Esc cancels).
func key(k: InputEventKey) -> bool:
	var m := run.mgmt
	if m.dismiss_pending != null:
		if k.keycode == KEY_ESCAPE or k.keycode == KEY_N:
			screen.send(RunIntent.CREW_DISMISS_CONFIRM, {"arg": 0})
		elif k.keycode == KEY_ENTER or k.keycode == KEY_Y:
			screen.send(RunIntent.CREW_DISMISS_CONFIRM, {"arg": 1})
		return true
	if m.renaming == null:
		return false
	match k.keycode:
		KEY_ENTER, KEY_KP_ENTER:
			m.commit_rename()
		KEY_ESCAPE:
			m.renaming = null
			m.rename_text = ""
		KEY_BACKSPACE:
			m.type_rename(m.rename_text.substr(0, maxi(m.rename_text.length() - 1, 0)))
		_:
			if k.unicode >= 32:
				m.type_rename(m.rename_text + char(k.unicode))
	return true


func _draw() -> void:
	if run == null or not run.mgmt.open:
		return
	var m := run.mgmt
	var mouse := TooltipService.local_pointer(self) if not profile.is_touch() else Vector2(-1, -1)
	ShipScreen.img(self, "upgradeUI/Equipment/crew_main.png", P + Vector2(0, -7))
	FtlData.draw_ftl_text(self, 10, FtlData.tr_id("rename_note"), P + Vector2(25, 55), ShipScreen.COL_TEXT)
	var crew := CrewRoster.members(run.ship)
	if CrewRoster.is_over_capacity(run.ship):
		var lines := ShipScreen.text_lines("overcapacity_crew_text")
		ShipScreen.drop_box(self, P + Vector2(-275, 100), false, false, FtlData.tr_id("overcapacity_crew_title"),
			lines, 0)
	# The 9th box is shown only when filled (the third row is then not shifted).
	for i in CrewRoster.BOXES if crew.size() >= CrewRoster.BOXES else CrewRoster.BOXES - 1:
		_draw_box(i, crew[i] if i < crew.size() else null)
	if _hover >= 0 and _hover < crew.size():
		_draw_info(crew[_hover])
	screen.draw_chrome(self, mouse)
	if m.dismiss_pending != null:
		_draw_confirm()


func _draw_box(i: int, c: CrewMember) -> void:
	var b := box_rect(i)
	var m := run.mgmt
	var st := "off" if c == null else ("selected" if i == _hover and not profile.is_touch() else "on")
	ShipScreen.img(self, "upgradeUI/Equipment/box_crew_%s.png" % st, b.position)
	if c == null:
		return
	var centre := b.position + Vector2(50, 27)  # matched to the vanilla screenshot (43_ship_crew)
	if portrait_drawer.is_valid():
		portrait_drawer.call(self, c, centre, 1.0)
	else:
		_fallback_portrait(c, centre)
	# Name (rename field while typing).
	var nm := CrewRoster.display_name(c)
	var name_col := Color8(245, 238, 163) if (i == _hover and _hover_part == "name") else Color.WHITE
	if m.renaming == c:
		var nr := name_rect(b)
		draw_rect(nr.grow(-1), Color8(10, 20, 22, 230))
		draw_rect(nr.grow(-1), ShipScreen.COL_HOT, false, 1.0)
		var caret := "_" if fmod(Time.get_ticks_msec() / 500.0, 2.0) < 1.0 else " "
		nm = m.rename_text + caret
		name_col = ShipScreen.COL_HOT
	FtlData.draw_ftl_text(self, 6, nm, b.position + Vector2(50, 49), name_col, 1)  # print (x + 50, y + 49) centred
	# DISMISS (only with more than one crew) [exe CrewEquipBox]: `customizeUI/box_crewcustom_on.png` (100×24;
	# `_selected` while the box glows) at box + (0, 62), then the TextButton (box + (4, 70), 92×12, corner inset
	# 2, `crewbox_dismiss` font 51: COLOR_BUTTON_ON plate, COLOR_BUTTON_SELECT when hovered, COLOR_BUTTON_TEXT text).
	# No skill display on this page (skills are in the hover info box).
	if CrewRoster.can_dismiss(run.ship):
		var glow := i == _hover and not profile.is_touch()
		ShipScreen.img(self, "customizeUI/box_crewcustom_%s.png" % ("selected" if glow else "on"),
			b.position + Vector2(0, 62))
		var dr := Rect2(b.position + Vector2(4, 70), Vector2(92, 12))
		var hot := i == _hover and _hover_part == "dismiss"
		ShipScreen.text_button(self, dr, FtlData.tr_id("crewbox_dismiss"), "hot" if hot else "on", 51, 2)


## CrewPortrait (crew-appearance helper): walk_down frame 0 with the colour layers, ×2 (EquipmentBox::RenderIcon GL_Scale(2)).
func _fallback_portrait(c: CrewMember, centre: Vector2) -> void:
	CrewPortrait.draw_icon(self, CrewPortrait.look_of(c), centre, 2.0)


func _draw_info(c: CrewMember) -> void:
	# CrewManifest: InfoBox::SetBlueprint(crew, 0, detailed) with the crew member's real skills (InfoPanels).
	var d := InfoPanels.crew_content(c.race, c.name_long, InfoPanels.crew_skills(c),
		{"context": "crew_manifest", "crew": c})
	InfoPanels.draw_crew(self, P + Vector2(600, 0), d, true)


func _draw_confirm() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.35))
	WindowFrame.draw(self, CONFIRM)
	var y := CONFIRM.position.y + 12
	for l in FtlData.tr_id("confirm_dismiss").replace("\\n", "\n").split("\n"):
		FtlData.draw_ftl_text(self, 10, l, Vector2(CONFIRM.get_center().x, y), ShipScreen.COL_TEXT, 1)
		y += 20
	var cr := confirm_rects()
	var mouse := TooltipService.local_mouse(self)
	ShipScreen.text_button(self, cr[0], FtlData.tr_id("yes"), "hot" if (cr[0] as Rect2).has_point(mouse) else "on")
	ShipScreen.text_button(self, cr[1], FtlData.tr_id("no"), "hot" if (cr[1] as Rect2).has_point(mouse) else "on")
