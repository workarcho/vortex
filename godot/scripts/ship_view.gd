class_name ShipView
extends Node2D
## Draws a ship (ShipState) with the original FTL assets. Contains no game logic.

const T := 35
# rules/ship_rendering.md §3: grid black α 0.25 width 1, walls black width 2 (1 px inside each room), 19 px gaps.
const GRID_COLOR := Color(0, 0, 0, 0.25)
const WALL_COLOR := Color(0, 0, 0, 1)
const WALL_WIDTH := 2.0
const DOOR_GAP_A := 8  # wall segment [t, t+8] and [t+27, t+35] on a tile edge holding a door / airlock
const DOOR_GAP_B := 27
const BLACKOUT := Color8(55, 55, 55)  # blacked-out room (§8)
# Doors (§5): door_sheet.png 5 frames x 35 px per row, 0.2 s open/close; rows by doors level, hacked row 140.
const DOOR_ANIM_TIME := 0.2
const DOOR_FRAMES := 5
const DOOR_FORCED_FRAME := 3
const DOOR_HACKED_ROW := 140
const DOOR_HIT_TIME := 0.5
const DOOR_HIT_TINT := Color(1, 0, 0)
const DOOR_UNPOWERED_TINT := Color(1, 0.6, 0.6)
const DOOR_HIGHLIGHT_ALPHA := 0.75
const INTERIOR_ALPHA := 0.75  # player interior images and console glows (§4)
# Fire / smoke / breach (§7).
const FIRE_FRAMES := 8
const FIRE_TIME := 1.0
const SMOKE_FRAMES := 7
const SMOKE_TIME := 1.0
const BREACH_FRAMES := 7
const BREACH_OFFSET := Vector2(7, 7)
# Thrusters (§2): effects/thrusters_on.png 4 frames 22×70, 0.5 s loop, offsets from the hull image corner.
const THRUSTER_FRAMES := 4
const THRUSTER_TIME := 0.5
const THRUSTERS := {"kestral": [Vector2(60, 39), Vector2(60, 305)], "fed_cruiser": [Vector2(17, 44), Vector2(17, 285)]}
const SUPER_SHIELD_COLOR := Color8(100, 255, 100)  # COLOR_GREEN (§9)
# Crew lasers (CrewLaser::OnRender, rules/crew_combat.md "Crew lasers"): the crewLaser cell (column 1 of the bottom
# row, 35x35) of the shooter's own <race>_base.png, rotated heading + 90 about its centre; tinted COLOR_GREEN /
# COLOR_RED (player / enemy) for human, anaerobic, engi, energy and slug, untinted for the others (mantis spit, rock,
# crystal shard, drone bolt). Hit: explosion_missile1_strip9 (9 frames of 32 px, 0.5 s) at half scale.
const CREW_SHOT_CELL := 35
const CREW_SHOT_TINTED := ["human", "anaerobic", "engi", "energy", "slug"]
const CREW_SHOT_HIT_FRAMES := 9
const CREW_SHOT_HIT_FW := 32
const O2_STRIPES_AT := 5.0  # Room::OnRenderO2Low: stripes when oxygen <= 5 %
const O2_STRIPES_ALPHA := 0.5

var ship: ShipState
var hull_tex: Texture2D
var floor_tex: Texture2D
var cloak_tex: Texture2D  # img/ship/<cloakImage>_cloak.png (Ship::OnInit cloakImageName; rules/cloaking.md "Visuals")
var shield_tex: Texture2D
var shield_flash := 0.0  # legacy whole-bubble flash (unused by combat; kept for callers)
var shield_hits: Array = []  # Shields::ShieldAnimation: {loc, size, thick, id}
var weapon_slide := {}  # WeaponState -> slideTracker progress 0 (retracted) .. 1 (out)
var highlight_rooms: Array = []  # rooms outlined yellow/orange (move destination, weapon target); set by Space
var _health_seen := {}  # CrewMember -> [last hp, lastHealthChange timer] (health bar after a change)
var hits_layer: Node2D  # shield hit arcs, above the ship and the incoming shots
var bubble_layer: Node2D  # shield bubble (z -1: under the hull)
var mask_layer: Node2D  # player layer-pop ghost / super-shield wave, circle-masked (z -1, after the bubble)
var _crew_anims := {}  # race -> {walk_down, walk_up, walk_left, walk_right, repair, type_*}
const GHOST_ALPHA := 0.5  # CrewAnimation::OnRender: bGhost crew (event class "ghost") drawn at alpha 0.5
var _time := 0.0
var hovered_door := -1  # player-ship door under the pointer (set by main from CrewControl.hovered_door)
var _grid := PackedVector2Array()  # Room::GetGridLines, precomputed per layout
var _walls := PackedVector2Array()  # Ship::OnInit wall lines with door gaps
var _doors_anim: Array = []  # per door: {p: 0 closed .. 1 open, hp, forced, hit: s of red tint left}
var _fire_phase := {}  # Vector2i(room, tile) -> random start (s) of the largeFire loop
var _smokes: Array = []  # [{room, tile, t, phase}]: one-shot fire_smoke after a fire went out
var _sparks := {}  # room -> {start, cycle, rot, mirror, mask}: stun_spark_big random orientation per cycle
var _thruster_phase := 0.0
var _blk := {}  # rooms blacked out this frame (ShipState.blacked_out_rooms)
var jump_time := -1.0  # s into ShipManager::jumpAnimation (2.0 s, started by JumpLeave), −1 = not jumping
var jump_driven := false  # player jump: jump_time is set by main.gd (set_jump_frame), not advanced here
var _smoke_emitters := {}  # CrewMember -> {parts: [{p, v, life}], counter, running}: firefight_cloud particles
var _ext_emitters := {}  # room id -> {parts, counter}: FIRE_EXTINGUISHERS clouds (room centre)
const SLUG_GEL_TINT := Color8(207, 70, 253)  # COLOR_PURPLE [inferred value]


var hide_interior := false  # hangar HIDE ROOMS (bShowRoom false): weapons, hull and thrusters only
var drew_interior := false  # the last _draw_ship drew rooms / crew (past the interior gate); for tests
## Camera rotation this view is shown with (Space.fixed_rotation; main.gd split layout: PI / 2, the ship faces up).
## What is meant to be read upright — system symbols, crew (sprite, outline, health bar, status icons), fires,
## smoke and breaches — is drawn turned by it about its own centre, so it stays upright on screen; hull, floor,
## walls, doors and grid turn with the ship. Crew facings are remapped to the screen direction (_facing).
var upright := 0.0


## Draw transform turning the next draws by `upright` about world point `c` (no-op when the view is not rotated).
func _upright_at(c: Vector2) -> void:
	if upright != 0.0:
		draw_set_transform_matrix(Transform2D(upright, c) * Transform2D(0.0, -c))


func _upright_end() -> void:
	if upright != 0.0:
		draw_set_transform_matrix(Transform2D.IDENTITY)


## The crew facing to draw: the world facing turned like the view (camera +PI/2: world right shows up on screen,
## up -> left, left -> down, down -> right), so the counter-rotated sprite walks the way it moves on screen.
func _facing(c: CrewMember) -> String:
	if upright == 0.0:
		return c.facing
	var dirs := ["right", "up", "left", "down"]  # counter-clockwise on screen
	var steps := int(roundf(upright / (PI / 2)))
	var i := dirs.find(c.facing)
	return c.facing if i < 0 else dirs[posmod(i + steps, 4)]


func setup(state: ShipState) -> void:
	ship = state
	var img: String = ship.blueprint.img
	if ship.is_player:
		hull_tex = FtlData.texture("img/ship/" + img + "_base.png")
		floor_tex = FtlData.texture("img/ship/" + String(ship.blueprint.get("floor_img", img)) + "_floor.png")
		# Shields::Shields 0x0060b230: player = "ship/<shieldFile>_shields1.png" (<shieldImage>, default img).
		shield_tex = FtlData.first_texture(["img/ship/" + String(ship.blueprint.get("shield_img", img)) + "_shields1.png",
			"img/ship/enemy_shields.png"])
	else:
		hull_tex = FtlData.first_texture([
			"img/ships_glow/" + img + "_base.png", "img/ship/" + img + "_base.png"])
		shield_tex = FtlData.texture("img/ship/enemy_shields.png")
	var cimg: String = ship.blueprint.get("cloak_img", img)
	cloak_tex = FtlData.first_texture(["img/ship/%s_cloak.png" % cimg, "img/ships_glow/%s_cloak.png" % cimg])
	bubble_layer = Node2D.new()
	bubble_layer.z_index = -1
	bubble_layer.draw.connect(_draw_shield_bubble)
	add_child(bubble_layer)
	mask_layer = Node2D.new()
	mask_layer.z_index = -1
	var sh := Shader.new()
	sh.code = MASK_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mask_layer.material = mat
	mask_layer.draw.connect(_draw_shield_mask)
	add_child(mask_layer)
	hits_layer = Node2D.new()
	hits_layer.z_index = 6
	hits_layer.draw.connect(_draw_shield_hits)
	add_child(hits_layer)
	for w in ship.weapons + ship.artillery:
		weapon_slide[w] = 1.0 if w.powered else 0.0
	_build_lines()
	_doors_anim.clear()
	for d in ship.env.doors:
		_doors_anim.append({"p": 1.0 if _door_shown_open(d) else 0.0, "hp": d.health, "forced": d.forced, "hit": 0.0})
	_thruster_phase = randf() * THRUSTER_TIME
	queue_redraw()


## Grid (Room::GetGridLines: lines between tiles of a room at edge − 0.5, from +0.5 to size + 0.5) and walls
## (Ship::OnInit: per room, each edge 1 px inside, tile by tile, split around a door / airlock).
func _build_lines() -> void:
	_grid.clear()
	_walls.clear()
	var door_keys := {}
	for d in ship.layout.doors:
		door_keys[Vector3i(d.x, d.y, 1 if d.vertical else 0)] = true
	for r in ship.layout.rooms:
		var rr: Rect2i = r.rect
		var rect := ship.room_rect(r.id)
		var p := rect.position
		var s := rect.size
		for k in range(1, rr.size.x):
			_grid.append_array([p + Vector2(k * T - 0.5, 0.5), p + Vector2(k * T - 0.5, s.y + 0.5)])
		for k in range(1, rr.size.y):
			_grid.append_array([p + Vector2(0.5, k * T - 0.5), p + Vector2(s.x + 0.5, k * T - 0.5)])
		for i in rr.size.x:
			var tx := p.x + i * T
			_wall_segment(Vector2(tx, p.y + 1), Vector2(1, 0), door_keys.has(Vector3i(rr.position.x + i, rr.position.y, 0)))
			_wall_segment(Vector2(tx, p.y + s.y - 1), Vector2(1, 0),
				door_keys.has(Vector3i(rr.position.x + i, rr.end.y, 0)))
		for j in rr.size.y:
			var ty := p.y + j * T
			_wall_segment(Vector2(p.x + 1, ty), Vector2(0, 1), door_keys.has(Vector3i(rr.position.x, rr.position.y + j, 1)))
			_wall_segment(Vector2(p.x + s.x - 1, ty), Vector2(0, 1),
				door_keys.has(Vector3i(rr.end.x, rr.position.y + j, 1)))


func _wall_segment(start: Vector2, dir: Vector2, door: bool) -> void:
	if door:
		_walls.append_array([start, start + dir * DOOR_GAP_A, start + dir * DOOR_GAP_B, start + dir * T])
	else:
		_walls.append_array([start, start + dir * T])


## A door is shown open when open, fake-opened by crew walking through, or broken open by intruders.
static func _door_shown_open(d: Dictionary) -> bool:
	return d.open or float(d.crew_pass) > 0.0 or float(d.forced) > 0.0


## Rectangle (local coordinates) of a door.
func door_rect(d: Dictionary) -> Rect2:
	return door_rect_of(ship, d)


static func door_rect_of(s: ShipState, d: Dictionary) -> Rect2:
	var p: Vector2 = s.origin + Vector2(d.x, d.y) * T
	if d.vertical:
		return Rect2(p + Vector2(-3, 7), Vector2(6, 21))
	return Rect2(p + Vector2(7, -3), Vector2(21, 6))


## Index of the door under a point (with a touch margin), or -1.
func door_at(p: Vector2) -> int:
	return door_index_at(ship, p)


static func door_index_at(s: ShipState, p: Vector2) -> int:
	for i in s.env.doors.size():
		if door_rect_of(s, s.env.doors[i]).grow(6).has_point(p):
			return i
	return -1


## Crew animations of a race (loaded once): walk per direction, repair, typing at a console.
func _anims_for(race: String) -> Dictionary:
	if not _crew_anims.has(race):
		var a := {}
		for k in ["walk_down", "walk_up", "walk_left", "walk_right", "repair",
				"type_down", "type_up", "type_left", "type_right",
				"shoot_down", "shoot_up", "shoot_left", "shoot_right", "punch_down", "punch_up",
				"fire_down", "fire_up", "fire_left", "fire_right", "death_right"]:
			a[k] = FtlData.anim(("human" if race == "ghost" else race) + "_" + k)
		if race == "ghost":
			a["death_right"] = FtlData.anim("ghost_death")  # bGhost: human strips; dies with the teleport strip
		_crew_anims[race] = a
	return _crew_anims[race]


## CrewAnimation bTyping = CrewMember bActiveManning (CrewMember::SetCurrentSystem): on the room's console slot,
## idle, and the system is boostable and intact (manning bonus > 0). In and out of combat alike (rules/crew.md).
static func is_typing(sh: ShipState, c: CrewMember) -> bool:
	var s := sh.system_in_room(c.room)
	return s != null and sh.active_manning_crew(s.id) == c and sh.crew_level_in(s.id) > 0


## Frame of an animation at the current time (or `index` if >= 0).
func _anim_frame(anim: Dictionary, index := -1) -> Rect2:
	var frames: Array = anim.frames
	if index >= 0:
		return frames[mini(index, frames.size() - 1)]
	var ft: float = maxf(float(anim.time), 0.01) / frames.size()
	return frames[int(_time / ft) % frames.size()]


## Crew sounds (CrewAnimation::OnUpdate / UpdateShooting): the death sound when the death animation
## starts, only for crew owned by the player ship (iShipId == 0); a shot sound for every crew shot.
func _crew_sounds() -> void:
	for c in ship.crew:
		if not c.is_alive():
			if not c.death_sound_done:
				c.death_sound_done = true
				if c.is_drone():
					FtlData.play("sysExplosion")  # drones: both sides (rules/crew.md)
				elif c.player_owned:
					FtlData.play(c.death_sound())
			continue
		if c.shots_fired > c.last_shots_fired:
			FtlData.play(c.shooting_sound())
		c.last_shots_fired = c.shots_fired
		# Ion boarding drone (IonDroneAnimation): ionBoarderCharge when a charge starts, ionHit1 at the discharge.
		if c.ion_charges > c.last_ion_charges:
			FtlData.play("ionBoarderCharge")
		c.last_ion_charges = c.ion_charges
		if c.ion_discharges > c.last_ion_discharges:
			FtlData.play("ionHit1")
		c.last_ion_discharges = c.ion_discharges


func _draw_crew() -> void:
	var life := not _blk.is_empty() and ship.player_detects_life()
	for c in ship.crew:
		_upright_at(_crew_at(c))  # (each crew member resets it; cleared after the loop)
		if _blk.has(c.room):
			# Blacked-out room (§8): hidden, unless the player detects life (slug crew or LIFE_SCANNER): then
			# CrewMember::OnRender(outlineOnly) draws the red life sign; drones and bodies stay hidden.
			if life and c.is_alive() and not c.is_drone():
				_draw_life_sign(c)
			continue
		var anims := _anims_for(c.race)
		if not c.is_alive():
			# Death animation (<race>_death_right for every direction), played once, then its last
			# frame fades out over DEATH_FADE s.
			var da: Dictionary = anims.get("death_right", {})
			var fade := 0.0 if c.is_drone() else CrewMember.DEATH_FADE  # drones: no fade-out
			if not da.is_empty() and c.dead_time < da.time + fade:
				var n: int = da.frames.size()
				var src0 := _anim_frame(da, int(c.dead_time / da.time * n))
				var alpha := clampf(1.0 - (c.dead_time - da.time) / fade, 0.0, 1.0) if fade > 0.0 else 1.0
				CrewPortrait.draw_frame(self, CrewPortrait.look_of(c), da, src0,
					Rect2(c.pos - src0.size / 2, src0.size), Color.WHITE, alpha)
			continue
		var pick := _crew_anim(c, anims)
		var anim: Dictionary = pick[0]
		var frame: int = pick[1]
		var firefight: bool = pick[2]
		# Two crew sharing a tile (punching) are drawn apart a little (visual only).
		var at := _crew_at(c)
		var state := selection_state(c)
		if firefight:
			_draw_firefight(c, at - Vector2(17, 17))
		if not anim.is_empty():
			var src := _anim_frame(anim, frame)
			var rect := Rect2(at - src.size / 2, src.size)
			# CrewAnimation::OnRender: the <race>_color.png silhouette (same frame) under the body, tinted
			# per side / selection state; x1.125 about the frame centre when selected. Drones have none.
			var outline := _outline_texture(c, anim)
			if outline:
				var orect := rect
				if state == 1:
					orect = Rect2(at - src.size * 1.125 / 2, src.size * 1.125)
				var oc := outline_color(c, state)
				if c.race == "ghost":
					oc.a *= GHOST_ALPHA  # bGhost: every strip of CrewAnimation::OnRender at alpha 0.5
				draw_texture_rect_region(outline, orect, src, oc)
			# Base x body tint, then the colour layers (rules/crew_appearance.md §4).
			CrewPortrait.draw_frame(self, CrewPortrait.look_of(c), anim, src, rect, body_tint(c, state),
				GHOST_ALPHA if c.race == "ghost" else 1.0)
		else:
			draw_circle(c.pos, 8, Color8(240, 200, 120))
		if c.drone_kind == "boarder_ion" and c.ion_charge >= 0.0:
			_draw_ion_glow(c, at)
		# CrewMember::OnRenderHealth: the healing animation (people/healing_strip11.png, 11 frames 32×32, 1.0 s loop)
		# while fMedbay > 0, top-left at (x − 17, y − 20), before the health bar.
		if _heal_t.has(c):
			var htex := FtlData.texture("img/people/healing_strip11.png")
			if htex:
				var hf := int(float(_heal_t[c]) * HEAL_FRAMES / HEAL_TIME) % HEAL_FRAMES
				draw_texture_rect_region(htex, Rect2(at - Vector2(17, 20), Vector2(32, 32)),
					Rect2(hf * 32, 0, 32, 32))
		if show_health_bar(c):
			_draw_health(c, at)
		# Mind control: people/mindcontrol_strip8 (8 frames 14×14, 1.0 s loop) over the crew while
		# controlled (at the health-bar icon spot, x−27, y−20); "RESISTED" after a Slug shrugged it off.
		if c.mind_controlled:
			var mc := FtlData.anim("mindcontrol")
			if not mc.is_empty():
				var msrc := _anim_frame(mc)
				draw_texture_rect_region(mc.texture, Rect2(at + Vector2(-27, -20), msrc.size), msrc)
		if c.resisted > 0.0:
			draw_string(ThemeDB.fallback_font, at + Vector2(-24, -22), "RESISTED", HORIZONTAL_ALIGNMENT_LEFT, -1,
				10, FtlColors.PURPLE_HACK)
		if c.level_up >= 0.0 and c.player_owned and c.last_level_up != "":
			_draw_level_up(c, at)
	_upright_end()


## CrewMember::OnRenderHealth, last (player crew while levelUp runs): q = 2 × progress of the 2.0 s tracker; the
## skill's icons/s_<skill>_overlay.png (GetSkillIcon(lastLevelUp, true), 32×32) in GetCurrentSkillColor
## (xp / max: < 0.5 COLOR_CB_WHITE, < 1 COLOR_GREEN, else COLOR_YELLOW / colour-blind COLOR_CB_BLUE):
##   - blitted at size s = 3 × q × 32 centred on (x, y − 14), alpha (1 − q) × 0.6 (an expanding ghost, gone at q 1);
##   - at its own size at (x − 16, y − 30) with opacity q (fades in over the first second, then stays).
func _draw_level_up(c: CrewMember, at: Vector2) -> void:
	var tex := FtlData.texture("img/icons/s_%s_overlay.png" % c.last_level_up)
	if tex == null:
		return
	var q := 2.0 * clampf(c.level_up / CrewMember.LEVEL_UP_TIME, 0.0, 1.0)
	var r := float(c.skills.get(c.last_level_up, 0)) / float(maxi(c.skill_cap(c.last_level_up), 1))
	var col := Color8(243, 255, 238)
	if r >= 1.0:
		col = Color8(0, 147, 224) if GameOptions.colorblind else FtlColors.YELLOW
	elif r >= 0.5:
		col = FtlColors.GREEN
	var p := at.floor()
	var ghost := (1.0 - q) * 0.6
	if ghost > 0.0:
		var s := 3.0 * q * 32.0
		draw_texture_rect(tex, Rect2(p.x - 0.5 * s, p.y - 0.5 * s - 14.0, s, s), false,
			Color(col.r, col.g, col.b, ghost))
	draw_texture(tex, p + Vector2(-16, -30), Color(col.r, col.g, col.b, minf(q, 1.0)))


## IonDroneAnimation::OnRender: while the charge animation runs (ionAnimation running), boarder_ion_glow (sheet cell
## x 5, y 3: the blue disc) over the body at (lastPosition - 17, the body's own cell), white, alpha = ionEffect (0
## during the 1 s charge, then fading in at 1/s until the discharge at 1.25).
func _draw_ion_glow(c: CrewMember, at: Vector2) -> void:
	var g := FtlData.anim("boarder_ion_glow")
	if g.is_empty():
		return
	var src := _anim_frame(g, 0)
	draw_texture_rect_region(g.texture, Rect2(at - src.size / 2, src.size), src,
		Color(1, 1, 1, clampf(c.ion_effect, 0.0, 1.0)))


## IonDroneAnimation::OnRenderProps (replaces the crew-laser props): the discharge explosion explosion_big1_ion
## (64 px, 10 frames, 0.5 s) at its fixed top-left (drone position - 32 at the discharge), multiplied by
## COLOR_BLUE_ION.
func _draw_ion_explosion(c: CrewMember) -> void:
	var e := FtlData.anim("explosion_big1_ion")
	if e.is_empty():
		return
	var n: int = e.frames.size()
	var src := _anim_frame(e, mini(int(c.ion_explosion / CrewCombat.ION_EXPLOSION_TIME * n), n - 1))
	draw_texture_rect_region(e.texture, Rect2(c.ion_explosion_pos, src.size), src, FtlColors.BLUE)


## Crew lasers in flight and their hits (CrewAnimation::OnRenderProps, from CrewMember::OnRenderHealth: after every
## crew body, not for a dying shooter or one in a blacked-out room; not moved by PositionShift).
func _draw_crew_shots() -> void:
	var hit_tex := FtlData.texture("img/effects/explosion_missile1_strip9.png")
	for c in ship.crew:
		if not c.is_alive() or _blk.has(c.room):
			continue
		if c.drone_kind == "boarder_ion" and c.ion_explosion >= 0.0:
			_draw_ion_explosion(c)
		if c.shots.is_empty():
			continue
		var walk: Dictionary = _anims_for(c.race).get("walk_down", {})
		var tex: Texture2D = walk.get("texture")
		var tint := Color.WHITE
		if c.race in CREW_SHOT_TINTED and c.drone_kind == "":
			tint = FtlColors.GREEN if c.player_owned else FtlColors.RED
		for sh in c.shots:
			var p: Vector2 = sh.pos
			if sh.death < 0.0:
				if tex == null:
					continue
				var cell := Rect2(CREW_SHOT_CELL, tex.get_height() - CREW_SHOT_CELL, CREW_SHOT_CELL, CREW_SHOT_CELL)
				draw_set_transform(p, deg_to_rad(sh.heading + 90.0))
				var h := CREW_SHOT_CELL * 0.5
				draw_texture_rect_region(tex, Rect2(-h, -h, CREW_SHOT_CELL, CREW_SHOT_CELL), cell, tint)
				draw_set_transform(Vector2.ZERO)
			elif hit_tex:
				var f := mini(int(sh.death / CrewCombat.SHOT_HIT_TIME * CREW_SHOT_HIT_FRAMES), CREW_SHOT_HIT_FRAMES - 1)
				var size := CREW_SHOT_HIT_FW * 0.5
				var src := Rect2(f * CREW_SHOT_HIT_FW, 0, CREW_SHOT_HIT_FW, hit_tex.get_height())
				draw_texture_rect_region(hit_tex, Rect2(p - Vector2(8, 8), Vector2(size, size)), src)


## The animation a living crew member shows this frame (CrewAnimation status): [anim, frame (−1 = running), firefight].
## Shared by the normal draw and the life sign (outlineOnly renders the same status / direction / frame).
func _crew_anim(c: CrewMember, anims: Dictionary) -> Array:
	var face := _facing(c)  # screen facing (the world one unless the view is rotated)
	var anim: Dictionary = anims.get("walk_" + face, {})
	var frame := 0  # idle: first frame of the facing direction
	var firefight := false  # CrewAnimation status 4 (fire_<dir>): the extinguisher cloud is drawn
	if c.drone_kind == "boarder_ion" and CrewCombat.ion_status7(ship, c):
		return _ion_drone_anim(c, anims, face)
	var shooting: bool = c.blocking_door >= 0 or c.task == CrewMember.Task.SABOTAGE 		or (c.target != null and not c.is_walking() and not c.shared_spot)
	if c.target != null and c.shared_spot and not c.is_walking():
		var pk: String = "punch_down" if face == "down" else "punch_up"  # left/right use punch_up
		if not anims.get(pk, {}).is_empty():
			anim = anims[pk]
			frame = -1
	elif shooting and not anims.get("shoot_" + face, {}).is_empty():
		anim = anims["shoot_" + face]
		if c.drone_kind == "" and c.race in CrewCombat.FRAME_FIRE_RACES:
			# Rock / mantis: the shoot strip loops (GetFiringFrame -1); their shots follow its frames.
			frame = int(c.shoot_anim / CrewCombat.FRAME_FIRE_LOOP * anim.frames.size()) % anim.frames.size()
		else:
			frame = CrewCombat.firing_frame(c.pos, c.aim)
	elif c.is_walking():
		frame = -1
		# CREW_STIMS: the walk cycle runs in 0.7 s instead of 1.0 s (CrewAnimation::OnUpdate).
		var wt := AugmentRule.walk_time(AugmentRule.crew_owner(ship, c), c)
		if wt < 1.0 and not anim.is_empty():
			frame = int(_time / (wt / anim.frames.size())) % anim.frames.size()
	elif c.task in [CrewMember.Task.REPAIR_SYSTEM, CrewMember.Task.FIRE, CrewMember.Task.BREACH]:
		# Any repair (system, breach or fire) in a burning room (iOnFire > 0) uses fire_<dir>;
		# otherwise the single repair animation.
		var fk: String = "fire_" + face
		if not ship.fires.get(c.room, {}).is_empty() and not anims.get(fk, {}).is_empty():
			anim = anims[fk]
			frame = -1
			firefight = true
		elif not anims.get("repair", {}).is_empty():
			anim = anims.repair
			frame = -1
	elif c.task == CrewMember.Task.MAN and is_typing(ship, c):
		if not anims.get("type_" + face, {}).is_empty():
			anim = anims["type_" + face]
			frame = -1
	return [anim, frame, firefight]


## Ion boarding drone in status 7 (IonDroneAnimation::UpdateShooting swaps the shoot strip): a sealed door ->
## boarder_ion_shoot_<dir> (2 frames, its own loop time); charging -> boarder_ion_ion (5 frames over 1 s, then its
## last frame held); otherwise a copy of the walk_down strip (stopped: frame 0) whatever the facing.
func _ion_drone_anim(c: CrewMember, anims: Dictionary, face: String) -> Array:
	if c.blocking_door >= 0:
		var sa: Dictionary = anims.get("shoot_" + face, {})
		if not sa.is_empty():
			var n: int = sa.frames.size()
			return [sa, int(c.ion_door_t / CrewCombat.ION_DOOR_LOOP * n) % n, false]
	elif c.ion_charge >= 0.0:
		var ia := FtlData.anim("boarder_ion_ion")
		if not ia.is_empty():
			var n2: int = ia.frames.size()
			return [ia, mini(int(c.ion_charge / CrewCombat.ION_CHARGE_TIME * n2), n2 - 1), false]
	return [anims.get("walk_down", {}), 0, false]


## Draw centre of a crew member: its position; two crew sharing a tile (punching) are drawn apart a little.
func _crew_at(c: CrewMember) -> Vector2:
	var at: Vector2 = c.pos
	if c.shared_spot and c.target != null:
		at += Vector2(7, 0) if c.is_intruder(ship) else Vector2(-7, 0)
	return at


## Life sign = CrewAnimation::OnRender(outlineOnly = true) (rules/crew_appearance.md §4 "Life signs"): the
## **base** strip only (no `_color` outline, no colour layers, no extinguisher cloud), current animation frame,
## multiplied by COLOR_RED (255, 50, 50) for every crew member (player's or enemy's), alpha 0.75 (1.0 in
## colourblind mode). No health bar, no selection scale.
const LIFE_SIGN_COLOR := Color8(255, 50, 50)
const LIFE_SIGN_ALPHA := 0.75


static func life_sign_color() -> Color:
	return Color(LIFE_SIGN_COLOR, 1.0 if GameOptions.colorblind else LIFE_SIGN_ALPHA)


func _draw_life_sign(c: CrewMember) -> void:
	var pick := _crew_anim(c, _anims_for(c.race))
	var anim: Dictionary = pick[0]
	if anim.is_empty():
		return
	var src := _anim_frame(anim, pick[1])
	var rect := Rect2(_crew_at(c) - src.size / 2, src.size)
	var tex: Texture2D = anim.texture
	if CrewPortrait.is_base_anim(c.race, anim):
		var lk := CrewPortrait.look_of(c)
		var base := FtlData.texture("img/people/%s_base.png" % lk.file)
		if base:
			tex = base
	draw_texture_rect_region(tex, rect, src, life_sign_color())


# ------------------------------------------------- jump away (ShipManager::JumpLeave / Ship::OnRenderJump)

const JUMP_TIME := 2.0  # jumpAnimation length (ShipManager ctor)


## Starts the jump-away animation (JumpLeave plays "jumpLeave").
func start_jump() -> void:
	if jump_time < 0.0:
		jump_time = 0.0
		FtlData.play("jumpLeave")


## The player's jump (main.gd `_jump_step`, which runs while the world is paused): the jumpAnimation tracker time
## t (0..2) set from outside every frame; JumpLeave runs it forward, JumpArrive in reverse (2 -> 0). t < 0 ends it.
func set_jump_frame(t: float) -> void:
	jump_driven = t >= 0.0
	jump_time = t


func jump_done() -> bool:
	return jump_time >= JUMP_TIME


## ShipManager::OnRender: progress 0 for the first second, then 2·(t − 1) up to 1.
static func jump_progress(t: float) -> float:
	return clampf((t - 1.0) * 2.0, 0.0, 1.0)


## Ship::OnRenderJump glare: [x, y, size] of effects/glowing_star.png (64×64 scaled to `size`) in the ship box
## (w, h) for progress p; enemy ships (iShipId 1) rise out of the top, the player's leaves to the right.
static func jump_glare(p: float, w: float, h: float, player: bool) -> Array:
	var l := p / 0.75
	var size := 0.0
	if l >= 1.0:
		l = 1.0
	elif l > 0.0:
		size = 600.0 - 2.0 * (l - 0.5) * 600.0 if l >= 0.5 else l * 1200.0 + 64.0
	var half := size * 0.5
	if player:
		return [-half + l * w, h / 2.0 - half, size]
	return [w / 2.0 - half, h - half - h * l, size]


## Hull at alpha 1 − progress (no interior, no weapons), then the glare.
func _draw_jump() -> void:
	var p := jump_progress(jump_time)
	var hull_pos := ship.hull_position()
	if hull_tex:
		draw_texture(hull_tex, hull_pos, Color(1, 1, 1, 1.0 - p))
		var g := jump_glare(p, hull_tex.get_width(), hull_tex.get_height(), ship.is_player)
		var glare := FtlData.texture("img/effects/glowing_star.png")
		if glare and float(g[2]) > 0.0:
			draw_texture_rect(glare, Rect2(hull_pos + Vector2(g[0], g[1]), Vector2(g[2], g[2])), false)
	# Player ship (bShowEngines): the thrusters at alpha 1 − min(progress / 0.75, 1), after the glare.
	if ship.is_player:
		_draw_thrusters(1.0 - minf(p / 0.75, 1.0), true)


# ------------------------------------------------- extinguisher cloud (CrewAnimation::smokeEmitter)

## ParticleEmitter("people/firefight_cloud.png", 24×24) set up in CrewAnimation::OnInit: lifespan 1.0, birthRate
## 3.0, speedMag 1.0; CrewAnimation::UpdateFiring places it per facing and runs it while not stunned / frozen.
## Units are the ×16 speed factor: one birth every 3/16 s, 16 px/s, life 1 s, alpha 4 × life remaining.
const SMOKE_EMIT := {"down": [Vector2(7, 17), 90.0], "right": [Vector2(15, 15), 0.0], "up": [Vector2(14, 4), 270.0],
	"left": [Vector2(4, 10), 180.0]}
const SMOKE_BIRTH := 3.0
const SMOKE_SPEED := 1.0
const SMOKE_LIFE := 1.0
const SMOKE_MAX := 64


static func is_firefighting(sh: ShipState, c: CrewMember) -> bool:
	return c.is_alive() and not c.is_walking() and c.task in [CrewMember.Task.REPAIR_SYSTEM, CrewMember.Task.FIRE,
		CrewMember.Task.BREACH] and not sh.fires.get(c.room, {}).is_empty()


## ParticleEmitter::OnUpdate for every crew's emitter (emitters are created on the first fire fight).
func _update_firefight(delta: float) -> void:
	var sf := delta * GameClock.BASE
	for c in ship.crew:
		var ff := is_firefighting(ship, c)
		if not ff and not _smoke_emitters.has(c):
			continue
		var e: Dictionary = _smoke_emitters.get(c, {"parts": [], "counter": 0.01})
		_smoke_emitters[c] = e
		var parts: Array = e.parts
		for i in range(parts.size() - 1, -1, -1):
			var pt: Dictionary = parts[i]
			pt.p += pt.v * sf
			pt.life -= sf * 0.0625
			if pt.life < 0.0:
				parts.remove_at(i)
		if ff and c.stun <= 0.0:  # UpdateFiring: running = not frozen and not stunned
			e.counter -= sf
			if e.counter <= 0.0:
				e.counter = SMOKE_BIRTH
				if parts.size() < SMOKE_MAX:
					var em: Array = SMOKE_EMIT.get(_facing(c), SMOKE_EMIT.down)
					var jitter := Vector2(float(randi() % 100) / 50.0 - 1.0, float(randi() % 100) / 50.0 - 1.0) * 2.0
					var ang := deg_to_rad(float(em[1]) - 45.0 + float(randi() % 90))
					parts.append({"p": (em[0] as Vector2) + jitter, "v": Vector2(cos(ang), sin(ang)) * SMOKE_SPEED,
						"life": SMOKE_LIFE})
		elif parts.is_empty():
			_smoke_emitters.erase(c)


## ParticleEmitter::OnRender, under the crew body: each particle centred on its position, alpha 4 × life.
func _draw_firefight(c: CrewMember, origin: Vector2) -> void:
	var e: Dictionary = _smoke_emitters.get(c, {})
	var tex := FtlData.texture("img/people/firefight_cloud.png")
	if e.is_empty() or tex == null:
		return
	var half := tex.get_size() / 2
	for pt in e.parts:
		draw_texture(tex, origin + (pt.p as Vector2) - half, Color(1, 1, 1, clampf(4.0 * float(pt.life), 0.0, 1.0)))


## selectionState: 1 selected, 2 potential (hovered / in the drag box), 0 none (selected wins).
static func selection_state(c: CrewMember) -> int:
	if c.selected:
		return 1
	return 2 if c.hovered else 0


const OUTLINE_YELLOW := Color8(255, 255, 50)  # COLOR_YELLOW: player crew, not selected
const OUTLINE_GREEN := Color8(100, 255, 100)  # COLOR_GREEN: selected / hovered
const OUTLINE_RED := Color8(255, 50, 50)  # COLOR_RED: enemy crew
const SELECTED_TINT := Color(0.5, 1.0, 0.5)
const STUN_TINT := Color8(125, 125, 125)
const HEALTH_SHOW_BELOW := 0.55  # health bar always shown below 55 % of max
const HEALTH_CHANGE_TIME := 2.0  # lastHealthChange (CrewMember::DirectModifyHealth)
const HEALTH_FLASH_AT := 25.0  # hp at or below which health_box_red.png flashes
const HEALTH_FLASH_PERIOD := 1.0  # flashHealthTracker length [inferred]


static func outline_color(c: CrewMember, state: int) -> Color:
	if not c.player_owned:
		return OUTLINE_RED
	return OUTLINE_GREEN if state > 0 else OUTLINE_YELLOW


static func body_tint(c: CrewMember, state: int) -> Color:
	if c.stun > 0.0:
		return STUN_TINT
	return SELECTED_TINT if state == 1 else Color.WHITE


## The silhouette sheet (`<file>_color.png`, female for female humans), only for frames of the base sheet.
func _outline_texture(c: CrewMember, anim: Dictionary) -> Texture2D:
	return CrewPortrait.outline_texture(c, anim)


## CrewMember::OnRenderHealth condition: selected or hovered, health changed in the last 2 s, or below 55 %.
func show_health_bar(c: CrewMember) -> bool:
	if not c.is_alive():
		return false
	if selection_state(c) > 0 or c.hp < HEALTH_SHOW_BELOW * c.max_hp:
		return true
	return _health_seen.has(c) and float(_health_seen[c][1]) > 0.0


func _draw_health(c: CrewMember, at: Vector2) -> void:
	var red := c.hp <= HEALTH_FLASH_AT and fmod(_time, HEALTH_FLASH_PERIOD) < HEALTH_FLASH_PERIOD / 2
	var box := FtlData.texture("img/people/health_box_red.png" if red else "img/people/health_box.png")
	var p := (at + Vector2(-18, -17)).floor()
	if box:
		draw_texture(box, p)
	var w := roundf(25.0 * clampf(c.hp / c.max_hp, 0.0, 1.0))
	draw_rect(Rect2(p + Vector2(5, 3), Vector2(w, 3)), Color(0, 1, 0) if c.player_owned else Color(1, 0, 0))


## lastHealthChange: set to 2 s whenever health changes (not when it lands on full), counts down.
## CrewMember::OnLoop: healing.Start (keeps running) while fMedbay > 0 (medbay_rate), Stop (reset) otherwise.
const HEAL_FRAMES := 11
const HEAL_TIME := 1.0
var _heal_t := {}  # CrewMember -> s into the healing loop


func _update_healing(delta: float) -> void:
	var seen := {}
	for c in ship.crew:
		if c.is_alive() and c.medbay_rate > 0.0:
			seen[c] = fmod(float(_heal_t.get(c, -delta)) + delta, HEAL_TIME)
	_heal_t = seen


func _track_health(delta: float) -> void:
	var seen := {}
	for c in ship.crew:
		var e: Array = _health_seen.get(c, [c.hp, 0.0])
		var t: float = maxf(float(e[1]) - delta, 0.0)
		if not is_equal_approx(float(e[0]), c.hp) and c.hp < c.max_hp:
			t = HEALTH_CHANGE_TIME
		seen[c] = [c.hp, t]
	_health_seen = seen


## CrewMember::OnRenderPath: people/green_destination.png on the slot of every walking player crew.
func _draw_destinations() -> void:
	var tex := FtlData.texture("img/people/green_destination.png")
	if tex == null:
		return
	for c in ship.crew:
		if not c.player_owned or not c.is_alive() or c.slot < 0:
			continue
		var sp := ship.graph.slot_position(c.target_room, c.slot)
		if absf(c.pos.x - sp.x) >= 0.5 or absf(c.pos.y - sp.y) >= 0.5:
			draw_texture(tex, sp - Vector2(17, 17))


## Room highlight (Room::Room primitives): yellow 5 px outline on the room rect + orange 1 px outline
## inset 5 px. No fill. Used for the move destination and for weapon targeting.
func draw_room_highlight(room_id: int) -> void:
	if room_id < 0:
		return
	var r := ship.room_rect(room_id)
	# Outline primitives grow inward from the rect edge; Godot strokes are centred on it, hence the half insets.
	draw_rect(r.grow(-2.5), Color8(255, 255, 0), false, 5)
	draw_rect(r.grow(-5.5), Color8(255, 188, 0), false, 1)


## Top-left corner of tile `tile` (row-major) of a room.
func _tile_origin(room_id: int, tile: int) -> Vector2:
	return ship.tile_center(room_id, tile) - Vector2(T, T) / 2


## Door animation state (Door::OnLoop / UpdateAnimations): progress toward open/closed at 5 frames per 0.2 s,
## red tint for 0.5 s after a hit (health dropped, or broken open).
func _update_doors(delta: float) -> void:
	var doors: Array = ship.env.doors
	for i in mini(doors.size(), _doors_anim.size()):
		var d: Dictionary = doors[i]
		var st: Dictionary = _doors_anim[i]
		var target := 1.0 if _door_shown_open(d) else 0.0
		st.p = move_toward(st.p, target, delta / DOOR_ANIM_TIME)
		# A health drop counts as a hit only when the base health is unchanged: a blast-level change (manning boost
		# lost, doors depowered) or a lockdown ending rescales the health without any attack.
		var same_base := int(d.base) == int(st.get("base", d.base))
		if (same_base and int(d.health) < int(st.hp)) or (float(d.forced) > 0.0 and float(st.forced) <= 0.0):
			st.hit = DOOR_HIT_TIME
		else:
			st.hit = maxf(float(st.hit) - delta, 0.0)
		st.hp = d.health
		st.base = d.base
		st.forced = d.forced


## Fires that went out since the last frame leave a one-shot fire_smoke (Fire::OnLoop); new fires get a random
## start in the largeFire loop.
func _update_fires(delta: float) -> void:
	var seen := {}
	for room_id in ship.fires:
		for tile in ship.fires[room_id]:
			var k := Vector2i(room_id, tile)
			seen[k] = true
			if not _fire_phase.has(k):
				_fire_phase[k] = randf() * FIRE_TIME
	for k in _fire_phase.keys():
		if not seen.has(k):
			if not ship.is_destroyed():
				_smokes.append({"room": k.x, "tile": k.y, "t": 0.0, "phase": _fire_phase[k]})
			_fire_phase.erase(k)
	for s in _smokes:
		s.t += delta
	_smokes = _smokes.filter(func(s): return s.t < SMOKE_TIME)


func _process(delta: float) -> void:
	var real_delta := delta
	delta = Combat.world_delta(delta)  # every animation here is game-world: frozen while paused
	_time += delta
	if shield_flash > 0.0:
		shield_flash = maxf(shield_flash - delta * 2.5, 0.0)
	# Weapons slide out when powered and back in when not (0.5 s). Keyed by weapon: a swapped weapon keeps
	# its slide state on its new mount.
	for w in ship.weapons + ship.artillery:
		if ship.is_destroyed():
			break  # the weapon art is frozen on its gib (the ship's loop no longer runs)
		var target := 1.0 if w.powered else 0.0
		weapon_slide[w] = move_toward(weapon_slide.get(w, 0.0), target, delta / WeaponArt.SLIDE_TIME)
	_track_health(delta)
	_update_healing(delta)
	# Ship::PauseLoop (WorldManager::PauseLoop -> player CompleteShip::PauseLoop): while paused the player ship's
	# doors still animate (Door::PauseLoop = UpdateAnimations on frame time), so a door toggled while paused opens /
	# closes on screen at once (rules/pause.md). Enemy ships get no PauseLoop: their doors hold their frame.
	_update_doors(real_delta if ship.is_player and Combat.world_paused else delta)
	_update_fires(delta)
	_update_firefight(delta)
	_update_extinguishers(delta)
	if jump_time >= 0.0 and not jump_driven:
		jump_time += delta
	bubble_layer.modulate.a = 1.0 - jump_progress(jump_time) if jump_time >= 0.0 else 1.0
	_update_shield_hits(delta * GameClock.BASE)
	_crew_sounds()
	queue_redraw()
	bubble_layer.queue_redraw()
	mask_layer.queue_redraw()
	hits_layer.queue_redraw()


# ------------------------------------------------- shield hits (Shields::CollisionReal / OnRenderShields)

const HIT_END_SIZE := 40.0  # half-width of the lit arc, degrees of the ellipse parameter
const HIT_DX := 10.0  # growth of current_size per factor (lifetime 40 / 10 = 4 factor = 0.25 s)
const HIT_END_THICKNESS := 75.0  # px: inward fade of the glow (grows 6 × dx per factor)


## A shot (or beam) hits the shield at `point`. The same `id` (a beam) refreshes its arc and keeps it alive.
func add_shield_hit(point: Vector2, id := -1) -> void:
	if id >= 0:
		for h in shield_hits:
			if h.id == id:
				h.loc = point
				h.size = HIT_END_SIZE - 2.0 * HIT_DX * 0.27
				return
	shield_hits.append({"loc": point, "size": 0.0, "thick": 0.0, "id": id})


func _update_shield_hits(f: float) -> void:
	for h in shield_hits:
		h.size += HIT_DX * f
		h.thick = minf(h.thick + HIT_DX * 6.0 * f, HIT_END_THICKNESS)
	shield_hits = shield_hits.filter(func(h): return h.size < HIT_END_SIZE)


## GL_DrawShield: a white band on the ellipse from (angle − 40°) to (angle + 40°); the outer edge alpha
## rises then falls (t², t = 0 → 1 → 0 along the arc), the inner edge (thickness px inside) is transparent.
func _draw_shield_hits() -> void:
	if ship == null or ship.is_destroyed() or ship.shield_layers <= 0 and shield_hits.is_empty():
		return
	var c := ship.shield_center
	var a := ship.shield_axes.x
	var ratio := ship.shield_axes.y / a
	for h in shield_hits:
		var d: Vector2 = h.loc - c
		var ang := rad_to_deg(acos(clampf(d.x / a, -1.0, 1.0)))
		if d.y < 0.0:
			ang = -ang
		var a1 := int(ang - HIT_END_SIZE)
		var a2 := int(ang + HIT_END_SIZE)
		var inner_a := maxf(a - float(h.thick), 0.0)
		var step := 2.0 / float(a2 - a1)
		var t := 0.0
		var prev_o := Vector2.ZERO
		var prev_i := Vector2.ZERO
		var prev_alpha := 0.0
		for deg in range(a1, a2):
			var r := deg_to_rad(float(deg))
			var o := c + Vector2(cos(r) * a, sin(r) * a * ratio)
			var r2 := r + 0.001
			var inn := c + Vector2(cos(r2) * inner_a, sin(r2) * ratio * inner_a)
			var alpha := t * t
			if deg > a1:
				# draw_primitive (a plain quad, no triangulation): while the glow is still thin the inner
				# edge collapses onto the centre and the quad is degenerate, which made draw_polygon's
				# triangulation fail ("triangulation failed" errors).
				hits_layer.draw_primitive(PackedVector2Array([prev_o, o, inn, prev_i]), PackedColorArray([
					Color(1, 1, 1, prev_alpha), Color(1, 1, 1, alpha), Color(1, 1, 1, 0), Color(1, 1, 1, 0)]),
					PackedVector2Array())
			prev_o = o
			prev_i = inn
			prev_alpha = alpha
			t += step
			if t >= 1.0:
				step = -step


## Floor colour for an oxygen level (Room::OnRenderFloor): step c = int((100 − O2) × 0.25),
## RGB = (230 + c, 226 − 2c, 219 − 2c) → #E6E2DB at 100 %, #FFB0A9 at 0 %.
static func floor_color(o2: float) -> Color:
	var c := int((100.0 - clampf(o2, 0.0, 100.0)) * 0.25)
	return Color8(230 + c, 226 - 2 * c, 219 - 2 * c)


## effects/low_o2_stripes_{1x2,2x1,2x2}.png at native size from the room's top-left corner,
## white at 50 % alpha (Room::Room picks the image by room size). Clipped to the room.
func _draw_o2_stripes(rect: Rect2, alpha: float) -> void:
	var tag := "2x2"
	if rect.size.x < 36:
		tag = "1x2"
	elif rect.size.y < 36:
		tag = "2x1"
	var tex := FtlData.texture("img/effects/low_o2_stripes_%s.png" % tag)
	if tex == null:
		return
	var size := Vector2(minf(tex.get_width(), rect.size.x), minf(tex.get_height(), rect.size.y))
	draw_texture_rect_region(tex, Rect2(rect.position, size), Rect2(Vector2.ZERO, size),
		Color(1, 1, 1, O2_STRIPES_ALPHA * alpha))




## ShipManager::OnRender order (rules/ship_rendering.md §1): bubble → weapons → hull → cloak image → floor image →
## thrusters → [interior gate] → room floors → O2 stripes → grid → interiors/consoles → breaches → fires →
## blackout → crew paths → room highlight → warning lights, walls, doors → system symbols → ion/hack sparks → crew.
## Cloak (rules/cloaking.md "Visuals"): hull `cloak_alpha` (0.75 → 0.375), cloak image `cloak_overlay_alpha`,
## and `cloak_interior_alpha` (1 → 0.5) on weapons, floor image, thrusters, room floors, O2 stripes, blackout,
## warning lights and doors. Bubble, grid, walls, interiors, fires, symbols and crew stay opaque, so the
## semi-transparent room floors (drawn after the cloak image) only let it show through faintly.
func _draw() -> void:
	_draw_ship()
	_draw_charge_bars()


## ShipManager::RenderChargeBars (CombatControl::RenderTarget, after the target ship is drawn): enemy weapon and
## artillery charge bars beside their art while the player's sensors provide them (effective power > 2) or the
## system is hacked (WeaponArt.draw_charge_bar). Not while the ship is jumping away or destroyed.
func _draw_charge_bars() -> void:
	if ship == null or ship.is_player or ship.opponent == null or ship.is_destroyed() or jump_time >= 0.0:
		return
	var wl := ship.crew_level_in("weapons")
	for w: WeaponState in ship.weapons + ship.artillery:
		if w.mount_index < ship.mounts.size() and WeaponArt.charge_bar_visible(ship, w):
			WeaponArt.draw_charge_bar(self, w, ship.mounts[w.mount_index], ship.mount_position(w.mount_index),
				weapon_slide.get(w, 1.0), w.ratio(0 if w.is_artillery else wl), WeaponArt.hack_level(ship, w))


func _draw_ship() -> void:
	if ship == null:
		return
	if ship.is_destroyed():
		_draw_explosion()  # ShipManager::OnRender: a dying ship draws only Ship::OnRenderExplosion
		return
	if jump_time >= 0.0:
		_draw_jump()  # ShipManager::OnRender while jumpAnimation runs: Ship::OnRenderJump only
		return
	var alpha := ship.cloak_interior_alpha()  # Ship::GetCloakAlpha(false)
	var mod := Color(1, 1, 1, alpha)
	var hull_pos := ship.hull_position()
	# Shield bubble: drawn by bubble_layer / mask_layer (z −1, under everything below).
	# Weapon art under the hull (ShipManager::RenderWeapons before Ship::OnRenderBase): the weapons, then every
	# artillery system's weapon (same WeaponAnimation: charge / charged / fire frames, glow) on its mount
	# (rules/artillery.md "Art"); artillery charges without a manning bonus.
	if not ship.is_destroyed():
		var wl := ship.crew_level_in("weapons")
		for w: WeaponState in ship.weapons + ship.artillery:
			if w.mount_index < ship.mounts.size():
				WeaponArt.draw(self, w, ship.mounts[w.mount_index], ship.mount_position(w.mount_index),
					weapon_slide.get(w, 1.0), 0 if w.is_artillery else wl, mod)
	# Hangar HIDE ROOMS (ShipManager::bShowRoom false, set from ShipBuilder::bShowRooms): RenderWeapons, then
	# Ship::OnRenderJump(0) — the hull at alpha 1, a zero-size glare and, on bShowEngines ships, the thrusters at
	# alpha 1 whatever the engines do. No floor image, rooms, interiors, doors, symbols or crew.
	drew_interior = false
	if hide_interior:
		_blk = {}
		if hull_tex:
			draw_texture(hull_tex, hull_pos)
		_draw_thrusters(1.0, true)
		return
	# Ship::OnRenderBase: hull, then the cloak image (while cloaked or fading out), then the player floor image.
	if hull_tex:
		draw_texture(hull_tex, hull_pos, Color(1, 1, 1, ship.cloak_alpha()))
	var ca := ship.cloak_overlay_alpha()
	if cloak_tex and ca > 0.0:
		draw_texture(cloak_tex, hull_pos + ship.layout.get("cloak_offset", Vector2.ZERO), Color(1, 1, 1, ca))
	if floor_tex:
		draw_texture(floor_tex, hull_pos + ship.layout.floor_offset, mod)
	_draw_thrusters(alpha)

	# Interior gate: a cloaked enemy (without player crew aboard) shows only bubble, weapons and hull.
	if not ship.shows_interior():
		_blk = {}
		return
	drew_interior = true
	_blk = {} if ship.is_destroyed() else ship.blacked_out_rooms()

	# Room floor (Room::OnRenderFloor): flat colour that shifts toward salmon as oxygen drops, then the low-O2
	# stripes at ≤ 5 % (Room::OnRenderO2Low); both skipped in blacked-out rooms. Then the grid (all rooms).
	# Both ships alike: a visible enemy room shows them too; no oxygen system -> lastO2 0 everywhere (room_o2).
	for r in ship.layout.rooms:
		if _blk.has(r.id):
			continue
		var rect := ship.room_rect(r.id)
		var o2: float = ship.env.room_o2(r.id)
		draw_rect(rect, floor_color(o2) * mod)
		if o2 <= O2_STRIPES_AT:
			_draw_o2_stripes(rect, alpha)
	if not _grid.is_empty():
		draw_multiline(_grid, GRID_COLOR, 1.0)

	if not ship.is_destroyed():
		_draw_interiors()
		_draw_breaches()
		_draw_fires()
		_draw_extinguishers()
	for room in _blk:
		draw_rect(ship.room_rect(room), BLACKOUT * mod)

	# Destination tiles of walking player crew, then the room highlight (both under the walls).
	if not ship.is_destroyed():
		_draw_destinations()
	for r in highlight_rooms:
		draw_room_highlight(r)

	if not ship.is_destroyed():
		_draw_warning_lights(alpha)
	if not _walls.is_empty():
		draw_multiline(_walls, WALL_COLOR, WALL_WIDTH)  # wallsPrimitive: no cloak alpha
	_draw_doors(mod)
	_draw_lockdown_shards(Color.WHITE)  # LockdownShard: alpha 1

	# System symbols in the rooms (no blackout check): tinted overlay silhouette (grey / orange / red / flashing
	# blue), plus a purple border while hacked (ShipSystem::OnRender)
	if not ship.is_destroyed():
		for s in ship.systems.values():
			var tex := FtlData.texture("img/icons/s_%s_overlay.png" % s.id)
			if tex == null:
				continue
			var pos := ship.room_rect(s.room).get_center() - tex.get_size() / 2
			_upright_at(ship.room_rect(s.room).get_center())
			draw_texture(tex, pos, s.room_symbol_tint(_time))
			# Purple border while a hacking effect is active (solid during a pulse, flashing while a drone
			# is attached).
			var he: int = s.hack_effect()
			if he >= 2 or (he == 1 and fmod(_time, 1.0) < 0.5):
				var border := FtlData.texture("img/icons/s_%s_overlay2.png" % s.id)
				if border:
					draw_texture(border, pos, FtlColors.PURPLE_HACK)
		_upright_end()

	if not ship.is_destroyed():
		_draw_sparks()
		_draw_crew()
		_draw_crew_shots()


## ExplosionAnimation::OnRender (rules/ship_destruction.md §3.3): gibs in reverse order (each with the weapons whose
## mount names it, under the gib), the intact hull until the final boom, then the small / boom explosions while
## the tracker is under 3 s. No floor, interior, crew or shield.
func _draw_explosion() -> void:
	var ex := ship.explosion
	var hull_pos := ship.hull_position()
	if ex != null:
		for gi in range(ex.gibs.size() - 1, -1, -1):
			if gi == ex.gibs.size() - 1 and ex.jump_out_progress() >= 0.0:
				continue  # flagship jump-out: the last gib is skipped once progress > 0.75
			var g: Dictionary = ex.gibs[gi]
			var tex: Texture2D = g.tex
			var c := tex.get_size() / 2 if tex else Vector2.ZERO
			var xf := Transform2D(0.0, hull_pos + g.pos) * Transform2D(0.0, c) 				* Transform2D(deg_to_rad(g.rot), Vector2.ZERO) * Transform2D(0.0, -c)
			for w in ship.weapons + ship.artillery:
				if w.mount_index >= ship.mounts.size():
					continue
				var m: Dictionary = ship.mounts[w.mount_index]
				if int(m.get("gib", -1)) == int(g.index):
					WeaponArt.draw(self, w, m, m.pos - g.start, weapon_slide.get(w, 1.0), 0, Color.WHITE, xf)
			if tex:
				draw_set_transform_matrix(xf)
				draw_texture(tex, Vector2.ZERO)
		draw_set_transform_matrix(Transform2D.IDENTITY)
	if hull_tex and (ex == null or not ex.final_boom):
		draw_texture(hull_tex, hull_pos)
	if ex != null and ex.jump_out_progress() >= 0.0 and hull_tex:
		# Ship::OnRenderExplosion -> OnRenderJump((progress - 0.75) x 4): hull at alpha 1 - p plus the jump glare.
		var jp := ex.jump_out_progress()
		draw_texture(hull_tex, hull_pos, Color(1, 1, 1, 1.0 - jp))
		var jg := jump_glare(jp, hull_tex.get_width(), hull_tex.get_height(), ship.is_player)
		var glare := FtlData.texture("img/effects/glowing_star.png")
		if glare and float(jg[2]) > 0.0:
			draw_texture_rect(glare, Rect2(hull_pos + Vector2(jg[0], jg[1]), Vector2(jg[2], jg[2])), false)
	if ex == null or ex.time >= ShipExplosion.ANIMS_UNTIL:
		return
	for e in ex.anims:
		var an: Dictionary = e.anim
		var frames: Array = an.get("frames", [])
		if frames.is_empty() or an.get("texture") == null:
			continue
		var i := clampi(int(e.t / maxf(float(an.time), 0.001) * frames.size()), 0, frames.size() - 1)
		var src: Rect2 = frames[i]
		draw_texture_rect_region(an.texture, Rect2(e.pos, src.size * float(e.scale)), src)


## Thrusters (Ship::OnRenderBase): player Kestrel / Federation cruiser only (Ship::bShowEngines, set in
## Ship::OnInit for kestral* / fed_cruiser*), while the engines give evasion; `always` (Ship::OnRenderJump: jump
## away, hangar HIDE ROOMS) skips the evasion check.
func _draw_thrusters(alpha := 1.0, always := false) -> void:
	if not ship.is_player or ship.is_destroyed() or (ship.dodge_factor() == 0 and not always):
		return
	var img: String = ship.blueprint.img
	for key in THRUSTERS:
		if not img.begins_with(key):
			continue
		var tex := FtlData.texture("img/effects/thrusters_on.png")
		if tex == null:
			return
		var fw := float(tex.get_width()) / THRUSTER_FRAMES
		var f := int((_time + _thruster_phase) / THRUSTER_TIME * THRUSTER_FRAMES) % THRUSTER_FRAMES
		for off in THRUSTERS[key]:
			draw_texture_rect_region(tex, Rect2(ship.hull_position() + off, Vector2(fw, tex.get_height())),
				Rect2(f * fw, 0, fw, tex.get_height()), Color(1, 1, 1, alpha))
		return


## Rotation (radians, clockwise on screen) of a console / glow facing a direction; UP = the image as drawn.
static func dir_angle(dir: String) -> float:
	match dir.to_upper():
		"DOWN":
			return PI
		"RIGHT":
			return PI / 2
		"LEFT":
			return -PI / 2
	return 0.0


## Draws `src` of `tex` so that its bounding box after rotation by `angle` (multiple of 90°) starts at `at`.
func _draw_rotated(tex: Texture2D, at: Vector2, src: Rect2, angle: float, col := Color.WHITE) -> void:
	var size := src.size
	var bb := size if is_zero_approx(fmod(absf(angle), PI)) else Vector2(size.y, size.x)
	draw_set_transform(at + bb / 2, angle)
	draw_texture_rect_region(tex, Rect2(-size / 2, size), src, col)
	draw_set_transform(Vector2.ZERO, 0.0)


## computerLevel: −1 not mannable, 0 unmanned / damaged, 1–3 manned (skill tier) with the system intact.
func _computer_level(s: SystemState) -> int:
	if not ShipState.BOOSTABLE.has(s.id):
		return -1
	return ship.crew_level_in(s.id)


## Step 6 (§4): per system whose room is seen — player interior image (α 0.75) + manned console glow,
## teleporter pads, clonebay tube, cloaking glow; enemy computer console + glow; hacked console sparks.
func _draw_interiors() -> void:
	for b in ship.blueprint.systems:
		if not b.start or not ship.systems.has(b.id):
			continue
		var s: SystemState = ship.systems[b.id]
		if _blk.has(s.room):
			continue
		var rect := ship.room_rect(s.room)
		match s.id:
			"teleporter":
				_draw_teleporter_pads(s, rect)
			"clonebay":
				_draw_clonebay(s)
			_:
				if ship.is_player:
					_draw_player_interior(s, b, rect)
		if not ship.is_player:
			_draw_enemy_console(s, b)
		if int(ship.room_hack.get(s.room, 0)) > 0:
			_draw_hacked_console(s, b)


## Interior image name of a player system (§4): the blueprint `img`, else the default `"room_" + name` that
## ShipSystem::ShipSystem (0x61bab0) sets for every system but the clonebay; ShipManager::AddSystem then calls the
## SetFloorImage wrapper (0x61ba70), which keeps the default when `img` is empty.
static func interior_image(id: String, b: Dictionary) -> String:
	var img: String = b.get("img", "")
	if img != "":
		return img
	return "" if id == "clonebay" else "room_" + id


func _draw_player_interior(s: SystemState, b: Dictionary, rect: Rect2) -> void:
	var img := interior_image(s.id, b)
	if img == "":
		return
	var tex := FtlData.texture("img/ship/interior/" + img + ".png")
	if tex:
		draw_texture(tex, rect.position, Color(1, 1, 1, INTERIOR_ALPHA))
	# Cloaking room: <img>_glow.png while cloaked, alpha from a 2.0 s looping tracker [triangle pulse inferred].
	if s.id == "cloaking" and ship.is_cloaked():
		var g := FtlData.texture("img/ship/interior/" + img + "_glow.png")
		if g:
			var t := fmod(_time, 2.0) / 2.0
			draw_texture(g, rect.position, Color(1, 1, 1, 2.0 * (0.5 - absf(t - 0.5))))
	var lvl := _computer_level(s)
	if lvl < 1:
		return
	var lay := FtlData.room_layout(img)
	if lay.is_empty():
		return
	var glow := FtlData.texture("img/ship/interior/%s%d.png" % [lay.name, mini(lvl, 3)])
	if glow:
		_draw_rotated(glow, rect.position + lay.pos, Rect2(Vector2.ZERO, glow.get_size()), dir_angle(lay.dir),
			Color(1, 1, 1, INTERIOR_ALPHA))


## What is drawn under the manning slot of a system's room (rules/ship_rendering.md §4), for checks and tests:
## {kind: "computer" (enemy computer1.png), "interior" (player <img> whose rooms.xml glow sits on a tile),
## "bare" (player interior image without a rooms.xml glow layout, e.g. room_doors / room_sensors: no lit console,
## the crew still man it), "" (no console slot), slot (console slot or the glow's tile), dir (lower-case facing)}.
func console_art(s: SystemState) -> Dictionary:
	var slot := ship.graph.console_slot(s.room)
	if slot < 0 or _computer_level(s) < 0:
		return {"kind": "", "slot": -1, "dir": ""}
	if not ship.is_player:
		return {"kind": "computer", "slot": slot, "dir": ship.graph.console_dir(s.room)}
	var img := interior_image(s.id, ship.system_by_id(s.id))
	var lay := FtlData.room_layout(img) if img != "" else {}
	var glow := FtlData.texture("img/ship/interior/%s1.png" % lay.name) if not lay.is_empty() else null
	if glow == null or FtlData.texture("img/ship/interior/" + img + ".png") == null:
		return {"kind": "bare", "slot": slot, "dir": ship.graph.console_dir(s.room)}
	return glow_tile(lay, glow.get_size(), ship.graph.room_size(s.room))


## Tile (slot) of a room holding the centre of a rooms.xml computerGlow (size `glow` before rotation; LEFT / RIGHT
## swap its sides) and the glow's facing: where the console of the interior image is drawn.
static func glow_tile(lay: Dictionary, glow: Vector2, room: Vector2i) -> Dictionary:
	var dir := String(lay.dir).to_lower()
	var sz := Vector2(glow.y, glow.x) if dir in ["left", "right"] else glow
	var c: Vector2 = lay.pos + sz / 2
	var t := Vector2i(clampi(int(c.x / T), 0, room.x - 1), clampi(int(c.y / T), 0, room.y - 1))
	return {"kind": "interior", "slot": t.x + t.y * room.x, "dir": dir}


## Console tile of a system's room (top-left) and its rotation (enemy console, hacked console sparks).
func _console_place(s: SystemState, b: Dictionary) -> Array:
	var slot := ship.graph.console_slot(s.room)
	if slot < 0:
		return []
	return [ship.graph.slot_position(s.room, slot) - Vector2(T, T) / 2, dir_angle(ship.graph.console_dir(s.room))]


## Room::OnRenderSystem (enemy only): computer1.png on the console slot + computer1_glow1/2 when manned.
func _draw_enemy_console(s: SystemState, b: Dictionary) -> void:
	var lvl := _computer_level(s)
	if lvl < 0:
		return
	var place := _console_place(s, b)
	if place.is_empty():
		return
	var tex := FtlData.texture("img/ship/interior/computer1.png")
	if tex:
		_draw_rotated(tex, place[0], Rect2(Vector2.ZERO, tex.get_size()), place[1])
	if lvl >= 1:
		var g := FtlData.texture("img/ship/interior/computer1_glow%d.png" % (1 if lvl == 1 else 2))
		if g:
			_draw_rotated(g, place[0], Rect2(Vector2.ZERO, g.get_size()), place[1])


## hacked_console (stun_computer.png, 7 frames 35×35, 1.0 s) on the console tile, same rotation.
func _draw_hacked_console(s: SystemState, b: Dictionary) -> void:
	var anim := FtlData.anim("hacked_console")
	var place := _console_place(s, b)
	if anim.is_empty() or place.is_empty():
		return
	_draw_rotated(anim.texture, place[0], _anim_frame(anim), place[1])


## TeleportSystem::OnRenderFloor: per tile a 24×24 pad at + (4, 5): off (not functioning), on (locked), selected
## (ready).
func _draw_teleporter_pads(s: SystemState, rect: Rect2) -> void:
	var n := "teleporter_off"
	if s.effective_power() > 0:
		n = "teleporter_on" if s.is_power_locked() else "teleporter_selected"
	var tex := FtlData.texture("img/ship/interior/%s.png" % n)
	if tex == null:
		return
	for y in int(rect.size.y / T):
		for x in int(rect.size.x / T):
			draw_texture(tex, rect.position + Vector2(x * T + 4, y * T + 5))


## CloneSystem::OnRenderFloor: clone_bottom then clone_top at the clonebay slot − (17, 17).
func _draw_clonebay(s: SystemState) -> void:
	var slot := maxi(ship.graph.blocked_slot(s.room), 0)
	var p := ship.graph.slot_position(s.room, slot) - Vector2(17, 17)
	for n in ["clone_bottom", "clone_top"]:
		var tex := FtlData.texture("img/ship/interior/%s.png" % n)
		if tex:
			draw_texture(tex, p)


## OuterHull::OnRender: breach.png frame int(7 × damage / 100) at tile top-left + (7, 7) — the hole shrinks as
## crew repair it. Skipped in blacked-out rooms.
func _draw_breaches() -> void:
	_draw_breaches_impl()


## OuterHull::OnRender: SetCurrentFrame(int(7 × fDamage / 100)) on a started, never-updated animation — the
## frame follows the repair state only (full hole at 100, shrinking to 0); it never loops or plays by itself.
static func breach_frame(health: float) -> int:
	return clampi(int(BREACH_FRAMES * health / ShipState.REPAIRABLE_HEALTH), 0, BREACH_FRAMES - 1)


func _draw_breaches_impl() -> void:
	var anim := FtlData.anim("breach")
	if anim.is_empty():
		return
	var slug_gel := AugmentRule.has(ship, "SLUG_GEL")
	var htex: Texture2D = FtlData.texture("img/people/healing_strip11.png") if slug_gel else null
	for room_id in ship.breaches:
		if _blk.has(room_id):
			continue
		for tile in ship.breaches[room_id]:
			var h: float = ship.breaches[room_id][tile].health
			var f := breach_frame(h)
			var src := _anim_frame(anim, f)
			_upright_at(ship.tile_center(room_id, tile))
			draw_texture_rect_region(anim.texture, Rect2(_tile_origin(room_id, tile) + BREACH_OFFSET, src.size), src)
			if slug_gel and htex:  # SLUG_GEL: the heal anim on top, purple, at breach position + (-7, -7)
				var hf := int(_time * HEAL_FRAMES / HEAL_TIME) % HEAL_FRAMES
				draw_texture_rect_region(htex, Rect2(_tile_origin(room_id, tile), Vector2(32, 32)),
					Rect2(hf * 32, 0, 32, 32), SLUG_GEL_TINT)
			_upright_end()


## Fire::OnRender: largeFire.png (8 frames 32×32, 1.0 s loop, random start) at the tile's top-left; a fire that
## went out plays fire_smoke.png (7 frames 34×34, 1.0 s once) there, with the fire at α 0.5 under smoke frame 0.
func _draw_fires() -> void:
	var tex := FtlData.texture("img/effects/largeFire.png")
	if tex:
		for room_id in ship.fires:
			if _blk.has(room_id):
				continue
			for tile in ship.fires[room_id]:
				_draw_fire_frame(tex, room_id, tile, float(_fire_phase.get(Vector2i(room_id, tile), 0.0)), 1.0)
	var smoke := FtlData.texture("img/effects/fire_smoke.png")
	for s in _smokes:
		if _blk.has(s.room):
			continue
		var f := mini(int(s.t / SMOKE_TIME * SMOKE_FRAMES), SMOKE_FRAMES - 1)
		if f == 0 and tex:
			_draw_fire_frame(tex, s.room, s.tile, s.phase, 0.5)
		if smoke:
			var fw := float(smoke.get_width()) / SMOKE_FRAMES
			_upright_at(ship.tile_center(s.room, s.tile))
			draw_texture_rect_region(smoke, Rect2(_tile_origin(s.room, s.tile), Vector2(fw, smoke.get_height())),
				Rect2(f * fw, 0, fw, smoke.get_height()))
			_upright_end()


## FIRE_EXTINGUISHERS (ShipManager::OnRender): one firefight_cloud emitter per room on fire, at the room centre.
func _draw_extinguishers() -> void:
	var tex := FtlData.texture("img/people/firefight_cloud.png")
	if tex == null:
		return
	var half := tex.get_size() / 2
	for room_id in _ext_emitters:
		if _blk.has(room_id):
			continue
		var c := ship.room_rect(room_id).get_center()
		for pt in _ext_emitters[room_id].parts:
			draw_texture(tex, c + (pt.p as Vector2) - half, Color(1, 1, 1, clampf(4.0 * float(pt.life), 0.0, 1.0)))


## ParticleEmitter::OnUpdate of the extinguisher emitters (birthRate 3, random angle; same units as the crew's).
func _update_extinguishers(delta: float) -> void:
	var sf := delta * GameClock.BASE
	var on := AugmentRule.has(ship, "FIRE_EXTINGUISHERS")
	for room_id in ship.fires.keys():
		if on and not _ext_emitters.has(room_id) and not ship.fires[room_id].is_empty():
			_ext_emitters[room_id] = {"parts": [], "counter": 0.01}
	for room_id in _ext_emitters.keys():
		var e: Dictionary = _ext_emitters[room_id]
		var parts: Array = e.parts
		for i in range(parts.size() - 1, -1, -1):
			var pt: Dictionary = parts[i]
			pt.p += pt.v * sf
			pt.life -= sf * 0.0625
			if pt.life < 0.0:
				parts.remove_at(i)
		if on and not ship.fires.get(room_id, {}).is_empty():
			e.counter -= sf
			if e.counter <= 0.0:
				e.counter = SMOKE_BIRTH
				if parts.size() < SMOKE_MAX:
					var ang := deg_to_rad(float(randi() % 360))
					parts.append({"p": Vector2.ZERO, "v": Vector2(cos(ang), sin(ang)) * SMOKE_SPEED, "life": SMOKE_LIFE})
		elif parts.is_empty():
			_ext_emitters.erase(room_id)


func _draw_fire_frame(tex: Texture2D, room_id: int, tile: int, phase: float, a: float) -> void:
	var fw := float(tex.get_width()) / FIRE_FRAMES
	var f := int((_time + phase) / FIRE_TIME * FIRE_FRAMES) % FIRE_FRAMES
	_upright_at(ship.tile_center(room_id, tile))
	draw_texture_rect_region(tex, Rect2(_tile_origin(room_id, tile), Vector2(fw, tex.get_height())),
		Rect2(f * fw, 0, fw, tex.get_height()), Color(1, 1, 1, a))
	_upright_end()


## Room::OnRenderWalls warning light: light_base.png, then light_glow.png with a 1.0 s triangle pulse, at
## x + (w < 70 ? −17 : 0), y + (h > 69 ? 33 : −2), on every room of `warning_light_rooms`.
func _draw_warning_lights(alpha := 1.0) -> void:
	var base := FtlData.texture("img/effects/light_base.png")
	var glow := FtlData.texture("img/effects/light_glow.png")
	var t := fmod(_time, 1.0)
	for room_id in warning_light_rooms(ship):
		if _blk.has(room_id):
			continue
		var r := ship.room_rect(room_id)
		var p := r.position + Vector2(-17 if r.size.x < 70 else 0, 33 if r.size.y > 69 else -2)
		if base:
			draw_texture(base, p, Color(1, 1, 1, alpha))
		if glow:
			draw_texture(glow, p, Color(1, 1, 1, 2.0 * (0.5 - absf(t - 0.5)) * alpha))


## bWarningLight, as left by ShipManager::OnLoop (rules/ship_rendering.md §3): set by UpdateEnvironment for a room
## with a fire or a hull breach, only on ships with an oxygen system. Damaged systems do not count (their set is
## cleared later in the same loop); open airlocks and lanius drain do not count either.
static func warning_light_rooms(s: ShipState) -> Array:
	var rooms := []
	if s.sys("oxygen") == null:
		return rooms
	for d in [s.fires, s.breaches]:
		for room_id in d:
			if not (d[room_id] as Dictionary).is_empty() and not rooms.has(room_id):
				rooms.append(room_id)
	return rooms


## Door::OnRender: door_sheet.png cell (35×35 at wall − 17; horizontal doors rotated 90°), frame by the
## open/close animation (3 while broken open), row by doors-system effective power (purple when hacked),
## tint (1, .6, .6) at level 0 and red for 0.5 s after a hit; door_highlight.png at α 0.75 under the hovered door.
func _draw_doors(mod: Color) -> void:
	var sheet := FtlData.texture("img/effects/door_sheet.png")
	var hl := FtlData.texture("img/effects/door_highlight.png")
	var level := ship.env.door_level()
	var doors: Array = ship.env.doors
	for i in mini(doors.size(), _doors_anim.size()):
		var d: Dictionary = doors[i]
		var st: Dictionary = _doors_anim[i]
		var at: Vector2 = ship.origin + Vector2(d.x, d.y) * T
		var angle := 0.0
		if d.vertical:
			at += Vector2(-17, 0)
		else:
			at += Vector2(T, -17)
			angle = PI / 2
		var frame := DOOR_FORCED_FRAME if float(d.forced) > 0.0 \
			else mini(int(float(st.p) * DOOR_FRAMES), DOOR_FRAMES - 1)
		var hacked := int(d.get("hacked", 0)) > 0
		var row := DOOR_HACKED_ROW if hacked else clampi(level - 1, 0, 3) * T
		var col := Color.WHITE
		if float(st.hit) > 0.0:
			col = DOOR_HIT_TINT
		elif level <= 0 and not hacked:
			col = DOOR_UNPOWERED_TINT
		draw_set_transform(at, angle)
		if hl and ship.is_player and i == hovered_door:
			draw_texture(hl, Vector2.ZERO, Color(1, 1, 1, DOOR_HIGHLIGHT_ALPHA))  # fixed 0.75
		if sheet:
			draw_texture_rect_region(sheet, Rect2(0, 0, T, T), Rect2(frame * T, row, T, T), col * mod)
		else:
			draw_rect(Rect2(14, 7, 6, 21), Color8(255, 150, 48) * mod)
		draw_set_transform(Vector2.ZERO, 0.0)


## LockdownShard::OnRender (with the walls / doors layer): crystal_1 / crystal_2 frame at position − (9, 14), white.
func _draw_lockdown_shards(mod: Color) -> void:
	for s in ship.lockdowns:
		var a := FtlData.anim(String(s.anim))
		if a.is_empty():
			continue
		var frames: Array = a.frames
		var src: Rect2 = frames[LockdownRule.shard_frame(s, frames.size())]
		draw_texture_rect_region(a.texture, Rect2(s.pos - LockdownRule.SHARD_OFFSET, src.size), src, mod)


## Room::OnRenderSparks: stun_spark_big (stun_floor.png, 10 frames 70×70, 1.0 s) over a room while its system is
## ionized (bStunning [inferred]) or under a hack pulse (fHacked). Each cycle picks a random orientation:
## 2-wide rooms a rotation about the room centre (0/90/180/270°; 0/180° when 1 tile high) and a horizontal mirror;
## 1-wide rooms a random 35 px column (MaskX), rotated −90° when the room is 1 tile high.
func _draw_sparks() -> void:
	var anim := FtlData.anim("stun_spark_big")
	if anim.is_empty():
		return
	var active := {}
	for room in ship.room_hack:
		if int(ship.room_hack[room]) >= 2:
			active[room] = true
	for s in ship.systems.values():
		if s.is_ionized() and s.ion_stunned:
			active[s.room] = true
	for room in _sparks.keys():
		if not active.has(room):
			_sparks.erase(room)
	for room in active:
		var r := ship.room_rect(room)
		if not _sparks.has(room):
			_sparks[room] = {"start": _time, "cycle": -1}
		var sp: Dictionary = _sparks[room]
		var el: float = _time - float(sp.start)
		var cycle := int(el / maxf(float(anim.time), 0.01))
		if cycle != int(sp.cycle):
			sp.cycle = cycle
			sp.rot = randi() % 4
			sp.mirror = randi() % 2 == 1
			sp.mask = randi() % 2
		var frames: Array = anim.frames
		var src: Rect2 = frames[mini(int(fmod(el, anim.time) / anim.time * frames.size()), frames.size() - 1)]
		var w := r.size.x
		var h := r.size.y
		var c := r.get_center()
		if w == 2 * T and h <= 2 * T:
			var reg := src if h == 2 * T else Rect2(src.position, Vector2(src.size.x, T))
			var angle: float = int(sp.rot) * PI / 2 if h == 2 * T else (PI if int(sp.rot) % 2 == 1 else 0.0)
			draw_set_transform(c, angle, Vector2(-1 if sp.mirror else 1, 1))
			draw_texture_rect_region(anim.texture, Rect2(-reg.size / 2, reg.size), reg)
		elif w == T and h <= 2 * T:
			var reg := Rect2(src.position + Vector2(int(sp.mask) * T, 0), Vector2(T, h))
			draw_set_transform(c, -PI / 2 if h == T else 0.0)
			draw_texture_rect_region(anim.texture, Rect2(-reg.size / 2, reg.size), reg)
		else:
			# Larger rooms (not covered by the rule): the 70×70 frame tiled over the room.
			var y := r.position.y
			while y < r.end.y - 1:
				var x := r.position.x
				while x < r.end.x - 1:
					var sz := Vector2(minf(src.size.x, r.end.x - x), minf(src.size.y, r.end.y - y))
					draw_texture_rect_region(anim.texture, Rect2(Vector2(x, y), sz), Rect2(src.position, sz))
					x += src.size.x
				y += src.size.y
		draw_set_transform(Vector2.ZERO, 0.0)


## Shields::OnRenderBaseShield (rules/weapon_visuals.md "Shields" and "Shield bubble animations"): the normal
## bubble (RenderBase) on `bubble_layer`, then on the player ship the layer-pop ghost or the super-shield wave on
## `mask_layer` (a circle mask shader replaces FTL's stencil). Both layers sit under the hull (z −1).
func _draw_shield_bubble() -> void:
	if shield_tex == null or ship == null or ship.is_destroyed():
		return
	_render_base(bubble_layer, ship.shield_layers, ship.max_shield_layers(), ship.super_shield, 1.0)


## OnRenderBaseShield, player ship only: the layer-pop ghost or the super-shield wave (mask_layer).
func _draw_shield_mask() -> void:
	if shield_tex == null or ship == null or ship.is_destroyed() or not ship.is_player:
		return
	var mat := mask_layer.material as ShaderMaterial
	if ship.super_up_t >= 0.0:
		# superShieldUp: inside a circle of radius 1000 × p at the drone, only the green bubble again (normal
		# layers forced to 0), alpha × 1 until p = 0.5, then fading to 0 at p = 1.
		var p := ship.super_up_t / ShipState.SUPER_UP_TIME
		mat.set_shader_parameter("center", ship.super_up_loc)
		mat.set_shader_parameter("radius", MASK_RADIUS * p)
		mat.set_shader_parameter("inside", true)
		var fade := 1.0 if p <= 0.5 else 1.0 - 2.0 * (p - 0.5)
		_render_base(mask_layer, 0, 0, ship.super_shield, fade)
	elif ship.shield_down_t >= 0.0:
		# shieldsDown: a ghost of the popped layer (1 of 1 white, or 1 of 5 super green) drawn outside a circle of
		# radius 1000 × p growing from the hit point.
		var p := ship.shield_down_t / ShipState.SHIELD_DOWN_TIME
		mat.set_shader_parameter("center", ship.shield_down_point)
		mat.set_shader_parameter("radius", MASK_RADIUS * p)
		mat.set_shader_parameter("inside", false)
		if ship.shield_down_super:
			_render_base(mask_layer, 0, 0, 1, 1.0, 5)
		else:
			_render_base(mask_layer, 1, 1, 0, 1.0)


const MASK_RADIUS := 1000.0  # GL_CreateCirclePrimitive(0, 0, 1000), scaled by the tracker progress
const MASK_SHADER := """
shader_type canvas_item;
uniform vec2 center;
uniform float radius;
uniform bool inside;
varying vec2 local_pos;
void vertex() { local_pos = VERTEX; }
void fragment() {
	if ((distance(local_pos, center) < radius) != inside) { discard; }
}
"""


## Rectangle of the bubble image (white layers and the green super shield alike), local ship coordinates
## (Shields::RenderBase 0x0060c100, centre = Ship::GetBaseEllipse 0x00480be0): player (iShipId 0) = the image at its
## own pixel size about the ellipse centre; enemy = the image scaled to 2a × 2b about the centre.
static func bubble_rect(s: ShipState, tex_size: Vector2) -> Rect2:
	if s.is_player:
		return Rect2(s.shield_center - (tex_size / 2).floor(), tex_size)
	return Rect2(s.shield_center - s.shield_axes, s.shield_axes * 2)


## Shields::RenderBase(alpha) with the given layer counts: the white bubble, alpha = layers / (3.5 player,
## 4 enemy) × 0.6 + 0.4 (nothing at 0 layers or max 0), scaled by the shieldsUp progress; then the super shield
## (§9) tinted COLOR_GREEN, alpha n / max(5, superMax), × 0.6 + 0.4 when the normal shield has no layer (unscaled).
## Player: `<shieldImage>_shields1.png` at its own pixel size centred on the ellipse (scale 1); enemy: enemy_shields.png
## stretched to 2a × 2b. Normal alpha blend, no additive pass.
func _render_base(ci: CanvasItem, layers: int, max_layers: int, super_n: int, alpha: float, super_max := -1) -> void:
	var rect := bubble_rect(ship, shield_tex.get_size())
	var a := 0.0
	if layers > 0 and max_layers > 0:
		a = float(layers) / (3.5 if ship.is_player else 4.0) * 0.6 + 0.4
	if ci == bubble_layer:
		a = maxf(a, shield_flash)
	if a > 0.0:
		var s := ship.shield_up_scale()
		if s > 0.0:
			ci.draw_texture_rect(shield_tex, _scaled_bubble(rect, s), false, Color(1, 1, 1, minf(a * alpha, 1.0)))
	if super_n > 0:
		var sa := float(super_n) / maxf(5.0, float(ship.super_shield_max if super_max < 0 else super_max))
		if layers <= 0:
			sa = sa * 0.6 + 0.4
		ci.draw_texture_rect(shield_tex, rect, false, Color(SUPER_SHIELD_COLOR, minf(sa * alpha, 1.0)))


## The shieldsUp scale s applied about the texture point (w/2, h/2) of the drawn size: the bubble centre for the
## player (texture drawn at its size), but for the enemy (enemy_shields.png stretched to 2a × 2b first) the pivot is
## top-left + (2a² / texW, 2b² / texH) — FTL's off-centre growth point.
func _scaled_bubble(rect: Rect2, s: float) -> Rect2:
	if s >= 1.0:
		return rect
	var pivot := rect.get_center()
	if not ship.is_player:
		pivot = rect.position + Vector2(rect.size.x * rect.size.x / 2.0 / shield_tex.get_width(),
			rect.size.y * rect.size.y / 2.0 / shield_tex.get_height())
	return Rect2(pivot + (rect.position - pivot) * s, rect.size * s)
