class_name WorldStore
extends RefCounted

## Phase-0 world store (see docs/roadmap.md — "the pivot").
##
## Today it holds ONE zone: every snapshot is ingested into a per-zone record and
## the renderer reads the live zone back out. That is deliberately a no-op right now
## — the point is to establish the store as the thing the renderer reads FROM, so
## Phase 1 can add remembered neighbours, fog, and eviction without touching the
## render path again. Qud is the source of truth (always synced), so SIM simply
## overwrites; no provenance/merge logic lives here yet.
##
## A record is a plain Dictionary (keep it serialisable for the eventual on-disk
## chunk store):
##   { id, snapshot, origin:Vector3i, wx,wy,zx,zy,stratum:int, visited:bool, seen:int }

const WorldMath := preload("res://World.gd")

var _zones := {}            # zoneId -> record
var _live_id := ""
var _live_snapshot := {}    # direct ref to the most recent snapshot (never empty after first)
var _tick := 0              # monotonic ingest counter; ordering key for future LRU eviction

## Record a snapshot as the live zone. Returns the zone id ("" if the snapshot
## carried none — still rendered, just not keyed into the store).
func ingest(data: Dictionary) -> String:
	_live_snapshot = data
	_tick += 1
	var zone: Dictionary = data.get("zone", {})
	var id := String(zone.get("id", ""))
	_live_id = id
	if id == "":
		return ""
	var c := WorldMath.components(zone)
	_zones[id] = {
		"id": id,
		"snapshot": data,
		"origin": WorldMath.global_coord(zone, 0, 0),
		"wx": c[0], "wy": c[1], "zx": c[2], "zy": c[3], "stratum": c[4],
		"visited": true,
		"seen": _tick,
	}
	return id

## The snapshot the renderer should draw. Always the exact dict last ingested, so
## routing the render through the store cannot change what is drawn.
func live_snapshot() -> Dictionary:
	return _live_snapshot

func live_id() -> String:
	return _live_id

func live_record() -> Dictionary:
	return _zones.get(_live_id, {})

func has_zone(id: String) -> bool:
	return _zones.has(id)

func record(id: String) -> Dictionary:
	return _zones.get(id, {})

func zone_count() -> int:
	return _zones.size()
