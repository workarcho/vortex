extends Node
## Logic behind the in-combat visuals (rules/hud_layout.md, rules/hazards.md §8, rules/ship_rendering.md,
## rules/power.md "How the bars are drawn"): hazard HUD effects / tooltips, room warning lights, power bar states and
## repair / damage progress, the ship-status warnings (shields critical, hull 25 % loop), skill-up trackers, the
## extinguisher cloud condition, resource popups and the asteroid layer tint / scroll. Run:
##   godot --headless --path godot res://tests/test_combat_visuals.tscn

const Harness := preload("res://tests/harness.gd")

var fails := 0


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	print("hazard HUD (SpaceStatus)")
	var E := HazardRule.Env
	check("asteroids -> effect 1", HazardRule.create(E.ASTEROIDS, 2, 1, 2).hud_effects(), [1, 0])
	check("sun -> 2", HazardRule.create(E.SUN, 2, 1, 2).hud_effects(), [2, 0])
	check("pulsar -> 5", HazardRule.create(E.PULSAR, 2, 1, 2).hud_effects(), [5, 0])
	check("nebula -> 3", HazardRule.create(E.NEBULA, 2, 1, 2).hud_effects(), [3, 0])
	check("storm -> 3 + 4", HazardRule.create(E.STORM, 2, 1, 2).hud_effects(), [3, 4])
	check("PDS at all -> 6", HazardRule.create(E.PDS, 2, 1, 2).hud_effects(), [6, 0])
	check("PDS at the enemy only -> 9 (allies)", HazardRule.create(E.PDS, 1, 1, 2).hud_effects(), [9, 0])
	var ast := HazardRule.create(E.ASTEROIDS, 2, 1, 2)
	check("asteroid tooltip", ast.hud_tooltip(1), "tooltip_asteroids")
	check("storm tooltip", ast.hud_tooltip(4), "tooltip_storm")
	check("PDS player tooltip", HazardRule.create(E.PDS, 0, 1, 2).hud_tooltip(6), "tooltip_PDS_PLAYER")
	check("PDS fleet tooltip", HazardRule.create(E.PDS, 0, 1, 2).hud_tooltip(6, true), "tooltip_PDS_FLEET")
	check("tooltip text loaded (text_tooltips.xml)", FtlData.tr_id("tooltip_asteroids").begins_with("You're in an"),
		true)
	check("hit box strict inside (655..725, 72..145)", [HazardHud._inside(HazardHud.HITBOX, Vector2(700, 100)),
		HazardHud._inside(HazardHud.HITBOX, Vector2(725, 100)), HazardHud._inside(HazardHud.HITBOX, Vector2(656, 73))],
		[true, false, true])

	print("room warning lights (bWarningLight)")
	var k := ShipState.new("PLAYER_SHIP_HARD", true)
	check("intact ship: none", ShipView.warning_light_rooms(k), [])
	var w := k.sys("weapons")
	k.damage_system("weapons", 1)
	check("damaged system room not lit", ShipView.warning_light_rooms(k), [])
	k.breaches[0] = {0: {"health": 100.0}}
	check("breached room lit", ShipView.warning_light_rooms(k), [0])
	k.fires[w.room] = {0: {"death": -1.0, "health": 100.0}}
	check("burning room lit", ShipView.warning_light_rooms(k).has(w.room), true)
	var o2: SystemState = k.systems.get("oxygen")
	k.systems.erase("oxygen")
	check("no oxygen system: none", ShipView.warning_light_rooms(k), [])
	k.systems["oxygen"] = o2
	k.fires.erase(w.room)
	k.breaches.erase(0)

	print("power bars")
	check("damaged weapons top bar broken", w.bar_state(w.get_level() - 1), "broken")
	w.repair_progress = 40.0
	check("partial damage none", SystemPowerColumn.partial_damage(k, w), 0.0)
	w.damage_over_time(25.0)
	check("partial damage = fDamageOverTime / 100", SystemPowerColumn.partial_damage(k, w), 0.25)
	w.damage_over_time(25.0)
	check("fire and sabotage share it", SystemPowerColumn.partial_damage(k, w), 0.5)
	_test_hud_boxes()
	_test_screen_shake()
	_test_artillery_art()
	var en := k.sys("engines")
	k.set_power_loss("engines", 1)
	check("event-lost bar", en.bar_state(en.get_level() - 1), "lost")

	print("ship status warnings")
	var s2 := ShipState.new("PLAYER_SHIP_HARD", true)
	check("shields intact: no warning", ShipStatusHud.shields_critical(s2), false)
	s2.set_power_loss("shields", 2)
	check("event power loss does not count (GetSystemHealth)", ShipStatusHud.shields_critical(s2), false)
	s2.damage_system("shields", 1)
	check("health 1 < 2 with level 2: SHIELDS CRITICAL", ShipStatusHud.shields_critical(s2), true)

	print("skill-up trackers")
	var c := CrewMember.new("human", true)
	c.add_skill("pilot")
	check("gaining a point starts the pilot tracker", c.skill_up.has("pilot"), true)
	var m := CrewMember.new("human", true)
	m.skills["engines"] = CrewMember.SKILL_CAPS["engines"]
	m.add_skill("engines")
	check("maxed skill: no tracker", m.skill_up.has("engines"), false)

	print("extinguisher cloud")
	var f := ShipState.new("PLAYER_SHIP_HARD", true)
	var cr: CrewMember = f.crew[0]
	cr.task = CrewMember.Task.FIRE
	check("no fire in the room: no cloud", ShipView.is_firefighting(f, cr), false)
	f.fires[cr.room] = {0: {"death": -1.0, "health": 100.0}}
	check("fighting a fire in its room: cloud", ShipView.is_firefighting(f, cr), true)

	print("resource popups")
	var r := ShipState.new("PLAYER_SHIP_HARD", true)
	r.fuel = 10
	r.scrap = 30
	ShipStatusHud.poll_resources(r)  # first poll records the counts
	r.fuel -= 1
	r.scrap += 25
	var sp: Array = ShipStatusHud.poll_resources(r)
	check("two popups", sp.size(), 2)
	check("fuel -1 under the fuel box", [sp[0].kind, sp[0].delta, absf(sp[0].pos.x - 180) <= 10, sp[0].pos.y],
		["fuel", -1, true, 104.0])
	check("scrap +25 at (465, 70)", [sp[1].kind, sp[1].delta, sp[1].pos.y], ["scrap", 25, 70.0])
	check("no change: no popup", ShipStatusHud.poll_resources(r).size(), 0)
	ShipStatusHud.tick_popups(1.0)
	check("popups last 1 s", ShipStatusHud.popups.filter(func(p): return p.ship == r.get_instance_id()).size(), 0)
	var seen := []
	var cb := func(ship, kind, old, now): seen.append([kind, old, now])
	Hooks.listen(&"resource_changed", cb)
	r.missiles = r.missiles + 2
	check("resource_changed hook", seen.size() > 0 and seen[-1][0] == &"missiles", true)

	print("asteroid layers")
	var al := AsteroidLayers.new()
	var hs := ShipState.new("PLAYER_SHIP_HARD", true)
	al.ship = hs
	check("full hull: white", al.tint(), Color(1, 1, 1, 1))
	hs.hull = 0
	check("no hull: g = b = 0.5", al.tint(), Color(1, 0.5, 0.5, 1))
	check("jump zoom: 1 − 0.3k", [AsteroidLayers.jump_scale(0.0), AsteroidLayers.jump_scale(0.5),
		AsteroidLayers.jump_scale(1.0)], [1.0, 0.85, 0.7])
	var rs := RunState.new()
	rs.hazard = HazardRule.create(HazardRule.Env.ASTEROIDS, 2, 7, 2)
	al.run = rs
	al._serial = rs.arrival_serial
	check("asteroid field active", al.active(), true)
	rs.hazard = null
	rs.arrival_serial += 1  # arrived elsewhere, scene not rebuilt yet (jump-away animation)
	check("old field kept until the rebuild", al.active(), true)
	al.setup(rs, hs, null)
	check("rebuilt for the new beacon: off", al.active(), false)
	var af := AsteroidLayers.new()
	af.setup_front(al)
	al.visible = true
	af._process(0.0)
	check("front layer hidden without a jump", af.visible, false)
	al.jump_k = 0.5
	af._process(0.0)
	check("front layer shown while jumping", af.visible, true)
	af.free()
	al.free()

	print("enemy escape message / jump away")
	check("not escaping: nothing", EnemyWindow.escape_message(false, true, false, true, 10.0), [])
	check("escape message: PC above the frame (y 30), touch inside it (y 140)",
		[EnemyWindow.escape_message_pos(false), EnemyWindow.escape_message_pos(true)], [Vector2(1077, 30), Vector2(1077, 140)])
	check("neutral: nothing", EnemyWindow.escape_message(true, false, false, true, 10.0), [])
	check("dying: nothing", EnemyWindow.escape_message(true, true, true, true, 10.0), [])
	check("charging", EnemyWindow.escape_message(true, true, false, true, 10.0), ["warning_ftl_charging", false])
	check("<= 5 s: imminent, flashing", EnemyWindow.escape_message(true, true, false, true, 5.0),
		["warning_ftl_imminent", true])
	check("engines / piloting down: delayed", EnemyWindow.escape_message(true, true, false, false, 2.0),
		["warning_ftl_delayed", false])
	check("jump progress 0 for 1 s, then 2·(t − 1)", [ShipView.jump_progress(0.5), ShipView.jump_progress(1.25),
		ShipView.jump_progress(2.0)], [0.0, 0.5, 1.0])
	check("glare: l·1200 + 64 below l = 0.5, 600 at 0.5", [ShipView.jump_glare(0.1875, 200, 100, false)[2], ShipView.jump_glare(0.375, 200, 100, false)[2]], [364.0, 600.0])
	check("glare gone at progress 0.75", ShipView.jump_glare(0.75, 200, 100, false)[2], 0.0)

	print("target window info block (CombatControl::RenderTarget)")
	var ti := ShipState.new("MANTIS_FIGHTER", false)
	ti.hostile = true
	var il := EnemyWindow.info_lines(ti)
	check("no hack: class + relationship (red when hostile)", [il[0], il[2], il[3]],
		["Class: Mantis Fighter", "Relationship: Hostile", EnemyWindow.INFO_RED])
	ti.hostile = false
	check("neutral: default colour", EnemyWindow.info_lines(ti).slice(2), ["Relationship: Neutral",
		EnemyWindow.INFO_COLOR])
	var teng := ti.sys("engines")
	teng.hack_level = 1
	teng.under_attack = true
	il = EnemyWindow.info_lines(ti)
	check("engines hacked: headline + current evasion (no %), default colour",
		[il[0], il[2], il[3]], ["Engines Hacked", "Current Evasion: %d" % ti.dodge_factor(), EnemyWindow.INFO_COLOR])
	teng.hack_level = 0
	teng.under_attack = false
	var tox := ti.sys("oxygen")
	tox.hack_level = 2
	tox.under_attack = true
	il = EnemyWindow.info_lines(ti)
	check("oxygen hack pulsing: current oxygen replaces evasion, red", [il[0], il[2], il[3]],
		["Oxygen Hacked", "Current Oxygen: %d" % ti.oxygen_percentage(), EnemyWindow.INFO_RED])
	check("life sign colour: COLOR_RED x base strip, alpha 0.75", ShipView.life_sign_color(),
		Color(Color8(255, 50, 50), 0.75))



## Systems bar rebuild on install, activation button states, lock display, reactor column (rules/hud_layout.md).
func _test_hud_boxes() -> void:
	print("systems bar: a bought system appears at once (system_installed)")
	var k := ShipState.new("PLAYER_SHIP_HARD", true)
	var bar := SystemsBar.new()
	bar.setup(k)
	add_child(bar)
	var got := []
	var cb := func(_sh, id): got.append(id)
	Hooks.listen(&"system_installed", cb, 0, "test")
	var rebuilt := [0]
	bar.rebuilt.connect(func(): rebuilt[0] += 1)
	var w_before := bar.weapons_loc
	check("no mind box before", bar.columns.has("mind"), false)
	RunStore.install_system(k, "mind")
	bar._process(0.0)
	check("hook system_installed", got, ["mind"])
	check("mind column + button after install", [bar.columns.has("mind"), bar.buttons.has("mind")], [true, true])
	check("  boxes rebuilt once, weapons box moved right by 54", [rebuilt[0], bar.weapons_loc.x - w_before.x],
		[1, 54.0])
	bar._process(0.0)
	check("  no rebuild without a change", rebuilt[0], 1)
	Hooks.unlisten(&"system_installed", cb)
	bar.queue_free()

	print("activation buttons (CooldownSystemBox / CloakingBox / BatteryBox / MindBox / HackBox)")
	check("fill top L2 full / half / L4 full", [SystemButton.fill_top(2, 1.0), SystemButton.fill_top(2, 0.5),
		SystemButton.fill_top(4, 1.0)], [34, 50, 10])
	RunStore.install_system(k, "cloaking")
	var c := k.sys("cloaking")
	k.increase_power("cloaking")
	var st := SystemButton.box_state(k, "cloaking")
	check("cloak ready: base L1, button on, no fill", [st.base, st.button, st.active, st.fill],
		["button_cloaking1_base.png", "button_cloaking1", true, -1.0])
	CloakRule.turn_on(k)
	st = SystemButton.box_state(k, "cloaking")
	check("cloak running: button hidden, white fill 1.0, lock -1", [st.button, st.fill, c.ion], ["", 1.0, -1])
	check("  bars white while in use", SystemPowerColumn.bar_draw_state(c, 0), "white")
	c.timer = c.timer_goal * 0.5
	check("  fill drains", SystemButton.box_state(k, "cloaking").fill, 0.5)
	CloakRule.turn_off(k)
	st = SystemButton.box_state(k, "cloaking")
	check("cloak cooldown: button _off (inactive), no fill", [st.button, st.active, st.fill],
		["button_cloaking1", false, -1.0])
	check("  bars ion blue, lock timer steps 13 at 0, 11 after 5/12 s", [SystemPowerColumn.bar_draw_state(c, 0),
		SystemPowerColumn.lock_timer_steps(0.0), SystemPowerColumn.lock_timer_steps(5.0 / 12.0 + 0.01)],
		["ion", 13, 11])
	RunStore.install_system(k, "battery")
	var b := k.sys("battery")
	st = SystemButton.box_state(k, "battery")
	check("battery ready: button_cloaking3 at (-1, 1) on battery3 base", [st.button, st.base, st.at],
		["button_cloaking3", "button_battery3_base.png", Vector2(-1, 1)])
	b.add_lock(3)
	st = SystemButton.box_state(k, "battery")
	check("battery locked: button hidden, no fill", [st.button, st.fill], ["", -1.0])
	RunStore.install_system(k, "hacking")
	st = SystemButton.box_state(k, "hacking")
	check("hacking before launch: no box, hack base + drone button 2 px lower", [st.level, st.base, st.button,
		st.at], [-1, "button_hack_base.png", "button_hack_drone", Vector2(0, 2)])
	check("  drone button image 26 px below the base (HackBox imageStats (0, 26, 40, 81))", st.button_at,
		Vector2(0, 26))
	k.hacking = true
	st = SystemButton.box_state(k, "hacking")
	check("hacking drone launched: pulse button on cloaking base, image at (0, -9), no extra offset",
		[st.base.begins_with("button_cloaking"), st.button.begins_with("button_cloaking"), st.at, st.button_at],
		[true, true, Vector2(0, -9), Vector2.ZERO])
	k.hacking = false
	st = SystemButton.box_state(k, "mind")
	check("mind: L2 base, button_cloaking2", [st.base, st.button], ["button_cloaking2_base.png", "button_cloaking2"])
	k.mind_armed = true
	check("  armed -> selected", SystemButton.box_state(k, "mind").selected, true)

	print("clone queue box (CloneBox)")
	RunStore.install_system(k, "clonebay")
	var cbs := k.sys("clonebay")
	check("empty queue: height modifier 0", CloneQueueBox.height_modifier(k), 0)
	var dead: Array = []
	for i in 5:
		dead.append(CrewMember.new())
	k.clone_queue = dead.slice(0, 1)
	check("1 queued: modifier 29, solo box at P + (-29, -20)", [CloneQueueBox.height_modifier(k),
		CloneQueueBox.box_images(1, Vector2(100, 100))], [29, [["clonebar_small_solo.png", Vector2(71, 80)]]])
	check("3 slots: bottom / middle / top", CloneQueueBox.box_images(3, Vector2(100, 100)),
		[["clonebar_small_bottom.png", Vector2(71, 86)], ["clonebar_small_middle.png", Vector2(71, 63)],
		["clonebar_small_top.png", Vector2(71, 34)]])
	k.clone_queue = dead
	check("5 queued: modifier 75; anchor (35, -8 per level, max 24); slot 2 centre", [CloneQueueBox.height_modifier(k),
		CloneQueueBox.anchor(cbs, Vector2.ZERO), CloneQueueBox.slot_centre(Vector2(100, 100), 2)],
		[75, Vector2(35, -mini(maxi(cbs.get_level(), 1) * 8, 24)), Vector2(97, 53)])
	k.clone_death_timer = 1.5
	check("death progress = timer / 3", CloneQueueBox.death_progress(k), 0.5)
	k.clone_death_timer = 0.0
	k.clone_queue = []

	print("reactor column")
	check("bar 0 top 686, bar 9 top 605 (vanilla screenshot)", [ReactorColumn.bar_rect(0).position.y,
		ReactorColumn.bar_rect(9).position.y], [686.0, 605.0])
	var both := SystemsBar.masked_wire_image([9 * 8 - 1, 9])
	var bright_only := SystemsBar.masked_wire_image([9])
	if both and bright_only:
		var top_px := Vector2i(15, 20)  # wire_full row 20 (y 417): the hatched edge's top end
		check("bright wire alone would show the top stub (old white strip)", bright_only.get_pixelv(top_px).a > 0.0,
			true)
		check("  with the dim pass's stencil it is hidden", both.get_pixelv(top_px).a, 0.0)
		check("  bright part starts at y 704 - 9 free at x 52 (vanilla: 686 with 2 free)",
			[both.get_pixel(19, 695 - 397).a > 0.0, both.get_pixel(19, 694 - 397).a > 0.0], [true, false])


## rules/hud_layout.md "Screen shake" (CommandGui::OnLoop / UpdateShake, SpaceManager::GetScreenShake): timer =
## min(hull damage / 5, 1) s (set, not added; a repair stops it), an ASB shot clamps it to [0.05, 1]; offsets are
## whole-pixel targets in −3..2 reached in 5 frames, back to (0, 0) in 10 frames; targets move by the offset and
## end exactly where they were (a layout write while shaking becomes the new base).
func _test_screen_shake() -> void:
	print("screen shake")
	var sk := ScreenShake.new()
	sk.on_hull_damage(3)
	check("3 hull damage -> 0.6 s", snappedf(sk.timer, 0.001), 0.6)
	sk.on_hull_damage(10)
	check("10 hull damage -> capped at 1 s", sk.timer, 1.0)
	sk.on_hull_damage(1)
	check("a later 1 damage SETS 0.2 s", snappedf(sk.timer, 0.001), 0.2)
	sk.on_hull_damage(0)
	check("0 damage: unchanged", snappedf(sk.timer, 0.001), 0.2)
	sk.on_hull_damage(-2)
	check("repair (DamageHull < 0): negative timer, shake over", sk.timer < 0.0, true)
	sk.timer = 0.0
	sk.on_pds_shot()
	check("ASB shot from 0 -> 0.05 s", snappedf(sk.timer, 0.001), 0.05)
	sk.timer = 0.5
	sk.on_pds_shot()
	check("ASB shot keeps 0.5 s", sk.timer, 0.5)
	# Motion: seeded, 0.5 s of shake then back to rest.
	sk.rng.seed = 12
	sk.timer = 0.5
	sk.step()
	var d0 := sk.desired
	var ok_range := d0.x >= -3 and d0.x <= 2 and d0.y >= -3 and d0.y <= 2 and d0 == d0.round()
	check("first target: whole pixels in -3..2", ok_range, true)
	check("moves 1/5 of the way per frame", sk.current.is_equal_approx(d0 / 5.0), true)
	var reached := false
	for i in 4:
		sk.step()
		reached = reached or sk.current.round() == d0
	check("target reached (rounded) within 5 frames, then a new one is picked", reached, true)
	var seen_range := true
	var frames := 0
	while sk.active() and frames < 200:
		sk.step()
		frames += 1
		var c := sk.current
		if c.x < -3.0 or c.x > 2.0 or c.y < -3.0 or c.y > 2.0:
			seen_range = false
	check("offsets stay within -3..2", seen_range, true)
	check("settles back at (0, 0) after the timer (~0.5 s + 10 frames)", [sk.current, frames > 20 and frames < 60],
		[Vector2.ZERO, true])
	# Applying to nodes: offset added, layout writes respected, exact base at the end.
	var holder := Node2D.new()
	add_child(holder)
	var box := Control.new()
	box.position = Vector2(100, 50)
	holder.add_child(box)
	var n2 := Node2D.new()
	n2.position = Vector2(7, 9)
	holder.add_child(n2)
	sk.targets = func() -> Array: return [box, n2]
	sk.timer = 0.3
	sk.current = Vector2(2, -1)
	sk.apply()
	check("targets moved by the offset", [box.position, n2.position], [Vector2(102, 49), Vector2(9, 8)])
	box.position = Vector2(300, 60)  # a layout pass while shaking
	sk.current = Vector2(-3, 1)
	sk.apply()
	check("layout write = new base", box.position, Vector2(297, 61))
	sk.restore()
	check("restore(): unshaken positions", [box.position, n2.position], [Vector2(300, 60), Vector2(7, 9)])
	sk.current = Vector2(1, 1)
	sk.apply()
	sk.current = Vector2.ZERO
	sk.desired = Vector2.ZERO
	sk.timer = 0.0
	sk.apply()
	check("shake over: exact base again", [box.position, n2.position], [Vector2(300, 60), Vector2(7, 9)])
	# Sources through _process: the player's hull damage and the ASB's queueScreenShake.
	var me := ShipState.new("PLAYER_SHIP_HARD", true)
	var hz := HazardRule.create(HazardRule.Env.PDS, 0, 3, 2)
	sk.setup(me, sk.targets, func() -> HazardRule: return hz)
	me.take_hull_damage(4)
	check("take_hull_damage records iLastDamage", me.last_damage, 4)
	sk._process(0.0)
	check("player hull damage 4 -> timer 0.8, damage consumed", [snappedf(sk.timer, 0.001), me.last_damage], [0.8, 0])
	sk.timer = 0.0
	var en := ShipState.new("REBEL_FAT", false)
	for i in 80:
		hz.tick(0.1, [me, en])
	check("an ASB shot queues the shake (UpdatePDS)", hz.pds_shots > 0 and hz.screen_shake_queued, true)
	sk._process(0.0)
	check("  read once: timer >= 0.05, flag cleared", [sk.timer >= 0.05, hz.screen_shake_queued], [true, false])
	# The TARGET frame layer (main.gd adds enemy_window_back to hud_root BEFORE its setup) must cover the frame: a
	# Control is culled by its own size rect, and a 0 × 0 layer at (0, 0) vanished whenever the shake offset had a
	# negative axis (the frame flickered off while the enemy ship and status kept drawing).
	var hud := Control.new()
	hud.size = HudLayout.FRAME
	add_child(hud)
	var back := EnemyWindow.new()
	hud.add_child(back)
	back.setup(en, me, false)
	var front := EnemyWindow.new()
	front.setup(en, me, true)
	hud.add_child(front)
	check("frame layer set up in the tree: full frame size", [back.position, back.size], [Vector2.ZERO,
		HudLayout.FRAME])
	check("status layer set up before the tree: full frame size", front.size, HudLayout.FRAME)
	var space := Control.new()  # stands for the enemy Space container (its clip rect is container-local)
	space.position = Vector2(882, 54)
	space.size = Vector2(380, 529)
	hud.add_child(space)
	sk.setup(null, func() -> Array: return [back, space, front])
	var screen := Rect2(Vector2.ZERO, HudLayout.FRAME)
	var together := true
	var visible_rect := true
	for off in [Vector2(-3, -3), Vector2(2, -3), Vector2(-3, 2), Vector2(2, 2)]:
		sk.timer = 0.3
		sk.current = off
		sk.apply()
		together = together and back.position == off and front.position == off \
			and space.position == Vector2(882, 54) + off
		visible_rect = visible_rect and Rect2(back.position, back.size).intersects(screen)
	check("frame, status and ship view move together by the offset", together, true)
	check("  the frame's visibility rect stays on screen at every offset", visible_rect, true)
	sk.current = Vector2.ZERO
	sk.desired = Vector2.ZERO
	sk.timer = 0.0
	sk.apply()
	check("  shake over: all at rest, sizes unchanged", [back.position, front.position, space.position, back.size],
		[Vector2.ZERO, Vector2.ZERO, Vector2(882, 54), HudLayout.FRAME])
	hud.queue_free()
	holder.queue_free()
	sk.free()


## rules/artillery.md "Art": ShipManager::RenderWeapons pads the weapons to 4 and appends the artillery weapons,
## so artillery n sits on mount max(weapons, 4) + n and is drawn with its own weapon art (flagship: boss_1..4 on
## mounts 4-7; FED cruiser: artillery_fed = weapons/blank.png on mount 4, the cannon being part of the hull image).
func _test_artillery_art() -> void:
	print("artillery art")
	var boss := ShipState.new("BOSS_1", false)
	check("flagship artillery on mounts 4-7", boss.artillery.map(func(w): return w.mount_index), [4, 5, 6, 7])
	check("  mounts exist in the layout", boss.mounts.size() >= 8, true)
	check("  art = boss_1..4 strips", boss.artillery.map(func(w): return String(w.bp.get("weapon_art", ""))),
		["boss_1", "boss_2", "boss_3", "boss_4"])
	var fed := ShipState.new("PLAYER_SHIP_FED", true)
	check("FED artillery on mount 4 (649, 200)", [fed.artillery[0].mount_index, fed.mounts[4].pos],
		[4, Vector2(649, 200)])
	var sp := Space.new()
	add_child(sp)
	sp.setup(boss)
	var w: WeaponState = boss.artillery[0]
	check("the ship view slides / draws the artillery weapons too", sp.view.weapon_slide.has(w), true)
	w.powered = true
	w.charge = w.max_charge(0)
	check("charged artillery shows its charged frame", WeaponArt.frame_index(w, 0), int(w.anim.charged_frame))
	sp.queue_free()

