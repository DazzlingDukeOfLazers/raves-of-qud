using System;
using System.Collections.Generic;
using Qud.UI;               // PickGameObjectScreen, PickGameObjectLineData, PickGameObjectLineDataType
using XRL;                  // GameManager
using XRL.World;            // GameObject

namespace RavesOfQud
{
    /// <summary>
    /// Mirrors Qud's ITEM PICKER (<c>Qud.UI.PickGameObjectScreen</c>) to Raves, and injects the viewer's
    /// choice back so Qud's blocked turn thread unblocks.
    ///
    /// WHY THIS IS SEPARATE FROM <see cref="PopupBridge"/>: the picker is not a PopupMessage. Clicking an
    /// EMPTY paper-doll slot runs EquipmentScreen.ShowBodypartEquipUI → PickItem.ShowPicker →
    /// PickGameObjectScreen.show(), a whole screen with its own singleton, its own list model and its own
    /// TaskCompletionSource. It never passes through getWindow("PopupMessage"), so the popup mirror is blind
    /// to it: before this, Qud put the picker up and Raves showed nothing at all.
    ///
    /// Threading: identical to the popup case, and for the same reason. show() parks the turn thread on
    /// `await menucomplete.Task` while the UI thread keeps drawing and keeps draining uiQueue — so we poll
    /// from PopupBridge's existing UI-thread watcher and answer from there too.
    ///
    /// The model we export is exactly what PickGameObjectLine.setData draws, so Raves can reproduce the rows
    /// without guessing: a CATEGORY row is "[-] name" (collapsible), an ITEM row is tile + hotkey + display
    /// name + right-floated weight. Selection round-trips by INDEX into that same list, and Qud's own
    /// HandleSelectItem does the work — which is what makes a category row toggle and an item row pick,
    /// with no second implementation of the rule on our side.
    /// </summary>
    public static class PickerBridge
    {
        private static volatile bool _resend;   // client (re)connected → re-announce the live picker once
        private static int _id;
        private static bool _active;
        private static string _sig = "";
        private static PickGameObjectScreen _announced;   // the instance the announced rows came from

        private static void Log(string s) { try { Bridge.Server?.Log(s); } catch { } }

        public static void OnClientConnect() { _resend = true; }

        /// <summary>The picker screen if it is genuinely up, else null. Hide() clears listItems and drops
        /// Visible, so "visible with rows" is a sound liveness test — no ghost-instance problem like the
        /// popup's copyWindow path, because this screen is a true singleton.</summary>
        private static PickGameObjectScreen Live()
        {
            try
            {
                var sc = PickGameObjectScreen.instance;
                if (sc == null || !sc.Visible) return null;
                return (sc.listItems != null && sc.listItems.Count > 0) ? sc : null;
            }
            catch { return null; }
        }

        /// UI THREAD (driven by PopupBridge's watcher). Publish a picker frame whenever the screen's state
        /// changes — appeared, rows changed (a category collapsed, a sort flipped), or dismissed.
        public static void Poll(BridgeServer server)
        {
            bool resend = _resend;
            _resend = false;

            PickGameObjectScreen sc = Live();
            if (sc == null)
            {
                if (_active)
                {
                    _active = false;
                    _sig = "";
                    _announced = null;
                    var j = new JsonWriter();
                    j.BeginObject().Member("type", Protocol.TypePicker)
                        .Member("active", false).Member("id", ++_id).EndObject();
                    Publish(server, j.ToString());
                }
                return;
            }

            string sig = Signature(sc);
            if (_active && sig == _sig && !resend) return;
            _active = true;
            _sig = sig;
            _announced = sc;
            Publish(server, Frame(sc));
        }

        /// Cheap change-detector: everything the viewer can see, and nothing that churns per frame.
        private static string Signature(PickGameObjectScreen sc)
        {
            var sb = new System.Text.StringBuilder();
            try { sb.Append(sc.titleText != null ? sc.titleText.text : "").Append('\u001F'); } catch { }
            foreach (var d in sc.listItems)
            {
                if (d == null) continue;
                try
                {
                    if (d.type == PickGameObjectLineDataType.Category)
                        sb.Append('C').Append(d.category).Append(d.collapsed ? '+' : '-');
                    else
                        sb.Append('I').Append(d.go != null ? d.go.ID : "").Append(d.quickKey);
                    sb.Append('\u001F');
                }
                catch { }
            }
            return sb.ToString();
        }

        private static string Frame(PickGameObjectScreen sc)
        {
            var j = new JsonWriter();
            j.BeginObject().Member("type", Protocol.TypePicker).Member("active", true).Member("id", ++_id);
            try { j.Member("title", sc.titleText != null ? (sc.titleText.text ?? "") : ""); } catch { }
            // Qud's OWN highlighted row. Don't model the rule (it lands on the first ITEM, not the
            // first row, and it re-clamps after every category toggle) -- read the live scroller.
            try { j.Member("sel", sc.itemScrollerController.selectedPosition); } catch { }
            j.Name("rows").BeginArray();
            for (int i = 0; i < sc.listItems.Count; i++)
            {
                var d = sc.listItems[i];
                if (d == null) continue;
                j.BeginObject().Member("i", i);
                try
                {
                    // PickGameObjectLine.setData branches on `go == null`, NOT on the type enum — match it,
                    // so a malformed row can never be exported as an item with no object to draw.
                    if (d.go == null)
                    {
                        j.Member("cat", true)
                         .Member("name", d.category ?? "")
                         .Member("collapsed", d.collapsed);
                    }
                    else
                    {
                        j.Member("cat", false).Member("name", d.go.DisplayName ?? "");

                        // GetWeight() is a DOUBLE, and PickGameObjectLine right-floats its plain ToString()
                        // with a '#' suffix. Ship the formatted string so Raves doesn't re-decide how many
                        // decimals a 0.5-pound item shows.
                        try { j.Member("weight", d.go.GetWeight().ToString(System.Globalization.CultureInfo.InvariantCulture)); } catch { }
                        InventoryExporter.WriteTile(j, d.go);
                    }
                    // The hotkey belongs to BOTH kinds of row: setData writes `hotkey` AFTER the
                    // go==null branch closes, so Qud letters its categories too (a] [+] Armor) and
                    // those letters are how you collapse one from the keyboard.
                    if (d.indent) j.Member("indent", true);
                    if (d.quickKey != '\0') j.Member("key", d.quickKey.ToString());
                    if (!string.IsNullOrEmpty(d.hotkeyDescription)) j.Member("hk", d.hotkeyDescription);
                }
                catch { }
                j.EndObject();
            }
            j.EndArray();
            // The picker's own palette, so Raves resolves colour chars the same way the rest of the UI does.
            try { InventoryExporter.WritePalette(j); } catch { }
            j.EndObject();
            return j.ToString();
        }

        private static void Publish(BridgeServer server, string json)
        {
            try { server.Publish(Protocol.Frame(json)); }
            catch (Exception e) { Log("picker publish: " + e.Message); }
        }

        /// <summary>ANY THREAD. Answer the mirrored picker: {"name":"picker","do":"select","row":N} or
        /// {"do":"cancel"}. Marshalled onto the uiQueue because the turn thread is parked inside show().</summary>
        public static void HandleCommand(Dictionary<string, string> f)
        {
            f.TryGetValue("do", out string what);
            f.TryGetValue("row", out string rowStr);
            int row;
            // JSON numbers can arrive as "3.0"; parse leniently rather than silently doing nothing.
            if (!int.TryParse(rowStr, out row))
            {
                double dv;
                row = double.TryParse(rowStr, System.Globalization.NumberStyles.Any,
                    System.Globalization.CultureInfo.InvariantCulture, out dv) ? (int)dv : -1;
            }

            GameManager gm = GameManager.Instance;
            if (gm == null || gm.uiQueue == null) { Log("picker cmd: no uiQueue"); return; }
            gm.uiQueue.queueTask(delegate
            {
                try
                {
                    var sc = Live();
                    if (sc == null) { Log("picker cmd: no live picker"); return; }
                    // Answer the instance we ANNOUNCED. If the screen was rebuilt since, the row index the
                    // viewer clicked no longer means what they saw — drop it rather than pick a stranger.
                    if (_announced != null && !ReferenceEquals(_announced, sc))
                    { Log("picker cmd: screen changed since announce; ignoring"); return; }

                    if (what == "cancel") { sc.Cancel(); return; }
                    if (what != "select") { Log("picker cmd: unknown do=" + what); return; }
                    if (row < 0 || row >= sc.listItems.Count)
                    { Log("picker cmd: row " + row + " out of range (" + sc.listItems.Count + ")"); return; }

                    // Qud's own handler: a category row toggles collapse and rebuilds, an item row completes
                    // the task and unblocks the turn thread.
                    sc.HandleSelectItem(sc.listItems[row]);
                }
                catch (Exception e) { Log("picker cmd: " + e.Message); }
            }, 0);
        }
    }
}
