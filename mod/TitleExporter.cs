using System;
using System.IO;
using System.Threading;
using UnityEngine;      // Sprite, Texture2D, RenderTexture, Graphics, Rect, Mathf, Vector2
using UnityEngine.UI;   // Image, RawImage

namespace RavesOfQud
{
    /// <summary>
    /// Export Caves of Qud's title-screen art (background + logo) so Raves' own menu can
    /// render the REAL assets from the player's install — never redistributed.
    ///
    /// Qud's <c>Qud.UI.MainMenu</c> textures load at startup and stay RESIDENT; the
    /// MainMenu GameObject just goes INACTIVE once you're in a game. So from the mod's
    /// normal in-game hook we find it via <c>Resources.FindObjectsOfTypeAll</c> (which
    /// returns inactive objects, unlike FindObjectOfType), read its still-loaded sprites,
    /// and blit → readback → PNG them (the same path as <see cref="TileExportPump"/>).
    /// One-shot per session, skipped if the files already exist.
    ///
    /// THREADING: <see cref="Ensure"/> is turn-thread safe (enqueue only); the actual
    /// Unity graphics run on the main thread via GameManager.uiQueue, same rule as tiles.
    /// </summary>
    public static class TitleExporter
    {
        private static int _tried;    // one enqueue per session (retried until GM is ready)
        private static string _dir;

        public static string Dir
        {
            get
            {
                if (_dir == null)
                {
                    string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                    _dir = Path.Combine(home, "Library", "Application Support", "RavesOfQud", "title");
                    Directory.CreateDirectory(_dir);
                }
                return _dir;
            }
        }

        /// <summary>Turn-thread safe: queue the export onto Unity's main thread, once.</summary>
        public static void Ensure()
        {
            if (Interlocked.Exchange(ref _tried, 1) != 0) return;
            GameManager gm = GameManager.Instance;
            if (gm == null || gm.uiQueue == null) { _tried = 0; return; }  // not ready — retry next turn
            gm.uiQueue.queueTask(Export, 0);
        }

        private static void Export()
        {
            try
            {
                string bgPath = Path.Combine(Dir, "background.png");
                string logoPath = Path.Combine(Dir, "logo.png");
                if (File.Exists(bgPath) && File.Exists(logoPath)) return;

                Qud.UI.MainMenu[] menus = Resources.FindObjectsOfTypeAll<Qud.UI.MainMenu>();
                if (menus == null || menus.Length == 0) return;   // not loaded yet
                Qud.UI.MainMenu menu = menus[0];

                if (!File.Exists(bgPath)) ExportBackground(menu, bgPath);
                if (!File.Exists(logoPath) && menu.logoFader != null)
                    WriteGraphicSprite(menu.logoFader.GetComponentInChildren<Image>(true), logoPath);

                System.Console.WriteLine("[raves] title art exported -> " + Dir);
            }
            catch (Exception e)
            {
                System.Console.WriteLine("[raves] title export failed: " + e.Message);
            }
        }

        /// The single `background` Image, else the active `backgrounds[]` object's graphic.
        private static void ExportBackground(Qud.UI.MainMenu menu, string dest)
        {
            if (menu.background != null && menu.background.sprite != null)
            {
                WriteSprite(menu.background.sprite, dest);
                return;
            }
            if (menu.backgrounds == null) return;
            GameObject pick = null;
            foreach (GameObject go in menu.backgrounds)
            {
                if (go == null) continue;
                if (go.activeSelf) { pick = go; break; }   // Modern/Classic per option
                if (pick == null) pick = go;               // fallback: first available
            }
            if (pick == null) return;
            Image img = pick.GetComponentInChildren<Image>(true);
            if (img != null && img.sprite != null) { WriteSprite(img.sprite, dest); return; }
            RawImage raw = pick.GetComponentInChildren<RawImage>(true);
            if (raw != null && raw.texture is Texture2D t2)
                WriteRegion(t2, new Rect(0, 0, t2.width, t2.height), dest);
        }

        private static void WriteGraphicSprite(Image img, string dest)
        {
            if (img != null && img.sprite != null) WriteSprite(img.sprite, dest);
        }

        private static void WriteSprite(Sprite sp, string dest)
        {
            if (sp == null || sp.texture == null) return;
            WriteRegion(sp.texture, sp.textureRect, dest);
        }

        /// Scaled blit of just this region into an RT, readback, PNG (no full-atlas alloc).
        private static void WriteRegion(Texture tex, Rect r, string dest)
        {
            int w = Mathf.RoundToInt(r.width);
            int h = Mathf.RoundToInt(r.height);
            if (w <= 0 || h <= 0) return;
            RenderTexture rt = RenderTexture.GetTemporary(
                w, h, 0, RenderTextureFormat.ARGB32, RenderTextureReadWrite.Linear);
            Vector2 scale = new Vector2(r.width / tex.width, r.height / tex.height);
            Vector2 offset = new Vector2(r.x / tex.width, r.y / tex.height);
            Graphics.Blit(tex, rt, scale, offset);

            RenderTexture prev = RenderTexture.active;
            RenderTexture.active = rt;
            Texture2D outTex = new Texture2D(w, h, TextureFormat.RGBA32, false);
            outTex.ReadPixels(new Rect(0, 0, w, h), 0, 0);
            outTex.Apply();
            RenderTexture.active = prev;
            RenderTexture.ReleaseTemporary(rt);

            File.WriteAllBytes(dest, outTex.EncodeToPNG());
            UnityEngine.Object.Destroy(outTex);
        }
    }
}
