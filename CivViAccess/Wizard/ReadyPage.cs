using System.Runtime.Versioning;
using System.Windows.Forms;

namespace CivVIAccess.Launcher.Wizard;

[SupportedOSPlatform("windows")]
public sealed class ReadyPage : UserControl, IWizardPage
{
    private const string HeadingText = "Ready to install";
    private const string NoteText =
        "Clicking Install will prompt for administrator permission. " +
        "You can change the update channel later from " +
        "Windows Settings → Apps → Installed Apps → " +
        "Civ VI Access → Modify, or by re-running this installer.";

    private readonly Label _summary;
    private string _spokenSummary = string.Empty;

    public string Title => "Ready to install";
    public bool CanGoNext => true;
    public Control? InitialFocusControl => null;
    public string NextButtonText => "&Install";
    public event EventHandler? CanGoNextChanged { add { } remove { } }
    public event EventHandler? AdvanceRequested { add { } remove { } }

    public string AnnouncementText =>
        HeadingText + ". " + _spokenSummary + " " + NoteText;

    public ReadyPage()
    {
        Dock = DockStyle.Fill;

        var heading = new Label
        {
            Text = HeadingText,
            Font = new System.Drawing.Font("Segoe UI", 14F, System.Drawing.FontStyle.Bold),
            AutoSize = true,
            Location = new System.Drawing.Point(24, 24),
            AccessibleName = HeadingText,
            AccessibleRole = AccessibleRole.StaticText,
        };

        // Summary block: install location + chosen channel. Populated
        // in OnEnter from the InstallContext so a Back-then-forward
        // round-trip reflects any channel change the user just made.
        _summary = new Label
        {
            AutoSize = false,
            Location = new System.Drawing.Point(24, 80),
            Size = new System.Drawing.Size(500, 80),
            AccessibleRole = AccessibleRole.StaticText,
        };

        var note = new Label
        {
            Text = NoteText,
            AutoSize = false,
            Location = new System.Drawing.Point(24, 180),
            Size = new System.Drawing.Size(500, 120),
            AccessibleName = NoteText,
            AccessibleRole = AccessibleRole.StaticText,
        };

        Controls.Add(heading);
        Controls.Add(_summary);
        Controls.Add(note);
    }

    public void OnEnter(InstallContext context)
    {
        // Visible summary is two lines; the spoken version flattens
        // them into one phrase for Tolk so AnnouncementText reads
        // naturally end-to-end.
        var dir = Installer.DefaultInstallDir;
        var channel = context.SelectedChannel;
        _summary.Text =
            "Install location: " + dir + "\r\n" +
            "Update channel: " + channel;
        _summary.AccessibleName =
            "Install location " + dir + ". Update channel " + channel + ".";
        _spokenSummary = _summary.AccessibleName;
    }

    public void OnLeave(InstallContext context) { }
}
