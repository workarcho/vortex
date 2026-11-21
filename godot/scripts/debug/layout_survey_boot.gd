extends Node
## Boot scene for the read-only layout survey (layout_survey.gd): adds the survey node to the root (it survives
## scene changes) and opens the title scene as a normal run would.


func _ready() -> void:
	var s := preload("res://scripts/debug/layout_survey.gd").new()
	s.name = "LayoutSurvey"
	get_tree().root.add_child.call_deferred(s)
	get_tree().change_scene_to_file.call_deferred("res://title.tscn")
