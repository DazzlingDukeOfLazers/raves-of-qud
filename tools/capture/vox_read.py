#!/usr/bin/env python3
"""Read a MagicaVoxel .vox with MULTIPLE, NAMED models.

vox2wall.read_vox handles the single-model files the wall pipeline writes. A hand-authored door is
two models in one file -- the frame and the swinging leaf -- and which is which is carried in the
SCENE GRAPH (nTRN/nGRP/nSHP), not in the model order: an nTRN holds the name and a translation, its
child nSHP names the model index. Reading only SIZE/XYZI gets the geometry and loses the part that
says what any of it IS.

    python3 tools/capture/vox_read.py <file.vox>
"""
import os
import struct
import sys


def _dict(data, pos):
    """MagicaVoxel DICT: int32 count, then count * (STRING key, STRING value)."""
    n = struct.unpack_from("<i", data, pos)[0]
    pos += 4
    out = {}
    for _ in range(n):
        kl = struct.unpack_from("<i", data, pos)[0]; pos += 4
        k = data[pos:pos + kl].decode("utf-8", "replace"); pos += kl
        vl = struct.unpack_from("<i", data, pos)[0]; pos += 4
        v = data[pos:pos + vl].decode("utf-8", "replace"); pos += vl
        out[k] = v
    return out, pos


def read(path):
    """{'models': [{'dims','voxels'}], 'palette': [...], 'nodes': {name: {'model','t'}}}"""
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"VOX ":
        sys.exit("not a .vox file: " + path)
    pos = 8
    models, pal = [], [None] * 256
    dims = None
    trns, shps, grps = {}, {}, {}
    while pos + 12 <= len(data):
        cid = data[pos:pos + 4]
        size, _child = struct.unpack_from("<ii", data, pos + 4)
        body = pos + 12
        if cid == b"SIZE":
            dims = struct.unpack_from("<iii", data, body)
        elif cid == b"XYZI":
            n = struct.unpack_from("<i", data, body)[0]
            vox = [struct.unpack_from("<BBBB", data, body + 4 + i * 4) for i in range(n)]
            models.append({"dims": dims, "voxels": vox})
        elif cid == b"RGBA":
            for i in range(256):
                r, g, b, a = struct.unpack_from("<BBBB", data, body + i * 4)
                pal[i] = (r, g, b, a)
        elif cid == b"nTRN":
            p = body
            nid = struct.unpack_from("<i", data, p)[0]; p += 4
            attr, p = _dict(data, p)
            child = struct.unpack_from("<i", data, p)[0]; p += 4
            p += 8                                   # reserved, layer
            nframes = struct.unpack_from("<i", data, p)[0]; p += 4
            frames = []
            for _ in range(nframes):
                fr, p = _dict(data, p)
                frames.append(fr)
            trns[nid] = {"name": attr.get("_name", ""), "child": child, "frames": frames}
        elif cid == b"nGRP":
            p = body
            nid = struct.unpack_from("<i", data, p)[0]; p += 4
            _a, p = _dict(data, p)
            n = struct.unpack_from("<i", data, p)[0]; p += 4
            grps[nid] = [struct.unpack_from("<i", data, p + 4 * i)[0] for i in range(n)]
        elif cid == b"nSHP":
            p = body
            nid = struct.unpack_from("<i", data, p)[0]; p += 4
            _a, p = _dict(data, p)
            n = struct.unpack_from("<i", data, p)[0]; p += 4
            mids = []
            for _ in range(n):
                mid = struct.unpack_from("<i", data, p)[0]; p += 4
                _ma, p = _dict(data, p)
                mids.append(mid)
            shps[nid] = mids
        if cid == b"MAIN":
            pos = body
        else:
            pos = body + size
    nodes = {}
    for _nid, t in trns.items():
        if not t["name"]:
            continue
        c = t["child"]
        mids = shps.get(c)
        if mids is None:                              # nTRN -> nGRP -> nSHP
            for gc in grps.get(c, []):
                if gc in shps:
                    mids = shps[gc]
                    break
        if not mids:
            continue
        tr = (t["frames"][0].get("_t", "0 0 0") if t["frames"] else "0 0 0").split()
        nodes[t["name"]] = {"model": mids[0], "t": tuple(int(v) for v in tr)}
    return {"models": models, "palette": pal, "nodes": nodes}


if __name__ == "__main__":
    v = read(sys.argv[1] if len(sys.argv) > 1 else
             os.path.expanduser("~/Library/Application Support/RavesOfQud/vox/door.vox"))
    print("models:")
    for i, m in enumerate(v["models"]):
        xs = [p[0] for p in m["voxels"]]; ys = [p[1] for p in m["voxels"]]
        zs = [p[2] for p in m["voxels"]]; cs = sorted({p[3] for p in m["voxels"]})
        print("  [%d] dims %s  %d voxels  x %d..%d  y %d..%d  z %d..%d  palette idx %s"
              % (i, m["dims"], len(m["voxels"]), min(xs), max(xs), min(ys), max(ys),
                 min(zs), max(zs), cs))
    print("named nodes:")
    for n, d in sorted(v["nodes"].items()):
        print("  %-8s -> model %d   translation %s" % (n, d["model"], d["t"]))
    print("palette entries used:")
    used = sorted({p[3] for m in v["models"] for p in m["voxels"]})
    for i in used:
        print("  idx %3d  rgba %s" % (i, v["palette"][i]))
