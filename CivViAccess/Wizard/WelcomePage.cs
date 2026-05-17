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

    private static string SubheadText() =>
        "by Noel Romey, version " + SemVer.Current();

    private readonly Label _subhead;
    private bool _subheadVisible;

    public string Title => "Welcome";
    public bool CanGoNext => true;
    public string AnnouncementText
    {
        get
        {
            var sub = _subheadVisible ? SubheadText() + ". " : "";
            return HeadingText + ". " + sub + BodyText;
        }
    }

    // null = host uses its default (Next button). Welcome has no
    // input control to focus, so Next is the right initial target.
    public Control? InitialFocusControl => null;

    // No-op accessors: this page never raises these events, but the
    // interface requires the members. Empty add/remove satisfies the
    // contract without triggering CS0067 on an unraised field event.
    public event EventHandler? CanGoNextChanged { add { } remove { } }
    public event EventHandler? AdvanceRequested { add { } remove { } }

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

        // Subhead: "by Noel Romey, version X.Y.Z". Only shown on a
        // genuine first install — hidden on reinstall/update because
        // those users already know who built this. OnEnter flips
        // _subhead.Visible based on context.IsFirstInstall.
        _subhead = new Label
        {
            Text = SubheadText(),
            Font = new System.Drawing.Font("Segoe UI", 9F, System.Drawing.FontStyle.Italic),
            ForeColor = System.Drawing.SystemColors.GrayText,
            AutoSize = true,
            Location = new System.Drawing.Point(24, 60),
            AccessibleName = SubheadText(),
            AccessibleRole = AccessibleRole.StaticText,
            Visible = false,
        };

        var body = new Label
        {
            Text = BodyText,
            AutoSize = false,
            Location = new System.Drawing.Point(24, 100),
            Size = new System.Drawing.Size(500, 200),
            AccessibleName = BodyText,
            AccessibleRole = AccessibleRole.StaticText,
        };

        Controls.Add(heading);
        Controls.Add(_subhead);
        Controls.Add(body);
    }

    public void OnEnter(InstallContext context)
    {
        _subheadVisible = context.IsFirstInstall;
        _subhead.Visible = _subheadVisible;
    }

    public void OnLeave(InstallContext context) { }
}
