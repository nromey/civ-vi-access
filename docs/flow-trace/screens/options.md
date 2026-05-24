# Options screen

The Options screen (a.k.a. the Settings menu). Reachable from
MainMenu and from the in-game pause menu. Same Lua context in
both places, gated by `IsInGame()` for a handful of in-game-only
hides.

Non-chronological — Options sits outside the 00-10 new-game flow
in [[BLIND_FIRST_TRACE_PLAN.md]]. Lives here under
`docs/flow-trace/screens/` along with every other "reachable
from anywhere in the shell or pause menu" screen.

**Ramps status**: largely shipped via
`CivViAccessMod/Assets/UI/Accessibility/OptionsAccess.lua` (998
lines) — six of the seven tabs are fully populated and keyboard-
navigable; the **KeyBindings tab is the explicit gap**
(`KEYBINDINGS_ITEMS = {}` at OptionsAccess.lua:574). This trace
identifies what remains to bring KeyBindings up to ramps parity
and surfaces the Civ-VI-native key bindings catalog as a
secondary deliverable from that work.

## Engine source

- `Base/Assets/UI/Options.lua` (1808 lines)
- `Base/Assets/UI/Options.xml` (509 lines)
- DLC overrides: **none**. Only override on disk is our own
  mod's deployed `DLC/CivViAccessMod/Assets/UI/Options.lua`.
- Input action enumeration (KeyBindings tab data source):
  - `Input.GetActionCount()`
  - `Input.GetActionId(i)` for i in 0..count-1
  - `Input.GetActionName(actionId)` → LOC key
  - `Input.GetActionCategory(actionId)` → LOC key
  - `Input.GetActionDescription(actionId)` → LOC key
  - `Input.GetGestureDisplayString(actionId, slot)` → bound key
    text for slot 0 (primary) or 1 (alt)
  - `Input.ShouldShowActionKeybinding(actionId)` → bool, gates
    which actions appear in the tab
  - `Input.BindAction`, `Input.ClearGesture`,
    `Input.BeginRecordingGestures`, `Input.StopRecordingGestures`,
    `Input.ClearRecordedGestures` — mutation API
  - `Events.InputGestureRecorded` → fired when user presses a
    key combo while recording is active

Our overlay:
- `CivViAccessMod/Assets/UI/Accessibility/OptionsAccess.lua` (998 lines)
- `CivViAccessMod/Assets/UI/Options.lua` — thin shadow of base
  that adds `include("OptionsAccess")` + a handful of capture
  hand-offs at the slider/checkbox/combobox registration sites,
  plus `OptionsAccess.Install / WrapInput / WrapShow` at the end
  of `Initialize()`

## How it opens

- **MainMenu path**: MainMenu → "Options" button → fires
  `LuaEvents.MainMenu_RaiseOptions` (or equivalent); the
  Options context shows.
- **In-game path**: Pause menu → "Options" → same Options
  context shows. `IsInGame()` returns true; certain controls
  (resolution, adapter, language switch) are hidden or disabled
  per the `not IsInGame()` checks scattered through Options.lua
  (lines 258, 305, 1598, 1906).
- `OnShow()` (Options.lua:1897):
  - `RefreshKeyBinding()` rebuilds the KeyBindings tab content
    each show (engine-side caching is via the Instance manager)
  - `UserConfiguration.SaveCheckpoint()` snapshots current
    config so Cancel can revert
  - Disables/hides controls per `IsInGame()` gates
- Tab 1 (Game Options) is selected by default via
  `OnSelectTab(1)` at line 98.

## What appears visually

**Top bar**: WindowTitle (e.g., "GAME OPTIONS", changes per tab),
seven tab buttons in a horizontal `TabStack`:

| Idx | Control            | Title key                          | Hide-Reset |
|-----|--------------------|------------------------------------|------------|
| 1   | `GameTab`          | `LOC_OPTIONS_GAME_OPTIONS`         | 0          |
| 2   | `GraphicsTab`      | `LOC_OPTIONS_GRAPHICS_OPTIONS`     | 0          |
| 3   | `AudioTab`         | `LOC_OPTIONS_AUDIO_OPTIONS`        | 0          |
| 4   | `InterfaceTab`     | `LOC_OPTIONS_INTERFACE_OPTIONS`    | 0          |
| 5   | `AppTab`           | `LOC_OPTIONS_APPLICATION_OPTIONS`  | 0          |
| 6   | `LanguageTab`      | `LOC_OPTIONS_LANGUAGE_OPTIONS`     | 0          |
| 7   | `KeyBindingsTab`   | `LOC_OPTIONS_KEY_BINDINGS_OPTIONS` | 1          |

Tab 6 and 7 are conditionally inserted at runtime
(Options.lua:2076-2088) based on
`supportsChangingLanguage` and `supportsKeyBinding`. Both are
hard-coded `true` on PC; the conditionals exist for console
platforms that disable them.

**Each tab's body** is a `Container` (`GameOptions`,
`GraphicsOptions`, `AudioOptions`, `InterfaceOptions`,
`ApplicationOptions`, `LanguageOptions`, `KeyBindings`) — only
the active tab's container is unhidden at a time.

**Bottom action row**:
- `ResetButton` (LOC_SETUP_RESTORE_DEFAULT) — hidden on
  KeyBindings tab
- `ConfirmButton` (LOC_GENERIC_CONFIRM_BUTTON) — disabled
  until a change is staged
- `WindowCloseButton` (LOC_MULTIPLAYER_BACK) — Cancel

**KeyBindings-specific overlays**:
- `KeyBindingPopup` modal — appears when user clicks any
  binding button. Title shows the action name; body says
  "Press the desired key combination" (LOC_OPTIONS_SET_KEY_BINDING_TEXT).
  Has Cancel + Clear buttons.
- The body is a `ScrollPanel` (`KeyBindingsScrollPanel`)
  containing a `Stack` (`KeyBindingsStack`) of alternating
  `KeyBindingCategory` headers and `KeyBindingAction` rows.
  Each action row has `ActionName` label + `Binding`
  (primary) + `AltBinding` button.

## What it accepts as input

**Stock Civ VI**: mouse-driven. Engine recognizes Escape during
the KeyBindingPopup modal (Options.lua:1749-1754) to cancel
recording; otherwise the screen has no keyboard support beyond
fall-through to engine OnCancel via Escape.

**Our overlay** adds (OptionsAccess.lua:24-31):
- Up/Down — previous/next item within tab
- Home/End — first/last within tab
- Left/Right — slider step down/up, or pulldown prev/next
- Ctrl+Left/Ctrl+Right — slider big step (Shift was unreliable
  due to Civ VI input-pipeline ghosting; Ctrl chosen as
  reliable alternative)
- Enter/Space — activate/toggle focused item
- Tab — next tab (forward-only; Shift+Tab unreliable)
- PageUp/PageDown — previous/next tab (reliable cross-tab nav)
- F1 — speak keyboard help (registered under "OPTIONS" key in
  ContextHelp.lua)
- Escape — falls through to engine OnCancel

## How it closes / advances

- `OnConfirm()` (Options.lua:192) — commits staged changes;
  may show restart prompt if graphics options changed; closes.
- `OnCancel()` (Options.lua:105) — reverts to checkpoint;
  closes.
- `OnReset()` (Options.lua:157) — resets current tab to
  defaults (per-tab restore, not global). Re-enables
  ConfirmButton.
- `KeyBindingPopup` Escape → `StopActiveKeyBinding()` only
  (doesn't close Options).
- Some changes (language switch, certain graphics) raise
  `_PromptRestartGame` and queue a restart confirmation popup
  on confirm.

## Ruleset variants

**None.** Options.lua has no expansion override. The same Lua/
XML files run under Vanilla, Rise & Fall, and Gathering Storm.
Tab content, control layout, and behavior are identical across
rulesets.

Two runtime divergences exist but are **not** ruleset-driven:
1. `IsInGame()` gate — different visibility for resolution,
   adapter, language switch, and a few others when Options is
   raised from the in-game pause menu vs. the front-end.
2. Platform gate — `supportsChangingLanguage` and
   `supportsKeyBinding` (Options.lua:2076, 2083) — both hard-
   true on PC; controlled on consoles.

**Implication**: one trace, one implementation, two test
contexts (MainMenu + in-game). No per-ruleset divergence to
worry about.

## Current accessibility state

**Shipped** (OptionsAccess.lua, declarative item lists per
tab; see lines 496-583 for the per-tab content):

| Tab           | Items populated | Notes                                  |
|---------------|-----------------|----------------------------------------|
| Game          | 14              | Per OptionsAccess.lua:505              |
| Graphics      | 9               | Advanced subsection still mouse-only   |
| Audio         | 6 (5 sliders + Mute Focus checkbox) | Was MVP for the screen |
| Interface     | 19              | Largest tab                            |
| Application   | 2               | ShowIntro pulldown + WarnAboutMods     |
| Language      | 3               | DisplayLang + SpokenLang + Subtitles   |
| KeyBindings   | **0 (empty)**   | Bottom row only — no rebind reachable  |

**Cross-tab features** shipped:
- Tab/PageUp/PageDown navigation between tabs with announce
- F1 in-screen keyboard help
- Per-item speech (label + value) for slider / checkbox /
  pulldown / button / editbox
- Slider engine-callback capture so keyboard-driven changes
  fire the same logic mouse drags do (see comment
  OptionsAccess.lua:14-23)
- Modifier-state suppression window for Shift bounce
  (OptionsAccess.lua:96-103)

**Gaps**:

1. **KeyBindings tab — entirely inaccessible from keyboard**.
   The rebind buttons are mouse-click-only; the modal popup
   waits on `Events.InputGestureRecorded` (which DOES fire on
   any keypress, so a keyboard user could conceivably trigger
   a rebind once they click into the popup — but they have no
   way to focus the right action's button to begin with).
2. **Graphics → Advanced subsection** not enumerated. Shows
   only after clicking `AdvancedGraphicsOptions` button;
   controls become visible at that point but aren't in our
   item list (OptionsAccess.lua:534-536 explicit follow-up).
3. **Editboxes (LAN player name, webhook URL)** announce
   their current text but typing requires mouse-click into the
   field. Flagged via `LOC_CIVVIACCESS_EDITBOX_MOUSE_HINT` in
   activateEditbox (line 458).
4. **Restart-required prompt** after confirming language /
   graphics changes — modal popup, accessibility unverified.
5. **No layered-info hotkeys (Ctrl+T / Ctrl+I)**. Most Options
   controls have a tooltip (`SetToolTipString` at multiple
   sites including KeyBinding tooltips at Options.lua:1824).
   Ctrl+T should speak the focused control's tooltip. Per
   [[project_layered_info_hotkeys]].

## Blind-first design

### KeyBindings tab — ramps work

Goal: make every Civ VI action's primary + alt binding
reachable, readable, and rebindable from keyboard.

**Data model** — items list is dynamic, not hard-coded.
Mirror Options.lua's `RefreshKeyBinding()` enumeration into our
item list:

```lua
-- At tab-entry time, rebuild KEYBINDINGS_ITEMS from
-- Input.GetActionCount() / GetActionId / GetActionName /
-- GetActionCategory / GetGestureDisplayString.
--
-- One item per (action, slot) pair, sorted by
-- (category, action name) to match the visual order.
-- Item kind: "keybind" (new handler).
```

**Item handler `keybind`** (new in OptionsAccess.lua):
- `announce(item)` →
  `"<Category>: <Action name>, primary <Gesture1>, alt <Gesture2>"`
  on first action of a category;
  `"<Action name>, primary <Gesture1>, alt <Gesture2>"`
  on subsequent actions
- `adjust(item, dir, big)` → no-op (rebinding isn't a
  scalar)
- `activate(item)` → call `StartActiveKeyBinding(actionId, slot)`
  → modal opens; announce
  "Press the desired key combination, Escape to cancel,
  Delete to clear, then we wait for the next key. When you
  press a combination, it binds and we return to the list."

**Modal popup speech**:
- On open: announce action name + the prompt
- After `Events.InputGestureRecorded` fires + the binding
  updates: announce "Bound to <new gesture>" and re-focus the
  same action row
- On Cancel / Escape: announce "Cancelled"
- On Clear (Delete key support added; click also fine):
  announce "<Action name> primary cleared"

**Slot navigation within an action**:
- Up/Down moves between actions (primary slot focused
  initially)
- Left/Right toggles between primary and alt slot of the
  current action (rather than firing a slider step, which
  doesn't apply here)
- This gives a 2D feel: vertical = action, horizontal =
  slot

**Category headers**:
- Use the `pseudo-header` item pattern (non-focusable, only
  announced when crossing into a new category during
  Up/Down nav, not enumerated as a stop). Civ V Access uses
  the same pattern; check [[reference_civ_v_basemenu_pattern]]
  for the convention.

**Conflict announcing**: when binding produces a conflict
(two actions on the same gesture), Civ VI does not currently
warn — engine just lets both fire. Out of scope for ramps;
note as finishing polish.

### Layered info (Ctrl+T) across all tabs

`Ctrl+T` on any focused item speaks the engine tooltip
(Options.lua sets `SetToolTipString` at many sites — including
KeyBinding tooltips at line 1824 which Locale.Lookup the
`Input.GetActionDescription`). Generic handler:

- Get focused control
- If has GetToolTipString → speak it
- Otherwise: speak "No additional information"

### Civ VI native key bindings — catalog deliverable

The KeyBindings tab IS the canonical, runtime-authoritative
catalog of Civ VI's input actions and their default key
mappings. Once the rebind UX is accessible, the catalog
becomes readable in-game. For static reference (planning,
memory, docs), also dump it once:

- Run the game with our mod active
- Add a one-shot debug routine that iterates
  `Input.GetActionCount()` / `GetActionId` / `GetActionName` /
  `GetActionCategory` / `GetGestureDisplayString(action, 0/1)`
  / `GetActionDescription`, writes JSON to
  `docs/reference/civ-vi-key-bindings.json`
- Update [[reference_civ_vi_default_keybindings]] memory to
  reference the JSON file as the authoritative catalog (the
  memory currently lists a hand-collected subset)
- Repeat per ruleset to confirm catalog is ruleset-invariant
  (expectation: yes, since action enumeration is engine-bound,
  not data-driven by ruleset)

## Implementation notes

**Files to touch**:

- `CivViAccessMod/Assets/UI/Accessibility/OptionsAccess.lua` —
  add `keybind` item kind handler, dynamic
  `buildKeyBindingsItems()` called from `NotifyShow` and from
  `OnSelectTab` when entering KeyBindings tab; add modal
  popup speech hooks.
- `CivViAccessMod/Assets/UI/Options.lua` (our fork) — at the
  end of `RefreshKeyBinding()` call
  `OptionsAccess.NotifyKeyBindingsRefreshed()` so our items
  list rebuilds whenever the engine's instance manager
  repopulates. One additional hand-off at the
  `Events.InputGestureRecorded` listener so we can announce
  the new binding after the engine commits it.
- `CivViAccessMod/Assets/Text/en_US/CivVIAccessStrings.xml` —
  new LOC strings for keybind speech (see below).
- `CivViAccessMod/Assets/UI/Accessibility/ContextHelp.lua` —
  extend "OPTIONS" help text with the new keybind interactions.

**Generic Ctrl+T tooltip handler** — single change in
`OptionsAccess.OnInput`: add a Ctrl+T branch that pulls
`Controls[item.controlName]:GetToolTipString()` and speaks it.
~10 lines.

**LOC strings to add**:
- `LOC_CIVVIACCESS_KEYBIND_ANNOUNCE` —
  "{1_ActionName}, primary {2_Primary}, alt {3_Alt}"
- `LOC_CIVVIACCESS_KEYBIND_ANNOUNCE_WITH_CATEGORY` —
  "{1_Category}. {2_ActionName}, primary {3_Primary}, alt
  {4_Alt}"
- `LOC_CIVVIACCESS_KEYBIND_UNBOUND` — "unbound"
- `LOC_CIVVIACCESS_KEYBIND_RECORDING_PROMPT` —
  "Recording {1_ActionName} primary. Press the desired key
  combination. Escape cancels. Delete clears the binding."
- `LOC_CIVVIACCESS_KEYBIND_RECORDING_PROMPT_ALT` —
  "Recording {1_ActionName} alternate. Press the desired key
  combination. Escape cancels. Delete clears the binding."
- `LOC_CIVVIACCESS_KEYBIND_BOUND` —
  "{1_ActionName} {2_Slot} bound to {3_Gesture}"
- `LOC_CIVVIACCESS_KEYBIND_CLEARED` —
  "{1_ActionName} {2_Slot} cleared"
- `LOC_CIVVIACCESS_KEYBIND_CANCELLED` —
  "Cancelled rebinding {1_ActionName}"
- `LOC_CIVVIACCESS_KEYBIND_SLOT_PRIMARY` — "primary"
- `LOC_CIVVIACCESS_KEYBIND_SLOT_ALT` — "alternate"

**Estimated LOC**: ~120-150 for KeyBindings keybind handler +
modal speech + slot-toggle nav + LOC; ~10 for generic Ctrl+T;
~40 for the JSON-dump debug routine. Total ~180. Per
[[feedback_loc_estimates_anchor_low]] → real ~300-450.

**No modinfo changes** — Options.lua is already shadowed via
the existing entry in `CivViAccessMod.modinfo` (per the
deployed file at `DLC/CivViAccessMod/Assets/UI/Options.lua`).

## Test plan

Run from **MainMenu** AND **in-game pause menu** (two contexts;
same Lua, but `IsInGame()` flips a few control visibilities).
Ruleset-invariant — one ruleset (Vanilla preferred for fastest
load) suffices.

### Regression — already-shipped tabs

1. Open Options from MainMenu. Verify "Game options" tab
   header announces; first item ("Quick combat, off" or
   similar) reads.
2. Down-arrow through every Game tab item. Verify each speaks
   label + value.
3. Tab forward through all 7 tabs. Verify each tab announces
   header and first item. KeyBindings tab announces as
   "stub" (LOC_CIVVIACCESS_TAB_STUB) BEFORE this change, as
   "header" after.
4. PageUp / PageDown — same.
5. Audio tab: Left/Right on Master Volume → percent changes
   audibly; speech announces "Master Volume, NN percent".
6. Audio tab: Ctrl+Left/Ctrl+Right → 20% jumps.
7. Interface tab: ScrollSpeedSlider Left/Right → ScrollSpeedValue
   label text reads ("Slow", "Medium", "Fast" etc.).
8. Bottom row reachable on every tab via End key.
9. F1 → keyboard help text speaks.
10. Escape → screen closes; returns to MainMenu / pause menu.
11. Confirm a real change (e.g., MuteFocus toggle on Audio
    tab → ConfirmButton enables → Enter on ConfirmButton →
    screen closes with change committed).
12. Repeat from in-game pause menu. Verify the IsInGame-
    gated controls (resolution, language) are reported as
    unavailable when focused (or skipped via isItemUsable).

### New — KeyBindings tab

13. Open Options, PageDown to KeyBindings tab. Verify header
    announces "Key Bindings" and first item announces
    "Camera. Move camera up, primary W, alt unbound" (or
    whatever the first sorted action is).
14. Down-arrow through ~10 items. Verify each speaks. When
    crossing a category boundary, the new category name
    prefixes the action ("Unit. Attack, primary A, alt
    unbound").
15. Right-arrow on a focused action → focus toggles to its
    alt slot; speech announces "alt unbound" or the alt
    gesture.
16. Left-arrow → back to primary slot.
17. Enter / Space on a focused (action, slot) → modal opens;
    "Recording <action> primary. Press the desired key
    combination..." announces.
18. Press a new key combo (e.g., F12) → modal closes; speech
    announces "<action> primary bound to F12"; focus returns
    to the same row showing the new binding.
19. Re-enter the rebind modal. Press Escape → "Cancelled
    rebinding <action>"; focus returns to the row, binding
    unchanged.
20. Re-enter the rebind modal. Press Delete (planned support)
    → "<action> primary cleared"; row now shows "unbound".
21. Conflict probe (manual): rebind two actions to the same
    key. Verify nothing breaks; engine keeps both. Note in
    test report that conflict-warning is not yet implemented
    (deferred).
22. End → focus bottom-row Close button; Enter closes.

### Catalog dump

23. With debug routine enabled, open Options → KeyBindings tab
    → verify `docs/reference/civ-vi-key-bindings.json` is
    written. Spot-check: file contains all enumerated actions
    with their categories, names, descriptions, and default
    gestures.

## Cross-references

- [[reference_civ_vi_default_keybindings]] — hand-collected
  subset; will be superseded by the runtime JSON catalog
- [[reference_screen_reader_key_conflicts]] — NumLock /
  modifier overlap; informs which gestures we avoid suggesting
  as defaults if we ever rebind for our own mod actions
- [[project_layered_info_hotkeys]] — Ctrl+T as the generic
  tooltip-reveal binding, applied here for the first time
- [[project_announce_engine_actions]] — broader "speak each
  Events.InputActionTriggered firing" project; the KeyBindings
  catalog feeds that work
- [[project_tabbed_screen_nav_patterns]] — Tab + PageUp/Down
  conventions used here
- [[reference_civ_v_basemenu_pattern]] — declarative items
  list pattern; OptionsAccess.lua already follows it
- `Base/Assets/UI/Options.lua:1770-1894` — InitializeKeyBinding
  + RefreshKeyBinding + popup state machine
- `Base/Assets/UI/Options.lua:2067-2104` — m_tabs construction
