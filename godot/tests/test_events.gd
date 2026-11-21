extends Node
## Tests for rules/events.md (list resolution, OVERRIDE_ lists with AE, unique events, text lists, autoReward /
## item_modify math incl. difficulty, choice filtering by req / max_group / affordability, choice application).
## Small project-made event XML strings (not FTL text) plus checks on the user's data. Run:
##   godot --headless --path godot res://tests/test_events.tscn

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
<eventList name="L"><event load="A"/><event load="B"/></eventList>
<eventList name="OVERRIDE_L"><event load="C"/></eventList>
<eventList name="LU"><event load="U"/><event load="V"/></eventList>
<eventList name="LI"><event><text>inline one</text></event></eventList>
<event name="A"><text>a</text></event>
<event name="B"><text>b</text></event>
<event name="C"><text>c</text></event>
<event name="U" unique="true"><text>u</text></event>
<event name="V"><text>v</text></event>
<textList name="T"><text>t1</text><text>t2</text></textList>
<event name="TXT"><text load="T"/></event>
<event name="STD"><text>x</text><autoReward level="LOW">standard</autoReward></event>
<event name="FUELH"><text>x</text><autoReward level="HIGH">fuel</autoReward></event>
<event name="RANDLV"><text>x</text><autoReward level="MEDIUM">scrap_only</autoReward></event>
<event name="UNKNOWN"><text>x</text><autoReward level="LOW">scrap</autoReward></event>
<event name="OVERWRITE"><text>x</text><item_modify><item type="scrap" min="100" max="100"/><item type="fuel" min="5" max="5"/></item_modify><autoReward level="LOW">fuel_only</autoReward></event>
<event name="MOD"><text>x</text><item_modify><item type="fuel" min="-3" max="-3"/><item type="scrap" min="10" max="10"/></item_modify></event>
<event name="HAS_ITEM"><text>x</text><weapon name="LASER_BURST_1"/><autoReward level="LOW">weapon</autoReward></event>
<event name="CHOICES">
	<text>pick</text>
	<choice><text>plain</text><event><text>next</text><item_modify><item type="scrap" min="7" max="7"/></item_modify></event></choice>
	<choice req="shields" lvl="3"><text>needs shields 3</text><event/></choice>
	<choice req="shields" lvl="1"><text>shields ok</text><event/></choice>
	<choice req="shields" lvl="1" max_lvl="1"><text>max 1</text><event/></choice>
	<choice req="shields" max_group="0"><text>group first</text><event/></choice>
	<choice req="engines" max_group="0"><text>group last</text><event/></choice>
	<choice><text>too expensive</text><event><item_modify><item type="fuel" min="-50" max="-50"/></item_modify></event></choice>
	<choice><text>steal</text><event><item_modify steal="true"><item type="fuel" min="-50" max="-50"/></item_modify></event></choice>
	<choice><text>close</text><event/></choice>
</event>
<event name="ALLGREY">
	<text>poor</text>
	<choice><text>a</text><event><item_modify><item type="scrap" min="-999" max="-999"/></item_modify></event></choice>
	<choice><text>b</text><event><item_modify><item type="scrap" min="-999" max="-999"/></item_modify></event></choice>
</event>
</FTL>
"""


func make_db() -> EventDB:
	var db := EventDB.new()
	db.add_source(SRC)
	db.rarity = EventDB.shared().rarity
	return db


func eng(db: EventDB, seed: int) -> EventEngine:
	var e := EventEngine.new(db)
	e.rng.seed = seed
	return e


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	var db := make_db()
	check("parsed events", db.events.size(), 15)
	check("parsed lists", db.lists.size(), 4)

	# --- list resolution (uniform pick), AE OVERRIDE_
	var seen := {}
	var seen_ae := {}
	for s in 200:
		var e := eng(db, s)
		e.ae = false
		seen[e.base_event("L").text] = true
		var e2 := eng(db, s)
		seen_ae[e2.base_event("L").text] = true
	check("list L resolves to A or B (no AE)", seen.keys().size() == 2 and seen.has("a") and seen.has("b"), true)
	check("AE: OVERRIDE_L replaces L", seen_ae.keys(), ["c"])
	check("inline list entry", eng(db, 1).base_event("LI").text, "inline one")

	# --- unique: once created, gone until clear_sector
	var e := eng(db, 3)
	var got := {}
	for i in 60:
		got[e.base_event("LU").text] = got.get(e.base_event("LU").text, 0) + 1
	var e3 := eng(db, 3)
	var us := 0
	for i in 60:
		if e3.base_event("LU").text == "u":
			us += 1
	check("unique event created at most once per sector", us, 1)
	e3.clear_sector()
	var again := 0
	for i in 60:
		if e3.base_event("LU").text == "u":
			again += 1
	check("unique available again after clear_sector", again, 1)

	# --- text list: without replacement
	var et := eng(db, 9)
	var t1: String = et.base_event("TXT").text
	var t2: String = et.base_event("TXT").text
	var t3: String = et.base_event("TXT").text
	check("text list draws differ", t1 != t2 and t1 in ["t1", "t2"] and t2 in ["t1", "t2"], true)
	check("text list runs out", t3, "")

	# --- rewards (rules/events.md §4.1)
	var bad := {}
	for s in 300:
		var en := eng(db, s)
		en.level = 0
		var ev := en.base_event("STD")
		var res: Dictionary = ev.res
		if ev.weapon == "" and ev.drone == "" and ev.augment == "":
			if res.scrap < 7 or res.scrap > 10:
				bad["standard LOW scrap in [7, 10] at L0"] = res.scrap
			var nz := ["fuel", "missiles", "drones"].filter(func(k): return res[k] != 0)
			if nz.size() != 2:
				bad["standard: two different resources"] = res
			if res.fuel != 0 and (res.fuel < 1 or res.fuel > 3):
				bad["standard fuel LOW 1-3"] = res.fuel
			if res.missiles != 0 and (res.missiles < 1 or res.missiles > 2):
				bad["standard missiles LOW 1-2"] = res.missiles
		var fh := eng(db, s).base_event("FUELH")
		if fh.res.fuel < 3 or fh.res.fuel > 6 or fh.res.scrap < int(1.3 * 15) or fh.res.scrap > int(1.55 * 15):
			bad["fuel HIGH: fuel 3-6, scrap 19-23"] = fh.res
		var easy := eng(db, s)
		easy.difficulty = EventEngine.Difficulty.EASY
		var es := easy.base_event("STD")
		if es.weapon == "" and es.drone == "" and es.augment == "" and (es.res.scrap < 10 or es.res.scrap > 14):
			bad["easy: scrap uses L+1 (10-14)"] = es.res.scrap
		var hard := eng(db, s)
		hard.difficulty = EventEngine.Difficulty.HARD
		hard.level = 2
		var hs := hard.base_event("STD")
		if hs.weapon == "" and hs.drone == "" and hs.augment == "" and (hs.res.scrap < 10 or hs.res.scrap > 14):
			bad["hard: scrap uses L-1 (L2 -> 10-14)"] = hs.res.scrap
		var rl := eng(db, s).base_event("RANDLV")
		if not int(rl.auto_reward[1]) in [0, 1, 2]:
			bad["MEDIUM = RANDOM level"] = rl.auto_reward
	check("reward ranges over 300 seeds (failures)", bad, {})
	var levels := {}
	for s in 60:
		levels[int(eng(db, s).base_event("RANDLV").auto_reward[1])] = true
	check("level 'MEDIUM' is RANDOM (all 3 tiers seen)", levels.size(), 3)
	var unk := eng(db, 1).base_event("UNKNOWN")
	check("unknown reward type gives nothing", [unk.res.scrap, unk.res.fuel, unk.weapon], [0, 0, ""])
	var ow := eng(db, 1).base_event("OVERWRITE")
	check("autoReward fuel_only overwrites fuel, keeps item_modify scrap", [ow.res.scrap, ow.res.fuel >= 1
		and ow.res.fuel <= 3], [100, true])
	check("item_modify values", [eng(db, 1).base_event("MOD").res.fuel, eng(db, 1).base_event("MOD").res.scrap],
		[-3, 10])
	check("explicit weapon: reward item step skipped", eng(db, 1).base_event("HAS_ITEM").weapon, "LASER_BURST_1")
	var w := eng(db, 5)
	var item := w.random_item("weapon")
	check("random weapon has rarity > 0", int(db.rarity.weapon.get(item, 0)) > 0, true)

	# --- choice filtering and application (RunState over a custom engine)
	var r := RunState.new()
	r.engine = eng(db, 11)
	r.ship = ShipState.new("PLAYER_SHIP_HARD", true)
	r.ship.fuel = 16
	r.ship.scrap = 30
	r.show_event(r.engine.base_event("CHOICES"))
	var texts := r.dialog_choices.map(func(v): return v.text)
	check("req lvl 3 removed (Kestrel shields 2)", "needs shields 3" in texts, false)
	check("req met kept", "shields ok" in texts, true)
	check("max_lvl below level removed", "max 1" in texts, false)
	check("max_group: last qualifying wins", ["group first" in texts, "group last" in texts], [false, true])
	var by := {}
	for v in r.dialog_choices:
		by[v.text] = v
	check("met req is blue", by["shields ok"].blue, true)
	check("plain choice not blue", by["plain"].blue, false)
	check("unaffordable greyed", by["too expensive"].enabled, false)
	check("steal never greyed", by["steal"].enabled, true)
	check("preview shown", by["plain"].preview, "[Scrap: +7]")
	check("preview as ResourceBox amounts", by["plain"].preview_res, {"scrap": 7})
	check("ResourceBox: 32 px icon + number, advance 45 / 50 (+5 negative)",
		[ResourceBox.advance(7), ResourceBox.advance(15), ResourceBox.advance(-15)], [45, 50, 55])
	check("ResourceBox size for +7 scrap", ResourceBox.measure({"scrap": 7}), Vector2(55, 32))
	_reward_box_checks()
	var idx: int = r.dialog_choices.find(by["too expensive"])
	check("greyed choice refused", r.choose(idx), false)
	var scrap0 := r.ship.scrap
	check("choose plain", r.choose(r.dialog_choices.find(by["plain"])), true)
	check("sub-event shown", r.dialog.text, "next")
	check("sub-event reward applied", r.ship.scrap - scrap0, 7)
	check("dialog rewards listed", r.dialog_rewards, [["scrap", 7]])
	r.choose(0)  # continue
	check("empty event closes the box", r.phase, RunState.Phase.IDLE)
	r.ship.scrap = 0
	r.show_event(r.engine.base_event("ALLGREY"))
	check("all greyed -> first enabled", r.dialog_choices.map(func(v): return v.enabled), [true, false])
	_boarder_checks(r)

	# --- the user's data
	var real := EventDB.shared()
	check("data: START_GAME, DESTROYED_DEFAULT, PIRATE ship", [real.events.has("START_GAME"),
		real.lists.has("DESTROYED_DEFAULT"), real.ships.has("PIRATE")], [true, true, true])
	check("data: dlcEventsOverwrite OVERRIDE_ lists loaded (%d events)" % real.events.size(), real.lists.has("OVERRIDE_HOSTILE_PIRATE") and real.events.size() > 400, true)
	var re := EventEngine.new(real)
	re.rng.seed = 4
	var dd := re.base_event("DESTROYED_DEFAULT")
	check("DESTROYED_DEFAULT: MED standard reward", dd.auto_reward.size() == 2 and dd.auto_reward[0] == "standard"
		and dd.auto_reward[1] == 1, true)
	var seeded_a := re.base_event("DESTROYED_DEFAULT", 777)
	var seeded_b := re.base_event("DESTROYED_DEFAULT", 777)
	check("ship-seeded outcome event reproducible", seeded_a.res, seeded_b.res)
	var ships := 0
	for s in 40:
		re.rng.seed = s
		var h := re.base_event("HOSTILE1")
		if not h.ship.is_empty():
			ships += 1
	check("HOSTILE1 events bring ships (%d/40)" % ships, ships > 10, true)



## <boarders> (WorldManager::AddBoarders / CompleteShip::AddBoarders) and a choice outcome's <environment>.
func _boarder_checks(r: RunState) -> void:
	r.ship = ShipState.new("PLAYER_SHIP_HARD", true)
	r.hazard = null
	var hull0 := r.ship.hull
	check("boarders: 2 placed", r.add_boarders({"amount": 2, "race": "mantis", "breach": false}), 2)
	var b := r.ship.intruders()
	check("boarders: same room, enemy mantis", [b[0].room == b[1].room, b[0].race, b[0].player_owned],
		[true, "mantis", false])
	check("boarders: teleport-arrive animation, no hull damage", [r.ship.teleporting.has(b[0]),
		r.ship.teleporting.has(b[1]), r.ship.hull], [true, true, hull0])
	check("intruder alarm waits for the arrival animation", CommandHud.intruders_arrived(r.ship), false)
	Combat._update_event_arrivals(r.ship, 0.3)
	check("still materialising at 0.3 s", r.ship.teleporting.has(b[0]), true)
	Combat._update_event_arrivals(r.ship, 0.3)
	check("arrived after 0.5 s -> intruder alarm", [r.ship.teleporting.has(b[0]),
		CommandHud.intruders_arrived(r.ship)], [false, true])
	var br := ShipState.new("PLAYER_SHIP_HARD", true)
	r.ship = br
	check("breach boarder placed", r.add_boarders({"amount": 1, "race": "anaerobic", "breach": true}), 1)
	var lan: CrewMember = br.intruders()[0]
	check("breach: no animation, a breach in its room, 1 hull damage", [br.teleporting.is_empty(),
		br.breaches.has(lan.room), br.hull], [true, true, hull0 - 1])
	for i in 14:
		r.add_boarders({"amount": 1, "race": "human", "breach": false})
	check("15 intruders aboard", br.intruders().size(), 15)
	check("no boarders added at 15 intruders", r.add_boarders({"amount": 2, "race": "human"}), 0)
	check("amount 0 adds nothing", r.add_boarders({"amount": 0, "race": "human"}), 0)
	# Super shield: the event text gets the intruder_energy line; the reward box gets the intruder alert.
	r.ship = ShipState.new("PLAYER_SHIP_HARD", true)
	r.ship.super_shield = 3
	var ev := r.engine.new_event("BOARD_TEST")
	ev.text = "boarded"
	ev.content = true
	ev.boarders = {"amount": 2, "race": "ghost", "breach": false}
	ev.environment = HazardRule.Env.ASTEROIDS
	r.show_event(ev)
	check("super shield: intruder_energy appended", r.dialog.text,
		"boarded \n\n" + r.engine.tr_text("intruder_energy"))
	check("boarders listed in the rewards", r.dialog_rewards.has(["boarders", 2]), true)
	check("ghost boarders: 50 HP", r.ship.intruders().map(func(c): return c.max_hp), [50.0, 50.0])
	check("choice outcome environment starts the hazard", r.hazard != null and r.hazard.env == 1, true)
	r.hazard = null


## Event reward box items (ChoiceBox::RenderResources): weapon / drone / augment icon + name, alert line.
func _reward_box_checks() -> void:
	print("Reward box items (RenderResources)")
	var lay := ResourceBox.layout({"scrap": 7, "weapon": "MISSILES_2_PLAYER"}, false)
	var kinds := (lay.ops as Array).map(func(o): return o[1])
	check("  weapon: icon + title after the resources", kinds, ["res", "weapon", "text"])
	check("  weapon title is the blueprint title", lay.ops[2][3], FtlData.blueprint_title("MISSILES_2_PLAYER", "weapon"))
	var d := WeaponIcon.weapon_dims("MISSILES_2_PLAYER")
	check("  weapon icon after scrap (5 + 45) + 20, centred on its rotated width",
		lay.ops[1][3], Vector2(70 + int(d.x) / 2, 16))
	check("  row height max(32, art h + 9)", lay.size.y, maxf(32, d.y + 9))
	check("  item only (no resources): starts at row_x 5",
		ResourceBox.layout({"augment": "NANO_MEDBAY"}, false).ops[0][4], Vector2(5, 9))
	check("  augment label", ResourceBox.layout({"augment": "NANO_MEDBAY"}, false).ops[0][3], "Augment:")
	var dl := ResourceBox.layout({"drone": "REPAIR"}, false)
	check("  crew-like drone: portrait op", dl.ops[0][1], "drone")
	var al := ResourceBox.layout({"weapon": "BEAM_1", "alerts": [["3 damage to your hull", false]]}, false)
	var last: Array = al.ops[al.ops.size() - 1]
	check("  alert line centred under the items, 28 px lower", [last[1], last[4].y], ["ctext", 37.0])
	check("  alert red when only bad", last[5], "loss")
	check("  box height = first row + 24", al.size.y, ResourceBox.layout({"weapon": "BEAM_1"}, false).size.y + 24)
	var mixed := ResourceBox.layout({"alerts": [["a", true], ["b", false]]}, false)
	check("  alerts alone: left at 30, white when mixed, joined by 5 spaces",
		[mixed.ops[0][4].x, mixed.ops[0][5], mixed.ops[0][3]], [30.0, "white", "a     b"])
	check("  choice box hides the alert line", ResourceBox.is_empty({"alerts": [["a", true]]}, true), true)
	var cb := ResourceBox.layout({"scrap": 7, "weapon": "BEAM_1"}, true)
	check("  choice box: items on a second row", cb.ops[1][3].y > 32, true)
	var box := EventBox.new()
	var res := box._reward_resources([["cargo", "BEAM_1"], ["hull", -3], ["boarders", 2]], {"modify_pursuit": -1})
	check("  cargo weapon shown as the weapon", res.get("weapon", ""), "BEAM_1")
	check("  alerts: intruders, fleet delayed, damage", (res.alerts as Array).map(func(a): return a[0]),
		[FtlData.tr_id("intruder_alert"), FtlData.tr_id("fleet_delayed_1"), "3 damage to your hull"])
	box.free()
