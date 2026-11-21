extends Node
## Tests for rules/crew_appearance.md (CrewIdentity, CrewPortrait, CrewMember identity): name pool and gender, no
## repeats among the player crew (21 draws), colour choices rolled once and kept, ShortenName, sheet / layer colours
## (female humans, enemy human white shirt, drones), death sound by gender, starting crew identities, and a store crew
## keeping its box identity on purchase. Uses the user's FTL data. Run:
##   godot --headless --path godot res://tests/test_crew_look.tscn

const Harness := preload("res://tests/harness.gd")

var fails := 0


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	# --- data
	var pool := FtlData.crew_names()
	var n: int = pool.keys.size()
	var females: int = pool.names.values().count(false)
	check("names.xml: ~169 unique names (default language)", n >= 150 and n <= 200, true)
	check("about 17 % female names", females > 15 and females < n / 3, true)
	check("preset short name read", pool.short.get("Norwyn Schultze", ""), "Schultze")
	check("human colour layers: shirt 1, hair/face 4", FtlData.crew_colors("human").map(func(l): return l.size()), [1, 4])
	check("engi has no colour layers", FtlData.crew_colors("engi").size(), 0)
	check("mantis 1 layer of 5", FtlData.crew_colors("mantis").map(func(l): return l.size()), [5])
	var shirt: Color = FtlData.crew_colors("human")[0][0]
	check("colour = r/255, a as-is", [roundi(shirt.r8), roundi(shirt.b * 255), roundi(shirt.a * 100)], [140, 255, 70])

	# --- names: gender from the name, no repeats while names are free, 21 draws then accept
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var used := []
	var gender_ok := true
	for i in 30:
		var got := CrewIdentity.unused_name(rng, used)
		if bool(pool.names[got[0]]) != bool(got[1]):
			gender_ok = false
	check("gender comes from the name's list", gender_ok, true)
	var uniq := {}
	for u in used:
		uniq[u] = true
	check("30 draws, no repeats (pool %d)" % n, uniq.size(), 30)
	var all: Array = pool.keys.duplicate()
	var last := CrewIdentity.unused_name(rng, all)
	check("all names used: the 21st draw is accepted anyway", [last[0] in pool.names, all.size()],
		[true, pool.keys.size() + 1])

	# --- ShortenName (font 6, 49 px)
	check("short: preset", CrewIdentity.shorten("Norwyn Schultze"), "Schultze")
	check("short: fits -> unchanged", CrewIdentity.shorten("Jon"), "Jon")
	check("short: last word when the whole name is too wide", CrewIdentity.shorten("Wwwwwwwwwwww Bob"), "Bob")
	var trimmed := CrewIdentity.shorten("Wwwwwwwwwwwwwww Mmmmmmmmmmmmmmmmm")
	check("short: narrowest word trimmed + '.'", [trimmed.ends_with("."), trimmed.begins_with("W"),
		FtlData.ftl_text_width(6, trimmed) <= 49 + FtlData.ftl_text_width(6, ".")], [true, true, true])
	var c := CrewMember.new("human")
	c.set_name("Norwyn Schultze")
	check("set_name: long kept, short derived", [c.name_long, c.name_short, c.display_name()],
		["Norwyn Schultze", "Schultze", "Schultze"])
	c.set_name("Norwyn Schultze", true)
	check("set_name(force): short = name", c.name_short, "Norwyn Schultze")

	# --- colours: rolled once, kept
	check("choose_colors keeps chosen values, fills -1", CrewIdentity.choose_colors(rng, "human", [0, 2]), [0, 2])
	var ch := CrewIdentity.choose_colors(rng, "human", [-1, -1])
	check("choose_colors rolls in range", ch[0] == 0 and ch[1] >= 0 and ch[1] < 4, true)
	var varied := {}
	for i in 40:
		varied[CrewIdentity.choose_colors(rng, "mantis", [])[0]] = true
	check("mantis colours vary", varied.size() > 2, true)

	# --- looks
	var f := CrewMember.new("human")
	f.male = false
	f.color_choices = [0, 1]
	check("female human uses female_* sheets", CrewPortrait.look_of(f).file, "female")
	check("male human uses human_*", CrewPortrait.look(String("human"), true, []).file, "human")
	check("female slug keeps slug_* sheets", CrewPortrait.sheet_file("slug", false), "slug")
	var e := CrewMember.new("human", false)
	e.color_choices = [0, 1]
	var el: Array = CrewPortrait.look_of(e).colors
	check("enemy human shirt layer forced white", [el[0], el[1] == FtlData.crew_colors("human")[1][1]], [Color.WHITE, true])
	check("player human shirt = its colour", CrewPortrait.look_of(f).colors[0], FtlData.crew_colors("human")[0][0])
	var d := CrewMember.new("human", true)
	d.make_drone("repair")
	check("player drone layer green", CrewPortrait.look_of(d).colors, [CrewPortrait.COLOR_GREEN])
	var ed := CrewMember.new("human", false)
	ed.make_drone("battle")
	check("enemy drone layer red", CrewPortrait.look_of(ed).colors, [CrewPortrait.COLOR_RED])
	var fs := CrewMember.new("slug")
	fs.male = false
	check("female slug: femaleDeath sound", fs.death_sound().begins_with("femaleDeath"), true)
	var mh := CrewMember.new("human")
	check("male human: death1/2", mh.death_sound().begins_with("death"), true)
	var fm := CrewMember.new("mantis")
	fm.male = false
	check("mantis: own death sound regardless", fm.death_sound(), "mantisDeath")

	# --- starting crew: named, unique, colours rolled; different runs differ; same seed replays
	var r1 := RunState.new_run(101)
	var names1 := r1.ship.own_crew().map(func(x): return x.name_long)
	check("starting crew named", names1.all(func(x): return x != ""), true)
	var u1 := {}
	for x in names1:
		u1[x] = true
	check("starting crew names unique", u1.size(), names1.size())
	check("starting crew colours rolled", r1.ship.own_crew().all(func(x): return (x.color_choices.size() ==
		FtlData.crew_colors(x.race).size() and not -1 in x.color_choices)), true)
	var r1b := RunState.new_run(101)
	check("same seed -> same starting crew", r1b.ship.own_crew().map(func(x): return x.name_long), names1)
	var differ := false
	for s in range(102, 110):
		if RunState.new_run(s).ship.own_crew().map(func(x): return x.name_long) != names1:
			differ = true
	check("other seeds -> other starting crew", differ, true)
	# colours persist on the run's crew (no re-roll on later reads / jumps)
	var keep := r1.ship.own_crew().map(func(x): return [x.name_long, x.male, x.color_choices.duplicate()])
	var links: Array = r1.map.beacons[r1.current_beacon].links
	if not links.is_empty():
		r1.jump_to(int(links[0]))
	check("identity persists in the run state", r1.ship.own_crew().map(func(x): return [x.name_long, x.male,
		x.color_choices.duplicate()]), keep)
	var added := r1.ship.add_crew("engi", true)
	check("event / debug crew get a name too", added.name_long != "" and not added.name_long in names1, true)

	# --- store crew: identity pre-rolled with the box, kept on purchase
	var rs := RunState.new_run(5)
	var st := RunStore.new()
	var grng := RandomNumberGenerator.new()
	grng.seed = 3
	var sec := st._boxes(RunStore.CREW, grng, rs.ship, 2, true, {"crew": {"human": 1, "mantis": 2}}, [RunStore.CREW])
	var ids := sec.map(func(o): return o.extra.get("ident", {}))
	check("store crew boxes carry name / gender / colours", ids.all(func(i): return (String(i.get("name", "")) != ""
		and i.has("male") and i.colors.size() == FtlData.crew_colors(i.race).size())), true)
	var box_names := ids.map(func(i): return i.name)
	var crew_names := rs.ship.own_crew().map(func(x): return x.name_long)
	check("store names distinct from each other and the crew", box_names.all(func(x): return (box_names.count(x) == 1
		and not x in crew_names)), true)
	st.sections = [{"type": RunStore.CREW, "boxes": sec}]
	st.resources = {"fuel": {"count": 0, "price": 3}, "missiles": {"count": 0, "price": 6},
		"drones": {"count": 0, "price": 8}}
	rs.beacon().shop = st
	rs.store_open = true
	rs.ship.scrap = 500
	var id0: Dictionary = sec[0].extra.ident
	check("buy store crew", rs.store_buy(0), "ok")
	var hired: CrewMember = rs.ship.crew[-1]
	check("hired crew keeps the box identity", [hired.race, hired.name_long, hired.male, hired.color_choices],
		[id0.race, id0.name, id0.male, id0.colors])
	check("hired crew short name derived", hired.name_short, CrewIdentity.shorten(id0.name))
	check("store box name = crew name", StoreView.short_name(sec[1]), String(sec[1].extra.ident.name))

