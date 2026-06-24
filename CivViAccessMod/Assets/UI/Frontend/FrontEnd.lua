-- ===========================================================================
--
--	Root content for the "Shell" (aka: FrontEnd)
--	All menus are loaded off of here, including the MainMenu.
--
-- ===========================================================================
--
--	ACCESSIBILITY FORK of Base/Assets/UI/FrontEnd/FrontEnd.lua.
--
--	Base OnInit shows two informational popups when the engine can't classify
--	the GPU: the "unknown graphics device" notice (UI.HasUnknownDevice() — e.g.
--	an Intel Arc or any card newer than Civ VI's 2016 device database) and the
--	"outdated driver" notice. Both are PopupDialogs whose buttons are MOUSE-ONLY
--	(no keyboard handling in PopupDialog at all) — a silent, un-exitable wall for
--	a blind player, and the reason the main-menu arrows looked "dead" (the
--	invisible OK box stole the show while the menu sat behind it).
--
--	KEY FINDING (2026-06-23 recon): hosting an accessible popup on THIS context
--	does NOT work. FrontEnd is the shell ROOT container (a <ContextDefaults> whose
--	screens are child LuaContexts); its Lua input handler is nil and QueuePopup-ing
--	the root never grabs keyboard focus. An accessible popup here renders + speaks
--	but never receives arrows. A popup must live on a real popup <Context> that
--	grabs keyboard — we already have one: FrontEndPopup. So this fork just DETECTS
--	the conditions and routes them to FrontEndPopup.lua (our accessible, keyboard-
--	grabbing popup context) via a LuaEvent. Everything else is base verbatim.
--
--	When a Civ VI patch ships a new FrontEnd.lua, diff against the base and
--	re-apply the OnInit routing below.
--
-- ===========================================================================

include("PopupDialog")
include("InputSupport");



-- ===========================================================================
--	Event Handlers
-- ===========================================================================
function OnMultiplayerJoinRoomAttempt()
	--We're attempting to join a lobby room as part of joining multiplayer game.  Show the joining room screen.
	UIManager:QueuePopup(Controls.JoiningRoom, PopupPriority.Current);
end


-- ===========================================================================
function OnInit()

    -- ACCESSIBILITY: route the unknown-device / outdated-driver notices to the
    -- accessible FrontEndPopup context (which grabs keyboard) instead of base's
    -- mouse-only PopupDialog hosted here (which never receives arrows). Same
    -- gating conditions as base; FrontEndPopup runs the same accept logic
    -- (sets the AppOption flag, fires Events.UserAccepts*).
    local needDevice = UI.HasUnknownDevice()  and Options.GetAppOption("Misc", "AcceptedUnknownDevice")  ~= 1;
    local needDriver = UI.HasOutdatedDriver() and Options.GetAppOption("Misc", "AcceptedOutdatedDriver") ~= 1;
    if needDevice or needDriver then
        LuaEvents.CivViAccess_ShowGraphicsNotices(needDevice, needDriver);
    end

end

function OpenPopup()
	UIManager:QueuePopup( ContextPtr, PopupPriority.Current );
end

function ClosePopup()
	UIManager:DequeuePopup(ContextPtr);
	-- Front end background is visible on this context, so we should never be hidden
	ContextPtr:SetHide(false);
end

-- ===========================================================================
function OnShutdown()

	if (Controls.BackgroundMovie ~= nil) then
		Controls.BackgroundMovie:Close();
	end

    Events.SystemUpdateUI.Remove( OnUpdateUI );
    Events.MultiplayerJoinRoomAttempt.Remove( OnMultiplayerJoinRoomAttempt );
end

-- ===========================================================================
function OnUpdateUI(type:number, tag:string, iData1:number, iData2:number, strData1:string)
    if type == SystemUpdateUI.ScreenResize then
		--Resize();
		if (Controls.BackgroundMovie ~= nil) then
			Controls.BackgroundMovie:ReprocessAnchoring();
		end
	end
end

-- ===========================================================================
--
-- ===========================================================================
function Initialize()

	Input.SetActiveContext( InputContext.Shell );

	ContextPtr:SetInputHandler( OnInputHandler, true );
    ContextPtr:SetInitHandler( OnInit );
    ContextPtr:SetShutdown( OnShutdown );

    Events.SystemUpdateUI.Add( OnUpdateUI );

	Events.MultiplayerJoinRoomAttempt.Add( OnMultiplayerJoinRoomAttempt );

	-- Does a main menu exist?
	if Controls.MainMenu ~= nil then
		UIManager:QueuePopup( Controls.MainMenu, PopupPriority.Low );
	else
		-- No main menu; there better be a test file being shown.
		if Controls.Test == nil then
			UI.DataError("No 'MainMenu' and no 'Test' control found!");
		end
	end
end
Initialize();
