extends SceneTree

## Headless unit check for World.global_coord / cell_vector. Run:
##   Godot --headless --path godot/ --script res://tests/test_world.gd
## Exits non-zero (via assert) if the coordinate math drifts.
## Preloaded rather than referenced by class_name: the global class cache isn't
## built under `--script`, though `World` resolves normally in the running project.

const World := preload("res://World.gd")

func _init() -> void:
	# our sample zone: JoppaWorld parasang (11,22), zone (1,1), stratum 10
	var A := {"id": "JoppaWorld.11.22.1.1.10", "wx": 11, "wy": 22, "zx": 1, "zy": 1, "z": 10}

	# (11*3+1)=34 -> gx=34*80+11=2731 ; (22*3+1)=67 -> gy=67*25+20=1695 ; gz=10
	var ga := World.global_coord(A, 11, 20)
	assert(ga == Vector3i(2731, 1695, 10), "global_coord A wrong: %s" % ga)

	# same zone, five cells east -> (5,0,0)
	var v := World.cell_vector(A, 11, 20, A, 16, 20)
	assert(v == Vector3i(5, 0, 0), "cell_vector east wrong: %s" % v)

	# one parasang east (wx 12): global zone col +3 -> +240 cells
	var C := {"wx": 12, "wy": 22, "zx": 1, "zy": 1, "z": 10}
	var v2 := World.cell_vector(A, 0, 0, C, 0, 0)
	assert(v2 == Vector3i(240, 0, 0), "cell_vector parasang wrong: %s" % v2)

	# id-string fallback (no structured fields), one stratum deeper
	var D := {"id": "JoppaWorld.11.22.1.1.11"}
	var gd := World.global_coord(D, 0, 0)
	assert(gd == Vector3i(2720, 1675, 11), "id fallback wrong: %s" % gd)

	print("test_world OK  A=%s  east=%s  parasang=%s  fallback=%s" % [ga, v, v2, gd])
	quit()
