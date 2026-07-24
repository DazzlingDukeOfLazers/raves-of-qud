class_name World
extends RefCounted

## World-space coordinate math for Raves of Qud.
##
## A Qud world is a grid of parasangs; each parasang is PARASANG×PARASANG zones;
## each zone is ZONE_W×ZONE_H cells; plus Z strata. The snapshot's `zone` block
## carries the components as structured ints (wx/wy = parasang, zx/zy = zone within
## the parasang, z = stratum) — confirmed against XRL.World.Zone by reflection
## (see docs/roadmap.md). This is the single GDScript source for that math; the C#
## mod is the server-side counterpart (it emits the components; it does not parse).

const ZONE_W := 80
const ZONE_H := 25
const PARASANG := 3

## The five zone components [wx, wy, zx, zy, z] from a snapshot `zone` block.
## Prefers the structured fields; falls back to parsing the `id` string
## (`world.wx.wy.zx.zy.z`) so this still works against a snapshot from a mod build
## that predates the structured fields. Uses the trailing five tokens so a world
## name is tolerated even if it ever contained a dot.
static func components(zone: Dictionary) -> Array:
	if zone.has("wx"):
		return [int(zone.get("wx", 0)), int(zone.get("wy", 0)),
				int(zone.get("zx", 0)), int(zone.get("zy", 0)), int(zone.get("z", 0))]
	var parts := String(zone.get("id", "")).split(".", false)
	if parts.size() >= 6:
		var n := parts.size()
		return [int(parts[n - 5]), int(parts[n - 4]), int(parts[n - 3]),
				int(parts[n - 2]), int(parts[n - 1])]
	return [0, 0, 0, 0, 0]

## Global integer cell coordinate (gx, gy, gz) for cell (x, y) in the given zone.
## gx/gy are absolute cell indices across the whole world; gz is the raw stratum.
static func global_coord(zone: Dictionary, x: int, y: int) -> Vector3i:
	var c := components(zone)
	return Vector3i(
		(c[0] * PARASANG + c[2]) * ZONE_W + x,
		(c[1] * PARASANG + c[3]) * ZONE_H + y,
		c[4])

## Vector from cell A to cell B, each given by its zone block and in-zone (x, y).
## gz is a raw stratum difference; the surface baseline/sign doesn't affect it.
static func cell_vector(za: Dictionary, ax: int, ay: int,
		zb: Dictionary, bx: int, by: int) -> Vector3i:
	return global_coord(zb, bx, by) - global_coord(za, ax, ay)
