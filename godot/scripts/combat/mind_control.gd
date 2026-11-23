class_name MindRule
extends RefCounted
## Mind control system, system 14 (rules/mind_control.md): MindSystem::OnLoop / QueueMindControl /
## InitiateMindControl / ReleaseCrew / CanUse / SetArmed / SetHackingLevel / Jump, CrewMember::SetMindControl
## and the boosts, CombatAI::UpdateMindControl. State lives on ShipState (`mind_list`, `mind_queue`, ...).
## A controlled crew keeps its owner (`player_owned`); `CrewMember.mind_controlled` flips its side
## (`is_intruder`), so slots, door sealing, combat and the crew AIs treat it as the other side.

const TIMER := [14.0, 14.0, 20.0, 28.0]  # MIND_CONTROL_TIMER[level] (s)
const COUNT := [0, 1, 1, 1]  # MIND_CONTROL_COUNT
const HEALTH_BOOST := [0.0, 0.0, 15.0, 30.0]  # HEALTH_BOOST
const DAMAGE_BOOST := [1.0, 1.0, 1.25, 2.0]  # DAMAGE_BOOST
const LOCK := 4  # MIND_CONTROL_LOCK: 4 x 5 s = 20 s cooldown
const RESIST_SHOW := 2.0  # s the "resisted" feedback stays (visual only)
const BYPASS_AUG := "ZOLTAN_BYPASS"


## Level index: effective power; while actively hacked, the undamaged bars (healthState.first).
static func level(ship: ShipState) -> int:
	var m := ship.sys("mind")
	if m == null:
		return 0
	if m.hacked:
		return clampi(m.get_level() - m.damage, 0, 3)
	return clampi(m.effective_power(), 0, 3)


## CanUse: bCanUse, not completely destroyed, powered or under an active hack.
static func can_use(ship: ShipState) -> bool:
	var m := ship.sys("mind")
	return m != null and ship.mind_can_use and m.damage < m.get_level() and (m.effective_power() > 0 or m.hacked)


## Charged: not locked (ion / cooldown / in use / hacked) and functioning.
static func charged(ship: ShipState) -> bool:
	var m := ship.sys("mind")
	return m != null and not m.is_power_locked() and m.effective_power() > 0 and m.damage < m.get_level()


## Player MindBox: arms when usable and charged; super shields (without ZOLTAN_BYPASS) -> "blocked"
## (warning_super_shield_mind). Clicking again disarms ("off").
static func arm(ship: ShipState) -> String:
	if ship.mind_armed:
		ship.mind_armed = false
		return "off"
	if not can_use(ship) or not charged(ship) or ship.mind_in_use:
		return "no"
	if ship.mind_blocked and not ship.has_augment(BYPASS_AUG):
		return "blocked"
	ship.mind_armed = true
	return "ok"


## Armed + click on a room of either ship: every crew standing in it is queued (QueueMindControl).
static func room_clicked(ship: ShipState, on: ShipState, room: int) -> bool:
	if not ship.mind_armed or room < 0 or on == null:
		return false
	if ship.is_player and blocked_by_blackout(on, room):
		return true  # refused (tooltip mind_blocked_blackout); the click is used up but stays armed
	ship.mind_armed = false
	queue_room(ship, on, room)
	return true


## CombatControl::UpdateAiming / UpdateTarget: the player cannot mind control a blacked-out room unless it detects
## life there (a slug crew member or LIFE_SCANNER, rules/races.md "Slug").
static func blocked_by_blackout(on: ShipState, room: int) -> bool:
	return on.blacked_out_rooms().has(room) and not on.player_detects_life()


static func queue_room(ship: ShipState, on: ShipState, room: int) -> void:
	ship.mind_queue = on.crew.filter(func(c): return c.is_alive() and c.room == room)


## Remaining control fraction for the UI (1 at the start of the control, 0 at its end).
static func control_fraction(ship: ShipState) -> float:
	if not ship.mind_in_use or ship.mind_duration <= 0.0:
		return 0.0
	return clampf(1.0 - ship.mind_elapsed / ship.mind_duration, 0.0, 1.0)


## CrewMember::SetMindControl(v): leaves its slot, flips the side, takes a slot of its current room as
## the new side and walks there; manning, combat and medbay state cleared; deselected. Releasing also
## resets the boosts (CrewMember::OnLoop: boost 0, damage x1, extra HP above the base max lost).
static func set_mind(c: CrewMember, owner: ShipState, v: bool) -> void:
	if not c.is_alive():
		c.mind_controlled = v
		return
	var on := owner.ship_of(c)
	c.mind_controlled = v
	c.selected = false
	c.hovered = false
	c.target = null
	c.fighting = false
	c.shared_spot = false
	c.blocking_door = -1
	c.task = CrewMember.Task.NONE
	c.medbay_rate = 0.0
	c.manning_id = ""
	if not v:
		c.set_health_boost(0.0)
		c.mind_damage_boost = 1.0
	if on == null:
		return
	var room := c.room if c.room >= 0 else c.target_room
	c.slot = -1
	var slot := on.graph.find_slot(room, c)
	if slot < 0:
		var r := TeleporterRule.available_room(on, c, room)
		if r >= 0:
			room = r
			slot = on.graph.find_slot(r, c)
	if slot >= 0 and not c.walk_to_slot(on, room, slot):
		c.slot = slot
		c.target_room = room
	c.ai_task = CrewAI.make_task(CrewAI.IDLE, room)


## ReleaseCrew: every controlled crew freed (sound mindControlEnd each), list cleared, cooldown lock,
## timer back to idle. `lock` = LockSystem value (4 normally, 0 after a jump / when hacked).
static func release(ship: ShipState, lock := LOCK) -> void:
	var m := ship.sys("mind")
	for c in ship.mind_list:
		if c.mind_controlled:
			set_mind(c, ship, false)
			FtlData.play("mindControlEnd")
	if not ship.mind_list.is_empty() or ship.mind_in_use:
		Combat.log("%s mind control released" % ship.blueprint.name)
	ship.mind_list.clear()
	ship.mind_in_use = false
	ship.mind_elapsed = ship.mind_duration
	if m:
		m.lock_system(lock)


## MindSystem::SetHackingLevel: releases when entering a pulse (then LockSystem(0): usable by the hacker)
## and again when the pulse ends (normal 20 s cooldown).
static func on_hacked(ship: ShipState, now_hacked: bool) -> void:
	if now_hacked:
		release(ship, 0)
	else:
		release(ship)


## Jump: release with no cooldown.
static func jump(ship: ShipState) -> void:
	release(ship, 0)


## ShipDestroyed: release.
static func ship_destroyed(ship: ShipState) -> void:
	if ship.sys("mind") != null:
		release(ship)


static func _living_non_drone(list: Array) -> Array:
	return list.filter(func(c): return c.is_alive() and not c.is_drone())


## MindSystem::OnLoop (called from ShipState.tick).
static func tick(ship: ShipState, seconds: float) -> void:
	for c in ship.crew:
		if c.resisted > 0.0:
			c.resisted = maxf(c.resisted - seconds, 0.0)
	var m := ship.sys("mind")
	if m == null:
		return
	# ShipManager::OnLoop flags: bCanUse (intruders aboard, or a hostile target with crew aboard it) and
	# bBlocked (target super shields, no intruders aboard, none of our crew aboard is controlled).
	var intruders := _living_non_drone(ship.intruders())
	var t := ship.opponent
	var target_crew := []
	if t != null and t.hostile and not t.is_destroyed():
		target_crew = _living_non_drone(t.crew).filter(func(c): return not c.is_intruder(t))
	ship.mind_can_use = not intruders.is_empty() or not target_crew.is_empty()
	var own_controlled := false
	for s in [ship, t]:
		if s == null:
			continue
		for c in s.crew:
			if c.is_alive() and c.mind_controlled and c.player_owned == ship.is_player:
				own_controlled = true
	ship.mind_blocked = t != null and t.super_shield > 0 and intruders.is_empty() and not own_controlled
	var p := level(ship)
	var dur: float = TIMER[p]
	if dur != ship.mind_duration:
		ship.mind_duration = dur
		if not ship.mind_in_use:
			ship.mind_elapsed = dur
	# Prune crew that died, left the game or were freed (e.g. by the other side's mind control).
	for c in ship.mind_list.duplicate():
		if not c.is_alive() or not c.mind_controlled or ship.ship_of(c) == null:
			ship.mind_list.erase(c)
			if not c.is_alive():
				c.mind_controlled = false  # a body is nobody's
	if ship.mind_in_use and ship.mind_list.is_empty():
		release(ship)
	elif ship.mind_list.size() > COUNT[p]:
		var first: CrewMember = ship.mind_list.pop_front()
		set_mind(first, ship, false)
		FtlData.play("mindControlEnd")
		if ship.mind_list.is_empty():
			release(ship)
	if ship.mind_in_use:
		ship.mind_elapsed += seconds
		if ship.mind_elapsed >= ship.mind_duration:
			release(ship)
	for c in ship.mind_list:
		c.set_health_boost(HEALTH_BOOST[p])
		c.mind_damage_boost = DAMAGE_BOOST[p]
	if not ship.mind_queue.is_empty():
		if can_use(ship):
			initiate(ship)
		ship.mind_queue.clear()


## InitiateMindControl: filter the queue, Slugs resist, lock -1, control (or free) one random crew.
static func initiate(ship: ShipState) -> void:
	var m := ship.sys("mind")
	var hacked := m.hacked
	var keep := []
	for c: CrewMember in ship.mind_queue:
		if not c.is_alive() or c.is_drone():
			continue
		var same := c.player_owned == ship.is_player
		if hacked:
			same = not same  # actively hacked: it targets its own ship's crew
		if same and not c.mind_controlled:
			continue
		if not same and c.mind_controlled:
			continue
		var on := ship.ship_of(c)
		if on == null:
			continue
		if on != ship and on.super_shield > 0 and not ship.has_augment(BYPASS_AUG):
			continue
		keep.append(c)
	var targets := keep.filter(func(c): return not c.is_telepathic())
	if targets.is_empty():
		return  # only Slugs (or nobody): nothing happens, no cooldown
	for c in keep:
		if c.is_telepathic():
			c.resisted = RESIST_SHOW
	m.lock_system(-1)
	ship.mind_in_use = true
	ship.mind_elapsed = 0.0
	for i in COUNT[level(ship)]:
		if targets.is_empty():
			break
		var c: CrewMember = targets.pop_at(ship.rng.randi() % targets.size())
		if not c.mind_controlled:
			set_mind(c, ship, true)
			ship.mind_list.append(c)
			c.set_health_boost(HEALTH_BOOST[level(ship)])
			c.mind_damage_boost = DAMAGE_BOOST[level(ship)]
			FtlData.play("mindControl")
			Combat.log("%s mind-controls %s (%s crew) in room %d for %.0f s" % [ship.blueprint.name, c.race,
				"player" if c.player_owned else "enemy", c.room, ship.mind_duration])
		else:
			set_mind(c, ship, false)
			FtlData.play("mindControlEnd")
			Combat.log("%s frees %s from mind control" % [ship.blueprint.name, c.race])


## CombatAI::UpdateMindControl(hostile). The player ship's system only runs while actively hacked (the
## hacker uses it against the player's crew). Picks a random crew of the side to control (own crew when
## hacked), takes its room and queues the non-telepathic crew standing there.
static func ai_update(ship: ShipState, hostile: bool) -> void:
	var m := ship.sys("mind")
	if m == null:
		return
	if not hostile:
		if ship.mind_in_use:
			release(ship)
		return
	if ship.is_player and not m.hacked and not ship.ai_driven:  # autobattle: an AI-driven player side uses it too
		return
	if not can_use(ship) or ship.mind_in_use or m.ion != 0:
		return
	var own_side := m.hacked
	var pool := []
	for s in [ship, ship.opponent]:
		if s == null:
			continue
		for c in s.crew:
			if c.is_alive() and not c.is_drone() and (c.player_owned == ship.is_player) == own_side:
				pool.append(c)
	if pool.is_empty():
		return
	var pick: CrewMember = pool[ship.rng.randi() % pool.size()]
	var on := ship.ship_of(pick)
	if on == null:
		return
	ship.mind_queue = on.crew.filter(func(c): return c.is_alive() and c.room == pick.room \
		and not c.is_telepathic())
