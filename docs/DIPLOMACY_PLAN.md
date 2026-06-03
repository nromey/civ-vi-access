# Accessible Diplomacy / Meet-a-Leader

Making the Civ VI `DiplomacyActionView` (leader screen) screen-reader
navigable — the "rest of meet-a-leader." Design locked 2026-06-02 with Noel.

## Status

- **Foundation — DONE & validated live (2026-06-02).** `LeaderMeetAnnounce`
  speaks who + mood expression + the leader's greeting on screen open.
  Greeting control path locked: `/InGame/DiplomacyActionView/LeaderResponseText`
  (conversation mode); `VoiceoverText` retained as the untested first-meet
  cinematic fallback. Debug trigger: **Alt+M** (or FireTuner
  `LuaEvents.CivViAccess_DebugMeetLeader()`) opens diplomacy with the first
  met major civ — repeatable test without waiting for a natural first contact.
- **The screen itself — TO BUILD.** Right now we announce the leader but the
  screen isn't navigable; you can only Escape out.

## Core design principle: thin reader over engine-populated statements

Both Civ V Access AND the base Civ VI screen are **data-driven** — the action
list comes from the `DiplomacyStatements` DB, filtered through
`Player:GetDiplomacy():IsDiplomaticActionValid(actionType, otherID, true)`.
So we do NOT hardcode or reimplement the diplomacy vocabulary. We read the
statements the engine considers valid, present them as a navigable list, and
route selection back through the engine's own `OnSelectInitialDiplomacyStatement`.
Correct across patches and expansions for free.

Open implementation question to resolve first: enumerate the actions by
**reading the populated button controls** (Civ V Access's approach — traverse
the statement container, read each button's live text) vs **re-deriving** the
valid statement list from the DB + `IsDiplomaticActionValid`. Reading the
populated controls is lower-risk if the container is traversable cross-context
(same technique that worked for `LeaderResponseText`); re-deriving avoids UI
coupling but reimplements `ExtractStatement`/`RemoveInvalidSelections` (which
are local to `DiplomacyActionView.lua`, not global).

## Layout — HYBRID (Noel's call 2026-06-02)

- **Top level, flat:** the common actions — Declare Friendship, Denounce,
  Diplomatic Delegation, Resident Embassy, Open Borders, Make Deal — plus
  Make Peace when at war. Fewest keypresses for everyday diplomacy.
- **"War" submenu:** the war declarations (Surprise/Formal/Holy/Liberation/
  Reconquest/Protectorate/Colonial/Territorial — whichever Casus Belli are
  valid) tucked one level down so they can't be fired by accident.
- Read each item on focus (terse: label + state), Enter to select, Escape to
  leave. Disabled actions are **read with their reason** (e.g. "Declare
  Friendship, unavailable: you denounced them" via the `FailureReasons`
  tooltip) — teach why, don't just hide.

## Preamble + relationship readout

- On open (have): leader name + mood expression + greeting.
- Add on a **re-readable key** (terse default, detail on demand — the Ctrl+T
  idiom): diplomatic state, the top "why they feel this way" modifiers
  (`GetDiplomaticAI():GetDiplomaticModifiers(localID)` → `[{Score,Text}]`,
  sorted by score), access/visibility level, and agenda(s). Not auto-dumped.

## Confirm dialogs

War and Denounce route through a confirmation popup. Handle it as a Yes/No
sub-list pushed on top (the Civ V Access overlay-detection child-handler
pattern), so the confirm stays keyboard-navigable.

## Expansion gating

Grievances / Diplomatic Favor (Gathering Storm) and Alliances / Emergencies
(Rise & Fall) and the World Congress tab are expansion-only. `GetGrievancesAgainst`
/ favor APIs do NOT exist in base — guard every such readout behind an
expansion check (see `reference_popup_expansion_gating`).

## DEFERRED — add trade to the diplomacy picker (Noel 2026-06-02)

**v1 ships the statement actions only.** "Make Deal" for now opens the vanilla
deal screen (`DiplomacyDealView`) as-is — NOT yet accessible. **TODO: once the
deal/trade screen is designed (offer/request items, gold, cities, agreements),
wire an accessible deal-builder into the diplomacy picker as a follow-up pass.**
The deal screen is a separate, complex UI and is its own project; this note is
the reminder to come back and add it.

## API cheat-sheet (from 2026-06-02 research)

- Availability: `Player:GetDiplomacy():IsDiplomaticActionValid(actionType, otherID, true)` → `(bValid, {FailureReasons})`
- Cost: `GetDiplomacy():GetDiplomaticActionCost(actionString)`
- Diplomatic state: `selectedPlayer:GetDiplomaticAI():GetDiplomaticStateIndex(localID)` → `GameInfo.DiplomaticStates[i].Name`
- "Why" reasons: `GetDiplomaticAI():GetDiplomaticModifiers(localID)` → `[{Score,Text}]`
- Access level: `GetDiplomacy():GetVisibilityOn(otherID)` → `GameInfo.Visibilities[i].Name`
- Agendas: `selectedPlayer:GetAgendaTypes()` (entry 1 = historical; rest = random, access-gated by `GameInfo.Visibilities[...].RevealAgendas`)
- Mood: `DiplomacySupport_GetPlayerMood(player, localID)` (in `DiplomacyStatementSupport.lua`)
- Open the screen: `LuaEvents.DiplomacyRibbon_OpenDiplomacyActionView(playerID)` (raises `Events.ShowLeaderScreen` even for an already-met leader — validated 2026-06-02)
- Base screen file: `…/Base/Assets/UI/DiplomacyActionView.lua`; statement plumbing in `DiplomacyStatementSupport.lua`.
- Reusable list-nav in the mod: `ChoosePopupAccess.lua` (lighter) and `BaseMenu.lua`/`BaseMenuItems.lua` (declarative, submenus — the better fit for hybrid grouping + confirm sub-lists).
