using System;
using System.Collections;
using System.Reflection;

namespace RavesOfQud
{
    /// <summary>
    /// Drive Qud's Map Editor through its OWN API instead of synthetic mouse input.
    ///
    /// WHY: injected input reproduces the editor's drag verbs only partially — a bare drag pans
    /// reliably, Ctrl+drag paints intermittently, and Shift+drag never commits a region at all
    /// (measured; see highvisor gametree me_controls). The editor builds a selection from
    /// OnBeginDrag/OnDragMove, and the press-anchored raycast those depend on does not survive
    /// raw event injection. Rather than keep tuning timings, do what <see cref="EmbarkDriver"/>
    /// does for chargen: skip the input layer and call the real thing.
    ///
    /// Everything here is reflection so a Qud update degrades to a logged error instead of
    /// breaking the mod's compile, and every entry point is MAIN-THREAD ONLY (Unity objects) —
    /// callers must come through GameManager.uiQueue, same rule as the tile export.
    /// </summary>
    public static class MapEditorDriver
    {
        private const BindingFlags ANY = BindingFlags.Instance | BindingFlags.Static
                                       | BindingFlags.Public | BindingFlags.NonPublic;

        private static void Log(string s)
        {
            System.Console.WriteLine("[raves] mapedit: " + s);
            try { Bridge.Server?.Log("mapedit: " + s); } catch { }
        }

        private static Type ViewType => Type.GetType("Overlay.MapEditor.MapEditorView, Assembly-CSharp");

        /// The live MapEditorView, or null when the editor isn't open.
        private static object View()
        {
            Type t = ViewType;
            if (t == null) return null;
            object v = t.GetField("Instance", ANY)?.GetValue(null)
                    ?? t.GetField("instance", ANY)?.GetValue(null);
            return v;
        }

        /// <summary>Select a cell region and refresh the selected-contents list — the state a
        /// Shift+drag is supposed to produce. Coordinates are CELL indices (0-79, 0-24).</summary>
        public static bool Select(int x1, int y1, int x2, int y2)
        {
            try
            {
                object v = View();
                if (v == null) { Log("no MapEditorView (is the editor open?)"); return false; }
                Type t = v.GetType();
                int lx = Math.Min(x1, x2), ly = Math.Min(y1, y2);
                int hx = Math.Max(x1, x2), hy = Math.Max(y1, y2);
                // Rect is min-based here: OnDragMove sets min/max from the two drag corners.
                var rect = new UnityEngine.Rect(lx, ly, hx - lx + 1, hy - ly + 1);
                t.GetField("SelectedRegion", ANY)?.SetValue(v, rect);
                t.GetField("HasSelectedRegion", ANY)?.SetValue(v, true);
                Invoke(v, "UpdateSelectedContents");
                Invoke(v, "RenderSelectionFrame");
                Invoke(v, "RenderMap");
                Log(string.Format("selected ({0},{1})-({2},{3})", lx, ly, hx, hy));
                return true;
            }
            catch (Exception e) { Log("select failed: " + e.Message); return false; }
        }

        /// <summary>Place a blueprint into a cell — what Ctrl+drag does, minus the input layer.</summary>
        public static bool Paint(int x, int y, string blueprint)
        {
            try
            {
                object v = View();
                if (v == null) { Log("no MapEditorView"); return false; }
                object cells = CellsOf(v);
                if (cells == null) { Log("no Map.Cells (open or create a map first)"); return false; }
                MethodInfo getOrCreate = cells.GetType().GetMethod("GetOrCreateCellAt", ANY,
                    null, new[] { typeof(int), typeof(int) }, null);
                if (getOrCreate == null) { Log("no GetOrCreateCellAt on " + cells.GetType().Name); return false; }
                object cell = getOrCreate.Invoke(cells, new object[] { x, y });
                if (cell == null) { Log("no cell at " + x + "," + y); return false; }
                var objects = cell.GetType().GetField("Objects", ANY)?.GetValue(cell) as IList;
                if (objects == null) { Log("cell has no Objects list"); return false; }
                Type bpType = Type.GetType("XRL.EditorFormats.Map.MapFileObjectBlueprint, Assembly-CSharp");
                if (bpType == null) { Log("no MapFileObjectBlueprint type"); return false; }
                object bp = Activator.CreateInstance(bpType, new object[] { blueprint, null, null });
                objects.Add(bp);
                Invoke(v, "RenderMap");
                Log(string.Format("painted '{0}' at ({1},{2}); cell now holds {3}",
                    blueprint, x, y, objects.Count));
                return true;
            }
            catch (Exception e) { Log("paint failed: " + e.Message); return false; }
        }

        /// <summary>Open the per-object context menu for the FIRST object in a cell — the menu a
        /// right-click on a selected-contents row raises (MapEditorSelectedObjectsRow.OnPointerClick
        /// -> DisplayContextInRegion). Requires a selection, which is what Select() establishes.</summary>
        public static bool Context(int x, int y)
        {
            try
            {
                object v = View();
                if (v == null) { Log("no MapEditorView"); return false; }
                object cells = CellsOf(v);
                MethodInfo getOrCreate = cells?.GetType().GetMethod("GetOrCreateCellAt", ANY,
                    null, new[] { typeof(int), typeof(int) }, null);
                object cell = getOrCreate?.Invoke(cells, new object[] { x, y });
                var objects = cell?.GetType().GetField("Objects", ANY)?.GetValue(cell) as IList;
                if (objects == null || objects.Count == 0)
                {
                    Log("no object at " + x + "," + y + " — paint one first");
                    return false;
                }
                object bp = objects[0];
                MethodInfo show = v.GetType().GetMethod("DisplayContextInRegion", ANY);
                if (show == null) { Log("no DisplayContextInRegion"); return false; }
                show.Invoke(v, new[] { bp });
                Log("context menu raised for the object at " + x + "," + y);
                return true;
            }
            catch (Exception e) { Log("context failed: " + e.Message); return false; }
        }

        /// <summary>Report what the editor currently thinks is selected — a cheap readback so a
        /// driven test asserts on state instead of pixels.</summary>
        public static string State()
        {
            try
            {
                object v = View();
                if (v == null) return "{\"open\":false}";
                Type t = v.GetType();
                object rect = t.GetField("SelectedRegion", ANY)?.GetValue(v);
                object has = t.GetField("HasSelectedRegion", ANY)?.GetValue(v);
                object map = t.GetField("Map", ANY)?.GetValue(v);
                return "{\"open\":true,\"hasRegion\":" + ((has is bool b && b) ? "true" : "false")
                     + ",\"region\":\"" + rect + "\",\"map\":" + (map != null ? "true" : "false") + "}";
            }
            catch (Exception e) { return "{\"open\":false,\"error\":\"" + e.Message + "\"}"; }
        }

        /// The editor's cell grid. MapFile is NOT itself a region (measured — the first
        /// attempt looked for GetOrCreateCellAt on MapFile and the driver logged
        /// "no GetOrCreateCellAt on MapFile"); the region hangs off MapFile.Cells.
        private static object CellsOf(object view)
        {
            object map = view.GetType().GetField("Map", ANY)?.GetValue(view);
            if (map == null) return null;
            return map.GetType().GetField("Cells", ANY)?.GetValue(map);
        }

        /// Bridge fields arrive as strings; a missing/garbage one is 0, not an exception.
        public static int ParseInt(string s)
        {
            int v;
            return int.TryParse(s, out v) ? v : 0;
        }

        private static void Invoke(object target, string method)
        {
            try { target.GetType().GetMethod(method, ANY)?.Invoke(target, null); }
            catch (Exception e) { Log(method + " threw: " + e.Message); }
        }
    }
}
