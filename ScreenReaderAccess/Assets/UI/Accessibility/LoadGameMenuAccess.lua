-- LoadGameMenu accessibility companion.
--
-- Owns kb-driven save-list navigation. The base LoadGameMenu/LoadSaveMenu_Shared
-- pair already handles Esc (back) and Enter (load focused save) via the
-- screen's own InputHandler/KeyHandler; what was missing for blind users was
-- any way to MOVE focus across the save list. The list is built
-- asynchronously: OnShow kicks off `SetupFileList` which calls
-- `UI.QuerySaveGameList`, the engine streams results back via
-- `OnFileListQueryResults`, and finally `LuaEvents.FileListQueryComplete` is
-- fired once the UI instances are built.
--
-- Architecture: thin LoadGameMenu fork that `include`s this companion +
-- swaps the InputHandler to consult us first. We tap
-- `LuaEvents.FileListQueryComplete` directly (no LoadGameMenu hook needed
-- for that) so the announce-when-ready path is self-contained.
--
-- Key bindings layered on top of the base screen:
--   Up / Down / Left / Right   previous / next save (wraps at edges)
--   Home / End                 first / last save in the list
--   (Enter / Esc are NOT handled here — they're already wired in the
--    base LoadGameMenu KeyHandler and we fall through to them.)
--
-- Selection visual + state: every focus move calls `SetSelected(idx)`
-- which is the same API the mouse-click path uses. So selecting via the
-- keyboard is indistinguishable from clicking — the right entry is the
-- right entry, and the existing Enter-loads-the-selected path Just Works.

include("ScreenReader");

LoadGameMenuAccess = {};

local NAV_SOUND :string = "Main_Menu_Mouse_Over";

local m_navIndex :number = 0;  -- 1-based index into g_FileList (0 = no focus)

-- ===========================================================================
--  Helpers
-- ===========================================================================
local function playNavSound()
    if UI ~= nil and UI.PlaySound ~= nil then
        UI.PlaySound(NAV_SOUND);
    end
end

local function describeEntry(entry, ordinal, total)
    if entry == nil then
        return "";
    end
    -- GetDisplayName lives in LoadSaveMenu_Shared.lua which the base
    -- LoadGameMenu already includes; available in our shared Lua context.
    local displayName = GetDisplayName(entry);
    if entry.IsDirectory then
        return Locale.Lookup("LOC_CIVVIACCESS_ENTRY_FOLDER", displayName);
    end
    if ordinal and total and total > 1 then
        return Locale.Lookup("LOC_CIVVIACCESS_ENTRY_ORDINAL", displayName, ordinal, total);
    end
    return displayName;
end

local function focusEntry(idx, interrupt)
    if g_FileList == nil or #g_FileList == 0 then
        return;
    end
    if idx < 1 then idx = 1; end
    if idx > #g_FileList then idx = #g_FileList; end
    m_navIndex = idx;
    SetSelected(idx);
    playNavSound();
    OutputMessageToScreenReader(describeEntry(g_FileList[idx], idx, #g_FileList), not interrupt);
end

local function moveBy(step)
    local list = g_FileList;
    if list == nil or #list == 0 then
        return;
    end
    local target;
    if m_navIndex < 1 then
        target = (step > 0) and 1 or #list;
    else
        target = m_navIndex + step;
        if target < 1 then target = #list; end
        if target > #list then target = 1; end
    end
    focusEntry(target, true);
end

-- ===========================================================================
--  Notifications from LoadGameMenu.lua fork
-- ===========================================================================
function LoadGameMenuAccess.NotifyShow()
    -- Reset focus state on every show — the list will repopulate via the
    -- async query and we'll announce the result via the
    -- FileListQueryComplete handler below.
    --
    -- Earlier this fn spoke "Load Game Menu. Loading save list, please
    -- wait." but the file query usually completes before Tolk finishes
    -- the line, and `onFileListReady` then fires another interrupt-mode
    -- announce that clobbers the in-progress speech. Testing 2026-05-11
    -- confirmed: user only heard the second message ("No saved games
    -- available...") never the first. Better to stay quiet here and let
    -- the result announce stand alone.
    m_navIndex = 0;
end

-- ===========================================================================
--  LuaEvent: file list rebuild complete
-- ===========================================================================
-- Fires every time the save-list rebuild finishes — initial load, after
-- sort change, after auto/cloud toggle, after directory navigation, after
-- a delete. Each rebuild re-announces the new state. If the list is empty
-- we say so explicitly (a fresh install with no saves lands here).
local function onFileListReady()
    local count = g_FileList and #g_FileList or 0;
    if count == 0 then
        m_navIndex = 0;
        OutputMessageToScreenReader(Locale.Lookup("LOC_CIVVIACCESS_LOADGAME_EMPTY"));
        return;
    end
    -- Two-key singular/plural pattern: English count line varies by 1 vs many;
    -- translators choose how their language inflects (Russian has three forms
    -- based on count, Chinese has one, etc.). Lua picks the key; translators
    -- own the text.
    local countKey = (count == 1) and "LOC_CIVVIACCESS_LOADGAME_COUNT_ONE"
                                   or  "LOC_CIVVIACCESS_LOADGAME_COUNT_MANY";
    local line = Locale.Lookup(countKey, count)
        .. " " .. Locale.Lookup("LOC_CIVVIACCESS_LOADGAME_NAV_HELP");
    OutputMessageToScreenReader(line);
    -- Focus the first entry and announce it. Use queued speech so it chains
    -- after the count line.
    focusEntry(1, false);
end

LuaEvents.FileListQueryComplete.Add(onFileListReady);

-- ===========================================================================
--  Input handler. Called from the LoadGameMenu fork's OnInputHandler
--  BEFORE it falls through to the base game's KeyHandler. Returns true
--  when we consumed the input (so the base handler doesn't double-fire).
-- ===========================================================================
function LoadGameMenuAccess.OnInputStruct(pInputStruct)
    local uiMsg = pInputStruct:GetMessageType();
    if uiMsg ~= KeyEvents.KeyUp then
        return false;
    end
    local key = pInputStruct:GetKey();
    if key == Keys.VK_UP or key == Keys.VK_LEFT then
        moveBy(-1);
        return true;
    end
    if key == Keys.VK_DOWN or key == Keys.VK_RIGHT then
        moveBy(1);
        return true;
    end
    if key == Keys.VK_HOME then
        focusEntry(1, true);
        return true;
    end
    if key == Keys.VK_END then
        if g_FileList ~= nil then
            focusEntry(#g_FileList, true);
        end
        return true;
    end
    return false;
end
