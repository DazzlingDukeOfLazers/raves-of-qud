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

        public static string BuildJson(GameObject player)
        {
            var j = new JsonWriter();
            j.BeginObject();
            j.Member("type", Protocol.TypeSnapshot);
            j.Member("tilesDir", TileExporter.Dir); // where Godot loads exported PNGs

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

                    bool opened = false;
                    foreach (GameObject go in c.Objects)
                    {
                        Render r = go.GetPart<Render>();
                        if (r == null || string.IsNullOrEmpty(r.RenderString)) continue;

                        if (!opened)
                        {
                            // Cell-level water/bridge facts. Godot turns these into a
                            // "sink" depth for the actors standing here; a bridge
                            // cancels it (you walk over the water, not through it).
                            j.BeginObject().Member("x", x).Member("y", y)
                                .Member("bridge", c.HasBridge())
                                .Member("wade", c.HasWadingDepthLiquid())
                                .Member("swim", c.HasSwimmingDepthLiquid())
                            .Name("objs").BeginArray();
                            opened = true;
                        }

                        string tile = r.Tile ?? "";
                        if (tile.Length > 0) TileExporter.Ensure(tile); // export-on-sight, cached

                        Physics phys = go.GetPart<Physics>();
                        j.BeginObject()
                            // Identity. Without this an object with no Tile is
                            // unidentifiable on the client — you see a glyph and a
                            // colour and cannot tell grass from a glowpad.
                            .Member("name", go.Blueprint ?? "")
                            .Member("display", DisplayNameOf(go))
                            .Member("glyph", r.RenderString)
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
                            .Member("sinks", go.IsCreature && !go.IsFlying)
                        .EndObject();
                    }

                    if (opened) { j.EndArray().EndObject(); }
                }
            }
            j.EndArray();

            j.EndObject();
            return j.ToString();
        }
    }
}
