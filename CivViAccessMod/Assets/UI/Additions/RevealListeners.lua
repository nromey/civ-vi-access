-- ===========================================================================
--  RevealListeners — mod-owned modal reveal window for the DLC reveal popups.
--
--  The Heroes / Secret Society / Natural Disaster / Rock Band / Era Complete
--  popups are added by their expansion/game-mode pack as named UI Contexts
--  (AddUserInterfaces -> HeroesPopup.xml etc.). We CANNOT shadow them:
--  confirmed 2026-05-29 via Modding.log that user mods apply as a block BEFORE
--  all official DLC, so ReplaceUIScript / ImportFiles / LoadOrder can't win.
--
--  So this addin (a) subscribes to the same trigger events and (b) raises OUR
--  OWN modal — the picker pattern (QueuePopup + ContextPtr:SetInputHandler +
--  PushActiveContext, like HelpAddin) routed through RevealPopupAccess, so
--  T re-read / I full description / Enter+Esc dismiss behave IDENTICALLY to the
--  base-game NaturalWonder & WonderBuilt popups. On dismiss we also tear down
--  the vanilla DLC popup underneath (UIManager:DequeuePopup — the same call the
--  vanilla itself uses to close).
--
--  Timing: our event handler runs BEFORE the vanilla popup's (we load in the
--  earlier user-mod phase, so we subscribe first). If we showed immediately the
--  vanilla would stack on top of us. So live reveals defer one frame via
--  SetUpdate — by then the vanilla has shown, and we dequeue it and raise ours
--  on top. Debug raises (no vanilla popup exists) show immediately.
-- ===========================================================================
include("InputSupport");        -- InputContext table (GameOptions) for the input-context push
include("RevealPopupAccess");   -- NotifyShow / HandleKey / locOrNil (pulls in ScreenReader/Speech)
include("ChoosePopupAccess");   -- navigate+select helper that drives the dedication + government choosers
include("PolicyWizard");        -- slot-by-slot policy-card arranger (the Government policies tab)
include("RevealAnnounce");      -- tier-1 fog-reveal summary (hosted here for its live UI VM)
include("BoardQueryProbe");     -- THROWAWAY spatial-design probe (strip before release)
include("Log");

-- HeroesSupport (Babylon DLC) gives us GetHeroUnitStats +
-- FormatHeroClassAbilitiesAndCommands, so the hero modal reuses the game's
-- own hardcoded ability table + era-scaled stat math instead of duplicating
-- them. Present ONLY when Heroes & Legends mode is active; pcall the include
-- so a missing file (mode off) can't abort our load, and guard every use of
-- the globals it defines (heroes only ever fire when the mode is on anyway,
-- but the debug raiser could be invoked without it). Each UI Context is its
-- own Lua VM, so we must include it here even though HeroesPopup already did.
pcall(function() include("HeroesSupport"); end);

local locOrNil = RevealPopupAccess.locOrNil;

-- Safe Locale.Lookup: returns nil when the key is undefined (Civ VI returns
-- the key itself for a missing tag) so we never speak a raw LOC_ token.
local function L(key, ...)
    if key == nil or key == "" then return nil; end
    if Locale == nil or Locale.Lookup == nil then return nil; end
    local v = Locale.Lookup(key, ...);
    if v == nil or v == "" or v == key then return nil; end
    return v;
end

local function localPlayer()
    return (Game ~= nil and Game.GetLocalPlayer ~= nil) and Game.GetLocalPlayer() or -1;
end

-- Publish the current reveal's LONG visual description cross-VM so the Shift+I
-- global hotkey (HexCursorAddin) can also read it; harmless alongside the
-- in-modal I key. Pass nil to clear for reveals with no long description.
local function setLastLong(text)
    if LuaEvents ~= nil and LuaEvents.CivViAccess_RevealLongDesc ~= nil then
        LuaEvents.CivViAccess_RevealLongDesc(text or "");
    end
end

-- ===========================================================================
--  The modal: raise / close / input
-- ===========================================================================
local m_open        = false;
local m_vanillaPath = nil;   -- "/InGame/HeroesPopup" etc. — torn down on close
local m_pending     = nil;   -- {opts, vanillaPath} awaiting the deferred show

-- Dedication (commemoration) CHOICE chooser state — see the DEDICATION section
-- below. Declared up here so onInput (defined before that section) can see them.
local m_dedicationOpen = false;
local m_pendingDed     = nil;   -- {options, cap, onCommit} awaiting deferred show

-- Government family state. m_govMode routes input to the right sub-handler
-- (hub / government-type chooser / policy wizard). govHandleKey is assigned in
-- the GOVERNMENT section below; forward-declared here so onInput can see it.
local m_govMode    = nil;       -- nil | "hub" | "chooser" | "wizard"
local govHandleKey = nil;

-- RockBand delayed-cinematic gate. Default ON so the debug concert generator
-- exercises it; set false to fall back to the safe announce-only path (the
-- vanilla popup plays its cinematic immediately and we only speak). See
-- OnRockBandConcert + the "RockBand delayed-cinematic gate" section below.
local ROCKBAND_DELAY_CINEMATIC = true;
local m_rb = nil;   -- {owner, unit, x, y, played, opts} while the gate is active

-- Dequeue a vanilla DLC popup by its context path so it stops owning input /
-- the screen. Same call the popup's own Close() makes. Guarded — the control
-- may not exist (mode off, already closed).
local function dequeueVanilla(path)
    if path == nil then return; end
    pcall(function()
        local ctx = ContextPtr and ContextPtr.LookUpControl and ContextPtr:LookUpControl(path);
        if ctx ~= nil and UIManager ~= nil and UIManager.DequeuePopup ~= nil then
            UIManager:DequeuePopup(ctx);
        end
    end);
end

function CloseReveal()
    if not m_open then return; end
    m_open = false;
    local vanilla = m_vanillaPath;
    m_vanillaPath = nil;

    RevealPopupAccess.NotifyClose();

    pcall(function()
        if UIManager ~= nil and UIManager.DequeuePopup ~= nil then
            UIManager:DequeuePopup(ContextPtr);
        end
    end);
    pcall(function()
        if Input ~= nil and Input.PopContext ~= nil
           and InputContext ~= nil and InputContext.GameOptions ~= nil
           and Input.GetActiveContext ~= nil
           and Input.GetActiveContext() == InputContext.GameOptions then
            Input.PopContext();
        end
    end);
    pcall(function() if ContextPtr ~= nil and ContextPtr.SetHide ~= nil then ContextPtr:SetHide(true); end end);

    -- Tear the vanilla popup down too (it's behind ours).
    dequeueVanilla(vanilla);
end

-- Raise our modal NOW. opts: {leadIn, name, gameplay, short, long, typeNoun}.
local function ShowReveal(opts, vanillaPath)
    if opts == nil then return; end
    m_vanillaPath = vanillaPath;
    -- Remove the vanilla popup first so only ours is modal (it has already
    -- shown by the time we get here on the live deferred path).
    dequeueVanilla(vanillaPath);

    m_open = true;
    pcall(function() if ContextPtr ~= nil and ContextPtr.SetHide ~= nil then ContextPtr:SetHide(false); end end);
    pcall(function()
        if UIManager ~= nil and UIManager.QueuePopup ~= nil then
            UIManager:QueuePopup(ContextPtr, PopupPriority.Current);
        end
    end);
    -- Push GameOptions input context so World bare-letter bindings (Enter
    -- toggling units, etc. — the leak Noel hit) stop firing while our modal
    -- owns the keyboard.
    pcall(function()
        if Input ~= nil and Input.PushActiveContext ~= nil
           and InputContext ~= nil and InputContext.GameOptions ~= nil
           and (Input.GetActiveContext == nil or Input.GetActiveContext() ~= InputContext.GameOptions) then
            Input.PushActiveContext(InputContext.GameOptions);
        end
    end);

    opts.onClose = CloseReveal;
    opts.kind    = opts.kind or "critical";
    RevealPopupAccess.NotifyShow(opts);
end

-- Live reveals: defer one frame so we land on TOP of the vanilla popup (which
-- subscribes after us and shows this frame), then dequeue it and show ours.
local function OnDeferredShow()
    if ContextPtr ~= nil and ContextPtr.ClearUpdate ~= nil then ContextPtr:ClearUpdate(); end
    local p = m_pending;
    m_pending = nil;
    if p ~= nil then ShowReveal(p.opts, p.vanillaPath); end
end

local function RaiseLive(opts, vanillaPath)
    if opts == nil then Log.warn("RaiseLive: opts nil (heroOpts/etc. returned nil)"); return; end
    m_pending = { opts = opts, vanillaPath = vanillaPath };
    if ContextPtr ~= nil and ContextPtr.SetUpdate ~= nil then
        -- A HIDDEN context does NOT receive SetUpdate ticks, so the deferred
        -- OnDeferredShow never fires (root-caused 2026-05-30). Unhide first so
        -- the engine ticks us; our context is a 1x1 invisible grid, so showing
        -- it has no visual cost.
        if ContextPtr.SetHide ~= nil then ContextPtr:SetHide(false); end
        ContextPtr:SetUpdate(OnDeferredShow);
    else
        ShowReveal(opts, vanillaPath);   -- fallback: no SetUpdate, show now
    end
end

local function onInput(pInputStruct)
    -- A government interaction (hub / chooser / policy wizard) owns input when up.
    if m_govMode ~= nil then
        if govHandleKey ~= nil and govHandleKey(pInputStruct) then return true; end
        return false;
    end
    -- A dedication (choice) chooser takes priority when open: route to
    -- ChoosePopupAccess, which owns navigate / toggle / confirm / cancel.
    if m_dedicationOpen then
        if ChoosePopupAccess.HandleKey(pInputStruct) then return true; end
        return false;
    end
    if not m_open then return false; end
    if RevealPopupAccess.HandleKey(pInputStruct) then return true; end
    return false;   -- swallow nothing else; let the engine have unrelated keys
end

-- ===========================================================================
--  Opts builders (return the structured announce; also stash the long desc)
-- ===========================================================================
-- Hero abilities + commands as one speech string (the T block). Reuses the
-- DLC's own formatter so we get its hardcoded passive-ability table for free;
-- [NEWLINE] separators → ". " for the direct-Tolk path (the launcher's
-- [NEWLINE] sanitizer only touches the cross-VM log-tail path, not in-VM emit).
local function heroAbilitiesText(eHeroClass)
    if FormatHeroClassAbilitiesAndCommands == nil then return nil; end
    local ok, s = pcall(FormatHeroClassAbilitiesAndCommands, eHeroClass);
    if not ok or s == nil or s == "" then return nil; end
    s = s:gsub("%[NEWLINE%]", ". ");   -- per-row token → sentence break
    s = s:gsub("%. %. ", ". ");        -- collapse any accidental doubles
    return s;
end

-- Discovery-source line, mirroring the vanilla HeroesPopup so we speak exactly
-- what a sighted player reads (parity). Falls back to the generic summary for
-- sources we don't special-case or when the enum isn't available.
local function heroDiscoverySourceText(kHeroDef, eSourceType, iSourceID)
    local name = L(kHeroDef.Name) or "";
    local HDS = HeroDiscoverySources;
    if HDS ~= nil and eSourceType ~= nil then
        if eSourceType == HDS.DISCOVERY_SOURCE_PROJECT then
            return L("LOC_HERO_DISCOVERED_DESC_PROJECT", name);
        elseif eSourceType == HDS.DISCOVERY_SOURCE_GOODY_HUT then
            return L("LOC_HERO_DISCOVERED_DESC_GOODY_HUT", name);
        elseif eSourceType == HDS.DISCOVERY_SOURCE_ENCOUNTER then
            return L("LOC_HERO_DISCOVERED_DESC_ENCOUNTER", name);
        elseif eSourceType == HDS.DISCOVERY_SOURCE_NEW_CONTINENT
               and iSourceID ~= nil and GameInfo.Continents[iSourceID] ~= nil then
            return L("LOC_HERO_DISCOVERED_DESC_NEW_CONTINENT", name, GameInfo.Continents[iSourceID].Description);
        elseif eSourceType == HDS.DISCOVERY_SOURCE_NATURAL_WONDER
               and iSourceID ~= nil and GameInfo.Features[iSourceID] ~= nil then
            return L("LOC_HERO_DISCOVERED_DESC_NATURAL_WONDER", name, GameInfo.Features[iSourceID].Name);
        elseif (eSourceType == HDS.DISCOVERY_SOURCE_CITY_STATE_INFLUENCE
                or eSourceType == HDS.DISCOVERY_SOURCE_CITY_STATE_SUZERAIN)
               and PlayerConfigurations ~= nil and PlayerConfigurations[iSourceID] ~= nil then
            local civ = PlayerConfigurations[iSourceID]:GetCivilizationShortDescription();
            local k = (eSourceType == HDS.DISCOVERY_SOURCE_CITY_STATE_SUZERAIN)
                      and "LOC_HERO_DISCOVERED_DESC_CITY_STATE_SUZERAIN" or "LOC_HERO_DISCOVERED_DESC_CITY_STATE";
            return L(k, name, civ);
        end
    end
    return L("LOC_NOTIFICATION_HERO_DISCOVERED_SUMMARY", name);
end

-- How-to-claim text + the verb for the G hint, mirroring the vanilla popup. A
-- freshly discovered hero is unclaimed → "claim it" (Faith at the hero
-- building); already claimed → "view it" + who holds it. Returns (helpText,
-- verb); helpText may be nil (no hero building yet / manager absent).
local function heroClaimHelp(kHeroDef)
    local pGH = (Game.GetHeroesManager ~= nil) and Game.GetHeroesManager() or nil;
    if pGH == nil or pGH.GetHeroClaimPlayer == nil then return nil, "view it"; end
    local eClaimedBy = pGH:GetHeroClaimPlayer(kHeroDef.Index);
    if eClaimedBy == -1 then
        local eBld = pGH.GetPlayerHeroOriginBuildingType and pGH:GetPlayerHeroOriginBuildingType(localPlayer()) or -1;
        local kBld = (eBld ~= nil and eBld >= 0) and GameInfo.Buildings[eBld] or nil;
        local kUnit = GameInfo.Units[kHeroDef.UnitType];
        local help = nil;
        if kBld ~= nil then
            if kUnit ~= nil and kUnit.Domain == "DOMAIN_SEA" then
                help = L("LOC_DISCOVER_HERO_NAVAL_HELP", kBld.Name);
            else
                help = L("LOC_DISCOVER_HERO_HELP", kBld.Name);
            end
        end
        return help, "claim it";
    end
    local cfg = (PlayerConfigurations ~= nil) and PlayerConfigurations[eClaimedBy] or nil;
    local who = (cfg ~= nil and cfg.GetPlayerName and cfg:GetPlayerName()) or L("LOC_PLAYERNAME_UNKNOWN") or "another player";
    return L("LOC_DISCOVER_CLAIMED_HERO_HELP", who), "view it";
end

local function heroOpts(kHeroDef, leadIn, eSourceType, iSourceID)
    if kHeroDef == nil then return nil; end
    local eHeroClass = kHeroDef.Index;
    local key  = "LOC_CIVVIACCESS_HERO_" .. tostring(kHeroDef.HeroClassType);
    local long = locOrNil(key .. "_LONG");
    setLastLong(long);

    local lore      = L(kHeroDef.Description);
    local discovery = heroDiscoverySourceText(kHeroDef, eSourceType, iSourceID);
    local claimHelp, claimVerb = heroClaimHelp(kHeroDef);
    local abilities = heroAbilitiesText(eHeroClass);   -- abilities + commands TEXT only

    -- On-open = exactly the vanilla discovery popup's text fields, for PARITY:
    -- EventDescription (discovery source) + HeroDescription (lore) + how-to-claim.
    -- Deliberately NO lifespan/charges/combat — those are NOT on the vanilla
    -- popup (they live on the Great People panel, where a sighted player reads
    -- them; surfacing them here would be a hidden advantage — Noel 2026-05-30).
    local parts = {};
    if discovery ~= nil then parts[#parts + 1] = discovery; end
    if lore      ~= nil then parts[#parts + 1] = lore; end
    if claimHelp ~= nil then parts[#parts + 1] = claimHelp; end
    local gameplay = (#parts > 0) and table.concat(parts, " ")
                     or L("LOC_NOTIFICATION_HERO_DISCOVERED_SUMMARY", L(kHeroDef.Name) or "");

    -- G action: open the Great People claim panel (the vanilla "Look At Hero"
    -- button → ShowHeroInGreatPeoplePopup → LuaEvents.HeroesPopup_ShowNewHero).
    local action = nil;
    if LuaEvents ~= nil and LuaEvents.HeroesPopup_ShowNewHero ~= nil then
        action = function() LuaEvents.HeroesPopup_ShowNewHero(kHeroDef); end;
    end

    return {
        leadIn         = leadIn or "Hero discovered",
        name           = L(kHeroDef.Name),
        gameplay       = gameplay,
        short          = locOrNil(key .. "_SHORT"),
        long           = long,
        abilities      = abilities,
        abilitiesLabel = "abilities",
        longLabel      = "appearance",
        typeNoun       = "hero",
        action         = action,
        actionHint     = claimVerb or "view it",
    };
end

-- The name of the secret society the local player already belongs to (nil if
-- none). Mirrors the vanilla popup's GetGovernors():GetSecretSociety() check,
-- which switches the discovery flavor to the "while a member of another" text.
local function currentMemberSocietyName()
    local pPlayer = Players and Players[localPlayer()] or nil;
    if pPlayer == nil or pPlayer.GetGovernors == nil then return nil; end
    local govs = pPlayer:GetGovernors();
    if govs == nil or govs.GetSecretSociety == nil then return nil; end
    local hash = govs:GetSecretSociety();
    local kMember = (hash ~= nil) and GameInfo.SecretSocieties[hash] or nil;
    return kMember and L(kMember.Name) or nil;
end

-- Build the society reveal body exactly as the vanilla SecretSocietyPopup reads
-- it (PARITY): the event description (LOC_DISCOVERED_SOCIETY_FIRST/SUBSEQUENT or
-- LOC_JOINED_SOCIETY_DESC) followed by the society's own discovery/membership
-- flavor (DiscoveryText / MembershipText, or the "while member of another"
-- variant). The vanilla EventTitle is dropped — our leadIn + name already say
-- it (same call the hero modal makes). Icon tags are stripped downstream.
local function societyGameplay(kDef, joined, isFirst, memberOfOtherName)
    local icon = kDef.IconString or "";
    local eventDesc, societyDesc;
    if joined then
        eventDesc   = L("LOC_JOINED_SOCIETY_DESC", kDef.Name, icon);
        societyDesc = L(kDef.MembershipText);
    else
        eventDesc = isFirst
            and L("LOC_DISCOVERED_SOCIETY_FIRST_DESC", kDef.Name, icon)
            or  L("LOC_DISCOVERED_SOCIETY_SUBSEQUENT_DESC", kDef.Name, icon);
        if memberOfOtherName ~= nil then
            societyDesc = L("LOC_DISCOVERED_SOCIETY_WHILE_MEMBER_OF_ANOTHER", kDef.Name, memberOfOtherName);
        else
            societyDesc = L(kDef.DiscoveryText);
        end
    end
    local parts = {};
    if eventDesc   ~= nil then parts[#parts + 1] = eventDesc; end
    if societyDesc ~= nil then parts[#parts + 1] = societyDesc; end
    return (#parts > 0) and table.concat(parts, " ") or nil;
end

local function societyOpts(kSocietyDef, leadIn, gameplay)
    if kSocietyDef == nil then return nil; end
    local key  = "LOC_CIVVIACCESS_SS_" .. tostring(kSocietyDef.SecretSocietyType);
    local long = locOrNil(key .. "_LONG");
    setLastLong(long);
    -- G: open the Governors panel — the vanilla "Open Governors" button
    -- (OnOpenGovernorsButton -> LuaEvents.GovernorPanel_Open). That panel is
    -- where a governor title is spent to join the society / unlock its tiers,
    -- so it's the society reveal's primary action (the hero modal's G analogue).
    local action = nil;
    if LuaEvents ~= nil and LuaEvents.GovernorPanel_Open ~= nil then
        action = function() LuaEvents.GovernorPanel_Open(); end;
    end
    return {
        leadIn     = leadIn,
        name       = L(kSocietyDef.Name),
        gameplay   = gameplay,
        short      = locOrNil(key .. "_SHORT"),
        long       = long,
        typeNoun   = "secret society",
        action     = action,
        actionHint = "open the Governors panel",
    };
end

local function disasterOpts(kEventInfo, mitigationLevel)
    if kEventInfo == nil then return nil; end
    setLastLong(nil);
    -- The event Description is the effect summary. Per-occurrence casualty
    -- counts (units/pop/tiles lost) are computed by the vanilla popup from game
    -- state — a deeper extraction, deferred; the modal can carry it later.
    local extra = L(kEventInfo.Description);
    if mitigationLevel ~= nil and mitigationLevel > 0 then
        extra = (extra and (extra .. " ") or "") .. "Damage mitigated.";
    end
    return {
        leadIn   = "Natural disaster",
        name     = L(kEventInfo.Name),
        gameplay = extra,
    };
end

-- RockBand is ANNOUNCE-ONLY: the vanilla RockBandMoviePopup holds a gamecore
-- event (ms_eventID = UI.ReferenceCurrentEvent()) released ONLY in its own
-- Close() (UI.ReleaseEventID). That ID is a local in the vanilla's VM, so if we
-- dequeued the vanilla to layer our modal over it the hold would never release
-- -> soft-lock, and we can't release another VM's hold. So we let the vanilla
-- own the popup + cinematic + Escape-to-close (which releases cleanly) and only
-- SPEAK. The concert is a cinematic scene with thin, non-navigable content
-- (band + level + tourism), so AnnounceOnly costs only the R re-read. (Enter-
-- gating the concert for audio description needs the event-hold solved first —
-- a focused future session; see the rockband memory.)
local function rockBandOpts(bandName, rockLevel, totalTourism)
    setLastLong(nil);
    local gparts = {};
    if rockLevel ~= nil then
        gparts[#gparts + 1] = "Rock band level " .. tostring(rockLevel);
    end
    if totalTourism ~= nil and totalTourism > 0 then
        gparts[#gparts + 1] = tostring(totalTourism) .. " tourism gained";
    end
    return {
        leadIn   = "Rock band concert",
        name     = bandName,
        gameplay = (#gparts > 0) and table.concat(gparts, ". ") or nil,
    };
end

local function ageVerdict(eras, player)
    if eras == nil then return nil; end
    -- LOC keys are LOC_ERA_PROGRESS_*_AGE (no _NAME suffix).
    if eras.HasHeroicGoldenAge and eras:HasHeroicGoldenAge(player) then
        return L("LOC_ERA_PROGRESS_HEROIC_AGE");
    elseif eras.HasGoldenAge and eras:HasGoldenAge(player) then
        return L("LOC_ERA_PROGRESS_GOLDEN_AGE");
    elseif eras.HasDarkAge and eras:HasDarkAge(player) then
        return L("LOC_ERA_PROGRESS_DARK_AGE");
    end
    return L("LOC_ERA_PROGRESS_NORMAL_AGE");
end

local function eraOpts(eraIndex, player, eras)
    setLastLong(nil);
    local kEra = (eraIndex ~= nil) and GameInfo.Eras[eraIndex] or nil;
    return {
        leadIn   = "New era",
        name     = kEra and L(kEra.Name) or nil,
        gameplay = ageVerdict(eras, player),
    };
end

-- ===========================================================================
--  RockBand delayed-cinematic gate (two-stage, soft-lock-safe)
-- ---------------------------------------------------------------------------
-- The vanilla RockBandMoviePopup holds a gamecore event it releases ONLY in its
-- own Close(); that id is private to its VM, so dequeuing the vanilla would
-- orphan the hold -> soft-lock, and we can't release another VM's hold. So we
-- DON'T dequeue it: we leave the vanilla up and let its own Escape do the clean
-- teardown (event release + lens/mode/input restore). We stop the cinematic it
-- auto-starts (so it doesn't play over our briefing), layer our modal ON TOP
-- owning input, and Enter replays the concert (Sean-Bean). On dismiss we close
-- ONLY our modal and cue the user to press Escape once more -> the vanilla then
-- tears itself down. Two-step dismiss, but zero event-hold risk. (A single-
-- Escape takeover needs the event-hold release proven on a real concert first.)
local function rbStopCinematic()
    if m_rb == nil then return; end
    pcall(function() Events.StopAllCameraAnimations(); end);
    pcall(function() Events.UnitStopCinematicAnimation("IDLE", m_rb.owner, m_rb.unit, m_rb.x, m_rb.y); end);
end

local function rbPlayCinematic()
    if m_rb == nil then return; end
    m_rb.played = true;
    pcall(function() UI.LookAtPlotScreenPosition(m_rb.x, m_rb.y, 0.5, 0.5); end);
    pcall(function() Events.PlayCameraAnimationAtHex("ROCK_BAND_CONCERT_CAMERA", m_rb.x, m_rb.y, 0.0, true); end);
    pcall(function() Events.UnitPlayCinematicAnimation("ACTION_1", m_rb.owner, m_rb.unit, m_rb.x, m_rb.y); end);
end

local function rbSpeak(text)
    if text == nil or text == "" then return; end
    if Speech ~= nil and Speech.emit ~= nil then Speech.emit(text, "selection"); end
end

-- Close ONLY our modal; leave the vanilla popup frontmost to self-teardown on
-- Escape (it owns the gamecore event hold). Cue the user to press Escape.
local function rbCloseModal()
    if m_rb == nil then return; end
    rbStopCinematic();
    m_rb = nil;
    m_open = false;
    RevealPopupAccess.NotifyClose();
    pcall(function() if UIManager ~= nil and UIManager.DequeuePopup ~= nil then UIManager:DequeuePopup(ContextPtr); end end);
    pcall(function()
        if Input ~= nil and Input.PopContext ~= nil
           and InputContext ~= nil and InputContext.GameOptions ~= nil
           and Input.GetActiveContext ~= nil
           and Input.GetActiveContext() == InputContext.GameOptions then
            Input.PopContext();
        end
    end);
    pcall(function() if ContextPtr ~= nil and ContextPtr.SetHide ~= nil then ContextPtr:SetHide(true); end end);
    rbSpeak("Press Escape to continue.");
end

-- Deferred show: by now the vanilla popup has appeared + started its cinematic
-- this frame. Stop the cinematic, then layer our modal OVER it (no dequeue).
local function rbShowDeferred()
    if ContextPtr ~= nil and ContextPtr.ClearUpdate ~= nil then ContextPtr:ClearUpdate(); end
    if m_rb == nil then return; end
    rbStopCinematic();
    m_open = true;
    pcall(function() if ContextPtr ~= nil and ContextPtr.SetHide ~= nil then ContextPtr:SetHide(false); end end);
    pcall(function() if UIManager ~= nil and UIManager.QueuePopup ~= nil then UIManager:QueuePopup(ContextPtr, PopupPriority.Current); end end);
    pcall(function()
        if Input ~= nil and Input.PushActiveContext ~= nil and InputContext ~= nil and InputContext.GameOptions ~= nil then
            Input.PushActiveContext(InputContext.GameOptions);
        end
    end);
    local o = m_rb.opts or {};
    o.playCinematic = rbPlayCinematic;   -- first Enter replays the concert
    o.stopCinematic = rbStopCinematic;   -- torn down on dismiss if it was played
    o.cinematicHint = "Enter to play the concert";
    o.onClose       = rbCloseModal;
    o.kind          = "critical";
    RevealPopupAccess.NotifyShow(o);
end

local function rbRaiseGate()
    if ContextPtr ~= nil and ContextPtr.SetUpdate ~= nil then
        -- Hidden contexts get no SetUpdate tick (root-caused 2026-05-30) — unhide first.
        if ContextPtr.SetHide ~= nil then ContextPtr:SetHide(false); end
        ContextPtr:SetUpdate(rbShowDeferred);
    else
        rbShowDeferred();   -- fallback: no SetUpdate, show now
    end
end

-- ===========================================================================
--  Live event handlers (build opts -> RaiseLive, which defers + tears down
--  the vanilla popup of the given context path)
-- ===========================================================================
local function OnHeroDiscovered(pNotification)
    if pNotification == nil or pNotification:GetPlayerID() ~= localPlayer() then return; end
    local eClass  = pNotification:GetValue("HERO_CLASS");
    local eSource = pNotification:GetValue("PARAM_SUB_TYPE");
    local iSrcID  = pNotification:GetValue("PARAM_TARGET0");
    RaiseLive(heroOpts(eClass and GameInfo.HeroClasses[eClass] or nil, "Hero discovered", eSource, iSrcID), "/InGame/HeroesPopup");
end

local function OnHeroExpired(pNotification)
    if pNotification == nil or pNotification:GetPlayerID() ~= localPlayer() then return; end
    local eClass = pNotification:GetValue("PARAM_TARGET0");
    local kDef = eClass and GameInfo.HeroClasses[eClass] or nil;
    if kDef == nil then return; end
    setLastLong(nil);
    RaiseLive({
        leadIn   = "Hero lost",
        name     = L(kDef.Name),
        gameplay = L("LOC_HERO_EXPIRED_DESC", L(kDef.Name) or ""),
    }, "/InGame/HeroesPopup");
end

local function OnSecretSocietyDiscovered(pNotification)
    if pNotification == nil or pNotification:GetValue("PARAM_DATA0") ~= localPlayer() then return; end
    local eSociety = pNotification:GetValue("PARAM_DATA1");
    local kDef = eSociety and GameInfo.SecretSocieties[eSociety] or nil;
    if kDef == nil then return; end
    local isFirst = pNotification:GetValue("PARAM_DATA2") and true or false;
    local gameplay = societyGameplay(kDef, false, isFirst, currentMemberSocietyName());
    RaiseLive(societyOpts(kDef, "Secret society discovered", gameplay), "/InGame/SecretSocietyPopup");
end

local function OnSecretSocietyJoined(pNotification)
    if pNotification == nil or pNotification:GetValue("PARAM_DATA0") ~= localPlayer() then return; end
    local eSociety = pNotification:GetValue("PARAM_DATA1");
    local kDef = eSociety and GameInfo.SecretSocieties[eSociety] or nil;
    if kDef == nil then return; end
    RaiseLive(societyOpts(kDef, "Secret society joined", societyGameplay(kDef, true)), "/InGame/SecretSocietyPopup");
end

local function OnRandomEventOccurred(type, severity, plotx, ploty, mitigationLevel, randomEventID, gameCorePlaybackEventID)
    local lp = localPlayer();
    if lp < 0 then return; end
    local pPlayer = Players and Players[lp] or nil;
    if pPlayer == nil or (pPlayer.IsHuman and not pPlayer:IsHuman()) then return; end
    RaiseLive(disasterOpts(type and GameInfo.RandomEvents[type] or nil, mitigationLevel), "/InGame/NaturalDisasterPopup");
end

local function OnRockBandConcert(ownerID, unitID, unitX, unitY, result, totalTourism)
    local lp = localPlayer();
    if lp < 0 or ownerID ~= lp then return; end
    -- Mirror the vanilla guards: no concert popup in multiplayer, and only for a
    -- human (skip AI autoplay).
    if GameConfiguration ~= nil and GameConfiguration.IsAnyMultiplayer
       and GameConfiguration.IsAnyMultiplayer() then return; end
    local pPlayer = Players and Players[lp] or nil;
    if pPlayer == nil or (pPlayer.IsHuman and not pPlayer:IsHuman()) then return; end
    local bandName, rockLevel = nil, nil;
    local pUnits = pPlayer.GetUnits and pPlayer:GetUnits() or nil;
    local pUnit = pUnits and pUnits:FindID(unitID) or nil;
    if pUnit ~= nil then
        if pUnit.GetName then bandName = pUnit:GetName(); end
        local pRockBand = pUnit.GetRockBand and pUnit:GetRockBand() or nil;
        if pRockBand ~= nil and pRockBand.GetRockBandLevel then
            rockLevel = pRockBand:GetRockBandLevel();
        end
    end
    if ROCKBAND_DELAY_CINEMATIC then
        -- Sean-Bean gate: defer a frame so the vanilla shows + starts its
        -- cinematic, then stop it + layer our modal; Enter replays the concert.
        m_rb = {
            owner = ownerID, unit = unitID, x = unitX, y = unitY, played = false,
            opts  = rockBandOpts(bandName, rockLevel, totalTourism),
        };
        rbRaiseGate();
    else
        -- Safe fallback: the vanilla popup owns the cinematic, its event hold, and
        -- Escape-to-close; we only speak. No dequeue -> no soft-lock.
        RevealPopupAccess.AnnounceOnly(rockBandOpts(bandName, rockLevel, totalTourism));
    end
end

-- Era: PlayerEraChanged fires a volley at game load (before the view is up);
-- gate on LoadGameViewStateDone so we only announce genuine mid-game era
-- completions, not the starting era.
local m_eraReady = false;
local function OnLoadGameViewStateDone() m_eraReady = true; end

local function OnPlayerEraChanged(player, era)
    if not m_eraReady or player ~= localPlayer() then return; end
    if Game.GetEras == nil then return; end
    local eras = Game.GetEras();
    if eras == nil then return; end
    RaiseLive(eraOpts(era, player, eras), "/InGame/EraCompletePopup");
end

-- ===========================================================================
--  DEDICATION (commemoration) chooser — the first un-shadowable CHOICE popup.
--  Same intercept pattern as the reveals: the DLC DedicationPopup is a modal we
--  can't shadow, so we listen to the SAME trigger (EraReviewPopup_MakeDedication,
--  a cross-VM LuaEvent the era-review flow fires), defer a frame so the vanilla
--  shows, dequeue it, and drive ChoosePopupAccess over our own input-owning
--  context. Commit fires COMMEMORATE directly (the same op the vanilla OnConfirm
--  makes), so we don't depend on its mouse-driven checkboxes. Unlike RockBand,
--  the vanilla DedicationPopup holds NO gamecore event (its Close is a plain
--  DequeuePopup), so dequeuing it is clean — exactly the Hero/SecretSociety case.
--  MULTI-SELECT: a Heroic age lets you choose several commemorations, so this is
--  the first user of ChoosePopupAccess's maxSelect mode.
-- ===========================================================================
local DEDICATION_VANILLA_PATH = "/InGame/DedicationPopup";

-- Age-appropriate bonus text for a commemoration, mirroring the vanilla
-- CreateCommemoration: Golden uses the golden bonus (plus the normal bonus for
-- always-allowed-quest civs), Dark uses the dark bonus, else the normal bonus.
local function commemorationDesc(info, gameEras, lp)
    if info == nil then return nil; end
    if gameEras ~= nil and gameEras.HasGoldenAge ~= nil and gameEras:HasGoldenAge(lp) then
        local t = L(info.GoldenAgeBonusDescription);
        if gameEras.IsPlayerAlwaysAllowedCommemorationQuest ~= nil
           and gameEras:IsPlayerAlwaysAllowedCommemorationQuest(lp) then
            local n = L(info.NormalAgeBonusDescription);
            if t ~= nil and n ~= nil then t = t .. " " .. n; elseif n ~= nil then t = n; end
        end
        return t;
    elseif gameEras ~= nil and gameEras.HasDarkAge ~= nil and gameEras:HasDarkAge(lp) then
        return L(info.DarkAgeBonusDescription);
    end
    return L(info.NormalAgeBonusDescription);
end

-- Build the option list from the SAME source the vanilla popup uses:
-- GetPlayerCommemorateChoices -> GameInfo.CommemorationTypes. data = the
-- commemoration index (what COMMEMORATE's PARAM_COMMEMORATION_TYPE wants).
local function buildDedicationOptions(lp, gameEras)
    local options = {};
    if gameEras == nil or gameEras.GetPlayerCommemorateChoices == nil then return options; end
    local choices = gameEras:GetPlayerCommemorateChoices(lp);
    if choices == nil then return options; end
    for _, cType in ipairs(choices) do
        local info = (GameInfo ~= nil and GameInfo.CommemorationTypes ~= nil) and GameInfo.CommemorationTypes[cType] or nil;
        if info ~= nil then
            options[#options + 1] = {
                name        = L(info.CategoryDescription) or L(info.Name) or info.CommemorationType,
                description = commemorationDesc(info, gameEras, lp),
                data        = cType,
            };
        end
    end
    return options;
end

-- Close ONLY our chooser: dequeue our context, drop the input-context push,
-- hide, and tear down the (already-dequeued) vanilla for good measure.
function CloseDedication()
    if not m_dedicationOpen then return; end
    m_dedicationOpen = false;
    ChoosePopupAccess.NotifyClose();
    pcall(function() if UIManager ~= nil and UIManager.DequeuePopup ~= nil then UIManager:DequeuePopup(ContextPtr); end end);
    pcall(function()
        if Input ~= nil and Input.PopContext ~= nil
           and InputContext ~= nil and InputContext.GameOptions ~= nil
           and Input.GetActiveContext ~= nil
           and Input.GetActiveContext() == InputContext.GameOptions then
            Input.PopContext();
        end
    end);
    pcall(function() if ContextPtr ~= nil and ContextPtr.SetHide ~= nil then ContextPtr:SetHide(true); end end);
    dequeueVanilla(DEDICATION_VANILLA_PATH);
end

-- Fire COMMEMORATE for each chosen commemoration (the same op the vanilla
-- OnConfirm makes), play the confirm sound, then close.
function CommitDedications(selOpts)
    local lp = localPlayer();
    if PlayerOperations ~= nil and PlayerOperations.COMMEMORATE ~= nil and selOpts ~= nil then
        for _, opt in ipairs(selOpts) do
            local kParameters = {};
            kParameters[PlayerOperations.PARAM_COMMEMORATION_TYPE] = opt.data;
            UI.RequestPlayerOperation(lp, PlayerOperations.COMMEMORATE, kParameters);
        end
    end
    pcall(function() UI.PlaySound("Confirm_Dedication"); end);
    CloseDedication();
end

-- Raise our chooser NOW (vanilla already shown by the deferred path; dequeue it
-- so only we own input). onCommit defaults to the real COMMEMORATE commit.
local function ShowDedication(options, cap, onCommit)
    m_dedicationOpen = true;
    dequeueVanilla(DEDICATION_VANILLA_PATH);
    pcall(function() if ContextPtr ~= nil and ContextPtr.SetHide ~= nil then ContextPtr:SetHide(false); end end);
    pcall(function()
        if UIManager ~= nil and UIManager.QueuePopup ~= nil then
            UIManager:QueuePopup(ContextPtr, PopupPriority.Current);
        end
    end);
    pcall(function()
        if Input ~= nil and Input.PushActiveContext ~= nil
           and InputContext ~= nil and InputContext.GameOptions ~= nil
           and (Input.GetActiveContext == nil or Input.GetActiveContext() ~= InputContext.GameOptions) then
            Input.PushActiveContext(InputContext.GameOptions);
        end
    end);
    ChoosePopupAccess.Open({
        title     = L("LOC_ERA_COMMEMORATION_POPUP_DEDICATION_HEADER") or "Choose a dedication",
        options   = options,
        typeNoun  = "dedication",
        maxSelect = cap,
        onCommit  = onCommit or function(sel) CommitDedications(sel); end,
        onCancel  = function() CloseDedication(); end,
    });
end

-- Live trigger fires before the vanilla's handler (we subscribe first), so defer
-- a frame: the vanilla shows + becomes modal, then we dequeue it and raise ours.
local function OnDeferredDedication()
    if ContextPtr ~= nil and ContextPtr.ClearUpdate ~= nil then ContextPtr:ClearUpdate(); end
    local p = m_pendingDed;
    m_pendingDed = nil;
    if p ~= nil then ShowDedication(p.options, p.cap, p.onCommit); end
end

local function RaiseDedication(options, cap, onCommit)
    if options == nil or #options == 0 or cap == nil or cap <= 0 then return; end
    m_pendingDed = { options = options, cap = cap, onCommit = onCommit };
    if ContextPtr ~= nil and ContextPtr.SetUpdate ~= nil then
        if ContextPtr.SetHide ~= nil then ContextPtr:SetHide(false); end   -- hidden contexts get no tick
        ContextPtr:SetUpdate(OnDeferredDedication);
    else
        ShowDedication(options, cap, onCommit);
    end
end

-- EraReviewPopup_MakeDedication(prevEraIndex, newEraIndex): the era-review flow's
-- handoff to the dedication choice (the same event the vanilla DedicationPopup
-- listens to). Build options + cap from live game state; bail if there's nothing
-- to choose (mirrors the vanilla's "allocatedInstances > 0 and allowed > 0" gate).
local function OnMakeDedication(prevEraIndex, newEraIndex)
    local lp = localPlayer();
    if lp < 0 then return; end
    if newEraIndex == nil or newEraIndex <= 0 then return; end
    if Game.GetEras == nil then return; end
    local gameEras = Game.GetEras();
    if gameEras == nil then return; end
    local cap = (gameEras.GetPlayerNumAllowedCommemorations ~= nil)
                and gameEras:GetPlayerNumAllowedCommemorations(lp) or 0;
    if cap <= 0 then return; end
    local options = buildDedicationOptions(lp, gameEras);
    if #options == 0 then return; end
    RaiseDedication(options, cap, nil);
end

-- ===========================================================================
--  GOVERNMENT — type chooser + policy-slot wizard + manual-open hub.
--  The Gathering Storm GovernmentScreen is a DLC replacement (loads AFTER us =
--  the hard engine wall), so this is the Dedication intercept pattern, not a
--  shadow: subscribe to the same open events the vanilla screen uses, defer a
--  frame so it shows + becomes modal, dequeue it, own the keyboard via the
--  GameOptions input-context push, and drive our own flow. Three entry points
--  (mirroring which vanilla tab each event opens):
--    * "Open Governments" (LaunchBar / new-government notification / tech-civic)
--        -> government-TYPE chooser (single-select ChoosePopupAccess). Commit =
--        pCulture:RequestChangeGovernment(hash); each option's T-detail speaks
--        the inherent + accumulated bonus and the anarchy cost.
--    * "Open Policies" (fill-slot notification / tech-civic completion)
--        -> POLICY WIZARD (PolicyWizard, slot-by-slot card arranger). Commit =
--        pCulture:RequestPolicyChanges (full clear-and-reapply, our Pass-4 path).
--    * "Open My Government" (the LaunchBar button's default tab)
--        -> HUB: announce current government, G -> type chooser, P -> policies.
--        (Needed so the manual open can still reach "change government", which
--        on the vanilla screen lives behind a tab we don't navigate to.)
--  Government change is async (a queued player op), so we do NOT chain the
--  policy wizard after it in the same frame (the new slots aren't applied yet) —
--  the game's own fill-slot notification brings policies up when ready.
-- ===========================================================================
local GOVERNMENT_VANILLA_PATH = "/InGame/GovernmentScreen";
local m_govPendingShow = nil;   -- deferred show fn for the gov family

local SLOT_LABELS = {
    SLOT_MILITARY     = "Military",
    SLOT_ECONOMIC     = "Economic",
    SLOT_DIPLOMATIC   = "Diplomatic",
    SLOT_WILDCARD     = "Wildcard",
    SLOT_GREAT_PERSON = "Great Person",
};

local function govSpeak(text, kind)
    if text == nil or text == "" then return; end
    if Speech ~= nil and Speech.emit ~= nil then Speech.emit(text, kind or "selection"); end
end

-- Unhide + queue our context + push GameOptions so we own the keyboard. The
-- push is guarded against double-push, so it's safe to call on every Show* (hub
-- -> chooser / wizard transitions reuse the same already-pushed context).
local function govOpenContext()
    dequeueVanilla(GOVERNMENT_VANILLA_PATH);
    pcall(function() if ContextPtr ~= nil and ContextPtr.SetHide ~= nil then ContextPtr:SetHide(false); end end);
    pcall(function()
        if UIManager ~= nil and UIManager.QueuePopup ~= nil then
            UIManager:QueuePopup(ContextPtr, PopupPriority.Current);
        end
    end);
    pcall(function()
        if Input ~= nil and Input.PushActiveContext ~= nil
           and InputContext ~= nil and InputContext.GameOptions ~= nil
           and (Input.GetActiveContext == nil or Input.GetActiveContext() ~= InputContext.GameOptions) then
            Input.PushActiveContext(InputContext.GameOptions);
        end
    end);
end

local function govCloseContext()
    m_govMode = nil;
    pcall(function() ChoosePopupAccess.NotifyClose(); end);
    pcall(function() PolicyWizard.NotifyClose(); end);
    pcall(function() if UIManager ~= nil and UIManager.DequeuePopup ~= nil then UIManager:DequeuePopup(ContextPtr); end end);
    pcall(function()
        if Input ~= nil and Input.PopContext ~= nil
           and InputContext ~= nil and InputContext.GameOptions ~= nil
           and Input.GetActiveContext ~= nil
           and Input.GetActiveContext() == InputContext.GameOptions then
            Input.PopContext();
        end
    end);
    pcall(function() if ContextPtr ~= nil and ContextPtr.SetHide ~= nil then ContextPtr:SetHide(true); end end);
    dequeueVanilla(GOVERNMENT_VANILLA_PATH);
end

-- ---- Government-TYPE chooser -------------------------------------------------
local function playerCulture()
    local pPlayer = Players and Players[localPlayer()] or nil;
    return pPlayer and pPlayer.GetCulture and pPlayer:GetCulture() or nil;
end

-- Anarchy-cost line for the option detail. govIndex = GameInfo.Governments[].Index.
local function governmentAnarchyLine(govIndex)
    local pCulture = playerCulture();
    if pCulture == nil or pCulture.GetAnarchyTurns == nil or govIndex == nil then return nil; end
    local ok, n = pcall(function() return pCulture:GetAnarchyTurns(govIndex); end);
    if not ok or n == nil then return nil; end
    if n > 0 then return "Switching costs " .. tostring(n) .. " turns of anarchy"; end
    return "No anarchy";
end

local function buildGovernmentOptions(lp)
    local options = {};
    if GameInfo == nil or GameInfo.Governments == nil then return options; end
    local pCulture = playerCulture();
    for row in GameInfo.Governments() do
        local typeRow = GameInfo.Types and GameInfo.Types[row.GovernmentType] or nil;
        local hash = typeRow and typeRow.Hash or nil;
        local unlocked = true;
        if pCulture ~= nil and pCulture.IsGovernmentUnlocked ~= nil and hash ~= nil then
            local ok, u = pcall(function() return pCulture:IsGovernmentUnlocked(hash); end);
            unlocked = ok and u or false;
        end
        if hash ~= nil and unlocked then
            local descParts = {};
            local inh = L(row.InherentBonusDesc);
            local acc = L(row.AccumulatedBonusShortDesc);
            if inh ~= nil then descParts[#descParts + 1] = inh; end
            if acc ~= nil then descParts[#descParts + 1] = acc; end
            local anarchy = governmentAnarchyLine(row.Index);
            if anarchy ~= nil then descParts[#descParts + 1] = anarchy; end
            options[#options + 1] = {
                name        = L(row.Name) or row.GovernmentType,
                description = (#descParts > 0) and table.concat(descParts, ". ") or nil,
                data        = hash,
            };
        end
    end
    return options;
end

local function CommitGovernment(hash)
    local pCulture = playerCulture();
    if pCulture ~= nil and pCulture.RequestChangeGovernment ~= nil and hash ~= nil then
        pcall(function() pCulture:RequestChangeGovernment(hash); end);
    end
    pcall(function() UI.PlaySound("Confirm_Government"); end);
    govCloseContext();
end

local function ShowGovernmentChooser(options, onCommit)
    govOpenContext();
    m_govMode = "chooser";
    ChoosePopupAccess.Open({
        title    = L("LOC_GOVERNMENT_PICKER_TITLE") or "Choose a government",
        options  = options,
        typeNoun = "government",
        onCommit = onCommit or function(opt) CommitGovernment(opt.data); end,
        onCancel = function() govCloseContext(); end,
    });
end

-- ---- Policy-slot wizard ------------------------------------------------------
local function govSlotTypeString(pCulture, i)
    local iSlotType = pCulture:GetSlotType(i);
    local row = (iSlotType ~= nil and GameInfo.GovernmentSlots ~= nil) and GameInfo.GovernmentSlots[iSlotType] or nil;
    return row and row.GovernmentSlotType or nil;
end

local function govPolicyFitsSlot(policySlotType, strSlotType)
    if strSlotType == "SLOT_WILDCARD" or strSlotType == "SLOT_GREAT_PERSON" then return true; end
    return policySlotType == strSlotType;
end

local function buildPolicySlots(pCulture)
    local slots = {};
    if pCulture == nil or pCulture.GetNumPolicySlots == nil then return slots; end
    local total = pCulture:GetNumPolicySlots();
    local perType = {};
    for i = 0, total - 1 do
        local strSlotType = govSlotTypeString(pCulture, i);
        local base = SLOT_LABELS[strSlotType] or "Policy";
        perType[base] = (perType[base] or 0) + 1;
        local cur = pCulture:GetSlotPolicy(i);   -- policy row index, -1 if empty
        local curName, curHash = nil, nil;
        if cur ~= nil and cur >= 0 and GameInfo.Policies[cur] ~= nil then
            local prow = GameInfo.Policies[cur];
            curName = L(prow.Name);
            local typeRow = GameInfo.Types and GameInfo.Types[prow.PolicyType] or nil;
            curHash = typeRow and typeRow.Hash or nil;
        end
        slots[#slots + 1] = {
            index       = i,
            label       = base .. " slot " .. tostring(perType[base]),
            slotType    = strSlotType,
            currentName = curName,
            currentHash = curHash,
        };
    end
    return slots;
end

-- Candidate cards legal for a slot, excluding any already staged in an earlier
-- slot. Legality mirrors the vanilla IsPolicyAvailable (not banned, slottable,
-- not obsolete); falls back to unlocked/not-obsolete/not-active when the newer
-- CanPolicyBeSlotted API is absent (matches our CityProduction Pass-4 path). A
-- slot's CURRENT card is active -> excluded here -> retained via Shift+Enter.
local function buildCandidatesForSlot(pCulture, slot, stagedHashes)
    local cands = {};
    if pCulture ~= nil and GameInfo ~= nil and GameInfo.Policies ~= nil then
        for row in GameInfo.Policies() do
            local typeRow = GameInfo.Types and GameInfo.Types[row.PolicyType] or nil;
            local hash = typeRow and typeRow.Hash or nil;
            if hash ~= nil and not stagedHashes[hash]
               and govPolicyFitsSlot(row.GovernmentSlotType, slot.slotType) then
                local legal;
                if pCulture.CanPolicyBeSlotted ~= nil then
                    local ok, v = pcall(function() return pCulture:CanPolicyBeSlotted(hash); end);
                    legal = ok and v or false;
                    if legal and pCulture.IsPolicyBanned ~= nil then
                        local okb, banned = pcall(function() return pCulture:IsPolicyBanned(hash); end);
                        if okb and banned then legal = false; end
                    end
                    if legal and pCulture.IsPolicyObsolete ~= nil then
                        local oko, obs = pcall(function() return pCulture:IsPolicyObsolete(hash); end);
                        if oko and obs then legal = false; end
                    end
                else
                    local unlocked = (pCulture.IsPolicyUnlocked == nil) or pCulture:IsPolicyUnlocked(hash);
                    local obsolete = (pCulture.IsPolicyObsolete ~= nil) and pCulture:IsPolicyObsolete(hash);
                    local active   = (pCulture.IsPolicyActive ~= nil) and pCulture:IsPolicyActive(hash);
                    legal = unlocked and not obsolete and not active;
                end
                if legal then
                    cands[#cands + 1] = {
                        name        = L(row.Name) or row.PolicyType,
                        description = L(row.Description),
                        hash        = hash,
                    };
                end
            end
        end
    end
    cands[#cands + 1] = { name = "Leave empty", empty = true };
    return cands;
end

local function applyPolicyDecisions(pCulture, decisions)
    if pCulture == nil or pCulture.RequestPolicyChanges == nil or decisions == nil then return; end
    -- Full clear-and-reapply (GovernmentScreen OnConfirmPolicies / our Pass 4):
    -- clearList = every slot index; addList[i] = hash for keep/set, omit empty.
    local clearList = {};
    local addList   = {};
    for _, d in ipairs(decisions) do
        clearList[#clearList + 1] = d.index;
        if (d.action == "keep" or d.action == "set") and d.hash ~= nil then
            addList[d.index] = d.hash;
        end
    end
    local ok, err = pcall(function() pCulture:RequestPolicyChanges(clearList, addList); end);
    if not ok then Log.warn("RevealListeners: RequestPolicyChanges failed: " .. tostring(err)); end
    pcall(function() UI.PlaySound("Confirm_Policy"); end);
end

local function ShowPolicyWizard(slots, pCulture, onCommit, onCancel)
    govOpenContext();
    m_govMode = "wizard";
    PolicyWizard.Open({
        slots           = slots,
        buildCandidates = function(slot, staged) return buildCandidatesForSlot(pCulture, slot, staged); end,
        onCommit        = onCommit or function(decisions) applyPolicyDecisions(pCulture, decisions); govCloseContext(); end,
        onCancel        = onCancel or function() govCloseContext(); end,
    });
end

-- ---- Manual-open hub ---------------------------------------------------------
local function currentGovernmentName(pCulture)
    if pCulture == nil or pCulture.GetCurrentGovernment == nil then return nil; end
    -- GetCurrentGovernment returns a GameInfo.Governments row id (-1 = none) —
    -- the exact accessor the vanilla GovernmentScreen uses (line 2250). Earlier
    -- guessed GetGovernmentIndex, which doesn't exist -> always "none".
    local ok, rowId = pcall(function() return pCulture:GetCurrentGovernment(); end);
    if not ok or rowId == nil or rowId < 0 then return nil; end
    local row = GameInfo.Governments[rowId];
    return row and L(row.Name) or nil;
end

local function ShowGovernmentHub()
    govOpenContext();
    m_govMode = "hub";
    local govName = currentGovernmentName(playerCulture());
    govSpeak("Government: " .. (govName or "none")
        .. ". Press G to change government, P to arrange policies, Escape to close.", "critical");
end

local function govHubHandleKey(p)
    if p == nil or p.GetMessageType == nil then return false; end
    if p:GetMessageType() ~= (KeyEvents and KeyEvents.KeyUp or 1) then return false; end
    local key  = p:GetKey();
    local KG   = (Keys and Keys.G) or 0x47;
    local KP   = (Keys and Keys.P) or 0x50;
    local KESC = (Keys and Keys.VK_ESCAPE) or 0x1B;
    if key == KG then
        local options = buildGovernmentOptions(localPlayer());
        if #options == 0 then govSpeak("No governments available.", "selection"); return true; end
        ShowGovernmentChooser(options, nil);
        return true;
    elseif key == KP then
        local pCulture = playerCulture();
        local slots = buildPolicySlots(pCulture);
        if #slots == 0 then govSpeak("No policy slots.", "selection"); return true; end
        ShowPolicyWizard(slots, pCulture, nil, nil);
        return true;
    elseif key == KESC then
        govCloseContext();
        return true;
    end
    return true;   -- hub is modal: swallow everything else
end

-- Dispatch input by mode (assigned to the forward-declared upvalue).
govHandleKey = function(p)
    if m_govMode == "hub" then
        return govHubHandleKey(p);
    elseif m_govMode == "chooser" then
        return ChoosePopupAccess.HandleKey(p);
    elseif m_govMode == "wizard" then
        return PolicyWizard.HandleKey(p);
    end
    return false;
end

-- ---- Deferred raise + live event handlers -----------------------------------
local function OnGovDeferred()
    if ContextPtr ~= nil and ContextPtr.ClearUpdate ~= nil then ContextPtr:ClearUpdate(); end
    local fn = m_govPendingShow;
    m_govPendingShow = nil;
    if fn ~= nil then fn(); end
end

local function govRaise(showFn)
    m_govPendingShow = showFn;
    if ContextPtr ~= nil and ContextPtr.SetUpdate ~= nil then
        if ContextPtr.SetHide ~= nil then ContextPtr:SetHide(false); end   -- hidden contexts get no tick
        ContextPtr:SetUpdate(OnGovDeferred);
    else
        showFn();
    end
end

local function OnOpenGovChooser()
    local options = buildGovernmentOptions(localPlayer());
    if #options == 0 then return; end
    govRaise(function() ShowGovernmentChooser(options, nil); end);
end

local function OnOpenPolicyWizard()
    local pCulture = playerCulture();
    local slots = buildPolicySlots(pCulture);
    if #slots == 0 then return; end
    govRaise(function() ShowPolicyWizard(slots, pCulture, nil, nil); end);
end

local function OnOpenGovHub()
    govRaise(function() ShowGovernmentHub(); end);
end

-- ===========================================================================
--  Debug raisers — same FireTuner commands; no vanilla popup exists, so show
--  immediately (no defer / teardown). Use REAL GameInfo lookups so the name +
--  description-key path is exercised.
-- ===========================================================================
local function firstRow(tbl)
    if GameInfo == nil or GameInfo[tbl] == nil then return nil; end
    for row in GameInfo[tbl]() do return row; end
    return nil;
end

LuaEvents.CivViAccess_DebugRaisePopup.Add(function(name, arg2)
    if name == "Heroes" then
        -- Optional 2nd arg picks a specific hero class for spot-checking
        -- ability/command variety, e.g.
        --   LuaEvents.CivViAccess_DebugRaisePopup("Heroes", "HEROCLASS_WUKONG")
        -- Defaults to Hercules (1 passive + 2 commands — exercises both paths).
        local cls = (arg2 ~= nil and arg2 ~= "" and GameInfo.HeroClasses[arg2])
                    or GameInfo.HeroClasses["HEROCLASS_HERCULES"] or firstRow("HeroClasses");
        ShowReveal(heroOpts(cls, "Hero discovered"), nil);
    elseif name == "SecretSociety" then
        local kDef = GameInfo.SecretSocieties["SECRETSOCIETY_OWLS_OF_MINERVA"] or firstRow("SecretSocieties");
        if kDef ~= nil then
            -- arg2 "joined" exercises the membership-text path; default = discovery.
            local joined = (arg2 == "joined");
            local leadIn = joined and "Secret society joined" or "Secret society discovered";
            ShowReveal(societyOpts(kDef, leadIn, societyGameplay(kDef, joined, true, nil)), nil);
        end
    elseif name == "NaturalDisaster" then
        ShowReveal(disasterOpts(firstRow("RandomEvents"), 0), nil);
    elseif name == "RockBand" then
        -- RockBand ships announce-only (see OnRockBandConcert), so the debug
        -- raise SPEAKS the same announce rather than opening a modal.
        RevealPopupAccess.AnnounceOnly(rockBandOpts("The Debug Band", 2, 42));
    elseif name == "EraComplete" then
        local eras = (Game.GetEras ~= nil) and Game.GetEras() or nil;
        local cur = eras and eras:GetCurrentEra() or 0;
        ShowReveal(eraOpts(cur, localPlayer(), eras), nil);
    elseif name == "Dedication" then
        -- Synthetic smoke test (any game state): first few commemorations, cap 2.
        -- Commit just SPEAKS — these aren't real choices, so don't fire COMMEMORATE.
        local opts = {};
        if GameInfo ~= nil and GameInfo.CommemorationTypes ~= nil then
            local cnt = 0;
            for row in GameInfo.CommemorationTypes() do
                opts[#opts + 1] = {
                    name        = L(row.CategoryDescription) or row.CommemorationType,
                    description = L(row.NormalAgeBonusDescription),
                    data        = row.Index,
                };
                cnt = cnt + 1;
                if cnt >= 5 then break; end
            end
        end
        ShowDedication(opts, 2, function(sel)
            local names = {};
            for _, o in ipairs(sel) do names[#names + 1] = o.name or "?"; end
            if Speech ~= nil and Speech.emit ~= nil then
                Speech.emit("Debug: would commemorate " .. table.concat(names, ", "), "selection");
            end
            CloseDedication();
        end);
    elseif name == "Government" then
        -- Synthetic government chooser (all governments, ignore unlock filter).
        -- Commit just SPEAKS — don't actually change government in a debug raise.
        local options = {};
        if GameInfo ~= nil and GameInfo.Governments ~= nil then
            for row in GameInfo.Governments() do
                local typeRow = GameInfo.Types and GameInfo.Types[row.GovernmentType] or nil;
                options[#options + 1] = {
                    name        = L(row.Name) or row.GovernmentType,
                    description = L(row.InherentBonusDesc),
                    data        = typeRow and typeRow.Hash or 0,
                };
            end
        end
        ShowGovernmentChooser(options, function(opt)
            govSpeak("Debug: would adopt " .. (opt.name or "?"), "selection");
            govCloseContext();
        end);
    elseif name == "Policies" then
        -- Synthetic policy wizard: fake slots + candidates so the slot-walk,
        -- Space-stage, Shift+Enter-keep, Enter-apply, Escape-cancel interaction
        -- is testable in ANY game state. Commit just SPEAKS the decisions.
        local slots = {
            { index = 0, label = "Military slot 1",  slotType = "SLOT_MILITARY", currentName = "Discipline", currentHash = 1 },
            { index = 1, label = "Economic slot 1",  slotType = "SLOT_ECONOMIC", currentName = nil,          currentHash = nil },
            { index = 2, label = "Wildcard slot 1",  slotType = "SLOT_WILDCARD", currentName = "Survey",     currentHash = 2 },
        };
        local fake = {
            SLOT_MILITARY = { { name = "Maneuver",      description = "Plus 100 percent production toward light cavalry.", hash = 11 },
                              { name = "Conscription",  description = "Unit maintenance reduced.",                         hash = 12 } },
            SLOT_ECONOMIC = { { name = "Urban Planning", description = "Plus 1 production in all cities.",                 hash = 21 },
                              { name = "God King",       description = "Plus 1 faith and gold in the Capital.",            hash = 22 } },
            SLOT_WILDCARD = { { name = "Strategos",      description = "Plus 2 great general points.",                     hash = 31 } },
        };
        m_govMode = "wizard";
        govOpenContext();
        PolicyWizard.Open({
            slots = slots,
            buildCandidates = function(slot, staged)
                local out = {};
                for _, c in ipairs(fake[slot.slotType] or {}) do
                    if not staged[c.hash] then out[#out + 1] = c; end
                end
                out[#out + 1] = { name = "Leave empty", empty = true };
                return out;
            end,
            onCommit = function(decisions)
                local parts = {};
                for _, d in ipairs(decisions) do
                    parts[#parts + 1] = d.action .. (d.hash and (" " .. tostring(d.hash)) or "");
                end
                govSpeak("Debug: would commit " .. table.concat(parts, ", "), "selection");
                govCloseContext();
            end,
            onCancel = function() govCloseContext(); end,
        });
    elseif name == "GovHub" then
        ShowGovernmentHub();
    end
end);

-- ===========================================================================
--  DEBUG TEST HOOK — live-path validation (dev-only; inert unless invoked from
--  FireTuner). Kept as the test harness for the not-yet-validated reveals
--  (Secret Society / Disaster / Era); strip once the whole reveal family is done.
-- ---------------------------------------------------------------------------
-- DebugRaisePopup (above) stubs the live plumbing — it calls ShowReveal
-- directly, so there's no real vanilla popup, no one-frame defer, and modality
-- is force-applied. THIS hook instead fires the REAL cross-VM trigger event
-- with a synthetic notification, so the ACTUAL vanilla popup shows AND our
-- listener races it (OnHeroDiscovered -> RaiseLive -> defer -> dequeue vanilla
-- -> our modal on top). That exercises the live path the raisers skip.
--
-- Only LuaEvent-triggered popups can be fired from Lua: Hero + SecretSociety.
-- Disaster / RockBand / EraComplete are engine Events (Events.*) Lua cannot
-- raise — they need a real in-play occurrence. But RaiseLive / dequeue / on-top
-- is SHARED, so proving the Hero race validates the plumbing for all five.
--
-- From the FireTuner console (any state):
--   LuaEvents.CivViAccess_DebugTriggerReal("Hero")
--   LuaEvents.CivViAccess_DebugTriggerReal("Hero", "HEROCLASS_WUKONG")
-- ===========================================================================
local function synthNotification(fields, playerId)
    return {
        GetPlayerID = function() return playerId; end,
        GetValue    = function(_, k) return fields[k]; end,
    };
end

LuaEvents.CivViAccess_DebugTriggerReal.Add(function(name, arg2)
    local lp = localPlayer();
    if lp < 0 then Log.warn("DebugTriggerReal: no local player"); return; end

    if name == "Hero" then
        local cls = (arg2 ~= nil and arg2 ~= "" and GameInfo.HeroClasses[arg2])
                    or GameInfo.HeroClasses["HEROCLASS_HERCULES"] or firstRow("HeroClasses");
        if cls == nil then Log.warn("DebugTriggerReal Hero: no hero class"); return; end

        -- The vanilla HeroesPopup reads the player's hero ORIGIN BUILDING for its
        -- claim-help text; if the test player hasn't built one it may throw there
        -- (logged, harmless to us — our modal still shows). Warn so it's labeled.
        local pGH = (Game.GetHeroesManager ~= nil) and Game.GetHeroesManager() or nil;
        local ob  = (pGH ~= nil and pGH.GetPlayerHeroOriginBuildingType ~= nil)
                    and pGH:GetPlayerHeroOriginBuildingType(lp) or -1;
        if ob == nil or ob < 0 or GameInfo.Buildings[ob] == nil then
            Log.warn("DebugTriggerReal Hero: player " .. lp .. " has NO hero origin building"
                     .. " — the VANILLA popup may throw on claim-help; our modal still shows.");
        end

        Log.info("DebugTriggerReal: firing REAL NotificationPanel_HeroDiscovered for " .. tostring(cls.HeroClassType));
        LuaEvents.NotificationPanel_HeroDiscovered(synthNotification(
            { HERO_CLASS = cls.Index, PARAM_SUB_TYPE = 0, PARAM_TARGET0 = 0 }, lp));

    elseif name == "SecretSociety" then
        local soc = (arg2 ~= nil and arg2 ~= "" and GameInfo.SecretSocieties[arg2])
                    or GameInfo.SecretSocieties["SECRETSOCIETY_OWLS_OF_MINERVA"] or firstRow("SecretSocieties");
        if soc == nil then Log.warn("DebugTriggerReal SecretSociety: no society"); return; end
        Log.info("DebugTriggerReal: firing REAL NotificationPanel_SecretSocietyDiscovered for " .. tostring(soc.SecretSocietyType));
        LuaEvents.NotificationPanel_SecretSocietyDiscovered(synthNotification(
            { PARAM_DATA0 = lp, PARAM_DATA1 = soc.Index }, lp));

    else
        Log.warn("DebugTriggerReal: '" .. tostring(name)
                 .. "' is an engine Event (Disaster/RockBand/Era) — Lua can't raise it; needs a real in-play occurrence.");
    end
end);

-- ===========================================================================
--  DEBUG: PERFORM a rock-band concert from THIS (UI) VM.
--  SPLIT-VM (root-caused 2026-05-31): unit CREATION (InitUnit*) lives only in
--  the GameCore VM; operation REQUESTS (RequestOperation/UnitOperationTypes)
--  live only HERE (this UI VM — the same calls UnitMovement.lua uses for
--  MOVE_TO). So the two halves are split: DebugConcert.lua (gameplay VM) spawns
--  a UNIT_ROCK_BAND if none exists; THIS hook performs the concert. No cross-VM
--  messaging — the band gameplay spawns on turn N is findable here on turn N+1.
--  Valid target plots come from the rock band's own GetActivationHighlightPlots
--  (the same source the vanilla SelectedUnit_Expansion2 highlights for the
--  player). Latches after one concert is requested. Debug-only.
-- ===========================================================================
local m_concertDone = false;

-- Operation / param hash WITHOUT the UnitOperationTypes enum. That enum is
-- absent in THIS context (the warn fired 2026-05-31 although RequestOperation
-- exists here — UnitMovement.lua has the enum because it runs in a DIFFERENT UI
-- context, HexCursorAddin; bindings are per-context). Three fallbacks, most
-- reliable first:
--   1. GameInfo.UnitOperations[name].Hash — GameInfo is confirmed present here
--      (we use GameInfo.Units in this file). UnitPanel.lua:232 uses exactly this.
--      (operations only; PARAM_* are not GameInfo rows.)
--   2. the UnitOperationTypes enum, if this context happens to have it.
--   3. DB.MakeHash(name) — how the base game hashes names (ActionPanel.lua).
-- RequestOperation accepts a raw hash, so any of these works.
local function opHash(name, enumKey, gameInfoTable)
    if gameInfoTable ~= nil and GameInfo ~= nil and GameInfo[gameInfoTable] ~= nil then
        local row = GameInfo[gameInfoTable][name];
        if row ~= nil and row.Hash ~= nil then return row.Hash; end
    end
    if UnitOperationTypes ~= nil and UnitOperationTypes[enumKey] ~= nil then
        return UnitOperationTypes[enumKey];
    end
    if DB ~= nil and DB.MakeHash ~= nil then
        return DB.MakeHash(name);
    end
    return nil;
end

-- ALL rock bands the player owns (the old spawn-every-turn bug scattered several
-- at varying distances; we must check each for a valid concert target, not just
-- the first). Type resolved via GetUnitType OR GetType (varies by VM).
local function dbgFindRockBands(pPlayer)
    local out = {};
    if pPlayer == nil or pPlayer.GetUnits == nil then return out; end
    local pUnits = pPlayer:GetUnits();
    if pUnits == nil then return out; end
    for _, u in pUnits:Members() do
        if u ~= nil then
            local t = (u.GetUnitType and u:GetUnitType()) or (u.GetType and u:GetType());
            local row = (t ~= nil and GameInfo ~= nil and GameInfo.Units) and GameInfo.Units[t] or nil;
            if row ~= nil and row.UnitType == "UNIT_ROCK_BAND" then out[#out + 1] = u; end
        end
    end
    return out;
end

-- First activation (concert-target) plot for a band; nil if it has none (not
-- adjacent to a valid foreign city). Returns (x, y, count).
local function bandActivationPlot(band)
    local rb = band.GetRockBand and band:GetRockBand() or nil;
    if rb == nil or rb.GetActivationHighlightPlots == nil then return nil, nil, nil; end
    local plots = rb:GetActivationHighlightPlots();
    local n = (plots ~= nil) and #plots or 0;
    if n > 0 and Map ~= nil and Map.GetPlotByIndex ~= nil then
        local p = Map.GetPlotByIndex(plots[1]);
        if p ~= nil then return p:GetX(), p:GetY(), n; end
    end
    return nil, nil, n;
end

-- Nearest city NOT owned by lp, to (bx,by). Returns (cx,cy) or nil. Gameplay
-- API sees through fog. Used by the auto-walk fallback.
local function uiNearestForeignCity(lp, bx, by)
    local bestX, bestY, bestD = nil, nil, nil;
    for i = 0, 63 do
        local p = Players ~= nil and Players[i] or nil;
        if p ~= nil and i ~= lp and (p.IsAlive == nil or p:IsAlive()) and p.GetCities ~= nil then
            local cs = p:GetCities();
            if cs ~= nil then
                for _, c in cs:Members() do
                    if c ~= nil then
                        local cx, cy = c:GetX(), c:GetY();
                        local d = (Map ~= nil and Map.GetPlotDistance)
                                  and Map.GetPlotDistance(bx, by, cx, cy)
                                  or (math.abs(cx - bx) + math.abs(cy - by));
                        if bestD == nil or d < bestD then bestX, bestY, bestD = cx, cy, d; end
                    end
                end
            end
        end
    end
    return bestX, bestY;
end

-- A passable land hex adjacent to city (cx,cy), nearest to (fromX,fromY) so the
-- walk path is shortest. Can't MOVE_TO the city center (foreign tile, no-ops);
-- a band must stand ADJACENT to concert anyway. Returns (x,y) or nil.
local function uiAdjacentPassableHex(cx, cy, fromX, fromY)
    if Map == nil or Map.GetAdjacentPlot == nil then return nil; end
    local ndir = (DirectionTypes ~= nil and DirectionTypes.NUM_DIRECTION_TYPES) or 6;
    local bestX, bestY, bestD = nil, nil, nil;
    for dir = 0, ndir - 1 do
        local p = Map.GetAdjacentPlot(cx, cy, dir);
        if p ~= nil then
            local water = (p.IsWater ~= nil) and p:IsWater() or false;
            local impassable = (p.IsImpassable ~= nil) and p:IsImpassable() or false;
            if not water and not impassable then
                local px, py = p:GetX(), p:GetY();
                local d = (Map.GetPlotDistance ~= nil)
                          and Map.GetPlotDistance(px, py, fromX, fromY)
                          or (math.abs(px - fromX) + math.abs(py - fromY));
                if bestD == nil or d < bestD then bestX, bestY, bestD = px, py, d; end
            end
        end
    end
    return bestX, bestY;
end

-- OFF by default (2026-05-31): this debug hook hunts for ANY rock band on every
-- turn-begin and would hijack a REAL rock band during normal play. The concert
-- pipeline is engine-validated (CanStartOperation=true); flip both this and
-- DebugConcert.lua's DEBUG_CONCERT_ENABLED to true (then relaunch) to re-run the
-- test rig. Paired with DebugConcert's gameplay-side spawn.
local DEBUG_CONCERT_PERFORM = false;

local function dbgPerformConcert()
    if not DEBUG_CONCERT_PERFORM then return; end
    if m_concertDone then return; end
    -- One decisive diagnostic line: which pieces exist in THIS context.
    Log.info("concert UI: ReqOp=" .. tostring(UnitManager ~= nil and UnitManager.RequestOperation ~= nil)
        .. " UOT=" .. tostring(UnitOperationTypes ~= nil)
        .. " DB.MakeHash=" .. tostring(DB ~= nil and DB.MakeHash ~= nil));
    if UnitManager == nil or UnitManager.RequestOperation == nil then
        Log.warn("concert UI: UnitManager.RequestOperation unavailable in this context"); return;
    end
    local hOp = opHash("UNITOPERATION_TOURISM_BOMB", "TOURISM_BOMB", "UnitOperations");
    local hX  = opHash("PARAM_X", "PARAM_X", nil);   -- params: GameInfo has no row, use enum/MakeHash
    local hY  = opHash("PARAM_Y", "PARAM_Y", nil);
    if hOp == nil or hX == nil or hY == nil then
        Log.warn("concert UI: cannot resolve hashes (hOp=" .. tostring(hOp)
                 .. " hX=" .. tostring(hX) .. " hY=" .. tostring(hY) .. ")"); return;
    end

    local lp = localPlayer();
    local pPlayer = Players ~= nil and Players[lp] or nil;
    if pPlayer == nil then return; end
    local bands = dbgFindRockBands(pPlayer);
    if #bands == 0 then
        Log.info("concert UI: no rock band yet (gameplay spawns one; will retry next turn-begin)"); return;
    end
    Log.info("concert UI: " .. #bands .. " rock band(s) owned; scanning for one with a valid concert target");

    -- Pick the first band that actually has an activation (concert-target) plot.
    local band, tx, ty = nil, nil, nil;
    for _, b in ipairs(bands) do
        local x, y, n = bandActivationPlot(b);
        Log.info("concert UI:   band id=" .. tostring(b:GetID()) .. " at (" .. b:GetX() .. "," .. b:GetY()
                 .. ") activationPlots=" .. tostring(n));
        if x ~= nil then band, tx, ty = b, x, y; break; end
    end
    if band == nil then
        -- DECISIVE DIAGNOSTIC (2026-05-31): no band has activation plots yet.
        -- Single driver now (gameplay hands off). Log moves + exact distance to
        -- the nearest foreign city, then either WAIT (adjacent, capture why plots
        -- are 0) or WALK (not adjacent, only if it has moves).
        local b = bands[1];
        local bx, by = b:GetX(), b:GetY();
        local moves = (b.GetMovesRemaining and b:GetMovesRemaining()) or -1;
        local cx, cy = uiNearestForeignCity(lp, bx, by);
        if cx == nil then Log.warn("concert UI: no foreign city to walk toward"); return; end
        local distToCity = (Map ~= nil and Map.GetPlotDistance)
                           and Map.GetPlotDistance(bx, by, cx, cy)
                           or (math.abs(cx - bx) + math.abs(cy - by));
        Log.info("concert UI: DIAG band (" .. bx .. "," .. by .. ") moves=" .. tostring(moves)
                 .. " nearestCity (" .. cx .. "," .. cy .. ") distToCity=" .. tostring(distToCity));

        -- ADJACENT to the city (dist 1): the band is in position. Capture WHY the
        -- concert won't fire — moves, CanStartOperation verdict, raw plot count.
        if distToCity <= 1 then
            local rawN = -1;
            pcall(function()
                local rb = b.GetRockBand and b:GetRockBand() or nil;
                if rb ~= nil and rb.GetActivationHighlightPlots ~= nil then
                    local pl = rb:GetActivationHighlightPlots();
                    rawN = (pl ~= nil) and #pl or -2;
                end
            end);
            local hOp2 = opHash("UNITOPERATION_TOURISM_BOMB", "TOURISM_BOMB", "UnitOperations");
            local canDo = "n/a";
            if UnitManager.CanStartOperation ~= nil and hOp2 ~= nil then
                pcall(function()
                    canDo = tostring(UnitManager.CanStartOperation(b, hOp2, nil, true));
                end);
            end
            Log.info("concert UI: DIAG ADJACENT — rawActivationPlots=" .. tostring(rawN)
                     .. " CanStartOperation(TOURISM_BOMB)=" .. canDo .. " moves=" .. tostring(moves));
            -- Try performing AT the city center directly (the activation target is
            -- the city tile). If CanStart says yes OR we just try anyway:
            if hOp2 ~= nil then
                local tp = {}; tp[hX] = cx; tp[hY] = cy;
                UnitManager.RequestOperation(b, hOp2, tp);
                Log.info("concert UI: DIAG attempted TOURISM_BOMB at city (" .. cx .. "," .. cy
                         .. ") directly — watch for PostTourismBomb");
            end
            return;
        end

        -- NOT adjacent. Only walk if it has moves; else wait (out of moves =
        -- can't move OR perform this turn; fresh moves next turn-begin).
        if moves ~= nil and moves <= 0 then
            Log.info("concert UI: band out of moves (=" .. tostring(moves) .. "), waiting for next turn");
            return;
        end
        local dgx, dgy = uiAdjacentPassableHex(cx, cy, bx, by);
        if dgx == nil then Log.warn("concert UI: no passable hex adjacent to city (" .. cx .. "," .. cy .. ")"); return; end
        local hMove = opHash("UNITOPERATION_MOVE_TO", "MOVE_TO", "UnitOperations");
        if hMove == nil then Log.warn("concert UI: MOVE_TO hash unavailable"); return; end
        local mp = {}; mp[hX] = dgx; mp[hY] = dgy;
        if UnitOperationMoveModifiers ~= nil and UnitOperationMoveModifiers.NONE ~= nil then
            local hMod = opHash("PARAM_MODIFIERS", "PARAM_MODIFIERS", nil);
            if hMod ~= nil then mp[hMod] = UnitOperationMoveModifiers.NONE; end
        end
        UnitManager.RequestOperation(b, hMove, mp);
        Log.info("concert UI: auto-walk MOVE_TO city-adjacent (" .. dgx .. "," .. dgy
                 .. ") from (" .. bx .. "," .. by .. "); city (" .. cx .. "," .. cy .. ")");
        if Speech ~= nil and Speech.emit ~= nil then
            Speech.emit("Rock band moving toward city", "event");
        end
        return;
    end
    Log.info("concert UI: using band id=" .. tostring(band:GetID()) .. ", concert target (" .. tx .. "," .. ty .. ")");

    if UnitManager.CanStartOperation ~= nil then
        pcall(function()
            Log.info("concert UI: CanStartOperation(TOURISM_BOMB)="
                     .. tostring(UnitManager.CanStartOperation(band, hOp, nil, true)));
        end);
    end
    local tParameters = {};
    tParameters[hX] = tx;
    tParameters[hY] = ty;
    UnitManager.RequestOperation(band, hOp, tParameters);
    m_concertDone = true;
    Log.info("concert UI: requested TOURISM_BOMB at (" .. tx .. "," .. ty .. ") — watch for PostTourismBomb / the gate");
end

-- ===========================================================================
--  Init
-- ===========================================================================
function Initialize()
    if ContextPtr ~= nil and ContextPtr.SetInputHandler ~= nil then
        ContextPtr:SetInputHandler(onInput, true);
    end
    if ContextPtr ~= nil and ContextPtr.SetHide ~= nil then
        ContextPtr:SetHide(true);
    end
    -- Heroes & Secret Societies events are LuaEvents (cross-VM); the others are
    -- engine Events. Each table may be absent if the mode/expansion is off.
    if LuaEvents ~= nil then
        if LuaEvents.NotificationPanel_HeroDiscovered ~= nil then LuaEvents.NotificationPanel_HeroDiscovered.Add(OnHeroDiscovered); end
        if LuaEvents.NotificationPanel_HeroExpired ~= nil then LuaEvents.NotificationPanel_HeroExpired.Add(OnHeroExpired); end
        if LuaEvents.NotificationPanel_SecretSocietyDiscovered ~= nil then LuaEvents.NotificationPanel_SecretSocietyDiscovered.Add(OnSecretSocietyDiscovered); end
        if LuaEvents.NotificationPanel_SecretSocietyJoined ~= nil then LuaEvents.NotificationPanel_SecretSocietyJoined.Add(OnSecretSocietyJoined); end
        -- Dedication (commemoration) chooser — first un-shadowable CHOICE popup.
        if LuaEvents.EraReviewPopup_MakeDedication ~= nil then LuaEvents.EraReviewPopup_MakeDedication.Add(OnMakeDedication); end
        -- Government: type chooser (Open Governments), policy wizard (Open
        -- Policies), and the manual-open hub (Open My Government). Same events
        -- the vanilla GovernmentScreen uses; we subscribe first and intercept.
        if LuaEvents.LaunchBar_GovernmentOpenGovernments ~= nil then LuaEvents.LaunchBar_GovernmentOpenGovernments.Add(OnOpenGovChooser); end
        if LuaEvents.NotificationPanel_GovernmentOpenGovernments ~= nil then LuaEvents.NotificationPanel_GovernmentOpenGovernments.Add(OnOpenGovChooser); end
        if LuaEvents.TechCivicCompletedPopup_GovernmentOpenGovernments ~= nil then LuaEvents.TechCivicCompletedPopup_GovernmentOpenGovernments.Add(OnOpenGovChooser); end
        if LuaEvents.NotificationPanel_GovernmentOpenPolicies ~= nil then LuaEvents.NotificationPanel_GovernmentOpenPolicies.Add(OnOpenPolicyWizard); end
        if LuaEvents.TechCivicCompletedPopup_GovernmentOpenPolicies ~= nil then LuaEvents.TechCivicCompletedPopup_GovernmentOpenPolicies.Add(OnOpenPolicyWizard); end
        if LuaEvents.LaunchBar_GovernmentOpenMyGovernment ~= nil then LuaEvents.LaunchBar_GovernmentOpenMyGovernment.Add(OnOpenGovHub); end
    end
    if Events ~= nil then
        if Events.RandomEventOccurred ~= nil then Events.RandomEventOccurred.Add(OnRandomEventOccurred); end
        if Events.PostTourismBomb ~= nil then Events.PostTourismBomb.Add(OnRockBandConcert); end
        if Events.PlayerEraChanged ~= nil then Events.PlayerEraChanged.Add(OnPlayerEraChanged); end
        if Events.LoadGameViewStateDone ~= nil then Events.LoadGameViewStateDone.Add(OnLoadGameViewStateDone); end
        -- DEBUG concert-perform hook (UI VM half of the split-VM rock-band test).
        if Events.LocalPlayerTurnBegin ~= nil then
            Events.LocalPlayerTurnBegin.Add(dbgPerformConcert);
            Log.info("RevealListeners: debug concert-perform armed on LocalPlayerTurnBegin (UI VM)");
        end
    end
    -- Tier-1 spatial awareness: fog-reveal summary. Hosted here because this is
    -- the live InGame UI-VM addin and PlotVisibilityChanged is UI-side. Separate
    -- module (RevealAnnounce.lua) for separation of concern; we just init it.
    if RevealAnnounce ~= nil and RevealAnnounce.Initialize ~= nil then
        local ok, err = pcall(RevealAnnounce.Initialize);
        if not ok then Log.warn("RevealAnnounce.Initialize failed: " .. tostring(err)); end
    end
    -- THROWAWAY: spatial-design probe (strip before release).
    if BoardQueryProbe ~= nil and BoardQueryProbe.Initialize ~= nil then
        local ok, err = pcall(BoardQueryProbe.Initialize);
        if not ok then Log.warn("BoardQueryProbe.Initialize failed: " .. tostring(err)); end
    end
    Log.info("RevealListeners.lua: loaded; modal reveal window + event subscriptions ready");
end
Initialize();
