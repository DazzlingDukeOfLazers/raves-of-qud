using XRL;
using XRL.World;
using XRL.World.Parts;

namespace RavesOfQud
{
    /// <summary>
    /// Serializes the active zone into the snapshot JSON that Godot renders.
    /// Reads game state — MUST be called on the main thread (it is: via Bridge.Tick).
    ///
    /// VERIFIED against the installed 1.0 build by reflecting Assembly-CSharp.dll
    /// (MetadataLoadContext — exact signatures, not string heuristics):
    ///   The.ActiveZone -> XRL.World.Zone
    ///   Zone: fields Width, Height (int); prop ZoneID (string); GetCell(int,int) -> Cell
    ///   XRL.World.Cell: X, Y, ParentZone, Objects
    ///   GameObject.GetPart&lt;T&gt;() ; GameObject.CurrentCell (prop)
    ///   XRL.World.Parts.Render fields (CAPITALIZED): RenderString, ColorString,
    ///     DetailColor, TileColor, Tile (all string), RenderLayer (int);
    ///     Visible is a bool property (use it for FOV filtering in v2).
    ///   Water/bridge (all first-class Qud concepts, no heuristics needed):
    ///     Cell.HasBridge() / HasWadingDepthLiquid() / HasSwimmingDepthLiquid()
    ///     GameObject.HasIntProperty("Bridge")  — set by Walkway/Bridge/BrineBridge/
    ///       WoodFloor/MarbleFloor blueprints in Base/ObjectBlueprints/ZoneTerrain.xml
    ///     GameObject.IsCreature / IsFlying (properties)
    ///
    /// We emit RAW Qud color strings (e.g. "&amp;Y") and let Godot interpret them.
    /// FOV / fog-of-war filtering is intentionally deferred (v2): for now we ship
    /// every object that has a Render + non-empty glyph.
    /// </summary>
    public static class ZoneSnapshot
    {
        /// <summary>
        /// Plain display name, defended against a throwing getter. DisplayName
        /// runs the full markup/adjective pipeline on some objects, and a
        /// snapshot must never be the thing that breaks someone's game.
        /// </summary>
        private static string DisplayNameOf(GameObject go)
        {
            try { return go.DisplayNameOnly ?? ""; }
            catch { return ""; }
        }

        // Qud's 16-colour palette, by ColorString character.
        private const string PaletteChars = "rRgGbBcCmMwWoOyYkK";

        /// <summary>
        /// Qud's REAL palette, straight from ConsoleLib. Base/Colors.xml names the
        /// colours but carries no RGB — the values live in code — so the client
        /// was otherwise stuck hand-estimating them, and "&amp;K" being dark grey
        /// rather than black is exactly the kind of thing a guess gets wrong.
        ///
        /// colorFromChar is a static dictionary lookup returning a struct: no
        /// graphics calls, so it is safe on the turn thread.
        /// </summary>
        private static void WritePalette(JsonWriter j)
        {
            j.Name("palette").BeginObject();
            foreach (char ch in PaletteChars)
            {
                try
                {
                    UnityEngine.Color c = ConsoleLib.Console.ColorUtility.colorFromChar(ch);
                    j.Member(ch.ToString(), Hex(c));
                }
                catch { /* a char the build doesn't map — skip it, keep the rest */ }
            }
            j.EndObject();

            // The colour Qud paints the world behind everything. Ours was an
            // estimate, and side-by-side the 3D view read black where Qud reads
            // dark teal — which flattens the whole scene. Emit the raw string too:
            // if it isn't resolvable, we want to see what it actually was.
            try
            {
                string raw = ConsoleLib.Console.ColorUtility.CAMERA_BACKGROUND ?? "";
                j.Member("bgRaw", raw);
                if (raw.Length > 0)
                {
                    UnityEngine.Color bg = raw.Length == 1
                        ? ConsoleLib.Console.ColorUtility.colorFromChar(raw[0])
                        : ConsoleLib.Console.ColorUtility.ColorFromString(raw);
                    j.Member("bg", Hex(bg));
                }
            }
            catch { /* keep the client's fallback */ }
        }

        private static string Hex(UnityEngine.Color c)
        {
            return "#" + Channel(c.r) + Channel(c.g) + Channel(c.b);
        }

        private static string Channel(float v)
        {
            int n = (int)System.Math.Round(v * 255f);
            if (n < 0) n = 0;
            if (n > 255) n = 255;
            return n.ToString("x2");
        }

        // Reused across the whole snapshot; the turn thread is the only writer.
        private static readonly ConsoleLib.Console.ConsoleChar _scratch =
            new ConsoleLib.Console.ConsoleChar();

        /// <summary>
        /// The tile Qud would actually DRAW for this object.
        ///
        /// Render.Tile is only the static blueprint value. Objects whose art is
        /// chosen at render time — grass and other ground cover — leave it empty
        /// and paint themselves through RenderTile instead, so reading the field
        /// gave "no tile", exported nothing, and the client drew a flat dot where
        /// the game shows a sprite.
        ///
        /// Falls back to the field, so anything that doesn't paint is unaffected.
        /// </summary>
        private static string ResolvedTile(GameObject go, Render r, out bool painted)
        {
            painted = false;

            // getTile() is the ACCESSOR: it resolves what the object actually
            // draws — PickRandomTile, RandomTileOnMove, harvestable states. The
            // Tile FIELD is only the blueprint's static value, and is empty for
            // anything that picks its art at runtime.
            try
            {
                string got = r.getTile();
                if (!string.IsNullOrEmpty(got)) return got;
            }
            catch { }

            // RenderTile is the OVERRIDE hook for parts that paint themselves.
            // It fires for almost nothing — kept because when it does fire it
            // also gives us resolved colours.
            try
            {
                _scratch.Clear();
                go.RenderTile(_scratch);
                string tile = _scratch.Tile;
                if (!string.IsNullOrEmpty(tile))
                {
                    painted = true;
                    return tile;
                }
            }
            catch { }

            return r.Tile ?? "";
        }

        /// <summary>
        /// The glyph the object actually draws. Same story as the tile: the
        /// RenderString FIELD can be empty while the accessor resolves one.
        /// An object with both fields empty was dropped entirely, which made its
        /// whole cell report as EMPTY.
        /// </summary>
        private static string ResolvedGlyph(Render r)
        {
            try
            {
                string got = r.getRenderString();
                if (!string.IsNullOrEmpty(got)) return got;
            }
            catch { }
            return r.RenderString ?? "";
        }

        /// <summary>
        /// Colours straight off the painted ConsoleChar: already RESOLVED to RGB,
        /// so the client needs no palette lookup and no &amp;X^Y parsing for these.
        /// Also carries Qud's own sprite flipping.
        ///
        /// Only emitted when RenderTile actually painted a tile. If it didn't, the
        /// ConsoleChar still holds whatever Clear() left, and shipping that would
        /// paint half the zone in default colours — the client keeps using the
        /// ColorString path in that case.
        /// </summary>
        private static void WritePaintedColors(JsonWriter j)
        {
            try
            {
                j.Member("fgHex", Hex(_scratch.TileForeground));
                j.Member("bgHex", Hex(_scratch.TileBackground));
                j.Member("detailHex", Hex(_scratch.Detail));
                if (_scratch.HFlip) j.Member("hflip", true);
                if (_scratch.VFlip) j.Member("vflip", true);
            }
            catch { /* colours are an optimisation; never fail a snapshot over them */ }
        }

        private static int CountSafe(Cell c)
        {
            try { return c.GetObjectCount(); } catch { return -1; }
        }

        private static int RenderedSafe(Cell c)
        {
            try { return c.RenderedObjectsCount; } catch { return -1; }
        }

        /// <summary>
        /// Qud's PAINTED GROUND LAYER.
        ///
        /// 1103 of this zone's 2000 cells hold no GameObject at all, yet Qud's
        /// compositor still draws dirt and grass on them (Terrain/sw_grass1.bmp,
        /// tile-dirt1.png...). That layer is not in the object model, which is why
        /// it never appeared in any object query and why every fix aimed at the
        /// object path was inert.
        ///
        /// Cell.Render() composites it. We emit it as a RenderLayer 0 floor so the
        /// client draws it like any other ground.
        /// </summary>
        /// <summary>
        /// A tile path reduced to its FAMILY, for comparing "is this the same art?".
        ///
        /// This is an INDEPENDENT copy of the family reduction, by design. The two
        /// GDScript copies (ZoneRenderer.tile_family, used by the form too) are
        /// unified into one; this one is server-side and used ONLY for ground-dedup
        /// within a single snapshot. It never crosses to the client's override
        /// keying, so drift here cannot mis-apply a user rule — at worst it emits or
        /// drops one duplicate ground tile. Keep the reduction rules matching the
        /// GDScript one anyway, for consistency.</summary>
        /// <remarks>Original doc:
        /// A tile path reduced to its FAMILY, for comparing "is this the same art?".
        ///
        /// Comparing exact paths is not enough: a water wheel cell handed back
        /// `sw_waterwheel_3` from the compositor while the object drew
        /// `sw_waterwheel_1`, so the duplicate slipped through and a second wheel
        /// was laid flat under the first. Variant numbers and autotile bitmasks are
        /// both just "which picture of this thing", so both are stripped.
        /// </remarks>
        private static string TileFamily(string tile)
        {
            if (string.IsNullOrEmpty(tile)) return "";
            string t = tile.Replace('\\', '/');
            int slash = t.LastIndexOf('/');
            if (slash >= 0) t = t.Substring(slash + 1);
            int dot = t.LastIndexOf('.');
            if (dot >= 0) t = t.Substring(0, dot);
            // trailing autotile bitmask: wall_rock-10100010
            int dash = t.LastIndexOf('-');
            if (dash >= 0 && dash < t.Length - 1)
            {
                bool bits = true;
                for (int i = dash + 1; i < t.Length; i++)
                    if (t[i] != '0' && t[i] != '1') { bits = false; break; }
                if (bits) t = t.Substring(0, dash);
            }
            // trailing variant number: sw_waterwheel_1, sw_ground_dots3
            int end = t.Length;
            while (end > 0 && t[end - 1] >= '0' && t[end - 1] <= '9') end--;
            if (end < t.Length && end > 0 && t[end - 1] == '_') end--;
            if (end > 0) t = t.Substring(0, end);
            return t.ToLowerInvariant();
        }

        private sealed class Ground
        {
            public string Tile, Color, Detail, Glyph;
            public bool HFlip, VFlip;
        }

        private static Ground ResolveGround(Cell c)
        {
            try
            {
                var ev = c.Render();
                if (ev == null) return null;
                string tile = ev.Tile;
                if (string.IsNullOrEmpty(tile)) return null;
                return new Ground
                {
                    Tile = tile,
                    Color = ev.ColorString ?? "",
                    Detail = ev.DetailColor ?? "",
                    Glyph = ev.RenderString ?? "",
                    HFlip = ev.HFlip,
                    VFlip = ev.VFlip,
                };
            }
            catch { return null; }
        }

        private static void WriteGroundTile(JsonWriter j, Ground g)
        {
            string tile = g.Tile, color = g.Color, detail = g.Detail, glyph = g.Glyph;
            bool hflip = g.HFlip, vflip = g.VFlip;
            TileExporter.Ensure(tile);
            j.BeginObject()
                .Member("name", "[painted ground]")
                .Member("display", "ground")
                .Member("glyph", glyph)
                .Member("tile", tile)
                .Member("color", color)
                .Member("tilecolor", "")
                .Member("detail", detail)
                .Member("layer", 0)
                .Member("wall", false)
                .Member("solid", false)
                .Member("occluding", false)
                .Member("bridge", false)
                .Member("sinks", false)
                .Member("ground", true);
            if (hflip) j.Member("hflip", true);
            if (vflip) j.Member("vflip", true);
            j.EndObject();
        }

        public static string BuildJson(GameObject player)
        {
            var j = new JsonWriter();
            j.BeginObject();
            j.Member("type", Protocol.TypeSnapshot);
            j.Member("tilesDir", TileExporter.Dir); // where Godot loads exported PNGs
            j.Member("mod", Protocol.Build);        // which mod build is actually live
            WritePalette(j);

            // Force-export reference tiles the client wants but that don't occur
            // naturally in a zone — e.g. the isolated wall (bordered on all sides),
            // used for the real framed wall-top. Cached after the first export.
            TileExporter.Ensure("Assets/Content/Textures/Tiles/wall_rock-00000000.bmp");

            Zone z = The.ActiveZone;
            if (z == null) { j.EndObject(); return j.ToString(); }

            int w = z.Width;
            int h = z.Height;

            j.Name("zone").BeginObject()
                .Member("id", z.ZoneID ?? "")
                .Member("width", w)
                .Member("height", h)
            .EndObject();

            Cell pc = player?.CurrentCell;
            j.Name("player").BeginObject()
                .Member("x", pc != null ? pc.X : -1)
                .Member("y", pc != null ? pc.Y : -1)
            .EndObject();

            j.Name("cells").BeginArray();
            for (int y = 0; y < h; y++)
            {
                for (int x = 0; x < w; x++)
                {
                    Cell c = z.GetCell(x, y);
                    if (c == null) continue;

                    // Cell.Objects is an ObjectRack, not a list. GetObjects() is
                    // the canonical accessor — don't assume raw enumeration of the
                    // rack yields the same set.
                    var objects = c.GetObjects();
                    int emitted = 0;

                    // Cell.Render() composites the WHOLE cell, so on any occupied
                    // cell it hands back the TOP OBJECT's tile — not the terrain.
                    // Emitting that as a floor drew every sprite twice: once
                    // standing, once flattened underneath itself (brinestalk over
                    // brinestalk, tree over tree). Only keep the composite when it
                    // is something no object in the cell already draws, i.e. when
                    // it really is the painted terrain.
                    var drawn = new System.Collections.Generic.HashSet<string>();
                    foreach (GameObject go in objects)
                    {
                        Render rr = go.GetPart<Render>();
                        if (rr == null) continue;
                        bool ignored;
                        string t = ResolvedTile(go, rr, out ignored);
                        if (!string.IsNullOrEmpty(t)) drawn.Add(TileFamily(t));
                    }

                    Ground ground = ResolveGround(c);
                    if (ground != null && drawn.Contains(TileFamily(ground.Tile))) ground = null;
                    if (ground == null && objects.Count == 0) continue;

                    bool opened = true;
                    j.BeginObject().Member("x", x).Member("y", y)
                        .Member("bridge", c.HasBridge())
                        .Member("wade", c.HasWadingDepthLiquid())
                        .Member("swim", c.HasSwimmingDepthLiquid())
                    .Name("objs").BeginArray();

                    // Qud's painted ground goes first: it is the bottom of the
                    // stack, and on most cells here it is the ONLY thing drawn.
                    if (ground != null) { WriteGroundTile(j, ground); emitted++; }

                    foreach (GameObject go in objects)
                    {
                        Render r = go.GetPart<Render>();
                        if (r == null) continue;

                        // Drawable = has ART or a GLYPH. Requiring RenderString
                        // silently dropped every tile-only object: RenderString is
                        // just the ASCII fallback, and in tile mode Qud draws from
                        // the tile. Objects filtered here never reach the wire, so
                        // no amount of querying the snapshot could find them.
                        bool painted;
                        string tile = ResolvedTile(go, r, out painted);
                        string glyph = ResolvedGlyph(r);
                        if (glyph.Length == 0 && tile.Length == 0) continue;

                        if (tile.Length > 0) TileExporter.Ensure(tile); // export-on-sight, cached

                        Physics phys = go.GetPart<Physics>();
                        LightSource light = go.GetPart<LightSource>();
                        j.BeginObject()
                            // Identity. Without this an object with no Tile is
                            // unidentifiable on the client — you see a glyph and a
                            // colour and cannot tell grass from a glowpad.
                            .Member("name", go.Blueprint ?? "")
                            .Member("display", DisplayNameOf(go))
                            .Member("glyph", glyph)
                            .Member("tile", tile)
                            .Member("color", r.ColorString ?? "")
                            .Member("tilecolor", r.TileColor ?? "")
                            .Member("detail", r.DetailColor ?? "")
                            .Member("layer", r.RenderLayer)
                            .Member("wall", go.IsWall())
                            .Member("solid", phys != null && phys.Solid)
                            .Member("occluding", r.Occluding)
                            // deck: a walkable surface laid over whatever is beneath it
                            // (bridges are RenderLayer 3, so without this flag Godot
                            // would stand them up as billboards instead of decking them).
                            .Member("bridge", go.HasIntProperty("Bridge"))
                            // only creatures sink; scenery/plants rooted in the water
                            // (watervines) must keep their full height. Flyers skim over.
                            .Member("sinks", go.IsCreature && !go.IsFlying);
                        // A lit LightSource -> Godot places a point light of this
                        // radius. The flame itself is procedural in Qud (particles +
                        // AnimatedMaterialFire), so there is no tile to send — only
                        // the light, which the blueprint specifies exactly.
                        if (light != null && light.Lit)
                            j.Member("lightRadius", light.Radius);
                        if (painted) WritePaintedColors(j);
                        j.EndObject();
                        emitted++;
                    }

                    if (opened)
                    {
                        // What the CELL says it holds vs what we actually sent.
                        // A gap here means we are dropping objects, and says so
                        // out loud instead of looking like an empty tile.
                        j.EndArray()
                            .Member("nHeld", CountSafe(c))
                            .Member("nRendered", RenderedSafe(c))
                            .Member("nSent", emitted)
                        .EndObject();
                    }

                }
            }
            j.EndArray();

            j.EndObject();
            return j.ToString();
        }
    }
}
