extends Node
## Tests for rules/fonts.md (the `.font` loader and FTL text layout). Run:
##   godot --headless --path godot res://tests/test_fonts.tscn

const Harness := preload("res://tests/harness.gd")

var fails := 0
const SAMPLE := "HULL Weapons: Burst Laser II 0123 gjpq"


func check(name: String, got, want) -> void:
	if got == want:
		print("  ok   ", name, " = ", got)
	else:
		fails += 1
		print("  FAIL ", name, ": got ", got, ", expected ", want)


## [x, y, w, h, ascent, prekern×256, postkern×256] of a glyph.
func glyph(f: FtlFont, ch: String) -> Array:
	return Array(f.glyphs.get(ch.unicode_at(0), PackedInt32Array()))


func _ready() -> void:
	Harness.run(self, _run)


func _run() -> void:
	print("Files parse")
	for id in [0, 5, 9, 10, 12, 13, 14, 51, 61]:
		var f := FtlData.ftl_font(id)
		check("font id %d loads" % id, f != null and f.ok, true)
	var hl2 := FtlData.ftl_font(62)
	check("HL2 header height / baseline", [hl2.height, hl2.baseline], [12, 9])
	check("HL2 glyph count", hl2.glyphs.size(), 252)
	check("HL2 atlas", [hl2.texture.get_width(), hl2.texture.get_height()], [256, 128])
	check("JustinFont8 header", [FtlData.ftl_font(7).height, FtlData.ftl_font(7).baseline, FtlData.ftl_font(7).glyphs.size()],
		[19, 12, 388])
	check("num_font header", [FtlData.ftl_font(0).height, FtlData.ftl_font(0).baseline], [24, 20])

	print("Glyph metrics (font_dump.py reference)")
	check("HL2 'H'", glyph(hl2, "H"), [16, 14, 7, 8, 7, 0, 102])
	check("HL2 'g'", glyph(hl2, "g"), [237, 15, 6, 9, 6, 0, 102])
	check("HL2 '0'", glyph(hl2, "0"), [101, 2, 6, 8, 7, 0, 102])
	check("num_font '0'", glyph(FtlData.ftl_font(0), "0"), [129, 7, 10, 14, 14, 0, 512])
	check("JustinFont8 'A'", glyph(FtlData.ftl_font(9), "A"), [182, 5, 6, 8, 8, 0, 256])

	print("Id remaps and metrics (GetFontData / PreloadFont)")
	check("ids 6, 7, 8 -> 9", [FtlFont.resolve_id(6), FtlFont.resolve_id(7), FtlFont.resolve_id(8)], [9, 9, 9])
	check("id 11 -> 12, unknown -> 12", [FtlFont.resolve_id(11), FtlFont.resolve_id(77)], [12, 12])
	check("id 62 = HL2 2x, baseline 16, line 24", FtlData.ftl_font_metrics(62), [2.0, 16, 24])
	check("id 61 baseline override 8", FtlData.ftl_font_metrics(61), [1.0, 8, 10])
	check("id 0 baseline 12 line 15", FtlData.ftl_font_metrics(0), [1.0, 12, 15])

	print("Text width (per-glyph rounding)")
	check("HL2 @12 (61)", FtlData.ftl_text_width(61, SAMPLE), 201)
	check("HL2 @24 (62)", FtlData.ftl_text_width(62, SAMPLE), 440)
	check("JustinFont8 @19 (7)", FtlData.ftl_text_width(7, SAMPLE), 239)
	check("num_font @24 (0)", FtlData.ftl_text_width(0, SAMPLE), 338)
	check("'HH' @61: postkern rounded away at 1x", FtlData.ftl_text_width(61, "HH"), 14)
	check("'HH' @62: +1 px per glyph at 2x", FtlData.ftl_text_width(62, "HH"), 30)
	check("missing code points are skipped", FtlData.ftl_text_width(61, "A一A"), FtlData.ftl_text_width(61, "AA"))
	check("multi-line width = widest line", FtlData.ftl_text_width(61, "A\nAAA"), FtlData.ftl_text_width(61, "AAA"))
	var lines := FtlData.ftl_wrap(9, "Heavy Laser Mark II", 55)
	check("wrap: lines fit the width", Array(lines).all(func(l): return FtlData.ftl_text_width(9, l) <= 55), true)
	check("wrap: words kept in order", " ".join(lines), "Heavy Laser Mark II")
	check("wrap: more than one line", lines.size() > 1, true)
	var b := hl2.ink_bounds("HULL", 2.0)
	check("ink bounds 'HULL' @2x", [b.x, b.y], [0, FtlData.ftl_text_width(62, "HULL") - 1])

	print("HUD helpers")
	check("tooltip size = text + (27, 18) + title", FtlTooltip.box_size("Shields", "Blocks projectiles.", 350),
		Vector2(maxi(FtlData.ftl_text_width(12, "Blocks projectiles."), FtlData.ftl_text_width(13, "Shields")) + 27,
		FtlData.ftl_line_height(12) + 18 + FtlData.ftl_line_height(13) + 5))
	check("system boxes: plain every 36, button boxes every 54", HudLayout.system_box_xs(
		["shields", "engines", "teleporter", "oxygen"], ["teleporter"], true, 4, true),
		{"shields": 58, "engines": 94, "teleporter": 130, "oxygen": 184, "weapons": 220, "drones": 656})
	check("HudDraw.txt turns \\n escapes into new lines", HudDraw.txt("warning_no_power"), "NOT\nENOUGH\nPOWER")

