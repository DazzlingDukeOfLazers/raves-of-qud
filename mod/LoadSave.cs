using System;
using System.Linq;
using ConsoleLib.Console;  // Keyboard.PushMouseEvent — the title menu's own dispatch

namespace RavesOfQud
{
    /// <summary>
    /// Load a NAMED save on request from Raves' 1:1 picker: complete Qud's own
    /// save-picker completionSource with the matching SaveGameInfo — byte-for-byte
    /// what a row click does (SaveManagement.SelectedInfo) — so Qud runs its normal
    /// version-check + TryRestoreModsAndLoadAsync flow. If the picker isn't open,
    /// push the title's "Pick:Continue" mouse event once and complete on a later tick.
    ///
    /// THREADING: Attempt() must run on the Unity main thread (UI state + the
    /// completionSource continuation) — marshalled via GameManager.uiQueue. Retries
    /// are re-armed ~1/s from the heartbeat thread (StartupHook), NOT by re-queueing
    /// inside the same uiQueue drain (that would spin all attempts in one frame while
    /// the picker is still animating open).
    /// </summary>
    public static class LoadSave
    {
        private static void Log(string s) { try { Bridge.Server?.Log(s); } catch { } }

        private static volatile string _id;
        private static DateTime _deadline;
        private static bool _opened;

        /// <summary>Bridge entry (any thread): start/replace the pending request.</summary>
        public static void Request(string id)
        {
            _id = id;
            _deadline = DateTime.UtcNow.AddSeconds(20);
            _opened = false;
            Pump();
            Log("[loadsave] requested " + id);
        }

        /// <summary>Heartbeat tick (background thread): re-arm a main-thread attempt.</summary>
        public static void Pump()
        {
            string id = _id;
            if (id == null) return;
            if (DateTime.UtcNow > _deadline)
            {
                _id = null;
                Log("[loadsave] timed out waiting for the picker (" + id + ")");
                return;
            }
            GameManager gm = GameManager.Instance;
            if (gm == null || gm.uiQueue == null) return;
            gm.uiQueue.queueTask(() => Attempt(id), 0);
        }

        private static void Attempt(string id)
        {
            if (_id != id) return;  // superseded or done
            try
            {
                // the picker's awaiting source — SaveManagement is the modern window;
                // MainMenu keeps its own for the title's inline save list
                var src = Qud.UI.SaveManagement.instance != null
                    ? Qud.UI.SaveManagement.instance.completionSource : null;
                if (src == null || src.Task.IsCompleted)
                    src = Qud.UI.MainMenu.instance != null
                        ? Qud.UI.MainMenu.instance.completionSource : null;
                if (src == null || src.Task.IsCompleted)
                {
                    if (!_opened)
                    {
                        _opened = true;
                        Keyboard.PushMouseEvent("Pick:Continue");   // the title row's own event
                        Log("[loadsave] pushed Pick:Continue for " + id);
                    }
                    return;  // picker still opening — the heartbeat re-arms us
                }
                var task = Qud.API.SavesAPI.GetSavedGameInfo();
                task.Wait(5000);  // Show() itself does Task.WaitAll on this — safe by precedent
                var info = (task.IsCompleted && task.Result != null)
                    ? task.Result.FirstOrDefault(i => i != null && i.ID == id) : null;
                if (info == null)
                {
                    _id = null;
                    Log("[loadsave] no save with ID " + id);
                    return;
                }
                if (src.TrySetResult(info))
                {
                    _id = null;
                    Log("[loadsave] loading '" + info.Name + "' (" + id + ")");
                }
            }
            catch (Exception ex)
            {
                Log("[loadsave] error: " + ex.Message);
            }
        }
    }
}
