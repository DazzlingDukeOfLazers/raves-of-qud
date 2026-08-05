using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using TMPro;                 // TMP_FontAsset, TMP_Character
using UnityEngine;           // Texture2D, RenderTexture, Graphics, Color32
using UnityEngine.TextCore;  // Glyph, GlyphRect, GlyphMetrics, FaceInfo

namespace RavesOfQud
{
    /// <summary>
    /// Extracts Qud's INPUT-GLYPH font — the keycap/stick icons it draws for Ctrl, Shift, LMB, the
    /// navigation keys and friends — into a BMFont Raves can load as a text fallback.
    ///
    /// WHY: Qud emits those icons as PRIVATE USE AREA codepoints (ControlManager returns "" for
    /// NavigationXYAxis, and swaps "Ctrl"→"", "Shift"→"", "LMB"→"" …) and draws them
    /// from its own TMP font. Raves renders with Source Code Pro, which has nothing at U+E8xx, so every
    /// one came out as a tofu "?" — the picker's footer bar literally read "[?] navigate". Substituting
    /// words for them was a legibility patch; this is the actual glyph.
    ///
    /// WHY A WHOLE-RANGE SCAN, not the seven codepoints we know: the ones we have met are the ones that
    /// happened to appear on screens mirrored so far. Sweeping U+E000..U+F8FF across every loaded font
    /// means the next screen's glyph is already in the fallback instead of being another tofu bug.
    ///
    /// The fonts are inside Unity's asset files (there is no .ttf on disk to copy), so extraction has to
    /// happen from INSIDE the running game — atlas texture + glyph rects + face metrics, written out as
    /// a BMFont page. Output lives in the SUPPORT DIR with the other extracted assets; it is never
    /// redistributed with the repo.
    /// </summary>
    public static class GlyphExporter
    {
        private const uint PUA_LO = 0xE000, PUA_HI = 0xF8FF;
        private const int PAGE_W = 512;
        private const int GUTTER = 2;

        // Sibling of the tiles dir — TileExporter.Dir is <support>/tiles, so its parent is <support>.
        public static string Dir => Path.Combine(
            Directory.GetParent(TileExporter.Dir).FullName, "glyphs");
        private static string PngPath => Path.Combine(Dir, "qud_glyphs.png");
        private static string FntPath => Path.Combine(Dir, "qud_glyphs.fnt");

        private static void Log(string s)
        {
            System.Console.WriteLine("[raves] glyphs: " + s);
            try { Bridge.Server?.Log("glyphs: " + s); } catch { }
        }

        /// <summary>Export unless it's already there. Called on the first in-game tick so a normal
        /// session gets the fallback without anyone asking for it.</summary>
        public static void EnsureExported()
        {
            try { if (File.Exists(PngPath) && File.Exists(FntPath)) return; } catch { }
            Export();
        }

        /// <summary>UNITY MAIN THREAD ONLY (graphics calls). Scan every loaded TMP font for PUA
        /// characters, blit each glyph out of its atlas, and write a BMFont page.</summary>
        public static void Export()
        {
            try
            {
                var picked = new SortedDictionary<uint, Entry>();
                var fonts = Resources.FindObjectsOfTypeAll<TMP_FontAsset>();
                if (fonts == null || fonts.Length == 0) { Log("no TMP_FontAsset loaded yet"); return; }

                foreach (var fa in fonts)
                {
                    if (fa == null) continue;
                    Dictionary<uint, TMP_Character> table;
                    try { table = fa.characterLookupTable; } catch { continue; }
                    if (table == null) continue;
                    int hits = 0;
                    foreach (var kv in table)
                    {
                        uint cp = kv.Key;
                        if (cp < PUA_LO || cp > PUA_HI) continue;
                        var ch = kv.Value;
                        if (ch == null || ch.glyph == null) continue;
                        var gr = ch.glyph.glyphRect;
                        if (gr.width <= 0 || gr.height <= 0) continue;
                        hits++;
                        // THE GLYPH'S OWN ASSET, not the table we found it in. A font's
                        // characterLookupTable also carries characters served by its FALLBACKS, whose
                        // pixels live in the fallback's atlas — reading those rects out of `fa` samples
                        // a completely different texture. That is exactly how U+E80A (the picker's
                        // "navigate") came out as a '#' plus a fragment of its neighbour.
                        var owner = ch.textAsset as TMP_FontAsset ?? fa;
                        // Prefer a BIGGER rendering of the same codepoint: several assets carry the same
                        // icon at different atlas sizes, and the small one goes mushy once Godot scales
                        // it up to body-text size.
                        if (picked.TryGetValue(cp, out var prev) &&
                            prev.Ch.glyph.glyphRect.height >= gr.height) continue;
                        picked[cp] = new Entry { Font = owner, Ch = ch };
                    }
                    if (hits > 0) Log(string.Format("{0}: {1} PUA glyphs, atlas {2}x{3} {4} pad={5}",
                        fa.name, hits, fa.atlasWidth, fa.atlasHeight, fa.atlasRenderMode, fa.atlasPadding));
                }

                if (picked.Count == 0) { Log("no PUA glyphs in any loaded font"); return; }
                Directory.CreateDirectory(Dir);
                WritePage(picked);
            }
            catch (Exception e) { Log("export failed: " + e); }
        }

        private struct Entry { public TMP_FontAsset Font; public TMP_Character Ch; }

        private static void WritePage(SortedDictionary<uint, Entry> picked)
        {
            // ---- ONE scale for the whole page. The glyphs come from several font assets, and those
            // are rasterised at different point sizes (we've seen 201 and 120 side by side). Qud draws
            // each at the text's size, so relative to each other they'd be wrong here unless the
            // smaller font's glyphs are scaled up to match. A bitmap font has a single nominal size,
            // so normalise everything onto the largest.
            float target = 0f;
            foreach (var kv in picked)
            {
                float ps = kv.Value.Font.faceInfo.pointSize;
                if (ps > target) target = ps;
            }
            if (target <= 0f) target = 32f;

            // ---- lay the glyphs out, row-major, before touching the GPU
            var placed = new List<Placed>();
            int px = GUTTER, py = GUTTER, rowH = 0, pageH = 0;
            foreach (var kv in picked)
            {
                var gr = kv.Value.Ch.glyph.glyphRect;
                float ps = kv.Value.Font.faceInfo.pointSize;
                float k = (ps > 0f) ? target / ps : 1f;
                int w = Math.Max(1, Mathf.RoundToInt(gr.width * k));
                int h = Math.Max(1, Mathf.RoundToInt(gr.height * k));
                if (px + w + GUTTER > PAGE_W) { px = GUTTER; py += rowH + GUTTER; rowH = 0; }
                placed.Add(new Placed { Cp = kv.Key, E = kv.Value, X = px, Y = py, W = w, H = h, K = k });
                px += w + GUTTER;
                if (h > rowH) rowH = h;
                if (py + h + GUTTER > pageH) pageH = py + h + GUTTER;
            }
            _target = target;

            var page = new Color32[PAGE_W * pageH];   // transparent by default

            int copied = 0, empty = 0;
            byte lo = 255, hi = 0;
            foreach (var p in placed)
            {
                var atlas = p.E.Font.atlasTexture;
                if (atlas == null) { empty++; continue; }
                var gr = p.E.Ch.glyph.glyphRect;

                // Same readback shape as TileExportPump: a scaled Blit of just this rect into a small
                // RT, because the atlas itself is a GPU texture with no CPU-side pixels to read.
                // The UV window is the glyph's rect in the SOURCE atlas; the RT's size is the
                // DESTINATION size, so a p.W/p.H bigger than the rect resamples the glyph up on the
                // GPU. (These were the same number before point-size normalisation — keeping them
                // tied would silently crop instead of scale.)
                RenderTexture rt = RenderTexture.GetTemporary(
                    p.W, p.H, 0, RenderTextureFormat.ARGB32, RenderTextureReadWrite.Linear);
                var scale = new Vector2((float)gr.width / atlas.width, (float)gr.height / atlas.height);
                var offset = new Vector2((float)gr.x / atlas.width, (float)gr.y / atlas.height);
                Graphics.Blit(atlas, rt, scale, offset);

                RenderTexture prev = RenderTexture.active;
                RenderTexture.active = rt;
                var tmp = new Texture2D(p.W, p.H, TextureFormat.RGBA32, false);
                tmp.ReadPixels(new Rect(0, 0, p.W, p.H), 0, 0);
                tmp.Apply();
                RenderTexture.active = prev;
                RenderTexture.ReleaseTemporary(rt);

                var src = tmp.GetPixels32();
                UnityEngine.Object.Destroy(tmp);

                // An SDF atlas stores a DISTANCE, not coverage: 0.5 is the edge. Copying it straight
                // out gives a grey smear, so threshold it back to a hard mask. A SMOOTH/RASTER atlas
                // already holds antialiased coverage and is copied as-is.
                bool sdf = p.E.Font.atlasRenderMode.ToString().IndexOf("SDF", StringComparison.OrdinalIgnoreCase) >= 0;
                bool any = false;
                for (int yy = 0; yy < p.H; yy++)
                {
                    for (int xx = 0; xx < p.W; xx++)
                    {
                        var c = src[yy * p.W + xx];
                        // Qud's atlases are single-channel; whichever channel carries it, take the max
                        // so we can't silently read a zeroed one and write a blank page.
                        byte a = Math.Max(c.a, Math.Max(c.r, Math.Max(c.g, c.b)));
                        if (a < lo) lo = a;
                        if (a > hi) hi = a;
                        if (sdf) a = (byte)(a >= 128 ? 255 : 0);
                        if (a != 0) any = true;
                        // The page is drawn top-down; the atlas rect is bottom-up (Unity texture space).
                        int dx = p.X + xx;
                        int dy = p.Y + (p.H - 1 - yy);
                        page[dy * PAGE_W + dx] = new Color32(255, 255, 255, a);
                    }
                }
                if (any) copied++; else empty++;
            }

            var outTex = new Texture2D(PAGE_W, pageH, TextureFormat.RGBA32, false);
            // Texture2D is bottom-up; our page array is top-down, so flip on the way in.
            var flipped = new Color32[page.Length];
            for (int y = 0; y < pageH; y++)
                Array.Copy(page, y * PAGE_W, flipped, (pageH - 1 - y) * PAGE_W, PAGE_W);
            outTex.SetPixels32(flipped);
            outTex.Apply();
            File.WriteAllBytes(PngPath, outTex.EncodeToPNG());
            UnityEngine.Object.Destroy(outTex);

            WriteFnt(placed, pageH);
            Log(string.Format("wrote {0} glyphs ({1} blank), page {2}x{3}, alpha {4}..{5} -> {6}",
                copied, empty, PAGE_W, pageH, lo, hi, Dir));
        }

        private struct Placed { public uint Cp; public Entry E; public int X, Y, W, H; public float K; }

        private static float _target = 32f;   // the page's nominal point size (largest source font)

        /// BMFont text format, which is what Godot's FontFile.load_bitmap_font() parses.
        private static void WriteFnt(List<Placed> placed, int pageH)
        {
            var inv = CultureInfo.InvariantCulture;
            int size = Math.Max(1, (int)Math.Round(_target));
            // ONE baseline for the page. Glyphs come from fonts with different ascents, so each
            // yoffset is measured against the tallest scaled ascent — otherwise icons from the two
            // fonts would sit at different heights on the same line of text.
            float ascent = 0f, lineH = 0f;
            foreach (var p in placed)
            {
                var fi = p.E.Font.faceInfo;
                if (fi.ascentLine * p.K > ascent) ascent = fi.ascentLine * p.K;
                if (fi.lineHeight * p.K > lineH) lineH = fi.lineHeight * p.K;
            }
            int line = (int)Math.Round(lineH <= 0 ? size : lineH);
            int baseline = (int)Math.Round(ascent <= 0 ? size : ascent);

            var sb = new StringBuilder();
            sb.Append("info face=\"QudGlyphs\" size=").Append(size)
              .Append(" bold=0 italic=0 charset=\"\" unicode=1 stretchH=100 smooth=1 aa=1 ")
              .Append("padding=0,0,0,0 spacing=0,0\n");
            // CHANNEL SEMANTICS MATTER. In BMFont these fields say what each channel HOLDS:
            // 0=glyph, 1=outline, 2=glyph+outline, 3=zero, 4=one. Our page is white pixels with the
            // coverage in alpha, so it is alphaChnl=0 (glyph) and RGB=4 (one). Declaring alphaChnl=1
            // instead — i.e. "alpha is the OUTLINE" — made Godot render every glyph as a solid filled
            // block, which looks like a broken atlas but is really a broken description of a fine one.
            sb.Append("common lineHeight=").Append(line).Append(" base=").Append(baseline)
              .Append(" scaleW=").Append(PAGE_W).Append(" scaleH=").Append(pageH)
              .Append(" pages=1 packed=0 alphaChnl=0 redChnl=4 greenChnl=4 blueChnl=4\n");
            sb.Append("page id=0 file=\"qud_glyphs.png\"\n");
            sb.Append("chars count=").Append(placed.Count).Append('\n');
            foreach (var p in placed)
            {
                GlyphMetrics m = p.E.Ch.glyph.metrics;
                // BMFont yoffset is measured DOWN from the line's top; TMP's bearingY is measured UP
                // from the baseline. Converting between them is what keeps the icon sitting on the
                // text baseline instead of floating. Metrics scale with the glyph's own pixels (K).
                int xoff = (int)Math.Round(m.horizontalBearingX * p.K);
                int yoff = (int)Math.Round(baseline - m.horizontalBearingY * p.K);
                int xadv = (int)Math.Round(m.horizontalAdvance * p.K);
                sb.Append("char id=").Append(p.Cp.ToString(inv))
                  .Append(" x=").Append(p.X).Append(" y=").Append(p.Y)
                  .Append(" width=").Append(p.W).Append(" height=").Append(p.H)
                  .Append(" xoffset=").Append(xoff).Append(" yoffset=").Append(yoff)
                  .Append(" xadvance=").Append(xadv)
                  .Append(" page=0 chnl=15\n");
            }
            File.WriteAllText(FntPath, sb.ToString());
        }
    }
}
