extends Node
## Tests for rules/races.md: zoltan bonus power and death explosion, lanius O2 drain, slug vision, crystal lockdown,
## suffocation threshold, human skill caps, race sounds. Run:
##   godot --headless --path godot res://tests/test_races.tscn

const Harness := preload("res://tests/harness.gd")

const DT := 1.0 / 60.0

var fails := 0


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func near(name: String, got: float, want: float, tol: float) -> void:
	check("%s ~= %.2f (+/-%.2f) [%.2f]" % [name, want, tol, got], absf(got - want) <= tol, true)


func step(s: ShipState) -> void:
	s.tick(DT * GameClock.BASE)


func run(s: ShipState, seconds: float) -> void:
	var t := 0.0
	while t < seconds - 1e-6:
		step(s)
		t += DT


func kestrel() -> ShipState:
	var s := ShipState.new("PLAYER_SHIP_HARD", true)
	s.hostile = true
	return s


## Puts a new crew member of `race` on a free slot of `room` (no walking).
func put(s: ShipState, race: String, owned: bool, room: int) -> CrewMember:
	var c := CrewMember.new(race, owned)
	c.place(s, room, s.graph.find_slot(room, c))
	s.crew.append(c)
	s.crew_changed()
	return c


## A room of the ship with no system.
func empty_room(s: ShipState) -> int:
	for r in s.layout.rooms:
		if s.system_in_room(r.id) == null:
			return r.id
	return -1


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	_skills()
	_zoltan_power()
	_zoltan_weapons()
	_zoltan_blast()
	_lanius()
	_suffocation()
	_slug()
	_lockdown()
	_enemy_crystals()
	_multipliers()
	_life_detection()
	_door_rescale_not_a_hit()


func _skills() -> void:
	print("Human skill caps")
	var h := CrewMember.new("human")
	var e := CrewMember.new("engi")
	check("human pilot cap 26", h.skill_cap("pilot"), 26)
	check("human weapons cap 116", h.skill_cap("weapons"), 116)
	check("human combat cap 14", h.skill_cap("combat"), 14)
	check("engi pilot cap 30 (default)", e.skill_cap("pilot"), 30)
	h.skills["pilot"] = 13
	e.skills["pilot"] = 13
	check("human level 2 at 13", h.skill_level("pilot"), 2)
	check("engi level 1 at 13", e.skill_level("pilot"), 1)
	h.skills["pilot"] = 25
	h.add_skill("pilot")
	h.add_skill("pilot")
	check("human pilot stops at 26", h.skills["pilot"], 26)
	check("human level 3 at 26", h.skill_level("pilot"), 3)
	check("convert at old cap", CrewMember.convert_progress(30, 30, 26), 26)
	check("convert at half", CrewMember.convert_progress(15, 30, 26), 13)
	check("convert other x0.9", CrewMember.convert_progress(20, 30, 26), 18)


func _zoltan_power() -> void:
	print("Zoltan bonus power")
	var s := kestrel()
	var sh := s.sys("shields")
	check("shields start at 2 reactor bars", sh.power, 2)
	var free0 := s.reactor_free()
	var z := put(s, "energy", true, sh.room)
	step(s)
	check("bonus 1", sh.bonus_power, 1)
	check("a reactor bar is freed", sh.power, 1)
	check("effective power still 2", sh.effective_power(), 2)
	check("reactor free +1", s.reactor_free(), free0 + 1)
	check("still 1 shield layer max", s.max_shield_layers(), 1)
	check("bar 1 drawn yellow", sh.bar_state(1), "bonus")
	check("bar 0 green", sh.bar_state(0), "on")
	s.ion_system("shields", 1)
	step(s)
	check("ion keeps the bonus", sh.bonus_power, 1)
	sh.ion = 0
	# Leaves: the reactor bar comes back (CheckForRepower).
	z.place(s, empty_room(s), s.graph.find_slot(empty_room(s), z))
	step(s)
	check("left: bonus 0", sh.bonus_power, 0)
	check("left: reactor bar re-added", sh.power, 2)
	check("left: reactor free back", s.reactor_free(), free0)

	print("Walking vs standing zoltan, wish")
	s = kestrel()
	var en := s.sys("engines")
	en.override_level = 4
	en.power = 2
	en.user_power = 2
	var w := put(s, "energy", true, en.room)
	w.state = CrewMember.State.WALKING  # walking through (not AtFinalGoal)
	s.update_bonus_power()
	check("walking zoltan gives bonus", en.bonus_power, 1)
	check("walking zoltan: wish unchanged", en.user_power, 2)
	check("engines effective 3", en.effective_power(), 3)
	w.state = CrewMember.State.IDLE
	s.update_bonus_power()
	check("standing zoltan raises the wish", en.user_power, 3)
	var w2 := put(s, "energy", true, en.room)
	s.update_bonus_power()
	check("two zoltans stack", en.bonus_power, 2)
	check("engines effective 4", en.effective_power(), 4)
	s.damage_system("engines", 3)
	check("bonus capped at undamaged bars", en.bonus_power, 1)
	check("reactor bars gone", en.power, 0)
	s.update_bonus_power()
	check("bonus capped next frame too", en.bonus_power, 1)
	s.damage_system("engines", 1)
	s.update_bonus_power()
	check("destroyed system: 0 bonus", en.bonus_power, 0)
	check("increase refused while bonus fills max", (func():
		s.repair_system("engines", 4)
		s.update_bonus_power()
		var r := ""
		while true:
			r = s.increase_power("engines")
			if r != "ok":
				break
		return en.power + en.bonus_power).call(), 4)
	w2.hp = 0  # not removed yet: dying zoltans still count
	s.update_bonus_power()
	check("dying zoltan still counts", en.bonus_power, 2)

	print("Who gives nothing")
	s = kestrel()
	var pi := s.sys("pilot")
	put(s, "energy", true, pi.room)
	s.update_bonus_power()
	check("subsystem (pilot) unaffected", pi.bonus_power, 0)
	var ox := s.sys("oxygen")
	put(s, "energy", false, ox.room)  # an intruder zoltan
	s.update_bonus_power()
	check("intruder zoltan gives nothing", ox.bonus_power, 0)
	var med := s.sys("medbay")
	med.power = 0
	med.user_power = 0
	put(s, "energy", true, med.room)
	s.update_bonus_power()
	check("medbay powered only by a zoltan", med.effective_power(), 1)


func _zoltan_weapons() -> void:
	print("Zoltan in weapons (slot order)")
	var s := kestrel()
	var ws := s.sys("weapons")
	for w in s.weapons:
		s.depower_weapon(w)
	var w0 := s.weapons[0]
	check("weapon 0 needs power", w0.power_cost() > 0, true)
	var free0 := s.reactor_free()
	for i in w0.power_cost():
		put(s, "energy", true, ws.room)
	step(s)
	check("weapon 0 bonus = its power", w0.bonus_power, w0.power_cost())
	check("fully covered weapon powered automatically", w0.powered, true)
	check("no reactor bar used", s.reactor_free(), free0)
	# One zoltan leaves: the weapon is depowered, then re-powered with a reactor bar next frame.
	var z: CrewMember = s.crew[s.crew.size() - 1]
	z.place(s, empty_room(s), s.graph.find_slot(empty_room(s), z))
	if w0.power_cost() > 1:
		step(s)
		check("bonus shrank -> depowered", w0.powered, false)
		step(s)
		check("re-powered with reactor bars", w0.powered, true)
		check("one reactor bar used", s.reactor_free(), free0 - 1)
	else:
		step(s)
		step(s)
		check("no bonus left", w0.bonus_power, 0)


func _zoltan_blast() -> void:
	print("Zoltan death explosion")
	var s := kestrel()
	var r := empty_room(s)
	var z := put(s, "energy", true, r)
	var friend := put(s, "human", true, r)
	var foe := put(s, "human", false, r)
	var far := put(s, "human", false, s.sys("shields").room)
	z.hp = 0.0
	step(s)
	near("intruder in the room -15 HP", foe.hp, 85.0, 1.5)  # (may also take a crew shot)
	check("own-side crew untouched", friend.hp >= 99.0, true)
	check("intruder elsewhere untouched", far.hp >= 99.0, true)
	var hp1 := foe.hp
	step(s)
	check("only once", foe.hp >= hp1 - 7.5, true)
	# Enemy zoltan intruder dying on the player ship hurts the player crew around it.
	s = kestrel()
	r = empty_room(s)
	var ez := put(s, "energy", false, r)
	var mine := put(s, "engi", true, r)
	ez.hp = 0.0
	step(s)
	check("player crew hurt by an enemy zoltan", mine.hp <= 86.0, true)


func _lanius() -> void:
	print("Lanius")
	var l := CrewMember.new("anaerobic")
	near("speed 0.85", l.move_speed(), 68.0, 0.01)
	check("cannot suffocate", l.can_suffocate(), false)
	check("death sound shrikeDeath", l.death_sound(), "shrikeDeath")
	check("shrikeDeath in dlcSounds.xml", FtlData.text("data/dlcSounds.xml").contains("<shrikeDeath"), true)
	# O2 drain: isolated room (all doors closed), with and without a lanius.
	var a := kestrel()
	var b := kestrel()
	for s in [a, b]:
		s.env.set_all_doors(false, true)
	var r := empty_room(a)
	put(b, "anaerobic", true, r)
	a.env.oxygen[r] = 80.0
	b.env.oxygen[r] = 80.0
	run(a, 1.0)
	run(b, 1.0)
	near("each lanius drains 8 %/s", a.env.oxygen[r] - b.env.oxygen[r], 8.0, 0.4)
	check("lanius room counted like a breach", b.env.lanius_per_room().get(r, 0), 1)
	check("no breach warning light", ShipView.warning_light_rooms(b).has(r), false)
	# Fall-off: an open door to a neighbour room drains it at x0.75.
	var c := kestrel()
	c.env.set_all_doors(false, true)
	var di := -1
	for i in c.env.doors.size():
		var d: Dictionary = c.env.doors[i]
		if not d.airlock and (d.left == r or d.right == r):
			di = i
			break
	c.env.set_door(di, true)
	var nb: int = c.env.doors[di].left if c.env.doors[di].right == r else c.env.doors[di].right
	put(c, "anaerobic", true, r)
	check("neighbour at distance 1", c.env.room_distances(r).get(nb, -1), 1)


func _suffocation() -> void:
	print("Suffocation at O2 <= 5")
	var s := kestrel()
	var c := s.crew[0]
	c.hp = 100.0
	s.env.oxygen[c.room] = 5.0
	s.env._tick_crew(1.0)
	near("O2 = 5: 6.4 HP/s", c.hp, 93.6, 0.01)
	c.hp = 100.0
	s.env.oxygen[c.room] = 5.1
	s.env._tick_crew(1.0)
	check("O2 = 5.1: no damage", c.hp, 100.0)
	var cr := put(s, "crystal", true, c.room)
	s.env.oxygen[c.room] = 0.0
	s.env._tick_crew(1.0)
	near("crystal 3.2 HP/s", cr.hp, 125.0 - 3.2, 0.01)
	var lan := put(s, "anaerobic", true, c.room)
	s.env._tick_crew(1.0)
	check("lanius never suffocates", lan.hp, 100.0)


func _slug() -> void:
	print("Slug vision")
	var s := kestrel()
	s.damage_system("sensors", 9)
	var r := s.sys("shields").room
	for c in s.crew.duplicate():
		s.crew.erase(c)
	var all := s.blacked_out_rooms()
	check("sensors destroyed: every room blacked out", all.size(), s.layout.rooms.size())
	var sl := put(s, "slug", true, r)
	var nbs := s.graph.room_neighbors(r)
	check("shields room has neighbours", nbs.size() > 0, true)
	check("own room not a neighbour", nbs.has(r), false)
	var blk := s.blacked_out_rooms()
	var seen := true
	for n in nbs:
		if blk.has(n):
			seen = false
	check("neighbours of the slug's room visible", seen, true)
	check("other rooms still blacked out", blk.size(), s.layout.rooms.size() - 1 - nbs.size())
	# Neighbours are geometric: every neighbour rect touches the room rect.
	var rr := s.room_rect(r)
	var touch := true
	for n in nbs:
		if not rr.grow(1).intersects(s.room_rect(n)):
			touch = false
	check("neighbours touch the room", touch, true)
	sl.player_owned = false
	sl.mind_controlled = false
	check("enemy-owned slug reveals nothing", s.blacked_out_rooms().size(), s.layout.rooms.size())
	# Boarding an enemy ship with player sensors at 0.
	var p := kestrel()
	var e := ShipState.new("PLAYER_SHIP_HARD", false)
	e.opponent = p
	p.opponent = e
	p.damage_system("sensors", 9)
	var er := e.sys("shields").room
	put(e, "slug", true, er)
	var eb := e.blacked_out_rooms()
	var ok := not eb.has(er)
	for n in e.graph.room_neighbors(er):
		if eb.has(n):
			ok = false
	check("slug aboard the enemy reveals its room and neighbours", ok, true)
	check("slug is mind-control immune", CrewMember.new("slug").is_telepathic(), true)


func _lockdown() -> void:
	print("Crystal lockdown")
	var s := kestrel()
	var r := s.sys("shields").room
	var cr := put(s, "crystal", true, r)
	check("player crystal has power", cr.has_power(), true)
	check("not ready at start", cr.power_ready(), false)
	run(s, 49.0)
	check("not ready at 49 s", cr.power_ready(), false)
	run(s, 1.1)
	check("ready at 50 s", cr.power_ready(), true)
	check("activate", cr.activate_power(s), true)
	check("charge reset", cr.power_charge, 0.0)
	var doors := []
	for i in s.env.doors.size():
		var d: Dictionary = s.env.doors[i]
		if d.left == r or d.right == r:
			doors.append(i)
	check("room has doors", doors.size() > 0, true)
	var d0: Dictionary = s.env.doors[doors[0]]
	near("door locked 12 s", d0.lockdown, 12.0, 0.001)
	check("door health 50", d0.health, 50)
	var own := s.crew[0]
	check("sealed for own crew", s.graph.is_sealed(d0, own), true)
	var foe := CrewMember.new("human", false)
	check("sealed for intruders", s.graph.is_sealed(d0, foe), true)
	d0.open = true
	check("sealed even when open", s.graph.is_sealed(d0, own), true)
	check("room locked (shards)", LockdownRule.room_locked(s, r), true)
	check("shards: 3 per tile side + 1 per door",
		s.lockdowns.size(), 3 * 2 * (int(s.room_rect(r).size.x / 35) + int(s.room_rect(r).size.y / 35)) + doors.size())
	var base_after := 0
	run(s, 11.9)
	check("still locked at 11.9 s", d0.lockdown > 0.0, true)
	run(s, 0.2)
	check("unlocked after 12 s", d0.lockdown, 0.0)
	check("health restored", d0.health, d0.base)
	check("not sealed for own crew any more", s.graph.is_sealed(d0, own), false)
	run(s, 1.0)
	check("shards gone after ~12 s", s.lockdowns.size(), 0)
	check("room no longer locked", LockdownRule.room_locked(s, r), false)
	# Breaking a locked-down door.
	cr.reset_power()
	cr.activate_power(s)
	for i in 49:
		s.env.damage_door(doors[0])
	check("49 hits: still locked", d0.lockdown > 0.0, true)
	s.env.damage_door(doors[0])
	check("50th hit ends that door's lockdown", d0.lockdown, 0.0)
	check("forced open 7 s", d0.forced, 7.0)
	check("health back to normal", d0.health == base_after or d0.health == d0.base, true)
	if doors.size() > 1:
		check("other doors stay locked", s.env.doors[doors[1]].lockdown > 0.0, true)
	# BOMB_LOCK damage routes to the same lockdown.
	var s2 := kestrel()
	var dmg := Damage.new()
	dmg.lockdown = true
	var r2 := s2.sys("engines").room
	s2.apply_damage(r2, dmg, s2.rng)
	check("BOMB_LOCK locks the room", LockdownRule.room_locked(s2, r2), true)
	# Hotkey P / crew box button through CrewControl.
	var s3 := kestrel()
	var c3 := put(s3, "crystal", true, s3.sys("engines").room)
	var cc := CrewControl.new(s3, null, func(_s, p): return p, func(_s): return Rect2())
	c3.selected = true
	check("P while charging: nothing", cc.hotkey(KEY_P) and not LockdownRule.room_locked(s3, c3.room), true)
	c3.reset_power()
	cc.hotkey(KEY_P)
	check("P casts the lockdown", LockdownRule.room_locked(s3, c3.room), true)


func _multipliers() -> void:
	print("Race multipliers applied (HP, speed, repair, fire-fight, combat damage)")
	var want := {  # race: [hp, speed x, repair x, fire-fight x, damage x]
		"human": [100.0, 1.0, 1.0, 1.2, 1.0], "engi": [100.0, 1.0, 2.0, 1.2, 0.5],
		"mantis": [100.0, 1.2, 0.5, 1.2, 1.5], "slug": [100.0, 1.0, 1.0, 1.2, 1.0],
		"rock": [150.0, 0.5, 1.0, 2.0, 1.0], "crystal": [125.0, 0.8, 1.0, 1.0, 1.0],
		"energy": [70.0, 1.0, 1.0, 1.2, 1.0], "anaerobic": [100.0, 0.85, 1.0, 1.2, 1.0]}
	for r in want:
		var c := CrewMember.new(r)
		var w: Array = want[r]
		var got := [c.max_hp, c.move_speed() / CrewMember.BASE_SPEED, c.repair_speed(false),
			c.repair_speed(true) / c.repair_speed(false), c.damage_mult()]
		var ok := true
		for i in w.size():
			if absf(float(got[i]) - float(w[i])) > 0.001:
				ok = false
		check("%s %s" % [r, str(got)], ok, true)
	check("rock cannot burn", CrewMember.new("rock").can_burn(), false)
	check("crystal suffocation x0.5", CrewMember.new("crystal").suffocation_mult(), 0.5)
	# Hits really use the multiplier: mantis max roll 7 x 1.5.
	near("mantis hit 10.5", CrewMember.new("mantis").roll_hit(1.0), 10.5, 0.001)
	near("engi hit 3.5", CrewMember.new("engi").roll_hit(1.0), 3.5, 0.001)


func _life_detection() -> void:
	print("Life detection (slug crew / LIFE_SCANNER) and mind control in blacked-out rooms")
	var p := kestrel()
	var e := ShipState.new("PLAYER_SHIP_HARD", false)
	e.opponent = p
	p.opponent = e
	p.damage_system("sensors", 9)
	var er := e.sys("shields").room
	check("enemy room blacked out", e.blacked_out_rooms().has(er), true)
	check("no slug: no life detection", e.player_detects_life(), false)
	check("mind control refused in a blacked-out room", MindRule.blocked_by_blackout(e, er), true)
	p.mind_armed = true
	MindRule.room_clicked(p, e, er)
	check("refused click queues nobody and stays armed", p.mind_armed and p.mind_queue.is_empty(), true)
	put(p, "slug", true, p.sys("pilot").room)
	check("slug crew aboard: life detected on the enemy", e.player_detects_life(), true)
	check("still blacked out (life signs only)", e.blacked_out_rooms().has(er), true)
	check("mind control allowed", MindRule.blocked_by_blackout(e, er), false)
	var q := kestrel()
	q.augments.append("LIFE_SCANNER")
	check("LIFE_SCANNER detects life", q.player_detects_life(), true)


func _door_rescale_not_a_hit() -> void:
	print("Doors: losing the manning boost is not a hit (no red tint)")
	var s := kestrel()
	var v := ShipView.new()
	add_child(v)
	v.setup(s)
	var di := 0
	s.env.doors[di].base = 12
	s.env.doors[di].health = 12
	v._update_doors(0.016)
	s.env.doors[di].base = 4  # blast level dropped (manning crew walked away)
	s.env.doors[di].health = 4
	v._update_doors(0.016)
	check("rescale: no hit tint", float(v._doors_anim[di].hit), 0.0)
	s.env.damage_door(di)
	v._update_doors(0.016)
	check("a real hit tints", float(v._doors_anim[di].hit) > 0.0, true)
	v.queue_free()


func _enemy_crystals() -> void:
	print("Enemy crystals")
	var never := 0
	var n := 400
	for i in n:
		var c := CrewMember.new("crystal", false)
		check("enemy crystal starts at charge 10", c.power_charge, 10.0) if i == 0 else null
		if c.power_max == INF:
			never += 1
	near("about half can never lock down", float(never) / n, 0.5, 0.08)
	var s := kestrel()
	var r := empty_room(s)
	var ec := put(s, "crystal", false, r)
	ec.power_max = 50.0
	ec.power_charge = 50.0
	ec.hp = ec.max_hp * 0.5
	check("AI: not at 50 % health", CrewCombat.enemy_lockdown(s, ec), false)
	ec.hp = ec.max_hp
	check("AI: casts when healthy and ready", CrewCombat.enemy_lockdown(s, ec), true)
	ec.power_charge = 50.0
	check("AI: no re-cast in a locked room", CrewCombat.enemy_lockdown(s, ec), false)
	var pc := put(s, "crystal", true, empty_room(s))
	pc.reset_power()
	check("AI never casts for player crystals", CrewCombat.enemy_lockdown(s, pc), false)
	# Full fight: an enemy crystal boarder fighting a player crew casts after a hit.
	var s2 := kestrel()
	var rr := s2.sys("shields").room
	put(s2, "human", true, rr)
	var e2 := put(s2, "crystal", false, rr)
	e2.power_max = 50.0
	e2.power_charge = 50.0
	run(s2, 4.0)
	check("enemy crystal locked down its room in a fight", e2.power_charge < 50.0, true)
