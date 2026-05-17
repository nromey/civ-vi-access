# CAMM Extraction Plan — Chameleon Access Mod Manager

Captured 2026-05-17. Drives a future implementation session.
Self-contained: a reader who hasn't been in the originating conversation
can execute this plan from the doc alone.

## Why this extraction

The launcher at `CivViAccess/` started as Civ-VI-specific scaffolding and
grew into a general-purpose accessibility-mod installer / updater /
transparent launcher. About 80% of the code is genuinely game-agnostic:
Tolk bootstrap, IFEO redirect, Apps & Features registration, update
channel selection, GitHub Releases polling, AOT-clean TaskDialog wrappers,
self-update via .pending swap. Re-implementing all of that for the next
adopter (Factorio Access UI gaps, RimWorld Access, ONI Accessibility,
Civ V Access second iteration) would be wasted work.

CAMM (Chameleon Access Mod Manager) is the extracted reusable form.
Naming and architecture decisions follow `project_camm_architecture_v0.md`:
single-mod-per-build template, build-time bundling, programmer-ish author
audience, mandatory "powered by CAMM" footer, Tolk bundled by default.

The extraction also lands launcher-side localization as the very first
piece of new work — per `project_launcher_localization_gap.md`, retrofitting
it into the current launcher then doing it again in CAMM wastes the effort.

This plan covers what stays in Civ VI Access vs what becomes CAMM, the
shape of the public surface, repo strategy, customization points,
localization architecture, the staged migration path, and open questions.

The wizard rewrite (`WIZARD_PLAN.md`) is in flight in a parallel work
stream. This plan assumes the wizard exists and folds it into CAMM as
the canonical install UX. If the wizard ships before extraction starts,
nothing changes here. If extraction starts first, the wizard work pauses
until the CAMM `Wizard/` folder exists as the home for those new files.

## Design decisions (locked)

1. **Distribution: template repo plus referenced project, not NuGet.**
   The CAMM repo is a standalone .NET project the consuming repo
   includes as a git submodule and references via
   `<ProjectReference>`. NuGet is the obvious mainstream answer but
   adds package-publish overhead, requires .nupkg signing, and forces
   semantic-versioning discipline across all internal API changes —
   all of which is wasted ceremony for a single maintainer with two
   adopters. Submodule + ProjectReference gives version pinning
   (submodule SHA), in-place debugging (step into CAMM source from
   Visual Studio), and zero release overhead. Switch to NuGet later
   if/when external adopters can't live with submodule mechanics.

2. **Config: C# class compiled into the consuming exe, not JSON.**
   Mod identity (game name, install dir, Steam App ID, IFEO targets,
   etc.) lives in a `CammModManifest` static class the consuming
   project defines and CAMM consumes via its constructor /
   `Initialize` entry point. C# beats JSON here because: AOT-clean
   without source-gen contortions, compiler-checked (typo a property
   name and the build fails, not the install), and the file lives
   inside the consuming project's source tree so it can reference
   constants from elsewhere in that project. JSON only wins when
   non-programmers edit it; CAMM's audience is programmers.

3. **Single .exe per mod, no runtime mod-host.** Same as today's Civ
   VI Access shape. Each accessibility mod gets its own CAMM-built
   exe (RimWorldAccess.exe, FactorioAccess.exe, CivViAccess.exe).
   No central mod manager process, no plugin loading. Confirms
   `project_camm_architecture_v0.md`.

4. **Tolk bundled by default, opt-out via manifest.** Per
   `project_camm_architecture_v0.md`. The `CammModManifest` exposes a
   `UseTolk = true` default; setting it false disables Tolk bootstrap,
   omits the embedded Tolk DLLs from the build, and routes
   accessibility output through a manifest-supplied `IAccessibleSpeech`
   implementation instead. Out of scope for v0 — every initial adopter
   uses Tolk — but the abstraction seam exists from day one so the
   eventual macOS port and any alternate-speech-bridge users (rare)
   aren't a rewrite.

5. **Powered-by-CAMM footer is mandatory and enforced at link time.**
   `CammHost` exposes the wizard's footer text as a non-overridable
   constant the wizard form reads at runtime. Per
   `project_camm_architecture_v0.md`: "always add at the bottom of
   the window, powered by the Chameleon Access Mod Manager by Noel
   Romey." Not configurable, not localizable in v0 (the phrase is a
   credit/lineage marker; translating it dilutes the credit).

6. **Localization lands in the extraction, not before.** Per
   `project_launcher_localization_gap.md`. CAMM strings live in
   `lang/<culture>.json` next to the exe; loaded via
   `CultureInfo.CurrentUICulture` with `en` fallback. Source-generated
   `JsonSerializerContext` keeps it AOT-clean. The wizard ships English-
   only in the current rewrite; extraction is when the JSON loader
   appears.

7. **Versioning: independent SemVer for CAMM, lockstep tag versions
   for consuming mods.** CAMM uses 0.x.y while pre-1.0 same as Civ VI
   Access. Consuming mods continue their own version scheme; the
   CAMM version they're built against is captured in the submodule
   SHA. No backwards-compatibility promises until CAMM hits 1.0.

## What stays in Civ VI Access vs what becomes CAMM

File-by-file walkthrough of `CivViAccess/*.cs`. Classifications:

- **TEMPLATE** — moves to CAMM as-is or with minor abstraction.
- **GLUE** — stays in Civ VI Access; the small Civ-specific layer
  over the template.
- **HYBRID** — needs refactor; split into a template piece (in CAMM)
  and a glue piece (in CivViAccess).

`Program.cs` — HYBRID. The mode-routing skeleton (apply pending
self-update → bootstrap Tolk → branch on `--install` / `--uninstall` /
`--config` / `--version` / transparent invocation / bare-exe) is the
Chameleon pattern itself and belongs in CAMM as a `CammHost.Run(args,
manifest)` entry. The Civ-VI-specific bits — `civVIPath` hardcoded
constant, `Lua.log` path, `UserOptions.txt` EULA-detection, EULA
first-launch speech variant, `CivilizationVI` / `CivilizationVI_DX12`
process name list, lifecycle-watch loop — stay in `CivViAccess/Program.cs`
as a thin shim that builds a `CammModManifest`, hands it to `CammHost.Run`,
and provides Civ-VI-specific hooks via virtual methods or delegates on
the manifest. Estimated 80 LOC remaining in `CivViAccess/Program.cs`
after extraction, down from 607.

`Installer.cs` — HYBRID. Install/uninstall orchestration (welcome →
channel pick → ready → UAC relaunch → file copy → Tolk extract → IFEO
register → mod extract → A&F register → completion dialog, plus the
mirror image for uninstall) is template work. The
`Civilization VI Access` install dir name, hardcoded launcher exe name
`CivViAccess.exe`, A&F display name, the verbose body text describing
"Civ VI's DLC directory" and "Steam-launch redirect" are Civ-specific
strings. After extraction: `CivViAccess/Installer.cs` no longer exists;
its work happens in `Camm.Install/InstallOrchestrator.cs` and
`InstallOrchestrator` reads strings from the manifest plus the
locale-loader. Civ VI Access carries no installer code.

`Dialogs.cs` — TEMPLATE. The TaskDialog and MessageBox P/Invokes, the
`ShowChoice` / `ShowInfo` / `ShowError` / `ShowChannelPicker` helpers,
the AOT-clean pointer arithmetic for the TASKDIALOG_BUTTON array, the
console-as-owner-HWND workaround for Win11 — all generic. Move whole-
file to `Camm.UI/Dialogs.cs`. `ShowChannelPicker` becomes a stock
helper inside CAMM since UpdateChannel is a CAMM concept (see
`LauncherSettings` below). Civ VI Access loses this file entirely.

`IfeoInstaller.cs` — HYBRID. The IFEO mechanism (HKLM key path, quoted
Debugger value, register/unregister/detect-transparent-invocation
loop, IsRunningElevated check) is template. The `TargetExeNames` array
(`CivilizationVI.exe`, `CivilizationVI_DX12.exe`) is Civ-specific —
RimWorld would set `["RimWorldWin64.exe"]`, Factorio
`["factorio.exe"]`, ONI `["OxygenNotIncluded.exe"]`. Manifest exposes
`IfeoTargetExeNames` as a `string[]`. After extraction the file is
`Camm.Install/IfeoInstaller.cs`, taking the target names as a
constructor parameter or reading them from a `CammModManifest` injected
at host setup.

`AppsAndFeaturesRegistration.cs` — HYBRID. The registry key path,
value names, EstimatedSize computation, ModifyPath / UninstallString
encoding are template. Display strings (`DisplayName = "Civ VI Access"`,
`Publisher = "Noel Romey"`, `URLInfoAbout = ".../civ-vi-access"`) come
from the manifest. UninstallKeyName needs to be unique per mod; expose
as `CammModManifest.AppsAndFeaturesKeyName`.

`Updater.cs` — TEMPLATE. The .pending swap, the
`ApplyPendingSelfUpdateAndRelaunchIfNeeded` logic, the
`RedeployMarkerPath` pattern, the launcher-asset download → stage →
swap flow — completely game-agnostic. Two strings need parameterization:
the `CivViAccess` LocalAppData folder name (becomes
`manifest.LocalAppDataFolderName`) and the launcher-asset filename
pattern `CivViAccess-{version}.exe` (becomes
`manifest.LauncherAssetNamePattern`, e.g. `"FactorioAccess-{0}.exe"`).
Move to `Camm.Update/Updater.cs`.

`GitHubReleasesClient.cs` — HYBRID. The HTTP client wrapper, JSON
source-generator setup, channel-aware best-release-finder logic are
template. Owner and Repo constants are mod-specific
(`nromey/civ-vi-access`). After extraction the constants become
manifest fields; the JsonSerializerContext stays in CAMM since the
DTOs are GitHub's, not the mod's. Move to `Camm.Update/`.

`SemVer.cs` — TEMPLATE. Three-part SemVer parser, AOT-clean, used
across update flow + about-print. Move to `Camm.Versioning/SemVer.cs`.
`SemVer.Current()` already reads the calling assembly's version via
`typeof(SemVer).Assembly` — after extraction it'll read CAMM's own
version, which is wrong. Fix: pass the consuming assembly to
`SemVer.Current(Assembly?)` or have `CammHost` cache the entry
assembly's SemVer and expose it as `CammHost.ModVersion`.

`TolkBootstrap.cs` — TEMPLATE. Embedded-resource extraction, temp-
dir-vs-install-dir dispatch, SetDllDirectory dance. The `tolk/` resource
prefix is a CAMM-internal convention (the consuming csproj embeds Tolk
DLLs with this LogicalName because CAMM's csproj template says to).
Move to `Camm.Tolk/TolkBootstrap.cs`. No parameterization needed.

`AccessibleOutputHandler.cs` — HYBRID. The Tolk-call wrapper +
interrupt-management logic is template. The `#SCREENREADER` marker
prefix and the icon/color/newline sanitization regex table are
Civ-VI-specific (those are Civ VI's TXT_KEY-style markup tags, not a
universal convention — RimWorld's mod-side speech text won't have
`[ICON_FOOD]` in it, it'll have RimWorld's own markup). After
extraction:
- `Camm.Speech/AccessibleOutputHandler.cs` — handles Tolk loading,
  the SAPI-on toggle, interrupt timing, and accepts a
  `IMessageSanitizer` from the manifest.
- `CivViAccess/Speech/CivViMessageSanitizer.cs` — implements
  `IMessageSanitizer` with the existing regex table.

`AccessibleOutputOptionReader.cs` — HYBRID. The `#SCREENREADER[…]`
options parser is a Civ-VI mod-side convention. Each adopter will
define their own marker prefix and option grammar. After extraction:
this becomes a `IScreenReaderMarkerProtocol` interface in CAMM
(`Camm.Speech/IScreenReaderMarkerProtocol.cs`) with the Civ V
implementation in `CivViAccess/Speech/CivViScreenReaderMarkerProtocol.cs`.

`Mediator.cs` — GLUE. Trivial three-line wrapper around
AccessibleOutputHandler + TextOutputHandler. Keep in CivViAccess; or
inline at the call site and delete. Not worth abstracting.

`TextOutputHandler.cs` — GLUE. Two-method `Console.WriteLine` wrapper.
Keep in CivViAccess. Delete if you inline `Mediator`.

`LogFileWatcher.cs` — GLUE. Reads the `Lua.log` tail and forwards
lines through `Mediator` → `AccessibleOutputHandler`. Civ-VI-specific
(Lua.log is a Firaxis-engine artifact). RimWorld has its own log
location, Factorio has factorio-current.log, ONI has Player.log.
**However** the *pattern* — tail a log file from a captured offset,
forward to speech — is universal. Refactor to extract a
`Camm.Speech/LogTailSpeaker.cs` base that takes a file path + a
post-launch offset + an `IScreenReaderMarkerProtocol` and does the
poll-read-forward loop. The Civ-specific log file path resolution
stays in CivViAccess.

`WindowFocusManager.cs` — HYBRID. The follow-focus + force-foreground
behavior is universal launcher concern (every adopter spawns the game
and wants foreground handed over reliably). The `CivilizationVI` /
`CivilizationVI_DX12` process-name list is game-specific. Move to
`Camm.WindowManagement/WindowFocusManager.cs`, take the game process-
name list from the manifest.

`ProcessLauncher.cs` — TEMPLATE. The DEBUG_PROCESS IFEO-bypass spawn
is the standard pattern for any IFEO-using launcher (Civ V Access uses
the equivalent of this). No game-specific code. Move to
`Camm.Launch/ProcessLauncher.cs`.

`Logger.cs` — TEMPLATE. File-based launcher logger to
`%LocalAppData%\<modfolder>\launcher.log`. The `CivVIAccess` folder
name is the only mod-specific bit; comes from
`manifest.LocalAppDataFolderName`. Move to `Camm.Diagnostics/Logger.cs`.

`LauncherSettings.cs` — TEMPLATE. The ini-style key=value parser, the
`%LocalAppData%\<modfolder>\launcher.ini` location, the
self-documenting commented template, and the `UpdateChannel` enum
(`Stable` / `Latest` / `Off`) — all template. Move to
`Camm.Settings/LauncherSettings.cs`. Consuming mods that want to
extend launcher.ini with their own keys can either subclass
`LauncherSettings` and add properties (parsed via overridable
`ApplyKey(string, string)`) or ship a second ini in the same dir.

`ModDeployer.cs` — HYBRID. The find-mod-source-in-parent-dirs walk and
the `Deploy(source, dest)` copy-tree are template. The
`DefaultDestination` constant pointing into Civ VI's DLC dir, the
`CivViAccessMod` folder name + `.modinfo` sentinel are Civ-specific.
After extraction: `Camm.ModPayload/ModDeployer.cs` is generic; the
manifest exposes:
- `ModPayloadFolderName` (e.g. `"CivViAccessMod"`)
- `ModPayloadSentinelFileName` (e.g. `"CivViAccessMod.modinfo"`)
- `ModPayloadDeployDestination` (computed from the per-game user-files
  convention — see "Per-game customization points" below)

`ModFiles.cs` — TEMPLATE. Embedded-resource extraction of mod payload
into a target dir. The `mod/` resource prefix is a CAMM internal
convention. Move to `Camm.ModPayload/ModFiles.cs`.

`Wizard/*.cs` (in-flight from `WIZARD_PLAN.md`) — TEMPLATE. The
`InstallWizardForm`, `IWizardPage`, `InstallContext`, and the five
page UserControls — all generic. The only mod-specific bits are the
display strings on each page, which come from the locale JSON. Move
to `Camm.UI/Wizard/`. The mandatory "powered by CAMM" footer label is
constructed in `InstallWizardForm` and not overridable.

After extraction the consuming `CivViAccess/` directory holds, at
most: `Program.cs` (thin shim), `Speech/CivViMessageSanitizer.cs`,
`Speech/CivViScreenReaderMarkerProtocol.cs`,
`Speech/CivViLogTailSpeaker.cs` (subclass of `LogTailSpeaker` with
the Lua.log path resolution), `Civ/CivVIPathFinder.cs` (Steam +
EULA-detection logic), and a `CammModManifest.cs` that wires the
configuration. Expect ~250-350 LOC of Civ-VI-specific glue against
~2000-2500 LOC moved to CAMM. The ratio justifies the extraction.

## CAMM's public surface

What does a downstream mod author write? Three artifacts: a manifest
class, a Program.cs entry point, and a mod-payload directory.

### The CammModManifest

A static class in the consuming project that CAMM reads at startup.
Concrete shape:

```csharp
namespace FactorioAccess;
using Camm;

public static class FactorioAccessManifest
{
    public static CammModManifest Build() => new()
    {
        // Identity
        ModDisplayName = "Factorio Access",
        ModInternalName = "FactorioAccess",          // ASCII, no spaces
        Publisher = "Crowsfeather, et al.",
        ProjectUrl = "https://github.com/Crowsfeather/factorio-access",
        LocalAppDataFolderName = "FactorioAccess",   // %LocalAppData%\FactorioAccess\

        // Install
        InstallDirName = "Factorio Access",          // Program Files\Factorio Access\
        LauncherExeName = "FactorioAccess.exe",
        AppsAndFeaturesKeyName = "FactorioAccess",
        LauncherAssetNamePattern = "FactorioAccess-{0}.exe",  // {0} = version

        // Target game
        TargetGameDisplayName = "Factorio",
        IfeoTargetExeNames = new[] { "factorio.exe" },
        GameProcessNames = new[] { "factorio" },
        GameInstallPathFinder = FactorioInstallPaths.Find,    // delegate
        ModPayloadFolderName = "FactorioAccessMod",
        ModPayloadSentinelFileName = "info.json",
        ModPayloadDeployDestination = FactorioInstallPaths.ModDir,

        // Updates
        GitHubReleasesOwner = "Crowsfeather",
        GitHubReleasesRepo = "factorio-access",

        // Speech
        UseTolk = true,
        Sanitizer = new FactorioMessageSanitizer(),
        MarkerProtocol = new FactorioScreenReaderMarkerProtocol(),
        LogTailSpeaker = new FactorioLogTailSpeaker(),

        // Optional
        DefaultLocale = "en",
    };
}
```

The author's `Program.cs` becomes a one-liner:

```csharp
return await Camm.CammHost.RunAsync(args, FactorioAccessManifest.Build());
```

`CammHost.RunAsync` does everything in today's Program.cs main flow —
apply pending self-update, bootstrap Tolk, route on args, install /
uninstall / config / transparent-invocation / dev-mode behaviors,
spawn game, attach log tail, wait for game exit.

### The mod-payload directory

A sibling directory of the consuming project's launcher csproj, named
per `ModPayloadFolderName` in the manifest. CAMM's csproj template
embeds everything in that directory as `mod/...` resources at build
time. Same shape as today's `..\CivViAccessMod\**\*.*` glob in
`CivViAccess.csproj`. Authors who don't have a mod payload (pure
launcher, no in-game mod files) can leave the directory absent —
CAMM's installer skips the mod-extract step when no `mod/*` resources
exist.

### The build command

CAMM ships a `build.ps1` script the author runs at the consuming
repo's root:

```powershell
.\camm\build.ps1 -Version 0.2.0
```

The script wraps `dotnet publish -c Release -r win-x64 -p:Version=0.2.0`
and stages the signed output as `<ModInternalName>-<Version>.exe`. CI
authors use the released `.github/workflows/camm-release.yml` template
(copied into their repo's `.github/workflows/release.yml`) which does
the same thing inside the Azure Trusted Signing OIDC flow. Authors
without Trusted Signing can sign with their own cert or skip signing
(unsigned binaries still install, but SmartScreen will complain).

### Hypothetical RimWorld Access manifest

```csharp
public static class RimWorldAccessManifest
{
    public static CammModManifest Build() => new()
    {
        ModDisplayName = "RimWorld Access",
        ModInternalName = "RimWorldAccess",
        Publisher = "<rimworld_access maintainers>",
        ProjectUrl = "https://github.com/<owner>/rimworld_access",
        LocalAppDataFolderName = "RimWorldAccess",

        InstallDirName = "RimWorld Access",
        LauncherExeName = "RimWorldAccess.exe",
        AppsAndFeaturesKeyName = "RimWorldAccess",
        LauncherAssetNamePattern = "RimWorldAccess-{0}.exe",

        TargetGameDisplayName = "RimWorld",
        IfeoTargetExeNames = new[] { "RimWorldWin64.exe" },
        GameProcessNames = new[] { "RimWorldWin64" },
        GameInstallPathFinder = RimWorldInstallPaths.Find,
        ModPayloadFolderName = "RimWorldAccessMod",
        // RimWorld looks for mods in
        //   %USERPROFILE%\AppData\LocalLow\Ludeon Studios\RimWorld by Ludeon Studios\Mods
        // (the Mods\ subdir under the game's user-data path)
        ModPayloadDeployDestination = RimWorldInstallPaths.ModDir,
        ModPayloadSentinelFileName = "About/About.xml",

        GitHubReleasesOwner = "<owner>",
        GitHubReleasesRepo = "rimworld_access",

        UseTolk = true,
        Sanitizer = new RimWorldMessageSanitizer(),
        MarkerProtocol = new RimWorldScreenReaderMarkerProtocol(),
        LogTailSpeaker = new RimWorldLogTailSpeaker(),  // reads Player.log
    };
}
```

The shape is identical; the per-game fields differ. That's the value
proposition.

## Repository and distribution strategy

The CAMM repo lives at `github.com/nromey/camm`. Layout:

```
/Camm/                    — the reusable library project
  Camm.csproj
  CammHost.cs             — public entry point
  CammModManifest.cs      — public config struct
  Install/                — Installer.cs, IfeoInstaller.cs, AppsAndFeaturesRegistration.cs
  Update/                 — Updater.cs, GitHubReleasesClient.cs
  UI/                     — Dialogs.cs, Wizard/
  Tolk/                   — TolkBootstrap.cs
  Speech/                 — AccessibleOutputHandler.cs, LogTailSpeaker.cs, IMessageSanitizer.cs, IScreenReaderMarkerProtocol.cs
  WindowManagement/       — WindowFocusManager.cs
  Launch/                 — ProcessLauncher.cs
  Settings/               — LauncherSettings.cs, UpdateChannel.cs
  ModPayload/             — ModDeployer.cs, ModFiles.cs
  Diagnostics/            — Logger.cs, SemVer.cs
  Localization/           — LocaleCatalog.cs, Strings.cs (loads lang/*.json)
  lang/
    en.json               — English strings (shipped)
    de.json, fr.json, …   — additional locales as contributed
/template/                — files copied into a new consuming repo
  CammMod.csproj.template
  app.manifest            — Common Controls v6 declaration
  Program.cs.template     — minimal `return CammHost.RunAsync(args, ...)` skeleton
  CammModManifest.cs.template
  build.ps1
  .github/workflows/release.yml.template
  .camm-mod.json.template  — registry marker file
/third_party/tolk/        — same vendored Tolk source the current launcher uses
/docs/
  getting-started.md
  customization.md
  per-game-conventions.md  — list of known game install/mod-dir conventions
README.md
LICENSE                   — MIT, matches Civ VI Access
CHANGELOG.md
```

Consuming repos pull CAMM via git submodule:

```
git submodule add https://github.com/nromey/camm.git camm
```

The consuming csproj does `<ProjectReference Include="..\camm\Camm\Camm.csproj" />`
and is done. To upgrade CAMM, the consuming repo updates the submodule SHA
and rebuilds. No NuGet, no version-matrix puzzles, no signing of intermediate
artifacts. Authors who hate submodules can subtree-pull instead — both work
the same way at the .csproj level.

Release cadence for CAMM: tagged whenever a downstream adopter needs a
feature or fix, no fixed cadence. Pre-1.0 means any release can break
API — consumers pin to a SHA and upgrade when ready. Tags follow
`v0.X.Y` per the existing Civ VI Access scheme.

## What template files ship

The `/template/` directory in the CAMM repo contains:

- `CammMod.csproj.template` — the consuming project's csproj, with
  `<UseWindowsForms>true</UseWindowsForms>`, `<PublishAot>true</PublishAot>`,
  `<InvariantGlobalization>true</InvariantGlobalization>`,
  `<TargetFramework>net10.0-windows</TargetFramework>`, the
  ProjectReference to CAMM, the Tolk DLL embedded-resource glob
  (referencing `..\camm\third_party\tolk\dist\x64\*.dll`), and the mod-
  payload embedded-resource glob (referencing the
  `ModPayloadFolderName` directory). Placeholder tokens
  `__MOD_INTERNAL_NAME__`, `__MOD_DISPLAY_NAME__`, etc. get
  search-and-replaced by the bootstrap script.

- `app.manifest` — Common Controls v6 dependency + PerMonitorV2 DPI +
  Windows 10/11 compatibility GUID. Identical to today's
  `CivViAccess/app.manifest`.

- `Program.cs.template` — three lines: usings, namespace, and
  `return await Camm.CammHost.RunAsync(args, MyModManifest.Build());`

- `CammModManifest.cs.template` — a worked example with every field
  populated and commented for explanation.

- `build.ps1` — `dotnet publish -c Release -r win-x64 -p:Version=$Version
  --nologo`, output staged in `dist/`.

- `.github/workflows/release.yml.template` — copy of the current
  Civ VI Access `release.yml`, with placeholders for Trusted Signing
  account name + cert profile name. Authors who don't have Trusted
  Signing set up replace the sign step with `# unsigned` or their own
  signtool invocation.

- `.camm-mod.json.template` — the registry marker per
  `project_camm_architecture_v0.md`, with `name`, `description`,
  `targetGame`, `downloadUrl`, `projectUrl`, `publisher`,
  `minCammVersion` fields. Author edits once, commits, and the CAMM
  registry's daily action picks it up via GitHub Code Search.

A bootstrap script `camm\bin\camm-new.ps1` (or just `camm new` as a
.NET tool — see open questions) automates the copy from `/template/`
into a new consuming repo with placeholder substitution.

## Per-game customization points

The `CammModManifest` exposes these knobs. Each is a one-liner in the
manifest constructor, plus a `*PathFinder` delegate for the cases
where Steam/Epic/standalone install paths need probing.

**Identity.** ModDisplayName (user-facing), ModInternalName (ASCII,
used in all OS-level identifiers like the LocalAppData folder),
Publisher, ProjectUrl. The "powered by CAMM" footer is generated by
CAMM itself.

**Install paths.** InstallDirName (subdir under Program Files),
LauncherExeName (the produced exe), AppsAndFeaturesKeyName (HKLM
Uninstall subkey name; usually equals ModInternalName but exposed
separately in case of collisions with other apps).

**Target game.** TargetGameDisplayName (used in dialog text:
"Launching Sid Meier's Civilization VI" etc.), IfeoTargetExeNames
(array — Civ VI has two, most games have one), GameProcessNames
(used by WindowFocusManager and the game-still-running poll;
distinct from exe names because Process.GetProcessesByName uses
the process name without `.exe` and may differ from the exe filename),
GameInstallPathFinder (delegate returning the absolute path to the
game's main exe — Civ VI Access today hardcodes
`C:\Program Files (x86)\Steam\...\CivilizationVI.exe`; CAMM exposes
this as a delegate so each adopter can probe Steam/Epic/GOG/etc).

**Mod payload.** ModPayloadFolderName (the dev-mode source directory
sibling to the launcher), ModPayloadSentinelFileName (the file CAMM
looks for to confirm a folder is genuinely the mod source, not a
random collision), ModPayloadDeployDestination (where on the user's
machine the mod files get extracted — for Civ VI this is the Steam
DLC dir; for RimWorld it's
`%USERPROFILE%\AppData\LocalLow\Ludeon Studios\RimWorld by Ludeon
Studios\Mods\<modname>`; for Factorio it's
`%APPDATA%\Factorio\mods\<modname>`; for ONI it's `%USERPROFILE%\
Documents\Klei\OxygenNotIncluded\mods\Local\<modname>`). The
destination is a `Func<string>` rather than a string constant
because it commonly needs `Environment.GetFolderPath` resolution.

**Updates.** GitHubReleasesOwner, GitHubReleasesRepo,
LauncherAssetNamePattern (a format string like
`"CivViAccess-{0}.exe"` where `{0}` is the version — different mods
ship under different filenames).

**Speech.** UseTolk (default true; opt-out reserved for the macOS
port and similar non-Tolk-based audio backends), Sanitizer
(`IMessageSanitizer` implementation that strips game-specific markup),
MarkerProtocol (`IScreenReaderMarkerProtocol` implementation that
recognizes the mod's chosen log-line marker prefix and its option
grammar), LogTailSpeaker (subclass of `Camm.Speech.LogTailSpeaker`
with the file-path resolution for the game's log file).

**Optional / future.** DefaultLocale (override the
CurrentUICulture fallback), MinCammVersion (recorded in
.camm-mod.json for registry filtering), ExtraSettingsKeys
(callback that extends launcher.ini with mod-specific keys — out of
scope for v0).

Documentation in `/docs/per-game-conventions.md` catalogues the
known mod-deploy destinations for the games we care about (Civ VI,
Civ V, RimWorld, Factorio, ONI). New adopters can either find their
game listed or contribute a section.

## Localization architecture

Per `project_launcher_localization_gap.md` and the open question at
the end of `WIZARD_PLAN.md`. The wizard ships English-only;
localization lands as the first piece of new CAMM work in extraction.

**Storage.** `lang/<culture>.json` next to the consuming launcher
exe. Loaded at startup by `Camm.Localization.LocaleCatalog`. Files
ship as embedded resources in `Camm.csproj` (`lang/en.json` baseline)
plus optionally as loose files alongside the consuming exe (so a
translator can drop a `lang/de.json` without rebuilding). The
embedded-resource fallback guarantees `en` is always available.

**Format.** Flat JSON dictionary, key = identifier, value = string.
Example:

```json
{
  "Install.Welcome.Title": "Install __MOD_DISPLAY_NAME__",
  "Install.Welcome.Body": "After install, launching __TARGET_GAME__ from Steam will automatically activate the screen-reader accessibility mod.",
  "Install.Channel.Title": "Update channel",
  "Install.Channel.Stable.Description": "Tested releases only. Safest, gets new features after they've been validated.",
  "Install.Channel.Latest.Description": "Includes pre-release builds. Newer features but may be rougher. Good for testers.",
  "Install.Channel.Off.Description": "Never check for updates. You will miss bug fixes and new screen support."
}
```

Manifest-driven substitution tokens (`__MOD_DISPLAY_NAME__`,
`__TARGET_GAME__`, `__INSTALL_DIR__`, etc.) get replaced at
load-time from the consuming manifest. This keeps the localized
strings game-agnostic in the JSON file itself, with per-mod
identity injected at runtime.

**Loader.** `Camm.Localization.Strings.Get(string key)` returns
the resolved string. `Strings.Get("Install.Welcome.Title")` returns
"Install Civ VI Access" for the Civ VI Access build. Missing keys
log a warning and return the key itself (so missing-string bugs are
visible but never crash the launcher). Source-generated
`JsonSerializerContext` keeps AOT-clean.

**Fallback chain.** `<culture>.json` (e.g. `de-DE.json`) →
`<language>.json` (`de.json`) → `en.json`. Standard .NET locale
fallback semantics, implemented manually because we control file
naming.

**Where translations live.** The base `en.json` lives in CAMM. The
consuming repo can ship its own `lang/en-override.json` for
mod-specific phrasing tweaks (rare). New translations land in CAMM
via PRs against `lang/<culture>.json`. Crowdin integration is
deferred until at least one community-contributed translation
arrives — handles JSON natively when needed.

**What's NOT localized in v0.** Log messages (English-only because
they're diagnostic output developers read), the "powered by CAMM"
footer (lineage marker), the .ini comments (English-only file format
documentation).

## Staged migration path for Civ VI Access

Civ VI Access is the test case. The migration proceeds through ten
ordered steps. Each step ends in a working launcher that passes the
chameleon test palette (see `project_chameleon_launcher.md`); no
step lands in an intermediate broken state.

**Step 1: Stand up the CAMM repo with the lowest-risk modules first.**
Create `github.com/nromey/camm`. Copy in `SemVer.cs`, `Logger.cs`,
`ProcessLauncher.cs`, `TolkBootstrap.cs`, `Dialogs.cs`. These have
zero or near-zero parameterization needed. The CAMM repo at this
stage compiles as a library but isn't yet referenced by anything.

**Step 2: Wire Civ VI Access to consume CAMM for those modules.**
Add CAMM as a submodule in `Civ-vi-access`. Delete the in-tree
copies of the migrated files. Update `using` statements in the
remaining files. Run the full chameleon test palette. This is the
first time CAMM is actually consumed; flushes out any embedded-
resource path mismatches or namespace issues.

**Step 3: Move LauncherSettings + UpdateChannel + GitHubReleasesClient
+ Updater.** Slightly more parameterization (`LocalAppDataFolderName`,
`GitHubReleasesOwner`, `GitHubReleasesRepo`, `LauncherAssetNamePattern`).
Wire those through the manifest. Test the update flow against a
real GitHub Release.

**Step 4: Move IfeoInstaller + AppsAndFeaturesRegistration +
WindowFocusManager + ModFiles + ModDeployer.** All HYBRIDs that
need their game-specific bits pulled into the manifest. Test
install/uninstall/already-installed flows end to end.

**Step 5: Introduce the CammModManifest + CammHost.** Define the
manifest class and the `CammHost.RunAsync(args, manifest)` entry
point. CivViAccess/Program.cs gets cut down to manifest-build +
host-run; the routing logic moves into CammHost. This is the
biggest single behavioral cut; expect to run the full chameleon
palette twice (before and after) to confirm no regressions.

**Step 6: Move Installer and Wizard (wizard if already shipped by
this point; otherwise wizard lands directly in CAMM during its
implementation).** This is the install flow. Manifest provides
identity strings; locale catalog provides the visible text.
Civ-VI-specific dialog body text gets either parameterized into the
locale file or replaced with manifest-substituted strings.

**Step 7: Introduce LocaleCatalog and migrate all visible strings to
en.json.** First step where the launcher loads JSON at startup.
Verify NVDA still announces dialogs correctly. Add a `de.json` stub
with one or two translated strings as a smoke-test of the fallback
chain.

**Step 8: Move LogTailSpeaker + AccessibleOutputHandler + introduce
IMessageSanitizer / IScreenReaderMarkerProtocol seams.** Civ-VI-
specific sanitizer and marker-protocol implementations stay in
CivViAccess. The Civ-V-style log-tail loop moves to CAMM. Test that
Civ VI Lua.log narration still works through the new path.

**Step 9: Clean up CivViAccess to its minimum.** What's left should
be: `Program.cs` (thin shim with manifest build + host run),
`Speech/CivViMessageSanitizer.cs`,
`Speech/CivViScreenReaderMarkerProtocol.cs`,
`Speech/CivViLogTailSpeaker.cs`, `Civ/CivVIPathFinder.cs`,
`CammModManifest` instance (the configuration). Estimated 250-350
LOC remaining. Anything that didn't fit in that footprint either
(a) belongs in CAMM and was missed, or (b) is genuinely Civ-VI-
specific and that's fine.

**Step 10: Ship a CAMM 0.1.0 tagged release + a Civ VI Access
version bump.** First tagged CAMM release. CHANGELOG.md in CAMM
captures the "extracted from Civ VI Access" lineage. Civ VI Access
bumps to 0.2.0 to signal the major reorganization (the version
scheme says 0.2.0 is reserved for "installer + auto-update path"
ships — which is true now, since CAMM extraction *is* that
generalization).

The cut-over commit lives at Step 5 — that's where the architecture
genuinely changes from "launcher.exe with helpers" to "manifest fed
to a host". Earlier steps are mechanical file moves; later steps
are incremental refactors of internals. Step 5 is the only one that
should land with a thorough manual test of every chameleon mode.

Estimated total scope: 12-20 focused sessions of work to land all
ten steps with NVDA testing at each. Doable in calendar weeks, not
months, given each step is independently verifiable.

## Open questions and decisions deferred

1. **Bootstrap experience.** Does CAMM ship a `camm new` .NET tool
   that scaffolds a consuming repo from `/template/`, or just docs
   telling the author to clone `/template/` manually and search-
   replace placeholders? Manual is simpler to ship; a tool is more
   polished. Recommendation: docs-only for v0, tool when adopter
   count justifies it. Defer.

2. **The Tolk-opt-out abstraction shape.** What does
   `IAccessibleSpeech` look like for the macOS-port case? Tolk's
   surface area is small (`Output`, `Load`, `IsLoaded`,
   `HasSpeech`, `HasBraille`, `DetectScreenReader`, `TrySAPI`) but
   the macOS NSSpeechSynthesizer abstraction is meaningfully
   different. Probably ship v0 with Tolk hard-wired and revisit
   when the macOS port is concrete. Decision deferred to
   `project_cross_platform.md` follow-up.

3. **Per-locale config of the manifest itself.** Should
   `TargetGameDisplayName = "Civilization VI"` be a key in the
   locale catalog so it gets translated, or a manifest constant
   (English everywhere)? Game brand names typically don't get
   translated (Civilization VI is "Civilization VI" in every
   locale), so manifest-constant is fine. Confirm before locking.

4. **Trusted Signing setup automation.** The current
   `release.yml` requires the author to have an Azure App
   Registration, federated credential, Trusted Signing account,
   and cert profile pre-configured. Each adopter has to redo
   this for their own GitHub repo. Could CAMM provide a one-time
   `Setup-TrustedSigning.ps1` that walks an author through it via
   `az` CLI? Out of scope for v0 — most adopters won't sign with
   Trusted Signing initially. Document the requirement, link to
   the Civ VI Access setup notes, defer automation.

5. **Mod-callable UI APIs.** `project_camm_architecture_v0.md`
   raises the `#SCREENREADER_DIALOG[NUMBER:1-50]:prompt` extension
   to the log-tail protocol for mod-requested UI. This is v1+
   territory; extraction lands the WinForms host (already in the
   wizard work) but doesn't open the dialog channel yet. Spec it
   when an actual adopter (Factorio Access) needs it.

6. **Registry indexer host.** Where does the GitHub Pages site for
   the .camm-mod.json registry actually live? Same `nromey/camm`
   repo or a separate `nromey/camm-registry` repo? Recommendation:
   separate repo to keep the daily GitHub Action's failure mode
   isolated from CAMM library releases. Defer until first
   external adopter ships.

7. **CAMM's own dogfooding.** Since CivViAccess will be the first
   consumer, and CAMM has its own version, do we keep CivViAccess
   pinned to a CAMM tag or to `main` during early extraction? Pin
   to a tag at each Civ VI Access release; track `main` between
   releases for fast iteration. Standard library-development
   practice.

8. **Localization seed beyond English.** Do we ship `de.json` and
   `fr.json` stubs in the extraction or wait for community
   translations? Stubs invite half-baked translation; absent
   files force `en` fallback (which is correct behavior, just
   un-tested by code reviewers). Ship `en.json` only at extraction
   time; add other locales as PRs from contributors arrive.
