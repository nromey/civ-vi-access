using System.Runtime.Versioning;
using System.Security.Principal;
using Microsoft.Win32;

namespace CivVIAccess.Launcher;

// Image File Execution Options (IFEO) transparent-launch registration.
//
// IFEO is a Windows feature where any process under
// HKLM\...\Image File Execution Options\<exe>\Debugger gets that
// "Debugger" prepended whenever <exe> is launched. We use it to make
// every Civ VI launch (Steam shortcut, desktop icon, Big Picture, Steam
// URL handler) go through our launcher first. Civ V Access uses the
// same trick — see [[project-transparent-launch]].
//
// Civ VI ships TWO executables: CivilizationVI.exe (DirectX 11) and
// CivilizationVI_DX12.exe (DirectX 12). Which one Steam launches
// depends on the user's preference. We register IFEO entries for BOTH
// so the launcher catches the launch regardless of which renderer the
// user picked. Discovered the hard way 2026-05-15 when DX12-mode users
// bypassed the redirect entirely.
//
// Caveats:
//   - HKLM is admin-only. Install/uninstall paths re-launch elevated
//     via UAC if needed.
//   - The "Debugger" value isn't actually a debugger; Windows just
//     prepends it. The launched-program path arrives as args[0..n].
//   - Anti-cheat / DRM that walks IFEO entries could in theory complain,
//     but Civ VI uses neither and Civ V Access has shipped this pattern
//     for years without incident.
[SupportedOSPlatform("windows")]
public static class IfeoInstaller
{
    // Both Civ VI binaries. Order doesn't matter; we treat them
    // symmetrically (register both on install, remove both on uninstall,
    // accept either as a transparent-invocation marker).
    public static readonly string[] TargetExeNames = new[]
    {
        "CivilizationVI.exe",
        "CivilizationVI_DX12.exe",
    };

    private const string IfeoKeyPath =
        @"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options";

    public static bool IsRunningElevated()
    {
        using var identity = WindowsIdentity.GetCurrent();
        var principal = new WindowsPrincipal(identity);
        return principal.IsInRole(WindowsBuiltInRole.Administrator);
    }

    // Returns the currently-registered launcher path from whichever IFEO
    // entry is set first. Read-only — works without elevation. Used for
    // "is the mod installed?" checks; consistency between the two
    // entries is enforced by Install/Uninstall always operating on both
    // together.
    public static string? GetRegisteredLauncherPath()
    {
        foreach (var exeName in TargetExeNames)
        {
            using var key = Registry.LocalMachine.OpenSubKey(
                $@"{IfeoKeyPath}\{exeName}", writable: false);
            if (key?.GetValue("Debugger") is string debugger)
            {
                return debugger;
            }
        }
        return null;
    }

    public static bool IsInstalledFor(string launcherPath)
    {
        var registered = GetRegisteredLauncherPath();
        if (registered is null) return false;
        // Stored value is typically quoted ("C:\path\foo.exe"); compare
        // by stripped path.
        var stripped = registered.Trim().Trim('"');
        return string.Equals(stripped, launcherPath, StringComparison.OrdinalIgnoreCase);
    }

    public static void Install(string launcherPath)
    {
        if (!File.Exists(launcherPath))
        {
            throw new FileNotFoundException(
                $"Launcher path does not exist: {launcherPath}", launcherPath);
        }

        // Quote the path defensively — IFEO splits on spaces otherwise
        // and a Program Files install would break.
        var quoted = $"\"{launcherPath}\"";

        foreach (var exeName in TargetExeNames)
        {
            using var key = Registry.LocalMachine.CreateSubKey(
                $@"{IfeoKeyPath}\{exeName}", writable: true)
                ?? throw new UnauthorizedAccessException(
                    $"Failed to open HKLM IFEO subkey for {exeName}. Are we elevated?");
            key.SetValue("Debugger", quoted, RegistryValueKind.String);
        }
    }

    public static void Uninstall()
    {
        using var parent = Registry.LocalMachine.OpenSubKey(IfeoKeyPath, writable: true);
        if (parent is null) return;

        foreach (var exeName in TargetExeNames)
        {
            using var sub = parent.OpenSubKey(exeName, writable: true);
            if (sub is null) continue;

            // Just remove the Debugger value, then delete the subkey if
            // we're the only thing in there. Other tools (Process Monitor,
            // various profilers) sometimes set their own values on IFEO
            // subkeys; we don't want to nuke those.
            try { sub.DeleteValue("Debugger", throwOnMissingValue: false); } catch { }
            var hasOtherValues = sub.GetValueNames().Length > 0
                || sub.GetSubKeyNames().Length > 0;
            sub.Dispose();
            if (!hasOtherValues)
            {
                try { parent.DeleteSubKey(exeName, throwOnMissingSubKey: false); } catch { }
            }
        }
    }

    // Detect transparent invocation: if our first arg looks like a path
    // ending in either Civ VI binary, we were almost certainly invoked
    // by IFEO. The arg is the path Windows would have launched; we
    // pass it through to ProcessLauncher to launch the real Civ VI.
    public static bool TryGetTransparentInvocationTarget(string[] args, out string civVIPath)
    {
        civVIPath = "";
        if (args.Length == 0) return false;
        var first = args[0];
        foreach (var exeName in TargetExeNames)
        {
            if (first.EndsWith(exeName, StringComparison.OrdinalIgnoreCase)
                && File.Exists(first))
            {
                civVIPath = first;
                return true;
            }
        }
        return false;
    }
}
