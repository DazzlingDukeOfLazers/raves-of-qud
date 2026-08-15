extends SceneTree
## SPOT: wall2vox.py's writer and the vendored (ported) VoxReader agree.
## Run: VOX_PATH=<file.vox> Godot --headless --path godot/ --script res://tests/vox_roundtrip.gd
func _init():
	var path := OS.get_environment("VOX_PATH")
	var result := VoxReader.read_file(path)
	if result["error"] != OK:
		print("vox_roundtrip: FAIL error=", result["error"])
	else:
		print("vox_roundtrip: OK voxels=", result["voxels"].size(),
			" palette=", result["palette"].size())
	quit()
