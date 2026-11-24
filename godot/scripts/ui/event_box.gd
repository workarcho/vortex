class_name EventBox
extends Control
## Event choice box (ChoiceBox look: WindowFrame, FTL font text, numbered choices) for the run's dialog
## (RunState.dialog / dialog_choices / dialog_rewards) and its placeholder messages. Presentation only: it
## reads the run state and reports gestures to the InputProfile, which turns them into intents.
## Event text comes from the user's FTL data at runtime.

## ChoiceBox::OnRender geometry [exe] (rules/events.md "Dialog box rendering"): origin (327, 140) − (0, 15); the
## WindowFrame's inner rect at origin + (7, 22), 602 wide, max(377, 32·choices + 88) tall; text at origin + (25, 45)
## wrapped at 565 px in the box font (CommandGui choiceBox fontSize 12; IncreaseFont / DecreaseFont keep 9..13).
const ORIGIN := Vector2(327, 125)
const BOX_OFS := Vector2(7, 22)
const W := 602
const MIN_H := 377
const TEXT_OFS := Vector2(25, 45)
const WRAP := 565
const FONT := 12
const LINE := 20  # font 12 line step
const GAP := 30  # choiceBox gap_size: main text -> first choice
const COL_TEXT := Color8(235, 245, 229)
const COL_HOVER := Color(0.9529412, 1.0, 0.3137255)  # potentialChoice
const COL_BLUE := Color(0.0, 0.7647059, 1.0)  # type 2 (blue option)
const COL_GREY := Color(0.5882353, 0.5882353, 0.5882353)  # type 1 (requirement not met)
const COL_REWARD := Color8(100, 255, 100)
const COL_LOSS := Color8(255, 90, 80)

var run: RunState
var profile: InputProfile
var _rows: Array = []  # [Rect2, choice index]
var _hover := -1
var _pressed := -1
var _shown_key := ""
var hold := false  # main.gd: hidden while the jump-out animation plays (the new location is not built yet)


func setup(r: RunState, p: InputProfile) -> void:
	run = r
	profile = p
	position = Vector2.ZERO
	size = HudLayout.FRAME
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	mouse_filter = Control.MOUSE_FILTER_STOP


func _process(_d: float) -> void:
	var show := run != null and not hold and not run.map_open and run.phase != RunState.Phase.IDLE
	visible = show
	mouse_filter = Control.MOUSE_FILTER_STOP if show else Control.MOUSE_FILTER_IGNORE
	if show:
		var key := "%s|%d|%d" % [str(run.dialog.get("name", "")), run.dialog_choices.size(), run.messages.size()] \
			+ str(run.dialog.hash())
		if key != _shown_key:
			_shown_key = key
			_hover = -1
			profile.dialog_opened()
		queue_redraw()
	else:
		_shown_key = ""


func _row_at(p: Vector2) -> int:
	for r in _rows:
		if (r[0] as Rect2).has_point(p):
			return r[1]
	return -1


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var i := _row_at(event.position)
		if i != _hover:
			_hover = i
			if i >= 0 and run.phase == RunState.Phase.DIALOG:
				profile.choice_hover(i)
		accept_event()
		return
	var mb := event as InputEventMouseButton
	if mb == null or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	accept_event()
	var i := _row_at(mb.position)
	if mb.pressed:
		_pressed = i
		return
	if i < 0 or i != _pressed:  # release inside the same row (drag cancels)
		_pressed = -1
		return
	_pressed = -1
	if run.phase == RunState.Phase.MESSAGE:
		profile.message_continue()
	else:
		profile.choice_click(i)


## Keys 1â€“9: apply choice n (message boxes: any of them continues). Returns true if handled.
func key(n: int) -> bool:
	if not visible:
		return false
	if run.phase == RunState.Phase.MESSAGE:
		profile.message_continue()
	else:
		profile.choice_key(n)
	return true


func _draw() -> void:
	if run == null:
		return
	_rows.clear()
	var body := ""
	var rewards: Array = []
	var choices: Array = []  # [text, color, enabled, resources]
	if run.phase == RunState.Phase.MESSAGE:
		body = String(run.messages[0]) if not run.messages.is_empty() else ""
		choices.append([FtlData.tr_id("continue"), Color.WHITE, true, {}])
	else:
		# CreateChoiceBox: system-reward warnings of the choices appended to the main text (RunState.choice_views).
		body = String(run.dialog.get("text", "")) + String(run.dialog.get("system_note", ""))
		rewards = run.dialog_rewards
		for v in run.dialog_choices:
			var t: String = v.text
			var col := Color.WHITE
			if not v.enabled:
				col = COL_GREY
			elif v.blue:
				col = COL_BLUE
			choices.append([t, col, v.enabled, v.get("preview_res", {})])
	var touch := profile.is_touch()
	var lines := FtlData.ftl_wrap(FONT, body, WRAP)
	var reward_lines := _reward_lines(rewards)
	var reward_res := _reward_resources(rewards, run.dialog if run.phase != RunState.Phase.MESSAGE else {})
	var reward_lay := ResourceBox.layout(reward_res, false)
	var reward_box: Vector2 = reward_lay.size
	var reward_w := int(reward_lay.w)  # MeasureResources width (the drawn rect is 5 px wider)
	# Box size: fixed by the choice count (the text does not grow it); a resource box wider than the default
	# widens the frame to its width + 25 and shifts it left (x = 4 − (w − 577) / 2).
	var w := W
	var bx := BOX_OFS.x
	if reward_w > W:
		w = reward_w + 25
		bx = 4 - floorf((reward_w - 577) / 2.0)
	var h := maxi(MIN_H, 32 * choices.size() + 88)
	# Pre-layout the choice rows to keep extra reward lines (prototype addition) inside the frame.
	var rows := []  # [lines, y_text_offset, row_h, box_w]
	var rows_h := 0.0
	for c in choices:
		var res: Dictionary = c[3]
		var bsz := ResourceBox.measure(res)
		var bw := bsz.x
		var bh := bsz.y  # MeasureResources height: 32, more with a second row (items / crew)
		var label := "%d. %s" % [rows.size() + 1, c[0]]
		var cl := FtlData.ftl_wrap(FONT, label, WRAP)
		var wide := 0
		for l in cl:
			wide = maxi(wide, FtlData.ftl_text_width(FONT, l))
		var off := 10.0
		var rh := cl.size() * LINE + 12.0
		if bw > 0:
			if wide + bw > WRAP:  # text wrapped narrower so the box fits after it
				cl = FtlData.ftl_wrap(FONT, label, 0x221 - int(bw))
			# ChoiceBox::OnRender: the row is max(box height, text + 12) tall and a shorter text is centred on the
			# box height ((h − text) × 0.5).
			var th := cl.size() * LINE
			if th < bh:
				off = (bh - th) * 0.5
			rh = maxf(bh, th + 12.0) + 10.0
		if touch:
			rh = maxf(rh, 44.0)
		rows.append([cl, off, rh, bw])
		rows_h += rh
	var content := TEXT_OFS.y - BOX_OFS.y + lines.size() * LINE + GAP + rows_h + 16
	if reward_box.y > 0:
		content += 50 + maxf(reward_box.y / 2.0 - 45.0, 0.0)  # a tall box must not reach the frame bottom
	if not reward_lines.is_empty():
		content += reward_lines.size() * LINE + 10
	h = maxi(h, int(content))
	var r := Rect2(ORIGIN + Vector2(bx, BOX_OFS.y), Vector2(w, h))
	WindowFrame.draw(self, r)
	var tx := ORIGIN.x + TEXT_OFS.x
	var y := ORIGIN.y + TEXT_OFS.y
	for l in lines:
		FtlData.draw_ftl_text(self, FONT, l, Vector2(tx, y), Color.WHITE)
		y += LINE
	y += GAP  # lastChoice.y = end of the text + gap_size
	if reward_box.y > 0:
		# PrintResourceBox(choice = false) at (origin + 25 + 282 − 5, lastChoice.y + 5): x − w/2, y − h/2.
		ResourceBox.draw(self, reward_res, Vector2(tx + 282 - 5 - floorf(reward_w / 2.0),
			y + 5 - floorf(reward_box.y / 2.0)), COL_TEXT, false)
		y += 50
	if not reward_lines.is_empty():  # items / crew / hull lines [prototype; not part of the exe box]
		for rl in reward_lines:
			FtlData.draw_ftl_text(self, FONT, rl[0], Vector2(tx, y), rl[1])
			y += LINE
		y += 10
	for i in choices.size():
		var cl: PackedStringArray = rows[i][0]
		var off: float = rows[i][1]
		var rh: float = rows[i][2]
		var res: Dictionary = choices[i][3]
		var col: Color = choices[i][1]
		var hot: bool = choices[i][2] and (i == _hover or i == run.highlighted)
		if hot:
			col = COL_HOVER
		var y0 := y + (10.0 if not ResourceBox.is_empty(res) else 0.0)
		var widest := 0
		for l in cl:
			widest = maxi(widest, FtlData.ftl_text_width(FONT, l))
		# Hit rect = the printed text block (x, lastChoice.y, text width, text height + 12); touch rows span
		# the box width and are at least 44 px tall.
		var rect := Rect2(tx, y, widest, rh)
		if touch:
			rect = Rect2(tx - 4, y, WRAP + 8, rh)
			if hot:
				draw_rect(rect, Color(1, 1, 1, 0.08))
		_rows.append([rect, i])
		var ty := y0 + off
		for l in cl:
			FtlData.draw_ftl_text(self, FONT, l, Vector2(tx, ty), col)
			ty += LINE
		if not ResourceBox.is_empty(res):
			# ChoiceBox::OnRender: the box 10 px after the text, centred on the text block − 3 px; greyed
			# choices draw it with a 0.75 tint.
			var cy := y0 + off + cl.size() * LINE * 0.5 - 3.0
			var bcol := col * Color(0.75, 0.75, 0.75) if not choices[i][2] else col
			ResourceBox.draw(self, res, Vector2(tx + widest + 10, cy - ResourceBox.measure(res).y / 2.0), bcol)
		y += rh


## Reward lines outside the resource box [prototype]: only crew rewards without an identity (old callers).
## Everything else the exe shows is in the ResourceBox (_reward_resources).
func _reward_lines(rewards: Array) -> Array:
	var out := []
	for rw in rewards:
		var k := String(rw[0])
		if k in ["crew", "crew_lost"] and rw.size() < 3:
			out.append(["%s: %s" % ["New crew member" if k == "crew" else "Crew lost",
				item_title(String(rw[1]), "crew")], COL_REWARD if k == "crew" else COL_LOSS])
	return out


## The event's ResourceEvent as ChoiceBox::RenderResources shows it (ResourceBox input): fuel / missiles / drone
## parts / scrap, the weapon / drone / augment received (also when it went to cargo or the over-capacity box),
## crew gained / lost, and the alert line: hull damage / repair, intruders, fleet delay, item removed, upgrade,
## system installed. Alert entries are [text, true = helpful | false = dangerous | null = neither].
func _reward_resources(rewards: Array, ev: Dictionary = {}) -> Dictionary:
	var out := {}
	var hull := 0
	var alerts := []
	var removed := []
	var upgrades := []
	var systems: Array[String] = []
	for rw in rewards:
		var k := String(rw[0])
		if k in ResourceBox.ORDER:
			out[k] = int(out.get(k, 0)) + int(rw[1])
		elif k in ["crew", "crew_lost"] and rw.size() >= 3 and rw[2] is Dictionary:
			if not out.has("crew"):
				out["crew"] = []
			out.crew.append(rw[2])
		elif k in ["weapon", "drone", "augment", "cargo", "over"]:
			var nm := String(rw[1])
			out[k if k in ["weapon", "drone", "augment"] else item_kind(nm)] = nm
		elif k == "hull":
			hull += int(rw[1])
		elif k == "boarders":
			alerts.append([FtlData.tr_id("intruder_alert"), false])
		elif k == "removed":
			removed.append(String(rw[1]))
		elif k == "upgrade" and rw.size() >= 4:
			upgrades.append(rw)
		elif k == "system":
			systems.append(String(rw[1]))
	# RenderResources order: intruders, fleet, hull damage, item removed, repair, upgrade, system installed.
	var pursuit := int(ev.get("modify_pursuit", 0))
	if pursuit != 0:  # negative = fleet delayed, positive = pursuit doubled
		var id := "fleet_delayed" if pursuit < 0 else "fleet_speed"
		var n := absi(pursuit)
		var ft := FtlData.tr_id(id + "_1") if n == 1 else FtlData.tr_id(id).replace("\\1", str(n))
		alerts.append([ft, pursuit < 0])
	if hull < 0:
		alerts.append([FtlData.tr_id("damage_alert").replace("\\1", str(-hull)), false])
	for nm in removed:
		alerts.append([FtlData.tr_id("item_removed").replace("\\1", item_title(nm)), false])
	if hull > 0:
		var heal := FtlData.tr_id("heal_alert").replace("\\1", str(hull))
		alerts.append([FtlData.tr_id("heal_1_alert") if hull == 1 else heal, true])
	# Upgrade (upgradeSuccessFlag, RunState.upgrade_result): 1 success (helpful); 2 maxed / 3 missing count as
	# neither helpful nor dangerous (null). \1 = the system's running-text name (`oxygen` = "the Oxygen System").
	for u in upgrades:
		var sname := FtlData.tr_id(String(u[1]))
		match int(u[2]):
			1:
				var t := FtlData.tr_id("upgrade_success").replace("\\1", sname)
				alerts.append([t.replace("\\2", str(int(u[3]))), true])
			2:
				alerts.append([FtlData.tr_id("upgrade_fail_max").replace("\\1", sname), null])
			3:
				alerts.append([FtlData.tr_id("upgrade_fail_missing").replace("\\1", sname), null])
	# A system reward: `<name>_installed` (helpful), whatever AddSystem did.
	for sid in systems:
		alerts.append([FtlData.tr_id(sid + "_installed"), true])
	if not alerts.is_empty():
		out["alerts"] = alerts
	return out


## Weapon, drone or augment for a blueprint name (cargo / over-capacity rewards carry only the name).
static func item_kind(nm: String) -> String:
	if not FtlData.weapon_blueprint(nm).is_empty():
		return "weapon"
	if not FtlData.drone_blueprint(nm).is_empty():
		return "drone"
	return "augment"


## Display title of a blueprint name (FtlData.blueprint_title: never the raw id).
static func item_title(name: String, kind := "") -> String:
	return FtlData.blueprint_title(name, kind)
