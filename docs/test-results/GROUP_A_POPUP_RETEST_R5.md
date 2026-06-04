# Group A Popup — Retest ROUND 5 (hero modal: R/T/I/S briefing idiom)

## What changed
The reveal modal now uses the game-start **leader-briefing key idiom** — speak
the bulk on open, then bounded facets on constant keys:
- R = repeat the whole open-announce
- T = abilities / mechanical block
- I = full visual (appearance) description
- S = transcript / "what was said" (reserved; heroes have none)
- Enter / Space / Escape = dismiss

The HERO modal is the flagship this round. On open it now speaks name + lore +
lifespan/charges + short visual; T reads the combat profile + passive abilities +
active commands (with charge costs); I reads the full appearance. It reuses the
game's own Heroes & Legends data (an `include` of the DLC's HeroesSupport).

Only the hero PATH gained new content. The other popups picked up the R key and a
reworded hint but no new facets — that's a light regression check at the end.

NOTE: re-read moved from T to **R**. T now means abilities. Muscle-memory change.

## Setup
1. Start the game however you normally do. I copied the two changed files straight
   into the DLC dir, but if your launcher redeploys from the embedded build it
   could overwrite them with stale copies — so once you're in-game, ping me and
   I'll re-verify/re-copy before you test (one command, avoids a wasted cycle).
2. Load a game with **Heroes & Legends mode ON**. Get in-game. Attach FireTuner.

## STEP 1 — did the listener load?
Search Lua.log for:  `RevealListeners.lua: loaded`
- Found? ____

## STEP 2 — raise the hero modal (Hercules)
```
LuaEvents.CivViAccess_DebugRaisePopup("Heroes")
```
2a. On open, does it speak roughly:
    "Hero discovered. Hercules. Demigod of superhuman strength, renowned for his
    Labors. Lifespan 30 turns, 6 ability charges. <short visual>. Press R to
    repeat, T for abilities, I for appearance, Enter to dismiss." ? ____
2b. KEY SIGNAL: are "Lifespan 30 turns, 6 ability charges" present in the open
    line? ____  (If MISSING, the HeroesSupport include didn't resolve from our VM
    — note it; everything else still works but T/stats will be empty.)

## STEP 3 — the four keys (leave the modal open)
3a. Press T — reads combat line + passives + commands? e.g. "Combat strength 48,
    3 movement. Rugged: Ignores Movement penalties in Hills terrain. Hercules'
    Labor: <help, costs 2 charges, ends turn>. Hercules' Rage: <help, costs 1
    charge>." ? ____
    (T SILENT = the include didn't resolve. The abilities are the tell.)
3b. Press I — reads the long appearance description (detailed portrait)? ____
3c. Press R — repeats the whole open-announce from the top? ____
3d. Press S — does NOTHING for a hero (no transcript). Confirm it neither speaks
    nor breaks anything. ____
3e. Press Enter — modal dismisses, back to the game? ____

## STEP 4 — Escape + key-capture sanity
4a. Raise it again, press Escape — dismisses? ____
4b. While open, do R/T/I/S stay captured (NO stray unit/map actions fire from the
    letter keys)? ____

## STEP 5 — spot-check a different hero (optional, ability variety)
The 2nd arg picks a specific hero. Wukong has 3 passives + 0 commands; Mulan has
2 passives. Good for confirming the ability list varies per hero.
```
LuaEvents.CivViAccess_DebugRaisePopup("Heroes", "HEROCLASS_WUKONG")
LuaEvents.CivViAccess_DebugRaisePopup("Heroes", "HEROCLASS_MULAN")
```
5a. Wukong: open mentions lifespan ~50, and T lists 3 passives (Disguise /
    Immortality / Swift), no commands? ____
5b. Mulan: T lists her 2 passives? ____

## STEP 6 — light regression on a non-hero popup
```
LuaEvents.CivViAccess_DebugRaisePopup("NaturalDisaster")
```
6a. Opens + speaks the disaster announce, now ending "Press R to repeat, Enter to
    dismiss." ? ____
6b. R repeats, Enter dismisses? ____

## STEP 7 — LIVE-PATH test (the real plumbing) — RELAUNCH first
Steps 2-6 prove the CONTENT. This proves the live race the debug raiser skips:
real vanilla popup shows, we defer one frame, dequeue it, land on top owning
input. `DebugTriggerReal` fires the REAL discovery event so the actual vanilla
HeroesPopup appears alongside ours.

IMPORTANT: relaunch (`dotnet run`) first — the running game loaded the listener
at startup and won't hot-pick-up the new hook from disk.
```
LuaEvents.CivViAccess_DebugTriggerReal("Hero")
```
7a. Our hero modal opens + speaks the full announce (same as step 2)? ____
7b. R / T / I still work while it's up? ____
7c. Enter dismisses cleanly AND leaves you back in the game — no leftover vanilla
    popup stuck on screen, no stuck input? ____
7d. Any sign of the vanilla popup itself (a visual flash, or a SECOND dismiss
    needed after Enter)? ____  (Ideally none — ours should replace it seamlessly.)
7e. (I'll check the log) if it warns "no hero origin building", the vanilla popup
    may have thrown on its own claim-help — harmless to us, but say if the modal
    misbehaved.

## STEP 8 — found-wonder cinematic deferral (the voice-collision fix)
The natural-wonder voiced quote no longer talks over our announce — it's now held
behind Enter (Sean-Bean style), and the quote TEXT rides the S key.
```
LuaEvents.CivViAccess_DebugRaisePopup("NaturalWonder")
```
8a. On open our announce speaks with NO voiced narration over it (clean)? ____
    Hint should end "...S for the quote, Enter to play the quote." ____
8b. Press Enter — the game's voiced quote plays now, and the popup STAYS open
    (does NOT dismiss)? ____
8c. Press Enter again (or Escape) — dismisses? ____
8d. Press S — reads the quote TEXT aloud (our speech, not the game voice)? ____
8e. R and I still work? ____
Same shape for world wonders: `CivViAccess_DebugRaisePopup("WonderBuilt")`.

## Notes
- I'll pull Lua.log directly — just say roughly what each key did or didn't.
- The single most important signal across the whole round: **does T speak the
  abilities?** That confirms the cross-VM include of the DLC's HeroesSupport
  resolved, which is the linchpin of the rich-hero approach. If it didn't, I have
  a fallback (replicate the extraction inline) ready.
