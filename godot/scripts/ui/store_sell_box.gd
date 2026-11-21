class_name StoreSellBox
## The SELL tab's "SELL ITEM" drop box (Equipment::sellBox = DropBox::OnInit(isSellBox = true, sell_box_title,
## sell_box_text, bodySpace 0), DropBox::CalcHeight / OnRender; rules/store.md "SELL tab drop box"). Drawn by the
## Equipment view in store mode at Equipment position + (−275, 100).
## Art `dropbox_sell_<on|select2>.png` (272×122) cut in five horizontal slices: rows 0–32 as is, row 32 stretched
## over titleInsert + 1, rows 33–64, row 64 stretched over insertHeight + 1, rows 65–122. titleInsert = 24 when the
## title has a line break; insertHeight = body height (font 52, wrap 235) − 13.

const W := 272
const TEXT_W := 235  # textWidth = image width − 37
const COL_TITLE := Color(0.10980392, 0.08235294, 0.08235294)
const COL_ON := Color8(235, 245, 229)  # COLOR_BUTTON_ON
const COL_SELECT := Color8(255, 230, 94)  # COLOR_BUTTON_SELECT


static func _title() -> String:
	return FtlData.tr_id("sell_box_title").replace("\\n", "\n")


static func _body() -> String:
	return FtlData.tr_id("sell_box_text").replace("\\n", "\n")


static func title_insert() -> int:
	return 24 if "\n" in _title() else 0


static func insert_height() -> int:
	return FtlData.ftl_wrap(52, _body(), TEXT_W).size() * FtlData.ftl_line_height(52) - 13


static func height() -> int:
	return 122 + title_insert() + insert_height()


static func rect(at: Vector2) -> Rect2:
	return Rect2(at, Vector2(W, height()))


## `hot` = selectedImage 1 (an item dragged over the box): select2 art and yellow text. `value` = sellCostText
## (the hovered / dragged item's sell value, "" = none): font 0 at (214, 90 + insertHeight) after the baked gear.
static func draw(ci: CanvasItem, at: Vector2, hot: bool, value: String) -> void:
	var t := FtlData.texture("img/dropbox_sell_%s.png" % ("select2" if hot else "on"))
	var ti := title_insert()
	var ih := insert_height()
	if t:
		var th := t.get_size().y
		var slices := [[0.0, 32.0, 0.0, 32.0], [32.0, 1.0, 32.0, ti + 1.0], [33.0, 31.0, 33.0 + ti, 31.0],
			[64.0, 1.0, 64.0 + ti, ih + 1.0], [65.0, th - 65.0, 65.0 + ti + ih, th - 65.0]]
		for s in slices:
			ci.draw_texture_rect_region(t, Rect2(at + Vector2(0, s[2]), Vector2(W, s[3])), Rect2(0, s[0], W, s[1]))
	var cx := at.x + W / 2.0
	var tl := _title().split("\n")
	if tl.size() > 1:
		FtlData.draw_ftl_text(ci, 63, tl[0], Vector2(cx, at.y + 10), COL_TITLE, 1)
		FtlData.draw_ftl_text(ci, 63, tl[1], Vector2(cx, at.y + 38), COL_TITLE, 1)
	else:
		FtlData.draw_ftl_text(ci, 63, tl[0], Vector2(cx, at.y + 12), COL_TITLE, 1)
	var col := COL_SELECT if hot else COL_ON
	var y := at.y + 57 + ti
	for l in FtlData.ftl_wrap(52, _body(), TEXT_W):
		FtlData.draw_ftl_text(ci, 52, l, Vector2(cx, y), col, 1)
		y += FtlData.ftl_line_height(52)
	FtlData.draw_ftl_text(ci, 52, FtlData.tr_id("sell_value"), Vector2(at.x + 102, at.y + 85 + ih), col, 1)
	if value != "":
		FtlData.draw_ftl_text(ci, 0, value, Vector2(at.x + 214, at.y + 90 + ih), col)
