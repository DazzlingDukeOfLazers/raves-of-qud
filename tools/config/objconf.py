#!/usr/bin/env python3
"""Object-configurator store — the SQLite source of truth for render profiles.

Godot can't read SQLite (no native driver, and adding a GDExtension would drag
per-platform binaries into a repo that's deliberately dependency-light). So the
netlist lives here, in Python's stdlib sqlite3, and the renderer keeps reading the
same live `overrides.json` it always has. This tool is the bridge:

    SQLite (source of truth)  --export-->  overrides.json (renderer reads live)
              ^                                     |
              +------- import-overrides ------------+   (seed from today's file)

A *profile* is a named bundle of the three independent render axes the renderer
already understands, each stored as the raw verdict PHRASE (e.g. "should be a WALL
(solid 3D block)") so ZoneRenderer's substring matchers interpret them unchanged —
no wording contract to keep in sync, and export round-trips byte-for-meaning.

    profiles(id, name, shape, fill, position)     -- position is float/ground
    file_assignments(family -> profile)           -- the "filenames -> profiles" netlist
    event_assignments(event -> profile)           -- projectiles etc.; scaffolding until
                                                     the mod sends event data over the wire

Step 1 (this file) covers the store + import-overrides + export round-trip. The
Godot form's write-back path (a pending journal folded in by `sync`) lands later.

Usage:
    objconf.py init                 # create the db + schema
    objconf.py import-overrides     # seed the db from overrides.json
    objconf.py export               # (re)write overrides.json from the db
    objconf.py show                 # print profiles + assignment counts

Paths default to the RavesOfQud support dir (via the plat seam); override with
--support-dir / --db / --overrides (used by the round-trip test).
"""
import argparse
import json
import os
import sqlite3
import sys

# Reuse the platform seam's support_dir() rather than re-deriving the path — plat.py
# is the cross-platform dispatcher, so this works on mac and pc alike.
_TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(_TOOLS, "capture"))
import plat  # noqa: E402

SCHEMA_VERSION = 1

_SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT
);
CREATE TABLE IF NOT EXISTS profiles (
    id       INTEGER PRIMARY KEY,
    name     TEXT UNIQUE NOT NULL,
    shape    TEXT,
    fill     TEXT,
    position TEXT
);
CREATE TABLE IF NOT EXISTS file_assignments (
    family     TEXT PRIMARY KEY,
    profile_id INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS event_assignments (
    event      TEXT PRIMARY KEY,
    profile_id INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE
);
"""


# --- paths ----------------------------------------------------------------------
def _support_dir(args):
    return args.support_dir or plat.support_dir()


def _db_path(args):
    return args.db or os.path.join(_support_dir(args), "objconf.db")


def _overrides_path(args):
    return args.overrides or os.path.join(_support_dir(args), "overrides.json")


# --- db -------------------------------------------------------------------------
def _connect(path):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    con = sqlite3.connect(path)
    con.execute("PRAGMA foreign_keys = ON")
    return con


def _init_schema(con):
    con.executescript(_SCHEMA)
    con.execute(
        "INSERT OR IGNORE INTO meta(key, value) VALUES('schema_version', ?)",
        (str(SCHEMA_VERSION),),
    )
    con.commit()


def _get_or_create_profile(con, shape, fill, position):
    """Return the id of the profile with exactly this (shape, fill, position) triple,
    creating it if absent. `IS` is SQLite's null-safe equality, so NULL slots match."""
    row = con.execute(
        "SELECT id FROM profiles WHERE shape IS ? AND fill IS ? AND position IS ?",
        (shape, fill, position),
    ).fetchone()
    if row is not None:
        return row[0]
    name = _next_auto_name(con)
    cur = con.execute(
        "INSERT INTO profiles(name, shape, fill, position) VALUES(?, ?, ?, ?)",
        (name, shape, fill, position),
    )
    return cur.lastrowid


def _next_auto_name(con):
    """First free 'auto-NN' name, so import is idempotent and re-runnable."""
    existing = {r[0] for r in con.execute("SELECT name FROM profiles")}
    i = 1
    while ("auto-%02d" % i) in existing:
        i += 1
    return "auto-%02d" % i


# --- commands -------------------------------------------------------------------
def cmd_init(args):
    con = _connect(_db_path(args))
    _init_schema(con)
    con.close()
    print("initialised", _db_path(args))


def cmd_import_overrides(args):
    path = _overrides_path(args)
    if not os.path.exists(path):
        print("no overrides.json at %s — nothing to import" % path)
        return
    data = json.load(open(path, encoding="utf-8"))
    tiles = data.get("tiles", {})
    con = _connect(_db_path(args))
    _init_schema(con)
    n_assign = 0
    # Sorted for deterministic auto-NN naming regardless of dict order on disk.
    for family in sorted(tiles):
        entry = tiles[family]
        if not isinstance(entry, dict):
            continue
        shape = entry.get("shape") or None
        fill = entry.get("fill") or None
        position = entry.get("position") or None
        if shape is None and fill is None and position is None:
            continue
        pid = _get_or_create_profile(con, shape, fill, position)
        con.execute(
            "INSERT OR REPLACE INTO file_assignments(family, profile_id) VALUES(?, ?)",
            (family, pid),
        )
        n_assign += 1
    con.commit()
    n_prof = con.execute("SELECT COUNT(*) FROM profiles").fetchone()[0]
    con.close()
    print("imported %d assignments across %d profiles from %s" % (n_assign, n_prof, path))


def cmd_export(args):
    con = _connect(_db_path(args))
    _init_schema(con)
    tiles = {}
    rows = con.execute(
        "SELECT fa.family, p.shape, p.fill, p.position "
        "FROM file_assignments fa JOIN profiles p ON p.id = fa.profile_id "
        "ORDER BY fa.family"
    )
    for family, shape, fill, position in rows:
        entry = {}
        if shape:
            entry["shape"] = shape
        if fill:
            entry["fill"] = fill
        if position:
            entry["position"] = position
        if entry:
            tiles[family] = entry
    con.close()
    out = {"version": 1, "tiles": tiles}
    path = _overrides_path(args)
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    # 2-space indent matches what TileReport wrote (JSON.stringify(data, "  ")).
    with open(path, "w", encoding="utf-8") as f:
        f.write(json.dumps(out, indent=2))
        f.write("\n")
    print("exported %d tiles to %s" % (len(tiles), path))


def cmd_show(args):
    con = _connect(_db_path(args))
    _init_schema(con)
    print("db:", _db_path(args))
    for pid, name, shape, fill, position in con.execute(
        "SELECT id, name, shape, fill, position FROM profiles ORDER BY id"
    ):
        n = con.execute(
            "SELECT COUNT(*) FROM file_assignments WHERE profile_id = ?", (pid,)
        ).fetchone()[0]
        print("  [%d] %-10s files:%-3d  shape=%r fill=%r position=%r"
              % (pid, name, n, shape, fill, position))
    con.close()


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--support-dir", help="override the RavesOfQud data dir")
    p.add_argument("--db", help="override the sqlite db path")
    p.add_argument("--overrides", help="override the overrides.json path")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("init", help="create the db + schema")
    sub.add_parser("import-overrides", help="seed the db from overrides.json")
    sub.add_parser("export", help="(re)write overrides.json from the db")
    sub.add_parser("show", help="print profiles + assignment counts")
    args = p.parse_args(argv)
    {
        "init": cmd_init,
        "import-overrides": cmd_import_overrides,
        "export": cmd_export,
        "show": cmd_show,
    }[args.cmd](args)


if __name__ == "__main__":
    main()
