# Report Bridge (browser-rendered)

Foundational plumbing for rich, screen-reader-navigable readouts
(end-of-turn summary, empire status, civilopedia, pickers-as-reports).
The mod streams HTML to the launcher, which writes it to a file and opens
it in an isolated Microsoft Edge app-mode (`--app`) window; the screen
reader navigates it in browse mode (headings / lists / tables / links —
all for free, no custom reader to build).

Established 2026-06-01. Status: **pipe proven end-to-end live 2026-06-02**
(mod emit → log-tail → ReportBridge accumulate → render). The original
in-process WebView2 control was swapped for the Edge `--app` window on
2026-06-02 because WebView2 cannot activate under Native AOT (see "Why
this shape" below). See `project_pickers_and_reader_plan` for where this
sits in the roadmap (it's the bridge that items 3–8 stack on).

## Why this shape

Two hard constraints decided the architecture:

1. **Civ VI's Lua sandbox can't write files** (no `io`). So the mod can't
   "write HTML to disk and tell the launcher to open it." Report content
   must travel over the channel we already have — `print()` into Lua.log,
   tailed by the launcher.
2. **WebView2 cannot activate under Native AOT** — so the launcher (which
   ships AOT: see `project_launcher_publish_mode`) renders via the user's
   browser instead of an embedded control. WebView2's RCW-based COM
   activation needs built-in COM interop, which AOT disables;
   `CoreWebView2Environment.CreateAsync` throws `NotSupportedException`
   ("Built-in COM has been disabled via a feature switch") at **runtime**,
   even though ILC compiles the assembly cleanly. (The original plan
   conflated compile-time with runtime; confirmed live 2026-06-02 — the
   form opened blank, the launcher logged the exact COM exception. Known,
   unresolved WebView2+NativeAOT gap: WebView2Feedback #4783 / #4800.)
   Rather than drop AOT or add a non-AOT helper exe, the launcher writes
   the page to a file and opens it in **Microsoft Edge app mode**
   (`msedge --app=file://…`). Edge is present by default on Win10
   20H2+/Win11 (it *is* the WebView2 runtime) and gives a clean borderless
   single window instead of a tab in the user's everyday browser.

So: content rides the log; the **launcher** materializes the HTML and the
**browser** renders it.

## Data flow

```
Lua: Report.show(title, body)
   -> print("#SHOWREPORT[begin] - <title>")
      print("#SHOWREPORT[chunk] - <html fragment>")  (1..N)
      print("#SHOWREPORT[end]")
        |
        v   (engine prefixes each line "Context: ", written to Lua.log)
Launcher LogTailSpeaker -> Mediator.Output(chunk)
   -> AccessibleOutputHandler (speech; ignores #SHOWREPORT, no marker)
   -> LogLineObserver  ==  ReportBridge.OnLogLine     <-- the new seam
        accumulates begin/chunk/end, wraps body in an accessible HTML
        shell, calls ReportWindow.Instance.Show(html, title)
        |
        v
ReportWindow -> writes %LocalAppData%\CivVIAccess\report.html
   -> kills the prior report window, then
      msedge --app=file://…\report.html --user-data-dir=…\ReportBrowser
   -> NVDA browse mode reads it
```

## Wire protocol

Each marker is one `print()` = one log line. The launcher matches the
marker anywhere in the line (past the engine's `Context: ` prefix).

| Line | Meaning |
| --- | --- |
| `#SHOWREPORT[begin] - <title>` | Start a report; the body of this line is the plain-text title. |
| `#SHOWREPORT[chunk] - <fragment>` | One HTML **body** fragment. Concatenated **verbatim** (no separator) so a caller can pass a table of lines, and oversized fragments split seamlessly. |
| `#SHOWREPORT[end]` | Render the accumulated body and surface the window. |

- The mod sends HTML **body content only**. The page shell (semantic
  structure, readable typography, light/dark via `prefers-color-scheme`,
  a top-level `<h1>` from the title) is applied launcher-side in
  `ReportBridge.BuildPage` so every report is consistent and the mod
  stays simple.
- `%` is escaped (`%%`) in the Lua emitter so Civ VI's printf-style
  `print()` doesn't eat it; the logged text comes out clean.

## Components

- **Mod**
  - `Assets/UI/Accessibility/Report.lua` — `Report.show(title, body)`
    emitter (+ `Report.showTest()` sample). `include("Report")`.
  - `RemapForHexCursor.xml` — `CIVVIACCESS_ShowReportTest` action on
    **Alt+K** (temporary smoke-test trigger).
  - `HexCursorAddin.lua` — includes Report, binds Alt+K to
    `Report.showTest()`.
- **CAMM** (`camm/Camm/`) — generic, report-agnostic line tap:
  - `CammModManifest.LogLineObserver` (`Action<string>?`).
  - `Mediator` fans `Output` to the observer (exceptions swallowed +
    logged so speech is never affected).
  - `CammHost` passes `manifest.LogLineObserver` into the `Mediator`.
- **CivViAccess** (`CivViAccess/Report/`) — all report-rendering code:
  - `ReportBridge.cs` — marker accumulation + HTML shell. Registered as
    `LogLineObserver` in `Program.cs`.
  - `ReportWindow.cs` — writes the page to `report.html` and opens it in
    an isolated Edge `--app` window. `Show()` is thread-safe (called from
    the log-tail thread, returns promptly). Single window: every report
    overwrites the same file and the prior window is killed before the new
    one opens, so no per-turn window pileup. A dedicated `--user-data-dir`
    isolates the window into its own Edge process (so the handle is ours
    to kill). Falls back to the OS default browser if Edge isn't found.
    No WinForms/WebView2/COM — keeps the launcher AOT-clean.

## How to test live

1. Rebuild the launcher (`dotnet build CivViAccess` or a publish), then
   run `CivViAccess.exe`. Dev-mode deploy copies the updated mod source
   (incl. `Report.lua`, `.modinfo`, `RemapForHexCursor.xml`) into the DLC
   dir, then launches Civ VI.
2. Start/load a game, get to the world view, press **Alt+K**.
3. Expect: "Opening test report" speech, then an Edge app window titled
   "Report bridge test" containing headings, a list, a table, and a link.
   NVDA should navigate it with H (headings), K (links), T (tables).
   Alt+Tab back to Civ (or close the window) to return to the game.
4. If nothing fires on Alt+K, slurp/burp test the binding (custom
   `CIVVIACCESS_` actions occasionally need confirmation the engine sees
   the gesture). The `Report.show` call also logs to Lua.log, and
   `ReportBridge` logs "rendered report ..." to launcher.log — check both
   to localize where the pipe breaks.

## First real consumer: Empire status report (bare U)

`EmpireStatus.lua` → `EmpireStatus.show()` builds a live report from game
state and sends it through the bridge. Press **U** in the world view.
Expect a window titled "Empire Status — Turn N" with: a **Needs
attention** checklist (only when something's pending — empty production,
no research/civic, idle units), **Yields per turn**, **Research and
civic** with turns-left, a **Cities** table (pop / producing+turns /
grows-in), **Units** counts by state + the units needing orders, and
**City-states** met / suzerain-of. Every section is pcall-guarded, so if
one engine call is off it shows "(section) unavailable" instead of
failing the whole report — note which section(s) say that so we can fix
the specific API. This is the "what needs attention before I end the
turn" reader.

## Second real consumer: End-of-turn report (bare N)

`EotReport.lua` is the *delta* sibling to the empire snapshot — "what
happened last turn." It speaks "End of turn report ready. Press N any turn
to read it." **once** (the first turn a report exists), then stays silent —
no per-turn nag (Noel 2026-06-02); press **N** any turn to open it.
Content: techs /
civics completed, **eurekas / inspirations triggered** (the Civ V Access
analogue never had this), production completed + cities founded, treasury
change + income, population / unit deltas, and current research / civic
ETA. The first turn after starting/loading only primes the baseline
(nothing to compare yet), so the report appears from turn 2 on.

How it's computed (all VM-safe): a **snapshot diff** at each
`LocalPlayerTurnBegin` for completions / boosts / gold / pop / units
(set-diff of `HasTech`/`HasCivic`/`HasBoostBeenTriggered`, `GetGoldBalance`,
etc.), plus **engine-event accumulation** (`Events.CityProductionCompleted`
/ `CityAddedToMap`, which fire in every VM) for production and founded
cities. No cross-VM `LuaEvents`.

### Why three rendering paths (the triangulation)

Alt+K (synthetic), U (empire snapshot), and N (turn delta) all flow
through the **same** `ReportBridge` → HTML shell → `ReportWindow`. If the
window/shell misbehaves, comparing the three localizes the fault: broken
on all three → shell or WebView host (`ReportBridge.BuildPage` /
`ReportWindow`); broken only on U or N → that report's content builder.
A fix in the shared shell propagates to both real reports at once.

### These are Civ VII primitives

`Report.lua` (mod side) and the CAMM `LogLineObserver` + `ReportBridge` +
`ReportWindow` (launcher side) are deliberately engine-agnostic: the mod
emits `#SHOWREPORT` text, the launcher renders HTML. Nothing in the bridge
itself knows about Civ VI. Per `project_cross_game_foundation`, this whole
stack should port to Civ VII (and the report *content* builders —
EmpireStatus / EotReport — rewrite against VII's gameplay API while the
bridge stays put). Civilopedia is the next consumer on the todo, and it's
the one that motivates HTML over plain speech (hyperlinked pedia entries).

## Leader meetings — what they say (needs live path validation)

`LeaderMeetAnnounce.lua` v2 adds the leader's spoken greeting on top of
the v1 who+mood announce. The text lives in `DiplomacyActionView`'s
control tree (`LeaderResponseText` / `VoiceoverText`), set via
`ApplyStatement`; we read it cross-context with
`ContextPtr:LookUpControl("/InGame/DiplomacyActionView/<ctrl>")` and also
listen to `Events.DiplomacyStatement` as a deferred catch. **It logs which
candidate control path produced text** — when you meet a leader, check
Lua.log for `LeaderMeetAnnounce: greeting (via <path>)`. If a path works,
tell me which and I'll lock it in (trim the candidate list). If none read
text, the v1 "<Leader> of <Civ> <expression>. Press Escape" still speaks —
the greeting is just silently absent until we find the right path.

## Open follow-ups (not blockers for the smoke test)

- **CAMM submodule commit.** The `camm/Camm/` edits (Mediator, manifest,
  CammHost — the generic `LogLineObserver` seam, unaffected by the
  WebView2→Edge swap) compile via ProjectReference but live in the
  submodule's working tree — commit them in the camm repo + bump the
  submodule pointer before a clean release.
- **Single-window robustness.** We kill the prior Edge `--app` process
  before launching the next so only one report window exists. If Edge's
  per-profile singleton lock ever lingers past the kill and the next
  launch no-ops, switch to navigating the existing window instead of
  kill-and-respawn. Watch live across many U/N presses.
- **Foreground/focus.** A cross-process window launched from the launcher
  may land behind fullscreen Civ. `--app` + a fresh `--user-data-dir`
  generally foregrounds; verify against fullscreen vs windowed Civ and,
  if it flashes in the taskbar instead, consider forcing the game to
  windowed/borderless or an explicit foreground nudge.
- **Real report hotkey.** Alt+K is a throwaway trigger. The actual
  report-open key(s) (EOT / empire status) are Noel's call now that the
  pipe is proven; the bridge itself is content-agnostic.
- **Edge absence fallback.** If `msedge.exe` isn't found, ReportWindow
  shell-opens the file in the default browser (a normal tab, no
  single-window management). Edge is effectively always present on
  Win10 20H2+/Win11, so this is a long-tail path.
- **Report depth + expandables (future — Noel 2026-06-02).** EOT/empire
  reads are deliberately thin now (early game has little to report), but
  there's far more to surface mid/late game, especially with expansions:
  era score + Golden/Dark Age + dedication progress, per-city
  loyalty/revolt risk, governors and available titles (R&F); diplomatic
  favor, grievances, World Congress, climate/disasters/power and resource
  consumption (GS); plus cross-cutting great-people points, religion
  spread, trade routes, envoy/suzerainty changes, amenities/war-weariness,
  resource stockpiles, units that leveled or fought. Mechanism: HTML
  `<details>`/`<summary>` disclosures (native browse-mode widgets — NVDA
  toggles on Enter), so each section is a one-line headline that drills in
  on demand — the same progressive-disclosure idea as the Ctrl+T/Ctrl+I
  layered hotkeys. Architecture: turn `renderDelta`'s hardcoded sequence
  into a *section registry* — each section a self-contained, pcall-guarded
  builder returning summary + `<details>` body, auto-skipped when its
  expansion API is absent (so a GS-only section no-ops in vanilla without
  touching the others). The existing per-section pcall guarding is the
  foundation. Revisit when a real playthrough makes the thinness bite.
