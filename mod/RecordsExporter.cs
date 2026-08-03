using System;
using System.IO;
using System.Threading;

namespace RavesOfQud
{
    /// <summary>
    /// Export the player's high-score records — Qud's OWN <c>HighScores.json</c> (the "Records" the
    /// title menu shows, i.e. <see cref="XRL.Core.Scoreboard2"/> = a list of past-character game
    /// summaries) — to <c>records.json</c> in the RavesOfQud support dir, so Raves' Records screen
    /// shows exactly what Qud shows. Read from the player's own install, never redistributed.
    ///
    /// Qud persists the scoreboard as JSON at <c>DataManager.SyncedPath("HighScores.json")</c> (a Steam
    /// cloud-synced path, per-user, that Raves can't compute). We resolve it via that public accessor —
    /// which is a pure combine of the cached <c>XRLCore.SyncedPath</c> string, so it's safe on the turn
    /// thread — and copy the file VERBATIM. Copying the raw bytes (rather than parsing + re-emitting)
    /// keeps every field and can't drop one; the client reads Qud's own schema:
    ///
    ///   { "Scores": [ { "Score":int, "Details":string(markup), "Turns":long,
    ///                   "GameId":string, "GameMode":string, "Name":string,
    ///                   "Level":int, "Version":int }, ... ] }
    ///
    /// <c>Details</c> is the full multi-line game summary with Qud <c>{{colour|text}}</c> markup (the
    /// structured fields are parsed out of it by Qud); the client renders it coloured.
    ///
    /// Data-only (no Unity calls) — like <see cref="ModsExporter"/>, so it runs on the turn thread.
    /// One-shot per session; the bridge "export" command re-runs it so the screen can refresh live.
    /// </summary>
    public static class RecordsExporter
    {
        private static int _tried;

        /// <summary>Re-run on demand (bridge "export" command), bypassing the one-shot guard, so Raves
        /// can refresh the records without a fresh in-game turn.</summary>
        public static void ReExport()
        {
            try { Export(); }
            catch (Exception e) { System.Console.WriteLine("[raves] records re-export failed: " + e.Message); }
        }

        /// <summary>Turn-thread safe: export the records once per session.</summary>
        public static void Ensure()
        {
            if (Interlocked.Exchange(ref _tried, 1) != 0) return;
            try
            {
                Export();
                System.Console.WriteLine("[raves] records exported -> " + Path.Combine(Root, "records.json"));
            }
            catch (Exception e)
            {
                System.Console.WriteLine("[raves] records export failed: " + e.Message);
                _tried = 0;   // let a later turn retry
            }
        }

        private static string Root
        {
            get
            {
                string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                string root = Path.Combine(home, "Library", "Application Support", "RavesOfQud");
                Directory.CreateDirectory(root);
                return root;
            }
        }

        private static void Export()
        {
            string dst = Path.Combine(Root, "records.json");

            string src = null;
            try { src = XRL.DataManager.SyncedPath("HighScores.json"); }
            catch (Exception e) { System.Console.WriteLine("[raves] records path: " + e.Message); }

            // Copy Qud's own scoreboard file verbatim. Read+write (not File.Copy) so we always
            // overwrite and never inherit source file attributes. If the player has no finished
            // games yet the file is absent — emit an empty scoreboard so the screen shows its
            // "no records" note instead of erroring on a missing file.
            if (!string.IsNullOrEmpty(src) && File.Exists(src))
                File.WriteAllText(dst, File.ReadAllText(src));
            else
                File.WriteAllText(dst, "{\"Scores\":[]}");
        }
    }
}
