-- Unit direct-move (Alt+QAZEDC). Phase 1 of the 0.5.x Playable Basics
-- arc. Single-hex commit per key press; multi-hex target mode is Phase 2.
--
-- Civ V Access has a much heavier movement layer (pending-move tracker
-- across SerialEventUnitMove + an engine-fork CivVAccessMissionDispatched
-- hook, war-confirm popup intercept, combat preflight, embark gate). We
-- start simpler in Civ VI because (a) there's no engine fork available,
-- (b) Civ VI's own MoveUnitToPlot helper already handles war popups +
-- attack vs. move dispatch + air units, and (c) combat is explicitly
-- deferred to a future release.
--
-- The whole flow: pre-validate (selection, ownership, edge, enemy, MP,
-- CanStartOperation) -> MoveUnitToPlot -> announce on UnitMoveComplete
-- -> sync HexCursor to follow.

include("Log");
include("ScreenReader");
include("HexCursor");

UnitMovement = UnitMovement or {};

local DIR_NAMES = {
    [DirectionTypes.DIRECTION_NORTHWEST] = "northwest",
    [DirectionTypes.DIRECTION_NORTHEAST] = "northeast",
    [DirectionTypes.DIRECTION_WEST]      = "west",
    [DirectionTypes.DIRECTION_EAST]      = "east",
    [DirectionTypes.DIRECTION_SOUTHWEST] = "southwest",
    [DirectionTypes.DIRECTION_SOUTHEAST] = "southeast",
};

-- Pending-move state. Stashed at commit time so the asynchronous
-- UnitMoveComplete handler knows which direction the user pressed and
-- which (player, unit) tuple to filter on. The engine fires
-- UnitMoveComplete for every unit's move (including AI moves during turn
-- processing), so the playerID + unitID filter is required.
local _pending = nil;

local function selectedUnit()
    if UI == nil or UI.GetHeadSelectedUnit == nil then return nil; end
    return UI.GetHeadSelectedUnit();
end

-- Returns the first enemy (different-owner) unit visible at the plot,
-- or nil if the plot is empty or only holds friendly / own units.
local function enemyAt(plot, localPlayerID)
    if plot == nil then return nil; end
    local x, y = plot:GetX(), plot:GetY();
    local units = Units.GetUnitsInPlotLayerID(x, y, MapLayers.ANY);
    if units == nil then return nil; end
    for _, unit in ipairs(units) do
        if unit:GetOwner() ~= localPlayerID then
            return unit;
        end
    end
    return nil;
end

local function unitTypeName(unit)
    if unit == nil then return "enemy unit"; end
    local info = GameInfo.Units[unit:GetUnitType()];
    if info == nil or info.Name == nil then return "enemy unit"; end
    return Locale.Lookup(info.Name);
end

local function formatMovesRemaining(mp)
    if mp <= 0 then return "out of moves"; end
    -- Civ VI's GetMovesRemaining returns whole MP for the keyboard-hotkey
    -- case (unit hasn't traversed mixed-cost terrain yet). Floor + 0.5
    -- defensively in case a fractional value shows up.
    local mpInt = math.floor(mp + 0.5);
    if mpInt == 1 then return "1 move remaining"; end
    return tostring(mpInt) .. " moves remaining";
end

function UnitMovement.directMove(direction)
    local pUnit = selectedUnit();
    if pUnit == nil then
        OutputMessageToScreenReader("No unit selected");
        return;
    end
    local localPlayerID = Game.GetLocalPlayer();
    if localPlayerID == -1 then return; end
    if pUnit:GetOwner() ~= localPlayerID then
        OutputMessageToScreenReader("Not your unit");
        return;
    end
    local sx, sy = pUnit:GetX(), pUnit:GetY();
    local target = Map.GetAdjacentPlot(sx, sy, direction);
    if target == nil then
        OutputMessageToScreenReader("Edge of map");
        return;
    end
    local tx, ty = target:GetX(), target:GetY();
    -- Combat is deferred to a future release per project_04_in_game_plan +
    -- the 0.5.x Playable Basics scope. If the target plot has an enemy,
    -- refuse the move with a helpful message rather than letting
    -- MoveUnitToPlot route to RANGE_ATTACK / COASTAL_RAID / ATTACK.
    local enemy = enemyAt(target, localPlayerID);
    if enemy ~= nil then
        OutputMessageToScreenReader(
            unitTypeName(enemy) .. " " .. DIR_NAMES[direction]
            .. ". Combat coming in a future release.");
        return;
    end
    -- 0-MP gate. Without this the engine accepts the move and queues it
    -- for next turn, which is invisible to a screen-reader user and
    -- collides with future target-mode queueing (Phase 2 Shift+Enter).
    if pUnit:GetMovesRemaining() <= 0 then
        OutputMessageToScreenReader("Out of moves");
        return;
    end
    -- Pre-validate. If the operation can't start (impassable terrain,
    -- embark restriction, friendly unit blocking, etc.) speak a generic
    -- failure rather than firing a no-op move and getting silence.
    local tParameters = {};
    tParameters[UnitOperationTypes.PARAM_X] = tx;
    tParameters[UnitOperationTypes.PARAM_Y] = ty;
    if not UnitManager.CanStartOperation(pUnit, UnitOperationTypes.MOVE_TO,
                                         nil, tParameters) then
        OutputMessageToScreenReader("Cannot move " .. DIR_NAMES[direction]);
        return;
    end
    -- Stash before commit so the UnitMoveComplete listener has the
    -- direction the user pressed when it fires.
    _pending = {
        playerID = localPlayerID,
        unitID = pUnit:GetID(),
        direction = direction,
        targetX = tx,
        targetY = ty,
    };
    -- Issue the move directly via UnitManager.RequestOperation. The engine
    -- helper MoveUnitToPlot from Civ6Common.lua isn't in scope here
    -- (Civ6Common isn't included in our addin context, confirmed via
    -- "function expected instead of nil" at first test). We don't need
    -- its war-popup or attack-dispatch logic anyway — our pre-validation
    -- above already filters enemy / combat cases.
    tParameters[UnitOperationTypes.PARAM_MODIFIERS] = UnitOperationMoveModifiers.NONE;
    UnitManager.RequestOperation(pUnit, UnitOperationTypes.MOVE_TO, tParameters);
end

-- Shared resolver. Reads the unit's current position from the player's
-- unit cache (not from the event args, which differ per event), then
-- speaks moved / stopped-short. Idempotent — clearing _pending guards
-- against multiple events firing for the same commit (UnitMoveComplete
-- AND UnitOperationsCleared can both fire; whichever arrives first wins).
local function resolveAndSpeak()
    if _pending == nil then return; end
    local snap = _pending;
    _pending = nil;
    local pPlayer = Players[snap.playerID];
    if pPlayer == nil then return; end
    local pUnit = pPlayer:GetUnits():FindID(snap.unitID);
    if pUnit == nil then return; end
    local x, y = pUnit:GetX(), pUnit:GetY();
    -- If the unit didn't move (still at start), the engine refused the
    -- operation. Speak that explicitly rather than misleading "Moved".
    if x == snap.startX and y == snap.startY then
        OutputMessageToScreenReader("Move blocked " .. (DIR_NAMES[snap.direction] or "?"));
        return;
    end
    local direction = DIR_NAMES[snap.direction] or "?";
    local reached = (x == snap.targetX and y == snap.targetY);
    local lead = reached and ("Moved " .. direction)
                          or ("Stopped short " .. direction);
    local mpText = formatMovesRemaining(pUnit:GetMovesRemaining());
    OutputMessageToScreenReader(lead .. ". " .. mpText);
    if HexCursor ~= nil and HexCursor.jumpTo ~= nil then
        HexCursor.jumpTo(x, y);
    end
end

-- The engine fires three different events depending on the operation
-- shape and outcome — UnitPanel.lua subscribes to all three. We saw in
-- test (2026-05-24) that UnitMoveComplete alone missed the SECOND move
-- in a multi-move turn: the Settler's MP dropped from 2 to 1 (so the
-- move physically happened) but no announce fired, because the engine
-- routed that completion through UnitOperationsCleared instead.

function UnitMovement.onMoveComplete(playerID, unitID, x, y)
    if _pending == nil then return; end
    if playerID ~= _pending.playerID or unitID ~= _pending.unitID then return; end
    resolveAndSpeak();
end

function UnitMovement.onUnitOperationDeactivated(playerID, unitID, hOp, iData1)
    if _pending == nil then return; end
    if playerID ~= _pending.playerID or unitID ~= _pending.unitID then return; end
    resolveAndSpeak();
end

function UnitMovement.onUnitOperationsCleared(playerID, unitID, hOp, iData1)
    if _pending == nil then return; end
    if playerID ~= _pending.playerID or unitID ~= _pending.unitID then return; end
    resolveAndSpeak();
end

local function Initialize()
    Log.info("UnitMovement.lua: file loaded");
    if Events == nil then
        Log.warn("UnitMovement.Initialize: Events table unavailable");
        return;
    end
    if Events.UnitMoveComplete ~= nil then
        Events.UnitMoveComplete.Add(UnitMovement.onMoveComplete);
        Log.info("UnitMovement.Initialize: subscribed to Events.UnitMoveComplete");
    end
    if Events.UnitOperationDeactivated ~= nil then
        Events.UnitOperationDeactivated.Add(UnitMovement.onUnitOperationDeactivated);
        Log.info("UnitMovement.Initialize: subscribed to Events.UnitOperationDeactivated");
    end
    if Events.UnitOperationsCleared ~= nil then
        Events.UnitOperationsCleared.Add(UnitMovement.onUnitOperationsCleared);
        Log.info("UnitMovement.Initialize: subscribed to Events.UnitOperationsCleared");
    end
end
Initialize();
