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
    -- Civ VI uses GroupId "Victories" (plural). Earlier pattern "^Victory"
    -- failed to match "Victories" because position 7 differs (Y vs I),
    -- causing every victory param to leak into the global L1 list instead
    -- of the Victory Conditions submenu.
    return parameter.GroupId == "Victories"
end

-- Resolve a parameter Name/Description that might be a raw LOC key into
-- displayable text. Civ VI's parameter framework leaves these as keys
-- (LOC_PLAYER_TEAM, LOC_LEADER_TYPE etc.) for the UI to look up at render
-- time; passing them straight to the screen reader makes the user hear
-- the literal "loc player team" pronounced.
--
-- Failure detection: Civ VI's Locale.Lookup of an unknown key returns
-- the key itself (sometimes unchanged, sometimes case-folded). Match on
-- case-insensitive equality OR the returned string having a "LOC_" prefix.
-- On lookup failure, sanitize the key into human-readable text by
-- stripping the LOC_ prefix and converting underscores to spaces.
local function sanitizeKey(key)
    if key == nil or key == "" then return "" end
    local clean = key
    clean = clean:gsub("^LOC_", ""):gsub("^Loc_", ""):gsub("^loc_", "")
    clean = clean:gsub("_", " ")
    clean = clean:lower()
    return clean
end

local function resolveLocText(value)
    if value == nil or value == "" then return "" end
    if Locale == nil or Locale.Lookup == nil then return value end
    local ok, resolved = pcall(Locale.Lookup, value)
    if not ok or resolved == nil or resolved == "" then
        return sanitizeKey(value)
    end
    -- Lookup-failed signals: result equals input (case-insensitive), OR
    -- result still has the LOC_ prefix.
    if string.upper(resolved) == string.upper(value)
        or string.find(resolved, "^[Ll][Oo][Cc]_") then
        return sanitizeKey(value)
    end
    return resolved
end

-- gameParameters defaults to g_GameParameters but per-slot parameters
-- live in their own SetupParameters object (GetPlayerParameters(playerID)),
-- so playerSlotItems passes that instead. The commit path
-- (SetParameterValue) goes through whichever object is passed.
local function parameterItem(parameter, gameParameters)
    gameParameters = gameParameters or g_GameParameters

    -- isNavigable closure that checks the parameter's visibility flags
    -- dynamically. Civ VI flips parameter.Visible on ruleset / mode
    -- changes (e.g. Gathering Storm climate params hidden under Standard
    -- ruleset). Static items can't be filtered out after-the-fact unless
    -- we return false from isNavigable here.
    local function paramVisible()
        if parameter.Hidden == true then return false end
        if parameter.Visible == false then return false end
        return true
    end

    local labelFn = function() return resolveLocText(parameter.Name) end
    local tooltipFn = function() return resolveLocText(parameter.Description) end

    local item

    -- Array parameters (CityStates, LeaderPool1/2, NaturalWonders) are
    -- modal pickers. Three engine modals back these:
    --   CityStates  -> LuaEvents.CityStatePicker_Initialize     (not yet)
    --   LeaderPool* -> LuaEvents.LeaderPicker_Initialize        (not yet)
    --   everything else -> LuaEvents.MultiSelectWindow_Initialize (Natural
    --                  Wonders, accessible via MultiSelectWindowAccess)
    -- Route the activation to the engine event + show the modal;
    -- accessible nav is handled by whichever companion picks up the
    -- show. Params without a shipped companion still announce the stub
    -- so the user knows the modal won't be navigable.
    -- Picker buttons have no current-value display (the engine shows
    -- a count or "..." visually), so a blind user at L1 has no audible
    -- cue that Enter opens a modal. AdvancedSetup doesn't set
    -- alwaysVerbose on itself, so chatty's describe path doesn't fire
    -- at L1 — instead, fold an action-specific hint into the label
    -- dynamically when Verbosity is on.
    --
    -- Each known picker gets a custom phrasing that states what the
    -- user is about to do; unknown / future pickers fall back to a
    -- generic ", press Enter to open" suffix so they're at least
    -- announced as actionable. To add a new picker hint, append to
    -- PICKER_HINTS keyed by ParameterId; same pattern extends to any
    -- future in-game pickers that show up as Array params.
    --
    -- In chatty mode the action hint REPLACES the engine label
    -- (otherwise the engine label and the action sentence say
    -- overlapping things — "Select City-States. Press Enter to pick
    -- city states..."). Terse mode keeps the engine label intact.
    local PICKER_HINTS = {
        CityStates     = "Press Enter to pick city-states that will be available in the game",
        LeaderPool1    = "Press Enter to select Leader Pool 1 members",
        LeaderPool2    = "Press Enter to select Leader Pool 2 members",
        NaturalWonders = "Press Enter to pick natural wonders that will be available in the game",
    }
    if parameter.Array then
        local pickerLabelFn = function()
            local base = resolveLocText(parameter.Name)
            if Verbosity ~= nil and Verbosity.isOn() then
                local hint = PICKER_HINTS[parameter.ParameterId]
                if hint ~= nil then return hint end
                return base .. ", press Enter to open"
            end
            return base
        end
        item = BaseMenuItems.Button({
            parameter = parameter,
            labelFn = pickerLabelFn,
            tooltipFn = tooltipFn,
            activate = function()
                local pid = parameter.ParameterId
                if pid == "CityStates" then
                    if Controls and Controls.CityStatePicker ~= nil then
                        LuaEvents.CityStatePicker_Initialize(parameter, gameParameters)
                        Controls.CityStatePicker:SetHide(false)
                    else
                        Speech.emit(
                            Locale.Lookup("LOC_CIVVIACCESS_PICKER_NOT_ACCESSIBLE",
                                resolveLocText(parameter.Name)), "meta")
                    end
                elseif pid == "LeaderPool1" or pid == "LeaderPool2" then
                    if Controls and Controls.LeaderPicker ~= nil then
                        LuaEvents.LeaderPicker_Initialize(parameter, gameParameters)
                        Controls.LeaderPicker:SetHide(false)
                    else
                        Speech.emit(
                            Locale.Lookup("LOC_CIVVIACCESS_PICKER_NOT_ACCESSIBLE",
                                resolveLocText(parameter.Name)), "meta")
                    end
                else
                    -- MultiSelectWindow path (Natural Wonders et al.).
                    if Controls and Controls.MultiSelectWindow ~= nil then
                        LuaEvents.MultiSelectWindow_Initialize(parameter)
                        Controls.MultiSelectWindow:SetHide(false)
                    else
                        Speech.emit(
                            Locale.Lookup("LOC_CIVVIACCESS_PICKER_NOT_ACCESSIBLE",
                                resolveLocText(parameter.Name)), "meta")
                    end
                end
            end,
        })
    elseif parameter.Domain == "bool" or isGameModeParameter(parameter) then
        item = BaseMenuItems.ParameterCheckbox({
            parameter = parameter,
            gameParameters = gameParameters,
            labelFn = labelFn,
            tooltipFn = tooltipFn,
        })
    elseif parameter.Domain == "int" or parameter.Domain == "uint"
        or parameter.Domain == "text" then
        -- Free-form numeric / text entry (random seeds). The engine
        -- renders these as a text input; we expose them as a
        -- NumberInput that drops into edit mode on Enter.
        item = BaseMenuItems.NumberInput({
            parameter = parameter,
            gameParameters = gameParameters,
            labelFn = labelFn,
            tooltipFn = tooltipFn,
        })
    elseif parameter.Values ~= nil and parameter.Values.Type == "IntRange" then
        -- Bounded integer slider (CityStateCount, Disaster Intensity).
        -- Left / Right step ±1 within MinimumValue..MaximumValue; Enter
        -- drops into edit mode for exact jumps.
        item = BaseMenuItems.Slider({
            parameter = parameter,
            gameParameters = gameParameters,
            labelFn = labelFn,
            tooltipFn = tooltipFn,
        })
    else
        -- Default: pulldown over parameter.Values. Empty Values means a
        -- no-op pulldown (sub-menu has nothing to show); we still emit
        -- the item so the user hears the label rather than the parameter
        -- disappearing.
        item = BaseMenuItems.Pulldown({
            parameter = parameter,
            gameParameters = gameParameters,
            labelFn = labelFn,
            tooltipFn = tooltipFn,
        })
    end

    -- Layer the parameter-visibility check on top of the factory's
    -- default isNavigable. Civ VI flips parameter.Visible on ruleset /
    -- mode changes; without the dynamic check, the item stays in the
    -- list and reads as "silent" or shows stale entries.
    local baseIsNavigable = item.isNavigable
    item.isNavigable = function(self)
        if not paramVisible() then return false end
        if type(baseIsNavigable) == "function" then
            return baseIsNavigable(self)
        end
        return true
    end
    return item
end

-- Player slot ---------------------------------------------------------------

local function slotLabel(playerID)
    return function()
        local config = PlayerConfigurations and PlayerConfigurations[playerID]
        if config == nil then
            return "Slot " .. tostring(playerID + 1)
        end
        local leaderTypeID = config.GetLeaderTypeID and config:GetLeaderTypeID() or -1
        local leaderName
        if leaderTypeID == -1 then
            -- LOC_RANDOM_LEADER_NAME isn't reliably resolved by Locale.Lookup
            -- in this context (returns the key literal). Use a fixed string.
            -- Engine displays this as "Random" in the pulldown text.
            leaderName = "Random"
        else
            local key = config:GetLeaderName()
            local resolved = Locale.Lookup(key)
            -- Locale.Lookup returns the key when the LOC isn't found.
            -- Fall back to a sanitized form of the key in that case.
            if resolved == key then
                resolved = key:gsub("^LOC_LEADER_", ""):gsub("_NAME$", ""):gsub("_", " "):lower()
            end
            leaderName = resolved
        end
        return "Slot " .. tostring(playerID + 1) .. ", " .. leaderName
    end
end

-- Per-slot parameters (PlayerLeader, PlayerDifficulty, PlayerColorAlternate
-- etc.) live in a SEPARATE collection from the global g_GameParameters.
-- PlayerSetupLogic.lua creates a SetupParameters object per player_id and
-- stores it in g_PlayerParameters; GetPlayerParameters(player_id) returns
-- it. The shape is identical to g_GameParameters — a .Parameters dict and
-- a :SetParameterValue method — so we can wrap each one with our standard
-- Pulldown / ParameterCheckbox.
local function playerSlotItems(playerID)
    return function()
        local items = {}
        if GetPlayerParameters == nil then return items end
        local playerParams = GetPlayerParameters(playerID)
        if playerParams == nil or playerParams.Parameters == nil then return items end
        -- Iterate the player's parameters dict. parameterItem chooses
        -- Pulldown / ParameterCheckbox / Button based on parameter shape;
        -- we pass playerParams as the gameParameters arg so commits go
        -- through the right SetupParameters object for this slot. The
        -- item's own isNavigable will re-check parameter.Visible /
        -- parameter.Hidden dynamically (Civ VI flips those on ruleset
        -- changes), so we include everything here and let the item
        -- decide whether it should appear.
        for _, parameter in pairs(playerParams.Parameters) do
            items[#items + 1] = parameterItem(parameter, playerParams)
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
        labelFn = function()
            -- AddAIButton is an image button with no visible text in the
            -- engine; fall back to a fixed string. (Localizing this would
            -- require a string the base game doesn't provide.)
            return "Add A I Player"
        end,
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
            else
                -- Include unconditionally; per-item isNavigable does the
                -- dynamic visibility check (Civ VI flips parameter.Visible
                -- on ruleset / mode changes, e.g. Gathering Storm climate
                -- params hidden under Standard ruleset).
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

    -- Action row. Query the actual control text via labelFn — Locale.Lookup
    -- on these LOC keys was returning the key literally (e.g.
    -- "LOC_SETUP_DEFAULT") because the strings aren't reliably loaded by
    -- the time items are built. The buttons themselves are populated by
    -- the engine before our items list runs, so reading their text is
    -- definitive.
    local function controlText(controlName, fallback)
        return function()
            local c = Controls and Controls[controlName]
            if c == nil then return fallback end
            local ok, text = pcall(function() return c:GetText() end)
            if not ok or text == nil or text == "" then return fallback end
            return text
        end
    end

    items[#items + 1] = BaseMenuItems.Button({
        controlName = "DefaultButton",
        labelFn = controlText("DefaultButton", "Defaults"),
        activate = function()
            if OnDefaultButton ~= nil then OnDefaultButton() end
        end,
    })
    items[#items + 1] = BaseMenuItems.Button({
        controlName = "CloseButton",
        labelFn = controlText("CloseButton", "Back"),
        activate = function()
            if OnBackButton ~= nil then OnBackButton() end
        end,
    })
    items[#items + 1] = BaseMenuItems.Button({
        controlName = "StartButton",
        labelFn = controlText("StartButton", "Start Game"),
        activate = function()
            if OnStartButton ~= nil then OnStartButton() end
        end,
    })

    return items
end

local _menuHandler = BaseMenu.install(ContextPtr, {
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

-- Chain UI_PostRefreshParameters so the BaseMenu's items cache invalidates
-- when Civ VI's parameter set changes mid-show. Without this, switching
-- ruleset (e.g. Gathering Storm -> Standard) leaves the prior expansion's
-- parameters in our cached items list — user hears Calendar / Temperature
-- / Precipitation params that the engine has flipped to Visible=false but
-- which are still wrapped in our items DSL with stale data.
local _priorPostRefresh = UI_PostRefreshParameters
function UI_PostRefreshParameters()
    if _priorPostRefresh ~= nil then
        local ok, err = pcall(_priorPostRefresh)
        if not ok then
            print("[AdvancedSetupAccess] priorPostRefresh failed: " .. tostring(err))
        end
    end
    if _menuHandler ~= nil then
        BaseMenu.invalidateItemsCache(_menuHandler)
    end
end
