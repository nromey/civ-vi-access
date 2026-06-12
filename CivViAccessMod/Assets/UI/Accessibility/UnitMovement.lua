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

-- Unit to re-grab after the engine auto-deselects it post-move. Set in
-- resolveAndSpeak when the moved unit can still act; consumed (one-shot) by the
-- addin's selection handler. nil = let the engine's deselect stand.
local _keepSel = nil;

-- Move-to (P2) destination tracking, keyed "player:unit". The engine auto-paths a
-- distant MOVE_TO across turns; we stay silent on the per-hex UnitMoveComplete
-- events (the one-hex _pending isn't set for move-to) and announce only on
-- ARRIVAL. Forward-declared checker so the move-complete handlers (defined above
-- the move-to block) can reach it.
local _moveToTargets = {};
local checkMoveToArrival;

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

-- True if any enemy unit sits on a hex ADJACENT to (x,y) — the usual cause of a
-- move that passes pre-validation but then doesn't budge (zone of control).
local function enemyAdjacent(x, y, localPlayerID)
    for dir = 0, (DirectionTypes.NUM_DIRECTION_TYPES or 6) - 1 do
        local adj = Map.GetAdjacentPlot(x, y, dir);
        if adj ~= nil and enemyAt(adj, localPlayerID) ~= nil then return true; end
    end
    return false;
end

local function unitTypeName(unit)
    if unit == nil then return "enemy unit"; end
    local info = GameInfo.Units[unit:GetUnitType()];
    if info == nil or info.Name == nil then return "enemy unit"; end
    return Locale.Lookup(info.Name);
end

-- Best-effort reason a one-hex move was refused, by inspecting the target hex
-- (and the shared edge for cliffs). Returns nil when no concrete cause is found
-- so the caller falls back to the bare "Cannot move <dir>". Noel 2026-06-01:
-- "tell me WHY I can't go that way" — ocean / mountain / cliff / impassable.
local function blockedReason(fromPlot, toPlot, direction)
    if toPlot == nil then return "edge of map"; end
    if toPlot.IsWater and toPlot:IsWater() then
        local terr = GameInfo.Terrains[toPlot:GetTerrainType()];
        if terr ~= nil and terr.TerrainType == "TERRAIN_OCEAN" then return "ocean"; end
        return "water";
    end
    if toPlot.IsMountain and toPlot:IsMountain() then return "mountain"; end
    -- Cliffs sit on hex EDGES. A plot stores cliffs on its NW/W/NE edges; the
    -- SE/E/SW edges live on the neighbour as ITS NW/W/NE. Map the move direction
    -- to whichever plot owns that shared edge.
    local DT = DirectionTypes;
    local cliff = false;
    pcall(function()
        if     direction == DT.DIRECTION_NORTHWEST then cliff = fromPlot:IsNWOfCliff();
        elseif direction == DT.DIRECTION_WEST      then cliff = fromPlot:IsWOfCliff();
        elseif direction == DT.DIRECTION_NORTHEAST then cliff = fromPlot:IsNEOfCliff();
        elseif direction == DT.DIRECTION_SOUTHEAST then cliff = toPlot:IsNWOfCliff();
        elseif direction == DT.DIRECTION_EAST      then cliff = toPlot:IsWOfCliff();
        elseif direction == DT.DIRECTION_SOUTHWEST then cliff = toPlot:IsNEOfCliff();
        end
    end);
    if cliff then return "cliff"; end
    if toPlot.IsImpassable and toPlot:IsImpassable() then return "impassable terrain"; end
    return nil;
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
    _keepSel = nil;   -- reset each attempt; resolveAndSpeak re-sets it if moves remain
    local pUnit = selectedUnit();
    if pUnit == nil then
        Speech.emit("No unit selected", "meta");
        return;
    end
    local localPlayerID = Game.GetLocalPlayer();
    if localPlayerID == -1 then return; end
    if pUnit:GetOwner() ~= localPlayerID then
        Speech.emit("Not your unit", "meta");
        return;
    end
    local sx, sy = pUnit:GetX(), pUnit:GetY();
    local target = Map.GetAdjacentPlot(sx, sy, direction);
    if target == nil then
        Speech.emit("Edge of map", "meta");
        return;
    end
    local tx, ty = target:GetX(), target:GetY();
    -- Enemy on the adjacent target -> route into the combat preview/confirm flow
    -- (P3). Moving a melee unit into an adjacent enemy IS the attack; UnitCombat
    -- previews the odds on the first press and commits on the second.
    local enemy = enemyAt(target, localPlayerID);
    if enemy ~= nil then
        if UnitCombat ~= nil and UnitCombat.requestAttackAt ~= nil then
            UnitCombat.requestAttackAt(pUnit, target);
        else
            Speech.emit(unitTypeName(enemy) .. " " .. DIR_NAMES[direction] .. ".", "meta");
        end
        return;
    end
    -- 0-MP gate. Without this the engine accepts the move and queues it
    -- for next turn, which is invisible to a screen-reader user and
    -- collides with future target-mode queueing (Phase 2 Shift+Enter).
    if pUnit:GetMovesRemaining() <= 0 then
        Speech.emit("Out of moves", "meta");
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
        -- Enrich the refusal with WHY (Noel 2026-06-01): unit type + direction
        -- + concrete cause when we can name one ("Cannot move Settler southwest,
        -- cliff"). Falls back to bare direction when the cause is opaque.
        local reason = blockedReason(Map.GetPlot(sx, sy), target, direction);
        local msg = "Cannot move " .. unitTypeName(pUnit) .. " " .. DIR_NAMES[direction];
        if reason ~= nil then msg = msg .. ", " .. reason; end
        Speech.emit(msg, "meta");
        return;
    end
    -- Stash before commit so the UnitMoveComplete listener has the
    -- direction the user pressed when it fires. startX/startY let
    -- resolveAndSpeak distinguish "didn't move at all" (Move blocked)
    -- from "moved partway" (Stopped short) — without them, the engine
    -- accepting MOVE_TO but the unit not budging (insufficient MP for
    -- the cheapest path step, etc.) would falsely announce as
    -- "Stopped short. 1 move remaining", confusing the user.
    _pending = {
        playerID = localPlayerID,
        unitID = pUnit:GetID(),
        direction = direction,
        startX = sx,
        startY = sy,
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
    -- Keep this unit selected if it can still act, so the engine's auto-deselect
    -- after the move doesn't strand the user on "No unit selected" (Noel
    -- 2026-06-01). Covers both moved and blocked-but-has-moves; out-of-moves
    -- units fall through to the engine's normal cycle.
    if pUnit:GetMovesRemaining() > 0 then
        _keepSel = { playerID = snap.playerID, unitID = snap.unitID };
    else
        _keepSel = nil;
    end
    -- If the unit didn't move (still at start), the engine refused the
    -- operation silently. Speak that explicitly rather than misleading
    -- "Moved" or "Stopped short" — both of which imply some motion.
    if x == snap.startX and y == snap.startY then
        -- The move may have been ACCEPTED but DEFERRED to next turn: the unit had
        -- already moved this turn and can't afford the target tile's MP cost now
        -- (rough terrain — hills cost 2). The engine QUEUES it rather than refusing,
        -- so the unit doesn't budge THIS turn. That's NOT a block (Noel 2026-06-12:
        -- "desert hills shouldn't block a warrior" — it didn't; the move was queued).
        if UnitManager ~= nil and UnitManager.GetQueuedDestination ~= nil then
            local okDest, destId = pcall(function() return UnitManager.GetQueuedDestination(pUnit); end);
            if okDest and destId ~= nil and Map ~= nil and Map.GetPlotByIndex ~= nil then
                local dest = Map.GetPlotByIndex(destId);
                if dest ~= nil and dest:GetX() == snap.targetX and dest:GetY() == snap.targetY then
                    Speech.emit(unitTypeName(pUnit) .. " moving " .. (DIR_NAMES[snap.direction] or "?")
                        .. ", not enough moves this turn, arrives next turn.", "move_result");
                    return;
                end
            end
        end
        -- No queued move -> a real block. Passed the pre-check but didn't budge —
        -- almost always enemy zone of control from an adjacent unit, sometimes a
        -- terrain edge. Name it (Noel 2026-06-01: "blocked without finding out why").
        local why = blockedReason(Map.GetPlot(snap.startX, snap.startY),
                                  Map.GetPlot(snap.targetX, snap.targetY), snap.direction);
        if why == nil and enemyAdjacent(snap.startX, snap.startY, snap.playerID) then
            why = "enemy zone of control";
        end
        local msg = unitTypeName(pUnit) .. " blocked " .. (DIR_NAMES[snap.direction] or "?");
        if why ~= nil then msg = msg .. ", " .. why; end
        Speech.emit(msg, "move_result");
        return;
    end
    -- Lead with the UNIT NAME (Noel 2026-06-11): "Warrior moved west" not "Moved
    -- west". A directional press is always one hex, so distance is implicit; the
    -- moves-remaining is the useful number. (Multi-hex distance lives on move-to / M.)
    local direction = DIR_NAMES[snap.direction] or "?";
    local name = unitTypeName(pUnit);
    local reached = (x == snap.targetX and y == snap.targetY);
    local lead = reached and (name .. " moved " .. direction)
                          or (name .. " stopped short " .. direction);
    local mpText = formatMovesRemaining(pUnit:GetMovesRemaining());
    Speech.emit(lead .. ". " .. mpText, "move_result");
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
    if checkMoveToArrival ~= nil then checkMoveToArrival(playerID, unitID); end
    if _pending ~= nil and playerID == _pending.playerID and unitID == _pending.unitID then
        resolveAndSpeak();
    end
end

function UnitMovement.onUnitOperationDeactivated(playerID, unitID, hOp, iData1)
    if checkMoveToArrival ~= nil then checkMoveToArrival(playerID, unitID); end
    if _pending ~= nil and playerID == _pending.playerID and unitID == _pending.unitID then
        resolveAndSpeak();
    end
end

function UnitMovement.onUnitOperationsCleared(playerID, unitID, hOp, iData1)
    if checkMoveToArrival ~= nil then checkMoveToArrival(playerID, unitID); end
    if _pending ~= nil and playerID == _pending.playerID and unitID == _pending.unitID then
        resolveAndSpeak();
    end
end

-- Keep-selected coordination with the addin's selection handler. After a move
-- leaves the unit able to act, the engine auto-deselects it; the addin re-grabs
-- it iff this returns true, then calls clearKeepSelected (one-shot, loop-safe).
function UnitMovement.shouldKeepSelected(playerID, unitID)
    return _keepSel ~= nil
       and _keepSel.playerID == playerID and _keepSel.unitID == unitID;
end

function UnitMovement.clearKeepSelected()
    _keepSel = nil;
end

-- Civ V Access pattern: one "rest" key wraps both MISSION_FORTIFY
-- (military) and MISSION_SLEEP (civilian) — see
-- CivVAccess_UnitControlMovement.lua line 313:
--   SLEEP = { "MISSION_FORTIFY", "MISSION_SLEEP" }
-- Civ VI keeps SLEEP / FORTIFY / ALERT / HEAL / SKIP_TURN as separate
-- UnitOperations and the engine refuses SLEEP on military units
-- (Warrior CanStart=false, no failure reasons populated). Diagnostic
-- 2026-05-26 confirmed via cascade trial: Sleep refused on Warrior,
-- Fortify accepted on same unit.
--
-- R = smart Rest: cascade through the rest operations and dispatch
-- the first the engine accepts. Civilians land on SLEEP, military on
-- FORTIFY, others fall through. ALERT is included so units that can
-- defend but aren't combat-fortifiable still have a resting state.
local REST_CASCADE = {
    { name = "Sleep",    op = UnitOperationTypes.SLEEP },
    { name = "Fortify",  op = UnitOperationTypes.FORTIFY },
    { name = "Alert",    op = UnitOperationTypes.ALERT },
    { name = "Heal",     op = UnitOperationTypes.HEAL },
    { name = "SkipTurn", op = UnitOperationTypes.SKIP_TURN },
};

function UnitMovement.rest()
    local pUnit = selectedUnit();
    if pUnit == nil then
        Speech.emit("No unit selected", "meta");
        return;
    end
    local localPlayerID = Game.GetLocalPlayer();
    if localPlayerID == -1 then return; end
    if pUnit:GetOwner() ~= localPlayerID then
        Speech.emit("Not your unit", "meta");
        return;
    end
    for _, entry in ipairs(REST_CASCADE) do
        local ok = UnitManager.CanStartOperation(
            pUnit, entry.op, nil, false, OperationResultsTypes.NO_TARGETS);
        if ok then
            UnitManager.RequestOperation(pUnit, entry.op, nil);
            Speech.emit(unitTypeName(pUnit) .. " " .. string.lower(entry.name), "event");
            return;
        end
    end
    Speech.emit("Cannot rest " .. unitTypeName(pUnit), "meta");
end

-- Alt+Z (Civ V muscle memory) = strict Sleep. Civilians actually sleep.
-- Military units get an educational redirect to R: "Cannot sleep
-- Warrior. Press R to fortify instead." On a civilian that's mid-task
-- (Sleep also refused), don't suggest R — Fortify won't accept either.
function UnitMovement.sleepStrict()
    local pUnit = selectedUnit();
    if pUnit == nil then
        Speech.emit("No unit selected", "meta");
        return;
    end
    local localPlayerID = Game.GetLocalPlayer();
    if localPlayerID == -1 then return; end
    if pUnit:GetOwner() ~= localPlayerID then
        Speech.emit("Not your unit", "meta");
        return;
    end
    local ok = UnitManager.CanStartOperation(
        pUnit, UnitOperationTypes.SLEEP, nil, false, OperationResultsTypes.NO_TARGETS);
    if ok then
        UnitManager.RequestOperation(pUnit, UnitOperationTypes.SLEEP, nil);
        Speech.emit(unitTypeName(pUnit) .. " sleeping", "event");
        return;
    end
    -- Sleep refused. If Fortify would accept, this is a military unit —
    -- redirect to R. Otherwise the unit is stuck on its own state
    -- (mid-mission civilian, etc.), no R suggestion.
    local fortifyOk = UnitManager.CanStartOperation(
        pUnit, UnitOperationTypes.FORTIFY, nil, false, OperationResultsTypes.NO_TARGETS);
    if fortifyOk then
        Speech.emit(
            "Cannot sleep " .. unitTypeName(pUnit) .. ". Press R to fortify instead.",
            "meta");
    else
        Speech.emit("Cannot sleep " .. unitTypeName(pUnit), "meta");
    end
end

-- Alt+X = auto-explore ("eXplore"). The vanilla engine "AutoExplore" hotkey is
-- the C++ hotkey FOR UNITOPERATION_AUTOMATE_EXPLORE, and it can't be used: its
-- key (E) is the HexCursor NE pan, and bare E intercepts Alt+E (pressing Alt+E
-- fires CursorNE, not the Alt+E binding — Noel 2026-06-02). So auto-explore
-- lives on Alt+X and we issue the operation directly, the same way
-- rest()/sleepStrict() issue SLEEP/FORTIFY — reliable and VM-safe.
function UnitMovement.autoExplore()
    local pUnit = selectedUnit();
    if pUnit == nil then
        Speech.emit("No unit selected", "meta");
        return;
    end
    local localPlayerID = Game.GetLocalPlayer();
    if localPlayerID == -1 then return; end
    if pUnit:GetOwner() ~= localPlayerID then
        Speech.emit("Not your unit", "meta");
        return;
    end
    -- Resolve the operation hash the way the ENGINE does: it iterates
    -- GameInfo.UnitOperations and uses operationRow.Hash (UnitPanel.lua). The
    -- convenience constant UnitOperationTypes.AUTOMATE_EXPLORE may be nil for
    -- this op, which makes CanStartOperation(pUnit, nil, ...) silently return
    -- false — the likely cause of "cannot auto-explore" on a full-move unit.
    local row = GameInfo.UnitOperations
                and GameInfo.UnitOperations["UNITOPERATION_AUTOMATE_EXPLORE"] or nil;
    local op = (row ~= nil and row.Hash)
            or (UnitOperationTypes ~= nil and UnitOperationTypes.AUTOMATE_EXPLORE) or nil;
    Log.info("autoExplore: op=" .. tostring(op)
        .. " GameInfo.Hash=" .. tostring(row and row.Hash)
        .. " UnitOperationTypes.AUTOMATE_EXPLORE="
        .. tostring(UnitOperationTypes and UnitOperationTypes.AUTOMATE_EXPLORE));
    if op == nil then
        Speech.emit("Auto-explore operation not found", "meta");
        return;
    end

    -- Two-tier check, mirroring the base UnitPanel (VisibleInUI branch):
    --   loose (nil,true)         = can this unit type EVER auto-explore?
    --   real  (false,NO_TARGETS) = can it start RIGHT NOW? (when false, vanilla
    --                              shows the button greyed/disabled, not absent.)
    local everCan = UnitManager.CanStartOperation(pUnit, op, nil, true);
    if not everCan then
        Speech.emit(unitTypeName(pUnit) .. " can't auto-explore.", "meta");
        return;
    end
    local canNow, tResults = UnitManager.CanStartOperation(
        pUnit, op, nil, false, OperationResultsTypes.NO_TARGETS);
    if canNow then
        UnitManager.RequestOperation(pUnit, op, nil);
        Speech.emit(unitTypeName(pUnit) .. " exploring", "event");
        return;
    end
    -- Can't start this instant. Surface the engine's reason if it gave one.
    local reason = nil;
    if tResults ~= nil and UnitOperationResults ~= nil
       and tResults[UnitOperationResults.FAILURE_REASONS] ~= nil then
        local rs = tResults[UnitOperationResults.FAILURE_REASONS];
        if rs[1] ~= nil then reason = Locale.Lookup(rs[1]); end
    end
    if reason ~= nil and reason ~= "" then
        Speech.emit("Cannot auto-explore " .. unitTypeName(pUnit) .. " yet. " .. reason, "meta");
    else
        Speech.emit("Cannot auto-explore " .. unitTypeName(pUnit)
            .. ". Check the log for the reason.", "meta");
    end
end

-- Shift+B = build an improvement with the selected Builder.
--
-- v1 (2026-06-02): build the engine-RECOMMENDED improvement (BEST_IMPROVEMENT)
-- for the unit's current tile and announce it plus the other valid options, so
-- the player can improve tiles immediately and learns what else is buildable.
--
-- v2 design (Noel 2026-06-02): keep it ALL on Shift+B (no separate auto vs pick
-- key). Shift+B opens a navigable list whose TOP entry is "Build recommended"
-- (the v1 behavior here) with the specific improvements below it to choose from
-- — progressive disclosure, recommended-default-first. Needs world-view list
-- input (a HandlerStack picker handler), so build/validate it live.
--
-- Enumeration mirrors the base UnitPanel build branch: one CanStartOperation
-- with PARAM_X/PARAM_Y returns tResults[IMPROVEMENTS] (valid improvements for
-- the tile) + BEST_IMPROVEMENT; we set PARAM_IMPROVEMENT_TYPE and RequestOperation.
function UnitMovement.buildImprovement()
    local pUnit = selectedUnit();
    if pUnit == nil then
        Speech.emit("No unit selected", "meta");
        return;
    end
    local localPlayerID = Game.GetLocalPlayer();
    if localPlayerID == -1 then return; end
    if pUnit:GetOwner() ~= localPlayerID then
        Speech.emit("Not your unit", "meta");
        return;
    end

    -- Resolve the BUILD_IMPROVEMENT hash (UnitOperationTypes may be nil for some
    -- ops — see autoExplore — so fall back to the GameInfo row hash).
    local row = GameInfo.UnitOperations
                and GameInfo.UnitOperations["UNITOPERATION_BUILD_IMPROVEMENT"] or nil;
    local op = (UnitOperationTypes ~= nil and UnitOperationTypes.BUILD_IMPROVEMENT)
            or (row ~= nil and row.Hash) or nil;
    if op == nil then
        Speech.emit("Build operation not found", "meta");
        return;
    end

    local tParameters = {};
    tParameters[UnitOperationTypes.PARAM_X] = pUnit:GetX();
    tParameters[UnitOperationTypes.PARAM_Y] = pUnit:GetY();

    local bCanStart, tResults = UnitManager.CanStartOperation(pUnit, op, nil, tParameters, true);
    local improvements = (bCanStart and tResults ~= nil)
                         and tResults[UnitOperationResults.IMPROVEMENTS] or nil;
    if improvements == nil or #improvements == 0 then
        Speech.emit("Nothing to build on this tile with " .. unitTypeName(pUnit) .. ".", "meta");
        return;
    end

    local best = tResults[UnitOperationResults.BEST_IMPROVEMENT];
    local chosen = nil;
    if best ~= nil and best ~= -1 then
        for _, eImp in ipairs(improvements) do
            if eImp == best then chosen = eImp; break; end
        end
    end
    if chosen == nil then chosen = improvements[1]; end

    local function impName(eImp)
        local r = GameInfo.Improvements and GameInfo.Improvements[eImp] or nil;
        return (r ~= nil and r.Name ~= nil) and Locale.Lookup(r.Name) or "an improvement";
    end

    tParameters[UnitOperationTypes.PARAM_IMPROVEMENT_TYPE] = chosen;
    UnitManager.RequestOperation(pUnit, op, tParameters);

    local msg = "Building " .. impName(chosen);
    if #improvements > 1 then
        local others = {};
        for _, eImp in ipairs(improvements) do
            if eImp ~= chosen then others[#others + 1] = impName(eImp); end
        end
        if #others > 0 then
            msg = msg .. ". Also available here: " .. table.concat(others, ", ");
        end
    end
    Speech.emit(msg .. ".", "event");
end

-- ===========================================================================
--  MOVE-TO (P2): send the selected unit to the HEX CURSOR; the engine auto-paths
--  across turns. Preview (Shift+M) is read-only; move (M) commits. Destination =
--  the cursor (our universal pointer — parked by scanner Home / nav / search).
--  Civ VI exposes the pathfinder in stock Lua (UnitManager.GetMoveToPathEx) and
--  RequestOperation(MOVE_TO, distant x,y) resumes each turn natively — no engine
--  fork (unlike Civ V Access), no per-turn re-issue. See project_routes_builder.
--  Phase 2 (deferred): manual waypoint legs + worker route-to.
-- ===========================================================================

-- pathInfo = { plots = {plotId,...}, turns = {turnNum,...} }. Total turns to
-- arrive = the largest turn number on the path.
local function pathTurns(pathInfo)
    if pathInfo == nil or pathInfo.turns == nil then return 1; end
    local t = 1;
    for _, n in pairs(pathInfo.turns) do
        if type(n) == "number" and n > t then t = n; end
    end
    return t;
end

-- A land unit whose path includes a water plot needs to embark.
local function pathCrossesWater(pathInfo, pUnit)
    if pathInfo == nil or pathInfo.plots == nil then return false; end
    local info = GameInfo.Units[pUnit:GetUnitType()];
    if info == nil or info.Domain ~= "DOMAIN_LAND" then return false; end
    for _, pid in pairs(pathInfo.plots) do
        local p = Map.GetPlotByIndex(pid);
        if p ~= nil and p.IsWater ~= nil and p:IsWater() then return true; end
    end
    return false;
end

-- Does the path run through tiles you haven't explored?
local function pathEntersFog(pathInfo, localPlayerID)
    if pathInfo == nil or pathInfo.plots == nil then return false; end
    local vis = (PlayersVisibility ~= nil) and PlayersVisibility[localPlayerID] or nil;
    if vis == nil or vis.IsRevealed == nil then return false; end
    for _, pid in pairs(pathInfo.plots) do
        local p = Map.GetPlotByIndex(pid);
        if p ~= nil then
            local ok, r = pcall(function() return vis:IsRevealed(p:GetX(), p:GetY()); end);
            if ok and r ~= true then return true; end
        end
    end
    return false;
end

local function cursorTarget()
    if HexCursor ~= nil and HexCursor.position ~= nil then return HexCursor.position(); end
    return nil, nil;
end

-- Shared front-half: selected OWN unit + a distinct cursor plot, or nil + reason.
local function moveToContext()
    local pUnit = selectedUnit();
    if pUnit == nil then Speech.emit("No unit selected", "meta"); return nil; end
    local lp = Game.GetLocalPlayer();
    if lp == -1 then return nil; end
    if pUnit:GetOwner() ~= lp then Speech.emit("Not your unit", "meta"); return nil; end
    local cx, cy = cursorTarget();
    if cx == nil then Speech.emit("No cursor target", "meta"); return nil; end
    local endPlot = Map.GetPlot(cx, cy);
    if endPlot == nil then Speech.emit("No tile there", "meta"); return nil; end
    if pUnit:GetX() == cx and pUnit:GetY() == cy then
        Speech.emit("Unit is already there", "meta"); return nil;
    end
    return pUnit, lp, cx, cy, endPlot;
end

-- Shift+M — read-only path preview to the cursor.
function UnitMovement.previewToCursor()
    local pUnit, lp, cx, cy, endPlot = moveToContext();
    if pUnit == nil then return; end
    local pathInfo = UnitManager.GetMoveToPathEx(pUnit, endPlot:GetIndex());
    if pathInfo == nil or pathInfo.plots == nil or table.count(pathInfo.plots) <= 1 then
        Speech.emit("No path there for " .. unitTypeName(pUnit) .. ".", "meta"); return;
    end
    local turns = pathTurns(pathInfo);
    local dir  = HexGeom.directionString(pUnit:GetX(), pUnit:GetY(), cx, cy) or "";
    local dist = Map.GetPlotDistance(pUnit:GetX(), pUnit:GetY(), cx, cy);
    local turnWord = (turns == 1) and "1 turn" or (turns .. " turns");
    local msg = turnWord .. " to " .. dir .. ", " .. dist .. " hexes";
    if pathCrossesWater(pathInfo, pUnit) then msg = msg .. ", crosses water, needs embark"; end
    if pathEntersFog(pathInfo, lp) then msg = msg .. ", enters unexplored"; end
    Speech.emit(msg .. ".", "status");
end

-- M — commit: move the selected unit to the cursor (multi-turn auto-path).
function UnitMovement.moveToCursor()
    local pUnit, lp, cx, cy, endPlot = moveToContext();
    if pUnit == nil then return; end
    -- Enemy on the target -> route into the combat preview/confirm flow (P3).
    -- Melee only via this path; UnitCombat refuses a non-adjacent melee with a
    -- "move closer" hint, and ranged units are nudged to the A key.
    local enemy = enemyAt(endPlot, lp);
    if enemy ~= nil then
        if UnitCombat ~= nil and UnitCombat.requestAttackAt ~= nil then
            UnitCombat.requestAttackAt(pUnit, endPlot);
        else
            Speech.emit(unitTypeName(enemy) .. " on target.", "meta");
        end
        return;
    end
    local tParameters = {};
    tParameters[UnitOperationTypes.PARAM_X] = cx;
    tParameters[UnitOperationTypes.PARAM_Y] = cy;
    if not UnitManager.CanStartOperation(pUnit, UnitOperationTypes.MOVE_TO, nil, tParameters) then
        Speech.emit("Can't path " .. unitTypeName(pUnit) .. " there.", "meta");
        return;
    end
    local turns = pathTurns(UnitManager.GetMoveToPathEx(pUnit, endPlot:GetIndex()));
    local dir   = HexGeom.directionString(pUnit:GetX(), pUnit:GetY(), cx, cy) or "";
    -- Track for the arrival announce. The engine auto-paths; per-hex
    -- UnitMoveComplete events stay silent (no _pending) until the unit arrives.
    _moveToTargets[lp .. ":" .. pUnit:GetID()] = { destX = cx, destY = cy };
    tParameters[UnitOperationTypes.PARAM_MODIFIERS] = UnitOperationMoveModifiers.NONE;
    UnitManager.RequestOperation(pUnit, UnitOperationTypes.MOVE_TO, tParameters);
    local turnWord = (turns <= 1) and "arriving this turn" or (turns .. " turns");
    Speech.emit("Moving " .. unitTypeName(pUnit) .. " " .. dir .. ", " .. turnWord .. ".", "event");
end

-- Arrival checker (forward-declared above). Fires from the move-complete events;
-- announces + untracks when a tracked move-to unit reaches its destination.
checkMoveToArrival = function(playerID, unitID)
    local key = playerID .. ":" .. unitID;
    local tgt = _moveToTargets[key];
    if tgt == nil then return; end
    local pPlayer = Players[playerID];
    if pPlayer == nil then _moveToTargets[key] = nil; return; end
    local pUnit = pPlayer:GetUnits():FindID(unitID);
    if pUnit == nil then _moveToTargets[key] = nil; return; end   -- died en route
    if pUnit:GetX() == tgt.destX and pUnit:GetY() == tgt.destY then
        _moveToTargets[key] = nil;
        Speech.emit(unitTypeName(pUnit) .. " arrived at destination.", "event");
    end
end

-- Turn-start progress: terse "N turns remaining" for each unit still en route, so
-- a unit walking on its own isn't a surprise. Drops finished/cancelled tracks.
function UnitMovement.onLocalTurnBegin()
    local lp = Game.GetLocalPlayer();
    if lp == -1 or Players[lp] == nil then return; end
    for key, tgt in pairs(_moveToTargets) do
        local pidStr, uidStr = key:match("^(%d+):(%d+)$");
        local pid, uid = tonumber(pidStr), tonumber(uidStr);
        if pid == lp then
            local pUnit = Players[lp]:GetUnits():FindID(uid);
            if pUnit == nil then
                _moveToTargets[key] = nil;
            elseif UnitManager.GetQueuedDestination(pUnit) ~= nil then
                local endPlot = Map.GetPlot(tgt.destX, tgt.destY);
                local turns = endPlot and pathTurns(UnitManager.GetMoveToPathEx(pUnit, endPlot:GetIndex())) or nil;
                if turns ~= nil then
                    local tw = (turns <= 1) and "arriving this turn" or (turns .. " turns remaining");
                    Speech.emit(unitTypeName(pUnit) .. " moving to destination, " .. tw .. ".", "status");
                end
            else
                _moveToTargets[key] = nil;   -- no longer queued (arrived / cancelled)
            end
        end
    end
end

local function doCancel(pUnit, lp)
    UnitManager.RequestCommand(pUnit, UnitCommandTypes.CANCEL, nil);
    _moveToTargets[lp .. ":" .. pUnit:GetID()] = nil;
    Speech.emit("Movement cancelled, " .. unitTypeName(pUnit) .. ".", "event");
end

-- A unit auto-moving must be cancelled WITHOUT relying on re-selecting it — the
-- engine drops a queued-move unit from the needs-orders cycle, so "select it
-- again" fails ("only one ready unit"). So Ctrl+M finds the unit to cancel in
-- order: the selected unit, then a moving unit under the cursor (scan to it ->
-- Home -> Ctrl+M), then — the common case — the single unit you have en route.
function UnitMovement.cancelMove()
    local lp = Game.GetLocalPlayer();
    if lp == -1 then return; end

    -- 1. Selected unit with a queued move.
    local sel = selectedUnit();
    if sel ~= nil and sel:GetOwner() == lp and UnitManager.GetQueuedDestination(sel) ~= nil then
        doCancel(sel, lp); return;
    end

    -- 2. An own unit on the cursor tile with a queued move.
    local cx, cy = cursorTarget();
    if cx ~= nil and Units ~= nil and Units.GetUnitsInPlotLayerID ~= nil then
        local units = Units.GetUnitsInPlotLayerID(cx, cy, MapLayers.ANY);
        if units ~= nil then
            for _, u in ipairs(units) do
                if u:GetOwner() == lp and UnitManager.GetQueuedDestination(u) ~= nil then
                    doCancel(u, lp); return;
                end
            end
        end
    end

    -- 3. The single unit we're tracking as en route (the "undo my last move" case).
    local onlyKey, count = nil, 0;
    for key, _ in pairs(_moveToTargets) do
        if tonumber(key:match("^(%d+):")) == lp then count = count + 1; onlyKey = key; end
    end
    if count == 1 then
        local uid = tonumber(onlyKey:match(":(%d+)$"));
        local u = (Players[lp] ~= nil) and Players[lp]:GetUnits():FindID(uid) or nil;
        if u ~= nil then doCancel(u, lp); return; end
        _moveToTargets[onlyKey] = nil;
    elseif count > 1 then
        Speech.emit("Several units are moving. Scan to one and press Home, then Ctrl+M.", "meta");
        return;
    end
    Speech.emit("No movement to cancel.", "meta");
end

-- Key dispatch, forwarded from the capture-all wrap. M = move-to-cursor,
-- Shift+M = preview, Ctrl+M = cancel. mods bit0 = Shift, bit1 = Ctrl.
local KEY_M = Keys and Keys.M;
function UnitMovement.dispatch(key, mods)
    mods = mods or 0;
    if KEY_M ~= nil and key == KEY_M then
        local shift = (mods % 2) == 1;
        local ctrl  = (math.floor(mods / 2) % 2) == 1;
        if ctrl then UnitMovement.cancelMove();
        elseif shift then UnitMovement.previewToCursor();
        else UnitMovement.moveToCursor(); end
        return true;
    end
    return false;
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
    if Events.LocalPlayerTurnBegin ~= nil then
        Events.LocalPlayerTurnBegin.Add(UnitMovement.onLocalTurnBegin);
        Log.info("UnitMovement.Initialize: subscribed to Events.LocalPlayerTurnBegin");
    end
end
Initialize();
