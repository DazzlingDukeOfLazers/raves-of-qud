using System.IO;
using HarmonyLib;
using Kobold;      // SpriteManager
using UnityEngine; // Sprite, Texture2D, RenderTexture, Graphics, Rect, Mathf, Vector2

namespace RavesOfQud
{
    /// <summary>
    /// Main-thread export pump. A Harmony postfix on <c>GameManager.LateUpdate</c>
    /// (which Unity calls every frame on the MAIN thread) drains
    /// <see cref="TileExporter.Pending"/> and does the actual atlas readback +
    /// PNG write here — the only place Unity graphics calls are legal.
    ///
    /// Why here and not in Bridge.Tick: Qud runs turn logic on a background thread;
    /// graphics there crashes ("Graphics device is null"). LateUpdate is main-thread.
    /// Because export happens ONLY in this postfix, the turn thread stays
    /// graphics-free and cannot crash even if this patch fails to apply.
    ///
    /// Qud auto-applies mod [HarmonyPatch] classes (ApplyHarmonyPatches).
    /// </summary>
    [HarmonyPatch(typeof(GameManager), "LateUpdate")]
    public static class TileExportPump
    {
        private const int PerFrame = 8; // throttle so a fresh zone's tiles don't hitch

        private static void Postfix()
        {
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
