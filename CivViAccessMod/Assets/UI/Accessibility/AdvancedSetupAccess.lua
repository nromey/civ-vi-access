-- AdvancedSetup accessibility companion.
--
-- Wires keyboard navigation + spoken focus tracking onto Civ VI's
-- AdvancedSetup screen via BaseMenu. The base screen is parameter-driven
-- (g_GameParameters.Parameters is a dict of Parameter objects built
-- asynchronously from the GameConfiguration), so our item tree is a
-- function that re-reads the parameter list on every show — a ruleset or
-- mode toggle can reshape the set between shows.
--
-- Top-level shape:
--   * All non-player, non-GameMode, non-Victory parameters, in the order
--     g_GameParameters emits them. Each is a Pulldown (or a
--     ParameterCheckbox for bool / GameModes-domain ones).
--   * Players group: one sub-group per participating player ID, plus an
--     Add AI button at the end.
--   * Game Modes group: every parameter with GroupId == "GameModes",
--     flat checkbox list.
--   * Victory Conditions group: every parameter with GroupId starting
--     with "Victory", flat checkbox list (mirrors Game Modes shape).
--   * Action row: Defaults, Close (= back), Start.
--
-- Player slots: each slot is a sub-group whose children are that player's
-- own parameters (PlayerLeader<id>, PlayerHandicap<id>, etc.) plus a
-- Remove button when removal is legal (>min players, non-local slot).

include("ScreenReader")
include("BaseMenu")
include("BaseMenuItems")

-- Civ VI's AdvancedSetup uses named globals for its handlers (OnShow, OnHide,
-- OnInputHandler) and registers them via SetShowHandler / SetHideHandler /
-- SetInputHandler in Initialize(). We capture them here so BaseMenu.install
-- can chain them — this file is included at the bottom of the AdvancedSetup
-- fork, after Initialize() has run and globals are defined.
local _priorShow = OnShow
local _priorHide = OnHide
local _priorInput = OnInputHandler

-- Parameter classification --------------------------------------------------
--
-- "bool" / GameModes-domain params become ParameterCheckboxes; everything
-- else with a Values list becomes a Pulldown. Array (multi-select) params
-- are rendered as a Button that triggers the engine's existing modal
-- picker (the picker itself is not yet accessible — known gap).

local function isPlayerParameter(parameterId)
    -- Player-specific parameters use the engine's "Player<id>_..." or
    -- "<X><id>" convention; we lift those out of the L1 list and surface
    -- them inside the per-slot sub-group instead.
    if type(parameterId) ~= "string" then return false end
    return string.find(parameterId, "^Player") ~= nil
end

local function isGameModeParameter(parameter)
    return parameter.GroupId == "GameModes"
end

local function isVictoryParameter(parameter)
    if parameter.GroupId == nil then return false end
    return string.find(parameter.GroupId, "^Victory") ~= nil
end

local function parameterItem(parameter)
    -- Array parameters (CityStates, LeaderPool1/2) are modal pickers. We
    -- expose them as a Button that re-fires the same activate path the
    -- engine wires; the picker itself remains the engine's modal until
    -- we ship its own companion.
    if parameter.Array then
        return BaseMenuItems.Button({
            parameter = parameter,   -- suppress the no-controlName warning
            labelText = parameter.Name,
            tooltipText = parameter.Description,
            activate = function()
                -- For LeaderPool / CityStates, the engine's CreatePicker
                -- driver hooks into LuaEvents.<Picker>_Initialize. We don't
                -- have direct access to the driver's button, so we don't
                -- yet wire a real open here. Once the picker companion
                -- ships this will be replaced.
                OutputMessageToScreenReader(
                    Locale.Lookup("LOC_CIVVIACCESS_PICKER_NOT_ACCESSIBLE", parameter.Name))
            end,
        })
    end

    if parameter.Domain == "bool" or isGameModeParameter(parameter) then
        return BaseMenuItems.ParameterCheckbox({
            parameter = parameter,
            gameParameters = g_GameParameters,
            labelText = parameter.Name,
            tooltipText = parameter.Description,
        })
    end

    -- Default: pulldown over parameter.Values. Empty Values means a no-op
    -- pulldown (sub-menu has nothing to show); we still emit the item so
    -- the user hears the label rather than the parameter disappearing.
    return BaseMenuItems.Pulldown({
        parameter = parameter,
        gameParameters = g_GameParameters,
        labelText = parameter.Name,
        tooltipText = parameter.Description,
    })
end

-- Player slot ---------------------------------------------------------------

local function slotLabel(playerID)
    return function()
        local config = PlayerConfigurations and PlayerConfigurations[playerID]
        if config == nil then
            return Locale.Lookup("LOC_CIVVIACCESS_AI_SLOT_GENERIC", playerID + 1)
        end
        local leaderTypeID = config.GetLeaderTypeID and config:GetLeaderTypeID() or -1
        local leaderName
        if leaderTypeID == -1 then
            leaderName = Locale.Lookup("LOC_RANDOM_LEADER_NAME")
        else
            leaderName = Locale.Lookup(config:GetLeaderName())
        end
        return Locale.Lookup("LOC_CIVVIACCESS_AI_SLOT", playerID + 1, leaderName)
    end
end

-- Find parameters that belong to a specific player slot. The Civ VI
-- parameter framework names these "Player<X>" with X varying by parameter
-- (PlayerLeader, PlayerLeader2, PlayerHandicap, etc.). We match against
-- parameter.PlayerId since that's the canonical link the framework sets.
local function playerSlotItems(playerID)
    return function()
        local items = {}
        if g_GameParameters == nil or g_GameParameters.Parameters == nil then
            return items
        end
        -- Iterate Parameters dict and pull out anything bound to this slot.
        for _, parameter in pairs(g_GameParameters.Parameters) do
            if parameter.PlayerId == playerID then
                items[#items + 1] = parameterItem(parameter)
            end
        end
        -- Remove button when legal: the engine sets RemoveButton:SetHide
        -- based on min-player constraints; our wrapper reads that hide
        -- state via the matched ui_instance. We can't easily reach the
        -- per-slot instance from here without parallel iteration, so
        -- defer the Remove control until we have a stable hook — clicking
        -- a non-existent button is a worse failure mode than a missing
        -- option.
        return items
    end
end

local function playersChildren()
    local items = {}
    if GameConfiguration == nil or GameConfiguration.GetParticipatingPlayerIDs == nil then
        return items
    end
    local participatingIDs = GameConfiguration.GetParticipatingPlayerIDs() or {}
    for _, playerID in ipairs(participatingIDs) do
        items[#items + 1] = BaseMenuItems.Group({
            labelFn = slotLabel(playerID),
            itemsFn = playerSlotItems(playerID),
            cached = false,
        })
    end
    items[#items + 1] = BaseMenuItems.Button({
        controlName = "AddAIButton",
        labelText = Locale.Lookup("LOC_SETUP_ADD_AI_PLAYER"),
        activate = function()
            if OnAddAIButton ~= nil then
                OnAddAIButton()
            end
        end,
    })
    return items
end

-- Top-level item builder ----------------------------------------------------

local function topLevelItems()
    local items = {}

    if g_GameParameters == nil or g_GameParameters.Parameters == nil then
        -- Parameters not built yet; degrade to action row only. The next
        -- show after GameSetup_RefreshParameters completes will rebuild
        -- with full content (items spec is a function).
    else
        local globalParams = {}
        local gameModeParams = {}
        local victoryParams = {}
        for parameterId, parameter in pairs(g_GameParameters.Parameters) do
            if isPlayerParameter(parameterId) or parameter.PlayerId ~= nil then
                -- handled in Players group
            elseif isGameModeParameter(parameter) then
                gameModeParams[#gameModeParams + 1] = parameter
            elseif isVictoryParameter(parameter) then
                victoryParams[#victoryParams + 1] = parameter
            elseif parameter.Hidden ~= true then
                globalParams[#globalParams + 1] = parameter
            end
        end

        -- Stable order: by parameter.SortIndex if present, else by Name.
        local function sortKey(p)
            return (p.SortIndex or 0) * 1000000 + 0
        end
        table.sort(globalParams, function(a, b)
            if a.SortIndex ~= b.SortIndex then
                return (a.SortIndex or 0) < (b.SortIndex or 0)
            end
            return Locale.Compare(a.Name or "", b.Name or "") == -1
        end)
        table.sort(gameModeParams, function(a, b)
            return Locale.Compare(a.Name or "", b.Name or "") == -1
        end)
        table.sort(victoryParams, function(a, b)
            return Locale.Compare(a.Name or "", b.Name or "") == -1
        end)

        for _, parameter in ipairs(globalParams) do
            items[#items + 1] = parameterItem(parameter)
        end

        -- Players group always shown.
        items[#items + 1] = BaseMenuItems.Group({
            labelText = Locale.Lookup("LOC_CIVVIACCESS_GROUP_PLAYERS"),
            itemsFn = playersChildren,
            cached = false,
        })

        if #gameModeParams > 0 then
            local modeItems = {}
            for _, parameter in ipairs(gameModeParams) do
                modeItems[#modeItems + 1] = parameterItem(parameter)
            end
            items[#items + 1] = BaseMenuItems.Group({
                labelText = Locale.Lookup("LOC_CIVVIACCESS_GROUP_GAME_MODES"),
                items = modeItems,
            })
        end

        if #victoryParams > 0 then
            local vItems = {}
            for _, parameter in ipairs(victoryParams) do
                vItems[#vItems + 1] = parameterItem(parameter)
            end
            items[#items + 1] = BaseMenuItems.Group({
                labelText = Locale.Lookup("LOC_CIVVIACCESS_GROUP_VICTORY_CONDITIONS"),
                items = vItems,
            })
        end
    end

    -- Action row.
    items[#items + 1] = BaseMenuItems.Button({
        controlName = "DefaultButton",
        labelText = Locale.Lookup("LOC_SETUP_DEFAULT"),
        activate = function()
            if OnDefaultButton ~= nil then OnDefaultButton() end
        end,
    })
    items[#items + 1] = BaseMenuItems.Button({
        controlName = "CloseButton",
        labelText = Locale.Lookup("LOC_BACK_BUTTON"),
        activate = function()
            if OnBackButton ~= nil then OnBackButton() end
        end,
    })
    items[#items + 1] = BaseMenuItems.Button({
        controlName = "StartButton",
        labelText = Locale.Lookup("LOC_START_GAME"),
        activate = function()
            if OnStartButton ~= nil then OnStartButton() end
        end,
    })

    return items
end

BaseMenu.install(ContextPtr, {
    name = "AdvancedSetup",
    displayName = Locale.Lookup("LOC_CIVVIACCESS_SCREEN_ADVANCED_SETUP"),
    items = topLevelItems,
    preamble = function()
        -- Speak a status hint when participating-player count is at min/max
        -- or when a parameter conflict blocks Start. Keeps the user oriented
        -- before they arrow into the player list.
        if g_GameParameters == nil then return nil end
        local err = nil
        if GetGameParametersError ~= nil then
            err = GetGameParametersError()
        end
        if err ~= nil then
            return Locale.Lookup("LOC_CIVVIACCESS_SETUP_PARAMETER_ERROR")
        end
        return nil
    end,
    priorShow = _priorShow,
    priorHide = _priorHide,
    priorInput = _priorInput,
    onShow = function(handler)
        -- After a player-count change the participating-IDs list may have
        -- shifted under our cursor. handler._initialized was cleared on
        -- hide, so onActivate (which fires after onShow) will reset the
        -- cursor to the first navigable item and re-announce. No state to
        -- repair here.
    end,
})
