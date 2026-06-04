# Group A Popup — Retest ROUND 4 (listener pivot)

## What changed (big architecture shift)
`ReplaceUIScript` is a confirmed dead end: Modding.log proved user mods apply
as a block BEFORE all official DLC, so we can never replace a context the DLC
hasn't created yet. So we STOPPED trying to shadow the 5 DLC popups. Instead a
new headless addin, **RevealListeners**, subscribes to the same trigger events
(hero discovered, society discovered/joined, disaster, rock band, era change)
and **announces** — the vanilla popup still shows and handles its own dismiss.

Only the 5 DLC popups are affected. NaturalWonder / WonderBuilt / ProjectBuilt /
BoostUnlocked / TechCivic are unchanged — skip them.

## Setup
1. **Relaunch the launcher** (deploys the new addin + modinfo). Close game first.
2. Load the GS save (Heroes + Secret Societies modes). Get in-game. Attach FireTuner2.

## STEP 1 — did the listener load? (the key signal)
Search Lua.log for:  `RevealListeners.lua: loaded`
- Found? ____   (full line is "RevealListeners.lua: loaded; subscribed to reveal events")

If yes, the addin is live and listening. (Note: you will NOT see the 5
"HeroesPopup: RevealPopupAccess.lua: loaded" lines anymore — that approach is
gone. The single RevealListeners line is the new signal.)

## STEP 2 — debug raisers (announce a real sample, no waiting for live events)
These now speak a real sample (Hercules, Owls of Minerva, first disaster type,
a debug band, the current era) — so they exercise the name + description lookup.

```
LuaEvents.CivViAccess_DebugRaisePopup("Heroes")
```
- speaks "Hero discovered. Hercules. … <visual description>"? ____

```
LuaEvents.CivViAccess_DebugRaisePopup("SecretSociety")
```
- speaks "Secret society discovered. Owls of Minerva. … <visual description>"? ____

```
LuaEvents.CivViAccess_DebugRaisePopup("NaturalDisaster")
```
- speaks "Natural disaster. <name>"? ____

```
LuaEvents.CivViAccess_DebugRaisePopup("RockBand")
```
- speaks "Rock band concert. The Debug Band. 42 tourism gained"? ____

```
LuaEvents.CivViAccess_DebugRaisePopup("EraComplete")
```
- speaks "New era. <current era>. <age verdict>"? ____

## STEP 3 — (optional) live event
If you happen to discover a hero / hit a disaster / complete an era in normal
play, note whether it announced on its own. The vanilla popup should appear;
confirm you can dismiss it (Escape).

## Notes
(I'll pull Lua.log directly — just say roughly what each said or didn't.)
- If a debug raiser says the lead-in + "Press Escape to dismiss" but no name/
  description, the GameInfo lookup for that one is off — tell me which.
