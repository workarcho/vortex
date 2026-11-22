class_name EnemyWindow
extends Control
## Right-hand enemy window (FTL CombatControl::DrawHostileBox / RenderShipStatus; rules/hud_layout.md).
## `front == false`: the box_hostiles2.png frame (tinted hostile) drawn under the enemy ship view.
## `front == true`: the status block at (889, 90) — "TARGET", HULL tag + box_hostiles_hull2.png cropped by
## hull/22, SHIELDS tag + bubbles + recharge bar — the info text, and the enemy system boxes along
## (912 + 30·i, 515), with power bars only when the player's sensors show them (or the system is hacked).

var enemy: ShipState
var player: ShipState
var front := false
var show_power := false  # set by main.gd every frame (player sensors >= 3, not hacked)
var _t := 0.0
var run: RunState = null  # run mode: the event ship's escape state (run.enemy.escaping / escape_timer)
var touch := false  # touch layout (set by main.gd each frame): the escape message is drawn inside the frame
## Open-Fold "pan" layout (main.gd `_touch_layout_pan`): only the status block (TARGET title, hull, shields, info
## lines) over a dark backing (STATUS_RECT), next to the enemy ship in the shared scene; no system boxes.
var status_only := false
const STATUS_RECT := Rect2(878, 48, 384, 112)  # frame coordinates of the status block (+ info lines)
var _ftl_timer := 0.0  # CombatControl::ftl_timer (0.66 s loop), updated only while the enemy is escaping

const FTL_TIMER := 0.66
const IMMINENT_AT := 5.0  # escapeTimer ≤ 5 s → JUMP IMMINENT (flashing)


## CombatControl::RenderTarget escape message: "" (none), or [text id, flashing]. Shown while the hostile, living
## target is escaping: JumpCharging (engines + piloting working, ShipFlying) → `warning_ftl_imminent` (flashing)
## once escapeTimer ≤ 5 s, else `warning_ftl_charging`; not charging → `warning_ftl_delayed`.
static func escape_message(escaping: bool, hostile: bool, dying: bool, charging: bool, timer: float) -> Array:
	if not escaping or not hostile or dying:
		return []
	if not charging:
		return ["warning_ftl_delayed", false]
	if timer <= IMMINENT_AT:
		return ["warning_ftl_imminent", true]
	return ["warning_ftl_charging", false]


func setup(e: ShipState, p: ShipState, is_front: bool) -> void:
	enemy = e
	player = p
	front = is_front
	# Anchors AND offsets: set_anchors_preset alone on a node already in the tree (the back layer is added before
	# its setup) keeps the old 0 × 0 rect. A Control's visibility (culling) rect is its own size rect, so a 0 × 0
	# frame layer is culled as soon as the screen shake moves its origin off-screen (rules/hud_layout.md "Screen
	# shake": the TARGET frame vanished while the ship, status and system boxes kept drawing).
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(d: float) -> void:
	_t += d
	_ftl_timer += d
	if front and not status_only and enemy != null and is_visible_in_tree() and not TooltipService.hud_blocked:
		var m := TooltipService.local_pointer(self)
		for e in system_boxes():
			if Rect2(e[1] + Vector2(16, 0), Vector2(32, 48)).has_point(m):
				# Enemy SystemBox (bPlayerUI false): tooltip_<name>_enemy, instant.
				TooltipService.request(TooltipText.system_enemy(e[0]), {"instant": true, "kind": &"system_enemy",
					"source": self, "ctx": {"ship": enemy, "system": e[0]}})
	queue_redraw()


## [system id, box location] of the enemy system boxes (CombatControl target window order).
func system_boxes() -> Array:
	var ids := []
	for id in SystemState.ORDER:
		if enemy.sys(id) != null:
			ids.append(id)
	var x0 := HudLayout.ENEMY_SYSTEMS.x - (45 if ids.size() > 12 else 0)
	var out := []
	for i in ids.size():
		out.append([ids[i], Vector2(x0 + HudLayout.ENEMY_SYSTEM_STEP * i, HudLayout.ENEMY_SYSTEMS.y)])
	return out


func _draw() -> void:
	if enemy == null:
		return
	var f := HudLayout.ENEMY_FRAME
	if not front:
		HudDraw.img(self, "combatUI/box_hostiles2.png", f.position, HudLayout.ENEMY_TINT if enemy.hostile
			else Color.WHITE)
		return
	if status_only:
		draw_rect(STATUS_RECT, Color(0.02, 0.04, 0.06, 0.6))
	_draw_status(HudLayout.ENEMY_STATUS)
	var info := info_lines(enemy)
	HudDraw.text(self, 7, info[0], HudLayout.ENEMY_INFO, info[1], 2)
	HudDraw.text(self, 7, "
" + String(info[2]), HudLayout.ENEMY_INFO, info[3], 2)
	if status_only:
		return
	_draw_systems()
	_draw_escape()
	Hooks.emit(&"hud_draw.enemy_window", self, enemy)


const INFO_COLOR := Color(0.9529412, 1.0, 0.9019608)  # CombatControl::RenderTarget default info text colour
const INFO_RED := Color(1.0, 0.2, 0.2)  # hostile relationship / hack pulse


## CombatControl::RenderTarget info block (two lines, font 7, right-aligned at box + (380, 35)):
## [line 1, colour 1, line 2, colour 2]. No pilot / engines / oxygen hack: "Class: <ship class>" and
## "Relationship: Hostile|Neutral" (red when hostile). Any of those three hacked (IsSystemHacked > 0): the hack
## headline (engines > oxygen > pilot) and "Current Evasion: N" (GetNetDodgeFactor) — or "Current Oxygen: N"
## (GetOxygenPercentage) when oxygen is the hacked one — red while a hack pulse runs (IsSystemHacked > 1).
static func info_lines(e: ShipState) -> Array:
	var effects := {}
	for id in ["pilot", "engines", "oxygen"]:
		var s := e.sys(id)
		effects[id] = s.hack_effect() if s != null else 0
	if effects.pilot == 0 and effects.engines == 0 and effects.oxygen == 0:
		var cls := HudDraw.txt("combat_class").replace("\\1", TitleState.ship_class(String(e.blueprint.get("name", ""))))
		var rel := HudDraw.txt("combat_relationship").replace("\\1", HudDraw.txt("hostile" if e.hostile else "neutral"))
		return [cls, INFO_COLOR, rel, INFO_RED if e.hostile else INFO_COLOR]
	var head := "pilot_hacked"
	if effects.engines != 0:
		head = "engines_hacked"
	elif effects.oxygen != 0:
		head = "oxygen_hacked"
	var line2 := HudDraw.txt("current_evasion").replace("\\1", str(e.dodge_factor()))
	if effects.oxygen != 0:
		line2 = HudDraw.txt("current_oxygen").replace("\\1", str(e.oxygen_percentage()))
	var pulse: bool = effects.pilot > 1 or effects.engines > 1 or effects.oxygen > 1
	return [HudDraw.txt(head), INFO_COLOR, line2, INFO_RED if pulse else INFO_COLOR]


## The escape WarningMessage: centred at (box x + box width / 2, box y − 15), font 59 with the red glow,
## COLOR_RED_WARNING; alpha 1, or GetAlphaLevel(ftl_timer) = 1 − |t − 0.33| / 0.33 (triangle) when imminent.
func _draw_escape() -> void:
	var m := current_escape_message()
	if m.is_empty():
		_ftl_timer = 0.0
		return
	var a := 1.0
	if m[1]:
		var half := FTL_TIMER * 0.5
		a = (half - absf(fmod(_ftl_timer, FTL_TIMER) - half)) / half
	HudDraw.text_with_glow(self, HudDraw.txt(m[0]), escape_message_pos(touch), Color(HudLayout.RED_WARNING, a))


## Top-centre of the escape message. PC (vanilla): box y − 15, above the frame. Touch: the scaled TARGET window
## reaches the top of the canvas, so the message goes inside the frame, centred under the TARGET / HULL / SHIELDS
## block (below the hostile / hacked info lines).
static func escape_message_pos(touch_layout: bool) -> Vector2:
	var f := HudLayout.ENEMY_FRAME
	if touch_layout:
		return Vector2(f.position.x + f.size.x / 2, HudLayout.ENEMY_STATUS.y + 50)
	return Vector2(f.position.x + f.size.x / 2, f.position.y - 15)


func current_escape_message() -> Array:
	if run == null or run.enemy.is_empty() or run.enemy.get("done", false) or bool(run.enemy.get("escaped", false)):
		return []
	return escape_message(bool(run.enemy.get("escaping", false)), enemy.hostile, enemy.is_destroyed(),
		FtlDrive.ship_flying(enemy), float(run.enemy.get("escape_timer", 15.0)))


## CombatControl::RenderShipStatus, origin `o`.
func _draw_status(o: Vector2) -> void:
	HudDraw.text(self, 62, HudDraw.txt("target_window"), o + Vector2(-2, -36), Color.WHITE)
	var hull_l := HudDraw.txt("status_hull")
	var sh_l := HudDraw.txt("status_shields")
	_tag(o + Vector2(-5, -12), FtlData.ftl_text_width(61, hull_l))
	_tag(o + Vector2(-5, 15), FtlData.ftl_text_width(61, sh_l))
	HudDraw.text(self, 61, hull_l, o + Vector2(-3, -11), Color(0, 0, 0, 0.5))
	HudDraw.text(self, 61, sh_l, o + Vector2(-3, 16), Color(0, 0, 0, 0.5))
	# Hull: box_hostiles_hull2.png (22 segments) cropped to hull/22, green (0.47, 1, 0.47).
	var t := HudDraw.tex("combatUI/box_hostiles_hull2.png")
	if t:
		var frac: float = Hooks.filter(&"hud_hull_fraction", clampf(enemy.hull / 22.0, 0.0, 1.0), enemy, "enemy")
		var col: Color = Hooks.filter(&"hud_hull_color", Color(0.47, 1.0, 0.47), enemy, "enemy")
		HudDraw.img_cropped(self, "combatUI/box_hostiles_hull2.png", o + Vector2(0, 0),
			t.get_width() * clampf(frac, 0.0, 1.0), col)
	# Shield bubbles (21×21, step 23) and the recharge bar at (5, 57).
	var sh := enemy.sys("shields")
	var hacked := sh != null and sh.hack_effect() > 1
	for i in enemy.max_shield_layers():
		var on := i < enemy.shield_layers
		HudDraw.img(self, "combatUI/%s.png" % shield_image(on, hacked), o + Vector2(HudLayout.SHIELD_STEP * i, 36))
	# Vanilla draws the recharge bar and then, independently, the super shield bar (different rows).
	if enemy.shield_layers < enemy.max_shield_layers():
		var r := clampf(enemy.shield_charger / ShipState.SHIELD_CHARGE_TIME, 0.0, 1.0)
		if r > 0.0:
			draw_rect(Rect2(o + Vector2(5, 57), Vector2(roundf(52 * r), 6)),
				FtlColors.PURPLE_HACK if hacked else Color8(27, 132, 255))
	if enemy.super_shield > 0:
		_draw_super_shield(o)
	if enemy.is_destroyed():
		HudDraw.text(self, 62, "DESTROYED", o + Vector2(160, -36), HudLayout.RED_WARNING)


## Super shield bar of RenderShipStatus (0x0055ef20, tail): placed to the RIGHT of the shield bubbles on the same
## row, x = 23 · max layers (ShieldPower.second, the bubble count). Frame at (x + 13, 35):
## box_hostiles_shield_super5.png when the super shield max is 5, _super12.png when 12, otherwise a
## (0, 0, 0, 0.5) rect (10 · max + 6) × 13 with a 2 px white outline. Fill: COLOR_GREEN rect at (x + 16, 38),
## 10 px per point, height 7. Drawn only while the super shield is > 0.
func _draw_super_shield(o: Vector2) -> void:
	var r := super_shield_rects(enemy.max_shield_layers(), enemy.super_shield, enemy.super_shield_max)
	var smax := enemy.super_shield_max
	if smax == 5 or smax == 12:
		HudDraw.img(self, "combatUI/box_hostiles_shield_super%d.png" % smax, o + r[0].position)
	else:
		var box: Rect2 = r[0]
		box.position += o
		draw_rect(box, Color(0, 0, 0, 0.5))
		draw_rect(box, Color.WHITE, false, 2.0)
	var fill: Rect2 = r[1]
	fill.position += o
	draw_rect(fill, FtlColors.GREEN)


## [frame rect, fill rect] of the enemy super shield bar, relative to the status origin (see _draw_super_shield).
static func super_shield_rects(max_layers: int, points: int, points_max: int) -> Array:
	var x := HudLayout.SHIELD_STEP * max_layers
	return [Rect2(x + 13, 35, 10 * points_max + 6, 13), Rect2(x + 16, 38, maxi(10 * points, 0), 7)]


## Bubble image of one enemy shield layer: box_hostiles_shield1 = filled (charged layer), box_hostiles_shield2 =
## empty ring (missing / recharging); hacked: _shield2_hacked_charged (filled purple) / _shield2_hacked (ring).
static func shield_image(charged: bool, hacked: bool) -> String:
	if hacked:
		return "box_hostiles_shield2_hacked_charged" if charged else "box_hostiles_shield2_hacked"
	return "box_hostiles_shield1" if charged else "box_hostiles_shield2"


## box_hostiles_smallbar_left/middle/right 3-slice behind a tag text of width `tw`.
func _tag(p: Vector2, tw: int) -> void:
	HudDraw.img(self, "combatUI/box_hostiles_smallbar_left.png", p)
	var m := HudDraw.tex("combatUI/box_hostiles_smallbar_middle.png")
	if m:
		draw_texture_rect(m, Rect2(p + Vector2(8, 0), Vector2(maxf(tw - 6, 0), m.get_height())), false)
	HudDraw.img(self, "combatUI/box_hostiles_smallbar_right.png", p + Vector2(tw + 2, 0))


## Enemy SystemBoxes (playerUI = false): symbol always, bars with sensors (hacked systems always).
func _draw_systems() -> void:
	var ids := []
	for id in SystemState.ORDER:
		if enemy.sys(id) != null:
			ids.append(id)
	var x0 := HudLayout.ENEMY_SYSTEMS.x - (45 if ids.size() > 12 else 0)
	for i in ids.size():
		var s := enemy.sys(ids[i])
		var at := Vector2(x0 + HudLayout.ENEMY_SYSTEM_STEP * i, HudLayout.ENEMY_SYSTEMS.y)
		SystemPowerColumn.draw_box(self, enemy, s, at, _t, false, show_power or s.hack_effect() > 0)
