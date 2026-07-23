using System;
using System.Collections.Generic;
using System.IO;
using Kobold;      // SpriteManager (Assets/Kobold/Kobold.SpriteManager.cs) — static tile API
using UnityEngine; // Sprite, Texture2D, RenderTexture, Graphics, Rect, Mathf

namespace RavesOfQud
{
    /// <summary>
    /// Engine-assisted tile export. Runs INSIDE Qud on the main thread, so it can
    /// ask <c>Kobold.SpriteManager</c> for a tile's atlas sprite and read its
    /// pixels via a GPU readback (atlas textures aren't CPU-readable). Writes one
    /// PNG per distinct tile into a shared folder the Godot client loads.
    ///
    /// On-demand + cached + resumable + per-tile try/catch: a tile that fails to
    /// export simply isn't written, and Godot falls back to the ASCII glyph.
    ///
    /// Verified API (reflection): SpriteManager.GetUnitySprite(string) -> Sprite
    /// is static; Sprite.texture is the atlas, Sprite.textureRect the pixel rect.
    /// </summary>
    public static class TileExporter
    {
        // Marked as "seen" (not necessarily written) so a failing tile isn't
        // retried on every turn.
        private static readonly HashSet<string> _seen = new HashSet<string>();
        private static string _dir;

        /// <summary>Shared output dir; also sent to Godot in each snapshot.</summary>
        public static string Dir
        {
            get
            {
                if (_dir == null)
                {
                    string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                    _dir = Path.Combine(home, "Library", "Application Support", "RavesOfQud", "tiles");
                    Directory.CreateDirectory(_dir);
                }
                return _dir;
            }
        }

        /// <summary>tile path -> flat filename (must match the Godot side).</summary>
        public static string FileFor(string tilePath) =>
            tilePath.Replace('/', '_').Replace('\\', '_').Replace(':', '_');

        /// <summary>Export one tile if not already on disk. Silent on any failure.</summary>
        public static void Ensure(string tilePath)
        {
            if (string.IsNullOrEmpty(tilePath) || !_seen.Add(tilePath)) return;

            try
            {
                string dest = Path.Combine(Dir, FileFor(tilePath));
                if (File.Exists(dest)) return;

                Sprite sp = SpriteManager.GetUnitySprite(tilePath);
                if (sp == null || sp.texture == null) return;

                Texture2D atlas = sp.texture;
                Rect tr = sp.textureRect;
                int w = Mathf.RoundToInt(tr.width);
                int h = Mathf.RoundToInt(tr.height);
                int x = Mathf.RoundToInt(tr.x);
                int y = Mathf.RoundToInt(tr.y);
                if (w <= 0 || h <= 0) return;

                // Blit the atlas into a RenderTexture, then read back just our rect.
                RenderTexture rt = RenderTexture.GetTemporary(
                    atlas.width, atlas.height, 0,
                    RenderTextureFormat.ARGB32, RenderTextureReadWrite.Linear);
                Graphics.Blit(atlas, rt);

                RenderTexture prev = RenderTexture.active;
                RenderTexture.active = rt;
                var outTex = new Texture2D(w, h, TextureFormat.RGBA32, false);
                outTex.ReadPixels(new Rect(x, y, w, h), 0, 0);
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
