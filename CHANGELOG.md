# Changelog

Reverse-chronological. Dates are when work landed, grouped by batch rather
than per-commit.

## Versioning

Pre-release scheme: `0.1.N`, where `N` is a sequential build number that
bumps once per shipped batch. We stay on `0.1.x` until the mod has a
first-time user installer + auto-update path; the bump to `0.2.0` or
`1.0.0` is reserved for that milestone, not for any in-game feature.

The same number lives in three places and must move together:

- This file's top entry.
- `<Version>` in `CivVIAccess.Launcher/CivVIAccess.Launcher.csproj`
  (drives the .exe `FileVersion` / `ProductVersion`).
- Future installer manifest (when the helper grows update support).

The `version="1"` attribute in `CivViAccessMod.modinfo` is the
Firaxis mod-system version, not ours — leave it alone.

## 0.1.13 — 2026-05-16 — Release pipeline fix (publish output path)

Third pipeline-debugging bump. 0.1.12 fixed Azure auth and the
build + sign step actually started executing — but the signing
step couldn't find the published binary because of a path
mismatch. When dotnet publish runs inside the vcvars-loaded
dev environment that ilammy/msvc-dev-cmd@v1 provides (which we
need for the AOT linker), MSBuild picks up the Platform=x64
env var and inserts an extra `x64\` segment into the output
path: `bin\x64\Release\...` instead of `bin\Release\...`.
Local builds outside dev cmd don't have this segment, so the
hardcoded path was wrong only on CI.

Updated all `files-folder` / `copy` paths in the workflow to
include the extra `bin\x64\` segment. Workflow only runs on CI
so the divergence from local-build paths is contained.

## 0.1.12 — 2026-05-16 — Release pipeline fix (drop subscription-id from azure/login)

Second pipeline-debugging bump. 0.1.11 added `allow-no-subscriptions:
true` to the azure/login step, which handles the "no subscriptions
enumerated" case — but we were ALSO explicitly passing
`subscription-id`, which triggers a separate code path that tries
to `az account set` to the specified subscription and fails because
the App Registration has no subscription-level access. Removed the
`subscription-id` parameter entirely; the OIDC-derived access
token is used directly by the Trusted Signing call which doesn't
need subscription context.

Build pipeline reached the AOT publish step successfully under
0.1.11 (first time the build phase ran end-to-end on GitHub
runners). This bump fixes the Azure-auth step that immediately
follows.

## 0.1.11 — 2026-05-16 — Release pipeline fix (subscription-enumeration bypass)

Pipeline-debugging bump on top of 0.1.10. The 0.1.10 tag pushed
a new `release.yml` workflow that authenticated to Azure
successfully but failed at `azure/login`'s default subscription-
enumeration step, because the signing App Registration has no
subscription-level RBAC role (it only has signing scope on the
cert profile itself, which is the principle-of-least-privilege
shape). Added `allow-no-subscriptions: true` to the azure/login
step so it skips that check and just produces the access token
the signing call needs.

No source / binary changes from 0.1.10; this is the first version
that actually produces a signed binary attached to a GitHub
Release.

## 0.1.10 — 2026-05-16 — TaskDialog dialog migration, full uninstall cleanup, signed releases

### Installer / uninstaller UX

- **All choice dialogs migrated from MessageBox to TaskDialog with
  explicit verb-labelled command-link buttons.** Previous OK/Yes/No
  semantics required users to read the dialog body to figure out what
  each button did — "Yes" in the Already-Installed dialog meant
  Reinstall, which is a real UX trap. Migrated: Already-Installed
  (Reinstall / Uninstall / Change update channel / Exit), Welcome
  (Continue / Exit installer), Update Channel picker (Stable / Latest
  / Off / Keep current — single dialog replacing the sequential
  MessageBox chain), Ready-to-Install (Install / Cancel installation),
  Uninstall confirm (Uninstall / Cancel; defaulted to Cancel + warning
  icon since uninstall is destructive).
- **Ready-to-Install dialog added** between channel-picker and UAC.
  Previous flow conflated configure with commit by taking the user
  straight from channel selection into UAC with no explicit go-ahead.
  New dialog restates destination + chosen channel, asks for explicit
  Install, and confirms cancel-from-this-point with an "are-you-sure"
  step (the only place where cancel-confirm fires, since it's the
  last point before UAC).
- **Uninstall now fully removes the install directory.** Previous
  behavior left the launcher exe + Tolk DLLs orphaned in
  `Program Files\Civ VI Access` with a "delete the folder manually
  if you want a complete cleanup" note in the completion dialog. Now
  when uninstall is invoked from outside the install dir
  (downloaded-installer path), `Directory.Delete` cleans up entirely.
  When invoked from inside (Apps & Features path runs the installed
  exe directly), the non-elevated parent stages a copy of itself to
  `%TEMP%\CivViAccessUninstall\` before elevating, so the elevated
  child isn't holding the install dir open. Net: uninstall via either
  path leaves Program Files clean.

### Signing + release infrastructure

- **Azure Trusted Signing wired up via GitHub Actions.** New
  `.github/workflows/release.yml` triggers on `v*` tag pushes, builds
  the AOT publish on a GitHub-hosted Windows runner, signs the
  resulting `CivViAccess.exe` via Microsoft's Trusted Signing service,
  and publishes the signed binary as a GitHub Release asset. OIDC
  federation (no client secrets stored in GitHub); per-repo App
  Registration with federated credentials scoped to main branch + tag
  push; RBAC role `Trusted Signing Certificate Profile Signer` scoped
  to a single shared certificate profile under the "Noel Romey"
  individual publisher identity. End users will see "Verified
  Publisher: Noel Romey" in UAC instead of the previous "Unknown
  publisher" warning. This is the first release with a signed binary.
- **`app.manifest` added** declaring Common Controls v6 dependency —
  required for `TaskDialogIndirect` to resolve (without it,
  `EntryPointNotFoundException` at first call). Also declares
  PerMonitorV2 DPI awareness so dialogs render crisply on high-DPI
  displays, and supportedOS GUIDs for Windows 10/11.

## 0.1.9 — 2026-05-15 (evening) — Chameleon Installation, Update, and Launch System

Polish batch on top of 0.1.8's install validation. Internal codename
for the multi-mode launcher binary: **Chameleon Installation, Update,
and Launch System** (CIULS) — same binary picks one of several
behaviors based on where it is and what flags it was invoked with:

| Context | Behavior |
|---|---|
| `--install` from outside install dir | Welcome dialog → channel picker → UAC → install |
| `--uninstall` | Confirm dialog → UAC → remove IFEO + Apps & Features + DLC mod |
| `--version` / `--about` | Print + speak version info |
| `--config` | Open channel-picker dialog |
| `<CivVI path>` arg (IFEO redirect) | Transparent launch: spawn Civ VI via debug-bypass, attach log watcher |
| Bare exe, not installed | Auto-trigger install flow |
| Bare exe, already installed, run from outside install dir | Show Already-Installed dialog (Reinstall / Uninstall / change settings / exit) |
| Bare exe in dev tree | Dev mode: deploy local mod + launch Civ VI |

### Update channel UI surfaced in 4 discovery points

- **Welcome dialog at install** — channel picker fires right after the
  user confirms install, before UAC. They pick Stable / Latest / Off
  and the choice is saved to `launcher.ini` (no admin needed; see
  below).
- **Already Installed dialog → Change Settings** — when a user
  double-clicks a downloaded copy of the launcher post-install, the
  Cancel branch leads to a "change settings only" sub-prompt, which
  opens the channel picker without re-installing.
- **Apps & Features Modify button** — `AppsAndFeaturesRegistration`
  now sets `ModifyPath` to `<launcher> --config` (drops the old
  `NoModify=1`). Users find it in Windows Settings → Apps → Installed
  Apps → Civ VI Access → Modify. Standard Windows discovery surface.
- **`--config` flag** — opens the channel picker directly. Power-user
  path; also what Apps & Features Modify invokes.

All four converge on the same `Dialogs.ShowChannelPicker(currentChannel)`
helper. Sequential MessageBoxes (primary Yes/No/Cancel picker;
secondary Off-or-keep dialog) since MessageBox can't do 4 buttons.

### Settings location moved to %LocalAppData%

`launcher.ini` was in Program Files (admin-write only). Moved to
`%LocalAppData%\CivVIAccess\launcher.ini` so:
- Channel changes work without UAC every time
- Per-user settings (each Windows account picks their own channel)
- Co-locates with launcher.log under one `CivVIAccess\` directory

The template content + comments explain the discovery surfaces above so
power users editing the file know there's also a dialog path.

### Update artifact model simplified to single .exe

Earlier model shipped two artifacts per release:
`CivViAccess-X.Y.Z.exe` + `CivViAccessMod-X.Y.Z.zip`. Since 0.1.8 the
launcher contains the mod as embedded resources, so two artifacts was
redundant.

Now ships ONE artifact: `CivViAccess-X.Y.Z.exe`. The launcher is the
canonical source of truth for both itself and the mod files. After
self-update via the .pending swap, the new launcher writes a
`.mod-redeploy-needed` marker in `%LocalAppData%\CivVIAccess\`; on the
post-relaunch startup, Program.cs detects the marker, calls
`ModFiles.ExtractTo(DLC)`, then deletes the marker. Idempotent; if
extraction fails (e.g., game already running, files locked), retried
on next launch.

`Updater.ApplyAsync` now downloads only the launcher exe; ApplyModZipAsync
removed entirely. `ApplyPendingSelfUpdateAndRelaunchIfNeeded` writes the
marker before relaunching.

## 0.1.8 — 2026-05-15 — Launcher install + IFEO transparent launch validated end-to-end

End-to-end validation pass: Steam Play → IFEO redirect → our launcher →
CreateProcess-with-debug-bypass → Civ VI → mod loads → menu narrates.
All gotchas surfaced + fixed in a single afternoon of install testing
on a real Windows 11 machine. Significant additions and fixes on top of
the 0.1.8-equivalent scope originally drafted as "Unreleased":

### Install flow (new)

- **Welcome / Completion / Already-Installed dialogs.** Native Win32
  `MessageBox` via P/Invoke (AOT-friendly, screen-reader-accessible
  via UIAutomation by default). Initial implementation with unowned
  hWnd was invisible on Win11 — `MB_SYSTEMMODAL` + console-window
  ownership + explicit foreground-restore is the working combination.
  Welcome confirms before UAC; Completion confirms after install.
  Re-clicked installer when already installed offers Yes/No/Cancel
  → Reinstall / Uninstall / Cancel via `Dialogs.YesNoCancel`.
- **Mod files deployed during install.** The launcher's old install
  flow copied `CivViAccess.exe` to Program Files but never touched
  Civ VI's DLC dir — dev mode hid this because `dotnet run` always
  redeploys from local source. Embedded the full `CivViAccessMod/`
  source tree (~21 files, ~640 KB) as resources via the `mod/<path>`
  prefix in csproj `<EmbeddedResource>`; `ModFiles.ExtractTo` writes
  them into `DLC\CivViAccessMod\` during install. One .exe contains
  everything needed to install both launcher and mod.
- **Uninstall removes deployed mod.** `Installer.Uninstall` now also
  removes `DLC\CivViAccessMod\` so a clean install starts fresh and
  uninstall actually clears the screen-reader path end-to-end.
- **Add/Remove Programs registration.** `AppsAndFeaturesRegistration`
  writes `HKLM\...\Uninstall\CivVIAccess` with DisplayName, Publisher,
  DisplayVersion, InstallLocation, UninstallString (→ our `--uninstall`
  flag), DisplayIcon, NoModify, NoRepair. Civ VI Access now appears in
  Settings → Apps → Installed Apps and uninstalling from there fires
  our standard uninstall path.

### IFEO transparent launch (fixed)

- **Both `CivilizationVI.exe` and `CivilizationVI_DX12.exe` registered.**
  Initial cut registered only the DX11 binary, which silently bypassed
  the launcher on DX12 systems (the default for many players on modern
  GPUs). `IfeoInstaller.TargetExeNames` is now an array; Install,
  Uninstall, GetRegisteredLauncherPath, and TryGetTransparentInvocationTarget
  all iterate both binaries.
- **IFEO infinite-recursion bug discovered + fixed.** Original
  `Process.Start(civVIPath)` from inside our launcher re-triggered our
  own IFEO redirect → infinite loop of launchers spawning launchers.
  New `ProcessLauncher.LaunchBypassingIfeo` uses `CreateProcess` with
  the `DEBUG_PROCESS` flag; Windows skips IFEO substitution when the
  caller is creating the child as a debugger.
- **DEBUG_PROCESS suspended-child bug discovered + fixed.** First cut
  of the bypass left Civ VI in suspended state after `CreateProcess` —
  the child waits for `WaitForDebugEvent` + `ContinueDebugEvent` before
  it can run. Now drains initial debug events (up to 32) and calls
  `DebugSetProcessKillOnExit(false)` so Civ VI survives our detach.

### Speech UX (fixed)

- **Removed launcher chatter cascade.** Previous version fired three
  Speak calls within ~300ms (`Civ VI Access Launcher ready` →
  `Checking for updates` → `Launching Sid Meier's Civilization VI`).
  With default interrupt=true semantics, NVDA only ever vocalized the
  last one, often cut off by Civ VI's focus change. Dropped the first
  two from speech entirely; they go to the log. Update check is
  silent on no-op (the common case); only speaks when actually
  applying updates. The single audible message at launch is now
  `Launching Sid Meier's Civilization VI.`

### Diagnostic infrastructure (new)

- **`Logger` class** writes to `%LocalAppData%\CivVIAccess\launcher.log`
  with append-only per-session traces (truncate on startup, ISO-8601
  timestamps, INFO/WARN/ERROR levels). Invaluable for post-mortem
  diagnosis when launcher console output is invisible (IFEO-spawned
  Steam launches inherit Steam's stdin/stdout, which goes nowhere).
  Surfaced this batch's bugs that we wouldn't have caught from speech
  alone.
- **Tolk detection probes logged** at startup: `DetectScreenReader`,
  `HasSpeech`, `IsLoaded`, `HasBraille`. Helps confirm post-install
  that Tolk + screen reader are wired up correctly.

### Carry-over from earlier in the same batch (pre-validation work)



- **Single-file distribution.** Launcher exe renamed `CivVIAccess.Launcher.exe`
  → `CivViAccess.exe` (no dots, camelCase). Tolk DLLs moved from
  sidecar-copy-to-output to embedded resources; `TolkBootstrap` extracts
  them next to the running .exe on every start. A downloaded
  `CivViAccess-X.Y.Z.exe` can now be dropped anywhere and double-clicked.
- **Mod folder rename.** `ScreenReaderAccess/` → `CivViAccessMod/` for
  symmetry with the launcher name. Also renames the modinfo file,
  civ6proj, and civ6sln. The mod's UUID (`49224623-…`) and user-facing
  `<Name>Screen Reader Access</Name>` are unchanged so existing Civ VI
  state migrates cleanly.
- **Transparent Steam launch via IFEO.** New `IfeoInstaller` writes
  `HKLM\…\Image File Execution Options\CivilizationVI.exe\Debugger` to
  point at the installed launcher. After `--install`, every
  CivilizationVI.exe launch (Steam Play, desktop shortcut, Big Picture,
  Steam URL) routes through the launcher first. The launcher passes
  through any args Steam supplied to Civ VI.
- **Installer / uninstaller.** `--install` flag elevates via UAC, copies
  the running exe to `%ProgramFiles%\Civ VI Access\CivViAccess.exe`,
  extracts Tolk DLLs alongside, and registers the IFEO entry. Bare-exe
  no-args run on an uninstalled machine triggers the same path. Targeted
  copy (not full BaseDirectory enumeration) so running from Downloads
  doesn't sweep up unrelated files.
- **Auto-update from GitHub Releases.** `GitHubReleasesClient` polls
  `api.github.com/repos/nromey/civ-vi-access/releases`. Version compare
  via three-part `SemVer`. Per-release assets: `CivViAccess-X.Y.Z.exe`
  (launcher) and `CivViAccessMod-X.Y.Z.zip` (mod tree). Launcher self-
  update lands as `<exe>.pending` and applies via in-place swap on next
  start (`Updater.ApplyPendingSelfUpdateAndRelaunchIfNeeded`).
- **Update channels.** `launcher.ini` next to the exe with
  `UpdateChannel=stable|latest|off`. `stable` filters out GH prereleases;
  `latest` includes them; `off` skips the check entirely (off is not
  recommended but available because users are users).
- **About / version mode.** `CivViAccess.exe --version` (or `--about`)
  prints + speaks version, running path, install state, update channel,
  and project URL.
- **Speech wording.** "Launching Civilization VI" → "Launching Sid Meier's
  Civilization VI" (and matching exit phrase). Update flow adds
  "Checking for updates." / "Updating mod to X.Y.Z." / "Update to X.Y.Z
  complete." steps before the launch line. Dev-checkout mode skips the
  update check (local source is presumed ahead of any release).
- **TFM moved to `net10.0-windows`.** Honest declaration of what the
  launcher needs — Tolk, registry, AttachThreadInput, IFEO are all
  Windows-only. Drops the now-redundant Microsoft.Win32.Registry NuGet
  reference (in-framework on `-windows`).

## 0.1.7 — 2026-05-14 — De-fork, localization scaffolding, launcher window UX

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

## 0.1.6 — 2026-05-12 — Accessible Options screen

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

## 0.1.5 — 2026-05-11 — MainMenu re-announce on return; Batch 02 polish

- MainMenu re-announces the current focus when returning from a sub-screen
  (Options → back, AdvancedSetup → back, etc.) so the user lands oriented.
- Icon-tag stripping applied to button label reads (Civ VI buttons embed
  `[ICON_*]` markers that read literally as nonsense).
- Tighter back-cue wording ("Main menu" instead of the verbose original)
  pending a dedicated earcon.
- `TESTING.md` rewritten from table layout to flat numbered steps for
  screen-reader friendliness.

## 0.1.4 — 2026-05-10 — Accessible LoadGameMenu

- Up / Down / Left / Right cycles through saves with wrap-at-edges.
- Home / End jump to first / last entry.
- Empty-list state announces with explicit "Press Escape to go back."
- File-list re-query on sort / filter changes re-announces the new state.

## 0.1.3 — 2026-05-09 — Accessible main menu, Alt+F4 dialog, first-launch EULA

- Main menu kb nav: arrow keys move focus across options, Enter/Space
  activates, Escape backs out of submenus. Selection plays the existing
  `Main_Menu_Mouse_Over` cue plus a spoken label.
- Alt+F4 "Exit to Desktop?" dialog made arrow-key-navigable per the
  project popup nav standard.
- First-launch EULA screen narrates the copyright text and "Press Enter
  to accept" prompt; auto-accept path (returning users) stays silent.

## 0.1.2 — 2026-05-08 — Launcher: auto-deploy + log watcher + first-launch detection

- Launcher walks the source tree on every run and copies mod files into
  Civ VI's DLC dir before spawning the game. No more manual `cp` between
  edits.
- Background `LogFileWatcher` tails `Lua.log` and routes prefix-marked
  lines (`#SCREENREADER` / `#SCREENREADER[NOINTERRUPT]`) to Tolk.
- First-launch detection via `UserOptions.txt` `CopyrightAccept` key;
  tailors the pre-game announcement to first-time vs. returning users.

## 0.1.1 — 2026-05-07 — Tolk integration, .NET 10 launcher

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
