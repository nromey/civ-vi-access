using System.Windows.Forms;

namespace CivVIAccess.Launcher.Wizard;

// Contract every wizard page UserControl implements. The host form
// drives transitions via OnEnter/OnLeave; pages signal Next-eligibility
// via CanGoNext + CanGoNextChanged so the host doesn't poll.
//
// AnnouncementText is what the host Tolk-speaks when this page becomes
// active. Keeping speech orchestration in the host (with a small delay
// so NVDA's focus event fires first) means pages don't each re-invent
// the timing dance.
//
// InitialFocusControl is the control that should receive focus when the
// page becomes active — combobox on Channel, Install button on Ready,
// etc. Return null to fall back to the host's default (Next button when
// enabled, Cancel otherwise).
public interface IWizardPage
{
    string Title { get; }
    string AnnouncementText { get; }
    Control? InitialFocusControl { get; }
    bool CanGoNext { get; }
    event EventHandler? CanGoNextChanged;
    void OnEnter(InstallContext context);
    void OnLeave(InstallContext context);
}
