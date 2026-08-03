# Verified Qud API reference

Namespaces and signatures confirmed by **reflection** against the `Assembly-CSharp.dll` shipped with the
installed **Caves of Qud 1.0** build, running on **Unity `6000.0.77f1`** (that string is the *engine*
version, not the game version — record the game version separately when it matters for re-verification).
**Not a stable public API** — re-verify after a Qud update with the reflection probe / `dotnet build`
against the shipped DLL (see [`CLAUDE.md`](../CLAUDE.md) for the ilspycmd command). Reflect, don't grep —
string-grepping the DLL lies about casing.

```
XRL.The.ActiveZone : Zone            XRL.The.Player : GameObject
XRL.IEventRegistrar                  XRL.IPlayerMutator.mutate(GameObject)   [PlayerMutator] attr
XRL.World.IPart:
    Register(GameObject, IEventRegistrar) ; FireEvent(Event)
    WantEvent(int ID, int cascade)  ;  HandleEvent(EndTurnEvent) / HandleEvent(BeforeRenderEvent)
XRL.World.EndTurnEvent  (pooled; static .ID)      per-turn hook, fires on the TURN thread
XRL.World.BeforeRenderEvent (static .ID)          also fires on the TURN thread, NOT main
XRL.World.Zone:      fields Width, Height (int) ; prop ZoneID (string) ; GetCell(int,int) -> Cell
XRL.World.Cell:      X, Y, Objects, ParentZone
XRL.World.GameObject:
    GetPart<T>() ; HasPart<T>() ; AddPart(IPart) ; CurrentCell (prop)
    Physics (field, prefer for new code)  ;  pPhysics (legacy accessor, [Obsolete] but still compiles — the mod uses pPhysics.Temperature)
    IsWall() ; IsOpenLiquidVolume() ; IsWadingDepthLiquid()
XRL.World.Parts.Render (fields CAPITALIZED):
    RenderString, ColorString, TileColor, DetailColor, Tile (string), RenderLayer (int)
    Visible (bool prop), Occluding (bool prop)
XRL.World.Parts.Physics:  Solid (bool prop)
XRL.World.CommandEvent.Send(GameObject actor, string cmd, GameObject target, Cell cell,
    int standoff, bool forced, bool silent, GameObject handler)     // no 2-arg overload
    // movement command IDs: CmdMoveN/S/E/W/NE/NW/SE/SW  (Commands.xml)
Kobold.SpriteManager (static):
    GetUnitySprite(string) -> UnityEngine.Sprite
    GetTextureInfo(string, bool) ; TryGetTextureInfo(string, out exTextureInfo) ; HasTextureInfo(string)
GameManager (global namespace):
    static Instance (field) ; uiQueue, gameQueue (QupKit.ThreadTaskQueue) ; MainCamera
QupKit.ThreadTaskQueue:
    queueTask(Action, int delay) ; queueSingletonTask(...) ; executeTasks() ; HasTask() ; awaitTask(Action)
```

Player-stat APIs (name / hp / AV·DV·MA / weight / water / hunger …) are in
[`architecture.md`](architecture.md#player-stats-the-stats-block).
