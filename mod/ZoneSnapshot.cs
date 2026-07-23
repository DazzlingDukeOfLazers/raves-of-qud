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
    ///
    /// We emit RAW Qud color strings (e.g. "&amp;Y") and let Godot interpret them.
    /// FOV / fog-of-war filtering is intentionally deferred (v2): for now we ship
    /// every object that has a Render + non-empty glyph.
    /// </summary>
    public static class ZoneSnapshot
    {
        public static string BuildJson(GameObject player)
        {
            var j = new JsonWriter();
            j.BeginObject();
            j.Member("type", Protocol.TypeSnapshot);
            j.Member("tilesDir", TileExporter.Dir); // where Godot loads exported PNGs

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
                            j.BeginObject().Member("x", x).Member("y", y).Name("objs").BeginArray();
                            opened = true;
                        }

                        string tile = r.Tile ?? "";
                        if (tile.Length > 0) TileExporter.Ensure(tile); // export-on-sight, cached

                        Physics phys = go.GetPart<Physics>();
                        j.BeginObject()
                            .Member("glyph", r.RenderString)
                            .Member("tile", tile)
                            .Member("color", r.ColorString ?? "")
                            .Member("tilecolor", r.TileColor ?? "")
                            .Member("detail", r.DetailColor ?? "")
                            .Member("layer", r.RenderLayer)
                            .Member("wall", go.IsWall())
                            .Member("solid", phys != null && phys.Solid)
                            .Member("occluding", r.Occluding)
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
