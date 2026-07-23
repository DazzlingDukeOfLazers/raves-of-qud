using XRL;
using XRL.World;

namespace RavesOfQud
{
    /// <summary>
    /// Attaches <see cref="BridgePart"/> to the player as soon as the player
    /// GameObject is created, so the bridge starts streaming from turn one.
    ///
    /// CONFIRM: the [PlayerMutator] attribute + IPlayerMutator.mutate(GameObject)
    /// shape (see https://wiki.cavesofqud.com/wiki/Modding:Adding_Code_to_the_Player).
    /// </summary>
    [PlayerMutator]
    public class PlayerBridgeMutator : IPlayerMutator
    {
        public void mutate(GameObject player)
        {
            // GetFirstPart + AddPart are both confirmed present in the 1.0 build
            // (HasPart<T> / GetPart<T> did not surface in metadata).
            if (player.GetFirstPart<BridgePart>() == null)
                player.AddPart(new BridgePart());
        }
    }
}
