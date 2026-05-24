# 04 — Loading screen (Sean Bean civ-intro)

The "Dawn of Man" loading screen that appears after AdvancedSetup
Start. Sean Bean narrates the player's civilization lore over a
visual showing the leader portrait, civ name, era, ability list,
and a Begin Game button when ready.

For a sighted player this is a 30-60s "set the stage" moment.
For a blind player today it is silent except for Sean Bean's
English voice-over (the text on screen — civ, leader, abilities
— is never spoken). The describer pipeline output
([[project-trace-methodology-generalizes]] +
`LeaderDescriptions.xml` from task #12) lets us deliver a real
accessible briefing in the same time window.

## Engine source

- `Base/Assets/UI/FrontEnd/LoadScreen.lua` (516 lines)
- `Base/Assets/UI/FrontEnd/LoadScreen.xml` (85 lines)
- DLC overrides: **none**. Single file pair shared across all
  rulesets. Confirmed by grep on `LoadScreen` in
  `DLC/Expansion1` (no matches) and `DLC/Expansion2` (only
  false-positive matches in `WorldCongress*.lua`).
- Helpers used:
  - `Civ6Common.lua` → `GetLeaderUniqueTraits(leaderType)` and
    `GetCivilizationUniqueTraits(civType)` — return ability /
    unit / building tables we'll need to mirror
  - `SupportFunctions.lua`, `InputSupport.lua` — input + locale

## How it opens

- Player clicks **Start Game** on AdvancedSetup
  (`OnStartButton` → game proceeds)
- Engine pre-loads player + map data, then fires
  `Events.LoadScreenContentReady` — at this point all player
  config is populated and we can read leader/civ/era data
- `OnShow` (line 120) fires first, hiding portrait + banner
  until content is ready
- `OnLoadScreenContentReady` (line 162) populates everything:
  background image, portrait, civ name, era info, leader name,
  leader info text, unique abilities/units/buildings, civ symbol
- `UI.PlaySound("Play_DawnOfMan_Speech")` (line 382) starts the
  Sean Bean voice-over
- Engine continues loading the game state in parallel
- `Events.LoadGameViewStateDone` fires when the world is ready
  (`OnLoadGameViewStateDone` line 457) — shows the "Begin Game"
  button + plays a chime

## What appears visually

**Background layer**: full-screen `<LeaderType>_BACKGROUND.dds`
scenic image (sky, architecture per civ).

**Left side**: large leader portrait cutout
(`<LeaderType>_NEUTRAL.dds`), bottom-anchored, scaled to screen
height.

**Center banner** (600×987 parchment panel) containing, top to
bottom:
1. Civ symbol logo in circular backing, colored to civ primary
2. Civ name in caps (e.g., "EGYPT")
3. Subtitle: "JOIN THE WORLD STAGE"
4. Era info (e.g., "Ancient Era" — start era description, or a
   challenge / saved-game era if applicable)
5. Leader name in caps (e.g., "CLEOPATRA")
6. Leader info paragraph (looked up via
   `LOC_LOADING_INFO_<LEADER_TYPE>`, e.g.,
   `LOC_LOADING_INFO_LEADER_CLEOPATRA`)
7. Subtitle: "FEATURES & ABILITIES"
8. `FeaturesStack` — grid of:
   - Unique abilities (one `TextInfoInstance` per: Header +
     Description, no icon)
   - Unique units (one `IconInfoInstance` per: 32×32 Icon +
     Header + Description)
   - Unique buildings / districts / improvements (one
     `IconInfoInstance` per: 38×38 Icon + Header + Description)

**Bottom**: "PLEASE WAIT" label until load complete; then a
"BEGIN GAME" button (or "CONTINUE GAME" for saves) replaces it
with a fade-in animation.

**Letterbox bars** top + bottom (decorative).

## What it accepts as input

**Before load complete (`m_isLoadComplete = false`)**: input is
ignored. The InputHandler isn't even installed yet.

**After `OnLoadGameViewStateDone` fires** (line 496 — that's
when `ContextPtr:SetInputHandler` lands):
- Esc → `OnActivateButtonClicked` → start game
- StartGame engine hotkey (default Enter) → start game
- StartGameAlt engine hotkey (default Space) → start game
- Click on `ActivateButton` (the round button) → start game
- Click on `StartLabelButton` (the "BEGIN GAME" label) → start game

## How it closes / advances

- `OnActivateButtonClicked` (line 47):
  - Unloads background + portrait textures
  - Fires `Events.LoadScreenClose`
  - Stops Sean Bean speech (`UI.PlaySound("STOP_SPEECH_DAWNOFMAN")`)
  - Stops menu music, plays game-begin sound, plays Set_View_3D
  - Dequeues this popup → engine transitions to world view
  - Sets input context to `InputContext.World`
- Multiplayer / resync / world-builder paths auto-activate the
  button without showing it (line 466)

## Ruleset variants

**One Lua/XML, all rulesets.** Variation is data-driven:

- **Available leaders / civs** filter by ruleset via the
  parameter system (same DB query as AdvancedSetup); the
  loadscreen just reads whichever leader the player picked
- **Era info** — vanilla has 6 eras; R&F + GS expand to 8 +
  Era Score mechanic; the era string at the top still comes from
  `GameInfo.Eras[startEra].Description` — text content differs
  per ruleset but the path is identical
- **Unique abilities/units/buildings** — pulled via
  `GetLeaderUniqueTraits` + `GetCivilizationUniqueTraits` which
  query the DB; counts and content vary per ruleset and per
  civ
- **LoadingInfo overrides** — `GameInfo.LoadingInfo[leaderType]`
  table lets DLCs override `BackgroundImage`, `ForegroundImage`,
  `EraText`, `LeaderText`, `DawnOfManLeaderId`, `DawnOfManEraId`,
  and `PlayDawnOfManAudio` per leader. R&F and GS leaders use
  this table to customize their loadscreen experience without
  the Lua needing to know.
- **Challenge mode**: if `Challenges.IsChallengeActive()`,
  challenge name + description override leader text and the
  Dawn of Man speech is suppressed (line 372)

**Implication**: zero per-ruleset code changes. One companion
file, three test runs.

## Current accessibility state

**Speaks nothing.** The Sean Bean (or per-locale equivalent)
audio plays but is voice-over only — none of the visible text
(civ, leader, era, abilities) is announced via screen reader.
Player sits through 30-60s of audio narration without knowing
what's on screen unless they understand and pay attention to the
narrator.

**Subtitle support — probed 2026-05-22.** Civ VI ships SRTs
under `Base/Assets/UI/Subtitles/<locale>/` for 13 locales
(de_DE, en_US, es_ES, fr_FR, it_IT, ja_JP, ko_KR, pl_PL,
pt_BR, ru_RU, zh_Hans, zh_Hans_CN, zh_Hant_HK). Per-locale
content under en_US: `civ6_cinematic.srt`, `Culture.srt`,
`Defeat.srt`, `Domination.srt`, `Religion.srt`, `Science.srt`,
`Time.srt`, `TUT_INTRO.srt`, `TUT_OUTRO.srt`. Expansion 1
adds `Expansion1*.srt`; Expansion 2 adds `XP2_Opening*.srt` +
`XP2Victory*.srt`.

**There is no Dawn of Man SRT in any locale.** The speech is
fired via `UI.PlaySound("Play_DawnOfMan_Speech")` — a Wwise
SoundBank event (audio lives in per-locale
`Base/Platforms/Windows/audio/<Language>/Speech*.bnk` and
related files). The Bink-style `.srt` pipeline is reserved for
the boot cinematic, victory cinematics, and the two tutorials.

**Implication for deaf-blind support**: we cannot extract Sean
Bean's words from a shipped subtitle. Options:
1. Use `LOC_LOADING_INFO_<LEADER_TYPE>` (the already-
   translated leader paragraph the visual UI displays) as a
   stand-in transcript via Ctrl+S — it covers similar
   substance ("Cleopatra rules Egypt. As Pharaoh she is a
   pragmatic ruler...") and is shipped in every supported
   locale. This is the path of least resistance.
2. Hand-transcribe Sean Bean per-leader into a new
   `LOC_CIVVIACCESS_LDR_<TYPE>_DAWN_TRANSCRIPT` LOC key.
   Higher fidelity but per-leader effort + per-locale audio
   work. Defer to finishing polish.
3. Wait for a community SRT — none known to exist.

Recommend Option 1 as ramps; Option 2 as future polish.

**Advance hotkey doesn't work during the speech** (verified by
Noel 2026-05-22). My earlier claim that Esc/Enter let a player
skip past the briefing was wrong — the engine's
`ContextPtr:SetInputHandler` doesn't land until line 496 of
LoadScreen.lua, which fires inside `OnLoadGameViewStateDone`.
That event fires only when the world is fully loaded, which on
a typical machine is AFTER the Sean Bean narration has run.
So in practice the player is locked into listening through the
speech with no keyboard escape. Our implementation needs to
install its own input handler earlier (subscribed to
`Events.LoadScreenContentReady`) so we can offer a real skip
key before the engine's handler arrives.

## Blind-first design

Goal: deliver the same briefing a sighted player gets from
reading the on-screen text, **before** the Sean Bean narration
starts — so the player has the lay of the land while the
voice-over plays. The describer-output portrait briefs
(LeaderDescriptions.xml) supply the visual layer.

### Design directives (Noel, 2026-05-22)

These shape the implementation:

1. **Briefing speaks first**, then offer to advance into the
   Dawn of Man speech. Don't queue our briefing during Sean
   Bean — speak it first while the load is still pre-speech, or
   suppress Sean Bean until our briefing is done.
2. **Auto-copy the full briefing to clipboard** (per
   [[project_rich_text_clipboard_pattern]]) so the user can
   paste into Notepad / preferred reader for slow re-read.
3. **Play a "clip" earcon** whenever long description data is
   copied to clipboard — a distinct auditory marker so the
   user knows the copy happened. Noel will generate via
   ElevenLabs (ties to [[project_elevenlabs_earcons]]).
   Becomes a project-wide convention for any long-text speech
   path, not just this screen.
4. **Verbosity-gated**: a future game-options accessibility
   setting controls whether auto-clip-to-clipboard fires for
   long text. Default-on; verbose-off users get speech-only.
   Ties to [[project_verbosity_someday]].
5. **Allow the user to skip the Dawn of Man speech entirely**.
   Today the engine doesn't expose Esc until post-load (see
   "Current accessibility state"); we install our own input
   handler early so a skip key works during the briefing /
   speech window.
6. **Subtitle / SRT support for deaf-blind users**: if a Dawn
   of Man subtitle file exists for the current locale, expose
   the speech transcript via a clip-to-clipboard hotkey so a
   deaf-blind user can read what Sean Bean is saying. Probe
   for SRT presence (see Current accessibility state TODO);
   if absent, generate a transcript from the leader info text
   as a substitute.

**On `Events.LoadScreenContentReady` (auto-speak briefing):**

Queue these in order, separated by short pauses to allow
interruption:

1. `"Loading. <Civilization>. Join the world stage."`
   - Example: "Loading. Egypt. Join the world stage."
2. `"<Era> Era."` (from `GameInfo.Eras[startEra].Description`)
   - Example: "Ancient Era."
3. `"<Leader Name>. <Portrait brief>."` — leader brief is the
   SHORT field from `LOC_CIVVIACCESS_LDR_<LEADER_TYPE>_SHORT`
   - Example: "Cleopatra. A woman in a black gown with a white
     ruff holds a champagne flute forward against a dark teal
     map of the world."
4. `"<LeaderInfo>"` — the full leader paragraph from
   `LOC_LOADING_INFO_<LEADER_TYPE>` (already-translated game text)
   - Example: "Cleopatra rules Egypt. As Pharaoh she is a
     pragmatic ruler whose alliance loyalty…"
5. `"Unique abilities and features."`
6. For each unique ability / unit / building, in the same order
   the visual FeaturesStack shows them:
   - `"<Header>. <Description>."` (Description stripped of
     `[ICON_*]` tags per
     [[reference-civ-vi-icon-tags-in-labels]])
7. `"Press Ctrl+I for full leader description. Press Ctrl+T to
   re-read abilities. Press Enter or Escape when ready to begin."`

Estimate: 30-60s of speech depending on how many uniques the
civ has. **Goal**: this finishes BEFORE Sean Bean starts (or
Sean Bean is suppressed during it), so the player gets the
briefing first, then chooses whether to listen to the speech.

After step 7, play the **"clip" earcon** (signaling the full
briefing was copied to clipboard — see directive #3 above) and
prompt: "Press Enter to start the Dawn of Man speech, or Escape
to skip to the game." This becomes the player's decision point.

**On `Events.LoadGameViewStateDone` (briefing complete, world
ready):**

- Stop any in-progress queued briefing
- Speak `"Loading complete. Press Enter or Escape to begin the
  game."`
- Play the **"ready" chime** — Noel to generate via ElevenLabs;
  intended sound is **pages of a book turning**, fitting the
  Civilization era / encyclopedia aesthetic. Layered with
  speech so the cue lands without blocking the announcement.

**Hotkeys (active during briefing AND post-load — installed
early so they work before the engine's input handler arrives)**:
- `Ctrl+I` → speak `LOC_CIVVIACCESS_LDR_<LEADER_TYPE>_LONG` (the
  full portrait description) + copy to clipboard + clip earcon
- `Ctrl+T` → re-speak the abilities list + copy to clipboard +
  clip earcon
- `Ctrl+S` (subtitle) → if a Dawn of Man SRT exists for the
  current locale, copy its transcript to clipboard + clip
  earcon, then speak "Sean Bean transcript copied" (or locale
  equivalent). Falls back to "Subtitle not available" if no SRT.
- `Esc` → skip to game (our handler dispatches even before
  engine input lands)
- `Enter` → during briefing: advance to Dawn of Man speech;
  post-briefing: start game
- `Ctrl+R` (optional, future polish) → re-speak the whole briefing

**Sighted player parity check**: yes, a sighted player can read
the on-screen text repeatedly while Sean Bean talks, and can
read it again while waiting for the load. Our briefing + Ctrl+I
+ Ctrl+T give the blind player equivalent re-readable access.

## Implementation notes

**New file**: `CivViAccessMod/Assets/UI/Accessibility/LoadScreenAccess.lua`

**Pattern**: same as other accessibility companions — included
at the end of a shadow `CivViAccessMod/Assets/UI/Frontend/LoadScreen.lua`
that mirrors the base file plus a final `include("LoadScreenAccess")`.

**Code outline** (~200 LOC estimate, probably 400-500 once
edge cases land per [[feedback-loc-estimates-anchor-low]]):

```lua
include("ScreenReader")
include("Civ6Common")  -- for GetLeaderUniqueTraits etc.

local _priorContentReady = OnLoadScreenContentReady
local _priorViewDone = OnLoadGameViewStateDone

local function buildBriefing(leaderType, civType, ...)
  -- Mirror the same data-fetching the visual code does:
  -- - playerConfig:GetCivilizationDescription()
  -- - GameInfo.Eras[startEra].Description
  -- - GameInfo.Leaders[leaderType].Name
  -- - LOC_LOADING_INFO_<leaderType>
  -- - GetLeaderUniqueTraits / GetCivilizationUniqueTraits
  -- - LOC_CIVVIACCESS_LDR_<leaderType>_SHORT
  -- Return a single string with newline-separated paragraphs
end

local function speakBriefing(text, clipboardMarkdown)
  -- Use queued speech (interrupt=false) so each paragraph
  -- plays without cutting the previous off.
  -- Strip [ICON_*] tags per stripIconTags helper.
  -- Copy clipboardMarkdown (NOT the raw speech string) to
  -- clipboard via UI.SetClipboardString — clipboard variant
  -- uses simple markdown (## headings for sections, - for
  -- ability bullets). No tables (per
  -- [[feedback_communication_preferences]]).
  -- Play clip earcon after copy.
end

function OnLoadScreenContentReady()
  if _priorContentReady then _priorContentReady() end
  -- Skip if WorldBuilder editor (line 164 path)
  if GameConfiguration:IsWorldBuilderEditor() then return end
  local localPlayer = Network.GetLocalPlayerID()
  -- ... same hotseat localPlayer lookup as base ...
  local playerConfig = PlayerConfigurations[localPlayer]
  local leaderType = playerConfig:GetLeaderTypeName()
  local civType = playerConfig:GetCivilizationTypeName()
  local briefing = buildBriefing(leaderType, civType, playerConfig)
  speakBriefing(briefing)
  installHotkeys(leaderType)
end

function OnLoadGameViewStateDone()
  if _priorViewDone then _priorViewDone() end
  OutputMessageToScreenReader(
    Locale.Lookup("LOC_CIVVIACCESS_LOAD_COMPLETE_READY"))
end
```

**LOC strings to add**:
- `LOC_CIVVIACCESS_LOAD_BRIEFING_HEADER` —
  "{1_Civ}. Join the world stage."
- `LOC_CIVVIACCESS_LOAD_ERA_FORMAT` — "{1_Era} Era."
- `LOC_CIVVIACCESS_LOAD_LEADER_INTRO` —
  "{1_LeaderName}. {2_PortraitBrief}."
- `LOC_CIVVIACCESS_LOAD_FEATURES_HEADER` —
  "Unique abilities and features."
- `LOC_CIVVIACCESS_LOAD_COMPLETE_READY` —
  "Loading complete. Press Enter or Escape to begin the game."
- `LOC_CIVVIACCESS_LOAD_HOTKEY_HINT` —
  "Press Ctrl+I for full leader description. Ctrl+T to
  re-read abilities. Ctrl+S for the Dawn of Man transcript."
- `LOC_CIVVIACCESS_LOAD_BRIEFING_DECISION` —
  "Press Enter to start the Dawn of Man speech, or Escape to
  skip to the game."
- `LOC_CIVVIACCESS_LOAD_TRANSCRIPT_COPIED` —
  "Dawn of Man transcript copied."
- `LOC_CIVVIACCESS_LOAD_TRANSCRIPT_MISSING` —
  "Subtitle not available for this leader."

**Earcon assets to add** (Noel generating via ElevenLabs):
- `clip.wav` — short distinct cue played whenever long
  description data is copied to clipboard. Project-wide
  convention from this trace forward, not loading-screen-
  specific. Coordinate with [[project_elevenlabs_earcons]] +
  [[project_earcon_system_feedback]].
- `ready_chime.wav` — pages-of-a-book-turning sound for the
  "loading complete" announcement. Fits the Civilization
  encyclopedia aesthetic.

**Dependencies**:
- Task #12 (describer batch) must produce LeaderDescriptions.xml
  before this wiring is useful — without the SHORT/LONG LOC
  keys, layers 3 and Ctrl+I/Ctrl+T fall back to terse.
- Foundation work (HandlerStack / Help) provides the input layer
  for Ctrl+I / Ctrl+T / Ctrl+S.
- Earcon assets (clip + ready chime) need to be in the mod
  before final ship; speech-only path works as interim.
- Ctrl+S transcript source — per SRT probe (Current
  accessibility state), no Dawn of Man SRT ships. Ramps
  implementation uses `LOC_LOADING_INFO_<LEADER_TYPE>` as the
  transcript stand-in. Polish path: per-leader hand-transcribed
  `LOC_CIVVIACCESS_LDR_<TYPE>_DAWN_TRANSCRIPT` keys, deferred.
- Future verbosity option (per [[project_verbosity_someday]])
  gates auto-clip behavior — until that option exists, default
  is clip-on for long text.

**Modinfo**: shadow the LoadScreen.lua + register the new
LoadScreenAccess strings via `<UpdateText>`.

## Test plan

Run each ruleset (Vanilla, R&F, GS), report per-ruleset
pass/fail.

1. Start a new game from AdvancedSetup with a known leader
   (Cleopatra for Vanilla, Tamar for R&F-exclusive, Mansa Musa
   for GS-exclusive).
2. Confirm the briefing auto-speaks starting from
   `Events.LoadScreenContentReady`, BEFORE Sean Bean begins
   (or with Sean Bean suppressed until briefing finishes).
   Verify in order:
   - "Loading. Egypt. Join the world stage."
   - "Ancient Era." (or other start era)
   - "Cleopatra. <portrait brief>."
   - Leader info paragraph
   - "Unique abilities and features."
   - Each ability / unit / building announced
   - Hotkey hint
   - **Clip earcon** plays (clipboard copy confirmation)
   - "Press Enter to start the Dawn of Man speech, or Escape
     to skip to the game."
3. Verify Ctrl+I during briefing speaks the full LONG portrait
   description, copies to clipboard, plays clip earcon.
4. Verify Ctrl+T re-speaks the abilities list + clip earcon.
5. Verify Ctrl+S either copies Sean Bean transcript + clip
   earcon (if SRT present) or speaks "Subtitle not available"
   (if absent).
6. Press Escape during briefing → game proceeds to world view
   (skip path works even though engine input handler hasn't
   installed yet — our early handler dispatches).
7. Repeat run: let briefing finish, press Enter → Sean Bean
   speech plays through. Press Escape during speech → game
   proceeds.
8. Wait for "Loading complete" + **ready chime** (pages
   turning) announcement; confirm it stops any in-progress
   briefing.
9. Open Notepad after each run, paste — verify clipboard
   contains the simple-markdown briefing (## headings, -
   bullets, no tables).
10. Repeat under each ruleset; verify era + ability counts
    shift appropriately.
11. Edge cases:
    - Saved-game load — verify "Continue Game" button text +
      loading info comes from saved-era metadata
    - WorldBuilder editor — verify briefing skipped (matches
      base code's early-return path)
    - Challenge mode — verify challenge name/description
      overrides leader info (base sets this; we mirror)
    - Hotseat — verify first human's data is used (base does
      this iteration; we mirror)
12. **Skippability regression** — explicitly verify the
    pre-correction-claim is now wrong: Escape during Sean
    Bean's speech (with our handler) skips; without our mod,
    Escape during the speech still does nothing (engine
    handler not yet installed).

## Cross-references

- [[project_layered_info_hotkeys]] — Ctrl+I / Ctrl+T convention
- [[project_rich_text_clipboard_pattern]] — copy briefing to
  clipboard alongside speech
- [[reference_civ_vi_icon_tags_in_labels]] — strip [ICON_*]
  from ability descriptions
- [[project_cinematic_playback_behavior]] — related: Sean Bean
  audio plays every launch; the briefing-first directive here
  reframes the toggle question (suppress or delay Sean Bean
  during our briefing).
- [[reference_civ_vi_cinematic_audio_pipeline]] — context on
  cinematic audio + SRT path; informs the Dawn of Man subtitle
  probe (Current accessibility state → TODO)
- [[project_elevenlabs_earcons]] +
  [[project_earcon_system_feedback]] — the clip earcon + ready
  chime are the first additions to the earcon library from
  trace work
- [[project_verbosity_someday]] — verbosity toggle that gates
  auto-clip-to-clipboard for long-text speech paths
- [[project_native_language_leader_speech]] — related but
  different surface: in-game leader voice subtitles (diplomacy
  context). Dawn of Man speech is a separate Wwise event;
  subtitle pipeline likely separate too.
- Task #12 — LeaderDescriptions.xml supplies the
  `LOC_CIVVIACCESS_LDR_<TYPE>_SHORT/_LONG` strings consumed here
