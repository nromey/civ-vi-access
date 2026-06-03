using System.Diagnostics;
using System.Runtime.Versioning;
using Camm;
using Microsoft.Win32;

namespace CivVIAccess.Launcher.Report;

// Renders a report by writing the assembled HTML to a file and opening it
// in an isolated Microsoft Edge "app mode" window (--app), so the screen
// reader's mature browse mode handles all heading / list / table / link
// navigation for free.
//
// Why not an in-process WebView2 control (the original design): the launcher
// ships as a Native AOT single-file exe (see CivViAccess.csproj
// <PublishAot>), and Native AOT disables built-in COM interop — which the
// WebView2 SDK's RCW-based COM activation requires. CoreWebView2Environment
// .CreateAsync throws NotSupportedException ("Built-in COM has been disabled
// via a feature switch") at runtime; ILC compiling the assembly cleanly does
// NOT imply it activates. This is a known, unresolved WebView2+NativeAOT gap
// (MicrosoftEdge/WebView2Feedback #4783 / #4800). Rather than abandon AOT (a
// deliberate size / no-runtime-install decision — see
// project_launcher_publish_mode) or add a non-AOT helper exe, we hand
// rendering to the browser the user already has. Edge is guaranteed present
// on Win10 20H2+/Win11 (it IS the WebView2 runtime), and --app gives a clean
// borderless single window instead of a tab in their everyday browser.
//
// One window, always current: every report overwrites the same file and we
// kill the prior app window before opening the new one, so the user never
// accumulates a window per turn. A dedicated --user-data-dir isolates the
// window into its own Edge process so the handle is ours to kill (a shared
// profile would let Edge hand the launch off to the user's running browser
// and orphan the window). If Edge can't be located we fall back to the OS
// default browser — a normal tab, which is still fully browse-mode readable.
[SupportedOSPlatform("windows")]
public sealed class ReportWindow
{
    private static readonly ReportWindow _instance = new();
    public static ReportWindow Instance => _instance;

    private readonly object _lock = new();
    private Process? _current;

    private ReportWindow() { }

    // Write `html` to the report file and surface it in an Edge app window.
    // Safe to call from the log-tail background thread; returns promptly
    // (Process.Start does not block on the child). Any failure is logged and
    // swallowed so the speech bridge is never affected.
    public void Show(string html, string title)
    {
        lock (_lock)
        {
            try
            {
                var path = WriteReportFile(html);
                var url = new Uri(path).AbsoluteUri;     // file:///C:/...

                var edge = FindEdge();
                if (edge is null)
                {
                    OpenInDefaultBrowser(path);
                    Logger.Info($"ReportWindow: opened '{title}' in default browser (Edge not found).");
                    return;
                }

                KillCurrent();   // single-window: close the previous report first

                var psi = new ProcessStartInfo(edge) { UseShellExecute = false };
                psi.ArgumentList.Add($"--app={url}");
                psi.ArgumentList.Add($"--user-data-dir={UserDataDir()}");
                psi.ArgumentList.Add("--no-first-run");
                psi.ArgumentList.Add("--no-default-browser-check");
                _current = Process.Start(psi);
                Logger.Info($"ReportWindow: opened '{title}' in Edge app window (pid={_current?.Id}).");

                // The launcher spawns this while fullscreen Civ holds the
                // foreground, so Windows won't surface the new window — the
                // user would have to Alt+Tab to find it. Force it foreground
                // off-thread (the window doesn't exist the instant Start
                // returns; the helper polls it in) so Show stays non-blocking.
                var spawned = _current;
                if (spawned is not null)
                {
                    Task.Run(() =>
                    {
                        var ok = WindowFocusManager.ForceForegroundForProcess(
                            spawned, TimeSpan.FromSeconds(5));
                        if (!ok) Logger.Info("ReportWindow: report window did not take foreground (user can Alt+Tab).");
                    });
                }
            }
            catch (Exception ex)
            {
                Logger.Exception("ReportWindow.Show failed", ex);
            }
        }
    }

    private static string ReportDir()
    {
        var dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            CammHost.Manifest.LocalAppDataFolderName);
        Directory.CreateDirectory(dir);
        return dir;
    }

    private static string UserDataDir()
    {
        var dir = Path.Combine(ReportDir(), "ReportBrowser");
        Directory.CreateDirectory(dir);
        return dir;
    }

    private static string WriteReportFile(string html)
    {
        var path = Path.Combine(ReportDir(), "report.html");
        File.WriteAllText(path, html);
        return path;
    }

    private void KillCurrent()
    {
        var proc = _current;
        _current = null;
        if (proc is null) return;
        try
        {
            if (!proc.HasExited) proc.Kill(entireProcessTree: true);
        }
        catch { /* already gone, or Edge handed off to an existing instance */ }
        finally { proc.Dispose(); }
    }

    // Locate msedge.exe: the App Paths registry key first (authoritative,
    // survives non-default install locations), then the standard install
    // dirs. Returns null if Edge isn't found so the caller can fall back.
    private static string? FindEdge()
    {
        const string appPaths = @"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe";
        foreach (var root in new[] { Registry.LocalMachine, Registry.CurrentUser })
        {
            try
            {
                using var key = root.OpenSubKey(appPaths);
                if (key?.GetValue(null) is string val && File.Exists(val)) return val;
            }
            catch { /* registry unavailable; fall through to fixed paths */ }
        }

        foreach (var env in new[] { "ProgramFiles(x86)", "ProgramFiles" })
        {
            var bas = Environment.GetEnvironmentVariable(env);
            if (string.IsNullOrEmpty(bas)) continue;
            var candidate = Path.Combine(bas, "Microsoft", "Edge", "Application", "msedge.exe");
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    private static void OpenInDefaultBrowser(string path)
    {
        Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
    }
}
