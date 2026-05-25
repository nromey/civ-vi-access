# Civ VI Access Roadmap

Multi-arc plan from 0.5.x (in flight) through 1.0+. Each arc is a
self-contained release line ending in a tagged release. Arcs ship
sequentially; within an arc, versions ship as testable increments
so we never have a long stretch of "everything's broken until X."

This is a working doc. Reorder, defer, or pull forward as priorities
shift. Goal is to expose more of the game at the right time and not
forget expansion-gated pieces.

## North star

- **0.5.x** — A blind player can play a peaceful turn-1-to-turn-N
  builder game start to finish. (Playable basics.)
- **0.6.x** — That player can deeply inspect the world and learn the
  game without sighted help. (Inspection + civilopedia.)
- **0.7.x** — The game's own tutorials teach a blind first-time
  player from scratch. (Tutorial accessibility.)
- **0.8.x** — That player can defend themselves and interact with
  rival civs. (Combat + diplomacy.)
- **0.9.x** — Mid-game systems become reachable. (Religion,
  espionage, trade, great people, era transitions.)
- **1.0.x** — Late-game victory paths work end-to-end, including
  Gathering Storm content. (Victory + climate + World Congress.)
- **Post-1.0** — Cross-platform (Mac), Civ VII foundation,
  multiplayer parity, polish (AD, earcons, narration depth).

Each arc enables a clearly larger fraction of the game. None require
finishing earlier arcs perfectly — we ship, polish later.

---

## Arc 0.5: Playable Basics (in flight)

**Goal**: peaceful builder game playable end-to-end.

Plan: `docs/PLAYABLE_BASICS_PLAN.md` (authoritative).

- **0.5.0** ✓ Movement Phase 1 (Shift+QAZEDC direct-move)
- **0.5.1** City production picker — the play-loop closer
- **0.5.2** Research access — tech + civic pickers
- **0.5.3** Movement Phase 2 — multi-hex target mode + path preview

**Expansion notes**: This arc is base-game only. Tech/civic trees are
expanded in R&F/GS (more techs, future tech in GS) but the picker
architecture is identical.

---

## Arc 0.6: Inspection + Civilopedia (next after 0.5)

**Goal**: player can learn the game and inspect any piece of state on
demand.

- **0.6.0** Civilopedia keyboard nav. Arrow through categories →
  Enter to drill → arrow through topic body → cross-link nav.
  Ports the Civ V Access analog. ~500 LOC.
- **0.6.1** Civilopedia LOC overrides. Author keyboard-friendly
  rewrites of mouse-centric instruction text. `"Click an icon to
  select a unit"` → `"Period or comma to cycle units. Shift+letter
  to move."` Crowdin pipeline for translation later. Ledger doc
  tracks what's overridden.
- **0.6.2** Plot inspection deep-dive. Ctrl+T verbose plot announce
  — yields, appeal, continent, movement cost, defense modifier,
  improvements, district adjacencies. Already in HexCursor scope,
  needs expansion.
- **0.6.3** World Tracker accessibility — yields per turn, current
  research/civic with ETA, era progress, score. Hotkey to open.
- **0.6.4** Message buffer — cycle through recent notifications via
  `[` / `]` (Civ V Access parity). `Ctrl+[`/`]` for first/last.
  `Shift+[`/`]` for filter cycle. Persistent across the session so
  user can re-read missed announces. Mirrors
  `CivVAccess_MessageBuffer.lua` from Civ V Access.

**Expansion notes**: 0.6.2 plot inspection needs expansion-aware
fields when those rulesets are active: loyalty pressure (R&F),
climate type / CO2 / sea-level (GS).

---

## Arc 0.7: Tutorial Accessibility

**Goal**: Civ VI's own tutorials teach a blind first-time player.

Per `project_tutorial_accessibility_goal` — tutorial layers ONTO the
primitives. Now that 0.5.x has shipped the primitives the tutorial
teaches (move, build, research, found city), the tutorial can
actually reference what we built.

- **0.7.0** Tutorial framework integration. Subscribe to advisor /
  goal / world-pointer LuaEvents per
  `reference_civ_vi_tutorial_arch`. Make popups arrow-navigable and
  speak their text + options.
- **0.7.1** "First Look" tutorial accessible end-to-end. Civ VI's
  built-in tutorial. Validate every tutorial step is speakable and
  uses our keyboard idioms. Likely needs LOC overrides per 0.6.1
  approach.
- **0.7.2** Goal tracker + advisor recommendations accessibility.
  "Your settler should found a city" → speakable nag list.
- **0.7.3** Civ V-style advisor ↔ civilopedia integration. Civ V's
  advisor fires frequently and opens civilopedia to the relevant
  topic when teaching ("You founded a city" → opens "Cities" page).
  Civ VI's advisor fires less often and never opens civilopedia.
  Our wrapper: on advisor-popup events, offer "Press Enter for more
  detail" → opens accessible civilopedia to the matching topic.
  Gives blind players the same teaching depth Civ V gives sighted
  players. Depends on 0.6.0 (civilopedia kb nav) shipping first.

**Expansion notes**: No expansion-specific tutorials worth tackling
yet.

---

## Arc 0.8: Combat + Diplomacy

**Goal**: blind player can defend their civ and interact with rivals.

Combat was explicitly deferred from 0.5.x. Time to add it.

- **0.8.0** Combat — attack, ranged attack, melee odds preview,
  combat result announce, kill/death speech. Ports Civ V Access
  combat preflight pattern.
- **0.8.1** Diplomacy — meet civ event, deal proposal screen, war/
  peace, agenda visibility. The diplomacy screen is one of Civ VI's
  most complex; will need its own multi-version sub-arc.
- **0.8.2** Battle planner / scanner — Civ V Access port for
  "what's around me," "what can attack me," "what can I attack."
  Bindings (per Civ V Access parity): PageUp/PageDown for item
  cycling, Ctrl+PgUp/PgDn for primary categories, Shift+PgUp/PgDn
  for subcategories, Alt+PgUp/PgDn for instances, Home jumps cursor
  to entry, End speaks distance, Ctrl+F opens search. Surveyor
  port collides with our Shift+QEADZC unit-move — pick a different
  surveyor activation gesture (likely Alt+modifier prefix) so
  Civ V Access muscle memory still maps cleanly to scanner +
  surveyor activation without trampling our move bindings.
- **0.8.3** Declaration popup arrow nav — war/peace confirmations.

**Expansion notes**: 0.8.1 diplomacy + 0.8.3 popups are
expansion-aware (R&F adds agendas, GS adds World Congress
deflection, environmental concerns). Diplomacy screen UI is
ruleset-aware but our wrapper can be ruleset-agnostic.

---

## Arc 0.9: Mid-game Systems

**Goal**: mid-game depth reachable.

Order within this arc is flexible — these can ship in any sequence.

- **0.9.0** Era transitions speech (R&F-gated) — golden/dark age
  announce, dedication picker, era score readout.
- **0.9.1** Religion — pantheon picker, beliefs, found religion,
  missionary actions, religious pressure readouts.
- **0.9.2** Espionage — recruit spies, mission picker, mission
  outcome speech.
- **0.9.3** Trade Routes — start trade, route picker, route yield
  readout, route end announce.
- **0.9.4** Great People — recruitment, ability use, era points
  toward great people.
- **0.9.5** Governors (R&F-gated) — recruit, assign, promote.
- **0.9.6** Loyalty (R&F-gated) — per-city pressure readout, free
  city flip alerts.

**Expansion notes**: 0.9.0, 0.9.5, 0.9.6 require R&F or higher.
Gate on `GameConfiguration.GetRuleSet()` so vanilla games don't
crash.

---

## Arc 1.0: Late Game + Gathering Storm

**Goal**: a complete game ends with an accessible victory or defeat.

- **1.0.0** Victory progress UI — each victory type (Science,
  Culture, Domination, Religion, Diplomatic). Speakable progress
  toward each.
- **1.0.1** World Congress (GS-gated) — resolutions, voting,
  diplomatic favor accumulation.
- **1.0.2** Climate Change (GS-gated) — CO2 level, climate phase,
  sea-level rise warnings, flood / storm alerts.
- **1.0.3** Power (GS-gated) — coal/oil/uranium consumption per
  turn, renewable energy generation, power-required-by-city status.
- **1.0.4** Endgame screens — victory cinematic, score breakdown,
  rankings, "play one more turn" prompt.
- **1.0.5** Future Tech tree (GS-gated) — repeatable end-game tech.

**Expansion notes**: 1.0.1, 1.0.2, 1.0.3, 1.0.5 are GS-only. Gate
on ruleset. Vanilla and R&F games skip these phases.

---

## Cross-cutting tracks (not gated on arcs)

These can run in parallel with any arc:

- **Earcons** — per `project_elevenlabs_earcons`. Once ElevenLabs
  trial validates, generate first batch (nav / wrap / drill / back /
  activate / error / terrain types).
- **Cinematic AD** — per `project_audio_description_production_plan`.
  Boot intro, victory, wonder, leader speech. AI-generated then
  human-polish.
- **Visual descriptions** — per `project_visual_describe_hotkey` +
  `reference_gemini_credit_available`. Leaders, wonders, natural
  wonders, terrain. Ctrl+I per-element describe.
- **Native-language leader subtitles** — per
  `project_native_language_leader_speech`. Activates with 0.8.1
  diplomacy.
- **CAMM v0.6.0 — Prism backend** — per
  `project_camm_screen_reader_abstraction`. Cross-platform
  foundation; might also fix CAMM dedupe issues seen in #25b.
- **NVDA / JAWS add-ons** — per `project_screen_reader_addons`.
  Auto-suspend numpad object-nav while Civ VI is foreground.

---

## Post-1.0: Reach

After 1.0 — these become possible.

- **Mac port** — per `project_cross_platform`. CAMM v0.6.0 Prism
  swap enables this. Mod-side already portable; helper needs Tolk
  replacement + Win32 swap.
- **Multiplayer parity** — per `project_multiplayer_parity_goal`.
  Turn timers, chat, diplo announce, combat results, per-player
  sighted/blind mode toggle (per `project_sighted_mode_per_turn`).
- **Civ VII foundation port** — per `project_cross_game_foundation`.
  HandlerStack / InputRouter / Help / Log / BaseMenu modules
  designed to port. Engine-specific calls (HexCursor) need rewrite.
- **Audio description tiers** — per `project_audio_description_vision`.
  SRT-via-Tolk → TTS track → human-voiced. 14 languages.

---

## Order rationale (the why)

1. **Playable basics first** because without movement / production /
   research, nothing else matters — you can't END a turn.
2. **Civilopedia before tutorial** because civilopedia is reference
   material reachable any time; tutorial uses primitives we've
   built. Tutorial layers on civilopedia, not the other way.
3. **Combat after inspection** because combat decisions require
   knowing terrain + adjacent units, which inspection (Ctrl+T)
   surfaces.
4. **Mid-game after combat** because religion/espionage/trade
   intersect with diplomacy and combat.
5. **GS endgame last** because Future Tech / Diplomatic Victory /
   climate disasters only matter after a long game has played out.

---

## How to use this doc

- Adding new ideas: drop them in the relevant arc with rationale.
  If they don't fit any arc, propose a new one or move to
  cross-cutting.
- Pulling something forward: flag the dependencies it skips. The
  ordering exists for reasons; breaking it has costs.
- Marking work complete: leave the entry in place with a "shipped
  in vX.Y.Z" suffix so the historical sequence stays readable.
- Deferring expansion content: gate on `GameConfiguration.GetRuleSet()`
  or `Modding.IsModEnabled()`. Don't crash vanilla games on
  expansion code paths. See `docs/EXPANSION_BACKLOG.md` for the
  ruleset / mode taxonomy.

---

## Open architectural questions

These shape the roadmap but aren't decided yet:

- **CAMM v0.6.0 timing**: pull forward to fix #25b dedupe and start
  Mac port runway, or stay disciplined and finish 0.5.x first?
- **Civilopedia scope**: full keyboard nav including all categories,
  or start with the most-used ("How to play X" pages) and expand?
- **Crowdin spinup**: do we wait until volume justifies the
  infrastructure, or set it up early so accessibility strings
  translate as we author them?
- **Tutorial vs primitives**: 0.7 tutorial work assumes we'll
  override every "click here" instruction. Does that require us to
  finish ALL primitives first, or can tutorial ship partial?
