# 07 — Leader-intro cinematic (investigation result)

The blind-first trace plan listed this as "does Civ VI play a
leader-intro cinematic on first turn? Investigate."

**Answer: no.** There is no per-leader cinematic that plays for
the player's own civ between AdvancedSetup and first-turn
interactivity. The game-start sequence is:

1. Boot animation (waypoint 00 — Firaxis/2K logos)
2. MainMenu (waypoints 01-02)
3. AdvancedSetup (waypoint 03)
4. Loading screen with Sean Bean Dawn of Man audio + civ
   illustration (waypoint 04)
5. Expansion intro slideshow if R&F or GS (waypoint 05)
6. First-turn advisor popup (waypoint 06)
7. World becomes interactive (waypoint 10)

No cinematic between any of these. The "leader intro" experience
is delivered via the loading screen's Sean Bean narration plus
the static leader portrait + civ illustration — both already
covered by waypoint 04's blind-first design.

## What I checked

- `Base/Assets/UI/FrontEnd/IntroScreen.lua` — this is the
  pre-MainMenu intro (Firaxis/2K logos and the spinning globe);
  belongs to waypoint 00, not here
- `Base/Assets/UI/Popups/LeaderView.lua` (133 lines) — handles
  the diplomacy LeaderScreen transitions
- `Base/Assets/UI/Subtitles/<locale>/civ6_cinematic.srt` —
  subtitles for the boot intro cinematic only
- Grep for `PlayLeaderCinematic|StartCinematic|LeaderCinematic`
  across all UI Lua — only 3 matches, all in mid-game contexts
  (Options.lua autoplay setting, TutorialUIRoot.lua for tutorial
  triggers, LeaderView.lua for diplomacy)
- Grep for `FullScreenMovie` — same; mid-game / options only

## Where leader cinematics DO play (out of scope for this trace)

`LeaderView.lua` is the diplomacy leader screen that transitions
to a leader cinematic when the player:

- Meets another civ for the first time
  (`Events.DiplomacyMeet` → `ShowFirstMeetingLeader`)
- Declares war (`Events.DiplomacyDeclareWar` →
  `ShowWarLeader`)
- Refuses peace (`Events.DiplomacyRefusePeace` →
  `ShowRefusePeaceLeader`)
- Initiates diplomacy from the city banner
  (`LuaEvents.CityBannerManager_TalkToLeader` →
  `OnTalkToLeader`)
- Receives a leader popup (`Events.LeaderPopup`)

Each of these transitions into the full leader cinematic scene
(3D animated leader, voice line in native language, subtitled
greeting). For example, when you first meet Cleopatra, the
LeaderScreen opens showing her 3D model in her diplomacy
environment, plays her Egyptian-language greeting, and shows the
English subtitle "Greetings."

**These all belong to mid-game work** ([[project-multiplayer-parity-goal]]
and broader diplomacy accessibility), not the new-game flow this
trace plan covers. See [[project-native-language-leader-speech]]
for the subtitle-exposure design that activates when we hit
diplomacy.

## Ruleset variants

Not applicable — there's nothing to vary for a waypoint that
doesn't exist.

## Implementation notes

**Action**: none. Waypoint deletes from the implementation
queue. Update the trace plan sequence to remove it, OR keep this
doc as a reference that the answer was "no" so future-us doesn't
re-investigate.

The cinematic infrastructure that DOES exist (boot animation
audio + diplomacy leader scenes) is captured in:

- [[reference-civ-vi-cinematic-hookpoints]] — Lua-hookable
  cinematics (victory, wonder, tutorial) vs engine-native boot
  intro
- [[reference-civ-vi-cinematic-audio-pipeline]] — split .bk2 +
  .wem cinematic audio
- [[project-audio-description-production-plan]] — AD pipeline
  for cinematics that DO exist

## Cross-references

- Waypoint 04 — loading screen IS the "leader intro" experience
  for the player's own civ; design lives there
- [[project-native-language-leader-speech]] — diplomacy leader
  speech subtitle exposure (future, mid-game scope)
- [[reference-civ-vi-cinematic-hookpoints]] — broader cinematic
  catalog
