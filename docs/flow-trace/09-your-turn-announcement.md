# 09 — Your-turn announcement

When the local player's turn begins each round, the engine fires
`Events.LocalPlayerTurnBegin`. Sighted players see the action
panel and turn indicator update; blind players need to hear it.

Currently: `Diagnostics.lua` logs the event to `lua.log` for
verification purposes but does NOT speak anything. Need to wire
a real screen-reader announce.

This fires **every turn for the rest of the game** — hundreds
of times in a long playthrough. Brevity matters more here than
anywhere else in the trace plan.

## Engine source

- No dedicated Lua file — this is an engine-fired event.
- Hook: `Events.LocalPlayerTurnBegin()` (no parameters; the
  local player is implicit)
- Sibling events worth knowing:
  - `Events.LocalPlayerTurnEnd()` — fires when player ends turn
  - `Events.PlayerTurnActivated(playerID, isFirstTimeThisTurn)`
    — fires for whichever player becomes active (incl. AI)
  - `Events.TurnBegin()` — fires once per game turn (any player)
- These are all ruleset-invariant engine events.

## How it opens

- Player presses End Turn → engine processes AI turns →
  eventually `Events.LocalPlayerTurnBegin` fires for the next
  local-player turn
- Also fires once at the very start of the game after the
  first-turn popups (waypoints 05 + 06) close, when the world
  becomes interactive for the first time

## What appears visually

- Action panel updates to show "Your Turn" indicator
- End Turn button enables
- Camera may auto-center on a unit needing orders
- Notification panel may show new notifications (research
  completed, civic adopted, unit healed, etc.)
- Action panel sometimes flashes a "begin turn" animation

## What it accepts as input

This event itself doesn't accept input — it's a fire-and-forget
notification. The general in-game input system (HexCursor, unit
movement keys, etc.) becomes active when the turn begins.

## How it closes / advances

- Player ends turn (Enter / End Turn hotkey) → engine fires
  `LocalPlayerTurnEnd`, processes AI turns, eventually fires
  `LocalPlayerTurnBegin` again for the next round
- No close path for the event itself — it's a one-shot signal

## Ruleset variants

Event itself is ruleset-invariant. Content variation:

- **Vanilla**: turn N + era + year
- **R&F + GS**: same, plus optional era-score / age indicator
  (Dark Age, Golden Age, Heroic Age) which Vanilla doesn't have
- **GS**: World Congress timer counts down on certain turns

For ramps-quality, all rulesets get the same basic "Turn N"
announce. Polish layer can add ruleset-specific context.

## Current accessibility state

**Zero — only logged.** `Diagnostics.lua` line 46 subscribes
`Events.LocalPlayerTurnBegin` to a logger; the logger writes to
`lua.log` but never speaks anything via Tolk.

Player has no audible cue when their turn begins. They have to
guess from absence-of-AI-turn-sounds when control has returned.
This is one of the most frequently-needed announces in the
game.

## Blind-first design

**Terse by default** — this fires every turn, hundreds of times
per game. Long announces become unbearable.

**Default announce**: `"Turn {N}."`
- Example: "Turn 47."
- Spoken at minimum priority (interruptible if user is mid-
  speech on something else)
- Preceded by a short earcon ("turn-begin chime") so the audio
  cue is recognizable without speech parsing

**Verbose mode** (off by default, opt-in via
[[project-verbosity-someday]] toggle when shipped):
- `"Turn {N}, {Era} Era, year {Year}."`
- Example: "Turn 47, Classical Era, year 200 BC."
- Era from `Game.GetEras():GetCurrentEra()`
- Year from `Calendar.MakeYearStr(Game.GetCurrentGameTurn())`

**Optional augmentation** (if non-zero, separate queued line):
- `"{N} notifications pending."` — only when count > 0
- `"{N} units have moves remaining."` — only at turn-START
  (not the end-of-turn warning that should fire separately)

**Turn 1 special case**: this event fires once after first-turn
popups close. For the FIRST turn, the announce is part of the
waypoint 08 first-turn unit auto-select orientation, not this
generic announce. Detect `currentTurn == startTurn` and skip
the generic announce (waypoint 08 handles the briefing).

**End-of-turn reminders** (separate concern, future work):
- When player tries to End Turn with unmoved units, engine
  shows a "you have units that can still move" warning popup
- That's a different event flow (`UnitOperations_ClearStateOnUnit`
  or similar); not waypoint 09

## Implementation notes

**New file**: `CivViAccessMod/Assets/UI/Accessibility/TurnAnnouncements.lua`
- Register via `<AddGameplayScripts>` in modinfo (same context
  as ScreenReaderEventHandlers.lua)

**Code outline** (~50 LOC):

```lua
include("ScreenReader")
include("Log")

local function announceTurnBegin()
  local currentTurn = Game.GetCurrentGameTurn()
  local startTurn = GameConfiguration.GetStartTurn()

  -- Turn 1 is handled by waypoint 08's first-turn orientation;
  -- skip the generic announce so we don't double-speak.
  if currentTurn == startTurn then
    return
  end

  local text = Locale.Lookup(
    "LOC_CIVVIACCESS_TURN_BEGIN_FORMAT", currentTurn)

  -- Optional earcon hook: UI.PlaySound("Notification_Generic")
  -- or a custom earcon once the audio bank lands.

  OutputMessageToScreenReader(text)

  -- Augment with notification count if non-zero
  local pPlayer = Players[Game.GetLocalPlayer()]
  if pPlayer ~= nil then
    local notifications = pPlayer:GetNotifications()
    if notifications ~= nil then
      local count = notifications:GetCount()
      if count > 0 then
        OutputMessageToScreenReader(
          Locale.Lookup(
            "LOC_CIVVIACCESS_TURN_NOTIFICATIONS_PENDING", count),
          true)  -- queued, not interrupting
      end
    end
  end
end

Events.LocalPlayerTurnBegin.Add(announceTurnBegin)
```

**LOC strings to add**:
- `LOC_CIVVIACCESS_TURN_BEGIN_FORMAT` — "Turn {1_N}."
- `LOC_CIVVIACCESS_TURN_NOTIFICATIONS_PENDING` —
  "{1_N} notifications pending."

**Diagnostics.lua removal**: once this ships and we verify it
fires correctly, remove the `tryAdd(Events,
"LocalPlayerTurnBegin")` line from Diagnostics — that file is
diagnostic-only and the comment explicitly says "Remove after we
identify the in-game failures." Per [[feedback-fix-bugs-when-seen]],
the cleanup belongs in this PR if Diagnostics is otherwise
stable, OR file a follow-up to delete Diagnostics entirely once
all events it tracks have real announcers.

**Modinfo**: register `TurnAnnouncements.lua` under the same
`<AddGameplayScripts>` block as `ScreenReaderEventHandlers.lua`.

**Estimated LOC**: ~50 + 2 LOC strings (per
[[feedback-loc-estimates-anchor-low]] → ~100-150 real).

## Test plan

Single playthrough, all rulesets benefit identically.

1. Start a new game (any ruleset). Click through popups.
2. Verify NO "Turn 1" announce — first-turn orientation from
   waypoint 08 should fire instead.
3. Press End Turn → AI turns process → on next turn:
   - Verify "Turn 2." announces.
4. Continue playing for a few turns. Verify each turn
   announces "Turn N." with correct N.
5. Trigger a notification (e.g., complete a research project,
   build a unit) → next turn should announce "Turn N. N
   notifications pending."
6. Verify the announce is terse enough that it doesn't intrude
   on rapid play. If you press End Turn quickly, no overlap.
7. Verify announce works after `PlayerChange_Show` (hotseat
   mode) — when control returns to the local human.

## Cross-references

- [[feedback-terse-announce-default]] — this is the canonical
  terse case
- [[project-verbosity-someday]] — future verbose mode adds
  era / year context
- Waypoint 08 — first-turn orientation, fires INSTEAD of this
  generic announce on turn 1
- `CivViAccessMod/Assets/UI/Accessibility/Diagnostics.lua` —
  contains the current log-only subscription to remove
- `CivViAccessMod/Assets/UI/Accessibility/ScreenReaderEventHandlers.lua`
  — sibling gameplay script for selection events; turn
  announce belongs in a sibling file
- [[project-announce-engine-actions]] — broader engine-event
  announcement framework that this fits into
