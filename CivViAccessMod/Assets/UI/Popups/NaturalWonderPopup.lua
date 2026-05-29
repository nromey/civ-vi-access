-- Copyright 2016-2019, Firaxis Games
-- Popup for Natural Wonders
--
-- ScreenReaderAccess shadow: minimal additions over Base —
--   1. include("RevealPopupAccess") at top
--   2. ShowPopup tail hands off to RevealPopupAccess.NotifyShow with
--      assembled headline + quote + description text
--   3. Close calls RevealPopupAccess.NotifyClose
--   4. OnInputHander routes through RevealPopupAccess.HandleKey first
-- All other code is verbatim from Base.

include("PopupManager");
include("RevealPopupAccess");

-- ===========================================================================
--	CONSTANTS
-- ===========================================================================
local RELOAD_CACHE_ID:string = "NaturalWonderPopup";


-- ===========================================================================
--	MEMBERS
-- ===========================================================================
local m_kPopupMgr		:table	 = ExclusivePopupManager:new("NaturalWonderPopup");
local m_kQueuedPopups	:table	 = {};
local m_kCurrentPopup	:table	 = nil;
local m_eCurrentFeature	:number  = -1;


-- ===========================================================================
--	FUNCTIONS
-- ===========================================================================


-- ===========================================================================
--	Closes the immediate popup, will raise more if queued.
-- ===========================================================================
function Close()

	UI.ClearTemporaryPlotVisibility("NaturalWonder");
	UI.PlaySound("Stop_Speech_NaturalWonders");

	-- Stop the camera animation if it hasn't finished already
	if (m_kCurrentPopup ~= nil) then
		Events.StopAllCameraAnimations();
	end

	-- begin ScreenReaderAccess mod change
	RevealPopupAccess.NotifyClose();
	-- end ScreenReaderAccess mod change

	local isDone:boolean  = true;

	-- Find first entry in table, display that, then remove it from the internal queue
	for i, entry in ipairs(m_kQueuedPopups) do
		ShowPopup(entry);
		table.remove(m_kQueuedPopups, i);
		isDone = false;
		break;
	end

	-- If done, restore engine processing and let the world know.
	if isDone then
		m_eCurrentFeature = -1;
		m_kCurrentPopup = nil;
		LuaEvents.NaturalWonderPopup_Closed();	-- Signal other systems (e.g., bulk show UI)
		UI.SetInterfaceMode(InterfaceModeTypes.SELECTION);
		UILens.RestoreActiveLens();
		m_kPopupMgr:Unlock();
	end
end

-- ===========================================================================
--	UI Callback
-- ===========================================================================
function OnClose()
	Close();
end

-- ===========================================================================
function ShowPopup( kData:table )

	-- Only call once to preserve whatever lens was on before showing scene
	if(UI.GetInterfaceMode() ~= InterfaceModeTypes.CINEMATIC) then
		UILens.SaveActiveLens();
		UILens.SetActive("Cinematic");
		UI.SetInterfaceMode(InterfaceModeTypes.CINEMATIC);
	end

	local pPlot = Map.GetPlot(kData.plotx, kData.ploty);
	if pPlot ~= nil then
		local aPlots = pPlot:GetFeature():GetPlots();
		-- Just in case the local player can't see all the plots, temporarily reveal them on the app side
		-- This includes even single plot NWs, as the NW can be completely in mid-fog, if just the underlying map was revealed to the player.
		-- This happens with city state captital reveals, etc.
		UI.AddTemporaryPlotVisibility("NaturalWonder", aPlots, RevealedState.VISIBLE);
	end

	m_eCurrentFeature = kData.Feature;
	m_kCurrentPopup = kData;

	UI.OnNaturalWonderRevealed(kData.plotx, kData.ploty);

	if(kData.QuoteAudio) then
		UI.PlaySound(kData.QuoteAudio);
	end

	Controls.WonderName:SetText( kData.Name );
	Controls.WonderQuoteContainer:SetHide( kData.Quote == nil );
	Controls.WonderIcon:SetIcon( "ICON_".. kData.TypeName);
	if kData.Quote ~= nil then
		Controls.WonderQuote:SetText( kData.Quote );
	end
	if kData.Description ~= nil then
		Controls.WonderIcon:SetToolTipString( kData.Description );
	end
	Controls.QuoteContainer:DoAutoSize();

	-- begin ScreenReaderAccess mod change
	-- Structured announce (Noel 2026-05-29): lead-in framing → name →
	-- gameplay effects → [short visual] → [Press I for full <type>] →
	-- dismiss hint. Short/long visual descriptions come from the
	-- wonder-describer pipeline (NaturalWonderDescriptions.xml) and get
	-- wired in once generated; until then they're nil and the helper omits
	-- the short line + the "Press I" hint.
	--
	-- The game VOICES the quote (QuoteAudio) — Sean-Bean-style narration —
	-- so we DON'T duplicate it (avoids double-speak; Noel's option 1). If a
	-- feature has no QuoteAudio the quote is silent text, so we fold it in
	-- after the gameplay effects rather than lose it.
	local gameplay = kData.Description;
	if (kData.QuoteAudio == nil or kData.QuoteAudio == "")
			and kData.Quote ~= nil and kData.Quote ~= "" then
		if gameplay ~= nil and gameplay ~= "" then
			gameplay = gameplay .. ". " .. kData.Quote;
		else
			gameplay = kData.Quote;
		end
	end

	-- Visual descriptions keyed by FeatureType (wonder-describer →
	-- NaturalWonderDescriptions.xml). nil until that XML ships; then the
	-- short line + "Press I" hint appear automatically.
	local nwKey = "LOC_CIVVIACCESS_NW_" .. tostring(kData.TypeName);
	RevealPopupAccess.NotifyShow({
		leadIn   = "Natural wonder discovered",
		name     = kData.Name,
		gameplay = gameplay,
		short    = RevealPopupAccess.locOrNil(nwKey .. "_SHORT"),
		long     = RevealPopupAccess.locOrNil(nwKey .. "_LONG"),
		typeNoun = "natural wonder",
		onClose  = function() Close() end,
		kind     = "critical",
	});
	-- end ScreenReaderAccess mod change
end

-- ===========================================================================
--	Game EVENT
-- ===========================================================================
function OnNaturalWonderRevealed( plotx:number, ploty:number, eFeature:number, isFirstToFind:boolean )
	local localPlayer = Game.GetLocalPlayer();
	if (localPlayer < 0) then
		return;	-- autoplay
	end

	if not Players[localPlayer]:IsHuman() then
		return;
	end

	-- Only human players and NO hotseat
	local info:table = GameInfo.Features[eFeature];
	if info ~= nil then

		local quote :string = nil;
		if info.Quote ~= nil then
			quote = Locale.Lookup(info.Quote);
		end

		local description :string = nil;
		if info.Description ~= nil then
			description = Locale.Lookup(info.Description);
		end

		local kData:table = {
			Feature		= eFeature,
			Name		= Locale.ToUpper(Locale.Lookup(info.Name)),
			Quote		= quote,
			QuoteAudio	= info.QuoteAudio,
			Description	= description,
			TypeName	= info.FeatureType,
			plotx		= plotx,
			ploty		= ploty
		}

		-- Add to queue if already showing a popup
		if not m_kPopupMgr:IsLocked() then
			m_kPopupMgr:Lock( ContextPtr, PopupPriority.High );
			ShowPopup( kData );
			LuaEvents.NaturalWonderPopup_Shown();	-- Signal other systems (e.g., bulk hide UI)
		else

			-- Prevent DUPES when bulk showing; only happen during force reveal?
			for _,kExistingData in ipairs(m_kQueuedPopups) do
				if kExistingData.Feature == eFeature then
					return;		-- Already have a popup for this feature queued then just leave.
				end
			end
			if m_eCurrentFeature ~= eFeature then
				table.insert(m_kQueuedPopups, kData);
			end
		end

	end
end

-- ===========================================================================
function OnLocalPlayerTurnEnd()
	if m_kPopupMgr:IsLocked() then
		m_kQueuedPopups = {};	-- Ensure queue is empty to close immediately.
		Close();
	end
end

-- ===========================================================================
function OnCameraAnimationStopped(name : string)
	if (m_kCurrentPopup ~= nil) then
		UI.LookAtPlot(m_kCurrentPopup.plotx, m_kCurrentPopup.ploty, 0.0, 0.0, true);
	end
end

-- ===========================================================================
function OnCameraAnimationNotFound()
	if (m_kCurrentPopup ~= nil) then
		-- this will play if the animation doesnt exist
		UI.LookAtPlot(m_kCurrentPopup.plotx, m_kCurrentPopup.ploty);
	end
end

-- ===========================================================================
function OnInit(isReload:boolean)
	if isReload then
		LuaEvents.GameDebug_GetValues(RELOAD_CACHE_ID);
	end
end

-- ===========================================================================
function OnShutdown()
	LuaEvents.GameDebug_AddValue(RELOAD_CACHE_ID, "isHidden", ContextPtr:IsHidden());
	LuaEvents.GameDebug_AddValue(RELOAD_CACHE_ID, "m_kCurrentPopup", m_kCurrentPopup);
	LuaEvents.GameDebug_AddValue(RELOAD_CACHE_ID, "m_kPopupMgr", m_kPopupMgr.ToTable() );
	if not ContextPtr:IsHidden() then
		UILens.RestoreActiveLens();
	end
end

-- ===========================================================================
function OnGameDebugReturn(context:string, contextTable:table)
	if context == RELOAD_CACHE_ID then
		if contextTable["isHidden"] ~= nil and contextTable["isHidden"] == false then
			UI.SetInterfaceMode(InterfaceModeTypes.SELECTION);
			if contextTable["m_kCurrentPopup"] ~= nil then
				m_kCurrentPopup = contextTable["m_kCurrentPopup"];
				ShowPopup(m_kCurrentPopup);
			end
		end
		m_kPopupMgr.FromTable( contextTable["m_kPopupMgr"], ContextPtr );
	end
end

-- ===========================================================================
--	Native Input / ESC support
-- ===========================================================================
function KeyHandler( key:number )
    if key == Keys.VK_ESCAPE then
		Close();
		return true;
    end
    return false;
end
function OnInputHander( pInputStruct:table )
	-- begin ScreenReaderAccess mod change
	-- Reveal helper consumes Enter/Esc/Space (dismiss), Ctrl+T (re-read).
	-- Falls through to engine for anything else.
	if RevealPopupAccess.HandleKey(pInputStruct) then return true; end
	-- end ScreenReaderAccess mod change
	local uiMsg :number = pInputStruct:GetMessageType();
	if (uiMsg == KeyEvents.KeyUp) then return KeyHandler( pInputStruct:GetKey() ); end;
	return false;
end

-- ===========================================================================
--	Initialize the context
-- ===========================================================================
function Initialize()

	-- Because these popup movies lock the engine until complete; disable
	-- them if playing in any type of multiplayer game.
	if GameConfiguration.IsAnyMultiplayer() or GameConfiguration.IsHotseat() then
		return;
	end

	ContextPtr:SetInputHandler( OnInputHander, true );
	Controls.Close:RegisterCallback(Mouse.eLClick, OnClose);
	Controls.ScreenConsumer:RegisterCallback(Mouse.eRClick, OnClose);

	Events.NaturalWonderRevealed.Add( OnNaturalWonderRevealed );
	Events.LocalPlayerTurnEnd.Add( OnLocalPlayerTurnEnd );
	Events.CameraAnimationStopped.Add( OnCameraAnimationStopped );
	Events.CameraAnimationNotFound.Add( OnCameraAnimationNotFound );

	-- Hot-Reload Events
	ContextPtr:SetInitHandler( OnInit );
	ContextPtr:SetShutdown( OnShutdown );
	LuaEvents.GameDebug_Return.Add( OnGameDebugReturn );

end
Initialize();

-- begin ScreenReaderAccess mod change (debug)
-- Lets FireTuner raise this popup without selecting its Lua state (the state
-- combo isn't keyboard/screen-reader focusable). From any tuner state:
--   LuaEvents.CivViAccess_DebugRaisePopup("NaturalWonder")
RevealPopupAccess.RegisterDebugRaiser("NaturalWonder", function()
	local f;
	for r in GameInfo.Features() do
		if r.NaturalWonder then f = r.Index; break; end
	end
	local u = UI.GetHeadSelectedUnit();
	local x, y = (u and u:GetX() or 0), (u and u:GetY() or 0);
	OnNaturalWonderRevealed(x, y, f, true);
end);
-- end ScreenReaderAccess mod change (debug)
