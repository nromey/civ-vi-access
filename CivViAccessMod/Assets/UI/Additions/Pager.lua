-- Pager — the screen-reader paged reader for LONG text (pager arc
-- deliverable 2; Noel 2026-06-12: "a pager for long things"). One
-- interruption used to delete a whole announce (Robert's diplomacy line, the
-- reveal payload); in here, text is split into sentence-sized parts you walk
-- at your own pace — every part re-readable, nothing lost.
--
--   Down / N      next part        Up / P    previous part
--   Home / End    first / last     Ctrl+T    re-read current part
--   A             read everything from here on as one utterance
--   Escape        close
--
-- Opened cross-VM via LuaEvents.CivViAccess_OpenPager(title, text). Feeds:
--   * SpeechHistory: a history entry longer than its threshold opens here
--     instead of re-speaking as one blob (Shift+R -> long entry -> pager).
--   * Future: context-sensitive `?`, the empire/EOT report, Civilopedia.
--
-- Input model mirrors BuildImprovementPicker (the proven world-view modal
-- shell): separate sandboxed Context, QueuePopup makes us the active modal,
-- raw KeyUp dispatches through InputRouter/HandlerStack so `?` lists our keys
-- and nothing below us fires while open.
--
-- Notification BUFFERING while the pager is open is the next pass (v1 relies
-- on per-part re-reads: an interrupted part is one keypress from coming back,
-- which is the property that was missing).

include("Log");
include("ScreenReader");
include("HandlerStack");
include("InputRouter");

Pager = Pager or {};

local bind     = HandlerStack.bind;
local MOD_NONE = InputRouter.MOD_NONE;
local MOD_CTRL = InputRouter.MOD_CTRL;

local VK_ESCAPE = (Keys ~= nil and Keys.VK_ESCAPE) or 0x1B;
local VK_END    = (Keys ~= nil and Keys.VK_END)    or 0x23;
local VK_HOME   = (Keys ~= nil and Keys.VK_HOME)   or 0x24;
local VK_UP     = (Keys ~= nil and Keys.VK_UP)     or 0x26;
local VK_DOWN   = (Keys ~= nil and Keys.VK_DOWN)   or 0x28;
local VK_T      = (Keys ~= nil and Keys.VK_T)      or 0x54;
local VK_N      = (Keys ~= nil and Keys.N)         or 0x4E;
local VK_P      = (Keys ~= nil and Keys.P)         or 0x50;
local VK_A      = (Keys ~= nil and Keys.A)         or 0x41;

local _open  = false;
local _title = "";
local _parts = {};
local _index = 1;

-- Split text into sentence-sized parts. Sentences end at . ! ? followed by
-- whitespace (or end of string). Fragments shorter than MIN_PART glue onto
-- the previous part so abbreviation dots ("e.g. ", "X 14, Y 30.") don't
-- shred the text into confetti.
local MIN_PART = 20;

local function splitParts(text)
    local parts = {};
    for chunk in tostring(text):gmatch("[^%.!%?]*[%.!%?]*%s*") do
        local trimmed = chunk:match("^%s*(.-)%s*$");
        if trimmed ~= nil and trimmed ~= "" then
            if #parts > 0 and (#trimmed < MIN_PART or #parts[#parts] < MIN_PART) then
                parts[#parts] = parts[#parts] .. " " .. trimmed;
            else
                parts[#parts + 1] = trimmed;
            end
        end
    end
    if #parts == 0 then parts = { tostring(text) }; end
    return parts;
end

local function speakPart(prefix)
    local part = _parts[_index];
    if part == nil then return; end
    local pos = _index .. " of " .. #_parts;
    Speech.emit((prefix or "") .. part .. ". " .. pos, "status");
end

local function navTo(i)
    if i < 1 then
        _index = 1;
        speakPart("Start. ");
        return;
    end
    if i > #_parts then
        _index = #_parts;
        Speech.emit("End of reader. Escape to close.", "meta");
        return;
    end
    _index = i;
    speakPart();
end

local function readRest()
    local rest = {};
    for i = _index, #_parts do rest[#rest + 1] = _parts[i]; end
    Speech.emit(table.concat(rest, ". "), "status");
end

local function close()
    if not _open then return; end
    _open = false;
    HandlerStack.removeByName("Pager");
    if UIManager ~= nil and UIManager.DequeuePopup ~= nil then
        UIManager:DequeuePopup(ContextPtr);
    end
    Speech.emit("Reader closed", "meta");
end

local _handler = {
    name = "Pager",
    capturesAllInput = true,
    bindings = {
        bind(VK_DOWN,   MOD_NONE, function() navTo(_index + 1); end, "Next part"),
        bind(VK_N,      MOD_NONE, function() navTo(_index + 1); end, "Next part"),
        bind(VK_UP,     MOD_NONE, function() navTo(_index - 1); end, "Previous part"),
        bind(VK_P,      MOD_NONE, function() navTo(_index - 1); end, "Previous part"),
        bind(VK_HOME,   MOD_NONE, function() navTo(1); end,          "First part"),
        bind(VK_END,    MOD_NONE, function() navTo(#_parts); end,    "Last part"),
        bind(VK_T,      MOD_CTRL, function() speakPart(); end,       "Re-read current part"),
        bind(VK_A,      MOD_NONE, readRest,                          "Read everything from here"),
        bind(VK_ESCAPE, MOD_NONE, close,                             "Close the reader"),
    },
    helpEntries = {
        { keyLabel = "Down or N", description = "Next part" },
        { keyLabel = "Up or P", description = "Previous part" },
        { keyLabel = "Home/End", description = "First / last part" },
        { keyLabel = "Ctrl+T", description = "Re-read the current part" },
        { keyLabel = "A", description = "Read everything from here as one piece" },
        { keyLabel = "Escape", description = "Close the reader" },
    },
};

function Pager.open(title, text)
    if text == nil or tostring(text) == "" then return; end
    _title = (title ~= nil and title ~= "") and tostring(title) or "Reader";
    _parts = splitParts(text);
    _index = 1;
    if not _open then
        _open = true;
        if UIManager ~= nil and UIManager.QueuePopup ~= nil and PopupPriority ~= nil then
            UIManager:QueuePopup(ContextPtr, PopupPriority.Current);
        end
        HandlerStack.push(_handler);
    end
    Speech.emit(_title .. ". Reader, " .. #_parts
        .. ((#_parts == 1) and " part." or " parts."), "critical");
    speakPart();
end

local function onInput(pInputStruct)
    if not _open or pInputStruct == nil then return false; end
    local msgType = pInputStruct.GetMessageType and pInputStruct:GetMessageType();
    local keyUp = (KeyEvents ~= nil and KeyEvents.KeyUp) or 257;
    if msgType ~= keyUp then return false; end
    local key  = pInputStruct:GetKey();
    local mods = InputRouter.modifierMaskFromInputStruct(pInputStruct);
    return InputRouter.dispatch(key, mods);
end

local function OnOpenEvent(title, text)
    local ok, err = pcall(function() Pager.open(title, text); end);
    if not ok then Log.error("Pager.open failed: " .. tostring(err)); end
end

local function Initialize()
    if ContextPtr == nil then
        Log.warn("Pager.Initialize: ContextPtr unavailable");
        return;
    end
    ContextPtr:SetInputHandler(onInput, true);
    ContextPtr:SetHide(true);
    if LuaEvents ~= nil then
        LuaEvents.CivViAccess_OpenPager.Add(OnOpenEvent);
        Log.info("Pager: subscribed to CivViAccess_OpenPager");
    end
end
Initialize();

Log.info("Pager.lua: loaded");
