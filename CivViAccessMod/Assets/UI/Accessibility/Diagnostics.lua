-- Diagnostic event firehose. Subscribes to a broad set of engine Events
-- and LuaEvents that fire around game-start / mid-game so the Lua.log
-- captures the actual sequence of engine signals. Once we see WHICH
-- events fire, we'll know which to hook for game-creation status speech,
-- advisor popups, leader announce, etc.
--
-- This file ships only during the 0.4.0 diagnostic pass. Remove after
-- we identify the in-game failures.

include("Log");

Log.info("Diagnostics.lua: file loaded");

local function logEvent(name)
    return function(...)
        local args = { ... };
        local argstr = "";
        for i, v in ipairs(args) do
            if i > 1 then argstr = argstr .. ", "; end
            argstr = argstr .. tostring(v);
        end
        Log.info("EVENT " .. name .. "(" .. argstr .. ")");
    end;
end

-- Subscribe with a defensive try/catch so a missing event name (Civ VI
-- patch-dependent) doesn't blow up the whole file.
local function tryAdd(source, eventName)
    if source == nil then return; end
    local ev = source[eventName];
    if ev == nil or ev.Add == nil then return; end
    local ok, err = pcall(function() ev.Add(logEvent(eventName)); end);
    if not ok then
        Log.warn("Diagnostics: failed to subscribe to " .. eventName .. ": " .. tostring(err));
    end
end

-- Engine events (fired by C++ side) — most relevant for game lifecycle.
if Events ~= nil then
    Log.info("Diagnostics: Events available, subscribing");
    tryAdd(Events, "LoadScreenClose");
    tryAdd(Events, "LoadScreenContentReady");
    tryAdd(Events, "LoadGameViewStateDone");
    tryAdd(Events, "GameConfigChanged");
    tryAdd(Events, "PlayerInfoChanged");
    tryAdd(Events, "LocalPlayerTurnBegin");
    tryAdd(Events, "LocalPlayerTurnEnd");
    tryAdd(Events, "PlayerTurnActivated");
    tryAdd(Events, "PlayerTurnDeactivated");
    tryAdd(Events, "TurnBegin");
    tryAdd(Events, "TurnEnd");
    tryAdd(Events, "UserRequestClose");
    tryAdd(Events, "UserConfirmedClose");
    tryAdd(Events, "InputActionTriggered");
    tryAdd(Events, "SystemUpdateUI");
    tryAdd(Events, "InterfaceModeChanged");
    tryAdd(Events, "UnitSelectionChanged");
    tryAdd(Events, "CitySelectionChanged");
    tryAdd(Events, "NotificationAdded");
    tryAdd(Events, "PlayerEraChanged");
    tryAdd(Events, "BeginWonderReveal");
    tryAdd(Events, "EndWonderReveal");
    tryAdd(Events, "ShowLeaderScreen");
    tryAdd(Events, "HideLeaderScreen");
else
    Log.warn("Diagnostics: Events table not available");
end

-- LuaEvents (fired by Lua side, cross-Context pub/sub).
if LuaEvents ~= nil then
    Log.info("Diagnostics: LuaEvents available, subscribing");
    tryAdd(LuaEvents, "InGame_OpenInGameOptionsMenu");
    tryAdd(LuaEvents, "InGameTopOptionsMenu_Show");
    tryAdd(LuaEvents, "InGameTopOptionsMenu_Close");
    tryAdd(LuaEvents, "AdvisorPopup_ShowAdvisorPopup");
    tryAdd(LuaEvents, "AdvisorPopup_ClearActiveAdvisor");
    tryAdd(LuaEvents, "Tutorial_TutorialEnd");
    tryAdd(LuaEvents, "Tutorial_PlayerInfoEarned");
    tryAdd(LuaEvents, "NotificationPanel_ShowNotificationContent");
    tryAdd(LuaEvents, "PlayerChange_Show");
    tryAdd(LuaEvents, "PlayerChange_Close");
else
    Log.warn("Diagnostics: LuaEvents table not available");
end

Log.info("Diagnostics: subscriptions complete");
