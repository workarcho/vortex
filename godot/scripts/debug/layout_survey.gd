extends Node
## Read-only touch-layout survey (debug tool; touches no layout code). Boot scene layout_survey.tscn adds this node to
## the root and then opens title.tscn exactly like a normal run, so every game / sandbox CLI flag works as usual:
##   godot --path godot res://scripts/debug/layout_survey.tscn -- --device=phone --player-ship=PLAYER_SHIP_HARD
##     --drones=Blueprint --screenshot=../work/shots/survey/phone/PLAYER_SHIP_HARD.png --wait=8 --mute [--survey-at=1.5]
## `--survey-at` seconds after main.gd's scene appears (keep `--wait` larger: main's own shot then never happens) it
## saves the normal screenshot to the --screenshot path, then captures the HUD alone (player ship, its space, the
## backdrop and asteroids hidden) over black and over white to get the HUD's alpha, and prints one `SURVEY {json}`
## line: layout kind, canvas, player ship zoom, rooms in canvas px (rotation-aware, through main.world_to_screen),
## HUD-solid (alpha > 0.5) pixels inside each room (+ TOUCH_ROOM_WALL), the hull art's opaque extent vs the canvas,
## and room area vs the free (non-HUD) canvas area. A check image (HUD tinted, rooms outlined: green clear / red
## overlapped, hull extent in yellow) goes to <shot>_check.png. Then quits.

const ALPHA_SOLID := 0.5

var _main: Node = null
var _t := 0.0
var _done := false
var _at := 1.5
var _shot := ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--survey-at="):
			_at = float(a.trim_prefix("--survey-at="))
		elif a.begins_with("--screenshot="):
			_shot = a.trim_prefix("--screenshot=")


func _process(delta: float) -> void:
	if _done:
		return
	var cs := FrameHost.top_scene(get_tree())
	if _main == null:
		if cs != null and cs.get_script() != null and String(cs.get_script().resource_path).ends_with("main.gd"):
			_main = cs
			_t = 0.0
		return
	_t += delta
	if _t >= _at:
		_done = true
		_survey()


func _survey() -> void:
	var m := _main
	var vp := m.get_viewport()
	var vis: Vector2 = vp.get_visible_rect().size
	var ps = m.player_space
	var ship = ps.ship
	await RenderingServer.frame_post_draw
	var normal: Image = vp.get_texture().get_image()
	var isz := normal.get_size()
	var f := Vector2(isz) / vis  # image px per canvas px
	if _shot != "":
		normal.save_png(_shot)
	# Rooms (canvas rects, rotation-aware bbox of the corners), grown by the walls like the layout fit.
	var z: float = m.touch_ship_zoom
	var wall: float = m.TOUCH_ROOM_WALL
	var rooms := []
	for room in ship.layout.rooms:
		var rr: Rect2 = ship.room_rect(room.id)
		rooms.append({"id": room.id, "r": _canvas_rect(m, ship, rr), "rw": _canvas_rect(m, ship, rr.grow(wall))})
	# Hull art opaque extent: each opaque row's two ends mapped to the canvas.
	var rows: Array = m._touch_hull_rows()
	var hp: Vector2 = m._touch_hull_pos()
	var hb := Rect2()
	var first := true
	for i in rows.size():
		var r: Vector2i = rows[i]
		if r.x < 0:
			continue
		for p in [Vector2(r.x, i), Vector2(r.y + 1, i), Vector2(r.x, i + 1), Vector2(r.y + 1, i + 1)]:
			var c: Vector2 = m.world_to_screen(ship, hp + p)
			if first:
				hb = Rect2(c, Vector2.ZERO)
				first = false
			else:
				hb = hb.expand(c)
	# HUD alone over black and over white.
	var hidden := []
	for n in [ps, m.space_backdrop, m.asteroid_layers, m.asteroid_front]:
		if n != null and n.visible:
			n.visible = false
			hidden.append(n)
	if m.space_backdrop != null and m.space_backdrop.mirror != null and m.space_backdrop.mirror.visible:
		m.space_backdrop.mirror.visible = false
		hidden.append(m.space_backdrop.mirror)
	RenderingServer.set_default_clear_color(Color.BLACK)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var blk: Image = vp.get_texture().get_image()
	RenderingServer.set_default_clear_color(Color.WHITE)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var wht: Image = vp.get_texture().get_image()
	for n in hidden:
		n.visible = true
	blk.convert(Image.FORMAT_RGB8)
	wht.convert(Image.FORMAT_RGB8)
	var bd := blk.get_data()
	var wd := wht.get_data()
	var w := isz.x
	var h := isz.y
	var mask := PackedByteArray()
	mask.resize(w * h)
	var hud_px := 0
	for i in w * h:
		var j := i * 3
		var diff := (wd[j] - bd[j]) + (wd[j + 1] - bd[j + 1]) + (wd[j + 2] - bd[j + 2])
		if 1.0 - diff / 765.0 > ALPHA_SOLID:
			mask[i] = 1
			hud_px += 1
	var free_canvas := (w * h - hud_px) / (f.x * f.y)
	# Per room: HUD-solid pixels inside the walled room rect.
	var room_area := 0.0
	var bad := []
	var worst := 0
	var bad_core := []  # HUD pixels inside the room's floor itself (walls excluded)
	for e in rooms:
		room_area += (e.r as Rect2).get_area()
		var n_canvas := _count(mask, e.rw, f, w, h)
		var n_core := _count(mask, e.r, f, w, h)
		e["hud_px"] = n_canvas
		if n_canvas > 2:
			bad.append([e.id, n_canvas])
		if n_core > 2:
			bad_core.append([e.id, n_core])
		worst = maxi(worst, n_canvas)
	var rooms_bb := Rect2()
	for i in rooms.size():
		rooms_bb = rooms[i].r if i == 0 else rooms_bb.merge(rooms[i].r)
	var off := {"left": maxf(0.0, -hb.position.x), "top": maxf(0.0, -hb.position.y),
		"right": maxf(0.0, hb.end.x - vis.x), "bottom": maxf(0.0, hb.end.y - vis.y)}
	var on := hb.intersection(Rect2(Vector2.ZERO, vis))
	var out := {
		"ship": ship.blueprint.name, "kind": m._touch_kind, "canvas": [vis.x, vis.y], "zoom": z,
		"hud_scale": m.TOUCH_SYSBAR_SCALE, "pan": m.get("pan_pos"),
		"rooms_hit": bad, "rooms_hit_core": bad_core, "worst_room_hud_px": worst,
		"hull": [roundf(hb.position.x), roundf(hb.position.y), roundf(hb.size.x), roundf(hb.size.y)],
		"hull_off": off, "hull_on_frac": snappedf(on.get_area() / maxf(hb.get_area(), 1.0), 0.001),
		"rooms_bb": [roundf(rooms_bb.position.x), roundf(rooms_bb.position.y), roundf(rooms_bb.size.x),
			roundf(rooms_bb.size.y)],
		"room_area_frac_free": snappedf(room_area / maxf(free_canvas, 1.0), 0.001),
		"rooms_bb_frac_canvas": snappedf(rooms_bb.get_area() / (vis.x * vis.y), 0.001),
		"free_frac_canvas": snappedf(free_canvas / (vis.x * vis.y), 0.001),
	}
	print("SURVEY ", JSON.stringify(out))
	if _shot != "":
		_check_image(normal, mask, rooms, hb, f).save_png(_shot.get_basename() + "_check.png")
	get_tree().quit()


## HUD-solid pixels (canvas px²) of `mask` inside canvas rect `r`.
func _count(mask: PackedByteArray, r: Rect2, f: Vector2, w: int, h: int) -> int:
	var ri := Rect2i(Vector2i((r.position * f).floor()), Vector2i((r.size * f).ceil())).intersection(Rect2i(0, 0, w, h))
	var n := 0
	for y in range(ri.position.y, ri.end.y):
		var row := y * w
		for x in range(ri.position.x, ri.end.x):
			n += mask[row + x]
	return int(round(n / (f.x * f.y)))


func _canvas_rect(m: Node, ship, r: Rect2) -> Rect2:
	var out := Rect2()
	var i := 0
	for p in [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]:
		var c: Vector2 = m.world_to_screen(ship, p)
		out = Rect2(c, Vector2.ZERO) if i == 0 else out.expand(c)
		i += 1
	return out


## The screenshot darkened, HUD-solid pixels tinted blue, rooms outlined (green clear / red with HUD inside), the
## hull's opaque extent in yellow.
func _check_image(normal: Image, mask: PackedByteArray, rooms: Array, hb: Rect2, f: Vector2) -> Image:
	var img := normal.duplicate() as Image
	img.convert(Image.FORMAT_RGB8)
	var w := img.get_width()
	var d := img.get_data()
	for i in w * img.get_height():
		var j := i * 3
		if mask[i]:
			d[j] = d[j] / 3
			d[j + 1] = d[j + 1] / 3
			d[j + 2] = mini(255, d[j + 2] / 3 + 110)
		else:
			d[j] = d[j] * 2 / 3
			d[j + 1] = d[j + 1] * 2 / 3
			d[j + 2] = d[j + 2] * 2 / 3
	img.set_data(w, img.get_height(), false, Image.FORMAT_RGB8, d)
	for e in rooms:
		_outline(img, e.rw, f, Color.RED if e.hud_px > 2 else Color.GREEN)
	_outline(img, hb, f, Color.YELLOW)
	return img


func _outline(img: Image, r: Rect2, f: Vector2, c: Color) -> void:
	var a := Vector2i((r.position * f).round())
	var b := Vector2i((r.end * f).round())
	var sz := img.get_size()
	for t in 2:
		for x in range(a.x, b.x + 1):
			for y in [a.y + t, b.y - t]:
				if x >= 0 and x < sz.x and y >= 0 and y < sz.y:
					img.set_pixel(x, y, c)
		for y in range(a.y, b.y + 1):
			for x in [a.x + t, b.x - t]:
				if x >= 0 and x < sz.x and y >= 0 and y < sz.y:
					img.set_pixel(x, y, c)
