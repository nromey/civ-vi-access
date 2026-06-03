using System.Net;
using System.Runtime.Versioning;
using System.Text;
using System.Text.RegularExpressions;
using Camm;

namespace CivVIAccess.Launcher.Report;

// The launcher half of the report bridge. Subscribes (via the CAMM
// manifest's LogLineObserver seam) to every line the log-tail reads, and
// reassembles the mod's report stream into HTML for the ReportWindow
// (which renders it in an Edge app-mode browser window — see ReportWindow).
//
// Wire protocol — the mod emits these via print() into Lua.log; the
// engine prefixes each with "Context: ", so we match the marker
// anywhere in the line, not just at the start:
//
//   #SHOWREPORT[begin] - <title>     start a report; body is its title
//   #SHOWREPORT[chunk] - <fragment>  one HTML body fragment (concatenated
//                                     verbatim — the mod splits long bodies
//                                     into multiple chunks with no separator
//                                     so we just append)
//   #SHOWREPORT[end]                 render the accumulated body + show window
//
// Chunking exists because a single Civ VI print is one log line; framing
// the body as many small marker lines sidesteps any per-line length cap
// and the engine prefix that every print carries. The mod ships HTML
// *body* content only; the accessible page shell (semantic structure,
// readable typography, light/dark via prefers-color-scheme) is applied
// here so every report looks consistent and the mod stays simple.
//
// Lives entirely in CivViAccess (the locked "build the report stack in
// the launcher first, extract to CAMM once it's shaken out" decision).
[SupportedOSPlatform("windows")]
public sealed class ReportBridge
{
    private const string Marker = "#SHOWREPORT";

    // [opts] then an optional " - body". opts is the first []-group after
    // the marker; body is everything after the first "] - " to end of line.
    private static readonly Regex MarkerRegex = new(
        @"#SHOWREPORT\[(?<opts>[^\]]*)\](?:\s*-\s*(?<body>.*))?",
        RegexOptions.Compiled);

    // Guard rail: a browser handles large files fine, but no real report
    // approaches this. If a runaway stream blows past it we truncate and
    // render what we have rather than buffering without bound.
    private const int MaxBodyChars = 1_500_000;

    private readonly StringBuilder _body = new();
    private bool _capturing;
    private bool _truncated;
    private string _title = "Civ VI Access";
    private bool _orphanWarned;

    // Registered as CammModManifest.LogLineObserver. Runs on the log-tail
    // background thread; must not block (ReportWindow.Show writes the file
    // and launches the browser without waiting on the child, returning
    // promptly).
    public void OnLogLine(string chunk)
    {
        if (string.IsNullOrEmpty(chunk) || chunk.IndexOf(Marker, StringComparison.Ordinal) < 0)
        {
            return;  // fast path: the vast majority of lines aren't ours
        }

        foreach (var line in chunk.Split('\n'))
        {
            if (line.IndexOf(Marker, StringComparison.Ordinal) < 0) continue;
            HandleMarkerLine(line);
        }
    }

    private void HandleMarkerLine(string line)
    {
        var match = MarkerRegex.Match(line);
        if (!match.Success) return;

        var opts = match.Groups["opts"].Value;
        var body = match.Groups["body"].Success ? match.Groups["body"].Value : string.Empty;

        if (HasOpt(opts, "begin"))
        {
            _capturing = true;
            _truncated = false;
            _body.Clear();
            _title = string.IsNullOrWhiteSpace(body) ? "Civ VI Access" : body.Trim();
            return;
        }

        if (HasOpt(opts, "end"))
        {
            if (!_capturing)
            {
                WarnOrphan("end");
                return;
            }
            _capturing = false;
            Render(_title, _body.ToString());
            return;
        }

        if (HasOpt(opts, "chunk"))
        {
            if (!_capturing)
            {
                WarnOrphan("chunk");
                return;
            }
            if (!_truncated)
            {
                if (_body.Length + body.Length > MaxBodyChars)
                {
                    _body.Append(body, 0, Math.Max(0, MaxBodyChars - _body.Length));
                    _truncated = true;
                    Logger.Warn($"ReportBridge: report body exceeded {MaxBodyChars} chars; truncating.");
                }
                else
                {
                    _body.Append(body);
                }
            }
        }
    }

    private void Render(string title, string bodyHtml)
    {
        try
        {
            var html = BuildPage(title, bodyHtml);
            ReportWindow.Instance.Show(html, title);
            Logger.Info($"ReportBridge: rendered report '{title}' ({bodyHtml.Length} body chars).");
        }
        catch (Exception ex)
        {
            Logger.Exception("ReportBridge.Render failed", ex);
        }
    }

    // Comma-separated, case-insensitive token check ("begin" / "chunk" /
    // "end"; tolerant of future key=value options living alongside).
    private static bool HasOpt(string opts, string token)
    {
        foreach (var raw in opts.Split(','))
        {
            if (raw.Trim().Equals(token, StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
    }

    private void WarnOrphan(string which)
    {
        if (_orphanWarned) return;
        _orphanWarned = true;
        Logger.Warn($"ReportBridge: saw #SHOWREPORT[{which}] with no active [begin] " +
                    "(further occurrences silenced).");
    }

    // Wrap mod-supplied body HTML in an accessible page shell: a single
    // top-level <h1> for the title, readable typography, sane max width,
    // and automatic light/dark via prefers-color-scheme. The mod sends
    // body content only.
    private static string BuildPage(string title, string bodyHtml)
    {
        var safeTitle = WebUtility.HtmlEncode(title);
        return $$"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{safeTitle}}</title>
<style>
  :root { color-scheme: light dark; }
  body {
    font-family: "Segoe UI", system-ui, sans-serif;
    font-size: 18px;
    line-height: 1.5;
    margin: 0 auto;
    padding: 1.25rem 1.5rem 3rem;
    max-width: 60rem;
    color: #1a1a1a;
    background: #ffffff;
  }
  h1 { font-size: 1.6rem; margin: 0 0 1rem; }
  h2 { font-size: 1.3rem; margin: 1.5rem 0 0.5rem; }
  h3 { font-size: 1.1rem; margin: 1.2rem 0 0.4rem; }
  ul, ol { padding-left: 1.5rem; }
  li { margin: 0.2rem 0; }
  a { color: #0b5fff; }
  table { border-collapse: collapse; margin: 0.5rem 0; }
  th, td { border: 1px solid #888; padding: 0.3rem 0.6rem; text-align: left; }
  .muted { color: #555; }
  @media (prefers-color-scheme: dark) {
    body { color: #e8e8e8; background: #1b1b1b; }
    a { color: #6ea8ff; }
    th, td { border-color: #666; }
    .muted { color: #aaa; }
  }
</style>
</head>
<body>
<h1>{{safeTitle}}</h1>
{{bodyHtml}}
</body>
</html>
""";
    }
}
