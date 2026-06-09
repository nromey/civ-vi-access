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
include("ScannerHandler");

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
    -- Move the cursor onto (x, y) and speak the tile glance (HexCursor.AnnouncePlot
    -- emits it). Return "" so ScannerNav/handler don't re-speak on top of it.
    jumpTo = function(x, y)
        if HexCursor ~= nil and HexCursor.jumpTo ~= nil then
            HexCursor.jumpTo(x, y);
        end
        local plot = (Map ~= nil and Map.GetPlot ~= nil) and Map.GetPlot(x, y) or nil;
        if plot ~= nil and HexCursor ~= nil and HexCursor.AnnouncePlot ~= nil then
            HexCursor.AnnouncePlot(plot);
        end
        return "";
    end,
};

-- Keys forwarded from the WorldInput wrap (cross-VM, one-way). Route through the
-- scanner handler; pcall-guarded so a dispatch error can't break the addin.
if LuaEvents ~= nil and LuaEvents.CivViAccess_ScannerInput ~= nil then
    LuaEvents.CivViAccess_ScannerInput.Add(function(key, mods)
        if ScannerHandler == nil or ScannerHandler.dispatch == nil then
            Log.warn("ScannerAddinGlue: received scanner key but ScannerHandler.dispatch missing");
            return;
        end
        local handled = false;
        local ok, err = pcall(function() handled = ScannerHandler.dispatch(key, mods); end);
        Log.info("ScannerAddinGlue: received scanner key=" .. tostring(key) .. " mods=" .. tostring(mods)
            .. " handled=" .. tostring(handled));
        if not ok then Log.warn("ScannerAddinGlue: dispatch failed: " .. tostring(err)); end
    end);
    Log.info("ScannerAddinGlue: scanner wired into addin VM (cursor seam + input listener).");
else
    Log.warn("ScannerAddinGlue: LuaEvents.CivViAccess_ScannerInput unavailable — scanner input not wired.");
end
