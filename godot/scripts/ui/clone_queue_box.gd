class_name CloneQueueBox
extends RefCounted
## FTL CloneBox (player clonebay system box, rules/hud_layout.md "Clone bay queue"): the clone queue drawn above
## the clonebay power bars with `systemUI/clonebar_small_{solo,bottom,middle,top,fill}.png`, one 23 px slot per
## queued crew (max 3 shown; the third shows "+N" when 4 or more wait), the green clone progress in the bottom
## slot, the red death progress in the top shown slot, and the "CLONEBAY OFF / CREW DYING" WarningWithLines.
## Static helpers only; drawn by SystemPowerColumn for the player's clonebay.

const SLOT_PITCH := 23
const FILL := Vector2(34, 20)  # clonebar_small_fill.png
const PROGRESS_GREEN := Color(0, 1, 0)
const DEATH_RED := Color(1, 0.3, 0.3)
## WarningWithLines at loc + (22, −61), moved by (topPower − loc.y): polyline, text origin.
const WARNING := [Vector2(22, -61), [Vector2(10, 77), Vector2(10, 27), Vector2(173, 27)], Vector2(107, 6)]


## Crew waiting in the clone queue of `ship` (CrewMemberFactory::GetCloneReadyList: first to clone first).
static func queue(ship: ShipState) -> Array:
	return ship.clone_queue if ship != null and ship.sys("clonebay") != null else []


## CloneBox::GetHeightModifier: 0 with an empty queue, else 23·n + 6 (n ≤ 3), 75 for 4 or more. Raises the
## column's lock outline top / status icons / warnings above the queue box.
static func height_modifier(ship: ShipState) -> int:
	var n := queue(ship).size()
	if n == 0:
		return 0
	return 75 if n >= 4 else n * SLOT_PITCH + 6


## Anchor P = (loc.x + 35, loc.y − 8·maxPower), maxPower 0 → 8 px, capped at 24 px.
static func anchor(s: SystemState, l: Vector2) -> Vector2:
	var mp := s.get_level()
	var h := 8 if mp <= 0 else mini(mp * 8, 24)
	return l + Vector2(35, -h)


## Box images [name, top-left] for `shown` (1..3) slots relative to the anchor P.
static func box_images(shown: int, p: Vector2) -> Array:
	if shown <= 0:
		return []
	var x := p.x - 29
	if shown == 1:
		return [["clonebar_small_solo.png", Vector2(x, p.y - 20)]]
	var out := [["clonebar_small_bottom.png", Vector2(x, p.y - 14)]]
	var y := p.y - 14
	if shown == 3:
		y = p.y - 37
		out.append(["clonebar_small_middle.png", Vector2(x, y)])
	out.append(["clonebar_small_top.png", Vector2(x, y - 29)])
	return out


## Centre of slot i (0 = bottom): (P.x − 3, P.y − 1 − 23 i).
static func slot_centre(p: Vector2, i: int) -> Vector2:
	return p + Vector2(-3, -1 - SLOT_PITCH * i)


## CloneSystem::GetProgress: fTimeToClone / fTimeGoal while it has effective power, else 0.
static func clone_progress(ship: ShipState) -> float:
	var cb := ship.sys("clonebay")
	if cb == null or cb.effective_power() == 0 or cb.timer_goal <= 0.0 or cb.timer < 0.0:
		return 0.0
	return clampf(cb.timer / cb.timer_goal, 0.0, 1.0)


## CloneSystem::GetDeathProgress: fDeathTime / 3 (0 when not dying).
static func death_progress(ship: ShipState) -> float:
	return clampf(ship.clone_death_timer / ClonebayRule.DEATH_DELAY, 0.0, 1.0) if ship.clone_death_timer > 0.0 else 0.0


## Dying warning shown (CloneBox::OnRender): queue not empty, the clonebay not `Functioning()` (vtable slot 0xb:
## effective power 0) and no BACKUP_DNA. Unlike the death timer / cloneBroken loop (ClonebayRule.dying) a hack
## does not count: a powered but hacked clonebay loses crew with the sound but without this warning [exe].
static func dying_warning(ship: ShipState) -> bool:
	return not queue(ship).is_empty() and ship.sys("clonebay").effective_power() <= 0 \
		and not ship.has_augment("BACKUP_DNA")


## CloneBox::OnRender after SystemBox::OnRender. `l` = box location in `ci`, `top_power` = the column's topPower
## (same coordinates), `t` = flash time.
static func draw(ci: CanvasItem, ship: ShipState, l: Vector2, top_power: float, t: float) -> void:
	var s := ship.sys("clonebay")
	if s == null:
		return
	var q := queue(ship)
	if dying_warning(ship):
		var spec := [l + WARNING[0] + Vector2(0, top_power - l.y), WARNING[1], WARNING[2]]
		HudDraw.warning_with_lines(ci, spec, HudDraw.txt("warning_clone_off_2"), t, HudDraw.txt("warning_clone_off_1"))
	var shown := mini(q.size(), 3)
	if shown == 0:
		return
	var p := anchor(s, l)
	for b in box_images(shown, p):
		HudDraw.img(ci, "systemUI/" + String(b[0]), b[1])
	var fill := HudDraw.tex("systemUI/clonebar_small_fill.png")
	for i in shown:
		var c := slot_centre(p, i)
		if i == 0 and fill:  # clone progress: int(f · 20) rows, anchored at the bottom of the slot
			var h := int(clone_progress(ship) * FILL.y)
			if h > 0:
				ci.draw_texture_rect_region(fill, Rect2(c + Vector2(-17, 10 - h), Vector2(FILL.x, h)),
					Rect2(0, FILL.y - h, FILL.x, h), PROGRESS_GREEN)
		if i == 2 and q.size() >= 4:
			HudDraw.text(ci, 10, "+%d" % (q.size() - 2), c + Vector2(0, -7), Color.WHITE, 1)
		else:
			var cm: CrewMember = q[i]
			CrewPortrait.draw_icon(ci, CrewPortrait.look_of(cm), c + Vector2(1, 2))
		if i == shown - 1 and fill:  # death progress: int(d · 20) rows from the top of the slot, red
			var dh := int(death_progress(ship) * FILL.y)
			if dh > 0:
				ci.draw_texture_rect_region(fill, Rect2(c + Vector2(-17, -10), Vector2(FILL.x, dh)),
					Rect2(0, 0, FILL.x, dh), DEATH_RED)
