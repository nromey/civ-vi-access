-- Unit-info readout. Bare `/` speaks a composite line for the selected
-- unit (name + combat + moves + HP + status). Ctrl+`/` recenters the
-- HexCursor on the selected unit. Mirrors Civ V Access's pattern from
-- CivVAccess_UnitControlSelection.lua (speakInfo + recenterOnUnit
-- bound to VK_OEM_2).
--
-- Civ V Access's UnitSpeech.info is more elaborate (level/XP, full
-- promotions list, upgrade availability, cargo, embark state). This is
-- the minimal 0.5.0 version — extend incrementally as the unit-stat
-- vocabulary grows.

include("Log");
include("ScreenReader");
include("ScreenReaderPlotUtils");
include("HexCursor");

UnitInfo = UnitInfo or {};

-- Selection cache. UI.GetHeadSelectedUnit lags after period/comma fires
-- because Civ VI processes the cycle asynchronously — confirmed via
-- 2026-05-24 test where slash post-cycle spoke the PRIOR unit. UnitPanel
-- .lua uses the same Events.UnitSelectionChanged tracking pattern
-- (g_selectedPlayerId / g_UnitId) instead of trusting GetHeadSelectedUnit.
local _selectedPlayerId = nil;
local _selectedUnitId   = nil;

local function selectedUnit()
    -- Prefer the cache (updated on the actual UnitSelectionChanged event)
    -- over GetHeadSelectedUnit (lagging snapshot). Fall back to the engine
    -- helper for the first call before any selection event has fired.
    if _selectedPlayerId ~= nil and _selectedUnitId ~= nil then
        local pPlayer = Players[_selectedPlayerId];
        if pPlayer ~= nil then
            local pUnit = pPlayer:GetUnits():FindID(_selectedUnitId);
            if pUnit ~= nil then return pUnit; end
        end
    end
    if UI == nil or UI.GetHeadSelectedUnit == nil then return nil; end
    return UI.GetHeadSelectedUnit();
end

local function onUnitSelectionChanged(playerId, unitId, hexI, hexJ, hexK,
                                       isSelected, isEditable)
    if Game == nil or playerId ~= Game.GetLocalPlayer() then return; end
    if isSelected then
        _selectedPlayerId = playerId;
        _selectedUnitId = unitId;
        -- HexCursor auto-follow. Sighted Civ VI auto-centers the camera
        -- on selection; the blind equivalent is the HexCursor. Without
        -- this, Shift+./, cycles units but the cursor stays where it
        -- was — Noel hit this 2026-05-25 ("cursor stuck in unexplored
        -- territory after Shift+. to warrior, expected Ctrl+/ would
        -- recenter but selection alone should suffice"). The
        -- "explore independently, then command unit to remote spot"
        -- workflow is handled by the planned bookmarks/pins feature
        -- ([[project-map-pins-feature]]), not by cursor decoupling.
        if HexCursor ~= nil and HexCursor.jumpTo ~= nil then
            pcall(HexCursor.jumpTo, hexI, hexJ);
        end
    elseif _selectedPlayerId == playerId and _selectedUnitId == unitId then
        -- Our cached unit was deselected. Clear so the next speakInfo
        -- falls back to GetHeadSelectedUnit (which may have a new
        -- selection by then) rather than reporting the deselected unit.
        _selectedPlayerId = nil;
        _selectedUnitId = nil;
    end
end

-- Civ VI's GetMovesRemaining / GetMaxMoves return fractional movement
-- points in some cases (movement-modifying terrain partial entry). Round
-- to whole MP for the announce; the user doesn't care about 60ths.
local function roundMp(mp)
    if mp == nil then return 0; end
    return math.floor(mp + 0.5);
end

function UnitInfo.speakInfo()
    local pUnit = selectedUnit();
    if pUnit == nil then
        Speech.emit("No unit selected", "meta");
        return;
    end

    local parts = {};
    parts[#parts + 1] = StringifyUnit(pUnit);

    -- Combat strength. 0 means non-combat (Settler, Builder, Trader).
    local okC, combat = pcall(function() return pUnit:GetCombat(); end);
    if okC and combat ~= nil and combat > 0 then
        parts[#parts + 1] = tostring(combat) .. " combat";
    end

    -- Ranged strength + range. Most units lack these.
    local okR, ranged = pcall(function() return pUnit:GetRangedCombat(); end);
    if okR and ranged ~= nil and ranged > 0 then
        local okRng, range = pcall(function() return pUnit:GetRange(); end);
        if okRng and range ~= nil and range > 0 then
            parts[#parts + 1] = tostring(ranged) .. " ranged, range " .. tostring(range);
        else
            parts[#parts + 1] = tostring(ranged) .. " ranged";
        end
    end

    -- Moves remaining / max moves. Settlers have 2 MP, Warriors 2, Scouts 3.
    local okMR, movesRemaining = pcall(function() return pUnit:GetMovesRemaining(); end);
    local okMM, maxMoves = pcall(function() return pUnit:GetMaxMoves(); end);
    if okMR and okMM and movesRemaining ~= nil and maxMoves ~= nil then
        parts[#parts + 1] = tostring(roundMp(movesRemaining)) .. " of "
            .. tostring(roundMp(maxMoves)) .. " moves";
    end

    -- HP. Only mention if damaged — otherwise full HP is implied.
    local okD, damage = pcall(function() return pUnit:GetDamage(); end);
    local okMD, maxDamage = pcall(function() return pUnit:GetMaxDamage(); end);
    if okD and okMD and damage ~= nil and maxDamage ~= nil and damage > 0 then
        local hp = maxDamage - damage;
        parts[#parts + 1] = tostring(hp) .. " of " .. tostring(maxDamage) .. " HP";
    end

    -- status: user asked for info (pressed /). Queue politely behind
    -- whatever's in flight rather than clobbering it.
    Speech.emit(table.concat(parts, ". "), "status");
end

-- Cycle through ALL local-player units regardless of orders state.
-- Civ VI's `.` (NextUnit) and `,` (PrevUnit) only cycle units that
-- still need orders — once everything has moved/fortified, both keys
-- become no-ops and there's no keyboard way to revisit a unit that's
-- already done for the turn. Ctrl+. / Ctrl+, iterate the full unit
-- list instead, mirroring Civ V Access's cycleAllUnits pattern.
local function collectAllUnits(pPlayer)
    local list = {};
    if pPlayer == nil or pPlayer.GetUnits == nil then return list; end
    local units = pPlayer:GetUnits();
    if units == nil or units.Members == nil then return list; end
    -- Civ VI's Members() returns Lua's generic-for triple
    -- (iter_fn, container, control). The engine pattern is
    -- `for i, unit in container:Members() do` — the multi-return must
    -- flow through generic-for directly. Wrapping in pcall captures only
    -- the first value and breaks the binding, which fails with
    -- "Not a valid instance" inside lMembersAux. Confirmed via Noel's
    -- 2026-05-24 Lua.log line 384.
    for i, unit in units:Members() do
        list[#list + 1] = unit;
    end
    return list;
end

function UnitInfo.cycleAllUnits(forward)
    if Game == nil then return; end
    local localPlayerId = Game.GetLocalPlayer();
    if localPlayerId == -1 then return; end
    local pPlayer = Players[localPlayerId];
    if pPlayer == nil then return; end
    local list = collectAllUnits(pPlayer);
    local n = #list;
    if n == 0 then
        Speech.emit("No units", "meta");
        return;
    end
    -- Find current unit in list.
    local current = selectedUnit();
    local startIdx = nil;
    if current ~= nil and current:GetOwner() == localPlayerId then
        local cid = current:GetID();
        for i, unit in ipairs(list) do
            if unit:GetID() == cid then
                startIdx = i;
                break;
            end
        end
    end
    local idx;
    if startIdx == nil then
        idx = forward and 1 or n;
    elseif forward then
        idx = startIdx + 1;
        if idx > n then idx = 1; end
    else
        idx = startIdx - 1;
        if idx < 1 then idx = n; end
    end
    local nextUnit = list[idx];
    if nextUnit == nil then return; end
    -- Cycle-to-self gate. With one selectable unit, idx wraps back to
    -- the currently selected unit. UI.SelectUnit on the already-
    -- selected unit doesn't fire UnitSelectionChanged, so the speech
    -- path stays silent and the user gets no feedback at all.
    -- Announce explicitly so the user knows the cycle did something
    -- (even if "something" was confirming there's nothing else).
    if current ~= nil and nextUnit:GetID() == current:GetID()
       and nextUnit:GetOwner() == current:GetOwner() then
        Speech.emit("Only one unit. " .. StringifyUnit(nextUnit), "meta");
        return;
    end
    if UI ~= nil and UI.SelectUnit ~= nil then
        UI.SelectUnit(nextUnit);
    end
    -- Speech rides on Events.UnitSelectionChanged → SREH.ownUnitAnnouncement
    -- same as bare . / , — matching the audible bare-period pattern
    -- exactly. Previously injected a "Cycled. <name>" direct line
    -- here, but CAMM log analysis 2026-05-24 showed bare period
    -- (audible) and Ctrl+. (silent) hit Tolk with the SAME 3-call
    -- pattern except for that first injected line. Removing it makes
    -- the patterns identical so any remaining audibility difference
    -- points to something deeper than our Lua-side speech.
end

-- Recenter HexCursor on the selected unit. Useful when the cursor has
-- wandered away during exploration and the user wants to return to
-- whichever unit they're working with.
function UnitInfo.recenterOnUnit()
    local pUnit = selectedUnit();
    if pUnit == nil then
        Speech.emit("No unit selected", "meta");
        return;
    end
    local x, y = pUnit:GetX(), pUnit:GetY();
    if HexCursor ~= nil and HexCursor.jumpTo ~= nil then
        HexCursor.jumpTo(x, y);
    end
    -- Speak position + unit so the user gets a confirmation, since
    -- jumpTo is silent by design.
    Speech.emit("Cursor on " .. StringifyUnit(pUnit), "event");
end

local function Initialize()
    Log.info("UnitInfo.lua: file loaded");
    if Events ~= nil and Events.UnitSelectionChanged ~= nil then
        Events.UnitSelectionChanged.Add(onUnitSelectionChanged);
        Log.info("UnitInfo.Initialize: subscribed to Events.UnitSelectionChanged");
    else
        Log.warn("UnitInfo.Initialize: Events.UnitSelectionChanged unavailable");
    end
end
Initialize();
