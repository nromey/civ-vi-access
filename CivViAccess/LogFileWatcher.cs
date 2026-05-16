using System.Text;

namespace CivVIAccess.Launcher;

public sealed class LogFileWatcher
{
    private Mediator mediator;

    public LogFileWatcher(Mediator mediator)
    {
        this.mediator = mediator;
    }

    public Task WaitForLogFileToExist(string luaLogFilePath, CancellationToken? cancellationToken = null)
    {
        // Poll at 250ms so a brief Civ VI lifecycle event (the engine
        // appears to delete and recreate Lua.log on first-launch / clean-
        // install paths, possibly as part of "no EULA accepted yet" reset
        // behavior) doesn't leave the launcher parked in "File no longer
        // found, waiting..." for up to 10 seconds while the file is
        // actually already back. 250ms is responsive enough that the user
        // hears at most one beat of silence before speech resumes.
        while (cancellationToken?.IsCancellationRequested != true)
        {
            if (File.Exists(luaLogFilePath))
            {
                return Task.CompletedTask;
            }

            Thread.Sleep(250);
        }

        // this is a catch all for anything that isn't covered by the cancellation token throwing
        return Task.FromException(new ApplicationException($"Unable to load log file {luaLogFilePath}"));
    }

    public async void WatchLogFile(string filePath, long preLaunchSize)
    {
        // Choose the read cursor so we replay nothing from prior sessions
        // (Tolk firing every #SCREENREADER line in the last 1KB on attach
        // was deafening). preLaunchSize is the file's size captured at
        // launcher startup, before Civ VI was spawned:
        //   * If the file is now SMALLER, Civ VI truncated it on boot — a
        //     fresh session. Start at 0 so we catch every line this run.
        //   * Otherwise the engine appended; start at preLaunchSize so we
        //     replay only this session's writes.
        // The previous rewind-1024 logic was meant to catch messages
        // emitted between log-file-creation and watcher-attach; this
        // approach covers that race AND avoids replaying historical lines.
        var currentSize = new FileInfo(filePath).Length;
        var lastReadLength = currentSize < preLaunchSize ? 0L : preLaunchSize;

        while (true)
        {
            try
            {
                var fileSize = new FileInfo(filePath).Length;
                if (fileSize > lastReadLength)
                {
                    using (var fs = new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                    {
                        fs.Seek(lastReadLength, SeekOrigin.Begin);
                        var buffer = new byte[1024];

                        while (true)
                        {
                            var bytesRead = fs.Read(buffer, 0, buffer.Length);
                            lastReadLength += bytesRead;

                            if (bytesRead == 0)
                                break;

                            var text = ASCIIEncoding.ASCII.GetString(buffer, 0, bytesRead);

                            this.mediator.Output(text);
                        }
                    }
                }
            }
            catch (FileNotFoundException)
            {
                this.mediator.OutputText("File no longer found: Waiting for file to exist again...");
                await this.WaitForLogFileToExist(filePath);
                this.mediator.OutputText("Log file found. Watching...");
                // File reappeared mid-session (rare — manual delete, log
                // rotation, etc.). Reset to read from the start since
                // whatever's there is new.
                lastReadLength = 0L;
            }
            catch (Exception e)
            {
                this.mediator.OutputTextError("Error: " + e.Message);
            }

            Thread.Sleep(200);
        }
    }

}
