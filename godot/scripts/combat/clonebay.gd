class_name ClonebayRule
extends RefCounted
## Clone bay, system 13 (rules/clonebay.md): CloneSystem::OnLoop/GetCloneTime/GetJumpHealth,
## CrewMember::Clone, ShipManager::CloneHealing. Dead crew of a side whose ship has a clonebay (killed
## anywhere, also aboard the enemy) leave their ship's crew list when the death animation ends and wait
## in `ShipState.clone_queue` (first to die first). The clonebay clones the first one in CLONE_TIME[p]
## seconds; unpowered/hacked it resets the progress and, without BACKUP_DNA, loses the newest queued crew
## every 3 s.

const CLONE_TIME := [0.0, 12.0, 9.0, 7.0, 0.0]  # by effective power (4: only via bonus, instant)
const CLONE_HEALTH := [0, 8, 16, 25]  # jump healing by usable level
const DEATH_DELAY := 3.0  # s per crew lost while it cannot clone
const SKILL_LOSS := 0.1  # of each skill's cap (at least 1)
const PICKUP_DELAY := CrewMember.DEATH_ANIM  # s: the body leaves the ship when the death anim ends

static var _death_counter := 0  # global death number (CrewMember::SetOutOfGame)


## clone_ready = the owner ship has a clonebay installed (power and damage do not matter).
static func has_clonebay(ship: ShipState) -> bool:
	return ship.sys("clonebay") != null


## Power the clonebay works with: effective power, 0 while actively hacked.
static func clone_power(ship: ShipState) -> int:
	var cb := ship.sys("clonebay")
	if cb == null or cb.hacked:
		return 0
	return cb.effective_power()


static func clone_time(power: int) -> float:
	return CLONE_TIME[clampi(power, 0, CLONE_TIME.size() - 1)]


## Kill(noClone = true): this crew member can never be cloned (crew left behind, events).
static func kill_no_clone(c: CrewMember) -> void:
	c.hp = 0.0
	c.set_meta("no_clone", true)


## Moves the dead crew of `owner`'s side (on any of `ships`) into owner's clone queue once their death
## animation is over (bodies on a destroyed ship at once). Only if `owner` has a clonebay.
static func collect_dead(owner: ShipState, ships: Array) -> void:
	if not has_clonebay(owner):
		return
	for ship in ships:
		var gone := false
		for c in ship.crew.duplicate():
			if c.is_alive() or c.player_owned != owner.is_player or c.has_meta("no_clone"):
				continue
			if c.dead_time < PICKUP_DELAY and not ship.is_destroyed():
				continue
			ship.crew.erase(c)
			ship.teleporting.erase(c)
			_death_counter += 1
			c.set_meta("death_number", _death_counter)
			owner.clone_queue.append(c)
			gone = true
		if gone:
			ship.crew_changed()


## CloneSystem::OnLoop. Returns the crew member cloned this frame (already aboard), or null.
static func tick(ship: ShipState, seconds: float) -> CrewMember:
	var cb := ship.sys("clonebay")
	if cb == null:
		return null
	if ship.clone_queue.is_empty():
		cb.timer = 0.0
		ship.clone_death_timer = 0.0
		return null
	var p := clone_power(ship)
	if p > 0:
		ship.clone_death_timer = 0.0
		var goal := clone_time(p)
		if cb.timer_goal > 0.0 and not is_equal_approx(goal, cb.timer_goal):
			cb.timer = cb.timer / cb.timer_goal * goal  # fraction kept
		cb.timer_goal = goal
		cb.timer += seconds
		if cb.timer >= goal:
			cb.timer = 0.0
			var c: CrewMember = ship.clone_queue.pop_front()
			if clone(ship, c):
				return c
			ship.clone_queue.push_front(c)  # no free slot: wait
		return null
	cb.timer = 0.0  # unpowered / hacked: progress reset (not paused)
	if ship.has_augment("BACKUP_DNA"):
		return null
	ship.clone_death_timer += seconds
	if ship.clone_death_timer > DEATH_DELAY:
		var lost: CrewMember = ship.clone_queue.pop_back()  # most recent death
		lost.set_meta("no_clone", true)
		ship.clone_death_timer = 0.0
	return null


## True while the death timer runs (CloneSystem::OnLoop): queue not empty, clone power 0 (unpowered, ionized,
## destroyed or actively hacked) and no BACKUP_DNA. For the player ship this is the `cloneBroken` sound loop
## volume (UpdateSoundLoop("cloneBroken", 1 / 0) every frame).
static func dying(ship: ShipState) -> bool:
	return ship.sys("clonebay") != null and not ship.clone_queue.is_empty() and clone_power(ship) == 0 \
		and not ship.has_augment("BACKUP_DNA")


## CrewMember::Clone: full health, skill loss, placed in the clonebay room (spilling like a teleport).
static func clone(ship: ShipState, c: CrewMember) -> bool:
	var cb := ship.sys("clonebay")
	var room := cb.room if cb else -1
	c.hp = c.max_hp
	c.stun = 0.0
	c.dead_time = 0.0
	if not TeleporterRule.place_arrival(ship, c, room):
		c.hp = 0.0
		return false
	apply_skill_loss(c)
	FtlData.play("cloneArrive")
	return true


## Each skill loses max(1, int(cap x 0.1)) progress, never below 0.
static func apply_skill_loss(c: CrewMember) -> void:
	for sk in CrewMember.SKILLS:
		var cap: int = c.skill_cap(sk)
		var loss := maxi(1, int(cap * SKILL_LOSS))
		c.skills[sk] = maxi(int(c.skills.get(sk, 0)) - loss, 0)


## ShipManager::CloneHealing (JumpArrive / Wait): player-owned crew aboard get CLONE_HEALTH[usable level]
## HP; needs no power. (No jump exists yet; tests call it directly.)
static func jump_heal(ship: ShipState) -> void:
	var cb := ship.sys("clonebay")
	if cb == null:
		return
	var heal: int = CLONE_HEALTH[clampi(cb.max_power(), 0, CLONE_HEALTH.size() - 1)]
	for c in ship.crew:
		if c.is_alive() and c.player_owned:
			c.hp = minf(c.hp + heal, c.max_hp)


## Progress 0..1 of the clone in progress (UI), or -1 when the queue is empty.
static func progress(ship: ShipState) -> float:
	var cb := ship.sys("clonebay")
	if cb == null or ship.clone_queue.is_empty() or cb.timer_goal <= 0.0:
		return -1.0
	return clampf(cb.timer / cb.timer_goal, 0.0, 1.0)
