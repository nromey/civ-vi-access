using static System.Console;

namespace CivVIAccess.Launcher;

public sealed class TextOutputHandler
{
    public void OutputLine(string message) => WriteLine(message);
    public void OutputErrorLine(string message) => Error.WriteLine(message);
}
