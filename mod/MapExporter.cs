using System;
using System.IO;
using UnityEngine;
using XRL;                  // The
using Genkit;               // Location2D (NOT XRL.World)
using XRL.World;            // ZoneManager

namespace RavesOfQud
{
    /// <summary>
    /// Exports the world-map panel that the Quests (and Journal) status screens draw beside their
    /// list, as a PNG plus the quest-giver PINS.
    ///
    /// WHY EXPORT THE TEXTURE RATHER THAN RE-RENDER IT: MapScrollerController.RefreshMap builds the
    /// map by walking all 80x25 cells of the "JoppaWorld" zone, rendering each through a RenderEvent
    /// and blitting its recoloured sprite into a 1280x600 texture (16x24 per cell). Reproducing that
    /// means reproducing Qud's whole world-map render — terrain sprite choice, per-cell colour,
    /// exploration state — and keeping it in step forever. The texture Qud already built is exact
    /// and free.
    ///
    /// The texture is private, but the Image it feeds is not: mapImage.sprite.texture IS it, and it
    /// is CPU-readable because RefreshMap constructs it with `new Texture2D(...)` rather than
    /// uploading an opaque GPU resource.
    ///
    /// PINS are recomputed the way QuestsStatusScreen.UpdateViewFromData does: one per distinct
    /// QuestGiverLocationZoneID, positioned by ZoneManager.GetWorldMapLocationForZoneID, titled with
    /// the location name and detailed with the quests there. Same source, same rule.
    /// </summary>
    public static class MapExporter
    {
        public const int CellW = 16;    // RefreshMap's per-cell blit size
        public const int CellH = 24;
        public const int MapW = 80;     // JoppaWorld is 80x25 world-map cells
        public const int MapH = 25;

        public static string Dir => Path.Combine(
            Directory.GetParent(TileExporter.Dir).FullName, "map");

        private static void Log(string s)
        {
            System.Console.WriteLine("[raves] map: " + s);
            try { Bridge.Server?.Log("map: " + s); } catch { }
        }

        /// <summary>UNITY MAIN THREAD, with the Quests screen live. Writes world_map.png.</summary>
        public static void ExportQuestsMap()
        {
            try
            {
                var quests = Qud.UI.QuestsStatusScreen.instance;
                if (quests == null || !quests.Visible) { Log("quests screen not live"); return; }
                var mc = quests.mapController;
                if (mc == null || mc.mapImage == null || mc.mapImage.sprite == null)
                { Log("no map image yet — has the screen rendered?"); return; }
                var tex = mc.mapImage.sprite.texture;
                if (tex == null) { Log("map sprite has no texture"); return; }

                Directory.CreateDirectory(Dir);
                byte[] png;
                try { png = tex.EncodeToPNG(); }
                catch (Exception e) { Log("texture not readable: " + e.Message); return; }
                if (png == null || png.Length == 0) { Log("empty PNG"); return; }
                File.WriteAllBytes(Path.Combine(Dir, "world_map.png"), png);
                Log(string.Format("wrote world_map.png ({0}x{1}, {2} bytes)", tex.width, tex.height, png.Length));
            }
            catch (Exception e) { Log("failed: " + e); }
        }

        /// <summary>Quest-giver pins, as UpdateViewFromData computes them. Safe off the UI thread —
        /// it only reads quest + zone data.</summary>
        public static void WritePins(JsonWriter j)
        {
            j.Name("pins").BeginArray();
            try
            {
                // ONE PIN PER ZONE, listing every quest there — UpdateViewFromData dedupes by
                // QuestGiverLocationZoneID and then builds `details` from ALL quests sharing that
                // location. Keeping only the first quest's name would silently hide the others
                // whenever two quest givers stand in the same place (which Joppa's two do).
                var order = new System.Collections.Generic.List<string>();
                var byZone = new System.Collections.Generic.Dictionary<string, System.Collections.Generic.List<XRL.World.Quest>>();
                foreach (var q in Qud.API.QuestsAPI.allQuests())
                {
                    if (q == null || q.Finished) continue;
                    string zid = q.QuestGiverLocationZoneID;
                    if (string.IsNullOrEmpty(zid)) continue;
                    if (!byZone.ContainsKey(zid))
                    {
                        byZone[zid] = new System.Collections.Generic.List<XRL.World.Quest>();
                        order.Add(zid);
                    }
                    byZone[zid].Add(q);
                }
                foreach (var zid in order)
                {
                    var list = byZone[zid];
                    Location2D loc = null;
                    try { loc = ZoneManager.GetWorldMapLocationForZoneID(zid); } catch { }
                    if (loc == null) loc = Location2D.Get(0, 0);
                    j.BeginObject()
                     .Member("x", loc.X).Member("y", loc.Y)
                     .Member("title", list[0].QuestGiverLocationName ?? "");
                    j.Name("quests").BeginArray();
                    foreach (var q in list)
                        j.Value(ConsoleLib.Console.ColorUtility.StripFormatting(q.DisplayName ?? ""));
                    j.EndArray();
                    j.EndObject();
                }
            }
            catch (Exception e) { Log("pins: " + e.Message); }
            j.EndArray();
        }
    }
}
