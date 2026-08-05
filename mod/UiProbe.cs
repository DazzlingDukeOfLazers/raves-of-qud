using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using TMPro;
using UnityEngine;
using UnityEngine.UI;

namespace RavesOfQud
{
    /// <summary>
    /// Dumps a live Qud screen's LAYOUT MODEL — every RectTransform's screen rect, plus the text,
    /// font size and colour of anything that draws glyphs — to JSON in the support dir.
    ///
    /// WHY THIS AND NOT PIXEL MEASUREMENT: docs/decisions/1to1-measurement-and-layout.md is blunt
    /// about where the thrash came from — chasing pixel offsets, nudging a constant, rebuilding
    /// (~90s), re-measuring. The cure is to reproduce Qud's layout MODEL in one build and then set
    /// one calibration constant. Qud's model is not something to infer from a screenshot: it is
    /// sitting right here in the RectTransforms, exact and free of the value-dependent glyph-width
    /// contamination that fooled the top-bar pass.
    ///
    /// Coordinates come out in SCREEN PIXELS with a TOP-LEFT origin, i.e. the same space as an
    /// `hv shot` capture (both windows render at 1x, so capture px == Qud px), so a dump can be
    /// compared against a capture directly with no conversion step to get wrong.
    /// </summary>
    public static class UiProbe
    {
        public static string Dir => Path.Combine(
            Directory.GetParent(TileExporter.Dir).FullName, "probe");

        private static void Log(string s)
        {
            System.Console.WriteLine("[raves] uiprobe: " + s);
            try { Bridge.Server?.Log("uiprobe: " + s); } catch { }
        }

        /// <summary>UNITY MAIN THREAD. `target` names the screen: "picker" today; anything else is
        /// matched as a substring against root GameObject names, so a new screen needs no code.</summary>
        public static void Dump(string target)
        {
            try
            {
                GameObject root = Resolve(target);
                if (root == null) { Log("no live screen matching '" + target + "'"); return; }

                Directory.CreateDirectory(Dir);
                var sb = new StringBuilder();
                sb.Append("{\"target\":\"").Append(Esc(target)).Append("\",\"root\":\"")
                  .Append(Esc(root.name)).Append("\",\"screen\":[")
                  .Append(Screen.width).Append(',').Append(Screen.height).Append("],\"nodes\":[");
                int n = 0;
                Walk(root.transform, 0, sb, ref n);
                sb.Append("]}");
                string path = Path.Combine(Dir, "ui_" + Safe(target) + ".json");
                File.WriteAllText(path, sb.ToString());
                Log("dumped " + n + " nodes -> " + path);
            }
            catch (Exception e) { Log("failed: " + e); }
        }


        /// <summary>UNITY MAIN THREAD. Export a live screen's chrome sprites by pulling them off the
        /// Image components themselves.
        ///
        /// WHY NOT TitleExporter.ExportNamedSprite: that scans Resources.FindObjectsOfTypeAll&lt;Sprite&gt;()
        /// for a name match, and these live in a SpriteAtlas — the Image's sprite is a runtime instance
        /// the global scan never sees, so the lookup silently found nothing and wrote no file. Reading
        /// the sprite off the component that is drawing it cannot miss.</summary>
        public static void ExportChrome(string target)
        {
            try
            {
                GameObject root = Resolve(target);
                if (root == null) { Log("no live screen matching '" + target + "' for chrome"); return; }
                int n = 0;
                foreach (var img in root.GetComponentsInChildren<Image>(true))
                {
                    if (img == null || img.sprite == null) continue;
                    string nm = img.sprite.name;
                    string dest = null;
                    if (nm == "polat-char-frame-border") dest = "picker_frame.png";
                    else if (nm == "polat-frame-reverse-top-header-filler") dest = "picker_divider.png";
                    if (dest == null) continue;
                    TitleExporter.WriteSprite(img.sprite, Path.Combine(TileExporter.Dir, dest));
                    // The 9-SLICE BORDER, without which the client has to guess where to cut the
                    // sprite — and a guessed inset shows up as a smeared or doubled frame edge.
                    var b = img.sprite.border;
                    File.WriteAllText(Path.Combine(TileExporter.Dir, dest + ".json"),
                        "{\"border\":[" + F(b.x) + "," + F(b.y) + "," + F(b.z) + "," + F(b.w) +
                        "],\"type\":\"" + img.type + "\",\"ppu\":" + F(img.sprite.pixelsPerUnit) + "}");
                    Log("chrome '" + nm + "' -> " + dest + " border=" + b);
                    n++;
                }
                if (n == 0) Log("no known chrome sprites on '" + target + "'");
            }
            catch (Exception e) { Log("chrome export failed: " + e); }
        }

        private static GameObject Resolve(string target)
        {
            try
            {
                if (string.Equals(target, "picker", StringComparison.OrdinalIgnoreCase))
                {
                    var sc = Qud.UI.PickGameObjectScreen.instance;
                    return (sc != null && sc.Visible) ? sc.gameObject : null;
                }
                foreach (var go in UnityEngine.Object.FindObjectsOfType<GameObject>())
                {
                    if (go == null || !go.activeInHierarchy) continue;
                    if (go.GetComponent<RectTransform>() == null) continue;
                    if (go.name.IndexOf(target, StringComparison.OrdinalIgnoreCase) >= 0) return go;
                }
            }
            catch { }
            return null;
        }

        private static readonly Vector3[] _corners = new Vector3[4];

        private static void Walk(Transform t, int depth, StringBuilder sb, ref int n)
        {
            if (t == null || depth > 24) return;
            var rt = t as RectTransform;
            if (rt != null)
            {
                rt.GetWorldCorners(_corners);
                float xmin = _corners[0].x, xmax = _corners[0].x;
                float ymin = _corners[0].y, ymax = _corners[0].y;
                for (int i = 1; i < 4; i++)
                {
                    if (_corners[i].x < xmin) xmin = _corners[i].x;
                    if (_corners[i].x > xmax) xmax = _corners[i].x;
                    if (_corners[i].y < ymin) ymin = _corners[i].y;
                    if (_corners[i].y > ymax) ymax = _corners[i].y;
                }
                // Unity's screen space is bottom-up; captures are top-down. Flip here, once, rather
                // than in every consumer.
                float top = Screen.height - ymax;

                if (n++ > 0) sb.Append(',');
                sb.Append("{\"d\":").Append(depth)
                  .Append(",\"name\":\"").Append(Esc(t.name)).Append('"')
                  .Append(",\"on\":").Append(t.gameObject.activeInHierarchy ? "true" : "false")
                  .Append(",\"x\":").Append(F(xmin)).Append(",\"y\":").Append(F(top))
                  .Append(",\"w\":").Append(F(xmax - xmin)).Append(",\"h\":").Append(F(ymax - ymin));

                // Text: what it says, how big, what colour — the three things a parity pass needs and
                // the three a screenshot reports least reliably.
                var tmp = t.GetComponent<TMP_Text>();
                if (tmp != null)
                {
                    sb.Append(",\"text\":\"").Append(Esc(Trim(tmp.text))).Append('"')
                      .Append(",\"font\":").Append(F(tmp.fontSize))
                      .Append(",\"color\":\"").Append(Hex(tmp.color)).Append('"')
                      .Append(",\"align\":\"").Append(Esc(tmp.alignment.ToString())).Append('"');
                    if (tmp.font != null)
                        sb.Append(",\"face\":\"").Append(Esc(tmp.font.name)).Append('"');
                }
                var img = t.GetComponent<Image>();
                if (img != null)
                {
                    sb.Append(",\"img\":\"").Append(Esc(img.sprite != null ? img.sprite.name : "<none>"))
                      .Append("\",\"imgColor\":\"").Append(Hex(img.color)).Append('"');
                }
                sb.Append('}');
            }
            for (int i = 0; i < t.childCount; i++) Walk(t.GetChild(i), depth + 1, sb, ref n);
        }

        private static string Trim(string s)
        {
            if (string.IsNullOrEmpty(s)) return "";
            return s.Length > 120 ? s.Substring(0, 120) : s;
        }

        private static string F(float v) =>
            Math.Round(v, 2).ToString(CultureInfo.InvariantCulture);

        private static string Hex(Color c) => string.Format(
            "#{0:x2}{1:x2}{2:x2}{3:x2}",
            (int)(Mathf.Clamp01(c.r) * 255f), (int)(Mathf.Clamp01(c.g) * 255f),
            (int)(Mathf.Clamp01(c.b) * 255f), (int)(Mathf.Clamp01(c.a) * 255f));

        private static string Safe(string s)
        {
            var sb = new StringBuilder();
            foreach (char c in s) sb.Append(char.IsLetterOrDigit(c) ? c : '_');
            return sb.ToString();
        }

        private static string Esc(string s)
        {
            if (s == null) return "";
            var sb = new StringBuilder();
            foreach (char c in s)
            {
                if (c == '"' || c == '\\') sb.Append('\\').Append(c);
                else if (c == '\n') sb.Append("\\n");
                else if (c == '\r') sb.Append("\\r");
                else if (c == '\t') sb.Append("\\t");
                else if (c < ' ') sb.Append("\\u").Append(((int)c).ToString("x4"));
                else sb.Append(c);
            }
            return sb.ToString();
        }
    }
}
