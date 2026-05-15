-- Tutorial accessibility companion.
--
-- Civ VI's tutorial (Base/Assets/UI/TutorialUIRoot.lua) is event-driven —
-- each step emits LuaEvents when it shows / hides popups, adds / completes
-- goals, and points at hexes. The data carried by those events is already
-- structured and already localized through TXT keys, so accessibility is
-- a matter of subscribing and routing through OutputMessageToScreenReader.
--
-- Hooked events (all fired from TutorialUIRoot.lua):
--   * TutorialUIRoot_AdvisorRaise(advisorInfo) — popup appears
--   * TutorialUIRoot_AdvisorLower(advisorInfo) — popup dismisses (no announce
--                                                today; reconsider if testing
--                                                shows users want a cue)
--   * TutorialUIRoot_GoalAdd(goal)              — goal added to panel
--   * TutorialUIRoot_GoalMarkComplete(id, turn) — goal completed
--   * TutorialUIRoot_ShowWorldPointer(plot, direction, offset, head, body)
--                                                visual arrow points to a hex
--
-- Goal completion fires only the goalId, not the goal struct. We mirror
-- the GoalAdd payload in m_goalTextById so completion announces can name
-- which goal finished without forcing the user to remember it by id.
--
-- Loads via the InGameActions ImportFiles registration in
-- ScreenReaderAccess.modinfo. Frontend context never reaches this file —
-- the tutorial is only active during an in-game session.

include("ScreenReader");

TutorialAccess = {};

local m_goalTextById :table = {};

-- Defensively resolves a possibly-TXT-key string. Civ VI's TutorialItem
-- payload stores raw TXT keys ("LOC_TUTORIAL_FOO_BODY"); Locale.Lookup
-- returns the localized text. If Lookup returns the key unchanged the
-- caller passed something already resolved (or a literal that isn't a
-- key) — use the value as-is so we don't end up speaking the raw key
-- name to the user.
local function resolveText(s)
    if s == nil or s == "" then
        return "";
    end
    local str = tostring(s);
    if Locale ~= nil and Locale.Lookup ~= nil then
        local ok, v = pcall(Locale.Lookup, str);
        if ok and type(v) == "string" and v ~= "" and v ~= str then
            return v;
        end
    end
    return str;
end

-- Compose a single announceable line from an AdvisorItem popup.
-- Pattern parallels FrontEndPopup's announcement: prefix + body, then a
-- buttons enumeration if any buttons exist. The CalloutBody is appended
-- when it carries information distinct from the main message (some
-- tutorial steps use only CalloutBody, some use only Message, some both).
local function buildAdvisorAnnouncement(advisorInfo)
    if advisorInfo == nil then
        return "";
    end
    local parts = {};
    parts[#parts + 1] = Locale.Lookup("LOC_CIVVIACCESS_TUTORIAL_POPUP_PREFIX");

    local msg = resolveText(advisorInfo.Message);
    if msg ~= "" then
        parts[#parts + 1] = msg;
    end

    local calloutBody = resolveText(advisorInfo.CalloutBody);
    if calloutBody ~= "" and calloutBody ~= msg then
        parts[#parts + 1] = calloutBody;
    end

    local buttons = {};
    local b1 = resolveText(advisorInfo.Button1Text);
    local b2 = resolveText(advisorInfo.Button2Text);
    if b1 ~= "" then buttons[#buttons + 1] = b1; end
    if b2 ~= "" then buttons[#buttons + 1] = b2; end
    if #buttons > 0 then
        parts[#parts + 1] = Locale.Lookup("LOC_CIVVIACCESS_TUTORIAL_BUTTONS", table.concat(buttons, ", "));
    end

    return table.concat(parts, " ");
end

function TutorialAccess.OnAdvisorRaise(advisorInfo)
    local line = buildAdvisorAnnouncement(advisorInfo);
    if line ~= "" then
        OutputMessageToScreenReader(line);
    end
end

function TutorialAccess.OnAdvisorLower(advisorInfo)
    -- Deliberately no-op for now. Popup dismissal is implicit when the
    -- user activates a button; saying "tutorial popup dismissed" on every
    -- close would be noise. Reconsider if real-world testing shows users
    -- want explicit dismissal confirmation.
end

function TutorialAccess.OnGoalAdd(goal)
    if goal == nil or goal.Id == nil then
        return;
    end
    local text = resolveText(goal.Text);
    if text == "" then
        return;
    end
    m_goalTextById[goal.Id] = text;
    OutputMessageToScreenReader(Locale.Lookup("LOC_CIVVIACCESS_TUTORIAL_GOAL_ADDED", text));
end

function TutorialAccess.OnGoalMarkComplete(goalId, turn)
    if goalId == nil then
        return;
    end
    -- Fall back to the raw id if we never saw the GoalAdd (shouldn't happen
    -- in normal flow but is defensive — engine reload, mid-session join,
    -- or a tutorial item that completes a goal it didn't add itself).
    local text = m_goalTextById[goalId] or tostring(goalId);
    OutputMessageToScreenReader(Locale.Lookup("LOC_CIVVIACCESS_TUTORIAL_GOAL_COMPLETE", text));
end

function TutorialAccess.OnShowWorldPointer(plotID, direction, offset, head, body)
    local parts = {};
    local headText = resolveText(head);
    local bodyText = resolveText(body);
    if headText ~= "" then
        parts[#parts + 1] = headText;
    end
    if bodyText ~= "" and bodyText ~= headText then
        parts[#parts + 1] = bodyText;
    end

    if plotID ~= nil and plotID >= 0 and Map ~= nil and Map.GetPlotByIndex ~= nil then
        local ok, plot = pcall(Map.GetPlotByIndex, plotID);
        if ok and plot ~= nil then
            local coordOk, x, y = pcall(function() return plot:GetX(), plot:GetY(); end);
            if coordOk and x ~= nil and y ~= nil then
                parts[#parts + 1] = Locale.Lookup("LOC_CIVVIACCESS_TUTORIAL_POINTING_AT", x, y);
            end
        end
    end

    if #parts > 0 then
        -- Queued speech: world-pointer announcement usually follows the
        -- advisor popup on the same step, and we don't want to clobber
        -- the popup's spoken body mid-sentence.
        OutputMessageToScreenReader(table.concat(parts, ". "), true);
    end
end

local function Initialize()
    print("Initializing tutorial accessibility hooks");
    LuaEvents.TutorialUIRoot_AdvisorRaise.Add(TutorialAccess.OnAdvisorRaise);
    LuaEvents.TutorialUIRoot_AdvisorLower.Add(TutorialAccess.OnAdvisorLower);
    LuaEvents.TutorialUIRoot_GoalAdd.Add(TutorialAccess.OnGoalAdd);
    LuaEvents.TutorialUIRoot_GoalMarkComplete.Add(TutorialAccess.OnGoalMarkComplete);
    LuaEvents.TutorialUIRoot_ShowWorldPointer.Add(TutorialAccess.OnShowWorldPointer);
end

Initialize();
