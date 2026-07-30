extends Node

## SINGLE SOURCE OF TRUTH for the project's name and the fixed external facts around
## it (the base game, store links, legal placeholders). Registered as the "Brand"
## autoload (see project.godot) so every script refers to `Brand.GAME_NAME` instead
## of hardcoding the string — the name may change, and when it does this is the ONE
## place to edit.
##
## Anything marked with «guillemets» is a deliberate PLACEHOLDER awaiting a real
## value (exact legal entity, org name, donation link). They render literally so a
## placeholder is never mistaken for a finished string.

# ── the project ──────────────────────────────────────────────────────────────
const GAME_NAME := "Raves of Qud"
const GAME_TAGLINE := "a 3D viewer for Caves of Qud"
const ORG_NAME := "«the organization that makes Raves of Qud»"   # placeholder
const LICENSE := "MIT"

## The base Caves of Qud release this 1:1 build was reconstructed against — shown on the
## title screen's version corner in 1:1 mode (in place of Raves' own name/licence), matching
## Qud. Reference build (measured off a 1.0.5 title capture); TODO: source dynamically from the
## mod's title export so it tracks the player's actual install instead of being pinned here.
const QUD_VERSION := "1.0.5"
const QUD_BUILD := "2.0.211.50"

# ── the base game it renders ─────────────────────────────────────────────────
const BASE_GAME := "Caves of Qud"
const BASE_GAME_RIGHTS_HOLDER := "Freehold Games"   # confirm the exact legal suffix (LLC?) for formal use
const STEAM_APPID := "333640"

# ── links (open in the user's browser) ───────────────────────────────────────
const URL_STEAM := "https://store.steampowered.com/app/333640/Caves_of_Qud/"
const URL_GOG := "https://www.gog.com/game/caves_of_qud"
const URL_ELSEWHERE := "https://www.cavesofqud.com/"
const URL_STEAM_RUN := "steam://rungameid/333640"   # launches an installed copy
const URL_DONATE := "«donation link for Raves of Qud»"   # placeholder

## Convenience: the window/title string. Kept here so a rename only touches Brand.
static func title() -> String:
	return GAME_NAME

## The right-hand-panel legal / attribution copy. Best-faith, plain-language summary —
## NOT legal advice. Assembled from the constants so a rename or a confirmed rights
## holder flows through automatically. Returned as an Array of {head, body} sections
## so the menu can style headings distinctly from body text.
static func attribution_sections() -> Array:
	return [
		{
			"head": "%s artwork & content" % BASE_GAME,
			"body": ("All %s artwork, tiles, text, audio, and game content are the "
				+ "property of %s and are used here only to render a copy the player "
				+ "already owns. No such assets are redistributed by %s.") % [
					BASE_GAME, BASE_GAME_RIGHTS_HOLDER, GAME_NAME],
		},
		{
			"head": "No AI-generated assets",
			"body": ("No artwork or content in %s was created with generative AI. "
				+ "%s renders the original assets from your installed copy of %s.") % [
					GAME_NAME, GAME_NAME, BASE_GAME],
		},
		{
			"head": "%s is %s-licensed" % [GAME_NAME, LICENSE],
			"body": ("%s itself is released under the %s license: anyone may use it for "
				+ "anything — as-is or refactored, free or commercial.") % [GAME_NAME, LICENSE],
		},
		{
			"head": "The license does NOT extend to %s" % BASE_GAME,
			"body": ("The %s license covers only %s's own code. It grants no rights to "
				+ "%s's artwork, content, or licenses. Anyone using %s has a fiduciary "
				+ "due-diligence duty to ensure NO %s assets are released or distributed.") % [
					LICENSE, GAME_NAME, BASE_GAME, GAME_NAME, BASE_GAME],
		},
		{
			"head": "Requires a purchased copy",
			"body": ("%s requires a purchased and downloaded copy of %s and will not "
				+ "run without it.") % [GAME_NAME, BASE_GAME],
		},
	]
