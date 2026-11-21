class_name EventDB
extends RefCounted
## Event templates loaded from the user's FTL data (rules/events.md §1): events, eventLists, textLists, ship
## templates, shipLists, sectorDescriptions, sectorTypes, plus item rarities for random rewards. Later
## definitions win (dlcEventsOverwrite.xml is loaded last). Pure data; parsed once and shared.

var events := {}  # name -> XmlNode <event>
var lists := {}  # name -> Array[XmlNode] (entries: <event load=..> or inline <event>)
var text_lists := {}  # name -> Array[XmlNode] (<text> nodes)
var image_lists := {}  # name -> Array[String] image paths under img/ (<imageList>; ui="..." variants skipped)
var ships := {}  # name -> XmlNode <ship>
var ship_lists := {}  # name -> Array[String]
var sectors := {}  # name -> XmlNode <sectorDescription>
var sector_types := {}  # name -> Array[String]
var rarity := {"weapon": {}, "drone": {}, "augment": {}, "crew": {}}  # kind -> name -> rarity
var _inline := 0

static var _shared: EventDB = null


static func shared() -> EventDB:
	if _shared == null:
		_shared = EventDB.new()
		_shared.load_all()
	return _shared


func load_all() -> void:
	for f in RunTuning.data().get("event_files", []):
		var src := FtlData.text("data/" + String(f))
		if src == "":
			continue
		add_source(src)
	for f in ["data/blueprints.xml", "data/dlcBlueprints.xml", "data/dlcBlueprintsOverwrite.xml"]:
		_load_rarities(FtlData.text(f))
	Hooks.emit(&"event_data_loaded", self)  # mods may add / replace events, lists, ships, sectors


## Adds the top-level nodes of one file (EventsParser::ProcessBaseNode). Unknown nodes are ignored.
func add_source(src: String) -> void:
	for n0 in XmlNode.parse(src).children:
		# Data patches per definition (rules/hooks.md `event_node_loaded`): replace or cancel (skip) a node.
		var fn: Variant = Hooks.filter(&"event_node_loaded", n0, n0.tag, n0.attr("name"))
		if not fn is XmlNode:
			continue
		var n: XmlNode = fn
		var name := n.attr("name")
		match n.tag:
			"event":
				if name != "":
					events[name] = n
			"eventList":
				if name != "":
					lists[name] = n.children_named("event")
			"textList":
				if name != "":
					text_lists[name] = n.children_named("text")
			"imageList":
				# ProcessBaseNode / ProcessImageList (rules/backgrounds.md §1): only lists without a `ui` attribute;
				# each <img> keeps its text (the path) only, w / h are ignored; a later list of the same name
				# replaces the earlier one.
				if name != "" and n.attr("ui") == "":
					var imgs: Array[String] = []
					for im in n.children_named("img"):
						imgs.append(im.text.strip_edges())
					image_lists[name] = imgs
			"ship":
				if name != "":
					ships[name] = n
			"shipList":
				if name != "":
					var arr := []
					for s in n.children_named("ship"):
						arr.append(s.attr("load", s.attr("name")))
					ship_lists[name] = arr
			"sectorDescription":
				if name != "":
					sectors[name] = n
			"sectorType":
				if name != "":
					var arr := []
					for s in n.children_named("sector"):
						arr.append(s.text)
					sector_types[name] = arr


func _load_rarities(src: String) -> void:
	var kinds := {"weaponBlueprint": "weapon", "droneBlueprint": "drone", "augBlueprint": "augment",
		"crewBlueprint": "crew"}
	for n in XmlNode.parse(src).children:
		if not kinds.has(n.tag):
			continue
		var r := n.child("rarity")
		rarity[kinds[n.tag]][n.attr("name")] = int(r.text) if r != null else 0


func has_event_or_list(name: String) -> bool:
	return events.has(name) or lists.has(name)
