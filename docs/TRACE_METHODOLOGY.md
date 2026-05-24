# Trace methodology

How we trace a game's screens, popups, and transitions before
writing accessibility code. Born out of the blind-first
redesign of CivViAccess (2026-05-22), generalized here so the
same playbook applies to Civ VI, Civ VII (purchased 2026-05-21
— see [[project_cross_game_foundation]]), and any future title
we ramp into.

## Why this exists

When a screen-reader user loads our mod, **they cannot see the
screen**. Every visual change must be auto-announced; every
state transition must guide. We cannot write input handlers,
auto-describe popups, or define hotkeys for a screen we have not
first traced from the engine source and understood end-to-end.

Six debug iterations on Civ VI's HexCursor (2026-05-21) were
spent chasing input-dispatch architecture before the real
blocker — an inaccessible first-turn modal popup — was
discovered. That's the failure mode this methodology prevents.

See [[feedback_trace_screens_in_code]] for the rule. See
[[project_blind_first_design_principle]] for the design stance
this serves.

## Scope — applies across games

This methodology applies to **every** screen, popup, or
transition we want to make accessible, in **every** Firaxis-
style game we work on. Not just new-game flow. Not just Civ VI.
Specifically:

- **Civ VI** — every chronological waypoint in the new-game
  flow (cataloged in
  [[BLIND_FIRST_TRACE_PLAN.md]]) AND every non-chronological
  screen reachable from MainMenu, pause menu, in-game shells,
  diplomacy, World Congress, era transitions, victory screens.
  Non-chronological screens live under
  `docs/flow-trace/screens/`.
- **Civ VII** — every screen, full stop. The same template, the
  same ruleset-variant requirement (with the game's own
  expansion / DLC structure substituted for R&F / GS), the same
  describer workflow, the same per-waypoint working pattern.
  When Civ VII work activates, mirror this directory layout
  under a sibling project (e.g., `civ-vii-access/docs/`) and
  reference this methodology by file rather than copying it.
- **Civ IV** (if work activates) — same.
- **Any future game** we ramp — same.

The point of generalizing this doc: when the next game starts,
we don't re-invent the methodology, we instantiate it.

## Template — every waypoint trace

Each screen / popup / transition gets its own trace file as the
source of truth until the work ships. File template:

```markdown
# NN — <waypoint name>

## Engine source
- Lua file(s) that own this screen/popup
- XML file(s) for visual layout
- Database tables relevant (rare)

## How it opens
- Triggering event (Events.X, LuaEvents.Y, button click, etc.)
- Preconditions (game state required)
- Where the trigger fires from

## What appears visually
- Title, body text, controls, portraits, animations
- Image asset paths (for the describer)
- Layout summary

## What it accepts as input
- Buttons + their callbacks
- Keyboard shortcuts (Enter, Esc, Tab, arrows)
- Mouse-only paths

## How it closes / advances
- Default dismiss path
- Each button's callback
- Events fired on close

## Ruleset / variant coverage
- Vanilla: does this waypoint exist? what's different?
- Each expansion / DLC layer: same questions.
- Each platform variant (in-game vs. front-end, console vs. PC)
  if behavior diverges.
- If divergence is large enough that one trace doc can't hold
  it cleanly, split into NN-vanilla.md / NN-rnf.md / NN-gs.md
  (or whatever the game's variant taxonomy is).

## Current accessibility state
- What screen-reader behavior exists (usually nothing)
- Where speech is currently silent
- What's already shipped vs. what's gap

## Blind-first design
- Auto-describe text on open (1-2 sentence brief)
- Visual descriptions for portraits/images (LOC keys + image
  paths to feed the describer)
- Expected-next-action guidance ("Press X to continue" / option
  presentation)
- Keyboard nav between options
- Dismiss key
- Deeper-info hotkeys (Ctrl+T mechanics, Ctrl+I image — per
  [[project_layered_info_hotkeys]])
- Per-variant speech differences if any

## Implementation notes
- File(s) to shadow or extend
- Events to subscribe to
- LOC strings to add
- Modinfo changes (if any)
- Variant gating: which conditionals the implementation needs

## Test plan
- Specific keystrokes + expected speech
- Run the full keystroke sequence under each variant and report
  per-variant pass/fail
```

Sections are mandatory — even if a section's content is
"none / N/A," write that explicitly so the next reader knows
the question was answered, not skipped.

## Trace in source, verify by playing

**Trace by reading code.** The base game's Lua + XML + DLC
overrides are the source of truth. Read them first. The user's
playthroughs are for **verification** (does what the trace
predicted match reality), not for **discovery** (figuring out
what happens by walking through the game with a screen reader
on).

Reasons:
- A screen-reader user trying to discover a flow they can't
  navigate is a Catch-22.
- The Lua source is more authoritative than memory: it tells
  us what *can* happen, not just what happened in one
  playthrough.
- Expansion / DLC divergences are often invisible during a
  single playthrough — they require diffing the base file
  against the DLC override.

The Civ VI override pattern: a same-named Lua/XML file in DLC
shadows the base. Identify what each layer adds or replaces and
write that into the trace doc.

## Variant coverage requirement

Most strategy games ship with multiple rulesets, expansions, or
DLC layers that change UI flow, available content, or popup
existence. Civ VI has Vanilla / Rise & Fall / Gathering Storm;
Civ VII has its own taxonomy; Civ IV had Warlords / Beyond the
Sword.

Every waypoint trace must cover all variants of the active
game — either via the per-doc "Ruleset / variant coverage"
section, or as parallel docs when divergence is too large to
hold in one doc.

The test plan must explicitly run keystrokes under each variant
and report per-variant pass/fail. Don't declare a waypoint
shipped until all variants pass.

## Image description workflow

Many traces surface image assets (leader portraits, advisor
avatars, natural wonders, civilization icons) that a sighted
player parses visually. The describer pipeline produces blind-
accessible descriptions:

**Stills vs. cinematics**:
- Stills (PNG / .dds / screenshots) — `tools/describe-image.py`
  for ad-hoc one-image, `tools/wonder-describer/describe.py`
  for batches.
- Cinematics — Omni Describer or AI-Studio video understanding
  (see [[project_omni_describer_trial_2026_05_15]] +
  [[project_audio_description_production_plan]]). Don't try to
  describe video frames with the still-image tools.

**Ad-hoc single-image**:
```powershell
python tools/describe-image.py --image path/to/img.png
```
Output: 1-2 sentence description to stdout; paste into the
trace doc.

**Batch**:
```powershell
cd tools/wonder-describer
python describe.py `
  --images images/<category>/ `
  --prompt prompts/<category>.txt `
  --output-json output/<category>.json `
  --output-xml ../../<mod>/Assets/Text/en_US/<Category>Descriptions.xml `
  --loc-prefix LOC_<MOD>_<CATEGORY>
```
Output: JSON + game-specific LOC XML registering at runtime
under `Locale.Lookup` keys. New asset categories: write a new
prompt file modeled on the existing ones.

**Roles**:
- Claude runs the describer. The user spot-checks the first
  few entries; if quality is good, trust the rest. If a
  description feels off, the user flags it and Claude refines
  the prompt + re-runs (skips already-described entries).
- API key (`GEMINI_API_KEY`) lives in the User environment
  variable so Bash inherits it; not in the script or config.

## Per-waypoint working pattern

1. **Claude traces one waypoint at a time.** Read the engine
   source, write the trace file with the full template filled
   out. Identify any images that need description.
2. **Claude runs the describer** for any image batch surfaced.
   User spot-checks.
3. **Claude implements.** Write the Lua/XML changes per the
   "Blind-first design" section. Register new LOC strings.
4. **User tests.** Specific keystrokes from the test plan.
   Reports pass/fail per variant.
5. **Move to the next waypoint.**

Don't try to ship a multi-waypoint chunk as a single release.
Each waypoint that ships is a marginal improvement. Cumulative
work reaches a release-able milestone naturally.

## Division of labor

Per [[feedback_civ_vi_division_of_labor]] — the user (Noel) owns
screen-reader UX calls: what to speak, how to phrase it, what
order to present options. Claude owns the codegen +
scaffolding from the engine source. Both are needed; neither
substitutes for the other.

Trace work specifically belongs in Claude's column — the user
shouldn't have to read 1700 lines of `Options.lua` to find out
what tabs the screen has. Claude reads, summarizes, writes the
trace doc; the user reviews and redirects if needed.

## Ramps before polish

Per [[project_ramps_before_polish]] — the trace work gates on:

- Waypoint is keyboard-dismissible / advanceable
- Every focusable control speaks label + state
- Every in-popup option (checkboxes, button choices) is
  reachable via arrow-key nav
- Critical text on screen is announced

Cinematic AD, rich visual descriptions, multi-paragraph
mechanics readouts are **finishing work** — note them in the
trace doc, ship the ramp, polish later.

## When to deviate from the template

The template is exhaustive on purpose so traces that span
new screen types still have a place to put each piece of
information. Skip sections only when they're genuinely
inapplicable, and say so explicitly:

```markdown
## Ruleset / variant coverage
**None.** This screen has no DLC override; same Lua under all
rulesets.
```

Don't drop a section silently — the next reader can't tell
"didn't apply" from "didn't bother."

## How to resume in a fresh context

1. Read this methodology doc.
2. Read the game-specific plan (for Civ VI, that's
   `docs/BLIND_FIRST_TRACE_PLAN.md`).
3. Read `MEMORY.md` and follow links to:
   - `project_blind_first_design_principle.md`
   - `feedback_trace_screens_in_code.md`
   - `feedback_civ_vi_division_of_labor.md`
   - `reference_gemini_credit_available.md`
4. Skim existing trace docs under `docs/flow-trace/` for the
   active game.
5. Pick the next waypoint that doesn't have a trace doc yet
   (or one whose user-notes indicate revision needed).
6. Trace it — engine source first, template second.
