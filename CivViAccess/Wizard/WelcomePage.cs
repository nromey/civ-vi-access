using System.Runtime.Versioning;
using System.Windows.Forms;

namespace CivVIAccess.Launcher.Wizard;

[SupportedOSPlatform("windows")]
public sealed class WelcomePage : UserControl, IWizardPage
{
    private const string HeadingText = "Install Civilization VI Access";
    private const string BodyText =
        "This installer will copy the launcher to Program Files " +
        "and register Civilization VI Access with Windows.\r\n\r\n" +
        "Windows will prompt for administrator permission later " +
        "in this installer.";

    public string Title => "Welcome";
    public bool CanGoNext => true;
    public string AnnouncementText => HeadingText + ". " + BodyText;

    // null = host uses its default (Next button). Welcome has no
    // input control to focus, so Next is the right initial target.
    public Control? InitialFocusControl => null;

    // No-op accessor: this page never disables Next, so it has no
    // state change to report. Satisfies the interface without
    // triggering CS0067 on an unraised event field.
    public event EventHandler? CanGoNextChanged { add { } remove { } }

    public WelcomePage()
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
