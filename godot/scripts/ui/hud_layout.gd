class_name HudLayout
extends RefCounted
## Every position/size of the combat HUD, in the 1280×720 frame (rules/hud_layout.md). One place, so
## adaptive layouts (phone / tablet / ultrawide) can swap these values later. "rel." = relative to the
## named parent. Asset paths are relative to ftl-data/img.

const FRAME := Vector2(1280, 720)


# ---------------------------------------------------------------- touch UI: centred frame (wide / tall screens)
## Touch UI only (`touch`; PC: always the origin, so the PC look never changes): where a full-frame screen or
## window (title menu, hangar, map, store, event box, ship screen, ...) goes so the 1280×720 frame is centred in
## the visible canvas (canvas_items stretch, aspect "expand": a wider or taller screen widens / heightens the
## canvas). `ci`'s parent must draw in canvas coordinates (a CanvasLayer / scene root at identity). The nodes are
## only moved (their transform), so their local hit testing keeps working. A CanvasLayer offset (the touch
## combat HUD centred on tall screens, main.gd `_touch_layout`) is taken out, so the result stays screen-centred.
static func frame_offset(ci: CanvasItem, touch: bool) -> Vector2:
	if not touch or ci == null or not ci.is_inside_tree():
		return Vector2.ZERO
	var s := ci.get_viewport_rect().size
	var layer := ci.get_canvas_layer_node()
	var lo := layer.offset if layer != null else Vector2.ZERO
	return ((s - FRAME) / 2.0).max(Vector2.ZERO).floor() - lo


## The rect a full-screen tint / fill should cover, in `ci`'s local coordinates: the frame on PC, the whole
## visible canvas in the touch UI (so a centred window's dim also covers the bands around the frame).
static func cover_rect(ci: CanvasItem, touch: bool) -> Rect2:
	if not touch or ci == null or not ci.is_inside_tree():
		return Rect2(Vector2.ZERO, FRAME)
	return ci.get_global_transform_with_canvas().affine_inverse() * ci.get_viewport_rect()

# ---------------------------------------------------------------- player / enemy ship placement
## CommandGui::LinkShip / ClearLocation: player ship translate = (350 + horizontal_shift, 170 + vertical_shift)
## with no ship at the beacon; CommandGui::AddEnemyShip moves x to 200 (150 in a boss fight) while a ship is there.
const PLAYER_SHIP := Vector2(350, 170)
const PLAYER_SHIP_X_ENEMY := 200
const PLAYER_SHIP_X_BOSS := 150
## CombatControl: origin (747, 0); enemy target pos = (308 − shipBox.w/2 + 20, 45 + vertical_shift + 85).
const COMBAT_ORIGIN := Vector2(747, 0)
const ENEMY_TARGET_X := 308 + 20
const ENEMY_TARGET_Y := 45 + 85

# ---------------------------------------------------------------- top-left: ShipStatus
const HULL_FRAME := Vector2(0, 0)  # top_hull.png 385×65
const HULL_FILL := Vector2(11, 0)  # top_hull_bar_mask.png, width 360·hull/max
const HULL_FILL_W := 360.0
const HULL_TEXT := Vector2(9, 9)  # "HULL", font 62
const HULL_LABEL_END := 121  # the label 4-slice ends at x = 121
const HULL_GREEN := Color8(120, 255, 120)  # hull >= 20
const HULL_YELLOW := Color8(255, 230, 92)  # 10..19
const HULL_RED := Color8(255, 92, 92)  # < 10
const SHIELDS_FRAME := Vector2(0, 43)  # top_shields4_*.png 135×52
const SHIELD_BUBBLE := Vector2(30, 47)  # 30×30, step 23
const SHIELD_STEP := 23
const ENERGY_SHIELD := Vector2(30, 77)  # energy_shield_box.png 98×12 [inferred position]
const EVADE_BOX := Vector2(1, 89)  # top_evade_oxygen*.png 104×56 [inferred]
const EVADE_TEXT_X := 82
const EVADE_TEXT_Y := 99
const O2_TEXT_Y := 121
const FUEL := Vector2(122, 43)
const FUEL_TEXT := Vector2(173, 58)  # centre of the count (font 0)
const MISSILES := Vector2(188, 43)
const MISSILES_TEXT := Vector2(240, 58)
const DRONES := Vector2(258, 43)
const DRONES_TEXT := Vector2(307, 58)
const SCRAP := Vector2(377, 0)
const SCRAP_TEXT := Vector2(460, 23)
const RESOURCE_TEXT := Color8(243, 255, 230)
# Warnings with lines: [anchor, polyline points rel. anchor, text origin rel. anchor]
const HULL_WARNING := [Vector2(340, 28), [Vector2(20, 22), Vector2(52, 54), Vector2(142, 54)], Vector2(97, 33)]
const SHIELDS_WARNING := [Vector2(110, 72), [Vector2(19, 21), Vector2(40, 42), Vector2(140, 42)], Vector2(93, 21)]
const O2_WARNING := [Vector2(89, 123), [Vector2(10, 13), Vector2(27, 47), Vector2(127, 47)], Vector2(78, 26)]
const INTRUDER_MSG := Vector2(730, 210)

# ---------------------------------------------------------------- top centre: FTL / SHIP / STORE / MENU
const FTL_BASE := Vector2(524, 22)  # FTL_base.png 98×55 (red variant 110×67 at −6)
const FTL_BARS := Rect2(536, 35, 74, 29)  # FTL_loadingbars(_off).png, width ∝ charge
const FTL_LABEL := Vector2(573, 18)  # "FTL DRIVE" centred, font 51
const FTL_STATUS := Vector2(573, 72)  # status line centred, font 61
const FTL_PULLOUT := Vector2(535, 63)  # FTL_pullout.png 75×49, slides −40 → 0
## FTLButton enginesDown (WarningWithLines, FTLButton::OnInit): anchor p + (78, 86) with p = (521, 10), polyline
## (9, 11) → (64, 66) → (155, 66), text origin (110, 46): "WARNING!" / `warning_engine`.
const ENGINES_WARNING := [Vector2(599, 96), [Vector2(9, 11), Vector2(64, 66), Vector2(155, 66)], Vector2(110, 46)]
const BUTTON_OFF := Color8(164, 171, 160)  # COLOR_BUTTON_OFF (inactive TextButton fill)
const SHIP_BUTTON := Vector2(625, 22)  # top_ship_on/off/select2.png 74×55
const SHIP_HIT := Rect2(631, 25, 62, 49)
const MENU_BUTTON := Vector2(702, 22)  # top_optionswrench_on/select2.png 55×55 (no store)
const IN_DANGER := Vector2(662, 6)

# ---------------------------------------------------------------- bottom left: SystemControl
const SYSTEMS_ORIGIN := Vector2(0, 382)
const SYSTEM_BOX_Y := 651  # box location y (rel. 269)
const SYSTEM_FIRST_X := 22  # running x starts at 22; each box at x + 36
const SYSTEM_STEP := 36  # plain box advance
const SYSTEM_STEP_BUTTON := 54  # box with a cooldown button (cloak, teleport, hack, mind)
const DRONE_BOX_ADVANCE := {2: 278, 3: 375, 4: 472}  # running x advance over the weapons panel
const WIRE_FULL := Vector2(33, 397)  # wireUI/wire_full.png 56×340
const BOX_WIRE := Vector2(31, 31)  # wire_36 / wire_54 / caps / wire_456_* rel. the box location
## Wire visible below 697 − 9·bars: the hatched edge spans the whole reactor column (original 1.6.9 HUD
## screenshots). The decompiled stencil offsets (mask at 431 + 1, 280 px) would put it 15 px lower; the shots win.
const WIRE_MASK_BOTTOM := 697
const WIRE_MASK := Vector2(36, 431)  # wire_left_mask.png (24×280) stencil at 0 bars (SystemControl (0,382) + (36,49))
const REACTOR_X := 12
const REACTOR_BOTTOM := 696  # SystemPower hit rect bottom (y = 696 − 9n, height 9n)
const REACTOR_BAR_TOP := 686  # top of the bottom reactor bar; bar i at 686 − 9i
const REACTOR_BAR := Vector2(28, 7)
const REACTOR_PITCH := 9
const POWER_BAR := Vector2(16, 6)  # system bars, pitch 8: bar i top at box + (24, 8 − 8·i) (RenderPowerBoxes)
const POWER_PITCH := 8
const POWER_BAR_Y0 := 8  # lowest bar's top below the box location: y + 10 − gap (RenderPowerBoxes)
const SHIELD_PAIR_GAP := 4  # GetPowerBars(useShieldGap): + 2·gap after every odd shields bar
const BUTTON_OFFSET := Vector2(36, -50)  # cooldown button rel. the box
const SUBSYSTEMS := Vector2(1015, 633)
const SUBSYSTEM_BOX := Vector2(1022, 667)  # box_subsystems4.png 170×40
const SUBSYSTEM_LABEL := Vector2(1102, 680)  # centred, font 62
const SUBSYSTEM_STEP := 36

# ---------------------------------------------------------------- bottom centre: weapons / drones
const ARMAMENT_Y := 607  # holder top
const HOLDER_X := 32  # holder x = system box x + 32
const BOX_ORIGIN := Vector2(16, 16)  # first armament box rel. holder
const BOX_STEP := 97
const BOX_SIZE := Vector2(95, 39)
const LABEL_TAB_Y := 61  # box_weapons_bottom_label.png 3-slice, h 27
const LABEL_TEXT := Vector2(19, 60)  # "WEAPONS" / "DRONES", font 62
const AUTOFIRE_RIGHT := {3: 311, 4: 408}  # autofire text right edge rel. holder
const AUTOFIRE_Y := 63
const WEAPON_WARNING := Vector2(203, -25)
const BUTTON_TEXT := Color8(25, 49, 51)  # COLOR_BUTTON_TEXT
const BUTTON_TEXT_LIGHT := Color8(40, 78, 82)  # ×1.6
const BUTTON_ON := Color8(235, 245, 229)  # COLOR_BUTTON_ON
const RED_WARNING := Color8(253, 84, 70)  # COLOR_RED_WARNING

# ---------------------------------------------------------------- right: enemy window
const ENEMY_FRAME := Rect2(872, 45, 410, 555)  # box_hostiles2.png (+ box_hostiles_mask.png)
const ENEMY_TINT := Color(1.0, 0.7, 0.7)
const ENEMY_STATUS := Vector2(889, 90)  # box + (17, 45)
const ENEMY_SYSTEMS := Vector2(912, 515)  # + 30·i
const ENEMY_SYSTEM_STEP := 30
const ENEMY_INFO := Vector2(1252, 80)  # right-aligned info texts, font 7 (box + (380, 35))

# ---------------------------------------------------------------- pause / warnings / tooltips
const PAUSE_TEXT := Vector2(640, 558)  # Text_pause1/2.png 256×64 centred
const PAUSE_HINT := Vector2(640, 580)
const WARNING_FLASH := 0.66  # s loop; alpha 0.9 first half, 0.4 second
const TOOLTIP_MAX := Vector2(1260, 670)

## Box x of each power-using system in the bar (SystemControl::CreateSystemBoxes), weapons, drones.
## Returns {id: x, "weapons": x, "drones": x}; `button_ids` advance 54, others 36.
static func system_box_xs(ids: Array, button_ids: Array, has_weapons: bool, weapon_slots: int,
		has_drones: bool) -> Dictionary:
	var out := {}
	var run := SYSTEM_FIRST_X
	for id in ids:
		out[id] = run + 36
		run += SYSTEM_STEP_BUTTON if button_ids.has(id) else SYSTEM_STEP
	if has_weapons:
		out["weapons"] = run + 36
		run += DRONE_BOX_ADVANCE.get(weapon_slots, 472)
	if has_drones:
		out["drones"] = run
	return out
