-- Verbosity setting. Binary chatty / terse toggle that gates whether reads
-- speak the full describe()/detail text or just the lighter announce() text.
-- Toggled via Alt+V.
--
-- SHARED ACROSS CONTEXTS (2026-06-02): Civ VI UI Contexts are sandboxed Lua
-- states, so a plain `local _on` only toggles the Context you pressed the key
-- in — Alt+V in the world view would never reach PlotToolTip's separate
-- Context. So setOn() broadcasts LuaEvents.CivViAccess_VerbosityChanged and
-- every Context's Verbosity (each include()s this file) syncs its local copy.
-- Now one Alt+V gates reads everywhere. (Edge case, acceptable for v1: a
-- Context loaded AFTER a toggle misses that broadcast until the next toggle;
-- and state is in-memory, resetting each launch. A future settings screen
-- binds this to UserConfiguration for persistence + load-time sync.)
--
-- DEFAULT: TERSE (_on=false), confirmed by Noel 2026-06-02 ("make it work
-- across the whole mod ... more robust that way"). In-game reads are brief by
-- default; chatty is opt-in via Alt+V. Setup screens whose pulldown entry
-- descriptions are the only useful differentiator (AdvancedSetup, etc.) must
-- NOT rely on this global default — they set BaseMenu's alwaysVerbose so they
-- stay chatty regardless of the global terse default. That keeps the model
-- robust: one global default (terse), screens opt INTO always-chatty where the
-- detail is essential.

Verbosity = Verbosity or {}

local _on = false

function Verbosity.isOn()
    return _on
end

-- Set the local copy without re-broadcasting (used by the sync listener).
local function applyLocal(on)
    _on = on and true or false
    return _on
end

function Verbosity.setOn(on)
    applyLocal(on)
    -- Broadcast so every other sandboxed Context's Verbosity stays in sync.
    if LuaEvents ~= nil then
        LuaEvents.CivViAccess_VerbosityChanged(_on)
    end
    return _on
end

function Verbosity.toggle()
    return Verbosity.setOn(not _on)
end

-- Sync to toggles fired from any other Context. applyLocal (not setOn) so the
-- broadcast doesn't echo back into an infinite loop.
if LuaEvents ~= nil then
    LuaEvents.CivViAccess_VerbosityChanged.Add(function(on) applyLocal(on) end)
end
