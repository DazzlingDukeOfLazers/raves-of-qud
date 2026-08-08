"""Carve Qud's UI fonts out of the player's OWN install, into the Raves support dir.

WHY THIS EXISTS
    Raves already knows how to USE Qud's proportional face -- MainMenu._elliot() and
    BlueprintBrowserScreen both load <support>/title/chrome/ElliotSans-<Weight>.ttf -- but
    nothing produced those files; they were carved by hand once. This makes it repeatable.

WHY CARVING RATHER THAN EXPORTING AN ATLAS
    Unity's Font asset keeps the ORIGINAL font file in m_FontData, so Caves of Qud ships the
    real vector TTFs verbatim inside sharedassets0.assets. That beats dumping a TextMeshPro
    SDF atlas by a mile: Godot loads a TTF natively and it stays crisp at every size, with
    real kerning, instead of us reconstructing glyph metrics and fighting SDF thresholds.

LICENSING -- READ BEFORE "IMPROVING" THIS
    These are the game's fonts, and Elliot Sans is a commercial face. They are extracted from
    the player's own installation into their own support dir at runtime, exactly like the tile
    art (TileExporter). They are NEVER committed to this repo and never redistributed. Raves
    degrades to its bundled fallback when they are absent -- see MainMenu._elliot(), which
    returns null and leaves the theme font in place.

USAGE
    python3 tools/capture/fonts.py            # carve the fonts Raves consumes
    python3 tools/capture/fonts.py --all      # every font in the install (survey/debug)
    python3 tools/capture/fonts.py --list     # report only, write nothing
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import plat  # noqa: E402

# sfnt wrappers. 0x00010000 is TrueType outlines, OTTO is CFF, ttcf is a collection.
MAGICS = (b"\x00\x01\x00\x00", b"OTTO", b"true", b"ttcf")
# A real UI font in this game is tens of KB. The ceiling is what keeps a chance OTTO inside
# bulk texture data from "validating" as a 120 MB font -- which it did, before this bound.
MIN_FONT = 4_000
MAX_FONT = 8_000_000

# What Raves actually consumes, mapped from the font's own name table to the filename the
# Godot side asks for. Keys are (family, subfamily) lowercased.
WANTED = {
    ("elliot sans", "regular"): "ElliotSans-Regular.ttf",
    ("elliot sans", "medium"): "ElliotSans-Medium.ttf",
    ("elliot sans", "bold"): "ElliotSans-Bold.ttf",
    # Qud's modding-tool dialogs (DialogManager) are Unity's stock UI face, not Qud's own.
    ("liberation sans", "regular"): "LiberationSans-Regular.ttf",
}


def qud_install_dir():
    """The <install>/CoQ_Data (or .app equivalent) that holds the Unity asset files.

    NOT plat.qud_data_dir() — that is Qud's persistentDataPath (saves, mods, options), a
    different directory entirely; pointing this at it would find no .assets files and report
    "no embedded fonts" as though the game shipped none.

    Both backends define qud_install_dir() now (the PC branch added it to plat_win only, so
    this used to carry a getattr() fallback and a duplicate copy of each platform's path).
    """
    return plat.qud_install_dir()


def parse_sfnt(buf, off, limit):
    """Byte length of the sfnt starting at off, or None if this isn't really one.

    Structural, not a magic-byte guess: every table record has to be self-consistent, tags
    have to be printable and unique, and head+name have to be present.
    """
    if off + 12 > limit:
        return None
    num_tables = struct.unpack_from(">H", buf, off + 4)[0]
    if not (4 <= num_tables <= 64):
        return None
    dir_end = off + 12 + num_tables * 16
    if dir_end > limit:
        return None
    end, seen = dir_end, set()
    for i in range(num_tables):
        rec = off + 12 + i * 16
        tag = buf[rec:rec + 4]
        if not all(32 <= c <= 126 for c in tag) or tag in seen:
            return None
        seen.add(tag)
        t_off, t_len = struct.unpack_from(">II", buf, rec + 8)
        if t_off < 12 or t_len > MAX_FONT or off + t_off + t_len > limit:
            return None
        end = max(end, off + t_off + t_len)
    if not ({b"head", b"name"} <= seen):
        return None
    size = end - off
    return size if MIN_FONT <= size <= MAX_FONT else None


def font_names(data):
    """{nameID: text} from the 'name' table — 1 family, 2 subfamily, 4 full name."""
    num_tables = struct.unpack_from(">H", data, 4)[0]
    off = None
    for i in range(num_tables):
        rec = 12 + i * 16
        if data[rec:rec + 4] == b"name":
            off = struct.unpack_from(">I", data, rec + 8)[0]
            break
    if off is None:
        return {}
    count, str_off = struct.unpack_from(">HH", data, off + 2)
    out = {}
    for i in range(count):
        pid, eid, lid, nid, ln, s_off = struct.unpack_from(">HHHHHH", data, off + 6 + i * 12)
        raw = data[off + str_off + s_off: off + str_off + s_off + ln]
        try:
            txt = raw.decode("utf-16-be") if pid == 3 else raw.decode("latin-1")
        except Exception:
            continue
        if nid in (1, 2, 4) and txt.strip():
            out.setdefault(nid, txt.strip())
    return out


def scan(data_dir):
    """Every distinct font embedded in the install, as (family, subfamily, bytes)."""
    found, seen = [], set()
    for name in sorted(os.listdir(data_dir)):
        path = os.path.join(data_dir, name)
        if not os.path.isfile(path) or os.path.getsize(path) < MIN_FONT:
            continue
        if os.path.splitext(name)[1].lower() not in ("", ".assets", ".resource", ".ress"):
            continue
        with open(path, "rb") as f:
            buf = f.read()
        n = len(buf)
        for magic in MAGICS:
            pos = 0
            while True:
                pos = buf.find(magic, pos)
                if pos < 0:
                    break
                size = parse_sfnt(buf, pos, n)
                if not size:
                    pos += 1
                    continue
                blob = buf[pos:pos + size]
                names = font_names(blob)
                fam = names.get(1, "?")
                sub = names.get(2, "Regular")
                key = (fam.lower(), sub.lower(), size)
                if key not in seen:
                    seen.add(key)
                    found.append((fam, sub, blob, name))
                pos += size
    return found


def main(argv):
    want_all = "--all" in argv
    list_only = "--list" in argv
    data_dir = qud_install_dir()
    if not os.path.isdir(data_dir):
        print("Qud data dir not found: %s" % data_dir)
        return 1
    dest_dir = os.path.join(plat.support_dir(), "title", "chrome")

    fonts = scan(data_dir)
    if not fonts:
        print("no embedded fonts found in %s" % data_dir)
        return 1

    print("%d font(s) embedded in %s" % (len(fonts), data_dir))
    written = 0
    for fam, sub, blob, src in fonts:
        target = WANTED.get((fam.lower(), sub.lower()))
        if target is None and want_all:
            target = ("%s-%s.ttf" % (fam, sub)).replace(" ", "")
        mark = "  ->" if target else "    "
        print("%s %-30s %-10s %8d bytes  (%s)%s"
              % (mark, fam, sub, len(blob), src, "  " + target if target else ""))
        if target and not list_only:
            os.makedirs(dest_dir, exist_ok=True)
            with open(os.path.join(dest_dir, target), "wb") as f:
                f.write(blob)
            written += 1
    if list_only:
        print("\n--list: nothing written")
    else:
        print("\nwrote %d font(s) to %s" % (written, dest_dir))
        print("(the player's own install -> the player's own support dir; never committed)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
