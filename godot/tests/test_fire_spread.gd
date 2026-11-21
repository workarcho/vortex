extends Node
## Fire timeline measurements against an independent model of the exe's per-frame fire code
## (rules/fire_and_oxygen.md "Fire timeline"). Run:
##   godot --headless --path godot res://tests/test_fire_spread.tscn
##
## VanillaRoom below is written from the decompiled FTL 1.6.9 functions (Spreader<Fire>::UpdateSpread /
## CheckSquareSpread, Fire::UpdateStartTimer / UpdateDeathTimer, Repairable::PartialRepair,
## CrewMember::UpdateRepair) for one isolated room, one frame = SpeedFactor 16/60. Our game (ShipState.tick on
## the Kestrel's 2x2 weapons room) must give the same outcome distribution.

const Harness := preload("res://tests/harness.gd")
const DT := 1.0 / 60.0
const TRIALS := 150

var fails := 0


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func near(name: String, got: float, want: float, tol: float) -> void:
	check("%s ~= %.3f (+/-%.3f) [%.3f]" % [name, want, tol, got], absf(got - want) <= tol, true)


## Reference model: one w x h room, walls all round, its own oxygen (refill %/s from the oxygen system).
class VanillaRoom:
	const SF := 16.0 / 60.0  # CFPS::SpeedFactor of one 60 fps frame at normal speed
	var w := 2
	var h := 2
	var damage: Array[float] = []  # Repairable::fDamage (burning while > 0)
	var start: Array[float] = []  # Fire::fStartTimer
	var death: Array[float] = []  # Fire::fDeathTimer
	var o2 := 100.0
	var refill := 1.2  # %/s
	var crew := 0  # humans on their slots (repair skill 0)
	var current := -1  # CrewMember::currentRepair (shared: every crew picks GetFires()[0])
	var rng := RandomNumberGenerator.new()
	static var _trial := 0

	func _init(width: int, height: int) -> void:
		w = width
		h = height
		for i in w * h:
			damage.append(0.0)
			start.append(0.0)
			death.append(-1.0)
		_trial += 1
		rng.seed = _trial * 104729  # deterministic trials (the statistical checks must not flake)

	func idx(x: int, y: int) -> int:
		return y * w + x

	func burning(i: int) -> bool:
		return damage[i] > 0.0

	func count() -> int:
		var n := 0
		for i in w * h:
			if burning(i):
				n += 1
		return n

	func frame() -> void:
		# ShipManager::UpdateEnvironment -> Spreader<Fire>::UpdateSpread, column by column.
		for x in w:
			for y in h:
				var i := idx(x, y)
				var c := 0
				for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var nx: int = x + d.x
					var ny: int = y + d.y
					if nx < 0 or ny < 0 or nx >= w or ny >= h:
						continue  # wall
					if burning(idx(nx, ny)):
						c += 1
						_start_timer(i)  # same room: ConnectedGridSquares 3 -> door level 0 -> 0.1
				_death_timer(i, c)
				if c == 0 and not burning(i):
					start[i] = 0.0  # ResetStartTimer
		# Room oxygen: oxygen system refill, -0.06 x SF per burning tile; fire sees (int) O2.
		o2 = clampf(o2 + refill * SF / 16.0 - 0.06 * SF * count(), 0.0, 100.0)
		# CrewMember::UpdateRepair: PartialRepair(GetRepairSpeed 1 x skill 1 x fire 1.2) = -speed x 0.5 x SF.
		if crew > 0 and count() > 0:
			if current < 0 or not burning(current):
				current = -1
				for x in w:
					for y in h:
						if current < 0 and burning(idx(x, y)):
							current = idx(x, y)
			for k in crew:
				damage[current] -= 1.2 * 0.5 * SF
			if damage[current] <= 0.0:
				damage[current] = 0.0

	func _start_timer(i: int) -> void:
		if burning(i):
			return
		if start[i] == 0.0:
			start[i] = float(rng.randi() % 40 + 10)
		var f := start[i] - SF * 0.1
		if f < 0.0:
			start[i] = 0.0
			damage[i] = 100.0
		else:
			start[i] = f

	func _death_timer(i: int, c: int) -> void:
		if not burning(i):
			death[i] = -1.0
			return
		var oxy := floorf(o2)
		var f := death[i]
		if f >= 0.0:
			f = death[i] - SF * (15 - 3 * c) * 0.01
			if f < 0.0:
				death[i] = 0.0
				if oxy > 10.0:
					return
				_out(i)
				return
			death[i] = f
		if oxy > 10.0:
			return
		if f != 0.0:
			if f < 0.0:
				death[i] = float(rng.randi() % 10 + 5)
			return
		_out(i)

	func _out(i: int) -> void:
		damage[i] = 0.0
		start[i] = 0.0
		death[i] = -1.0


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	var t0 := Time.get_ticks_msec()
	_rates()
	_one_crew()
	print("  (%.1f s)" % ((Time.get_ticks_msec() - t0) / 1000.0))
	_unattended()
	print("  (%.1f s)" % ((Time.get_ticks_msec() - t0) / 1000.0))


func new_ship() -> ShipState:
	var s := ShipState.new("PLAYER_SHIP_HARD", true)
	s.env._rng.seed = _next_seed()  # deterministic trials
	s.rng.seed = _next_seed()
	return s


static var _seed_counter := 1000


static func _next_seed() -> int:
	_seed_counter += 1
	return _seed_counter * 7919


## The Kestrel's oxygen refill (%/s) for the reference room.
func refill() -> float:
	var p := new_ship().sys("oxygen").effective_power()
	return ShipEnvironment.O2_REFILL * (1 + 3 * (p - 1))


## Only the test room burns: fires / start timers that crossed a door are dropped (the reference room has walls).
func isolate(s: ShipState, room: int) -> void:
	for r in s.fires.keys():
		if r != room:
			s.fires.erase(r)
	for g in s.env.spread_timers.keys():
		if s.env.tile_room[g] != room:
			s.env.spread_timers.erase(g)


func _rates() -> void:
	print("Spread rates by connection (Spreader<Fire>::CheckSquareSpread / ShipGraph::ConnectedGridSquares)")
	var s := new_ship()
	var env := s.env
	var di := -1
	for i in env.doors.size():
		if not env.doors[i].airlock:
			di = i
			break
	var d: Dictionary = env.doors[di]
	# The two tiles either side of the door edge.
	var a := Vector2i(d.x - 1, d.y) if d.vertical else Vector2i(d.x, d.y - 1)
	var b := Vector2i(d.x, d.y)
	check("door tiles are in its two rooms", [env.tile_room.get(a, -1), env.tile_room.get(b, -1)].has(d.left), true)
	s.sys("doors").override_level = 1
	d.open = false
	near("closed door, doors level 1 (no blast): 0.0571 x 16", env.fire_spread_rate(a, b), 0.914, 0.001)
	d.open = true
	near("open door: 0.1 x 16", env.fire_spread_rate(a, b), 1.6, 0.001)
	d.open = false
	d.forced = 3.0
	near("forced-open door: 0.1 x 16", env.fire_spread_rate(a, b), 1.6, 0.001)
	d.forced = 0.0
	s.sys("doors").override_level = 2
	near("closed blast door (doors level 2): 0.01 x 16", env.fire_spread_rate(a, b), 0.16, 0.001)
	d.hacked = 1
	near("hacked door (ConnectedGridSquares 6 -> level 0): 0.1 x 16", env.fire_spread_rate(a, b), 1.6, 0.001)
	d.hacked = 0
	var g0 := env.tile_global(s.sys("weapons").room, 0)
	near("same room: 0.1 x 16", env.fire_spread_rate(g0, g0 + Vector2i.RIGHT), 1.6, 0.001)

	print("Fire oxygen (fOxygen = (int) room O2; 0 without an oxygen system)")
	var room := s.sys("weapons").room
	env.oxygen[room] = 10.9
	check("10.9 % -> sees 10 (starves)", env.fire_oxygen(room), 10.0)
	s.ignite(room, 0)
	s.fires[room][0].health = 40.0
	s.ignite(room, 0)
	check("hit again while burning: back to 100 (Fire::Spread = SetDamage(100))", s.fires[room][0].health, 100.0)
	var auto := ShipState.new("AUTO_BASIC", false)
	if auto.sys("oxygen") == null:
		var r: int = auto.layout.rooms[0].id
		check("no oxygen system: fires see 0 %", auto.env.fire_oxygen(r), 0.0)
		auto.ignite(r, 0)
		var t := 0.0
		while auto.fires.has(r) and t < 30.0:
			auto.env.spread_timers.clear()
			auto.env.tick(DT)
			t += DT
		check("  a lone fire there dies within 14 / 2.4 = 5.9 s [%.1f s]" % t, t <= 5.9, true)


## One fire on a 2x2 room, full O2, one human on its slot fighting it.
func _one_crew() -> void:
	print("One human vs one fire in a 2x2 room (%d trials each)" % TRIALS)
	# Reference.
	var ref_spread := 0
	var ref_t := 0.0
	var ref_max := 0.0
	for k in TRIALS:
		var v := VanillaRoom.new(2, 2)
		v.refill = refill()
		v.crew = 1
		v.damage[0] = 100.0
		var t := 0.0
		var spread := false
		while v.count() > 0 and t < 300.0:
			v.frame()
			t += DT
			spread = spread or v.count() > 1
		ref_t += t
		ref_max = maxf(ref_max, t)
		if spread:
			ref_spread += 1
	# Ours.
	var our_spread := 0
	var our_t := 0.0
	var our_max := 0.0
	var first_t := 0.0
	for k in TRIALS:
		var s := new_ship()
		var room := s.sys("weapons").room
		s.ignite(room, 0)
		var t := 0.0
		var spread := false
		var first := -1.0
		while s.fires.has(room) and t < 300.0:
			s.tick(DT * GameClock.BASE)
			isolate(s, room)
			t += DT
			if first < 0.0 and not s.fires.get(room, {}).has(0):
				first = t
			spread = spread or s.fires.get(room, {}).size() > 1
		our_t += t
		our_max = maxf(our_max, t)
		first_t += first
		if spread:
			our_spread += 1
	var p_ref := float(ref_spread) / TRIALS
	var p_our := float(our_spread) / TRIALS
	print("  reference: spread in %.0f %% of trials, all out after %.1f s on average (worst %.1f s)" % [
		p_ref * 100.0, ref_t / TRIALS, ref_max])
	print("  ours:      spread in %.0f %% of trials, all out after %.1f s on average (worst %.1f s)" % [
		p_our * 100.0, our_t / TRIALS, our_max])
	near("first tile out: 100 / (8 x 1.2) = 10.42 s", first_t / TRIALS, 100.0 / 9.6, 0.1)
	# Analytic: a neighbour ignites before 10.42 s only if its 10..49 timer is < 1.6 x 10.42 = 16.7 (7 of 40);
	# two in-room neighbours -> 1 - (33/40)^2 = 31.9 %.
	near("reference P(spread) ~ 31.9 % (analytic)", p_ref, 1.0 - pow(33.0 / 40.0, 2.0), 0.08)
	# Compared with the analytic value (two noisy estimates against each other flaked); 3 sigma at 150 trials = 0.11.
	near("ours P(spread) ~ 31.9 % (analytic)", p_our, 1.0 - pow(33.0 / 40.0, 2.0), 0.11)
	near("ours mean time all out = reference", our_t / TRIALS, ref_t / TRIALS, 1.5)
	check("every trial put out (one crew wins)", our_max < 300.0 and ref_max < 300.0, true)


## One fire on a 2x2 room, nobody fighting it.
func _unattended() -> void:
	print("Unattended fire in a 2x2 room (%d trials each)" % TRIALS)
	var ref := [0.0, 0.0, 0.0]  # time to 2 tiles, to 4 tiles, burnt out by oxygen (s)
	for k in TRIALS:
		var v := VanillaRoom.new(2, 2)
		v.refill = refill()
		v.damage[0] = 100.0
		var t := 0.0
		var t2 := -1.0
		var t4 := -1.0
		while v.count() > 0 and t < 600.0:
			v.frame()
			t += DT
			if t2 < 0.0 and v.count() >= 2:
				t2 = t
			if t4 < 0.0 and v.count() >= 4:
				t4 = t
		ref[0] += t2
		ref[1] += t4
		ref[2] += t
	var ours := [0.0, 0.0, 0.0]
	for k in TRIALS:
		var s := new_ship()
		var room := s.sys("weapons").room
		s.crew.clear()
		s.crew_changed()
		s.ignite(room, 0)
		var t := 0.0
		var t2 := -1.0
		var t4 := -1.0
		while s.fires.has(room) and t < 600.0:
			s.env.tick(DT)
			isolate(s, room)
			t += DT
			var n: int = s.fires.get(room, {}).size()
			if t2 < 0.0 and n >= 2:
				t2 = t
			if t4 < 0.0 and n >= 4:
				t4 = t
		ours[0] += t2
		ours[1] += t4
		ours[2] += t
	for i in 3:
		ref[i] /= TRIALS
		ours[i] /= TRIALS
	print("  reference: 2nd tile %.1f s, whole room %.1f s, starved out %.1f s" % ref)
	print("  ours:      2nd tile %.1f s, whole room %.1f s, starved out %.1f s" % ours)
	# 2nd tile = min of two neighbours' (10..49) / 1.6 timers: E = sum P(min >= k) over k... ~ 8.9 s.
	var e_min := 0.0
	for k in range(10, 50):
		e_min += k * (pow((50.0 - k) / 40.0, 2.0) - pow((49.0 - k) / 40.0, 2.0))
	near("reference 2nd tile ~ E[min of two 10..49 timers] / 1.6", ref[0], e_min / 1.6, 0.8)
	near("ours 2nd tile = reference", ours[0], ref[0], 0.8)
	near("ours whole room = reference", ours[1], ref[1], 1.2)
	near("ours burn-out by lack of oxygen = reference", ours[2], ref[2], 4.0)
