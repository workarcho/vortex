class_name ShipManagement
extends RefCounted
## Ship management window state (rules/ship_management.md §1, §5, §6; TabbedWindow `shipScreens`): open / current
## tab (Upgrades, Crew, Equipment), the lock (9th crew, dismiss dialog), commit-on-close of the upgrade session,
## the crew rename / dismiss state, the equipment inventory (also the store's SELL tab) and the auto-open of
## the window (over-capacity reward, 9th crew). Intents arrive through `RunState.apply` → `apply`.

enum { UPGRADES, CREW, EQUIPMENT }

var open := false
var tab := UPGRADES
var inv := ShipInventory.new()
var upgrades := UpgradeSession.new()
var renaming: CrewMember = null  # crew box with the active TextInput
var rename_text := ""
var dismiss_pending: CrewMember = null  # ConfirmWindow open for this crew member
var last_flags: Array = []  # achievement flags of the last commit
var last_result := ""  # last upgrade / equipment result ("ok", "scrap", "max", "blocked", ...)


## The SHIP button / hotkeys work outside danger, with nothing else modal on screen (CommandGui::OnLoop/KeyDown).
func can_open(run: RunState) -> bool:
	return run.over == "" and not run.in_danger() and not run.leave_crew_open and run.phase == RunState.Phase.IDLE and not run.map_open \
		and not run.choosing_sector and not run.store_open


## bWindowLock / bBlockClose: no tab change, no Accept, no Esc.
func locked(run: RunState) -> bool:
	if dismiss_pending != null:
		return true
	return tab == CREW and CrewRoster.is_over_capacity(run.ship)


## Equipment usable as the store SELL tab (bStoreMode).
func store_mode(run: RunState) -> bool:
	return run.store_open and run.store_tab == 1


func equipment_active(run: RunState) -> bool:
	return (open and tab == EQUIPMENT) or store_mode(run)


func open_screen(run: RunState, t: int) -> bool:
	if open:
		return set_tab(run, t)
	if not can_open(run):
		return false
	open = true
	tab = clampi(t, UPGRADES, EQUIPMENT)
	_open_tab(run)
	return true


func set_tab(run: RunState, t: int) -> bool:
	if not open or locked(run):
		return false
	t = clampi(t, UPGRADES, EQUIPMENT)
	if t == tab:
		return true
	_close_tab(run)
	tab = t
	_open_tab(run)
	return true


func close(run: RunState, force := false) -> bool:
	if not open:
		return false
	if locked(run) and not force:
		return false
	_close_tab(run)
	open = false
	return true


func _open_tab(_run: RunState) -> void:
	if tab == UPGRADES:
		upgrades = UpgradeSession.new()


## Sub-window Close: Upgrades commits its temporary levels, the crew tab commits a running rename.
func _close_tab(run: RunState) -> void:
	match tab:
		UPGRADES:
			var had := upgrades.has_pending()
			last_flags = upgrades.commit(run.ship)
			if not last_flags.is_empty():
				Hooks.emit(&"upgrades_applied", run, last_flags)  # AchievementTracker::SetFlag
			if had:
				FtlData.play("acceptUpgrades")
				run._log("upgrades applied %s" % str(last_flags))
		CREW:
			commit_rename()
			dismiss_pending = null


## TabbedWindow::OnLoop: a sub-window that opened by itself brings the window up on its tab.
func update(run: RunState) -> void:
	if run.over != "":
		return
	if inv.open_request:
		if run.store_open and run.phase == RunState.Phase.IDLE:
			inv.open_request = false
			run.store_tab = 1  # the store's SELL page is the same Equipment window
		elif can_open(run) or (open and not locked(run)):
			inv.open_request = false
			open_screen(run, EQUIPMENT)
	if CrewRoster.is_over_capacity(run.ship) and (can_open(run) or open) and not (open and tab == CREW):
		if open:
			_close_tab(run)
			tab = CREW
			_open_tab(run)
		else:
			open_screen(run, CREW)


# ------------------------------------------------------------------ crew

func start_rename(c: CrewMember) -> void:
	commit_rename()
	renaming = c
	rename_text = CrewRoster.long_name(c).substr(0, CrewRoster.NAME_MAX)
	_rename_from = rename_text


var _rename_from := ""


## Commits the text input (unchanged text keeps the full name).
func commit_rename() -> void:
	if renaming != null and rename_text != _rename_from:
		CrewRoster.rename(renaming, rename_text)
	renaming = null
	rename_text = ""


func type_rename(text: String) -> void:
	if renaming != null:
		rename_text = text.substr(0, CrewRoster.NAME_MAX)


# ------------------------------------------------------------------ intents

func apply(run: RunState, intent: Dictionary) -> bool:
	var arg := int(intent.get("arg", -1))
	match String(intent.type):
		RunIntent.OPEN_SHIP_SCREEN:
			return open_screen(run, maxi(arg, 0))
		RunIntent.SET_TAB:
			return set_tab(run, arg)
		RunIntent.CLOSE_SHIP_SCREEN:
			return close(run)
		RunIntent.UPGRADE_BUY:
			if not open or tab != UPGRADES:
				return false
			last_result = upgrades.buy(run.ship, String(intent.get("sys", "")))
			FtlData.play("upgradeSystem" if last_result == "ok" else "powerUpFail")
			return last_result == "ok"
		RunIntent.UPGRADE_REFUND:
			if not open or tab != UPGRADES:
				return false
			var got := upgrades.refund(run.ship, String(intent.get("sys", "")))
			if got > 0:
				# UpgradeBox / Upgrades::MouseRightClick, ReactorButton::OnRightClick: one temp level refunded ->
				# `downgradeSystem` (the Undo button's `undoUpgrades` is a different sound).
				FtlData.play("downgradeSystem")
			return got > 0
		RunIntent.UPGRADE_UNDO:
			if not open or tab != UPGRADES:
				return false
			var total := upgrades.undo_all(run.ship)
			if total > 0:
				FtlData.play("undoUpgrades")
			return total > 0
		RunIntent.EQUIP_MOVE:
			if not equipment_active(run):
				return false
			var ok := inv.move_or_swap(run, intent.src, intent.dst)
			last_result = "ok" if ok else "blocked"
			return ok
		RunIntent.EQUIP_SELL:
			if not store_mode(run):
				return false
			var v := inv.sell(run, intent.src)
			if v >= 0:
				FtlData.play("buy")
			return v >= 0
		RunIntent.CREW_RENAME:
			if not open or tab != CREW:
				return false
			var c: CrewMember = intent.get("crew")
			if c == null or not c in CrewRoster.members(run.ship):
				return false
			return CrewRoster.rename(c, String(intent.get("text", "")))
		RunIntent.CREW_DISMISS:
			if not open or tab != CREW:
				return false
			var c2: CrewMember = intent.get("crew")
			if c2 == null or not CrewRoster.can_dismiss(run.ship) or not c2 in CrewRoster.members(run.ship):
				return false
			commit_rename()
			dismiss_pending = c2
			return true
		RunIntent.CREW_DISMISS_CONFIRM:
			if dismiss_pending == null:
				return false
			var c3 := dismiss_pending
			dismiss_pending = null
			if arg != 1:
				return false
			var done := CrewRoster.dismiss(run.ship, c3)
			if done:
				run._log("crew dismissed: %s" % CrewRoster.long_name(c3))
			return done
	return false


## Every FTL jump (Equipment::Jump) and location change: over items lost, the window closes.
func on_jump(run: RunState) -> void:
	if open:
		close(run, true)
	inv.on_jump(run)


static func make(type: String, extra := {}) -> Dictionary:
	var d := {"type": type, "arg": -1}
	d.merge(extra, true)
	return d
