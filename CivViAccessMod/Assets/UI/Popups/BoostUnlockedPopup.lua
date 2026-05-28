-- ===========================================================================
--
--	Popup when a Tech/Civic Boost unlock occurs.
--
-- ScreenReaderAccess shadow: minimal additions over Base —
--   1. include("RevealPopupAccess") at top
--   2. ShowTechBoost / ShowCivicBoost tail hands off to
--      RevealPopupAccess.NotifyShow with assembled header + cause + desc.
--   3. OnClose calls RevealPopupAccess.NotifyClose.
--   4. OnInputHandler routes through RevealPopupAccess.HandleKey first.
-- All other code is verbatim from Base.
-- ===========================================================================
include("SupportFunctions");
include("RevealPopupAccess");

-- ===========================================================================
--	CONSTANS / MEMBERS
-- ===========================================================================
local m_queuedBoosts			:table	 = {};
local m_isDisabledByTutorial	:boolean = false;
local m_isPastLoadingScreen		:boolean = false;
local m_isOnQueue				:boolean = false;

-- begin ScreenReaderAccess mod change
-- Local helper to push the assembled header/cause/desc speech through
-- RevealPopupAccess. Called from the tail of ShowTechBoost /
-- ShowCivicBoost where all three strings are known.
local function _SRAccessAnnounce(headerString:string, msgString:string, descString:string)
	local parts = {};
	if headerString ~= nil and headerString ~= "" then
		table.insert(parts, headerString);
	end
	if msgString ~= nil and msgString ~= "" then
		table.insert(parts, msgString);
	end
	if descString ~= nil and descString ~= "" then
		table.insert(parts, descString);
	end
	local text = table.concat(parts, ". ");
	if stripIconTags ~= nil then
		text = stripIconTags(text);
	end
	RevealPopupAccess.NotifyShow({
		text    = text,
		onClose = function() OnClose() end,
		kind    = "critical",
	});
end
-- end ScreenReaderAccess mod change

-- ===========================================================================
function ShowBoost(queueEntry:table)
	if queueEntry.techIndex ~= nil then
		ShowTechBoost(queueEntry.techIndex, queueEntry.iTechProgress, queueEntry.eSource);
	else
		ShowCivicBoost(queueEntry.civicIndex, queueEntry.iCivicProgress, queueEntry.eSource);
	end

	-- Queue Popup through UI Manager
	UIManager:QueuePopup( ContextPtr, PopupPriority.Low, { DelayShow = true });
	m_isOnQueue = true;

	PlayAnimations();
end

-- ===========================================================================
--	Raise a panel in center of screen showing researched tech boost.
-- ===========================================================================
function ShowTechBoost(techIndex, iTechProgress, eSource)
	-- Make sure we're the local player
	local localPlayer = Players[Game.GetLocalPlayer()];
	if (localPlayer == nil) then
		return;
	end

	-- Update textures
	Controls.GlowImage:SetTexture(0, 0, "BoostPopup_GlowTech");
	Controls.BoostInfoGrid:SetTexture("BoostPopup_TechFrame");
	Controls.BoostBar:SetTexture("ResearchPanel_BoostMeter");
	Controls.ProgressBar:SetTexture("ResearchPanel_Meter");
	Controls.GearAnim:SetTexture("ResearchPanel_MeterFrameAnim");
	Controls.GearButton:SetTexture(0, 0, "ResearchPanel_Button");
	Controls.BoostDescFontIcon:SetText("[ICON_TechBoosted]");

	-- Update header text
	local headerString = Locale.ToUpper( Locale.Lookup( "LOC_HUD_POPUP_TECH_BOOST_UNLOCKED" ));
	Controls.HeaderLabel:SetText(headerString);

	local playerTechs = localPlayer:GetTechs();
	local totalTechCost = playerTechs:GetResearchCost(techIndex);

	local currentTech = GameInfo.Technologies[techIndex];
	local techName = " ";

	if currentTech ~= nil then
		techName = currentTech.Name;
	end

	-- Update Icon
	local iconName:string = "ICON_" .. currentTech.TechnologyType;
	local textureOffsetX, textureOffsetY, textureSheet = IconManager:FindIconAtlas(iconName,38);
	if (textureOffsetX ~= nil) then
		Controls.BoostIcon:SetTexture( textureOffsetX, textureOffsetY, textureSheet );
	end

	-- Update Cause Label
	local msgString :string;
	if eSource == BoostSources.BOOST_SOURCE_GOODYHUT then
		msgString = Locale.Lookup("LOC_TECH_BOOST_GOODYHUT");

	elseif eSource == BoostSources.BOOST_SOURCE_WONDER then
		msgString = Locale.Lookup("LOC_TECH_BOOST_WONDER");

	elseif eSource == BoostSources.BOOST_SOURCE_GREAT_PERSON then
		msgString = Locale.Lookup("LOC_TECH_BOOST_GREAT_PERSON");

	elseif eSource == BoostSources.BOOST_SOURCE_ESPIONAGE then
		msgString = Locale.Lookup("LOC_TECH_BOOST_ESPIONAGE");

	elseif eSource == BoostSources.BOOST_SOURCE_RESEARCH_AGREEMENT then
		msgString = Locale.Lookup("LOC_TECH_BOOST_RESEARCH_AGREEMENT");

	elseif eSource == BoostSources.BOOST_SOURCE_TEAMMATE then
		msgString = Locale.Lookup("LOC_TECH_BOOST_TEAMMATE");

	elseif eSource == BoostSources.BOOST_SOURCE_CAPTURED_CITY then
		msgString = Locale.Lookup("LOC_TECH_BOOST_CAPTURED_CITY");

	elseif eSource == BoostSources.BOOST_SOURCE_TRADING_POST then
		msgString = Locale.Lookup("LOC_TECH_BOOST_TRADING_POST");

	elseif eSource == BoostSources.BOOST_SOURCE_BARBARIAN_CLAN_STEAL then
		msgString = Locale.Lookup("LOC_TECH_BOOST_BARBARIAN_CLAN_STEAL");

	elseif currentTech ~= nil then
		for row in GameInfo.Boosts() do
			if(row.TechnologyType == currentTech.TechnologyType) then
				msgString = Locale.Lookup(row.TriggerLongDescription);
				break;
			end
		end
	end

	Controls.BoostCauseString:SetText(msgString);

	-- Show the player the amount of progress the boost has given
	local currentPercent = iTechProgress / totalTechCost;
	local totalProgress = playerTechs:GetResearchProgress(techIndex);
	local endPercent :number;

	Controls.ProgressBar:SetAnimationSpeed(0);
	Controls.ProgressBar:SetPercent(currentPercent);

	-- Update boost description and determine final research percentage
	local descString:string;
	if totalProgress > totalTechCost then
		endPercent = 1.0;
		descString = Locale.Lookup("LOC_TECH_BOOST_COMPLETE", techName);
		Controls.BoostDescString:SetText(descString);
	else
		endPercent = totalProgress / totalTechCost;
		descString = Locale.Lookup("LOC_TECH_BOOST_ADVANCED", techName);
		Controls.BoostDescString:SetText(descString);
	end

	Controls.ProgressBar:SetAnimationSpeed(.5);
	Controls.ProgressBar:SetPercent(endPercent);
	Controls.BoostBar:SetPercent(endPercent);
    if (m_isPastLoadingScreen) then
        UI.PlaySound("Pause_TechCivic_Speech");
        UI.PlaySound("Receive_Tech_Boost");
    end

	-- begin ScreenReaderAccess mod change
	_SRAccessAnnounce(headerString, msgString, descString);
	-- end ScreenReaderAccess mod change
end

-- ===========================================================================
--	Raise a panel in center of screen showing researched civic boost.
-- ===========================================================================
function ShowCivicBoost(civicIndex, iCivicProgress, eSource)
-- Make sure we're the local player
	local localPlayer = Players[Game.GetLocalPlayer()];
	if (localPlayer == nil) then
		return;
	end

	-- Update textures
	Controls.GlowImage:SetTexture(0, 0, "BoostPopup_GlowCivic");
	Controls.BoostInfoGrid:SetTexture("BoostPopup_CivicFrame");
	Controls.BoostBar:SetTexture("CivicPanel_BoostMeter");
	Controls.ProgressBar:SetTexture("CivicPanel_Meter");
	Controls.GearAnim:SetTexture("CivicPanel_MeterFrameAnim");
	Controls.GearButton:SetTexture(0, 0, "CivicPanel_Button");
	Controls.BoostDescFontIcon:SetText("[ICON_CivicBoosted]");

	-- Update header text
	local headerString = Locale.ToUpper( Locale.Lookup( "LOC_HUD_POPUP_CIVIC_BOOST_UNLOCKED" ));
	Controls.HeaderLabel:SetText(headerString);

	local playerCulture = localPlayer:GetCulture();
	local totalCivicCost = playerCulture:GetCultureCost(civicIndex);

	local currentCivic = GameInfo.Civics[civicIndex];
	local civicName = " ";

	if currentCivic ~= nil then
		civicName = currentCivic.Name;
	end

	-- Update Icon
	local iconName:string = "ICON_" .. currentCivic.CivicType;
	local textureOffsetX, textureOffsetY, textureSheet = IconManager:FindIconAtlas(iconName,42);
	if (textureOffsetX ~= nil) then
		Controls.BoostIcon:SetTexture( textureOffsetX, textureOffsetY, textureSheet );
	end

	-- Update Cause Label
	local msgString :string;
	if eSource == BoostSources.BOOST_SOURCE_GOODYHUT then
		msgString = Locale.Lookup("LOC_CIVIC_BOOST_GOODYHUT");

	elseif eSource == BoostSources.BOOST_SOURCE_WONDER then
		msgString = Locale.Lookup("LOC_CIVIC_BOOST_WONDER");

	elseif eSource == BoostSources.BOOST_SOURCE_GREAT_PERSON then
		msgString = Locale.Lookup("LOC_CIVIC_BOOST_GREAT_PERSON");

	elseif eSource == BoostSources.BOOST_SOURCE_TEAMMATE then
		msgString = Locale.Lookup("LOC_CIVIC_BOOST_TEAMMATE");

	elseif eSource == BoostSources.BOOST_SOURCE_CAPTURED_CITY then
		msgString = Locale.Lookup("LOC_CIVIC_BOOST_CAPTURED_CITY");

	elseif eSource == BoostSources.BOOST_SOURCE_TRADING_POST then
		msgString = Locale.Lookup("LOC_CIVIC_BOOST_TRADING_POST");

	elseif eSource == BoostSources.BOOST_SOURCE_BARBARIAN_CLAN_STEAL then
		msgString = Locale.Lookup("LOC_TECH_BOOST_BARBARIAN_CLAN_STEAL");

	elseif currentCivic ~= nil then

		for row in GameInfo.Boosts() do
			if(row.CivicType == currentCivic.CivicType) then
				msgString = Locale.Lookup(row.TriggerLongDescription);
				break;
			end
		end
	end

	Controls.BoostCauseString:SetText(msgString);

	-- Show the player the amount of progress the boost has given
	local currentPercent = iCivicProgress / totalCivicCost;
	local totalProgress = playerCulture:GetCulturalProgress(civicIndex);
	local endPercent :number;

	Controls.ProgressBar:SetAnimationSpeed(0);
	Controls.ProgressBar:SetPercent(currentPercent);

	-- Update boost description and determine final research percentage
	local civicString = Locale.Lookup(civicName)
	local descString:string;
	if totalProgress > totalCivicCost then
		endPercent = 1.0;
		descString = Locale.Lookup("LOC_CIVIC_BOOST_COMPLETE", civicString);
		Controls.BoostDescString:SetText(descString);
	else
		endPercent = totalProgress / totalCivicCost;
		descString = Locale.Lookup("LOC_CIVIC_BOOST_ADVANCED", civicString);
		Controls.BoostDescString:SetText(descString);
	end

	Controls.ProgressBar:SetAnimationSpeed(.5);
	Controls.ProgressBar:SetPercent(endPercent);
	Controls.BoostBar:SetPercent(endPercent);

    if (m_isPastLoadingScreen) then
        UI.PlaySound("Pause_TechCivic_Speech");
        UI.PlaySound("Receive_Culture_Boost");
    end

	-- begin ScreenReaderAccess mod change
	_SRAccessAnnounce(headerString, msgString, descString);
	-- end ScreenReaderAccess mod change
end

-- ===========================================================================
function PlayAnimations()
	-- Restart glow slide anim
	Controls.GlowSlideAnim:SetToBeginning();
	Controls.GlowSlideAnim:Play();

	-- Restart glow alpha anim
	Controls.GlowAlphaAnim:SetToBeginning();
	Controls.GlowAlphaAnim:Play();

	-- Restart gear anim
	Controls.GearAnim:SetToBeginning();
	Controls.GearAnim:Play();
end

-- ===========================================================================
function CanShow()
	return UI.CanShowPopup(PopupPriority.Low) and m_isOnQueue==false;
end

-- ===========================================================================
function DoCivicBoost(ePlayer, civicIndex, iCivicProgress, eSource)
	-- If it's the first turn of a late start game, ignore all the boosts the come across the wire.
	if (not m_isPastLoadingScreen) and (Game.GetCurrentGameTurn() == GameConfiguration.GetStartTurn()) then
		return;
	end

	if ePlayer == Game.GetLocalPlayer() and (not m_isDisabledByTutorial)  then
		local civicBoostEntry:table = { civicIndex=civicIndex, iCivicProgress=iCivicProgress, eSource=eSource };

		-- If we're not showing a boost popup then add it to the popup system queue
		if CanShow() then
			ShowBoost(civicBoostEntry);
		else
			-- Add to queue if already showing a boost popup
			table.insert(m_queuedBoosts, civicBoostEntry);
		end
	end
end

-- ===========================================================================
function DoTechBoost(ePlayer, techIndex, iTechProgress, eSource)

	-- If it's the first turn of a late start game, ignore all the boosts the come across the wire.
	if (not m_isPastLoadingScreen) and (Game.GetCurrentGameTurn() == GameConfiguration.GetStartTurn()) then
		return;
	end

	if ePlayer == Game.GetLocalPlayer() and (not m_isDisabledByTutorial) then
		local techBoostEntry:table = { techIndex=techIndex, iTechProgress=iTechProgress, eSource=eSource };

		-- If we're not showing a boost popup then add it to the popup system queue
		if CanShow() then
			ShowBoost(techBoostEntry);
		else
			-- Add to queue if already showing a boost popup
			table.insert(m_queuedBoosts, techBoostEntry);
		end
	end
end

-- ===========================================================================
function ShowNextQueuedPopup()
	-- Find first entry in table, display that, then remove it from the internal queue
	for i, entry in ipairs(m_queuedBoosts) do
		ShowBoost(m_queuedBoosts[i]);
        UI.PlaySound("Pause_TechCivic_Speech");
		table.remove(m_queuedBoosts, i);
		break;
	end
end

-- ===========================================================================
function OnClose()
	-- begin ScreenReaderAccess mod change
	RevealPopupAccess.NotifyClose();
	-- end ScreenReaderAccess mod change

	-- Dequeue popup from UI mananger
	UIManager:DequeuePopup( ContextPtr );
	m_isOnQueue = false;

	ShowNextQueuedPopup();
end

-- ===========================================================================
function OnInputHandler( input )
	-- begin ScreenReaderAccess mod change
	-- Reveal helper consumes Enter/Esc/Space (dismiss), Ctrl+T (re-read).
	-- Falls through to engine for anything else.
	if RevealPopupAccess.HandleKey(input) then return true; end
	-- end ScreenReaderAccess mod change
	local msg = input:GetMessageType();
	if (msg == KeyEvents.KeyUp) then
		local key = input:GetKey();
		if key == Keys.VK_RETURN or key == Keys.VK_ESCAPE then
			OnClose();
			return true;
		end
	end
	return false;
end

-- ===========================================================================
function OnLoadGameViewStateDone()
    m_isPastLoadingScreen = true;
end

-- ===========================================================================
function OnLocalPlayerTurnEnd()
	if(GameConfiguration.IsHotseat()) then
		OnClose();
	end
end

-- ===========================================================================
function OnProgressMeterAnimEnd()
	Controls.GearAnim:Stop();
end

-- ===========================================================================
function OnUIIdle()
	-- The UI is idle, are we waiting to show a popup?
	if UI.CanShowPopup(PopupPriority.Low) then
		ShowNextQueuedPopup();
	end
end

-- ===========================================================================
--	LUA Event
-- ===========================================================================
function OnDisableTechAndCivicPopups()
	m_isDisabledByTutorial = true;
end

-- ===========================================================================
--	LUA Event
-- ===========================================================================
function OnEnableTechAndCivicPopups()
	m_isDisabledByTutorial = false;
end

function OnNotificationPanel_ShowTechBoost( ePlayer, techIndex, iTechProgress, eSource )
	DoTechBoost(ePlayer, techIndex, iTechProgress, eSource);
end

function OnNotificationPanel_ShowCivicBoost( ePlayer, civicIndex, iCivicProgress, eSource )
	DoCivicBoost(ePlayer, civicIndex, iCivicProgress, eSource);
end

-- ===========================================================================
--	UI Callback
-- ===========================================================================
function OnInit( isHotload:boolean )
	if isHotload then
		m_isPastLoadingScreen = true;
	end
end

-- ===========================================================================
function Initialize()

	ContextPtr:SetInitHandler( OnInit );
	ContextPtr:SetInputHandler( OnInputHandler, true );

	-- Control Events
	Controls.ContinueButton:RegisterCallback( Mouse.eLClick, OnClose );
	Controls.ContinueButton:RegisterCallback( Mouse.eMouseEnter, function() UI.PlaySound("Main_Menu_Mouse_Over"); end);
	Controls.ProgressBar:RegisterEndCallback( OnProgressMeterAnimEnd );

	-- LUA Events
	LuaEvents.TutorialUIRoot_DisableTechAndCivicPopups.Add( OnDisableTechAndCivicPopups );
	LuaEvents.TutorialUIRoot_EnableTechAndCivicPopups.Add( OnEnableTechAndCivicPopups );
	LuaEvents.NotificationPanel_ShowTechBoost.Add( OnNotificationPanel_ShowTechBoost );
	LuaEvents.NotificationPanel_ShowCivicBoost.Add( OnNotificationPanel_ShowCivicBoost );

	-- Game Events
	Events.LocalPlayerTurnEnd.Add( OnLocalPlayerTurnEnd );
    Events.LoadGameViewStateDone.Add( OnLoadGameViewStateDone );
	Events.UIIdle.Add( OnUIIdle );
end
Initialize();
