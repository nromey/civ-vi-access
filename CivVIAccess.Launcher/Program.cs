using CivVIAccess.Launcher;
using System.Diagnostics;

// Set a real window title so the launcher is identifiable in Alt+Tab,
// Task Manager, and screen-reader window lists rather than appearing as
// "CivVIAccess.Launcher.exe".
try { Console.Title = "Civ VI Access Launcher"; } catch { /* console may be redirected */ }

var accessibleOutputOptionReader = new AccessibleOutputOptionReader();
var accessibleOutput = new AccessibleOutputHandler(accessibleOutputOptionReader);
var textOutput = new TextOutputHandler();
var mediator = new Mediator(accessibleOutput, textOutput);
var logFileWatcher = new LogFileWatcher(mediator);

Console.WriteLine("Civ VI Access Launcher initializing...");
accessibleOutput.Speak("Civ VI Access Launcher ready.");

var civVIPath = @"C:\Program Files (x86)\Steam\steamapps\common\Sid Meier's Civilization VI\Base\Binaries\Win64Steam\CivilizationVI.exe";

if (!File.Exists(civVIPath))
{
    var msg = $"Could not find Civilization VI at {civVIPath}. Edit Program.cs or relocate Civ VI.";
    Console.Error.WriteLine(msg);
    accessibleOutput.Speak(msg);
    Environment.Exit(1);
}

// Sync the mod source tree into Civ VI's DLC dir before the game launches.
// In a dev checkout this picks up whatever's currently on disk so we don't
// need a separate copy step between edits. In a shipped install the source
// tree isn't next to the launcher and FindModSourceDir returns null — we
// fall through silently and the game loads whatever the installer put in
// the DLC dir.
var modSource = ModDeployer.FindModSourceDir();
if (modSource is not null)
{
    try
    {
        var copied = ModDeployer.Deploy(modSource, ModDeployer.DefaultDestination);
        Console.WriteLine($"Deployed {copied} mod file(s): {modSource} -> {ModDeployer.DefaultDestination}");
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
    Console.WriteLine("No mod source dir found near launcher exe; skipping deploy.");
}

// Capture Lua.log's size BEFORE spawning Civ VI so the watcher can resume
// from this offset (and replay nothing from previous sessions) when it
// attaches. Civ VI typically truncates the log on boot, but on the off
// chance an engine update changes that behavior, the watcher will detect
// truncation (current < preLaunch) and start at 0.
var preLaunchLuaLogPath = Path.Join(
    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
    "Firaxis Games",
    "Sid Meier's Civilization VI",
    "Logs",
    "Lua.log");
long preLaunchLuaLogSize = File.Exists(preLaunchLuaLogPath)
    ? new FileInfo(preLaunchLuaLogPath).Length
    : 0L;

Console.WriteLine($"Launching {civVIPath}...");
// The engine plays its native boot cinematics (logos + civ6_cinematic.bk2)
// BEFORE Lua.log starts emitting, so our screen-reader pipeline can't
// announce that phase from inside Civ VI. Bridge the gap from this side,
// but tailor verbosity to whether the user has launched the game before
// on this machine — the long "logos + EULA + main menu" preview is
// genuinely helpful first time but a 20-second tax on every subsequent
// launch for a returning player.
//
// First-launch detection: UserOptions.txt only contains "CopyrightAccept"
// once IntroScreen has written it post-EULA-accept. Its absence is a
// reliable "this user has never accepted the EULA on this machine" signal,
// which is equivalent to "they're about to see the EULA flow for real."
var userOptionsPath = Path.Join(
    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
    "Firaxis Games",
    "Sid Meier's Civilization VI",
    "UserOptions.txt");
bool hasEulaBeenAccepted = false;
if (File.Exists(userOptionsPath))
{
    try
    {
        // The "CopyrightAccept" key is rewritten by Civ VI at boot even
        // before the user has actually accepted — it appears as
        // "CopyrightAccept " with an empty version value. Substring-match
        // would treat that as accepted; we need the value to be non-empty.
        // Format on a real accept is: "CopyrightAccept 1.0.12.68 (1023995)".
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
    catch { /* fall through to first-launch verbose path */ }
}

if (hasEulaBeenAccepted)
{
    accessibleOutput.Speak("Launching Civilization VI.");
}
else
{
    accessibleOutput.Speak(
        "Launching Civilization VI for the first time. The 2K and Firaxis logos and an intro "
        + "cinematic will play for a while. After that, an end user license agreement screen "
        + "will appear; press Enter to accept it. The main menu will load after acceptance.");
}

AppDomain.CurrentDomain.ProcessExit += (_, _) => KillAllCivVI();
Console.CancelKeyPress += (_, e) =>
{
    e.Cancel = true;
    KillAllCivVI();
};

Process.Start(new ProcessStartInfo
{
    FileName = civVIPath,
    UseShellExecute = false,
});

// Civ VI's window takes seconds to materialize, and Windows' foreground-
// window protection sometimes refuses the handoff even once it does. Force
// it with the AttachThreadInput trick, retrying for up to 15 seconds.
// If we win, also wire follow-focus so the console minimizes whenever
// Civ VI takes foreground and vice versa. If we lose, fall back to telling
// the user how to switch manually.
var consoleHwnd = WindowFocusManager.GetConsoleWindowHandle();
if (WindowFocusManager.EnsureForeground(TimeSpan.FromSeconds(15)))
{
    WindowFocusManager.StartFollowFocus(consoleHwnd);
}
else
{
    accessibleOutput.Speak("Could not focus Civilization VI. Press Alt+Tab to switch to the game window.");
}

var luaLogFileName = "Lua.log";
var luaLogFileDir = Path.Join(
    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
    "Firaxis Games",
    "Sid Meier's Civilization VI",
    "Logs");
var luaLogFilePath = Path.Join(luaLogFileDir, luaLogFileName);

Console.WriteLine("Waiting for Civ VI log file...");

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
        return;
    }
    else if (DateTime.UtcNow - startupStart > startupTimeout)
    {
        var msg = "Civ VI did not start within 2 minutes.";
        Console.Error.WriteLine(msg);
        accessibleOutput.Speak(msg);
        Environment.Exit(2);
    }

    Thread.Sleep(2000);
}

Console.WriteLine("Log file found. Watching...");
// WatchLogFile is declared async void but its hot path has no await, so it
// blocks the calling thread inside its while-true reader loop. Fire it on
// the thread pool so the main thread can fall through to the lifecycle
// poll below. When Civ VI exits the main thread breaks the poll and the
// process terminates, taking the background reader with it.
_ = Task.Run(() => logFileWatcher.WatchLogFile(luaLogFilePath, preLaunchLuaLogSize));

while (AnyCivVIProcessRunning())
{
    Thread.Sleep(2000);
}

Console.WriteLine("Civ VI closed. Launcher exiting.");
accessibleOutput.Speak("Civilization VI closed.");

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
