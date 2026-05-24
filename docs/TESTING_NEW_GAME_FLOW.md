# New-game flow test plan — waypoints 04, 05, 06, 08, 09, 10

Mark each step with `**** pass` after verifying.
If a step fails, write `**** FAIL: <symptom>` and we'll bisect.

This plan covers the end-to-end flow from clicking Start on AdvancedSetup
through the world becoming interactive on turn 1.

## Quick launch — paste this each session

```powershell
dotnet build CivViAccess/CivViAccess.csproj
.\CivViAccess\bin\Debug\net10.0-windows\CivViAccess.exe
```

Rebuild + launch in order. Skip the rebuild only if you're confident no source has changed since the last build.

## Fix log (chronological)

Most recent first. This is the running log of what we've fixed across test rounds.

### Round 14 (2026-05-23)

Round-13 confirmed: portrait brief speaking ("Trajan. A thin, grey-haired man..."), action IDs registered (`repeat=91 abilities=88 portrait=90 transcript=89`), but R/T/I/S still not dispatching. Two fixes + one architectural recognition.

- **Fixed double-dot at end of portrait brief**. LOC template `{1_LeaderName}. {2_PortraitBrief}.` added a trailing `.` to descriptions that already ended with one. Removed the trailing period; describer SHORT lines end with `.` themselves.
- **R/T/I/S actions changed from `ContextId="World"` to `ContextId="Universal"`**. Civ VI gates InputAction dispatch by context — World-bound actions don't fire during `InputContext.Loading` (LoadScreen window). Universal (Value=0) fires regardless. Other contexts available per `InputConfiguration.xml`: Default, Universal, StartupGame, Shell, Loading, Ready, World, Diplomacy, GameOptions, EndGame, Popup, Reveal, FullscreenMap, Tutorial. Universal is the right choice for global hotkeys.
- **City panel access is unbuilt**: pressing Enter on a city opens the production screen which is mouse-only. No keyboard-accessible way to set production / research / etc. yet. Big multi-session project; queued.

### Round 13 (2026-05-23)

Round-12 confirmed notifications working (4 announces after founding city), but exposed two real bugs.

- **`LeaderDescriptions.xml` is now in `<Files>` manifest**. Round-12 portrait lookup diagnostic showed `result='LOC_CIVVIACCESS_LDR_LEADER_TRAJAN_SHORT'` (key returned unchanged = not found). Modding.log confirmed the file wasn't loaded — it was referenced in two `<UpdateText>` blocks but missing from the `<Files>` manifest, which Civ VI requires for packaging. Now declared in `<Files>`; portrait briefs should resolve correctly next launch.
- **Eager InputAction ID lookup at LoadScreenAccess load**. Round-12 log showed `LoadScreenAccess: subscribed to InputActionTriggered` (subscription succeeded) but no `LoadScreenAccess actions:` line (lookupActionIds only fired lazily inside the handler, which never ran because no R/T/I/S action triggered). Now calls `lookupActionIds()` eagerly at file load — next run will tell us whether the engine actually registered our 4 new actions (non-nil action IDs) or whether the XML registration is silently failing.

### Round 12 (2026-05-23)

Two real bugs surfaced from round-11 log + one diagnostic.

- **Fixed notification API call**. Round-11 log showed `function expected instead of nil` thrown on every NotificationAdded event — my code called `pPlayer:GetNotifications():FindByID(id)` which was a guess; the correct Civ VI API is `NotificationManager.Find(playerID, notificationID)` (confirmed by reading `Base/Assets/UI/Panels/NotificationPanel.lua`). Notifications should now actually speak.
- **Diagnostic added to portrait brief lookup**. Round-11 briefing said "Trajan." with no description, despite `LeaderDescriptions.xml` being registered and containing `LOC_CIVVIACCESS_LDR_LEADER_TRAJAN_SHORT`. Added a Log.info that prints `leaderType`, the constructed LOC key, and the lookup result so we can see whether Locale.Lookup is missing the key or returning something unexpected.

### Known issues (deferred, will iterate)

- **TutorialReset doesn't restore FIRST_GREETING re-fire** — the user-options flag reset works (`HasChosenTutorialLevel = 0`), but the engine's tutorial-item Completed state seems to persist somewhere else (probably tutorial DB, not user options). No accessible API to clear it. The advisor popup INFRASTRUCTURE is proven working (round 5 captured FIRST_GREETING firing through it cleanly); other tutorial popups will use the same path when they fire on a fresh-state profile.
- **Tab not firing NextUnit** — no log entry. Need targeted test with NumLock toggle / NVDA browse-mode off.
- **R/T/I/S as engine InputActions not yet confirmed firing** — round-11 log doesn't show the `LoadScreenAccess actions: ...` diagnostic line which would print if any of those actions triggered. Either the InputAction registration didn't take effect, OR Noel didn't press R/T/I/S in a moment when they'd fire. Re-test next round.

### Round 11 (2026-05-23)

Three additions on Noel's ask: notifications, R/T/I/S as InputActions, and TutorialReset for repeatable testing.

- **Notification announce**: `Events.NotificationAdded` subscribed in `ScreenReaderEventHandlers`. New notifications (research available, civic available, production queue empty, etc.) speak as `"Notification. <summary>"` (NOINTERRUPT). Round-10 log showed 3 notifications firing after founding city with no audio — now they speak.
- **R / T / I / S registered as engine InputActions**. Round-9 found that letter keys never reach LoadScreen's `OnInput` during `InputContext.Loading`. Workaround: register 4 new actions (`CIVVIACCESS_RepeatBriefing` / `_AbilitiesReread` / `_PortraitDescribe` / `_DawnOfManTranscript`) in `RemapForHexCursor.xml`, bound to R/T/I/S. `LoadScreenAccess` subscribes to `Events.InputActionTriggered` — engine action dispatch is independent of context routing. Rebound the conflicting defaults: `T → ToggleTechTree → Alt+T`, `R → RangedAttack → Alt+R` (same Alt-prefix pattern we used for Q/E/A/Z/C). Actions fire globally; in-game presses also call the speak* functions, which are no-ops if briefing isn't built. Slightly weird in-game behavior; harmless for now.
- **TutorialReset gameplay script** (debug-only). Resets `HasChosenTutorialLevel`, `HasSeenXP1FeaturesScreen`, `HasSeenXP2FeaturesScreen`, and a few other tutorial flags to 0 on every game start so tutorial popups fire fresh during testing. Has `DISABLE_RESET` boolean inside; flip to true (or remove file) once tutorial flow is validated. Critical insight that prompted this: Civ VI's tutorial state is per-profile-not-per-save, so "start a new game from scratch" tests our flows ONCE and never again.

### Round 10 (2026-05-23)

Diagnostic for Tab-not-cycling issue from round 8. Round-8 log showed NextUnit action never firing despite Tab presses, and no way to tell whether Tab was reaching Civ VI at all or being intercepted upstream (NumLock, NVDA, etc.).

- **Always-on audible confirmation** for a curated set of in-game actions: NextUnit ("Next unit"), PrevUnit ("Previous unit"), EndTurn ("End turn"), SkipTurn ("Skip turn"), FoundCity ("Found city"), Sleep ("Sleep"), Fortify ("Fortify"), Alert, Attack, AutoExplore, PauseMenu, QuickSave, QuickLoad. These speak via Tolk every time the engine action fires, regardless of `DIAGNOSTIC_SPEECH` setting. Functional purpose, not diagnostic chatter — user needs to know e.g. "Found city" registered when they press B. Diagnostic purpose: if Noel presses Tab and hears nothing, Tab was intercepted before Civ VI saw it. If Noel hears "Next unit", Tab IS reaching the engine and the cycling logic is working. Asked Noel to test with/without NumLock to bisect.

### Round 9 (2026-05-23)

Round-8 results were strong on Sean Bean flow (briefing alone, Sean on Enter), but uncovered four issues:

- **Portrait brief now actually fires in briefing**. Round-8 log showed briefing saying just "Trajan." without the visual description, even though `LeaderDescriptions.xml` is loaded and contains `LOC_CIVVIACCESS_LDR_LEADER_TRAJAN_SHORT` ("A thin, grey-haired man in a silver muscle cuirass with gold trim stands before a dark, embossed world map."). Root cause: my code gated the lookup on `Locale.HasTextKey`, which doesn't exist in Civ VI's Lua API — it was always nil, so the gate always failed. Switched to `Locale.Lookup` + check-for-key-returned-unchanged pattern (Civ VI returns the key as-is when not found). Trajan's portrait brief now speaks immediately after the leader name.
- **Post-Sean prompt added**. Noel: "nothing was spoken at the end of Sean to tell user what's next." When Enter triggers `startDawnOfManSpeech`, we now also queue "Dawn of Man speech playing. Press Enter when you are ready to begin the game." through Tolk (NOINTERRUPT). Tolk and engine audio are independent streams so the prompt plays roughly when Sean starts rather than when he ends, but the user hears the cue and knows what to do.
- **First-turn orientation hint corrected** to reflect Enter's actual in-game behavior: Civ VI's Enter is bound to EndTurn, but when units still need orders, EndTurn cycles to the next unit instead of ending the turn. That's why Noel saw Enter "cycle between Settler and Warrior, not sure what I do with them." New hint: "Press B to found a city here with the Settler. Press Tab or Enter to cycle to other units that need orders. When every unit has an order, pressing Enter ends the turn."

### Deferred to a later round

- **R / T / I / S hotkeys in LoadScreen don't reach our handler** for letter keys (round-8 log: only Tab / CapsLock / Alt / Pause / Numpad got logged in HandleKey; no letters). The engine appears to route letter keys differently during `InputContext.Loading`. Likely fix: register R / T / I / S as engine InputActions (like our HexCursor Q/W/E/A/D/Z/X/C), which would dispatch via `Events.InputActionTriggered` regardless of context routing. Bigger change; punted to a later round.
- **Tab not cycling units in-game** — round-8 log shows no `NextUnit` action firing despite the binding. Possibly NumLock state or screen-reader Tab interception. Investigate next round if it persists.

### Round 8.1 (2026-05-23) — quick addition

- **Added R / Ctrl+R = repeat full briefing** in the LoadScreen window. Previously T re-read abilities only, I/S re-read portrait/transcript. There was no key to repeat the whole briefing if the user missed the start. Hotkey hint now leads with R.

### Round 8 (2026-05-23)

Sean Bean redesign per Noel's directive: "default sean bean on, but sean comes in after telling user to press enter. Togglable allows him to be turned off and display all of the stuff. ... that's how the true game is played, the user by default gets to hear that awesome voiceover."

- **Sean Bean OFF at engine-default, opt-in via Enter** — Sean is no longer auto-played by the engine. `LoadScreenAccess.ShouldPlayDawnOfMan()` always returns false so the engine's `Play_DawnOfMan_Speech` site is skipped. When the user presses Enter (and the `PLAY_SEAN_BEAN` setting is true, which is the default), `startDawnOfManSpeech()` fires `UI.PlaySound` directly. This gives us the "briefing first, then Sean" sequencing without needing a timer to detect when briefing ends — Sean only plays in response to a user keypress.
- **Toggle setting `PLAY_SEAN_BEAN`** (defaults true). When true: briefing skips the leader paragraph, briefing ends with "Press Enter for Dawn of Man speech" prompt, Sean plays on first Enter, game starts on second Enter. When false: briefing INCLUDES the leader paragraph (so blind player gets the full text via Tolk), no Sean prompt, Enter starts the game directly. No settings UI yet — toggle is a code constant for now; settings work is queued for after the new-game-flow ramps are clean.
- **Briefing decision prompt is now setting-aware** — "Press Enter to start the Dawn of Man speech, or Escape to skip to the game" when Sean is on; "Press Enter or Escape when ready to begin the game" when off.
- **Keypress flow**: Enter pre-Sean → starts Sean. Enter post-Sean (or with Sean disabled) → starts game. Escape any time → skips everything, starts game (engine stops Sean via `STOP_SPEECH_DAWNOFMAN` on the way out).

### Round 7 (2026-05-23)

Round-6 wins: "Ancient Era." (no more double "Era"), advisor popup spoke once, first-turn orientation queued behind LoadScreenClose, advisor activation announces confirmation. Three issues to address:

- **"Loading complete" no longer interrupts the briefing**. Round-6 log showed `LoadScreen: #SCREENREADER - Loading complete...` firing with interrupt priority while the briefing was still in Tolk's queue, chopping it mid-paragraph. Switched to NOINTERRUPT so it queues behind the briefing tail. On fast machines load completes mid-briefing; on slow machines briefing finishes well before load. Either way the user now hears the full briefing first, then the "Loading complete" cue.
- **"Creating game." announce on LoadScreen OnShow** (per Noel's suggestion: "Recommend speaking 'Creating game' until it starts reading"). Fires the moment the loading screen appears, before briefing data is even resolved. Queued (NOINTERRUPT) so it doesn't cut off the prior AdvancedSetup → click-Start speech. Briefing then follows naturally as data resolves.
- **Documented in-game T conflict**: bare T was working in LoadScreen context (between briefing and pressing Enter), but Noel pressed T AFTER starting the game and got "page flip" sound. Round-6 log confirmed T in-game = engine action `ToggleTechTree` (id 66). The engine consumes T before our handler can see it. Re-read of the briefing post-LoadScreen-close needs a different mechanism (likely a new engine InputAction, deferred). For now: T/I/S re-read only works in the LoadScreen window (after "Creating game" and before pressing Enter to begin the game).

### Round 6 (2026-05-23)

Round-5 milestone: advisor popup spoke + arrow nav worked + bare arrows for nav confirmed. Five smaller issues surfaced; fixing all in one pass.

- **Fixed "Ancient Era Era." duplicate** — LOC template was `{1_Era} Era.` but Civ VI's era Name LOC already includes "Era" (e.g. "Ancient Era"). Template now just `{1_Era}.` → speaks "Ancient Era." cleanly.
- **Dedupe advisor popup announce** — engine raised FIRST_GREETING twice in rapid succession (once via TutorialUIRoot, once via queued-popup drain). Popup got spoken twice. Added a 2-second signature-based dedupe in NotifyShow: same message + button text within 2s skips the re-announce.
- **Post-activation confirmation speech** — Noel reported "pressed enter, nothing happened" on the advisor popup. `activateFocused` now speaks "{choice} chosen." before invoking the button callback, so the activation is audibly confirmed. Plus a Log.info trace so we can see in the log whether activation is being invoked.
- **Bare T / I / S keys** in AdvisorPopupAccess AND LoadScreenAccess. Round-5 log showed Ctrl state isn't held when letter keys release (`keyup=84 ctrl=false` — Ctrl was released before T's keyup arrived). NVDA might be intercepting Ctrl, or the engine consumes it before our handler sees the release. Either way, requiring Ctrl was unreliable. Bare T (re-read), I (portrait), S (transcript) are now accepted as alternates. Safe to use bare here because both contexts (LoadScreen, AdvisorPopup) block engine actions.
- **Deferred first-turn orientation until LoadScreenClose** — round-5 log showed the Settler-selected orientation ("Settler on Plains (Hills). 2 moves remaining. Temperate region. Press B to found city...") firing inside `OnLoadGameViewStateDone` BEFORE LoadScreenClose, while the briefing was still in Tolk's queue. That was the "position info interrupted the readback" Noel reported. ScreenReaderEventHandlers now subscribes to LoadScreenClose; if UnitSelectionChanged fires before LoadScreenClose, the orientation is queued and replayed once the load screen closes.

### Round 5 (2026-05-23)

Triaged from round-4 results. Round 4 wins: Sean Bean suppression working ("No Sean Bean still"), briefing reading mostly intact, Enter starts game, adjacent-thing announcements working ("Mercury to the west and other things"), advisor popup at least APPEARED on screen.

- **Fixed the AdvisorPopupAccess type-annotation bug**. Round-4 diagnostics revealed the exact root cause: `m_currentData :table = nil` had a strict type annotation, but Civ VI passes an `AdvisorItem` hstructure (not a plain table) to NotifyShow. Havok Script's type check threw on the assignment: `expected 'table', but got instance of 'AdvisorItem'`. The function aborted before `m_visible = true`, so every HandleKey call saw visible=false and ignored input. **One-character fix** (removing the `:table` annotation) unblocks the entire advisor popup nav. The other access modules (`LoadScreenAccess`, `ExpansionIntroAccess`) have `:table` annotations too but they're assigned plain Lua tables, not hstructures, so they're safe.
- **Diagnostic Log.info added to LoadScreenAccess.HandleKey**. Round 4 had zero HandleKey log entries from LoadScreen — meaning either (a) input isn't being delivered to LoadScreen's context post-load (engine context-dispatch issue), or (b) HandleKey IS being called but had no logging to prove it. Adding a per-keyup log line so round 5 reveals which. If we still see no LoadScreen HandleKey logs, Ctrl+T/I/S in the LoadScreen window need a different input-routing strategy (probably registering them as engine InputActions like our HexCursor keys).

### Round 4 (2026-05-23)

Triaged from round-3 results: HexCursor QWEADZC nav now working (real milestone), but advisor popup STILL not speaking, and diagnostic chatter from HexCursorAddin was confusing the user ("camera pan up/down" speech on every arrow press).

- **Granular diagnostic prints in AdvisorPopup wrapper**. Round-3 fix moved NotifyShow into the wrapper, but the log still showed `ShowAdvisorPopup INVOKED` without `NotifyShow called` — meaning something between the INVOKED print and the NotifyShow invocation is failing silently. New prints now log: advisorData fields (msg, button text), `AdvisorPopupAccess` type, `AdvisorPopupAccess.NotifyShow` type, "About to call NotifyShow", pcall result with error message if it throws, and "NotifyShow returned successfully" on success. Round-4 log will show exactly where the chain breaks.
- **HexCursorAddin DIAGNOSTIC SPEECH MODE turned off** by default. The addin's diagnostic chatter (speaking every fired engine action like "Action CameraPanUp", and state-change events like "Your turn" / "Load screen closed" / "Interface mode changed") is now gated behind a `DIAGNOSTIC_SPEECH` boolean defaulting false. HexCursor's own move announcements (terrain, features) still fire — those go through `HexCursor.move` not the diagnostic announcer. Logging stays in place via Log.info for traceability. Flip the boolean to true to re-enable for future debugging sessions. ALSO addresses Noel's observation that "hex cursor something" interrupted the leader briefing text — that was this diagnostic announcer cutting in via Tolk's interrupt path while the briefing was still in queue.

### Round 3 (2026-05-23)

Triaged from round-2 Lua.log evidence + Noel's round-2 observations.

- **AdvisorPopupAccess.NotifyShow now fires from the wrapper, not from inside the original `ShowAdvisorPopup`**. Round-2 log showed `ShowAdvisorPopup INVOKED` printed but `NotifyShow called` did not — meaning the original engine body errored or returned early before reaching the bottom-of-function NotifyShow call. Moved the hand-off into the diagnostic wrapper at the TOP of `ShowAdvisorPopup`, so the access layer arms (m_visible=true, button count, focus state) regardless of whether the rendering body completes. Round-2 every HandleKey call logged `visible=false` despite the popup being on screen — this fixes that.
- **Sean Bean re-suppressed by default, Enter starts the speech.** Round-2 confirmed that briefing + Sean Bean playing concurrently produced unparseable audio (both recite the same leader paragraph). Restored the briefing-first design: Tolk speaks briefing immediately; Sean Bean fires only when user presses Enter (pre-load) or stays silent if user presses Escape to skip.
- **Diagnostic prints in AdvisorPopup remain** (ShowAdvisorPopup INVOKED, HandleKey keyup logging). Useful while we're still chasing the popup behavior.

### Round 2 (2026-05-23)

Triaged from round-1 results.

- **Launcher log-tail bug fixed in CAMM** (commit 75f8c51). The prior version read Lua.log in 1024-byte chunks and split each chunk independently — lines crossing the chunk boundary were truncated and follow-on lines silently dropped. The 12-line loading-screen briefing burst (~1.6KB) reliably triggered this. CAMM now buffers partial lines across reads and decodes as UTF-8 instead of ASCII. This was the root cause of "Tolk didn't speak the briefing at all" in round 1.
- **Briefing content trimmed**: era now uses `startEra.Name` ("Ancient Era") instead of `startEra.Description` (a 100-word flavor paragraph). Briefing skipped the leader info paragraph because Sean Bean recites it concurrently (later reversed in round 3: now Sean Bean is suppressed by default so the briefing can speak it without overlap, but actually we kept the paragraph out of auto-speech since Ctrl+S re-reads it on demand and that's a cleaner UX).
- **Hotkey constraint documented**: Civ VI sets `InputContext.Loading` during the loading screen, which appears to suppress Lua input dispatch. Ctrl+T/I/S won't work until the engine changes context (typically inside `OnLoadGameViewStateDone`, several seconds after the briefing finishes).
- **Diagnostic prints added** to the advisor popup path (ShowAdvisorPopup wrapper, NotifyShow, HandleKey) — surfaced the round-3 root cause.
- **`SuppressFirstTurnAdvisor.lua` disabled** in modinfo so FIRST_GREETING can be tested.

## Pre-test setup (one time)

1. Civ VI stores user options in engine-managed storage (no Options.txt file). The relevant flags — `HasChosenTutorialLevel`, `HasSeenXP1FeaturesScreen`, `HasSeenXP2FeaturesScreen` — default to 0 on a fresh install. **The Tutorial section of the in-game Options screen is not yet keyboard-accessible**, so we can't reset these mid-test. Strategy: run Tests 1 → 2 → 3 → 4 in order on a single fresh-install pass. Each popup fires once during its respective test, then gets marked 1 by the engine — which is the state Test 4 wants to verify.
2. The FIRST_GREETING popup is base-game (no ruleset variants) and one-shot per profile. It fires once in Test 1; Tests 2 and 3 should NOT see it reappear (HasChosenTutorialLevel is now 1). That's expected.
3. Confirm the CivViAccess mod is enabled in Additional Content.
4. Launch the game using the command at the top of this file.

## Test 1 — Vanilla ruleset (waypoints 04, 06, 08, 09, 10)

5. From MainMenu, Single Player, Create Game. Pick Vanilla ruleset.
6. Pick any leader (Trajan recommended for a known Settler+Warrior start).
7. Click Start Game. Loading screen appears.
8. Verify the briefing auto-announces something like: "Roman Empire. Join the world stage. Ancient Era. Trajan. Unique abilities and features. [each ability/unit/building]. Press Control plus T to re-read abilities. Control plus I for full leader description. Control plus S for Dawn of Man transcript. Press Enter to start the Dawn of Man speech, or Escape to skip to the game."
9. Verify Sean Bean does NOT start automatically. The briefing speaks alone in a clear audio channel.
10. Press Enter. Verify Sean Bean's Dawn of Man voice-over now starts.
11. **Wait for "Loading complete. Press Enter or Escape to begin the game." speech** before testing the next hotkeys. Civ VI suppresses Lua input dispatch during the loading-screen window; Ctrl+T/I/S don't reach our handler until that announce fires. (This is an engine constraint, not a bug we can patch.)
12. After "Loading complete": Press Control plus T. Verify the abilities list re-speaks.
13. Press Control plus I. Verify it speaks "Leader portrait description not yet available" (placeholder until describer batch runs).
14. Press Control plus S. Verify it speaks the leader info paragraph (the text Sean Bean was reciting).
15. Press Enter or Escape. Verify the game proceeds to world view (Sean Bean stops if still playing, loading screen closes).
16. No expansion intro popup should appear (Vanilla has none) — skip to step 17.
17. The first-turn advisor popup appears. Verify it announces: "Tutorial advisor. [welcome message]. Choose: option 1 of 2, New to the Civilization series. Use Left or Right to switch options, Enter to confirm. Press Control plus I for advisor description. Press Control plus T to re-read."
18. Press Right arrow. Verify it announces: "Option 2 of 2: New to Civilization 6."
19. Press Left arrow. Verify it announces: "Option 1 of 2: New to the Civilization series."
20. Press Control plus T. Verify the welcome message re-speaks (with "Tutorial advisor." prefix).
21. Press Control plus I. Verify it speaks "Advisor portrait description not yet available."
22. Press Escape. Verify it speaks "This choice is required. Press Left or Right to switch options, Enter to confirm." and the popup does NOT close.
23. Press Right then Enter (selecting "New to Civilization 6"). Popup closes.
24. Verify "World interactive. Press question mark for help." announces.
25. Verify the first-turn orientation announces: "Settler on [terrain]." then "[N] moves remaining." then "[Polar/Temperate/Subtropical/Tropical] region." then optionally "Visible nearby: [resources]." then optionally adjacent units/cities, then "Press B to found city here. Press Tab to cycle units. Press End Turn when ready."
26. Press Tab to cycle to the Warrior. Verify a TERSE announce ("Warrior on [terrain]" plus adjacency) — NOT a repeat of the long first-turn orientation.
27. Press End Turn (Enter on the End Turn hotkey, or wait for engine processing). On the next turn begin, verify "Turn 2." announces.
28. Play through a couple of turns. Verify each turn begin announces "Turn N."

## Test 2 — Rise and Fall ruleset (waypoints 04, 05 R&F, 08, 09, 10)

29. From MainMenu, Single Player, Create Game. Pick Rise and Fall ruleset. Pick any leader.
30. Click Start Game. Wait through the loading screen briefing (same as Test 1 steps 8-15).
31. The Rise and Fall expansion intro popup appears. Verify it announces: "Welcome to Rise and Fall. Page 1 of 9. [welcome description]. Press Right or N for next page, Left or P for previous, T to toggle 'Do not show again', Control plus I for illustration description, Control plus T to re-read, Enter or Escape to close."
32. Press Right arrow. Verify "Page 2 of 9. [Eras description]." announces.
33. Press N. Verify "Page 3 of 9. [Ages description]." announces.
34. Press P. Verify "Page 2 of 9. [Eras description]." announces (P goes back).
35. Press Left arrow. Verify page 1 announces again.
36. Press Control plus T. Verify the current page description re-speaks.
37. Press Control plus I. Verify "Illustration description not yet available." announces.
38. Press T. Verify "Do not show again, on." announces.
39. Press T. Verify "Do not show again, off." announces.
40. Navigate to page 9 (press Right repeatedly). Verify each page announces, and page 9 announces "Last page. Press Enter to continue to the game." in addition to the description.
41. Press Enter on page 9. Popup closes.
42. The first-turn advisor popup should NOT appear (HasChosenTutorialLevel set from Test 1). Verify it doesn't.
43. Verify world interactive + first-turn orientation announce (per Test 1 steps 24-25).

## Test 3 — Gathering Storm ruleset (waypoints 04, 05 GS, 08, 09, 10)

44. From MainMenu, Single Player, Create Game. Pick Gathering Storm ruleset. Pick any leader.
45. Click Start Game. Wait through the loading screen briefing (Test 1 steps 8-15).
46. The Gathering Storm expansion intro popup appears.
47. Verify it announces: "Welcome to Gathering Storm. Page 1 of 12. [welcome description]. ..." with the same nav hint as R&F.
48. Press Right several times. Verify each page announces, page count is 12 (not 9), and GS-specific topics appear (World Congress, Volcanoes, Climate / Environment, Strategic Resources).
49. Press T to toggle "do not show again" on then off.
50. Press Escape. Popup closes (Esc dismisses, doesn't require navigating to last page).
51. The first-turn advisor popup should NOT appear (HasChosenTutorialLevel set from Test 1).
52. Verify world interactive + first-turn orientation announce.

## Test 4 — Re-show suppression (waypoint 05)

53. After Test 3 finishes, start ANOTHER new Gathering Storm game.
54. Wait through the loading screen briefing.
55. Verify the GS expansion intro popup does NOT appear (HasSeenXP2FeaturesScreen is now 1).
56. Verify world interactive + first-turn orientation announce (the rest of the flow still works).

## Test 5 — Regression checks

57. From MainMenu, the existing AdvancedSetup screen still works end-to-end (Tab between groups, arrow nav, leader pulldown, Start Game).
58. From in-game (after Test 1 or later), press Esc to open the pause menu. Verify it works.
59. From the pause menu, open Options. Verify the Options screen still works (Tab between tabs, arrow nav within tab, slider Left/Right adjustment).
60. From the pause menu, find the "Show expansion intro" option (if exposed). Trigger it. Verify the expansion intro popup re-shows mid-game (this is the OnShowFromMenu path).
61. (If pause-menu trigger isn't easily reachable, skip this step.)

## Cleanup after tests pass

62. Once Test 1 through Test 4 all pass: delete `CivViAccessMod/Assets/UI/Accessibility/SuppressFirstTurnAdvisor.lua` and remove its references in `CivViAccessMod/CivViAccessMod.modinfo` (the commented-out line in `<AddGameplayScripts>` and the line in `<Files>`). The advisor wrapper handles the popup properly; the safety net is no longer needed.

## Known UX gaps (deferred, not test failures)

- **Long-list nav friction**: leader picker, civ list etc. have no type-ahead and no PageUp/Down for fast nav. Generic missing pattern across pulldowns; tackle after the new-game-flow ramps are clean.
- **Custom earcons** (clip sound, page-flip, ready chime) — placeholder uses an existing engine sound. The .wav files in `Assets/Sounds/` are ready for integration once Civ VI's custom-audio path is solved.
- **Real leader portrait descriptions** — Ctrl+I says "not yet available" until the describer batch runs on Advisors128.dds and leader portrait .dds files.
- **Real intro-diagram descriptions** — same for the expansion slideshows (21 diagrams, prompt + assets ready, batch not yet run).
- **Real Dawn of Man hand-transcribed transcripts** — Ctrl+S currently uses the LOC_LOADING_INFO_<leader> paragraph as stand-in.
- **Clip-to-file session journal** — system clipboard works (UI.SetClipboardString); file output deferred per `project_clip_to_file_session_journal` memory.
- **Tutorial section of in-game Options screen** — not yet keyboard-accessible. Sequencing puts accessible tutorial work AFTER rudimentary map navigation (waypoint 10 / HexCursor) is solid.
