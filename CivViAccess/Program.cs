using Camm;
using CivVIAccess.Launcher;
using CivVIAccess.Launcher.Speech;

// Civ VI Access launcher entry point. Builds the CAMM manifest and
// hands the whole launcher lifecycle to CammHost.RunAsync — apply-
// pending-update, Tolk bootstrap, args dispatch (--install /
// --uninstall / --version / --config / --install-from-wizard /
// --wizard-test), transparent invocation, bare-exe install trigger,
// update check, game launch, log-tail speech, lifecycle watch. The
// per-game hooks (Civ VI exe path, Lua.log path, EULA-aware launch
// announcement, "Civilization VI closed.") live in CivViGameInstance.
return await CammHost.RunAsync(args, new CammModManifest
{
    LocalAppDataFolderName = "CivVIAccess",
    LauncherExeName = "CivViAccess.exe",
    LauncherAssetNamePattern = "CivViAccess-{0}.exe",
    GitHubReleasesOwner = "nromey",
    GitHubReleasesRepo = "civ-vi-access",
    UserAgent = "CivVIAccess.Launcher",
    IfeoTargetExeNames = new[] { "CivilizationVI.exe", "CivilizationVI_DX12.exe" },
    GameProcessNames = new[] { "CivilizationVI", "CivilizationVI_DX12" },
    ModPayloadFolderName = "CivViAccessMod",
    ModPayloadSentinelFileName = "CivViAccessMod.modinfo",
    ModPayloadDefaultDestination = () =>
        @"C:\Program Files (x86)\Steam\steamapps\common\Sid Meier's Civilization VI\DLC\CivViAccessMod",
    AppsAndFeaturesKeyName = "CivVIAccess",
    DisplayName = "Civ VI Access",
    Publisher = "Noel Romey",
    ProjectUrl = "https://github.com/nromey/civ-vi-access",
    TargetGameDisplayName = "Civilization VI",
    TargetGameLauncherName = "Steam",
    Sanitizer = new CivViMessageSanitizer(),
    MarkerProtocol = new CivViScreenReaderMarkerProtocol(),
    GameInstance = new CivViGameInstance(),
});
