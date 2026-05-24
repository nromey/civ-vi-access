# 06 — First-turn advisor popup (FIRST_GREETING + AdvisorPopup wrapper)

The modal popup that appears immediately after the loading
screen (and after the expansion intro, if shown) showing the
tutorial advisor's portrait, a welcome message, and **two
buttons** asking the player to choose their experience level:
"New to the Civilization series" vs "New to Civilization VI."
This choice persistently sets the tutorial level, which gates
many later tutorial popups.

This is the **second modal that blocks the world for blind
players** ([[project-first-turn-popups-block-input]]). Today,
the engine has hotkeys for "Continue" but those only trigger
the FIRST button — a blind player pressing Enter unknowingly
chooses "New to series" with no way to pick the other option.
Our existing [[SuppressFirstTurnAdvisor.lua]] sidesteps it by
setting `HasChosenTutorialLevel = 1` so it never appears; we
need to replace that with a real accessible version.

Scope note: AdvisorPopup is a **generic tutorial modal** used
by many tutorial items, not just FIRST_GREETING. Our access
wrapper must handle every advisor popup, not just the first
one. FIRST_GREETING is the most complex case (2-button choice);
most others are 1-button "OK" dismissals.

## Engine source

- `Base/Assets/UI/Popups/AdvisorPopup.lua` (525 lines) — the
  generic modal renderer
- `Base/Assets/UI/Popups/AdvisorPopup.xml` (70 lines) — layout
- `Base/Assets/UI/TutorialScenarioBase.lua` (1465 lines) — item
  definitions including FIRST_GREETING (lines 47-89)
- `Base/Assets/UI/TutorialUIRoot.lua` — orchestrator that fires
  `LuaEvents.TutorialUIRoot_AdvisorRaise(item)` with populated
  `AdvisorItem`
- DLC overrides for AdvisorPopup itself: **none**. Generic to
  all rulesets. Expansion1 adds its own
  `TutorialUIRoot_Expansion1.lua` but reuses the same
  AdvisorPopup renderer.
- Tutorial item definitions in expansions:
  - R&F: `DLC/Expansion1/Data/Tutorial_*.xml` (data-driven items)
  - GS: `DLC/Expansion2/Data/Tutorial_*.xml`
  - Both fire through the same AdvisorPopup contract.

## How it opens

Two paths:

**Auto-raise** (the default for FIRST_GREETING):
- `TutorialUIRoot.lua` watches the engine event the item
  registered (`SetRaiseEvents`)
- FIRST_GREETING raises on `LoadScreenClose` (the event waypoint
  04 fires when player clicks Begin Game)
- Item's `SetRaiseFunction` checks gating conditions:
  - `UserConfiguration.TutorialLevel()` is 0 or 1 (novice)
  - `Options.GetUserOption("Tutorial", "HasChosenTutorialLevel") == 0`
- If gated open, fires `LuaEvents.TutorialUIRoot_AdvisorRaise(item)`
- AdvisorPopup's `OnAdvisorRaise(item)` → `ShowOrQueuePopup(item)`
- If popup priority is free, `ShowAdvisorPopup(advisorData)` runs

**Manual queue / explicit raise**:
- Tutorial system can queue popups for later via
  `ShowOrQueuePopup` (used if a higher-priority popup is showing)
- Drained via `OnUIIdle` when the popup queue is free

## What appears visually

Two layout variants depending on `advisorData.ShowPortrait`:

**Portrait variant (`AdvisorBase`)** — used for FIRST_GREETING:
- `Window` — 529x208 word-bubble texture (Advisor_WordBubble)
- `TitleText` — "ADVISOR" header
- `InfoImage` — optional inline image (hidden for most items)
- `InfoString` — the main message body (e.g., "Hello, I'm here
  to help you on your journey...")
- `ButtonStack` — horizontal row of dialog buttons
- `AdvisorPortrait` — 200x200 glowing circle backing,
  containing a 134x134 circle backing, containing a 128x128
  `Advisors128` texture (an atlas of advisor icons; specific
  advisor is indexed by ID)
- AlphaAnim + SlideAnim — fades in from top with a 0.5s pause
  before audio cue

**Meta variant (`MetaBase`)** — used for non-portrait popups:
- `MetaWindow` — 500x208
- `MetaTitleText`, `MetaInfoString`, `MetaButtonStack` — same
  shape, no portrait
- Used for system messages, alerts, in-game tutorials that don't
  have a "speaking advisor" framing

**FIRST_GREETING specifically renders**:
- Title: "ADVISOR"
- Message: `LOC_ADVISOR_LINE_FTUE_1` ("Hello! I'm here to
  help you on your journey through history…" — approximate;
  the actual text is in `AdvisorText.xml`)
- Audio: `Play_ADVISOR_LINE_FTUE_1` (voiced)
- Portrait: tutorial advisor character (Advisors128 atlas)
- Button 1: `LOC_TUTORIAL_NEW_TO_CIV` ("New to the
  Civilization series")
- Button 2: `LOC_TUTORIAL_NEW_TO_CIV_6` ("New to
  Civilization VI" — i.e., familiar with the series but new to
  this title)

## What it accepts as input

`OnInputHandler` → `KeyHandler` (lines 396-412):
- **Esc** → fires `LuaEvents.Tutorial_ToggleInGameOptionsMenu`
  (opens the pause menu — NOT dismisses the popup!)
- **Enter** (debug builds only — `not UI.IsFinalRelease()`) →
  fires `m_hotkeyCallback` which is button 1's callback
- All other input consumed by `IsBlockingInput()` returning true

Engine action hotkeys via `OnInputActionTriggered` (lines 366-373):
- `TutorialContinue` (engine action, default = Enter/Space) →
  fires `m_hotkeyCallback` (button 1)
- `TutorialContinueAlt` → same
- `TutorialShowMore` → not handled here

Mouse: button 1 + button 2 click handlers via
`AddAdvisorButton` (line 74). Each registered with `Mouse.eLClick`.

**The key accessibility gap**: there is **NO keyboard nav
between button 1 and button 2**. The engine hotkey only fires
button 1. A blind player who presses Enter (the obvious "I'm
done" key) always picks button 1 without knowing about button
2 — and the choice is persistent for the rest of their game.

## How it closes / advances

- Button click → `OnHideAdvisorDialog()` + invoke the button's
  `callbackFunc(advisorData)` → typically fires
  `LuaEvents.AdvisorPopup_ClearActive(advisorInfo)` → tutorial
  system marks item done → AdvisorPopup `Close()` if no other
  popup queued
- `LuaEvents.TutorialUIRoot_AdvisorLower` (called by tutorial
  system) → `OnAdvisorLower` → `Close()`
- Esc does NOT close the popup; it opens the pause menu

For FIRST_GREETING specifically, the button callbacks call the
item's cleanup function (lines 67-74 of TutorialScenarioBase)
which sets `HasChosenTutorialLevel = 1` so the popup never
appears again.

## Ruleset variants

**All rulesets fire FIRST_GREETING.** It's defined in
`Base/Assets/UI/TutorialScenarioBase.lua`, shared across all
three rulesets.

Other advisor popups vary by ruleset:
- Base: ~30-50 tutorial items in TutorialScenarioBase
- R&F: adds items via `DLC/Expansion1/Data/Tutorial_*.xml`
  (e.g., "first era complete", "first governor available")
- GS: adds items via `DLC/Expansion2/Data/Tutorial_*.xml`
  (e.g., "first natural disaster", "world congress opening")

The AdvisorPopup wrapper we build needs to handle all of them —
not just FIRST_GREETING. Per-item content varies but the
modal structure is identical (1-2 buttons, portrait or not,
optional callout image).

**Implementation impact**: one access file wraps AdvisorPopup
generically. No per-ruleset code; per-ruleset content comes via
LOC string lookups for each item's Message + Button text, which
already work cross-ruleset.

## Current accessibility state

**Effectively zero**. The popup is mouse-only for button choice.
The engine's "TutorialContinue" hotkey exists but only fires
button 1, hiding the existence of button 2 from any
keyboard-only user (sighted or blind).

Our workaround [[SuppressFirstTurnAdvisor.lua]] sets
`HasChosenTutorialLevel = 1` so FIRST_GREETING never appears at
all — solves the immediate blocker but loses the player's
tutorial level choice (defaults to whatever was last set, often
the most-tutorial-laden level which then floods the player with
popups later).

Subsequent advisor popups (post-FIRST_GREETING) have similar
issues: portrait not described, message not announced via
screen reader, button 2 (if present) unreachable via keyboard.

## Blind-first design

This wrapper sets the **modal-choice-menu pattern** for the
project. Any future multi-button popup (diplomacy choices,
crisis responses, victory acknowledgments) builds on the same
shape.

**On show** (wrap `OnAdvisorRaise` / `ShowAdvisorPopup`):

1. Announce: "Tutorial advisor." (or "Notification." for Meta
   variant without portrait)
2. Speak the message: `Locale.Lookup(advisorData.Message)`,
   stripped of `[ICON_*]` tags
3. If portrait visible: queue a brief portrait description
   (from describer pass over advisor atlas) — speak as part of
   the open announce, plus available via Ctrl+I for full
4. Announce the choice structure:
   - 0 buttons → "Press Enter or Escape to dismiss."
   - 1 button → "Press Enter to {Button1Text}. Press Escape to
     dismiss."
   - 2 buttons → "Choose: Option 1 of 2, {Button1Text}. Use
     Left or Right to switch options, Enter to confirm."
5. Focus starts on button 1 (or whatever was previously
   focused; engine's hotkey behavior pre-selects button 1)
6. Copy the full message + button labels to clipboard per
   [[project-rich-text-clipboard-pattern]]

**On arrow key** (when popup has 2 buttons):
- Right / Down → cycle to next button
- Left / Up → cycle to previous button
- Announce: "Option N of M, {ButtonNText}."
- Cycle wraps at ends

**On Enter / Space / TutorialContinue hotkey**:
- Activate the currently-focused button (not just button 1!)
- Override the engine's `m_hotkeyCallback` (which is always
  button 1) by reassigning on focus change

**On Esc**:
- The engine opens the pause menu — that's a problem because a
  blind player pressing Esc to "cancel" suddenly is in the
  pause menu with no announce
- **Override Esc** to instead announce: "This choice is
  required. Press Left or Right to switch options, Enter to
  confirm." (Don't dismiss; the choice is genuinely required
  for FIRST_GREETING.)
- For 1-button popups, Esc activates the button (same as
  Enter). For 0-button info popups, Esc dismisses.

**Ctrl+I** (when portrait visible):
- Speak full advisor portrait description from
  `LOC_CIVVIACCESS_ADVISOR_<TYPE>_LONG`
- Copy to clipboard

**Ctrl+T**:
- Re-speak the message body
- Copy to clipboard

**Edge case — generic Meta popups** (no portrait):
- Title is "Notification" instead of "Tutorial advisor"
- Skip Ctrl+I (no portrait)
- Otherwise same flow

**Edge case — popups with `CalloutHeader` + `CalloutBody`**:
- Some tutorial items use these instead of Message
- Speak: "{CalloutHeader}. {CalloutBody}."
- Apply same button-nav logic

## Implementation notes

**File**: `CivViAccessMod/Assets/UI/Accessibility/AdvisorPopupAccess.lua`

**Pattern**: include after the AdvisorPopup shadow loads, hook
`ShowAdvisorPopup` to wrap with our access layer.

**Approach** — monkey-patch `ShowAdvisorPopup` since it's a
global function in the AdvisorPopup context:

```lua
include("ScreenReader")

local _priorShowAdvisorPopup = ShowAdvisorPopup
local _focusedButton = 1
local _currentData = nil

local function announcePopupOpen(data)
  -- title + message + portrait brief + choice announce
end

local function announceFocusedButton()
  -- "Option {N} of {M}: {ButtonNText}."
end

local function cycleFocus(delta)
  local count = (data.Button1Text and 1 or 0)
              + (data.Button2Text and 1 or 0)
  if count < 2 then return end
  _focusedButton = ((_focusedButton - 1 + delta) % count) + 1
  rebindHotkeyCallback()
  announceFocusedButton()
end

local function rebindHotkeyCallback()
  -- Reassign m_hotkeyCallback to invoke whichever button is focused
  -- The engine's m_hotkeyCallback is module-local in AdvisorPopup.lua;
  -- need to monkey-patch by overriding ShowAdvisorPopup AFTER it sets the
  -- callback, capturing both button functions and routing through ours.
end

function ShowAdvisorPopup(data)
  _currentData = data
  _focusedButton = 1
  _priorShowAdvisorPopup(data)
  -- Now intercept the m_hotkeyCallback that base just set
  -- (Need to dig: AdvisorPopup module local; may require approach
  --  of replacing the entire AdvisorPopup file rather than monkey-patching)
  installAccessHotkeys()
  announcePopupOpen(data)
end
```

**Critical implementation question**: AdvisorPopup's
`m_hotkeyCallback` is module-local. We can't reach it from
outside the AdvisorPopup context directly. Two options:

1. **Full Lua replacement** — shadow `AdvisorPopup.lua` entirely
   with our own version that adds the access layer alongside
   the original logic. Brittle (Firaxis can ship an updated
   AdvisorPopup and we'd miss the change). Honest about scope.
2. **Augmentation via custom input handler** — install a
   ContextPtr-level input handler that runs BEFORE the engine's
   KeyHandler, intercepts arrow keys + overrides the
   Enter/TutorialContinue path. Means we don't touch
   `m_hotkeyCallback` directly; we just call button N's
   callback ourselves and call AdvisorPopup's
   `OnHideAdvisorDialog()` to clean up.

Option 2 is the right approach. Capture the button functions
from `advisorData.Button1Func` / `Button2Func` (which we DO
have access to from the wrapped `ShowAdvisorPopup` call), and
own the input dispatch ourselves.

**LOC strings to add**:
- `LOC_CIVVIACCESS_ADVISOR_TITLE` — "Tutorial advisor."
- `LOC_CIVVIACCESS_NOTIFICATION_TITLE` — "Notification."
- `LOC_CIVVIACCESS_ADVISOR_CHOICE_REQUIRED` —
  "This choice is required. Press Left or Right to switch
  options, Enter to confirm."
- `LOC_CIVVIACCESS_ADVISOR_CHOICE_FORMAT` —
  "Choose: Option {1_N} of {2_M}, {3_Text}. Use Left or Right
  to switch options, Enter to confirm."
- `LOC_CIVVIACCESS_ADVISOR_FOCUS_FORMAT` —
  "Option {1_N} of {2_M}: {3_Text}."
- `LOC_CIVVIACCESS_ADVISOR_SINGLE_BUTTON_FORMAT` —
  "Press Enter to {1_Text}."
- `LOC_CIVVIACCESS_ADVISOR_DISMISS_HINT` —
  "Press Enter or Escape to dismiss."
- `LOC_CIVVIACCESS_ADVISOR_PORTRAIT_HINT` —
  "Press Ctrl+I for advisor description."

**Advisor portrait describer batch** (new sub-task):
- Source: `Advisors128.dds` is an atlas; need to extract
  individual advisor portraits or describe the atlas as a whole
- Likely also have full-size advisor character art elsewhere in
  pantry/Textures — check for `ADVISOR_*` filenames
- ~5-7 advisors max (Cultural, Economic, Military, Religious,
  Science + the generic tutorial advisor)
- Output LOC keys:
  `LOC_CIVVIACCESS_ADVISOR_<TYPE>_SHORT/_LONG`
- Same Gemini Pro pipeline as leaders

**Replace SuppressFirstTurnAdvisor.lua**: once this access
wrapper ships, the suppress hack becomes obsolete. The wrapper
gives the user the actual choice they need to make. Delete
`SuppressFirstTurnAdvisor.lua` as part of this implementation.

**Estimated LOC**: ~250 for the wrapper + ~50 for the suppress
removal + ~20 LOC strings = ~320 (per
[[feedback-loc-estimates-anchor-low]] → likely ~600-700 real).

## Test plan

This is a per-ruleset test of FIRST_GREETING + a generic test
of subsequent advisor popups.

**FIRST_GREETING test** (run under each ruleset — Vanilla, R&F,
GS):

1. Reset state: delete `HasChosenTutorialLevel` from
   `Options.txt` user options (or use a fresh account).
2. Start a new game. Click through AdvancedSetup, wait through
   loading screen (waypoint 04). If R&F/GS, wait through
   expansion intro (waypoint 05).
3. Verify the advisor popup opens automatically when the world
   loads. Verify announce:
   - "Tutorial advisor. Hello! I'm here to help you…"
   - Portrait brief (if Ctrl+I describer is ready)
   - "Choose: Option 1 of 2, New to the Civilization series.
     Use Left or Right to switch options, Enter to confirm."
4. Press Right → "Option 2 of 2: New to Civilization 6."
5. Press Left → "Option 1 of 2: New to the Civilization series."
6. Press Ctrl+I → speak full advisor portrait description.
7. Press Ctrl+T → re-speak the welcome message.
8. Press Esc → "This choice is required. Press Left or Right
   to switch options, Enter to confirm." (Popup does NOT
   dismiss.)
9. Press Enter on option 2 → popup closes, tutorial level set
   to LEVEL_CIV_FAMILIAR, `HasChosenTutorialLevel = 1` saved.
10. Verify in `Options.txt` that `TutorialLevel = 4` (or
    whatever LEVEL_CIV_FAMILIAR maps to) and
    `HasChosenTutorialLevel = 1`.
11. Start a new game — FIRST_GREETING should NOT appear (seen
    flag set).

**Generic advisor popup test**:

12. Start a new game with a high tutorial level (e.g.,
    `TutorialLevel.LEVEL_NEW_TO_XP2` for GS) so subsequent
    advisor popups fire.
13. Trigger a 1-button advisor popup (e.g., "first city
    founded" tutorial). Verify announce:
    - "Tutorial advisor. {message}…"
    - "Press Enter to OK."
14. Press Enter → popup closes.
15. Trigger a 0-button info popup (e.g., a CalloutBody-only
    item). Verify "Press Enter or Escape to dismiss."
16. Confirm Esc dismisses 0/1-button popups but NOT 2-button
    choice popups.

**Regression**:

17. Verify our existing diagnostic popups (if any) still work.
18. Verify the in-game pause menu still opens on Esc when there
    is no advisor popup up.

## Cross-references

- [[project-first-turn-popups-block-input]] — this is the
  second of the two blocking popups; ExpansionIntro (05) was
  the first
- [[project-blind-first-design-principle]] — choice popups MUST
  let the user actually choose, not just dismiss
- [[project-popup-nav-standard]] — arrow-key nav between
  buttons + nav sound + label on each move
- [[project-layered-info-hotkeys]] — Ctrl+I for advisor
  portrait description, Ctrl+T for re-read message
- [[project-rich-text-clipboard-pattern]] — copy
  message+buttons text to clipboard
- [[reference-civ-vi-input-action-unreliable]] — engine input
  actions can be unreliable; install a raw input handler
  alongside
- [[reference-civ-vi-icon-tags-in-labels]] — strip [ICON_*]
  from message text
- `CivViAccessMod/Assets/UI/Accessibility/SuppressFirstTurnAdvisor.lua`
  — current workaround, delete when this wrapper ships
- Future: this wrapper's input dispatch pattern (capture button
  funcs, own the focus state, route Enter to focused button)
  becomes the template for diplomacy choice popups, crisis
  popups, World Congress votes — anywhere the engine ships a
  multi-button modal.
