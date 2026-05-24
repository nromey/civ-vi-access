# Blind-First Flow Trace Plan — Civ VI

The Civ-VI-specific instantiation of the trace methodology. The
master plan for redesigning Civ VI Access's in-game layer
around the blind-first principle. Started 2026-05-22 after six
debug iterations on HexCursor surfaced that the real blocker
was inaccessible modal popups, not the input-dispatch
architecture we'd been chasing.

**The methodology itself lives in [`TRACE_METHODOLOGY.md`](TRACE_METHODOLOGY.md)** —
game-agnostic, per-waypoint template, image-describer workflow,
ruleset-coverage requirement, working pattern, and division of
labor. Read it once, instantiate it per game. This file holds
only the Civ-VI-specific pieces: the waypoint catalog, the
specific Civ VI ruleset paths, and the design future for Civ VI
in particular.

For the next game (**Civ VII** purchased 2026-05-21, see
[[project_cross_game_foundation]]), instantiate the methodology
into a sibling `civ-vii-access/docs/` layout — same template,
same describer workflow, different waypoint catalog.

## Why this exists (Civ-VI specifically)

When the CivViAccess mod is loaded, **the player cannot see the
screen**. Every visual change that a sighted player would notice
must be auto-announced via speech. Every state transition must
guide the user on what to do next. We can't write input handlers
for screens we haven't first traced and described.

**Gating vs finishing.** This trace pass is about getting a
JAWS/NVDA user INTO gameplay — wheelchair ramps and stair lifts,
not interior decoration. Gating work for each waypoint:

- The waypoint is dismissible/advanceable from the keyboard.
- Every focusable control speaks label + state.
- Every in-popup option (checkboxes, button choices) is reachable
  via arrow-key nav.
- Critical text on screen is announced.

Cinematic AD (boot animation, expansion intros, leader cinematics)
and rich visual descriptions are **finishing work** that lands
later. Note them in the trace doc, leave a skip-the-cinematic
hotkey in place, then move on. Don't block a waypoint on its AD.

See [[project_blind_first_design_principle]] in memory for the
principle. See [[feedback_trace_screens_in_code]] for why we
trace before coding.

## Civ VI ruleset coverage

Civ VI ships three rulesets: **Vanilla**, **Rise and Fall**
(Expansion 1), and **Gathering Storm** (Expansion 2). The new-
game flow diverges meaningfully across them. Every waypoint
trace must cover all three — Noel owns the three variants, so
we can ramp them all. Specific Civ VI divergences:

- Vanilla has no intro popup after the load screen.
- R&F adds a Rise-and-Fall intro popup
  (`DLC/Expansion1/UI/Additions/ExpansionIntro.*`).
- GS adds a Gathering Storm intro popup
  (`DLC/Expansion2/UI/Additions/ExpansionIntro.*`) — this is
  shot2.
- AdvancedSetup parameter visibility flips per ruleset
  (`Visible` column on CriteriaRow); see
  [[reference_civ_vi_param_quirks]].
- All games start by displaying an animation/video with Firaxis
  Games and 2K which we should describe quickly.
- Available civs / leaders / city-states / natural wonders
  differ per ruleset.
- Era and World Congress mechanics affect first-turn flow.

Trace ruleset variants from source. Read `Base/Assets/UI/*.lua`,
`DLC/Expansion1/UI/**`, and `DLC/Expansion2/UI/**` to compare.
The expansion DLCs follow the override pattern where a same-
named Lua file in expansion DLC shadows the base one; identify
what each layer adds or replaces and write that into the trace
doc.

## Sequence of new-game waypoints (chronological)

These are in order from app launch through first-turn-interactive.
Each gets its own `docs/flow-trace/NN-name.md` (or parallel
ruleset variants).

0. **00-boot-animation.md** — Firaxis Games + 2K logo splash
   that plays before MainMenu. Cinematic (video), not a still
   image. **Gating work: make it skippable** (any key → straight
   to MainMenu, plus a "skip next launch" toggle). AD via Omni
   Describer or Google AI Studio is finishing polish, not gating.
   Ruleset-invariant.
1. **01-main-menu.md** — already partially accessible via
   `MainMenuAccess.lua`. Gap: `?` help doesn't work here (custom
   input handler, not BaseMenu). Out of scope for now; refer to
   existing memory. Ruleset-invariant.
2. **02-single-player-menu.md** — sub-menu of main menu. Already
   nav'd via MainMenuAccess. Ruleset-invariant.
3. **03-advanced-setup.md** — Create Game screen. **Fully
   accessible already** as of 0.3.9. Re-trace anyway to confirm
   it still works under the blind-first principle. Identify any
   visual elements (leader portraits in pulldowns) that aren't
   yet auto-described. **Per-ruleset section required**: civ
   list, leader list, parameter visibility (e.g., disaster
   intensity is GS-only).
4. **04-loading-screen.md** — `FrontEnd/LoadScreen.lua` + `.xml`.
   The Sean Bean civ-intro screen (shot1). Visible: civ name,
   leader name, abilities text, leader portrait. Sean Bean
   narrates the lore audio. **Currently speaks nothing.**
   Auto-announce on open: civ + leader + abilities. Describe
   leader portrait via the describer. Add "Loading, press any
   key to skip narration once you've heard it" guidance.
   **Per-ruleset section**: confirm same loader runs under all
   three; speech content per leader can reuse the same describer
   pass.
5. **05-expansion-intro-popup.md** — covers both R&F
   (`DLC/Expansion1/UI/Additions/ExpansionIntro.*`) and GS
   (`DLC/Expansion2/UI/Additions/ExpansionIntro.*`, shot2). One
   doc with side-by-side ruleset sections if the file structure
   is parallel; split if not. **Does not exist in Vanilla** —
   note that under "Ruleset variants" and skip to 06 for vanilla
   playthroughs.
6. **06-first-turn-advisor-popup.md** — already half-handled by
   `SuppressFirstTurnAdvisor.lua` (sets `HasChosenTutorialLevel = 1`).
   For a proper accessible version: announce advisor portrait +
   greeting, present the two button options as a choice menu,
   accept arrow-key nav, Enter to activate. Source:
   `Base/Assets/UI/TutorialScenarioBase.lua` lines 47-89. This
   popup is base-game, so it appears under all three rulesets;
   confirm the file isn't shadowed in expansion DLC.
7. **07-leader-portrait-cinematic.md** — does Civ VI play a
   leader-intro cinematic on first turn? Investigate. May
   differ per ruleset (some leaders are expansion-only).
8. **08-first-unit-selection.md** — engine auto-selects the
   Settler/Warrior. Partially handled by
   `ScreenReaderEventHandlers.lua`. Verify what announces, what
   doesn't. Likely ruleset-invariant, but starting units can
   differ per civ.
9. **09-your-turn-announcement.md** — `LocalPlayerTurnBegin`
   event. Our diagnostic announces this; finalize the speech.
   Ruleset-invariant.
10. **10-world-interactive-baseline.md** — the first moment the
    user can move the cursor. HexCursor work proper resumes
    here. Verify InputActionTriggered fires for our actions
    (after the Configuration-DB-only modinfo fix).
    Ruleset-invariant for cursor mechanics, but tile contents
    (resources, features) differ per ruleset.

Additional waypoints we'll discover as we trace.

## Non-chronological screens

Reachable from MainMenu, pause menu, or anywhere outside the
chronological new-game flow. Each gets its own trace under
`docs/flow-trace/screens/`. List grows as we identify them:

- **`screens/options.md`** — Options / Settings menu. Largely
  shipped via `OptionsAccess.lua`; KeyBindings tab is the
  explicit gap. The KeyBindings work also produces the
  authoritative runtime catalog of Civ VI's native input
  actions + default bindings (supersedes the hand-collected
  [[reference_civ_vi_default_keybindings]] memory).

Future non-chronological screens to trace as they become
priorities:
- Mods picker (MainMenu → Additional Content → Mods)
- Multiplayer browser + lobby
- Load Game / Save Game dialogs
- In-game pause menu (the menu that raises Options from in-game)
- Civilopedia (in-game → ? or menu)
- World Congress (mid-game popup, GS only)
- Diplomacy screen (mid-game)
- Espionage screen (mid-game)
- Reports screens (era summary, victory progress)
- Victory / defeat screens (end-game)

## Out of scope for now

- Tutorial system inside the game (post-first-turn advisor
  prompts when the player builds something, founds a city, etc.)
  Comes after the new-game flow is solid.
- Mid-game popups (diplomacy, espionage, era transitions, victory
  conditions). Same — after new-game flow.
- Sighted mode / per-player profile UI. After accessibility
  baseline is solid.
- Civ VII port. After Civ VI Access reaches end-to-end playability.

## Per-player accessibility profile (future, not v0.5)

Eventually each player slot gets an accessibility profile (blind,
sighted, low-vision, monitoring) selected at AdvancedSetup time
or in mod settings. The mod auto-switches profile on
`Events.PlayerTurnActivated` based on who's playing this turn.
For now, the mod assumes blind for every turn; sighted players
can suppress via a single toggle later.

Memory: [[project_blind_first_design_principle]] sec "Sighted-
mode toggle (future)" and the per-player vision Noel articulated
2026-05-22.
