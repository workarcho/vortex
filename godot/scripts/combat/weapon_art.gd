class_name WeaponArt
extends RefCounted
## Weapon art on the hull (rules/weapon_visuals.md "Weapon mounts"; FTL's WeaponAnimation::OnRender,
## GetSlide, SetChargedLevel, SetFireLevel, GetFireLocation). Drawing helpers only: no game logic.

const SLIDE_TIME := 0.5  # s: slideTracker time (weapon slides out of / back into the hull)
const MISSILE_LAUNCH_OFFSET := 16.0  # px: missiles start 16 px ahead of the fire point


## Frame of the weapon strip for the weapon's current state.
static func frame_index(w: WeaponState, weapons_crew_level: int) -> int:
	var a := w.anim
	var n: int = maxi(int(a.length), 1)
	var cf: int = int(a.charged_frame)
	var ff: int = int(a.fire_frame)
	if w.beam_level >= 0.0:  # SetFireLevel: fireFrame .. last frame along the sweep
		return clampi(int(float(n - 1 - ff) * w.beam_level + ff), 0, n - 1)
	if w.fire_anim >= 0.0:  # firing: chargedFrame .. last frame over fire_time
		var t := w.fire_anim / maxf(w.fire_time(), 0.001)
		return clampi(cf + int(t * float(n - cf)), 0, n - 1)
	if not w.powered:
		return 0
	if w.charge_levels() >= 2 and w.charge_level >= 1:
		return cf
	var r := w.ratio(weapons_crew_level)
	return cf if r >= 1.0 else clampi(int(r * cf), 0, n - 1)


## Mount point of the strip, mirrored like the art (frameWidth − x).
static func _mount_point(mount: Dictionary, a: Dictionary) -> Vector2:
	var mp: Vector2 = a.get("mount_point", Vector2.ZERO)
	if mount.get("mirror", false):
		mp.x = float(a.sheet.fw) - mp.x
	return mp


## GetSlide: an unpowered weapon is pushed half its (rotated) size back against the slide direction;
## `p` = 0 retracted .. 1 out. slide: 0 down, 1 right, 2 up, 3 left, 4 none.
static func slide_offset(mount: Dictionary, a: Dictionary, p: float) -> Vector2:
	if a.get("sheet", {}).is_empty():
		return Vector2.ZERO
	var rot: bool = mount.get("rotate", false)
	var h: int = (int(a.sheet.fw) if rot else int(a.sheet.fh)) / 2
	var wd: int = (int(a.sheet.fh) if rot else int(a.sheet.fw)) / 2
	var k := 1.0 - p
	match int(mount.get("slide", 4)):
		0:
			return Vector2(0, -h * k)
		2:
			return Vector2(0, h * k)
		1:
			return Vector2(-wd * k, 0)
		3:
			return Vector2(wd * k, 0)
	return Vector2.ZERO


## fireMountVector: fire point − mount point (mirrored, then rotated 90° clockwise with the art).
static func fire_vector(mount: Dictionary, a: Dictionary) -> Vector2:
	if a.get("sheet", {}).is_empty():
		return Vector2.ZERO
	var fp: Vector2 = a.get("fire_point", Vector2.ZERO)
	var mp: Vector2 = a.get("mount_point", Vector2.ZERO)
	if mount.get("mirror", false):
		fp.x = float(a.sheet.fw) - fp.x
		mp.x = float(a.sheet.fw) - mp.x
	var v := fp - mp
	if mount.get("rotate", false):
		v = Vector2(-v.y, v.x)
	return v


## Transform that places the strip frame (0,0)-(fw,fh) on the hull: the mount point lands on `at`
## (+ slide); rotate = 90° clockwise about the mount point; mirror = horizontal flip of the frame.
static func art_transform(mount: Dictionary, a: Dictionary, at: Vector2, slide: Vector2) -> Transform2D:
	var mp := _mount_point(mount, a)
	var x := Transform2D(0.0, (at - mp + slide).round())
	if mount.get("rotate", false):
		x = x * Transform2D(0.0, mp) * Transform2D(PI / 2, Vector2.ZERO) * Transform2D(0.0, -mp)
	if mount.get("mirror", false):
		x = x * Transform2D(Vector2(-1, 0), Vector2(0, 1), Vector2(float(a.sheet.fw), 0))
	return x


## Draws one weapon on `ci` (mount position `at` in ship coordinates; `slide_p` 0..1).
## `base`: extra transform applied first (weapons flying with a gib, rules/ship_destruction.md §3.3).
static func draw(ci: CanvasItem, w: WeaponState, mount: Dictionary, at: Vector2, slide_p: float,
		weapons_crew_level: int, modulate := Color.WHITE, base := Transform2D.IDENTITY) -> void:
	var a := w.anim
	if a.get("sheet", {}).is_empty():
		ci.draw_set_transform_matrix(base)
		ci.draw_circle(at, 4, Color(1, 0.85, 0.3))
		ci.draw_set_transform_matrix(Transform2D.IDENTITY)
		return
	var frame := frame_index(w, weapons_crew_level)
	var frames: Array = a.sheet.frames
	var src: Rect2 = frames[clampi(frame, 0, frames.size() - 1)]
	ci.draw_set_transform_matrix(base * art_transform(mount, a, at, slide_offset(mount, a, slide_p)))
	var rect := Rect2(Vector2.ZERO, Vector2(a.sheet.fw, a.sheet.fh))
	ci.draw_texture_rect_region(a.sheet.texture, rect, src, modulate)
	# Charge glow (chargeImage): alpha = charge level while charging, not on the charged frame.
	var glow_name: String = a.get("charge_image", "")
	if glow_name != "" and w.fire_anim < 0.0 and w.beam_level < 0.0 and frame != int(a.charged_frame):
		var glow := FtlData.texture("img/" + glow_name)
		var r := w.ratio(weapons_crew_level)
		if glow and r > 0.0:
			ci.draw_texture_rect(glow, Rect2(Vector2.ZERO, glow.get_size()), false, Color(modulate, modulate.a * r))
	ci.draw_set_transform_matrix(Transform2D.IDENTITY)


## Enemy weapon charge bar (WeaponAnimation::RenderChargeBar, called for every weapon and artillery weapon of
## the targeted enemy by ShipManager::RenderChargeBars after the ship is drawn; rules/hacking.md "UI"). Drawn
## only for an enemy weapon that is powered and either shows its charge (bShowCharge = player sensors
## DoSensorsProvide(4), i.e. effective power > 2, ship not dying / jumping) or is hacked (iHackLevel > 0 =
## the weapons / artillery system's IsSystemHacked). Frame: the art frame placed like the strip (mount, slide,
## rotation) but never flipped; the box `box_hostiles_weapon_charge.png` (8×35) at x = frame width + 10
## (mirrored mount: −18), y 0; the bar `box_hostiles_weapon_chargebar.png` (4×31) bottom part, h =
## min(ceil(charge × 31), 31), at (2, 33 − h). Both tinted COLOR_YELLOW, COLOR_PURPLE_HACKING at hack level ≥ 2.
static func charge_bar_visible(ship: ShipState, w: WeaponState) -> bool:
	if ship.is_player or not w.powered:
		return false
	var o := ship.opponent
	var show := o != null and o.is_player and o.sensors_provide(4) and not ship.jumping  # SetShowWeaponCharge
	return show or hack_level(ship, w) > 0


## ProjectileFactory::iHackLevel: WeaponSystem / ArtillerySystem::OnLoop copy IsSystemHacked of their system.
static func hack_level(ship: ShipState, w: WeaponState) -> int:
	var s := ship.artillery_system(w) if w.is_artillery else ship.sys("weapons")
	return s.hack_effect() if s != null else 0


static func draw_charge_bar(ci: CanvasItem, w: WeaponState, mount: Dictionary, at: Vector2, slide_p: float,
		charge: float, hack_level: int) -> void:
	var a := w.anim
	if a.get("sheet", {}).is_empty():
		return
	var box := FtlData.texture("img/combatUI/box_hostiles_weapon_charge.png")
	var bar := FtlData.texture("img/combatUI/box_hostiles_weapon_chargebar.png")
	if box == null:
		return
	var mp := _mount_point(mount, a)
	var x := Transform2D(0.0, (at - mp + slide_offset(mount, a, slide_p)).round())
	if mount.get("rotate", false):
		x = x * Transform2D(0.0, mp) * Transform2D(PI / 2, Vector2.ZERO) * Transform2D(0.0, -mp)
	var ox := -18.0 if mount.get("mirror", false) else float(a.sheet.fw) + 10.0
	ci.draw_set_transform_matrix(x * Transform2D(0.0, Vector2(ox, 0)))
	var col := FtlColors.PURPLE_HACK if hack_level > 1 else FtlColors.YELLOW
	ci.draw_texture(box, Vector2.ZERO, col)
	if charge > 0.0 and bar != null:
		var h := mini(int(ceilf(charge * 31.0)), 31)
		var th := bar.get_height()
		var src := Rect2(0, th * (1.0 - h / 31.0), bar.get_width(), th * h / 31.0)
		ci.draw_texture_rect_region(bar, Rect2(2, 33 - h, bar.get_width(), h), src, col)
	ci.draw_set_transform_matrix(Transform2D.IDENTITY)


## Where the weapon's shots start (GetFireLocation; missiles 16 px further along the firing heading).
static func fire_location(ship: ShipState, w: WeaponState) -> Vector2:
	var i := w.mount_index
	if i >= ship.mounts.size():
		return ship.mount_position(i)
	var p := ship.mount_position(i) + fire_vector(ship.mounts[i], w.anim)
	if w.bp.get("type", "") == "MISSILES":
		p += Vector2.from_angle(deg_to_rad(ship.fire_heading)) * MISSILE_LAUNCH_OFFSET
	return p
