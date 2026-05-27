using System.Text.RegularExpressions;
using Camm.Speech;

namespace CivVIAccess.Launcher.Speech;

// Civ VI Access mod-side convention: speech-bound log lines contain
// the literal "#SCREENREADER" marker followed by a bracket-delimited
// comma-separated option list. The Lua mod emits lines via Civ VI's
// print() into Lua.log; the launcher tails the log and routes any
// line matching this protocol to Tolk.
//
// Recognized bracket options:
//   NOINTERRUPT       Lua-side gateway decided this should queue
//                     behind in-flight speech (within its own VM).
//   kind=<name>       Speech-priority classification. The launcher
//                     applies global cross-VM shielding via
//                     CivViSpeechShield — a critical-tier emit in
//                     the gameplay VM can downgrade a selection-tier
//                     emit in the addin VM that the Lua-side check
//                     couldn't see.
//
// Forms in the wild:
//   #SCREENREADER[kind=critical] - body              (post-shield)
//   #SCREENREADER[NOINTERRUPT,kind=meta] - body      (post-shield)
//   #SCREENREADER[NOINTERRUPT] - body                (legacy, pre-shield)
//   #SCREENREADER - body                             (legacy, pre-shield)
//
// Implements CAMM's IScreenReaderMarkerProtocol seam.
public sealed class CivViScreenReaderMarkerProtocol : IScreenReaderMarkerProtocol
{
    public string MarkerPrefix => "#SCREENREADER";

    private static readonly Regex OptionsRegex = new(@"#SCREENREADER\[(.+?)\]");
    private static readonly Regex KindOptionRegex = new(@"^\s*kind\s*=\s*(\S+?)\s*$");

    // Cross-VM shield state. One instance, lives the lifetime of the
    // launcher process; sees every #SCREENREADER line from every Lua
    // VM the game runs.
    private readonly CivViSpeechShield _shield = new();

    public bool ContainsMarker(string line) => line.Contains(MarkerPrefix);

    public SpeechOptions ParseOptions(string line)
    {
        bool noInterrupt = false;
        string? kind = null;

        if (OptionsRegex.IsMatch(line))
        {
            var optionsString = OptionsRegex.Match(line).Groups[1].Value;
            foreach (var rawItem in optionsString.Split(','))
            {
                var item = rawItem.Trim();
                if (item.Equals("NOINTERRUPT", StringComparison.OrdinalIgnoreCase))
                {
                    noInterrupt = true;
                    continue;
                }
                var kindMatch = KindOptionRegex.Match(item);
                if (kindMatch.Success)
                {
                    kind = kindMatch.Groups[1].Value;
                }
            }
        }

        // Apply cross-VM shield. The Lua-side gateway already decided
        // whether this emit should interrupt within its own VM; the
        // shield may further downgrade interrupt → NOINTERRUPT if a
        // higher-priority kind fired recently in some OTHER VM. Never
        // upgrades: if Lua said queue, we keep queue (Lua's same-VM
        // view is more nuanced than ours for that case).
        if (kind is not null)
        {
            var shouldDowngrade = _shield.ShouldDowngradeToQueue(kind);
            if (shouldDowngrade && !noInterrupt)
            {
                noInterrupt = true;
            }
        }

        return new SpeechOptions(NoInterrupt: noInterrupt);
    }
}
