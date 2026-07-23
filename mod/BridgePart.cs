using System;
using XRL;        // IEventRegistrar (XRL.IEventRegistrar)
using XRL.World;  // IPart, GameObject, EndTurnEvent

namespace RavesOfQud
{
    /// <summary>
    /// A part attached to the player at game start (see PlayerBridgeMutator).
    /// Its only job is to fire <see cref="Bridge.Tick"/> once per turn, on the
    /// main thread.
    ///
    /// Uses the pooled-event path, verified against the 1.0 build:
    ///   IPart.WantEvent(int, int), IPart.HandleEvent(EndTurnEvent), EndTurnEvent.ID.
    /// </summary>
    [Serializable]
    public class BridgePart : IPart
    {
        public override bool WantEvent(int ID, int cascade)
        {
            return base.WantEvent(ID, cascade)
                || ID == EndTurnEvent.ID       // per-turn: publish snapshot (game thread)
                || ID == BeforeRenderEvent.ID; // per-frame: drain tile export (maybe main thread)
        }

        public override bool HandleEvent(EndTurnEvent E)
        {
            Bridge.Tick(ParentObject);
            return base.HandleEvent(E);
        }

        public override bool HandleEvent(BeforeRenderEvent E)
        {
            TileExportPump.Pump(); // guarded: only does graphics if on the Unity main thread
            return base.HandleEvent(E);
        }
    }
}
