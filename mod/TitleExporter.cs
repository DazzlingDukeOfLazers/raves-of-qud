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
                string chromeDump = Path.Combine(Dir, "chrome_dump.txt");
                if (File.Exists(bgPath) && File.Exists(logoPath) && File.Exists(chromeDump)) return;

                Qud.UI.MainMenu[] menus = Resources.FindObjectsOfTypeAll<Qud.UI.MainMenu>();
                if (menus == null || menus.Length == 0) return;   // not loaded yet
                Qud.UI.MainMenu menu = menus[0];

                if (!File.Exists(bgPath)) ExportBackground(menu, bgPath);
                if (!File.Exists(logoPath) && menu.logoFader != null)
                    WriteGraphicSprite(menu.logoFader.GetComponentInChildren<Image>(true), logoPath);
                if (!File.Exists(chromeDump)) ExportChrome(menu, chromeDump);

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

        /// Dump the centred menu-box subtree (the gilded frame + hieroglyph header live under
        /// <c>centerTransform</c>, wrapped by <c>leftFader</c>) and export every Image sprite it
        /// finds, so Raves can reconstruct the frame 1:1. The dump records each element's sprite
        /// name, source rect, 9-SLICE border (Sprite.border — the margins Raves needs for a
        /// StyleBoxTexture), Image.type, colour, and laid-out rect, so we can tell the sliced
        /// frame from the header glyphs from the option scroller without guessing. One-shot.
        private static void ExportChrome(Qud.UI.MainMenu menu, string dumpPath)
        {
            var sb = new System.Text.StringBuilder();
            string dir = Path.Combine(Dir, "chrome");
            Directory.CreateDirectory(dir);
            var seen = new System.Collections.Generic.HashSet<Sprite>();
            Transform[] roots = {
                menu.centerTransform,
                menu.leftFader != null ? menu.leftFader.transform : null,
            };
            foreach (Transform root in roots)
            {
                if (root == null) continue;
                sb.AppendLine("ROOT " + PathOf(root));
                WalkDump(root, sb, dir, seen);
                sb.AppendLine();
            }
            File.WriteAllText(dumpPath, sb.ToString());
            System.Console.WriteLine("[raves] chrome dump -> " + dumpPath + " (" + seen.Count + " sprites)");
        }

        private static void WalkDump(Transform t, System.Text.StringBuilder sb, string dir,
                                     System.Collections.Generic.HashSet<Sprite> seen)
        {
            foreach (Transform c in t)
            {
                string path = PathOf(c);
                var rt = c as RectTransform;
                Vector2 sz = rt != null ? rt.rect.size : Vector2.zero;
                Image img = c.GetComponent<Image>();
                RawImage raw = c.GetComponent<RawImage>();
                if (img != null)
                {
                    Sprite sp = img.sprite;
                    string sn = sp != null ? sp.name : "(null)";
                    Vector4 bd = sp != null ? sp.border : Vector4.zero;   // l, b, r, t
                    Rect trc = sp != null ? sp.textureRect : new Rect();
                    sb.AppendLine(string.Format(
                        "IMG {0} active={1} type={2} sprite={3} src={4}x{5} border=({6},{7},{8},{9}) rect={10}x{11} color={12}",
                        path, c.gameObject.activeInHierarchy, img.type, sn,
                        (int)trc.width, (int)trc.height, bd.x, bd.y, bd.z, bd.w,
                        (int)sz.x, (int)sz.y, "#" + ColorUtility.ToHtmlStringRGBA(img.color)));
                    if (sp != null && sp.texture != null && seen.Add(sp))
                        WriteSprite(sp, Path.Combine(dir, Sanitize(sn) + ".png"));
                }
                else if (raw != null)
                {
                    string tn = raw.texture != null ? raw.texture.name : "(null)";
                    sb.AppendLine(string.Format("RAW {0} active={1} tex={2} rect={3}x{4}",
                        path, c.gameObject.activeInHierarchy, tn, (int)sz.x, (int)sz.y));
                    if (raw.texture is Texture2D t2)
                        WriteRegion(t2, new Rect(0, 0, t2.width, t2.height),
                            Path.Combine(dir, Sanitize(c.name) + ".png"));
                }
                else
                {
                    sb.AppendLine(string.Format("--- {0} rect={1}x{2}", path, (int)sz.x, (int)sz.y));
                }
                WalkDump(c, sb, dir, seen);
            }
        }

        private static string PathOf(Transform t)
        {
            string p = t.name;
            for (Transform u = t.parent; u != null && u.GetComponent<Qud.UI.MainMenu>() == null; u = u.parent)
                p = u.name + "/" + p;
            return p;
        }

        private static string Sanitize(string s)
        {
            if (string.IsNullOrEmpty(s)) return "unnamed";
            foreach (char ch in Path.GetInvalidFileNameChars()) s = s.Replace(ch, '_');
            return s.Replace(' ', '_');
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
