# Civ VI Access — Ordered Task Plan

**Current as of 2026-06-09.** This is the cross-session source of truth for what
to work on and in what order. (The per-session task tracker does NOT persist
between Claude Code sessions — this file does. Also see the persistent memory:
`~/.claude/projects/C--dev-Civ-vi-access/memory/MEMORY.md` and
`project_session_handoff_2026_06_08.md`.)

## North star

Once **P1 (scanner complete) → P2 (movement) → P3 (combat)** land, Noel can play
solo with Claude on standby for fixes. Everything after is depth; the infra items
ride alongside and don't block play.

Goal framing test: "is this enough to actually play a turn?" beats checklist
completeness.

---

## ►► 0.8.0 BATCH — current focus (Noel 2026-06-14, long session, agreed plan)

**0.7.1 shipped first** (Shift+/ list, reader polish, input lock, "Game restored").
This batch = remaining pre-bump polish + the reporting arc, designed up front for
**Civ V key-mode parity** — the reports are the data surfaces that mode needs
([[project_keymap_profiles_civ_v_compat]]), so build them to cover what a Civ V
player reaches for (economic log etc.), not just our own sections.

1. **Finish pre-bump.**
   - **Granary Ctrl+T building-describe — FIXED & CONFIRMED (2026-06-14).** Root
     cause: `ProductionPickerAddin` never `include()`d `ToolTipHelper`, so it was
     nil in that addin VM and the tooltip block was skipped for EVERY kind; only
     `row.Description` survived (districts have it, buildings don't → Granary silent).
     Added the include; log shows `kind=building hasDesc=false ttOk=true ttLen=95`.
     REMAINING: (a) STRIP `LONGFORM_DEBUG`; (b) optional — pad the building path
     with yields/maintenance/prereqs (building tooltip is inherently short vs a
     district's; ttLen=95).
   - **Engine-hotkeys-in-Help audit** (see the #16 block below): surface engine
     actions (auto-explore Alt+X etc.) in Help; own/announce the silent Alt-letter
     actions. Pairs with #15's registry + the #14 remainder.
   - **Bracket cluster — DECIDED, keep as-is (Noel 2026-06-14).** Reviewed the Civ V
     model (unified buffer + filter ladder on `[`/`Shift+[`/`Ctrl+[`). Noel prefers
     VI's split (notifications on `[` `]`, speech history on Shift+R/Ctrl+R, city
     cycle on Shift+brackets) — keeping the notification channel clean beats V's
     merge. No swap, no merge, no city-cycle relocation. Two backlog items only:
       - **Notification-category filter on `Ctrl+[` / `Ctrl+]`** (free combo): cycle
         filter so a busy stream can be walked by category (combat / diplomacy /
         city-production / all). ~30-40 LOC; slot into 0.8.0 if time, else park.
       - **Chat-in-buffer** — defer to multiplayer (only pays off there, needs MP
         chat plumbing). MP watchpoint, not now.
2. **Reporting arc core — web ReportWindow** (reports = web, pager = in-game speech).
   Economy (treasury, per-turn gold/sci/culture/faith + ETAs), per-city yields (the
   mine-effect acceptance test), cities. Detail: P5 / [[project_empire_status_expansion]].
3. **Territory + exploration section** — owned/improved/workable tiles, % explored,
   nearest fog edge ([[project_map_exploration_report]]).
4. **LOC sweep** woven through 2-3: ALL `Speech.emit` onto the LOC file + the standing
   #18 backlog ([[project_localization_approach]]).

Before tagging 0.8.0: strip `LONGFORM_DEBUG`, confirm `LOAD_DEBUG` stays false. The
Civ V key REMAPPING itself stays a later task; this batch builds the reports it needs.

---

## P0 — Prism speech backend + user-selectable output  *(SHIPPED 2026-06-09: camm v0.6.0)*

CAMM screen-reader abstraction so users pick their speech library.

- Add `IScreenReader` to CAMM (`Init/Speak/Stop/IsSpeaking/Shutdown`); back it
  with Tolk (default) + Prism (opt-in). `AccessibleOutputHandler` calls through
  the interface, not Tolk directly. The v0.5.4 coalesce window stays above the
  interface so both backends inherit it.
- **Our own** thin P/Invoke wrapper — NOT a third-party managed wrapper. Build
  Prism from source with clang, bundle `prism.dll` exactly like `Tolk.dll`
  (`camm/third_party/tolk/dotnet/Tolk.cs` is the template).
- Civ VI accessibility-settings picker: Tolk / Prism / auto (can hide under
  "advanced").

**Prism recon (source is local at `C:\dev\prism`):**
- Flat **C ABI**, P/Invoke-ready, no shim: `include/prism.h`, `extern "C"`,
  `__cdecl`, `__declspec(dllexport/dllimport)` (define `PRISM_BUILDING` to build
  the DLL), opaque handles (`PrismContext*`, `PrismBackend*`, `PrismConfig`), flat
  `prism_*` funcs. Bind via `[DllImport("prism", CallingConvention=Cdecl)]`.
- License **MPL-2.0** (weak/per-file copyleft) — compatible with our MIT: wrapper
  stays MIT in its own files; preserve Prism's `LICENSE`/`NOTICE` + provide source;
  don't modify Prism's files. Vendoring + building unmodified is clean.
- No upstream C# binding (only `bindings/py`) → hand-rolled wrapper is right.
- clang is already on the GitHub Actions Windows runner — CI needs no extra install.

**Decision (RESOLVED 2026-06-09, chose pinned):** pinned Prism submodule —
reproducible release tags, same model as camm, pull latest locally on demand.
NOT pull-latest-every-build (would detonate a release on an upstream change,
same class as the dirty-submodule break). Now at `camm/third_party/prism` @ bb68308.

**Read first:** RimWorld Access (`C:\dev\rimworld_access`) ships both prism + tolk
DLLs in its mod dir — copy its DLL-load + selection/fallback pattern.

> UPDATE 2026-06-09 (this session): SHIPPED. `IScreenReader` + Tolk/Prism backends
> (our own `[LibraryImport]` P/Invoke, NOT Prismatoid), `ScreenReaderFactory`
> (auto Prism->Tolk fallback), manifest `ScreenReaderBackend` + a
> `CAMM_SCREEN_READER_BACKEND` launch override. Prism BUILT FROM SOURCE via a
> PINNED submodule (`camm/third_party/prism` @ bb68308) + `build/Camm.Prism.targets`
> (BuildFromSource) + `build/build-prism.ps1`. Built with MSVC (clang NOT required:
> VS2026 CMake 4.2 handles C++23; VS2022 CMake 3.31 does not, so release.yml got a
> `lukka/get-cmake` step). camm v0.6.0 committed+tagged+pushed (`743e9fa`);
> civ-vi-access gitlink bumped (`0706ba6`). Validated Prism->NVDA on an
> AOT-published launcher. REMAINING (small, non-blocking): (1) in-game A/B lag test
> (only the launcher's `--about` is proven so far); (2) CI from-source build is
> unproven until the next release tag exercises it (`Prebuilt` mode = fallback);
> (3) the Tolk/Prism/auto settings picker is DEFERRED by Noel until the in-game
> accessibility-options tab exists — the env override covers testing until then.

---

## P1 — Scanner complete  *(do this whole block before movement)*

Make the scanner exhaustive, surveyable, and searchable.

- **#8 Backends** — finish the remaining ones: improvements, geography
  (landmasses/oceans — needs contiguous-area grouping), recommendations.
- **#19 Surveyor** — radius aggregate readout ("Dutch soldier 9 o'clock 6 hexes,
  archer 3 o'clock 3 hexes"); tied to zoom.
- **#12 Search + favorites + beep** — type-to-search a category/entity (the Civ V
  feature Noel saw); favorites; HRTF/stereo-pan beep. (Search is grouped here with
  the surveyor even though the scanner uses it.)
- **#17 Zoom** — radius scope (5×5 / 10×10 / levels), speak zoom state.

## P2 — Movement  *(#10)*

- **Move-to**: send the selected unit to a scanned plot. Scanner Home already parks
  the cursor; wire "issue move order to the current cursor/scanned plot."
- **Routes (manual AND auto)**: select → destination → preview turns-to-arrive →
  confirm a multi-turn move. Pathfinder is in STOCK Lua (`GetMoveToPathEx` →
  `pathInfo.plots`), pure-Lua.
- **Ocean crossings / embarkation** (Noel 2026-06-09): the pathfinder handles
  embarkation, so move-to / routes onto another landmass cross at the narrowest
  navigable point for free — surface via the route PREVIEW (read crossing +
  embark hint + turns, allow adjust). Coast/embark points (`IsCoastalLand`) are
  supporting scanner data; revealed water only (fog). Lean on the router, not a
  hand-rolled water-gap search.
- Cross-VM: units operate in GameCore, the cursor/scanner in the addin VM.

## P3 — Combat  *(#11)*

- Threat awareness (event-driven): barbarian/enemy appearance, "your Warrior was
  attacked." Check `ScreenReaderEventHandlers` for existing coverage first.
- Issuing attacks.
- **At end of turn, speak enemy/other units that MOVED on the grid** (situational
  awareness of what shifted while you weren't looking) — do this here.

## P4 — Civilopedia  *(#21)*

Navigable/readable Civilopedia (`docs/CIVILOPEDIA_PLAN.md`). Look up
units/techs/civics/terrain mechanics in-game.

## P5 — Empire stats  *(#22)*  — EXPANDED 2026-06-09

Grew from "EmpireStatus.lua granularity + turn-1 briefing parity" into a navigable,
heading-jump **world/empire overview** report via the ReportWindow (more exhaustive
than the EOT summary). Absorbs the map/exploration report + resources. Sections:
economy (treasury/gold/sci/culture/faith + ETAs), resources (strategic stockpiles,
luxuries→amenities, unimproved-in-borders — survey feeds it), cities, map/exploration
(% explored, contiguity, where-to-scout, civs/city-states met), standing & threats,
then government/civics/law/production/trade/great-people/era/religion. Core v1 =
economy + resources + cities. Full detail: memory `project_empire_status_expansion`.

**LOC audit while we're here (Noel 2026-06-14):** EOT + empire output mints a lot of
new speech strings, so use this task to sweep ALL speech output onto the LOC file —
no inline English in any `Speech.emit` (CLAUDE.md rule). Covers the new report/EOT
strings AND folds in the standing #18 audit (ScannerCore category labels + backend
itemNames). Reuse Civ VI `LOC_*` tables where they exist; net-new strings get our own
LOC keys in `CivVIAccessStrings.xml`. See [[project_localization_approach]].

## P6 — Diplomacy flesh-out  *(#23)*

Beyond first-contact (shipped v0.6.0): deal/trade screen, DeclareWarPopup (war
routes through it), ongoing diplo interactions.

---

## NEXT UP: Pager + speech history (Noel 2026-06-12 — design settled)

Three losses in one day (Robert's diplomacy line, the reveal payload,
notification detail) proved the gap: speech that gets interrupted is GONE.
Two cooperating pieces, built in this order:

1. **Repeat-last key** (first deliverable, ships before anything else):
   re-speak the most recent utterance, works everywhere.
   (`CIVVIACCESS_RepeatAnnounce` exists as a stub — standardize or replace.)
2. **Speech history queue:** ring buffer of the last N utterances; a key steps
   back through them (newest first), another re-reads. N configurable later in
   the accessibility options tab (NOT built yet — hardcode a sane default,
   ~20). ARCHITECTURE: emits happen in MULTIPLE VMs, so Speech.emit
   LuaEvents-broadcasts each utterance to ONE collector in the addin VM (same
   cross-VM pattern as scanner input forwarding); collector owns history +
   keys.
3. **Pager for long text:** sentence-paged reader (N/P/re-read/Escape),
   buffers notifications while active; any history entry too long for one
   utterance opens IN the pager; context-aware `?` renders through it.
   (Memory: `project_help_pager_and_context_help`.)
   **SURFACE RULE (Noel 2026-06-12): REPORTS (empire/EOT/economy) go through
   the WEB ReportWindow (launcher Edge view, real HTML headings — the proven
   N-key bridge), NOT the pager.** Pager = in-game speech-length content
   (help, long announces, history, advisor text). Don't re-drift.

## Advisor + tutorial content (Noel 2026-06-12 — "crucial for new players")

We SUPPRESSED the first-turn advisor popups (mouse-only modal blockers,
`SuppressFirstTurnAdvisor.lua`) as triage — the CONTENT was never delivered
accessibly. Bring it back as speech: the tutorial system is event-driven Lua
(`AdvisorRaise` / `GoalAdd` / `ShowWorldPointer` LuaEvents — see
`reference_civ_vi_tutorial_arch`), so advisor guidance can speak + land in
the history/pager instead of blocking. Scope when picked up: advisor hints
during play, goal tracking, the "First Look" tutorial path
(`project_tutorial_accessibility_goal`). Pairs with the engine
recommendations already surfaced in the pickers.
DELIVERY SHAPE (Noel 2026-06-12): the advisor/tutorial narrative text gets
REPLACED with accessible event-based modals — our popup-nav standard
(arrow-navigable, re-readable, Escape-dismissable, long text through the
pager), driven by the same tutorial LuaEvents, not the vanilla mouse-only
popups. Civilopedia itself stays P4.

## Queue manager (Noel 2026-06-12 — AFTER the pager + empire report)

Unified queue awareness + editing across production / tech / civics (engine
supports all three natively; GS added research queueing). Two halves, built
in this order:
- **Read side rides the empire report:** per-city "Granary 4 turns, then
  Monument" + "Research: Writing 3 turns, then Currency". Plus completion
  hand-offs already in the overnight briefing (shipped 2026-06-12).
- **Edit side rides the pickers:** a real Queue tab (today it shows only the
  current item) — arrow entries, Delete cancels, reorder, modifier-pick to
  append instead of replace. PolicyWizard's slot-walk is the interaction
  cousin. Prereq lesson (the Granary surprise): NO deeper queueing UX until
  the audibility layer is solid — a queue you can't hear is a trap.

## Unphased infra (ride alongside / after P1–P3 — not blocking play)

- **#13 Sighted mode** — input passthrough + per-player designation in game options
  (hotseat with Julian/Dulian). Different use case than solo play.
- **#14 Key migration** — MOSTLY DONE (verified 2026-06-11/12): the hex cluster
  (bare + Shift Q/E/A/D/Z/C) + Ctrl+D vocab ride the capture-all wrap via
  `NavKeys.lua`. Remaining: the Alt+Q/A/Z/C engine letter-actions (silent
  legacy InputActions) — own + announce or eat them.
- **#15 Key audit** — classify keys, register in Help, live-test. Should produce a
  real `(key,mods)→description` REGISTRY (not loose Help-label strings) — the spine
  for **learn-key mode** (NVDA/JAWS-style: press a key to hear it, execute nothing)
  + Help (#16) + **coherent per-key announces** (capture-all lets us drop the
  diagnostic action-name crutch; one announce per key, scheduler-coalesced). Noel
  2026-06-11; memory `project_key_registry_announce_learn`.
- **#16 Two-tier help** — context-sensitive `?` + searchable F1 (the `?` cheat-sheet
  already exists; move the searchable list to F1).
- **Engine hotkeys missing from Help (Noel 2026-06-14 — DO BEFORE A BUMP).** The Help
  list is built from `HandlerStack.collectHelpEntries`, which only sees keys WE own on
  the wrap. Engine-action keys (e.g. Alt+X auto-explore — Noel went looking for it on
  his scout — and the Alt+Q/A/Z/C letter-actions) aren't listed at all. Audit every
  engine hotkey we forward/allow, and surface them in Help (add helpEntries for the
  ones we own; for pure-engine passthroughs, at minimum list them). Pairs with #15's
  registry and the "#14 remainder" (own + announce the silent Alt-letter actions).
- **#18 LOC audit** — ScannerCore category labels + backend itemNames still inline
  English; use the LOC file going forward.
- **Slim screen-reader bundling (Noel 2026-06-13)** — Prism is the path forward
  (default in 0.7.0, no adverse reports, cross-platform). Stop shipping the Tolk
  bridge DLLs we don't use. The embed glob is in `CivViAccess.csproj`
  (`..\camm\third_party\tolk\dist\x64\*.dll`), so the quick win is our-side. Three
  gates: (1) the Prism->Tolk fallback is the real tradeoff — dropping Tolk removes
  the safety net (no-speech is the worst failure); deliberate call. (2) VERIFY what
  prism.dll loads at runtime before dropping the whole glob — it likely still needs
  `nvdaControllerClient.dll` (standard NVDA API); drop `Tolk.dll` + JAWS/SAPI/Dolphin
  bridges, keep what Prism uses. (3) The clean version = CAMM backend bundling is
  adopter-selectable (declare `Backends = Prism` once, drives embed + runtime
  selection) — that's camm-side, so submodule-publish-before-tag applies. Also
  retires the macOS "Tolk replacement" blocker (`project_cross_platform`).

---

## Done (recent)

- v0.6.0 shipped + GREEN: capture-all input, the map scanner (Core/Snap/Nav/Handler
  + 5 backends), direction vocabulary (Shift+D: hex/compass/clock/degrees), the
  diplomacy rebuild (first contact navigable without Escape), Group A/B popups.
- Scanner jump announces: Home appends coords; Backspace = "Returning to" + where-am-I.

## Standing gotchas

- **Submodule-publish-before-tag:** when launcher (C#) code uses a new camm API,
  commit+push camm (its own repo) + bump the gitlink + push BEFORE tagging — else
  the Release CI compiles against the old camm and fails. `dotnet run` locally uses
  the dirty submodule and hides the problem. (Same applies to Prism once vendored.)
- **Strip debug before any public release:** `DiploDebugMeet.lua`, the Alt+M
  DiploProbe in `LeaderMeetAnnounce`, `POSTFOUND_DIAG` in `HexCursorAddin`.
