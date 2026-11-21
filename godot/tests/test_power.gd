extends Node
## Tests for rules/power.md. Run:
##   godot --headless --path godot res://tests/test_power.tscn

const Harness := preload("res://tests/harness.gd")

var fails := 0


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func ship_with_shields(level: int, power: int) -> ShipState:
	var s := ShipState.new("PLAYER_SHIP_HARD", true)
	s.reactor_max = 20
	var sh := s.sys("shields")
	sh.override_level = level
	sh.power = power
	sh.user_power = power
	s.shield_layers = s.max_shield_layers()
	return s


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	print("Shields: damage")
	var s := ship_with_shields(4, 4)
	var free_before := s.reactor_free()
	s.damage_system("shields", 1)
	check("level 4, power 4, damage 1 -> power", s.sys("shields").power, 2)
	check("  -> layers", s.max_shield_layers(), 1)
	check("  -> bars returned to reactor", s.reactor_free() - free_before, 2)
	check("  -> + fails (the 3rd bar alone is not enough)", s.increase_power("shields"), "max")

	s = ship_with_shields(3, 2)
	s.damage_system("shields", 1)
	check("level 3, power 2, damage 1 -> power", s.sys("shields").power, 2)
	check("  -> layers", s.max_shield_layers(), 1)

	s = ship_with_shields(3, 2)
	s.damage_system("shields", 2)
	check("level 3, power 2, damage 2 -> power", s.sys("shields").power, 0)
	check("  -> layers", s.max_shield_layers(), 0)

	print("Shields: ion (the only case where power can be odd)")
	s = ship_with_shields(4, 4)
	s.ion_system("shields", 1)
	check("power 4, ion 1 -> power (odd while ionized)", s.sys("shields").power, 3)
	for i in 330:  # 5.5 s at 60 FPS
		s.tick(GameClock.factor(1.0 / 60.0))
	check("  -> when the ion ends it re-powers to", s.sys("shields").power, 4)

	print("Shields: increase and decrease in steps of 2")
	s = ship_with_shields(4, 0)
	s.increase_power("shields")
	check("0 -> +", s.sys("shields").power, 2)
	s.increase_power("shields")
	check("2 -> +", s.sys("shields").power, 4)
	s.decrease_power("shields")
	check("4 -> -", s.sys("shields").power, 2)

	s = ship_with_shields(4, 4)
	s.damage_system("shields", 1)
	s.repair_system("shields", 1)
	s.increase_power("shields")
	check("damage 1 (->2), repair, + -> power", s.sys("shields").power, 4)

	s = ship_with_shields(4, 2)
	s.reactor_max = s.reactor_used() + 1
	check("even with 1 free reactor bar -> + fails", s.increase_power("shields"), "reactor")

	s = ship_with_shields(3, 2)
	check("level 3, power 2 -> + fails (needs 2)", s.increase_power("shields"), "max")

	print("Weapons: depower order")
	s = ShipState.new("PLAYER_SHIP_HARD", true)
	for w in s.weapons:  # the startup power-up leaves weapons unpowered (rules/power.md)
		s.try_power_weapon(w)
	s.damage_system("weapons", 1)
	check("damage 1: Artemis stays on", s.weapons[0].powered, true)
	check("damage 1: Burst II depowers", s.weapons[1].powered, false)

	print("System symbol color (RenderSystemSymbol)")
	s = ShipState.new("PLAYER_SHIP_HARD", true)
	check("shields intact and powered", s.sys("shields").symbol_color(0.0), "green")
	check("medbay powered at start (startup: 1 bar)", s.sys("medbay").symbol_color(0.0), "green")
	s.decrease_power("medbay")
	check("medbay unpowered", s.sys("medbay").symbol_color(0.0), "grey")
	check("pilot subsystem intact", s.sys("pilot").symbol_color(0.0), "green")
	s.damage_system("engines", 1)
	check("engines 1 broken bar", s.sys("engines").symbol_color(0.0), "orange")
	s.damage_system("engines", 5)
	check("engines all bars broken", s.sys("engines").symbol_color(0.0), "red")
	s.ion_system("oxygen", 1)
	check("oxygen ionized, flash on (t=0.1)", s.sys("oxygen").symbol_color(0.1), "blue")
	check("oxygen ionized, flash off (t=0.6)", s.sys("oxygen").symbol_color(0.6), "grey")
	check("icon texture loads", s.sys("shields").symbol_texture(0.0) != null, true)

	print("In-room symbol tint (ShipSystem::OnRender)")
	s = ShipState.new("PLAYER_SHIP_HARD", true)
	check("intact powered -> gray", s.sys("shields").room_symbol_tint(0.0), Color8(125, 125, 125))
	check("intact unpowered -> gray", s.sys("medbay").room_symbol_tint(0.0), Color8(125, 125, 125))
	s.damage_system("engines", 1)
	check("damaged -> orange", s.sys("engines").room_symbol_tint(0.0), Color8(255, 153, 76))
	s.damage_system("engines", 5)
	check("destroyed -> pure red", s.sys("engines").room_symbol_tint(0.0), Color8(255, 0, 0))
	s.ion_system("oxygen", 1)
	check("ionized, flash on -> ion blue", s.sys("oxygen").room_symbol_tint(0.1), Color8(133, 231, 237))
	check("overlay texture loads", FtlData.texture("img/icons/s_shields_overlay.png") != null, true)

	print("Automatic re-power after repair (ShipSystem::CheckForRepower)")
	s = ShipState.new("PLAYER_SHIP_HARD", true)
	s.reactor_max = 20
	var o2 := s.sys("oxygen")
	o2.override_level = 2
	s.increase_power("oxygen")
	var want := o2.power
	s.damage_system("oxygen", 2)
	check("oxygen destroyed -> power 0", o2.power, 0)
	s.repair_system("oxygen", 1)
	check("1 bar repaired, reactor free -> re-powered", o2.power, mini(want, 1))
	s.repair_system("oxygen", 1)
	check("fully repaired -> back to what the player had", o2.power, want)
	# Reactor full when the bar comes back: the wish is forgotten for good
	s.damage_system("oxygen", 2)
	var keep := s.reactor_max
	s.reactor_max = s.reactor_used()
	s.repair_system("oxygen", 1)
	check("reactor full at repair -> stays at 0", o2.power, 0)
	check("  -> and forgets what it had", o2.user_power, 0)
	s.reactor_max = keep
	s.repair_system("oxygen", 1)
	check("  -> a later repair with free reactor does NOT re-power", o2.power, 0)

	_test_power_warning()


## rules/power.md "Power-up failure warning": the flag is set by the RULE layer (every reactor refusal, also the
## automatic re-power) and consumed by the HUD's ReactorColumn, which starts NOT ENOUGH POWER (no restart).
func _test_power_warning() -> void:
	print("Power-up failure warning: rule-layer flag (PowerManager failedPowerup)")
	var s := ShipState.new("PLAYER_SHIP_HARD", true)
	var o2 := s.sys("oxygen")
	o2.override_level = 3
	s.reactor_max = s.reactor_used()  # no free bar
	check("flag starts clear", s.failed_powerup, false)
	check("+1 oxygen with the reactor full -> reactor", s.increase_power("oxygen"), "reactor")
	check("  -> failed_powerup set", s.failed_powerup, true)
	check("  take_failed_powerup returns and clears", [s.take_failed_powerup(), s.failed_powerup], [true, false])
	s.reactor_max = 20
	o2.override_level = o2.power
	check("system at its max -> max", s.increase_power("oxygen"), "max")
	check("  -> no flag (the system's own limit is checked first)", s.failed_powerup, false)
	o2.override_level = 3
	s.ion_system("oxygen", 1)
	check("ionized -> locked", s.increase_power("oxygen"), "locked")
	check("  -> no flag", s.failed_powerup, false)

	print("Shields ask for 2 bars: one free bar with even power fails at the reactor")
	s = ship_with_shields(4, 2)
	s.reactor_max = s.reactor_used() + 1
	check("one free bar, shields 2 -> +", s.increase_power("shields"), "reactor")
	check("  -> flag", s.take_failed_powerup(), true)

	print("Weapon power refused by the reactor")
	s = ShipState.new("PLAYER_SHIP_HARD", true)
	var w := s.weapons[0]
	if w.powered:
		s.depower_weapon(w)
	s.reactor_max = s.reactor_used()
	check("weapon click, reactor full -> reactor", s.try_power_weapon(w), "reactor")
	check("  -> flag", s.take_failed_powerup(), true)

	print("Drone power refused by the reactor")
	var t := ShipState.new("TEST_SHIP_ALL", true)
	DroneSystemRule.set_drones(t, ["DEFENSE_1"])
	t.drone_parts = 5
	t.reactor_max = t.reactor_used()
	t.battery_cap = 0
	check("drone click, reactor full -> reactor", DroneSystemRule.power_drone(t, t.drones[0]), "reactor")
	check("  -> flag", t.take_failed_powerup(), true)

	print("Automatic re-power refused by the reactor: the warning appears with no click")
	s = ShipState.new("PLAYER_SHIP_HARD", true)
	s.reactor_max = 20
	o2 = s.sys("oxygen")
	o2.override_level = 2
	s.increase_power("oxygen")
	s.damage_system("oxygen", 2)
	s.reactor_max = s.reactor_used()
	s.take_failed_powerup()
	s.repair_system("oxygen", 1)  # CheckForRepower -> IncreasePower refused
	check("repair with the reactor full -> flag set by the rule layer", s.failed_powerup, true)
	var col := ReactorColumn.new()
	col.setup(s)
	col.poll(1.0 / 60.0)
	check("HUD frame: warning running", col.no_power.running(), true)
	check("  flag consumed by the HUD", s.failed_powerup, false)
	check("  text id", col.no_power.text_id, "warning_no_power")
	check("  font 59 / COLOR_BUTTON_ON / flashing / 2.31 s",
		[WarningMessage.FONT, col.no_power.color, col.no_power.flash, col.no_power.length],
		[59, HudLayout.BUTTON_ON, true, 2.31])
	s.failed_powerup = true
	col.poll(1.0)
	check("a second failure while running does not restart it", [col.starts, snappedf(col.no_power.t, 0.01)],
		[1, 1.0])
	col.poll(1.4)
	check("ends after 2.31 s", col.no_power.running(), false)
	s.failed_powerup = true
	col.poll(0.0)
	check("a failure after it ended starts it again", col.starts, 2)
	col.no_power.t = 0.1
	check("flash: bright half (0.1 s) -> alpha 0.9, bars white", [col.no_power.alpha(), col.no_power.flash_on()],
		[0.9, true])
	col.no_power.t = 0.5
	check("flash: dim half (0.5 s) -> alpha 0.4", [col.no_power.alpha(), col.no_power.flash_on()], [0.4, false])
	col.no_power.t = 0.7
	check("flash loop 0.66 s (0.7 s = bright again)", col.no_power.flash_on(), true)
	check("text top-left for 8 bars = (6, 622 - 72)", ReactorColumn.warning_pos(8), Vector2(6, 550))
	col.free()
	var enemy := ShipState.new("REBEL_FAT", false)
	enemy.decrease_power("oxygen")
	enemy.reactor_max = enemy.reactor_used()
	check("enemy refusals set the flag too (never read: no HUD consumes it)",
		[enemy.increase_power("oxygen"), enemy.failed_powerup], ["reactor", true])

	print("Sibling warnings: weapons / drones system message text (WeaponControl::SelectArmament)")
	var ws := SystemState.new("weapons", 0, 3)
	check("level 3 < weapon power 4 -> needs upgrade", WeaponPanel.system_message_id(ws, 0, 4), "warning_needs_upgrade")
	check("level 3, 2 in use, weapon 2 -> no system power", WeaponPanel.system_message_id(ws, 2, 2),
		"warning_no_system_power")
	ws.damage = 2
	check("level 3, damage 2, 0 in use, weapon 2 -> system broken", WeaponPanel.system_message_id(ws, 0, 2),
		"warning_system_broken")
	var m := WarningMessage.new("warning_no_missiles", Vector2(203, -25), 2.0, true)
	check("no-flash message alpha 1", m.alpha(), 1.0)
	m.start()
	m.update(1.0)
	m.start()
	check("start() while running keeps the time", m.t, 1.0)

	print("Clicks: an ionized system box is silent and leaves no flag")
	s = ShipState.new("PLAYER_SHIP_HARD", true)
	var bar := SystemsBar.new()
	bar.setup(s)
	s.reactor_max = s.reactor_used()
	s.ion_system("oxygen", 1)
	var before := s.sys("oxygen").power
	bar._increase("oxygen")
	check("ionized click: no change, no flag", [s.sys("oxygen").power, s.failed_powerup], [before, false])
	var sh := s.sys("shields")
	sh.override_level = 3
	s.reactor_max = 20
	sh.power = 2
	sh.user_power = 2
	bar._increase("shields")
	check("shields level 3, power 2: half a layer -> needs_upgrade on the shields box",
		[bar.columns["shields"].warning.running(), bar.columns["shields"].warning.text_id],
		[true, "warning_needs_upgrade"])
	bar.free()
