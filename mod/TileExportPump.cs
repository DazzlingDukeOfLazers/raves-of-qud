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

        public static void Export(string tilePath)
        {
            if (Interlocked.Exchange(ref _logged, 1) == 0)
                System.Console.WriteLine($"[raves] uiQueue task on Unity main thread = {OnUnityMainThread()}");
            if (!OnUnityMainThread()) return; // never do graphics off the main thread

            try
            {
                string dest = Path.Combine(TileExporter.Dir, TileExporter.FileFor(tilePath));
                if (File.Exists(dest)) return;

                Sprite sp = SpriteManager.GetUnitySprite(tilePath);
                if (sp == null || sp.texture == null) return;

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
