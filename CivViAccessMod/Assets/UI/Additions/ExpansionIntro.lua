-- Copyright 2017-2018 (c) Firaxis Games
--
-- Civ VI Access shadow — wraps BOTH the R&F and GS engine
-- ExpansionIntro.lua files. They share the relative path
-- UI/Additions/ExpansionIntro.lua after Civ VI strips DLC prefixes
-- during file matching, so a single shadow overrides both contexts.
-- Per-ruleset config is selected at OnLoadGameViewStateDone via
-- GameConfiguration.GetRuleSet(); both context instances of this
-- file race for the show, so a global sentinel
-- _G.CivViAccess_ExpansionIntroShownThisGame prevents the second
-- instance from queueing a duplicate popup.
--
-- See docs/flow-trace/05-expansion-intro-popup.md and
-- Accessibility/ExpansionIntroAccess.lua.

include("ExpansionIntroAccess");

-- ===========================================================================
--	CONSTANTS
-- ===========================================================================
local RULESET_EXPANSION_1 :string = "RULESET_EXPANSION_1";
local RULESET_EXPANSION_2 :string = "RULESET_EXPANSION_2";

-- Per-ruleset config tables. The engine's two files each hardcode their
-- own; we hold both and pick at show time. Keys correspond to fields
-- the engine code uses + ExpansionIntroAccess.Install consumes.
local CONFIG_BY_RULESET :table = {

    [RULESET_EXPANSION_1] = {
        ruleset         = RULESET_EXPANSION_1,
        optionsSeenKey  = "HasSeenXP1FeaturesScreen",
        optionsHideKey  = "HideXP1FeaturesScreen",
        minTutorialLevel = (TutorialLevel ~= nil and TutorialLevel.LEVEL_NEW_TO_XP1) or 0,
        illustrations = {
            "XP1Intro_Diagram_1",
            "XP1Intro_Diagram_2",
            "XP1Intro_Diagram_3",
            "XP1Intro_Diagram_4",
            "XP1Intro_Diagram_5",
            "XP1Intro_Diagram_6",
            "XP1Intro_Diagram_7",
            "XP1Intro_Diagram_8",
            "XP1Intro_Diagram_9",
        },
        descriptions = {
            "LOC_TUTORIAL_XP1_INTRO_WELCOME",
            "LOC_TUTORIAL_XP1_INTRO_ERAS",
            "LOC_TUTORIAL_XP1_INTRO_AGES",
            "LOC_TUTORIAL_XP1_INTRO_LOYALTY",
            "LOC_TUTORIAL_XP1_INTRO_GOVERNORS",
            "LOC_TUTORIAL_XP1_INTRO_ALLIANCES",
            "LOC_TUTORIAL_XP1_INTRO_EMERGENCIES",
            "LOC_TUTORIAL_XP1_INTRO_CITYBANNER",
            "LOC_TUTORIAL_XP1_INTRO_END",
        },
        details = {
            "",
            "",
            "",
            "",
            "",
            "",
            "",
            "",
            "LOC_TUTORIAL_XP1_INTRO_END_DETAILS_1",
        },
        welcomeKey = "LOC_CIVVIACCESS_EXPANSION_INTRO_WELCOME_RF",
    },

    [RULESET_EXPANSION_2] = {
        ruleset         = RULESET_EXPANSION_2,
        optionsSeenKey  = "HasSeenXP2FeaturesScreen",
        optionsHideKey  = "HideXP2FeaturesScreen",
        minTutorialLevel = (TutorialLevel ~= nil and TutorialLevel.LEVEL_NEW_TO_XP2) or 0,
        illustrations = {
            "XP2Intro_Diagram_1",
            "XP2Intro_Diagram_2",
            "XP2Intro_Diagram_3",
            "XP2Intro_Diagram_11",
            "XP2Intro_Diagram_12",
            "XP2Intro_Diagram_4",
            "XP2Intro_Diagram_5",
            "XP2Intro_Diagram_6",
            "XP2Intro_Diagram_7",
            "XP2Intro_Diagram_8",
            "XP2Intro_Diagram_9",
            "XP2Intro_Diagram_10",
        },
        descriptions = {
            "LOC_TUTORIAL_XP2_INTRO_WELCOME",
            "LOC_TUTORIAL_XP2_INTRO_WORLD_CONGRESS",
            "LOC_TUTORIAL_XP2_INTRO_FAVOR",
            "LOC_TUTORIAL_XP2_INTRO_DIPLO_VICTORY",
            "LOC_TUTORIAL_XP2_INTRO_GRIEVANCES",
            "LOC_TUTORIAL_XP2_INTRO_ENVIRONMENT",
            "LOC_TUTORIAL_XP2_INTRO_VOLCANOES",
            "LOC_TUTORIAL_XP2_INTRO_GEOTHERMAL",
            "LOC_TUTORIAL_XP2_INTRO_STRATEGIC_RESOURCES",
            "LOC_TUTORIAL_XP2_INTRO_RESOURCES",
            "LOC_TUTORIAL_XP2_INTRO_MORE",
            "LOC_TUTORIAL_XP2_INTRO_END",
        },
        details = {
            "",
            "LOC_TUTORIAL_XP2_INTRO_WORLD_CONGRESS_DETAILS",
            "LOC_TUTORIAL_XP2_INTRO_FAVOR_DETAILS",
            "LOC_TUTORIAL_XP2_INTRO_DIPLO_VICTORY_DETAILS",
            "LOC_TUTORIAL_XP2_INTRO_GRIEVANCES_DETAILS",
            "LOC_TUTORIAL_XP2_INTRO_ENVIRONMENT_DETAILS",
            "",
            "",
            "LOC_TUTORIAL_XP2_INTRO_STRATEGIC_RESOURCES_DETAILS",
            "LOC_TUTORIAL_XP2_INTRO_RESOURCES_DETAILS",
            "",
            "LOC_TUTORIAL_XP2_INTRO_END_DETAILS_1",
        },
        welcomeKey = "LOC_CIVVIACCESS_EXPANSION_INTRO_WELCOME_GS",
    },
};

-- Active config (selected at show time based on current ruleset).
local m_ActiveConfig :table = nil;

local NEXT_BUTTON_TEXT     = Locale.Lookup("LOC_XP1_INTRO_NEXT");
local CONTINUE_BUTTON_TEXT = Locale.Lookup("LOC_XP1_INTRO_CONTINUE");

-- ===========================================================================
--	MEMBERS
-- ===========================================================================
m_PageIndex = 1;	-- global so ExpansionIntroAccess can read post-Realize


-- ===========================================================================
function Realize()
    if m_ActiveConfig == nil then return; end
    local n = #m_ActiveConfig.illustrations;
    Controls.Illustration:SetTexture(m_ActiveConfig.illustrations[m_PageIndex]);
    Controls.Description:SetText(Locale.Lookup(m_ActiveConfig.descriptions[m_PageIndex]));

    -- Show detail screens or hide box if we don't have any for this page
    if m_ActiveConfig.details[m_PageIndex] ~= "" then
        Controls.FrameDeco:SetHide(false);
        Controls.Description2:SetText(Locale.Lookup(m_ActiveConfig.details[m_PageIndex]));
    else
        Controls.FrameDeco:SetHide(true);
    end

    Controls.Next:SetText(m_PageIndex == n and CONTINUE_BUTTON_TEXT or NEXT_BUTTON_TEXT);
    Controls.Previous:SetHide(m_PageIndex == 1);
    Controls.ButtonStack:CalculateSize();
end

-- ===========================================================================
function OnShow()
    if m_ActiveConfig == nil then return; end
    m_PageIndex = 1;
    Realize();
    UIManager:QueuePopup(ContextPtr, PopupPriority.TutorialHigh);
    -- Civ VI Access hand-off: announce welcome + page 1 + nav hint.
    if ExpansionIntroAccess ~= nil and ExpansionIntroAccess.NotifyShow ~= nil then
        ExpansionIntroAccess.NotifyShow();
    end
end

-- ===========================================================================
function OnShowFromMenu()
    -- Triggered from the in-game pause menu. Pick config from current
    -- ruleset since the LoadGameViewStateDone gate doesn't run here.
    local ruleset = GameConfiguration.GetRuleSet();
    local cfg = CONFIG_BY_RULESET[ruleset];
    if cfg == nil then return; end
    m_ActiveConfig = cfg;
    if ExpansionIntroAccess ~= nil and ExpansionIntroAccess.Install ~= nil then
        ExpansionIntroAccess.Install(cfg);
    end
    m_PageIndex = 1;
    Realize();
    UIManager:QueuePopup(ContextPtr, PopupPriority.Current);
    if ExpansionIntroAccess ~= nil and ExpansionIntroAccess.NotifyShow ~= nil then
        ExpansionIntroAccess.NotifyShow();
    end
end

-- ===========================================================================
function OnClose()
    UIManager:DequeuePopup(ContextPtr);
    if ExpansionIntroAccess ~= nil and ExpansionIntroAccess.NotifyClose ~= nil then
        ExpansionIntroAccess.NotifyClose();
    end
end

-- ===========================================================================
function OnNext()
    if m_ActiveConfig == nil then return; end
    local n = #m_ActiveConfig.illustrations;
    if m_PageIndex >= n then
        OnClose();
    else
        m_PageIndex = math.min(m_PageIndex + 1, n);
        Realize();
        if ExpansionIntroAccess ~= nil and ExpansionIntroAccess.NotifyPageChange ~= nil then
            ExpansionIntroAccess.NotifyPageChange(m_PageIndex);
        end
    end
end

-- ===========================================================================
function OnPrevious()
    m_PageIndex = math.max(1, m_PageIndex - 1);
    Realize();
    if ExpansionIntroAccess ~= nil and ExpansionIntroAccess.NotifyPageChange ~= nil then
        ExpansionIntroAccess.NotifyPageChange(m_PageIndex);
    end
end

-- ===========================================================================
function OnLoadGameViewStateDone()
    -- Sentinel: when both DLCs are enabled, both context instances of
    -- this file subscribe to LoadGameViewStateDone. First one to pass
    -- the gate flips the global so the second instance bails.
    if _G.CivViAccess_ExpansionIntroShownThisGame then return; end

    local ruleset = GameConfiguration.GetRuleSet();
    local cfg = CONFIG_BY_RULESET[ruleset];
    if cfg == nil then
        -- Vanilla ruleset (or some other non-expansion variant). No
        -- popup to show; skip silently. The engine's per-DLC checks
        -- would also fail in this case.
        return;
    end

    local isAutoPlayMode :boolean = (Game.GetLocalPlayer() == -1);
    local hasSeenScreen  :boolean = Options.GetUserOption("Tutorial", cfg.optionsSeenKey) == 1;
    local hideScreen     :boolean = Options.GetUserOption("Tutorial", cfg.optionsHideKey) == 1;
    local showScreen     :boolean = not GameConfiguration.IsNetworkMultiplayer()
                            and not isAutoPlayMode
                            and (not hasSeenScreen or UserConfiguration.TutorialLevel() <= cfg.minTutorialLevel)
                            and not hideScreen;

    if showScreen and Game.GetCurrentGameTurn() == GameConfiguration.GetStartTurn() then
        _G.CivViAccess_ExpansionIntroShownThisGame = true;
        Options.SetUserOption("Tutorial", cfg.optionsSeenKey, 1);
        Options.SaveOptions();
        m_ActiveConfig = cfg;
        if ExpansionIntroAccess ~= nil and ExpansionIntroAccess.Install ~= nil then
            ExpansionIntroAccess.Install(cfg);
        end
        OnShow();
    end
end

-- ===========================================================================
function OnInput( pInputStruct:table )
    -- Civ VI Access first: arrow nav, Enter, T toggle, Ctrl+I, Ctrl+T.
    -- Returns true if it consumed the input.
    if ExpansionIntroAccess ~= nil and ExpansionIntroAccess.HandleKey ~= nil then
        if ExpansionIntroAccess.HandleKey(pInputStruct) then
            return true;
        end
    end

    local key = pInputStruct:GetKey();
    local type = pInputStruct:GetMessageType();
    if type == KeyEvents.KeyUp and key == Keys.VK_ESCAPE then
        HideIfVisible();
    end
    return true; -- consume all input
end

-- ===========================================================================
function HideIfVisible()
    if ContextPtr:IsVisible() then
        OnClose();
    end
end


-- ===========================================================================
function Initialize()
    ContextPtr:SetInputHandler( OnInput, true );

    Controls.Close:RegisterCallback(Mouse.eLClick, OnClose);
    Controls.Next:RegisterCallback(Mouse.eLClick, OnNext);
    Controls.Previous:RegisterCallback(Mouse.eLClick, OnPrevious);

    Controls.Close:RegisterCallback(Mouse.eMouseEnter, function()
        UI.PlaySound("Main_Menu_Mouse_Over"); end);
    Controls.Next:RegisterCallback(Mouse.eMouseEnter, function()
        UI.PlaySound("Main_Menu_Mouse_Over"); end);
    Controls.Previous:RegisterCallback(Mouse.eMouseEnter, function()
        UI.PlaySound("Main_Menu_Mouse_Over"); end);

    -- Initialize DontShowAgain from whichever ruleset this context will
    -- end up rendering. Both expansions' hide keys exist independently;
    -- prefer XP2's if both DLCs are enabled, falling back to XP1.
    -- Worst case: the box reads the WRONG ruleset's hide state until
    -- OnLoadGameViewStateDone fires and the user toggles it.
    local initialHide = false;
    if Options ~= nil and Options.GetUserOption ~= nil then
        local hideXP2 = Options.GetUserOption("Tutorial", "HideXP2FeaturesScreen") == 1;
        local hideXP1 = Options.GetUserOption("Tutorial", "HideXP1FeaturesScreen") == 1;
        initialHide = hideXP2 or hideXP1;
    end
    Controls.DontShowAgain:SetCheck(initialHide);
    Controls.DontShowAgain:RegisterCheckHandler(function(bCheck)
        local value = bCheck and 1 or 0;
        -- Write to whichever ruleset is active. If none active yet
        -- (popup hasn't been shown), write to both as a defensive
        -- catch-all; the user clearly wants to suppress this category.
        if m_ActiveConfig ~= nil then
            Options.SetUserOption("Tutorial", m_ActiveConfig.optionsHideKey, value);
        else
            Options.SetUserOption("Tutorial", "HideXP1FeaturesScreen", value);
            Options.SetUserOption("Tutorial", "HideXP2FeaturesScreen", value);
        end
        Options.SaveOptions();
    end);

    Events.LoadGameViewStateDone.Add( OnLoadGameViewStateDone );

    LuaEvents.InGameTopOptionsMenu_ShowExpansionIntro.Add( OnShowFromMenu );
    LuaEvents.DiplomacyActionView_HideIngameUI.Add( HideIfVisible );
end
Initialize();
