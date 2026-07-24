extends SceneTree

## Headless check for WorldStore on-disk persistence. Run:
##   Godot --headless --path godot/ --script res://tests/test_persist.gd
## Writes to a unique /tmp dir, so re-runs don't collide.

const Store := preload("res://WorldStore.gd")

func _init() -> void:
	var base := "/tmp/rq_persist_%d" % Time.get_ticks_usec()
	var zoneA := {"id": "JoppaWorld.11.22.1.1.10", "wx": 11, "wy": 22, "zx": 1, "zy": 1,
			"z": 10, "width": 80, "height": 25}
	var zoneB := {"id": "JoppaWorld.11.22.0.1.10", "wx": 11, "wy": 22, "zx": 0, "zy": 1,
			"z": 10, "width": 80, "height": 25}

	# session 1: visit zone A -> persisted on first sight
	var s1 := Store.new()
	s1.ingest({"tilesDir": base + "/tiles", "gameId": "GAME123", "zone": zoneA, "cells": []})

	# session 2 (fresh store, same game): entering zone B loads A from disk
	var s2 := Store.new()
	s2.ingest({"tilesDir": base + "/tiles", "gameId": "GAME123", "zone": zoneB, "cells": []})
	assert(s2.has_zone("JoppaWorld.11.22.1.1.10"), "zone A was not loaded from disk")
	assert(s2.zone_count() == 2, "expected 2 zones (A loaded + B live), got %d" % s2.zone_count())
	assert(s2.record("JoppaWorld.11.22.1.1.10")["origin"] == Vector3i(2720, 1675, 10),
			"loaded record origin wrong")

	# a DIFFERENT game must not see GAME123's zones
	var s3 := Store.new()
	s3.ingest({"tilesDir": base + "/tiles", "gameId": "OTHERGAME", "zone": zoneB, "cells": []})
	assert(not s3.has_zone("JoppaWorld.11.22.1.1.10"), "cross-game leak: saw another game's zone")
	assert(s3.zone_count() == 1, "cross-game store should hold only its own zone")

	# control chars in a glyph (Qud CP437 bytes) must not corrupt the JSON on disk
	var glyph_cells := [{"x": 0, "y": 0, "objs": [{"tile": "x.bmp", "glyph": char(0x0B)}]}]
	var zoneC := {"id": "JoppaWorld.9.9.0.0.10", "wx": 9, "wy": 9, "zx": 0, "zy": 0, "z": 10}
	var s4 := Store.new()
	s4.ingest({"tilesDir": base + "/tiles", "gameId": "GLYPHGAME", "zone": zoneC, "cells": glyph_cells})
	var s5 := Store.new()
	s5.ingest({"tilesDir": base + "/tiles", "gameId": "GLYPHGAME",
			"zone": {"id": "JoppaWorld.9.9.1.0.10", "wx": 9, "wy": 9, "zx": 1, "zy": 0, "z": 10},
			"cells": []})
	assert(s5.has_zone("JoppaWorld.9.9.0.0.10"), "glyph zone failed to persist/reload (bad JSON)")

	print("test_persist OK  s2=%d s3=%d glyph-reload=ok  dir=%s" % [s2.zone_count(), s3.zone_count(), base])
	quit()
