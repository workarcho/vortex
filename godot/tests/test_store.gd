extends Node
## Tests for rules/store.md (RunStore): generation (sections, drone override, item counts, no duplicates,
## resources, repair price), prices (blueprint cost, crew cost, drone system + free drone), buying rules (scrap,
## CanHold, cargo, augments, crew limit, systems + confirmation), resources, hull repair, selling at half, and the
## PC / touch input profiles (click buys vs select → buy). Uses the user's FTL data. Run:
##   godot --headless --path godot res://tests/test_store.tscn

const Harness := preload("res://tests/harness.gd")

var fails := 0


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func make_run(seed := 5) -> RunState:
	var r := RunState.new_run(seed)
	for i in 10:
		if r.phase == RunState.Phase.DIALOG:
			r.choose(0)
		elif r.phase == RunState.Phase.MESSAGE:
			r.apply(RunIntent.make(RunIntent.CONTINUE))
	return r


func rarity(r: RunState) -> Dictionary:
	return r.engine.db.rarity


## Puts `st` on the run's current beacon and opens it.
func open_store(r: RunState, st: RunStore) -> void:
	r.beacon().shop = st
	r.store_open = true


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	var r := make_run()
	var kestrel := r.ship
	# --- generation over many seeds
	var bad := {}
	var section_counts := {}
	for s in range(1, 120):
		var rng := RandomNumberGenerator.new()
		rng.seed = s
		var st := RunStore.generate(rng, kestrel, 0, true, rarity(r))
		var n := st.sections.size()
		section_counts[n] = true
		if n < 2 or n > 4:
			bad["2..4 sections"] = s
		var types := st.sections.map(func(x): return x.type)
		for t in types:
			if types.count(t) > 1:
				bad["distinct section types"] = s
		if kestrel.sys("drones") == null and RunStore.DRONES in types and not RunStore.SYSTEMS in types:
			bad["drone override"] = s
		for sec in st.sections:
			if sec.boxes.size() != 3:
				bad["3 boxes per section"] = s
			var names := []
			for o in sec.boxes:
				if int(o.count) == -1:
					continue
				if sec.type != RunStore.CREW and o.name in names:
					bad["no duplicates in a section"] = s
				names.append(o.name)
				if int(o.price) <= 0 and sec.type != RunStore.SYSTEMS:
					bad["price > 0"] = s
			if sec.type in [RunStore.WEAPONS, RunStore.DRONES, RunStore.AUGMENTS, RunStore.CREW] and names.size() != 3:
				bad["AE: 3 items"] = s
			if sec.type == RunStore.SYSTEMS:
				for o in sec.boxes:
					if int(o.count) > 0 and kestrel.sys(String(o.name)) != null:
						bad["systems not owned"] = s
		var f: int = st.resources.fuel.count
		var m: int = st.resources.missiles.count
		var d: int = st.resources.drones.count
		if f < 3 or f > 7 or m < 2 or m > 6 or d < 2 or d > 4:
			bad["resource stock ranges"] = s
		if [st.resources.fuel.price, st.resources.missiles.price, st.resources.drones.price] != [3, 6, 8]:
			bad["resource prices 3/6/8"] = s
	check("generation invariants over 119 seeds", bad, {})
	check("section counts 2, 3 and 4 all occur", section_counts.has(2) and section_counts.has(3) and section_counts.has(4),
		true)
	# Non-AE: 2–3 items.
	var two := false
	for s in range(1, 60):
		var rng := RandomNumberGenerator.new()
		rng.seed = s
		var st := RunStore.generate(rng, kestrel, 0, false, rarity(r))
		for sec in st.sections:
			if sec.type == RunStore.WEAPONS and sec.boxes.filter(func(o): return int(o.count) == 1).size() == 2:
				two = true
	check("non-AE stores can have 2 weapons", two, true)
	check("repair price 2 / 3 / 4 by sector", [RunStore.repair_price(0), RunStore.repair_price(2),
		RunStore.repair_price(3), RunStore.repair_price(5), RunStore.repair_price(6)], [2, 2, 3, 3, 4])
	var wr := RandomNumberGenerator.new()
	wr.seed = 3
	check("weighted draw never picks rarity 0", RunStore.random_items({"A": 0, "B": 1}, 2, wr), ["B"])

	# --- prices
	var st0 := RunStore.new()
	check("weapon price = blueprint cost", st0._offer("weapon", "LASER_BURST_2").price,
		FtlData.item_info("weapon", "LASER_BURST_2").cost)
	check("crew price human 45 / mantis 55", [st0._offer("crew", "human").price, st0._offer("crew", "mantis").price],
		[45, 55])
	var dr := RandomNumberGenerator.new()
	dr.seed = 1
	var dsys := st0._system_offer("drones", dr)
	var free_cost := int(FtlData.item_info("drone", dsys.extra.free_drone).cost)
	check("drone system price = 60 + free drone / 2 (%s)" % dsys.extra.free_drone, dsys.price, 60 + free_cost / 2)
	check("sell value = cost / 2", RunStore.sell_value("weapon", "LASER_BURST_2"),
		int(FtlData.item_info("weapon", "LASER_BURST_2").cost) / 2)

	# --- buying
	var st := RunStore.new()
	st.sections = [{"type": RunStore.WEAPONS, "boxes": [st._offer("weapon", "LASER_BURST_2"),
		st._offer("weapon", "ION_1"), st._offer("weapon", "MISSILES_1")]},
		{"type": RunStore.AUGMENTS, "boxes": [st._offer("augment", "SCRAP_COLLECTOR"),
		st._offer("augment", "ENGI_MED_BOOST"), st._offer("augment", "AUTO_COOLDOWN")]},
		{"type": RunStore.CREW, "boxes": [st._offer("crew", "human"), st._offer("crew", "engi"),
		st._offer("crew", "mantis")]},
		{"type": RunStore.SYSTEMS, "boxes": [st._offer("system", "teleporter"), st._offer("system", "cloaking"),
		st._offer("system", "clonebay")]}]
	st.resources = {"fuel": {"count": 3, "price": 3}, "missiles": {"count": 2, "price": 6},
		"drones": {"count": 2, "price": 8}}
	st.repair_cost = 2
	open_store(r, st)
	r.ship.scrap = 10
	var w0 := r.ship.weapons.size()
	check("too expensive: nothing bought", [r.store_buy(0), r.ship.scrap, r.ship.weapons.size()], ["scrap", 10, w0])
	r.ship.scrap = 1000
	check("weapon bought into a free slot", [r.store_buy(0), r.ship.weapons.size(), r.ship.scrap],
		["ok", w0 + 1, 1000 - int(st.offer(0, 0).price)])
	check("sold out after one", [st.offer(0, 0).count, r.store_buy(0)], [0, "none"])
	# fill slots → cargo → full
	r.ship.weapon_slots = r.ship.weapons.size()
	check("no slot: weapon to cargo", [r.store_buy(1), r.cargo.size()], ["ok", 1])
	r.cargo = ["A", "B", "C", "D"]
	check("weapons + cargo full: max_weapons", [RunStore.can_hold(st.offer(0, 2), r), r.store_buy(2)],
		["max_weapons", "max_weapons"])
	r.cargo = []
	check("augment bought", [r.store_buy(3), "SCRAP_COLLECTOR" in r.ship.augments], ["ok", true])
	r.ship.augments = ["A", "B", "C"]
	check("3 augments: max_augments", RunStore.can_hold(st.offer(1, 1), r), "max_augments")
	r.ship.augments = []
	var crew0 := r.ship.own_crew().size()
	check("crew bought", [r.store_buy(6), r.ship.own_crew().size()], ["ok", crew0 + 1])
	while r.ship.own_crew().size() < 8:
		r.ship.add_crew("human", true)
	check("8 crew: max_crew", RunStore.can_hold(st.offer(2, 1), r), "max_crew")
	check("system bought and installed", [r.store_buy(9), r.ship.sys("teleporter") != null], ["ok", true])
	# clonebay while owning medbay → confirmation, replacement
	var had_med := r.ship.sys("medbay") != null
	var res := r.store_buy(11)
	check("clonebay over medbay asks for confirmation", [res, st.pending_confirm.get("text_id", "")],
		["confirm" if had_med else "ok", "confirm_buy_clonebay" if had_med else ""])
	if had_med:
		check("confirm yes replaces medbay", [r.apply(RunIntent.make(RunIntent.STORE_CONFIRM, 1)),
			r.ship.sys("clonebay") != null, r.ship.sys("medbay") == null], [true, true, true])
	# resources and repair
	var fuel0 := r.ship.fuel
	check("fuel unit", [r.store_buy(RunState.BOX_FUEL), r.ship.fuel, st.resources.fuel.count], ["ok", fuel0 + 1, 2])
	check("repair refused at full hull", r.store_buy(RunState.BOX_REPAIR_ONE), "none")
	r.ship.hull = r.ship.max_hull - 5
	var sc := r.ship.scrap
	check("repair 1", [r.store_buy(RunState.BOX_REPAIR_ONE), r.ship.hull, r.ship.scrap],
		["ok", r.ship.max_hull - 4, sc - 2])
	check("repair all price", st.repair_all_price(r), 8)
	check("repair all", [r.store_buy(RunState.BOX_REPAIR_ALL), r.ship.hull], ["ok", r.ship.max_hull])
	# selling
	var items := RunStore.sellable(r)
	var wi := -1
	for i in items.size():
		if items[i].kind == "weapon":
			wi = i
			break
	var sc2 := r.ship.scrap
	var nw := r.ship.weapons.size()
	var val: int = items[wi].value
	check("sell a weapon at half price", [r.apply(RunIntent.make(RunIntent.STORE_SELL, wi)), r.ship.scrap - sc2,
		r.ship.weapons.size()], [true, val, nw - 1])

	# --- input profiles
	var rp := make_run(9)
	var sp := RunStore.new()
	sp.sections = [{"type": RunStore.WEAPONS, "boxes": [sp._offer("weapon", "LASER_BURST_1"),
		sp._offer("weapon", "ION_1"), sp._offer("weapon", "MISSILES_1")]}]
	sp.resources = {"fuel": {"count": 3, "price": 3}, "missiles": {"count": 2, "price": 6},
		"drones": {"count": 2, "price": 8}}
	open_store(rp, sp)
	rp.ship.scrap = 500
	var pc := InputProfile.new(InputProfile.PC)
	pc.run = rp
	pc.store_click(0)
	check("pc: click buys at once", sp.offer(0, 0).count, 0)
	var touch := InputProfile.new(InputProfile.TOUCH)
	touch.run = rp
	touch.store_click(1)
	check("touch: first tap selects, no purchase", [rp.store_selected, sp.offer(0, 1).count], [1, 1])
	touch.store_click(1)
	check("touch: second tap on the selected box buys", [sp.offer(0, 1).count, rp.store_selected], [0, -1])
	touch.store_click(2)
	touch.store_click(2)
	check("touch: second tap buys", sp.offer(0, 2).count, 0)
	touch.store_close()
	check("close store", rp.store_open, false)

	# --- store view layout (rules/store.md "Store screen rendering"; window at (336, 85) = the 1.6.14 screenshots,
	# the 1.6.9 exe says (340, 85))
	var rv2 := make_run(13)
	var sv_st := RunStore.new()
	sv_st.sections = [{"type": RunStore.CREW, "boxes": []}, {"type": RunStore.AUGMENTS, "boxes": [
		sv_st._offer("augment", "SCRAP_COLLECTOR")]}]
	var crng := RandomNumberGenerator.new()
	crng.seed = 4
	sv_st.sections[0].boxes = sv_st._boxes(RunStore.CREW, crng, rv2.ship, 0, true, {"crew": {"human": 1, "engi": 2}},
		[RunStore.CREW])
	while sv_st.sections[1].boxes.size() < 3:
		sv_st.sections[1].boxes.append({"kind": "augment", "name": "", "price": -1, "count": -1, "extra": {}})
	sv_st.resources = {"fuel": {"count": 3, "price": 3}, "missiles": {"count": 2, "price": 6},
		"drones": {"count": 2, "price": 8}}
	open_store(rv2, sv_st)
	rv2.ship.scrap = 1000
	var tp := InputProfile.new(InputProfile.TOUCH)
	tp.run = rv2
	var sv := StoreView.new()
	sv.setup(rv2, tp)
	var lay := {}
	for e in sv.layout():
		lay[int(e[1])] = e[0]
	check("window at (336, 85): first crew box at W + (208, 103)", lay.get(0, Rect2()).position, Vector2(544, 188))
	check("augment row at W + (203, 83 + 209)", lay.get(3, Rect2()).position, Vector2(539, 377))
	check("fuel box at W + (18, 83)", lay.get(RunState.BOX_FUEL, Rect2()).position, Vector2(354, 168))
	check("CLOSE at W + (468, 470) 103x32", lay.get(-10, Rect2()), Rect2(804, 555, 103, 32))
	check("no page tabs with 2 sections", lay.has(-11) or lay.has(-12), false)
	check("no BUY button on touch", lay.has(-20), false)
	sv_st.sections.append({"type": RunStore.WEAPONS, "boxes": [sv_st._offer("weapon", "LASER_BURST_1")]})
	lay = {}
	for e in sv.layout():
		lay[int(e[1])] = e[0]
	check("3 sections: only the other page's half is clickable (page 2 = right half)", [lay.has(-11),
		lay.get(-12, Rect2())], [false, Rect2(806, 96, 118, 32)])
	check("info box right of the window, 323 wide", ItemInfoBox.frame_rect(StoreView.WPOS + Vector2(600, 0), "crew",
		242), Rect2(943, 159, 323, 242))
	var id0: Dictionary = sv_st.sections[0].boxes[0].extra.ident
	sv.click(0)
	check("touch view: first tap selects (info), no purchase", [rv2.store_selected, sv_st.offer(0, 0).count], [0, 1])
	sv.click(0)
	check("touch view: second tap buys", sv_st.offer(0, 0).count, 0)
	var hired: CrewMember = rv2.ship.crew[-1]
	check("bought crew keeps the box's name, gender and colours", [hired.name_long, hired.male, hired.color_choices],
		[id0.name, id0.male, id0.colors])
	check("crew box label = the crew's name", StoreView.short_name(sv_st.offer(0, 1)),
		String(sv_st.offer(0, 1).extra.ident.name))
	check("weapon box label = short title", StoreView.short_name(sv_st._offer("weapon", "LASER_BURST_1")) != "", true)
	var hook := Control.new()
	sv.embed_sell_view(hook)
	tp.store_tab(1)
	lay = {}
	for e in sv.layout():
		lay[int(e[1])] = e[0]
	check("sell hook: embedded view at W, our sell rows off", [hook.get_parent() == sv, hook.position, lay.has(200)],
		[true, StoreView.WPOS, false])
	sv.free()

	# --- generated on the first visit, kept on the beacon
	var rv := make_run(11)
	var sb := -1
	for b in rv.map.beacons:
		if b.event.get("store", false) and b.id != rv.current_beacon:
			sb = b.id
			break
	check("map has a store beacon", sb >= 0, true)
	check("no store before the visit", rv.map.beacons[sb].shop, null)
	rv.jump_to(sb)
	for i in 10:
		if rv.phase == RunState.Phase.DIALOG:
			rv.choose(0)
		elif rv.phase == RunState.Phase.MESSAGE:
			rv.apply(RunIntent.make(RunIntent.CONTINUE))
	var shop: RunStore = rv.map.beacons[sb].shop
	check("store generated on arrival, not opened by itself", [shop != null, rv.store_open], [true, false])
	if not rv.has_hostile():
		var hp := InputProfile.new(InputProfile.PC)
		hp.run = rv
		rv.store_tab = 1
		hp.store_open()
		check("STORE button opens it on the BUY tab", [rv.store_open, rv.store_tab], [true, 0])
	# arrival: the event text is shown first (dialog), the store stays closed while it is up
	var ra := make_run(11)
	ra.jump_to(sb)
	check("arrival: event text first, store closed", [ra.phase != RunState.Phase.IDLE or ra.has_hostile(),
		ra.store_open], [true, false])

	_info_box_tests()
	_repair_tests()



## Info box content (rules/store.md "Info box content"): weapon stat lines as WeaponBlueprint::GetDescription builds
## them, tips, drones, items, chance strings, float format, sell drop box geometry.
func _info_box_tests() -> void:
	var ion := ItemInfoBox.content("weapon", "ION_1", true, true)
	var lines: Array = Array(String(ion.desc).split("\n")).map(func(l): return l.strip_edges())
	var stats := lines.slice(lines.find("") + 1)
	check("Ion Blast stat lines (screenshot 63)", stats, ["Required Power: 1", "Charge Time: 8 seconds",
		"Shots Per Charge: 1", "Normal Damage: 0", "Stun Chance: Low", "Ion Damage: 1"])
	check("Ion Blast tip = <tip> tip_ion", ion.tip, FtlData.tr_id("tip_ion"))
	var ion_classic := ItemInfoBox.content("weapon", "ION_1", true, false)
	check("stun chance line only with AE", "Stun Chance" in String(ion_classic.desc), false)
	var art := ItemInfoBox.weapon_description("MISSILES_1", true)
	check("missile: requires missiles, no shots line for 1 shot", ["Requires missile" in art.to_lower() or
		FtlData.tr_id("requires_missiles") in art, "Shots Per Charge" in art], [true, false])
	var beam := ItemInfoBox.weapon_description("BEAM_1", true)
	check("beam: damage per room hit", ItemInfoBox.fmt("damage_room", 1) in beam, true)
	var flak := ItemInfoBox.weapon_description("SHOTGUN_PLAYER", true)
	check("flak: shots = non-fake projectiles (1 + 2)", ItemInfoBox.fmt("shots", 3) in flak, true)
	var chain := ItemInfoBox.weapon_description("LASER_CHAINGUN", true)
	check("chain: boost speed + cap line", [FtlData.tr_id("boost_power_speed") in chain, "Chain Charge Cap" in chain],
		[true, true])
	check("chance strings 0 / 1-3 / 4-6 / 7+", [ItemInfoBox.chance_string(0), ItemInfoBox.chance_string(3),
		ItemInfoBox.chance_string(4), ItemInfoBox.chance_string(7)], ["", FtlData.tr_id("chance_low"), FtlData.tr_id("chance_medium"), FtlData.tr_id("chance_high")])
	check("float format like ostream", [ItemInfoBox.fmt_float(8.0), ItemInfoBox.fmt_float(11.5),
		ItemInfoBox.fmt_float(0.1)], ["8", "11.5", "0.1"])
	var dr := ItemInfoBox.content("drone", "REPAIR", false, true)
	check("drone: required power + drone part line, generic tip, no-system warning", [
		FtlData.tr_id("drone_required") in String(dr.desc), dr.tip != "", dr.tip_warning == FtlData.tr_id(
		"tip_drone_warning")], [true, true, true])
	check("drone with the system: no warning", ItemInfoBox.content("drone", "REPAIR", true, true).tip_warning, "")
	var fuel := ItemInfoBox.content("item", "fuel", false, true)
	check("fuel info = item blueprint title / desc, no tip", [fuel.title, fuel.desc, fuel.tip],
		[FtlData.tr_id("item_fuel_title"), FtlData.tr_id("item_fuel_desc"), ""])
	check("augment: description only", ItemInfoBox.content("augment", "SCRAP_COLLECTOR", true, true).tip, "")
	check("weapon frame 252 at location + (7, 74)", ItemInfoBox.frame_rect(Vector2(936, 60), "weapon"),
		Rect2(943, 134, 323, 252))
	check("tip frame top = location.y + 77 + 266", ItemInfoBox.tip_rect(Vector2(936, 60), ion).position.y, 403.0)
	check("sell drop box: 122 + 4 body lines × 24 − 13 = 205 high", StoreSellBox.height(), 205)


## FIX 1 / FIX ALL (RepairStoreBox): one hull point per click at repairCost, repeatable; FIX ALL = missing × cost.
func _repair_tests() -> void:
	var r := make_run(21)
	var st := RunStore.new()
	st.sections = []
	st.resources = {"fuel": {"count": 0, "price": 3}, "missiles": {"count": 0, "price": 6},
		"drones": {"count": 0, "price": 8}}
	st.repair_cost = 2
	open_store(r, st)
	r.ship.hull = r.ship.max_hull - 5
	r.ship.scrap = 86
	var pc := InputProfile.new(InputProfile.PC)
	pc.run = r
	pc.store_click(RunState.BOX_REPAIR_ONE)
	pc.store_click(RunState.BOX_REPAIR_ONE)
	check("FIX 1 twice: +2 hull, -4 scrap (screenshot 64)", [r.ship.max_hull - r.ship.hull, r.ship.scrap], [3, 82])
	check("FIX ALL price = missing × 2", st.repair_all_price(r), 6)
	r.ship.scrap = 5
	check("FIX ALL unaffordable: nothing", [r.store_buy(RunState.BOX_REPAIR_ALL), r.ship.max_hull - r.ship.hull],
		["scrap", 3])
	r.ship.scrap = 6
	check("FIX ALL heals to max", [r.store_buy(RunState.BOX_REPAIR_ALL), r.ship.hull, r.ship.scrap],
		["ok", r.ship.max_hull, 0])
	check("repair inactive at full hull", r.store_buy(RunState.BOX_REPAIR_ONE), "none")
