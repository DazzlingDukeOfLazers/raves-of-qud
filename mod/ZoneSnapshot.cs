using XRL;
using XRL.World;
using XRL.World.Effects;
using XRL.World.Parts;

namespace RavesOfQud
{
    /// <summary>
    /// Serializes the active zone into the snapshot JSON that Godot renders.
    /// Reads game state — MUST be called on the main thread (it is: via Bridge.Tick).
    ///
    /// VERIFIED against the installed 1.0 build by reflecting Assembly-CSharp.dll
    /// (MetadataLoadContext — exact signatures, not string heuristics):
    ///   The.ActiveZone -> XRL.World.Zone
    ///   Zone: fields Width, Height (int); prop ZoneID (string); GetCell(int,int) -> Cell
    ///   XRL.World.Cell: X, Y, ParentZone, Objects
    ///   GameObject.GetPart&lt;T&gt;() ; GameObject.CurrentCell (prop)
    ///   XRL.World.Parts.Render fields (CAPITALIZED): RenderString, ColorString,
    ///     DetailColor, TileColor, Tile (all string), RenderLayer (int);
    ///     Visible is a bool property (use it for FOV filtering in v2).
    ///   Water/bridge (all first-class Qud concepts, no heuristics needed):
    ///     Cell.HasBridge() / HasWadingDepthLiquid() / HasSwimmingDepthLiquid()
    ///     GameObject.HasIntProperty("Bridge")  — set by Walkway/Bridge/BrineBridge/
    ///       WoodFloor/MarbleFloor blueprints in Base/ObjectBlueprints/ZoneTerrain.xml
    ///     GameObject.IsCreature / IsFlying (properties)
    ///
    /// We emit RAW Qud color strings (e.g. "&amp;Y") and let Godot interpret them.
    /// FOV / fog-of-war filtering is intentionally deferred (v2): for now we ship
    /// every object that has a Render + non-empty glyph.
    /// </summary>
    public static class ZoneSnapshot
    {
        // Serialize time of the PREVIOUS snapshot, in microseconds. Sent as serverUs
        // so the client's profiler can Pareto server-serialize vs client-render. We
        // can't measure this turn's build until it's done and the JSON is written
        // sequentially, so we report the prior turn's — representative, one turn late.
        static int _lastBuildUs = 0;
        static string _lastCmdbarLog = "";   // de-dupes the command-bar diagnostic in Player.log

        /// <summary>
        /// Plain display name, defended against a throwing getter. DisplayName
        /// runs the full markup/adjective pipeline on some objects, and a
        /// snapshot must never be the thing that breaks someone's game.
        /// </summary>
        private static string DisplayNameOf(GameObject go)
        {
            try { return go.DisplayNameOnly ?? ""; }
            catch { return ""; }
        }

        // Qud's 16-colour palette, by ColorString character.
        private const string PaletteChars = "rRgGbBcCmMwWoOyYkK";

        /// <summary>
        /// Qud's REAL palette, straight from ConsoleLib. Base/Colors.xml names the
        /// colours but carries no RGB — the values live in code — so the client
        /// was otherwise stuck hand-estimating them, and "&amp;K" being dark grey
        /// rather than black is exactly the kind of thing a guess gets wrong.
        ///
        /// colorFromChar is a static dictionary lookup returning a struct: no
        /// graphics calls, so it is safe on the turn thread.
        /// </summary>
        private static void WritePalette(JsonWriter j)
        {
            j.Name("palette").BeginObject();
            foreach (char ch in PaletteChars)
            {
                try
                {
                    UnityEngine.Color c = ConsoleLib.Console.ColorUtility.colorFromChar(ch);
                    j.Member(ch.ToString(), Hex(c));
                }
                catch { /* a char the build doesn't map — skip it, keep the rest */ }
            }
            j.EndObject();

            // The colour Qud paints the world behind everything. Ours was an
            // estimate, and side-by-side the 3D view read black where Qud reads
            // dark teal — which flattens the whole scene. Emit the raw string too:
            // if it isn't resolvable, we want to see what it actually was.
            try
            {
                string raw = ConsoleLib.Console.ColorUtility.CAMERA_BACKGROUND ?? "";
                j.Member("bgRaw", raw);
                if (raw.Length > 0)
                {
                    UnityEngine.Color bg = raw.Length == 1
                        ? ConsoleLib.Console.ColorUtility.colorFromChar(raw[0])
                        : ConsoleLib.Console.ColorUtility.ColorFromString(raw);
                    j.Member("bg", Hex(bg));
                }
            }
            catch { /* keep the client's fallback */ }
        }

        private static string Hex(UnityEngine.Color c)
        {
            return "#" + Channel(c.r) + Channel(c.g) + Channel(c.b);
        }

        private static string Channel(float v)
        {
            int n = (int)System.Math.Round(v * 255f);
            if (n < 0) n = 0;
            if (n > 255) n = 255;
            return n.ToString("x2");
        }

        // Reused across the whole snapshot; the turn thread is the only writer.
        private static readonly ConsoleLib.Console.ConsoleChar _scratch =
            new ConsoleLib.Console.ConsoleChar();

        /// <summary>
        /// The tile Qud would actually DRAW for this object.
        ///
        /// Render.Tile is only the static blueprint value. Objects whose art is
        /// chosen at render time — grass and other ground cover — leave it empty
        /// and paint themselves through RenderTile instead, so reading the field
        /// gave "no tile", exported nothing, and the client drew a flat dot where
        /// the game shows a sprite.
        ///
        /// Falls back to the field, so anything that doesn't paint is unaffected.
        /// </summary>
        private static string ResolvedTile(GameObject go, Render r, out bool painted)
        {
            painted = false;

            // getTile() is the ACCESSOR: it resolves what the object actually
            // draws — PickRandomTile, RandomTileOnMove, harvestable states. The
            // Tile FIELD is only the blueprint's static value, and is empty for
            // anything that picks its art at runtime.
            try
            {
                string got = r.getTile();
                if (!string.IsNullOrEmpty(got)) return got;
            }
            catch { }

            // RenderTile is the OVERRIDE hook for parts that paint themselves.
            // It fires for almost nothing — kept because when it does fire it
            // also gives us resolved colours.
            try
            {
                _scratch.Clear();
                go.RenderTile(_scratch);
                string tile = _scratch.Tile;
                if (!string.IsNullOrEmpty(tile))
                {
                    painted = true;
                    return tile;
                }
            }
            catch { }

            return r.Tile ?? "";
        }

        /// <summary>
        /// The glyph the object actually draws. Same story as the tile: the
        /// RenderString FIELD can be empty while the accessor resolves one.
        /// An object with both fields empty was dropped entirely, which made its
        /// whole cell report as EMPTY.
        /// </summary>
        private static string ResolvedGlyph(Render r)
        {
            try
            {
                string got = r.getRenderString();
                if (!string.IsNullOrEmpty(got)) return got;
            }
            catch { }
            return r.RenderString ?? "";
        }

        /// <summary>
        /// Colours straight off the painted ConsoleChar: already RESOLVED to RGB,
        /// so the client needs no palette lookup and no &amp;X^Y parsing for these.
        /// Also carries Qud's own sprite flipping.
        ///
        /// Only emitted when RenderTile actually painted a tile. If it didn't, the
        /// ConsoleChar still holds whatever Clear() left, and shipping that would
        /// paint half the zone in default colours — the client keeps using the
        /// ColorString path in that case.
        /// </summary>
        private static void WritePaintedColors(JsonWriter j)
        {
            try
            {
                j.Member("fgHex", Hex(_scratch.TileForeground));
                j.Member("bgHex", Hex(_scratch.TileBackground));
                j.Member("detailHex", Hex(_scratch.Detail));
                // NB: hflip/vflip are emitted by the caller from Render.getHFlip() (the real display
                // flip); _scratch (the painted ConsoleChar) never carries it, so don't emit here — a
                // second hflip key would duplicate/override the correct one.
                if (_scratch.VFlip) j.Member("vflip", true);
            }
            catch { /* colours are an optimisation; never fail a snapshot over them */ }
        }

        private static int CountSafe(Cell c)
        {
            try { return c.GetObjectCount(); } catch { return -1; }
        }

        private static int RenderedSafe(Cell c)
        {
            try { return c.RenderedObjectsCount; } catch { return -1; }
        }

        /// <summary>
        /// Qud's PAINTED GROUND LAYER.
        ///
        /// 1103 of this zone's 2000 cells hold no GameObject at all, yet Qud's
        /// compositor still draws dirt and grass on them (Terrain/sw_grass1.bmp,
        /// tile-dirt1.png...). That layer is not in the object model, which is why
        /// it never appeared in any object query and why every fix aimed at the
        /// object path was inert.
        ///
        /// Cell.Render() composites it. We emit it as a RenderLayer 0 floor so the
        /// client draws it like any other ground.
        /// </summary>
        /// <summary>
        /// A tile path reduced to its FAMILY, for comparing "is this the same art?".
        ///
        /// This is an INDEPENDENT copy of the family reduction, by design. The two
        /// GDScript copies (ZoneRenderer.tile_family, used by the form too) are
        /// unified into one; this one is server-side and used ONLY for ground-dedup
        /// within a single snapshot. It never crosses to the client's override
        /// keying, so drift here cannot mis-apply a user rule — at worst it emits or
        /// drops one duplicate ground tile. Keep the reduction rules matching the
        /// GDScript one anyway, for consistency.</summary>
        /// <remarks>Original doc:
        /// A tile path reduced to its FAMILY, for comparing "is this the same art?".
        ///
        /// Comparing exact paths is not enough: a water wheel cell handed back
        /// `sw_waterwheel_3` from the compositor while the object drew
        /// `sw_waterwheel_1`, so the duplicate slipped through and a second wheel
        /// was laid flat under the first. Variant numbers and autotile bitmasks are
        /// both just "which picture of this thing", so both are stripped.
        /// </remarks>
        private static string TileFamily(string tile)
        {
            if (string.IsNullOrEmpty(tile)) return "";
            string t = tile.Replace('\\', '/');
            int slash = t.LastIndexOf('/');
            if (slash >= 0) t = t.Substring(slash + 1);
            int dot = t.LastIndexOf('.');
            if (dot >= 0) t = t.Substring(0, dot);
            // trailing autotile bitmask: wall_rock-10100010
            int dash = t.LastIndexOf('-');
            if (dash >= 0 && dash < t.Length - 1)
            {
                bool bits = true;
                for (int i = dash + 1; i < t.Length; i++)
                    if (t[i] != '0' && t[i] != '1') { bits = false; break; }
                if (bits) t = t.Substring(0, dash);
            }
            // trailing variant number: sw_waterwheel_1, sw_ground_dots3
            int end = t.Length;
            while (end > 0 && t[end - 1] >= '0' && t[end - 1] <= '9') end--;
            if (end < t.Length && end > 0 && t[end - 1] == '_') end--;
            if (end > 0) t = t.Substring(0, end);
            return t.ToLowerInvariant();
        }

        private sealed class Ground
        {
            public string Tile, Color, Detail, Glyph;
            public bool HFlip, VFlip;
        }

        private static Ground ResolveGround(Cell c)
        {
            try
            {
                var ev = c.Render();
                if (ev == null) return null;
                string tile = ev.Tile;
                if (string.IsNullOrEmpty(tile)) return null;
                return new Ground
                {
                    Tile = tile,
                    Color = ev.ColorString ?? "",
                    Detail = ev.DetailColor ?? "",
                    Glyph = ev.RenderString ?? "",
                    HFlip = ev.HFlip,
                    VFlip = ev.VFlip,
                };
            }
            catch { return null; }
        }

        private static void WriteGroundTile(JsonWriter j, Ground g)
        {
            string tile = g.Tile, color = g.Color, detail = g.Detail, glyph = g.Glyph;
            bool hflip = g.HFlip, vflip = g.VFlip;
            TileExporter.Ensure(tile);
            j.BeginObject()
                .Member("name", "[painted ground]")
                .Member("display", "ground")
                .Member("glyph", glyph)
                .Member("tile", tile)
                .Member("color", color)
                .Member("tilecolor", "")
                .Member("detail", detail)
                .Member("layer", 0)
                .Member("wall", false)
                .Member("solid", false)
                .Member("occluding", false)
                .Member("bridge", false)
                .Member("sinks", false)
                .Member("ground", true);
            if (hflip) j.Member("hflip", true);
            if (vflip) j.Member("vflip", true);
            j.EndObject();
        }

        /// <summary>
        /// Time of day for the client's day/night grade. Everything derives from
        /// The.Game.Turns and the static Calendar fields — no Calendar instance
        /// needed. Qud has NO moon phase (the only "moon" is the Moonstair
        /// location), so none is sent; the client gives night a generic moonlit
        /// tint rather than inventing a phase.
        /// </summary>
        private static void WriteTime(JsonWriter j)
        {
            try
            {
                // CurrentDaySegment is the position in the day, in SEGMENTS — the
                // same unit as StartOfDay(3250)/StartOfNight(10000), which are NOT
                // hours. A day is TurnsPerDay*10 = 12000 segments (dawn 3250 = 6:30,
                // dusk 10000 = 20:00). Send everything in segments and let the client
                // normalise; sending StartOfDay as an "hour" is what pinned the grade
                // to permanent night.
                int seg = Calendar.CurrentDaySegment;
                int segPerDay = Calendar.TurnsPerDay > 0 ? Calendar.TurnsPerDay * 10 : 12000;
                j.Name("time").BeginObject()
                    .Member("segment", seg)
                    .Member("segmentsPerDay", segPerDay)
                    .Member("startOfDay", Calendar.StartOfDay)
                    .Member("startOfNight", Calendar.StartOfNight)
                    .Member("isDay", CalendarIsDay())
                    .Member("label", TimeLabel())
                .EndObject();
            }
            catch { /* time is cosmetic; never fail a snapshot over it */ }
        }

        private static bool CalendarIsDay()
        {
            try { return Calendar.IsDay(); } catch { return true; }
        }

        private static string TimeLabel()
        {
            try
            {
                long t = The.Game != null ? The.Game.TimeTicks : 0L;
                return Calendar.GetTime(t) ?? "";
            }
            catch { return ""; }
        }

        private static int SafeStat(GameObject go, string stat)
        {
            try { return go.GetStatValue(stat); } catch { return 0; }
        }

        /// Strip Qud's {{color|text}} markup (and a trailing "!") to plain text, e.g.
        /// "{{R|Famished!}}" -> "Famished". Never throws.
        private static string StripMarkup(string s)
        {
            if (string.IsNullOrEmpty(s)) return "";
            var sb = new System.Text.StringBuilder(s.Length);
            int i = 0;
            while (i < s.Length)
            {
                if (i + 1 < s.Length && s[i] == '{' && s[i + 1] == '{')
                {
                    i += 2;
                    int bar = s.IndexOf('|', i);
                    int close = s.IndexOf("}}", i);
                    if (bar >= 0 && (close < 0 || bar < close)) i = bar + 1;   // drop the colour code
                    continue;
                }
                if (i + 1 < s.Length && s[i] == '}' && s[i + 1] == '}') { i += 2; continue; }
                sb.Append(s[i]); i++;
            }
            return sb.ToString().Trim().TrimEnd('!');
        }

        /// Player vitals + stats for the frame's status bar (top row). Every read is guarded so a
        /// missing part never fails the snapshot. AV/DV/MA use Stats.GetCombat* (Qud's displayed
        /// values, which fold in attribute modifiers) so they match the game's own status bar.
        private static void WriteStats(JsonWriter j, GameObject player, Zone z)
        {
            if (player == null) return;
            j.Name("stats").BeginObject();
            j.Member("name", DisplayNameOf(player));
            try { j.Member("hp", player.hitpoints).Member("hpMax", player.baseHitpoints); } catch { }
            int lvl = SafeStat(player, "Level");
            j.Member("level", lvl);
            j.Member("xp", SafeStat(player, "XP"));
            // XP thresholds so the EXP bar fills within the level: floor = XP to reach this level,
            // next = XP to reach the next. (Qud sets the "XP" stat's base to GetXPForLevel(Level).)
            try { j.Member("xpFloor", Leveler.GetXPForLevel(lvl)).Member("xpNext", Leveler.GetXPForLevel(lvl + 1)); } catch { }
            try { if (player.pPhysics != null) j.Member("temp", player.pPhysics.Temperature); } catch { }
            j.Member("qn", SafeStat(player, "Speed"));       // Quickness (100 nominal)
            j.Member("ms", SafeStat(player, "MoveSpeed"));   // Move speed (100 nominal)
            try { j.Member("av", XRL.Rules.Stats.GetCombatAV(player)); } catch { }
            try { j.Member("dv", XRL.Rules.Stats.GetCombatDV(player)); } catch { }
            try { j.Member("ma", XRL.Rules.Stats.GetCombatMA(player)); } catch { }
            try { j.Member("weight", player.GetCarriedWeight()).Member("weightMax", player.GetMaxCarriedWeight()); } catch { }
            try { j.Member("water", player.GetFreeDrams("water")); } catch { }   // fresh water = currency (lowercase liquid id)
            try
            {
                var st = player.GetPart<Stomach>();
                if (st != null)
                {
                    j.Member("hunger", StripMarkup(st.FoodStatus()));    // Sated / Hungry / Famished
                    j.Member("thirst", StripMarkup(st.WaterStatus()));   // Parched / Thirsty / Quenched / Tumescent
                }
            }
            catch { }
            try { if (z != null) j.Member("terrain", z.DisplayName ?? ""); } catch { }   // "salt marsh, surface"
            j.EndObject();
        }

        /// The player's active effects (buffs/debuffs) for the frame's Active effects panel. DisplayName
        /// keeps its {{colour|...}} markup so the client renders each in its Qud colour (wet is blue, a
        /// debuff its own red/etc). Duration is in turns; DURATION_INDEFINITE (9999) marks a permanent
        /// effect. `bad` = the effect carries Qud's TYPE_NEGATIVE flag, so the client can group/emphasise.
        private static void WriteEffects(JsonWriter j, GameObject player)
        {
            j.Name("effects").BeginArray();
            if (player != null)
            {
                try
                {
                    foreach (var e in player.Effects)
                    {
                        if (e == null) continue;
                        try
                        {
                            string nm = e.DisplayName ?? "";
                            // LiquidCovered's DisplayName is the generic "covered in liquid"; Qud instead
                            // shows the liquid's SMEARED name (the adjective it stamps on the creature) —
                            // water -> "{{B|wet}}", blood -> "{{r|bloody}}", etc. Use that so the panel
                            // matches the game (and stays coloured), falling back to the plain DisplayName.
                            if (e is LiquidCovered lc && lc.Liquid != null)
                            {
                                try
                                {
                                    var primary = lc.Liquid.GetPrimaryLiquid();
                                    string smeared = primary != null ? primary.GetSmearedName(lc.Liquid) : null;
                                    if (!string.IsNullOrEmpty(smeared)) nm = smeared;
                                }
                                catch { }
                            }
                            if (nm.Length == 0) continue;
                            bool bad = false;
                            try { bad = e.IsOfType(Effect.TYPE_NEGATIVE); } catch { }
                            j.BeginObject()
                                .Member("name", nm)                                   // keep markup — client colours it
                                .Member("duration", e.Duration)
                                .Member("indefinite", e.Duration >= Effect.DURATION_INDEFINITE)
                                .Member("bad", bad)
                            .EndObject();
                        }
                        catch { }
                    }
                }
                catch { }
            }
            j.EndArray();
        }

        /// The player's current combat target (Qud's status-bar target, XRL.UI.Sidebar.CurrentTarget)
        /// for the frame's Target panel. Sends `present=false` when nothing is targeted. Emits the full
        /// render info (glyph/tile/colours — like a cell object) plus hp/position/hostile, so the client
        /// can show a rich card AND a future tile image with no further mod change (mod edits cost a Qud
        /// restart; client edits don't). Position lets the client show direction/distance from the player.
        private static void WriteTarget(JsonWriter j, GameObject player)
        {
            j.Name("target").BeginObject();
            GameObject t = null;
            try { t = XRL.UI.Sidebar.CurrentTarget; } catch { }
            if (t == null || t == player)
            {
                j.Member("present", false).EndObject();
                return;
            }
            try
            {
                j.Member("present", true);
                j.Member("display", DisplayNameOf(t));   // DisplayNameOnly keeps colour markup; client renders it
                // Exact HP is HIDDEN info in Qud — sent only for the client's debug "full info" toggle.
                try { j.Member("hp", t.hitpoints).Member("hpMax", t.baseHitpoints); } catch { }
                try { var pc = t.CurrentCell; if (pc != null) j.Member("x", pc.X).Member("y", pc.Y); } catch { }
                try { j.Member("hostile", t.IsHostileTowards(player)); } catch { }
                // PERCEIVED descriptors — exactly what Qud's look/target line shows, colour markup kept:
                //   wound      = Strings.WoundLevel (the health WORD, e.g. Perfect/Injured; becomes exact
                //                hp AV/DV only if the player has scanning for the target — Qud's own rule)
                //   feeling    = disposition (Friendly/Neutral/Hostile; null if the target hides con)
                //   difficulty = toughness (Trivial..Impossible; null/"" if hidden)
                try { j.Member("wound", XRL.Rules.Strings.WoundLevel(t) ?? ""); } catch { }
                try
                {
                    var desc = t.GetPart<Description>();
                    if (desc != null)
                    {
                        j.Member("feeling", desc.GetFeelingDescription(player) ?? "");
                        j.Member("difficulty", desc.GetDifficultyDescription(player) ?? "");
                    }
                }
                catch { }
                WriteObjectRender(j, t);   // full tile + perceived override (unidentified -> "unknown" icon)
            }
            catch { }
            j.EndObject();
        }

        /// The contextual command menu (row 4, right) — Qud's bottom missile-weapon area. For each
        /// equipped missile weapon: its coloured name + ammo (remaining/total, via the game's own
        /// MissileWeapon.Status fill), plus the Fire/Reload actions. "No missile weapons equipped." when
        /// none. Mirrors Qud.UI.MissileWeaponArea. (Future: other contexts beyond missile weapons.)
        private static void WriteContext(JsonWriter j, GameObject player)
        {
            j.Name("context").BeginObject();
            var mws = (player != null) ? SafeMissileWeapons(player) : null;
            if (mws == null || mws.Count == 0)
            {
                j.Member("kind", "none").Member("text", "You have no missile weapons equipped.").EndObject();   // Qud's exact wording
                return;
            }
            j.Member("kind", "missile");
            // Actions carry Qud's own hotkey (ControlManager binding) so the client can show "[F] fire"
            // exactly as the game does — matches even if the player rebound the key.
            j.Name("actions").BeginArray();
            WriteAction(j, "fire", "CmdFire");
            WriteAction(j, "reload", "CmdReload");
            j.EndArray();
            j.Name("weapons").BeginArray();
            foreach (var w in mws)
            {
                try
                {
                    if (w == null) continue;
                    var part = w.GetPart<MissileWeapon>();
                    if (part == null) continue;
                    int total = 0, remaining = 0;
                    string statusText = "";
                    try
                    {
                        // The game's own per-weapon fill (name-agnostic ammo readout). The status object
                        // is a plain data holder — constructing it directly (not via the pooled .next())
                        // avoids touching the live UI's pool.
                        var st = new Qud.UI.MissileWeaponArea.MissileWeaponAreaWeaponStatus();
                        part.Status(st);
                        total = st.ammoTotal;
                        remaining = st.ammoRemaining;
                        statusText = st.text ?? "";
                    }
                    catch { }
                    string wid = "";
                    bool canCell = false;
                    try { wid = w.ID ?? ""; } catch { }
                    try { canCell = w.HasPart("EnergyCellSocket"); } catch { }   // "[?]" change-battery affordance
                    j.BeginObject()
                        .Member("name", DisplayNameOf(w))       // DisplayNameOnly keeps colour markup
                        .Member("id", wid)                      // so the client can target this weapon for a cell swap
                        .Member("canReplaceCell", canCell)
                        .Member("ammoRemaining", remaining)
                        .Member("ammoTotal", total)
                        .Member("status", statusText);
                    // PERCEIVED render — an UNIDENTIFIED artifact shows Qud's generic "unknown" icon, not
                    // its real tile, until the player understands it (RenderForUI honours identification).
                    WriteObjectRender(j, w);
                    j.EndObject();
                }
                catch { }
            }
            j.EndArray();
            j.EndObject();
        }

        /// Write an object's render fields for a panel icon: the FULL (known) tile from the raw Render
        /// part, PLUS a perceived override (see WritePerceivedOverride). The client shows the perceived
        /// icon by default and the full one under the global "Full info" toggle.
        private static void WriteObjectRender(JsonWriter j, GameObject go)
        {
            try
            {
                var r = go.GetPart<Render>();
                if (r != null)
                {
                    bool painted;
                    string tile = ResolvedTile(go, r, out painted);
                    string glyph = ResolvedGlyph(r);
                    if (tile.Length > 0) TileExporter.Ensure(tile);
                    j.Member("glyph", glyph)
                     .Member("tile", tile)
                     .Member("color", r.ColorString ?? "")
                     .Member("tilecolor", r.TileColor ?? "")
                     .Member("detail", r.DetailColor ?? "");
                    // Sprite facing: Qud display-flips creature tiles (their atlas art faces one way; the
                    // creature faces the other). The reliable source is the CELL's render event (the same
                    // one the ground path uses) — it evaluates the flip in render context. Render.HFlip is
                    // false here, and getHFlip() (= HFlip XOR PartyFlip) is unstable per call (the same
                    // object read true from one serialization, false from another). cell.Render() reflects
                    // the top object's display; the player/creature is that top object.
                    try
                    {
                        var pc2 = go.CurrentCell;
                        if (pc2 != null) { var rev = pc2.Render(); if (rev != null && rev.HFlip) j.Member("hflip", true); }
                    }
                    catch { }
                    if (painted) WritePaintedColors(j);
                }
            }
            catch { }
            WritePerceivedOverride(j, go);
        }

        /// If the object is NOT understood, add a PERCEIVED override (tileP/colorP/detailP/glyphP) from
        /// GameObject.RenderForUI() — Qud's own UI render, honouring identification — so the client can
        /// show the generic "unknown" icon in perceived mode. Understood objects (the common case) get no
        /// override, so RenderForUI (the expensive call) only runs for the rare unidentified item.
        private static void WritePerceivedOverride(JsonWriter j, GameObject go)
        {
            try
            {
                if (go.Understood()) return;   // known -> perceived == full, no override needed
                var re = go.RenderForUI();
                if (re == null) return;
                string tp = re.Tile ?? "";
                if (tp.Length > 0) TileExporter.Ensure(tp);
                j.Member("glyphP", re.RenderString ?? "")
                 .Member("tileP", tp)
                 .Member("colorP", re.ColorString ?? "")   // ColorString is already the tile colour
                 .Member("detailP", re.DetailColor ?? "");
            }
            catch { }
        }

        /// One context action: its label, Qud's current hotkey (e.g. fire -> "F"), and the command the
        /// client sends back to trigger it.
        private static void WriteAction(JsonWriter j, string name, string cmd)
        {
            string key = "";
            try { key = ControlManager.getCommandInputDescription(cmd, false) ?? ""; } catch { }
            j.BeginObject().Member("name", name).Member("key", key).Member("command", cmd).EndObject();
        }

        private static System.Collections.Generic.List<GameObject> SafeMissileWeapons(GameObject player)
        {
            try { return player.GetMissileWeapons(); } catch { return null; }
        }

        /// The player's activated abilities for the row-5 command bar, in Qud's own bar order
        /// (GetAbilityListOrderedByPreference). Each: name, the command to activate it, hotkey, toggle/
        /// cooldown/enabled state, and a state-appropriate icon (tile + colours, else glyph).
        private static void WriteCommandBar(JsonWriter j, GameObject player)
        {
            j.Name("abilities").BeginArray();
            var aa = (player != null) ? player.GetPart<ActivatedAbilities>() : null;
            // One-shot diagnostic (logs to Player.log only when it changes): is the part present, and how
            // many abilities does Qud count? Tells us empty-because-none vs empty-because-we-dropped-them.
            string diag = "part=" + (aa != null) + " count=" + (aa != null ? aa.GetAbilityCount() : -1);
            if (diag != _lastCmdbarLog) { _lastCmdbarLog = diag; try { System.Console.WriteLine("[raves] cmdbar " + diag); } catch { } }
            if (aa != null)
            {
                try
                {
                    foreach (var e in aa.GetAbilityListOrderedByPreference())
                    {
                        if (e == null) continue;   // NOTE: no Visible filter — the ability bar shows what Qud's bar shows
                        try
                        {
                            string hk = e.DisplayForHotkey ?? "";       // the ability-bar hotkey, if assigned
                            if (hk.Length == 0)
                            {
                                try { hk = ControlManager.getCommandInputDescription(e.Command, false) ?? ""; } catch { }
                            }
                            j.BeginObject()
                                .Member("name", e.DisplayName ?? "")
                                .Member("command", e.Command ?? "")
                                .Member("hotkey", hk)
                                .Member("visible", e.Visible)
                                .Member("toggleable", e.Toggleable)
                                .Member("toggle", e.ToggleState)
                                .Member("enabled", e.Enabled)
                                .Member("cooldown", e.Cooldown);
                            WriteAbilityIcon(j, e);
                            j.EndObject();
                        }
                        catch { }
                    }
                }
                catch { }
            }
            j.EndArray();
        }

        /// The ability's icon: the state-appropriate UI tile Renderable (toggle-on / cooling-down /
        /// disabled / default) as tile + colours, with the glyph as fallback.
        private static void WriteAbilityIcon(JsonWriter j, ActivatedAbilityEntry e)
        {
            // GetUITile() LAZILY fills the tile from the ability's XmlData (the raw UITileDefault field is
            // often null until then — that's why Rebuke Robot/Slam came through iconless) AND returns the
            // state-appropriate variant (toggle-on / cooling / disabled / default). Works for ANY ability.
            var r = e.UITileDefault;                // seeds the Renderable type for `var` (may be null)
            try { r = e.GetUITile(); } catch { }
            string tile = (r != null) ? (r.Tile ?? "") : "";
            if (tile.Length > 0) TileExporter.Ensure(tile);
            j.Member("glyph", (r != null && !string.IsNullOrEmpty(r.RenderString)) ? r.RenderString : (e.Icon ?? ""))
             .Member("tile", tile)
             .Member("color", (r != null) ? (r.ColorString ?? "") : "")
             .Member("tilecolor", (r != null) ? (r.TileColor ?? "") : "")
             .Member("detail", (r != null) ? r.DetailColor.ToString() : "");
        }

        // --- "since load" message count -------------------------------------------------------------
        // Qud's on-screen message log (Qud.UI.MessageLogWindow) is CLEARED on every game load and then
        // accumulates only messages emitted afterwards, via XRLCore.RegisterNewMessageLogEntryCallback —
        // it does NOT re-show the save's persisted backlog. Player.Messages, which the client renders in
        // 1:1 mode, DOES include that backlog, so Raves showed far more history than Qud. Mirror Qud's
        // callback to count messages since the current load; the client trims its 1:1 log to that many.
        private static readonly object _sinceLock = new object();
        private static int _sinceLoadCount;
        private static object _lastMsgGame;
        private static bool _msgCbRegistered;

        /// Register the message-log callback. MUST run at mod startup (before any game loads) so it catches
        /// the load-time messages Qud's own sidebar catches — a lazy first-snapshot registration misses them.
        public static void EnsureMessageCallback()
        {
            if (_msgCbRegistered) return;
            try { XRL.Core.XRLCore.RegisterNewMessageLogEntryCallback(OnNewLogEntry); _msgCbRegistered = true; }
            catch { }
        }

        private static void OnNewLogEntry(string log)
        {
            try
            {
                object g = The.Game;
                lock (_sinceLock)
                {
                    if (!ReferenceEquals(g, _lastMsgGame)) { _sinceLoadCount = 0; _lastMsgGame = g; }  // load → clear, like Qud
                    _sinceLoadCount++;
                }
            }
            catch { }
        }

        /// The player's recent message-log lines (tail), markup-stripped, for the frame's Message log.
        private static void WriteMessages(JsonWriter j)
        {
            try
            {
                EnsureMessageCallback();
                var mq = (The.Game != null && The.Game.Player != null) ? The.Game.Player.Messages : null;
                if (mq == null || mq.Messages == null) return;
                var lines = mq.Messages;
                int n = lines.Count;
                int start = n > 80 ? n - 80 : 0;   // last ~80 lines is plenty for the panel
                j.Member("msgCount", n);           // total ever, so the client can diff for NEW lines (filter mode)
                int since; lock (_sinceLock) since = _sinceLoadCount;
                j.Member("msgSinceLoad", since);   // how many trailing lines were emitted THIS load (Qud's sidebar window)
                j.Name("messages").BeginArray();
                for (int i = start; i < n; i++)
                    j.Value(lines[i]);             // keep {{colour|...}} markup; the client renders it coloured
                j.EndArray();
            }
            catch { }
        }

        public static string BuildJson(GameObject player)
        {
            var sw = System.Diagnostics.Stopwatch.StartNew();
            var j = new JsonWriter();
            j.BeginObject();
            j.Member("type", Protocol.TypeSnapshot);
            j.Member("tilesDir", TileExporter.Dir); // where Godot loads exported PNGs
            j.Member("mod", Protocol.Build);        // which mod build is actually live (human-readable)
            j.Member("protocol", Protocol.Version); // numeric wire version — client checks it vs its minimum
            // Stable per-game id: the client namespaces its on-disk zone store by
            // this so a NEW game never renders a previous game's remembered zones.
            j.Member("gameId", The.Game != null ? (The.Game.GameID ?? "") : "");
            j.Member("serverUs", _lastBuildUs);     // prior turn's serialize time (profiler)
            j.Member("renderBaseUs", (int)Bridge.LastRenderBaseUs);  // this turn's RenderBase cost (0 if skipped)
            WriteTime(j);
            WritePalette(j);

            // Force-export reference tiles the client wants but that don't occur
            // naturally in a zone — e.g. the isolated wall (bordered on all sides),
            // used for the real framed wall-top. Cached after the first export.
            TileExporter.Ensure("Assets/Content/Textures/Tiles/wall_rock-00000000.bmp");

            Zone z = The.ActiveZone;
            if (z == null) { j.EndObject(); return j.ToString(); }

            int w = z.Width;
            int h = z.Height;

            // Structured zone coordinates, straight off the Zone (confirmed real int
            // fields by reflection: wX/wY = parasang, X/Y = zone within the 3x3
            // parasang, Z = stratum). The client derives global cell coordinates from
            // these — no fragile parsing of the ZoneID string. See docs/roadmap.md.
            j.Name("zone").BeginObject()
                .Member("id", z.ZoneID ?? "")
                .Member("width", w)
                .Member("height", h)
                .Member("wx", z.wX)
                .Member("wy", z.wY)
                .Member("zx", z.X)
                .Member("zy", z.Y)
                .Member("z", z.Z)
            .EndObject();

            Cell pc = player?.CurrentCell;
            j.Name("player").BeginObject()
                .Member("x", pc != null ? pc.X : -1)
                .Member("y", pc != null ? pc.Y : -1);
            if (player != null) WriteObjectRender(j, player);   // player's icon (for the log's "you" pictograph)
            j.EndObject();

            // The current location's WORLD-MAP terrain (its tile + landmark/biome name, e.g. "Salt marsh",
            // "Red Rock"). The client accumulates these as the player travels, so a log line naming a
            // landmark can show its world tile. Null off the world map / mid-teardown — just skip.
            try
            {
                var terrain = z.GetTerrainObject();
                if (terrain != null)
                {
                    j.Name("worldTerrain").BeginObject().Member("name", DisplayNameOf(terrain));
                    WriteObjectRender(j, terrain);
                    j.EndObject();
                }
            }
            catch { }

            WriteStats(j, player, z);   // player vitals/stats for the frame status bar
            WriteEffects(j, player);    // active effects (buffs/debuffs) for the frame Active effects panel
            WriteTarget(j, player);     // current combat target for the frame Target panel
            WriteContext(j, player);    // contextual command menu (missile Fire/Reload) for the frame
            WriteCommandBar(j, player);  // activated abilities for the row-5 command bar
            WriteMessages(j);           // recent message-log lines for the frame Message log

            j.Name("cells").BeginArray();
            for (int y = 0; y < h; y++)
            {
                for (int x = 0; x < w; x++)
                {
                    Cell c = z.GetCell(x, y);
                    if (c == null) continue;

                    // Cell.Objects is an ObjectRack, not a list. GetObjects() is
                    // the canonical accessor — don't assume raw enumeration of the
                    // rack yields the same set.
                    var objects = c.GetObjects();
                    int emitted = 0;

                    // Qud's painted ground (Cell.Render()) matters ONLY on a cell with no object.
                    // On an occupied cell Cell.Render() composites the WHOLE cell and hands back the
                    // TOP object's tile — which the objects already draw, so it was always deduped
                    // away there (else every sprite drew twice). Resolving it per occupied cell was
                    // pure waste: Cell.Render() is expensive, and on the WORLD MAP every one of the
                    // 2000 cells is occupied — 2000 Cell.Render() calls + 2000 HashSet allocs every
                    // turn were the overworld movement lag. So only resolve it on empty cells.
                    Ground ground = (objects.Count == 0) ? ResolveGround(c) : null;
                    if (ground == null && objects.Count == 0) continue;   // truly blank cell

                    bool opened = true;
                    j.BeginObject().Member("x", x).Member("y", y)
                        .Member("bridge", c.HasBridge())
                        .Member("wade", c.HasWadingDepthLiquid())
                        .Member("swim", c.HasSwimmingDepthLiquid())
                        // Qud's own per-cell light level (LightLevel byte: Blackout=0,
                        // None=1 .. Light=200 ..). The client uses this underground to fall
                        // off to black away from sources, matching what Qud shows.
                        .Member("light", (int)c.GetLight())
                        .Member("explored", c.IsExplored())
                    .Name("objs").BeginArray();

                    // Qud's painted ground goes first: it is the bottom of the
                    // stack, and on most cells here it is the ONLY thing drawn.
                    if (ground != null) { WriteGroundTile(j, ground); emitted++; }

                    foreach (GameObject go in objects)
                    {
                        Render r = go.GetPart<Render>();
                        if (r == null) continue;

                        // Drawable = has ART or a GLYPH. Requiring RenderString
                        // silently dropped every tile-only object: RenderString is
                        // just the ASCII fallback, and in tile mode Qud draws from
                        // the tile. Objects filtered here never reach the wire, so
                        // no amount of querying the snapshot could find them.
                        bool painted;
                        string tile = ResolvedTile(go, r, out painted);
                        string glyph = ResolvedGlyph(r);
                        if (glyph.Length == 0 && tile.Length == 0) continue;

                        if (tile.Length > 0) TileExporter.Ensure(tile); // export-on-sight, cached

                        Physics phys = go.GetPart<Physics>();
                        LightSource light = go.GetPart<LightSource>();
                        j.BeginObject()
                            // Identity. Without this an object with no Tile is
                            // unidentifiable on the client — you see a glyph and a
                            // colour and cannot tell grass from a glowpad.
                            .Member("name", go.Blueprint ?? "")
                            .Member("display", DisplayNameOf(go))
                            .Member("glyph", glyph)
                            .Member("tile", tile)
                            .Member("color", r.ColorString ?? "")
                            .Member("tilecolor", r.TileColor ?? "")
                            .Member("detail", r.DetailColor ?? "")
                            .Member("layer", r.RenderLayer)
                            .Member("wall", go.IsWall())
                            .Member("solid", phys != null && phys.Solid)
                            .Member("occluding", r.Occluding)
                            // deck: a walkable surface laid over whatever is beneath it
                            // (bridges are RenderLayer 3, so without this flag Godot
                            // would stand them up as billboards instead of decking them).
                            .Member("bridge", go.HasIntProperty("Bridge"))
                            // only creatures sink; scenery/plants rooted in the water
                            // (watervines) must keep their full height. Flyers skim over.
                            .Member("sinks", go.IsCreature && !go.IsFlying)
                            // mobile actor: the client drops these from a REMEMBERED
                            // neighbour zone (they've wandered off since it was live).
                            .Member("creature", go.IsCreature)
                            // liquid pool (has a LiquidVolume). Volatile: it spreads/evaporates and,
                            // crucially, SLOSHES onto every cell a wet player wades through — so the
                            // client must exclude it from the STATIC signature or a wet walk rebuilds
                            // the frozen zone every step (the "tiles vanish while walking" bug).
                            .Member("liquid", go.LiquidVolume != null);
                        // A lit LightSource -> Godot places a point light of this
                        // radius. The flame itself is procedural in Qud (particles +
                        // AnimatedMaterialFire), so there is no tile to send — only
                        // the light, which the blueprint specifies exactly.
                        if (light != null && light.Lit)
                            j.Member("lightRadius", light.Radius);
                        // On fire: Qud draws the flame procedurally (AnimatedMaterialFire), so the TILE is
                        // flameless (a campfire's sw_campfire_noflame.png). The client fakes an additive
                        // flame that fades out by day — fine for a torch whose tile shows flame, but a
                        // campfire then vanishes in daylight. Flag it so the client draws a daytime flame +
                        // smoke for these. (Only sent when true; client defaults false.)
                        if (go.HasPart("AnimatedMaterialFire"))
                            j.Member("onFire", true);
                        if (painted) WritePaintedColors(j);
                        WritePerceivedOverride(j, go);   // "unknown" icon override for unidentified items (Nearby)
                        j.EndObject();
                        emitted++;
                    }

                    if (opened)
                    {
                        // What the CELL says it holds vs what we actually sent.
                        // A gap here means we are dropping objects, and says so
                        // out loud instead of looking like an empty tile.
                        j.EndArray()
                            .Member("nHeld", CountSafe(c))
                            .Member("nRendered", RenderedSafe(c))
                            .Member("nSent", emitted)
                        .EndObject();
                    }

                }
            }
            j.EndArray();

            j.EndObject();
            var s = j.ToString();
            _lastBuildUs = (int)(sw.Elapsed.TotalMilliseconds * 1000.0);
            return s;
        }
    }
}
