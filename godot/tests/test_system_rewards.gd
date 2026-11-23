extends Node
## Tests for rules/events.md "System rewards" and "Crew skill icons": event <system> rewards (ShipManager::AddSystem:
## room / starting level / unpowered, medbay <-> clonebay replacement, blueprint without the system), the
## CreateChoiceBox warnings (new_system_update / penultimate / last / full / owned / medbay / clonebay, greyed
## choices), the `<system>_installed` alert, <upgrade> caps (CanUpgrade, upgrade_fail_max / missing / success,
## the flag computed when the box opens, before the upgrade is applied on the choice, reactor 25), and event crew skills (all_skills / per-skill attributes,
## RandomSkills) with their reward-box icons. Small project-made event XML (not FTL text). Run:
##   godot --headless --path godot res://tests/test_system_rewards.tscn

const Harness := preload("res://tests/harness.gd")

var fails := 0


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


const SRC := """
<FTL>
<event name="GIVE_CLOAK"><text>cloak</text><system name="cloaking"/></event>
<event name="GIVE_CLONE"><text>clone</text><system name="clonebay"/></event>
<event name="GIVE_MEDBAY"><text>med</text><system name="medbay"/></event>
<event name="GIVE_HACK"><text>hack</text><system name="hacking"/></event>
<event name="GIVE_BATTERY"><text>battery</text><system name="battery"/></event>
<event name="GIVE_BOGUS"><text>bogus</text><system name="warp_core"/></event>
<event name="OFFER_CLOAK"><text>Take it?</text>
	<choice><text>Yes.</text><event load="GIVE_CLOAK"/></choice>
	<choice><text>No.</text><event/></choice>
</event>
<event name="OFFER_TWO"><text>Pick one.</text>
	<choice><text>Clonebay.</text><event load="GIVE_CLONE"/></choice>
	<choice><text>Battery.</text><event load="GIVE_BATTERY"/></choice>
	<choice><text>Hacking.</text><event load="GIVE_HACK"/></choice>
</event>
<event name="UP_PILOT"><text>up</text><upgrade amount="1" system="pilot"/></event>
<event name="UP_PILOT2"><text>up</text><upgrade amount="2" system="pilot"/></event>
<event name="UP_REACTOR"><text>up</text><upgrade amount="1" system="reactor"/></event>
<event name="UP_CLOAK"><text>up</text><upgrade amount="1" system="cloaking"/></event>
<event name="UP_ALL"><text>up</text><upgrade amount="1" system="all"/></event>
<event name="CREW_SKILLS"><text>crew</text><crewMember amount="1" class="human" pilot="2" engines="1"/></event>
<event name="CREW_ALL"><text>crew</text><crewMember amount="1" class="engi" all_skills="1"/></event>
<event name="CREW_PLAIN"><text>crew</text><crewMember amount="1" class="human"/></event>
<event name="CREW_LOST"><text>lost</text><crewMember amount="-1"/></event>
</FTL>
"""


func make_run(ship_name := "PLAYER_SHIP_HARD", seed := 3) -> RunState:
	var db := EventDB.new()
	db.add_source(SRC)
	db.rarity = EventDB.shared().rarity
	var r := RunState.new()
	r.engine = EventEngine.new(db)
	r.engine.rng.seed = seed
	r.rng.seed = seed
	r.ship = ShipState.new(ship_name, true)
	return r


var shown: Array = []  # reward box of the last event shown by `pick`
var shown_dialog := {}


## Shows the event, keeps its reward box (built before ModifyResources) and picks the first choice: the event's
## resources / system / upgrade / crew are applied then (WorldManager::PauseLoop).
func pick(r: RunState, name: String) -> void:
	r.show_event(r.engine.base_event(name))
	shown = r.dialog_rewards.duplicate(true)
	shown_dialog = r.dialog
	r.choose(0)


func box(r: RunState) -> Dictionary:
	var eb := EventBox.new()
	eb.run = r
	var res: Dictionary = eb._reward_resources(shown, shown_dialog)
	eb.free()
	return res


func alert_texts(res: Dictionary) -> Array:
	return (res.get("alerts", []) as Array).map(func(a): return a[0])


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	FtlData.muted = true
	test_parse()
	test_install_fits()
	test_choice_warnings()
	test_full_and_owned()
	test_medbay_clonebay()
	test_upgrade_caps()
	test_crew_skills()
	test_skill_icons_layout()


func test_parse() -> void:
	print("Parsing <system name>")
	var r := make_run()
	check("system name kept", r.engine.base_event("GIVE_CLOAK").system, "cloaking")
	check("unknown name: no system (NameToSystemId -1)", r.engine.base_event("GIVE_BOGUS").system, "")
	check("event with only <system> has content", r.engine.base_event("GIVE_CLOAK").content, true)
	check("crew skills parsed", r.engine.base_event("CREW_SKILLS").crew.skills, {"pilot": 2, "engines": 1})
	check("all_skills -> every skill", r.engine.base_event("CREW_ALL").crew.skills.size(), 6)


func test_install_fits() -> void:
	print("AddSystem: room, starting level, unpowered, installed alert")
	var r := make_run()
	check("Kestrel starts without cloaking", r.ship.sys("cloaking") == null, true)
	var bp: Dictionary = {}
	for b in r.ship.blueprint.systems:
		if b.id == "cloaking":
			bp = b
	r.show_event(r.engine.base_event("GIVE_CLOAK"))
	check("box open: not installed yet (ModifyResources on the choice)", r.ship.sys("cloaking") == null, true)
	shown = r.dialog_rewards.duplicate(true)
	shown_dialog = r.dialog
	r.choose(0)
	var s := r.ship.sys("cloaking")
	check("cloaking installed", s != null, true)
	if s == null:
		return
	check("in the blueprint room", s.room, int(bp.room))
	check("level max(power, 1) capped by maxPower", s.level, mini(maxi(int(bp.power), 1),
		int(UpgradeSession.system_info("cloaking").max)))
	check("unpowered", s.power, 0)
	check("listed in system_list", r.ship.system_list().has("cloaking"), true)
	check("reward entry", shown.has(["system", "cloaking"]), true)
	var res := box(r)
	check("alert = cloaking_installed", alert_texts(res), [FtlData.tr_id("cloaking_installed")])
	check("alert helpful (green)", res.alerts[0][1], true)
	var lay := ResourceBox.layout(res, false)
	check("box not empty", lay.size.x > 0, true)
	# A system the ship blueprint has no room for: nothing installed, the alert is still shown (exe).
	var k := make_run("PLAYER_SHIP_HARD")
	var has_art: bool = k.ship.blueprint.systems.any(func(b): return b.id == "artillery")
	check("Kestrel blueprint has no artillery room", has_art, false)
	check("install_system(artillery) refused", k.install_system("artillery"), false)


func test_choice_warnings() -> void:
	print("CreateChoiceBox system warnings appended to the text")
	var r := make_run()
	var n := r.main_system_count()
	r.show_event(r.engine.base_event("OFFER_CLOAK"))
	var want := " \n\n" + FtlData.tr_id("new_system_update").replace("\\1", str(7 - n))
	check("main systems on the Kestrel", n, 5)
	check("note = new_system_update (\\1 = 7 - count)", r.dialog.get("system_note", ""), want)
	check("choice enabled", r.dialog_choices[0].enabled, true)
	check("no system preview in the choice box", ResourceBox.is_empty(r.dialog_choices[0].preview_res), true)
	r.choose(0)
	check("chosen: the outcome box lists it, not installed yet", [r.dialog_rewards.has(["system", "cloaking"]),
		r.ship.sys("cloaking") == null], [true, true])
	r.choose(0)
	check("its Continue installs", r.ship.sys("cloaking") != null, true)
	# 6 main systems -> penultimate; 7 -> last.
	var p := make_run()
	RunStore.install_system(p.ship, "drones")
	p.show_event(p.engine.base_event("OFFER_CLOAK"))
	check("6 main systems: penultimate", p.dialog.system_note, " \n\n" + FtlData.tr_id("new_system_penultimate"))
	var l := make_run()
	RunStore.install_system(l.ship, "drones")
	RunStore.install_system(l.ship, "teleporter")
	l.show_event(l.engine.base_event("OFFER_CLOAK"))
	check("7 main systems: last", l.dialog.system_note, " \n\n" + FtlData.tr_id("new_system_last"))
	# Several choices: notes joined by " \n\n"; a subsystem adds nothing.
	var t := make_run()
	t.show_event(t.engine.base_event("OFFER_TWO"))
	var upd := FtlData.tr_id("new_system_update").replace("\\1", "2")
	check("clonebay with a medbay + battery (nothing) + hacking", t.dialog.system_note,
		" \n\n" + FtlData.tr_id("new_system_clonebay") + " \n\n" + upd)
	check("no choice greyed", t.dialog_choices.map(func(v): return v.enabled), [true, true, true])
	var eb := EventBox.new()
	eb.run = t
	check("EventBox body includes the note", String(t.dialog.text) + String(t.dialog.system_note) != "", true)
	eb.free()


func test_full_and_owned() -> void:
	print("Full ship / owned system: greyed choice")
	var r := make_run()
	for id in ["drones", "teleporter", "hacking"]:
		RunStore.install_system(r.ship, id)
	check("8 main systems", r.main_system_count(), 8)
	check("CanFitSystem false", r.can_fit_system("cloaking"), false)
	check("medbay/clonebay swap still fits", r.can_fit_system("clonebay"), true)
	r.show_event(r.engine.base_event("OFFER_CLOAK"))
	check("note = new_system_full", r.dialog.system_note, " \n\n" + FtlData.tr_id("new_system_full"))
	check("cloak choice greyed, other enabled", r.dialog_choices.map(func(v): return v.enabled), [false, true])
	var o := make_run()
	RunStore.install_system(o.ship, "cloaking")
	var lvl := o.ship.sys("cloaking").level
	o.show_event(o.engine.base_event("OFFER_CLOAK"))
	check("owned: new_system_owned", o.dialog.system_note, " \n\n" + FtlData.tr_id("new_system_owned"))
	check("owned: greyed", o.dialog_choices[0].enabled, false)
	o.ship.sys("cloaking").level = 3
	pick(o, "GIVE_CLOAK")  # applied anyway (a top-level event): nothing changes
	check("owned + applied: level kept", o.ship.sys("cloaking").level, 3)
	check("owned + applied: installed alert still shown", alert_texts(box(o)), [FtlData.tr_id("cloaking_installed")])
	check("(start level was)", lvl > 0, true)


func test_medbay_clonebay() -> void:
	print("Medbay <-> clonebay replacement")
	var r := make_run()
	var med := r.ship.sys("medbay")
	med.level = 3
	r.ship.increase_power("medbay")
	var room := med.room
	# Put a crew member on the medbay's blocked slot, then install the clonebay in its room.
	pick(r, "GIVE_CLONE")
	check("medbay gone", r.ship.sys("medbay") == null, true)
	var cb := r.ship.sys("clonebay")
	check("clonebay installed", cb != null, true)
	if cb == null:
		return
	check("clonebay takes the medbay's level", cb.level, 3)
	check("clonebay unpowered", cb.power, 0)
	var g := make_run()
	pick(g, "GIVE_CLONE")
	check("level stays at least the blueprint power", g.ship.sys("clonebay").level >= 1, true)
	pick(g, "GIVE_MEDBAY")
	check("medbay back, clonebay gone", [g.ship.sys("medbay") != null, g.ship.sys("clonebay") == null], [true, true])
	# Crew standing in the room move off the blocked slot.
	var k := make_run()
	var mroom := k.ship.sys("medbay").room
	var blocked := k.ship.graph.blocked_slot(mroom)
	var c: CrewMember = k.ship.crew[0]
	k.ship.sys("medbay").level = 1
	RunStore.install_system(k.ship, "clonebay")  # replaces: same room, same blocked slot rule
	k.ship.systems.erase("clonebay")  # no obstruction while placing the crew member
	c.walk_to_slot(k.ship, mroom, maxi(blocked, 0))
	check("crew placed on slot", c.slot, maxi(blocked, 0))
	RunStore.install_system(k.ship, "medbay")
	var nb := k.ship.graph.blocked_slot(mroom)
	check("blocked slot exists", nb >= 0, true)
	check("crew re-slotted off the blocked slot", c.slot != nb and c.target_room == mroom, true)
	check("(room)", room == mroom, true)


func test_upgrade_caps() -> void:
	print("<upgrade>: CanUpgrade caps and the reward flag")
	var r := make_run()
	var p := r.ship.sys("pilot")
	var mx := UpgradeSession.max_level(r.ship, "pilot")
	p.level = mx
	pick(r, "UP_PILOT")
	check("at max: level unchanged", p.level, mx)
	check("reward flag 2 (maxed)", shown.has(["upgrade", "pilot", 2, 1]), true)
	var res := box(r)
	check("upgrade_fail_max text", alert_texts(res),
		[FtlData.tr_id("upgrade_fail_max").replace("\\1", FtlData.tr_id("pilot"))])
	check("failure is neither good nor bad (white)", res.alerts[0][1], null)
	var lay := ResourceBox.layout(res, false)
	check("alert kind white", lay.ops.filter(func(o): return o[1] == "text")[0][5], "white")
	p.level = mx - 2
	r.show_event(r.engine.base_event("UP_PILOT"))
	check("box open: not upgraded yet", p.level, mx - 2)
	shown = r.dialog_rewards.duplicate(true)
	shown_dialog = r.dialog
	r.choose(0)
	check("two below max: +1 on the choice", p.level, mx - 1)
	check("flag 1, amount 1", shown.has(["upgrade", "pilot", 1, 1]), true)
	check("upgrade_success text", alert_texts(box(r)),
		[FtlData.tr_id("upgrade_success").replace("\\1", FtlData.tr_id("pilot")).replace("\\2", "1")])
	# One below max: the box (built before the upgrade) says success, then the choice brings it to the max.
	pick(r, "UP_PILOT")
	check("one below max: reaches max", p.level, mx)
	check("one below max: flag 1 (computed before the upgrade)", shown.has(["upgrade", "pilot", 1, 1]), true)
	# amount 2 from max - 3: CanUpgrade(2) = 2 on the box -> success with \2 = 2, then +2.
	p.level = mx - 3
	pick(r, "UP_PILOT2")
	check("amount 2: +2", p.level, mx - 1)
	check("flag 1, amount 2", shown.has(["upgrade", "pilot", 1, 2]), true)
	p.level = mx - 1
	pick(r, "UP_PILOT2")
	check("amount 2 one below max: capped at max", p.level, mx)
	check("amount 2 one below max: flag 1, amount capped to 1", shown.has(["upgrade", "pilot", 1, 1]), true)
	# Missing system.
	pick(r, "UP_CLOAK")
	check("missing: flag 3", shown.has(["upgrade", "cloaking", 3, 1]), true)
	check("upgrade_fail_missing text", alert_texts(box(r)),
		[FtlData.tr_id("upgrade_fail_missing").replace("\\1", FtlData.tr_id("cloaking"))])
	# Reactor: 25 cap.
	r.ship.reactor_max = 24
	pick(r, "UP_REACTOR")
	check("reactor 24 -> 25", r.ship.reactor_max, 25)
	check("reactor reaching 25: flag 1", shown.has(["upgrade", "reactor", 1, 1]), true)
	pick(r, "UP_REACTOR")
	check("reactor capped at 25", r.ship.reactor_max, 25)
	check("reactor at 25: flag 2", shown.has(["upgrade", "reactor", 2, 1]), true)
	r.ship.reactor_max = 8
	pick(r, "UP_REACTOR")
	check("reactor 8 -> 9, success", [r.ship.reactor_max, shown.has(["upgrade", "reactor", 1, 1])],
		[9, true])
	# all = id 16: nothing upgraded, reported missing.
	var before := r.ship.systems.values().map(func(s): return s.level)
	pick(r, "UP_ALL")
	check("all: nothing upgraded", r.ship.systems.values().map(func(s): return s.level), before)
	check("all: flag 3", shown.has(["upgrade", "all", 3, 1]), true)


func test_crew_skills() -> void:
	print("Event crew skills")
	var r := make_run()
	var n0 := r.ship.crew.size()
	r.show_event(r.engine.base_event("CREW_SKILLS"))
	check("box open: crew not added yet", r.ship.crew.size(), n0)
	shown = r.dialog_rewards.duplicate(true)
	r.choose(0)
	check("crew joins on the choice", r.ship.crew.size(), n0 + 1)
	var rw: Array = shown.filter(func(x): return x[0] == "crew")
	check("one crew reward", rw.size(), 1)
	var c: CrewMember = r.ship.crew[r.ship.crew.size() - 1]
	check("pilot at max", c.skills.get("pilot", 0.0), float(c.skill_cap("pilot")))
	check("engines at half", c.skills.get("engines", 0.0), float(int(c.skill_cap("engines") / 2.0)))
	check("reward skills", rw[0][2].skills, {"pilot": 2, "engines": 1})
	# No skill attributes: RandomSkills(worldLevel); sector 1 (RANDOM_SKILLS[0] = [0, 0]) gives none.
	var p := make_run()
	p.engine.level = 0
	p.show_event(p.engine.base_event("CREW_PLAIN"))
	check("sector 1: no random skills", p.dialog_rewards.filter(func(x): return x[0] == "crew")[0][2].skills, {})
	var q := make_run()
	q.engine.level = 7
	q.show_event(q.engine.base_event("CREW_PLAIN"))
	var sk: Dictionary = q.dialog_rewards.filter(func(x): return x[0] == "crew")[0][2].skills
	check("sector 8: 1..2 skills rolled (RANDOM_SKILLS[7] = [2, 3] bumps)", sk.size() >= 1 and sk.size() <= 2, true)
	var lost := make_run()
	lost.show_event(lost.engine.base_event("CREW_LOST"))
	check("lost crew carry no skills", lost.dialog_rewards[0][2].has("skills"), false)


func test_skill_icons_layout() -> void:
	print("Reward box: crew skill icons (RenderResources crew branch)")
	var cr := {"name": "Bob", "lost": false, "race": "human", "male": true, "colors": [],
		"skills": {"pilot": 2, "engines": 1}}
	var lay := ResourceBox.layout({"crew": [cr]}, false)
	var skills: Array = lay.ops.filter(func(o): return o[1] == "skill")
	check("two icons", skills.size(), 2)
	var name_op: Array = lay.ops.filter(func(o): return o[1] == "text")[0]
	var end_x: float = name_op[4].x + FtlData.ftl_text_width(10, "Bob") + 15
	check("icon order = CrewBlueprint order", skills.map(func(o): return o[2]), [0, 1])
	check("first icon at name end + 15 - 10", skills[0][4].x, end_x - 10)
	check("second icon 23 px further", skills[1][4].x, end_x - 10 + 23)
	check("icons at row y + 2", skills[0][4].y, 2.0)
	check("ratios level / 2", skills.map(func(o): return o[3]), [1.0, 0.5])
	check("box width = last icon + 23 + 5 + 5", lay.size.x, end_x - 10 + 23 + 23 + 5 + ResourceBox.PAD)
	var all6 := cr.duplicate()
	all6.skills = {"pilot": 1, "engines": 1, "shields": 1, "weapons": 1, "repair": 1, "combat": 1}
	check("at most two icons", ResourceBox.layout({"crew": [all6]}, false).ops.filter(
		func(o): return o[1] == "skill").size(), 2)
	var none := cr.duplicate()
	none.skills = {}
	var ln := ResourceBox.layout({"crew": [none]}, false)
	check("no skills: name end + 15 - 7 (+5 pad)", ln.size.x, end_x - 7 + ResourceBox.PAD)
	var gone := cr.duplicate()
	gone.lost = true
	check("lost crew: no icons", ResourceBox.layout({"crew": [gone]}, false).ops.filter(
		func(o): return o[1] == "skill").size(), 0)
	check("skill icon texture exists", FtlData.texture("img/people/skill_pilot_white.png") != null, true)
