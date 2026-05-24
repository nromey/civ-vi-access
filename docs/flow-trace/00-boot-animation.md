# 00 — Firaxis/2K boot animation (intro video + copyright accept)

The cinematic that plays at app startup before MainMenu: Firaxis
Games logo → 2K logo → spinning-globe intro cinematic with
narrated voiceover ("You're plotting a new course again, aren't
you?...") → EULA copyright accept screen → MainMenu.

For ramps-first work, the gating concern is: **the player
should be able to advance past the cinematic and accept the EULA
from the keyboard.** Note (from Noel, 2026-05-22): the Firaxis
logo phase specifically is **not** skippable — Esc/Space don't
cut it short. What we can ramp is the EULA accept and the post-
cinematic state, plus the at-launch speech announcement so the
user knows what's happening during the unskippable window. AD
of the cinematic itself (timed subtitle speech via Tolk
synchronized to the video) is finishing polish. Worth verifying
end-to-end on a fresh launch what is and isn't skippable per
phase before scoping the implementation.

**Future cross-platform / Prism note** (Noel): after the in-game
map / world layer is working, the plan is to attempt a move from
Tolk to Prism ([[reference_prism_screen_reader_library]]). Prism
is updated frequently and supports multiple platforms, which
opens MacOS support. The mod-side Lua is already portable;
the helper would need a Mac launcher that watches the game log
and reads Lua-emitted speech strings. Not gating for this trace,
but informs how we structure the speech path so the swap stays
small later.
## Engine source

- **Cinematic itself** — engine-native (C++), not Lua-readable
  source. The actual video file is at
  `Base/Platforms/Windows/Movies/civ6_cinematic.bk2` (Bink 2
  encoded; see [[reference-civ-vi-cinematic-audio-pipeline]]).
- **Subtitle file exists but verify playback context** — there
  IS a `Base/Assets/UI/Subtitles/<locale>/civ6_cinematic.srt`
  in the install, but Noel confirms (2026-05-22) the boot
  animation as actually played in-game **has no spoken
  narration** — only music and visuals (Firaxis logo, 2K logo,
  game-title reveal). The .srt may be from a previous version,
  or may be used by a different cinematic. **Don't promise AD
  of narration that isn't there.**
- **EULA accept screen** — `Base/Assets/UI/FrontEnd/IntroScreen.lua`
  (100 lines) + `.xml` (24 lines). This screen displays AFTER
  the cinematic finishes (or is skipped). Despite the name
  "IntroScreen," this is the copyright-acceptance UI, not the
  intro video itself.
- **PlayIntroVideo option** —
  `Base/Assets/UI/Options.lua:1731` exposes the user setting:
  ```lua
  Options.SetAppOption("Video", "PlayIntroVideo", option)
  ```
  Found via `Controls.ShowIntroPullDown` (a boolean combobox in
  the Video options tab). When set to 0/false, the engine skips
  the cinematic on subsequent launches and goes straight to
  IntroScreen.

DLC overrides: **none**. Boot animation is ruleset/expansion-
invariant.

## How it opens

App launch:
1. Engine starts → IF `Options.GetAppOption("Video",
   "PlayIntroVideo")` ≠ 0 AND not auto-test mode → play
   `civ6_cinematic.bk2` (Bink video, full-screen)
2. Engine signals cinematic complete (or user skipped) →
   transition to IntroScreen context (the EULA accept)
3. `IntroScreen.OnShow` → 5-second delay
   (`ACCEPT_DELAY = 5` in IntroScreen.lua:11; comment says
   "legal requirement for our third party software logos"),
   showing MainLogo + CopyrightText + Shell_Fork/Havok/WWise
   third-party logos
4. After delay: CopyrightAccept button reveals
5. IF current version matches previously-accepted
   `Options.GetUserOption("Interface", "CopyrightAccept")` —
   auto-accept (line 53-55)
6. Otherwise: wait for user to press Accept (mouse click or
   engine "Accept" / "AcceptAlt" input action)
7. `AcceptEULA()` → fires `Events.UserAcceptsEULA()` →
   transition to MainMenu (waypoint 01)

## What appears visually

**Cinematic phase**:
- Firaxis Games animated logo (10-15s) — visible "FIRAXIS
  GAMES" text alongside the logo
- 2K animated logo (5-10s) — visible "2K GAMES" or "2K" text
- Game title reveal — visible "SID MEIER'S CIVILIZATION VI"
  text
- Music + visuals only — NO spoken narration in current builds
  (per in-game verification 2026-05-22). The titles ARE visible
  text on screen, just unread by any system.
- Total duration ~30-60 seconds

**EULA accept phase**:
- Black background
- 1280x700 centered box
- Civilization VI logo (MainLogo.dds)
- Copyright text (small font)
- "Accept" button (initially hidden, appears after 5s delay)
- Three small third-party logos: Shell_Fork, Shell_Havok,
  Shell_WWise

## What it accepts as input

**During cinematic**: standard Bink player keys, typically Esc
or Space to skip. Engine-managed, not Lua-visible.

**During EULA accept**:
- Engine input actions `Accept` and `AcceptAlt` (default Enter
  + Space) → `AcceptEULA()`
- Mouse click on CopyrightAccept button
- `Events.UserRequestClose` → `OnRequestClose` → confirms close
  (user wants to quit the app)

No other keyboard input is handled on the EULA. Esc typically
does nothing (or quits the app via UserRequestClose).

**Video-card warning dialog (TODO investigate)** — Noel recalls
a separate engine-raised warning popup on first launch when the
detected video card is below the recommended spec. Read with
OCR previously, so it's almost certainly mouse-only / not
spoken. Need to find the source (likely engine-side, possibly
in `IntroScreen.lua` siblings or a separate context raised by
the renderer init), and decide:
- Whether it appears every launch or only first launch
- Whether `Events.UserRequestClose` or another LuaEvent fires
  on display
- Whether the message text is `Locale.Lookup`-able for speech
- Whether keyboard dismissal works at all

Document under this trace once located; may need its own
sub-section if the surface is large enough.

## How it closes / advances

- Cinematic dismiss → IntroScreen displays
- IntroScreen accept → `Events.UserAcceptsEULA` →
  MainMenu loads (waypoint 01)
- Subsequent launches: if PlayIntroVideo is off AND EULA
  already accepted for this version → both phases auto-skip;
  go straight to MainMenu

## Ruleset variants

**None.** Boot animation runs before any ruleset is selected.
Same cinematic, same EULA, regardless of which expansions are
installed. (The cinematic file itself is base-game; expansions
do not add new boot cinematics.)

## Current accessibility state

**Cinematic phase** (corrected per Noel 2026-05-22):
- The **Firaxis / 2K logo portion is NOT skippable** — earlier
  assumption that Esc/Space skip the entire cinematic was
  wrong. Engine-side enforces logo display through to
  completion.
- The portion after the logos (game-title reveal / globe
  intro) may be skippable — verify per phase on next launch.
- "Music" earlier in this trace was Claude's inference, not
  verified by Noel. The actual audio content during the
  unskippable Firaxis/2K portion needs verification:
  silent? logo-sting? music bed? short narration that
  Claude assumed didn't exist? Verify, then update.
- Later cinematics (post-boot, e.g., wonder completions,
  victory) sometimes have spoken dialogue — those are a
  different surface and live under
  [[reference_civ_vi_cinematic_hookpoints]] +
  [[reference_civ_vi_cinematic_audio_pipeline]].

**EULA accept phase**:
- Engine input action `Accept` works (Enter / Space) — keyboard
  accessible
- The 5-second delay is silent and unannounced; blind player
  doesn't know they need to wait
- Copyright text not spoken
- "Accept" button not announced when it reveals after the delay
- Auto-accept (when version unchanged) means subsequent launches
  silently skip this entirely — that's actually fine

## Blind-first design

**Ramps** (gating — ship by default):

0. **Speak the on-screen titles at app launch**. Regardless of
   whether the cinematic plays or skips, speak:
   `"Loading Sid Meier's Civilization VI by Firaxis Games and
   2K Games."` This conveys the publisher / game-title context
   that sighted players get from the visual logos. Fire once at
   the earliest hook we can reach — likely the MainMenu OnShow
   for the first time, since the cinematic plays before any
   Lua context loads.
1. **Auto-skip cinematic on installation**. The CAMM installer
   wizard or first-launch setup should set
   `Options.SetAppOption("Video", "PlayIntroVideo", 0)` so the
   cinematic never plays for blind users. Easy, decisive,
   doesn't break sighted-user opt-back-in (they can re-enable
   via Options).
   - Alternative: prompt the user on first launch ("Skip intro
     videos? Recommended for screen-reader users.") — but per
     [[feedback-runtime-toggle-over-install-choice]] we
     shouldn't ask wizard-style; just auto-disable and let user
     re-enable.
2. **Speak guidance on cinematic start**: if cinematic IS
   playing (user re-enabled or first launch), speak
   "Intro video playing." within the first second.
   **Do not promise Esc-to-skip** — the Firaxis/2K logo
   portion is engine-enforced through to completion (per Noel
   2026-05-22). Once we know which portions accept skip and
   which don't, refine the speech accordingly (e.g.,
   "Intro video playing. Wait for the logos to finish, then
   Escape to skip the rest."). Hook: subscribe to whatever
   Lua event fires when cinematic begins — this may not exist
   as a Lua event; could require a timer from app-launch.
3. **Speak EULA accept guidance**: when IntroScreen displays
   and the 5-second delay is running, announce "Loading. Press
   Enter when ready." Once the delay expires and the Accept
   button reveals: announce "Press Enter to accept the
   copyright notice and continue."
4. **Speak third-party logo names** during the 5-second delay
   if a sighted player would notice them: "Forge, Havok, WWise
   licensed components." Brief, no AD pretense.

**Finishing polish** (later — not gating):

5. **Visual description** of the boot cinematic via Omni
   Describer or Google AI Studio video understanding —
   produces a brief AD script ("Firaxis Games logo. 2K Games
   logo. Civilization VI title appears over a sweeping shot
   of the globe."). Per
   [[project-audio-description-production-plan]]. Since there's
   no in-game narration to work around, this is the only AD
   layer — no SRT to sync against.

## Implementation notes

**Ramps file** (new): `CivViAccessMod/Assets/UI/Accessibility/BootScreenAccess.lua`

Wired via shadow of IntroScreen.lua plus an early-launch
gameplay script that sets the PlayIntroVideo option to 0 if
this is a CivViAccess-mod-enabled session AND the user hasn't
explicitly re-enabled it.

**Catch**: setting `PlayIntroVideo` from inside the mod is
tricky — the cinematic plays before any mod context loads.
Options:

1. **Set during install** — CAMM-style install wizard runs
   before first game launch and edits the user's Options.txt
   directly to set `PlayIntroVideo=0`. This is the
   highest-leverage approach but lives in CAMM, not the in-game
   mod.
2. **Set on first MainMenu load** — wait until the cinematic
   has already played once, then disable it for next time.
   Workable but the first-ever launch still has the cinematic
   problem.
3. **Document the user-Settings path** — for users who set up
   the mod manually, the README explains how to toggle
   PlayIntroVideo off via the Options screen. Honest about
   the limitation.

Recommend option 1 + option 3 fallback. Coordinate with CAMM
maintenance — the installer should know to suggest setting
PlayIntroVideo=0 for accessibility users.

**LOC strings to add**:
- `LOC_CIVVIACCESS_BOOT_LAUNCH_ANNOUNCE` —
  "Loading Sid Meier's Civilization VI by Firaxis Games and
  2K Games."
- `LOC_CIVVIACCESS_BOOT_INTRO_VIDEO_HINT` —
  "Intro video playing." (refine post-skippability probe; do
  not include Esc instruction until verified per phase)
- `LOC_CIVVIACCESS_BOOT_VIDEO_CARD_WARNING_PREFIX` —
  prefix for any detected video-card warning we surface
  through speech (text TBD once dialog is located in source)
- `LOC_CIVVIACCESS_BOOT_EULA_LOADING` —
  "Loading. Press Enter when ready."
- `LOC_CIVVIACCESS_BOOT_EULA_ACCEPT_PROMPT` —
  "Press Enter to accept the copyright notice and continue."

**Estimated LOC**: ~30 for the IntroScreen access wrap + ~20
for the install-time hook = ~50 (per
[[feedback-loc-estimates-anchor-low]] → ~100-150 real).

## Test plan

Single playthrough — boot animation is ruleset-invariant.

1. Fresh install (or simulate via deleting
   `Options.GetUserOption("Interface", "CopyrightAccept")` and
   setting `Options.GetAppOption("Video", "PlayIntroVideo") = 1`).
2. Launch the game with CivViAccess mod active.
3. **Skippability probe** (first time only): note which keys
   the engine accepts at each phase — during Firaxis logo,
   during 2K logo, during title reveal, during EULA. Log
   results back into "What it accepts as input" section.
4. **Cinematic phase**: verify "Intro video playing." announces
   within 1 second of cinematic start. (Refine the speech once
   probe results clarify which phases accept skip.)
5. Press Escape → expect Firaxis/2K logos to play through
   regardless; later phases may skip.
6. Verify "Loading. Press Enter when ready." announces on
   IntroScreen.
7. Wait 5 seconds → "Press Enter to accept the copyright notice
   and continue." announces.
8. Press Enter → MainMenu loads.
9. **Video-card warning probe** (first launch on a low-spec
   machine, or simulate): verify whether a hardware-warning
   dialog appears. If yes, capture the source file, the trigger
   condition, and whether keyboard dismiss works. Update
   "Video-card warning dialog" section above with findings.
10. Restart the game. Verify the cinematic skips automatically
    (PlayIntroVideo now 0) and IntroScreen auto-accepts
    (CopyrightAccept matches current version) → MainMenu loads
    directly.
11. Verify that the mod sets PlayIntroVideo=0 (re-enable via
    Options screen and confirm the toggle works both ways for
    sighted/dev users).

## Cross-references

- [[reference-civ-vi-cinematic-hookpoints]] — PlayIntroVideo
  option location confirmed (Options.lua:1731)
- [[reference-civ-vi-cinematic-audio-pipeline]] — cinematic
  audio format (.bk2 + .wem); subtitle .srt path
- [[project-audio-description-vision]] — 3-tier AD plan;
  cinematic AD is Tier 1
- [[project-audio-description-production-plan]] — execute-when-
  ready plan for cinematic AD via Omni Describer / AI Studio
- [[feedback-runtime-toggle-over-install-choice]] — auto-set
  PlayIntroVideo=0 rather than asking the user
- [[project-ramps-before-polish]] — skip the video first, AD
  the video later
- `Base/Assets/UI/FrontEnd/IntroScreen.lua` — the EULA accept
  screen we shadow
- Waypoint 01 — MainMenu, what we transition into after this
