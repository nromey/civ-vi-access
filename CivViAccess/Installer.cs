using System.Diagnostics;
using System.Runtime.Versioning;

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

    // Run from any directory (dev build, downloaded zip, wherever). We
    // copy ourselves + sidecars to DefaultInstallDir, then register
    // IFEO. Idempotent — running twice is safe and refreshes the files.
    public static void Install(Action<string> log, Action<string> speak)
    {
        if (!IfeoInstaller.IsRunningElevated())
        {
            // Welcome dialog BEFORE UAC. TaskDialog command-link buttons
            // give us literal verb labels — "Continue" / "Exit installer"
            // — instead of the OK/Cancel that MessageBox would force.
            // Screen readers announce the verbs, sighted users don't
            // have to scan the body to figure out which button does
            // what.
            const int ID_CONTINUE = 1;
            const int ID_EXIT = 2;
            var welcome = Dialogs.ShowChoice(
                title: "Civilization VI Access — Install",
                mainInstruction: "Install Civilization VI Access on this computer?",
                content:
                    "After install, launching Civilization VI from Steam (or any " +
                    "shortcut) will automatically activate the screen-reader " +
                    "accessibility mod.\n\n" +
                    "The installer will:\n" +
                    "  • Copy launcher files to " + DefaultInstallDir + "\n" +
                    "  • Deploy mod files to Civ VI's DLC directory\n" +
                    "  • Register Steam-launch redirect (so launches activate the mod)\n" +
                    "  • Register in Apps & Features (for easy uninstall later)\n\n" +
                    "You will be prompted to grant administrator permission (Windows " +
                    "UAC) at the end, after you choose your update channel.",
                choices: new[]
                {
                    new Dialogs.ChoiceButton(ID_CONTINUE, "Continue to update channel selection",
                        "Pick your update channel next, then confirm and install."),
                    new Dialogs.ChoiceButton(ID_EXIT, "Exit installer",
                        "Close this installer without making any changes."),
                },
                defaultChoiceId: ID_CONTINUE);
            if (welcome != ID_CONTINUE)
            {
                speak("Install cancelled.");
                log("Install cancelled by user at welcome dialog.");
                return;
            }

            // Channel picker BEFORE elevation so the user's choice can
            // be persisted to launcher.ini (in %LocalAppData%, user-
            // writable) without needing admin. The elevated install
            // process will then read this setting later when launches
            // happen.
            var currentSettings = LauncherSettings.LoadOrCreate(LauncherSettings.DefaultPath);
            var picked = Dialogs.ShowChannelPicker(currentSettings.UpdateChannel);
            UpdateChannel effectiveChannel;
            if (picked is UpdateChannel choice)
            {
                currentSettings.UpdateChannel = choice;
                try { currentSettings.Save(LauncherSettings.DefaultPath); }
                catch (Exception ex) { log($"Could not save update channel: {ex.Message}"); }
                log($"Update channel set to: {choice}");
                effectiveChannel = choice;
            }
            else
            {
                log($"Update channel unchanged (still {currentSettings.UpdateChannel}).");
                effectiveChannel = currentSettings.UpdateChannel;
            }

            // Explicit commit-step confirmation before UAC. The welcome
            // dialog described what would happen in the abstract; the
            // channel picker collected a setting. Neither said "and now
            // I'm going to start the install." Without this, the user
            // picks a channel and the next thing they see is a UAC
            // prompt — a surprising handoff that conflates configure
            // with commit. TaskDialog with literal "Install" /
            // "Cancel installation" buttons makes the next click
            // unambiguous; cancel triggers a second confirm because
            // this is the last point before UAC and accidentally
            // bailing means re-running the whole flow.
            const int ID_INSTALL = 1;
            const int ID_CANCEL_INSTALL = 2;
            while (true)
            {
                var ready = Dialogs.ShowChoice(
                    title: "Civilization VI Access — Ready to Install",
                    mainInstruction: "Ready to install. Click Install to continue.",
                    content:
                        "Settings:\n" +
                        "  • Install location: " + DefaultInstallDir + "\n" +
                        "  • Update channel: " + effectiveChannel + "\n\n" +
                        "Clicking Install will prompt for administrator permission " +
                        "(Windows UAC). You can change the update channel later from " +
                        "Windows Settings → Apps → Installed Apps → Civ VI Access " +
                        "→ Modify.",
                    choices: new[]
                    {
                        new Dialogs.ChoiceButton(ID_INSTALL, "Install",
                            "Apply these settings and start installation."),
                        new Dialogs.ChoiceButton(ID_CANCEL_INSTALL, "Cancel installation",
                            "Don't install. Exit without making any changes."),
                    },
                    defaultChoiceId: ID_INSTALL);

                if (ready == ID_INSTALL) break;

                // Confirm cancel — this is the last commit point, and
                // an accidental click here means re-launching the
                // installer from scratch. Give one chance to back out
                // of the cancel.
                const int ID_REALLY_CANCEL = 1;
                const int ID_RETURN = 2;
                var confirmCancel = Dialogs.ShowChoice(
                    title: "Civilization VI Access — Cancel Installation?",
                    mainInstruction: "Cancel installation and exit?",
                    content:
                        "Nothing has been installed yet. If you exit now, no changes " +
                        "will be made to your computer.",
                    choices: new[]
                    {
                        new Dialogs.ChoiceButton(ID_RETURN, "Go back to install",
                            "Return to the Ready to Install screen."),
                        new Dialogs.ChoiceButton(ID_REALLY_CANCEL, "Yes, cancel and exit",
                            "Exit the installer without installing."),
                    },
                    defaultChoiceId: ID_RETURN);
                if (confirmCancel == ID_REALLY_CANCEL)
                {
                    speak("Install cancelled.");
                    log("Install cancelled by user at ready-to-install confirmation.");
                    return;
                }
                // else loop and re-show the Ready dialog
            }

            RelaunchSelfElevated("--install");
            Environment.Exit(0);
        }

        // Elevated path: do the actual work, then show the TaskDialog
        // completion dialog. The wizard-driven install reuses
        // ApplyInstall directly (its own Done page handles completion
        // UX, so it skips the TaskDialog).
        ApplyInstall(log, speak);

        var installedLauncher = Path.Combine(DefaultInstallDir, LauncherExeName);
        Dialogs.ShowInfo(
            "Civilization VI Access — Install Complete",
            "Civ VI Access has been installed successfully.\n\n" +
            "To use the mod: launch Civilization VI from Steam as you normally would. " +
            "The accessibility mod will start automatically each time.\n\n" +
            "Installation location: " + DefaultInstallDir + "\n" +
            "Settings file: " + DefaultInstallDir + "\\launcher.ini\n\n" +
            "To uninstall later: run\n" +
            "    \"" + installedLauncher + "\" --uninstall\n\n" +
            "Click OK to finish.");
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

    private static void RelaunchSelfElevated(string arg)
    {
        var exe = Environment.ProcessPath
            ?? throw new InvalidOperationException("Cannot determine current exe path.");
        RelaunchElevated(exe, arg);
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
