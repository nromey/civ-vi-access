# Changelog

Reverse-chronological. Dates are when work landed, grouped by batch rather
than per-commit.

## Versioning

`0.1.x` was the pre-installer pre-release scheme — sequential build
numbers, bumped once per shipped batch. `0.2.0` shipped 2026-05-17 = the
install wizard rewrite (the installer + auto-update milestone the
scheme reserved this bump for). After 0.2.0 we resume sequential bumps
(0.2.1, 0.2.2, ...) per shipped batch until the next major-feature
milestone justifies `0.3.0` or `1.0.0`.

The same number lives in two places and must move together:

- This file's top entry.
- `<Version>` in `CivViAccess/CivViAccess.csproj` (drives the .exe
  `FileVersion` / `ProductVersion`; the release workflow overrides
  it via `-p:Version=<tag>` at publish time).

The `version="1"` attribute in `CivViAccessMod.modinfo` is the
Firaxis mod-system version, not ours — leave it alone.

## 0.5.4 — 2026-05-27 — Tech + civic pickers, help with type-to-filter, notification redesign

Builds on 0.5.3's picker scaffold. Tech and civic now have dedicated
modal pickers; help is its own addin with arrow nav, type-to-filter,
and engine-binding suppression; notifications cycle reflects the real
end-turn blocker instead of only what's in our cache.

### Tech picker (Alt+T) and civic picker (Alt+L)

`Assets/UI/Additions/TechPickerAddin.{lua,xml}` and `CivicPickerAddin.{lua,xml}`
clone the ProductionPicker shape. Both modal addins, both follow the same
contract: open via LuaEvent, list grouped by Available / Locked / Researched
(or Studying / Studied for civics), commit via `UI.RequestPlayerOperation`
with `PlayerOperations.RESEARCH` / `PROGRESS_CIVIC`.

Turn counts come from the engine's canonical APIs — `pPlayerTechs:GetTurnsToResearch(idx)`
and `pPlayerCulture:GetTurnsToProgressCivic(idx)` — not cost / yield division.
Civic version uses "Inspired" instead of "Boosted" and "Studying" instead of
"Researching" to match Civ VI's in-game vocabulary.

Alt+C wanted to be the civic key for mnemonic but Civ VI's engine consumes
bare-C as a World action; the Alt modifier didn't fall through. Moved to
Alt+L (for "law") instead.

Close path now resets `InterfaceModeTypes.SELECTION` and hides the addin
ContextPtr — fixes the case where Enter was blocked until the user pressed
Escape after picking a tech.

### HelpAddin — separate addin with arrow nav + type-to-filter

`Help.lua` previously lived inside the host handler (BaseMenu or HexCursor)
as a transient sub-mode. That worked for BaseMenu screens where raw keyboard
flowed naturally, but HexCursor dispatches via engine InputActions, not raw
keyboard — so arrow nav inside help never reached `Help.handleKey`.

Extracted into `Assets/UI/Additions/HelpAddin.{lua,xml}`. Its own UI VM,
its own ContextPtr, raw-keyboard `SetInputHandler`. Other contexts open it
by firing `LuaEvents.CivViAccess_OpenHelp(entries)` — the firing VM
collects entries from its own HandlerStack and marshals them across, since
HandlerStack is per-VM.

UX (mirrors Civ V Access's help-and-find pattern):

- `Up` / `Down` walk the list
- `Home` / `End` jump to first / last
- `Enter` / `Space` re-speak the current entry
- `Backspace` removes the last filter char (Esc with empty filter closes)
- Any letter / digit appends to a live filter — list narrows on every keystroke

No Ctrl+F mode switch. Filter and nav share the same mode because there's
no overlap between nav keys and printable input.

### Engine bare-letter suppression — `Input.PushActiveContext(GameOptions)`

Civ VI's engine binds bare letters (M=MoveTo, O=troop toggle, etc.) as
World-context InputActions. `ContextPtr:SetInputHandler(handler, true)`
does NOT suppress these — the InputAction system fires alongside our
raw-keyboard handler regardless. Confirmed via Noel test 2026-05-27:
typing "move" into the help filter was double-firing the engine's
MoveTo binding.

Fix: push `InputContext.GameOptions` on help open, pop on close. Mirrors
`Base/Assets/UI/Menus/InGameTopOptionsMenu.lua`'s pattern.

`InputContext` is NOT exposed in standalone `<AddUserInterfaces>` addin
VMs by default — only `Input.*` (the C++ API) is. But `InputContext` is
defined as a plain Lua table in `Base/Assets/UI/Scripts/InputSupport.lua`.
`include("InputSupport")` at the top of HelpAddin pulls it in — no
cross-VM bridge needed. (We tried a bridge through shadowed
NotificationPanel.lua first; addin VMs and shadowed-file InGame VMs do
NOT share LuaEvent tables, so the bridge never fired.)

### Addin VM keyboard delivery — three message types

Diagnostic 2026-05-27 revealed Civ VI delivers three message types to
the addin VM, each carrying different data:

- `KeyEvents.KeyDown` (msg=0): idiosyncratic VK code. Letters arrive
  as Ctrl+letter ASCII control codes (M→0x0D, O→0x0F, V→0x16, etc.).
  Unreliable for filter input.
- `KeyEvents.Character` (msg=2): the actual lowercase ASCII byte
  (m→0x6D, e→0x65, v→0x76). **Right path for filter input.**
- `KeyEvents.KeyUp` (msg=1): same idiosyncratic codes as KeyDown.
  Engine convention is to act on KeyUp to avoid auto-repeat fights.

HelpAddin handles `Character` for filter input, `KeyUp` for nav.
`KeyEvents.Character` may be nil in the addin VM even though msg=2
events still dispatch — literal-`2` fallback added.

Arrow keys with NumLock OFF arrive as numpad VK codes
(`VK_NUMPAD8`/`2`/`7`/`1`), not the regular `VK_UP`/`VK_DOWN`/`VK_HOME`/`VK_END`.
HelpAddin matches both conventions.

### Notification cycle redesign — engine-blocker-aware + read/unread

`Notifications.cycle` previously walked the in-VM cache only. Two
failure modes:

1. Cache empty but engine still blocking end-turn (e.g. fresh game,
   notification fired before our handler subscribed). User cycled,
   heard nothing, didn't know what was blocking.
2. Same-text refire while the engine assigned a new ID. Our dedup
   absorbed it into the canonical entry, but if the canonical was
   dismissed in the meantime, the new ID was orphaned. User had a
   blocker the cache didn't know about.

Fix 1: when cache empty, `synthesizeFromEngineBlocker(pid)` queries
`NotificationManager.GetFirstEndTurnBlocking(pid)` and emits a one-line
synthetic entry from the engine's blocker. Cycle is now always honest
about what's still blocking.

Fix 2: dedup now MIGRATES the existing entry to the new notification
ID instead of just refreshing the timestamp. Same-text refire keeps
the entry alive under whichever ID the engine currently knows.

Speech in chatty mode appends `, read` / `, unread` to each cycled
entry — matches the user's mental model of "what's left in my task
list before I can end turn."

### Verbosity binding in cursor mode (Alt+V)

`Verbosity.toggle()` was only reachable from BaseMenu screens. Added
`CIVVIACCESS_VerbosityToggle` engine action bound to Alt+V in
`RemapForHexCursor.xml` and a handler in HexCursorAddin so the user
can flip chatty / terse without leaving the world.

### Status kind always NOINTERRUPT

`Speech.emit(msg, "status")` was firing as INTERRUPT when no other
shield was active — "Loading complete" stomped on briefings, query
results stomped on each other. `status` is for follow-up / multi-line
continuation by definition; always NOINTERRUPT regardless of shield
state.

### Misc polish

- City-founded announce changed from "Press Enter to dismiss, then
  Shift+P" to "Press Shift+P to choose production, or Alt+P to
  auto-pick" — direct path, no dismiss step.
- "Ready to end turn" appends ", Press Enter to end turn" when
  Verbosity.isOn() (chatty mode hint for new players).
- Help icon strings stripped via the standard helper before speech.

## 0.5.3 — 2026-05-27 — Speech scheduler + cross-VM shield + production picker

Sea-change release. Three pieces shipped together because they
all converge on the same problem: speech that fires but doesn't
reach the user because something clobbered it.

### `Speech.emit(msg, kind)` — kind-classified speech gateway

Replaces `OutputMessageToScreenReader(msg, nointerrupt)`'s
boolean interrupt with a kind-classified gateway in
`Assets/UI/Accessibility/ScreenReader.lua`. Eight kinds with
per-kind priority, shield window (ms), and coalesce flag:

```
critical    pri 10  shield 2000ms  turn begin, city founded, victory
event       pri  8  shield 1500ms  Fortify, Building Monument, Quicksave
move_result pri  7  shield 1200ms  Moved west. 1 move remaining
picker      pri  6  shield  600ms  picker preamble, item nav
selection   pri  5  shield  400ms  unit / city selection
nav         pri  4  shield  200ms  cursor tile description
meta        pri  3  shield  100ms  keypress feedback, notification arrival
status      pri  2  no shield      query results, multi-line continuation
```

Decision per emit: if any other kind at >= my priority fired
within its shield, downgrade to NOINTERRUPT. Else if same kind
within own shield, interrupt iff `coalesce=true` (replace prior
in-flight); else queue. Else interrupt.

168 emit sites across 33 files migrated to `Speech.emit`. The
legacy `OutputMessageToScreenReader` stays as a back-compat shim
routing through `_legacy_interrupt` / `_legacy_queue` so any
unmigrated path still works.

### `CivViSpeechShield` — cross-VM shield in the launcher

Civ VI runs separate Lua VMs per Context (gameplay scripts vs
each UI addin). Each VM has its own `Speech._emitTime` table; a
critical-tier emit in the gameplay VM can't shield a selection-
tier emit in the addin VM, so back-to-back emits from different
VMs landed in Tolk as interrupts and clobbered. Confirmed in
Lua.log 2026-05-26: `World interactive. Press question mark for
help.` (gameplay VM, critical) → `Settler on Grassland (Hills).`
(gameplay VM, selection) → `Notification. Move a unit...`
(HexCursorAddin VM, meta) — three interrupt-tier lines back-to-
back; only the last was heard.

The launcher tails Lua.log, sees every `#SCREENREADER` line from
every VM, and re-runs the shield decision globally in C#. Each
log line now carries `kind=X` in the bracket; the protocol
parses it, asks `CivViSpeechShield`, and downgrades interrupt to
NOINTERRUPT before reaching Tolk if a higher-priority kind fired
in any VM. Within-VM gateway stays (defense in depth — launcher
may briefly lag reading the log).

Pinned CAMM bump to **v0.5.7** for the
`DisableStickyNoInterruptWindow` opt-in. Civ VI sets it `true`
now that per-kind shielding is in place; without it CAMM's
3-second post-NOINTERRUPT window over-dampens legitimate higher-
priority interrupts.

### Production picker (Stage 1)

Promoted out of "out of scope for 0.5.x" after speech-clobber
testing during the migration confirmed the picker design was
already functional in dev. Shipped as `ProductionPickerAddin`:

- BaseMenu shell, three tabs (Produce / Gold / Faith) with auto-
  hide of empty tabs, six groups per tab (Units / Districts /
  Buildings / Wonders / Projects / Queue) as flat-with-headers.
- Tab nav: Tab forward, PageUp / PageDown backward / forward.
- Group nav: Shift+PageUp / Shift+PageDown (slurp/burp-confirmed
  Shift modifier survives in PageUp / PageDown Civ VI input).
- Item nav: arrow up/down, Home / End for first/last.
- Activate: Enter / Space / Shift+Enter all commit. Esc closes.
- Long form: Ctrl+T expands description, yield delta, boost
  relevance, prerequisites, disabled reason — via engine's
  `ToolTipHelper`.
- Prev / next city: comma / period cycle target without leaving
  the picker.
- Commit via `CityManager.RequestOperation` with the right
  CityOperationTypes verb per kind (BUILD for units / buildings /
  districts, ADVANCE for projects).
- Disabled items announce the engine's tooltip reason in the
  label ("Settler — disabled, This city needs at least 2
  Population.").

Entry point: hotkey **Shift+P** opens the picker for the head-
selected city (fallback chain head-selected → capital → first).
Activating a `CHOOSE_CITY_PRODUCTION` notification from the
notification center also opens it (`NotificationPanel.lua` now
fires `LuaEvents.CivViAccess_OpenProductionPicker` with
notification-plot → head-selected → capital → first-city
resolution instead of the stale "not yet keyboard-accessible"
placeholder).

Tile placement for districts / wonders is deferred to a follow-
up (Section K/L of `docs/PICKER_DESIGN.md`); committing one of
those today fires the engine's normal placement mode which is
mouse-only. Tech and civic pickers also pending; design lives in
the same doc.

### Smaller fixes shipped in the same batch

- **FoundCity with 0-MP Settler**: engine silently refused but
  `speakAlways("Founding city. Press Enter to confirm.")` misled
  the user. `HexCursorAddin` now pre-checks `GetMovesRemaining()`
  before announcing; speaks "Cannot found city, no moves
  remaining. End the turn first." instead.
- **Reminder double-fire**: `Notifications.maybeFireReminder`
  now stamps `lastReminderAt` before `Speech.emit` so any
  reentrant call (where Speech.emit's `print()` triggers an
  engine event that loops back through `PublishComplete`) sees
  the updated timestamp and bails. Eliminates the "1 thing to
  do" double-fire observed in Lua.log 2026-05-26.
- **`_pending.startX`/`startY`** in `UnitMovement.lua` were
  referenced but never set — the "Move blocked" branch was dead
  code. Now records start coords at commit; `resolveAndSpeak`
  correctly distinguishes "didn't budge" (engine silently
  refused) from "moved partway" (terrain MP cost exhausted).
- **Stale "0.5.1 not accessible" text** in `NotificationPanel`
  removed; replaced with picker-LuaEvent dispatch.
- **Orientation hint string** in `CivVIAccessStrings.xml`: fix
  Shift → Alt typo for direct-move modifier, remove stale 0.5.1
  reference, mention Alt+P for the auto-unblock.

## 0.5.2 — 2026-05-25 — Notifications center + production unblock

Two pieces shipped together because both unblock end-turn-blocker
testing for blind players:

### `CityProduction.lua` (new, Alt+P) — end-turn blocker unblock

Civ VI gates end-turn on three mouse-only choosers
(`ProductionPanel`, `ResearchChooser`, `CivicsChooser`) — none
arrow-key navigable. Alt+P clears all three in one pass:

**Production** (per city with empty queue):
1. **Monument** (always-available, no prereqs, 60 prod) — canonical
   first-turn build.
2. **Warrior** — fallback for late-game / captured cities where
   Monument is already built.
3. **Cheapest available building or unit** — last-resort fallback.

**Research** (when player has no current tech): cheapest available
technology. Mirrors `ResearchChooser.lua:252` `OnChooseResearch`
(UI.RequestPlayerOperation, `PlayerOperations.RESEARCH`).

**Civic** (when player has no current civic): cheapest available
civic. Turn 1 = Code of Laws. Mirrors `CivicsChooser.lua:239`
`OnChooseCivic` (`PlayerOperations.PROGRESS_CIVIC`).

Per-item announce ("Queued Monument in Cape Town. Researching
Pottery. Studying Code of Laws."). `CIVVIACCESS_UnblockProduction`
InputAction bound to Alt+P (name is a holdover from when this
only handled production; kept for continuity). Hotkey stays as a
quick-default convenience even after the full pickers ship.

### `Notifications.lua` (extended) — notifications center (Stage 2)

The arrival-speech layer from 0.5.1 catches notifications as they
fire, but a burst can overrun the speech queue or land while the
user is away from the keyboard. The center adds a "task list"
persistence layer:

- **Cache** mirrors the engine's pending list (Civ VI exposes no
  global enumeration). Populated from `NotificationAdded`, drained
  from `NotificationDismissed`, marked-read from
  `NotificationActivated`.
- **Per-entry metadata**: blocker flag (`GetEndTurnBlocking ~=
  NO_ENDTURN_BLOCKING`), dismissable flag (`CanUserDismiss`),
  insertion timestamp.
- **`Ctrl+[` / `Ctrl+]`** walk prev/next pending. Sort priority:
  blockers first, then non-dismissable, then oldest-first. Speech
  is "Notification 2 of 3, blocker. Choose research." Mark-read
  on speak. Falls back to read entries if no unread remain.
- **Idle reminder**. After 20s of no user input AND pending > 0,
  plays a reminder earcon + speaks "N things to do". Exponential
  backoff (20s → 40s → 80s → cap at 5 min) so deliberately
  ignoring a notification doesn't get you yelled at. Backoff
  resets when a fresh notification arrives or any user hotkey
  fires (engagement signals).
- **`Alt+N`** toggles the reminder on/off, speaks new state. The
  per-feature toggle cluster (earcon on/off, chime-only vs
  chime+speech) is deferred to the options screen.

`Notifications.Initialize` is guarded against double-init (load
model can run the file from both AddGameplayScripts and addin
include, which would have caused double-speech).

Bare `[` / `]` (engine PrevCity / NextCity) deliberately NOT
stolen — `Ctrl+[/]` is free.

### `RemapForHexCursor.xml`

New InputActions + gestures:
- `CIVVIACCESS_UnblockProduction` → Alt+P
- `CIVVIACCESS_NotificationPrev` → Ctrl+[
- `CIVVIACCESS_NotificationNext` → Ctrl+]
- `CIVVIACCESS_NotificationReminderToggle` → Alt+N

### `HexCursorAddin.lua`

`include("CityProduction")` + `include("Notifications")`. Four new
`lookupAction` dispatches wired in the addin's action setup.

### `CivViAccessMod.modinfo`

Registered `CityProduction.lua` + `Notifications.lua` in both
`<ImportFiles>` (for `include()` resolution) and `<Files>`.
Notifications stays in `<AddGameplayScripts>` as it was in 0.5.1.

## 0.5.1 — 2026-05-25 — Notification polish (Stage 1)

**Stage 1 of the notifications work** — bug-fix layer ahead of Stage 2's
notifications center. See conversation 2026-05-25 for the full two-stage
design (cache + read/unread + idle reminder + toggles land in 0.5.2+).

### `Notifications.lua` (new)

`Assets/UI/Accessibility/Notifications.lua`. Owns the
`Events.NotificationAdded` subscription that previously lived bare in
`ScreenReaderEventHandlers.lua` (moved here so Stage 2's center can
share the same cache).

- **Dedup by `(playerID, notificationID)`** — the engine rebroadcasts
  undismissed notifications on load and around turn-end blockers; the
  bare handler would re-speak each one every rebroadcast wave.
- **200ms debounce** — bursts (war declared by N civs, multi-city
  events) collapse into one drain pass so the speech queue doesn't get
  flooded with N back-to-back lines that truncate each other.
- **500ms turn-start hold** — `LocalPlayerTurnBegin` arms a hold; drain
  blocks until expiry so the engine's popup storm (research/civic
  choice, advisors) speaks first. Lifted from Civ V Access's
  `CivVAccess_NotificationAnnounce` (same constants).
- **Arrival earcon** — `UI.PlaySound("NOTIFICATION_MISC_POSITIVE")`
  paired with the spoken line, per the earcon+speech design from the
  2026-05-25 conversation. Engine placeholder; will be replaced with a
  custom ElevenLabs earcon when those land.

Tick pump is `Events.GameCoreEventPublishComplete` (fires per Lua frame
in-game; engine source confirms via `CivicsChooser` / `ResearchChooser`
/ `MinimapPanel` / `WorldTracker`). When pending notifications exist
and the debounce + hold gates open, the next PublishComplete drains.

### `ScreenReaderEventHandlers.lua`

Removed `OnNotificationAdded` and the `Events.NotificationAdded`
subscription — now lives in `Notifications.lua`.

### `CivViAccessMod.modinfo`

Registered `Notifications.lua` under `<AddGameplayScripts>` and `<Files>`
(in-game context only; no notifications in the frontend).

## 0.5.0 — 2026-05-24 — Unit direct-move (Playable Basics Phase 1)

**Milestone**: the player can move units. Phase 1 of the 0.5.x Playable
Basics arc (`docs/PLAYABLE_BASICS_PLAN.md`). Single-hex direct-move via
`Shift+Q/E/A/D/Z/C`, mirroring the cursor's letter-cluster layout — hold
Shift to commit a move instead of just panning the cursor.

### `UnitMovement.lua` (new)

`Assets/UI/Accessibility/UnitMovement.lua`. Pre-validates (selection,
ownership, edge-of-map, enemy, MP, `UnitManager.CanStartOperation`),
then hands off to the engine's own `MoveUnitToPlot` (`Civ6Common.lua`)
which handles the war popup, attack vs. move dispatch, and air-unit
case. Announce fires on `Events.UnitMoveComplete` with direction +
"N moves remaining" (or "out of moves"). `HexCursor.jumpTo` syncs the
cursor to follow the unit.

Combat is explicitly deferred: stepping into an enemy plot speaks
`"Warrior northeast. Combat coming in a future release."` rather than
firing an attack. The Playable Basics arc is peaceful-builder-first;
combat lands in a later arc.

Civ V Access's much heavier movement layer (pending tracker across
`SerialEventUnitMove` + engine-fork `CivVAccessMissionDispatched`,
war-confirm popup intercept, combat preflight) is intentionally not
ported. Civ VI has no engine fork available, the engine's own
`MoveUnitToPlot` already covers the war popup + attack dispatch, and
combat is deferred — most of the complexity in Civ V Access lives in
the combat path we're not building yet.

### Numpad alternates dropped

`Assets/Data/RemapForHexCursor.xml`: removed all `LOC_OPTIONS_KEY_NP_*`
secondary gestures from cursor + WhereAmI actions. Letter cluster
(Q/E/A/D/Z/C, Shift+S, Alt+S) is now the only nav surface.

Two unfixable conflicts forced this. NVDA's default "Use numpad keys
for object navigation" intercepts the numpad before Civ VI sees it,
and Alt+numpad on Windows is the Unicode-input gesture (Alt+0233 = é,
etc.) which would collide with the new Alt+QAZEDC move bindings. Civ V
Access and other accessibility mods converged on letter-cluster-only
nav for these same reasons; we're catching up to the prior art rather
than re-relitigating a settled design choice. `HexCursor.CURSOR_HELP_
ENTRIES` updated to drop the "or Numpad N" suffixes and the standalone
Numpad 5 row.

### Move modifier: Shift+letter (revised after first test)

The initial 0.5.0 build bound Move to Alt+letter and tried to push the
engine actions (ToggleResources etc.) from their 0.4.x Alt+letter homes
out to Ctrl+Alt+letter via an `<Update>` statement. In test on 2026-
05-24, Alt+letter movement didn't fire at all. Diagnosis: Civ VI's
vanilla `InputConfiguration.xml` never uses 3-key combos in any
`InputActionDefaultGestures` row; the gesture parser appears not to
support that form, so the Ctrl+Alt+letter `Update` silently failed.
Engine actions stayed on Alt+letter (from 0.4.x), our Move actions
also bound to Alt+letter collided, and the engine resolved the
collision in the engine actions' favor (silent — ToggleResources
toggles a lens, no audible cue).

Fix: switch Move to **Shift+letter**. Two-tier model now:

- Bare letter (Q/E/A/D/Z/C) → cursor pan
- Shift+letter → unit direct-move
- Alt+letter → engine actions (ToggleResources, AutoExplore, Attack,
  Sleep, ToggleCivicsTree) — same as 0.4.x

Shift isn't intercepted by NVDA/JAWS the way Alt+numpad would be
(Shift is a typing modifier, not screen-reader-claimed), and no
existing Civ VI default binding uses Shift+letter for the cluster
letters.

### `HexCursorAddin.lua`

Six new `lookupAction` calls dispatch `CIVVIACCESS_Move*` to
`UnitMovement.directMove(direction)`. `include("UnitMovement")` added.

### Unit-info readout (`/`) and cursor recenter (`Ctrl+/`)

New `Assets/UI/Accessibility/UnitInfo.lua` matching Civ V Access's
unit-stats pattern from `CivVAccess_UnitControlSelection.lua` (bare `/`
for `speakInfo`, `Ctrl+/` for `recenterOnUnit`). The readout speaks
unit name + civ adjective, combat strength (if non-zero), ranged
strength + range (if applicable), moves remaining / max moves, and HP
fraction (only when damaged). Civ V Access's full readout also
includes level/XP, full promotions list, upgrade availability, and
cargo — we'll grow into that incrementally.

Recenter jumps the HexCursor back to the selected unit's tile and
announces the unit's name + civ — useful when the cursor has wandered
during exploration.

### HexCursor announce now includes civilian units

`Units.GetUnitsInPlot(x, y)` returns only the combat layer by default;
civilian units (Settler, Builder, Trader) live in a separate layer.
Confirmed in test 2026-05-24: cursor on a Settler's plot announced
only "grasslands, rice" and missed the Settler entirely. Fix: switch
to `Units.GetUnitsInPlotLayerID(x, y, MapLayers.ANY)` (the same call
`WorldInput.lua` uses).

### Help overlay

`HexCursor.CURSOR_HELP_ENTRIES` gains six `Alt+letter` rows for the
unit-move bindings, alongside the existing bare-letter cursor entries.
The `?` help overlay surfaces both groups so users can discover the
"cursor vs unit" two-tier model from the help screen.

### First-turn orientation hint corrected

`LOC_CIVVIACCESS_FIRST_TURN_NAV_HINT` told users "Press Tab or Enter to
cycle to other units." Tab is bound to nothing in Civ VI's default
`InputConfiguration.xml` — that's why the 0.4.1 diagnostic showed
`NextUnit` never firing on Tab presses. The actual engine defaults are
`.` for next unit, `,` for previous (Civ V Access ships these same
bindings; the field-converged design). Hint now reads "Press period to
cycle to the next unit that needs orders, comma for the previous."

### Bug sweep (multi-round, 2026-05-24)

Multiple test rounds after the initial Movement Phase 1 checkpoint
surfaced bugs and yielded root-cause findings worth documenting.

- **MainMenuAccess + LoadGameMenuAccess include() cache (#22, #24)**.
  Civ VI's `include()` returns from a process-wide cache without
  re-executing the file in a fresh Lua context. Both companion files
  were set on first load but nil on subsequent context entries
  (exit-to-main-menu, LoadGameMenu from pause). Lua.log: `attempt to
  index a nil value` at every call site. Fix: inline both companions
  into their respective Firaxis forks (MainMenu.lua, LoadGameMenu.lua)
  where the table construction re-runs per context. Deleted the
  separate `MainMenuAccess.lua` / `LoadGameMenuAccess.lua` files +
  modinfo entries. Plus for LoadGameMenu Enter: ActionButton sometimes
  disabled by soft mod-requirements warning; we force-enable before
  dispatching OnActionButton so the user's explicit Enter takes effect.
- **Alt+F4 NO leaves pause menu open + chatter on first attempt (#26b)**.
  Two issues: (a) when Alt+F4 fires with the pause menu hidden,
  `OnRequestClose` queues the pause-menu context to host the popup,
  but `CloseImmediately` after NO didn't pop the input context so the
  user was stuck in GameOptions input mode. (b) BaseMenu's onActivate
  spoke "Pause menu. Return to game." right before the popup spoke
  "Do you wish to exit?" — confusing chatter. Fixes: set
  `m_isRaisedForExitConfirm` BEFORE QueuePopup (it synchronously fires
  OnShow → onActivate, race condition); add `suppressInitialAnnounce`
  hook to BaseMenu and consult the flag; pop input context after
  CloseImmediately; reset flag in `accessibleResetPopup` so it doesn't
  leak across attempts. Also: preset `m_isLoadingDone = true` in
  Initialize so Alt+F4 always routes through exit-confirm regardless
  of whether the LoadScreenClose subscription registered in time.
  Also: speak "Exit cancelled. Back to game." on NO so the user knows
  the cancel registered.
- **Cycle-all Ctrl+./, silent — engine action dual-dispatch (#25b)**.
  Multi-round diagnosis (Ctrl-modifier-silences-Tolk theory wrong,
  CAMM-dedupe theory wrong). Real root cause: vanilla Civ VI binds
  Ctrl+./, to `CivilopediaForward`/`Back` (`InputConfiguration.xml`
  lines 158-159). Our `CIVVIACCESS_*UnitAll` actions registered on
  the same gestures, so both fired per press. Engine's C++ side
  handling for Civilopedia actions corrupts audio state even when
  the screen isn't visible — silencing both engine cycle sound AND
  our Tolk speech (CAMM forwarded the lines per launcher.log; audio
  never reached user). Bare period / N work fine because no engine
  binding shares the gesture. Final fix: rebind to **Shift+./,** —
  both gestures unbound in vanilla, no dual-dispatch. Mnemonic: bare
  ./, cycle units NEEDING ORDERS (engine NextUnit/PrevUnit), Shift+./,
  cycle ALL units (override the orders-gate). New memory:
  `reference_engine_action_dual_dispatch_breaks_audio` documents
  the rule: always grep `InputConfiguration.xml` before binding a
  gesture.
- **Notification chime fallback (#23)**. Only ~30 of Civ VI's
  notification types have per-type AddSound entries; the rest added
  silently. NotificationPanel shadow now falls back to a generic
  chime when no per-type AddSound is set. Trialled
  UI_Notification_Bar_Notch (subtle), ALERT_NEUTRAL (subtle), shipped
  with NOTIFICATION_MISC_POSITIVE (relic-created chime — distinct
  and audible).
- **Fog of war respect**. `HexCursor.AnnouncePlot` was exposing
  terrain, features, resources, cities, AND units regardless of
  player exploration. Real cheating bug — screen-reader users could
  pan into deep ocean and learn details a sighted player couldn't.
  Now gates on `PlayersVisibility[localPlayer]:IsRevealed/IsVisible`:
  unrevealed → "Unexplored"; revealed-but-foggy → terrain+features+
  resources + "Fog of war" suffix; visible → everything as before.
- **Exit-to-main transition speech**. Noel reported the silent
  multi-second exit-to-main transition was confusing. OnYes now
  speaks "Returning to main menu." / "Exiting game." before the
  engine transition fires.
- **CAMM LogArchiver — gzip + auto-prune Lua/Database/Modding.log**.
  Each launcher startup, copies the prior session's game logs to
  `%LocalAppData%\CivViAccess\logs-archive\` as gzipped timestamped
  files, prunes anything older than 7 days. Solves the
  "interesting log got wiped before I could check it" problem
  Noel hit multiple times during the bug-sweep rounds. Opt-in via
  `IGameInstance.GetArchivableLogPaths()` so installer-only adopters
  don't break.

### Documentation

- `docs/ROADMAP.md` — multi-arc plan from 0.5.x through post-1.0.
  Each arc has version targets, expansion-gating notes, rationale.
- `docs/EXPANSION_BACKLOG.md` — R&F / GS / GS-game-mode feature
  ledger so expansion content isn't forgotten when the foundation
  work ships.

### Release workflow

- `release.yml` now detects pre-release tags via semver hyphen
  convention. `v0.5.0` ships as stable; `v0.5.0-rc1` as pre-release.
  Wires into existing `LauncherSettings.UpdateChannel` (Stable
  default skips pre-releases; Latest gets them).

### Known gaps (deferred to next phase)

- **Multi-hex paths / target mode** ship in 0.5.1 (Phase 2).
- **End-turn after founding a city** is blocked by Civ VI's
  `ENDTURN_BLOCKING_PRODUCTION` until a production is selected. The
  production panel is mouse-only and lands in 0.5.1 (production was
  reordered ahead of Phase 2 since the play loop can't close without
  it — see `docs/PLAYABLE_BASICS_PLAN.md`). Until
  then: turn 1 is playable for exploration (move units, found cities,
  read terrain, cycle units with `.` / `,`), but ending the turn isn't
  reachable. We chose not to auto-pick a default production — sighted
  players don't get that fallback, so faking it for screen-reader
  players is the wrong parity move.
- **Verbosity-toggleable coords** in the per-move announce — design
  call from the plan, not implemented in 0.5.0. Move announce is
  currently "Moved {direction}. {N} moves remaining."; the
  tile-description with coords addition needs a per-move integration
  with HexCursor's `AnnouncePlot` that we'd like to validate in play
  first.

## 0.4.1 — 2026-05-23 — New-game flow speakable end-to-end

**Milestone**: a screen-reader user can start a Vanilla, R&F, or GS game
and reach world-interactive turn 1 with audible everything — loading-
screen briefing, advisor popup choice, expansion intro slideshow, first-
turn unit orientation, notifications, and HexCursor map exploration.
14 rounds of test-and-fix in one session.

### LoadScreen briefing (waypoint 04)

New `Assets/UI/Accessibility/LoadScreenAccess.lua` + shadow of
`Base/Assets/UI/FrontEnd/LoadScreen.lua`. The "Dawn of Man" loading
screen now speaks the on-screen text Civ VI shows sighted players.

- **"Creating game."** announces the moment the load screen opens
  (before briefing data is resolved).
- **Briefing reads**: civilization name → era name → leader name →
  leader portrait short brief (from the describer batch — see
  LeaderDescriptions below) → unique abilities/units/buildings → hotkey
  hint → decision prompt.
- **Sean Bean opt-in**: voice-over suppressed by default; user presses
  Enter to start the Dawn of Man speech, OR Escape to skip straight to
  the game. Round-8 design after testing several alternatives. Toggle
  setting (`PLAY_SEAN_BEAN`) lets future users opt-out entirely so the
  briefing reads the leader paragraph instead.
- **Re-read hotkeys** active throughout the LoadScreen window:
  - `R` → repeat the full briefing
  - `T` → re-read abilities only
  - `I` → speak the full LONG leader portrait description (from
    LeaderDescriptions.xml)
  - `S` → speak the leader paragraph (Sean Bean's transcript stand-in)
- **Clipboard**: full briefing (markdown) copied to clipboard via
  `UI.SetClipboardString` for later review / paste into Notepad.

### Advisor popup (waypoint 06)

New `Assets/UI/Accessibility/AdvisorPopupAccess.lua` + shadow of
`Base/Assets/UI/Popups/AdvisorPopup.lua`. FIRST_GREETING and every other
tutorial-system popup now speaks and accepts keyboard input.

- **Announce on raise**: "Tutorial advisor. [message]. Choose: option N
  of M, [button1]. Use Left or Right to switch options, Enter to confirm."
- **Arrow-key nav** between buttons (engine only supported clicking
  Option 1 via hotkey before — Option 2 was effectively unreachable for
  blind players).
- **Activation feedback**: "[choice] chosen." when Enter activates.
- **Esc override** for 2-button popups: "This choice is required."
  instead of opening the pause menu.
- **Dedupe**: engine raises FIRST_GREETING twice in rapid succession;
  we speak it only once (2-second signature window).
- **Ctrl+T / bare T** re-read message body. **Ctrl+I / bare I** speak
  portrait description (placeholder until describer batch covers
  advisor portraits).

### Expansion intro slideshow (waypoint 05)

New `Assets/UI/Accessibility/ExpansionIntroAccess.lua` + shadow of
`DLC/Expansion1/UI/Additions/ExpansionIntro.lua` + Expansion2 equivalent.
Single shadow handles both R&F (9 pages) and GS (12 pages) via runtime
ruleset detection + global sentinel preventing double-show.

- Right/N → next page. Left/P → previous page. T → toggle "do not show
  again". Ctrl+T → re-read current page. Ctrl+I → illustration
  description (placeholder until the diagram describer batch runs).
- Announce: "Welcome to Rise and Fall / Gathering Storm. Page N of M.
  [description]." Final page: "Last page. Press Enter to continue."

### First-turn unit orientation (waypoint 08)

Extended `Assets/UI/Accessibility/ScreenReaderEventHandlers.lua`. The
first own-unit selection during turn 1 fires a richer announce:

- "Settler on Plains (Hills) with Woods."
- "2 moves remaining."
- "Subtropical region." (coarse latitude band)
- "Visible nearby: Truffles East, Dyes West."
- Adjacent units / cities by 6-direction.
- "Press B to found a city here with the Settler. Press Tab or Enter to
  cycle to other units that need orders. When every unit has an order,
  pressing Enter ends the turn."

Deferred until LoadScreenClose so the briefing finishes without
interruption — engine fires UnitSelectionChanged earlier than expected.

### Turn-begin + world-interactive (waypoints 09, 10)

- New `Assets/UI/Accessibility/TurnAnnouncements.lua` — "Turn N." on
  every `LocalPlayerTurnBegin`. Plus a notification count.
- New `Assets/UI/Accessibility/WorldInteractiveAnnounce.lua` —
  "World interactive. Press question mark for help." once on first turn
  after blocking popups dismiss.

### Notification announce

`Events.NotificationAdded` subscribed in ScreenReaderEventHandlers.
Notifications speak as "Notification. [summary]." (NOINTERRUPT). Covers
"Move a unit", "Production completed", "Choose new technology", etc.

### In-game action audible confirmations

`Assets/UI/Additions/HexCursorAddin.lua` always speaks a curated set of
engine actions when fired, so users get audible confirmation that the
engine received the keypress: `NextUnit` → "Next unit", `EndTurn` →
"End turn", `FoundCity` → "Found city", `Sleep` → "Sleep",
`Fortify` → "Fortify", `Attack` → "Attack", and several more.

### HexCursor — confirmed working

The HexCursor framework (0.4.0 work) is play-tested working in this
release. Q/W/E/A/D/Z/X/C move the cursor in 6 directions, terrain +
features + adjacent units/cities announce on every move, ? opens the
help overlay.

### Leader portrait descriptions (LeaderDescriptions.xml)

`Assets/Text/en_US/LeaderDescriptions.xml` — 70 entries (SHORT + LONG
per leader) generated via the `tools/wonder-describer/describe.py`
pipeline with prompt `prompts/leaders.txt` and Gemini 2.5 Pro. SHORT
plays as part of the briefing; LONG is on-demand via `I` in the
LoadScreen window. Added to `<Files>` manifest in 0.4.1 — was registered
in `<UpdateText>` but missing from `<Files>` and wasn't actually being
loaded.

### CAMM fix consumed (v0.5.6+1)

CAMM submodule bumped to include a critical log-tail bug fix
(`Camm/Speech/LogTailSpeaker.cs`). The prior tail read Lua.log in
1024-byte chunks and split each chunk independently — lines spanning
the chunk boundary got truncated, with the first half emitted as a
"complete" line (often still matching the screen-reader marker, so Tolk
spoke half) and the second half silently dropped for missing marker.
Latent during single-line in-game speech; reliably hit any burst write
like the loading-screen briefing (12 lines / ~1.6 KB in one game frame
arriving 200ms later as one chunk). Fix: persistent StringBuilder of
pending decoded text across iterations; only emit complete lines
(terminated by `\n`); UTF-8 decoder (was ASCII, which mangled ellipses
and smart quotes in localized text).

### Engine InputAction context (R/T/I/S)

`Assets/Data/RemapForHexCursor.xml` adds four new actions for briefing
re-read (`CIVVIACCESS_RepeatBriefing`, `_AbilitiesReread`,
`_PortraitDescribe`, `_DawnOfManTranscript`) bound to R/T/I/S. Engine
defaults rebound to free those keys: `ToggleTechTree` → Alt+T,
`RangedAttack` → Alt+R. Actions registered with `ContextId="Universal"`
so they fire during `InputContext.Loading` (LoadScreen window) AND
in-game — letter-key dispatch to ContextPtr handlers doesn't work
during loading, but InputActions do.

### Debug aids (will trim later)

- `Assets/UI/Accessibility/Diagnostics.lua` — Events firehose; logs
  every engine event we care about during game-start. Helped triage
  most of the round-1-to-14 bugs.
- `Assets/UI/Accessibility/TutorialReset.lua` — resets tutorial
  user-options flags on game start so FIRST_GREETING + expansion intros
  re-fire across tests. Per-tutorial-item "Completed" state lives
  somewhere we can't reach from Lua; user-options reset is the best
  we can do for now.
- `HexCursorAddin.DIAGNOSTIC_SPEECH` toggle (defaults false) for the
  earlier "speak every action firing" diagnostic that helped trace
  HexCursor binding issues.

### Known issues (not blockers for this release)

- **City panel mouse-only**: pressing Enter on a city opens the
  production screen; no keyboard accessibility yet. Multi-session
  feature; queued.
- **Tab key not firing `NextUnit`** on Noel's machine: action is
  registered (id 39), binding is correct, but the keypress doesn't
  reach Civ VI's action dispatch. Possibly NVDA Tab interception or
  Civ VI window focus issue. Needs targeted diagnostic.
- **Per-item tutorial "Completed" state persists** across games —
  TutorialReset only clears user-options flags. Post-found-city
  advisor popup etc. won't re-fire even after reset. Engine doesn't
  expose a Lua API to clear per-item state.

## 0.4.0 — 2026-05-20 — In-game foundation: HexCursor + HandlerStack + Help

**Milestone: in-game accessibility work begins.** Game setup arc closed
in 0.3.9; 0.4.0 ships the foundation every future in-game screen will
depend on, plus HexCursor (the first user of the framework).

### Foundation modules (`Assets/UI/Accessibility/`)

- **`Log.lua`** — `Log.info / warn / error / debug / tryCall`. Replaces
  scattered `print()` calls; tags every line with `[CivViAccess][LEVEL]`
  for Lua.log grepping. Engine-agnostic.
- **`HandlerStack.lua`** — LIFO of input handlers with lifecycle
  callbacks (`onActivate / onSuspend / onDeactivate`). Each handler
  carries `bindings = [{key, mods, fn, description}]` + authored
  `helpEntries`. Provides `push / pop / replace / removeByName /
  popAbove`, `commonHelpEntries` registry, and `collectHelpEntries`
  (top-down dedupe walk used by the help overlay).
- **`InputRouter.lua`** — modifier-mask constants (`MOD_NONE / SHIFT /
  CTRL / ALT / CTRL_SHIFT / ALT_SHIFT / CTRL_ALT / ALL`),
  `modifierMaskFromInputStruct`, stack-walking `dispatch(key, mods)`,
  and `installOnContextPtr` helper that wires a `SetInputHandler`
  wrapper.
- **`Help.lua`** — `?` opens a transient help overlay (sub-mode of the
  host handler, same pattern BaseMenu uses for sub-menus). Up/Down nav,
  Home/End jump, type-ahead (A-Z first-letter match), `Ctrl+F` opens a
  substring filter mode (Enter applies, Escape clears). Renders snapshot
  of `HandlerStack.collectHelpEntries()` at open time so a stack mutation
  while help is up doesn't shift entries underneath the user.

All four modules are engine-agnostic where possible — only the
`pInputStruct` / `KeyEvents` / `ContextPtr` references in InputRouter and
the help-mode key handler touch Civ VI specifics. Ported from
Civ V Access's `CivVAccess_HandlerStack` / `_InputRouter` / `_Help`,
trimmed of Civ-V-only concerns (proxy-shared globals, env-probe dead-
context handling, beacons-transparency flag). Designed for portability
to Civ VII / Civ IV per [[project-cross-game-foundation]].

### `?` help discoverability on every BaseMenu screen

`BaseMenu.create` now composes each handler's `helpEntries` from
screen-specific entries (passed via `spec.helpEntries`) plus a default
nav template (Up/Down, Home/End, Enter/Space, Left/Right, Escape, F1,
A-Z type-ahead). `BaseMenu.install`'s show/hide handler pushes/removes
the handler from `HandlerStack`, so `?` collects the current screen's
bindings.

`Alt+V`, `Ctrl+T`, `?`, and `Ctrl+F` (in help) are registered into
`HandlerStack.commonHelpEntries` so they appear in the overlay
regardless of which screen is on top. The actual bindings still live
where they did before (BaseMenu's input handler for Alt+V / Ctrl+T;
Help.lua for ? / Ctrl+F) — the registration is documentation-only.

### `HexCursor` — free-roam tile cursor (in-game)

New `Assets/UI/Accessibility/HexCursor.lua`. Holds module-local
`(_x, _y)` cursor state; re-resolves the plot via `Map.GetPlot` on every
operation (never caches the userdata, since plot handles can outlive
their freshness across engine ticks).

- Key layout (ported from Civ V Access — the hex-shaped left-keyboard
  cluster, laptop-friendly, no numpad):
  - `Q` = NW, `E` = NE
  - `A` = W,  `D` = E
  - `Z` = SW, `C` = SE
  - Maps spatially to the hex shape on the keyboard.
- **Where-am-I keys:**
  - `Alt+S` speaks absolute X, Y coordinates ("X 47, Y 23").
  - `Shift+S` speaks position relative to the player's original capital,
    direction-decomposed ("5 east, 3 southeast of capital"). Mnemonic:
    Shift+S = "capital S" → relative to capital. Falls back to absolute
    with a "no capital yet" suffix when the player hasn't founded their
    first city.
  - Hex math (cube-coord conversion, decomposition, map-wrap folding)
    lives in new `Assets/UI/Accessibility/HexGeom.lua`, ported from
    Civ V Access's CivVAccess_HexGeom.lua. Civ VI doesn't expose a
    public `Map.IsWrapX()` so we default to wrap-X=true (standard for
    most map shapes); wrong-side seam reads on non-wrap maps are the
    only failure mode and are recoverable.
- Camera follows cursor every step via `UI.LookAtPlot(x, y)` (the
  Civ VI analog of Civ V Access's `UI.LookAt(plot, 0)`). The cursor IS
  the camera; no separate logical-vs-visual position to confuse users.
- Lean announce: terrain + feature + resource + city + units, joined by
  ". ". Skips yields / appeal / continent / defense / movement cost —
  those live behind future Ctrl+T verbose path per
  [[feedback-terse-announce-default]]. Terrain name resolution mirrors
  Firaxis's PlotToolTip View() (Lake / Coast get LOC_TOOLTIP_* keys;
  other terrains use the terrain's own Name field). Resource visibility
  gated by `playerResources:IsResourceVisible` so unrevealed strategics
  don't leak.
- `HexCursor.init()` places the cursor on `UI.GetHeadSelectedUnit()`,
  falling back to the player's first owned unit, falling back to the
  capital city. Wired to `Events.LoadScreenClose` so it fires once the
  loading screen finishes. Lazy first-move init as a safety net for
  hotloads where LoadScreenClose has already fired.
- Pushes itself onto `HandlerStack` and installs its own input wrapper
  (a richer variant of `InputRouter.installOnContextPtr` that
  intercepts Help mode for the `?` overlay).

### Civ VI vs Civ V hex cursor — design notes

Civ VI has no native keyboard hex cursor. `WorldInput.lua` binds the
arrow keys to `CameraPanUp / Down / Left / Right` action IDs (camera
pan, not logical focus); every `UI.GetCursorPlotID()` call in the base
UI resolves the *mouse* cursor's plot. Owning `(_x, _y)` ourselves end-
to-end is the only viable architecture. The full pre-implementation
investigation is in the `project_04_engine_investigation` memory.

### In-game pause menu + exit confirmations + Alt+F4

Without this, the player couldn't gracefully exit a session with a screen
reader. Shadowing `Base/Assets/UI/Menus/InGameTopOptionsMenu.lua` (the Esc
menu) and patching it inline:

- **`BaseMenu` nav** over the pause-menu buttons (Return, QuickSave, Save,
  Load, Options, Restart, Retire, Main Menu, Exit Game, plus PlayByCloud
  variants when applicable). Up/Down + Enter + Esc + type-ahead. Labels
  are read live from each engine button's `:GetText()` so we always speak
  exactly what sighted users see, with no LOC-key guesses that could drift
  if Firaxis renames one.
- **Speech on every confirmation popup.** Each `OnExitGameAskAreYouSure /
  OnRetireGame / OnRestartGame / OnMainMenu / OnPBCDeleteButton /
  OnPBCQuitButton` opens a Yes/No `PopupDialog`; the engine's popup
  primitive has no keyboard handling at all. Inline patches at each call
  site announce the warning text + first button, and `KeyHandler` now
  intercepts Left/Right/Up/Down (move between Yes/No, announces the new
  focus) and Enter (activate focused button) while a popup is open.
- **Alt+F4 works.** The engine already routes Alt+F4 through
  `Events.UserRequestClose` → `OnRequestClose` → `OnExitGameAskAreYouSure`.
  Wrapping `OnExitGameAskAreYouSure` with speech automatically covers both
  the Exit-Game-button path AND the Alt+F4 path — same function, two
  entry points.
- **Quicksave gets an audible "Quicksave" confirmation.** The engine
  plays a positive earcon (`Confirm_Bed_Positive`) but a screen-reader
  user has no other signal that the save fired.

The shadow file is a verbatim copy of the engine's 770-LOC original with
~120 LOC of inline accessibility patches marked "Begin/End CivViAccess
mod change". Maintenance burden: when Firaxis patches Civ VI, re-merge
this file. Same model we already use for `PlotToolTip.lua`,
`AdvancedSetup.lua`, etc.

### Deferred (will land in 0.4.1+)

- **MainMenu / Options / LoadGameMenu help retrofit.** These three
  screens have their own custom input handlers (not `BaseMenu.install`),
  so they don't auto-pick up `?` help. Each needs its own `push` /
  `removeByName` plus `?` interception. Out of scope for 0.4.0 — the
  framework is in place for them.
- **Universal `PopupDialog` accessibility.** Today only the
  `InGameTopOptionsMenu` confirmation popups (exit / retire / restart /
  main menu / PBC delete / PBC quit) are accessible. Other game popups
  using `PopupDialog` (end-turn warnings, notifications, tutorial popups,
  error dialogs across `DiplomacyActionView`, `EndGameMenu`, etc.) remain
  unspoken. Shadowing `Base/Assets/UI/Popups/PopupDialog.lua` would
  accessible-fy all of them with one change. Tracked separately.
- **Ctrl+T verbose plot announce** in HexCursor. Today HexCursor speaks
  the lean form on every step; Ctrl+T should pull yields / appeal /
  continent / defense / movement cost on demand. Trivial to add once
  the lean form is validated in play.
- **Alt+V verbosity toggle wired to in-game.** Currently Alt+V is bound
  in BaseMenu (front-end only). HexCursor doesn't yet vary speech with
  `Verbosity.isOn()`, so binding Alt+V in-game would have no visible
  effect until the chatty path lands alongside Ctrl+T.

## 0.3.9 — 2026-05-19 — Scenarios + edit-line cursor + per-value chatty (game setup complete)

**Milestone: the full game-setup arc is end-to-end accessible.**
Every screen, parameter, and picker the engine exposes for starting
a new game can be reached, read, and changed from the keyboard with
a screen reader: Create Game (AdvancedSetup), Scenarios (this
release), all four pickers (Natural Wonders, City-States, Leader
Pool 1, Leader Pool 2), every parameter shape (Pulldown, Checkbox,
NumberInput, Slider, Group, Button). The next release line
(0.4.x) starts in-game work.

### ScenarioSetup companion

`Frontend/ScenarioSetup.lua` thin fork +
`Accessibility/ScenarioSetupAccess.lua` companion — mirrors the
AdvancedSetup pattern. ScenarioSetup uses the same parameter
framework, so the existing item factories (Pulldown / Checkbox /
Slider / NumberInput / Button-as-picker), the same picker
companions (MultiSelectWindow / CityStatePicker / LeaderPicker),
and the same Players group all light up automatically.

Screen-specific tweaks:
- **Scenario pulldown pinned to the top** of L1 (regardless of its
  SortIndex) since it's the dominant choice — picking a scenario
  reshapes every other parameter on the screen.
- **`alwaysVerbose = true`** at the BaseMenu level: scenarios is a
  "browse and pick" screen where descriptions are the actual
  differentiator. Chatty mode reads per-value descriptions on every
  arrow landing, not just on L/R cycle. AdvancedSetup stays terse
  at L1 — different screen, different default.

The "Advanced Setup" button (visual-pane toggle for sighted users)
is intentionally NOT surfaced — our companion reads every parameter
from `g_GameParameters` regardless of which pane the engine is
showing, so the toggle is functionally redundant.

### NumberInput edit-line cursor nav

`BaseMenu.handleEditMode` now implements a proper edit line for
NumberInput / Slider edit-mode (the seed fields most prominently).
Previously typing was "fresh value only, no cursor" — users editing
a 9-digit random seed had to retype the whole thing. Now:

- Buffer **starts at the current value** with cursor at the end.
- **Left / Right** move cursor by one digit and speak the digit at
  the new position.
- **Home / End** jump to start / end of buffer.
- **Backspace** deletes left of cursor; **Delete** deletes under
  cursor (right of cursor index).
- Digit keys insert at cursor position.
- Enter commits parsed buffer; Esc cancels.

Initial announce reads the current value + a brief usage hint so
users know the edit affordances on first use.

### Pulldown describe reads per-value description (universal)

`BaseMenuItems.Pulldown` now overrides `describe` to prefer the
selected entry's `RawDescription` / `Description` (per-value) over
the parameter's generic `Description`. In chatty mode arrowing to
a Pulldown now reads the same content the Left/Right cycle reads —
"Ruleset, Standard Rules. This is a standard Civilization VI game"
instead of "Ruleset, Standard Rules. Choose the ruleset to play by".

The change is universal — affects every Pulldown in every screen
when chatty kicks in. ScenarioSetup feels the impact at L1 because
of `alwaysVerbose`; AdvancedSetup feels it inside drilled-in groups
(L2+) where chatty already fired. Strictly an improvement; no
regressions identified.

## 0.3.8 — 2026-05-19 — Consume CAMM v0.5.6 (replace coalesce with dedupe)

CAMM v0.5.6 replaces the v0.5.4/v0.5.5 deferred-pending coalesce
window with a simpler identical-text dedupe. The coalesce broke
normal flow — pressing Down arrow then Alt+V quickly caused the
verbosity-toggle's "Verbose off" to be stomped by the next arrow
announce in the pending slot, so users heard the arrow but never
the toggle confirmation.

After this bump, **Down → Alt+V works as expected** (the toggle's
announce interrupts the arrow announce). **Rapid same-key toggling
(Alt+V Alt+V) is hit-and-miss** — Tolk's natural last-write-wins
means rapid presses may produce only a fragment of the first
utterance before the second interrupts. State always cycles
correctly; the audible confirmation isn't fully reliable for spam.
Prism wouldn't help (same interrupt model). The proper fix is
distinct enable/disable **earcons** that don't compete in the
speech race — planned via the ElevenLabs Creator trial once the
Vermont travel settles.

Pure submodule consumption bump; no CivViAccess code changes.

## 0.3.7 — 2026-05-19 — Consume CAMM v0.5.5 (fixes v0.3.6 build break)

v0.3.6's CAMM v0.5.4 pin had a build break (Timer name ambiguous
against System.Windows.Forms.Timer with WinForms enabled); CI
failed at publish. v0.5.5 fixes the disambiguation. This is a
pure consumption bump; no CivViAccess code changes beyond the
submodule pointer.

The sticky-Alt+V behavior fix (rapid-interrupt coalesce window)
and the "Updating mod" speech-shortening — both intended for
v0.3.6 — now actually ship.

## 0.3.6 — 2026-05-19 — Consume CAMM v0.5.4 (sticky Alt+V fix)

Submodule pin bump to CAMM v0.5.4, which lands two speech-pipeline
fixes:

- **Rapid-interrupt coalesce window** in
  `AccessibleOutputHandler` — solves the "sticky Alt+V" symptom
  where rapidly toggling verbosity produced silence even though
  state cycled correctly. Tolk's `Output(text, interrupt=true)`
  is last-write-wins, and a second interrupt within tens of ms
  silenced the first before any audible part played. CAMM now
  locks out interrupt-mode calls for 150ms after firing one and
  holds the latest pending message to play when the window
  expires. Single utterances pass through immediately; rapid
  bursts collapse to first-played + last-pending. All speech
  paths in CAMM funnel through a single chokepoint, so every
  CivViAccess speech route is protected.
- **Shorter update-speech utterance** — CAMM's "Updating to
  version X.Y.Z." was reliably cut off by subsequent speech
  events; replaced with "Updating mod" so the announcement
  always lands.

No CivViAccess-side code changes; this is a pure consumption
bump. See `camm/CHANGELOG.md` for the upstream detail.

## 0.3.5 — 2026-05-19 — Numeric inputs, pulldown L/R cycling, picker hints

AdvancedSetup is now end-to-end editable from the keyboard: every
parameter the engine exposes is reachable, readable, and changeable
without touching the mouse. Three independent additions plus a
small UX polish ride this release.

### Edit-mode primitive in BaseMenu

`BaseMenu.lua` gains a `_editMode` state and `handleEditMode`
dispatch. When an item enters edit mode (digit-typing), the input
handler routes digits / Backspace / Enter / Esc through the edit
handler before any nav; every other key is swallowed so typing
can't accidentally trigger nav. Edit mode resets on screen hide.

### NumberInput + Slider item kinds

`BaseMenuItems.NumberInput` for Domain `int` / `uint` / `text`
(the random seed fields). Enter starts edit mode with an empty
buffer; type a fresh value digit-by-digit; Backspace pops, Enter
commits via `SetParameterValue` + `BroadcastGameConfig`, Esc
cancels. Each typed digit is spoken; commit speaks "set to N".

`BaseMenuItems.Slider` for `Values.Type == "IntRange"`
(CityStateCount, Disaster Intensity). Left / Right step ±1 within
`MinimumValue..MaximumValue`, committing each step immediately. At
a bound, the same value is re-spoken (silently stuck). Enter still
drops into edit mode for exact jumps far from the current value.

`AdvancedSetupAccess.parameterItem` now detects these shapes before
falling through to Pulldown.

### Pulldown Left / Right cycling

`BaseMenuItems.Pulldown` gains an `adjust(menu, ±1)` method that
cycles through `parameter.Values` in place, wrapping at the ends,
committing each step. BaseMenu's existing onLeft / onRight
machinery already calls `adjust` on items that implement it
(that's how Slider works), so the wiring is automatic.

Verbosity-aware: in chatty mode the cycle appends the per-value
description ("rainfall, Wet. Increases rainfall yields..."),
matching what the user would hear arrowing through the drilled-in
sub-menu. Terse mode reads label + value only. Enter still drills
into the sub-menu for users who want to browse all options.

Pickers (Array params) are unaffected — they're `Button` kind, not
Pulldown, and `Button` has no `adjust`. Left / Right on a picker
no-ops; Enter still opens the modal.

### Picker affordance hints (chatty)

A blind user at L1 has no audible cue that a picker button is
actionable since pickers have no current-value display. In chatty
mode, picker labels now read as a full action sentence:

- City-States → "Press Enter to pick city-states that will be available in the game"
- Leader Pool 1 / 2 → "Press Enter to select Leader Pool 1 (or 2) members"
- Natural Wonders → "Press Enter to pick natural wonders that will be available in the game"

Per-picker phrasing lives in a `PICKER_HINTS` map keyed by
ParameterId; unknown / future pickers fall back to a generic
", press Enter to open" suffix. Terse mode keeps the engine label
intact.

### Leader Pool button label normalization

The Select All / Select None buttons in the Leader picker now use
`LOC_SELECT_ALL` / `LOC_SELECT_NONE` instead of the engine's
preset-pulldown LOC keys (`LOC_LEADER_PICK_PRESET_ALL` / `_NONE`),
which resolve to bare "All" / "None". All three pickers' action
rows now read identically: "Select All", "Select None", "OK",
"Back".

## 0.3.4 — 2026-05-19 — Leader Pool picker (picker trio complete)

Ships the third and last Array-domain picker. Leader Pool 1 and
Leader Pool 2 are now fully keyboard- and screen-reader-navigable;
the picker trio (Natural Wonders, City-States, Leader Pools) is
complete and the largest remaining accessibility hole on AdvancedSetup
is closed.

### LeaderPicker companion

`Frontend/LeaderPicker.lua` thin fork +
`Accessibility/LeaderPickerAccess.lua` companion. Per-entry data
comes from the engine's `GetPlayerInfo` (PlayerSetupLogic.lua),
cached per Domain+Value so repeated arrows don't re-hit
`DB.CachedQuery`. This is the richest payload of the three pickers:

- Terse: `<leader>, <civ>` (e.g. "Trajan, Rome"). Some leaders share
  faces across DLC packs and the civ disambiguates them.
- Chatty / Ctrl+T: leader ability + civilization ability + uniques
  list, all `Locale.Lookup`-ed. This is the entire point — picking a
  leader without hearing the abilities is just naming faces blind.

`AdvancedSetupAccess.lua`'s Array-button stub now opens the engine
modal for `LeaderPool1` and `LeaderPool2` in addition to `CityStates`
(0.3.3) and the generic MultiSelectWindow path (0.3.2). All four
Array params on AdvancedSetup are accessible end-to-end.

Action row: Select All / Select None / OK / Back. The engine's third
preset ("Leaders with no Hall-of-Fame wins") is intentionally not
exposed — niche, and the BaseMenu button surface stays tight. Easy to
add as a fourth button if someone asks.

## 0.3.3 — 2026-05-19 — City-States picker + percent-escape speech fix

Ships the second of the three Array-domain pickers (Select City-States)
and resolves a global speech-pipeline gotcha: Civ VI's `print` runs
printf-style format processing on its argument, so any LOC text
containing `%` followed by a letter (e.g. "+15% Science",
"+5% Production") was being parsed as a format specifier, finding no
arg, and **silently nulling the entire output line**. Affected every
long-form announcement that included a percent-yield bonus — the
city-state picker exposed it first (Geneva, Taruga, others read as
empty) but the trap was global. Fix lives at the speech gateway, so
every call site through `OutputMessageToScreenReader` is protected.

### CityStatePicker companion

`Frontend/CityStatePicker.lua` thin fork +
`Accessibility/CityStatePickerAccess.lua` companion. Same shape as
the MultiSelectWindow companion shipped in 0.3.2 plus per-state
metadata: each city-state reads as `<name>, <category>` (terse —
"Geneva, scientific") so a fast scan tells you the type, and the
Suzerain bonus text (ruleset-aware: Bonus / Bonus_XP1 / Bonus_XP2
per active expansion) is the chatty / Ctrl+T payload. Bonus text and
category come from `DB.ConfigurationQuery` against the `CityStates`
table, matching the engine's lookup path.

AdvancedSetupAccess Array-button stub now opens the engine modal for
`CityStates` in addition to non-special-cased Array params; Leader
Pool 1/2 remain stubbed.

Deferred from this picker (not blockers): the in-modal CityStateCount
slider (adjust from parent AdvancedSetup until a Slider item kind
lands in BaseMenu) and the sort-by-name/type pulldown (default name
sort is fine for v1).

### Percent-escape speech fix

`ScreenReader.lua`'s `OutputMessageToScreenReader` now doubles every
`%` in the body before passing to `print` (two-line `body:gsub("%%",
"%%%%")` insertion). The printf processor consumes the doubled `%%`
and emits a literal `%`, so the log line carries the correct single
`%`, the launcher's log tail forwards "+15% Science" verbatim, and
Tolk speaks it correctly.

Affects every speech path, not just the picker. Many Civ VI LOC
strings (building yields, district adjacencies, wonder bonuses,
policy effects) embed `%` for percent values — those were all
intermittently silent on long announcements before this fix.

## 0.3.2 — 2026-05-19 — Natural Wonders picker + AD pipeline scaffold

Ships the first of the three Array-domain pickers (Select Natural
Wonders) plus the build-time scaffolding for AI-generated visual
descriptions ("image audio-description") of game art. City-States and
Leader Pool 1/2 pickers still stub; both follow the same shape and
land next.

### MultiSelectWindow companion

`Frontend/MultiSelectWindow.lua` is a thin fork of the engine's
generic multi-select modal (used for Natural Wonders and any future
non-special-cased Array param). `Accessibility/MultiSelectWindowAccess.lua`
mirrors the engine's `m_SelectedValues` via
`LuaEvents.MultiSelectWindow_Initialize`, builds a `VirtualCheckbox`
per entry, and commits via
`LuaEvents.MultiSelectWindow_SetParameterValues` which the existing
AdvancedSetup handler picks up. Select All / Select None / OK / Back
are wired.

`AdvancedSetupAccess.lua`'s Array-button stub now opens the engine
modal (fires the same `_Initialize` event the engine's mouse-click
path fires) for non-special-cased params; CityStates / LeaderPool1 /
LeaderPool2 still announce "picker not yet accessible" until their
own pickers ship.

### BaseMenu / BaseMenuItems additions

- `BaseMenuItems.VirtualCheckbox` — pure-state checkbox without an
  engine widget. Spec passes `getValue` / `setValue` closures so the
  item reflects and commits through caller-owned state. Used by the
  picker for its dynamic entry list (engine InstanceManager builds
  the visual instances; there's no stable `Controls.X` to bind to).
- `BaseMenu.install` accepts a `displayName` function (resolved at
  speak time, not install time) so screens whose title comes from a
  runtime parameter — the picker, whose title is the Array param's
  Name — can pass a closure instead of a frozen string.
- New `alwaysVerbose = true` spec flag. The picker opts in: it's
  itself a drilled-in modal, but as a fresh BaseMenu handler it
  starts at `_level = 1` with no `_parent`, so the standard L2+
  chatty gate would force terse. The flag tells the gate "treat me
  as already deep" so chatty kicks in throughout.

### AD pipeline scaffold (tools/wonder-describer/)

Build-time Python tool that runs game-art images through Gemini and
emits Civ VI LOC XML files registered via `<UpdateText>`. Output is
two LOC rows per image (`<prefix>_<stem>_SHORT`,
`<prefix>_<stem>_LONG`) so the picker companion (and future
consumers) call `Locale.Lookup` for screen-reader visual
descriptions. Translation parity with all other mod text.

- Per-category prompts in `prompts/` — natural-wonders, world-
  wonders, leaders, units, buildings, civilizations. Add more as
  surfaces come online.
- `--dry-run` flag for prompt iteration against a single image
  (prints to stdout, no JSON / XML written).
- `--limit N` for starter batches.
- Resume is automatic (entries already in JSON are skipped unless
  `--force`).
- JSON is the canonical store; XML is the mod-shipping artifact.

API key (`GEMINI_API_KEY`) is local-only. CI never calls Gemini —
the XML output is committed and shipped.

## 0.3.1 — 2026-05-19 — AdvancedSetup accessibility (single-player nav)

Lands the AdvancedSetup (Create Game) screen accessibility companion
+ a reusable per-screen BaseMenu framework adapted from the Civ V
Access architecture. The screen is fully keyboard- and screen-reader-
navigable for single-player setup; the Array-domain pickers (City-
States, Leader Pool 1/2, Natural Wonders) remain stubbed (see
"Known gaps").

### BaseMenu framework

`CivViAccessMod/Assets/UI/Accessibility/BaseMenu.lua` (cursor + nav
state machine) and `BaseMenuItems.lua` (item factories) replace the
previous per-screen ad-hoc kb wiring with a declarative items
description per screen. A screen registers its items via
`BaseMenu.install(ContextPtr, spec)`; the framework handles the
cursor, drill / undrill, announcement, prior-handler chaining, and
on-demand verbose description (Ctrl+T).

Bindings:
- Up / Down / Home / End — navigate within current level (wraps
  at level 1; deeper levels cross into sibling groups).
- Enter / Space — drill into a Group; activate any other item.
- Left — at depth > 1, walk back up a level.
- Right — drill into Group; reserved for slider adjust.
- Esc — clear sub-menu (Pulldown picker) if open, else fall
  through to the screen's existing back / cancel.
- F1 — re-speak displayName + preamble (screen header).
- Ctrl+T — re-speak the current item with its tooltip /
  parameter description appended. Default announce is terse
  (label + state); long help is on demand. The motivating bug:
  multi-paragraph Game Mode / Victory descriptions in the default
  announce got cut mid-word by the next nav keystroke, producing
  unintelligible fragments.

Item kinds: `Button`, `Checkbox`, `Pulldown` (with parameter +
selectEntry modes), `ParameterCheckbox` (for Civ VI's bool / GameMode
parameter framework), `Group` (static `items` or dynamic `itemsFn`
with optional caching), `Choice` (label-only row, no widget
backing). Slider / Textfield item kinds intentionally not built —
AdvancedSetup has no obvious need for them; add when a future
screen does.

### AdvancedSetup companion

`Accessibility/AdvancedSetupAccess.lua` walks
`g_GameParameters.Parameters` at show-time and classifies each
parameter:
- Globals (Ruleset, Map Type, Difficulty, Game Speed, Era,
  Disaster Intensity, etc.) → Pulldown at the top level.
- `parameter.Domain == "bool"` or `GroupId == "GameModes"` →
  ParameterCheckbox at L1 or inside the Game Modes group.
- `parameter.GroupId` starts with "Victory" → ParameterCheckbox
  inside the Victory Conditions group.
- `parameter.Array` (CityStates, LeaderPool1/2) → Button placeholder
  that announces "picker not yet accessible" (see Known gaps).
- Per-player parameters → drilled inside the Players group.

Top-level shape: globals → Players group → Game Modes group →
Victory Conditions group → Defaults / Close / Start.

`Frontend/AdvancedSetup.lua` is the thin fork: verbatim base file
plus `include("ScreenReader"); include("AdvancedSetupAccess");`
at the bottom (after `Initialize()` so the base screen's
`OnShow` / `OnHide` / `OnInputHandler` globals exist and are
captured by the companion).

### Polish landed 2026-05-19

- Per-slot params now come from `GetPlayerParameters(playerID)`, not
  `g_GameParameters`, so slot drill reads leader / handicap / team /
  color correctly.
- Pulldown `currentValueText` handles non-table `parameter.Value`
  (Disaster Intensity, GameRandomSeed, MapRandomSeed, CityStateCount,
  ...) — looks up in `parameter.Values` by Value equality, falls back
  to `tostring`. Previously crashed on `.Value.Name` index.
- `isVictoryParameter` matches `GroupId == "Victories"` literal; the
  earlier `^Victory` Lua pattern silently leaked all victory params
  into L1 because position 7 differs (Y vs I).
- `UI_PostRefreshParameters` hook invalidates the BaseMenu items
  cache on ruleset / mode flip, so Gathering Storm → Standard drops
  Calendar / Disaster Intensity / Diplomatic Victory live.
- Per-item `isNavigable` consults `parameter.Visible` dynamically.
- Action-row buttons read live `Controls.X:GetText()` instead of
  unresolved `LOC_SETUP_DEFAULT` etc.
- Pulldown sub-entry `describe` resolves `Description` LOC keys, so
  Ctrl+T on map types / world ages reads prose ("Continents. Multiple
  separate landmasses…") instead of `LOC_MAP_CONTINENTS_DESCRIPTION`.

### Escape semantics

`Esc` pops one level when drilled into a group or sub-menu (mirrors
Left arrow) and only falls through to the engine's close at L1.
Previously fell through at every depth, surprising users who
expected one-level-up semantics.

### Verbosity (Alt+V)

New `Verbosity.lua` module + `Alt+V` toggle. Chatty mode swaps the
arrow-key landing from `announce()` (label + value) to `describe()`
(label + value + tooltip / parameter description). Gated to L2+
(group children or Pulldown sub-entries) so generic L1 tooltips
don't add noise; the win is at sub-menu depth where each entry's
description is the only useful differentiator (leader, map type,
world age). Default chatty. `Ctrl+T` continues to force `describe`
regardless of mode.

### Known gaps (deferred)

- Array-domain pickers (City-States, Leader Pool 1/2, Natural
  Wonders) still announce "picker not yet accessible." Each picker
  is its own modal screen and needs its own per-screen fork +
  companion. Next deliberate work item on this screen.
- Per-slot Remove button inside the Players group is not surfaced
  yet (the engine builds it on a per-instance container that
  isn't trivially reachable from the parameter framework — needs
  a stable hook).
- Rich civ-pulldown announcement (leader / civ / uniques per the
  in-memory leader-civ-boons plan) is plumbed via the Pulldown's
  `entryAnnounceFn` parameter but not yet supplied by
  AdvancedSetupAccess. Easy add once the format is decided.
- Rapid back-to-back screen-reader interrupts (e.g. Alt+V Alt+V
  inside ~200 ms) can swallow the leading utterance. CAMM's
  `LogTailSpeaker` polls Lua.log every 200 ms and coalesces
  interrupts within a window; the Lua side fires correctly. Bundled
  with the future Prism / Tolk abstraction in CAMM.

### Risks to watch in pre-release testing

- BaseMenu uses `ContextPtr:SetShowHideHandler` to install its
  wrapper alongside the base's `SetShowHandler` / `SetHideHandler`.
  If Civ VI's engine dispatches the show and showHide slots
  independently, the base's `OnShow` / `OnHide` may fire twice
  (once from the engine, once via our priorShow / priorHide
  chain). The pattern mirrors Civ V Access's production-tested
  approach so we ship it as-is; if double-fire effects surface,
  swap to a Notify pattern where the fork explicitly calls into
  `AdvancedSetupAccess.NotifyShow` / `NotifyHide`. Documented
  inline in `BaseMenu.lua`.
- Combined with CAMM v0.5.1's single-instance mutex, fast nav
  through Victory / Game Modes should land "label, state" cleanly
  in the screen reader. If you still hear truncated readouts,
  the mutex didn't engage (check Task Manager for duplicate
  launchers) or the terse-announce change is regressed.

## 0.3.0 — 2026-05-17 — Built on CAMM v0.1.0

Architectural milestone: Civ VI Access is now a thin consumer of the
[CAMM](https://github.com/nromey/camm) framework, pinned to the
`v0.1.0` tag via the `camm/` git submodule. Roughly 2,900 lines of
launcher / installer / wizard / speech / lifecycle code that used to
live in this repo now lives in CAMM and is shared with any other
accessibility-mod author who wires CAMM in.

CivViAccess/ now holds 203 LOC across four files:
- `Program.cs` (36): builds the CAMM manifest, calls
  `CammHost.RunAsync(args, manifest)`.
- `CivViGameInstance.cs` (71): implements `Camm.IGameInstance`. The
  Steam path to `CivilizationVI.exe`, the `%LocalAppData%\Firaxis
  Games\Sid Meier's Civilization VI\Logs\Lua.log` location for log-
  tail speech, EULA-aware launch announcement (reads
  `UserOptions.txt`'s `CopyrightAccept` line), the post-exit
  "Civilization VI closed." line.
- `Speech/CivViMessageSanitizer.cs` (52): implements
  `Camm.Speech.IMessageSanitizer` with the existing regex map for
  Civ VI's `[ICON_*]`, `[COLOR:*]`, `[NEWLINE]`, and `<WORD>:
  #SCREENREADER` markup.
- `Speech/CivViScreenReaderMarkerProtocol.cs` (44): implements
  `Camm.Speech.IScreenReaderMarkerProtocol` with the `#SCREENREADER`
  prefix and `[NOINTERRUPT]` option parsing.

Plus the `CivViAccessMod/` mod payload directory, `app.manifest`, and
`CivViAccess.csproj` (a `<ProjectReference>` to `camm/Camm/Camm.csproj`
plus embedded-resource globs for the Tolk DLLs at
`camm/third_party/tolk/dist/x64/` and the mod payload).

Behavioral parity with 0.2.0 — same install wizard, same IFEO
transparent-launch, same auto-update behavior, same per-user state
locations. Verified via `dotnet run -- --version` (output identical
to 0.2.0); the real install / launch / uninstall flow will be
verified against the 0.3.0 signed release.

CAMM extraction roadmap from `CAMM_EXTRACTION_PLAN.md`:
- ✅ Steps 1-6, 8-10 of the plan.
- ⏭️ Step 7 (LocaleCatalog + en.json for localizable visible strings)
  ships as CAMM 0.1.1, no version bump required on this side.

## 0.2.0 — 2026-05-17 — Install wizard rewrite

The 0.2.0 milestone. Replaces the 0.1.10 chained-TaskDialog install
flow with a 5-page WinForms wizard — Welcome → Update channel →
Ready to install → Installing → Done. Standard Next/Back/Cancel
shape every Windows user recognizes; Back enables recovery from
mistakes without re-running the installer. The wizard also serves
as the canonical install UX for the future CAMM (Chameleon Access
Mod Manager) extraction (see `CAMM_EXTRACTION_PLAN.md`).

### Wizard pages

- **Welcome**: heading + body summarizing what the installer does +
  UAC heads-up. On a genuine first install (install dir doesn't
  exist), a subhead reads "by Noel Romey, version 0.2.0" — hidden
  on reinstall/update.
- **Update channel**: read-only ComboBox with Stable (default) /
  Latest / Off; live description Label updates on selection.
  Arrowing through items speaks `"<mode>. <description>"` through
  Tolk for deterministic announcements regardless of NVDA verbosity
  settings.
- **Ready to install**: summary block with install location +
  chosen channel; note explaining the UAC prompt is coming and
  pointing at both Apps & Features Modify AND re-running the
  installer as ways to change the channel later. The host Next
  button relabels to "Install" so the user knows the next click
  commits.
- **Installing**: marquee progress + status Label, all buttons
  disabled (mid-install close isn't safe once elevation has been
  granted). Spawns the launcher exe with `--install-from-wizard`
  via runas; the elevated child runs `Installer.ApplyInstall` with
  no UI. When the child exits, the wizard auto-advances.
- **Done**: variant rendering. Success shows "Civ VI Access is
  installed. Launch Civilization VI from Steam..." with Finish as
  the only button. Failure shows the error message and tells the
  user nothing was permanently changed.

### Accessibility plumbing

- **Tolk-driven page announcements** with a 250ms delay timer to
  beat NVDA's focus-event race — page content speaks reliably
  after focus has landed. Without the delay, NVDA's automatic
  "Next button" announce queues over our content and the user
  only hears the button name. Pattern documented in the
  `reference_installer_wizard_speech_pattern` memory.
- **Per-page initial focus** via `IWizardPage.InitialFocusControl`
  — combobox on Channel, Install button on Ready, Next elsewhere.
  Screen-reader users land on the primary control, not the
  heading.
- **Explicit `AccessibleName` + `AccessibleRole.StaticText`** on
  every Label so NVDA's browse-mode reads them; mnemonic ampersands
  stripped from button `AccessibleName` so screen readers don't
  say "ampersand Install button".
- **Cancel-confirm dialog** ("Continue installing" / "Yes, cancel
  and exit") on every page where Cancel is enabled. Parents on the
  wizard form (new `ownerHwnd` parameter on `Dialogs.ShowChoice`)
  so Z-order is sane and the console window isn't yanked to the
  front. Wired to both the Cancel button and `OnFormClosing` so
  the title-bar X also triggers it. Installing page blocks close
  entirely; Done page closes without prompt.

### Architecture

- **`Installer.ApplyInstall`** — the post-elevation install core
  (copy launcher exe, extract Tolk DLLs, deploy mod payload to DLC
  dir, register IFEO + Apps & Features) extracted as a public
  method. Both the wizard's elevated child (`--install-from-wizard`)
  and any future caller share one install implementation.
- **`IWizardPage` interface** — pages declare `Title`,
  `AnnouncementText`, `InitialFocusControl`, `NextButtonText`,
  `ShowBackButton`, `ShowCancelButton`, `ButtonsEnabled`,
  `CanGoNext` + events `CanGoNextChanged` and `AdvanceRequested`.
  Host form drives transitions and speech timing; adding a page
  is a self-contained `UserControl`.
- **`InstallContext`** carries per-run state across pages:
  `SelectedChannel`, `IsFirstInstall`, `IsDryRun`, `InstallError`.
  `IsDryRun=true` (the default) drives `--wizard-test` dev
  iteration with a 2-second simulation; `IsDryRun=false` (set by
  `Installer.Install`) drives the real install path.

### Build

- `<UseWindowsForms>true</UseWindowsForms>` enables WinForms for
  the wizard. Coexists with `<PublishAot>true</PublishAot>` via
  `<_SuppressWinFormsTrimError>true</_SuppressWinFormsTrimError>`
  — NETSDK1175 fires by default but the escape hatch is safe for
  our intentionally-code-only wizard surface (no Designer files,
  no data binding, no property grid). Trim warnings from
  `System.Windows.Forms` etc. are advisory.
- Expected exe size growth from ~7.5 MB (0.1.13) to ~12-15 MB.
  Native AOT linker still required (CI loads MSVC via
  `ilammy/msvc-dev-cmd@v1`).

### Companion: CAMM extraction plan

`CAMM_EXTRACTION_PLAN.md` lands alongside this release — a 620-line
file-by-file template/glue/hybrid classification of the launcher,
public-surface design (`CammModManifest` + `CammHost.RunAsync`),
ten-step migration path with Civ VI Access as the test case,
locale-catalog architecture, and open questions. Drives a future
session.

### Removed

- `Installer.Install`'s TaskDialog chain (welcome + channel picker
  + ready confirm + confirm-cancel loop) — replaced by wizard
  pages.
- `RelaunchSelfElevated` — only the legacy chain used it.
- Uninstall keeps its TaskDialog flow per WIZARD_PLAN.md: it's a
  single-binary confirm that doesn't benefit from a wizard shape.

## 0.1.13 — 2026-05-16 — Release pipeline fix (publish output path)

Third pipeline-debugging bump. 0.1.12 fixed Azure auth and the
build + sign step actually started executing — but the signing
step couldn't find the published binary because of a path
mismatch. When dotnet publish runs inside the vcvars-loaded
dev environment that ilammy/msvc-dev-cmd@v1 provides (which we
need for the AOT linker), MSBuild picks up the Platform=x64
env var and inserts an extra `x64\` segment into the output
path: `bin\x64\Release\...` instead of `bin\Release\...`.
Local builds outside dev cmd don't have this segment, so the
hardcoded path was wrong only on CI.

Updated all `files-folder` / `copy` paths in the workflow to
include the extra `bin\x64\` segment. Workflow only runs on CI
so the divergence from local-build paths is contained.

## 0.1.12 — 2026-05-16 — Release pipeline fix (drop subscription-id from azure/login)

Second pipeline-debugging bump. 0.1.11 added `allow-no-subscriptions:
true` to the azure/login step, which handles the "no subscriptions
enumerated" case — but we were ALSO explicitly passing
`subscription-id`, which triggers a separate code path that tries
to `az account set` to the specified subscription and fails because
the App Registration has no subscription-level access. Removed the
`subscription-id` parameter entirely; the OIDC-derived access
token is used directly by the Trusted Signing call which doesn't
need subscription context.

Build pipeline reached the AOT publish step successfully under
0.1.11 (first time the build phase ran end-to-end on GitHub
runners). This bump fixes the Azure-auth step that immediately
follows.

## 0.1.11 — 2026-05-16 — Release pipeline fix (subscription-enumeration bypass)

Pipeline-debugging bump on top of 0.1.10. The 0.1.10 tag pushed
a new `release.yml` workflow that authenticated to Azure
successfully but failed at `azure/login`'s default subscription-
enumeration step, because the signing App Registration has no
subscription-level RBAC role (it only has signing scope on the
cert profile itself, which is the principle-of-least-privilege
shape). Added `allow-no-subscriptions: true` to the azure/login
step so it skips that check and just produces the access token
the signing call needs.

No source / binary changes from 0.1.10; this is the first version
that actually produces a signed binary attached to a GitHub
Release.

## 0.1.10 — 2026-05-16 — TaskDialog dialog migration, full uninstall cleanup, signed releases

### Installer / uninstaller UX

- **All choice dialogs migrated from MessageBox to TaskDialog with
  explicit verb-labelled command-link buttons.** Previous OK/Yes/No
  semantics required users to read the dialog body to figure out what
  each button did — "Yes" in the Already-Installed dialog meant
  Reinstall, which is a real UX trap. Migrated: Already-Installed
  (Reinstall / Uninstall / Change update channel / Exit), Welcome
  (Continue / Exit installer), Update Channel picker (Stable / Latest
  / Off / Keep current — single dialog replacing the sequential
  MessageBox chain), Ready-to-Install (Install / Cancel installation),
  Uninstall confirm (Uninstall / Cancel; defaulted to Cancel + warning
  icon since uninstall is destructive).
- **Ready-to-Install dialog added** between channel-picker and UAC.
  Previous flow conflated configure with commit by taking the user
  straight from channel selection into UAC with no explicit go-ahead.
  New dialog restates destination + chosen channel, asks for explicit
  Install, and confirms cancel-from-this-point with an "are-you-sure"
  step (the only place where cancel-confirm fires, since it's the
  last point before UAC).
- **Uninstall now fully removes the install directory.** Previous
  behavior left the launcher exe + Tolk DLLs orphaned in
  `Program Files\Civ VI Access` with a "delete the folder manually
  if you want a complete cleanup" note in the completion dialog. Now
  when uninstall is invoked from outside the install dir
  (downloaded-installer path), `Directory.Delete` cleans up entirely.
  When invoked from inside (Apps & Features path runs the installed
  exe directly), the non-elevated parent stages a copy of itself to
  `%TEMP%\CivViAccessUninstall\` before elevating, so the elevated
  child isn't holding the install dir open. Net: uninstall via either
  path leaves Program Files clean.

### Signing + release infrastructure

- **Azure Trusted Signing wired up via GitHub Actions.** New
  `.github/workflows/release.yml` triggers on `v*` tag pushes, builds
  the AOT publish on a GitHub-hosted Windows runner, signs the
  resulting `CivViAccess.exe` via Microsoft's Trusted Signing service,
  and publishes the signed binary as a GitHub Release asset. OIDC
  federation (no client secrets stored in GitHub); per-repo App
  Registration with federated credentials scoped to main branch + tag
  push; RBAC role `Trusted Signing Certificate Profile Signer` scoped
  to a single shared certificate profile under the "Noel Romey"
  individual publisher identity. End users will see "Verified
  Publisher: Noel Romey" in UAC instead of the previous "Unknown
  publisher" warning. This is the first release with a signed binary.
- **`app.manifest` added** declaring Common Controls v6 dependency —
  required for `TaskDialogIndirect` to resolve (without it,
  `EntryPointNotFoundException` at first call). Also declares
  PerMonitorV2 DPI awareness so dialogs render crisply on high-DPI
  displays, and supportedOS GUIDs for Windows 10/11.

## 0.1.9 — 2026-05-15 (evening) — Chameleon Installation, Update, and Launch System

Polish batch on top of 0.1.8's install validation. Internal codename
for the multi-mode launcher binary: **Chameleon Installation, Update,
and Launch System** (CIULS) — same binary picks one of several
behaviors based on where it is and what flags it was invoked with:

| Context | Behavior |
|---|---|
| `--install` from outside install dir | Welcome dialog → channel picker → UAC → install |
| `--uninstall` | Confirm dialog → UAC → remove IFEO + Apps & Features + DLC mod |
| `--version` / `--about` | Print + speak version info |
| `--config` | Open channel-picker dialog |
| `<CivVI path>` arg (IFEO redirect) | Transparent launch: spawn Civ VI via debug-bypass, attach log watcher |
| Bare exe, not installed | Auto-trigger install flow |
| Bare exe, already installed, run from outside install dir | Show Already-Installed dialog (Reinstall / Uninstall / change settings / exit) |
| Bare exe in dev tree | Dev mode: deploy local mod + launch Civ VI |

### Update channel UI surfaced in 4 discovery points

- **Welcome dialog at install** — channel picker fires right after the
  user confirms install, before UAC. They pick Stable / Latest / Off
  and the choice is saved to `launcher.ini` (no admin needed; see
  below).
- **Already Installed dialog → Change Settings** — when a user
  double-clicks a downloaded copy of the launcher post-install, the
  Cancel branch leads to a "change settings only" sub-prompt, which
  opens the channel picker without re-installing.
- **Apps & Features Modify button** — `AppsAndFeaturesRegistration`
  now sets `ModifyPath` to `<launcher> --config` (drops the old
  `NoModify=1`). Users find it in Windows Settings → Apps → Installed
  Apps → Civ VI Access → Modify. Standard Windows discovery surface.
- **`--config` flag** — opens the channel picker directly. Power-user
  path; also what Apps & Features Modify invokes.

All four converge on the same `Dialogs.ShowChannelPicker(currentChannel)`
helper. Sequential MessageBoxes (primary Yes/No/Cancel picker;
secondary Off-or-keep dialog) since MessageBox can't do 4 buttons.

### Settings location moved to %LocalAppData%

`launcher.ini` was in Program Files (admin-write only). Moved to
`%LocalAppData%\CivVIAccess\launcher.ini` so:
- Channel changes work without UAC every time
- Per-user settings (each Windows account picks their own channel)
- Co-locates with launcher.log under one `CivVIAccess\` directory

The template content + comments explain the discovery surfaces above so
power users editing the file know there's also a dialog path.

### Update artifact model simplified to single .exe

Earlier model shipped two artifacts per release:
`CivViAccess-X.Y.Z.exe` + `CivViAccessMod-X.Y.Z.zip`. Since 0.1.8 the
launcher contains the mod as embedded resources, so two artifacts was
redundant.

Now ships ONE artifact: `CivViAccess-X.Y.Z.exe`. The launcher is the
canonical source of truth for both itself and the mod files. After
self-update via the .pending swap, the new launcher writes a
`.mod-redeploy-needed` marker in `%LocalAppData%\CivVIAccess\`; on the
post-relaunch startup, Program.cs detects the marker, calls
`ModFiles.ExtractTo(DLC)`, then deletes the marker. Idempotent; if
extraction fails (e.g., game already running, files locked), retried
on next launch.

`Updater.ApplyAsync` now downloads only the launcher exe; ApplyModZipAsync
removed entirely. `ApplyPendingSelfUpdateAndRelaunchIfNeeded` writes the
marker before relaunching.

## 0.1.8 — 2026-05-15 — Launcher install + IFEO transparent launch validated end-to-end

End-to-end validation pass: Steam Play → IFEO redirect → our launcher →
CreateProcess-with-debug-bypass → Civ VI → mod loads → menu narrates.
All gotchas surfaced + fixed in a single afternoon of install testing
on a real Windows 11 machine. Significant additions and fixes on top of
the 0.1.8-equivalent scope originally drafted as "Unreleased":

### Install flow (new)

- **Welcome / Completion / Already-Installed dialogs.** Native Win32
  `MessageBox` via P/Invoke (AOT-friendly, screen-reader-accessible
  via UIAutomation by default). Initial implementation with unowned
  hWnd was invisible on Win11 — `MB_SYSTEMMODAL` + console-window
  ownership + explicit foreground-restore is the working combination.
  Welcome confirms before UAC; Completion confirms after install.
  Re-clicked installer when already installed offers Yes/No/Cancel
  → Reinstall / Uninstall / Cancel via `Dialogs.YesNoCancel`.
- **Mod files deployed during install.** The launcher's old install
  flow copied `CivViAccess.exe` to Program Files but never touched
  Civ VI's DLC dir — dev mode hid this because `dotnet run` always
  redeploys from local source. Embedded the full `CivViAccessMod/`
  source tree (~21 files, ~640 KB) as resources via the `mod/<path>`
  prefix in csproj `<EmbeddedResource>`; `ModFiles.ExtractTo` writes
  them into `DLC\CivViAccessMod\` during install. One .exe contains
  everything needed to install both launcher and mod.
- **Uninstall removes deployed mod.** `Installer.Uninstall` now also
  removes `DLC\CivViAccessMod\` so a clean install starts fresh and
  uninstall actually clears the screen-reader path end-to-end.
- **Add/Remove Programs registration.** `AppsAndFeaturesRegistration`
  writes `HKLM\...\Uninstall\CivVIAccess` with DisplayName, Publisher,
  DisplayVersion, InstallLocation, UninstallString (→ our `--uninstall`
  flag), DisplayIcon, NoModify, NoRepair. Civ VI Access now appears in
  Settings → Apps → Installed Apps and uninstalling from there fires
  our standard uninstall path.

### IFEO transparent launch (fixed)

- **Both `CivilizationVI.exe` and `CivilizationVI_DX12.exe` registered.**
  Initial cut registered only the DX11 binary, which silently bypassed
  the launcher on DX12 systems (the default for many players on modern
  GPUs). `IfeoInstaller.TargetExeNames` is now an array; Install,
  Uninstall, GetRegisteredLauncherPath, and TryGetTransparentInvocationTarget
  all iterate both binaries.
- **IFEO infinite-recursion bug discovered + fixed.** Original
  `Process.Start(civVIPath)` from inside our launcher re-triggered our
  own IFEO redirect → infinite loop of launchers spawning launchers.
  New `ProcessLauncher.LaunchBypassingIfeo` uses `CreateProcess` with
  the `DEBUG_PROCESS` flag; Windows skips IFEO substitution when the
  caller is creating the child as a debugger.
- **DEBUG_PROCESS suspended-child bug discovered + fixed.** First cut
  of the bypass left Civ VI in suspended state after `CreateProcess` —
  the child waits for `WaitForDebugEvent` + `ContinueDebugEvent` before
  it can run. Now drains initial debug events (up to 32) and calls
  `DebugSetProcessKillOnExit(false)` so Civ VI survives our detach.

### Speech UX (fixed)

- **Removed launcher chatter cascade.** Previous version fired three
  Speak calls within ~300ms (`Civ VI Access Launcher ready` →
  `Checking for updates` → `Launching Sid Meier's Civilization VI`).
  With default interrupt=true semantics, NVDA only ever vocalized the
  last one, often cut off by Civ VI's focus change. Dropped the first
  two from speech entirely; they go to the log. Update check is
  silent on no-op (the common case); only speaks when actually
  applying updates. The single audible message at launch is now
  `Launching Sid Meier's Civilization VI.`

### Diagnostic infrastructure (new)

- **`Logger` class** writes to `%LocalAppData%\CivVIAccess\launcher.log`
  with append-only per-session traces (truncate on startup, ISO-8601
  timestamps, INFO/WARN/ERROR levels). Invaluable for post-mortem
  diagnosis when launcher console output is invisible (IFEO-spawned
  Steam launches inherit Steam's stdin/stdout, which goes nowhere).
  Surfaced this batch's bugs that we wouldn't have caught from speech
  alone.
- **Tolk detection probes logged** at startup: `DetectScreenReader`,
  `HasSpeech`, `IsLoaded`, `HasBraille`. Helps confirm post-install
  that Tolk + screen reader are wired up correctly.

### Carry-over from earlier in the same batch (pre-validation work)



- **Single-file distribution.** Launcher exe renamed `CivVIAccess.Launcher.exe`
  → `CivViAccess.exe` (no dots, camelCase). Tolk DLLs moved from
  sidecar-copy-to-output to embedded resources; `TolkBootstrap` extracts
  them next to the running .exe on every start. A downloaded
  `CivViAccess-X.Y.Z.exe` can now be dropped anywhere and double-clicked.
- **Mod folder rename.** `ScreenReaderAccess/` → `CivViAccessMod/` for
  symmetry with the launcher name. Also renames the modinfo file,
  civ6proj, and civ6sln. The mod's UUID (`49224623-…`) and user-facing
  `<Name>Screen Reader Access</Name>` are unchanged so existing Civ VI
  state migrates cleanly.
- **Transparent Steam launch via IFEO.** New `IfeoInstaller` writes
  `HKLM\…\Image File Execution Options\CivilizationVI.exe\Debugger` to
  point at the installed launcher. After `--install`, every
  CivilizationVI.exe launch (Steam Play, desktop shortcut, Big Picture,
  Steam URL) routes through the launcher first. The launcher passes
  through any args Steam supplied to Civ VI.
- **Installer / uninstaller.** `--install` flag elevates via UAC, copies
  the running exe to `%ProgramFiles%\Civ VI Access\CivViAccess.exe`,
  extracts Tolk DLLs alongside, and registers the IFEO entry. Bare-exe
  no-args run on an uninstalled machine triggers the same path. Targeted
  copy (not full BaseDirectory enumeration) so running from Downloads
  doesn't sweep up unrelated files.
- **Auto-update from GitHub Releases.** `GitHubReleasesClient` polls
  `api.github.com/repos/nromey/civ-vi-access/releases`. Version compare
  via three-part `SemVer`. Per-release assets: `CivViAccess-X.Y.Z.exe`
  (launcher) and `CivViAccessMod-X.Y.Z.zip` (mod tree). Launcher self-
  update lands as `<exe>.pending` and applies via in-place swap on next
  start (`Updater.ApplyPendingSelfUpdateAndRelaunchIfNeeded`).
- **Update channels.** `launcher.ini` next to the exe with
  `UpdateChannel=stable|latest|off`. `stable` filters out GH prereleases;
  `latest` includes them; `off` skips the check entirely (off is not
  recommended but available because users are users).
- **About / version mode.** `CivViAccess.exe --version` (or `--about`)
  prints + speaks version, running path, install state, update channel,
  and project URL.
- **Speech wording.** "Launching Civilization VI" → "Launching Sid Meier's
  Civilization VI" (and matching exit phrase). Update flow adds
  "Checking for updates." / "Updating mod to X.Y.Z." / "Update to X.Y.Z
  complete." steps before the launch line. Dev-checkout mode skips the
  update check (local source is presumed ahead of any release).
- **TFM moved to `net10.0-windows`.** Honest declaration of what the
  launcher needs — Tolk, registry, AttachThreadInput, IFEO are all
  Windows-only. Drops the now-redundant Microsoft.Win32.Registry NuGet
  reference (in-framework on `-windows`).

## 0.1.7 — 2026-05-14 — De-fork, localization scaffolding, launcher window UX

- **De-fork from upstream.** Rewrote the three upstream-derived Lua files
  (`ScreenReader.lua`, `ScreenReaderEventHandlers.lua`,
  `ScreenReaderPlotUtils.lua`) so no current-file line traces to the
  original craigbrett17 fork. Same public API surface; callers untouched.
- **Strings migration to LOC.** Audited 23 hardcoded user-facing string
  callsites across 5 Lua files and migrated them to 26 `LOC_CIVVIACCESS_*`
  entries in `Assets/Text/en_US/CivVIAccessStrings.xml`. All composition is
  via positional placeholders (`{1_Label}`, `{2_Value}`) so translators
  never deal with Lua-side punctuation. Singular/plural handled via two
  distinct keys + Lua-picks pattern (Crowdin-friendly across languages
  with 3+ plural forms).
- **Centralized icon-tag stripping.** `stripIconTags` consolidated into
  `ScreenReader.lua` from three local copies; `OutputMessageToScreenReader`
  now auto-strips on the way out so future callers can't forget.
- **Launcher focus-force.** New `WindowFocusManager` (~200 LOC). After
  `Process.Start`, polls for Civ VI's window handle and forces it
  foreground via the `AttachThreadInput` workaround, retrying every 200ms
  for up to 15 seconds. Fixes the "half the time focus stays on the
  launcher console" UX paper-cut.
- **Bidirectional follow-focus minimize.** While Civ VI runs, the launcher
  polls `GetForegroundWindow` every 250ms. When Civ VI takes foreground,
  console minimizes; when console takes foreground, Civ VI minimizes.
  Exactly one of the two on-screen at any time; Alt+Tab is the natural
  switcher.
- **Esc-at-top routes to exit dialog.** Pressing Escape at the top level
  of the main menu now fires the same `MainMenu_UserRequestClose` event
  Alt+F4 uses, opening the arrow-key-navigable Exit confirmation.
- **Bug fix: modinfo UpdateText.** Our localization XML was registered via
  `<UpdateDatabase>` which targets the Configuration DB (no `BaseGameText`
  table). Switched to `<UpdateText>` which targets the Localization DB.
  The original CivVIAccessHelp.xml was failing silently the whole time;
  ContextHelp's Lua-side fallback table masked the bug.
- **Bug fix: double-fire main menu announce.** `NotifyMainMenuBuilt` and
  `NotifyShow` both fire on initial load. Added a one-shot suppression
  flag so the initial show doesn't re-announce after the build path
  already did.
- **Project licensed MIT.** LICENSE file added; modinfo Authors updated.

## 0.1.6 — 2026-05-12 — Accessible Options screen

- All 7 tabs (Audio, Game, Graphics, Language, Interface, Application,
  KeyBindings) reachable and traversable via keyboard. Audio tab fully
  populated; other six expose Reset / Confirm / Close as a minimum so the
  screen is always dismissable.
- Slider / checkbox / pulldown / button / editbox kinds each have their
  own announce + adjust handlers. Sliders step by 5% (Ctrl+Left/Right for
  20%); pulldowns cycle entries with Left/Right; checkboxes toggle on
  Enter/Space.
- Page Up / Page Down for cross-tab nav (replaced Shift+Tab, which is
  unreliable through Civ VI's input pipeline). F1 announces a help body
  resolved through `ContextHelp.Speak("OPTIONS")`.

## 0.1.5 — 2026-05-11 — MainMenu re-announce on return; Batch 02 polish

- MainMenu re-announces the current focus when returning from a sub-screen
  (Options → back, AdvancedSetup → back, etc.) so the user lands oriented.
- Icon-tag stripping applied to button label reads (Civ VI buttons embed
  `[ICON_*]` markers that read literally as nonsense).
- Tighter back-cue wording ("Main menu" instead of the verbose original)
  pending a dedicated earcon.
- `TESTING.md` rewritten from table layout to flat numbered steps for
  screen-reader friendliness.

## 0.1.4 — 2026-05-10 — Accessible LoadGameMenu

- Up / Down / Left / Right cycles through saves with wrap-at-edges.
- Home / End jump to first / last entry.
- Empty-list state announces with explicit "Press Escape to go back."
- File-list re-query on sort / filter changes re-announces the new state.

## 0.1.3 — 2026-05-09 — Accessible main menu, Alt+F4 dialog, first-launch EULA

- Main menu kb nav: arrow keys move focus across options, Enter/Space
  activates, Escape backs out of submenus. Selection plays the existing
  `Main_Menu_Mouse_Over` cue plus a spoken label.
- Alt+F4 "Exit to Desktop?" dialog made arrow-key-navigable per the
  project popup nav standard.
- First-launch EULA screen narrates the copyright text and "Press Enter
  to accept" prompt; auto-accept path (returning users) stays silent.

## 0.1.2 — 2026-05-08 — Launcher: auto-deploy + log watcher + first-launch detection

- Launcher walks the source tree on every run and copies mod files into
  Civ VI's DLC dir before spawning the game. No more manual `cp` between
  edits.
- Background `LogFileWatcher` tails `Lua.log` and routes prefix-marked
  lines (`#SCREENREADER` / `#SCREENREADER[NOINTERRUPT]`) to Tolk.
- First-launch detection via `UserOptions.txt` `CopyrightAccept` key;
  tailors the pre-game announcement to first-time vs. returning users.

## 0.1.1 — 2026-05-07 — Tolk integration, .NET 10 launcher

- Swapped from AccessibleOutput (.NET Framework, dormant) to Tolk
  (cross-screen-reader, actively maintained). Removes the .NET Framework
  install requirement.
- Console app retargeted at `net10.0` x64, renamed to
  `CivVIAccess.Launcher`, spawns Civ VI as a child process.
- Vendored Tolk x64 DLLs under `third_party/tolk/`.

## Earlier — Inherited from upstream

The codebase was originally a fork of
[craigbrett17/civilization-vi-screenreader-access](https://github.com/craigbrett17/civilization-vi-screenreader-access),
which shipped basic plot tooltip + selection-change announce. All
upstream-derived Lua files were rewritten in this codebase on 2026-05-14
(see top entry); no current-file line traces to the upstream as of that
date.
