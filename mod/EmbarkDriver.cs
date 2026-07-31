using System;
using System.Threading;          // post-boot popup-suppress window
using UnityEngine;               // GameObject.GetComponent
using XRL;                       // The
using XRL.UI;                    // Popup (Popup.Suppress)
using XRL.CharacterBuilds;       // EmbarkBuilder, AbstractEmbarkBuilderModule(Data)
using XRL.CharacterBuilds.Qud;   // the concrete Qud modules + their *Data types

namespace RavesOfQud
{
    // ========================================================================
    //  THE DRIVE.  Turn Raves' character picks into a real running game while
    //  skipping Qud's on-screen chargen. Verified against the shipped 1.0 build
    //  by reflecting Assembly-CSharp.dll (see ~/qud-decomp + the raves-chargen memory).
    //
    //  Why not Harmony: on this macOS build, runtime patching dies with
    //  "mprotect returned EACCES" (hardened-runtime W^X). So instead of swapping
    //  EmbarkBuilder.Begin(), we let Qud's REAL Begin() run and drive the live
    //  builder it creates through its public API — set the module choices, then
    //  exitWithInfo(). No windows are walked; only Begin's first (game-mode)
    //  window ever momentarily exists, and it's torn down by exitWithInfo.
    //
    //  Flow (started by the "embark" bridge command, at the main menu):
    //    OnPayload (socket thread): stash spec -> PushMouseEvent("Pick:New Game")
    //      -> XRLCore._Start dispatches -> NewGame() [core thread]
    //         -> EmbarkBuilder.Begin() [hops to UI thread]: creates the live builder
    //    DrivePending (UI thread, via uiQueue): once the live builder exists, setData
    //      the choices in cascade order, then eb.exitWithInfo() -> builds EmbarkInfo,
    //      completes Begin's finishedEvent -> NewGame boots -> Game.Running -> RunGame().
    // ========================================================================

    /// <summary>Drives Qud's live EmbarkBuilder from a Raves character spec, headlessly.</summary>
    public static class EmbarkDriver
    {
        /// <summary>A character build requested from Raves. Only genotype+subtype are the
        /// player's choice; the rest are sensible defaults for a minimal valid build.</summary>
        public sealed class PendingBuildSpec
        {
            public string Genotype;                    // e.g. "Mutated Human", "True Kin"
            public string Subtype;                     // caste/calling id, e.g. "Apostle"
            public string Gamemode = "Classic";        // Classic | Roleplay | Wander
            public string Chartype = "New";            // "New" = fully custom character
            public string StartingLocation = "Joppa";  // QudChooseStartingLocationModule id
        }

        private static volatile PendingBuildSpec _pending;
        private static int _tries;
        // ~10s at 60fps: enough for New Game to dispatch + Begin to build the live builder,
        // bounded so an embark sent when NOT at the menu (builder never appears) gives up.
        private const int MaxTries = 600;

        /// <summary>Socket-thread entry: queue an embark and wake the main menu. Safe to call
        /// off the game thread — the actual builder driving is marshalled onto Qud's UI queue.</summary>
        /// <summary>Start the guided TUTORIAL. Unlike a normal embark there's no genotype/subtype —
        /// Qud's game-mode module does it all in SelectMode("Tutorial"): TutorialManager.StartTutorial,
        /// a Pregen character, and an advance that boots the tutorial zone. So we just drive the live
        /// builder's SelectMode. Signalled by Gamemode == "Tutorial".</summary>
        public static void RequestTutorial()
        {
            RequestEmbark(new PendingBuildSpec { Gamemode = "Tutorial" });
        }

        public static void RequestEmbark(PendingBuildSpec spec)
        {
            _pending = spec;
            _tries = 0;
            // Wake the CORE-thread main menu and choose New Game (no-op if a game is already
            // running / the menu isn't active — then DrivePending simply times out).
            ConsoleLib.Console.Keyboard.PushMouseEvent("Pick:New Game");
            Enqueue();
        }

        private static void Enqueue()
        {
            GameManager gm = GameManager.Instance;
            if (gm == null || gm.uiQueue == null) return;   // too early; RequestEmbark retries next call
            gm.uiQueue.queueTask(DrivePending, 0);
        }

        /// <summary>Runs on Qud's UI thread (uiQueue). Waits for Begin() to spin up the live
        /// EmbarkBuilder, then fills it in and exits it. Re-queues itself until then.</summary>
        private static void DrivePending()
        {
            var spec = _pending;
            if (spec == null) return;

            EmbarkBuilder eb = null;
            try { eb = EmbarkBuilder.gameObject?.GetComponent<EmbarkBuilder>(); }
            catch { /* GameManager not ready yet */ }

            if (eb == null)
            {
                if (++_tries <= MaxTries) { Enqueue(); }
                else
                {
                    _pending = null;
                    System.Console.WriteLine("[raves] embark timed out waiting for the builder " +
                                             "(is Qud at the main menu?).");
                }
                return;
            }

            _pending = null;   // got the builder — commit to this attempt
            try
            {
                if (spec.Gamemode == "Tutorial")
                {
                    // The tutorial is a pregen guided game — no player chargen. Qud's own
                    // QudGamemodeModule.SelectMode("Tutorial") sets it all up (StartTutorial + a
                    // Pregen character) and advances the builder; with nothing editable it advances
                    // all the way to the boot. Suppress the post-boot popups as for a normal embark.
                    XRL.UI.Popup.Suppress = true;
                    StartSuppressWindow();
                    var gmm = eb.GetModule<QudGamemodeModule>();
                    if (gmm == null)
                        throw new InvalidOperationException("Gamemode module not found");
                    System.Console.WriteLine("[raves] tutorial: SelectMode + commit pregen -> boot");
                    gmm.SelectMode("Tutorial");   // StartTutorial + Pregen chartype (advances to the genotype)
                    // The guided windows won't advance headlessly, so commit the tutorial's fixed build
                    // directly (from JoppaTutorial.IntroTutorialStart): a Marsh Taur mutated-human pregen
                    // starting in the JoppaTutorial zone. Then exitWithInfo builds it and boots.
                    SetData<QudGenotypeModule>(eb, new QudGenotypeModuleData("Mutated Human"));
                    SetData<QudPregenModule>(eb, new QudPregenModuleData("Marsh Taur"));
                    SetData<QudChooseStartingLocationModule>(eb, new QudChooseStartingLocationModuleData("JoppaTutorial"));
                    // bootGame reads Subtype.data for random-name generation even for a pregen (the
                    // pregen supplies the real body); without it that line NREs. Any valid calling works.
                    SetData<QudSubtypeModule>(eb, new QudSubtypeModuleData("Apostle"));
                    eb.exitWithInfo();
                    System.Console.WriteLine("[raves] tutorial: exitWithInfo done");
                    return;
                }

                // setData directly (NOT the Select*/SelectMode wrappers — those call
                // builder.advance(), which walks the on-screen windows). Order matters: each
                // setData re-runs the enable cascade that turns on the next stage —
                //   Gamemode -> Chartype -> Genotype -> Subtype -> ChooseStartingLocation.
                SetData<QudGamemodeModule>(eb, new QudGamemodeModuleData { Mode = spec.Gamemode });
                SetData<QudChartypeModule>(eb, new QudChartypeModuleData(spec.Chartype));
                SetData<QudGenotypeModule>(eb, new QudGenotypeModuleData(spec.Genotype));
                SetData<QudSubtypeModule>(eb, new QudSubtypeModuleData(spec.Subtype));
                // ChooseStartingLocation enables off Subtype and NREs at boot if its data is
                // null, so set it even though the player didn't pick it here.
                SetData<QudChooseStartingLocationModule>(
                    eb, new QudChooseStartingLocationModuleData(spec.StartingLocation));

                System.Console.WriteLine(
                    "[raves] embark: driving builder (genotype=" + spec.Genotype +
                    ", subtype=" + spec.Subtype + ") -> exitWithInfo.");

                // Raves is driving, so the player watches Raves — not Qud's window. Both post-boot
                // gates ("You embark for the caves of Qud" and the opening-story beat) are
                // Popup.Show() calls, which no-op (log-only) while Popup.Suppress is set. Suppress
                // across the boot + first turn so the game reaches a live zone on its own (the gate
                // text still lands in the message log, which Raves reads); a watchdog clears it.
                XRL.UI.Popup.Suppress = true;
                StartSuppressWindow();

                // Builds the EmbarkInfo from the (now-populated) enabled modules, tears down the
                // chargen windows, and completes Begin()'s finishedEvent -> NewGame boots.
                eb.exitWithInfo();
            }
            catch (Exception e)
            {
                System.Console.WriteLine("[raves] embark drive FAILED, returning to menu: " + e);
                // Fail safe: let NewGame see a cancelled build and drop back to the menu.
                try { eb.exitWithoutInfo(); }
                catch { try { EmbarkBuilder.finishedEvent?.TrySetResult(null); } catch { } }
            }
        }

        private static void SetData<T>(EmbarkBuilder eb, AbstractEmbarkBuilderModuleData data)
            where T : AbstractEmbarkBuilderModule
        {
            var m = eb.GetModule<T>();
            if (m == null)
                throw new InvalidOperationException("Embark module not found: " + typeof(T).Name);
            m.setData(data);
        }

        /// <summary>
        /// Watchdog that clears <see cref="Popup.Suppress"/> once the boot has passed both gates:
        /// the world build (~30s) finishes BEFORE Game.Running, then the "You embark" popup and the
        /// first-turn opening beat fire within a few seconds of Running. Wait for Running + a short
        /// tail, then re-enable popups. A hard timeout guarantees we never leave popups suppressed.
        /// </summary>
        private static void StartSuppressWindow()
        {
            var t = new Thread(() =>
            {
                try
                {
                    // Up to ~90s for the world build; then a tail to cover the two post-boot popups.
                    for (int i = 0; i < 180 && (The.Game == null || !The.Game.Running); i++)
                        Thread.Sleep(500);
                    Thread.Sleep(6000);
                }
                catch (Exception e)
                {
                    System.Console.WriteLine("[raves] suppress-window error: " + e.Message);
                }
                finally
                {
                    XRL.UI.Popup.Suppress = false;   // ALWAYS restore popups
                    System.Console.WriteLine("[raves] embark: popup suppression lifted.");
                }
            })
            { IsBackground = true, Name = "RavesEmbarkSuppress" };
            t.Start();
        }
    }
}
