extends Node
## End-to-end hostile escape in the real scene (main.tscn, run mode), rules/combat_ai.md §4 "Escape vs. non-hostile
## ships" + "Implementation notes (part B)": escape countdown -> JumpLeave -> 2 s jumpAnimation on game time (frozen
## while paused) -> gotaway event box -> the enemy is gone (ship + TARGET window hidden, player ship back at x 350,
## no hostile, combat over; touch layout without the TARGET column). Run:
##   godot --headless --path godot res://tests/test_escape_flow.tscn

const Harness := preload("res://tests/harness.gd")

const MAIN := preload("res://scripts/main.gd")

var fails := 0
var main: Node


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame
		await get_tree().process_frame


func _close_dialogs(r: RunState) -> void:
	for i in 10:
		if r.phase == RunState.Phase.DIALOG:
			var first := r.dialog_choices.find_custom(func(v): return v.enabled)
			r.choose(maxi(first, 0))
		elif r.phase == RunState.Phase.MESSAGE:
			r.apply(RunIntent.make(RunIntent.CONTINUE))


## A run at a beacon with a hostile PIRATE (the PIRATE event, continued), main.tscn built for it.
func _start(mode: String) -> RunState:
	MAIN.run_mode = true
	MAIN.input_mode = mode
	MAIN.player_ship_name = "PLAYER_SHIP_HARD"
	var r := RunState.new_run(31337)
	_close_dialogs(r)
	r.show_event(r.engine.base_event("PIRATE"))
	_close_dialogs(r)
	RunState.current = r
	main = load("res://main.tscn").instantiate()
	add_child(main)
	await frames(6)
	return r


func _stop() -> void:
	main.queue_free()
	await get_tree().process_frame
	main = null
	RunState.current = null
	MAIN.run_mode = false
	MAIN.input_mode = InputProfile.PC


## Runs main's frame step with a fixed delta (headless frames are too short for a 2 s animation).
func _step(n: int, dt := 0.1) -> void:
	for i in n:
		main._process(dt)
		await frames(1)


func _escape(mode: String) -> void:
	print("Hostile escape, %s" % mode)
	var r := await _start(mode)
	var e: ShipState = main.enemy_space.ship
	check("a hostile pirate is here", [r.has_hostile(), main.enemy_space.visible, main.enemy_window.visible],
		[true, true, true])
	var x_enemy: float = main.player_origin().x
	r.enemy.has_escape = true
	r.enemy.escaping = true
	r.enemy.escape_timer = 0.3
	for i in 60:
		await _step(1)
		if r.enemy.escaped:
			break
	check("timer out -> JumpLeave", [r.enemy.escaped, e.jumping], [true, true])
	# Paused mid-jump: the jumpAnimation (game time) and the gotaway wait; the ship stays on screen.
	main._toggle_pause()
	var t0: float = main.enemy_space.view.jump_time
	await _step(40)
	check("paused: jump frozen, ship still shown, no gotaway yet",
		[is_equal_approx(main.enemy_space.view.jump_time, t0), main.enemy_space.visible, r.enemy.outcome],
		[true, true, ""])
	main._toggle_pause()
	for i in 60:
		await _step(1)
		if r.enemy.outcome != "":
			break
	check("gotaway event box open", [r.enemy.outcome, r.phase != RunState.Phase.IDLE,
		str(r.dialog.get("name", "")).ends_with("gotaway")], ["gotaway", true, true])
	check("enemy gone: ship + TARGET window hidden", [main.enemy_space.visible, main.enemy_window.visible,
		main.enemy_window_back.visible, main.victory_shown], [false, false, false, true])
	check("no hostile, combat over", [r.has_hostile(), main._combat_live], [false, false])
	check("player ship origin back to the no-enemy x (CommandGui::ClearLocation)",
		[x_enemy < main.player_origin().x, main.player_origin().x - float(r.ship.layout.get("horizontal", 0))],
		[true, HudLayout.PLAYER_SHIP.x])
	if mode == InputProfile.TOUCH:
		check("touch layout: no TARGET window in the signature", main._touch_sig.split("|")[1], "false")
	_close_dialogs(r)
	await _step(5)
	main._apply_view()  # e.g. after a view toggle / the player's own jump
	check("box closed: still gone after _apply_view", [r.phase, main.enemy_space.visible,
		main.enemy_window.visible, r.has_hostile(), r.ship.ftl_charge], [RunState.Phase.IDLE, false, false, false, 1.0])
	await _stop()


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	FtlData.muted = true
	await _escape(InputProfile.PC)
	await _escape(InputProfile.TOUCH)
