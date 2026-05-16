namespace CivVIAccess.Launcher;

// Copies the mod source tree into Civ VI's DLC directory before the launcher
// spawns the game. Lets the dev loop be "edit source -> launch -> retest"
// instead of "edit source -> manually copy -> launch -> retest", which got
// painful within the first hour of multi-iteration testing.
//
// In a shipped installer the source tree won't sit next to the launcher
// exe; FindModSourceDir returns null in that case and Program.cs skips the
// deploy step, falling through to "use whatever the installer put in the
// DLC dir."
//
// Path discovery: walks parent directories from the launcher exe looking
// for a CivViAccessMod folder with a CivViAccessMod.modinfo file inside.
// That double-check (folder name + sentinel file) avoids confusing a
// random "CivViAccessMod" name match somewhere on disk.
public static class ModDeployer
{
    private const string ModDirName = "CivViAccessMod";
    private const string ModInfoFileName = "CivViAccessMod.modinfo";

    // Default Steam-install Civ VI DLC location. Matches the hardcoded
    // civVIPath in Program.cs; if/when that becomes configurable, this
    // does too.
    public const string DefaultDestination =
        @"C:\Program Files (x86)\Steam\steamapps\common\Sid Meier's Civilization VI\DLC\CivViAccessMod";

    public static string? FindModSourceDir()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            var candidate = Path.Combine(dir.FullName, ModDirName);
            if (File.Exists(Path.Combine(candidate, ModInfoFileName)))
            {
                return candidate;
            }
            dir = dir.Parent;
        }
        return null;
    }

    // Copy semantics: overwrite-only, never delete. Doing a true mirror
    // (delete dest-only files) would be tempting for cleanliness but
    // operates on a path inside Program Files; a bug in the path
    // discovery + a delete pass is how user data gets shredded. Stale
    // files left behind in DLC are harmless — Civ VI only loads what the
    // modinfo references — so leaving them is the safer default.
    public static int Deploy(string sourceDir, string destDir)
    {
        Directory.CreateDirectory(destDir);
        var copied = 0;
        foreach (var src in Directory.EnumerateFiles(sourceDir, "*", SearchOption.AllDirectories))
        {
            var relative = Path.GetRelativePath(sourceDir, src);
            var dest = Path.Combine(destDir, relative);
            var destFolder = Path.GetDirectoryName(dest);
            if (destFolder is not null)
            {
                Directory.CreateDirectory(destFolder);
            }
            File.Copy(src, dest, overwrite: true);
            copied++;
        }
        return copied;
    }
}
