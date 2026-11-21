extends CanvasLayer
## Autoload `TooltipService`: FTL's single global tooltip (MouseControl; rules/tooltips.md §1–§3, "Implementation
## notes"). Immediate mode like the exe: every frame `begin_frame` clears the request, UI elements call `request()`
## from their `_process` while hovered (last writer wins; later nodes in the tree = drawn on top = win), and the box
## is resolved and drawn after every `_process` (its own top CanvasLayer, 1280×720 HUD coordinates).
##
## - Delay: shown when the request is non-empty and (forced or the cursor has been still for > 0.15 s, real time).
##   Forced = `instant` or the same text as the one shown last frame (so a visible tooltip stays while the cursor
##   moves over the same element; a different text waits again).
## - Box: FtlTooltip (black α 0.95, white 2 px outline, text + (27, 18)), wrap 275 / 350 with a title / `width`.
## - Placement: cursor + (0, 22) or the static `anchor`, then the 670 / 1260 edge rules (`place`).
## - Mods: the final text goes through the `tooltip` filter `(text, source, kind, ctx)` (rules/hooks.md); builders
##   are rules `tooltip.<kind>` (TooltipText).
## - Touch profile (deviation, rules/tooltips.md §3 "Implementation notes"): no hover; a finger held still for
##   `TOUCH_HOLD` s shows the element's tooltip as a static box above the finger until it lifts.
## - Touch semantics for the mouse (touch profile: `--input=touch`, default with `--device=`): the mouse stands in
##   for a finger, so there is a pointer only while a mouse button is held. `pointer()` / `local_mouse()` return
##   OFF_SCREEN otherwise, and `_on_window_input` (the root window's `window_input`, emitted before the viewport
##   dispatches the event) moves button-less mouse motion off-screen, so Godot's GUI hover (mouse_entered,
##   button highlights) and the views' motion hover never see a mouse that merely moves. A press first delivers a
##   motion at the press point (the finger lands); a release is followed by an off-screen motion (the finger
##   lifts), also handed to every script `_gui_input` so views drop their motion-tracked hover.
## - Touch combat (TouchGestures): only the first finger counts; extra fingers never move the pointer.

const DELAY := 0.15  # s of stationary cursor (MouseControl::OnRender: tooltipTimer > 0.15)
const CURSOR_OFFSET := Vector2(0, 22)
const WRAP := 275  # no title
const WRAP_TITLED := 350
const WRAP_BOX := 300  # overrideTooltipWidth of system / weapon / drone boxes
const BOTTOM := 670.0
const RIGHT := 1260.0
const RIGHT_TO := 1240.0
const AIM_SHIFT := 10.0  # hacking / mind control armed
const TOUCH_HOLD := 0.4  # s [ours]
const TOUCH_SLOP := 8.0  # px a held finger may drift [ours]
const TOUCH_ABOVE := 40.0  # box bottom this far above the finger [ours]
const OFF_SCREEN := Vector2(-100000, -100000)  # touch: the pointer while no finger is down
const FINGER_BUTTONS := [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]

# ---- this frame's request (MouseControl state after Reset + the setters)
var text := ""
var title := ""
var width := -1
var forced := false
var anchor := Vector2(-1, -1)  # static anchor (QueueStaticTooltip), (-1, -1) = cursor
var kind := &""
var ctx := {}
var source: Object = null

var last_text := ""  # lastTooltipText: text shown last frame ("" = nothing)
var timer := 0.0  # stationary-cursor time
var debug_pointer: Variant = null  # CLI pointer (screenshots); overrides the mouse
var hud_blocked := false  # a full-focus window covers the combat HUD (set by main.gd every frame)
var aim_shift := false  # hacking / mind control armed: box 10 px lower
var touch := false  # touch profile
var manual := false  # tests drive begin_frame / resolve themselves
var cursor_hidden := false
var shown := {}  # last resolved box: {text, title, rect: Rect2, kind} or {} (tests / debug)

var _last_pointer := Vector2(-1e9, -1e9)
var _touch_down := false
var _finger := false  # touch: a mouse button is held (set from the window's raw input, before dispatch)
var _touch_at := Vector2.ZERO
var _canvas: Control


func _ready() -> void:
	layer = 120
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = -1000
	_canvas = Control.new()
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.size = Vector2(1280, 720)
	_canvas.draw.connect(_on_draw)
	add_child(_canvas)
	get_window().window_input.connect(_on_window_input)


func _process(delta: float) -> void:
	if manual:
		return
	begin_frame(delta)
	if debug_pointer != null and Engine.get_process_frames() % 10 == 0:
		# Screenshots: views that track the hover from mouse motion (ship screens, menus) see the CLI pointer too.
		var ev := InputEventMouseMotion.new()
		ev.position = debug_pointer
		ev.global_position = debug_pointer
		get_viewport().push_input(ev)
	_canvas.queue_redraw()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_touch_down = event.pressed
		_touch_at = event.position
		if event.pressed:
			timer = 0.0


## Touch profile, real mouse: true while no mouse button is held (no finger on the screen = no pointer).
func finger_up() -> bool:
	return touch and debug_pointer == null and not (_finger or _touch_down)


## Pointer in HUD (1280×720 canvas) coordinates (OFF_SCREEN in the touch profile while no finger is down).
func pointer() -> Vector2:
	if debug_pointer != null:
		return debug_pointer
	if finger_up():
		return OFF_SCREEN
	# In this layer's coordinates: main.gd gives it the touch combat HUD's layer offset (tall screens), so the
	# pointer and the tooltips stay in HUD coordinates.
	return transform.affine_inverse() * get_viewport().get_mouse_position() if is_inside_tree() else Vector2(-1, -1)


## `ci.get_local_mouse_position()` with the touch rule of `pointer()` (OFF_SCREEN while no finger is down).
func local_mouse(ci: CanvasItem) -> Vector2:
	return OFF_SCREEN if finger_up() else ci.get_local_mouse_position()


## Touch profile: the mouse acts as a finger (see the header). Runs before the viewport sees `event`.
func _on_window_input(event: InputEvent) -> void:
	if not touch or debug_pointer != null:
		return
	if event is InputEventMouseMotion:
		if event.button_mask == 0:
			event.position = OFF_SCREEN
			event.global_position = OFF_SCREEN
	elif event is InputEventMouseButton and event.button_index in FINGER_BUTTONS:
		if event.pressed:
			_finger = true
			var ev := InputEventMouseMotion.new()  # the finger lands: hover moves to the press point first
			ev.position = event.position
			ev.global_position = event.global_position
			ev.button_mask = event.button_mask
			get_window().push_input(ev)
		elif event.button_mask == 0:
			_lift.call_deferred()  # after the release is dispatched (handlers still see the pointer)


## The finger lifted: no pointer; Godot's GUI and the views' motion-tracked hover move off-screen.
func _lift() -> void:
	if Input.get_mouse_button_mask() != 0:
		return
	_finger = false
	var ev := InputEventMouseMotion.new()
	ev.position = OFF_SCREEN
	ev.global_position = OFF_SCREEN
	get_window().push_input(ev)
	FrameHost.push_off_screen(ev)
	get_tree().root.propagate_call(&"_gui_input", [ev])


## Pointer in `ci`'s local coordinates.
func local_pointer(ci: CanvasItem) -> Vector2:
	return ci.get_global_transform().affine_inverse() * pointer()


## True if the pointer is inside `rect` (in `ci`'s local coordinates) and `ci` is visible.
func hovering(ci: CanvasItem, rect: Rect2) -> bool:
	return ci.is_visible_in_tree() and rect.has_point(local_pointer(ci))


## Hover test for a combat-HUD element (false while a full-focus window covers the HUD). `hud` false = menus,
## maps, store and ship screens (always live).
func over(ci: CanvasItem, rect: Rect2, hud := true) -> bool:
	return not (hud and hud_blocked) and hovering(ci, rect)


## MouseControl::Reset + OnLoop: clear the request, advance or reset the stationary timer.
func begin_frame(delta: float, p: Variant = null) -> void:
	var at: Vector2 = pointer() if p == null else p
	if touch and debug_pointer == null:
		if not _touch_down or at.distance_to(_touch_at) > TOUCH_SLOP:
			timer = 0.0
			_touch_at = at
		else:
			timer += delta
	elif at != _last_pointer:
		timer = 0.0
	else:
		timer += delta
	_last_pointer = at
	text = ""
	title = ""
	width = -1
	forced = false
	anchor = Vector2(-1, -1)
	kind = &""
	ctx = {}
	source = null


## SetTooltip (+ InstantTooltip / QueueStaticTooltip / overrideTooltipWidth / SetTooltipTitle) in one call.
## opts: title: String, width: int, instant: bool, anchor: Vector2 (static), kind: StringName, ctx: Dictionary,
## source: Object.
func request(t: String, opts := {}) -> void:
	if t == "":
		return
	text = t
	if opts.has("title") and title == "":
		title = String(opts.title)
	width = int(opts.get("width", -1))
	anchor = opts.get("anchor", Vector2(-1, -1))
	kind = StringName(opts.get("kind", &""))
	ctx = opts.get("ctx", {})
	source = opts.get("source", null)
	if bool(opts.get("instant", false)) or t == last_text:
		forced = true


## Delay rule (pure): a request is shown when non-empty and forced or the timer passed the delay.
static func visible_for(t: String, is_forced: bool, still: float) -> bool:
	return t != "" and (is_forced or still > DELAY)


## Wrap width: overrideTooltipWidth if > 0, else 275, 350 with a title.
static func wrap_width(override_w: int, has_title: bool) -> int:
	if override_w > 0:
		return override_w
	return WRAP_TITLED if has_title else WRAP


## MouseControl::RenderTooltip placement of a w×h box for anchor `p`, cursor `c`.
static func place(p: Vector2, c: Vector2, sz: Vector2, aim := false) -> Vector2:
	if aim:
		p.y += AIM_SHIFT
	var out := p
	if c.y + sz.y > BOTTOM:
		out.x = p.x + 16
		out.y = p.y - (c.y + sz.y - BOTTOM)
		if c.y < out.y + sz.y:
			out.y = c.y - sz.y - 10
	if c.x + sz.x > RIGHT:
		out.x -= c.x + sz.x - RIGHT_TO
	return out


## OnRender part: decides what is visible this frame, runs the `tooltip` filter, updates lastTooltipText.
## Returns {text, title, rect, kind} or {}.
func resolve() -> Dictionary:
	var show := visible_for(text, forced, timer) and not cursor_hidden
	if touch and debug_pointer == null and not _touch_down:
		show = false
	shown = {}
	if not show:
		last_text = ""
		return shown
	last_text = text
	var ft: Variant = Hooks.filter(&"tooltip", text, source, kind, ctx)
	if Hooks.is_cancel(ft) or String(ft) == "":
		return shown
	var body := String(ft)
	var w := wrap_width(width, title != "")
	var sz := FtlTooltip.box_size(title, body, w)
	var c := pointer() if debug_pointer != null or not manual else _last_pointer
	var p := anchor
	if p.x < 0 and p.y < 0:
		p = c + CURSOR_OFFSET
		if touch and debug_pointer == null:
			p = Vector2(c.x - sz.x / 2.0, c.y - sz.y - TOUCH_ABOVE)
	var pos := place(p, c, sz, aim_shift)
	if touch:
		var vis := get_viewport().get_visible_rect().size if is_inside_tree() else HudLayout.FRAME
		var vis_w := maxf(1280.0, vis.x)
		var vis_h := maxf(720.0, vis.y)
		pos.x = clampf(pos.x, 0, vis_w - sz.x)  # the touch canvas may be wider / taller than the 1280×720 frame
		pos.y = clampf(pos.y, 0, vis_h - sz.y)
	shown = {"text": body, "title": title, "rect": Rect2(pos.round(), sz), "kind": kind, "width": w}
	return shown


func _on_draw() -> void:
	var d := resolve()
	if d.is_empty():
		return
	FtlTooltip.draw_box(_canvas, (d.rect as Rect2).position, String(d.title), String(d.text), int(d.width))
