using XRL;
using XRL.World;
using XRL.World.Parts;

namespace RavesOfQud
{
    /// <summary>
    /// Serializes the active zone into the snapshot JSON that Godot renders.
    /// Reads game state — MUST be called on the main thread (it is: via Bridge.Tick).
    ///
    /// CONFIRMED against the installed 1.0 build via Assembly-CSharp.dll metadata:
    ///   The.ActiveZone            (get_ActiveZone exists)
    ///   GameObject.GetFirstPart&lt;T&gt;()  (GetPart&lt;T&gt; was NOT present; GetFirstPart is)
    ///   Render fields are lowercase: renderString, colorString, detailColor
    ///   GameObject.CurrentCell    (get_CurrentCell exists)
    ///
    /// STILL CONFIRM in ILSpy (not resolvable from string metadata alone):
    ///   Zone.Width / Zone.Height / Zone.GetCell(x,y) / Zone.ZoneID (property chains)
    ///   Cell.Objects, Cell.X, Cell.Y
    ///   Render tile fields — the sprite path / tile color / render layer field
    ///   names didn't surface as bare strings; read them off Parts/Render.cs.
    ///   (Deferred below; the MVP renderer only needs glyph + color.)
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
                        Render r = go.GetFirstPart<Render>();
                        if (r == null || string.IsNullOrEmpty(r.renderString)) continue;

                        if (!opened)
                        {
                            j.BeginObject().Member("x", x).Member("y", y).Name("objs").BeginArray();
                            opened = true;
                        }

                        // Confirmed fields only. Add tile/tilecolor/layer once you've
                        // read their exact field names off Parts/Render.cs in ILSpy.
                        j.BeginObject()
                            .Member("glyph", r.renderString)
                            .Member("color", r.colorString ?? "")
                            .Member("detail", r.detailColor ?? "")
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
