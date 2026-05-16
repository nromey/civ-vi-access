using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace CivVIAccess.Launcher;

// Spawn Civ VI in a way that bypasses our own IFEO redirect.
//
// Why this exists: post-install, HKLM has an Image File Execution Options
// entry that redirects every CivilizationVI.exe (and DX12 variant) launch
// through our launcher. That's the whole point of the transparent-launch
// feature. But it means that when *we* call Process.Start(civVIPath),
// Windows ALSO redirects that call back through our launcher — which then
// tries to launch Civ VI again, which redirects again, forever. Infinite
// recursion, hit hard during 2026-05-15 install testing (see
// [[reference-civ-vi-ifeo-recursion-bug]] memory).
//
// The fix is the canonical IFEO-bypass pattern: CreateProcess with the
// DEBUG_PROCESS flag. Windows skips IFEO substitution when the caller
// is creating the child as a debugger (a debugger wants the real
// binary, not whatever the IFEO entry redirects to).
//
// CRITICAL: CreateProcess with DEBUG_PROCESS leaves the child in a
// SUSPENDED state until the debugger calls ContinueDebugEvent for the
// initial CREATE_PROCESS_DEBUG_EVENT. My first attempt skipped this
// step → Civ VI spawned but stayed frozen → launcher hung forever
// waiting for Lua.log that never got written. The 2026-05-15-pm fix
// drains debug events for the initial process release, calls
// DebugSetProcessKillOnExit(false) so the child survives our detach,
// THEN calls DebugActiveProcessStop.
//
// Net effect: we launch CivilizationVI(_DX12).exe directly without
// triggering our own IFEO entry. Civ VI runs normally; the brief
// debugger-attached state during startup is invisible to the user and
// to the game.
[SupportedOSPlatform("windows")]
public static partial class ProcessLauncher
{
    private const uint DEBUG_PROCESS = 0x00000001;
    private const uint DEBUG_ONLY_THIS_PROCESS = 0x00000002;
    private const uint DBG_CONTINUE = 0x00010002;
    private const uint INFINITE = 0xFFFFFFFF;
    private const uint CREATE_PROCESS_DEBUG_EVENT = 3;
    private const uint EXIT_PROCESS_DEBUG_EVENT = 5;

    [StructLayout(LayoutKind.Sequential)]
    private struct STARTUPINFO
    {
        public uint cb;
        public IntPtr lpReserved;
        public IntPtr lpDesktop;
        public IntPtr lpTitle;
        public uint dwX, dwY, dwXSize, dwYSize;
        public uint dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public ushort wShowWindow, cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public uint dwProcessId;
        public uint dwThreadId;
    }

    // DEBUG_EVENT is a 12-byte header followed by a union of debug-info
    // structs (largest is CREATE_PROCESS_DEBUG_INFO at ~88 bytes on x64).
    // We only read the header fields. Size attribute reserves enough
    // bytes for the union without us having to model it.
    [StructLayout(LayoutKind.Sequential, Size = 192)]
    private struct DEBUG_EVENT
    {
        public uint dwDebugEventCode;
        public uint dwProcessId;
        public uint dwThreadId;
    }

    [LibraryImport("kernel32.dll", EntryPoint = "CreateProcessW",
        StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CreateProcess(
        string? lpApplicationName,
        string lpCommandLine,
        IntPtr lpProcessAttributes,
        IntPtr lpThreadAttributes,
        [MarshalAs(UnmanagedType.Bool)] bool bInheritHandles,
        uint dwCreationFlags,
        IntPtr lpEnvironment,
        string? lpCurrentDirectory,
        ref STARTUPINFO lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool WaitForDebugEvent(ref DEBUG_EVENT lpDebugEvent, uint dwMilliseconds);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ContinueDebugEvent(uint dwProcessId, uint dwThreadId, uint dwContinueStatus);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DebugSetProcessKillOnExit([MarshalAs(UnmanagedType.Bool)] bool KillOnExit);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DebugActiveProcessStop(uint dwProcessId);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CloseHandle(IntPtr hObject);

    public static uint LaunchBypassingIfeo(string exePath, string[] passthroughArgs)
    {
        // Build a single command line: quoted exe path + each arg (quoted
        // if it contains spaces). CreateProcess's command-line parsing
        // splits on whitespace, so this matches what the OS would have
        // passed if launched via normal Start().
        var sb = new System.Text.StringBuilder();
        sb.Append('"').Append(exePath).Append('"');
        foreach (var arg in passthroughArgs)
        {
            sb.Append(' ');
            if (arg.Contains(' '))
            {
                sb.Append('"').Append(arg).Append('"');
            }
            else
            {
                sb.Append(arg);
            }
        }
        var commandLine = sb.ToString();

        var si = new STARTUPINFO { cb = (uint)Marshal.SizeOf<STARTUPINFO>() };
        var workingDir = Path.GetDirectoryName(exePath);

        if (!CreateProcess(
                lpApplicationName: null,
                lpCommandLine: commandLine,
                lpProcessAttributes: IntPtr.Zero,
                lpThreadAttributes: IntPtr.Zero,
                bInheritHandles: false,
                dwCreationFlags: DEBUG_PROCESS | DEBUG_ONLY_THIS_PROCESS,
                lpEnvironment: IntPtr.Zero,
                lpCurrentDirectory: workingDir,
                lpStartupInfo: ref si,
                lpProcessInformation: out var pi))
        {
            var err = Marshal.GetLastWin32Error();
            throw new System.ComponentModel.Win32Exception(err,
                $"CreateProcess failed for {exePath}. Win32 error: {err}");
        }

        // CRITICAL: drain initial debug events to release the child
        // from its suspended state. CreateProcess with DEBUG_PROCESS
        // suspends the child; ContinueDebugEvent on the initial
        // CREATE_PROCESS event lets it start. We drain a handful of
        // early events (LOAD_DLL fires several times for startup DLLs)
        // and then detach. Cap iterations so we don't deadlock if Civ
        // VI generates events indefinitely.
        DebugSetProcessKillOnExit(false);

        var debugEvent = new DEBUG_EVENT();
        const int maxEvents = 32;
        for (int i = 0; i < maxEvents; i++)
        {
            // Short per-event timeout: any single event that takes
            // longer than 500ms to arrive isn't worth waiting for —
            // we'll detach and let Civ VI continue without us.
            if (!WaitForDebugEvent(ref debugEvent, 500)) break;
            ContinueDebugEvent(debugEvent.dwProcessId, debugEvent.dwThreadId, DBG_CONTINUE);
            if (debugEvent.dwDebugEventCode == EXIT_PROCESS_DEBUG_EVENT)
            {
                // Civ VI exited before we even finished attaching — let
                // the caller's lifecycle loop handle that.
                break;
            }
        }

        // Detach. Civ VI continues running without a debugger from here.
        if (!DebugActiveProcessStop(pi.dwProcessId))
        {
            var err = Marshal.GetLastWin32Error();
            Console.Error.WriteLine(
                $"Warning: DebugActiveProcessStop({pi.dwProcessId}) failed with Win32 error {err}. " +
                "Civ VI may behave erratically; try restarting if so.");
        }

        var pid = pi.dwProcessId;
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
        return pid;
    }
}
