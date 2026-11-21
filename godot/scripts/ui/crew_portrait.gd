class_name CrewPortrait
extends RefCounted
## Crew sprite drawing with colour layers (rules/crew_appearance.md §4), shared by the ship view, the crew list, the
## store and the ship-management screens. Static helpers only.
##
## A "look" is {race, file, colors: Array[Color]}: `file` = the people/ sheet prefix (`female` for a female human),
## `colors` = the resolved colour of each `_layer<N>.png` (enemy human shirt forced white, drones green / red).
## Drawing = `<file>_base.png` × tint, then each layer × (tint.rgb · colour.rgb, colour.a) on the same frame.

const COLOR_GREEN := Color8(100, 255, 100)  # player drone light
const COLOR_RED := Color8(255, 50, 50)  # enemy drone light
const COLOR_YELLOW := Color8(255, 255, 50)  # crew-list portrait outline


## Sheet prefix: the race, except female humans (`female_*`) and event ghosts (CrewAnimation::OnInit: species
## "ghost" -> bGhost, drawn with the `human` sheets at alpha 0.5).
static func sheet_file(race: String, male: bool) -> String:
	if race == "ghost":
		return "human"
	return "female" if race == "human" and not male else race


## Look of a crew member (CrewAnimation::SetupStrips layerColors).
static func look_of(c: CrewMember) -> Dictionary:
	var cols: Array = []
	if c.is_drone():
		cols = [COLOR_GREEN if c.player_owned else COLOR_RED]
	else:
		cols = layer_colors(c.race, c.color_choices)
		if c.race == "human" and not c.player_owned and not cols.is_empty():
			cols[0] = Color.WHITE  # enemy humans: shirt layer untinted, alpha 1
	return {"race": c.race, "file": sheet_file(c.race, c.male) if not c.is_drone() else c.race, "colors": cols}


## Look from an identity (store box / blueprint icon: CrewBlueprint::RenderIcon; choice −1 → index 0).
static func look(race: String, male: bool, choices: Array) -> Dictionary:
	return {"race": race, "file": sheet_file(race, male), "colors": layer_colors(race, choices)}


## Crew-like drone icon (store drone box: base white + layer1 green).
static func drone_look(race: String) -> Dictionary:
	return {"race": race, "file": race, "colors": [COLOR_GREEN]}


static func layer_colors(race: String, choices: Array) -> Array:
	var out: Array = []
	var layers := FtlData.crew_colors(race)
	for i in layers.size():
		var ch := int(choices[i]) if i < choices.size() and choices[i] != null else 0
		var lay: Array = layers[i]
		out.append(lay[clampi(ch, 0, lay.size() - 1)])
	return out


## True when `anim` is drawn from the race's own `<race>_base.png` sheet (walk / type / repair / death ...); other
## animations (drone deaths, effects) have no layers.
static func is_base_anim(race: String, anim: Dictionary) -> bool:
	return not anim.is_empty() and anim.texture == FtlData.texture("img/people/%s_base.png" % (
		"human" if race == "ghost" else race))


## One frame of a crew animation with its layers (CrewAnimation::OnRender minus the outline).
static func draw_frame(ci: CanvasItem, lk: Dictionary, anim: Dictionary, src: Rect2, rect: Rect2,
		tint := Color.WHITE, alpha := 1.0) -> void:
	if not is_base_anim(String(lk.race), anim):
		ci.draw_texture_rect_region(anim.texture, rect, src, Color(tint, tint.a * alpha))
		return
	var base := FtlData.texture("img/people/%s_base.png" % lk.file)
	if base == null:
		base = anim.texture
	ci.draw_texture_rect_region(base, rect, src, Color(tint, tint.a * alpha))
	var cols: Array = lk.colors
	for i in cols.size():
		var col: Color = cols[i]
		if col.a <= 0.0:
			continue
		var tex := FtlData.texture("img/people/%s_layer%d.png" % [lk.file, i + 1])
		if tex:
			ci.draw_texture_rect_region(tex, rect, src,
				Color(tint.r * col.r, tint.g * col.g, tint.b * col.b, col.a * alpha))


## The silhouette sheet for the outline (`<file>_color.png`), only for frames of the base sheet; none for drones.
static func outline_texture(c: CrewMember, anim: Dictionary) -> Texture2D:
	if c.is_drone() or not is_base_anim(c.race, anim):
		return null
	return FtlData.texture("img/people/%s_color.png" % sheet_file(c.race, c.male))


## Portrait = `<race>_walk_down` frame 0, centred on `centre`, × `scale`, base + layers (CrewAnimation::RenderIcon /
## CrewBlueprint::RenderIcon). `outline` = the `_color` silhouette in COLOR_YELLOW under it (crew list box).
static func draw_icon(ci: CanvasItem, lk: Dictionary, centre: Vector2, scale := 1.0, outline := false) -> void:
	var an := FtlData.anim(String(lk.race) + "_walk_down")
	if an.is_empty():
		return
	var src: Rect2 = an.frames[0]
	var rect := Rect2(centre - src.size * scale / 2.0, src.size * scale)
	if outline:
		var ot := FtlData.texture("img/people/%s_color.png" % lk.file)
		if ot:
			ci.draw_texture_rect_region(ot, rect, src, COLOR_YELLOW)
	draw_frame(ci, lk, an, src, rect)
