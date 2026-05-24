-- TutorialReset.lua — debug-only script that resets tutorial state
-- flags on every game launch, so tutorial popups (FIRST_GREETING,
-- expansion intros, post-found-city advisor, etc.) actually fire
-- during testing instead of being silently skipped because the
-- profile already saw them in a previous session.
--
-- Background: Civ VI tracks tutorial state per-USER-PROFILE in
-- UserOptions.txt. Once HasChosenTutorialLevel = 1 (set when the
-- user picks an option in the first advisor popup), FIRST_GREETING
-- never re-fires. Same for HasSeenXP1/2FeaturesScreen. Without
-- this reset script, "start a new game from scratch" tests the
-- mod's flows ONCE and never again.
--
-- DISABLE_RESET below switches the script off so it ships
-- harmlessly. Default on while we're confirming tutorial popup
-- behavior; flip false after the tutorial flow is validated. The
-- file stays in place + registered for easy re-enable.
--
-- Registered under <AddGameplayScripts> in CivViAccessMod.modinfo.

include("Log");

Log.info("TutorialReset.lua: file loaded");

local DISABLE_RESET :boolean = false;

if DISABLE_RESET then
    Log.info("TutorialReset: DISABLE_RESET=true; no flags will be reset.");
    return;
end

local function reset(group, key)
    if Options == nil or Options.GetUserOption == nil
       or Options.SetUserOption == nil then
        return;
    end
    local before = Options.GetUserOption(group, key);
    if before ~= 0 then
        Options.SetUserOption(group, key, 0);
        Log.info("TutorialReset: " .. group .. "." .. key
                 .. " was " .. tostring(before) .. ", reset to 0");
    end
end

-- These are the flags that gate the tutorial-system popups we care
-- about testing. From UserOptions.txt under [Tutorial] section
-- (probed 2026-05-23 on Noel's machine).
reset("Tutorial", "HasChosenTutorialLevel");
reset("Tutorial", "HasSeenXP1FeaturesScreen");
reset("Tutorial", "HasSeenXP2FeaturesScreen");
reset("Tutorial", "HasSeenCivRoyaleIntro");
reset("Tutorial", "HasSeenPiratesIntro");

if Options ~= nil and Options.SaveOptions ~= nil then
    pcall(Options.SaveOptions);
end

-- Per-tutorial-item "seen" tracking (e.g. "you founded your first
-- city" popup) lives in UITutorialManager state, not in
-- UserOptions.txt. Try the SetTutorialCompleted API if it exists;
-- if it doesn't, those popups still won't re-fire but we'll know
-- from the log.
if UITutorialManager ~= nil and UITutorialManager.ClearAll ~= nil then
    pcall(function() UITutorialManager:ClearAll(); end);
    Log.info("TutorialReset: called UITutorialManager:ClearAll()");
elseif UITutorialManager ~= nil and UITutorialManager.ResetAll ~= nil then
    pcall(function() UITutorialManager:ResetAll(); end);
    Log.info("TutorialReset: called UITutorialManager:ResetAll()");
else
    Log.info("TutorialReset: no UITutorialManager reset API found; "
             .. "per-item tutorial seen state not reset (only the "
             .. "user-options flags above).");
end

Log.info("TutorialReset: complete.");
