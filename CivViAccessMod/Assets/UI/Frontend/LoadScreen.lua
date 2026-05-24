-- ===========================================================================
--
--	Loading screen as player goes from shell to game state.
--
--	Civ VI Access shadow — wraps the engine version with screen-reader
--	briefing + early input handler. See
--	docs/flow-trace/04-loading-screen.md and
--	Accessibility/LoadScreenAccess.lua.
--
--	Edits from the Firaxis original:
--	  1. include("LoadScreenAccess") at the top
--	  2. ContextPtr:SetInputHandler installed in Initialize (not
--	     deferred to OnLoadGameViewStateDone). The engine deferred it
--	     to avoid "engine makes LUA calls during load" — but that's
--	     why blind players are locked listening to Sean Bean: Esc
--	     never reaches the handler before load completes. We install
--	     early and route through LoadScreenAccess.HandleKey first.
--	  3. ShouldPlayDawnOfMan gate around UI.PlaySound("Play_DawnOfMan_Speech")
--	     so the briefing speaks first; user opts in via Enter.
--	  4. NotifyContentReady call at end of OnLoadScreenContentReady
--	     to hand off briefing data.
--	  5. NotifyLoadComplete call at end of OnLoadGameViewStateDone.
--
-- ===========================================================================

include( "InputSupport" );
include( "InstanceManager" );
include( "SupportFunctions" );
include( "Civ6Common" );
include( "Colors") ;
include( "LoadScreenAccess" );

-- ===========================================================================
--	Action Hotkeys
-- ===========================================================================
local m_actionHotkeyStartGame		:number = Input.GetActionId("StartGame");
local m_actionHotkeyStartGameAlt	:number = Input.GetActionId("StartGameAlt");



-- ===========================================================================
--	CONSTANTS
-- ===========================================================================

local DARKEN_AMOUNT			:number = -25;
local MIN_BLACK_Y			:number = 2;	-- Minimum size for black boxes on row bars
local SIZE_BUILDING_ICON	:number = 32;
local SIZE_CIV_LOGO_ICON	:number = 256;	-- Size of the logo in the background
local SIZE_UNIT_ICON		:number = 32;
local TIMEOUT_LOAD			:number = 1000;	-- # of frames before a timeout occurs obtaining player data for load screen


-- ===========================================================================
--	MEMBERS / VARIABLES
-- ===========================================================================
local m_isLoadComplete				:boolean = false;
local m_isResyncLoad				:boolean = false;
local m_isTraitsFullDescriptions	:boolean = false;



-- ===========================================================================
--	FUNCTIONS
-- ===========================================================================

-- ===========================================================================
function OnActivateButtonClicked()
	Controls.BackgroundImage:UnloadTexture();
	Controls.Portrait:UnloadTexture();
	Events.LoadScreenClose();
	UI.PlaySound("STOP_SPEECH_DAWNOFMAN");
	UI.StartStopMenuMusic(false);
	UI.PlaySound("Game_Begin_Button_Click");
	UI.PlaySound("Set_View_3D");
	UIManager:DequeuePopup( ContextPtr );

	Input.SetActiveContext( InputContext.World );

	if(UILens.IsPlayerLensSetToActive()) then
		UILens.SetActive("Default");
	end

    UI.SetExitOnClose(false);

	-- In PlayByCloud, we should trigger another cloud notification check now.
	-- This will ensure the player gets a notification for the next cloud match so they can daisy chain all their turns quickly.
	if(GameConfiguration.IsPlayByCloud()) then
		local kandoConnected = FiraxisLive.IsFiraxisLiveLoggedIn();
		if(kandoConnected) then
			FiraxisLive.CheckForCloudNotifications();
		end
	end
end

-- ===========================================================================
--	Input Processing
-- ===========================================================================
function OnInput( uiMsg, wParam, lParam )
    -- Civ VI Access first: Ctrl+T/I/S, Enter/Space pre-load (start
    -- Sean Bean), Esc skip (works pre-load AND post-load).
    if LoadScreenAccess ~= nil and LoadScreenAccess.HandleKey ~= nil then
        if LoadScreenAccess.HandleKey(uiMsg, wParam, lParam) then
            return true;
        end
    end

    if uiMsg == KeyEvents.KeyUp then
        if wParam == Keys.VK_ESCAPE then
			if m_isLoadComplete then
				OnActivateButtonClicked();
				return true;
			end
        end
    end
    return false;	-- Don't consume all; let hotkey action system get a crack
end

-- ===========================================================================
--	Hotkey
-- ===========================================================================
function OnInputActionTriggered( actionId:number )
	if	actionId == m_actionHotkeyStartGame		or
		actionId == m_actionHotkeyStartGameAlt	then
		if m_isLoadComplete then
			OnActivateButtonClicked();
		end
	end

end

-- ===========================================================================
function RegisterButtonCallbacks()
	Controls.ActivateButton:RegisterCallback( Mouse.eMouseEnter, function() UI.PlaySound("Main_Menu_Mouse_Over"); end );
	Controls.ActivateButton:RegisterCallback( Mouse.eLClick, OnActivateButtonClicked );
	Controls.StartLabelButton:RegisterCallback( Mouse.eLClick, OnActivateButtonClicked );
end

-- ===========================================================================
function ClearButtonCallbacks()
	Controls.ActivateButton:ClearCallback( Mouse.eLClick );
	Controls.ActivateButton:ClearCallback( Mouse.eMouseEnter );
	Controls.StartLabelButton:ClearCallback( Mouse.eLClick );
end

-- ===========================================================================
--	UI Event
-- ===========================================================================
function OnShow()

	m_isLoadComplete	= false;
	m_isResyncLoad		= UI.IsResyncLoadInProgress(); -- Remember if this is a resync load for later.

	-- Civ VI Access hand-off: announce "Creating game" early so the
	-- player knows the load sequence started, even before briefing
	-- data is resolved (which can take a few seconds for map gen).
	if LoadScreenAccess ~= nil and LoadScreenAccess.NotifyShowing ~= nil then
		LoadScreenAccess.NotifyShowing();
	end

	UIManager:SetUICursor( 1 );
	Controls.FadeAnim:SetToBeginning();
	Controls.ActivateButton:SetHide(true);
	Controls.LoadingContainer:SetHide(false);

	-- Wait until game configuration data is ready before showing anything.
	Controls.BackgroundImage:SetHide(true);
	Controls.Banner:SetHide(true);
	Controls.Portrait:SetHide(true);

	-- Clear button callbacks until loading is complete.
	ClearButtonCallbacks();

	-- Signal to a potentially raised state transition context that we're up (so it can hide).
	LuaEvents.Lower_State_Transition("LoadScreen");
end

-- ===========================================================================
--	UI Event
-- ===========================================================================
function OnHide()
	UIManager:SetUICursor( 0 );
end

-- ===========================================================================
function OnInit( isReload:boolean )
	if isReload then
		OnShow();
		OnLoadScreenContentReady();
		OnLoadGameViewStateDone();
	end
end

-- ===========================================================================
--	All game data exists for the player in order to fill out the screen.
--	Do it...
-- ===========================================================================
function OnLoadScreenContentReady()

	if (GameConfiguration:IsWorldBuilderEditor()) then
		-- This needs to show some kind of World Builder splash screen.
		-- It can't show leaders, etc., they may not be initialized.
		return;
	end

	-- Because Game.GetLocalPlayer() not servicing yet use the network flavor;
	-- if in a hotseat mode the first slot may not be set to the human.
	local localPlayer	:number = Network.GetLocalPlayerID();
	if GameConfiguration.IsHotseat() then

		local maxPlayers :number = MapConfiguration.GetMaxMajorPlayers();
		for playerID = 0, maxPlayers-1,1 do
			local pPlayerConfig :table	= PlayerConfigurations[playerID];
			local slotStatus	:number = pPlayerConfig:GetSlotStatus();

			-- Potentially change the localPlayer number to the first human
			-- player in a slot.
			if slotStatus == SlotStatus.SS_TAKEN then
				localPlayer = playerID;
				break;
			end
		end
	end

	local primaryColor, secondaryColor  = UI.GetPlayerColors( localPlayer );

	if primaryColor == nil then
		primaryColor = UI.GetColorValueFromHexLiteral(0xff99aaaa);
		UI.DataError("NIL primary color; likely player object not ready... using default color.");
	end
	if secondaryColor == nil then
		secondaryColor = UI.GetColorValueFromHexLiteral(0xffaa9999);
		UI.DataError("NIL secondary color; likely player object not ready... using default color.");
	end

	local backColor						= UI.DarkenLightenColor(primaryColor, DARKEN_AMOUNT, 255);
	Controls.Banner:SetColor(backColor);

	-- Civ VI Access: stash briefing context as we resolve it, hand off
	-- at the end of this function.
	local accessCtx = {
		leaderType    = nil,
		civType       = nil,
		civDisplay    = "",
		leaderDisplay = "",
		eraName       = "",
		leaderInfoText = "",
		leaderInfoKey  = nil,
		challengeName  = nil,
		challengeInfo  = nil,
	};

	local playerConfig		:table = PlayerConfigurations[localPlayer];
	if playerConfig == nil then
		UI.DataError("Received NIL playerConfig for player #"..tostring(localPlayer));
	else
		local backgroundTexture:string;
		local leaderType:string = playerConfig:GetLeaderTypeName();
		accessCtx.leaderType = leaderType;
		local loadingInfo:table = GameInfo.LoadingInfo[leaderType];
		if loadingInfo and loadingInfo.BackgroundImage then
			backgroundTexture = loadingInfo.BackgroundImage;
		else
			backgroundTexture = leaderType .. "_BACKGROUND";
		end

		Controls.BackgroundImage:SetTexture( backgroundTexture );
		if (not Controls.BackgroundImage:HasTexture()) then
			UI.DataError("Failed to load background image texture: "..backgroundTexture);
			Controls.BackgroundImage:SetTexture("LEADER_T_ROOSEVELT_BACKGROUND");	-- Set to well known texture
		end

		-- fix 720P
		if (Controls.Background:GetSizeY() < 768) then
			Controls.Banner:SetSizeY(920);
			Controls.MainStack:SetOffsetY(20);
		else
			Controls.Banner:SetSizeY(987);
			Controls.MainStack:SetOffsetY(0);
		end

		local LEADER_CONTAINER_X = 512;
		local offsetX = math.floor((Controls.Portrait:GetSizeX() - LEADER_CONTAINER_X)/2);
		if (offsetX > 0) then
			Controls.Portrait:SetOffsetX(offsetX);
		else
			Controls.Portrait:SetOffsetX(0);
		end

		local portraitName:string;
		if loadingInfo and loadingInfo.ForegroundImage then
			portraitName = loadingInfo.ForegroundImage;
		else
			portraitName = leaderType .. "_NEUTRAL";
		end

		Controls.Portrait:SetTexture( portraitName );
		if (not Controls.Portrait:HasTexture()) then
			UI.DataError("We are lacking a texture for "..portraitName);
		end
		local civDescription = Locale.Lookup(playerConfig:GetCivilizationDescription());
		Controls.CivName:SetText( Locale.ToUpper( civDescription ) );
		accessCtx.civDisplay = civDescription;
		accessCtx.civType    = playerConfig:GetCivilizationTypeName();


		local eraInfoText;
		local leaderInfoText;

		local startEra = GameInfo.Eras[ GameConfiguration.GetStartEra() ];
		if (GameConfiguration.IsSavedGame()) then
			-- Returns a list of 1 entry...
			local metaData = UI.GetSaveGameMetaData();
			if(metaData and #metaData == 1) then
				local item = metaData[1];
				local saveEra = GameInfo.Eras[ item.HostEra ];
				if(saveEra) then
					startEra = saveEra;
				end
			end
		end

		if (startEra ~= nil) then
			eraInfoText = startEra.Description;
			-- Briefing uses Name (e.g. "Ancient Era") not Description
			-- (which is a 100-word flavor paragraph). The visual UI
			-- shows Description; the screen-reader briefing wants the
			-- short version. Lookup against Name; fall back to
			-- EraType-derived label if Name unavailable.
			accessCtx.eraName = safeLookupOrNil(startEra.Name);
			if accessCtx.eraName == "" or accessCtx.eraName == nil then
				accessCtx.eraName = tostring(startEra.EraType or "");
			end
		end

		local challengeName;
		local challengeInfoText;

		local isChallengeActive = Challenges.IsChallengeActive();
		if isChallengeActive then
			challengeName = Challenges.GetLocalizedChallengeNameText();
			challengeInfoText = Challenges.GetLocalizedChallengeLoadingScreenDescriptionText();
			accessCtx.challengeName = challengeName;
			accessCtx.challengeInfo = challengeInfoText;
		end

		local kLeader	:table = GameInfo.Leaders[leaderType];
		local leaderName;
		if kLeader ~= nil then
			leaderName = Locale.ToUpper(Locale.Lookup( kLeader.Name ));
			accessCtx.leaderDisplay = Locale.Lookup( kLeader.Name );

			local details = "LOC_LOADING_INFO_" .. leaderType;
			if(Locale.HasTextKey(details)) then
				leaderInfoText = details;
				accessCtx.leaderInfoKey = details;
				accessCtx.leaderInfoText = Locale.Lookup(details);
			end
		else
			UI.DataError("No leader in DB by leaderType '"..leaderType.."'");
		end

		if(challengeName) then
			Controls.LeaderName:SetText(challengeName);
		elseif(leaderName) then
			Controls.LeaderName:SetText(leaderName);
		else
			UI.DataError("No proper text for the LeaderName field");
		end

		if(loadingInfo) then
			if(loadingInfo.EraText) then
				eraInfoText = loadingInfo.EraText;
				-- LoadingInfo.EraText is typically a description-style
				-- LOC, not a short name. Keep our Name-based eraName
				-- from above; do not overwrite with the description.
			end

			if(loadingInfo.LeaderText) then
				leaderInfoText = loadingInfo.LeaderText;
				accessCtx.leaderInfoKey  = loadingInfo.LeaderText;
				accessCtx.leaderInfoText = Locale.Lookup(loadingInfo.LeaderText);
			end
		end

		if (eraInfoText) then
			Controls.EraInfo:LocalizeAndSetText(eraInfoText);
			Controls.EraInfo:SetHide(false);
		else
			Controls.EraInfo:SetHide(true);
		end

		if(challengeInfoText) then
			Controls.LeaderInfo:SetText(challengeInfoText);
			Controls.LeaderInfo:SetHide(false);
		elseif(leaderInfoText) then
			Controls.LeaderInfo:LocalizeAndSetText(leaderInfoText);
			Controls.LeaderInfo:SetHide(false);
		else
			Controls.LeaderInfo:SetHide(true);
		end

		local civType	:string = playerConfig:GetCivilizationTypeName();
		local iconName	:string = "ICON_"..civType;
		Controls.LogoContainer:SetColor(primaryColor);
		Controls.Logo:SetColor(secondaryColor);
		Controls.Logo:SetIcon(iconName);

		Controls.Logo:SetHide(false);
		Controls.BackgroundImage:SetHide(false);
		Controls.Banner:SetHide(false);
		Controls.Portrait:SetHide(false);

		-- Find center of remaining space to right of ribbon, portrait will center it's texture on that.
		local ribbonRunsPastCenter:number = 80;
		local screenWidth, screenHeight = UIManager:GetScreenSizeVal();
		local backgroundWidth, backgroundHeight = Controls.BackgroundImage:GetSizeVal();
		local minWidth = math.min(backgroundWidth, screenWidth);
		Controls.PortraitContainer:SetSizeX( (minWidth*0.5) - ribbonRunsPastCenter );

		-- start the voiceover
		local leaderID = playerConfig:GetLeaderTypeID();
		local bPlayDOM = true;

		if(loadingInfo) then
			bPlayDOM = loadingInfo.PlayDawnOfManAudio;
		end

		if (m_isResyncLoad) then
			bPlayDOM = false;
		end

		if bPlayDOM then
			local dawnOfManLeaderID = leaderID;
			local dawnOfManEraHash = startEra.Hash;

			if(loadingInfo and loadingInfo.DawnOfManLeaderId) then
				dawnOfManLeaderID = loadingInfo.DawnOfManLeaderId;
			end

			if(loadingInfo and loadingInfo.DawnOfManEraId) then
				dawnOfManEraHash = DB.MakeHash(loadingInfo.DawnOfManEraId);
			end

			if (Challenges.IsChallengeActive()) then
				-- Don't play leader/civilization for challenge games as those have the text missing.
				-- Setting this to the "NO_LEADER" values will cause sound not to play
				-- and override any stale values for the switch.
				dawnOfManLeaderID = -1;
			end

			UI.SetSoundSwitchValue("Leader_Screen_Civilization", UI.GetCivilizationSoundSwitchValueByLeader(dawnOfManLeaderID));
			UI.SetSoundSwitchValue("Civilization", UI.GetCivilizationSoundSwitchValueByLeader(dawnOfManLeaderID));
			UI.SetSoundSwitchValue("Era_DawnOfMan", UI.GetEraSoundSwitchValue(dawnOfManEraHash));
			-- Civ VI Access (round 8): Sean Bean is SUPPRESSED by
			-- default. Briefing covers everything Tolk-side
			-- (including the leader paragraph Sean recites). Per
			-- Noel's design: experienced players want the important
			-- info spoken by Tolk, not flavor narration. Future
			-- toggleable setting will let lore-curious users enable
			-- Sean — when enabled, briefing skips the leader
			-- paragraph and the user gets a "Press Enter for Dawn
			-- of Man speech" prompt that fires UI.PlaySound here.
			-- LoadScreenAccess.ShouldPlayDawnOfMan returns the
			-- current setting state.
			if LoadScreenAccess ~= nil and LoadScreenAccess.ShouldPlayDawnOfMan ~= nil
			   and LoadScreenAccess.ShouldPlayDawnOfMan() then
				UI.PlaySound("Play_DawnOfMan_Speech");
			end
		end

		-- Obtain "uniques" from Civilization and for the chosen leader
		local uniqueAbilities;
		local uniqueUnits;
		local uniqueBuildings;
		uniqueAbilities, uniqueUnits, uniqueBuildings = GetLeaderUniqueTraits( leaderType );
		local CivUniqueAbilities, CivUniqueUnits, CivUniqueBuildings = GetCivilizationUniqueTraits( civType );

		-- Merge tables
		for i,v in ipairs(CivUniqueAbilities)	do table.insert(uniqueAbilities, v) end
		for i,v in ipairs(CivUniqueUnits)		do table.insert(uniqueUnits, v)		end
		for i,v in ipairs(CivUniqueBuildings)	do table.insert(uniqueBuildings, v) end

		-- Generate content
		for _, item in ipairs(uniqueAbilities) do
			--print( "ua:", item.TraitType, item.Name, item.Description, Locale.Lookup(item.Description));	--debug
			local instance:table = {};
			ContextPtr:BuildInstanceForControl("TextInfoInstance", instance, Controls.FeaturesStack );
			if (item.Name ~= nil and item.Name ~= "NONE") then
				local headerText:string = Locale.ToUpper(Locale.Lookup( item.Name ));
				instance.Header:SetText( headerText );
			else
				instance.Header:SetShow(false);
			end

			if (item.Description ~= nil and item.Description ~= "NONE") then
				instance.Description:SetText( Locale.Lookup( item.Description ) );
			else
				instance.Description:SetShow(false);
			end
		end

		local size:number = SIZE_BUILDING_ICON;

		for _, item in ipairs(uniqueUnits) do
			--print( "uu:", item.TraitType, item.Name, item.Description, Locale.Lookup(item.Description));	--debug
			local instance:table = {};
			ContextPtr:BuildInstanceForControl("IconInfoInstance", instance, Controls.FeaturesStack );
			iconAtlas = "ICON_"..item.Type;
			instance.Icon:SetIcon(iconAtlas);
			instance.TextStack:SetOffsetX( size + 4 );
			local headerText:string = Locale.ToUpper(Locale.Lookup( item.Name ));
			instance.Header:SetText( headerText );
			instance.Description:SetText(Locale.Lookup(item.Description));
		end


		for _, item in ipairs(uniqueBuildings) do
			--print( "ub:", item.TraitType, item.Name, item.Description, Locale.Lookup(item.Description));	--debug
			local instance:table = {};
			ContextPtr:BuildInstanceForControl("IconInfoInstance", instance, Controls.FeaturesStack );
			instance.Icon:SetSizeVal(38,38);
			iconAtlas = "ICON_"..item.Type;
			instance.Icon:SetIcon(iconAtlas);
			instance.TextStack:SetOffsetX( size + 4 );
			local headerText:string = Locale.ToUpper(Locale.Lookup( item.Name ));
			instance.Header:SetText( headerText );
			instance.Description:SetText(Locale.Lookup(item.Description));
		end
	end

	-- Civ VI Access hand-off: build + speak the briefing using the
	-- data we just collected.
	if LoadScreenAccess ~= nil and LoadScreenAccess.NotifyContentReady ~= nil then
		LoadScreenAccess.NotifyContentReady(accessCtx);
	end
end

-- ===========================================================================
-- Small helper used in the shadow to capture localized strings
-- defensively. (Not in the engine original.)
-- ===========================================================================
function safeLookupOrNil(key)
	if key == nil or key == "" then return ""; end
	local ok, value = pcall(Locale.Lookup, key);
	if not ok or value == nil then return ""; end
	return tostring(value);
end

-- ===========================================================================
-- ENGINE Event
-- ===========================================================================
function OnBeforeMultiplayerInviteProcessing()
	-- We're about to process a game invite.  Get off the popup stack before we accidently break the invite!
	UIManager:DequeuePopup( ContextPtr );
end

-- ===========================================================================
--	ENGINE Event
-- ===========================================================================
function OnLoadGameViewStateDone()

	m_isLoadComplete = true;
	print("OnLoadGameViewStateDone");

	UIManager:SetUICursor( 0 );

	if m_isResyncLoad or GameConfiguration.IsAnyMultiplayer() or GameConfiguration:IsWorldBuilderEditor() then
		-- If this is a resync load, skip the Begin Game button.
		OnActivateButtonClicked();
	else
		-- Activate the Begin Game button.
		local strGameButtonName;


		if (GameConfiguration.IsSavedGame()) then
			strGameButtonName = Locale.Lookup("LOC_CONTINUE_GAME");
		else
			strGameButtonName = Locale.Lookup("LOC_BEGIN_GAME");
		end

		Controls.StartLabelButton:SetText(strGameButtonName);
		Controls.ActivateButton:SetHide(false);
		Controls.LoadingContainer:SetHide(true);
		Controls.FadeAnim:SetToBeginning();
		Controls.FadeAnim:Play();
		UI.PlaySound("Game_Begin_Button_Appear");

		Input.SetActiveContext( InputContext.Ready );

		-- If automation is running, continue on.
		if (Automation.IsAutoStartEnabled()) then
			OnActivateButtonClicked();
		end
	end

	RegisterButtonCallbacks();

	-- Civ VI Access: input handler is already installed in Initialize
	-- (so Esc works during the briefing). The engine version installs
	-- here for the first time, gated on m_isLoadComplete; we install
	-- earlier to fix the "Esc doesn't work during Sean Bean" bug.
	-- The Events.InputActionTriggered subscription still happens here
	-- since that's the StartGame hotkey path.
	Events.InputActionTriggered.Add( OnInputActionTriggered );

	-- Civ VI Access hand-off: announce "loading complete".
	if LoadScreenAccess ~= nil and LoadScreenAccess.NotifyLoadComplete ~= nil then
		LoadScreenAccess.NotifyLoadComplete();
	end
end

-- ===========================================================================
function Initialize()

	Input.SetActiveContext( InputContext.Loading );

	-- EVENTS:
	ContextPtr:SetInitHandler( OnInit );
	ContextPtr:SetShowHandler( OnShow );
	ContextPtr:SetHideHandler( OnHide );

	-- Civ VI Access: install input handler EARLY (engine deferred to
	-- OnLoadGameViewStateDone, but that's why Esc was broken during
	-- the speech — handler wasn't installed yet). Our wrapper routes
	-- through LoadScreenAccess.HandleKey first; the engine's logic
	-- still applies post-load via the m_isLoadComplete gate inside
	-- OnInput.
	ContextPtr:SetInputHandler( OnInput );

	Events.LoadScreenContentReady.Add( OnLoadScreenContentReady );		-- Ready to show player info
	Events.LoadGameViewStateDone.Add( OnLoadGameViewStateDone );		-- Ready to start game
	Events.BeforeMultiplayerInviteProcessing.Add( OnBeforeMultiplayerInviteProcessing );

    UI.SetExitOnClose(true);
end
Initialize();
