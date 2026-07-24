class_name WorldStore
extends RefCounted

## World store (see docs/roadmap.md — "the pivot"), now with on-disk persistence.
##
## Holds one record per zone the player has visited, and MIRRORS them to disk so an
## explored world survives a scene reload or a Qud restart. The renderer reads the
## live zone (full snapshot) plus remembered neighbours (trimmed records) from here.
## Qud is the source of truth (always synced): each visit overwrites the record, and
## the on-disk copy is re-saved when you leave the zone.
##
## Files live under <RavesOfQud>/world/<gameKey>/<zoneId>.json, namespaced by the
## mod's `gameId` so a NEW game never renders a previous game's zones. A record:
##   { id, snapshot:{zone,cells}, origin:Vector3i, wx,wy,zx,zy,stratum:int,
##     visited:bool, seen:int }

const WorldMath := preload("res://World.gd")

var _zones := {}            # zoneId -> record
var _live_id := ""
var _live_snapshot := {}    # full snapshot of the live zone (renderer draws this)
var _tick := 0              # monotonic ingest counter; LRU ordering key
var _dir := ""              # on-disk zone dir for this game ("" = persistence off)
var _loaded := false        # have we loaded this game's zones from disk yet?

## Record a snapshot as the live zone. Returns the zone id ("" if none).
func ingest(data: Dictionary) -> String:
	_live_snapshot = data
	_tick += 1
	if not _loaded:
		_resolve_dir(data)
		_load_from_disk()
		_loaded = true
	var zone: Dictionary = data.get("zone", {})
	var id := String(zone.get("id", ""))
	# re-save the zone we're LEAVING with its final state
	if _live_id != "" and _live_id != id and _zones.has(_live_id):
		_persist(_live_id)
	_live_id = id
	if id == "":
		return ""
	var is_new := not _zones.has(id)
	# a remembered zone only needs its coords + cells; drop palette/time/player/etc.
	var trimmed := {"zone": zone, "cells": data.get("cells", [])}
	_zones[id] = _make_record(trimmed, _tick)
	if is_new:
		_persist(id)   # save on first sight, so a reload brings it back even if never left
	return id

## Build a record from a (trimmed) snapshot. Shared by ingest and disk-load so the
## derived fields (origin, components) can't drift between the two paths.
func _make_record(snapshot: Dictionary, seen: int) -> Dictionary:
	var zone: Dictionary = snapshot.get("zone", {})
	var c := WorldMath.components(zone)
	return {
		"id": String(zone.get("id", "")),
		"snapshot": snapshot,
		"origin": WorldMath.global_coord(zone, 0, 0),
		"wx": c[0], "wy": c[1], "zx": c[2], "zy": c[3], "stratum": c[4],
		"visited": true,
		"seen": seen,
	}

# --- persistence -------------------------------------------------------------

## Resolve the on-disk dir for this game from the snapshot: base is the RavesOfQud
## dir (parent of tilesDir), namespaced by `gameId`. Falls back to the world token
## of the zone id when no gameId is present (a pre-`gameId` mod) — that is NOT
## multi-game-safe, so a fresh game could collide; the flag lands on next restart.
func _resolve_dir(data: Dictionary) -> void:
	var tiles := String(data.get("tilesDir", ""))
	if tiles == "":
		return   # no base path this session -> persistence disabled
	var key := String(data.get("gameId", ""))
	if key == "":
		var world := String(data.get("zone", {}).get("id", "unknown")).split(".")[0]
		key = "world-" + world
	_dir = tiles.get_base_dir().path_join("world").path_join(key.validate_filename())
	DirAccess.make_dir_recursive_absolute(_dir)

func _persist(id: String) -> void:
	if _dir == "" or not _zones.has(id):
		return
	var f := FileAccess.open(_dir.path_join(id.validate_filename() + ".json"), FileAccess.WRITE)
	if f == null:
		return
	# Qud glyphs are CP437 control bytes (e.g. 0x0B). Godot's JSON.stringify emits
	# them raw/malformed, so the file then FAILS its own JSON.parse_string on load.
	# Strip control chars from a deep copy before writing (glyphs are inspector-only
	# for a remembered zone, so nothing rendered is lost). Done here, not per step —
	# persist only fires on zone entry/leave.
	var safe: Dictionary = _zones[id]["snapshot"].duplicate(true)
	_sanitize(safe)
	f.store_string(JSON.stringify(safe))
	f.close()

## Recursively strip control characters (< 0x20) from every string in a snapshot,
## in place. Short-circuits clean strings so the common case is cheap.
static func _sanitize(v: Variant) -> void:
	if typeof(v) == TYPE_DICTIONARY:
		for k in v:
			if typeof(v[k]) == TYPE_STRING:
				v[k] = _strip_controls(v[k])
			else:
				_sanitize(v[k])
	elif typeof(v) == TYPE_ARRAY:
		for i in v.size():
			if typeof(v[i]) == TYPE_STRING:
				v[i] = _strip_controls(v[i])
			else:
				_sanitize(v[i])

static func _strip_controls(s: String) -> String:
	var dirty := false
	for i in s.length():
		if s.unicode_at(i) < 0x20:
			dirty = true
			break
	if not dirty:
		return s
	var out := ""
	for i in s.length():
		if s.unicode_at(i) >= 0x20:
			out += s[i]
	return out

func _load_from_disk() -> void:
	if _dir == "":
		return
	var d := DirAccess.open(_dir)
	if d == null:
		return
	for fn in d.get_files():
		if not fn.ends_with(".json"):
			continue
		var snap = JSON.parse_string(FileAccess.get_file_as_string(_dir.path_join(fn)))
		if typeof(snap) != TYPE_DICTIONARY:
			continue
		var id := String(snap.get("zone", {}).get("id", ""))
		if id != "":
			_zones[id] = _make_record(snap, 0)

# --- accessors ---------------------------------------------------------------

## The snapshot the renderer draws for the live zone (always the exact dict last
## ingested, so routing the render through the store cannot change what is drawn).
func live_snapshot() -> Dictionary:
	return _live_snapshot

func live_id() -> String:
	return _live_id

func live_record() -> Dictionary:
	return _zones.get(_live_id, {})

func ids() -> Array:
	return _zones.keys()

func has_zone(id: String) -> bool:
	return _zones.has(id)

func record(id: String) -> Dictionary:
	return _zones.get(id, {})

func zone_count() -> int:
	return _zones.size()
