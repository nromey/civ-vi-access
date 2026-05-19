-- Verbosity setting. Binary chatty / terse toggle that gates whether arrow-
-- key landings in a BaseMenu-powered screen speak the full describe() text
-- (label + value + tooltip / parameter description) or just the lighter
-- announce() text (label + value).
--
-- Toggled via Alt+V from any BaseMenu screen. Default chatty because the
-- highest-value first-time decisions (leader, ruleset, map type) live in
-- pulldowns whose entry descriptions are the only useful differentiator —
-- you can't pick between "Continents" and "Lakes" without hearing what
-- each one means. Ctrl+T continues to force describe() regardless of
-- mode, for callers who want a one-shot expansion while in terse mode.
--
-- Persistence is in-memory only for v1; a future settings screen will
-- bind setOn() to a UserConfiguration-backed toggle so the preference
-- survives across launches.

Verbosity = Verbosity or {}

local _on = true

function Verbosity.isOn()
    return _on
end

function Verbosity.setOn(on)
    _on = on and true or false
    return _on
end

function Verbosity.toggle()
    _on = not _on
    return _on
end
