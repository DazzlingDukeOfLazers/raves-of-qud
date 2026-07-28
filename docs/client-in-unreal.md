# How to build a Raves client in Unreal

Read [client-in-unity.md](client-in-unity.md) first if you haven't — it lays out the contract
in full. This page is the same client, ported to **Unreal Engine 5** (C++ with optional
Blueprint glue). Nothing about the bridge changes: the mod and the
[wire protocol](protocol.md) are engine-agnostic, and the Godot project in `godot/` is just the
reference consumer.

```
  Caves of Qud + bridge mod  ──frames──▶  a client that renders + sends input
        (engine-agnostic)                    (Godot today; Unreal here)
```

> You do **not** touch the mod. Deploy it to your Qud install per the README, then point Unreal
> at `127.0.0.1:48710`.

---

## The contract (recap)

The client's ten responsibilities are identical to the Unity port — see the table in
[client-in-unity.md](client-in-unity.md#the-contract-you-must-honour). Frames are
`[4-byte big-endian length][UTF-8 JSON]`; snapshots are full state (coalesce to newest);
classify each object wall→prism / `layer ≤ 2`→ground / else→billboard; resolve colours; recess
actors in liquid; map input to `command` frames. This page only swaps *how* Unreal does each.

---

## Project shape

```
Source/Raves/
  FBridgeRunnable      TCP framing + reconnect on an FRunnable worker thread   (port of BridgeClient.gd)
  ABridgeClient        AActor: owns the runnable, marshals snapshots to game thread, sends commands
  FSnapshot            USTRUCTs + FJsonObjectConverter parse
  AZoneRenderer        AActor: snapshot -> ISM/quads (walls / floors / billboards)  (port of ZoneRenderer.gd)
  UTileCache           UObject: tilesDir path map + PNG -> UTexture2D + glyph fallback
  QudColor             colour-string / palette resolution                       (port of _qud_color)
```

Enable the **Sockets**, **Networking**, **Json**, **JsonUtilities**, and **ImageWrapper**
modules in your `.Build.cs`:

```csharp
PublicDependencyModuleNames.AddRange(new[] {
    "Core", "CoreUObject", "Engine", "Sockets", "Networking",
    "Json", "JsonUtilities", "ImageWrapper", "ProceduralMeshComponent" });
```

---

## 1. The socket — an FRunnable worker + game-thread hand-off

Unreal's `UObject`/actor API is **game-thread-only**, exactly like Unity's main thread. Run the
blocking socket read on an `FRunnable` and marshal each finished snapshot back with
`AsyncTask(ENamedThreads::GameThread, …)` (or a lock-guarded queue drained in `Tick`).

```cpp
// FBridgeRunnable.h  (sketch)
class FBridgeRunnable : public FRunnable
{
public:
    TFunction<void(TSharedPtr<FJsonObject>)> OnSnapshot;  // invoked on GAME thread
    TFunction<void()> OnConnected;

    virtual uint32 Run() override
    {
        while (bRun)
        {
            FSocket* Sock = ISocketSubsystem::Get(PLATFORM_SOCKETSUBSYSTEM)
                ->CreateSocket(NAME_Stream, TEXT("raves"), false);
            TSharedRef<FInternetAddr> Addr = MakeAddr(TEXT("127.0.0.1"), 48710);

            if (Sock && Sock->Connect(*Addr))
            {
                bConnected = true;
                AsyncTask(ENamedThreads::GameThread, [this]{ if (OnConnected) OnConnected(); });

                while (bRun && Sock->GetConnectionState() == SCS_Connected)
                {
                    FlushOutbox(Sock);                      // send queued command frames

                    uint8 Len[4];
                    if (!ReadExact(Sock, Len, 4)) break;
                    int32 N = (Len[0] << 24) | (Len[1] << 16) | (Len[2] << 8) | Len[3];
                    TArray<uint8> Payload; Payload.SetNumUninitialized(N);
                    if (!ReadExact(Sock, Payload.GetData(), N)) break;

                    FString Text = FString(N, UTF8_TO_TCHAR((const char*)Payload.GetData()));
                    TSharedPtr<FJsonObject> Obj;
                    auto Reader = TJsonReaderFactory<>::Create(Text);
                    if (FJsonSerializer::Deserialize(Reader, Obj) && Obj.IsValid())
                        AsyncTask(ENamedThreads::GameThread,
                            [this, Obj]{ if (OnSnapshot) OnSnapshot(Obj); });
                }
            }
            bConnected = false;
            if (Sock) { Sock->Close(); ISocketSubsystem::Get(PLATFORM_SOCKETSUBSYSTEM)->DestroySocket(Sock); }
            FPlatformProcess::Sleep(1.0f);                  // retry ~once per second
        }
        return 0;
    }
    // ReadExact loops Sock->Recv until N bytes or failure (TCP is a stream — never assume one Recv == one frame).
};
```

**Coalesce on the game thread.** Because snapshots are full state, only the newest matters per
tick. If several arrive between `Tick`s, render just the last — the Godot client hard-crashed
its Metal allocator by rebuilding a zone per queued snapshot. Buffer incoming `TSharedPtr`s in
`ABridgeClient` under a `FCriticalSection` and, in `Tick`, take the last and drop the rest.

**Priming.** Send one `wait` command on `OnConnected`, or the first render never arrives (the
mod only publishes on change).

---

## 2. Parsing — USTRUCTs + FJsonObjectConverter

Declare USTRUCTs mirroring [docs/protocol.md](protocol.md) and let
`FJsonObjectConverter::JsonObjectToUStruct` fill them. Model optional fields as defaulted;
`objs` is heterogeneous (a ground layer has `bGround=true` and no glyph, a creature has
`bSinks=true`).

```cpp
USTRUCT() struct FQudObj {
    GENERATED_BODY()
    UPROPERTY() FString name, display, glyph, tile, color, tilecolor, detail;
    UPROPERTY() FString fgHex, bgHex, detailHex;   // present only when RenderTile fired
    UPROPERTY() int32 layer = 0;
    UPROPERTY() bool ground=false, wall=false, sinks=false, bridge=false, liquid=false, onFire=false;
    UPROPERTY() float lightRadius = 0.f;
};
USTRUCT() struct FQudCell {
    GENERATED_BODY()
    UPROPERTY() int32 x=0, y=0, nHeld=0, nRendered=0, nSent=0, light=0;
    UPROPERTY() bool bridge=false, wade=false, swim=false;
    UPROPERTY() TArray<FQudObj> objs;
};
USTRUCT() struct FQudSnapshot {
    GENERATED_BODY()
    UPROPERTY() FString type, mod, tilesDir;
    UPROPERTY() int32 protocol = 0;
    UPROPERTY() FQudZone zone;
    UPROPERTY() FQudVec2 player;
    UPROPERTY() TArray<FQudCell> cells;
    // palette: parse from the raw FJsonObject (a string->string map) — USTRUCT maps to TMap<FString,FString>.
    UPROPERTY() TMap<FString, FString> palette;
};
```

---

## 3. Version handshake

Same logic as [client-in-unity.md §3](client-in-unity.md#3-the-version-handshake): compare
`Snapshot.protocol` against `ClientProtocol`/`MinModProtocol` constants and surface a one-line
status (green up-to-date / red restart-Qud / yellow re-export-client). Bump `ClientProtocol`
when you start depending on a new field; raise `MinModProtocol` to match. History: `1` baseline,
`2` `liquid`, `3` `onFire`.

---

## 4. Tiles — `tilesDir` map + PNG decode + glyph fallback

`Creatures/sw_bearman.png` → `tilesDir/Creatures_sw_bearman.png` (slashes→underscores). Decode
the PNG bytes into a `UTexture2D` with `IImageWrapper`. Files export on-demand, so treat a
missing file as "known missing", draw the glyph, and retry on a later snapshot.

```cpp
UTexture2D* UTileCache::Load(const FString& TilesDir, const FString& Tile)
{
    if (Tile.IsEmpty()) return nullptr;
    if (auto* Found = Cache.Find(Tile)) return *Found;               // may be nullptr == known-missing
    FString Path = FPaths::Combine(TilesDir, Tile.Replace(TEXT("/"), TEXT("_")));
    TArray<uint8> Bytes;
    if (!FFileHelper::LoadFileToArray(Bytes, *Path)) { Cache.Add(Tile, nullptr); return nullptr; }

    IImageWrapperModule& M = FModuleManager::LoadModuleChecked<IImageWrapperModule>("ImageWrapper");
    TSharedPtr<IImageWrapper> W = M.CreateImageWrapper(EImageFormat::PNG);
    TArray<uint8> Raw;
    if (!W->SetCompressed(Bytes.GetData(), Bytes.Num()) || !W->GetRaw(ERGBFormat::BGRA, 8, Raw))
        { Cache.Add(Tile, nullptr); return nullptr; }

    UTexture2D* Tex = UTexture2D::CreateTransient(W->GetWidth(), W->GetHeight(), PF_B8G8R8A8);
    Tex->Filter = TF_Nearest;                                        // pixel art
    void* Data = Tex->GetPlatformData()->Mips[0].BulkData.Lock(LOCK_READ_WRITE);
    FMemory::Memcpy(Data, Raw.GetData(), Raw.Num());
    Tex->GetPlatformData()->Mips[0].BulkData.Unlock();
    Tex->UpdateResource();
    Cache.Add(Tile, Tex);
    return Tex;
}
```

The **static-layer self-heal race** applies here too: the per-turn dynamic layer retries a
missing tile for free, but a once-per-zone static wall/fence built before its tile exported
bakes a permanent glyph. Flag missing tiles during the static build and rebuild the zone on a
later snapshot (bounded, like `STATIC_RETRY_MAX`).

---

## 5. Render classification → Unreal primitives

```cpp
enum class EKind { Wall, Ground, Billboard };
EKind Classify(const FQudObj& O)
{
    if (O.wall)        return EKind::Wall;
    if (O.layer <= 2)  return EKind::Ground;
    return EKind::Billboard;   // layers: 0 clutter, 3 trees, 7 rock walls, 10 creatures
}
```

- **Wall** → an **Instanced Static Mesh** (`UInstancedStaticMeshComponent`) of a unit cube: one
  component, one instance per wall cell, one draw call for the whole zone (Unreal's analogue of
  Godot's greedy-meshed rock). Instance transform at `(x, y, 0)` in your grid basis.
- **Ground** → a flat plane ISM instance (or a single `UProceduralMeshComponent` floor), tile as
  the material's base texture.
- **Billboard** → a camera-facing plane. Use a `UMaterial` with **World Position Offset**
  billboarding, or a `UStaticMeshComponent` you spin in `Tick`. Recess by the water fraction (§7).

Keep the **static/dynamic split**: build walls/floors/scenery **once per zone entry**; rebuild
only creatures/`liquid`/`onFire` each turn. Per-instance tint via a **Dynamic Material Instance**
(`CreateDynamicMaterialInstance` + `SetVectorParameterValue("BaseColor", …)`), or
`PerInstanceCustomData` on the ISM for the wall tint.

Unreal is **Z-up and centimetre-scaled** by default; Godot is Y-up. Pick a grid basis (e.g. one
cell = 100 uu on X/Y, height on Z) and keep it in one place — this axis swap is the single most
common porting bug.

---

## 6. Colours

Identical rules to [client-in-unity.md §6](client-in-unity.md#6-colours): prefer resolved
`fgHex`/`bgHex`/`detailHex` when present, else look the trailing colour char up in the
snapshot's `palette` map. `k` is `#0f3b3a` (dark teal — the Qud world colour, not black); Qud
letters aren't web names (`Y`=white, `y`=gray, `W`=gold, `w`=brown).

```cpp
FLinearColor Resolve(const FString& Qud, const TMap<FString,FString>& Palette, const FString& FgHex)
{
    if (!FgHex.IsEmpty()) return FLinearColor(FColor::FromHex(FgHex));
    FString C = LastColorChar(Qud);                     // "b" from "&b^B" foreground
    if (const FString* Hex = Palette.Find(C)) return FLinearColor(FColor::FromHex(*Hex));
    return FLinearColor(1,0,1);                          // loud magenta fallback
}
```

---

## 7. Water & bridges

The water stays flat; the actor recesses. Cancel on `bridge`; only sink `sinks` objects.

```cpp
float SinkFraction(const FQudCell& C, const FQudObj& O)
{
    if (C.bridge || !O.sinks) return 0.f;
    if (C.swim) return 0.6f;
    if (C.wade) return 0.3f;
    return 0.f;
}
// Billboard->AddLocalOffset(FVector(0,0,-SinkFraction(C,O) * SpriteWorldHeight));  // Z-up
```

A `bridge` object draws as a flat opaque quad (fill the art's transparent field with ground
colour) lifted above the water it spans.

---

## 8. Input → commands

Bind **Enhanced Input** actions (or legacy input) to `command` frames. The reference bindings
(`Main.gd`): numpad → `move` + compass `dir`; Shift+Space → `wait`; S/D → `key` (Qud runs
whatever the player bound them to). The sim resolves the turn; new state returns as the next
snapshot.

```cpp
void ABridgeClient::Move(const FString& Dir)   // bound to your MoveN/S/E/W actions
{
    SendCommand(TEXT("move"), { { TEXT("dir"), Dir } });   // Dir in {N,S,E,W,NE,NW,SE,SW}
}
void ABridgeClient::SendCommand(const FString& Name, const TMap<FString,FString>& Extra)
{
    TSharedRef<FJsonObject> O = MakeShared<FJsonObject>();
    O->SetStringField("type", "command");
    O->SetStringField("name", Name);
    for (const auto& KV : Extra) O->SetStringField(KV.Key, KV.Value);
    FString Json; auto W = TJsonWriterFactory<>::Create(&Json);
    FJsonSerializer::Serialize(O, W);
    Enqueue(FrameFromJson(Json));   // [4-byte BE length][UTF-8] onto the runnable's outbox
}
```

---

## Validate like the Godot client does

Use the repo's Python tools (`tools/capture/snap.py`, [docs/tools.md](tools.md)) to read raw
snapshots off the wire and confirm your USTRUCT parse and classification match the reference
before trusting the Unreal render. The algorithms are validated in Python first *so that* a new
client can self-check without a human watching the viewport.

---

## What you are *not* porting

Same boundary as everywhere: the mod, protocol, tile export, worldgen, AI and saves stay in Qud.
An Unreal client is only planes 2–3 of the
[legacy-integration-playbook](legacy-integration-playbook.md) — render state, send input. If you
start reimplementing game logic, it belongs behind the socket.

See [migrating-clients.md](migrating-clients.md) for the portable-vs-engine-specific split and a
port checklist.
