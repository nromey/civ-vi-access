using System.Text.RegularExpressions;
using Camm;
using DavyKager;

namespace CivVIAccess.Launcher;

public sealed class AccessibleOutputHandler
{
    private readonly AccessibleOutputOptionReader optionReader;

    private static readonly string screenReaderMarker = "#SCREENREADER";

    private static readonly Dictionary<string, string> sanitizationRegexMap = new Dictionary<string, string>
    {
        { $@"^\w+\: {screenReaderMarker}\[.+?\] - ", string.Empty },
        { $@"^\w+\: {screenReaderMarker} - ", string.Empty },
        { @"\[ICON_\w+\]", " " },
        { @"[-]{2,}\[NEWLINE\]", string.Empty },
        { @"\[NEWLINE\]", ", " },
        { @"\[COLOR:\w+\]", string.Empty },
        { @"\[ENDCOLOR\]", string.Empty }
    };
    private static readonly Regex sanitizationRegex = new Regex(string.Join("|", sanitizationRegexMap.Keys.Select(k => $"({k})")), RegexOptions.Compiled);

    private DateTime lastNonInterruptableMessage = DateTime.MinValue;
    private static readonly TimeSpan nonInterruptTime = TimeSpan.FromSeconds(3);

    public AccessibleOutputHandler(AccessibleOutputOptionReader optionReader)
    {
        this.optionReader = optionReader;
        Tolk.TrySAPI(true);
        Tolk.Load();
    }

    public void Speak(string text, bool interrupt = true)
    {
        Tolk.Output(text, interrupt);
    }

    public void OutputMessage(string message)
    {
        var lines = message.Split('\n');

        foreach (var line in lines)
        {
            if (line.Contains(screenReaderMarker))
            {
                var options = this.optionReader.GetOptionsFrom(line);
                bool interrupt = !options.NoInterrupt;

                if (!interrupt)
                {
                    this.lastNonInterruptableMessage = DateTime.UtcNow;
                }
                else
                {
                    interrupt = DateTime.UtcNow >= this.lastNonInterruptableMessage.Add(nonInterruptTime);
                }

                var sanitized = SanitizeLine(line);
                Logger.Info($"OutputMessage forwarding to Tolk (interrupt={interrupt}): '{sanitized}'");
                var ok = Tolk.Output(sanitized, interrupt);
                Logger.Info($"  Tolk.Output returned {ok}");
            }
        }
    }

    private static string SanitizeLine(string line)
    {
        return sanitizationRegex.Replace(line, match => RegexEvaluate(match));
    }

    private static string RegexEvaluate(Match match)
    {
        for (int i = 1; i < match.Groups.Count; i++)
        {
            var group = match.Groups[i];
            if (group.Success)
            {
                return sanitizationRegexMap.ElementAt(i - 1).Value;
            }
        }

        throw new ArgumentException("Match found that doesn't have any successful groups");
    }

}
