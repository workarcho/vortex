class_name CrewList
extends Control
## Crew list on the left (CrewBox per player crew), the save / return stations buttons, the stations
## message and the white drag-selection rectangle (rules/crew_controls.md). Draws only: input goes
## through CrewControl (main.gd _input). Full-screen, ignores the mouse.

const COL_HOVER := Color8(235, 235, 235)
const COL_SELECTED := Color8(120, 255, 120)
const COL_NONE := Color8(100, 100, 100)
const COL_LOW_FLASH := Color8(255, 100, 100)
const COL_STUNNED := Color8(255, 255, 100)
const COL_DEAD := Color8(133, 231, 237)  # COLOR_BLUE_ION: dead / cloning, not selectable
const COL_MIND := Color8(255, 0, 255)  # mind controlled
const NAME_COLOR := Color8(200, 200, 200)
const LOW_HEALTH := 25.0
const FLASH_PERIOD := 1.0  # low-health flash tracker length [inferred]
const SKILL_UP_TIME := 1.0  # skillUp AnimationTracker length (CrewMember ctor: default 1.0 s)
## BlueprintManager::GetSkillIcon(skill, false): the system overlay icons, repair / combat icons.
const SKILL_ICONS := {"pilot": "icons/s_pilot_overlay.png", "engines": "icons/s_engines_overlay.png",
	"shields": "icons/s_shields_overlay.png", "weapons": "icons/s_weapons_overlay.png",
	"repair": "icons/s_repair_overlay.png", "combat": "icons/s_combat_overlay.png"}

var control: CrewControl
var _time := 0.0
## Touch UI (main.gd `_touch_layout`): when set (this Control's local coordinates), the save / return stations
## buttons are drawn here instead, stacked in a doors-style box: button_door_base.png at this point (without its
## pointer tail: `draw_tailless_box`), the two
## 20×20 buttons in its slots (10, 10) and (10, 33). Passed on to CrewControl.button_box (the hit boxes).
var touch_button_box: Variant = null:
	set(v):
		touch_button_box = v
		if control != null:
			control.button_box = v


## Touch UI with an enemy (main.gd): the stations buttons' rects in this Control's local coordinates — the
## 20×20 button art drawn stretched (nearest) over each; passed on to CrewControl.button_rects (the hit boxes).
var touch_station_rects: Array = []:
	set(v):
		touch_station_rects = v
		if control != null:
			control.button_rects = v


## Touch UI: local y the stations message ends above (INF = the stations buttons' top): the phone column layout
## has the doors buttons above them (main.gd `_touch_apply`).
var touch_message_top := INF


func setup(ctrl: CrewControl) -> void:
	control = ctrl
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_notify_transform(true)
	_sync_transform()


## CrewControl hit tests use this list's canvas transform (touch UI: ×1.2, moved up; PC: identity).
func _sync_transform() -> void:
	if control != null:
		control.list_xf = get_global_transform() if is_inside_tree() else get_transform()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED or what == NOTIFICATION_ENTER_TREE:
		_sync_transform()


func _process(delta: float) -> void:
	_sync_transform()
	_time += delta
	_tick_skill_up(delta)
	if control != null:
		_update_hover_tooltips()
	queue_redraw()


## Box state colour (CrewBox::OnRender).
func state_color(c: CrewMember) -> Color:
	if not c.is_alive():
		return COL_DEAD
	if c.mind_controlled:
		return COL_MIND
	if c.selected:
		return COL_SELECTED
	if c.stun > 0.0:
		return COL_STUNNED
	if c.hovered:
		return COL_HOVER
	if c.hp <= LOW_HEALTH and fmod(_time, FLASH_PERIOD) < FLASH_PERIOD / 2:
		return COL_LOW_FLASH
	return COL_NONE


## Health bar colour: full = green; damaged (255, min(255, 510 hp/max), 0).
static func health_color(c: CrewMember) -> Color:
	if c.hp >= c.max_hp:
		return Color8(0, 255, 0)
	return Color8(255, mini(255, int(510.0 * c.hp / c.max_hp)), 0)


func _draw() -> void:
	if control == null:
		return
	var font := ThemeDB.fallback_font
	for i in control.roster.size():
		if i != skill_box:
			_draw_box(i, control.roster[i], font)
	if skill_box >= 0 and skill_box < control.roster.size():
		_draw_box(skill_box, control.roster[skill_box], font)  # the skill shape on top
	_draw_buttons()
	if control.message_time > 0.0 and control.message != "":
		if touch_station_rects.size() == 2:
			# Touch UI: right-aligned just above the big stations buttons (TARGET corner / beside the toggle).
			var top := minf(minf(control.button_rect(0).position.y, control.button_rect(1).position.y),
				touch_message_top)
			var right := maxf(control.button_rect(0).end.x, control.button_rect(1).end.x)
			HudDraw.text(self, 10, control.message, Vector2(right, top - FtlData.ftl_line_height(10) - 2),
				Color.WHITE, 2)
		else:
			var y := control.box_rect(maxi(control.roster.size() - 1, 0)).end.y + 10 + 38  # PC: under the buttons
			HudDraw.text(self, 10, control.message, Vector2(10, y), Color.WHITE)  # font 10, white
	var dr := control.drag_rect()  # screen coordinates
	if dr.size.x > 0 or dr.size.y > 0:
		draw_set_transform_matrix(control.list_xf.affine_inverse())
		draw_rect(dr, Color.WHITE, false, 2)  # GL_DrawRectOutline, (1, 1, 1, 1)
		draw_set_transform_matrix(Transform2D.IDENTITY)
	Hooks.emit(&"hud_draw.crew_list", self, control)


func _draw_box(i: int, c: CrewMember, font: Font) -> void:
	var r := control.box_rect(i)
	var col := state_color(c)
	if i == skill_box:
		_draw_skills(i, c, font)  # hovered: the skill shape replaces the box frame
	else:
		_box_frame(r, col)
	if c.has_power():
		_draw_power(i, c, r, col)
	_box_body(i, c, r)


## Crew with a special power (crystal, CrewBox::OnRender): box widened 2 px to the left, a divider at x + 5 and the
## ion-blue 4 px cooldown bar on the left edge (x − 1, height ∝ charge); the LOCKDOWN button while the skill shape
## is shown (64×14 at x + w + 11, y + 7; active only while the power is ready).
func _draw_power(i: int, c: CrewMember, r: Rect2, col: Color) -> void:
	draw_line(Vector2(r.position.x - 1, r.position.y), Vector2(r.position.x - 1, r.end.y), col, 2)
	draw_line(Vector2(r.position.x + 5, r.position.y), Vector2(r.position.x + 5, r.end.y), col, 2)
	var h := roundf((r.size.y - 4) * c.power_fraction())
	if h > 0.0:
		draw_rect(Rect2(r.position.x - 1, r.end.y - 2 - h, 4, h), FtlColors.BLUE)
	if i != skill_box:
		return
	var b := control.power_button_rect(i)
	var ready := c.power_ready() and c.is_alive()
	var hover := ready and b.has_point(control.to_list(TooltipService.pointer()))
	var bc := Color.WHITE if hover else (FtlColors.BLUE if ready else Color8(110, 110, 110))
	draw_rect(b, Color(0, 0, 0, 0.6))
	FtlColors.draw_bar_outline(self, b, bc, 1.0)
	HudDraw.text(self, 6, HudDraw.txt("button_lockdown"), Vector2(b.position.x + b.size.x / 2, b.position.y + 2),
		bc, 1)


func _box_frame(r: Rect2, col: Color) -> void:
	draw_rect(r, Color(col, 0.25))
	# 2 px outline lines (top y+1, bottom y+h-1, left x+1, right x+w-1)
	draw_line(Vector2(r.position.x, r.position.y + 1), Vector2(r.end.x, r.position.y + 1), col, 2)
	draw_line(Vector2(r.position.x, r.end.y - 1), Vector2(r.end.x, r.end.y - 1), col, 2)
	draw_line(Vector2(r.position.x + 1, r.position.y), Vector2(r.position.x + 1, r.end.y), col, 2)
	draw_line(Vector2(r.end.x - 1, r.position.y), Vector2(r.end.x - 1, r.end.y), col, 2)


func _box_body(_i: int, c: CrewMember, r: Rect2) -> void:
	# Portrait (CrewAnimation::RenderIcon(border) at (x+17, y+15)): walk_down frame 0, yellow `_color` outline,
	# base + colour layers (CrewPortrait, rules/crew_appearance.md §4).
	CrewPortrait.draw_icon(self, CrewPortrait.look_of(c), r.position + Vector2(17, 15), 1.0, true)
	# Name, font 6 at (x+33, y+2): the crew member's short name (ShortenName, 49 px)
	HudDraw.text(self, 6, c.display_name(), r.position + Vector2(33, 2), NAME_COLOR)
	# Health bar: x+33, y+h-8, height 4, max width w-37, min 1 px if alive
	if c.is_alive():
		var w := maxf(1.0, (r.size.x - 37) * clampf(c.hp / c.max_hp, 0.0, 1.0))
		draw_rect(Rect2(r.position + Vector2(33, r.size.y - 8), Vector2(roundf(w), 4)), health_color(c))
		if c.hp <= LOW_HEALTH and fmod(_time, FLASH_PERIOD) < FLASH_PERIOD / 2:
			var warn := FtlData.texture("img/warnings/health_low.png")
			if warn:
				draw_texture(warn, r.position + Vector2(r.size.x - 2, -5))
			return  # CrewBox::OnRenderSkillLevel: the health warning replaces the skill-up arrow
	_draw_skill_up(c, r.position + Vector2(r.size.x + 2, 0))


## CrewMember::RenderSkillUpAnimation at p = (box right + 2, box top): the first running skill-gained
## tracker (1.0 s, advanced only while it is the one drawn, so gains queue up): the skill icon tinted
## COLOR_GREEN at p and icons/arrow.png rotated 180° (pointing up) at p + (25, 7), same colour.
func _draw_skill_up(c: CrewMember, p: Vector2) -> void:
	for sk in CrewMember.SKILLS:
		if not c.skill_up.has(sk):
			continue
		var icon := HudDraw.tex(SKILL_ICONS.get(sk, ""))
		if icon:
			draw_texture(icon, p, FtlColors.GREEN)
		var arrow := HudDraw.tex("icons/arrow.png")
		if arrow:
			var at := p + Vector2(25, 7) + arrow.get_size() / 2
			draw_set_transform(at, PI)
			draw_texture(arrow, -arrow.get_size() / 2, FtlColors.GREEN)
			draw_set_transform(Vector2.ZERO)
		return


## Advances the drawn skill-up tracker (render-time update, like the original: runs while paused).
func _tick_skill_up(delta: float) -> void:
	if control == null:
		return
	for c in control.roster:
		for sk in CrewMember.SKILLS:
			if c.skill_up.has(sk):
				c.skill_up[sk] += delta
				if c.skill_up[sk] >= SKILL_UP_TIME:
					c.skill_up.erase(sk)
				break


func _draw_buttons() -> void:
	if touch_station_rects.size() == 2:
		for k in 2:
			var kind := "assign" if k == 0 else "return"
			var state := "select2" if control.hovered_button == k else "on"
			var tex := FtlData.texture("img/statusUI/button_station_%s_%s.png" % [kind, state])
			if tex:
				draw_texture_rect(tex, control.button_rect(k), false)  # same rect as the hit test
		return
	if touch_button_box != null:
		var at: Vector2 = touch_button_box
		draw_tailless_box(self, at)
		for k in 2:
			var kind := "assign" if k == 0 else "return"
			var state := "select2" if control.hovered_button == k else "on"
			var tex := FtlData.texture("img/statusUI/button_station_%s_%s.png" % [kind, state])
			if tex:
				draw_texture(tex, control.button_rect(k).position)  # same rect as the hit test
		return
	var base := FtlData.texture("img/statusUI/button_station_base.png")
	for k in 2:
		var r := control.button_rect(k)
		if base:
			draw_texture(base, r.position - Vector2(12, 12))
		var kind := "assign" if k == 0 else "return"
		var state := "select2" if control.hovered_button == k else "on"
		var tex := FtlData.texture("img/statusUI/button_station_%s_%s.png" % [kind, state])
		if tex:
			draw_texture(tex, r.position)
		else:
			draw_rect(r, Color.WHITE, false, 1)


const DOOR_BOX := "img/systemUI/button_door_base.png"  # 40 × 79
const BOX_BODY_H := 57  # rows 0..56: top glow, rounded box, its 2 px white bottom border (rows 55..56)
const BOX_GLOW_H := 6  # rows 0..5: the glow above the top border
## Touch UI: the doors box art without its speech-bubble pointer tail (rows 57..73, which points at nothing here):
## rows 0..56, then the top glow rows mirrored under the cut so the bottom edge fades like the top (40 × 63).
static func draw_tailless_box(ci: CanvasItem, at: Vector2) -> void:
	var box := FtlData.texture(DOOR_BOX)
	if box == null:
		return
	ci.draw_texture_rect_region(box, Rect2(at, Vector2(40, BOX_BODY_H)), Rect2(0, 0, 40, BOX_BODY_H))
	# Negative height = vertically flipped region.
	ci.draw_texture_rect_region(box, Rect2(at + Vector2(0, BOX_BODY_H + BOX_GLOW_H), Vector2(40, -BOX_GLOW_H)),
		Rect2(0, 0, 40, BOX_GLOW_H))


## Crew box hover = the "skill" shape (CrewBox::OnRender, rules/tooltips.md §6): box ∪ skill panel
## (box.x + 84, box.y, 85, 146) filled with the state colour at α 0.25 and outlined at α 1, six RenderSkill rows.
func _draw_skills(i: int, c: CrewMember, _font: Font) -> void:
	var r := control.box_rect(i)
	var col := state_color(c)
	var p := r.position
	var sk := skill_rect(r, c.has_power())
	draw_rect(Rect2(sk.position, Vector2(sk.size.x, sk.size.y)), Color(col, 0.25))
	draw_rect(Rect2(p, Vector2(sk.position.x - p.x, r.size.y)), Color(col, 0.25))
	var pts := PackedVector2Array([p + Vector2(1, 1), Vector2(sk.end.x - 1, p.y + 1), sk.end - Vector2(1, 1),
		Vector2(sk.position.x + 1, sk.end.y - 1), Vector2(sk.position.x + 1, r.end.y - 1), Vector2(p.x + 1, r.end.y - 1),
		p + Vector2(1, 1)])
	draw_polyline(pts, col, 2.0)
	var dy := POWER_ROW if c.has_power() else 0  # the LOCKDOWN button row pushes the skills down
	for k in CrewMember.SKILLS.size():
		render_skill(self, c, k, Vector2(r.end.x + 7, p.y + dy + 24 * k), 40, 8)


## Skill panel rect of crew box `r` (146 px high; 170 with a special power's LOCKDOWN button).
static func skill_rect(r: Rect2, with_power := false) -> Rect2:
	return Rect2(r.position + Vector2(84, 0), Vector2(85, SKILL_PANEL_H + (POWER_ROW if with_power else 0)))


const SKILL_PANEL_H := 146
const POWER_ROW := 24
const SKILL_ICON := "people/skill_%s_white.png"
const SKILL_ICON_IDS := ["pilot", "engines", "shields", "weapons", "repair", "combat"]


## CrewBlueprint::RenderSkill(x, y, length, height, s): icon 26×26 tinted by r = xp / max (white below half,
## green to max, yellow at max; colour-blind: blue at max), bar at (x + 30, y + (26 − h) / 2): green to the
## half, then yellow with a 1 px white marker; white 1 px outline.
static func render_skill(ci: CanvasItem, c: CrewMember, s: int, at: Vector2, length: float, h: float) -> void:
	var sk: String = CrewMember.SKILLS[s]
	var mx := float(c.skill_cap(sk))
	render_skill_ratio(ci, clampf(float(c.skills.get(sk, 0)) / mx, 0.0, 1.0), s, at, length, h)


static func render_skill_ratio(ci: CanvasItem, r: float, s: int, at: Vector2, length: float, h: float) -> void:
	var yellow := Color8(0, 147, 224) if GameOptions.colorblind else FtlColors.YELLOW
	var tint := Color.WHITE if r < 0.5 else (FtlColors.GREEN if r < 1.0 else yellow)
	var icon := HudDraw.tex(SKILL_ICON % SKILL_ICON_IDS[s])
	if icon:
		ci.draw_texture_rect(icon, Rect2(at, Vector2(26, 26)), false, tint)
	var b := Vector2(at.x + 30, at.y + int((26 - h) / 2))
	if r < 0.5:
		ci.draw_rect(Rect2(b, Vector2(int(length * 2.0 * r), h)), FtlColors.GREEN)
	elif r < 1.0:
		ci.draw_rect(Rect2(b, Vector2(length, h)), FtlColors.GREEN)
		var yw := int(length * 2.0 * (r - 0.5))
		ci.draw_rect(Rect2(b, Vector2(yw, h)), yellow)
		ci.draw_rect(Rect2(b + Vector2(yw, 0), Vector2(1, h)), Color.WHITE)
	else:
		ci.draw_rect(Rect2(b, Vector2(int(length * r), h)), yellow)
	ci.draw_rect(Rect2(b + Vector2(0.5, 0.5), Vector2(length - 1, h - 1)), Color.WHITE, false, 1.0)


## Box whose skill panel is shown: the hovered box, kept while the pointer is in its skill panel.
var skill_box := -1


func _update_hover_tooltips() -> void:
	var m := TooltipService.pointer()
	var i := control.box_at(m)
	if i < 0 and skill_box >= 0 and skill_box < control.roster.size() \
			and skill_rect(control.box_rect(skill_box), control.roster[skill_box].has_power()).has_point(control.to_list(m)):
		i = skill_box
	skill_box = i
	if TooltipService.hud_blocked:
		return
	if i >= 0:
		var r := control.box_rect(i)
		var c := control.roster[i]
		var ml := control.to_list(m)  # crew list coordinates
		var anchor := control.list_xf * Vector2(r.end.x + 95, r.position.y)
		var tip := ""
		var k := &"crew_box"
		var sk := skill_rect(r, c.has_power())
		var dy := POWER_ROW if c.has_power() else 0
		if c.has_power() and control.power_button_rect(i).has_point(ml):
			# LOCKDOWN button: power_ready (\1 = key `lockdown`) / power_not_ready (rules/tooltips.md).
			tip = TooltipText.simple("button", "power_ready", {"key": "lockdown"}) if c.power_ready() \
				else TooltipText.simple("button", "power_not_ready")
			k = &"button"
		elif sk.has_point(ml):
			for s in CrewMember.SKILLS.size():
				if ml.y > r.position.y + dy + 3 + 24 * s and ml.y < r.position.y + dy + 21 + 24 * s:
					tip = TooltipText.crew_skill(c, s)
					k = &"crew_skill"
		elif r.has_point(ml):
			tip = TooltipText.crew_box(c, i)
		if tip != "":
			TooltipService.request(tip, {"instant": true, "anchor": anchor, "kind": k, "source": self,
				"ctx": {"crew": c, "index": i}})
		return
	var b := control.button_at(m)
	if b >= 0:
		TooltipService.request(TooltipText.simple("button", "save_stations_tooltip" if b == 0
			else "ret_stations_tooltip", {"key": "save_stations" if b == 0 else "ret_stations"}),
			{"kind": &"button", "source": self})
