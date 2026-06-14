-- ScannerAddinGlue.lua — wires the scanner into the HexCursorAddin VM, where the
-- hex cursor (HexCursor) already lives, so the scanner can read + park the cursor
-- with no cross-VM calls. Included by HexCursorAddin.lua (after HexCursor).
--
-- Three jobs:
--   1. Load the scanner stack into this VM (Core → Snap → Nav → backends → Handler).
--   2. Wire Scanner.cursor to HexCursor (the seam ScannerNav reads/jumps through).
--   3. Listen for keys forwarded from the WorldInput capture-all wrap
--      (LuaEvents.CivViAccess_ScannerInput, fired in the WorldInput VM) and route
--      them through ScannerHandler → ScannerNav.

include("Log");
include("ScannerCore");
include("ScannerSnap");
include("ScannerNav");
include("ScannerBackendUnits");
include("ScannerBackendResources");
include("ScannerBackendCities");
include("ScannerBackendTerrain");
include("ScannerBackendSpecial");
include("ScannerBackendImprovements");
include("ScannerBackendGeography");
include("ScannerBackendRecommendations");
include("ScannerHandler");
include("ScannerSurvey");

Scanner = Scanner or {};

-- Cursor seam. Functions resolve HexCursor at CALL time, so glue load-order vs
-- HexCursor doesn't matter (the scanner only calls these once the user navigates).
Scanner.cursor = {
    position = function()
        if HexCursor ~= nil and HexCursor.position ~= nil then
            return HexCursor.position();
        end
        return nil, nil;
    end,
    -- HOME: move the cursor onto (x, y) and confirm content + position (tile
    -- glance then coords). HexCursor.jumpAndAnnounce emits; return "" so
    -- ScannerNav/handler don't re-speak on top of it.
    jumpTo = function(x, y)
        if HexCursor ~= nil and HexCursor.jumpAndAnnounce ~= nil then
            HexCursor.jumpAndAnnounce(x, y);
        end
        return "";
    end,
    -- BACKSPACE: return the cursor to (x, y) with the "Returning to ..." +
    -- where-am-I framing. Same emit-and-return-"" contract as jumpTo.
    returnTo = function(x, y)
        if HexCursor ~= nil and HexCursor.returnAndAnnounce ~= nil then
            HexCursor.returnAndAnnounce(x, y);
        end
        return "";
    end,
};

-- Modal input lock (Noel 2026-06-14: "I can go to production from within help").
-- The WorldInput capture-all wrap is a SEPARATE VM and keeps forwarding map keys
-- even while our Help list or the Pager (reader) is the active modal — so without
-- this guard the forwarded keys double-dispatch and fire game actions underneath
-- the modal (Shift+P opens production, R rests a unit, typing to filter triggers
-- letter actions). The modal owns its OWN input handler for nav, so dropping the
-- forwarded COPY here costs the modal nothing. Track Help and Pager separately —
-- a single bool would race on the Help->topic->reader handoff, where HelpClosed
-- fires AFTER the reader's PagerState(true) and would wrongly clear the lock.
local _helpOpen  = false;
local _pagerOpen = false;
local function modalOpen() return _helpOpen or _pagerOpen; end
if LuaEvents ~= nil then
    if LuaEvents.CivViAccess_HelpOpened ~= nil then
        LuaEvents.CivViAccess_HelpOpened.Add(function() _helpOpen = true; end);
    end
    if LuaEvents.CivViAccess_HelpClosed ~= nil then
        LuaEvents.CivViAccess_HelpClosed.Add(function() _helpOpen = false; end);
    end
    if LuaEvents.CivViAccess_PagerState ~= nil then
        LuaEvents.CivViAccess_PagerState.Add(function(open) _pagerOpen = (open == true); end);
    end
end

-- Keys forwarded from the WorldInput wrap (cross-VM, one-way). Route through the
-- scanner handler; pcall-guarded so a dispatch error can't break the addin.
if LuaEvents ~= nil and LuaEvents.CivViAccess_ScannerInput ~= nil then
    LuaEvents.CivViAccess_ScannerInput.Add(function(key, mods)
        if modalOpen() then
            Log.info("ScannerAddinGlue: modal (help/reader) open — dropping forwarded key="
                .. tostring(key) .. " mods=" .. tostring(mods));
            return;
        end
        local handled = false;
        -- Hex-cluster nav FIRST (bare Q/E/A/D/Z/C = cursor, Shift+cluster = unit move,
        -- Ctrl+D = direction vocab) — the most frequent presses, migrated onto the wrap
        -- (task #14). Claims only those (key,mods); everything else falls through.
        if NavKeys ~= nil and NavKeys.dispatch ~= nil then
            local ok, h = pcall(function() return NavKeys.dispatch(key, mods); end);
            if ok then handled = (h == true);
            else Log.warn("ScannerAddinGlue: nav dispatch failed: " .. tostring(h)); end
        end
        -- Survey / zoom / locate family (S, W, Alt+G/U/R, Alt+digit). Anything
        -- it doesn't claim falls through to the scanner ladder (PageUp/Down/Home/
        -- End/Backspace/?).
        if not handled and ScannerSurvey ~= nil and ScannerSurvey.dispatch ~= nil then
            local ok, h = pcall(function() return ScannerSurvey.dispatch(key, mods); end);
            if ok then handled = (h == true);
            else Log.warn("ScannerAddinGlue: survey dispatch failed: " .. tostring(h)); end
        end
        if not handled and UnitMovement ~= nil and UnitMovement.dispatch ~= nil then
            local ok, h = pcall(function() return UnitMovement.dispatch(key, mods); end);
            if ok then handled = (h == true);
            else Log.warn("ScannerAddinGlue: movement dispatch failed: " .. tostring(h)); end
        end
        -- Combat (A = attack at cursor). After movement so M/Alt+dir stay movement
        -- (they redirect INTO combat themselves when the target is an enemy).
        if not handled and UnitCombat ~= nil and UnitCombat.dispatch ~= nil then
            local ok, h = pcall(function() return UnitCombat.dispatch(key, mods); end);
            if ok then handled = (h == true);
            else Log.warn("ScannerAddinGlue: combat dispatch failed: " .. tostring(h)); end
        end
        -- F1 = the searchable help list (the original navigable Help mode:
        -- arrows + Ctrl+F filter + type-ahead). Shift+/ is the quick paged
        -- context walk; this is the search tier (#16).
        if not handled and Keys ~= nil and Keys.F1 ~= nil and key == Keys.F1
           and (mods or 0) == 0 then
            if HexCursor ~= nil and HexCursor.openHelp ~= nil then
                pcall(HexCursor.openHelp);
                handled = true;
            end
        end
        -- Unit selection at cursor (Alt+/ = select own unit under cursor).
        if not handled and UnitInfo ~= nil and UnitInfo.dispatch ~= nil then
            local ok, h = pcall(function() return UnitInfo.dispatch(key, mods); end);
            if ok then handled = (h == true);
            else Log.warn("ScannerAddinGlue: unitinfo dispatch failed: " .. tostring(h)); end
        end
        -- Speech history (Shift+R = repeat last / walk back).
        if not handled and SpeechHistory ~= nil and SpeechHistory.dispatch ~= nil then
            local ok, h = pcall(function() return SpeechHistory.dispatch(key, mods); end);
            if ok then handled = (h == true);
            else Log.warn("ScannerAddinGlue: speech-history dispatch failed: " .. tostring(h)); end
        end
        -- Bare G = open My Government (Noel 2026-06-12: needed a way to CHANGE
        -- the cards Alt+P auto-picked). Raising the LaunchBar's own LuaEvent
        -- reproduces the sighted button click exactly: the RevealListeners hub
        -- intercepts, announces the current government, then G = type chooser,
        -- P = policy wizard.
        if not handled and Keys ~= nil and key == Keys.G and (mods or 0) == 0 then
            if LuaEvents ~= nil and LuaEvents.LaunchBar_GovernmentOpenMyGovernment ~= nil then
                LuaEvents.LaunchBar_GovernmentOpenMyGovernment();
                handled = true;
            end
        end
        -- Notifications (Shift+Enter = activate the cycle's current entry).
        if not handled and Notifications ~= nil and Notifications.dispatch ~= nil then
            local ok, h = pcall(function() return Notifications.dispatch(key, mods); end);
            if ok then handled = (h == true);
            else Log.warn("ScannerAddinGlue: notifications dispatch failed: " .. tostring(h)); end
        end
        if not handled and ScannerHandler ~= nil and ScannerHandler.dispatch ~= nil then
            local ok, err = pcall(function() handled = ScannerHandler.dispatch(key, mods); end);
            if not ok then Log.warn("ScannerAddinGlue: scanner dispatch failed: " .. tostring(err)); end
        end
        Log.info("ScannerAddinGlue: key=" .. tostring(key) .. " mods=" .. tostring(mods)
            .. " handled=" .. tostring(handled));
    end);
    Log.info("ScannerAddinGlue: scanner wired into addin VM (cursor seam + input listener).");
else
    Log.warn("ScannerAddinGlue: LuaEvents.CivViAccess_ScannerInput unavailable — scanner input not wired.");
end
