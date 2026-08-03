# Qud options — "1:1, no effects" reference

A snapshot of Caves of Qud's `PlayerOptions.json` tuned to strip the visual effects
that get in the way of pixel-comparing Qud vs Raves. Captured 2026-07-30 from
`~/Library/Application Support/com.FreeholdGames.CavesOfQud/Local/PlayerOptions.json`.

Use it to restore the comparison state (copy the JSON below back over that file, or
match the settings in Qud's Options screen).

## Visual effects — what's OFF vs still ON

Disabling an effect removes it from Qud's render, shrinking the surface area of
difference against Raves (which renders none of these). Two option shapes:
`Display/Use X = No` means the effect is **off**; `Disable X = No` means it is **on**.

### Already OFF (Daniel's "no effects" edit)
| Option | Value | Effect removed |
|---|---|---|
| `OptionDisplayVignette` | No | corner darkening (the thing that dimmed the avatar) |
| `OptionDisplayScanlines` | No | CRT scanline interlace |
| `OptionUseParticleVFX` | No | particle VFX (sparks, motes) |
| `OptionUseTextParticleVFX` | No | floating text particles |
| `OptionUseOverlayCombatEffects` | No | combat hit flashes/overlays |
| `OptionUseOverlayDamageText` | No | floating damage numbers |
| `OptionDisplayBrightness` / `OptionDisplayContrast` | 0 / 0 | neutral — no brightness/contrast shift |
| `OptionMasterVolume` | 0 | (audio muted — not visual, just noted) |

### Still ON — candidates to disable for a smaller diff surface
| Option | Value | Recommendation |
|---|---|---|
| **`OptionDisableAllIdleTileAnimations`** | No (ON) | **→ Yes.** Biggest one: idle tiles animate (water shimmer, torch flicker, glow pulse), so they change frame-to-frame and make any pixel diff noisy/unrepeatable. Freeze them for a stable 1:1. |
| **`OptionDisableFullscreenColorEffects`** | No (ON) | **→ Yes.** Any fullscreen color grade can shift tile colors — exactly the axis we're matching. |
| `OptionDisableSmoke` | No (ON) | → Yes if smoke drifts over the scene (campfires/brinestalk). |
| `OptionDisableTextWarpEffects` / `OptionDisableTextAnimationEffects` / `OptionDisableFullscreenWarpEffects` | No (ON) | minor for tile comparison (text/warp) — optional. |
| `OptionDisableFloorTextures` / `OptionDisableFloorTextureObjects` | No (ON) | leave ON — Raves renders floors too; disabling changes the ground, not an "effect". |
| `OptionDisableImposters` | No (ON) | leave — distant-tile LOD, not a visible effect up close. |
| `OptionDisableBloodsplatter` | No (ON) | only appears in combat; irrelevant at rest. |

**Top two to flip next: `OptionDisableAllIdleTileAnimations` and
`OptionDisableFullscreenColorEffects` → Yes.**

## Full options JSON (verbatim, for restore)

```json
{
    "OptionAllowCSMods": "Yes", "OptionOverlayMinimap": "No", "OptionShowAdvancedOptions": "Yes",
    "OptionMusicBackground": "Yes", "OptionMasterVolume": "0", "OptionMusicVolume": "15",
    "OptionDisplayFullscreen": "No", "OptionOverlayNearbyObjects": "No", "OptionLogTurnSeparator": "Yes",
    "OptionIndentBodyParts": "Yes", "OptionDropAll": "No", "OptionSound": "Yes", "OptionSoundVolume": "100",
    "OptionMusic": "Yes", "OptionAmbient": "Yes", "OptionAmbientVolume": "50", "OptionUseInterfaceSounds": "Yes",
    "OptionInterfaceVolume": "100", "OptionUseCombatSounds": "Yes", "OptionCombatVolume": "100",
    "OptionPlayFireSounds": "Yes", "OptionDisplayBrightness": "0", "OptionDisplayContrast": "0",
    "OptionDisplayResolution": "Unset", "OptionDisplayFramerate": "60", "OptionUseTiles": "Yes",
    "OptionDisplayVignette": "No", "OptionDisplayScanlines": "No", "OptionUseOverlayCombatEffects": "No",
    "OptionUseOverlayDamageText": "No", "OptionUseParticleVFX": "No", "OptionUseTextParticleVFX": "No",
    "OptionDisableFloorTextures": "No", "OptionDisableBloodsplatter": "No", "OptionDisableSmoke": "No",
    "OptionDisableImposters": "No", "OptionDisableFullscreenColorEffects": "No",
    "OptionDisableTextAnimationEffects": "No", "OptionDisableAllIdleTileAnimations": "No",
    "OptionDisableTextWarpEffects": "No", "OptionDisableFullscreenWarpEffects": "No",
    "OptionPlayScale": "Fit", "OptionTileScale": "1", "OptionThrottleAnimation": "No",
    "OptionModernUI": "Yes", "OptionUseTiles": "Yes"
}
```

(Trimmed to the display/effect-relevant keys; the live file also holds input,
audio, autoget, and debug options unrelated to the tile comparison.)
