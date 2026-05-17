using Camm;

namespace CivVIAccess.Launcher;

// Civ VI-specific implementation of CAMM's IGameInstance hook.
// Provides:
//   - The hardcoded Steam install path to Civilization VI (DX11
//     variant; the DX12 variant gets caught by IFEO instead and
//     reaches CammHost via transparent invocation)
//   - The Lua.log path under %LocalAppData%\Firaxis Games\Sid Meier's
//     Civilization VI\Logs\ that CAMM's LogTailSpeaker tails
//   - First-launch-aware launch announcement (uses UserOptions.txt's
//     `CopyrightAccept` line to detect whether the user has accepted
//     the EULA; on first launch the announcement explains the intro
//     cinematic + EULA-press-Enter flow)
//   - The post-exit closed-announcement string
public sealed class CivViGameInstance : IGameInstance
{
    private const string SteamDefaultExe =
        @"C:\Program Files (x86)\Steam\steamapps\common\Sid Meier's Civilization VI\Base\Binaries\Win64Steam\CivilizationVI.exe";

    public string? FindGameExe() => SteamDefaultExe;

    public string GetLogFilePath() =>
        Path.Join(GameUserDir, "Logs", "Lua.log");

    public string GetLaunchAnnouncement()
    {
        if (HasEulaBeenAccepted())
        {
            return "Launching Sid Meier's Civilization VI.";
        }
        return
            "Launching Sid Meier's Civilization VI for the first time. " +
            "The 2K and Firaxis logos and an intro cinematic will play " +
            "for a while. After that, an end user license agreement " +
            "screen will appear; press Enter to accept it. The main " +
            "menu will load after acceptance.";
    }

    public string GetClosedAnnouncement() =>
        "Sid Meier's Civilization VI closed.";

    private static string GameUserDir => Path.Join(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Firaxis Games", "Sid Meier's Civilization VI");

    // Civ VI writes UserOptions.txt under its user-data dir; one of
    // the lines is `CopyrightAccept <version>` once the user has
    // accepted the EULA. Missing file or missing/empty value = first
    // launch (or first launch since reset).
    private static bool HasEulaBeenAccepted()
    {
        var userOptionsPath = Path.Join(GameUserDir, "UserOptions.txt");
        if (!File.Exists(userOptionsPath)) return false;
        try
        {
            foreach (var line in File.ReadAllLines(userOptionsPath))
            {
                const string prefix = "CopyrightAccept ";
                if (line.StartsWith(prefix, StringComparison.Ordinal))
                {
                    var value = line.Substring(prefix.Length).Trim();
                    return value.Length > 0;
                }
            }
        }
        catch { /* first-launch verbose path is the safe fallback */ }
        return false;
    }
}
