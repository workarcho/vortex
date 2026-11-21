class_name Space
extends SubViewportContainer
## An FTL "space": a ship with its own coordinate system, camera and HUD.
## The UI decides how to lay out the spaces (side by side, one at a time, etc.).

signal room_clicked(room: int, button: int, shift: bool)
signal mouse_released(button: int, shift: bool)  # beam aiming by drag

var ship: ShipState
var viewport: SubViewport
var overlay: Node2D  # crosshairs and highlight (above the ship)
var hovered_room := -1
var highlight_hover := false  # enabled by the UI when a weapon is armed
var move_highlight_room := -1  # crew move destination under the pointer (CrewControl.move_highlight)
var aim_marks: Array = []  # [{room, label, beam: [p1, p2] (beams only)}] weapons aiming at this ship
var beam_preview: Array = []  # [start] or [start, end]: beam being aimed (player UI)
var beam_preview_color := Color8(227, 39, 39)
var hover_radius := 0  # armed flak: radius disc drawn under the pointer
var beam_preview_auto := false  # the beam being aimed will autofire (yellow line)
var mouse_world := Vector2.ZERO  # pointer in this space's coordinates (last motion / click)
var show_power := false  # player sensors ≥ 3: this ship's power is visible
var world: Node2D  # the ship and the projectiles currently in this space live here
var view: ShipView
var cam: Camera2D
var hud: Control
var _texts: Array = []  # [{text, pos, color, t}]
var _messages: Array = []  # DamageMessage: [{text (digits or "MISS"), pos (world), color, t}]
var _anims: Array = []  # one-shot animations [{anim, pos (world), t}] (show_anim)
var drone_layer: Node2D  # space drones flying in this space (both sides; rules/drones.md)
var _tp_anims := {}  # race -> <race>_teleport animation


func setup(state: ShipState) -> void:
	ship = state
	stretch = true
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	viewport = SubViewport.new()
	viewport.transparent_bg = true
	viewport.handle_input_locally = false
	# Pixel art: a SubViewport does NOT inherit the project's nearest texture filter (it defaults to linear),
	# which blurred every sprite drawn in the ship views (crosshairs, crew, ships). Force nearest.
	viewport.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	add_child(viewport)
	# Mix blending into a transparent viewport leaves premultiplied colour in it; compositing that with normal
	# alpha multiplied by alpha twice (a 0.27-alpha shield edge came out ~4× too dark, the bubble a grey film).
	var comp := CanvasItemMaterial.new()
	comp.blend_mode = CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA
	material = comp

	world = Node2D.new()
	viewport.add_child(world)
	view = ShipView.new()
	world.add_child(view)
	view.setup(ship)

	drone_layer = Node2D.new()
	drone_layer.z_index = 4  # above the ship, under incoming shots (z 5)
	drone_layer.draw.connect(_draw_drones)
	world.add_child(drone_layer)

	overlay = Node2D.new()
	overlay.z_index = 10
	overlay.draw.connect(_draw_overlay)
	world.add_child(overlay)

	cam = Camera2D.new()
	world.add_child(cam)
	cam.position = ship.shield_center
	cam.make_current()

	hud = Control.new()
	hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.draw.connect(_draw_hud)
	var layer := CanvasLayer.new()
	viewport.add_child(layer)
	layer.add_child(hud)
	resized.connect(_fit_camera)
	viewport.size_changed.connect(_fit_camera)


## FTL layout (rules/hud_layout.md): world (0, 0) is drawn at this point of the container, zoom 1.
## null = fit the ship into the container (debug "one at a time" view).
var fixed_origin: Variant = null
## Zoom of the fixed FTL view (1 on PC; the touch UI enlarges the enemy TARGET window, main.gd
## `touch_enemy_transform`). World (0, 0) still lands on `fixed_origin`.
var fixed_zoom := 1.0
## Camera rotation of the fixed view (radians; 0 everywhere but the open-Fold "split" touch layout, which turns the
## player ship to face up with PI / 2: main.gd `_touch_layout_split`). World (0, 0) still lands on `fixed_origin`.
var fixed_rotation := 0.0
## Debug view: the old per-space text HUD (name, hull pips, shields, enemy power) instead of the FTL HUD.
var legacy_hud := false


## Stencil of the view (CombatControl::DrawHostileBox 0x0055e190 + RenderTarget 0x0055ff00: the frame is drawn,
## then `box_hostiles_mask.png` at the box position sets stencil bit 0x20, and the whole enemy ship — shield bubble
## and super shield, hull, rooms, projectiles (CompleteShip::OnRenderShip) — is drawn with STENCIL_USE 0x20). The
## container composites its SubViewport only where the mask is opaque. `mask_rect` = the container's rectangle in
## mask pixels (PC frame units; the container may be scaled, e.g. the touch TARGET window). null = no mask.
const CLIP_SHADER := """
shader_type canvas_item;
render_mode blend_premul_alpha;
uniform sampler2D clip_mask : filter_nearest;
uniform vec4 mask_rect;
void fragment() {
	vec2 mp = mask_rect.xy + UV * mask_rect.zw;
	vec2 ms = vec2(textureSize(clip_mask, 0));
	bool inside = all(greaterThanEqual(mp, vec2(0.0))) && all(lessThan(mp, ms));
	COLOR *= inside ? step(0.5, texture(clip_mask, mp / ms).a) : 0.0;
}
"""
var clip_mask: Texture2D = null


func set_clip_mask(mask: Texture2D, mask_rect := Rect2()) -> void:
	clip_mask = mask
	if mask == null:
		var comp := CanvasItemMaterial.new()
		comp.blend_mode = CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA  # same compositing as setup()
		material = comp
		return
	var mat := material as ShaderMaterial
	if mat == null:
		var sh := Shader.new()
		sh.code = CLIP_SHADER
		mat = ShaderMaterial.new()
		mat.shader = sh
		material = mat
	mat.set_shader_parameter("clip_mask", mask)
	mat.set_shader_parameter("mask_rect", Vector4(mask_rect.position.x, mask_rect.position.y,
		mask_rect.size.x, mask_rect.size.y))


## Places the view: fixed FTL origin (zoom 1) or, in the debug view, fit the ship.
func set_fixed_origin(o: Variant, zoom := 1.0) -> void:
	fixed_origin = o
	fixed_zoom = zoom
	_fit_camera()


## Zoom so the shield, the hull image and the rooms all fit in the available space (some enemy hulls,
## e.g. MANTIS_FIGHTER, stick out of their shield ellipse).
func _fit_camera() -> void:
	if size.x <= 0 or size.y <= 0:
		return
	if fixed_origin != null:
		# The camera centres the SubViewport, whose size can lag behind the container's for a frame after a
		# resize (stretch): use the viewport's own size, and refit when it changes (viewport.size_changed).
		# Using the container size here drew the touch player ship (h − 720) / 2 too low on the open Fold.
		var vs := Vector2(viewport.size) if viewport != null and viewport.size.y > 0 else size
		cam.zoom = Vector2(fixed_zoom, fixed_zoom)
		cam.ignore_rotation = fixed_rotation == 0.0
		cam.rotation = fixed_rotation
		view.upright = fixed_rotation  # symbols / crew / fires drawn upright on screen
		cam.position = (vs / 2 - (fixed_origin as Vector2)).rotated(fixed_rotation) / fixed_zoom
		return
	cam.ignore_rotation = true  # the fitted debug view is never turned
	view.upright = 0.0
	var bounds := Rect2(ship.shield_center - ship.shield_axes, ship.shield_axes * 2)
	var img: Rect2 = ship.layout.img_rect
	if img.size.x > 0 and img.size.y > 0:
		bounds = bounds.merge(Rect2(ship.hull_position(), img.size))
	bounds = bounds.merge(ship.rooms_bounds())
	cam.position = bounds.get_center()
	var need := bounds.size + Vector2(80, 140)
	var z := minf(size.x / need.x, size.y / need.y)
	cam.zoom = Vector2(z, z)


## Screen (local to the container) -> world coordinates of this space.
func to_world(local_pos: Vector2) -> Vector2:
	return viewport.get_canvas_transform().affine_inverse() * local_pos


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		mouse_world = to_world(event.position)
		var r := ship.room_at(mouse_world)
		if r != hovered_room:
			hovered_room = r
	elif event is InputEventMouseButton and not event.pressed:
		mouse_world = to_world(event.position)
		mouse_released.emit(event.button_index, event.shift_pressed)
	elif event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		mouse_world = to_world(mb.position)
		# Crew selection, move orders and doors are handled by CrewControl (main.gd _input); here only
		# targeting (CombatControl::SelectTarget on press) and disarming.
		if mb.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			room_clicked.emit(ship.room_at(to_world(mb.position)), mb.button_index, mb.shift_pressed)
			accept_event()


## Rooms outlined this frame (Ship::HighlightRoom / Room::OnRenderHighlight, drawn by the ShipView under
## the walls): the crew move destination, the hovered room while a weapon is armed (not while a beam's
## first point is placed: CombatControl::RenderTarget clears it) and the rooms a beam being aimed crosses.
func highlighted_rooms() -> Array:
	var out := []
	if move_highlight_room >= 0:
		out.append(move_highlight_room)
	if highlight_hover and hovered_room >= 0 and beam_preview.is_empty() and not out.has(hovered_room):
		out.append(hovered_room)
	if not beam_preview.is_empty():
		var p0: Vector2 = beam_preview[0]
		var rooms: Array = beam_rooms(ship, p0, beam_preview[1]) if beam_preview.size() > 1 else [ship.room_at(p0)]
		for r in rooms:
			if r >= 0 and not out.has(r):
				out.append(r)
	return out


## Rooms a beam aimed from `a` to `b` will cross, in order (CombatControl::RenderTarget): walk the line in
## 1 px steps (the last step lands exactly on `b`) and collect each new room entered.
static func beam_rooms(target: ShipState, a: Vector2, b: Vector2) -> Array[int]:
	var out: Array[int] = []
	var dir := (b - a).normalized()
	var p := a
	var last := -1
	while p.distance_to(b) > 0.001:
		p = p + dir if p.distance_to(b) > 1.0 else b
		var r := target.room_at(p)
		if r != last and r != -1 and not out.has(r):
			out.append(r)
		last = r
	return out


func _draw_overlay() -> void:
	var font := ThemeDB.fallback_font
	# Room outlines are drawn by the ShipView (highlighted_rooms); flak radius disc under the pointer.
	if highlight_hover and hovered_room >= 0 and beam_preview.is_empty() and hover_radius > 0:
		overlay.draw_circle(mouse_world, float(hover_radius), Color(1, 0, 0, 0.5))
	# Beam being aimed (CombatControl::RenderTarget -> WeaponControl::RenderBeamAiming): every room the line
	# crosses is highlighted, then the aim line from the first point to the pointer (fixed length), red, or
	# yellow when it will autofire.
	if not beam_preview.is_empty():
		var p0: Vector2 = beam_preview[0]
		var p1: Vector2 = beam_preview[1] if beam_preview.size() > 1 else mouse_world
		draw_beam_aim(overlay, p0, p1, beam_preview_auto)
	# Weapons aiming at this ship (WeaponControl::RenderAiming): beams = their aim line; other weapons =
	# crosshairs_placedN(_yellow).png centred on the aiming point (-26, -26), yellow with autofire; flak
	# adds a translucent red disc of its radius.
	for m in aim_marks:
		if m.has("beam"):
			var b: Array = m.beam
			draw_beam_aim(overlay, b[1], b[0], m.get("auto", false))
			continue
		var p: Vector2 = m.get("point", ship.room_rect(m.room).get_center())
		if int(m.get("radius", 0)) > 0:
			overlay.draw_circle(p, float(m.radius), Color(1, 0, 0, 0.25))
		var tex := crosshair_texture(int(m.get("slot", 0)), m.get("auto", false))
		if tex:
			overlay.draw_texture(tex, p + Vector2(-26, -26))
		else:
			overlay.draw_arc(p, 14, 0, TAU, 24, FtlColors.RED, 3)
			overlay.draw_string(font, p + Vector2(-5, 6), m.label, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, FtlColors.RED)
	_draw_teleports()
	for a in _anims:
		overlay.draw_set_transform(a.pos)
		Projectile.draw_anim_frame(overlay, a.anim, a.t / maxf(float(a.anim.get("time", 0.75)), 0.05))
	overlay.draw_set_transform(Vector2.ZERO)
	_draw_messages()


## Space drones whose current space is this ship's (own defence drones, enemy combat drones, pods).
func _draw_drones() -> void:
	for s in [ship, ship.opponent]:
		if s == null:
			continue
		for d in s.drones:
			if d.is_space() and d.deployed and d.space_ship == ship:
				DroneArt.draw(drone_layer, d)
		var hd: Drone = s.hack_drone
		if hd != null and hd.deployed and hd.space_ship == ship:
			DroneArt.draw(drone_layer, hd)
		for sd in FlagshipRule.deployed_super_drones(s):  # flagship drone surge
			if sd.space_ship == ship:
				DroneArt.draw(drone_layer, sd)


## Crew in a teleport animation (rules/teleporter.md): the race's <race>_teleport strip (0.5 s) forward
## while dematerialising, reversed while materialising, over a pale beam glow.
func _draw_teleports() -> void:
	for c in ship.teleporting:
		var e: Dictionary = ship.teleporting[c]
		var p := clampf(float(e.t) / TeleporterRule.ANIM_TIME, 0.0, 1.0)
		if int(e.phase) == 1:
			p = 1.0 - p
		var glow := Color(0.6, 1.0, 0.7, 0.55 * p + 0.15)
		_upright(c.pos)
		overlay.draw_rect(Rect2(c.pos - Vector2(12, 17), Vector2(24, 34)), Color(glow, glow.a * 0.5))
		if not _tp_anims.has(c.race):
			_tp_anims[c.race] = FtlData.anim(("human" if c.race == "ghost" else c.race) + "_teleport")
		var an: Dictionary = _tp_anims[c.race]
		if an.is_empty():
			continue
		var n: int = an.frames.size()
		var src: Rect2 = an.frames[clampi(int(p * n), 0, n - 1)]
		overlay.draw_texture_rect_region(an.texture, Rect2(c.pos - src.size / 2, src.size), src)
	_upright(Vector2.INF)


## Overlay draws turned by the view's rotation about world point `c` so they read upright on screen (rotated
## fixed view only: ShipView.upright); Vector2.INF resets the transform.
func _upright(c: Vector2) -> void:
	if fixed_rotation == 0.0:
		return
	if c == Vector2.INF:
		overlay.draw_set_transform_matrix(Transform2D.IDENTITY)
	else:
		overlay.draw_set_transform_matrix(Transform2D(fixed_rotation, c) * Transform2D(0.0, -c))


## crosshairs_placed1..4 (weapon slot 0..3), _yellow when autofiring.
static func crosshair_texture(slot: int, auto: bool) -> Texture2D:
	var n := clampi(slot, 0, 3) + 1
	return FtlData.texture("img/misc/crosshairs_placed%d%s.png" % [n, "_yellow" if auto else ""])


## RenderBeamAiming: the 1×18 misc/beam_center(_yellow).png column repeated along the line, starting at
## `a` (1 px before it), centred on it (9 px each side).
static func draw_beam_aim(ci: CanvasItem, a: Vector2, b: Vector2, auto: bool) -> void:
	var length := int(a.distance_to(b))
	if length <= 0:
		return
	var tex := FtlData.texture("img/misc/beam_center_yellow.png" if auto else "img/misc/beam_center.png")
	ci.draw_set_transform(a, (b - a).angle())
	if tex:
		ci.draw_texture_rect_region(tex, Rect2(-1, -9, length, 18), Rect2(0, 0, 1, 18))
	else:
		ci.draw_line(Vector2(-1, 0), Vector2(length - 1, 0), Color(1, 0.2, 0.2, 0.8), 4)
	ci.draw_set_transform(Vector2.ZERO, 0.0)


## A shot or beam hits this ship's shield at `at` (arc flash; a beam passes its own `id` every frame).
func flash_shield(at := Vector2.INF, id := -1) -> void:
	if at == Vector2.INF:
		view.shield_flash = 1.0
		return
	view.add_shield_hit(at, id)


func show_text(text: String, at: Vector2, color: Color) -> void:
	_texts.append({"text": text, "pos": at, "color": color, "t": 1.2})


## DamageMessage colours (ShipManager::DamageArea / DamageSystem).
const MSG_HULL := Color(1, 1, 1)
const MSG_SYSTEM := Color(1.0, 0.392, 0.392)
const MSG_ION := Color(0.157, 0.824, 0.902)
const MSG_TIME := 1.0  # s on screen
const MSG_RISE := 10.0  # px it floats up over its life


## DamageMessage with a number (numbers/Text_N_L.png digits, 16 px apart, from (-32, -46)).
func show_number(amount: int, at: Vector2, color := MSG_HULL) -> void:
	_messages.append({"text": str(amount), "pos": at + Vector2(randi() % 21 - 10, 0), "color": color, "t": 0.0})


## One-shot animation (e.g. explosion1 of a system blowing up) centred at `at`, in world coordinates.
func show_anim(anim_name: String, at: Vector2) -> void:
	var an := FtlData.anim(anim_name)
	if an.is_empty() or an.get("frames", []).is_empty():
		return
	_anims.append({"anim": an, "pos": at, "t": 0.0})


## DamageMessage MISS (numbers/text_miss.png at (-32, -46)).
func show_miss(at: Vector2) -> void:
	_messages.append({"text": "MISS", "pos": at + Vector2(randi() % 21 - 10, 0), "color": MSG_HULL, "t": 0.0})


## DamageMessage RESIST (numbers/text_resist.png): ROCK_ARMOR / SYSTEM_CASING white, ION_ARMOR on a room
## (40, 210, 230), on a shield (40, 240, 40) (rules/augments.md §2).
func show_resist(at: Vector2, color := MSG_HULL) -> void:
	_messages.append({"text": "RESIST", "pos": at + Vector2(randi() % 21 - 10, 0), "color": color, "t": 0.0})


## The RESIST messages of an `apply_damage` / `apply_beam` summary (`resisted` ids).
func show_resists(r: Dictionary, at: Vector2) -> void:
	for id in r.get("resisted", []):
		show_resist(at, AugmentRule.RESIST_ROOM_COLOR if id == "ION_ARMOR" else MSG_HULL)


func _draw_messages() -> void:
	for m in _messages:
		_upright(m.pos)  # rotated view: upright, rising up the screen
		var p: Vector2 = m.pos - Vector2(0, m.t / MSG_TIME * MSG_RISE)
		if m.text == "RESIST":
			var rt := FtlData.texture("img/numbers/text_resist.png")
			if rt:
				overlay.draw_texture(rt, p + Vector2(-32, -46), m.color)
			continue
		if m.text == "MISS":
			var tex := FtlData.texture("img/numbers/text_miss.png")
			if tex:
				overlay.draw_texture(tex, p + Vector2(-32, -46), m.color)
			continue
		var x := -32.0
		for ch in String(m.text):
			var tex := FtlData.texture("img/numbers/Text_%s_L.png" % ch)
			if tex:
				overlay.draw_texture(tex, p + Vector2(x, -46), m.color)
			x += 16.0
	_upright(Vector2.INF)


func _process(delta: float) -> void:
	delta = Combat.world_delta(delta)  # damage numbers / messages are game-world (frozen while paused)
	for t in _texts:
		t.t -= delta
		t.pos.y -= 30 * delta
	_texts = _texts.filter(func(t): return t.t > 0)
	for m in _messages:
		m.t += delta
	_messages = _messages.filter(func(m): return m.t < MSG_TIME)
	for a in _anims:
		a.t += delta
	_anims = _anims.filter(func(a): return a.t < maxf(float(a.anim.get("time", 0.75)), 0.05))
	view.highlight_rooms = highlighted_rooms()
	hud.queue_redraw()
	overlay.queue_redraw()
	drone_layer.queue_redraw()


func _draw_hud() -> void:
	var font := ThemeDB.fallback_font
	# Floating texts (converted from world to screen coordinates)
	var xf := viewport.get_canvas_transform()
	for t in _texts:
		var p: Vector2 = xf * t.pos
		var c: Color = t.color
		c.a = clampf(t.t, 0, 1)
		hud.draw_string(font, p + Vector2(-20, 0), t.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, c)
	if not legacy_hud:
		return  # status is drawn by the FTL HUD (ShipStatus / EnemyWindow)

	# Hull bar
	var x := 16.0
	var y := 16.0
	var title := ("%s" % ship.blueprint.name) + ("  —  DESTROYED" if ship.is_destroyed() else "")
	hud.draw_string(font, Vector2(x, y + 14), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.WHITE)
	# Evasion and O2 on the title row: the player HUD must end above the crew list (y 155 of the frame).
	var o2 := ship.env.average_oxygen()
	var o2_col := FtlColors.RED if o2 < 25.0 else (FtlColors.YELLOW if o2 < 75.0 else Color(0.8, 0.8, 0.8))
	var tx := x + font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x + 16
	hud.draw_string(font, Vector2(tx, y + 14), "Evasion %d %%" % ship.dodge_factor(),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.8, 0.8, 0.8))
	hud.draw_string(font, Vector2(tx + 100, y + 14), "O2 %d %%" % int(o2),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, o2_col)
	y += 24
	for i in ship.max_hull:
		var col := Color8(80, 220, 90) if i < ship.hull else Color8(60, 60, 60)
		hud.draw_rect(Rect2(x + i * 9, y, 7, 14), col)
	y += 22
	# Shields
	for i in ship.max_shield_layers():
		var on := i < ship.shield_layers
		hud.draw_circle(Vector2(x + 8 + i * 22, y + 8), 8, Color8(80, 170, 255) if on else Color8(50, 60, 80))
	# Zoltan super shield layers (shield drone): green pips after the shield circles.
	for i in ship.super_shield:
		hud.draw_rect(Rect2(x + 4 + (ship.max_shield_layers() + i) * 22, y + 2, 12, 12), FtlColors.GREEN)
	var mx := ship.max_shield_layers()
	if ship.shield_layers < mx:
		var r := ship.shield_charger / ShipState.SHIELD_CHARGE_TIME
		var sh := ship.sys("shields")
		# Shield charge bar purple while the shields are hacked (draining).
		hud.draw_rect(Rect2(x, y + 20, 80 * r, 4), FtlColors.PURPLE_HACK if sh and sh.hacked else Color8(80, 170, 255))
	y += 30
	# Weapons: charge bar (enemy only; the player has its WeaponPanel)
	if ship.is_player:
		return
	var wl := ship.crew_level_in("weapons")
	for w in ship.weapons:
		var c := Color8(255, 200, 60) if w.powered else Color8(90, 90, 90)
		hud.draw_rect(Rect2(x, y, 120, 12), Color8(40, 40, 40))
		hud.draw_rect(Rect2(x, y, 120 * w.ratio(wl), 12), c)
		var wlabel := "%s (%d)%s" % [w.bp.name, w.power_cost(), "" if w.powered else "  OFF"]
		hud.draw_string(font, Vector2(x + 128, y + 11), wlabel, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)
		y += 18
	# Power of its systems (requires player sensors level 3)
	y += 6
	if not show_power:
		hud.draw_string(font, Vector2(x, y + 12), "Power: ? (sensors level 3)",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, FtlColors.GREY)
		# A system hacked by the player (drone attached) shows its power anyway (rules/hacking.md).
		for id in SystemState.ORDER:
			var hs := ship.sys(id)
			if hs == null or hs.hack_effect() <= 0:
				continue
			y += 16
			hud.draw_string(font, Vector2(x, y + 10), id, HORIZONTAL_ALIGNMENT_LEFT, 70, 11, FtlColors.PURPLE_HACK)
			for i in hs.get_level():
				FtlColors.draw_power_bar(hud, Rect2(x + 72 + i * 11, y, 9, 10), hs.bar_state(i))
		return
	hud.draw_string(font, Vector2(x, y + 12), "Reactor %d/%d" % [ship.reactor_used(), ship.reactor_max],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, FtlColors.WHITE)
	y += 18
	for id in SystemState.ORDER:
		var s := ship.sys(id)
		if s == null or not s.uses_reactor():
			continue
		hud.draw_string(font, Vector2(x, y + 10), id, HORIZONTAL_ALIGNMENT_LEFT, 70, 11, FtlColors.WHITE)
		for i in s.get_level():
			FtlColors.draw_power_bar(hud, Rect2(x + 72 + i * 11, y, 9, 10), s.bar_state(i))
		var outline := FtlColors.lock_outline(s)
		if outline.a > 0.0:
			hud.draw_rect(Rect2(x + 70, y - 2, s.get_level() * 11 + 2, 14), outline, false, 1)
			hud.draw_string(font, Vector2(x + 72 + s.get_level() * 11 + 4, y + 10),
				"HACK" if s.hacked else ("ION %d" % s.ion if s.ion > 0 else "ON"), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, outline)
		y += 14
