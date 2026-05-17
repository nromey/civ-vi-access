using System.Runtime.Versioning;
using System.Windows.Forms;

namespace CivVIAccess.Launcher.Wizard;

[SupportedOSPlatform("windows")]
public sealed class DonePage : UserControl, IWizardPage
{
    private const string HeadingText = "Install complete";
    private const string BodyText =
        "Civilization VI Access is installed.\r\n\r\n" +
        "Launch Civilization VI from Steam — the accessibility mod " +
        "activates automatically.\r\n\r\n" +
        "Per-user settings live at " +
        "%LocalAppData%\\CivVIAccess\\launcher.ini.";

    public string Title => "Done";
    public bool CanGoNext => true;
    public Control? InitialFocusControl => null;

    // Done page is the terminal step: no Back (the install already
    // happened — going back is meaningless), no Cancel (nothing left
    // to cancel). Finish is the only action.
    public bool ShowBackButton => false;
    public bool ShowCancelButton => false;
    public string NextButtonText => "&Finish";

    public string AnnouncementText => HeadingText + ". " + BodyText;

    public event EventHandler? CanGoNextChanged { add { } remove { } }
    public event EventHandler? AdvanceRequested { add { } remove { } }

    public DonePage()
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

        var body = new Label
        {
            Text = BodyText,
            AutoSize = false,
            Location = new System.Drawing.Point(24, 80),
            Size = new System.Drawing.Size(500, 200),
            AccessibleName = BodyText,
            AccessibleRole = AccessibleRole.StaticText,
        };

        Controls.Add(heading);
        Controls.Add(body);
    }

    public void OnEnter(InstallContext context) { }
    public void OnLeave(InstallContext context) { }
}
