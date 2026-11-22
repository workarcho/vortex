extends Node
## Tests for the Zoltan super shield (rules/augments.md §3, rules/drones.md §7): ENERGY_SHIELD fill on the first
## frame, no recharge in a fight, refill on jumps, neutral drain, InstantCharge, flagship 12, hits (damage, ion,
## ION_ARMOR, pure stun), blocks (teleporter, hacking), ZOLTAN_BYPASS, drone reconciliation. Run:
##   godot --headless --path godot res://tests/test_super_shield.tscn

const Harness := preload("res://tests/harness.gd")

const F := 0.25

var fails := 0
var rng := RandomNumberGenerator.new()


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	FtlData.muted = true
	rng.seed = 5
	test_fill()
	test_hits()
	test_jump()
	test_neutral_and_spawn()
	test_drone_and_flagship()
	test_blocks()
	test_bubble_geometry()
	test_target_bar()


func zoltan() -> ShipState:
	return ShipState.new("PLAYER_SHIP_ENERGY", true)


## Shot that crosses the shield (dodges skipped).
func shoot(s: ShipState, d: Damage) -> String:
	var r := "miss"
	for i in 100:
		r = s.on_projectile_enters_shield(d, rng)
		if r != "miss":
			return r
	return r


func test_fill() -> void:
	print("ENERGY_SHIELD: 5 points on the first frame, value 2 ignored")
	var s := zoltan()
	check("Zoltan cruiser has ENERGY_SHIELD", AugmentRule.has(s, "ENERGY_SHIELD"), true)
	check("before the first frame: 0", s.super_shield, 0)
	s.tick(F)
	check("first frame: 5", [s.super_shield, s.super_shield_max], [5, 5])
	check("shields system power irrelevant", s.sys("shields") != null, true)
	var k := ShipState.new("PLAYER_SHIP_HARD", true)
	k.tick(F)
	check("Kestrel: none", k.super_shield, 0)


func test_hits() -> void:
	print("Hits: damage removes points, ion x2, pure stun absorbed, no recharge")
	var s := zoltan()
	s.tick(F)
	var layers := s.shield_layers
	var d := Damage.new()
	d.damage = 1
	check("laser absorbed by the super shield", shoot(s, d), "super")
	check("5 -> 4", s.super_shield, 4)
	check("normal layers untouched", s.shield_layers, layers)
	check("green number total", s.last_super_hit.total, 1)
	var d2 := Damage.new()
	d2.damage = 2
	d2.shield_piercing = 5
	shoot(s, d2)
	check("piercing ignored: 4 -> 2", s.super_shield, 2)
	var ion := Damage.new()
	ion.ion = 1
	shoot(s, ion)
	check("ion counts double: 2 -> 0", s.super_shield, 0)
	var after := Damage.new()
	after.damage = 1
	check("no points: shots go to normal shields", shoot(s, after) in ["shield", "pass"], true)
	for i in 64 * 60:
		s.tick(F)
	check("no recharge in a fight (60 s)", s.super_shield, 0)
	var t := zoltan()
	t.tick(F)
	var stun := Damage.new()
	stun.stun_chance = 10
	check("pure stun absorbed", shoot(t, stun), "super")
	check("no point lost", t.super_shield, 5)
	check("bubble alpha 5/5", SuperShieldRule.alpha(t), 1.0)


func test_jump() -> void:
	print("Jump: refill to 5 with ENERGY_SHIELD, drone super shield lost")
	var run := RunState.new_run(4, "PLAYER_SHIP_ENERGY")
	run.ship.tick(F)
	run.ship.super_shield = 1
	run._clear_location()
	check("jump refills the Zoltan cruiser", run.ship.super_shield, 5)
	var k := ShipState.new("PLAYER_SHIP_HARD", true)
	k.add_super_shield()
	k.add_super_shield()
	check("drone made 2", k.super_shield, 2)
	SuperShieldRule.jump(k)
	check("drone super shield lost on jump", k.super_shield, 0)


func test_neutral_and_spawn() -> void:
	print("Neutral / surrendered enemy shows 0; InstantCharge; easy-mode removal")
	var e := ShipState.new("ZOLTAN_FIGHTER", false)
	var ai := ShipAI.new(e, rng)
	ai.hostile = false
	e.tick(F)
	ai.tick(F / GameClock.BASE)
	check("neutral: drained the same frame", e.super_shield, 0)
	e.tick(F)
	check("refilled by its own loop next frame", e.super_shield, 5)
	ai.tick(F / GameClock.BASE)
	check("and drained again by its AI", e.super_shield, 0)
	ai.hostile = true
	e.tick(F)
	ai.tick(F / GameClock.BASE)
	check("turns hostile: 5", e.super_shield, 5)
	var g := ShipState.new("ZOLTAN_FIGHTER", false)
	SuperShieldRule.instant_charge(g)
	check("InstantCharge at creation: 5", g.super_shield, 5)
	var plan := {"augments_removed": ["ENERGY_SHIELD"]}
	var h := ShipState.new("ZOLTAN_FIGHTER", false)
	for id in plan.augments_removed:
		AugmentRule.remove(h, id)
	h.tick(F)
	check("easy sector: ENERGY_SHIELD removed -> 0", h.super_shield, 0)
	var dead := ShipState.new("ZOLTAN_FIGHTER", false)
	var dai := ShipAI.new(dead, rng)
	dead.tick(F)
	dead.hull = 0
	dai.tick(F / GameClock.BASE)
	check("hull 0: drained", dead.super_shield, 0)


func test_drone_and_flagship() -> void:
	print("Shield drone on a Zoltan ship, flagship stage 3")
	var s := zoltan()
	s.tick(F)
	s.super_shield = 3
	s.add_super_shield()
	check("drone +1 (3 -> 4)", s.super_shield, 4)
	s.add_super_shield()
	s.add_super_shield()
	check("cap 5", s.super_shield, 5)
	var f := ShipState.new("REBEL_FAT", false)
	SuperShieldRule.flagship_stage(f, 2)
	check("stage 2: nothing", f.super_shield, 0)
	SuperShieldRule.flagship_stage(f, 3)
	check("stage 3: 12 points", [f.super_shield, f.super_shield_max], [12, 12])
	f.tick(F)
	check("not reset by the loop (no ENERGY_SHIELD)", f.super_shield, 12)
	check("alpha 12/12", SuperShieldRule.alpha(f), 1.0)


func test_blocks() -> void:
	print("Teleporter / hacking blocked; ZOLTAN_BYPASS")
	var me := ShipState.new("PLAYER_SHIP_HARD", true)
	var z := ShipState.new("ZOLTAN_FIGHTER", false)
	me.opponent = z
	z.opponent = me
	z.tick(F)
	check("teleporter send blocked", TeleporterRule.super_blocked(me, z), true)
	check("hacking blocked", HackingRule.blocked(me), true)
	AugmentRule.add(me, "ZOLTAN_BYPASS")
	check("bypass: teleporter allowed", TeleporterRule.super_blocked(me, z), false)
	check("bypass: bombs ignore it", AugmentRule.bypasses_super(me), true)
	check("enemy AI teleporter is not blocked", TeleporterRule.super_blocked(z, me), false)


## Shield ellipse / bubble placement (rules/ship_rendering.md §9, hud_layout.md "Enemy ship"): Ship::Import reads
## ELLIPSE a b cx cy; Ship::GetBaseEllipse = (cx, cy) + ShipGraph centre (integer centre of the rooms' box), +110 y
## on enemy ships; Shields::RenderBase draws the enemy image at 2a × 2b, the player image at its own size, the super
## shield with the same rectangle; the TARGET view is stencilled by box_hostiles_mask.png.
func test_bubble_geometry() -> void:
	print("Shield bubble geometry (enemy / player, super shield) and the TARGET stencil")
	var rig := ShipState.new("REBEL_FAT", false)  # rebel_squat: ELLIPSE 200 225 0 -130
	var b := rig.rooms_bounds()
	var gc := Vector2(floorf(b.position.x + b.size.x / 2.0), floorf(b.position.y + b.size.y / 2.0))
	check("rigger axes (a, b)", rig.shield_axes, Vector2(200, 225))
	check("rigger centre = rooms centre + (0, -130) + (0, 110)", rig.shield_center, gc + Vector2(0, -20))
	var r := ShipView.bubble_rect(rig, Vector2(340, 410))
	check("enemy bubble = 2a x 2b about the centre", r, Rect2(rig.shield_center - Vector2(200, 225), Vector2(400, 450)))
	SuperShieldRule.power(rig, 5)
	check("super shield uses the same rectangle", ShipView.bubble_rect(rig, Vector2(340, 410)), r)
	var k := ShipState.new("PLAYER_SHIP_HARD", true)  # kestral: ELLIPSE 350 220 -30 0, no +110
	var kb := k.rooms_bounds()
	var kc := Vector2(floorf(kb.position.x + kb.size.x / 2.0), floorf(kb.position.y + kb.size.y / 2.0))
	check("player centre: no enemy offset", k.shield_center, kc + Vector2(-30, 0))
	check("player bubble = image size about the centre", ShipView.bubble_rect(k, Vector2(700, 440)),
		Rect2(k.shield_center - Vector2(350, 220), Vector2(700, 440)))
	# BlueprintManager::ProcessShipBlueprint 0x005e77b0: shieldFile / floorFile default to img, <shieldImage> /
	# <floorImage> override them; Shields::Shields 0x0060b230 loads "ship/<shieldFile>_shields1.png" for the
	# player. Kestrel B (img kestral_2, no kestral_2_shields1.png) uses kestral_shields1.png 700 x 440 — it used to
	# fall back to enemy_shields.png 340 x 410 at its own size, a small bubble around the engines.
	var k2 := ShipState.new("PLAYER_SHIP_HARD_2", true)
	check("Kestrel B shield / floor image names", [k2.blueprint.shield_img, k2.blueprint.floor_img],
		["kestral", "kestral_2"])
	check("Kestrel A: names default to img", [k.blueprint.shield_img, k.blueprint.floor_img], ["kestral", "kestral"])
	var v2 := ShipView.new()
	add_child(v2)
	v2.setup(k2)
	check("Kestrel B bubble = kestral_shields1.png 700 x 440 about the centre", ShipView.bubble_rect(k2,
		v2.shield_tex.get_size()), Rect2(k2.shield_center - Vector2(350, 220), Vector2(700, 440)))
	var k3 := ShipState.new("PLAYER_SHIP_HARD_3", true)  # Kestrel C: <shieldImage>/<floorImage> kestral
	var v3 := ShipView.new()
	add_child(v3)
	v3.setup(k3)
	check("Kestrel C: kestral shield image and floor", [v3.shield_tex.get_size(), v3.floor_tex != null],
		[Vector2(700, 440), true])
	v2.queue_free()
	v3.queue_free()
	var missing := []
	for bp in ["PLAYER_SHIP_HARD", "PLAYER_SHIP_HARD_2", "PLAYER_SHIP_HARD_3", "PLAYER_SHIP_CIRCLE",
			"PLAYER_SHIP_CIRCLE_2", "PLAYER_SHIP_CIRCLE_3", "PLAYER_SHIP_FED", "PLAYER_SHIP_FED_2", "PLAYER_SHIP_FED_3",
			"PLAYER_SHIP_ENERGY", "PLAYER_SHIP_ENERGY_2", "PLAYER_SHIP_ENERGY_3", "PLAYER_SHIP_MANTIS",
			"PLAYER_SHIP_MANTIS_2", "PLAYER_SHIP_MANTIS_3", "PLAYER_SHIP_STEALTH", "PLAYER_SHIP_STEALTH_2",
			"PLAYER_SHIP_STEALTH_3", "PLAYER_SHIP_ANAEROBIC", "PLAYER_SHIP_ANAEROBIC_2", "PLAYER_SHIP_CRYSTAL",
			"PLAYER_SHIP_CRYSTAL_2", "PLAYER_SHIP_JELLY", "PLAYER_SHIP_JELLY_2", "PLAYER_SHIP_JELLY_3",
			"PLAYER_SHIP_ROCK", "PLAYER_SHIP_ROCK_2", "PLAYER_SHIP_ROCK_3"]:
		var sb := FtlData.ship_blueprint(bp)
		for f in ["img/ship/%s_shields1.png" % sb.shield_img, "img/ship/%s_floor.png" % sb.floor_img]:
			if FtlData.texture(f) == null:
				missing.append(f)
	check("every player ship A/B/C resolves its shield and floor images", missing, [])
	var jp :=ShipState.new("JELLY_BUTTON_P_DLC", false)  # dlcPirateBlueprints.xml "Pirate Scout": 170 205 0 -50
	check("pirate blueprint loaded, ellipse", [jp.shield_axes, jp.layout.get("vertical", 0)], [Vector2(170, 205), 55])
	print("TARGET stencil (CombatControl::DrawHostileBox)")
	var img := FtlData.texture("img/combatUI/box_hostiles_mask.png").get_image()
	check("mask opaque box (14, 29)..(389, 532)", img.get_used_rect(), Rect2i(14, 29, 376, 504))
	check("header band not in the stencil (frame y 28 / 29)",
		[img.get_pixel(200, 28).a > 0.5, img.get_pixel(200, 29).a > 0.5], [false, true])
	var sp := Space.new()
	var mask := FtlData.texture("img/combatUI/box_hostiles_mask.png")
	sp.set_clip_mask(mask, Rect2(10, 9, 380, 529))
	var mat := sp.material as ShaderMaterial
	check("clip material: mask + container rect in mask px", [mat != null,
		mat.get_shader_parameter("mask_rect") if mat else null], [true, Vector4(10, 9, 380, 529)])
	sp.set_clip_mask(null)
	check("no mask: plain premultiplied compositing", (sp.material as CanvasItemMaterial).blend_mode,
		CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA)
	sp.free()
	print("Unknown weapon names (BlueprintManager::GetWeaponBlueprint default blueprint)")
	check("BOMB_BREACH (WEAPONS_JELLY) unknown, BOMB_BREACH_1 known",
		[FtlData.has_weapon_blueprint("BOMB_BREACH"), FtlData.has_weapon_blueprint("BOMB_BREACH_1")], [false, true])


## CombatControl::RenderShipStatus (0x0055ef20): the enemy super shield bar sits to the right of the shield bubbles
## (x = 23 * max layers), frame (x + 13, 35) = box_hostiles_shield_super5 / 12 (10 * max + 6 wide, 13 high), green
## fill (x + 16, 38), 10 px per point, 7 high.
func test_target_bar() -> void:
	print("TARGET window super shield bar (CombatControl::RenderShipStatus)")
	var r := EnemyWindow.super_shield_rects(2, 5, 5)
	check("2 bubbles, 5/5: frame / fill", r, [Rect2(59, 35, 56, 13), Rect2(62, 38, 50, 7)])
	check("frame starts after the last bubble (x 23 + 21 = 44)", r[0].position.x > HudLayout.SHIELD_STEP + 21, true)
	r = EnemyWindow.super_shield_rects(4, 3, 12)
	check("4 bubbles, 3/12 (flagship)", r, [Rect2(105, 35, 126, 13), Rect2(108, 38, 30, 7)])
	check("frame widths match the images",
		[FtlData.texture("img/combatUI/box_hostiles_shield_super5.png").get_width(),
		FtlData.texture("img/combatUI/box_hostiles_shield_super12.png").get_width()],
		[int(EnemyWindow.super_shield_rects(0, 0, 5)[0].size.x), int(EnemyWindow.super_shield_rects(0, 0, 12)[0].size.x)])
