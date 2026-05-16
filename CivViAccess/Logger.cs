using System.Diagnostics;

namespace CivVIAccess.Launcher;

// File-based logging for post-mortem diagnosis when the launcher's
// Console.WriteLine output is invisible (IFEO-spawned launches from
// Steam inherit Steam's stdin/stdout, which goes nowhere). Writes to
// %LocalAppData%\CivVIAccess\launcher.log so we can read it after a
// session to see what the launcher actually did vs what we expected.
//
// Append-only, single shared file, best-effort. Failures to write are
// swallowed — logging should never prevent the launcher from running.
//
// On launcher startup, the log is truncated (start of session) so
// each launch produces a clean record rather than an ever-growing file.
// Each entry: ISO-8601 timestamp + level + message.
public static class Logger
{
    private static readonly object _lock = new();
    private static string? _logPath;

    public static string LogPath => _logPath ??= ResolveLogPath();

    private static string ResolveLogPath()
    {
        var dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "CivVIAccess");
        try { Directory.CreateDirectory(dir); } catch { }
        return Path.Combine(dir, "launcher.log");
    }

    // Call once at process startup to begin a fresh session log.
    public static void StartSession(string mode)
    {
        lock (_lock)
        {
            try
            {
                File.WriteAllText(LogPath, "");
                Write("INFO", $"=== launcher session start, mode={mode}, pid={Environment.ProcessId}, exe={Environment.ProcessPath} ===");
                Write("INFO", $"  AppContext.BaseDirectory={AppContext.BaseDirectory}");
                Write("INFO", $"  Args={string.Join(" ", Environment.GetCommandLineArgs())}");
            }
            catch { }
        }
    }

    public static void Info(string msg) => Write("INFO", msg);
    public static void Warn(string msg) => Write("WARN", msg);
    public static void Error(string msg) => Write("ERROR", msg);

    public static void Exception(string context, Exception ex)
    {
        Write("ERROR", $"{context}: {ex.GetType().Name}: {ex.Message}");
        if (ex.StackTrace is not null) Write("ERROR", $"  {ex.StackTrace}");
    }

    private static void Write(string level, string msg)
    {
        lock (_lock)
        {
            try
            {
                var line = $"{DateTime.Now:HH:mm:ss.fff} {level,-5} {msg}{Environment.NewLine}";
                File.AppendAllText(LogPath, line);
            }
            catch { /* logging must never crash the launcher */ }
        }
    }
}
