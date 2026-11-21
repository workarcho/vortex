class_name DroneArt
extends RefCounted
## Draws space drones with their original art (img/ship/drones/<droneImage>_*.png; rules/drones.md,
## CombatDrone / DefenseDrone / SuperShieldDrone / BoarderPodDrone::RenderDrone). Images are centred on
## the drone and rotated by angle + 90 degrees (the art points up).
##   combat / beam / hull repair: _base (unpowered), _on (powered, flying), _charged (paused before a shot),
##     plus drone_engine.png along the flight heading while powered;
##   defence / anti-drone: _base body + _gun (unpowered) / _gun_on / _gun_charged (ready) turret on the aim;
##   shield drone: drone_shield_off / _charged + _glow while charging;
##   boarding pod: the boarder's first walk frame + boarder_engine.png flame.
## Stunned drones spin; a destroyed drone plays explosion1.


static func _tex(name: String) -> Texture2D:
	return FtlData.texture("img/ship/drones/%s.png" % name)


static func _draw_centered(ci: CanvasItem, tex: Texture2D, at: Vector2, deg: float, mod := Color.WHITE) -> void:
	if tex == null:
		return
	ci.draw_set_transform(at, deg_to_rad(deg + 90.0))
	ci.draw_texture(tex, -tex.get_size() / 2, mod)
	ci.draw_set_transform(Vector2.ZERO, 0.0)


static func draw(ci: CanvasItem, d: Drone) -> void:
	if d.exploding >= 0.0:
		var an := FtlData.anim("explosion1")
		if not an.is_empty():
			var t := maxf(float(an.time), 0.1)
			ci.draw_set_transform(d.pos, 0.0)
			Projectile.draw_anim_frame(ci, an, clampf(1.0 - d.exploding / t, 0.0, 0.999))
			ci.draw_set_transform(Vector2.ZERO, 0.0)
		return
	var img := String(d.bp.get("drone_image", ""))
	var body_angle := d.spin if d.stunned() else d.aim_angle
	match d.kind:
		Drone.Kind.COMBAT, Drone.Kind.SHIP_REPAIR:
			if d.powered and not d.stunned() and d.pause <= 0.0:
				_draw_centered(ci, _tex("drone_engine"), d.pos, d.heading)
			var state := "_base"
			if d.powered:
				state = "_charged" if d.pause > 0.0 else "_on"
			_draw_centered(ci, _tex(img + state), d.pos, body_angle)
		Drone.Kind.DEFENSE:
			if d.powered and not d.stunned():
				_draw_centered(ci, _tex("drone_engine"), d.pos, d.heading)
			_draw_centered(ci, _tex(img + ("_charged" if d.powered else "_base")), d.pos,
				d.spin if d.stunned() else 0.0)
			var gun := "_gun"
			if d.powered:
				gun = "_gun_charged" if d.fire_ready else "_gun_on"
			_draw_centered(ci, _tex(img + gun), d.pos, body_angle)
		Drone.Kind.SHIELD:
			_draw_centered(ci, _tex("drone_shield_charged" if d.powered else "drone_shield_off"), d.pos,
				d.spin if d.stunned() else 0.0)
			if d.glow > 0.0:
				var a := clampf(sin((Drone.SHIELD_GLOW - d.glow) / Drone.SHIELD_GLOW * PI), 0.0, 1.0)
				_draw_centered(ci, _tex("drone_shield_glow"), d.pos, 0.0, Color(1, 1, 1, a))
		Drone.Kind.BOARDER:
			if d.pod_phase == 2:
				return
			var race := "boarder_ion" if String(d.bp.get("name", "")) == "BOARDER_ION" else "battle"
			if d.powered and not d.stunned():
				_draw_centered(ci, _tex("boarder_engine"), d.pos, body_angle)
			var an := FtlData.anim(race + "_walk_down")
			if not an.is_empty():
				var src: Rect2 = an.frames[0]
				ci.draw_set_transform(d.pos, deg_to_rad(body_angle + 90.0))
				ci.draw_texture_rect_region(an.texture, Rect2(-src.size / 2, src.size), src)
				ci.draw_set_transform(Vector2.ZERO, 0.0)
		Drone.Kind.HACKING:
			# HackingDrone: drone_hack_on (powered) / _base in flight; attached: drone_hack_land (5 frames,
			# 0.3 s) then drone_hack_extend (5 frames, 1.0 s, held on its last frame), pointing into the hull.
			if d.arrived():
				var land := FtlData.anim("drone_hack_land")
				var ext := FtlData.anim("drone_hack_extend")
				var an := land
				var p := 0.999
				if not land.is_empty() and d.land_time < float(land.time):
					p = d.land_time / maxf(float(land.time), 0.01)
				elif not ext.is_empty():
					an = ext
					p = minf((d.land_time - float(land.get("time", 0.0))) / maxf(float(ext.time), 0.01), 0.999)
				if not an.is_empty():
					var n: int = an.frames.size()
					var src: Rect2 = an.frames[clampi(int(p * n), 0, n - 1)]
					ci.draw_set_transform(d.pos, deg_to_rad(d.heading + 90.0))
					ci.draw_texture_rect_region(an.texture, Rect2(-src.size / 2, src.size), src)
					ci.draw_set_transform(Vector2.ZERO, 0.0)
					return
			_draw_centered(ci, _tex("drone_hack_on" if d.powered else "drone_hack_base"), d.pos,
				d.spin if d.stunned() else d.heading)
		_:
			_draw_centered(ci, _tex("drone_hack_base"), d.pos, body_angle)
