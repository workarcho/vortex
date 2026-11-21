extends Control
## First-run data setup (data_setup.tscn). FTL Proto ships nothing from FTL: when FtlData finds no usable data folder
## (or the one in user:// is incomplete), title.gd opens this screen. The player selects their own `ftl.dat` with the
## system file picker; it is unpacked into user://ftl-data (DatExtractor, a few entries per frame so the progress bar
## moves), FtlData.reload() picks it up and the title screen loads.
##
## Picker: DisplayServer.file_dialog_show (native dialog) when the platform has one, else Godot's FileDialog.
## On Android (Godot 4.7) the native picker is the system document picker (ACTION_OPEN_DOCUMENT); the selected
## entry comes back as a `content://` URI, which Godot's FileAccess opens directly (its SAF data access), so no
## storage permission is needed. A plain filesystem path (desktop, or a picker that resolves one) works the same.
## Plain Godot UI on purpose: FTL's fonts and images are exactly what is missing here.
##
## CLI: --data-setup (title.gd: show this screen even with data), --ftl-dat=<path> (start extracting that file).

const TITLE_SCENE := "res://title.tscn"

var extractor: DatExtractor
var status: Label
var problem: Label
var bar: ProgressBar
var pick_button: Button
var _dialog: FileDialog


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color(0.05, 0.06, 0.08))
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build()
	if FtlData.data_problem_text != "":
		problem.text = "The game data found earlier is unusable (%s). Select ftl.dat again." % FtlData.data_problem_text
	get_window().files_dropped.connect(_on_files_dropped)  # desktop: drop ftl.dat on the window
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--ftl-dat="):
			start_extraction.call_deferred(a.trim_prefix("--ftl-dat="))


func _build() -> void:
	var th := Theme.new()
	th.default_font_size = 24
	theme = th
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.06, 0.08)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(minf(900.0, get_viewport_rect().size.x - 64.0), 0)
	box.add_theme_constant_override("separation", 18)
	center.add_child(box)

	var head := Label.new()
	head.text = "FTL game data needed"
	head.add_theme_font_size_override("font_size", 40)
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(head)
	var body := Label.new()
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.text = ("This prototype includes none of FTL's files. It runs on the data of your own copy of "
		+ "FTL: Faster Than Light (version 1.6.x).\n\nCopy ftl.dat from your FTL install folder (Steam: "
		+ "steamapps/common/FTL Faster Than Light/ftl.dat) to this device, then select it below. "
		+ "It is unpacked once into the app's storage (about 280 MB).")
	box.add_child(body)
	problem = Label.new()
	problem.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	problem.add_theme_color_override("font_color", Color(1.0, 0.6, 0.4))
	box.add_child(problem)
	pick_button = Button.new()
	pick_button.text = "Select ftl.dat…"
	pick_button.custom_minimum_size = Vector2(0, 72)
	pick_button.pressed.connect(_pick)
	box.add_child(pick_button)
	bar = ProgressBar.new()
	bar.custom_minimum_size = Vector2(0, 32)
	bar.max_value = 1.0
	bar.step = 0.001
	bar.visible = false
	box.add_child(bar)
	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(status)


# ------------------------------------------------------------------ picking

func _pick() -> void:
	if busy():
		return
	problem.text = ""
	if DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE):
		# Android maps filters to MIME types and .dat has none: show every file there.
		var filters := PackedStringArray() if OS.get_name() == "Android" \
			else PackedStringArray(["*.dat, *.vanilla ; FTL data", "* ; All files"])
		var start := "" if OS.get_name() == "Android" else OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS)
		var err := DisplayServer.file_dialog_show("Select ftl.dat", start, "", false,
			DisplayServer.FILE_DIALOG_MODE_OPEN_FILE, filters, _on_native_picked)
		if err == OK:
			status.text = "Waiting for the file picker…"
			return
	_show_godot_dialog()


func _on_native_picked(ok: bool, paths: PackedStringArray, _filter: int) -> void:
	if not ok or paths.is_empty():
		status.text = "No file selected."
		return
	print("data setup: picker returned ", paths[0])
	start_extraction.call_deferred(paths[0])


func _show_godot_dialog() -> void:
	if _dialog == null:
		_dialog = FileDialog.new()
		_dialog.use_native_dialog = false
		_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_dialog.filters = PackedStringArray(["*.dat, *.vanilla ; FTL data", "* ; All files"])
		_dialog.title = "Select ftl.dat"
		_dialog.file_selected.connect(start_extraction)
		add_child(_dialog)
	_dialog.popup_centered_ratio(0.85)


func _on_files_dropped(files: PackedStringArray) -> void:
	if not files.is_empty():
		start_extraction(files[0])


# ------------------------------------------------------------------ extraction

func busy() -> bool:
	return extractor != null


## Starts unpacking `path` (filesystem path or content:// URI) into user://ftl-data.
func start_extraction(path: String) -> void:
	if busy():
		return
	var ex := DatExtractor.new()
	if not ex.begin(path, FtlData.user_data_dir()):
		_failed(ex.error)
		return
	extractor = ex
	pick_button.disabled = true
	bar.visible = true
	bar.value = 0.0
	DisplayServer.screen_set_keep_on(true)
	status.text = "Unpacking %d files…" % ex.entries.size()


func _process(_delta: float) -> void:
	if extractor == null:
		return
	var done := extractor.step(25)
	bar.value = extractor.progress()
	status.text = "Unpacking… %d / %d files (%d / %d MB)" % [extractor.done_files, extractor.entries.size(),
		extractor.done_bytes / 1048576, extractor.total_bytes / 1048576]
	if not done:
		return
	var ex := extractor
	extractor = null
	DisplayServer.screen_set_keep_on(false)
	if ex.error != "":
		_failed(ex.error)
		return
	print("data setup: extracted %d files (%d bytes, %s) to %s" % [ex.done_files, ex.done_bytes, ex.format, ex.dst])
	if not FtlData.reload():
		_failed("The unpacked data is unusable: %s." % FtlData.data_problem_text)
		return
	status.text = "Done."
	FrameHost.change_scene(get_tree(), TITLE_SCENE)


func _failed(msg: String) -> void:
	push_warning("data setup: " + msg)
	pick_button.disabled = false
	bar.visible = false
	status.text = ""
	problem.text = msg
