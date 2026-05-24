-- LIFO of active input handlers. The top of the stack is the currently
-- focused screen / overlay; InputRouter walks from the top on each keypress.
--
-- Handler shape (a plain Lua table pushed onto the stack):
--   name             (string, required) unique-ish; used by removeByName + logs.
--   capturesAllInput (bool, default false) barrier for InputRouter's top-down
--                    walk AND for Help's collectHelpEntries walk. Stays false
--                    for almost all handlers. Set true only for modal-like
--                    contexts (popups, confirmations, overlays) that should
--                    swallow unbound keys.
--   bindings         (array, optional) {key, mods, fn, description} entries.
--                    The handler owns its bindings; there is no central registry.
--   helpEntries      (array, required when handler has bindings) authored
--                    {keyLabel, description} entries for the ? help overlay.
--                    Handlers with no user-visible bindings should set this to
--                    an empty {} to opt in explicitly. keyLabel is a LOC key
--                    for a merged human-readable chord label ("Up/Down",
--                    "Ctrl+Shift+Left/Right"); description is a LOC key.
--   onActivate       (fn(self), optional) fired on push / re-exposure (becomes
--                    new top of stack).
--   onSuspend        (fn(self), optional) fired when this handler stops being
--                    the top because something is pushed above it. Distinct
--                    from onDeactivate: the handler is still on the stack and
--                    will receive onActivate again when re-exposed. Use for
--                    pausing background work that only makes sense while the
--                    handler is the input target.
--   onDeactivate     (fn(self), optional) fired on removal from the stack.
--
-- Cross-Context note: Civ VI's UI Contexts are sandboxed; each file imported
-- via the modinfo gets its own HandlerStack instance (no proxy-injected shared
-- table like Civ V Access uses). That is acceptable for our model — modal
-- pickers in Civ VI run as their own Context with their own input focus, so
-- a per-Context stack matches the engine's actual scoping. The Globals
-- handler (Alt+V, Ctrl+T) is pushed at the bottom of every Context's stack
-- so common hotkeys work everywhere.
--
-- Engine-agnostic — no DirectionTypes / LuaEvents / UI.* here. Ports as-is
-- per [[project-cross-game-foundation]].

include("Log");

HandlerStack = HandlerStack or {};

local _stack = {};
local _onMutated = nil;

-- Constructor for a single binding entry. Handlers import as
-- `local bind = HandlerStack.bind` so call sites read as
-- bind(key, mods, fn, desc).
function HandlerStack.bind(key, mods, fn, description)
    return { key = key, mods = mods, fn = fn, description = description };
end

-- Single-listener slot for stack-mutation side effects (currently only Help
-- needs to know about pushes / pops, e.g. to refresh an open help overlay).
-- If a second subscriber materializes, change to a table-of-listeners.
function HandlerStack.setOnMutated(fn)
    _onMutated = fn;
end

local function notifyMutated()
    if type(_onMutated) == "function" then
        Log.tryCall("HandlerStack.onMutated", _onMutated);
    end
end

local function invokeLifecycle(handler, methodName)
    local fn = handler[methodName];
    if type(fn) ~= "function" then
        return true;
    end
    return Log.tryCall(
        "HandlerStack." .. methodName .. " on '" .. tostring(handler.name) .. "'",
        fn, handler
    );
end

function HandlerStack.count() return #_stack; end
function HandlerStack.active() return _stack[#_stack]; end
function HandlerStack.at(i)    return _stack[i]; end

local function warnIfMissingHelpEntries(handler, callerName)
    if handler.helpEntries == nil and type(handler.bindings) == "table" and #handler.bindings > 0 then
        Log.warn(
            "HandlerStack." .. callerName .. ": '" .. tostring(handler.name)
            .. "' has bindings but no helpEntries; ? help will not list it."
            .. " Set helpEntries (or an explicit {}) to opt in."
        );
    end
end

function HandlerStack.push(handler)
    if handler == nil then
        Log.warn("HandlerStack.push: nil handler");
        return false;
    end
    warnIfMissingHelpEntries(handler, "push");
    -- onActivate fires BEFORE the handler is added to the stack so a refused
    -- push (callback threw) doesn't leave a half-installed handler behind.
    if not invokeLifecycle(handler, "onActivate") then
        return false;
    end
    local prevTop = _stack[#_stack];
    if prevTop ~= nil then
        invokeLifecycle(prevTop, "onSuspend");
    end
    _stack[#_stack + 1] = handler;
    Log.debug("HandlerStack.push '" .. tostring(handler.name) .. "' (depth=" .. #_stack .. ")");
    notifyMutated();
    return true;
end

function HandlerStack.pop()
    local n = #_stack;
    if n == 0 then
        Log.warn("HandlerStack.pop: empty stack");
        return nil;
    end
    local top = _stack[n];
    _stack[n] = nil;
    invokeLifecycle(top, "onDeactivate");
    Log.debug("HandlerStack.pop '" .. tostring(top.name) .. "' (depth=" .. #_stack .. ")");
    local newTop = _stack[#_stack];
    if newTop ~= nil then
        invokeLifecycle(newTop, "onActivate");
    end
    notifyMutated();
    return top;
end

function HandlerStack.replace(handler)
    if #_stack > 0 then
        local top = _stack[#_stack];
        _stack[#_stack] = nil;
        invokeLifecycle(top, "onDeactivate");
    end
    return HandlerStack.push(handler);
end

-- reactivate defaults true. Pass false when the caller is about to push
-- something else (idempotent clear-before-repush): firing onActivate on the
-- handler underneath would spuriously announce a screen the user is about
-- to be pulled off of.
function HandlerStack.removeByName(name, reactivate)
    if reactivate == nil then reactivate = true; end
    for i = #_stack, 1, -1 do
        if _stack[i].name == name then
            local h = _stack[i];
            local wasTop = (i == #_stack);
            table.remove(_stack, i);
            invokeLifecycle(h, "onDeactivate");
            Log.debug("HandlerStack.removeByName '" .. tostring(h.name) .. "' (depth=" .. #_stack .. ")");
            if wasTop and reactivate then
                local newTop = _stack[#_stack];
                if newTop ~= nil then
                    invokeLifecycle(newTop, "onActivate");
                end
            end
            notifyMutated();
            return true;
        end
    end
    return false;
end

-- Pop everything above `target` (without reactivating intermediates), then
-- expose target as the new top. Used by Esc-like flows that close several
-- nested overlays at once.
function HandlerStack.popAbove(target)
    for i = 1, #_stack do
        if _stack[i] == target then
            for j = #_stack, i + 1, -1 do
                local h = _stack[j];
                _stack[j] = nil;
                invokeLifecycle(h, "onDeactivate");
            end
            invokeLifecycle(_stack[i], "onActivate");
            notifyMutated();
            return true;
        end
    end
    return false;
end

function HandlerStack.clear()
    _stack = {};
    notifyMutated();
end

-- Test seam: lets suites reset between cases. Production never calls this.
function HandlerStack._reset()
    _stack = {};
    _onMutated = nil;
    HandlerStack.commonHelpEntries = {};
end

-- Always-on help entries appended at the bottom of every collected list.
-- For mod-wide hotkeys reachable at every depth (Alt+V, Ctrl+T, ? itself).
-- Authored as {keyLabel, description} LOC keys.
HandlerStack.commonHelpEntries = {};

function HandlerStack.registerCommonHelpEntry(entry)
    HandlerStack.commonHelpEntries[#HandlerStack.commonHelpEntries + 1] = entry;
end

-- Walk the stack top-to-bottom (mirroring InputRouter's dispatch walk),
-- collecting authored helpEntries from each reachable handler. Stops AFTER
-- the first capturesAllInput handler (inclusive — the modal's own entries
-- are listed, but no handler below the modal is reachable for help purposes
-- since none of its keys would fire). Deduplicates by keyLabel string —
-- topmost wins. Convention: keyLabels must be canonically merged ("Up/Down"
-- not "Up"), otherwise dedupe can't collapse equivalent entries from stacked
-- handlers. Appends commonHelpEntries at the end (also dedup-checked).
function HandlerStack.collectHelpEntries()
    local seen = {};
    local out = {};
    for i = #_stack, 1, -1 do
        local h = _stack[i];
        if type(h.helpEntries) == "table" then
            for _, e in ipairs(h.helpEntries) do
                local k = tostring(e.keyLabel);
                if not seen[k] then
                    seen[k] = true;
                    out[#out + 1] = e;
                end
            end
        end
        if h.capturesAllInput then
            break;
        end
    end
    for _, e in ipairs(HandlerStack.commonHelpEntries) do
        local k = tostring(e.keyLabel);
        if not seen[k] then
            seen[k] = true;
            out[#out + 1] = e;
        end
    end
    return out;
end
