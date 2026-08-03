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
            // EndTurn: publish a snapshot per turn.
            // BeforeRender: fires EVERY rendered frame (even while the player sits idle
            // at the input prompt, when no turn is ending). That is the only place we
            // can drain + apply a command that arrived from an external driver while the
            // game is idle — otherwise the move waits forever for a turn that never comes.
            // BeginTakeAction: fires on the TURN THREAD at the start of each player action — even while
            // Qud is unfocused (BeforeRender does not). Lets us flush an off-turn publish queued while the
            // game was blocked in a prompt (e.g. Make Camp's direction pick) as soon as it unblocks.
            return base.WantEvent(ID, cascade) || ID == EndTurnEvent.ID || ID == BeforeRenderEvent.ID
                || ID == BeginTakeActionEvent.ID;
        }

        public override bool HandleEvent(EndTurnEvent E)
        {
            Bridge.Tick(ParentObject);
            return base.HandleEvent(E);
        }

        public override bool HandleEvent(BeginTakeActionEvent E)
        {
            Bridge.TickAction(ParentObject);
            return base.HandleEvent(E);
        }

        public override bool HandleEvent(BeforeRenderEvent E)
        {
            Bridge.TickRender(ParentObject);
            return base.HandleEvent(E);
        }
    }
}
