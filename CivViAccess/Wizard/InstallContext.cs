namespace CivVIAccess.Launcher.Wizard;

// Shared mutable state passed between wizard pages. Pages write their
// result fields in OnLeave; subsequent pages read in OnEnter. Plain
// mutable POCO — the wizard form is the only owner so there's no
// risk of stale-state bugs from external mutation.
public sealed class InstallContext
{
    public UpdateChannel SelectedChannel { get; set; } = UpdateChannel.Stable;
    public bool IsFirstInstall { get; set; } = true;
}
