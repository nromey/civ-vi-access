-- Help overlay: ? opens a navigable list of bindings reachable from the
-- current HandlerStack, built from each handler's authored helpEntries.
--
-- Architectural pattern: Help is NOT a separate BaseMenu / ContextPtr —
-- Civ VI's ContextPtr:SetInputHandler is replace-semantics per Context, so
-- spawning a new BaseMenu for help would either fight the host screen's
-- input or require yanking the host out of input ownership. Instead Help
-- is a transient sub-mode of the host handler (BaseMenu screen or HexCursor),
-- toggled by stashing `handler._helpMode = { ... }` on the host. The host's
-- input dispatcher delegates to Help.handleKey while the flag is set; on
-- exit the host's normal navigation resumes.
--
-- This mirrors BaseMenu's existing transient-sub-handler pattern (the
-- _activeSubMenu used by Pulldown pickers).
--
-- State shape on handler._helpMode:
--   entries          (table) snapshotted from HandlerStack.collectHelpEntries
--                    at open time; the stack may mutate while help is up.
--   index            (number) cursor position into the visible (filtered) list.
--   filter           (string | nil) active filter substring; nil = no filter.
--   inputMode        (bool) currently TYPING into a filter (Ctrl+F engaged).
--   buffer           (string) accumulator while inputMode is true.
--   _visibleCount    (number) cached size of the filtered list; refreshed on
--                    every speakCurrent call so nav bounds match what's spoken.

include("Log");
include("ScreenReader");
include("HandlerStack");

Help = Help or {};

-- '/' / '?' is Windows VK_OEM_2 (0xBF = 191). Civ VI exposes it as
-- Keys.VK_OEM_2; fall back to the literal if the symbol isn't defined yet.
local VK_OEM_2 = (Keys ~= nil and Keys.VK_OEM_2) or 191;

-- Public — used by host input handlers to detect the ? chord without
-- duplicating the VK literal.
Help.VK_QUESTION = VK_OEM_2;

-- Resolve a help entry's key+description pair into a single spoken line.
-- keyLabel / description can be LOC keys (preferred) or raw strings (for
-- early-development fallback before strings land).
local function resolveEntry(entry)
    local keyText = entry.keyLabel or "";
    local descText = entry.description or "";
    if Locale ~= nil and Locale.Lookup ~= nil then
        if type(keyText) == "string" and keyText:sub(1, 4) == "LOC_" then
            local t = Locale.Lookup(keyText);
            if t ~= nil and t ~= "" and t ~= keyText then keyText = t; end
        end
        if type(descText) == "string" and descText:sub(1, 4) == "LOC_" then
            local t = Locale.Lookup(descText);
            if t ~= nil and t ~= "" and t ~= descText then descText = t; end
        end
    end
    return tostring(keyText) .. ": " .. tostring(descText);
end

-- Filter entries by case-insensitive substring match against the resolved
-- line. Empty / nil filter returns all entries.
local function applyFilter(entries, filter)
    if filter == nil or filter == "" then
        return entries;
    end
    local needle = string.lower(filter);
    local out = {};
    for _, e in ipairs(entries) do
        local line = string.lower(resolveEntry(e));
        if string.find(line, needle, 1, true) ~= nil then
            out[#out + 1] = e;
        end
    end
    return out;
end

local function speakCurrent(state)
    local visible = applyFilter(state.entries, state.filter);
    state._visibleCount = #visible;
    if #visible == 0 then
        OutputMessageToScreenReader("No matching bindings");
        return;
    end
    if state.index < 1 then state.index = 1; end
    if state.index > #visible then state.index = #visible; end
    local entry = visible[state.index];
    local position = "(" .. state.index .. " of " .. #visible .. ")";
    OutputMessageToScreenReader(resolveEntry(entry) .. " " .. position);
end

-- Open help on the given host handler. Snapshot the entries at open time
-- (the stack may mutate while help is up; we want the user reading the
-- bindings they pressed ? to see). Announce the open + first entry.
function Help.enter(handler)
    if handler == nil then
        Log.warn("Help.enter: nil handler");
        return;
    end
    local entries = HandlerStack.collectHelpEntries();
    handler._helpMode = {
        entries = entries,
        index = 1,
        filter = nil,
        inputMode = false,
        buffer = "",
    };
    OutputMessageToScreenReader("Help. " .. #entries .. " bindings.");
    speakCurrent(handler._helpMode);
end

function Help.exit(handler)
    if handler == nil or handler._helpMode == nil then return; end
    handler._helpMode = nil;
    OutputMessageToScreenReader("Help closed");
end

function Help.isOpen(handler)
    return handler ~= nil and handler._helpMode ~= nil;
end

-- Filter input mode: Ctrl+F engaged, user is typing the query. Captures
-- A-Z / 0-9 / space into buffer, Backspace removes a char, Enter commits
-- (applies buffer as the active filter, drops back to nav mode), Esc
-- cancels (clears buffer AND any previously-applied filter, drops back
-- to nav mode showing the full list).
local function handleInputModeKey(state, key, ctrlDown, altDown)
    if key == Keys.VK_RETURN then
        state.filter = state.buffer;
        state.inputMode = false;
        state.index = 1;
        OutputMessageToScreenReader("Filter applied");
        speakCurrent(state);
        return true;
    end
    if key == Keys.VK_ESCAPE then
        state.buffer = "";
        state.filter = nil;
        state.inputMode = false;
        state.index = 1;
        OutputMessageToScreenReader("Filter cleared");
        speakCurrent(state);
        return true;
    end
    if key == Keys.VK_BACK then
        if #state.buffer > 0 then
            state.buffer = state.buffer:sub(1, -2);
            OutputMessageToScreenReader("Filter " .. state.buffer);
        end
        return true;
    end
    -- Printable A-Z / 0-9 / space. Civ VI Keys.A-Z = 0x41-0x5A;
    -- 0-9 = 0x30-0x39; space = 0x20.
    if not ctrlDown and not altDown then
        if (key >= 0x41 and key <= 0x5A) or (key >= 0x30 and key <= 0x39) or key == 0x20 then
            local ch = string.char(key);
            state.buffer = state.buffer .. string.lower(ch);
            OutputMessageToScreenReader("Filter " .. state.buffer);
            return true;
        end
    end
    -- Swallow other keys so they don't fire host nav while typing.
    return true;
end

-- Host input handler delegates to this while handler._helpMode is set.
-- Returns true if the key was consumed. Help mode swallows everything
-- except its own exit chords — host nav is paused for the duration.
function Help.handleKey(handler, key, ctrlDown, altDown, shiftDown)
    local state = handler._helpMode;
    if state == nil then return false; end

    if state.inputMode then
        return handleInputModeKey(state, key, ctrlDown, altDown);
    end

    -- Nav mode.
    if key == Keys.VK_ESCAPE then
        Help.exit(handler);
        return true;
    end
    if shiftDown and key == VK_OEM_2 then
        -- ? again closes help.
        Help.exit(handler);
        return true;
    end
    if ctrlDown and key == Keys.F then
        state.inputMode = true;
        state.buffer = "";
        OutputMessageToScreenReader("Filter. Type to search, Enter to apply, Escape to clear.");
        return true;
    end
    if key == Keys.VK_UP then
        state.index = state.index - 1;
        if state.index < 1 then state.index = (state._visibleCount or 1); end
        speakCurrent(state);
        return true;
    end
    if key == Keys.VK_DOWN then
        state.index = state.index + 1;
        if state.index > (state._visibleCount or 1) then state.index = 1; end
        speakCurrent(state);
        return true;
    end
    if key == Keys.VK_HOME then
        state.index = 1;
        speakCurrent(state);
        return true;
    end
    if key == Keys.VK_END then
        state.index = (state._visibleCount or 1);
        speakCurrent(state);
        return true;
    end
    -- Type-ahead: a letter jumps to the next entry whose resolved line
    -- starts with that letter (case-insensitive). Wraps around if needed.
    if not ctrlDown and not altDown then
        if (key >= 0x41 and key <= 0x5A) then
            local letter = string.lower(string.char(key));
            local visible = applyFilter(state.entries, state.filter);
            if #visible == 0 then return true; end
            local start = state.index + 1;
            if start > #visible then start = 1; end
            for offset = 0, #visible - 1 do
                local idx = ((start + offset - 1) % #visible) + 1;
                local line = string.lower(resolveEntry(visible[idx]));
                if line:sub(1, 1) == letter then
                    state.index = idx;
                    speakCurrent(state);
                    return true;
                end
            end
            return true;
        end
    end
    -- Swallow everything else.
    return true;
end
