class_name SpaceImages
extends RefCounted
## Beacon backdrop picks (rules/backgrounds.md): the background image and the planet of a location, the fleet
## ships of a danger-zone beacon and the ASB planet. Pure rules: image lists come from EventDB.image_lists
## (paths under img/), randomness from the caller's RNG; textures are only read for their size.
## The drawing is scripts/ui/space_backdrop.gd.

const DEFAULT_BACK := "BACKGROUND"
const DEFAULT_PLANET := "PLANET"
const NONE := "NONE"
const PDS_LIST := "PLANET_POPULATED"
const PDS_POS := Vector2i(600, 247)  # SpaceManager::SetPlanetaryDefense
const PULSAR_BACK := "stars/bg_dullstars.png"  # SpaceManager::SetPulsarLevel replaces currentBack
const SANDBOX_BACK := "stars/bg_darknebula.png"  # combat sandbox (no run): the first BACKGROUND entry
const FRAME := Vector2i(1280, 720)
## SpaceManager::OnInit shipIds[0..7]: rebel (0–3) and federation (4–7) fleet ships; fleetShip (ASB gun ship).
const FLEET_IMAGES := ["ship/fleet/fleet_1_med.png", "ship/fleet/fleet_2_med.png", "ship/fleet/fleet_1_small.png",
	"ship/fleet/fleet_2_small.png", "ship/fleet/fleetfed_1_med.png", "ship/fleet/fleetfed_2_med.png",
	"ship/fleet/fleetfed_1_small.png", "ship/fleet/fleetfed_2_small.png"]
const FLEET_BIG := "ship/fleet/fleet_big.png"
const FLEET_BIG_POS := Vector2i(550, 447)
const FLEET_OFFSET := 150  # OnRenderFleet draws each ship at location − (150, 150)
const MAX_TRIES := 64  # vanilla re-rolls without limit; a one-entry list equal to the current image would hang


## EventGenerator::GetImageFromList: a uniform entry of the list, "" when the list does not exist.
static func image_from_list(lists: Dictionary, list_name: String, rng: RandomNumberGenerator) -> String:
	var l: Array = lists.get(list_name, [])
	if l.is_empty():
		return ""
	return String(l[rng.randi() % l.size()])


static func _tex(path: String) -> Texture2D:
	return FtlData.texture("img/" + path) if path != "" else null


## SpaceManager::SwitchBackground: draw from the list until the image differs from the one on screen
## (`current`). Returns the chosen path, or "" when the list gives no image (the old background stays).
static func switch_background(lists: Dictionary, list_name: String, current: String,
		rng: RandomNumberGenerator) -> String:
	for i in MAX_TRIES:
		var p := image_from_list(lists, list_name, rng)
		if _tex(p) == null:
			return ""
		if p != current or i == MAX_TRIES - 1:
			return p
	return ""


## SpaceManager::SwitchPlanet: "NONE" → no planet; else draw until the image differs from the current planet,
## then x = r % (1280 − w), y = r % (720 − h), rotation (r % 2)·180 (w, h = the texture's own size).
## Returns {} (no planet) or {img, pos: Vector2i, size: Vector2i, rot}.
static func switch_planet(lists: Dictionary, list_name: String, current: String,
		rng: RandomNumberGenerator) -> Dictionary:
	if list_name == NONE:
		return {}
	var p := ""
	var t: Texture2D = null
	for i in MAX_TRIES:
		p = image_from_list(lists, list_name, rng)
		t = _tex(p)
		if t == null:
			return {}
		if p != current:
			break
	var sz := Vector2i(t.get_size())
	var x := int(rng.randi() % maxi(FRAME.x - sz.x, 1))
	var y := int(rng.randi() % maxi(FRAME.y - sz.y, 1))
	var rot := int(rng.randi() % 2) * 180
	return {"img": p, "pos": Vector2i(x, y), "size": sz, "rot": rot}


## SpaceManager::SetPlanetaryDefense: a PLANET_POPULATED image at (600, 247), rotation (r % 2)·180.
static func pds_planet(lists: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var p := image_from_list(lists, PDS_LIST, rng)
	var t := _tex(p)
	var rot := int(rng.randi() % 2) * 180
	if t == null:
		return {}
	return {"img": p, "pos": PDS_POS, "size": Vector2i(t.get_size()), "rot": rot}


## SpaceManager::SetDangerZone(danger): 9 fleet ships on a 3 × 3 grid of the 1280 × 720 screen. Ship i:
## x = (r % 1280) / 3 + (i / 3)·1280 / 3, y = (i % 3)·720 / 3 + (r % 720) / 3, image r % 4 (+4 = federation):
## danger 1 rebel, 2 federation, 3 battle (ships 0–2 rebel, 3–5 a coin flip, 6–8 federation).
## Returns [{img, pos: Vector2i}] (pos = the location; drawn at pos − 150) or [] for danger 0.
@warning_ignore("integer_division")
static func danger_zone(danger: int, rng: RandomNumberGenerator) -> Array:
	var out := []
	if danger == 0:
		return out
	for i in 9:
		var rx := int(rng.randi() & 0x7fffffff)
		var ry := int(rng.randi() & 0x7fffffff)
		var id := int(rng.randi() % 4)
		if danger == 2 or (danger == 3 and i > 5):
			id += 4
		elif danger == 3 and i > 2:
			if rng.randi() % 2 == 1:
				id += 4
		var x := (rx % FRAME.x) / 3 + (i / 3) * FRAME.x / 3
		var y := (i % 3) * FRAME.y / 3 + (ry % FRAME.y) / 3
		out.append({"img": FLEET_IMAGES[id], "pos": Vector2i(x, y)})
	return out
