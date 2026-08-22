extends RefCounted
## MagicaVoxel .vox reader — multi-model, and it keeps the NAMES.
##
## Deliberately NOT a class_name: adding one makes the headless parse fail until an editor rescan
## (see CLAUDE.md), and this is loaded with preload() by the one caller that wants it.
##
## The wall pipeline never needed this. It BAKES a .vox back into tile art offline
## (tools/capture/vox2wall.py), so the game only ever reads .bmp — but a door's shape cannot survive
## that round trip: a 16x24 sprite has no depth, and the whole point of a hand-authored door is the
## frame's thickness and the leaf sitting inside it. So this reads the file at runtime instead.
##
## The names matter as much as the geometry. A door file is two models, and which is the frame and
## which is the swinging leaf is carried in the SCENE GRAPH (nTRN holds the name, its child nSHP
## names the model index), not in model order. tools/capture/vox_read.py is the same parse in
## Python; run it on a file to see what this will see.

## One model: {"dims": Vector3i, "vox": PackedByteArray-ish Array of [Vector3i, int]}.
## Returns {"models": Array, "palette": PackedColorArray, "nodes": {name: {"model": int}}}
static func read(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var d := f.get_buffer(f.get_length())
	f.close()
	if d.size() < 8 or d.slice(0, 4).get_string_from_ascii() != "VOX ":
		return {}
	var models: Array = []
	var palette := PackedColorArray()
	palette.resize(256)
	var trns := {}
	var shps := {}
	var grps := {}
	var dims := Vector3i.ZERO
	var pos := 8
	while pos + 12 <= d.size():
		var cid := d.slice(pos, pos + 4).get_string_from_ascii()
		var size := d.decode_s32(pos + 4)
		var body := pos + 12
		match cid:
			"SIZE":
				dims = Vector3i(d.decode_s32(body), d.decode_s32(body + 4), d.decode_s32(body + 8))
			"XYZI":
				var n := d.decode_s32(body)
				var vox: Array = []
				for i in n:
					var o := body + 4 + i * 4
					vox.append([Vector3i(d[o], d[o + 1], d[o + 2]), int(d[o + 3])])
				models.append({"dims": dims, "vox": vox})
			"RGBA":
				for i in 256:
					var o := body + i * 4
					palette[i] = Color8(d[o], d[o + 1], d[o + 2], d[o + 3])
			"nTRN":
				var p := body
				var nid := d.decode_s32(p); p += 4
				var attr := _read_dict(d, p)
				p = int(attr["end"])
				var child := d.decode_s32(p); p += 4
				p += 8                                  # reserved id, layer id
				var nfr := d.decode_s32(p); p += 4
				for i in nfr:
					var fr := _read_dict(d, p)
					p = int(fr["end"])
				trns[nid] = {"name": String((attr["d"] as Dictionary).get("_name", "")),
					"child": child}
			"nGRP":
				var p2 := body
				var gid := d.decode_s32(p2); p2 += 4
				var ga := _read_dict(d, p2)
				p2 = int(ga["end"])
				var gn := d.decode_s32(p2); p2 += 4
				var kids: Array = []
				for i in gn:
					kids.append(d.decode_s32(p2 + 4 * i))
				grps[gid] = kids
			"nSHP":
				var p3 := body
				var sid := d.decode_s32(p3); p3 += 4
				var sa := _read_dict(d, p3)
				p3 = int(sa["end"])
				var sn := d.decode_s32(p3); p3 += 4
				var mids: Array = []
				for i in sn:
					mids.append(d.decode_s32(p3)); p3 += 4
					var ma := _read_dict(d, p3)
					p3 = int(ma["end"])
				shps[sid] = mids
		pos = body if cid == "MAIN" else body + size
	var nodes := {}
	for nid in trns:
		var t: Dictionary = trns[nid]
		if String(t["name"]) == "":
			continue
		var c: int = int(t["child"])
		var mids2 = shps.get(c, null)
		if mids2 == null:                               # nTRN -> nGRP -> nSHP
			for gc in grps.get(c, []):
				if shps.has(gc):
					mids2 = shps[gc]
					break
		if mids2 == null or (mids2 as Array).is_empty():
			continue
		nodes[String(t["name"])] = {"model": int((mids2 as Array)[0])}
	return {"models": models, "palette": palette, "nodes": nodes}

## MagicaVoxel DICT: int32 count, then count * (STRING key, STRING value). Returns {"d":.., "end":..}
static func _read_dict(d: PackedByteArray, pos: int) -> Dictionary:
	var n := d.decode_s32(pos)
	var p := pos + 4
	var out := {}
	for i in n:
		var kl := d.decode_s32(p); p += 4
		var k := d.slice(p, p + kl).get_string_from_utf8(); p += kl
		var vl := d.decode_s32(p); p += 4
		var v := d.slice(p, p + vl).get_string_from_utf8(); p += vl
		out[k] = v
	return {"d": out, "end": p}
