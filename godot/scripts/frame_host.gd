class_name FrameHost
extends Node
## Main scene (frame_host.tscn): renders the game into a fixed frame and draws that frame scaled to the window, like
## FTL 1.6.9 (CApp::OnRender framebuffer path, rules/hud_layout.md "Window scaling"): the exe draws everything into
## a 1280×720 framebuffer and blits it to the window (aspect kept, black bars), with linear filtering
## ("antialias") unless the window is an exact integer multiple of 1280×720 (then nearest).
##
## Here the frame is a SubViewport the size of the stretched canvas (project stretch mode canvas_items + aspect
## expand: 1280×720 on a 16:9 window, wider / taller canvases on other shapes, as before) inside a
## SubViewportContainer that fills the canvas; the root canvas transform scales the container, and its texture
## filter does the vanilla blit: LINEAR at fractional scales, NEAREST at integer ones. Scenes live inside the
## frame, so `get_viewport()` is the frame (same visible size and coordinates as the canvas before) and input reaches
## them through the container.
##
## "sharp" scaling (the DEFAULT; `--frame-scaling=smooth` selects the blit above) keeps the old
## path: scenes are children of this node in the root viewport, every item scaled on its own with nearest
## filtering. Test scenes run without a host (FrameHost.instance == null): every helper falls back to SceneTree.

const FIRST_SCENE := "res://title.tscn"
const SETTING := "ftl/display/frame_scaling"  # "sharp" (default) | "smooth" (vanilla blit, blurry when windowed)

static var instance: FrameHost = null

var frame: SubViewport = null  # null in sharp mode
var box: SubViewportContainer = null
var scene: Node = null  # the game scene (title / main / data setup)


## Replaces the game scene (deferred, like SceneTree.change_scene_to_file, which it falls back to without a host).
static func change_scene(tree: SceneTree, path: String) -> void:
	if is_instance_valid(instance):
		instance._load.call_deferred(path)
	else:
		tree.change_scene_to_file.call_deferred(path)


## Reloads the game scene (SceneTree.reload_current_scene without a host).
static func reload_scene(tree: SceneTree) -> void:
	if is_instance_valid(instance) and instance.scene != null:
		instance._load.call_deferred(instance.scene.scene_file_path)
	else:
		tree.reload_current_scene()


## The running game scene: the host's scene, else SceneTree.current_scene (tests, survey boot).
static func top_scene(tree: SceneTree) -> Node:
	if is_instance_valid(instance):
		return instance.scene
	return tree.current_scene


## The final window image (frame scaled as shown), for screenshots.
static func window_image(tree: SceneTree) -> Image:
	return tree.root.get_texture().get_image()


## TooltipService's off-screen motion (touch: the finger lifted), pushed to the root window, never reaches the
## container: hand it to the frame as well (canvas coordinates).
static func push_off_screen(ev: InputEventMouse) -> void:
	if is_instance_valid(instance) and instance.frame != null:
		instance.frame.push_input(ev.duplicate(), true)


static func smooth_wanted() -> bool:
	var mode := String(ProjectSettings.get_setting(SETTING, "sharp"))
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--frame-scaling="):
			mode = a.trim_prefix("--frame-scaling=")
	return mode != "sharp"


func _enter_tree() -> void:
	instance = self


func _exit_tree() -> void:
	if instance == self:
		instance = null
	if frame != null and TooltipService.custom_viewport == frame:
		TooltipService.custom_viewport = get_tree().root


func _ready() -> void:
	# PC: keep the 1280×720 aspect with black bars (vanilla); the project's "expand" is for the touch layouts,
	# which fill wide / tall phone canvases (also the --device previews).
	if not DevicePreview.touch_default():
		get_tree().root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	if smooth_wanted():
		box = SubViewportContainer.new()
		box.name = "FrameBox"
		box.stretch = false
		box.mouse_filter = Control.MOUSE_FILTER_STOP
		frame = SubViewport.new()
		frame.name = "Frame"
		box.add_child(frame)
		add_child(box)
		_fit()
		get_tree().root.size_changed.connect(_fit)
		get_window().window_input.connect(_on_window_input)
		# The global tooltip (an autoload CanvasLayer in the root) is drawn inside the frame too.
		TooltipService.custom_viewport = frame
	_load(FIRST_SCENE)


## Frame = the stretched canvas (root visible rect); filter per the exe's blit rule.
func _fit() -> void:
	var root := get_tree().root
	var vis := root.get_visible_rect().size
	var sz := Vector2i(maxi(1, roundi(vis.x)), maxi(1, roundi(vis.y)))
	if frame.size != sz:
		frame.size = sz
	box.position = Vector2.ZERO
	box.size = Vector2(sz)
	var k := root.get_final_transform().get_scale().x
	var integral := absf(k - roundf(k)) < 0.001
	box.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST if integral else CanvasItem.TEXTURE_FILTER_LINEAR


## Pointer events the container never gets (outside it: the touch profile's OFF_SCREEN motion, TooltipService) are
## pushed into the frame directly, so its GUI and the views' motion hover still see the pointer leave.
func _on_window_input(event: InputEvent) -> void:
	if frame == null or not (event is InputEventMouse):
		return
	var p: Vector2 = get_tree().root.get_final_transform().affine_inverse() * (event as InputEventMouse).position
	if not Rect2(Vector2.ZERO, box.size).has_point(p):
		var ev: InputEventMouse = event.duplicate()
		ev.position = p
		ev.global_position = p
		frame.push_input(ev, true)


func _load(path: String) -> void:
	if scene != null and is_instance_valid(scene):
		scene.get_parent().remove_child(scene)
		scene.free()
	scene = (load(path) as PackedScene).instantiate()
	(frame if frame != null else self).add_child(scene)
