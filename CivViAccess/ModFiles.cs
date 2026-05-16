namespace CivVIAccess.Launcher;

// Extract embedded mod files (the CivViAccessMod source tree) into a
// target directory. Companion to TolkBootstrap.ExtractTo — same embedded-
// resource pattern, different prefix.
//
// Why this exists: the installer needs to put the mod's Lua + XML files
// in Civ VI's DLC dir at install time, but the installer doesn't have
// access to the source repo at run-time on a user's machine. Bundling
// the mod source as embedded resources solves it — one .exe contains
// everything needed to install both the launcher AND the mod.
//
// Mod is ~640 KB across ~21 files. Native AOT compiles them in as
// binary blobs. Resource names look like `mod/Assets/UI/Accessibility/
// ScreenReader.lua`, preserving the on-disk directory structure so
// ExtractTo can reconstruct the tree under any target dir.
//
// On uninstall, the caller is responsible for removing the deployed
// directory — see Installer.Uninstall.
public static class ModFiles
{
    private const string ResourcePrefix = "mod/";

    // Extract all embedded mod files into targetDir, preserving the
    // source tree's directory layout. Overwrites existing files (so
    // install-over-install reliably refreshes mod content).
    //
    // Returns the count of files written. Caller can log it for sanity.
    public static int ExtractTo(string targetDir)
    {
        Directory.CreateDirectory(targetDir);
        var asm = typeof(ModFiles).Assembly;
        int written = 0;

        foreach (var resourceName in asm.GetManifestResourceNames())
        {
            if (!IsModResource(resourceName)) continue;

            // Strip the "mod/" prefix and normalize separators to OS-
            // native. Resource names use forward-slash from the
            // LogicalName MSBuild metadata, but Windows file APIs work
            // with either — Path.Combine handles both fine.
            var relative = StripPrefix(resourceName).Replace('\\', '/');
            if (string.IsNullOrEmpty(relative)) continue;

            var destPath = Path.Combine(
                targetDir,
                relative.Replace('/', Path.DirectorySeparatorChar));

            var destFolder = Path.GetDirectoryName(destPath);
            if (destFolder is not null) Directory.CreateDirectory(destFolder);

            using var stream = asm.GetManifestResourceStream(resourceName);
            if (stream is null) continue;
            try
            {
                using var dest = File.Create(destPath);
                stream.CopyTo(dest);
                written++;
            }
            catch (IOException)
            {
                // File in use — extremely rare for mod assets (they're
                // not P/Invoke targets), but tolerate it without
                // aborting the whole install.
            }
        }
        return written;
    }

    private static bool IsModResource(string name) =>
        name.StartsWith(ResourcePrefix, StringComparison.OrdinalIgnoreCase)
        || name.StartsWith("mod\\", StringComparison.OrdinalIgnoreCase);

    private static string StripPrefix(string name)
    {
        if (name.StartsWith(ResourcePrefix, StringComparison.OrdinalIgnoreCase))
            return name.Substring(ResourcePrefix.Length);
        if (name.StartsWith("mod\\", StringComparison.OrdinalIgnoreCase))
            return name.Substring(4);
        return name;
    }
}
