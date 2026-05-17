using System.Text.RegularExpressions;
using Camm.Speech;

namespace CivVIAccess.Launcher.Speech;

// Civ VI Access mod-side convention: speech-bound log lines contain
// the literal "#SCREENREADER" marker, optionally followed by a
// bracket-delimited option list (e.g. `[NOINTERRUPT]`). The Lua mod
// emits lines via Civ VI's print() into Lua.log; the launcher tails
// the log and routes any line matching this protocol to Tolk.
//
// Implements CAMM's IScreenReaderMarkerProtocol seam.
public sealed class CivViScreenReaderMarkerProtocol : IScreenReaderMarkerProtocol
{
    public string MarkerPrefix => "#SCREENREADER";

    private static readonly Regex OptionsRegex = new(@"#SCREENREADER\[(.+?)\]");

    public bool ContainsMarker(string line) => line.Contains(MarkerPrefix);

    public SpeechOptions ParseOptions(string line)
    {
        bool noInterrupt = false;

        if (OptionsRegex.IsMatch(line))
        {
            var groups = OptionsRegex.Match(line).Groups;
            if (groups.Count >= 2)
            {
                var optionsString = groups[1].Value;
                var items = optionsString.Split(',');
                foreach (var item in items)
                {
                    if (item.Trim().ToUpperInvariant() == "NOINTERRUPT")
                    {
                        noInterrupt = true;
                    }
                }
            }
        }

        return new SpeechOptions(NoInterrupt: noInterrupt);
    }
}
