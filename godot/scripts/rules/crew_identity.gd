class_name CrewIdentity
extends RefCounted
## Crew names, gender and colour choices (rules/crew_appearance.md §2, §3, §5, §6). Engine-free apart from the data
## reader; the RNG is injected (`CrewIdentity.rng` is the shared default stream: seeded from the run seed by
## RunState.new_run, random otherwise, so the starting crew differs every run).
##
## Identity dictionary (store boxes, events): {race, name (long), male, colors: Array[int] colour choices}.

const MAX_DRAWS := 21  # GetUnusedCrewName: up to 21 draws, then the last draw is accepted anyway
const SHORT_FONT := 6  # ShortenName measures with font 6 ...
const SHORT_WIDTH := 49  # ... against 49 px (the crew-list name / health-bar width)

static var rng := RandomNumberGenerator.new()


## GetCrewName: uniform over the unique names of the pool; the gender comes with the name. [name, male]
static func random_name(r: RandomNumberGenerator) -> Array:
	var pool := FtlData.crew_names()
	var keys: Array = pool.keys
	if keys.is_empty():
		return ["", true]
	var nm: String = keys[r.randi() % keys.size()]
	return [nm, bool(pool.names[nm])]


## GetUnusedCrewName: the first of up to 21 draws not in `used` (exact compare), else the last draw. The accepted
## name is appended to `used` (boxes generated together stay distinct). [name, male]
static func unused_name(r: RandomNumberGenerator, used: Array) -> Array:
	var got := ["", true]
	for i in MAX_DRAWS:
		got = random_name(r)
		if not got[0] in used:
			break
	used.append(got[0])
	return got


## CrewBlueprint::ChooseColors / CrewMember ctor: each layer still at −1 gets rand % layer size; chosen values kept.
static func choose_colors(r: RandomNumberGenerator, race: String, choices: Array) -> Array:
	var layers := FtlData.crew_colors(race)
	var out := choices.duplicate()
	out.resize(layers.size())
	for i in layers.size():
		if out[i] == null or int(out[i]) < 0 or int(out[i]) >= (layers[i] as Array).size():
			out[i] = int(r.randi() % (layers[i] as Array).size())
	return out


## ShortenName (font 6, 49 px): preset `short` → the name if it fits → the last word if it fits → the narrowest
## word trimmed until it fits with a trailing ".".
static func shorten(full: String) -> String:
	var pool := FtlData.crew_names()
	if pool.short.has(full):
		return String(pool.short[full])
	if _w(full) <= SHORT_WIDTH:
		return full
	var words := []
	for part in full.replace("·", " ").replace("・", " ").split(" ", false):
		words.append(part)
	if words.is_empty():
		return full
	if _w(words[-1]) < SHORT_WIDTH:
		return words[-1]
	var best: String = words[0]
	for wd in words:
		if _w(wd) < _w(best):
			best = wd
	var dot := _w("..") - _w(".")
	var cut := best
	while cut.length() > 0 and _w(cut) > SHORT_WIDTH - dot:
		cut = cut.substr(0, cut.length() - 1)
	return cut + "." if cut != best else best


static func _w(s: String) -> int:
	return FtlData.ftl_text_width(SHORT_FONT, s)


## Long names of the player's crew (CrewMemberFactory::SetUsedCrewNames: player-owned, in game or waiting for the
## clonebay; drones excluded).
static func used_names(ship: ShipState) -> Array:
	var out := []
	if ship == null:
		return out
	for c in ship.crew:
		if c.player_owned and not c.is_drone() and c.name_long != "":
			out.append(c.name_long)
	return out


## A fresh identity for a race (store box / GetCrewBlueprint): random unused name + gender, colours rolled.
static func roll(race: String, r: RandomNumberGenerator, used: Array) -> Dictionary:
	var nm := unused_name(r, used)
	return {"race": race, "name": nm[0], "male": nm[1], "colors": choose_colors(r, race, [])}


## Gives `c` the identity (name re-shortened, gender, colour choices kept; any −1 rolled with `r`).
static func apply(c: CrewMember, ident: Dictionary, r: RandomNumberGenerator = null) -> void:
	c.male = bool(ident.get("male", true))
	c.set_name(String(ident.get("name", "")))
	c.color_choices = choose_colors(r if r else rng, c.race, ident.get("colors", []))


## AddCrewMember with an empty name: random unused name / gender and colours (crew drones get nothing).
static func assign(c: CrewMember, r: RandomNumberGenerator = null, used: Array = []) -> void:
	if c.is_drone():
		return
	var g := r if r else rng
	var nm := unused_name(g, used)
	c.male = nm[1]
	c.set_name(nm[0])
	c.color_choices = choose_colors(g, c.race, c.color_choices)
