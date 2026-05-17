using CivVIAccess.Launcher;
using CivVIAccess.Launcher.Wizard;
using DavyKager;
using System.Diagnostics;

// =========================================================================
// Entry point routing
// =========================================================================
//
// Modes (in priority order):
//   --install            Install to Program Files + register IFEO Steam
//                        intercept. Re-launches elevated if needed.
//   --uninstall          Reverse of --install.
//   --version, --about   Print build info + install state + channel,
//                        then exit. Same exe = same answer regardless of
//                        where it's run from.
//   <path>\CivilizationVI.exe [...]
//                        Transparent invocation: Windows IFEO redirected
//                        a Civ VI launch through us. Pass-through extra
//                        args. This is the "user clicked Play in Steam"
//                        path post-install.
//   (no args)            Stand-alone launcher mode. If not installed,
//                        offer install. Otherwise update-then-launch.
//
// Apply-pending self-update runs BEFORE anything else so a downloaded
// .pending launcher swaps in cleanly, regardless of which mode we'd
// otherwise enter.

Logger.StartSession("startup");

try { Console.Title = "Civ VI Access Launcher"; } catch { /* console may be redirected */ }

// Step 1: complete any pending self-update from a previous run. If a
// swap happens, we re-launch ourselves and Environment.Exit, so anything
// below this line runs against the newest launcher version.
Logger.Info("Step 1: ApplyPendingSelfUpdateAndRelaunchIfNeeded");
Updater.ApplyPendingSelfUpdateAndRelaunchIfNeeded();

// Step 1b: if a self-update just happened (or the marker was left by
// the previous launcher version's update flow), the deployed mod in
// the DLC dir is stale relative to our newly-current version. Rehydrate
// the mod from embedded resources, then delete the marker.
//
// Best-effort: if the rehydrate fails (e.g., Civ VI is somehow already
// running and has the files locked), we log and continue. The next
// launch will see the marker again and retry.
if (File.Exists(Updater.RedeployMarkerPath))
{
    Logger.Info("Step 1b: redeploy-mod marker present, rehydrating mod from embedded resources");
    try
    {
        var count = ModFiles.ExtractTo(ModDeployer.DefaultDestination);
        Logger.Info($"  Rehydrated {count} mod files to {ModDeployer.DefaultDestination}");
        File.Delete(Updater.RedeployMarkerPath);
    }
    catch (Exception ex)
    {
        Logger.Exception("Mod rehydrate failed (will retry on next launch)", ex);
    }
}

// Step 2: make Tolk's native sidecars loadable by P/Invoke. Post-install
// they live next to the exe in Program Files; pre-install we extract to
// a per-launch temp dir and SetDllDirectory the loader at it. Either
// way, by the time AccessibleOutputHandler hits a Tolk P/Invoke, the
// DLL loader can resolve it.
Logger.Info("Step 2: TolkBootstrap.PrepareRuntime");
try { TolkBootstrap.PrepareRuntime(); Logger.Info("  PrepareRuntime returned"); }
catch (Exception ex) { Logger.Exception("PrepareRuntime threw", ex); throw; }

Logger.Info("Step 3: AccessibleOutputHandler init");
AccessibleOutputHandler? accessibleOutput = null;
try
{
    var accessibleOutputOptionReader = new AccessibleOutputOptionReader();
    accessibleOutput = new AccessibleOutputHandler(accessibleOutputOptionReader);
    Logger.Info("  AccessibleOutputHandler constructed");
    try
    {
        var reader = Tolk.DetectScreenReader();
        Logger.Info($"  Tolk.DetectScreenReader: '{reader ?? "(null - no screen reader detected)"}'");
        Logger.Info($"  Tolk.HasSpeech: {Tolk.HasSpeech()}");
        Logger.Info($"  Tolk.IsLoaded: {Tolk.IsLoaded()}");
        Logger.Info($"  Tolk.HasBraille: {Tolk.HasBraille()}");
    }
    catch (Exception detectEx) { Logger.Exception("Tolk detection probes threw", detectEx); }
}
catch (Exception ex)
{
    Logger.Exception("AccessibleOutputHandler construction threw", ex);
    throw;
}
var textOutput = new TextOutputHandler();
var mediator = new Mediator(accessibleOutput, textOutput);

void Log(string msg) { Console.WriteLine(msg); Logger.Info($"LOG: {msg}"); }
void Speak(string msg)
{
    Log(msg);
    Logger.Info($"SPEAK call: {msg}");
    try { accessibleOutput!.Speak(msg); Logger.Info("  Speak returned"); }
    catch (Exception ex) { Logger.Exception("Speak threw", ex); }
}

// Top-level statements expose `args` as a `string[]` parameter that
// already excludes the exe path, so we use it directly rather than
// calling Environment.GetCommandLineArgs and slicing.
var userArgs = args;

if (HasFlag(userArgs, "--install"))
{
    Installer.Install(Log, Speak);
    return 0;
}
if (HasFlag(userArgs, "--uninstall"))
{
    Installer.Uninstall(Log, Speak);
    return 0;
}
if (HasFlag(userArgs, "--version") || HasFlag(userArgs, "--about"))
{
    PrintAbout(Speak);
    return 0;
}
if (HasFlag(userArgs, "--config"))
{
    // Settings dialog mode. Reached from:
    //   1. Apps & Features "Modify" button (Settings → Apps → Installed
    //      Apps → Civ VI Access → Modify, which Windows runs with our
    //      ModifyPath registry value pointing here).
    //   2. Power users running the launcher with --config from a
    //      terminal.
    //   3. The Already Installed dialog's "change settings" branch.
    //
    // No elevation required because launcher.ini lives in
    // %LocalAppData%, which is user-writable.
    var configSettings = LauncherSettings.LoadOrCreate(LauncherSettings.DefaultPath);
    if (OperatingSystem.IsWindows())
    {
        var picked = Dialogs.ShowChannelPicker(configSettings.UpdateChannel);
        if (picked is UpdateChannel choice)
        {
            configSettings.UpdateChannel = choice;
            try
            {
                configSettings.Save(LauncherSettings.DefaultPath);
                Log($"Update channel saved: {choice}");
                Dialogs.ShowInfo(
                    "Civilization VI Access — Settings Saved",
                    $"Update channel is now: {choice}\n\n" +
                    "Click OK to finish. The new setting takes effect on " +
                    "the next launch of Civilization VI through the access mod.");
            }
            catch (Exception ex)
            {
                Log($"Failed to save settings: {ex.Message}");
                Dialogs.ShowError(
                    "Civilization VI Access — Settings Error",
                    $"Could not save settings: {ex.Message}");
            }
        }
        else
        {
            Log("User cancelled channel change; settings unchanged.");
        }
    }
    return 0;
}

// Dev-only entry point: opens the install wizard scaffold without
// running the actual install. Yanked once the wizard replaces the
// TaskDialog install chain in Installer.Install (step 7 of
// WIZARD_PLAN.md). Lets us iterate on wizard UI without re-running
// the full install flow each time.
if (HasFlag(userArgs, "--wizard-test"))
{
    if (OperatingSystem.IsWindows())
    {
        Log("Opening install wizard (--wizard-test mode)...");
        InstallWizardForm.Run();
        Log("Wizard closed.");
    }
    return 0;
}

// Transparent invocation: Windows IFEO prepended us to a CivilizationVI.exe
// launch, so userArgs[0] is the full path to the real game binary and
// userArgs[1..] are whatever original args Steam (or a shortcut) used.
bool transparentInvocation = IfeoInstaller.TryGetTransparentInvocationTarget(
    userArgs, out var transparentCivVIPath);
string[] passthroughGameArgs = transparentInvocation && userArgs.Length > 1
    ? userArgs[1..]
    : Array.Empty<string>();
Logger.Info($"transparentInvocation={transparentInvocation}, transparentCivVIPath={transparentCivVIPath}");

// Step 3: if user just ran the bare exe with no args, we're not
// registered as the IFEO target, AND we're not in a dev checkout,
// enter install flow.
//
// The dev-checkout guard matters because `dotnet run` from a source
// tree also lands here with empty args; the right behavior in dev is
// to keep the iterate-edit-relaunch loop, not to suddenly UAC-prompt
// and copy bin/Debug into Program Files. Presence of a mod source
// tree adjacent to the launcher is a reliable dev-mode tell.
//
// If reading HKLM fails (anything other than a clean "no key" answer),
// don't guess — fall through to normal launch so we never auto-trigger
// UAC over a transient registry hiccup.
if (userArgs.Length == 0 && ModDeployer.FindModSourceDir() is null)
{
    bool installed = false;
    bool readOk = false;
    try
    {
        if (OperatingSystem.IsWindows())
        {
            installed = IfeoInstaller.GetRegisteredLauncherPath() is not null;
            readOk = true;
        }
    }
    catch { readOk = false; }

    if (readOk && !installed)
    {
        Speak("Civ VI Access is not installed. Starting install. Click Yes on the User Account Control prompt to continue.");
        Installer.Install(Log, Speak);
        return 0;
    }

    // Already installed AND running from outside the install dir =
    // user double-clicked a downloaded copy of the launcher after a
    // previous install. Don't silently fall through to launching Civ
    // VI (which is confusing — they ran the "installer" expecting
    // *install* UX, not gameplay). Offer Reinstall / Uninstall /
    // Cancel.
    //
    // If they're running from the install dir itself (no args), that
    // would be an admin manually invoking the installed launcher
    // outside Steam — rare, fall through to launch in that case so we
    // don't loop the same user through dialogs.
    if (OperatingSystem.IsWindows() && readOk && installed)
    {
        var currentExe = Environment.ProcessPath ?? "";
        var installedExe = Path.Combine(Installer.DefaultInstallDir, Installer.LauncherExeName);
        var runningFromInstallDir = string.Equals(
            Path.GetFullPath(currentExe),
            Path.GetFullPath(installedExe),
            StringComparison.OrdinalIgnoreCase);
        if (!runningFromInstallDir)
        {
            // Single TaskDialog with four explicit command-link buttons.
            // Previously a sequential YesNoCancel chain (Yes=Reinstall,
            // No=Uninstall, Cancel=more options → another YesNo). The
            // generic Yes/No labels were ambiguous — picking "Yes"
            // meaning to uninstall would actually trigger reinstall.
            // Explicit verbs eliminate the mismatch.
            const int ID_REINSTALL = 101;
            const int ID_UNINSTALL = 102;
            const int ID_SETTINGS = 103;
            const int ID_EXIT = 104;
            var choice = Dialogs.ShowChoice(
                title: "Civilization VI Access — Already Installed",
                mainInstruction: "Civ VI Access is already installed. What would you like to do?",
                content: "Installed at: " + Installer.DefaultInstallDir,
                choices: new[]
                {
                    new Dialogs.ChoiceButton(ID_REINSTALL, "Reinstall / update",
                        "Overwrite existing files with this version. Prompts for administrator permission (UAC)."),
                    new Dialogs.ChoiceButton(ID_UNINSTALL, "Uninstall Civ VI Access",
                        "Remove Civ VI Access from this computer. Prompts for administrator permission (UAC)."),
                    new Dialogs.ChoiceButton(ID_SETTINGS, "Change update channel only",
                        "Open the update channel picker without reinstalling. No UAC needed."),
                    new Dialogs.ChoiceButton(ID_EXIT, "Exit",
                        "Close without making any changes."),
                },
                defaultChoiceId: ID_REINSTALL);

            switch (choice)
            {
                case ID_REINSTALL:
                    Installer.Install(Log, Speak);
                    return 0;
                case ID_UNINSTALL:
                    Installer.Uninstall(Log, Speak);
                    return 0;
                case ID_SETTINGS:
                    var alreadyInstalledSettings = LauncherSettings.LoadOrCreate(LauncherSettings.DefaultPath);
                    var picked = Dialogs.ShowChannelPicker(alreadyInstalledSettings.UpdateChannel);
                    if (picked is UpdateChannel newChan)
                    {
                        alreadyInstalledSettings.UpdateChannel = newChan;
                        try { alreadyInstalledSettings.Save(LauncherSettings.DefaultPath); Log($"Channel saved: {newChan}"); }
                        catch (Exception ex) { Log($"Save failed: {ex.Message}"); }
                        Dialogs.ShowInfo(
                            "Civilization VI Access — Settings Saved",
                            $"Update channel is now: {newChan}\n\n" +
                            "The new setting takes effect next time Civilization VI launches.");
                    }
                    else
                    {
                        Log("Channel change cancelled.");
                    }
                    return 0;
                default:
                    Log("User exited from already-installed dialog.");
                    return 0;
            }
        }
    }
}

Logger.Info("Reaching main launch flow (past install/uninstall/version routing)");
Console.WriteLine("Civ VI Access Launcher initializing...");
// Deliberately NOT speaking "Civ VI Access Launcher ready" here — earlier
// versions did, but the rapid-fire "ready" → "checking for updates" →
// "launching" sequence within ~300ms means NVDA only vocalizes the last
// one (each Speak with default interrupt=true preempts the previous).
// The single audible message that matters is "Launching Sid Meier's
// Civilization VI" below; the rest just goes to the log.

// =========================================================================
// Update check (respects UpdateChannel = stable / latest / off)
// =========================================================================
//
// Skipped when running from a dev checkout: ModDeployer.FindModSourceDir
// returning non-null means we're going to overwrite the DLC dir from
// local source anyway, and the dev launcher's version is typically
// ahead of any release.

var settings = LauncherSettings.LoadOrCreate(LauncherSettings.DefaultPath);
var modSourceDir = ModDeployer.FindModSourceDir();
bool isDevCheckout = modSourceDir is not null;

if (settings.UpdateChannel != UpdateChannel.Off && !isDevCheckout)
{
    try
    {
        // The fast happy-path of "check returns nothing new" is the
        // common case once we're shipping releases, so it's silent —
        // only speak when we're actually doing update work the user
        // can perceive as latency. Log it either way for diagnostics.
        Log("Checking for updates...");
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
        var client = new GitHubReleasesClient(http);
        var release = await client.GetLatestForChannelAsync(settings.UpdateChannel);

        if (release is not null && release.Version.CompareTo(SemVer.Current()) > 0)
        {
            var updater = new Updater(http, Log, Speak);
            var result = await updater.ApplyAsync(
                release, ModDeployer.DefaultDestination);
            switch (result)
            {
                case UpdateResult.AppliedModOnly:
                case UpdateResult.AppliedBoth:
                    Speak($"Update to {release.Version} complete.");
                    break;
                case UpdateResult.LauncherStagedOnly:
                    Speak($"Launcher update to {release.Version} staged. It will take effect next launch.");
                    break;
                case UpdateResult.NothingToDo:
                    Log($"Release {release.TagName} had no applicable assets.");
                    break;
            }
        }
        else
        {
            Log("Mod is up to date.");
        }
    }
    catch (Exception ex)
    {
        // Update failures must not block the game. Log + continue.
        // No speech here either — the user clicked Civ VI in Steam, a
        // background update-check timeout shouldn't make them hear an
        // error that's unrelated to their actual goal of starting the
        // game.
        var msg = $"Update check failed: {ex.Message}. Continuing with installed version.";
        Console.Error.WriteLine(msg);
        Logger.Warn(msg);
    }
}

// =========================================================================
// Dev-mode mod deploy (no-op in shipped installs)
// =========================================================================
//
// In a shipped install the source tree isn't next to the launcher exe
// and FindModSourceDir returned null above — we fall through silently
// and the game loads whatever's in the DLC dir (either from --install
// initial drop or from the auto-update flow above).

if (modSourceDir is not null)
{
    try
    {
        var copied = ModDeployer.Deploy(modSourceDir, ModDeployer.DefaultDestination);
        Console.WriteLine($"Deployed {copied} mod file(s): {modSourceDir} -> {ModDeployer.DefaultDestination}");
    }
    catch (Exception ex)
    {
        var msg = $"Mod deploy failed: {ex.Message}. Launching with whatever is currently in the DLC dir.";
        Console.Error.WriteLine(msg);
        accessibleOutput.Speak(msg);
    }
}
else
{
    Console.WriteLine("No mod source dir found near launcher exe; using DLC dir as-is.");
}

// =========================================================================
// Locate Civ VI binary
// =========================================================================

var civVIPath = transparentInvocation
    ? transparentCivVIPath
    : @"C:\Program Files (x86)\Steam\steamapps\common\Sid Meier's Civilization VI\Base\Binaries\Win64Steam\CivilizationVI.exe";

if (!File.Exists(civVIPath))
{
    var msg = $"Could not find Civilization VI at {civVIPath}. " +
              "If Steam is installed somewhere non-default, run the launcher via Steam's Play button (the IFEO redirect will pass the right path) or edit Program.cs.";
    Console.Error.WriteLine(msg);
    accessibleOutput.Speak(msg);
    return 1;
}

// =========================================================================
// Capture pre-launch log size + first-launch state
// =========================================================================

var preLaunchLuaLogPath = Path.Join(
    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
    "Firaxis Games", "Sid Meier's Civilization VI", "Logs", "Lua.log");
long preLaunchLuaLogSize = File.Exists(preLaunchLuaLogPath)
    ? new FileInfo(preLaunchLuaLogPath).Length
    : 0L;

var userOptionsPath = Path.Join(
    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
    "Firaxis Games", "Sid Meier's Civilization VI", "UserOptions.txt");
bool hasEulaBeenAccepted = false;
if (File.Exists(userOptionsPath))
{
    try
    {
        foreach (var line in File.ReadAllLines(userOptionsPath))
        {
            const string prefix = "CopyrightAccept ";
            if (line.StartsWith(prefix, StringComparison.Ordinal))
            {
                var value = line.Substring(prefix.Length).Trim();
                hasEulaBeenAccepted = value.Length > 0;
                break;
            }
        }
    }
    catch { /* first-launch verbose path is the safe fallback */ }
}

Logger.Info($"About to speak 'Launching...' (hasEulaBeenAccepted={hasEulaBeenAccepted})");
Console.WriteLine($"Launching {civVIPath}...");
if (hasEulaBeenAccepted)
{
    Speak("Launching Sid Meier's Civilization VI.");
}
else
{
    Speak(
        "Launching Sid Meier's Civilization VI for the first time. The 2K and Firaxis logos and an intro "
        + "cinematic will play for a while. After that, an end user license agreement screen "
        + "will appear; press Enter to accept it. The main menu will load after acceptance.");
}

AppDomain.CurrentDomain.ProcessExit += (_, _) => KillAllCivVI();
Console.CancelKeyPress += (_, e) =>
{
    e.Cancel = true;
    KillAllCivVI();
};

// IFEO bypass: ProcessLauncher.LaunchBypassingIfeo uses CreateProcess
// with DEBUG_PROCESS to skip Windows' IFEO Debugger substitution. Without
// this, our own IFEO entry would redirect this Process.Start call back
// through ourselves, creating infinite recursion (encountered during
// 2026-05-15 install testing). Plain Process.Start works when IFEO isn't
// registered (dev mode); the bypass is harmless in that case too.
Logger.Info($"Calling ProcessLauncher.LaunchBypassingIfeo({civVIPath})");
try
{
    var spawnedPid = ProcessLauncher.LaunchBypassingIfeo(civVIPath, passthroughGameArgs);
    Logger.Info($"  LaunchBypassingIfeo returned pid={spawnedPid}");
}
catch (Exception ex)
{
    Logger.Exception("LaunchBypassingIfeo threw", ex);
    throw;
}

var consoleHwnd = WindowFocusManager.GetConsoleWindowHandle();
if (WindowFocusManager.EnsureForeground(TimeSpan.FromSeconds(15)))
{
    WindowFocusManager.StartFollowFocus(consoleHwnd);
}
else
{
    accessibleOutput.Speak("Could not focus Civilization VI. Press Alt+Tab to switch to the game window.");
}

var luaLogFileDir = Path.Join(
    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
    "Firaxis Games", "Sid Meier's Civilization VI", "Logs");
var luaLogFilePath = Path.Join(luaLogFileDir, "Lua.log");

Logger.Info("Waiting for Civ VI Lua.log to appear");
Console.WriteLine("Waiting for Civ VI log file...");

var logFileWatcher = new LogFileWatcher(mediator);
var startupTimeout = TimeSpan.FromMinutes(2);
var startupStart = DateTime.UtcNow;
bool seenAlive = false;

while (!File.Exists(luaLogFilePath))
{
    if (AnyCivVIProcessRunning())
    {
        seenAlive = true;
    }
    else if (seenAlive)
    {
        Console.WriteLine("Civ VI exited before creating a log file (likely never accepted the EULA). Launcher exiting.");
        return 0;
    }
    else if (DateTime.UtcNow - startupStart > startupTimeout)
    {
        var msg = "Civ VI did not start within 2 minutes.";
        Console.Error.WriteLine(msg);
        accessibleOutput.Speak(msg);
        return 2;
    }

    Thread.Sleep(2000);
}

Logger.Info($"Lua.log appeared at {luaLogFilePath}, starting WatchLogFile from offset {preLaunchLuaLogSize}");
Console.WriteLine("Log file found. Watching...");
_ = Task.Run(() =>
{
    try { logFileWatcher.WatchLogFile(luaLogFilePath, preLaunchLuaLogSize); }
    catch (Exception ex) { Logger.Exception("WatchLogFile threw", ex); }
});

while (AnyCivVIProcessRunning())
{
    Thread.Sleep(2000);
}

Console.WriteLine("Civ VI closed. Launcher exiting.");
accessibleOutput.Speak("Sid Meier's Civilization VI closed.");
return 0;

// =========================================================================
// Helpers
// =========================================================================

static bool HasFlag(string[] args, string flag)
{
    foreach (var a in args)
    {
        if (string.Equals(a, flag, StringComparison.OrdinalIgnoreCase)) return true;
    }
    return false;
}

static void PrintAbout(Action<string> speak)
{
    var version = SemVer.Current();
    var exe = Environment.ProcessPath ?? "<unknown>";
    var channel = "(default)";
    try
    {
        var settings = LauncherSettings.LoadOrCreate(LauncherSettings.DefaultPath);
        channel = settings.UpdateChannel.ToString().ToLowerInvariant();
    }
    catch { /* fall through to default label */ }

    string installState = "not installed";
    if (OperatingSystem.IsWindows())
    {
        try
        {
            var reg = IfeoInstaller.GetRegisteredLauncherPath();
            if (reg is not null) installState = $"installed (Steam routes through {reg.Trim('"')})";
        }
        catch { /* HKLM read failed; leave default */ }
    }

    Console.WriteLine($"Civ VI Access Launcher {version}");
    Console.WriteLine($"  Running from: {exe}");
    Console.WriteLine($"  Install state: {installState}");
    Console.WriteLine($"  Update channel: {channel}");
    Console.WriteLine("  Project: https://github.com/nromey/civ-vi-access");

    speak($"Civ VI Access Launcher version {version}. {installState}. Update channel: {channel}.");
}

static bool AnyCivVIProcessRunning()
{
    return Process.GetProcessesByName("CivilizationVI").Length > 0
        || Process.GetProcessesByName("CivilizationVI_DX12").Length > 0;
}

static void KillAllCivVI()
{
    foreach (var name in new[] { "CivilizationVI", "CivilizationVI_DX12" })
    {
        foreach (var p in Process.GetProcessesByName(name))
        {
            try { p.Kill(entireProcessTree: true); } catch { /* best effort */ }
        }
    }
}
