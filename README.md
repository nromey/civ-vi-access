# Civ VI Access

A screen-reader accessibility mod for Sid Meier's Civilization VI. Lets
blind and visually impaired players hear the text and UI state the game
normally only displays visually, and provides keyboard navigation for
screens that ship mouse-only in the base game.

## What's accessible right now

- **Main menu.** Arrow-key navigation across options, Enter / Space to
  activate, Escape backs out of submenus or opens the Exit-to-Desktop
  prompt at the top level. Selection plays the engine's existing nav cue
  plus a spoken label.
- **First-launch EULA.** Copyright text and "Press Enter to accept"
  prompt are narrated. Returning users get a silent gate-pass exactly the
  way they did before this override.
- **Alt+F4 / Exit dialog.** Arrow-key-navigable buttons, Esc cancels,
  Enter activates the focused button.
- **Load Game menu.** Arrow keys cycle saves, Home / End for first /
  last, count + nav-help announced on entry.
- **Options screen.** All 7 tabs reachable via Page Up / Page Down.
  Audio tab fully wired (sliders adjust by keyboard, checkboxes toggle).
  Other tabs are reachable and dismissable as a minimum; per-tab content
  fills in per session.
- **Plot tooltips, unit / city selection, notifications, tech & civic
  research completion** announce via Tolk when the player interacts with
  them in-game.

## How it works

Civ VI mods run inside the game's Lua sandbox and have no way to call
external DLLs, make HTTP requests, write files, or otherwise talk to
processes outside the game. To bridge that gap, this project pairs two
pieces:

1. **The mod itself** (`CivViAccessMod/`) runs inside Civ VI. When it
   has something to announce, it `print()`s the line into Civ VI's
   `Lua.log` with a special prefix marker (`#SCREENREADER -` or
   `#SCREENREADER[NOINTERRUPT] -`).
2. **The launcher** (`CivViAccess/`) is a small .NET 10 console
   app that runs alongside the game. It tails `Lua.log`, parses prefix-
   marked lines, and routes them to the user's screen reader via
   [Tolk](https://github.com/dkager/tolk) — which speaks to NVDA, JAWS,
   Narrator, SAPI, and a handful of others without the mod having to know
   which one is running.

The launcher also:

- **Deploys the mod source tree** into Civ VI's DLC directory on every
  run, so the dev loop is "edit source → launch → retest" without manual
  copying.
- **Forces foreground on Civ VI** after spawn. Without this, Windows
  refuses the handoff about half the time and the user's keystrokes land
  on the launcher console instead of the game. We retry for up to 15
  seconds using the `AttachThreadInput` workaround.
- **Minimizes whichever window isn't focused.** Console and Civ VI take
  turns being on screen; Alt+Tab switches naturally between them.
- **Spawns Civ VI as a child process** so closing the launcher also
  closes the game cleanly.

## Running it

You need:

- A Steam install of
  [Civilization VI](https://store.steampowered.com/app/289070/Sid_Meiers_Civilization_VI/)
  at the default path (`C:\Program Files (x86)\Steam\steamapps\common\Sid Meier's Civilization VI`).
  If yours is elsewhere, edit the `civVIPath` constant in
  `CivVIAccess.Launcher/Program.cs`.
- A screen reader Tolk supports (NVDA, JAWS, Narrator, SAPI, and others —
  see Tolk's docs for the full list).

Build and run:

```
dotnet run --project CivVIAccess.Launcher
```

The launcher will copy the mod into Civ VI's DLC directory, launch the
game, and start tailing `Lua.log`. You should hear "Civ VI Access
Launcher ready" via your screen reader within a second or two.

## Building / hacking

- **.NET 10 SDK** for the launcher.
- **The Civ VI source files** under `Base/Assets/UI/` (in your Steam
  install) are the reference for any Lua we fork — diff against them when
  the game patches and re-apply our hooks.

The launcher publishes as Native AOT (a single ~10-20 MB .exe with no
runtime install requirement). From a Developer PowerShell or Developer
Command Prompt (so MSVC `link.exe` is on PATH):

```
dotnet publish CivVIAccess.Launcher -c Release -r win-x64
```

Output lands in `CivVIAccess.Launcher/bin/Release/net10.0/win-x64/publish/`.
Regular `dotnet build` for development doesn't need the VC env — AOT
compilation only runs during `dotnet publish`.

## Status

This mod is a work in progress. Significant pieces of in-game UI are
still mouse-only or only partially announced. The goal is full keyboard
navigability and full announcement of game state for a blind player —
we're not there yet, but the foundation (Tolk bridge, launcher, per-
screen companion pattern, LOC-table-backed strings) is in place.

## Contributing

Help is welcome. The project is set up for the per-screen companion
pattern: every accessible screen has a fork of the Firaxis Lua file plus
a `*Access.lua` companion that owns the keyboard nav + speech wiring.
Adding a new screen mostly means reading the Firaxis source for that
screen and adding the companion.

## Acknowledgements

This project began as a fork of
[craigbrett17/civilization-vi-screenreader-access](https://github.com/craigbrett17/civilization-vi-screenreader-access),
which provided early plot tooltip and selection-announce work. The
upstream codebase has been dormant since 2018; all upstream-derived files
in this repository were rewritten on 2026-05-14 to relicense the codebase
under MIT (see [LICENSE](LICENSE)). The original architectural insight —
that a Lua-side `print()` plus a log-tailing external process is the only
viable speech bridge for a Civ VI mod — is craigbrett17's.

[Tolk](https://github.com/dkager/tolk) is by Davy Kager, distributed under
the LGPL 3.0.

## License

MIT. See [LICENSE](LICENSE). See [CHANGELOG.md](CHANGELOG.md) for the
project's history.
