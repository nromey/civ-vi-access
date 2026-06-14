-- HelpAccess: screen-reader-driven help overlay.
--
-- Modal-popup help that lists bindings from the firing context's
-- HandlerStack. Owns its own UI VM with raw-keyboard input — gives
-- us arrow-key nav + type-to-filter that HexCursorAddin's Input
-- Action dispatch can't provide. Mirrors picker addin shape.
--
-- Other contexts open via LuaEvents.CivViAccess_OpenHelp(entries) —
-- the firing VM collects entries from its own HandlerStack and
-- marshals them across since HandlerStack is per-VM.
--
-- UX (no mode switch — type-to-filter live):
--   Up / Down         walk filtered list
--   Home / End        first / last
--   Enter / Space     re-speak current entry
--   Any letter/digit  append to filter; list narrows live; cursor
--                     jumps to first match
--   Backspace         remove last char from filter
--   Esc               if filter non-empty: clear it; else close help

include("Log");
include("ScreenReader");
include("Help");
include("InputSupport");  -- Brings InputContext table (GameOptions = 0x0040
                          -- etc.) into this VM. Standalone <AddUserInterfaces>
                          -- addin VMs don't expose it by default, but the
                          -- shipping include is a plain Lua table — pulling
                          -- it in gives us Input.PushActiveContext() without
                          -- needing a cross-VM bridge (which doesn't work
                          -- between addin VMs and the InGame VM anyway).

HelpPicker = HelpPicker or {};

local VK_RETURN  = (Keys ~= nil and Keys.VK_RETURN)  or 0x0D;
local VK_SPACE   = (Keys ~= nil and Keys.VK_SPACE)   or 0x20;
local VK_ESCAPE  = (Keys ~= nil and Keys.VK_ESCAPE)  or 0x1B;
local VK_END     = (Keys ~= nil and Keys.VK_END)     or 0x23;
local VK_HOME    = (Keys ~= nil and Keys.VK_HOME)    or 0x24;
local VK_UP      = (Keys ~= nil and Keys.VK_UP)      or 0x26;
local VK_DOWN    = (Keys ~= nil and Keys.VK_DOWN)    or 0x28;
local VK_BACK    = (Keys ~= nil and Keys.VK_BACK)    or 0x08;
-- Numpad-alias codes: with NumLock OFF, Civ VI's input layer reports
-- arrow keys as their NUMPAD VK codes (NUMPAD8 for Up, NUMPAD2 for Down,
-- NUMPAD7 for Home, NUMPAD1 for End) rather than the regular VK_UP/etc.
-- Match both so users with either NumLock state nav reliably.
local VK_NUMPAD8 = (Keys ~= nil and Keys.VK_NUMPAD8) or 0x68;
local VK_NUMPAD2 = (Keys ~= nil and Keys.VK_NUMPAD2) or 0x62;
local VK_NUMPAD7 = (Keys ~= nil and Keys.VK_NUMPAD7) or 0x67;
local VK_NUMPAD1 = (Keys ~= nil and Keys.VK_NUMPAD1) or 0x61;
-- PageDown / PageUp as Down / Up aliases (Noel 2026-06-14: "can't page down past
-- items"). Matches the scanner ladder's PageUp/Down muscle memory.
local VK_NEXT    = (Keys ~= nil and Keys.VK_NEXT)    or 0x22;
local VK_PRIOR   = (Keys ~= nil and Keys.VK_PRIOR)   or 0x21;

local _state = {
    open    = false,
    all     = nil,    -- snapshot at open; never mutated
    visible = nil,    -- current filtered view
    filter  = "",
    index   = 1,
};

-- Resume state for the topic -> reader -> back-to-list round trip (Noel
-- 2026-06-13). When the user presses Enter on a TOPIC item we open the reader
-- (Pager) on top and close this list; on the reader's close we reopen the list
-- where they left off. _resume.pending guards that we only reopen when WE sent
-- them to the reader (not for a reader opened from SpeechHistory etc.).
local _resume = { pending = false, entries = nil, index = 1, filter = "" };

-- ====================================================================
-- View management
-- ====================================================================

local function rebuildView()
    _state.visible = Help.applyFilter(_state.all, _state.filter);
    if _state.index < 1 then _state.index = 1; end
    if _state.index > #_state.visible then _state.index = #_state.visible; end
end

local function currentLine()
    if _state.visible == nil or #_state.visible == 0 then return nil; end
    local entry = _state.visible[_state.index];
    if entry == nil then return nil; end
    return Help.resolveEntry(entry);
end

local function speakCurrent(includeIndex)
    local line = currentLine();
    if line == nil then
        if _state.filter ~= "" then
            Speech.emit("No matches for " .. _state.filter, "picker");
        else
            Speech.emit("No bindings", "picker");
        end
        return;
    end
    if includeIndex then
        local total = #_state.visible;
        Speech.emit(line .. ", " .. tostring(_state.index)
                    .. " of " .. tostring(total), "picker");
    else
        Speech.emit(line, "picker");
    end
end

local function announcePreamble()
    local count = #_state.all;
    Speech.emit("Help. " .. tostring(count) .. " bindings. "
                .. "Type to filter, up and down to walk, escape to close.",
                "picker");
    if #_state.visible > 0 then
        Speech.emit(currentLine(), "status");
    end
end

-- ====================================================================
-- Input handling
-- ====================================================================

-- Diagnostic showed Civ VI delivers two key paths in this addin VM:
--   KeyDown / KeyUp deliver an idiosyncratic VK code (e.g. 0x0D for M,
--     0x68 for Up arrow with NumLock OFF) — usable for non-printable
--     nav keys but unreliable for letters.
--   Character (msg=2) delivers the actual lowercase ASCII byte (0x6D='m',
--     0x65='e' etc.) — that's what we filter on.
-- We use KeyUp for nav (engine convention; nearly every Base screen does
-- the same) and Character for printable input.

local function isFilterableChar(ch)
    if ch == nil then return false; end
    if ch == 0x20 then return true; end             -- space
    if ch >= 0x30 and ch <= 0x39 then return true; end  -- 0-9
    if ch >= 0x61 and ch <= 0x7A then return true; end  -- a-z (Character is lowercase)
    if ch >= 0x41 and ch <= 0x5A then return true; end  -- A-Z (defensive)
    return false;
end

local function appendFilterChar(ch)
    local lower = ch;
    if lower >= 0x41 and lower <= 0x5A then lower = lower + 32; end
    _state.filter = _state.filter .. string.char(lower);
    _state.index = 1;
    rebuildView();
    Speech.emit("Filter " .. _state.filter, "picker");
    if #_state.visible > 0 then
        Speech.emit(currentLine(), "status");
    else
        Speech.emit("No matches", "status");
    end
end

-- Enter on a TOPIC item: stash where we are, open the long body in the reader
-- (Pager) on top, and close this list quietly. The CivViAccess_PagerState(false)
-- subscription in Initialize reopens the list here when the reader closes.
local function openTopic(entry)
    if LuaEvents == nil or LuaEvents.CivViAccess_OpenPager == nil then
        -- No reader available — don't arm resume (it would wrongly reopen the
        -- list on the next unrelated pager close); just re-speak the line.
        speakCurrent(true);
        return;
    end
    _resume.pending = true;
    _resume.entries = _state.all;
    _resume.index   = _state.index;
    _resume.filter  = _state.filter;
    LuaEvents.CivViAccess_OpenPager(entry.title or "Help",
                                    entry.body or entry.description or "");
    -- silent close: the reader's own preamble speaks; no "Help closed" first.
    HelpPicker.close(true);
end

local function handleKeyNav(key)
    -- Called on KeyUp. Handles the non-printable nav keys; printable
    -- filter input is handled in onInput's Character branch.
    if not _state.open then return false; end

    if key == VK_ESCAPE then
        if _state.filter ~= "" then
            _state.filter = "";
            _state.index = 1;
            rebuildView();
            Speech.emit("Filter cleared", "event");
            speakCurrent(true);
            return true;
        end
        HelpPicker.close();
        return true;
    end

    if key == VK_UP or key == VK_NUMPAD8 or key == VK_PRIOR then
        if #_state.visible <= 1 then
            speakCurrent(true);
            return true;
        end
        _state.index = _state.index - 1;
        if _state.index < 1 then _state.index = #_state.visible; end
        speakCurrent(true);
        return true;
    end

    if key == VK_DOWN or key == VK_NUMPAD2 or key == VK_NEXT then
        if #_state.visible <= 1 then
            speakCurrent(true);
            return true;
        end
        _state.index = _state.index + 1;
        if _state.index > #_state.visible then _state.index = 1; end
        speakCurrent(true);
        return true;
    end

    if key == VK_HOME or key == VK_NUMPAD7 then
        _state.index = 1;
        speakCurrent(true);
        return true;
    end

    if key == VK_END or key == VK_NUMPAD1 then
        _state.index = #_state.visible;
        speakCurrent(true);
        return true;
    end

    if key == VK_RETURN or key == VK_SPACE then
        -- Enter on a topic opens its body in the reader; Enter/Space on a plain
        -- binding (and Space on a topic) just re-speaks the current line.
        local entry = (_state.visible ~= nil) and _state.visible[_state.index] or nil;
        if key == VK_RETURN and entry ~= nil and entry.topic then
            openTopic(entry);
        else
            speakCurrent(true);
        end
        return true;
    end

    if key == VK_BACK then
        if #_state.filter > 0 then
            _state.filter = _state.filter:sub(1, -2);
            _state.index = 1;
            rebuildView();
            if _state.filter == "" then
                Speech.emit("Filter cleared", "event");
            else
                Speech.emit("Filter " .. _state.filter, "picker");
            end
            speakCurrent(false);
        end
        return true;
    end

    -- Non-nav, non-printable key — swallow.
    return false;
end

-- Civ VI's KeyEvents enum values, with literal fallbacks based on the
-- diagnostic we ran 2026-05-27: msg=0 KeyDown, msg=1 KeyUp, msg=2
-- Character. The Character constant in particular may not be exposed in
-- standalone <AddUserInterfaces> addin VMs even though the engine still
-- dispatches msg=2 events; treat the table-lookup as the optimistic path
-- and msg==2 as the load-bearing fallback.
local KE_KEY_DOWN  = (KeyEvents ~= nil and KeyEvents.KeyDown)  or 0;
local KE_KEY_UP    = (KeyEvents ~= nil and KeyEvents.KeyUp)    or 1;
local KE_CHARACTER = (KeyEvents ~= nil and KeyEvents.Character) or 2;

local function onInput(pInputStruct)
    if not _state.open then return false; end
    if pInputStruct == nil then return false; end
    local uiMsg = pInputStruct:GetMessageType();
    local key = (pInputStruct.GetKey ~= nil) and pInputStruct:GetKey() or -1;

    -- Character event: filterable printable input. Civ VI delivers
    -- lowercase ASCII (already shifted/un-modified) in pInputStruct.
    if uiMsg == KE_CHARACTER or uiMsg == 2 then
        if isFilterableChar(key) then
            appendFilterChar(key);
            return true;
        end
        return false;
    end

    -- KeyUp: nav keys. Engine convention.
    if uiMsg == KE_KEY_UP or uiMsg == 1 then
        return handleKeyNav(key);
    end

    return false;
end

-- ====================================================================
-- Open / close
-- ====================================================================

-- opts (optional): { index, filter, resume } — used when reopening the list
-- after the reader closes (the topic round trip) so we restore the user's spot
-- and skip the long preamble.
function HelpPicker.open(entries, opts)
    opts = opts or {};
    Log.info("HelpPicker.open: entry; " ..
             (entries ~= nil and tostring(#entries) or "nil")
             .. " entries" .. (opts.resume and " (resume)" or ""));
    if entries == nil or #entries == 0 then
        Speech.emit("No help available", "meta");
        return;
    end
    _state.all     = entries;
    _state.filter  = opts.filter or "";
    _state.index   = opts.index or 1;
    rebuildView();   -- builds _state.visible from the filter and clamps index
    _state.open    = true;

    pcall(function()
        if UIManager ~= nil and UIManager.QueuePopup ~= nil then
            UIManager:QueuePopup(ContextPtr, PopupPriority.Current);
        end
    end);

    -- Push GameOptions input context so engine bare-letter World
    -- bindings (M=MoveTo, O=troop toggle, etc.) stop firing while
    -- the user types into the filter. InputContext table comes from
    -- include("InputSupport") at the top of this file.
    pcall(function()
        if Input ~= nil and Input.PushActiveContext ~= nil
           and InputContext ~= nil and InputContext.GameOptions ~= nil
           and (Input.GetActiveContext == nil
                or Input.GetActiveContext() ~= InputContext.GameOptions) then
            Input.PushActiveContext(InputContext.GameOptions);
        end
    end);

    -- Broadcast so other VMs (HexCursorAddin) can disable their own
    -- InputAction handlers while help is up. Belt-and-suspenders with
    -- the InputContext push above — even if the engine's own context
    -- switch propagates correctly, our LuaEvent lockout ensures our
    -- mod doesn't fire its handlers.
    pcall(function()
        if LuaEvents ~= nil and LuaEvents.CivViAccess_HelpOpened ~= nil then
            LuaEvents.CivViAccess_HelpOpened();
        end
    end);

    if opts.resume then
        -- Back from the reader: terse re-entry, not the full "Type to filter…"
        -- preamble. Speak where we landed.
        Speech.emit("Back to help.", "event");
        local line = currentLine();
        if line ~= nil then Speech.emit(line, "status"); end
    else
        announcePreamble();
    end
    Log.info("HelpPicker.open: complete");
end

function HelpPicker.close(silent)
    if not _state.open then return; end
    _state.open = false;

    pcall(function()
        if UIManager ~= nil and UIManager.DequeuePopup ~= nil then
            UIManager:DequeuePopup(ContextPtr);
        end
    end);

    pcall(function()
        if Input ~= nil and Input.PopContext ~= nil
           and InputContext ~= nil and InputContext.GameOptions ~= nil
           and Input.GetActiveContext ~= nil
           and Input.GetActiveContext() == InputContext.GameOptions then
            Input.PopContext();
        end
    end);

    -- Tell HexCursorAddin et al. the InputAction lockout can lift.
    pcall(function()
        if LuaEvents ~= nil and LuaEvents.CivViAccess_HelpClosed ~= nil then
            LuaEvents.CivViAccess_HelpClosed();
        end
    end);

    pcall(function()
        if UI ~= nil and UI.SetInterfaceMode ~= nil
           and InterfaceModeTypes ~= nil and InterfaceModeTypes.SELECTION ~= nil then
            UI.SetInterfaceMode(InterfaceModeTypes.SELECTION);
        end
    end);

    pcall(function()
        if ContextPtr ~= nil and ContextPtr.SetHide ~= nil then
            ContextPtr:SetHide(true);
        end
    end);

    -- silent on the topic hand-off (the reader's preamble speaks instead);
    -- spoken on a real Escape-to-map close.
    if not silent then Speech.emit("Help closed", "event"); end
    Log.info("HelpPicker.close: complete");
end

local function OnLuaEventOpenHelp(entries)
    Log.info("HelpAddin: OnLuaEventOpenHelp called");
    HelpPicker.open(entries);
end

-- ====================================================================
-- Init
-- ====================================================================

local function Initialize()
    if ContextPtr == nil then
        Log.warn("HelpAddin.Initialize: ContextPtr unavailable");
        return;
    end
    ContextPtr:SetInputHandler(onInput, true);
    ContextPtr:SetHide(true);
    if LuaEvents ~= nil then
        LuaEvents.CivViAccess_OpenHelp.Add(OnLuaEventOpenHelp);
        Log.info("HelpAddin: subscribed to CivViAccess_OpenHelp");
        -- Topic round trip: when the reader closes and WE sent the user there
        -- from a topic, reopen the list where they left off (Noel 2026-06-13).
        pcall(function()
            LuaEvents.CivViAccess_PagerState.Add(function(isOpen)
                if isOpen == false and _resume.pending then
                    _resume.pending = false;
                    HelpPicker.open(_resume.entries, {
                        index  = _resume.index,
                        filter = _resume.filter,
                        resume = true,
                    });
                end
            end);
        end);
    end
    Log.info("HelpAddin.Initialize: input handler installed");
end

Initialize();
