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

local function societyOpts(kSocietyDef, leadIn, descKey)
    if kSocietyDef == nil then return nil; end
    local key  = "LOC_CIVVIACCESS_SS_" .. tostring(kSocietyDef.SecretSocietyType);
    local long = locOrNil(key .. "_LONG");
    setLastLong(long);
    return {
        leadIn   = leadIn,
        name     = L(kSocietyDef.Name),
        gameplay = locOrNil(descKey),
        short    = locOrNil(key .. "_SHORT"),
        long     = long,
        typeNoun = "secret society",
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

local function rockBandOpts(bandName, totalTourism)
    setLastLong(nil);
    local gameplay = nil;
    if totalTourism ~= nil and totalTourism > 0 then
        gameplay = tostring(totalTourism) .. " tourism gained";
    end
    return {
        leadIn   = "Rock band concert",
        name     = bandName,
        gameplay = gameplay,
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
    RaiseLive(societyOpts(kDef, "Secret society discovered", kDef.DiscoveryText), "/InGame/SecretSocietyPopup");
end

local function OnSecretSocietyJoined(pNotification)
    if pNotification == nil or pNotification:GetValue("PARAM_DATA0") ~= localPlayer() then return; end
    local eSociety = pNotification:GetValue("PARAM_DATA1");
    local kDef = eSociety and GameInfo.SecretSocieties[eSociety] or nil;
    if kDef == nil then return; end
    RaiseLive(societyOpts(kDef, "Secret society joined", kDef.MembershipText), "/InGame/SecretSocietyPopup");
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
    local pPlayer = Players and Players[lp] or nil;
    if pPlayer == nil then return; end
    local bandName = nil;
    local pUnits = pPlayer.GetUnits and pPlayer:GetUnits() or nil;
    local pUnit = pUnits and pUnits:FindID(unitID) or nil;
    if pUnit ~= nil and pUnit.GetName then bandName = pUnit:GetName(); end
    RaiseLive(rockBandOpts(bandName, totalTourism), "/InGame/RockBandMoviePopup");
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
        if kDef ~= nil then ShowReveal(societyOpts(kDef, "Secret society discovered", kDef.DiscoveryText), nil); end
    elseif name == "NaturalDisaster" then
        ShowReveal(disasterOpts(firstRow("RandomEvents"), 0), nil);
    elseif name == "RockBand" then
        ShowReveal(rockBandOpts("The Debug Band", 42), nil);
    elseif name == "EraComplete" then
        local eras = (Game.GetEras ~= nil) and Game.GetEras() or nil;
        local cur = eras and eras:GetCurrentEra() or 0;
        ShowReveal(eraOpts(cur, localPlayer(), eras), nil);
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
    end
    if Events ~= nil then
        if Events.RandomEventOccurred ~= nil then Events.RandomEventOccurred.Add(OnRandomEventOccurred); end
        if Events.PostTourismBomb ~= nil then Events.PostTourismBomb.Add(OnRockBandConcert); end
        if Events.PlayerEraChanged ~= nil then Events.PlayerEraChanged.Add(OnPlayerEraChanged); end
        if Events.LoadGameViewStateDone ~= nil then Events.LoadGameViewStateDone.Add(OnLoadGameViewStateDone); end
    end
    Log.info("RevealListeners.lua: loaded; modal reveal window + event subscriptions ready");
end
Initialize();
