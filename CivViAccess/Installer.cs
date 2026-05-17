using System.Diagnostics;
using System.Runtime.Versioning;
using CivVIAccess.Launcher.Wizard;

namespace CivVIAccess.Launcher;

// First-time install: copy the launcher exe + its sidecar DLLs (Tolk)
// to a stable Program Files location and register the IFEO redirect.
// Uninstall is the inverse.
//
// We deliberately install to a per-machine path (Program Files) rather
// than per-user (LocalAppData). The IFEO entry it registers is HKLM-
// only, so a per-user install path would create a mismatch where the
// redirect points to a launcher that any other user account on the
// machine couldn't read. Keep the binary and its activation symmetric.
[SupportedOSPlatform("windows")]
public static class Installer
{
    public const string InstallDirName = "Civ VI Access";

    public static string DefaultInstallDir =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            InstallDirName);

    public static string LauncherExeName => "CivViAccess.exe";

    // Open the install wizard. Replaces the legacy TaskDialog chain
    // (welcome → channel picker → ready confirm → UAC relaunch →
    // ApplyInstall → completion dialog) as of WIZARD_PLAN.md step 7.
    //
    // The wizard's pages drive the pre-elevation UX (Welcome, Channel,
    // Ready); InstallingPage spawns the elevated child via runas +
    // --install-from-wizard (or calls ApplyInstall directly when
    // already elevated); DonePage handles success/failure completion
    // UX. log and speak are accepted for caller-signature compat and
    // for the bare-exe entry's pre-wizard speech announcement — the
    // wizard itself routes its own speech through Tolk.
    public static void Install(Action<string> log, Action<string> speak)
    {
        log("Opening install wizard...");
        var context = new InstallContext
        {
            IsDryRun = false,
            // First install if the install dir doesn't exist yet. Drives
            // the WelcomePage subhead ("by Noel Romey, version X.Y.Z"),
            // shown only on genuine first installs.
            IsFirstInstall = !Directory.Exists(DefaultInstallDir),
        };
        InstallWizardForm.Run(context);
        if (context.InstallError is null)
        {
            log("Wizard closed.");
        }
        else
        {
            log($"Wizard closed with install error: {context.InstallError}");
        }
    }

    // The post-elevation work, factored out so both the TaskDialog
    // flow (Install above) and the wizard flow (--install-from-wizard
    // in Program.cs) can reuse it. MUST be called from an elevated
    // process — the caller is responsible for elevation handling and
    // for any pre-install UI (welcome, channel pick, ready confirm).
    //
    // Steps: copy launcher exe + Tolk DLLs to install dir, deploy mod
    // payload to DLC dir, register IFEO redirect, register Apps &
    // Features. Idempotent — running twice is safe and refreshes
    // files.
    public static void ApplyInstall(Action<string> log, Action<string> speak)
    {
        var destDir = DefaultInstallDir;
        Directory.CreateDirectory(destDir);

        var sourceExe = Environment.ProcessPath
            ?? throw new InvalidOperationException("Cannot determine current launcher exe path.");
        var installedLauncher = Path.Combine(destDir, LauncherExeName);

        // Two-step copy of the launcher itself:
        //   1. Copy the running .exe to the install dir, renamed to the
        //      canonical LauncherExeName (no version, no dots). This is
        //      the "downloaded as CivViAccess-0.1.18.exe lands as
        //      CivViAccess.exe" step.
        //   2. Drop the embedded Tolk DLLs next to it via the same
        //      bootstrap path the launcher uses at every startup.
        //
        // We deliberately do NOT iterate AppContext.BaseDirectory — when
        // the user runs a freshly-downloaded loose .exe, that directory
        // is typically Downloads, full of unrelated files. Targeted
        // copy only.

        var sameAsRunning = string.Equals(
            Path.GetFullPath(sourceExe),
            Path.GetFullPath(installedLauncher),
            StringComparison.OrdinalIgnoreCase);

        if (sameAsRunning)
        {
            log($"Already running from install location {installedLauncher}; skipping exe copy.");
        }
        else
        {
            try
            {
                File.Copy(sourceExe, installedLauncher, overwrite: true);
                log($"Copied launcher to {installedLauncher}.");
            }
            catch (IOException)
            {
                // Destination .exe was in use (rare — only if a previous
                // launcher run from the install dir is still alive). Stage
                // as .pending and let the in-place swap take care of it
                // on next launch.
                File.Copy(sourceExe, installedLauncher + ".pending", overwrite: true);
                log($"Existing launcher in use; staged update at {installedLauncher}.pending.");
            }
        }

        TolkBootstrap.ExtractTo(destDir);
        log($"Tolk sidecars present in {destDir}.");

        if (!File.Exists(installedLauncher))
        {
            throw new FileNotFoundException(
                $"Expected launcher exe at {installedLauncher} after install. " +
                "Did the assembly name change without updating Installer.LauncherExeName?");
        }

        // Deploy the mod itself into Civ VI's DLC dir. Without this step,
        // the launcher is installed but the game has no mod to load.
        // Embedded resources -> DLC\CivViAccessMod\ (overwrites existing).
        var dlcModDir = ModDeployer.DefaultDestination;
        try
        {
            var modCount = ModFiles.ExtractTo(dlcModDir);
            log($"Deployed {modCount} mod files to {dlcModDir}.");
        }
        catch (Exception ex)
        {
            // Best-effort: if DLC isn't writable for some reason, log
            // it but don't fail the install. User can re-deploy
            // manually or re-run install. Most users have Steam DLC
            // dir writable to their account.
            log($"Mod deploy to {dlcModDir} failed: {ex.Message}. " +
                "Install completed but the mod won't load until files are placed there.");
        }

        IfeoInstaller.Install(installedLauncher);
        log("Registered IFEO redirect for CivilizationVI.exe and CivilizationVI_DX12.exe.");

        // Register in Windows Apps & Features so users can uninstall
        // via Settings UI rather than needing to find a terminal.
        try
        {
            AppsAndFeaturesRegistration.Register(
                installDir: destDir,
                launcherExePath: installedLauncher,
                version: SemVer.Current().ToString());
            log("Registered in Apps & Features.");
        }
        catch (Exception ex)
        {
            // Non-fatal: the launcher still works, just isn't listed
            // in Settings → Apps. User can still --uninstall manually.
            log($"Apps & Features registration failed: {ex.Message}. " +
                "Uninstall via terminal will still work.");
        }

        speak("Civ VI Access installed.");
    }

    public static void Uninstall(Action<string> log, Action<string> speak)
    {
        if (!IfeoInstaller.IsRunningElevated())
        {
            // TaskDialog with explicit verb-labelled buttons. Previously
            // an OK/Cancel MessageBox — same Yes/No ambiguity the
            // Already-Installed dialog had before migration. Keep
            // labels self-documenting so screen readers and sighted
            // users both know what each button does at click time.
            const int ID_UNINSTALL = 1;
            const int ID_CANCEL = 2;
            var confirm = Dialogs.ShowChoice(
                title: "Civilization VI Access — Uninstall",
                mainInstruction: "Uninstall Civ VI Access from this computer?",
                content:
                    "This will:\n" +
                    "  • Remove the Steam-launch redirect (Civilization VI will launch directly again)\n" +
                    "  • Remove the Civ VI Access mod from Civ VI's DLC directory\n" +
                    "  • Remove the Apps & Features registration\n" +
                    "  • Leave installed files at " + DefaultInstallDir + " in place\n" +
                    "    (delete that folder manually if you want a complete cleanup)\n\n" +
                    "Clicking Uninstall will prompt for administrator permission (Windows UAC).",
                choices: new[]
                {
                    new Dialogs.ChoiceButton(ID_UNINSTALL, "Uninstall Civ VI Access",
                        "Remove the redirect, mod files, and Apps & Features entry."),
                    new Dialogs.ChoiceButton(ID_CANCEL, "Cancel",
                        "Exit without making any changes."),
                },
                defaultChoiceId: ID_CANCEL,
                warningIcon: true);
            if (confirm != ID_UNINSTALL)
            {
                speak("Uninstall cancelled.");
                log("Uninstall cancelled by user at confirm dialog.");
                return;
            }

            // If we're running from inside the install dir (the A&F-
            // invoked uninstall scenario: Windows runs
            // "C:\Program Files\Civ VI Access\CivViAccess.exe" --uninstall),
            // the elevated child would lock the install dir and prevent
            // full cleanup. Stage a copy of ourselves to %TEMP% and
            // re-exec the elevated child from there so the install dir
            // is free to be deleted.
            //
            // When the user runs the launcher from Downloads or any
            // other path (e.g., they downloaded a fresh installer .exe
            // and double-clicked it), this staging is unnecessary and
            // we skip it.
            var currentExe = Environment.ProcessPath
                ?? throw new InvalidOperationException("Cannot determine current exe path.");
            var installedExe = Path.Combine(DefaultInstallDir, LauncherExeName);
            bool runningFromInstallDir = string.Equals(
                Path.GetFullPath(currentExe),
                Path.GetFullPath(installedExe),
                StringComparison.OrdinalIgnoreCase);

            string exeToRelaunch = currentExe;
            if (runningFromInstallDir)
            {
                try
                {
                    var tempDir = Path.Combine(Path.GetTempPath(), "CivViAccessUninstall");
                    Directory.CreateDirectory(tempDir);
                    var tempExe = Path.Combine(tempDir, LauncherExeName);
                    File.Copy(currentExe, tempExe, overwrite: true);
                    log($"Staged uninstaller copy to {tempExe} so install dir can be cleaned up.");
                    exeToRelaunch = tempExe;
                }
                catch (Exception ex)
                {
                    log($"Could not stage uninstaller copy: {ex.Message}. " +
                        "Falling back to in-place elevation; install dir will not be removed.");
                }
            }

            RelaunchElevated(exeToRelaunch, "--uninstall");
            Environment.Exit(0);
        }

        IfeoInstaller.Uninstall();
        log("Removed IFEO redirect for CivilizationVI.exe and CivilizationVI_DX12.exe.");

        // Remove the Apps & Features entry so Civ VI Access no longer
        // shows up in Settings → Installed Apps.
        try
        {
            AppsAndFeaturesRegistration.Unregister();
            log("Removed Apps & Features registration.");
        }
        catch (Exception ex)
        {
            log($"Apps & Features unregister failed: {ex.Message}. " +
                "Entry may remain in Settings but won't function.");
        }

        // Remove the deployed mod from Civ VI's DLC dir. Without this,
        // a follow-up reinstall might mix old mod files with new ones,
        // and an uninstall would leave Civ VI loading the mod anyway
        // (since the .modinfo would still be present, even though
        // accessibility output would be unrouted with the launcher gone).
        var dlcModDir = ModDeployer.DefaultDestination;
        if (Directory.Exists(dlcModDir))
        {
            try
            {
                Directory.Delete(dlcModDir, recursive: true);
                log($"Removed mod files from {dlcModDir}.");
            }
            catch (Exception ex)
            {
                log($"Could not remove {dlcModDir}: {ex.Message}. " +
                    "Civ VI may still load the mod's manifest but with no launcher routing speech.");
            }
        }

        // Remove the install dir itself. The non-elevated path stages
        // a copy of the launcher to %TEMP% before elevating in the
        // running-from-install-dir case, so the elevated child here is
        // never the locked installed exe — it's either the temp-staged
        // copy (A&F path) or a copy started from somewhere else
        // (Downloads / fresh installer / etc). Directory.Delete with
        // recursive=true takes the launcher exe, Tolk DLLs, launcher.ini
        // if present, and any other content.
        bool installDirCleaned = false;
        try
        {
            if (Directory.Exists(DefaultInstallDir))
            {
                Directory.Delete(DefaultInstallDir, recursive: true);
                log($"Removed install directory {DefaultInstallDir}.");
                installDirCleaned = true;
            }
            else
            {
                // Didn't exist — treat as cleaned for completion-dialog
                // wording purposes; nothing left to leave behind.
                installDirCleaned = true;
            }
        }
        catch (Exception ex)
        {
            log($"Could not remove install dir {DefaultInstallDir}: {ex.Message}. " +
                "Files may remain; delete the folder manually if desired.");
        }

        speak("Civ VI Access uninstalled.");

        var leftInPlaceLine = installDirCleaned
            ? ""
            : "\nNot removed (could not be deleted):\n" +
              "  • Launcher files at " + DefaultInstallDir + "\n" +
              "    (delete that folder manually to finish cleanup)\n";

        Dialogs.ShowInfo(
            "Civilization VI Access — Uninstall Complete",
            "Civ VI Access has been uninstalled.\n\n" +
            "Civilization VI will now launch directly from Steam again — the access " +
            "mod will not activate.\n\n" +
            "Cleaned up:\n" +
            "  • Steam launch redirect (IFEO)\n" +
            "  • Apps & Features registration\n" +
            "  • Mod files in Civ VI's DLC directory\n" +
            (installDirCleaned ? "  • Launcher files at " + DefaultInstallDir + "\n" : "") +
            leftInPlaceLine + "\n" +
            "Click OK to finish.");
    }

    private static void RelaunchElevated(string exe, string arg)
    {
        var psi = new ProcessStartInfo
        {
            FileName = exe,
            UseShellExecute = true,   // required for runas
            Verb = "runas",
            Arguments = arg,
        };
        try { Process.Start(psi); }
        catch (System.ComponentModel.Win32Exception)
        {
            // User declined the UAC prompt. Nothing to do — the parent
            // process exits via Environment.Exit at the call site.
        }
    }
}
