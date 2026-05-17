# Install Wizard Rewrite — Design Plan

Captured 2026-05-16. Drives the implementation in a future session.
Self-contained: a reader who hasn't been in the originating
conversation can execute this plan from the doc alone.

## Why this rewrite

The current install flow uses a series of TaskDialogs (Welcome →
Update Channel picker → Ready-to-Install → UAC → Install →
Completion) added in 0.1.10 when we migrated off MessageBox. That
migration was a real improvement over plain Yes/No buttons, but the
chained-dialog shape is non-standard and required encoding things
like "Continue to update channel selection" into button labels
because TaskDialog has no concept of Next/Back. The flow felt
custom rather than familiar.

The replacement is a standard WinForms install wizard with
Next / Back / Cancel buttons on each page — the InstallShield /
Setup-Wizard pattern every Windows user knows. Familiarity
reduces friction; Back enables recovery from mistakes without
re-running the installer.

This wizard is also the canonical install UX for the future CAMM
(Chameleon Access Mod Manager) extraction. Every CAMM-built mod's
installer will use the same wizard pattern. So the design choices
here aren't just for Civ VI Access — they template the install
experience for the broader product family.

## Design decisions (locked)

1. **Architecture: single `Form` with swapping pages.** One main
   window stays open the whole time; page contents swap in/out via
   `UserControl` replacement inside a host `Panel`. Title bar
   stable, page header changes. (vs option B which was sequential
   `Form` objects opening/closing — choppier visually.)

2. **5 pages**: Welcome, Update channel, Ready to install,
   Installing, Done. (Could fold Welcome + Channel into one page,
   but keeping them separate is cleaner.)

3. **Cancel-confirm dialog on every Cancel click**, even with
   Back available. Standard installer convention — InstallShield,
   Inno Setup, MSI installers all confirm before exit.

## What does NOT change

- `Installer.Install()`'s elevated path — the actual install work
  (file copy, IFEO register, A&F register, mod extract). Wizard
  just gathers inputs then calls into this unchanged.
- `Installer.Uninstall()` — keeps TaskDialog (single binary
  confirm; doesn't benefit from a wizard shape).
- IFEO registration, mod deploy, A&F registration, all backend
  install steps.
- The release workflow (`.github/workflows/release.yml`) — still
  tag-push triggered, still signed via Azure Trusted Signing.
- All one-shot dialogs that aren't part of install flow:
  Already-Installed dialog (Program.cs), Settings Modify entry,
  Update channel-only popup. Stay TaskDialog. Mixed paradigm by
  design: wizards for multi-step linear flows, TaskDialogs for
  one-shot decisions.

## File structure

New files under `CivViAccess/Wizard/`:

- `InstallWizardForm.cs` — the main Form, hosts the page-swap
  panel and the bottom button bar (Back / Next / Install / Cancel
  / Finish — buttons enabled/disabled per page state).
- `IWizardPage.cs` — interface that every page UserControl
  implements:
  - `string Title { get; }` — appears as the page header
  - `void OnEnter(InstallContext context)` — called when page
    becomes visible; receives the shared context object
  - `void OnLeave(InstallContext context)` — called when leaving
    (forward via Next or backward via Back); page writes its
    state into context
  - `bool CanGoNext { get; }` — whether Next button is enabled
    (e.g., false until a required selection is made)
  - `event EventHandler CanGoNextChanged` — page raises when its
    `CanGoNext` flips, so the host enables/disables the Next
    button without polling
- `InstallContext.cs` — shared mutable state passed between
  pages: `UpdateChannel SelectedChannel`, `bool IsFirstInstall`,
  result fields, etc.
- `WelcomePage.cs` — page 1
- `ChannelPage.cs` — page 2
- `ReadyPage.cs` — page 3
- `InstallingPage.cs` — page 4
- `DonePage.cs` — page 5

## Page-by-page spec

### Page 1: Welcome

- Heading: `Install Civilization VI Access`
- Subhead (visible only when `IsFirstInstall == true`):
  `by Noel Romey, version 0.X.Y`
- Body: brief description of what install does + the UAC heads-up
  ("Windows will prompt for administrator permission later in this
  installer")
- Buttons: [Next] [Cancel] — Back disabled

### Page 2: Update channel

- Heading: `Update channel`
- Combobox: Stable (default selection), Latest, Off
- Per-option description Label that updates when selection
  changes (e.g., picking Stable shows "Tested releases only.
  Safest, gets new features after they've been validated.")
- Buttons: [Back] [Next] [Cancel]
- On `OnLeave` (forward), writes the chosen channel to
  `InstallContext.SelectedChannel`
- `CanGoNext` always true (default selection means a valid value
  is always picked)

### Page 3: Ready to install

- Heading: `Ready to install`
- Summary block showing the install location (read from
  `Installer.DefaultInstallDir`) and the chosen channel (read from
  context)
- Note: "Clicking Install will prompt for administrator permission.
  You can change the update channel later from Windows Settings →
  Apps → Installed Apps → Civ VI Access → Modify."
- Buttons: [Back] [Install] [Cancel]
- Install button text replaces the usual Next; same action
  semantics (go forward), different label so the user knows the
  next click commits.

### Page 4: Installing

- Heading: `Installing...`
- Marquee-mode progress bar (install is ~2 seconds; no useful
  percentage to track)
- Status Label updated as each install step runs:
  - "Copying launcher to Program Files..."
  - "Deploying mod files to Civ VI's DLC directory..."
  - "Registering Steam launch redirect..."
  - "Registering in Apps & Features..."
- All buttons disabled while this page is active
- `OnEnter` triggers the elevated install (current
  `Installer.Install()` logic, with the elevated child reporting
  progress via... TBD: probably IPC or a shared file the wizard
  watches, since the elevated child is a separate process). For
  MVP this can just show the marquee for the duration without
  per-step status — refinement once base wizard works.
- On install success, auto-advances to Page 5
- On install failure, switches to an error display + enables a
  Close button

### Page 5: Done

- Heading: `Install complete`
- Body: summary of what was installed + how to use ("Launch
  Civilization VI from Steam, the accessibility mod activates
  automatically. Settings: %LocalAppData%\CivVIAccess\
  launcher.ini")
- Buttons: [Finish] — no Cancel/Back (you're done; nothing to
  cancel)
- Finish closes the wizard

## Cancel flow

Every page **except** Page 4 (Installing) and Page 5 (Done) has a
Cancel button. Click triggers a confirm using
`Dialogs.ShowChoice` (reuse existing helper):

- Title: `Cancel installation?`
- Main instruction: `Are you sure you want to cancel?`
- Body: `Nothing has been installed yet. You can come back to the
  installer any time.`
- Choices (command-link buttons):
  - `Continue installing` (default — Esc maps here)
  - `Yes, cancel and exit`

If user picks Cancel-and-exit, close the wizard, no install
happens. If Continue, stay on current page.

## Accessibility plan

- Every input has both a visual `Label` AND `AccessibleName` set
- Tab order set explicitly via `TabIndex` on each page
- First focusable control on each page is the primary input
  (combobox on Channel page, Install button on Ready page) — NOT
  the heading. The heading is announced as page changes via Tolk
  (consistent with the current pattern).
- Accelerator keys via `&` in button text: `&Next`, `&Back`,
  `&Cancel`, `&Install`, `&Finish`
- Headings are `Label` controls with
  `AccessibleRole = AccessibleRole.Heading`
- On page change, Tolk speaks the new page title (e.g.,
  "Update channel, page 2 of 5")
- Tested against NVDA at each page before that page lands

## Build / project changes

- Add `<UseWindowsForms>true</UseWindowsForms>` to
  `CivViAccess.csproj`. WinForms is AOT-compatible in .NET 10
  with this property set.
- Expect exe size to grow from ~7.5 MB to ~13-15 MB (acceptable;
  modern installers commonly ship 50-200 MB).
- `app.manifest` already declares `PerMonitorV2` DPI awareness, so
  wizard renders crisp on high-DPI displays.

## Implementation order

1. **Scaffold**: add WinForms enable + `InstallWizardForm` shell +
   `IWizardPage` interface + empty `WelcomePage` (shows just
   "Welcome") + button bar. Minimum viable wizard that does
   nothing. Verify it compiles + runs + dismisses.
2. **Wire Page 1 (Welcome)** to the existing `Installer.Install()`
   non-elevated entry — wizard's Next on Welcome calls into the
   old TaskDialog chain for everything past it. Proves the wizard
   can replace the entry point.
3. **Page 2 (Channel)** + **Page 3 (Ready)** built and replace
   the corresponding TaskDialog steps in the install flow. Now
   wizard runs pages 1-3, then hands off to the elevated install.
4. **Page 4 (Installing)** + **Page 5 (Done)** for the post-UAC
   experience. The elevated install needs to report back to the
   wizard somehow — initial implementation can be "elevated
   process writes status to a file the wizard polls", or just
   "wait for elevated process exit and show Done page". Refine
   over time.
5. **Cancel-confirm dialog** wiring on each page.
6. **NVDA pass** — test each page with screen reader, fix label /
   tab-order / focus issues.
7. **Replace the current TaskDialog install flow** in
   `Installer.Install()`'s non-elevated path with
   `new InstallWizardForm().ShowDialog()`. Delete the now-unused
   TaskDialog install code paths.
8. **Bundle in 0.2.0** along with related work in the same
   release: speech-cutoff fix in update flow, mod-zip release
   asset for fast mod-only auto-updates, welcome-page publisher
   name on first install.

## Estimated scope

200-400 lines of C# across 6 new files in `Wizard/`, plus
modifications to `Installer.cs` and the csproj. Probably 2-3
focused sessions to land, including NVDA testing and polish.

## Open questions for the implementation session

- How does the elevated install process report progress back to
  the wizard for Page 4's status label? Named pipe? Polled file?
  Or skip per-step status for MVP and just show marquee for the
  full duration?
- Cancel-on-Installing-page: can we? Probably not safely once
  elevation has been granted and files are mid-copy. Document
  that the Cancel button stops being available on Page 4.
- Localization architecture: per [[project-launcher-localization-gap]],
  CAMM will need per-locale JSON for launcher strings. The wizard
  is the natural place to introduce this since every label is
  user-facing text. Decide whether to ship the wizard with
  hardcoded English strings (deferring localization to CAMM
  extraction) or to introduce the JSON loader in this work.
  Defer to CAMM extraction is simpler.
