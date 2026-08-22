extends SceneTree
## Headless check of the .vox reader — no Qud, no window, no game.
##
## Run:  Godot --headless --path godot/ --script res://VoxSelfTest.gd
##
## Worth having as its own entry point: the reader's job is to agree with
## tools/capture/vox_read.py, and comparing the two is a question about a FILE, not about a
## running game. Every other way of asking it needs Qud up and a door on screen.
const VoxFileScript = preload("res://VoxFile.gd")

func _initialize() -> void:
	var path := OS.get_environment("VOX_PATH")
	if path == "":
		path = OS.get_user_data_dir().get_base_dir().path_join("RavesOfQud/vox/door.vox")
	print("[vox] ", path, "  exists=", FileAccess.file_exists(path))
	var v: Dictionary = VoxFileScript.read(path)
	if v.is_empty():
		print("[vox] FAILED to read")
		quit(1)
		return
	var models: Array = v["models"]
	print("[vox] models=", models.size(), " nodes=", (v["nodes"] as Dictionary).keys())
	for name in (v["nodes"] as Dictionary):
		var mi: int = int((v["nodes"][name] as Dictionary)["model"])
		var m: Dictionary = models[mi]
		var lo := Vector3i(999, 999, 999)
		var hi := Vector3i(-1, -1, -1)
		var cols := {}
		for e in m["vox"]:
			var q: Vector3i = e[0]
			lo = Vector3i(mini(lo.x, q.x), mini(lo.y, q.y), mini(lo.z, q.z))
			hi = Vector3i(maxi(hi.x, q.x), maxi(hi.y, q.y), maxi(hi.z, q.z))
			cols[int(e[1])] = true
		print("[vox]   %s -> model %d  dims %s  %d voxels  x %d..%d y %d..%d z %d..%d  pal %s"
			% [name, mi, str(m["dims"]), (m["vox"] as Array).size(),
			   lo.x, hi.x, lo.y, hi.y, lo.z, hi.z, str(cols.keys())])
	var pal: PackedColorArray = v["palette"]
	print("[vox] palette 246=", pal[246].to_html(false), " 255=", pal[255].to_html(false))
	quit(0)
