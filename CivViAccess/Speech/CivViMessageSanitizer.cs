using System.Text.RegularExpressions;
using Camm.Speech;

namespace CivVIAccess.Launcher.Speech;

// Civ VI's in-engine markup vocabulary for screen-reader-bound log
// lines. Strips the `WORD: #SCREENREADER[opts] - ` line prefix,
// removes [ICON_*] markup, replaces [NEWLINE] with comma-space (so
// multi-line announcements speak as one phrase), and drops [COLOR:*]
// + [ENDCOLOR] color tags.
//
// Implements CAMM's IMessageSanitizer seam — every mod that does
// log-tail speech provides its own sanitizer for its game's markup.
public sealed class CivViMessageSanitizer : IMessageSanitizer
{
    private const string ScreenReaderMarker = "#SCREENREADER";

    // Order-preserved map of regex → replacement. Built into a single
    // alternation regex below for one-pass matching.
    private static readonly Dictionary<string, string> SanitizationRegexMap = new()
    {
        { $@"^\w+\: {ScreenReaderMarker}\[.+?\] - ", string.Empty },
        { $@"^\w+\: {ScreenReaderMarker} - ", string.Empty },
        { @"\[ICON_\w+\]", " " },
        { @"[-]{2,}\[NEWLINE\]", string.Empty },
        { @"\[NEWLINE\]", ", " },
        { @"\[COLOR:\w+\]", string.Empty },
        { @"\[ENDCOLOR\]", string.Empty },
    };

    private static readonly Regex SanitizationRegex = new Regex(
        string.Join("|", SanitizationRegexMap.Keys.Select(k => $"({k})")),
        RegexOptions.Compiled);

    public string Sanitize(string raw)
    {
        return SanitizationRegex.Replace(raw, match => Evaluate(match));
    }

    private static string Evaluate(Match match)
    {
        for (int i = 1; i < match.Groups.Count; i++)
        {
            var group = match.Groups[i];
            if (group.Success)
            {
                return SanitizationRegexMap.ElementAt(i - 1).Value;
            }
        }
        throw new ArgumentException("Match found that doesn't have any successful groups");
    }
}
