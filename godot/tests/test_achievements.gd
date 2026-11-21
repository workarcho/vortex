extends Node
## Achievements (rules/save_and_profile.md §4): SetAchievement (ship gating by layout, once / multiDifficulty with
## the best difficulty), CheckShipAchievements (two of three -> layout B), the Lanius unlock (exactly five type A),
## the run flags and the sector 5 / sector 8 checks (AdvanceWorldLevel / SetSectorEight), the per-frame checks
## (ShipManager / WorldManager OnLoop), the fight outcome checks, the hook-driven triggers (dodges, store,
## upgrades, weapons, drones, crew deaths, beams), the popup queue and the hangar achievement tooltip text.
## Works on an in-memory profile (PlayerProfile.persist off; never the player's profile.sav). Run:
##   godot --headless --path godot res://tests/test_achievements.tscn

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
	FtlData.muted = true
	var old := [SaveGame.path, SaveGame.persist, PlayerProfile.path, PlayerProfile.persist]
	SaveGame.path = "user://test_ach_continue.sav"
	SaveGame.persist = false
	PlayerProfile.path = "user://test_ach_profile.sav"
	PlayerProfile.persist = false
	_profile_rules()
	_ship_gating()
	_sector_checks()
	_frame_checks()
	_hook_triggers()
	_outcomes()
	_popups()
	_tooltip_text()
	await _hangar_hover()
	_ship_list_hover()
	_stats_hover()
	_pause_hover()
	SaveGame.path = old[0]
	SaveGame.persist = old[1]
	PlayerProfile.path = old[2]
	PlayerProfile.persist = old[3]
	PlayerProfile.reset_current()
	RunState.current = null
	AchievementTracker.popups.clear()
	Settings.thaw()


func _fresh() -> PlayerProfile:
	var p := PlayerProfile.new()
	PlayerProfile.reset_current(p)
	AchievementTracker.popups.clear()
	return p


func _run_with(bp: String, diff := EventEngine.Difficulty.NORMAL) -> RunState:
	var r := RunState.new_run(7, bp, diff)
	RunState.current = r
	return r


func _profile_rules() -> void:
	print("SetAchievement / CheckShipAchievements / UnlockShip (profile)")
	var p := _fresh()
	check("non-multi: earned once", [p.set_achievement("ACH_WIN_EASY", 0), p.set_achievement("ACH_WIN_EASY", 2)],
		[true, false])
	check("non-multi keeps its first difficulty", p.achievements["ACH_WIN_EASY"], 0)
	check("multi: earned again higher", [p.set_achievement("ACH_SECTOR_5", 0), p.set_achievement("ACH_SECTOR_5", 2),
		p.set_achievement("ACH_SECTOR_5", 1)], [true, true, false])
	check("multi keeps the best difficulty", p.achievements["ACH_SECTOR_5"], 2)
	check("Kestrel ship achievements", PlayerProfile.ship_achievement_ids(0),
		["ACH_UNITED_FEDERATION", "ACH_FULL_ARSENAL", "ACH_TOUGH_SHIP"])
	var counts := []
	for id in 10:
		counts.append(PlayerProfile.ship_achievement_ids(id).size())
	check("three per ship", counts, [3, 3, 3, 3, 3, 3, 3, 3, 3, 3])
	p.set_achievement("ACH_FULL_ARSENAL", 1)
	p.check_ship_achievements(0)
	check("one ship achievement: no layout B", p.is_unlocked(0, 1), false)
	p.set_achievement("ACH_TOUGH_SHIP", 1)
	p.check_ship_achievements(0)
	check("two ship achievements: layout B", p.is_unlocked(0, 1), true)
	# LoadProfile runs CheckShipAchievements for every ship.
	var q := PlayerProfile.new()
	q.achievements = {"ACH_ROBOTIC": 0, "ACH_IONED": 1}
	for id in 10:
		q.check_ship_achievements(id, true)
	check("load: Engi B from its achievements", q.is_unlocked(3, 1), true)
	# Victory marker -> the next ship of the chain (not from the Kestrel / Federation / Crystal / Lanius).
	q.set_ship_victory(3, 0, 1)
	q.check_ship_achievements(3, true)
	check("Engi victory unlocks the Federation", q.is_unlocked(4, 0), true)
	var before := q.unlocked.size()
	q.set_ship_victory(0, 0, 1)
	q.check_ship_achievements(0, true)
	check("Kestrel victory: no chain unlock (the Engi comes from sector 5)", q.unlocked.size(), before)
	# ScoreKeeper::UnlockShip: exactly five type A -> Lanius.
	var l := PlayerProfile.new()
	for id in [3, 4, 7]:
		l.unlock_ship(id, 0, true)
	check("four type A: no Lanius", l.is_unlocked(9, 0), false)
	l.unlock_ship(2, 0, true)
	check("fifth type A: Lanius", l.is_unlocked(9, 0), true)
	var m := PlayerProfile.new()
	for id in [1, 2, 3, 4, 5, 6]:
		m.unlocked["%d:0" % id] = true  # seven A already (0 + six), set directly
	m.unlock_ship(7, 0, true)
	check("eighth type A: not exactly five, no Lanius", m.is_unlocked(9, 0), false)


func _ship_gating() -> void:
	print("Ship gating (GetShipMarker) and difficulty")
	var p := _fresh()
	var r := _run_with("PLAYER_SHIP_HARD_2", EventEngine.Difficulty.HARD)
	check("current ship", AchievementTracker.current_ship, "PLAYER_SHIP_HARD_2")
	check("layout_of", [AchievementTracker.layout_of("PLAYER_SHIP_HARD", "PLAYER_SHIP_HARD"),
		AchievementTracker.layout_of("PLAYER_SHIP_HARD", "PLAYER_SHIP_HARD_2"),
		AchievementTracker.layout_of("PLAYER_SHIP_HARD", "PLAYER_SHIP_HARD_3"),
		AchievementTracker.layout_of("PLAYER_SHIP_HARD", "PLAYER_SHIP_CIRCLE")], [0, 1, 2, -1])
	check("own ship achievement with layout B", AchievementTracker.award("ACH_FULL_ARSENAL"), true)
	check("other ship's achievement refused", AchievementTracker.award("ACH_ROBOTIC"), false)
	check("stored with the run difficulty", p.achievements.get("ACH_FULL_ARSENAL"), 2)
	check("unknown id (commented out) ignored", AchievementTracker.award("ACH_LANIUS_SUFFOCATION"), false)
	check("fresh (New!)", p.fresh.has("ACH_FULL_ARSENAL"), true)
	r.end_run("gameover")


func _sector_checks() -> void:
	print("AdvanceWorldLevel / SetSectorEight flags")
	var p := _fresh()
	var r := _run_with("PLAYER_SHIP_FED")
	AchievementTracker.set_flag(r, "store_repair")
	AchievementTracker.set_flag(r, "used_drone")
	AchievementTracker.set_flag(r, "env_danger")
	AchievementTracker.advance_world_level(r, 3)
	check("sector 4: nothing", p.has_achievement("ACH_SECTOR_5"), false)
	AchievementTracker.advance_world_level(r, 4)
	check("sector 5", [p.has_achievement("ACH_SECTOR_5"), p.has_achievement("ACH_NO_REPAIR"),
		p.has_achievement("ACH_NO_UPGRADES"), p.has_achievement("ACH_PACIFIST"), p.has_achievement("ACH_FED_UPGRADE"),
		p.has_achievement("ACH_ENERGY_MANPOWER")], [true, false, true, true, true, false])
	check("sector 5: no sector 8 yet", p.has_achievement("ACH_SECTOR_8"), false)
	AchievementTracker.advance_world_level(r, 7)
	check("sector 8", [p.has_achievement("ACH_SECTOR_8"), p.has_achievement("ACH_NO_MISSILES"),
		p.has_achievement("ACH_NO_DRONES"), p.has_achievement("ACH_NO_BUYING"), p.has_achievement("ACH_NO_DEATH"),
		p.has_achievement("ACH_LANIUS_OXYGEN"), p.has_achievement("ACH_STEALTH_TACTICAL")],
		[true, true, false, true, true, false, false])
	# Flags come from the hooks.
	var p2 := _fresh()
	var r2 := _run_with("PLAYER_SHIP_FED")
	Hooks.emit(&"upgrades_applied", r2, ["system_upgrade", "weapon_upgrade"])
	Hooks.emit(&"store_bought", r2, "weapon")
	Hooks.emit(&"teleport_initiated", r2.ship)
	AchievementTracker.advance_world_level(r2, 4)
	AchievementTracker.advance_world_level(r2, 7)
	check("flags from hooks", [p2.has_achievement("ACH_NO_UPGRADES"), p2.has_achievement("ACH_FED_UPGRADE"),
		p2.has_achievement("ACH_PACIFIST"), p2.has_achievement("ACH_NO_BUYING"), p2.has_achievement("ACH_NO_REPAIR")],
		[false, false, false, false, true])
	r.end_run("gameover")
	r2.end_run("gameover")


func _frame_checks() -> void:
	print("Per-frame checks")
	var p := _fresh()
	var r := _run_with("PLAYER_SHIP_HARD")
	r.ship.hull = 1
	AchievementTracker.check_frame(r)
	check("hull 1: not yet", p.has_achievement("ACH_TOUGH_SHIP"), false)
	r.ship.hull = r.ship.max_hull
	AchievementTracker.check_frame(r)
	check("full again: ACH_TOUGH_SHIP", p.has_achievement("ACH_TOUGH_SHIP"), true)
	for race in ["engi", "mantis", "slug", "rock", "energy"]:
		r.ship.add_crew(race, true)
	AchievementTracker.check_frame(r)
	check("six species: ACH_UNITED_FEDERATION", p.has_achievement("ACH_UNITED_FEDERATION"), true)
	check("two Kestrel achievements: Kestrel B unlocked", p.is_unlocked(0, 1), true)
	r.end_run("gameover")
	# Zoltan: 29 bars in reactor systems.
	_fresh()
	var z := _run_with("PLAYER_SHIP_ENERGY")
	var n := 0
	for s: SystemState in z.ship.systems.values():
		if s.uses_reactor() and n < 3:
			s.power = 10
			n += 1
	AchievementTracker.check_frame(z)
	check("ACH_ENERGY_POWER", PlayerProfile.current().has_achievement("ACH_ENERGY_POWER"), true)
	z.end_run("gameover")
	# Lanius: 600 scrap (resource_changed).
	_fresh()
	var la := _run_with("PLAYER_SHIP_ANAEROBIC")
	la.ship.scrap = 600
	check("ACH_LANIUS_SCRAP", PlayerProfile.current().has_achievement("ACH_LANIUS_SCRAP"), true)
	la.end_run("gameover")
	# Engi vs an enemy: 4 locked systems.
	_fresh()
	var en := _run_with("PLAYER_SHIP_CIRCLE")
	var e := _enemy(en)
	var k := 0
	for s: SystemState in e.systems.values():
		if k < 4:
			s.ion = 2
			k += 1
	AchievementTracker.check_frame(en)
	check("ACH_IONED", PlayerProfile.current().has_achievement("ACH_IONED"), true)
	en.end_run("gameover")


func _enemy(r: RunState, bp := "REBEL_FAT") -> ShipState:
	var e := ShipState.new(bp, false)
	r.ship.opponent = e
	e.opponent = r.ship
	r.enemy = {"hostile": true, "done": false}
	return e


func _hook_triggers() -> void:
	print("Hook-driven triggers")
	var p := _fresh()
	var r := _run_with("PLAYER_SHIP_HARD")
	# BAD_DODGING: 5 failed rolls while flying with engines at 8.
	var eng := r.ship.sys("engines")
	eng.level = 8
	eng.power = 8
	check("ship flying", FtlDrive.ship_flying(r.ship), true)
	for i in 4:
		Hooks.emit(&"dodge_rolled", r.ship, false)
	Hooks.emit(&"dodge_rolled", r.ship, true)
	Hooks.emit(&"dodge_rolled", r.ship, false)
	check("a dodge resets the count", p.has_achievement("ACH_BAD_DODGING"), false)
	for i in 4:
		Hooks.emit(&"dodge_rolled", r.ship, false)
	check("five in a row: ACH_BAD_DODGING", p.has_achievement("ACH_BAD_DODGING"), true)
	# Weapons / drones / crew flags.
	Hooks.emit(&"weapon_fired", r.ship, r.ship.weapons[0], null)
	check("fired_shot", AchievementTracker.flag(r, "fired_shot"), 1)
	var c := r.ship.crew[0]
	c.hp = 0.0
	Hooks.emit(&"crew_died", r.ship, c)
	check("lost_crew", AchievementTracker.flag(r, "lost_crew"), 1)
	r.end_run("gameover")
	# Mantis: 5 enemy crew killed at this beacon without losing hull or crew.
	_fresh()
	var m := _run_with("PLAYER_SHIP_MANTIS")
	var e := _enemy(m)
	AchievementTracker._beacon_reset(m)
	for i in 5:
		var x := e.add_crew("human", false)
		x.hp = 0.0
		Hooks.emit(&"crew_died", e, x)
	check("ACH_MANTIS_SLAUGHTER", PlayerProfile.current().has_achievement("ACH_MANTIS_SLAUGHTER"), true)
	m.end_run("gameover")
	# Slug: one anti-bio beam kills three.
	_fresh()
	var s := _run_with("PLAYER_SHIP_JELLY")
	var se := _enemy(s)
	var d := Damage.new()
	d.damage = 0
	d.pers_damage = 3
	var holder := _BeamStub.new()
	holder.dmg = d
	Hooks.emit(&"beam_damage", se, holder, {"room": 0, "killed": 2})
	check("two kills: not yet", PlayerProfile.current().has_achievement("ACH_SLUG_BIO"), false)
	Hooks.emit(&"beam_damage", se, holder, {"room": 1, "killed": 1})
	check("three kills: ACH_SLUG_BIO", PlayerProfile.current().has_achievement("ACH_SLUG_BIO"), true)
	s.end_run("gameover")


class _BeamStub extends RefCounted:
	var dmg: Damage


func _outcomes() -> void:
	print("Fight outcomes (WorldManager::OnLoop)")
	_fresh()
	var en := _run_with("PLAYER_SHIP_CIRCLE")
	var e := _enemy(en)
	Hooks.emit(&"combat_outcome", en, "destroyed")
	check("Engi: no weapon / artillery volley -> ACH_ONLY_DRONES",
		PlayerProfile.current().has_achievement("ACH_ONLY_DRONES"), true)
	en.end_run("gameover")
	_fresh()
	var st := _run_with("PLAYER_SHIP_STEALTH")
	var se := _enemy(st)
	se.hull = se.max_hull - 2
	st.ship.sys("cloaking").turned_on = true
	AchievementTracker.check_frame(st)
	Hooks.emit(&"combat_outcome", st, "destroyed")
	check("Stealth: damaged only while cloaked -> ACH_STEALTH_DESTROY",
		PlayerProfile.current().has_achievement("ACH_STEALTH_DESTROY"), true)
	st.end_run("gameover")
	_fresh()
	var st2 := _run_with("PLAYER_SHIP_STEALTH")
	var se2 := _enemy(st2)
	se2.hull = se2.max_hull - 2
	AchievementTracker.check_frame(st2)
	Hooks.emit(&"combat_outcome", st2, "destroyed")
	check("Stealth: damaged while uncloaked -> no", PlayerProfile.current().has_achievement("ACH_STEALTH_DESTROY"),
		false)
	st2.end_run("gameover")
	# Crystal: 10 rock ships.
	_fresh()
	var cr := _run_with("PLAYER_SHIP_CRYSTAL")
	var ce := _enemy(cr)
	ce.blueprint["name"] = "ROCK_ASSAULT_ELITE"
	for i in 9:
		Hooks.emit(&"combat_outcome", cr, "destroyed")
	check("nine rock ships", PlayerProfile.current().has_achievement("ACH_CRYSTAL_CLASH"), false)
	Hooks.emit(&"combat_outcome", cr, "destroyed")
	check("ten rock ships: ACH_CRYSTAL_CLASH", PlayerProfile.current().has_achievement("ACH_CRYSTAL_CLASH"), true)
	cr.end_run("gameover")
	# Mantis: the last enemy killed by the last crew member aboard their ship.
	_fresh()
	var mt := _run_with("PLAYER_SHIP_MANTIS")
	var me := _enemy(mt)
	var last: CrewMember = mt.ship.crew[0]
	for c in mt.ship.crew.duplicate():
		mt.ship.crew.erase(c)
	me.crew.append(last)
	Hooks.emit(&"combat_outcome", mt, "deadCrew")
	check("ACH_MANTIS_SURVIVOR", PlayerProfile.current().has_achievement("ACH_MANTIS_SURVIVOR"), true)
	check("ACH_INVADE_SHIP (general)", PlayerProfile.current().has_achievement("ACH_INVADE_SHIP"), true)
	mt.end_run("gameover")


func _popups() -> void:
	print("Popups (AchievementTracker::OnLoop)")
	var p := _fresh()
	var r := _run_with("PLAYER_SHIP_HARD")
	AchievementTracker.award("ACH_FULL_ARSENAL")
	check("queued", AchievementTracker.popups.size(), 1)
	check("entry", [AchievementTracker.popups[0].header, AchievementTracker.popups[0].sound,
		AchievementTracker.popups[0].img], ["", "achievement", "achievements/kestral_2.png"])
	p.unlock_ship(3, 0)
	check("ship unlock popup", [AchievementTracker.popups.size(), AchievementTracker.popups[1].header,
		AchievementTracker.popups[1].sound], [2, "ship_unlocked", "unlock"])
	p.unlock_ship(4, 0, true)
	check("hidden unlock: no popup", AchievementTracker.popups.size(), 2)
	var pop := AchievementPopup.new()
	check("first shown", String(pop.step(0.0).get("img", "")), "achievements/kestral_2.png")
	pop.step(2.9)
	check("still the first at 2.9 s", AchievementTracker.popups.size(), 2)
	var nxt := pop.step(0.2)
	check("next after 3 s", String(nxt.get("header", "")), "ship_unlocked")
	pop.free()
	GameOptions.achievement_popups = false
	AchievementTracker.award("ACH_TOUGH_SHIP")
	# The option only hides achievement popups: the layout B unlock it causes still shows (AchievementTracker::
	# UnlockShip does not read Settings::achPopups).
	check("popups off: only the layout unlock", [AchievementTracker.popups.size(),
		AchievementTracker.popups[-1].header], [2, "layout_unlocked"])
	GameOptions.achievement_popups = true
	AchievementTracker.popups.clear()
	r.end_run("gameover")


func _tooltip_text() -> void:
	print("Hangar tooltip text (AchievementTracker::SetTooltip)")
	var p := _fresh()
	var t := HangarView.achievement_tooltip_text("ACH_SECTOR_5", "")
	check("locked: name + desc", t, [TooltipText.t("ACH_SECTOR_5_name"), TooltipText.t("ACH_SECTOR_5_desc")])
	p.set_achievement("ACH_SECTOR_5", 2)
	t = HangarView.achievement_tooltip_text("ACH_SECTOR_5", "")
	check("earned multi: + Unlocked on HARD", t[1], TooltipText.t("ACH_SECTOR_5_desc") + " \n\n"
		+ TooltipText.t("ach_hard"))
	p.set_achievement("ACH_WIN_EASY", 1)
	t = HangarView.achievement_tooltip_text("ACH_WIN_EASY", "")
	check("earned non-multi: no difficulty line", t[1], TooltipText.t("ACH_WIN_EASY_desc"))
	p.set_ship_victory(0, 0, 0)
	p.set_ship_victory(0, 2, 2)
	t = HangarView.achievement_tooltip_text("PLAYER_SHIP_HARD_VICTORY", "Kestrel")
	check("victory: one line per layout won", t[1], TooltipText.f("victory_ach", "Kestrel") + " \n\n"
		+ TooltipText.f("achieved_with", TooltipText.t("type_a"), TooltipText.t("easy")) + "\n"
		+ TooltipText.f("achieved_with", TooltipText.t("type_c"), TooltipText.t("hard")))
	check("victory title", t[0], TooltipText.f("victory_ach_title", "Kestrel"))


## The hangar: hovering an icon requests an instant tooltip with the achievement text and highlights the icon.
func _hangar_hover() -> void:
	print("Hangar hover")
	_fresh()
	var ts := TitleState.new()
	ts.unlock_all = true
	ts.open_hangar()
	var hv := HangarView.new()
	add_child(hv)
	hv.setup(ts, InputProfile.new())
	await get_tree().process_frame
	if ts.preview == null:
		check("hangar preview built", false, true)
		hv.queue_free()
		return
	var achs := MenuDraw.ship_achievements(ts.ship_id)
	var pos: Array = hv.achievement_positions(achs)
	TooltipService.manual = true
	TooltipService.begin_frame(0.0, Vector2(-100, -100))
	hv._achievement_tooltip(pos[1] + Vector2(20, 20))
	check("tooltip requested", [TooltipService.title, TooltipService.forced],
		[TooltipText.t(String(achs[1].id) + "_name"), true])
	check("hovered icon", hv.ach_hover, 1)
	TooltipService.begin_frame(0.0, Vector2(-100, -100))
	hv._achievement_tooltip(pos[3] + Vector2(10, 10))
	check("victory marker hovered", [hv.ach_hover, TooltipService.title.is_empty()], [3, false])
	TooltipService.begin_frame(0.0, Vector2(-100, -100))
	hv._achievement_tooltip(Vector2(5, 5))
	check("nothing hovered", [hv.ach_hover, TooltipService.text], [-1, ""])
	TooltipService.manual = false
	hv.queue_free()


## The ship list (ShipSelect::MouseMove): the mini achievements of ship-unlocked buttons answer with the
## achievement tooltip, ship-locked ones not at all; an unlock arrow shows its instant unlock text.
func _ship_list_hover() -> void:
	print("Ship list hover")
	var p := _fresh()
	p.unlocked["4:0"] = true  # Fed A
	p.set_achievement(String(PlayerProfile.ship_achievement_ids(4)[0]), 1)
	var ts := TitleState.new()
	ts.unlock_all = false
	var l := ShipListView.new()
	add_child(l)
	l.setup(ts)
	l.open(0, 0)
	TooltipService.manual = true
	var fed: Dictionary = l.buttons["ship4"]
	var rects: Array = l.mini_rects(fed)
	check("mini icons at button + (6, 123), 37 apart", [rects[0].position, rects[1].position.x - rects[0].position.x],
		[fed.rect.position + Vector2(6, 123), 37.0])
	TooltipService.begin_frame(0.0, Vector2(-100, -100))
	l.hover_tooltips(rects[0].get_center())
	var aid := String(MenuDraw.ship_achievements(4)[0].id)
	check("Fed mini 1: achievement tooltip", [TooltipService.title, TooltipService.forced, l.ach_hover],
		[TooltipText.t(aid + "_name"), true, Vector2i(4, 0)])
	TooltipService.begin_frame(0.0, Vector2(-100, -100))
	l.hover_tooltips(rects[3].get_center())
	check("Fed victory marker", TooltipService.title, TooltipText.f("victory_ach_title",
		TitleState.ship_class("PLAYER_SHIP_FED")))
	TooltipService.begin_frame(0.0, Vector2(-100, -100))
	var engi: Dictionary = l.buttons["ship3"]  # Engi A locked: no lower box, no tooltips
	l.hover_tooltips(engi.rect.position + Vector2(20, 139))
	check("ship-locked button: no achievement tooltip", [TooltipService.text, l.ach_hover], ["", Vector2i(-1, -1)])
	TooltipService.begin_frame(0.0, Vector2(-100, -100))
	var arrow: Dictionary = l.arrows()[0]  # Kestrel -> Engi (Engi locked): sector 5
	l.hover_tooltips(arrow.rect.get_center())
	check("arrow tooltip (instant, no title)", [TooltipService.text, TooltipService.title, TooltipService.forced,
		l.arrow_hover], [ShipListView.arrow_text(arrow), "", true, 0])
	TooltipService.manual = false
	l.queue_free()


## The stats screen (ScoreKeeper::MouseMove): ACHIEVEMENTS page icons and the SHIP BEST page's three icons.
func _stats_hover() -> void:
	print("Stats screen hover")
	var p := _fresh()
	p.set_achievement("ACH_SECTOR_5", 1)
	var ts := TitleState.new()
	var sv := StatsView.new()
	add_child(sv)
	sv.setup(ts)
	sv.left = 1
	sv.right = 1
	sv.open()
	TooltipService.manual = true
	TooltipService.begin_frame(0.0, Vector2(-100, -100))
	sv.hover_tooltips(StatsView.ACH_AT + Vector2(32, 32))
	check("ACHIEVEMENTS icon 0 = sector 5 (+ difficulty line)", [TooltipService.title, TooltipService.text,
		sv.ach_hover], [TooltipText.t("ACH_SECTOR_5_name"), TooltipText.t("ACH_SECTOR_5_desc") + " \n\n"
		+ TooltipText.t("ach_normal"), 0])
	TooltipService.begin_frame(0.0, Vector2(-100, -100))
	sv.hover_tooltips(StatsView.ACH_AT + Vector2(70 * 2 + 32, 170 + 32))
	check("row 2 icon 3", [TooltipService.title, sv.ach_hover], [TooltipText.t("ACH_NO_REPAIR_name"), 9])
	TooltipService.begin_frame(0.0, Vector2(-100, -100))
	sv.hover_tooltips(Vector2(410 + 70 + 32, 118 + 32))
	check("SHIP BEST icon 2", [TooltipService.title, sv.ship_ach_hover],
		[TooltipText.t(String(MenuDraw.ship_achievements(0)[1].id) + "_name"), 1])
	TooltipService.begin_frame(0.0, Vector2(-100, -100))
	sv.hover_tooltips(Vector2(410 + 64, 118 + 32))  # the 6 px gap between icons
	check("gap: nothing", [TooltipService.text, sv.ach_hover, sv.ship_ach_hover], ["", -1, -1])
	TooltipService.manual = false
	sv.queue_free()


## The Esc menu (MenuScreen::MouseMove): the current ship's icons and markers; nothing while the confirm is open.
func _pause_hover() -> void:
	print("Pause menu hover")
	var p := _fresh()
	p.set_ship_victory(4, 1, 0)
	var pm := PauseMenuView.new()
	add_child(pm)
	pm.open(1, true, "PLAYER_SHIP_FED_2")
	var achs := MenuDraw.ship_achievements(4)
	var rects: Array = pm.achievement_rects(achs)
	check("Fed: 3 icons + victory + quest, markers 32 px", [rects.size(), rects[3].size, rects[4].position.y,
		rects[3].position.y - rects[4].position.y], [5, Vector2(32, 32), PauseMenuView.ACH_AT.y, 34.0])
	TooltipService.manual = true
	TooltipService.begin_frame(0.0, Vector2(-100, -100))
	pm.hover_tooltips(rects[3].get_center())
	var cls := TitleState.ship_class("PLAYER_SHIP_FED_2")
	check("victory marker: achieved with type B", [TooltipService.title, TooltipService.text, pm.ach_hover],
		[TooltipText.f("victory_ach_title", cls), TooltipText.f("victory_ach", cls) + " \n\n"
		+ TooltipText.f("achieved_with", TooltipText.t("type_b"), TooltipText.t("easy")), 3])
	pm.click(pm.buttons["hangar"].rect.get_center())  # opens the end-game confirm
	TooltipService.begin_frame(0.0, Vector2(-100, -100))
	pm.hover_tooltips(rects[0].get_center())
	check("confirm open: no achievement hover", [TooltipService.text, pm.ach_hover], ["", -1])
	TooltipService.manual = false
	pm.queue_free()
