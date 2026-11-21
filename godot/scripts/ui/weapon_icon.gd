class_name WeaponIcon
## Weapon icon in UI boxes (store, equipment / SELL tab, hangar): WeaponAnimation::RenderIcon [exe] — the weapon
## strip at its charged frame, centred on the box point, rotated 90° (GL_Rotate(90, 0, 0, 1): clockwise on screen)
## and drawn with Animation::OnRender(mirror = true), i.e. the frame is flipped horizontally before the rotation
## (so the art points right and its top side ends up at the bottom; without the flip it looks upside down).


## `tex` = the weapon's strip texture, `src` = the frame rect in it, `centre` = icon centre on `ci`.
static func draw(ci: CanvasItem, tex: Texture2D, src: Rect2, centre: Vector2, color := Color.WHITE) -> void:
	if tex == null:
		return
	ci.draw_set_transform(centre, PI / 2, Vector2(-1, 1))  # scale (mirror) first, then the rotation
	ci.draw_texture_rect_region(tex, Rect2(-src.size / 2, src.size), src, color)
	ci.draw_set_transform(Vector2.ZERO, 0, Vector2.ONE)


## WeaponBlueprint::RenderIcon (AnimationControl::RenderWeaponIcon → WeaponAnimation::RenderIcon): the blueprint's
## weaponArt strip at its charged frame, rotated, centred on `centre`.
static func draw_weapon(ci: CanvasItem, weapon: String, centre: Vector2, color := Color.WHITE) -> void:
	var a := weapon_anim_of(weapon)
	if a.is_empty() or a.sheet.is_empty():
		return
	var frames: Array = a.sheet.frames
	draw(ci, a.sheet.texture, frames[clampi(int(a.charged_frame), 0, frames.size() - 1)], centre, color)


## WeaponBlueprint::GetDimensions: the art's frame size as drawn by the icon (rotated 90°: frame height × width).
static func weapon_dims(weapon: String) -> Vector2:
	var a := weapon_anim_of(weapon)
	if a.is_empty() or a.sheet.is_empty():
		return Vector2.ZERO
	return Vector2(int(a.sheet.fh), int(a.sheet.fw))


static func weapon_anim_of(weapon: String) -> Dictionary:
	var bp := FtlData.weapon_blueprint(weapon)
	if bp.is_empty():
		return {}
	var art := String(bp.get("weapon_art", "")).strip_edges()
	return FtlData.weapon_anim(art if art != "" else String(bp.get("image", "")).strip_edges())


## Crew-like drones (REPAIR 2, BATTLE 3, BOARDER 4: DroneBlueprint type − 2 < 3) draw a crew portrait.
static func drone_is_crew_like(drone: String) -> bool:
	return String(FtlData.drone_blueprint(drone).get("type", "")) in ["REPAIR", "BATTLE", "BOARDER"]


## DroneBlueprint::RenderIcon centred on `centre`: crew-like drones = the repair / battle / boarder_ion walk-down
## frame (base + green layer); others = ship/drones/<droneImage>_charged.png centred (+4 y for DEFENSE and
## COMBAT_BEAM_2), DEFENSE also its _gun_on turret.
static func draw_drone(ci: CanvasItem, drone: String, centre: Vector2, color := Color.WHITE) -> void:
	var bp := FtlData.drone_blueprint(drone)
	var ty := String(bp.get("type", ""))
	if drone_is_crew_like(drone):
		var race := "repair" if ty == "REPAIR" else ("boarder_ion" if drone == "BOARDER_ION" else "battle")
		CrewPortrait.draw_icon(ci, CrewPortrait.drone_look(race), centre)
		return
	var img := String(bp.get("drone_image", ""))
	var tex := FtlData.first_texture(["img/ship/drones/%s_charged.png" % img, "img/ship/drones/%s_on.png" % img,
		"img/ship/drones/%s_base.png" % img])
	if tex == null:
		return
	var c := centre
	if ty == "DEFENSE" or drone == "COMBAT_BEAM_2":
		c.y += 4
	ci.draw_texture(tex, (c - tex.get_size() / 2).round(), color)
	if ty == "DEFENSE":
		var gun := FtlData.texture("img/ship/drones/%s_gun_on.png" % img)
		if gun:
			ci.draw_texture(gun, (c - gun.get_size() / 2).round(), color)


## DroneBlueprint::GetDimensions. Crew-like drones look up "<NAME>_walk_down" with the upper-case blueprint name,
## which no animation has → (0, 0) [inferred]; others = the _charged image size, +8 h for DEFENSE /
## COMBAT_BEAM_2, +(16, 22) for SHIELD.
static func drone_dims(drone: String) -> Vector2:
	if drone_is_crew_like(drone):
		return Vector2.ZERO
	var bp := FtlData.drone_blueprint(drone)
	var img := String(bp.get("drone_image", ""))
	var tex := FtlData.texture("img/ship/drones/%s_charged.png" % img)
	var d := tex.get_size() if tex else Vector2.ONE
	var ty := String(bp.get("type", ""))
	if ty == "SHIELD":
		d += Vector2(16, 22)
	elif ty == "DEFENSE" or drone == "COMBAT_BEAM_2":
		d.y += 8
	return d
