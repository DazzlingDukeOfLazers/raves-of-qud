using System;
using System.IO;
using System.Threading;
using Kobold;      // SpriteManager
using UnityEngine; // Sprite, Texture2D, RenderTexture, Graphics, Rect, Mathf, Vector2

namespace RavesOfQud
{
    /// <summary>
    /// Main-thread tile export. <see cref="Export"/> is enqueued by
    /// <see cref="TileExporter.Ensure"/> onto Qud's GameManager.uiQueue and runs
    /// on the UI/main thread, where the atlas readback + PNG write are legal.
    ///
    /// Belt-and-suspenders: a guard verifies we really are on Unity's main thread
    /// (its SynchronizationContext is installed only there) and no-ops otherwise,
    /// so a wrong assumption about uiQueue's thread can't crash the game. A
    /// one-time log line confirms which thread uiQueue tasks run on.
    /// </summary>
    public static class TileExportPump
    {
        private static int _logged;

        public static bool OnUnityMainThread()
        {
            var ctx = SynchronizationContext.Current;
            return ctx != null && ctx.GetType().Name == "UnitySynchronizationContext";
        }


        /// Qud's canonical tile path is "<Dir>/<file>.bmp" with a CAPITALISED directory —
        /// SpriteManager.GetUnitySprite("Creatures/sw_farmer.bmp") resolves while
        /// "creatures/sw_farmer.bmp" and "Assets/Content/Textures/Creatures/sw_farmer.bmp" both
        /// return null (measured 2026-08-07).
        ///
        /// But ~345 of the ~4.6k blueprint Tile values arrive ALREADY FLATTENED, e.g.
        /// "Assets_Content_Textures_Creatures_sw_farmer.bmp". Those resolve to nothing, so those
        /// blueprints could never fetch their art. Rebuild a real path from the flattened form:
        /// drop the Assets_Content_Textures_ prefix, then split at the first underscore that is
        /// followed by a lower-case letter — Qud's directories are capitalised and its file names
        /// start lower-case ("sw_", "item_"), so that boundary is the directory separator.
        ///
        /// The caller still writes the file under the ORIGINAL requested name, so the client's
        /// lookup (which only knows the flattened string) keeps matching.
        private static Sprite Resolve(string tilePath)
        {
            Sprite sp = SpriteManager.GetUnitySprite(tilePath);
            if (sp != null) return sp;

            // Some blueprints spell the separator with a BACKSLASH ("creatures\sw_glowfish.bmp").
            // SpriteManager wants a forward slash, so try that before anything else — measured:
            // it was the single miss in a 12-path sample of otherwise-repairable tiles.
            if (tilePath.IndexOf('\\') >= 0)
            {
                sp = SpriteManager.GetUnitySprite(tilePath.Replace('\\', '/'));
                if (sp != null)
                {
                    System.Console.WriteLine("[raves] tile export: backslash path repaired for '" + tilePath + "'");
                    return sp;
                }
            }
            if (tilePath.IndexOf('/') >= 0) return null;   // already a real path; nothing to repair

            string flat = tilePath;
            const string prefix = "Assets_Content_Textures_";
            if (flat.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                flat = flat.Substring(prefix.Length);

            for (int i = 0; i < flat.Length - 1; i++)
            {
                if (flat[i] != '_' || !char.IsLower(flat[i + 1])) continue;
                string cand = flat.Substring(0, i) + "/" + flat.Substring(i + 1);
                sp = SpriteManager.GetUnitySprite(cand);
                if (sp != null)
                {
                    System.Console.WriteLine("[raves] tile export: '" + tilePath + "' -> '" + cand + "'");
                    return sp;
                }
                break;   // first lower-case boundary is THE separator; more would be guessing
            }
            return null;
        }

        public static void Export(string tilePath)
        {
            if (Interlocked.Exchange(ref _logged, 1) == 0)
                System.Console.WriteLine($"[raves] uiQueue task on Unity main thread = {OnUnityMainThread()}");
            if (!OnUnityMainThread()) return; // never do graphics off the main thread

            try
            {
                string dest = Path.Combine(TileExporter.Dir, TileExporter.FileFor(tilePath));
                if (File.Exists(dest)) return;

                Sprite sp = Resolve(tilePath);
                if (sp == null || sp.texture == null)
                {
                    // LOUD, not silent. A path that resolves to nothing used to return here
                    // without a word, so a bad tile string looked identical to a working one
                    // that simply had not been drawn yet — which cost a debugging round.
                    System.Console.WriteLine("[raves] tile export: could not resolve '" + tilePath + "'");
                    return;
                }

                Texture2D tex = sp.texture;
                Rect tr = sp.textureRect;
                int w = Mathf.RoundToInt(tr.width);
                int h = Mathf.RoundToInt(tr.height);
                int x = Mathf.RoundToInt(tr.x);
                int y = Mathf.RoundToInt(tr.y);
                if (w <= 0 || h <= 0) return;

                // Scaled blit of just this tile's rect into a small RT (no full-atlas alloc).
                RenderTexture rt = RenderTexture.GetTemporary(
                    w, h, 0, RenderTextureFormat.ARGB32, RenderTextureReadWrite.Linear);
                var scale = new Vector2((float)w / tex.width, (float)h / tex.height);
                var offset = new Vector2((float)x / tex.width, (float)y / tex.height);
                Graphics.Blit(tex, rt, scale, offset);

                RenderTexture prev = RenderTexture.active;
                RenderTexture.active = rt;
                var outTex = new Texture2D(w, h, TextureFormat.RGBA32, false);
                outTex.ReadPixels(new Rect(0, 0, w, h), 0, 0);
                outTex.Apply();
                RenderTexture.active = prev;
                RenderTexture.ReleaseTemporary(rt);

                File.WriteAllBytes(dest, outTex.EncodeToPNG());
                UnityEngine.Object.Destroy(outTex);
            }
            catch { /* leave it to Godot's glyph fallback */ }
        }
    }
}
