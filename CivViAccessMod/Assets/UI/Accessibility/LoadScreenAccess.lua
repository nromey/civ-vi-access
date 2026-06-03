-- Loading-screen accessibility companion (Dawn of Man briefing).
--
-- Owns the screen-reader briefing + keyboard input dispatch for the
-- post-AdvancedSetup loading screen — the "Sean Bean civ intro" with
-- the large leader portrait, civ name, era, leader info paragraph,
-- and unique abilities/units/buildings. The Firaxis fork at
-- Assets/UI/FrontEnd/LoadScreen.lua shadows the engine version and
-- hands off here.
--
-- Why this exists:
-- The engine LoadScreen plays Sean Bean's voice-over (or per-locale
-- equivalent) but never announces any of the on-screen text — civ,
-- leader, era, abilities are all silent for screen-reader users.
-- Worse, the engine's input handler isn't installed until
-- OnLoadGameViewStateDone (post-load), which means Esc doesn't work
-- during the speech — the player is locked listening for 30-60s.
--
-- This file fixes both: speaks a full briefing from the same data
-- the visual UI uses, suppresses Sean Bean by default (user opts
-- back in via Enter), and installs our input handler EARLY so skip
-- always works. See docs/flow-trace/04-loading-screen.md.
--
-- Key bindings (active from briefing-ready through game start):
--   Enter / Space     skip to game (engine auto-stops Sean Bean on
--                     LoadScreen close via STOP_SPEECH_DAWNOFMAN)
--   Escape            skip to game (same as Enter)
--   Ctrl+T or bare T  re-speak the abilities list
--   Ctrl+I or bare I  speak full leader portrait description
--                     (placeholder until describer batch lands)
--   Ctrl+S or bare S  speak Dawn of Man transcript stand-in — the
--                     LOC_LOADING_INFO_<LEADER> paragraph, i.e. the
--                     text Sean Bean is reciting. Round-8 design:
--                     Sean Bean speaks his lore paragraph normally,
--                     and S re-reads it for users who missed any of
--                     his narration.
--
-- Sean Bean plays normally (engine default). Briefing covers the
-- on-screen text Sean Bean does NOT cover (civ, era, leader name,
-- unique abilities). They run in parallel through different audio
-- channels — Tolk + engine voice — without content overlap.
--
-- Note: hotkeys ONLY work AFTER Civ VI changes from InputContext.
-- Loading to InputContext.Ready, which happens inside
-- OnLoadGameViewStateDone (typically several seconds after the
-- briefing starts). During the loading-screen-with-briefing window,
-- the engine does not deliver keypresses to our handler. This is an
-- engine constraint, not a bug we can patch from the mod side.

include("ScreenReader");
include("Log");

LoadScreenAccess = {};

-- ===========================================================================
--  Constants
-- ===========================================================================
local KEY_UP_MSG   :number = (KeyEvents ~= nil and KeyEvents.KeyUp)   or 257;
local KEY_DOWN_MSG :number = (KeyEvents ~= nil and KeyEvents.KeyDown) or 256;

local function vk(name, fallback)
    if Keys ~= nil and Keys[name] ~= nil then
        return Keys[name];
    end
    return fallback;
end

local VK_RETURN  :number = vk("VK_RETURN", 0x0D);
local VK_ESCAPE  :number = vk("VK_ESCAPE", 0x1B);
local VK_SPACE   :number = vk("VK_SPACE",  0x20);
local VK_CONTROL :number = vk("VK_CONTROL",0x11);
local VK_I       :number = vk("VK_I",      0x49);
local VK_R       :number = vk("VK_R",      0x52);
local VK_S       :number = vk("VK_S",      0x53);
local VK_T       :number = vk("VK_T",      0x54);

-- Earcon placeholder. Custom .wav playback is still unsolved on the
-- Civ VI side ([[project_elevenlabs_earcons]] open question). Engine
-- sound events work, so we use a reasonable existing event as the
-- "clip" cue until custom audio lands. Swap to UI.PlaySound("clip")
-- (or whatever the registration ends up named) when the audio bank
-- registration ships.
local CLIP_EARCON_PLACEHOLDER :string = "UI_Page_Forward";

-- ===========================================================================
--  State
-- ===========================================================================
local m_ready              :boolean = false;  -- briefing data is built
local m_ctrlDown           :boolean = false;
local m_loadComplete       :boolean = false;
local m_seanBeanStarted    :boolean = false;  -- user pressed Enter to fire Dawn of Man

-- Default-on Sean Bean toggle (round 8 design per Noel: "default sean
-- bean on, but sean comes in after telling user to press enter ...
-- that's how the true game is played"). When true, Tolk briefing
-- skips the leader paragraph (Sean recites it), briefing ends with
-- "Press Enter for Dawn of Man speech" prompt, user presses Enter to
-- fire Sean. When false (future toggleable setting), Tolk briefing
-- includes the leader paragraph and there's no Sean prompt.
local PLAY_SEAN_BEAN :boolean = true;
local m_briefing       :table = {
    lines           = {},    -- ordered speech lines
    clipboardText   = "",    -- markdown for clipboard
    leaderInfoKey   = nil,   -- LOC_LOADING_INFO_<LEADER> for Ctrl+S
    abilitiesText   = "",    -- joined abilities for Ctrl+T re-read
    leaderType      = nil,   -- for future Ctrl+I lookup
};

-- ===========================================================================
--  Speech helpers
-- ===========================================================================
local function safeLookup(key)
    if key == nil or key == "" then return ""; end
    local ok, value = pcall(Locale.Lookup, key);
    if not ok or value == nil then return ""; end
    return stripIconTags(value);
end

-- Local wrapper. All load-screen speech is detail-tier (user-asked
-- portrait / abilities / transcript readouts, post-Sean prompts) —
-- map to status. The legacy nointerrupt arg is ignored; status is
-- always queue-friendly (shield 0, no coalesce; gateway emits as
-- interrupt when nothing's shielding, NOINTERRUPT otherwise).
local function speak(text, nointerrupt)
    if text == nil or text == "" then return; end
    Speech.emit(text, "status");
end

local function playClipEarcon()
    if UI ~= nil and UI.PlaySound ~= nil then
        pcall(UI.PlaySound, CLIP_EARCON_PLACEHOLDER);
    end
end

local function copyToClipboard(text)
    if text == nil or text == "" then return; end
    if UI ~= nil and UI.SetClipboardString ~= nil then
        pcall(UI.SetClipboardString, text);
        playClipEarcon();
    end
end

-- ===========================================================================
--  Briefing assembly
-- ===========================================================================
-- Pull abilities/units/buildings via the engine helpers (Civ6Common.lua).
-- The shadow already includes Civ6Common so these globals exist when
-- this function runs.
local function collectUniques(leaderType, civType)
    local out = { abilities = {}, units = {}, buildings = {} };
    if GetLeaderUniqueTraits == nil or GetCivilizationUniqueTraits == nil then
        return out;
    end
    local ok, lAbilities, lUnits, lBuildings = pcall(GetLeaderUniqueTraits, leaderType);
    if ok then
        out.abilities = lAbilities or {};
        out.units     = lUnits or {};
        out.buildings = lBuildings or {};
    end
    local ok2, cAbilities, cUnits, cBuildings = pcall(GetCivilizationUniqueTraits, civType);
    if ok2 then
        for _, v in ipairs(cAbilities or {}) do table.insert(out.abilities, v); end
        for _, v in ipairs(cUnits     or {}) do table.insert(out.units, v); end
        for _, v in ipairs(cBuildings or {}) do table.insert(out.buildings, v); end
    end
    return out;
end

local function describeUniqueItem(item)
    if item == nil then return nil; end
    local header = "";
    if item.Name ~= nil and item.Name ~= "NONE" then
        header = safeLookup(item.Name);
    end
    local desc = "";
    if item.Description ~= nil and item.Description ~= "NONE" then
        desc = safeLookup(item.Description);
    end
    if header == "" and desc == "" then return nil; end
    if header == "" then return desc; end
    if desc == "" then return header; end
    return header .. ". " .. desc;
end

-- Build the speech list + clipboard markdown. Returns nothing; populates
-- m_briefing. Called from NotifyContentReady with the data the engine
-- already resolved.
local function buildBriefing(ctx)
    local lines = {};
    local md = {};  -- markdown for clipboard

    local civName    = ctx.civDisplay   or "";
    local leaderName = ctx.leaderDisplay or "";
    local eraName    = ctx.eraName       or "";
    local leaderInfo = ctx.leaderInfoText or "";
    local challengeName = ctx.challengeName;
    local challengeInfo = ctx.challengeInfo;

    -- 1. Header
    if civName ~= "" then
        local headerSpeech = Locale.Lookup(
            "LOC_CIVVIACCESS_LOAD_BRIEFING_HEADER", civName);
        table.insert(lines, headerSpeech);
        table.insert(md, "# " .. civName);
    end

    -- 2. Era
    if eraName ~= "" then
        local eraSpeech = Locale.Lookup(
            "LOC_CIVVIACCESS_LOAD_ERA_FORMAT", eraName);
        table.insert(lines, eraSpeech);
        table.insert(md, "## " .. eraSpeech);
    end

    -- 3. Leader name + portrait brief from LeaderDescriptions.xml.
    --    Civ VI doesn't expose Locale.HasTextKey reliably; instead,
    --    Locale.Lookup returns the key unchanged when the key is
    --    missing. So we look it up and check for an exact-match
    --    fallback to "" (missing) before deciding what to speak.
    if leaderName ~= "" then
        local portraitBriefKey =
            "LOC_CIVVIACCESS_LDR_" .. (ctx.leaderType or "") .. "_SHORT";
        local portraitBrief = safeLookup(portraitBriefKey);
        Log.info("LoadScreenAccess portrait lookup: leaderType='"
                 .. tostring(ctx.leaderType) .. "' key='"
                 .. portraitBriefKey .. "' result='"
                 .. tostring(portraitBrief):sub(1, 80) .. "'");
        if portraitBrief == portraitBriefKey then
            portraitBrief = "";  -- key not found; Locale returned it unchanged
        end
        local leaderLine;
        if portraitBrief ~= "" then
            leaderLine = Locale.Lookup(
                "LOC_CIVVIACCESS_LOAD_LEADER_INTRO",
                leaderName, portraitBrief);
        else
            leaderLine = leaderName .. ".";
        end
        table.insert(lines, leaderLine);
        table.insert(md, "## " .. leaderName);
        if portraitBrief ~= "" then
            table.insert(md, portraitBrief);
        end
    end

    -- 4. Challenge override (if active) takes the place of leader info.
    --    Round 8: default mode speaks the leader paragraph too
    --    (Sean Bean is suppressed by default, so no audio overlap
    --    risk). When PLAY_SEAN_BEAN is true, we skip the paragraph
    --    here because Sean Bean will recite it after Enter press.
    --    Clipboard always gets the paragraph regardless.
    if challengeName ~= nil and challengeName ~= "" then
        if challengeInfo ~= nil and challengeInfo ~= "" then
            table.insert(lines, challengeInfo);
            table.insert(md, "");
            table.insert(md, "## Challenge");
            table.insert(md, challengeInfo);
        end
    elseif leaderInfo ~= "" then
        if not PLAY_SEAN_BEAN then
            table.insert(lines, leaderInfo);
        end
        table.insert(md, "");
        table.insert(md, leaderInfo);
    end

    -- 5. Abilities / units / buildings
    local uniques = collectUniques(ctx.leaderType, ctx.civType);
    local abilityStrings = {};
    for _, item in ipairs(uniques.abilities) do
        local s = describeUniqueItem(item);
        if s ~= nil then table.insert(abilityStrings, s); end
    end
    for _, item in ipairs(uniques.units) do
        local s = describeUniqueItem(item);
        if s ~= nil then table.insert(abilityStrings, s); end
    end
    for _, item in ipairs(uniques.buildings) do
        local s = describeUniqueItem(item);
        if s ~= nil then table.insert(abilityStrings, s); end
    end

    if #abilityStrings > 0 then
        table.insert(lines, safeLookup("LOC_CIVVIACCESS_LOAD_FEATURES_HEADER"));
        table.insert(md, "");
        table.insert(md, "## Unique abilities and features");
        for _, s in ipairs(abilityStrings) do
            table.insert(lines, s);
            table.insert(md, "- " .. s);
        end
    end

    -- 6. Hotkey hint + decision prompt
    table.insert(lines, safeLookup("LOC_CIVVIACCESS_LOAD_HOTKEY_HINT"));
    -- Decision prompt varies by Sean-Bean setting.
    if PLAY_SEAN_BEAN then
        table.insert(lines, safeLookup("LOC_CIVVIACCESS_LOAD_BRIEFING_DECISION_SEAN"));
    else
        table.insert(lines, safeLookup("LOC_CIVVIACCESS_LOAD_BRIEFING_DECISION_NOSEAN"));
    end

    m_briefing.lines         = lines;
    m_briefing.clipboardText = table.concat(md, "\n");
    m_briefing.leaderInfoKey = ctx.leaderInfoKey;
    m_briefing.abilitiesText = table.concat(abilityStrings, ". ");
    m_briefing.leaderType    = ctx.leaderType;
end

local function speakBriefing()
    local lines = m_briefing.lines or {};
    if #lines == 0 then return; end
    -- First line emits as critical (load-screen briefing is the
    -- player's primary orientation moment); the gateway holds its
    -- shield for the follow-up status lines so the full briefing
    -- speaks in order instead of being clobbered.
    Speech.emit(lines[1], "critical");
    for i = 2, #lines do
        Speech.emit(lines[i], "status");
    end
end

-- ===========================================================================
--  Actions
-- ===========================================================================
local function startDawnOfManSpeech()
    if m_seanBeanStarted then return; end
    m_seanBeanStarted = true;
    if UI ~= nil and UI.PlaySound ~= nil then
        pcall(UI.PlaySound, "Play_DawnOfMan_Speech");
    end
    -- Tell the user what to do once Sean finishes. Queued so it
    -- plays AFTER Sean's intro audio (rough estimate — Tolk and
    -- engine audio are independent streams, so it won't actually
    -- wait for Sean; user hears it shortly after Sean starts).
    -- Without this prompt, user has no idea Sean's speech ends and
    -- the game is waiting for another Enter to begin (Noel
    -- 2026-05-23: "nothing was spoken at the end of Sean to tell
    -- user what's next").
    speak(safeLookup("LOC_CIVVIACCESS_LOAD_POST_SEAN_PROMPT"), true);
end

local function skipToGame()
    -- Try the engine's "begin game" entry point. The shadow exports
    -- OnActivateButtonClicked as a global; that path handles the
    -- transition out of LoadScreen and stops Sean Bean if running.
    if OnActivateButtonClicked ~= nil then
        pcall(OnActivateButtonClicked);
    end
end

local function speakPortraitDescription()
    if m_briefing.leaderType == nil then
        speak(safeLookup("LOC_CIVVIACCESS_LOAD_PORTRAIT_PLACEHOLDER"));
        return;
    end
    -- Same Locale.HasTextKey-doesn't-exist workaround as
    -- buildBriefing: call Lookup, check for key-returned-unchanged.
    local key = "LOC_CIVVIACCESS_LDR_" .. m_briefing.leaderType .. "_LONG";
    local text = safeLookup(key);
    if text == key or text == "" then
        speak(safeLookup("LOC_CIVVIACCESS_LOAD_PORTRAIT_PLACEHOLDER"));
        return;
    end
    speak(text);
    copyToClipboard(text);
end

local function speakAbilities()
    if m_briefing.abilitiesText == "" then return; end
    speak(safeLookup("LOC_CIVVIACCESS_LOAD_FEATURES_HEADER"));
    speak(m_briefing.abilitiesText, true);
    copyToClipboard(m_briefing.abilitiesText);
end

local function speakDawnOfManTranscript()
    -- No Sean Bean SRT ships per probe 2026-05-22. The
    -- LOC_LOADING_INFO_<LEADER> paragraph is the cleanest available
    -- stand-in — it's the leader's text that the visual UI displays
    -- and covers similar substance. Polish path: per-leader
    -- hand-transcribed LOC_CIVVIACCESS_LDR_<TYPE>_DAWN_TRANSCRIPT.
    if m_briefing.leaderType ~= nil then
        local transcriptKey = "LOC_CIVVIACCESS_LDR_" ..
                              m_briefing.leaderType .. "_DAWN_TRANSCRIPT";
        local text = safeLookup(transcriptKey);
        if text ~= transcriptKey and text ~= "" then
            speak(text);
            copyToClipboard(text);
            return;
        end
    end
    if m_briefing.leaderInfoKey ~= nil then
        local text = safeLookup(m_briefing.leaderInfoKey);
        if text ~= "" then
            speak(text);
            copyToClipboard(text);
            return;
        end
    end
    speak(safeLookup("LOC_CIVVIACCESS_LOAD_TRANSCRIPT_MISSING"));
end

-- ===========================================================================
--  Input dispatch (called from the shadowed OnInput)
-- ===========================================================================
-- 3-param signature matches the engine LoadScreen's OnInput. Returns
-- true if we consumed the input.

function LoadScreenAccess.HandleKey(uiMsg, wParam, lParam)
    -- Track Ctrl state.
    if wParam == VK_CONTROL then
        if uiMsg == KEY_DOWN_MSG then m_ctrlDown = true;
        elseif uiMsg == KEY_UP_MSG then m_ctrlDown = false; end
        return false;
    end

    if uiMsg ~= KEY_UP_MSG then return false; end
    -- Round-5 diagnostic: confirm input is actually reaching us
    -- post-load. Round-4 log showed zero HandleKey calls for the
    -- entire LoadScreen lifetime, suggesting the engine isn't
    -- delivering input to LoadScreen's handler at all (despite
    -- our early-install in Initialize). One log line per keyup
    -- so we can see whether the engine routes keys here.
    Log.info(string.format("LoadScreenAccess.HandleKey: keyup=%d ctrl=%s ready=%s loadComplete=%s",
        wParam, tostring(m_ctrlDown), tostring(m_ready),
        tostring(m_loadComplete)));

    -- Hotkeys: Ctrl+R/T/I/S OR bare R/T/I/S. Bare-key alternates
    -- exist because Civ VI's Ctrl tracking is unreliable (round-5
    -- log showed Ctrl released before T release reached our
    -- handler). Bare keys are safe here because the LoadScreen
    -- context blocks engine actions like B (Found City) etc.
    if wParam == VK_R then
        speakBriefing();
        return true;
    end
    if wParam == VK_T then
        speakAbilities();
        return true;
    end
    if wParam == VK_I then
        speakPortraitDescription();
        return true;
    end
    if wParam == VK_S then
        speakDawnOfManTranscript();
        return true;
    end

    -- Enter / Space: if Sean Bean is enabled and hasn't started yet,
    -- fire him. Otherwise skip straight to the game. This is the
    -- "press Enter for Dawn of Man speech, then press Enter again to
    -- begin the game" flow from the briefing's decision prompt.
    if wParam == VK_RETURN or wParam == VK_SPACE then
        if PLAY_SEAN_BEAN and not m_seanBeanStarted then
            startDawnOfManSpeech();
        else
            skipToGame();
        end
        return true;
    end

    -- Escape: skip everything. Bypasses Sean Bean even if not yet
    -- started. Engine's OnActivateButtonClicked stops Sean if he's
    -- already speaking via STOP_SPEECH_DAWNOFMAN.
    if wParam == VK_ESCAPE then
        skipToGame();
        return true;
    end

    return false;
end

-- ===========================================================================
--  Notifications from the shadowed LoadScreen.lua
-- ===========================================================================

-- Called by the shadow at the END of OnLoadScreenContentReady with the
-- briefing data the engine just resolved (leader, civ, era, info text,
-- challenge text if active). The shadow is responsible for NOT firing
-- Play_DawnOfMan_Speech before this call — our briefing speaks first.
function LoadScreenAccess.NotifyContentReady(ctx)
    if ctx == nil then return; end
    m_ctrlDown         = false;
    m_loadComplete     = false;
    m_seanBeanStarted  = false;
    buildBriefing(ctx);
    m_ready = true;
    speakBriefing();
    copyToClipboard(m_briefing.clipboardText);
end

-- Called by the shadow at the END of OnLoadGameViewStateDone (world
-- ready, Begin Game button visible / pending). NOINTERRUPT so it
-- queues behind the briefing tail if Tolk is still working through
-- it — round-6 log showed this firing with interrupt priority and
-- chopping the briefing mid-paragraph.
function LoadScreenAccess.NotifyLoadComplete()
    m_loadComplete = true;
    speak(safeLookup("LOC_CIVVIACCESS_LOAD_COMPLETE_READY"), true);
end

-- Called by the shadow at OnShow — before content is even resolved.
-- Lets the user know the game-start sequence has begun, queued so it
-- doesn't interrupt whatever the AdvancedSetup → click-Start speech
-- was finishing. Per Noel 2026-05-23 ("Recommend speaking 'Creating
-- game' until it starts reading").
function LoadScreenAccess.NotifyShowing()
    -- Pick the phrase by what's actually happening rather than always saying
    -- "Creating game" (the bug: every launch — new, load, or resume — said
    -- Creating game). Noel 2026-06-03.
    --   * GameConfiguration.IsSavedGame() is the reliable "this is a load"
    --     signal — the engine's own LoadScreen uses it to label the button
    --     LOC_CONTINUE_GAME. Resume (continue last save) and explicit Load are
    --     indistinguishable at this layer (both are saved-game loads), so both
    --     read "Loading game" for now; refining to "Resuming game" needs a
    --     signal we don't have here yet.
    --   * Tutorial wording is a FUTURE hook — the tutorial flow isn't coded yet,
    --     so the branch is ready but its detection (IsTutorial, guarded) will be
    --     confirmed when tutorial work lands.
    local key = "LOC_CIVVIACCESS_LOAD_STARTING";  -- new game: "Creating game."
    local isSaved, isTutorial = false, false;
    if GameConfiguration ~= nil and GameConfiguration.IsSavedGame ~= nil then
        local ok, v = pcall(function() return GameConfiguration.IsSavedGame(); end);
        isSaved = ok and v == true;
    end
    if GameConfiguration ~= nil and GameConfiguration.IsTutorial ~= nil then
        local ok, v = pcall(function() return GameConfiguration.IsTutorial(); end);
        isTutorial = ok and v == true;
    end
    if isTutorial then
        key = "LOC_CIVVIACCESS_LOAD_STARTING_TUTORIAL";
    elseif isSaved then
        key = "LOC_CIVVIACCESS_LOAD_STARTING_LOAD";
    end
    if Log ~= nil and Log.info ~= nil then
        Log.info("LoadScreenAccess.NotifyShowing: isSaved=" .. tostring(isSaved)
            .. " isTutorial=" .. tostring(isTutorial) .. " -> " .. key);
    end
    speak(safeLookup(key), true);
end

-- ===========================================================================
--  Engine InputAction subscription for briefing re-read hotkeys
-- ===========================================================================
-- Round-5/8/9 testing showed bare letter keys (R/T/I/S) inside
-- LoadScreen's OnInput handler are never delivered by Civ VI during
-- InputContext.Loading — only special keys make it through. The
-- workaround: register R/T/I/S as engine InputActions in
-- RemapForHexCursor.xml (already done) and subscribe here to
-- Events.InputActionTriggered. Engine action dispatch is independent
-- of LoadScreen's input handler, so this works during the load window.
--
-- These actions fire globally; in-game presses also trigger them. The
-- speak* functions are no-ops if briefing data isn't built yet
-- (m_ready guard inside speakBriefing / speakAbilities / etc.), so
-- post-game R-press just re-reads the most recent briefing. Slightly
-- weird but harmless — could gate on context if it becomes a problem.

local _actionIds = nil;

local function lookupActionIds()
    if _actionIds ~= nil then return; end
    if Input == nil or Input.GetActionId == nil then return; end
    _actionIds = {
        repeatBriefing      = Input.GetActionId("CIVVIACCESS_RepeatBriefing"),
        abilitiesReread     = Input.GetActionId("CIVVIACCESS_AbilitiesReread"),
        portraitDescribe    = Input.GetActionId("CIVVIACCESS_PortraitDescribe"),
        dawnOfManTranscript = Input.GetActionId("CIVVIACCESS_DawnOfManTranscript"),
    };
    Log.info(string.format(
        "LoadScreenAccess actions: repeat=%s abilities=%s portrait=%s transcript=%s",
        tostring(_actionIds.repeatBriefing),
        tostring(_actionIds.abilitiesReread),
        tostring(_actionIds.portraitDescribe),
        tostring(_actionIds.dawnOfManTranscript)));
end

local function onInputActionTriggered(actionId)
    -- Context-teardown guard: this listener is subscribed at file load
    -- in the FrontEnd context but the engine fires Events.Input
    -- ActionTriggered globally. After LoadScreenClose, when R/T/I/S
    -- press in-game, this handler is still invoked but the FrontEnd
    -- globals it depends on (Speech, Locale) are nil after teardown —
    -- confirmed via Lua.log runtime errors 2026-05-24. Skip if the
    -- speech infrastructure isn't available; there's no briefing to
    -- re-read in-game anyway (briefing is LoadScreen-only).
    if Speech == nil or Speech.emit == nil or Locale == nil then return; end
    lookupActionIds();
    if _actionIds == nil then return; end
    if actionId == _actionIds.repeatBriefing then
        speakBriefing();
    elseif actionId == _actionIds.abilitiesReread then
        speakAbilities();
    elseif actionId == _actionIds.portraitDescribe then
        speakPortraitDescription();
    elseif actionId == _actionIds.dawnOfManTranscript then
        speakDawnOfManTranscript();
    end
end

if Events ~= nil and Events.InputActionTriggered ~= nil then
    Events.InputActionTriggered.Add(onInputActionTriggered);
    Log.info("LoadScreenAccess: subscribed to InputActionTriggered");
end

-- Eagerly look up our new actions at file load so the log shows
-- whether the InputAction registration in RemapForHexCursor.xml
-- actually took effect (i.e. these IDs are non-nil and non-negative).
-- If we see "nil" or "-1" for any of these, the XML registration
-- failed for that action.
lookupActionIds();

Log.info("LoadScreenAccess.lua: loaded");
