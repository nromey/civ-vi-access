-- Suppresses Civ VI's first-turn Advisor Choice popup ("New to Civilization
-- / New to Civilization 6") that blocks all input on a new game's first turn.
--
-- The popup uses Civ VI's AdvisorPopup system. Its raise condition (per
-- Base/Assets/UI/TutorialScenarioBase.lua lines 75-85):
--
--   if ((tutorialLevel == 0 or 1) and hasChosenTutorialLevel == 0) then
--       return true;  -- show popup
--   else
--       return false; -- don't show
--   end
--
-- The popup's two buttons are mouse-only — no Enter, no Esc, no keyboard
-- navigation. A blind player loading a new game cannot dismiss it, cannot
-- reach the world layer, cannot play.
--
-- This file sets HasChosenTutorialLevel = 1 BEFORE LoadScreenClose fires,
-- so the raise check returns false and the popup never appears. We pick
-- LEVEL_CIV_FAMILIAR (most experienced, fewest tutorial advisors) as the
-- default — it minimizes future modal popups the user can't navigate
-- through. Per [[feedback-runtime-toggle-over-install-choice]] we don't
-- ask the user at install time; we make a sensible default and document.
--
-- Once HexCursor + the broader tutorial accessibility work ships, this
-- file can be replaced by a proper accessible Advisor popup that announces
-- the choice and lets the user pick via keyboard. For now: bypass.
--
-- Only runs if the user hasn't already chosen via Civ VI's Options screen.
-- Idempotent — safe to run on every game start; only acts on first run.

include("Log");

Log.info("SuppressFirstTurnAdvisor.lua: file loaded");

local function suppressIfNeeded()
    if Options == nil or Options.GetUserOption == nil then
        Log.warn("SuppressFirstTurnAdvisor: Options API not available; skipping");
        return;
    end
    local already = Options.GetUserOption("Tutorial", "HasChosenTutorialLevel");
    Log.info("SuppressFirstTurnAdvisor: HasChosenTutorialLevel = " .. tostring(already));
    if already ~= nil and already ~= 0 then
        Log.info("SuppressFirstTurnAdvisor: user has already chosen; nothing to do");
        return;
    end

    -- Set tutorial level to LEVEL_CIV_FAMILIAR (3) — experienced-player
    -- default, fewest tutorial advisors. Engine constant lookup via the
    -- TutorialLevel global if it's in scope; numeric fallback otherwise.
    local level = (TutorialLevel ~= nil and TutorialLevel.LEVEL_CIV_FAMILIAR) or 3;
    if UserConfiguration ~= nil and UserConfiguration.TutorialLevel ~= nil then
        UserConfiguration.TutorialLevel(level);
        if UserConfiguration.CommitToOptions ~= nil then
            UserConfiguration.CommitToOptions();
        end
    end
    Options.SetUserOption("Tutorial", "HasChosenTutorialLevel", 1);
    if Options.SaveOptions ~= nil and OptionFileTypes ~= nil then
        Options.SaveOptions(OptionFileTypes.User);
    end
    Log.info("SuppressFirstTurnAdvisor: set TutorialLevel=" .. tostring(level)
            .. " and HasChosenTutorialLevel=1 to suppress the inaccessible "
            .. "first-turn advisor popup");
end

suppressIfNeeded();
