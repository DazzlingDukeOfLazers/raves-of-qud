using System.IO;
using System.Threading;
using Kobold;      // SpriteManager
using UnityEngine; // Sprite, Texture2D, RenderTexture, Graphics, Rect, Mathf, Vector2

namespace RavesOfQud
{
    /// <summary>
    /// Main-thread tile export pump — Harmony-free.
    ///
    /// Harmony's runtime method-patching is BLOCKED on Apple Silicon macOS
    /// (mprotect EACCES), so we can't patch GameManager.LateUpdate. Instead
    /// BridgePart calls <see cref="Pump"/> from HandleEvent(BeforeRenderEvent).
    ///
    /// We can't assume that handler runs on Unity's main/render thread, and Unity
    /// graphics off the main thread crashes hard. So every call is GUARDED: the
    /// atlas readback runs only when we're demonstrably on Unity's main thread
    /// (its SynchronizationContext is installed only there). Off the main thread
    /// we no-op — never crash. The one-time log line reports which it is.
    /// </summary>
    public static class TileExportPump
    {
        private const int PerFrame = 8; // throttle so a fresh zone doesn't hitch
        private static int _logged;

        public static bool OnUnityMainThread()
        {
            var ctx = SynchronizationContext.Current;
            return ctx != null && ctx.GetType().Name == "UnitySynchronizationContext";
        }

        public static void Pump()
        {
            bool main = OnUnityMainThread();
            if (Interlocked.Exchange(ref _logged, 1) == 0)
                System.Console.WriteLine($"[raves] BeforeRender on Unity main thread = {main}");
            if (!main) return;

            for (int i = 0; i < PerFrame; i++)
            {
                if (!TileExporter.Pending.TryDequeue(out string path)) break;
                try { Export(path); } catch { /* leave it to Godot's glyph fallback */ }
            }
        }

        private static void Export(string tilePath)
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
    }
}
