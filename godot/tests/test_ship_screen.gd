extends Node
## Tests for rules/ship_management.md: upgrade costs (blueprint upgradeCost levels), reactor cost rule, scrap taken
## per click, refund / undo, commit on close and on tab switch; equipment hold / accept table, move / swap (slot
## order = combat order, mounts follow the slot), sell price floor(cost/2) and selling by drag in store mode;
## the over-capacity reward flow (slot → cargo → over box + auto-open → EQUIP_FULL 25 scrap; lost at the jump);
## crew rename (15 chars), dismiss rules (confirmation, min crew), the 9th-crew lock. Run:
##   godot --headless --path godot res://tests/test_ship_screen.tscn

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
	r.enemy = {}
	return r


func send(r: RunState, type: String, extra := {}) -> bool:
	return r.apply(ShipManagement.make(type, extra))


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	_test_upgrades()
	_test_equipment_rules()
	_test_over_capacity()
	_test_sell()
	_test_crew()
	_test_box_labels()
	_test_reactor_info()
	_test_drag_highlights()
	await _test_drag_source_empty(false)
	await _test_drag_source_empty(true)


## Equipment drag highlights (EquipmentBox::OnRender @0052b3d0, Equipment::OnLoop @00524fb0 / MouseMove @00525580):
## box images untinted; while dragging, box_overlay_red.png (alpha 0.2) × overlayColor/255 at alpha 0.5 — COLOR_GREEN
## on every unblocked box for a weapon / drone drag (filled slots and the source too), COLOR_RED on blocked boxes,
## nothing on augment boxes; the source box draws empty; glow = hovered non-empty box (idle) / hovered unblocked box
## (dragging).
func _test_drag_highlights() -> void:
	print("equipment drag highlights")
	var r := make_run()
	var ship := r.ship
	ship.augments = ["SCRAP_COLLECTOR"]
	r.give_item("drone", "COMBAT_1")  # no drone system: goes to cargo 0
	var ev := EquipmentView.new()
	var pc := InputProfile.new(InputProfile.PC)
	pc.run = r
	ev.setup(r, pc)
	add_child(ev)
	var W0 := Vector2i(ShipInventory.WEAPON, 0)
	var W1 := Vector2i(ShipInventory.WEAPON, 1)
	var W3 := Vector2i(ShipInventory.WEAPON, 3)
	var A0 := Vector2i(ShipInventory.AUG, 0)
	var A1 := Vector2i(ShipInventory.AUG, 1)
	var C0 := Vector2i(ShipInventory.CARGO, 0)
	var C1 := Vector2i(ShipInventory.CARGO, 1)
	var none := ShipInventory.NONE
	var clear := Color(1, 1, 1, 0)
	var green := Color(EquipmentView.COL_GREEN, 0.5)
	var red := Color(EquipmentView.COL_RED, 0.5)
	check("overlay image / alpha", [EquipmentView.OVERLAY_IMG, EquipmentView.OVERLAY_ALPHA],
		["upgradeUI/Equipment/box_overlay_red.png", 0.5])
	var ov := FtlData.texture("img/" + EquipmentView.OVERLAY_IMG).get_image()
	check("overlay art: white at alpha 51 (10 % wash after × 0.5)", ov.get_pixel(54, 38), Color8(255, 255, 255, 51))
	check("weapon colours COLOR_GREEN / COLOR_RED", [EquipmentView.COL_GREEN, EquipmentView.COL_RED],
		[Color8(100, 255, 100), Color8(255, 50, 50)])
	# idle
	check("idle: filled weapon, no overlay", ev.box_look(W0, none, false), {"img":
		"upgradeUI/Equipment/box_weapons_on.png", "empty": false, "overlay": clear})
	check("idle: hovered filled box glows", ev.box_look(W0, W0, false).img, "upgradeUI/Equipment/box_weapons_selected.png")
	check("idle: hovered empty box does not glow", ev.box_look(W3, W3, false).img,
		"upgradeUI/Equipment/box_weapons_off.png")
	check("idle: empty cargo = base", ev.box_look(C1, none, false).img, "upgradeUI/Equipment/box_base_off.png")
	# weapon drag from slot 0, pointer over slot 1
	ev.press(ev.box_rect(W0).get_center())
	check("mouse press drags", ev.dragging(), true)
	check("weapon drag: source drawn empty, green, glows when hovered", ev.box_look(W0, W0, true), {"img":
		"upgradeUI/Equipment/box_weapons_off_selected.png", "empty": true, "overlay": green})
	check("weapon drag: other filled slot keeps its item art + green wash", ev.box_look(W1, none, true), {"img":
		"upgradeUI/Equipment/box_weapons_on.png", "empty": false, "overlay": green})
	check("weapon drag: hovered filled slot glows", ev.box_look(W1, W1, true).img,
		"upgradeUI/Equipment/box_weapons_selected.png")
	check("weapon drag: empty slot green", ev.box_look(W3, none, true).overlay, green)
	check("weapon drag: empty cargo green", ev.box_look(C1, none, true), {"img":
		"upgradeUI/Equipment/box_base_off.png", "empty": true, "overlay": green})
	check("weapon drag: cargo holding a drone is blocked (red, no glow)", [ev.box_look(C0, C0, true).overlay,
		ev.box_look(C0, C0, true).img], [red, "upgradeUI/Equipment/box_drones_on.png"])
	check("weapon drag: augment boxes untouched (no overlay, no glow)", [ev.box_look(A0, A0, true),
		ev.box_look(A1, none, true).overlay], [{"img": "upgradeUI/Equipment/box_augment_on.png", "empty": false,
		"overlay": clear}, clear])
	ev.release(Vector2(5, 5))
	# augment drag: no green anywhere; weapon / cargo boxes blocked (red); augment boxes never tinted
	ev.press(ev.box_rect(A0).get_center())
	check("augment drag: weapon slot red", ev.box_look(W1, none, true).overlay, red)
	check("augment drag: empty cargo red", ev.box_look(C1, none, true).overlay, red)
	check("augment drag: empty augment slot glows, no overlay", ev.box_look(A1, A1, true), {"img":
		"upgradeUI/Equipment/box_augment_off_selected.png", "empty": true, "overlay": clear})
	check("augment drag: source slot (blocked in the exe) does not glow", ev.box_look(A0, A0, true).img,
		"upgradeUI/Equipment/box_augment_off.png")
	ev.release(Vector2(5, 5))
	# drone drag from cargo (no drone system): cargo green (cargo ↔ cargo), weapon slots red
	ev.press(ev.box_rect(C0).get_center())
	check("cargo drone drag: other cargo green, weapon slot red, source base + green", [ev.box_look(C1, none,
		true).overlay, ev.box_look(W0, none, true).overlay, ev.box_look(C0, none, true)], [green, red, {"img":
		"upgradeUI/Equipment/box_base_off.png", "empty": true, "overlay": green}])
	ev.release(Vector2(5, 5))
	ev.queue_free()


## The dragged item is carried (EquipmentBox::OnRender with forcedEmpty on the drag source): while a weapon is
## dragged its own box draws no icon / label, the item is drawn once at the pointer, and the other boxes keep
## theirs. Real input events through _gui_input, mouse (drag on press) and touch (drag after 9 px).
func _test_drag_source_empty(touch: bool) -> void:
	print("equipment drag: source box empty (%s)" % ("touch" if touch else "mouse"))
	var r := make_run()
	r.give_item("weapon", "LASER_HEAVY_1")
	var prof := InputProfile.new(InputProfile.TOUCH if touch else InputProfile.PC)
	prof.run = r
	var scr := ShipScreen.new()
	scr.setup(r, prof)
	add_child(scr)
	send(r, RunIntent.OPEN_SHIP_SCREEN, {"arg": 2})
	var ev := scr.equip_view
	var names: Array = r.ship.weapons.map(func(w): return String(w.bp.name))
	var W1 := Vector2i(ShipInventory.WEAPON, 1)
	var c := ev.box_rect(W1).get_center()
	var away := ev.box_rect(Vector2i(ShipInventory.CARGO, 1)).get_center() + Vector2(0, 40)
	_mouse(ev, c, true)
	_motion(ev, c + Vector2(4, 0))
	_motion(ev, away)
	await _frames(2)
	var drawn: Array = ev.drawn_items.map(func(e): return e[0])
	check("dragging", ev.dragging(), true)
	check("source box draws no item", drawn.has(W1), false)
	check("the other weapons keep theirs", [drawn.has(Vector2i(ShipInventory.WEAPON, 0)),
		drawn.has(Vector2i(ShipInventory.WEAPON, 2))], [true, true])
	check("the dragged item is drawn at the pointer", ev.drawn_dragged.get("name", ""), names[1])
	check("source look: empty box", ev.box_look(W1, ShipInventory.NONE, true).empty, true)
	_mouse(ev, away, false)
	await _frames(2)
	check("released away: nothing moved", r.ship.weapons.map(func(w): return String(w.bp.name)), names)
	check("released: the source draws its item again, nothing at the pointer",
		[ev.drawn_items.map(func(e): return e[0]).has(W1), ev.drawn_dragged], [true, {}])
	scr.queue_free()
	await _frames(1)


func _mouse(ev: Control, p: Vector2, down: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = down
	e.position = p
	e.global_position = p
	ev._gui_input(e)


func _motion(ev: Control, p: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = p
	e.global_position = p
	e.button_mask = MOUSE_BUTTON_MASK_LEFT
	ev._gui_input(e)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## Upgrades::OnLoop, reactor hovered [exe]: InfoBox::SetText(upgrade_reactor, reactor_desc); below 5 bars (reactor +
## pending) the short text and the weak_warning line.
func _test_reactor_info() -> void:
	print("upgrades: reactor info box")
	var r := make_run()
	var ses := r.mgmt.upgrades
	r.ship.reactor_max = 8
	var d := UpgradesView.reactor_info(r.ship, ses)
	check("reactor box: title / text / no warning", [d.title, d.description, d.warning], [FtlData.tr_id(
		"upgrade_reactor"), FtlData.tr_id("reactor_desc"), ""])
	check("reactor box: a text box (default 323 x 121 frame)", [d.kind, ItemInfoBox.frame_rect(Vector2.ZERO, d.kind).size],
		["text", Vector2(323, 121)])
	r.ship.reactor_max = 3
	ses.reactor_temp = 1
	d = UpgradesView.reactor_info(r.ship, ses)
	check("reactor 3 + 1 pending: short text + weak warning", [d.description, d.warning], [FtlData.tr_id(
		"reactor_desc_short"), FtlData.tr_id("weak_warning")])
	ses.reactor_temp = 2
	check("reactor 3 + 2 pending: the full text again", UpgradesView.reactor_info(r.ship, ses).warning, "")
	ses.reactor_temp = 0


func _test_upgrades() -> void:
	print("upgrades")
	check("reactor cost table", [4, 5, 9, 10, 14, 15, 19, 20, 24].map(func(n): return UpgradeSession.reactor_cost(n)),
		[30, 20, 20, 25, 25, 30, 30, 35, 35])
	var r := make_run()
	var ship := r.ship
	ship.scrap = 100
	check("engines upgradeCost from the blueprint", UpgradeSession.system_info("engines").costs.slice(0, 3), [10, 15, 30])
	check("open on Upgrades", send(r, RunIntent.OPEN_SHIP_SCREEN, {"arg": 0}), true)
	check("modal while open", r.modal(), true)
	var ses := r.mgmt.upgrades
	var lv := ship.sys("engines").level
	var c1 := ses.cost_next(ship, "engines")
	check("cost = upgradeCosts[level − 1]", c1, UpgradeSession.system_info("engines").costs[lv - 1])
	check("buy takes the scrap at once", [send(r, RunIntent.UPGRADE_BUY, {"sys": "engines"}), ship.scrap], [true, 100 - c1])
	check("level not applied yet", ship.sys("engines").level, lv)
	var c2 := ses.cost_next(ship, "engines")
	check("next cost uses current + temp", c2, UpgradeSession.system_info("engines").costs[lv])
	send(r, RunIntent.UPGRADE_BUY, {"sys": "engines"})
	check("refund the last temp level", [send(r, RunIntent.UPGRADE_REFUND, {"sys": "engines"}), ship.scrap],
		[true, 100 - c1])
	var rmax := ship.reactor_max
	send(r, RunIntent.UPGRADE_BUY, {"sys": "reactor"})
	check("reactor bought at its cost", ship.scrap, 100 - c1 - UpgradeSession.reactor_cost(rmax))
	check("undo refunds everything", [send(r, RunIntent.UPGRADE_UNDO), ship.scrap, ses.has_pending()], [true, 100, false])
	ship.scrap = 5
	check("not enough scrap", [send(r, RunIntent.UPGRADE_BUY, {"sys": "engines"}), r.mgmt.last_result, ship.scrap],
		[false, "scrap", 5])
	ship.scrap = 200
	send(r, RunIntent.UPGRADE_BUY, {"sys": "engines"})
	send(r, RunIntent.UPGRADE_BUY, {"sys": "reactor"})
	check("tab switch commits", [send(r, RunIntent.SET_TAB, {"arg": 2}), ship.sys("engines").level, ship.reactor_max],
		[true, lv + 1, rmax + 1])
	check("flags", r.mgmt.last_flags, ["system_upgrade", "reactor_upgrade"])
	send(r, RunIntent.SET_TAB, {"arg": 0})
	var s0 := ship.scrap
	send(r, RunIntent.UPGRADE_BUY, {"sys": "shields"})
	check("close commits (no cancel)", [send(r, RunIntent.CLOSE_SHIP_SCREEN), ship.sys("shields").level, ship.scrap < s0],
		[true, 3, true])
	# max level: blocked
	var sh := ship.sys("oxygen")
	sh.level = UpgradeSession.max_level(ship, "oxygen")
	send(r, RunIntent.OPEN_SHIP_SCREEN, {"arg": 0})
	check("maxed system", [r.mgmt.upgrades.cost_next(ship, "oxygen"), send(r, RunIntent.UPGRADE_BUY, {"sys": "oxygen"})],
		[-1, false])
	ship.reactor_max = 25
	check("reactor max 25", r.mgmt.upgrades.reactor_cost_next(ship), -1)
	send(r, RunIntent.CLOSE_SHIP_SCREEN)
	# layout: 12 boxes, 4 subsystem boxes in the bottom row
	var lay := UpgradeSession.layout(ship)
	check("12 boxes, 4 bottom", [lay.size(), lay.filter(func(e): return not e.top).size()], [12, 4])
	# opening is blocked with a hostile ship
	r.enemy = {"hostile": true, "done": false}
	check("no ship screen in danger", send(r, RunIntent.OPEN_SHIP_SCREEN, {"arg": 0}), false)
	r.enemy = {}


func _test_equipment_rules() -> void:
	print("equipment drag rules")
	var r := make_run()
	var inv := r.mgmt.inv
	var ship := r.ship
	var W := func(i): return Vector2i(ShipInventory.WEAPON, i)
	var C := func(i): return Vector2i(ShipInventory.CARGO, i)
	var A := func(i): return Vector2i(ShipInventory.AUG, i)
	var D := Vector2i(ShipInventory.DRONE, 0)
	r.cargo = ["DEFENSE_1", "LASER_BURST_1"]
	ship.augments = ["SCRAP_COLLECTOR"]
	var nw := ship.weapons.size()
	# hold rules
	check("weapon slot holds weapons (system installed)", inv.can_hold_weapon(r, W.call(0)), true)
	check("weapon slot never holds drones", inv.can_hold_drone(r, W.call(0)), false)
	check("cargo with a drone cannot hold a weapon", inv.can_hold_weapon(r, C.call(0)), false)
	check("empty cargo holds both", [inv.can_hold_weapon(r, C.call(2)), inv.can_hold_drone(r, C.call(2))], [true, true])
	check("augments only in augment boxes", [ShipInventory.can_hold_augment(A.call(1)),
		ShipInventory.can_hold_augment(C.call(2))], [true, false])
	check("no drone system: drone slot invalid", inv.valid(r, D), ship.sys("drones") != null)
	# accept table
	check("weapon → empty cargo", inv.accepts(r, W.call(0), C.call(2)), true)
	check("weapon → cargo weapon (swap)", inv.accepts(r, W.call(0), C.call(1)), true)
	check("weapon → cargo drone blocked", inv.accepts(r, W.call(0), C.call(0)), false)
	check("cargo ↔ cargo swaps anything", inv.accepts(r, C.call(0), C.call(1)), true)
	check("drone → weapon slot blocked", inv.accepts(r, C.call(0), W.call(0)), false)
	check("augment → cargo blocked", inv.accepts(r, A.call(0), C.call(2)), false)
	check("augment → empty augment box", inv.accepts(r, A.call(0), A.call(2)), true)
	check("over box inactive: invalid target", inv.accepts(r, W.call(0), Vector2i(ShipInventory.OVER, 0)), false)
	check("empty source", inv.accepts(r, C.call(3), C.call(2)), false)
	# moves
	send(r, RunIntent.OPEN_SHIP_SCREEN, {"arg": 2})
	var w0 := ship.weapons[0]
	var w1 := ship.weapons[1]
	check("swap two weapon slots", [inv.move_or_swap(r, W.call(0), W.call(1)), ship.weapons[0] == w1,
		ship.weapons[1] == w0, w1.mount_index, w0.mount_index], [true, true, true, 0, 1])
	w0.powered = true
	var n0 := String(ship.weapons[1].bp.name)
	check("weapon slot ↔ cargo weapon swap", [send(r, RunIntent.EQUIP_MOVE, {"src": W.call(1), "dst": C.call(1)}),
		String(r.cargo[1]), String(ship.weapons[1].bp.name), ship.weapons[1].powered], [true, n0, "LASER_BURST_1", false])
	check("weapon to empty cargo compacts the slots", [inv.move_or_swap(r, W.call(0), C.call(3)), ship.weapons.size(),
		r.cargo.size()], [true, nw - 1, 4])
	for i in ship.weapons.size():
		if ship.weapons[i].mount_index != i:
			check("mount follows slot %d" % i, ship.weapons[i].mount_index, i)
	check("cargo weapon → empty slot appends", [inv.move_or_swap(r, C.call(3), W.call(3)), ship.weapons.size(),
		r.cargo.size()], [true, nw, 2])
	check("augment move", [inv.move_or_swap(r, A.call(0), A.call(2)), ship.augments], [true, ["SCRAP_COLLECTOR"]])
	check("blocked drop does nothing", send(r, RunIntent.EQUIP_MOVE, {"src": A.call(0), "dst": C.call(2)}), false)
	send(r, RunIntent.CLOSE_SHIP_SCREEN)
	check("no move without the window", send(r, RunIntent.EQUIP_MOVE, {"src": W.call(0), "dst": C.call(3)}), false)


func _test_over_capacity() -> void:
	print("over-capacity rewards")
	var r := make_run()
	var inv := r.mgmt.inv
	var ship := r.ship
	while ship.weapons.size() < ship.weapon_slots:
		r.give_item("weapon", "LASER_BURST_1")
	r.cargo = []
	for i in 4:
		check("weapon %d to cargo" % i, r.give_item("weapon", "ION_1")[0], "cargo")
	check("completely full? not yet (over box free)", inv.is_completely_full(r, "weapon"), false)
	var sc := ship.scrap
	check("next to the over box", r.give_item("weapon", "MISSILES_1"), ["over", "MISSILES_1"])
	check("window requested", inv.open_request, true)
	r.mgmt.update(r)
	check("equipment opens by itself", [r.mgmt.open, r.mgmt.tab], [true, ShipManagement.EQUIPMENT])
	check("not locked by an over item", r.mgmt.locked(r), false)
	check("completely full now", inv.is_completely_full(r, "drone"), true)
	check("EQUIP_FULL: 25 scrap", [r.give_item("weapon", "ION_1"), ship.scrap - sc], [["scrap", 25], 25])
	var O := Vector2i(ShipInventory.OVER, 0)
	var first := String(ship.weapons[0].bp.name)
	check("over box accepts a weapon from a slot (swap)", send(r, RunIntent.EQUIP_MOVE, {"src": O,
		"dst": Vector2i(ShipInventory.WEAPON, 0)}), true)
	check("swapped in", [String(ship.weapons[0].bp.name), String(inv.over_item.name)], ["MISSILES_1", first])
	# augments
	ship.augments = ["SCRAP_COLLECTOR", "ENGINE_BOOST", "SHIELD_RECHARGE"]
	check("4th augment → over-aug box", r.give_item("augment", "AUTO_COOLDOWN"), ["over", "AUTO_COOLDOWN"])
	check("AUGMENT_FULL with both taken", r.give_item("augment", "STASIS_POD")[0], "scrap")
	var OA := Vector2i(ShipInventory.OVER_AUG, 0)
	check("over aug ↔ filled augment slot", [inv.accepts(r, OA, Vector2i(ShipInventory.AUG, 1)),
		inv.move_or_swap(r, OA, Vector2i(ShipInventory.AUG, 1)), ship.augments[1], inv.over_aug],
		[true, true, "AUTO_COOLDOWN", "ENGINE_BOOST"])
	check("installed augment → over aug box", inv.accepts(r, Vector2i(ShipInventory.AUG, 0), OA), true)
	# the jump leaves them behind
	r.jump_to(r.map.beacon(r.current_beacon).links[0])
	check("over items lost at the jump", [inv.over_item, inv.over_aug, inv.over_active, r.mgmt.open], [{}, "", false,
		false])


func _test_sell() -> void:
	print("sell")
	var r := make_run()
	var inv := r.mgmt.inv
	var ship := r.ship
	var odd := ""
	for nm in ["ION_1", "LASER_BURST_1", "MISSILES_1", "BEAM_1", "LASER_HEAVY_1"]:
		if int(FtlData.item_info("weapon", nm).cost) % 2 == 1:
			odd = nm
	var cost := int(FtlData.item_info("weapon", ship.weapons[0].bp.name).cost)
	check("sell value floor(cost/2)", inv.sell_value(r, Vector2i(ShipInventory.WEAPON, 0)), cost / 2)
	if odd != "":
		check("odd cost rounds down", RunStore.sell_value("weapon", odd), int(FtlData.item_info("weapon", odd).cost) / 2)
	var W0 := Vector2i(ShipInventory.WEAPON, 0)
	check("no selling outside the store", send(r, RunIntent.EQUIP_SELL, {"src": W0}), false)
	r.store_open = true
	r.store_tab = 1
	check("store SELL tab = equipment in store mode", r.mgmt.equipment_active(r), true)
	var sc := ship.scrap
	var nw := ship.weapons.size()
	check("drag a weapon to the sell box (no confirmation)", [send(r, RunIntent.EQUIP_SELL, {"src": W0}),
		ship.scrap - sc, ship.weapons.size()], [true, cost / 2, nw - 1])
	ship.augments = ["SCRAP_COLLECTOR"]
	sc = ship.scrap
	check("augment sold at half, no scrap-recovery bonus", [send(r, RunIntent.EQUIP_SELL, {"src": Vector2i(
		ShipInventory.AUG, 0)}), ship.scrap - sc], [true, int(FtlData.item_info("augment", "SCRAP_COLLECTOR").cost) / 2])
	check("empty box: nothing to sell", send(r, RunIntent.EQUIP_SELL, {"src": Vector2i(ShipInventory.CARGO, 2)}), false)
	# the view's drag state machine (store mode): touch drags after > 9 px, release on the sell box sells
	r.give_item("weapon", "LASER_BURST_1")
	r.give_item("weapon", "LASER_BURST_1")
	var ev := EquipmentView.new()
	var tp := InputProfile.new(InputProfile.TOUCH)
	tp.run = r
	ev.setup(r, tp)
	add_child(ev)
	var c0 := ev.box_rect(W0).get_center()
	var nw2 := ship.weapons.size()
	ev.press(c0)
	ev.motion(c0 + Vector2(6, 0))
	check("touch: no drag under 9 px", ev.dragging(), false)
	ev.motion(c0 + Vector2(12, 0))
	check("touch: drag after 9 px", ev.dragging(), true)
	sc = ship.scrap
	ev.release(ev.sell_rect().get_center())
	check("released on the sell box: sold", [ship.weapons.size(), ship.scrap > sc], [nw2 - 1, true])
	ev.press(c0)
	ev.release(c0)
	check("tap without moving selects, sells nothing", [ev._selected, ship.weapons.size()], [W0, nw2 - 1])
	var pc := InputProfile.new(InputProfile.PC)
	pc.run = r
	ev.profile = pc
	ev.press(c0)
	check("mouse: drag at once", ev.dragging(), true)
	ev.release(Vector2(5, 5))
	check("released outside: nothing happens", ship.weapons.size(), nw2 - 1)
	ev.queue_free()
	while ship.weapons.size() > 1:
		send(r, RunIntent.EQUIP_SELL, {"src": W0})
	check("the last weapon can be sold", [send(r, RunIntent.EQUIP_SELL, {"src": W0}), ship.weapons.size()], [true, 0])
	r.cargo = ["", "ION_1"]
	check("cargo positions kept / sellable list", RunStore.sellable(r).map(func(x): return [x.where, x.index]),
		[["cargo", 1]])
	check("store CanHold counts empty cargo holes", ShipInventory.cargo_free(r), 3)


func _test_crew() -> void:
	print("crew")
	var r := make_run()
	var ship := r.ship
	send(r, RunIntent.OPEN_SHIP_SCREEN, {"arg": 1})
	var crew := CrewRoster.members(ship)
	var c: CrewMember = crew[0]
	check("rename (15 chars max)", [send(r, RunIntent.CREW_RENAME, {"crew": c, "text": "Abcdefghijklmnopqrs"}),
		CrewRoster.long_name(c)], [true, "Abcdefghijklmno"])
	check("empty rename ignored", send(r, RunIntent.CREW_RENAME, {"crew": c, "text": "  "}), false)
	r.mgmt.start_rename(c)
	r.mgmt.type_rename("Zed")
	send(r, RunIntent.SET_TAB, {"arg": 0})
	check("tab change commits the rename", CrewRoster.long_name(c), "Zed")
	send(r, RunIntent.SET_TAB, {"arg": 1})
	var n := crew.size()
	check("dismiss asks first", [send(r, RunIntent.CREW_DISMISS, {"crew": c}), CrewRoster.members(ship).size(),
		r.mgmt.locked(r)], [true, n, true])
	check("locked while asking: no close", send(r, RunIntent.CLOSE_SHIP_SCREEN), false)
	check("no → kept", [send(r, RunIntent.CREW_DISMISS_CONFIRM, {"arg": 0}), CrewRoster.members(ship).size()], [false, n])
	send(r, RunIntent.CREW_DISMISS, {"crew": c})
	check("yes → gone for good", [send(r, RunIntent.CREW_DISMISS_CONFIRM, {"arg": 1}), CrewRoster.members(ship).size(),
		c in ship.crew], [true, n - 1, false])
	while CrewRoster.members(ship).size() > 1:
		send(r, RunIntent.CREW_DISMISS, {"crew": CrewRoster.members(ship)[0]})
		send(r, RunIntent.CREW_DISMISS_CONFIRM, {"arg": 1})
	check("the last crew member cannot be dismissed", send(r, RunIntent.CREW_DISMISS,
		{"crew": CrewRoster.members(ship)[0]}), false)
	send(r, RunIntent.CLOSE_SHIP_SCREEN)
	for i in 8:
		ship.add_crew("human", true)
	check("9 crew", CrewRoster.members(ship).size(), 9)
	r.mgmt.update(r)
	check("crew tab opens and locks", [r.mgmt.open, r.mgmt.tab, r.mgmt.locked(r)], [true, ShipManagement.CREW, true])
	check("locked: no tab switch, no accept", [send(r, RunIntent.SET_TAB, {"arg": 0}),
		send(r, RunIntent.CLOSE_SHIP_SCREEN)], [false, false])
	send(r, RunIntent.CREW_DISMISS, {"crew": CrewRoster.members(ship)[8]})
	send(r, RunIntent.CREW_DISMISS_CONFIRM, {"arg": 1})
	check("unlocked after dismissing", [r.mgmt.locked(r), send(r, RunIntent.CLOSE_SHIP_SCREEN)], [false, true])


## EquipmentBox::RenderLabels [exe 0052c0f0]: augment title font 13 (JustinFont12Bold 19 px) centred at box +
## (117, 14), weapon / drone short title font 6 (→ 9 JustinFont8) at box + (60, 58), both COLOR_WHITE in every state,
## one line (no wrap). Shared by the equipment screen, the store SELL tab, the over-capacity box and the hangar.
func _test_box_labels() -> void:
	print("Equipment box labels")
	check("augment label font", EquipmentView.AUG_LABEL_FONT, 13)
	check("augment label font file", FtlFont.IDS[FtlFont.resolve_id(EquipmentView.AUG_LABEL_FONT)][0], "JustinFont12Bold")
	check("augment label anchor", EquipmentView.AUG_LABEL_AT, Vector2(117, 14))
	check("item label font", FtlFont.resolve_id(EquipmentView.ITEM_LABEL_FONT), 9)
	check("item label anchor", EquipmentView.ITEM_LABEL_AT, Vector2(60, 58))
	check("label colour (white, all states)", EquipmentView.LABEL_COL, Color.WHITE)
	check("weapon icon centre (OnRender translate)", EquipmentView.WEAPON_ICON_AT, Vector2(63, 35))
	check("drone icon centre ((60, 32) + RenderIcon (0, 3))", EquipmentView.DRONE_ICON_AT, Vector2(60, 35))
	# The longest vanilla augment titles still fit the 235 px box on one line.
	for nm in ["SYSTEM_CASING", "TELEPORT_HEAL", "O2_MASKS"]:
		var w := FtlData.ftl_text_width(EquipmentView.AUG_LABEL_FONT, FtlData.blueprint_title(nm, "augment"))
		check("%s title fits the augment box (%d px)" % [nm, w], w <= int(EquipmentView.AUG_BOX.x), true)
