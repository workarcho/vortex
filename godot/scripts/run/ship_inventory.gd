class_name ShipInventory
extends RefCounted
## Equipment boxes of the player ship (rules/ship_management.md §2.1, §2.3, §3, §6): weapon / drone slots (the
## ShipState lists, slot order = depower order), 3 augment slots (`ship.augments`), 4 cargo boxes (`run.cargo`,
## positional: "" = empty box), the over-capacity item box and the over-capacity augment box (this object).
## Pure rules: hold / accept matrix, move-or-swap, sell, rewards (slot → cargo → over box → EQUIP_FULL) and the
## jump that drops the over items. Box refs are Vector2i(kind, index).

enum { WEAPON, DRONE, AUG, CARGO, OVER, OVER_AUG }

const AUG_SLOTS := 3
const CARGO_SLOTS := 4
const NONE := Vector2i(-1, -1)

var over_item := {}  # {kind: "weapon" | "drone", name} in the over-capacity box (bOverCapacity)
var over_aug := ""  # augment in the over-capacity augment box (bOverAugCapacity)
var over_active := false  # bOverCapacity: the over box is shown (stays until the jump, even if emptied)
var over_aug_active := false
var open_request := false  # Equipment::Open by itself (an over-capacity reward): the window must open


# ------------------------------------------------------------------ boxes

## All boxes in vEquipmentBoxes order (§2.1), including the inactive over boxes.
static func all_boxes(run: RunState) -> Array:
	var out := []
	for i in maxi(run.ship.weapon_slots, 0):
		out.append(Vector2i(WEAPON, i))
	for i in maxi(run.ship.drone_slots, 0):
		out.append(Vector2i(DRONE, i))
	for i in AUG_SLOTS:
		out.append(Vector2i(AUG, i))
	for i in CARGO_SLOTS:
		out.append(Vector2i(CARGO, i))
	out.append(Vector2i(OVER, 0))
	out.append(Vector2i(OVER_AUG, 0))
	return out


## Equipment::ValidBox: weapon slots need the weapon system, drone slots the drone system, over boxes their flag.
func valid(run: RunState, b: Vector2i) -> bool:
	match b.x:
		WEAPON:
			return run.ship.sys("weapons") != null and b.y >= 0 and b.y < run.ship.weapon_slots
		DRONE:
			return run.ship.sys("drones") != null and b.y >= 0 and b.y < run.ship.drone_slots
		AUG:
			return b.y >= 0 and b.y < AUG_SLOTS
		CARGO:
			return b.y >= 0 and b.y < CARGO_SLOTS
		OVER:
			return over_active
		OVER_AUG:
			return over_aug_active
	return false


static func is_cargo(b: Vector2i) -> bool:
	return b.x == CARGO or b.x == OVER


## The item in a box: {kind, name} or {} (empty).
func item_at(run: RunState, b: Vector2i) -> Dictionary:
	var ship := run.ship
	match b.x:
		WEAPON:
			if b.y >= 0 and b.y < ship.weapons.size():
				return {"kind": "weapon", "name": String(ship.weapons[b.y].bp.name)}
		DRONE:
			if b.y >= 0 and b.y < ship.drones.size():
				return {"kind": "drone", "name": String(ship.drones[b.y].bp.get("name", ""))}
		AUG:
			if b.y >= 0 and b.y < ship.augments.size():
				return {"kind": "augment", "name": String(ship.augments[b.y])}
		CARGO:
			if b.y >= 0 and b.y < run.cargo.size() and String(run.cargo[b.y]) != "":
				var nm := String(run.cargo[b.y])
				return {"kind": item_kind(nm), "name": nm}
		OVER:
			return over_item.duplicate()
		OVER_AUG:
			if over_aug != "":
				return {"kind": "augment", "name": over_aug}
	return {}


## Weapon or drone, from the blueprints (cargo holds bare names).
static func item_kind(nm: String) -> String:
	if not FtlData.item_info("weapon", nm).is_empty():
		return "weapon"
	if not FtlData.item_info("drone", nm).is_empty():
		return "drone"
	return "augment" if not FtlData.item_info("augment", nm).is_empty() else "weapon"


# ------------------------------------------------------------------ hold / accept (§2.3)

func can_hold_weapon(run: RunState, b: Vector2i) -> bool:
	match b.x:
		WEAPON:
			return run.ship.sys("weapons") != null
		CARGO, OVER:
			var it := item_at(run, b)
			return it.is_empty() or it.kind == "weapon"
	return false


func can_hold_drone(run: RunState, b: Vector2i) -> bool:
	match b.x:
		DRONE:
			return run.ship.sys("drones") != null
		CARGO, OVER:
			var it := item_at(run, b)
			return it.is_empty() or it.kind == "drone"
	return false


static func can_hold_augment(b: Vector2i) -> bool:
	return b.x == AUG or b.x == OVER_AUG


## Dragging the item of `s` over `t`: accepted (white) or blocked (red). Equipment::OnLoop / MouseUp.
func accepts(run: RunState, s: Vector2i, t: Vector2i) -> bool:
	if s == t or not valid(run, s) or not valid(run, t):
		return false
	var x := item_at(run, s)
	if x.is_empty():
		return false
	if x.kind == "weapon" and can_hold_weapon(run, t):
		return true
	if x.kind == "drone" and can_hold_drone(run, t):
		return true
	if x.kind == "augment" and can_hold_augment(t) and item_at(run, t).is_empty():
		return true
	if is_cargo(s) and is_cargo(t):
		return true
	if s.x == OVER_AUG and can_hold_augment(t):
		return true
	if t.x == OVER_AUG and can_hold_augment(s):
		return true
	return false


# ------------------------------------------------------------------ moves

## Drop on an accepted box: move (target empty) or swap (target filled). Returns true if something moved.
func move_or_swap(run: RunState, s: Vector2i, t: Vector2i) -> bool:
	if not accepts(run, s, t):
		return false
	var ship := run.ship
	# Within the weapon / drone / augment lists the slot order is the list order (combat depower order).
	if s.x == t.x and s.x == WEAPON:
		if t.y < ship.weapons.size():
			ship.swap_weapons(s.y, t.y)
		else:
			var w: WeaponState = ship.weapons[s.y]
			ship.weapons.remove_at(s.y)
			ship.weapons.append(w)
		_renumber(ship)
		return true
	if s.x == t.x and s.x == DRONE:
		if t.y < ship.drones.size():
			DroneSystemRule.swap_drones(ship, s.y, t.y)
		else:
			var d: Drone = ship.drones[s.y]
			ship.drones.remove_at(s.y)
			ship.drones.append(d)
		_renumber(ship)
		return true
	if s.x == t.x and s.x == AUG:
		if t.y < ship.augments.size():
			var a: Variant = ship.augments[s.y]
			ship.augments[s.y] = ship.augments[t.y]
			ship.augments[t.y] = a
		return true
	var a_item := item_at(run, s)
	var b_item := item_at(run, t)
	# Augments leave the ship before being re-added (effects follow the slot); the target is filled first so the
	# compacting lists keep the source index valid.
	_put(run, t, a_item)
	_put(run, s, b_item)
	_renumber(ship)
	return true


## Puts `it` ({} = empty) into box `b`. Weapon / drone slots: replacing or removing depowers; an index past the
## list end appends (the lists stay compact: slot i = weapons[i]).
func _put(run: RunState, b: Vector2i, it: Dictionary) -> void:
	var ship := run.ship
	match b.x:
		WEAPON:
			if b.y < ship.weapons.size():
				ship.depower_weapon(ship.weapons[b.y])
				ship.weapons[b.y].powered = false
				if it.is_empty():
					ship.weapons.remove_at(b.y)
				else:
					ship.weapons[b.y] = _new_weapon(String(it.name), b.y)
			elif not it.is_empty():
				ship.weapons.append(_new_weapon(String(it.name), ship.weapons.size()))
			_sync_weapons(ship)
		DRONE:
			if b.y < ship.drones.size():
				_drop_drone(ship, ship.drones[b.y])
				if it.is_empty():
					ship.drones.remove_at(b.y)
				else:
					ship.drones[b.y] = Drone.new(FtlData.drone_blueprint(String(it.name)), ship, b.y)
			elif not it.is_empty():
				ship.drones.append(Drone.new(FtlData.drone_blueprint(String(it.name)), ship, ship.drones.size()))
			DroneSystemRule._sync(ship)
		AUG:
			if b.y < ship.augments.size():
				if it.is_empty():
					ship.augments.remove_at(b.y)
				else:
					ship.augments[b.y] = String(it.name)
			elif not it.is_empty():
				ship.augments.append(String(it.name))
		CARGO:
			while run.cargo.size() <= b.y:
				run.cargo.append("")
			run.cargo[b.y] = "" if it.is_empty() else String(it.name)
			_trim_cargo(run)
		OVER:
			over_item = it.duplicate()
		OVER_AUG:
			over_aug = "" if it.is_empty() else String(it.name)


static func _new_weapon(nm: String, slot: int) -> WeaponState:
	var ws := WeaponState.new(FtlData.weapon_blueprint(nm), slot)
	ws.powered = false
	return ws


static func _drop_drone(ship: ShipState, d: Drone) -> void:
	if d.powered:
		DroneSystemRule.depower_drone(ship, d)
	if d.deployed:
		DroneSystemRule.set_deployed(ship, d, false)


## Weapon system power = the powered weapons (WeaponSystem::RemoveWeapon depowers).
static func _sync_weapons(ship: ShipState) -> void:
	var s := ship.sys("weapons")
	if s:
		var n := 0
		for w in ship.weapons:
			if w.powered:
				n += int(w.bp.get("power", 0))
		ship._set_power(s, n)


## Slot i uses hull mount i and drone slot i (the mount stays with the slot, rules/weapon_controls.md).
static func _renumber(ship: ShipState) -> void:
	for i in ship.weapons.size():
		ship.weapons[i].mount_index = i
	for i in ship.drones.size():
		ship.drones[i].slot = i


static func _trim_cargo(run: RunState) -> void:
	while not run.cargo.is_empty() and String(run.cargo[-1]) == "":
		run.cargo.pop_back()


static func cargo_free(run: RunState) -> int:
	var n := CARGO_SLOTS - run.cargo.size()
	for nm in run.cargo:
		if String(nm) == "":
			n += 1
	return maxi(n, 0)


## First empty cargo box (never the over box), or −1.
static func first_free_cargo(run: RunState) -> int:
	for i in CARGO_SLOTS:
		if i >= run.cargo.size() or String(run.cargo[i]) == "":
			return i
	return -1


# ------------------------------------------------------------------ selling (§3)

## GetItemValue / 2 (ModifyScrapCount income = false: no Scrap Recovery bonus).
func sell_value(run: RunState, b: Vector2i) -> int:
	var it := item_at(run, b)
	if it.is_empty():
		return 0
	return RunStore.sell_value(String(it.kind), String(it.name))


## Releasing a dragged item on the sell box: scrap + floor(cost/2), the box is emptied. No confirmation.
func sell(run: RunState, b: Vector2i) -> int:
	if not valid(run, b):
		return -1
	var it := item_at(run, b)
	if it.is_empty():
		return -1
	var v := sell_value(run, b)
	_put(run, b, {})
	_renumber(run.ship)
	run.ship.scrap += v
	run._log("store: sold %s for %d" % [it.name, v])
	return v


## Every non-empty valid box (store sell list order: weapons, drones, augments, cargo, over boxes).
func sellable(run: RunState) -> Array:
	var out := []
	for b in all_boxes(run):
		if valid(run, b) and not item_at(run, b).is_empty():
			out.append(b)
	return out


# ------------------------------------------------------------------ rewards (§6)

## IsCompletelyFull(kind): no empty box that can hold it, counting the over boxes.
func is_completely_full(run: RunState, kind: String) -> bool:
	var ship := run.ship
	match kind:
		"augment":
			return ship.augments.size() >= _max_augments() and over_aug != ""
		"weapon":
			if ship.sys("weapons") != null and ship.weapons.size() < ship.weapon_slots:
				return false
		"drone":
			if ship.sys("drones") != null and ship.drones.size() < ship.drone_slots:
				return false
	return first_free_cargo(run) < 0 and not over_item.is_empty()


static func _max_augments() -> int:
	return RunTuning.i("reward", "max_augments", AUG_SLOTS)


## CommandGui::AddWeapon / AddDrone / AddAugment for an event reward: slot → first empty cargo box → the
## over-capacity box (the equipment window opens by itself) → EQUIP_FULL / AUGMENT_FULL (25 scrap).
## Returns the reward line [kind, name or amount].
func add_reward(run: RunState, kind: String, nm: String) -> Array:
	var ship := run.ship
	var full_scrap := RunTuning.i("reward", "full_cargo_scrap", 25)
	match kind:
		"weapon":
			var bp := FtlData.weapon_blueprint(nm)
			if ship.sys("weapons") != null and ship.weapons.size() < ship.weapon_slots and not bp.is_empty():
				ship.weapons.append(_new_weapon(nm, ship.weapons.size()))
				return ["weapon", nm]
		"drone":
			if ship.sys("drones") != null and ship.drones.size() < ship.drone_slots:
				ship.drones.append(Drone.new(FtlData.drone_blueprint(nm), ship, ship.drones.size()))
				DroneSystemRule._sync(ship)
				return ["drone", nm]
		"augment":
			if AugmentRule.duplicate_refused(ship, nm):  # ModifyResources: owned and not <stackable>
				ship.scrap += full_scrap  # AUGMENT_FULL
				return ["scrap", full_scrap]
			if ship.augments.size() < _max_augments() and AugmentRule.add(ship, nm):  # CommandGui::AddAugment
				return ["augment", nm]
			if over_aug == "":
				over_aug = nm
				over_aug_active = true
				open_request = true
				return ["over", nm]
			ship.scrap += full_scrap  # AUGMENT_FULL
			return ["scrap", full_scrap]
	var ci := first_free_cargo(run)
	if ci >= 0:
		while run.cargo.size() <= ci:
			run.cargo.append("")
		run.cargo[ci] = nm
		return ["cargo", nm]
	if over_item.is_empty():
		over_item = {"kind": kind, "name": nm}
		over_active = true
		open_request = true
		return ["over", nm]
	ship.scrap += full_scrap  # EQUIP_FULL
	return ["scrap", full_scrap]


## Equipment::Jump: both over-capacity items are left behind.
func on_jump(run: RunState) -> void:
	if not over_item.is_empty() or over_aug != "":
		run._log("left behind at the jump: %s %s" % [over_item.get("name", ""), over_aug])
	over_item = {}
	over_aug = ""
	over_active = false
	over_aug_active = false
	open_request = false
