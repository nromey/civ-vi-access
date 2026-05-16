using System.Text.RegularExpressions;

namespace CivVIAccess.Launcher;

public class AccessibleOutputOptionReader
{
    public record Result(bool NoInterrupt = false);

    private readonly Regex optionsRegex = new Regex(@"#SCREENREADER\[(.+?)\]");

    public Result GetOptionsFrom(string line)
    {
        bool noInterrupt = false;
        
        if (optionsRegex.IsMatch(line))
        {
            var groups = optionsRegex.Match(line).Groups;
            if (groups.Count < 2)
            {
                return new Result();
            }

            var optionsString = groups[1].Value;
            var optionsStringItems = optionsString.Split(',');
            foreach (var item in optionsStringItems)
            {
                if (item.Trim().ToUpper() == "NOINTERRUPT")
                {
                    noInterrupt = true;
                }
            }
        }

        return new Result(NoInterrupt: noInterrupt);
    }
}