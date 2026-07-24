extends SceneTree

## Headless unit check for WorldStore. Run:
##   Godot --headless --path godot/ --script res://tests/test_store.gd
## Guards the Phase-0 no-op guarantee (renderer gets back what it put in) and the
## record metadata. Preloaded (global class cache isn't built under --script).

const Store := preload("res://WorldStore.gd")

func _init() -> void:
	var s := Store.new()
	var data := {
		"zone": {"id": "JoppaWorld.11.22.1.1.10", "wx": 11, "wy": 22, "zx": 1, "zy": 1,
				 "z": 10, "width": 80, "height": 25},
		"cells": [],
	}
	var id := s.ingest(data)
	assert(id == "JoppaWorld.11.22.1.1.10", "id wrong: %s" % id)
	# NO-OP GUARANTEE: the renderer gets back the exact snapshot it put in.
	assert(s.live_snapshot() == data, "live_snapshot is not the ingested data")
	assert(s.zone_count() == 1, "count wrong: %d" % s.zone_count())

	var rec := s.live_record()
	assert(rec["origin"] == Vector3i(2720, 1675, 10), "origin wrong: %s" % rec["origin"])
	assert(rec["stratum"] == 10 and rec["visited"] == true, "record meta wrong")

	# re-ingesting the same zone updates in place; count stays 1
	s.ingest(data)
	assert(s.zone_count() == 1, "re-ingest grew the count")

	# a snapshot with no zone id still renders (identity) but isn't keyed
	var noid := {"zone": {}, "cells": []}
	s.ingest(noid)
	assert(s.live_snapshot() == noid, "no-id live_snapshot not identity")
	assert(s.zone_count() == 1, "no-id snapshot grew the count")

	print("test_store OK  id=%s  count=%d  origin=%s" % [id, s.zone_count(), rec["origin"]])
	quit()
