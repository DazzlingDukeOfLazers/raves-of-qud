using System;
using XRL.World;

namespace RavesOfQud
{
    /// <summary>
    /// A part attached to the player at game start (see PlayerBridgeMutator).
    /// Its only job is to fire <see cref="Bridge.Tick"/> once per turn, on the
    /// main thread.
    ///
    /// CONFIRM (see header in Bridge.cs): the Register/FireEvent signatures and
    /// the "EndTurn" event name. If your version uses pooled events instead,
    /// replace the body with:
    ///     public override bool WantEvent(int id, int casc) =&gt;
    ///         base.WantEvent(id, casc) || id == EndTurnEvent.ID;
    ///     public override bool HandleEvent(EndTurnEvent e) { Bridge.Tick(ParentObject); return base.HandleEvent(e); }
    /// </summary>
    [Serializable]
    public class BridgePart : IPart
    {
        public override void Register(GameObject Object, IEventRegistrar Registrar)
        {
            Registrar.Register("EndTurn");
            base.Register(Object, Registrar);
        }

        public override bool FireEvent(Event E)
        {
            if (E.ID == "EndTurn")
            {
                Bridge.Tick(ParentObject);
            }
            return base.FireEvent(E);
        }
    }
}
