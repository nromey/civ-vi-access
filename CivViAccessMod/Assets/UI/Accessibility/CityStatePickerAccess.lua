-- Accessibility companion for the engine's City-State picker modal
-- (Base\Assets\UI\FrontEnd\CityStatePicker.lua). Opened from
-- AdvancedSetup via `LuaEvents.CityStatePicker_Initialize(parameter,
-- g_GameParameters)` when the user activates the Select City-States
-- Array button at L1.
--
-- Compared to the generic MultiSelectWindow companion this one adds
-- per-state metadata: each city-state has a category (cultural /
-- scientific / militaristic / industrial / trade / religious /
-- military) and a Suzerain bonus string that depends on the active
-- ruleset (Standard / Rise and Fall / Gathering Storm uses Bonus /
-- Bonus_XP1 / Bonus_XP2 respectively). The category is appended to
-- the label so terse mode is still informative; the bonus is the
-- tooltip / describe payload that chatty mode and Ctrl+T speak.
--
-- v1 scope: the list of city-states + Select All / None / OK / Back.
-- DEFERRED: the in-modal CityStateCount slider (needs a Slider item
-- kind in BaseMenu, not yet built — adjust CityStateCount from the
-- parent AdvancedSetup screen for now) and the sort-by-name/type
-- toggle (default name sort is fine for v1).

include("ScreenReader")
include("Verbosity")
include("BaseMenu")
include("BaseMenuItems")

local XP1_RULESETUP = "RULESET_EXPANSION_1"
local XP2_RULESETUP = "RULESET_EXPANSION_2"

local _parameter = nil
local _pGameParameters = nil
local _selected = {}
local _invertSelection = false
local _menuHandler = nil
local _cityStateDataCache = {}
local _rulesetType = nil
local _originalCityStateCount = nil

-- DB.ConfigurationQuery against the CityStates table, cached per
-- civType. Returns the data row's columns (CityStateCategory, Bonus,
-- Bonus_XP1, Bonus_XP2). Mirrors the engine's GetCityStateData
-- (CityStatePicker.lua:116) so our lookups match its bonus text exactly.
local function getCityStateData(civType)
    if _cityStateDataCache[civType] == nil then
        _cityStateDataCache[civType] = {}
        local query = "SELECT CityStateCategory, Bonus, Bonus_XP1, Bonus_XP2 from CityStates where CivilizationType = ?"
        local results = DB.ConfigurationQuery(query, civType)
        if results then
            for _, row in ipairs(results) do
                for k, v in pairs(row) do
                    _cityStateDataCache[civType][k] = v
                end
            end
        end
    end
    return _cityStateDataCache[civType]
end

-- Suzerain bonus text in the active ruleset. Mirrors the engine's
-- ruleset-gated selection in OnItemFocus (CityStatePicker.lua:96-104).
local function bonusText(civType)
    local data = getCityStateData(civType)
    if data == nil then return "" end
    local key
    if data.Bonus_XP2 ~= nil and _rulesetType == XP2_RULESETUP then
        key = data.Bonus_XP2
    elseif data.Bonus_XP1 ~= nil and
        (_rulesetType == XP1_RULESETUP or _rulesetType == XP2_RULESETUP) then
        key = data.Bonus_XP1
    else
        key = data.Bonus
    end
    if key == nil or key == "" then return "" end
    return Locale.Lookup(key)
end

-- Human-readable category name. The DB column holds tokens like
-- CULTURAL / SCIENTIFIC / MILITARISTIC. Try a LOC-key form first, fall
-- back to a lowercased token if no LOC matches.
local function categoryText(civType)
    local data = getCityStateData(civType)
    if data == nil or data.CityStateCategory == nil then return "" end
    local locKey = "LOC_CITY_STATE_CATEGORY_" .. data.CityStateCategory .. "_NAME"
    local resolved = Locale.Lookup(locKey)
    if resolved == nil or resolved == "" or resolved == locKey then
        return data.CityStateCategory:lower()
    end
    return resolved
end

local function captureSelection(parameter, pGameParameters)
    _parameter = parameter
    _pGameParameters = pGameParameters
    _invertSelection = parameter.UxHint == "InvertSelection"
    _selected = {}
    if parameter.Value ~= nil then
        for _, v in ipairs(parameter.Value) do
            _selected[v.Value] = true
        end
    end

    -- Ruleset drives which bonus column we read at announce time.
    if pGameParameters and pGameParameters.Parameters then
        local rulesetParam = pGameParameters.Parameters["Ruleset"]
        if rulesetParam and rulesetParam.Value and rulesetParam.Value.Value then
            _rulesetType = rulesetParam.Value.Value
        end
        local countParam = pGameParameters.Parameters["CityStateCount"]
        if countParam then
            _originalCityStateCount = countParam.Value
        end
    end

    if _menuHandler ~= nil then
        BaseMenu.invalidateItemsCache(_menuHandler)
    end
end

local function isItemChecked(itemValue)
    local stored = _selected[itemValue] == true
    if _invertSelection then return not stored end
    return stored
end

local function setItemChecked(itemValue, newOn)
    local stored = newOn
    if _invertSelection then stored = not newOn end
    _selected[itemValue] = stored
end

local function setAll(displayState)
    if _parameter == nil then return end
    local stored = displayState
    if _invertSelection then stored = not displayState end
    for _, v in ipairs(_parameter.Values) do
        _selected[v.Value] = stored
    end
    if _menuHandler ~= nil then
        BaseMenu.invalidateItemsCache(_menuHandler)
    end
end

local function commitAndClose()
    if _parameter ~= nil then
        local values = {}
        for k, v in pairs(_selected) do
            if v then table.insert(values, k) end
        end
        LuaEvents.CityStatePicker_SetParameterValues(_parameter.ParameterId, values)
    end
    ContextPtr:SetHide(true)
end

-- Mirror engine OnBackButton (CityStatePicker.lua:52): cancel without
-- commit, but ALSO restore the CityStateCount slider value the user
-- may have nudged inside the modal. We don't expose the slider in v1,
-- but the restore path is harmless and future-proofs the Back button
-- once we wire the slider.
local function cancelAndClose()
    if _pGameParameters and _originalCityStateCount ~= nil
        and _pGameParameters.Parameters then
        local countParam = _pGameParameters.Parameters["CityStateCount"]
        if countParam then
            LuaEvents.CityStatePicker_SetParameterValue(
                countParam.ParameterId, _originalCityStateCount)
        end
    end
    ContextPtr:SetHide(true)
end

local function buildItems()
    local items = {}
    if _parameter == nil then return items end
    for _, v in ipairs(_parameter.Values) do
        local entry = v
        items[#items + 1] = BaseMenuItems.VirtualCheckbox({
            -- Label: name + category. Terse still gets the differentiator
            -- ("Geneva, scientific" vs "Geneva") so a fast scan tells you
            -- the type even with verbosity off.
            labelFn = function()
                local name = Locale.Lookup(entry.Name or "")
                local cat = categoryText(entry.Value)
                if cat ~= "" then
                    return name .. ", " .. cat
                end
                return name
            end,
            -- Tooltip / chatty payload: the Suzerain bonus text in the
            -- active ruleset. Reading on arrow in chatty mode is the
            -- entire point — picking city-states without hearing each
            -- one's bonus is just naming them blind.
            tooltipFn = function() return bonusText(entry.Value) end,
            getValue = function() return isItemChecked(entry.Value) end,
            setValue = function(newOn) setItemChecked(entry.Value, newOn) end,
        })
    end
    items[#items + 1] = BaseMenuItems.Button({
        labelText = Locale.Lookup("LOC_SELECT_ALL"),
        activate = function() setAll(true) end,
    })
    items[#items + 1] = BaseMenuItems.Button({
        labelText = Locale.Lookup("LOC_SELECT_NONE"),
        activate = function() setAll(false) end,
    })
    items[#items + 1] = BaseMenuItems.Button({
        labelText = Locale.Lookup("LOC_OK_BUTTON"),
        activate = commitAndClose,
    })
    items[#items + 1] = BaseMenuItems.Button({
        labelText = Locale.Lookup("LOC_MULTIPLAYER_BACK"),
        activate = cancelAndClose,
    })
    return items
end

LuaEvents.CityStatePicker_Initialize.Add(captureSelection)

_menuHandler = BaseMenu.install(ContextPtr, {
    name = "CityStatePicker",
    displayName = function()
        if _parameter == nil then return "Select City-States" end
        return Locale.Lookup(_parameter.Name or "") or "Select City-States"
    end,
    preamble = function()
        if _parameter == nil then return "" end
        return Locale.Lookup(_parameter.Description or "")
    end,
    items = buildItems,
    alwaysVerbose = true,
})
