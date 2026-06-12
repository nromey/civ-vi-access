-- NavKeys.lua — the hex-cluster directional keys, migrated onto the capture-all
-- wrap (task #14). Lives in the HexCursorAddin VM next to HexCursor + UnitMovement.
--
-- WHY: until now the cursor (bare Q/E/A/D/Z/C) and unit-move (Shift+Q/E/A/D/Z/C)
-- rode the engine InputAction path (`RemapForHexCursor.xml`) — the cursor worked but
-- the unit-move fired SILENTLY or not at all (verified dead in Lua.log 2026-06-11).
-- Routing them through the wrap (the proven, reliable path the scanner/survey/move/
-- combat keys already use) makes every press reach our handler and speak. The old
-- InputAction bindings stay in the XML but are now suppressed by the wrap (it
-- consumes the key first) — harmless, cleaned up later.
--
-- The D-family is finalized here (the #14 "finalize Shift+D" note):
--   bare D  = move cursor east
--   Shift+D = move unit east   (was dead — Shift+D had been the vocab toggle)
--   Ctrl+D  = cycle direction vocabulary (moved off Shift+D so the cluster is clean)
-- Mirrors the A-family (bare = cursor west, Shift = unit west, Ctrl = attack).

NavKeys = NavKeys or {};

-- Keys.* -> DirectionTypes (pointy-top hex: NW=Q NE=E W=A E=D SW=Z SE=C).
local DIR = {};
if Keys ~= nil and DirectionTypes ~= nil then
    DIR[Keys.Q] = DirectionTypes.DIRECTION_NORTHWEST;
    DIR[Keys.E] = DirectionTypes.DIRECTION_NORTHEAST;
    DIR[Keys.A] = DirectionTypes.DIRECTION_WEST;
    DIR[Keys.D] = DirectionTypes.DIRECTION_EAST;
    DIR[Keys.Z] = DirectionTypes.DIRECTION_SOUTHWEST;
    DIR[Keys.C] = DirectionTypes.DIRECTION_SOUTHEAST;
end
local KEY_D = Keys and Keys.D;

-- Forwarded from the wrap as (key, mods); mods bit0=Shift, bit1=Ctrl, bit2=Alt.
-- Claims ONLY: bare cluster (cursor), Shift+cluster (unit move), Ctrl+D (vocab).
-- Returns false for anything else so Ctrl+A (combat), Alt+letter (engine), etc.
-- fall through to the other dispatchers.
function NavKeys.dispatch(key, mods)
    mods = mods or 0;
    local shift = (mods % 2) == 1;
    local ctrl  = (math.floor(mods / 2) % 2) == 1;
    local alt   = (math.floor(mods / 4) % 2) == 1;

    -- Ctrl+D = cycle direction vocabulary (hex / compass / clock / degrees).
    if KEY_D ~= nil and key == KEY_D and ctrl and not shift and not alt then
        if HexGeom ~= nil and HexGeom.cycleDirectionMode ~= nil then
            local label = HexGeom.cycleDirectionMode();
            if Speech ~= nil and Speech.emit ~= nil then Speech.emit(label, "picker"); end
            return true;
        end
        return false;
    end

    local dir = DIR[key];
    if dir == nil then return false; end

    if mods == 0 then
        -- Bare cluster -> move the hex cursor (HexCursor.move announces the tile).
        if HexCursor ~= nil and HexCursor.move ~= nil then
            HexCursor.move(dir); return true;
        end
    elseif shift and not ctrl and not alt then
        -- Shift+cluster -> move the selected unit one hex (directMove announces).
        if UnitMovement ~= nil and UnitMovement.directMove ~= nil then
            UnitMovement.directMove(dir); return true;
        end
    end
    return false;
end

if Log ~= nil then Log.info("NavKeys.lua: file loaded (cursor + unit-move + Ctrl+D vocab on the wrap)"); end
