using System.Runtime.Versioning;
using System.Windows.Forms;

namespace CivVIAccess.Launcher.Wizard;

[SupportedOSPlatform("windows")]
public sealed class InstallingPage : UserControl, IWizardPage
{
    private const string HeadingText = "Installing...";
    private const string StatusInitial = "Preparing to install...";

    private readonly Label _status;
    private readonly ProgressBar _progress;

    public string Title => "Installing";
    public bool CanGoNext => false;
    public Control? InitialFocusControl => null;

    // All buttons disabled during install — per WIZARD_PLAN.md page 4
    // spec. Cancel-during-install is not safe once elevation has been
    // granted and files are mid-copy; revisit if/when we add a
    // staged-rollback path.
    public bool ButtonsEnabled => false;

    public string AnnouncementText =>
        "Installing Civilization VI Access. Please wait.";

    public event EventHandler? CanGoNextChanged { add { } remove { } }
    public event EventHandler? AdvanceRequested;

    public InstallingPage()
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

        _status = new Label
        {
            Text = StatusInitial,
            AutoSize = false,
            Location = new System.Drawing.Point(24, 80),
            Size = new System.Drawing.Size(500, 30),
            AccessibleName = StatusInitial,
            AccessibleRole = AccessibleRole.StaticText,
        };

        // Marquee mode: the install is short (~2 seconds for file copy
        // + registry writes) and has no useful percent-complete to
        // report. The marquee gives visual "something is happening"
        // feedback without lying about progress.
        _progress = new ProgressBar
        {
            Style = ProgressBarStyle.Marquee,
            MarqueeAnimationSpeed = 30,
            Location = new System.Drawing.Point(24, 120),
            Size = new System.Drawing.Size(500, 20),
        };

        Controls.Add(heading);
        Controls.Add(_status);
        Controls.Add(_progress);
    }

    public void OnEnter(InstallContext context)
    {
        // Phase A (current): simulate install with a delay so the
        // full Welcome → Channel → Ready → Installing → Done flow can
        // be validated end-to-end. Phase B will wire to the real
        // non-interactive install logic extracted from Installer.cs.
        _ = Task.Run(async () =>
        {
            await Task.Delay(2000).ConfigureAwait(false);
            BeginInvoke(() =>
            {
                _status.Text = "Install complete.";
                _status.AccessibleName = _status.Text;
                AdvanceRequested?.Invoke(this, EventArgs.Empty);
            });
        });
    }

    public void OnLeave(InstallContext context) { }
}
