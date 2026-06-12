-- UnitCombat.lua — accessible combat (P3). Lives in the HexCursorAddin VM next to
-- UnitMovement + the hex cursor.
--
-- No engine fork (Civ V Access forked CvUnitCombat.cpp; we don't have to). Civ VI
-- exposes everything we need in stock Lua:
--   * CombatManager.SimulateAttackVersus(attackerID, defenderID, CombatTypes.*)
--       -> the same m_combatResults table the base UnitPanel previews from
--       (per-side COMBAT_STRENGTH + DAMAGE_TO). This is the spoken odds.
--   * CombatManager.IsAttackChangeWarState(unitID, x, y) -> {defenderPlayerID,...}
--       (#>0 means the attack declares war; [1] = whom). The war warning.
--   * CombatManager.CanAttackTarget(attackerID, defenderID, CombatTypes.*) -> bool.
--   * Commit mirrors the engine's own RequestMoveOperation (Civ6Common.lua):
--       ranged  -> RequestOperation(RANGE_ATTACK, {x,y})
--       melee   -> RequestOperation(MOVE_TO, {x,y, MODIFIERS = ATTACK})
--       capture -> RequestOperation(MOVE_TO, {x,y})  (military unit onto a civilian)
--
-- TWO entry points feed ONE preview->confirm->commit engine:
--   * bare A (dedicated attack key) acts on the hex cursor target — works at range.
--   * move-into-enemy: UnitMovement.directMove / moveToCursor redirect their old
--     "combat coming" refusal here (melee only — you can only move into adjacency).
-- First press previews odds (+ war warning); a second press on the same
-- (unit, target) THIS TURN commits. The arm latch is entry-agnostic, so previewing
-- with A and confirming with M is fine.

UnitCombat = UnitCombat or {};

-- Set true to log raw combat-event args while we confirm signatures live; flip off
-- (and strip the per-event Log.info) before a public release.
local COMBAT_DEBUG = true;

-- ---------------------------------------------------------------------------
-- Small helpers (kept local rather than reaching into UnitMovement's locals).
-- ---------------------------------------------------------------------------

local function selectedUnit()
    if UI == nil or UI.GetHeadSelectedUnit == nil then return nil; end
    return UI.GetHeadSelectedUnit();
end

local function cursorPlot()
    if HexCursor ~= nil and HexCursor.position ~= nil then return HexCursor.position(); end
    return nil, nil;
end

local function unitName(unit)
    if unit == nil then return "enemy unit"; end
    local info = GameInfo.Units[unit:GetUnitType()];
    if info == nil or info.Name == nil then return "enemy unit"; end
    return Locale.Lookup(info.Name);
end

-- First different-owner unit visible on the plot (the defender for unit combat).
local function enemyUnitAt(plot, localPlayerID)
    if plot == nil then return nil; end
    local units = Units.GetUnitsInPlotLayerID(plot:GetX(), plot:GetY(), MapLayers.ANY);
    if units == nil then return nil; end
    for _, unit in ipairs(units) do
        if unit:GetOwner() ~= localPlayerID then return unit; end
    end
    return nil;
end

-- Enemy city occupying the plot (the city is the combat target, garrison aside).
-- Guarded: Cities.GetCityInPlot exists in Civ VI but we never want a combat path
-- to die on a missing API.
local function enemyCityAt(plot, localPlayerID)
    if plot == nil then return nil; end
    local isCity = false;
    pcall(function() isCity = plot.IsCity ~= nil and plot:IsCity(); end);
    if not isCity then return nil; end
    local city = nil;
    pcall(function()
        if Cities ~= nil and Cities.GetCityInPlot ~= nil then
            city = Cities.GetCityInPlot(plot:GetX(), plot:GetY());
        end
    end);
    if city ~= nil and city:GetOwner() ~= localPlayerID then return city; end
    return nil;
end

local function cityName(city)
    if city == nil then return "city"; end
    local ok, n = pcall(function() return Locale.Lookup(city:GetName()); end);
    if ok and n ~= nil and n ~= "" then return n; end
    return "city";
end

-- A defender with no offensive or defensive combat strength is a civilian: a
-- military unit moving onto it captures rather than fights (no odds to read).
local function unitIsCivilian(unit)
    if unit == nil then return false; end
    local civ = true;
    pcall(function()
        civ = (unit:GetCombat() <= 0) and (unit:GetRangedCombat() <= 0)
            and (unit:GetBombardCombat() <= 0);
    end);
    return civ;
end

-- ---------------------------------------------------------------------------
-- Classify the (unit, target) into a combat kind + defender, or a refusal reason.
-- Returns: kind ("RANGED" | "MELEE" | "CAPTURE"), defender, defenderName,
--          isCity, ok, reason.
-- ---------------------------------------------------------------------------
local function classifyAttack(pUnit, plot)
    local lp = pUnit:GetOwner();
    local tx, ty = plot:GetX(), plot:GetY();

    local city = enemyCityAt(plot, lp);
    local unit = enemyUnitAt(plot, lp);
    local defender = city or unit;
    if defender == nil then
        return nil, nil, nil, false, false, "No enemy at cursor.";
    end
    local isCity = (city ~= nil);
    local defName = isCity and cityName(city) or unitName(unit);

    -- Civilian capture (melee mover onto a defenceless unit): no odds, just confirm.
    if (not isCity) and unitIsCivilian(unit) then
        if Map.GetPlotDistance(pUnit:GetX(), pUnit:GetY(), tx, ty) > 1 then
            return "CAPTURE", defender, defName, false, false,
                "Move next to " .. defName .. " to capture it.";
        end
        return "CAPTURE", defender, defName, false, true, nil;
    end

    -- Ranged units (ranged/bombard stronger than melee) strike at range when the
    -- engine accepts a RANGE_ATTACK to this plot; otherwise it's a melee.
    local ranged = false;
    pcall(function()
        ranged = (pUnit:GetRangedCombat() > pUnit:GetCombat())
              or (pUnit:GetBombardCombat() > pUnit:GetCombat());
    end);
    local tParameters = { [UnitOperationTypes.PARAM_X] = tx, [UnitOperationTypes.PARAM_Y] = ty };
    local kind, combatType = "MELEE", CombatTypes.MELEE;
    if ranged then
        local canRange = false;
        pcall(function()
            canRange = UnitManager.CanStartOperation(pUnit, UnitOperationTypes.RANGE_ATTACK,
                                                     nil, tParameters);
        end);
        if canRange then kind, combatType = "RANGED", CombatTypes.RANGED; end
    end

    -- Validity gate (the same call UnitPanel uses to decide whether to show a target).
    local can = false;
    pcall(function()
        can = CombatManager.CanAttackTarget(pUnit:GetComponentID(),
                                            defender:GetComponentID(), combatType);
    end);
    if not can then
        if kind == "MELEE" and Map.GetPlotDistance(pUnit:GetX(), pUnit:GetY(), tx, ty) > 1 then
            return kind, defender, defName, isCity, false,
                "Not adjacent. Move next to " .. defName .. ", or use a ranged unit.";
        end
        if ranged and kind == "MELEE" then
            return kind, defender, defName, isCity, false,
                defName .. " is out of range.";
        end
        return kind, defender, defName, isCity, false,
            "Can't attack " .. defName .. " from here.";
    end
    return kind, defender, defName, isCity, true, nil;
end

-- Civ name to warn about if this attack declares war (else nil).
local function warDeclaredName(pUnit, plot)
    local results = nil;
    pcall(function()
        results = CombatManager.IsAttackChangeWarState(pUnit:GetComponentID(),
                                                       plot:GetX(), plot:GetY());
    end);
    if results == nil or #results == 0 then return nil; end
    local pid = results[1];
    if pid == nil or pid == -1 then return nil; end
    local name = nil;
    pcall(function()
        name = Locale.Lookup(PlayerConfigurations[pid]:GetCivilizationShortDescription());
    end);
    if name ~= nil and name ~= "" then return name; end
    return "another civilization";
end

-- One-word read on the exchange, from the simulated damage + the defender's HP.
local function verdictWord(lethal, captures, dToAtk, dToDef)
    if lethal then return captures and "captures it" or "destroys it"; end
    if dToAtk == 0 then return "no losses to you"; end
    if dToDef >= dToAtk * 2 then return "you come out well ahead"; end
    if dToDef > dToAtk then return "you come out ahead"; end
    if dToAtk > dToDef then return "they come out ahead"; end
    return "an even trade";
end

-- ---------------------------------------------------------------------------
-- Preview (first press) — speak the odds + war warning, arm the confirm latch.
-- ---------------------------------------------------------------------------
local function speakPreview(pUnit, plot, kind, defender, defName, isCity)
    -- Civilian capture has no combat math.
    if kind == "CAPTURE" then
        local msg = "Capture " .. defName .. ".";
        local war = warDeclaredName(pUnit, plot);
        if war ~= nil then msg = msg .. " Declares war on " .. war .. "."; end
        Speech.emit(msg .. " Press Control A again to confirm.", "status");
        return;
    end

    local combatType = (kind == "RANGED") and CombatTypes.RANGED or CombatTypes.MELEE;
    local results = nil;
    pcall(function()
        results = CombatManager.SimulateAttackVersus(pUnit:GetComponentID(),
                                                     defender:GetComponentID(), combatType);
    end);

    local msg;
    if results ~= nil then
        local atk = results[CombatResultParameters.ATTACKER];
        local def = results[CombatResultParameters.DEFENDER];
        local myStr   = atk and atk[CombatResultParameters.COMBAT_STRENGTH] or 0;
        local theirStr= def and def[CombatResultParameters.COMBAT_STRENGTH] or 0;
        local dToAtk  = atk and atk[CombatResultParameters.DAMAGE_TO] or 0;
        local dToDef  = def and def[CombatResultParameters.DAMAGE_TO] or 0;

        local lethal = false;
        pcall(function()
            local cur = defender:GetDamage() or 0;
            local maxHP = defender:GetMaxDamage() or 100;
            lethal = (cur + dToDef) >= maxHP;
        end);
        -- Ranged can't capture a city outright (city floors at 1 HP from ranged).
        local captures = isCity and (kind ~= "RANGED");
        if isCity and kind == "RANGED" then lethal = false; end

        local rangedWord = (kind == "RANGED") and "ranged " or "";
        msg = "Attack " .. defName .. ". " .. unitName(pUnit) .. " " .. rangedWord
            .. tostring(myStr) .. " versus " .. tostring(theirStr) .. ". You deal "
            .. tostring(dToDef) .. ", take " .. tostring(dToAtk) .. ". "
            .. verdictWord(lethal, captures, dToAtk, dToDef) .. ".";
    else
        msg = "Attack " .. defName .. ".";
    end

    local war = warDeclaredName(pUnit, plot);
    if war ~= nil then msg = msg .. " Declares war on " .. war .. "."; end
    Speech.emit(msg .. " Press Control A again to confirm.", "status");
end

-- ---------------------------------------------------------------------------
-- Commit (second press) — issue the engine operation. The async result events
-- below interrupt with the outcome ("Scout destroyed").
-- ---------------------------------------------------------------------------
local function commitAttack(pUnit, plot, kind, defName)
    local tx, ty = plot:GetX(), plot:GetY();
    local tParameters = { [UnitOperationTypes.PARAM_X] = tx, [UnitOperationTypes.PARAM_Y] = ty };

    if kind == "RANGED" then
        if UnitManager.CanStartOperation(pUnit, UnitOperationTypes.RANGE_ATTACK, nil, tParameters) then
            UnitManager.RequestOperation(pUnit, UnitOperationTypes.RANGE_ATTACK, tParameters);
            Speech.emit(unitName(pUnit) .. " strikes " .. defName .. ".", "event");
        else
            Speech.emit("Can't range strike there.", "meta");
        end
        return;
    end

    -- Melee = MOVE_TO with the ATTACK modifier (engine resolves move-into-enemy as
    -- the attack). Capture = a plain MOVE_TO onto the civilian.
    if kind == "MELEE" then
        tParameters[UnitOperationTypes.PARAM_MODIFIERS] = UnitOperationMoveModifiers.ATTACK;
    end
    if UnitManager.CanStartOperation(pUnit, UnitOperationTypes.MOVE_TO, nil, tParameters) then
        UnitManager.RequestOperation(pUnit, UnitOperationTypes.MOVE_TO, tParameters);
        local verb = (kind == "CAPTURE") and " captures " or " attacks ";
        Speech.emit(unitName(pUnit) .. verb .. defName .. ".", "event");
    else
        Speech.emit("Can't reach " .. defName .. " to attack.", "meta");
    end
end

-- ---------------------------------------------------------------------------
-- Arm latch + the shared request entry. Keyed by (unit, plot, turn) so a stale
-- preview from a previous turn never auto-commits.
-- ---------------------------------------------------------------------------
local _armed = nil;

local function currentTurn()
    local t = -1;
    pcall(function() t = Game.GetCurrentGameTurn() or -1; end);
    return t;
end

local function isArmedFor(pUnit, plot)
    return _armed ~= nil
       and _armed.uid == pUnit:GetID()
       and _armed.plotid == plot:GetIndex()
       and _armed.turn == currentTurn();
end

-- Shared by both entry points (A key + move-into-enemy redirect). Returns true so
-- the caller treats the key as consumed (we always either preview, commit, or
-- explain the refusal). pUnit must be the local player's selected unit.
function UnitCombat.requestAttackAt(pUnit, plot)
    if pUnit == nil or plot == nil then return false; end
    local kind, defender, defName, isCity, ok, reason = classifyAttack(pUnit, plot);
    if not ok then
        _armed = nil;
        Speech.emit(reason or "No target.", "meta");
        return true;
    end
    if isArmedFor(pUnit, plot) then
        _armed = nil;
        commitAttack(pUnit, plot, kind, defName);
    else
        _armed = { uid = pUnit:GetID(), plotid = plot:GetIndex(), turn = currentTurn() };
        speakPreview(pUnit, plot, kind, defender, defName, isCity);
    end
    return true;
end

-- A key: attack whatever the hex cursor sits on.
function UnitCombat.attackAtCursor()
    local pUnit = selectedUnit();
    if pUnit == nil then Speech.emit("No unit selected", "meta"); return; end
    local lp = Game.GetLocalPlayer();
    if lp == -1 then return; end
    if pUnit:GetOwner() ~= lp then Speech.emit("Not your unit", "meta"); return; end
    local cx, cy = cursorPlot();
    if cx == nil then Speech.emit("No cursor target", "meta"); return; end
    local plot = Map.GetPlot(cx, cy);
    if plot == nil then Speech.emit("No tile there", "meta"); return; end
    UnitCombat.requestAttackAt(pUnit, plot);
end

-- ---------------------------------------------------------------------------
-- Result / threat awareness (part 3). Civ VI fires native events (no fork). The
-- exact arg shapes aren't documented; we LOG them (COMBAT_DEBUG) to confirm
-- signatures from a live game, and make only conservative, strongly-guarded
-- announces so a wrong guess stays silent rather than speaking garbage.
-- ---------------------------------------------------------------------------

-- Lua 5.1 (Havok Script): no table.pack — pass the count explicitly.
local function argsStr(a, n)
    local parts = {};
    for i = 1, n do parts[i] = tostring(a[i]); end
    return "n=" .. tostring(n) .. " [" .. table.concat(parts, ", ") .. "]";
end

-- Best-effort: assumes (playerID, unitID, newDamage, prevDamage). Announces only
-- when the damaged unit is ours and the damage INCREASED (i.e. we were hit).
function UnitCombat.onUnitDamageChanged(...)
    local n = select("#", ...);
    local a = { ... };
    if COMBAT_DEBUG then Log.info("UnitCombat.onUnitDamageChanged " .. argsStr(a, n)); end
    local playerID, unitID, newDamage, prevDamage = a[1], a[2], a[3], a[4];
    local lp = Game.GetLocalPlayer();
    if playerID ~= lp then return; end
    if type(newDamage) ~= "number" then return; end
    if type(prevDamage) == "number" and newDamage <= prevDamage then return; end
    local pPlayer = Players[lp];
    if pPlayer == nil then return; end
    local pUnit = pPlayer:GetUnits():FindID(unitID);
    if pUnit == nil then return; end
    local maxHP = 100;
    pcall(function() maxHP = pUnit:GetMaxDamage() or 100; end);
    local hpLeft = maxHP - newDamage;
    if hpLeft < 0 then hpLeft = 0; end
    Speech.emit(unitName(pUnit) .. " under attack, " .. hpLeft .. " HP left.", "event");
end

-- Signature unconfirmed (base handler ignores its arg). Log only for now; the
-- spoken kill announce gets wired once the live log shows the real arg shape.
function UnitCombat.onUnitKilledInCombat(...)
    if COMBAT_DEBUG then
        Log.info("UnitCombat.onUnitKilledInCombat " .. argsStr({ ... }, select("#", ...)));
    end
end

-- ---------------------------------------------------------------------------
-- Dispatch (forwarded from the capture-all wrap): bare A = attack at cursor.
-- ---------------------------------------------------------------------------
local KEY_A = Keys and Keys.A;
function UnitCombat.dispatch(key, mods)
    mods = mods or 0;
    if KEY_A ~= nil and key == KEY_A then
        local ctrl = (math.floor(mods / 2) % 2) == 1;   -- bit1 = Ctrl
        if ctrl then UnitCombat.attackAtCursor(); return true; end
    end
    return false;
end

local function Initialize()
    Log.info("UnitCombat.lua: file loaded");
    if Events == nil then return; end
    if Events.UnitDamageChanged ~= nil then
        Events.UnitDamageChanged.Add(UnitCombat.onUnitDamageChanged);
        Log.info("UnitCombat.Initialize: subscribed to Events.UnitDamageChanged");
    end
    if Events.UnitKilledInCombat ~= nil then
        Events.UnitKilledInCombat.Add(UnitCombat.onUnitKilledInCombat);
        Log.info("UnitCombat.Initialize: subscribed to Events.UnitKilledInCombat");
    end
end
Initialize();
