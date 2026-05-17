using System.Runtime.Versioning;
using System.Windows.Forms;
using DavyKager;

namespace CivVIAccess.Launcher.Wizard;

// Host Form for the install wizard. Stays open through the entire
// install flow; pages swap in/out of _pageHost via UserControl
// replacement. The bottom button bar is owned here; pages only
// influence button state via CanGoNext + CanGoNextChanged.
//
// Architecture decision (locked in WIZARD_PLAN.md): single Form +
// UserControl swap, not sequential Form objects opening/closing.
[SupportedOSPlatform("windows")]
public sealed class InstallWizardForm : Form
{
    private readonly Panel _pageHost;
    private readonly Button _btnBack;
    private readonly Button _btnNext;
    private readonly Button _btnCancel;
    private readonly List<IWizardPage> _pages = new();
    private readonly InstallContext _context = new();
    private int _index = -1;
    private System.Windows.Forms.Timer? _speakTimer;

    public InstallWizardForm()
    {
        Text = "Civilization VI Access Setup";
        ClientSize = new System.Drawing.Size(560, 420);
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MinimizeBox = false;
        MaximizeBox = false;

        _pageHost = new Panel { Dock = DockStyle.Fill };
        Controls.Add(_pageHost);

        // Button bar pinned bottom. Order Back / Next / Cancel left-
        // to-right matches Windows InstallShield convention.
        var buttonBar = new Panel { Dock = DockStyle.Bottom, Height = 48 };

        // CAMM attribution footer. Mandatory across all CAMM-built
        // installers (see project_camm_architecture_v0 memory) — the
        // branding pays for the reusable framework. Lives on the host
        // form so every page inherits it without per-page work.
        var footer = new Label
        {
            Text = "Powered by CAMM — Chameleon Access Mod Manager",
            Dock = DockStyle.Bottom,
            Height = 22,
            TextAlign = System.Drawing.ContentAlignment.MiddleCenter,
            Font = new System.Drawing.Font("Segoe UI", 8F, System.Drawing.FontStyle.Italic),
            ForeColor = System.Drawing.SystemColors.GrayText,
            AccessibleName = "Powered by CAMM, the Chameleon Access Mod Manager",
        };
        // TabIndex makes Tab cycle Next → Cancel → Back (Back becomes
        // reachable when enabled on page 2+). Next gets the lowest
        // index because it's the primary action on every page; Cancel
        // is always second so users can dismiss quickly from keyboard.
        _btnCancel = new Button
        {
            Text = "&Cancel",
            Width = 90,
            Top = 10,
            Left = 450,
            TabIndex = 1,
            DialogResult = DialogResult.Cancel,
            AccessibleName = "Cancel",
        };
        _btnNext = new Button
        {
            Text = "&Next",
            Width = 90,
            Top = 10,
            Left = 354,
            TabIndex = 0,
            AccessibleName = "Next",
        };
        _btnBack = new Button
        {
            Text = "&Back",
            Width = 90,
            Top = 10,
            Left = 258,
            TabIndex = 2,
            AccessibleName = "Back",
        };
        buttonBar.Controls.Add(_btnBack);
        buttonBar.Controls.Add(_btnNext);
        buttonBar.Controls.Add(_btnCancel);
        // Docking order: WinForms processes Dock.Bottom controls in
        // reverse Z-order (highest Z first against the edge). Adding
        // footer BEFORE buttonBar gives buttonBar the very bottom edge
        // (last-added → highest Z → docks first) and pushes footer up
        // to sit just above the buttons.
        Controls.Add(footer);
        Controls.Add(buttonBar);

        CancelButton = _btnCancel;
        AcceptButton = _btnNext;

        _btnBack.Click += (_, _) => Navigate(-1);
        _btnNext.Click += (_, _) => Navigate(+1);
        // Cancel-confirm dialog wires in step 5 of WIZARD_PLAN.md;
        // for the scaffold, plain Close is fine.
        _btnCancel.Click += (_, _) => Close();

        AddPage(new WelcomePage());
        AddPage(new ChannelPage());
        // UI-only show during construction. ActivatePage (in OnShown
        // and Navigate) drives OnEnter + focus + Tolk speak — keeping
        // those out of the constructor avoids speaking before the
        // form is visible AND avoids racing NVDA's own focus event.
        ShowPageUi(0);
    }

    private void AddPage(IWizardPage page)
    {
        _pages.Add(page);
        // Subscribe once per page lifetime, then dispatch only to the
        // active page. Avoids double-subscription when the user goes
        // Back and we re-show an existing page.
        page.CanGoNextChanged += (s, _) =>
        {
            if (_index >= 0 && ReferenceEquals(_pages[_index], s)) UpdateButtons();
        };
    }

    private void Navigate(int delta)
    {
        if (_index < 0) return;
        _pages[_index].OnLeave(_context);
        var target = _index + delta;
        if (target < 0 || target >= _pages.Count)
        {
            // Past the last page: closes the form. Becomes Finish-
            // wiring once DonePage lands (step 4 of WIZARD_PLAN.md).
            Close();
            return;
        }
        ShowPageUi(target);
        ActivatePage();
    }

    // UI-only swap: install the page UserControl, update the button bar,
    // and place initial focus. Does NOT call OnEnter or fire the Tolk
    // announcement — those run later in ActivatePage so the form is
    // already visible and NVDA's own focus event has fired first.
    private void ShowPageUi(int newIndex)
    {
        _index = newIndex;
        var page = _pages[_index];
        _pageHost.Controls.Clear();
        if (page is UserControl uc)
        {
            uc.Dock = DockStyle.Fill;
            _pageHost.Controls.Add(uc);
        }
        UpdateButtons();
        SetPageFocus();
    }

    // Fires the page lifecycle: OnEnter + delayed Tolk announcement.
    // Called from OnShown for the first page and from Navigate for
    // subsequent transitions, AFTER the form is visible.
    private void ActivatePage()
    {
        if (_index < 0) return;
        var page = _pages[_index];
        page.OnEnter(_context);
        DelayedSpeak(page.AnnouncementText);
    }

    private void UpdateButtons()
    {
        _btnBack.Enabled = _index > 0;
        _btnNext.Enabled = _pages[_index].CanGoNext;
    }

    // Initial focus per page. Page-specific override (combobox on
    // Channel, Install button on Ready, etc.) via InitialFocusControl;
    // falls back to Next when enabled, Cancel otherwise. Set
    // ActiveControl when the form isn't visible yet (constructor
    // path) and Focus() once it is. WIZARD_PLAN.md accessibility
    // plan: "First focusable control on each page is the primary
    // input — NOT the heading."
    private void SetPageFocus()
    {
        var fallback = _btnNext.Enabled ? _btnNext : (Control)_btnCancel;
        var target = (_index >= 0 ? _pages[_index].InitialFocusControl : null) ?? fallback;
        if (IsHandleCreated && Visible) target.Focus();
        else ActiveControl = target;
    }

    // Delayed speak via a UI Timer. The 250ms gap lets NVDA process
    // its own focus / window-shown announcements first; our
    // interrupt=true call then wipes those and speaks the page
    // content cleanly. Without the delay, NVDA's focus event fires
    // AFTER our Tolk.Output and the user only hears "Next button".
    //
    // Reusing one timer instance means a fast page change (Back-then-
    // Next) cancels the pending speak instead of stacking two.
    private void DelayedSpeak(string text)
    {
        _speakTimer?.Stop();
        _speakTimer?.Dispose();
        _speakTimer = new System.Windows.Forms.Timer { Interval = 250 };
        _speakTimer.Tick += (_, _) =>
        {
            _speakTimer?.Stop();
            _speakTimer?.Dispose();
            _speakTimer = null;
            try
            {
                var ok = Tolk.Output(text, true);
                Logger.Info($"InstallWizardForm.DelayedSpeak: " +
                    $"Tolk.Output returned {ok}, len={text.Length}");
            }
            catch (Exception ex)
            {
                Logger.Exception("InstallWizardForm.DelayedSpeak: Tolk.Output threw", ex);
            }
        };
        _speakTimer.Start();
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        // Form is now visible and focus is on Next (via ActiveControl
        // from the constructor's SetPageFocus). Re-Focus to refresh
        // the system's focus event, then fire OnEnter + delayed Tolk
        // for the first page.
        SetPageFocus();
        ActivatePage();
    }

    // Entry point for callers. WinForms requires an STA thread; the
    // launcher's main thread is MTA because top-level statements
    // can't carry [STAThread]. Spawn a dedicated UI thread, run the
    // message loop there, and join when the form closes.
    public static void Run()
    {
        var ui = new Thread(() =>
        {
            ApplicationConfiguration.Initialize();
            Application.Run(new InstallWizardForm());
        });
        ui.SetApartmentState(ApartmentState.STA);
        ui.Start();
        ui.Join();
    }
}
