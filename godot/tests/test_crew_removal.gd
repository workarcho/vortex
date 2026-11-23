extends Node
## Tests for rules/events.md "Crew removal and loss": <removeCrew> clone true/false + text, class preference,
## uniform pick, silent removal (no body / death sound / clone queue), instant clone with skill loss, traitor copy
## in the piloting room, negative <crewMember>, away-team / clone-queue pool, last crew. Small project-made event
## XML (not FTL text). Run:
##   godot --headless --path godot res://tests/test_crew_removal.tscn

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
<event name="RC_CLONE"><text>taken</text><removeCrew><clone>true</clone><text>cloned back</text></removeCrew></event>
<event name="RC_GONE"><text>lost</text><removeCrew><clone>false</clone><text>the clonebay cannot help</text></removeCrew></event>
<event name="RC_ENGI"><text>engi</text><removeCrew class="engi"><clone>false</clone><text>x</text></removeCrew></event>
<event name="TRAITOR"><text>betrayal</text><crewMember amount="-1" class="traitor"/></event>
<event name="PLAIN"><text>plain</text><crewMember amount="-1"/></event>
<event name="TWO"><text>two</text><crewMember amount="-2"/></event>
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


func own_names(s: ShipState) -> Array:
	return s.crew.filter(func(c): return c.player_owned).map(func(c): return c.name_long)


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	FtlData.muted = true
	test_parse()
	test_uniform()
	test_preference()
	test_gone()
	test_clonebay()
	test_traitor()
	test_pool_and_last()


func test_parse() -> void:
	print("Parsing")
	var r := make_run()
	var ev := r.engine.base_event("PLAIN")
	check("plain crewMember -1 keeps no class (no weighted race)", [ev.crew.amount, ev.crew.race], [-1, ""])
	check("traitor flag", r.engine.base_event("TRAITOR").crew.traitor, true)
	var rc: Dictionary = r.engine.base_event("RC_CLONE").remove_crew
	check("removeCrew clone / text", [rc.clone, rc.text, rc.amount], [true, "cloned back", -1])
	check("removeCrew class", r.engine.base_event("RC_ENGI").remove_crew.race, "engi")


func test_uniform() -> void:
	print("Uniform pick over the crew (no race bias)")
	var r := make_run()
	var counts := {}
	for i in 3000:
		r.crew_seed = -1
		var c := r.select_random_crew("")
		counts[c.name_long] = int(counts.get(c.name_long, 0)) + 1
	check("3 crew picked", counts.size(), 3)
	var ok := true
	for k in counts:
		ok = ok and absf(counts[k] / 3000.0 - 1.0 / 3.0) < 0.04
	check("each ≈ 1/3", ok, true)
	r.crew_seed = 77
	var a := r.select_random_crew("")
	var b := r.select_random_crew("")
	check("same seed -> same crew (preview == victim)", a == b, true)


func test_preference() -> void:
	print("class is a preference with a fallback")
	var r := make_run()
	var engi := r.ship.add_crew("engi", true)
	var all_engi := true
	for i in 200:
		r.crew_seed = -1
		all_engi = all_engi and r.select_random_crew("engi") == engi
	check("always the engi", all_engi, true)
	var seen := {}
	for i in 300:
		r.crew_seed = -1
		seen[r.select_random_crew("mantis")] = true
	check("no mantis: everyone possible", seen.size(), 4)
	var t := make_run()
	t.show_event(t.engine.base_event("RC_ENGI"))
	t.choose(0)
	check("no engi aboard: someone still lost", own_names(t.ship).size(), 2)


func test_gone() -> void:
	print("clone=false / no clonebay: silent removal")
	var r := make_run()
	var before := own_names(r.ship)
	r.show_event(r.engine.base_event("RC_GONE"))
	# The box opens with the victim previewed (CreateChoiceBox: SelectRandomCrew with lastSelectedCrewSeed); the
	# crew member is removed by ModifyResources when the choice is picked (PauseLoop).
	check("box open: nobody removed yet", own_names(r.ship), before)
	var shown: Array = r.dialog_rewards.duplicate(true)
	check("event text kept (no clonebay)", r.dialog.text, "lost")
	r.choose(0)
	var after := own_names(r.ship)
	check("one crew gone on the choice", after.size(), before.size() - 1)
	var lost := before.filter(func(n): return not after.has(n))
	check("reward named the victim before", shown.size() == 1 and shown[0][0] == "crew_lost"
		and shown[0][2].name == lost[0], true)
	check("ResourceBox text", ResourceBox.crew_text(shown[0][2]), "%s is gone" % lost[0])
	check("not in the clone queue", r.ship.clone_queue.size(), 0)
	check("box closed", r.phase, RunState.Phase.IDLE)
	check("lost_crew flag", r.lost_crew_flag, true)
	var p := make_run()
	p.show_event(p.engine.base_event("TWO"))
	p.choose(0)
	check("amount -2: one crew lost", own_names(p.ship).size(), 2)
	var q := make_run()
	q.show_event(q.engine.base_event("PLAIN"))
	q.choose(0)
	check("plain <crewMember amount=-1>: one lost", own_names(q.ship).size(), 2)


func test_clonebay() -> void:
	print("With a clonebay: clone=true instant clone, clone=false permanent, clone text replaces the dialog")
	var r := make_run("TEST_SHIP_ALL_CLONE")
	check("test ship has a clonebay", r.ship.sys("clonebay") != null, true)
	var n := own_names(r.ship).size()
	for c in r.ship.crew:
		c.skills["pilot"] = 15
		c.hp = 40.0
	r.crew_seed = 5
	var victim: CrewMember = r.select_random_crew("")
	r.crew_seed = -1
	r.crew_seed = 5
	r.show_event(r.engine.base_event("RC_CLONE"))
	check("box: event text, victim previewed", [r.dialog.text, r.dialog_rewards.size() == 1
		and r.dialog_rewards[0][2].name == victim.name_long], ["taken", true])
	check("box open: not cloned yet", victim.hp, 40.0)
	r.choose(0)
	check("nobody lost", own_names(r.ship).size(), n)
	check("same crew alive", victim.is_alive() and r.ship.crew.has(victim), true)
	check("full health", victim.hp, victim.max_hp)
	check("in the clonebay room", victim.room, r.ship.sys("clonebay").room)
	check("skill loss", victim.skills["pilot"] < 15, true)
	check("not queued", r.ship.clone_queue.size(), 0)
	check("dialog = clone text (DUMMY after the choice)", r.dialog.text, "cloned back")
	check("one continue", r.dialog_choices.size(), 1)
	check("no crew line", r.dialog_rewards, [])
	r.choose(0)
	check("clone box continue -> the chosen (empty) event: closed", r.phase, RunState.Phase.IDLE)
	var g := make_run("TEST_SHIP_ALL_CLONE")
	var m := own_names(g.ship).size()
	g.show_event(g.engine.base_event("RC_GONE"))
	g.choose(0)
	check("clone=false: permanently gone", own_names(g.ship).size(), m - 1)
	check("clone=false: not queued", g.ship.clone_queue.size(), 0)
	check("clone=false: clone text shown", g.dialog.text, "the clonebay cannot help")
	for i in 200:
		g.ship.tick(1.0)
	check("never comes back", own_names(g.ship).size(), m - 1)
	var k := make_run()
	var kn := own_names(k.ship).size()
	k.show_event(k.engine.base_event("RC_CLONE"))
	check("event text kept", k.dialog.text, "taken")
	k.choose(0)
	check("clone=true without clonebay: lost", own_names(k.ship).size(), kn - 1)
	check("no clone box without a clonebay", k.phase, RunState.Phase.IDLE)


func test_traitor() -> void:
	print("Traitor: hostile copy in the piloting room")
	var r := make_run()
	r.show_event(r.engine.base_event("TRAITOR"))
	var rw: Dictionary = r.dialog_rewards[0][2]
	r.choose(0)
	var hostile := r.ship.crew.filter(func(c): return not c.player_owned)
	check("one hostile crew aboard", hostile.size(), 1)
	check("same name", hostile[0].name_long, rw.name)
	check("in the piloting room", hostile[0].room, r.ship.sys("pilot").room)
	check("traitor line", ResourceBox.crew_text(rw), "%s is now an enemy" % rw.name)
	check("own crew 2", own_names(r.ship).size(), 2)


func test_pool_and_last() -> void:
	print("Pool: away team and clone queue; the last crew can be lost")
	var r := make_run()
	var e := ShipState.new("REBEL_FAT", false)
	r.ship.opponent = e
	e.opponent = r.ship
	var away: CrewMember = r.ship.crew[0]
	r.ship.crew.erase(away)
	e.crew.append(away)
	var dead: CrewMember = r.ship.crew[0]
	r.ship.crew.erase(dead)
	dead.hp = 0.0
	r.ship.clone_queue.append(dead)
	var pool := r.crew_loss_pool()
	check("pool includes away team and clone queue", pool.has(away) and pool.has(dead) and pool.size() == 3, true)
	var s := make_run()
	for i in 3:
		s.crew_seed = -1
		s.show_event(s.engine.base_event("RC_GONE"))
		s.choose(0)
	check("all crew lost (nothing protects the last)", own_names(s.ship).size(), 0)
	check("pool empty -> game over condition", s.crew_loss_pool().is_empty(), true)
