class_name FtlFont
extends RefCounted
## FTL bitmap font (`ftl-data/fonts/*.font`, rules/fonts.md): big-endian header + 16-byte glyph records + an
## embedded A8 `TEX` atlas. Loaded at runtime from the user's ftl-data (never shipped). Drawing follows
## font_bitmap_render: per-glyph pen rounding, nearest filtering, no kerning pairs.
## Use through `FtlData.draw_ftl_text()` / `FtlData.ftl_text_width()` (font ids, not files).

## Font id -> [file, size, baseline, lineHeight] (ResourceControl::PreloadFont; rules/fonts.md table).
const IDS := {
	0: ["num_font", 24, 12, 15],
	5: ["c&c", 15, 10, 11],
	9: ["JustinFont8", 19, 12, 15],
	10: ["JustinFont10", 19, 12, 17],
	12: ["JustinFont11Bold", 19, 12, 20],
	18: ["JustinFont11Bold", 38, 24, 34],
	20: ["JustinFont11Bold", 57, 36, 53],
	13: ["JustinFont12Bold", 19, 12, 22],
	14: ["c&cnew", 38, 24, 34],
	16: ["c&cnew", 38, 24, 20],
	24: ["c&cnew", 57, 36, 53],
	51: ["HL1", 11, 8, 10],
	52: ["HL1", 22, 16, 24],
	59: ["HL1", 22, 16, 18],
	53: ["HL1", 33, 24, 38],
	61: ["HL2", 12, 8, 10],
	62: ["HL2", 24, 16, 24],
	63: ["HL2", 36, 24, 38],
	64: ["HL2", 48, 32, 52],
}

enum Align { LEFT = 0, CENTER = 1, RIGHT = 2 }

var file := ""
var height := 0  # native pixel height (scale 1)
var baseline := 0  # native baseline
var glyphs := {}  # code point -> PackedInt32Array [x, y, w, h, ascent, prekern×256, postkern×256]
var texture: Texture2D
var ok := false


## GetFontData: 6–8 -> 9, 11 -> 12, unknown ids -> 12.
static func resolve_id(id: int) -> int:
	if id >= 6 and id <= 8:
		return 9
	if id == 11:
		return 12
	return id if IDS.has(id) else 12


## Parses a `.font` file. Returns a font with ok == false on any format error.
static func load_file(path: String) -> FtlFont:
	var f := FtlFont.new()
	f.file = path
	var data := FileAccess.get_file_as_bytes(path)
	if data.size() < 24 or data.slice(0, 4).get_string_from_ascii() != "FONT" or data[4] != 1:
		push_warning("FtlFont: not a FONT v1 file: " + path)
		return f
	f.height = data[5]
	f.baseline = data[6]
	var ci_off := _i32(data, 8)
	var ci_count := _u16(data, 12)
	var ci_size := _i16(data, 14)
	var tex_off := _i32(data, 16)
	if ci_size != 16:
		push_warning("FtlFont: charinfo size %d in %s" % [ci_size, path])
		return f
	for i in ci_count:
		var o := ci_off + i * 16
		var ch := _i32(data, o)
		if ch < 0:
			continue
		var asc := data[o + 10]
		if asc >= 128:
			asc -= 256
		f.glyphs[ch] = PackedInt32Array([_i16(data, o + 4), _i16(data, o + 6), data[o + 8], data[o + 9], asc,
			_i16(data, o + 12), _i16(data, o + 14)])
	# Embedded TEX v2, A8 alpha coverage.
	var t := tex_off
	if data.slice(t, t + 4).get_string_from_ascii() != "TEX\n" or data[t + 4] != 2:
		push_warning("FtlFont: bad TEX blob in " + path)
		return f
	var fmt := data[t + 5]
	var w := _i16(data, t + 8)
	var h := _i16(data, t + 10)
	var px_off := t + _i32(data, t + 16)
	if fmt != 0x40 and fmt != 0x41:
		push_warning("FtlFont: texture format 0x%x unsupported in %s" % [fmt, path])
		return f
	var la := PackedByteArray()
	la.resize(w * h * 2)
	for i in w * h:
		var a := data[px_off + i]
		la[i * 2] = 255
		la[i * 2 + 1] = a if fmt == 0x40 else 255
		if fmt == 0x41:
			la[i * 2] = a
	var img := Image.create_from_data(w, h, false, Image.FORMAT_LA8, la)
	f.texture = ImageTexture.create_from_image(img)
	f.ok = true
	return f


static func _i32(d: PackedByteArray, o: int) -> int:
	var v := (d[o] << 24) | (d[o + 1] << 16) | (d[o + 2] << 8) | d[o + 3]
	return v - 0x100000000 if v >= 0x80000000 else v


static func _u16(d: PackedByteArray, o: int) -> int:
	return (d[o] << 8) | d[o + 1]


static func _i16(d: PackedByteArray, o: int) -> int:
	var v := _u16(d, o)
	return v - 0x10000 if v >= 0x8000 else v


## roundf: half away from zero.
static func rnd(x: float) -> int:
	return int(floorf(x + 0.5)) if x >= 0.0 else -int(floorf(-x + 0.5))


## Glyph quads of one line at scale s, pen starting at 0: [[code point, gx], ...] and the final pen.
func layout_line(text: String, s: float) -> Array:
	var out := []
	var pen := 0.0
	for i in text.length():
		var g: PackedInt32Array = glyphs.get(text.unicode_at(i), PackedInt32Array())
		if g.is_empty():
			continue  # missing code points are skipped (no advance)
		var gx := rnd(pen + g[5] / 256.0 * s)
		out.append([g, gx])
		pen = gx + (g[2] + g[6] / 256.0) * s
	return [out, pen]


## text_advance: same accumulation, final pen rounded.
func line_width(text: String, s: float) -> int:
	return rnd(layout_line(text, s)[1])


## Rounded ink bounds [left, right] of a line (font_bitmap_get_text_bounds).
func ink_bounds(text: String, s: float) -> Vector2i:
	var l := 1 << 30
	var r := -(1 << 30)
	for q in layout_line(text, s)[0]:
		var g: PackedInt32Array = q[0]
		if g[2] == 0:
			continue
		l = mini(l, q[1])
		r = maxi(r, q[1] + rnd(g[2] * s))
	return Vector2i(0, 0) if l > r else Vector2i(l, r)
