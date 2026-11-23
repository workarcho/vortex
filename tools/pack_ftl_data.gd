extends SceneTree
## Packs an ftl-data folder into a Godot resource pack whose files live under res://ftl-data/ (raw bytes, nothing
## imported), for the local web wallpaper build (tools/build_web_wallpaper.py; FtlData mounts it on the web).
## The pack holds the player's own FTL data: it is a local build output only, never committed or published.
##
## godot --headless --path <any empty project> -s tools/pack_ftl_data.gd -- <ftl-data dir> <out.pck> [skip ...]
## `skip`: paths relative to the data folder (files or folders, e.g. audio fonts/ja) left out of the pack.


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		printerr("usage: -s pack_ftl_data.gd -- <ftl-data dir> <out.pck> [skip ...]")
		quit(2)
		return
	var src: String = args[0].replace("\\", "/").trim_suffix("/")
	var out: String = args[1]
	var skip: Array = []
	for s in args.slice(2):
		skip.append(String(s).replace("\\", "/").trim_suffix("/"))
	var files: Array = []
	_collect(src, "", skip, files)
	if files.is_empty():
		printerr("no files under ", src)
		quit(1)
		return
	var pk := PCKPacker.new()
	if pk.pck_start(out) != OK:
		printerr("cannot write ", out)
		quit(1)
		return
	for rel in files:
		if pk.add_file("res://ftl-data/" + rel, src.path_join(rel)) != OK:
			printerr("cannot add ", rel)
			quit(1)
			return
	if pk.flush(false) != OK:
		printerr("flush failed")
		quit(1)
		return
	print("packed %d files into %s" % [files.size(), out])
	quit(0)


func _collect(root: String, rel: String, skip: Array, out: Array) -> void:
	var dir := root.path_join(rel) if rel != "" else root
	for f in DirAccess.get_files_at(dir):
		var r := rel.path_join(f) if rel != "" else f
		if not skip.has(r):
			out.append(r)
	for d in DirAccess.get_directories_at(dir):
		var r := rel.path_join(d) if rel != "" else d
		if not skip.has(r):
			_collect(root, r, skip, out)
