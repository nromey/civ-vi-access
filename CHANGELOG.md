# Changelog

Reverse-chronological. Dates are when work landed, grouped by batch rather
than per-commit.

## 2026-05-14 — De-fork, localization scaffolding, launcher window UX

- **De-fork from upstream.** Rewrote the three upstream-derived Lua files
  (`ScreenReader.lua`, `ScreenReaderEventHandlers.lua`,
  `ScreenReaderPlotUtils.lua`) so no current-file line traces to the
  original craigbrett17 fork. Same public API surface; callers untouched.
- **Strings migration to LOC.** Audited 23 hardcoded user-facing string
  callsites across 5 Lua files and migrated them to 26 `LOC_CIVVIACCESS_*`
  entries in `Assets/Text/en_US/CivVIAccessStrings.xml`. All composition is
  via positional placeholders (`{1_Label}`, `{2_Value}`) so translators
  never deal with Lua-side punctuation. Singular/plural handled via two
  distinct keys + Lua-picks pattern (Crowdin-friendly across languages
  with 3+ plural forms).
- **Centralized icon-tag stripping.** `stripIconTags` consolidated into
  `ScreenReader.lua` from three local copies; `OutputMessageToScreenReader`
  now auto-strips on the way out so future callers can't forget.
- **Launcher focus-force.** New `WindowFocusManager` (~200 LOC). After
  `Process.Start`, polls for Civ VI's window handle and forces it
  foreground via the `AttachThreadInput` workaround, retrying every 200ms
  for up to 15 seconds. Fixes the "half the time focus stays on the
  launcher console" UX paper-cut.
- **Bidirectional follow-focus minimize.** While Civ VI runs, the launcher
  polls `GetForegroundWindow` every 250ms. When Civ VI takes foreground,
  console minimizes; when console takes foreground, Civ VI minimizes.
  Exactly one of the two on-screen at any time; Alt+Tab is the natural
  switcher.
- **Esc-at-top routes to exit dialog.** Pressing Escape at the top level
  of the main menu now fires the same `MainMenu_UserRequestClose` event
  Alt+F4 uses, opening the arrow-key-navigable Exit confirmation.
- **Bug fix: modinfo UpdateText.** Our localization XML was registered via
  `<UpdateDatabase>` which targets the Configuration DB (no `BaseGameText`
  table). Switched to `<UpdateText>` which targets the Localization DB.
  The original CivVIAccessHelp.xml was failing silently the whole time;
  ContextHelp's Lua-side fallback table masked the bug.
- **Bug fix: double-fire main menu announce.** `NotifyMainMenuBuilt` and
  `NotifyShow` both fire on initial load. Added a one-shot suppression
  flag so the initial show doesn't re-announce after the build path
  already did.
- **Project licensed MIT.** LICENSE file added; modinfo Authors updated.

## 2026-05-12 — Accessible Options screen

- All 7 tabs (Audio, Game, Graphics, Language, Interface, Application,
  KeyBindings) reachable and traversable via keyboard. Audio tab fully
  populated; other six expose Reset / Confirm / Close as a minimum so the
  screen is always dismissable.
- Slider / checkbox / pulldown / button / editbox kinds each have their
  own announce + adjust handlers. Sliders step by 5% (Ctrl+Left/Right for
  20%); pulldowns cycle entries with Left/Right; checkboxes toggle on
  Enter/Space.
- Page Up / Page Down for cross-tab nav (replaced Shift+Tab, which is
  unreliable through Civ VI's input pipeline). F1 announces a help body
  resolved through `ContextHelp.Speak("OPTIONS")`.

## 2026-05-11 — MainMenu re-announce on return; Batch 02 polish

- MainMenu re-announces the current focus when returning from a sub-screen
  (Options → back, AdvancedSetup → back, etc.) so the user lands oriented.
- Icon-tag stripping applied to button label reads (Civ VI buttons embed
  `[ICON_*]` markers that read literally as nonsense).
- Tighter back-cue wording ("Main menu" instead of the verbose original)
  pending a dedicated earcon.
- `TESTING.md` rewritten from table layout to flat numbered steps for
  screen-reader friendliness.

## 2026-05-10 — Accessible LoadGameMenu

- Up / Down / Left / Right cycles through saves with wrap-at-edges.
- Home / End jump to first / last entry.
- Empty-list state announces with explicit "Press Escape to go back."
- File-list re-query on sort / filter changes re-announces the new state.

## 2026-05-09 — Accessible main menu, Alt+F4 dialog, first-launch EULA

- Main menu kb nav: arrow keys move focus across options, Enter/Space
  activates, Escape backs out of submenus. Selection plays the existing
  `Main_Menu_Mouse_Over` cue plus a spoken label.
- Alt+F4 "Exit to Desktop?" dialog made arrow-key-navigable per the
  project popup nav standard.
- First-launch EULA screen narrates the copyright text and "Press Enter
  to accept" prompt; auto-accept path (returning users) stays silent.

## 2026-05-08 — Launcher: auto-deploy + log watcher + first-launch detection

- Launcher walks the source tree on every run and copies mod files into
  Civ VI's DLC dir before spawning the game. No more manual `cp` between
  edits.
- Background `LogFileWatcher` tails `Lua.log` and routes prefix-marked
  lines (`#SCREENREADER` / `#SCREENREADER[NOINTERRUPT]`) to Tolk.
- First-launch detection via `UserOptions.txt` `CopyrightAccept` key;
  tailors the pre-game announcement to first-time vs. returning users.

## 2026-05-07 — Tolk integration, .NET 10 launcher

- Swapped from AccessibleOutput (.NET Framework, dormant) to Tolk
  (cross-screen-reader, actively maintained). Removes the .NET Framework
  install requirement.
- Console app retargeted at `net10.0` x64, renamed to
  `CivVIAccess.Launcher`, spawns Civ VI as a child process.
- Vendored Tolk x64 DLLs under `third_party/tolk/`.

## Earlier — Inherited from upstream

The codebase was originally a fork of
[craigbrett17/civilization-vi-screenreader-access](https://github.com/craigbrett17/civilization-vi-screenreader-access),
which shipped basic plot tooltip + selection-change announce. All
upstream-derived Lua files were rewritten in this codebase on 2026-05-14
(see top entry); no current-file line traces to the upstream as of that
date.
