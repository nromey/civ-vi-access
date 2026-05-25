-- ===========================================================================
--	InGameTopOptionsMenu — Civ VI Access shadow.
--
--	Verbatim copy of Base/Assets/UI/Menus/InGameTopOptionsMenu.lua with
--	accessibility additions marked "Begin/End CivViAccess mod change".
--
--	What this adds on top of the engine file:
--	  1. BaseMenu nav for the main pause-menu button list (Return / QuickSave /
--	     Save / Load / Options / Restart / Retire / Main Menu / Exit Game /
--	     PBC buttons). Up/Down + Enter + Esc + type-ahead.
--	  2. Speech on every confirmation popup ("Exit to desktop?" / "Retire?" /
--	     "Restart?" / "Quit to main menu?" / PBC delete & quit).
--	  3. Left/Right (or Up/Down) keyboard nav between Yes/No buttons inside
--	     each confirmation popup, with announce on each move. Enter activates
--	     the focused button; Esc closes the popup.
--	  4. Speech routes through the same OnExitGameAskAreYouSure path Alt+F4
--	     triggers (engine fires Events.UserRequestClose → OnRequestClose →
--	     OnExitGameAskAreYouSure). One wrap covers both Esc-menu-then-Exit
--	     and Alt+F4.
--
--	Engine .xml is unchanged; our Lua replaces the engine's at the same
--	Context, so Controls.* references resolve to the engine-built widgets.
-- ===========================================================================

include( "Civ6Common" );
include( "Colors") ;
include( "SupportFunctions" ); --DarkenLightenColor
include( "InputSupport" );
include( "InstanceManager" );
include( "PopupDialog" );
include( "LocalPlayerActionSupport" );
include("PopupPriorityLoader_", true);

-- Begin CivViAccess mod change: accessibility module includes
include( "Log" );
include( "ScreenReader" );
include( "BaseMenu" );
include( "BaseMenuItems" );
include( "HandlerStack" );
include( "InputRouter" );
include( "Help" );

Log.info("InGameTopOptionsMenu.lua (shadowed): file loaded");
-- End CivViAccess mod change


-- ===========================================================================
--	GLOBALS
-- ===========================================================================
g_ModListingsManager = InstanceManager:new("ModInstance", "ModTitle", Controls.ModListingsStack);

-- ===========================================================================
--	MEMBERS
-- ===========================================================================
local m_kPopupDialog	: table;			-- Custom due to Utmost popup status
local ms_ExitToMain		: boolean = true;
local m_isSimpleMenu	: boolean = false;
local m_isLoadingDone   : boolean = false;
local m_isRetired		: boolean = false;
local m_isEndGameOpen	: boolean = false;
local m_isNeedRestoreOptions		: boolean = false;
local m_isNeedRestoreSaveGameMenu	: boolean = false;
local m_isNeedRestoreLoadGameMenu	: boolean = false;
-- Begin CivViAccess mod change: Alt+F4 in-game routes through
-- OnRequestClose which queues the pause-menu context to host the
-- exit-confirmation popup. If the user picks NO, the popup closes but
-- the pause menu stays raised (bug #26b 2026-05-24). Track when the
-- pause menu was raised purely to host the exit prompt; OnCancelExit
-- consults this and dequeues the context if so.
local m_isRaisedForExitConfirm		: boolean = false;
-- End CivViAccess mod change


-- State variable to track that the menu is in the process of being closed and
-- prevent duplicate calls.
local m_isClosing		: boolean = false;


-- ===========================================================================
--	COSTANTS
-- ===========================================================================
local ICON_PREFIX:string = "ICON_";

-- Begin CivViAccess mod change: popup keyboard-nav state.
-- Parallel button list maintained as we build each popup. When the popup
-- is open, KeyHandler nav walks this list and announces each focused
-- button; Enter activates the focused entry by closing the popup and
-- invoking the captured callback (mirrors PopupDialog's own closeAndCallback
-- internal wrapper).
local m_popupButtons = {};
local m_popupIndex   = 0;
local m_popupText    = "";

-- Forward declaration so accessibleResetPopup / Open can install +
-- uninstall the modal handler closure defined below.
local popupModalHandler;

local function accessibleResetPopup()
    m_popupButtons = {};
    m_popupIndex   = 0;
    m_popupText    = "";
    -- Clear the exit-confirm-raise flag here so it's reset on every
    -- popup dismiss path (NO callback, Esc dismiss, YES exit, etc.) —
    -- otherwise the flag leaks across attempts and a normal Esc-pause-
    -- menu open might get its initial announce suppressed (Noel's
    -- 2026-05-24 log showed second Alt+F4 suppressed because flag
    -- leaked from prior Esc-dismissed attempt).
    m_isRaisedForExitConfirm = false;
    -- Detach modal handler so BaseMenu's normal pause-menu nav resumes.
    -- HandlerStack.active() resolves to whatever handler is on top right
    -- now — typically our pause-menu BaseMenu handler.
    local activeHandler = HandlerStack.active();
    if activeHandler ~= nil then
        activeHandler._modalHandler = nil;
    end
end

local function accessibleAddPopupButton(label, callback)
    m_popupButtons[#m_popupButtons + 1] = { label = label, callback = callback };
end

local function accessibleAnnouncePopupOpen(text)
    m_popupText  = text or "";
    m_popupIndex = (#m_popupButtons >= 1) and 1 or 0;
    if m_popupText ~= "" then
        OutputMessageToScreenReader(m_popupText);
    end
    if m_popupIndex >= 1 then
        -- Queue the button label so it doesn't cut the prompt mid-word.
        OutputMessageToScreenReader(m_popupButtons[m_popupIndex].label, true);
    end
    -- Install modal handler on the active BaseMenu handler so popup nav
    -- intercepts Up/Down/Left/Right/Enter ahead of pause-menu nav. The
    -- escape hatch is built into BaseMenu's input handler (see
    -- BaseMenu.lua's _modalHandler check).
    local activeHandler = HandlerStack.active();
    if activeHandler ~= nil then
        activeHandler._modalHandler = popupModalHandler;
    end
end

local function accessibleAnnouncePopupCurrent()
    if m_popupIndex < 1 or m_popupIndex > #m_popupButtons then return; end
    OutputMessageToScreenReader(m_popupButtons[m_popupIndex].label);
end

local function accessiblePopupNav(step)
    if #m_popupButtons == 0 then return false; end
    m_popupIndex = m_popupIndex + step;
    if m_popupIndex < 1 then m_popupIndex = #m_popupButtons; end
    if m_popupIndex > #m_popupButtons then m_popupIndex = 1; end
    accessibleAnnouncePopupCurrent();
    return true;
end

local function accessibleActivatePopup()
    if m_popupIndex < 1 or m_popupIndex > #m_popupButtons then return false; end
    local btn = m_popupButtons[m_popupIndex];
    if btn == nil then return false; end
    -- Mirror PopupDialog's closeAndCallback: close first, then invoke the
    -- user callback. Reset our tracking list afterward (also detaches
    -- the modal handler so pause-menu nav resumes).
    m_kPopupDialog:Close();
    local callback = btn.callback;
    accessibleResetPopup();
    if callback then
        local ok, err = pcall(callback);
        if not ok then
            Log.error("accessibleActivatePopup callback failed: " .. tostring(err));
        end
    end
    return true;
end

-- Modal handler closure — installed onto the active BaseMenu handler's
-- _modalHandler slot while a confirmation popup is open. Runs ahead of
-- BaseMenu's pause-menu nav so Up/Down cycles Yes/No instead of the pause
-- menu underneath. Esc is NOT consumed here — BaseMenu's later Esc check
-- closes the popup via m_kPopupDialog:Close() and accessibleResetPopup().
popupModalHandler = function(key, ctrlDown, altDown, shiftDown)
    if not m_kPopupDialog:IsOpen() then
        -- Defensive: popup got closed by something other than our path
        -- (mouse click, programmatic ActivateCommand). Drop the modal
        -- handler so we don't trap input forever.
        accessibleResetPopup();
        return false;
    end
    if key == Keys.VK_LEFT or key == Keys.VK_UP then
        accessiblePopupNav(-1);
        return true;
    end
    if key == Keys.VK_RIGHT or key == Keys.VK_DOWN then
        accessiblePopupNav(1);
        return true;
    end
    if key == Keys.VK_RETURN or key == Keys.VK_SPACE then
        if accessibleActivatePopup() then
            return true;
        end
    end
    -- Other keys (incl. Esc, ?, Alt+V, Ctrl+T) fall through to BaseMenu's
    -- own handlers. Esc lands in BaseMenu's Esc clause which checks
    -- _activeSubMenu — not what we want; but our engine KeyHandler also
    -- has an Esc-while-popup-open branch that closes the popup. Whichever
    -- fires first wins; both produce the same end state.
    return false;
end
-- End CivViAccess mod change

-- ===========================================================================
--	FUNCTIONS
-- ===========================================================================

-- ===========================================================================
function OnReallyRetire()
	m_isRetired = true;
    UI.RequestAction(ActionTypes.ACTION_RETIRE);
	CloseImmediately();
	UI.PlaySound("Notification_Misc_Negative");
end

function OnRetireGame()
	-- If we're in an extended game AND we're the winner.  Just re-open the end-game menu.
	-- Otherwise, prompt for retirement.
	local me = Game.GetLocalPlayer();
	if(me) then
		local localPlayer = Players[me];
		if(localPlayer) then
			if(Game.GetWinningTeam() == localPlayer:GetTeam()) then
				LuaEvents.ShowEndGame(me);
			else
				if (not m_kPopupDialog:IsOpen()) then
					local promptText = Locale.Lookup("LOC_GAME_MENU_RETIRE_WARNING");
					local yesLabel   = Locale.Lookup("LOC_COMMON_DIALOG_YES_BUTTON_CAPTION");
					local noLabel    = Locale.Lookup("LOC_COMMON_DIALOG_NO_BUTTON_CAPTION");
					m_kPopupDialog:AddText(	  promptText);
					m_kPopupDialog:AddButton( yesLabel, OnReallyRetire, nil, nil, "PopupButtonInstanceRed" );
					m_kPopupDialog:AddButton( noLabel, nil );
					m_kPopupDialog:Open();
					-- Begin CivViAccess mod change
					accessibleResetPopup();
					accessibleAddPopupButton(yesLabel, OnReallyRetire);
					accessibleAddPopupButton(noLabel, nil);
					accessibleAnnouncePopupOpen(promptText);
					-- End CivViAccess mod change
				end
			end
		end
	end
end

-- ===========================================================================
function OnReallyRestart()
	-- Start a fresh game using the existing game configuration.
	Network.RestartGame();
end

function OnRestartGame()
	if (not m_kPopupDialog:IsOpen()) then
		local promptText = Locale.Lookup("LOC_GAME_MENU_RESTART_WARNING");
		local yesLabel   = Locale.Lookup("LOC_COMMON_DIALOG_YES_BUTTON_CAPTION");
		local noLabel    = Locale.Lookup("LOC_COMMON_DIALOG_NO_BUTTON_CAPTION");
		m_kPopupDialog:AddText(	  promptText);
		m_kPopupDialog:AddButton( yesLabel, OnReallyRestart, nil, nil, "PopupButtonInstanceRed" );
		m_kPopupDialog:AddButton( noLabel, nil );
		m_kPopupDialog:Open();
		-- Begin CivViAccess mod change
		accessibleResetPopup();
		accessibleAddPopupButton(yesLabel, OnReallyRestart);
		accessibleAddPopupButton(noLabel, nil);
		accessibleAnnouncePopupOpen(promptText);
		-- End CivViAccess mod change
	end
end

-- ===========================================================================
function DoPBCDelete()
	Network.CloudKillGame();

	-- Show killing game popup
	m_kPopupDialog:Close(); -- clear out the popup incase it is already open.
	local statusText = Locale.Lookup("LOC_GAME_MENU_DELETE_GAME_STARTED");
	m_kPopupDialog:AddText(	  statusText);
	m_kPopupDialog:Open();
	-- Begin CivViAccess mod change
	accessibleResetPopup();
	accessibleAnnouncePopupOpen(statusText);
	-- End CivViAccess mod change

	-- Next step is in OnCloudGameKilled.
end

function OnPBCDeleteButton()
	if (not m_kPopupDialog:IsOpen()) then
		local promptText = Locale.Lookup("LOC_GAME_MENU_PBC_DELETE_WARNING");
		local yesLabel   = Locale.Lookup("LOC_COMMON_DIALOG_YES_BUTTON_CAPTION");
		local noLabel    = Locale.Lookup("LOC_COMMON_DIALOG_NO_BUTTON_CAPTION");
		m_kPopupDialog:AddText(	  promptText);
		m_kPopupDialog:AddButton( yesLabel, DoPBCDelete, nil, nil, "PopupButtonInstanceRed" );
		m_kPopupDialog:AddButton( noLabel, nil );
		m_kPopupDialog:Open();
		-- Begin CivViAccess mod change
		accessibleResetPopup();
		accessibleAddPopupButton(yesLabel, DoPBCDelete);
		accessibleAddPopupButton(noLabel, nil);
		accessibleAnnouncePopupOpen(promptText);
		-- End CivViAccess mod change
	end
end

-- ===========================================================================
function DoPBCQuit()
	Network.CloudQuitGame();

	-- Show quitting game popup
	m_kPopupDialog:Close(); -- clear out the popup incase it is already open.
	local statusText = Locale.Lookup("LOC_GAME_MENU_QUITING_GAME_STARTED");
	m_kPopupDialog:AddText(	  statusText);
	m_kPopupDialog:Open();
	-- Begin CivViAccess mod change
	accessibleResetPopup();
	accessibleAnnouncePopupOpen(statusText);
	-- End CivViAccess mod change

	-- Next step is in OnCloudGameQuit.
end

function OnPBCQuitButton()
	if (not m_kPopupDialog:IsOpen()) then
		local promptText = Locale.Lookup("LOC_GAME_MENU_PBC_QUIT_WARNING");
		local yesLabel   = Locale.Lookup("LOC_COMMON_DIALOG_YES_BUTTON_CAPTION");
		local noLabel    = Locale.Lookup("LOC_COMMON_DIALOG_NO_BUTTON_CAPTION");
		m_kPopupDialog:AddText(	  promptText);
		m_kPopupDialog:AddButton( yesLabel, DoPBCQuit, nil, nil, "PopupButtonInstanceRed" );
		m_kPopupDialog:AddButton( noLabel, nil );
		m_kPopupDialog:Open();
		-- Begin CivViAccess mod change
		accessibleResetPopup();
		accessibleAddPopupButton(yesLabel, DoPBCQuit);
		accessibleAddPopupButton(noLabel, nil);
		accessibleAnnouncePopupOpen(promptText);
		-- End CivViAccess mod change
	end
end

-- ===========================================================================
function OnExitGame()
	local pFriends = Network.GetFriends();
	if pFriends ~= nil then
        pFriends:ClearRichPresence();
    end

    Events.UserConfirmedClose();
end

-- ===========================================================================
function OnCancelExit()
	if m_isNeedRestoreOptions then Controls.Options:SetHide( false); end
	if m_isNeedRestoreSaveGameMenu then Controls.SaveGameMenu:SetHide( false); end
	if m_isNeedRestoreLoadGameMenu then Controls.LoadGameMenu:SetHide( false ); end
	-- Begin CivViAccess mod change: dismiss the pause menu when NO was
	-- chosen on an Alt+F4 prompt that raised the pause menu just to host
	-- the popup. Without this, the user picks NO, the popup closes, and
	-- they're left staring at the pause menu they never asked for. Also
	-- speak confirmation so the user knows NO took effect — Noel
	-- 2026-05-24 hit NO and had "no idea what it did" because nothing
	-- audible signaled the cancel.
	if m_isRaisedForExitConfirm then
		m_isRaisedForExitConfirm = false;
		Log.info("OnCancelExit: dismissing pause menu raised for Alt+F4 confirmation");
		if OutputMessageToScreenReader ~= nil then
			OutputMessageToScreenReader("Exit cancelled. Back to game.");
		end
		CloseImmediately();
		-- CloseImmediately dequeues the popup but doesn't pop the input
		-- context — the user reported being "not in the game" after NO
		-- because Input.GetActiveContext() was still GameOptions and
		-- world keys (hex move, period cycle) didn't reach the world
		-- handler. Pop it manually so input flows back to InGame.
		if Input ~= nil and Input.GetActiveContext ~= nil
		   and Input.GetActiveContext() == InputContext.GameOptions then
			Log.info("OnCancelExit: popping GameOptions input context");
			Input.PopContext();
		end
	end
	-- End CivViAccess mod change
end

-- ===========================================================================
function OnExitGameAskAreYouSure()
	if (not m_kPopupDialog:IsOpen()) then

		-- Menus that may be up; same prioritiy as in-game menu which is
		-- problematic for raising a non-content, non-queue "popup" message
		m_isNeedRestoreOptions = UIManager:IsInPopupQueue(Controls.Options);
		m_isNeedRestoreSaveGameMenu = UIManager:IsInPopupQueue(Controls.SaveGameMenu);
		m_isNeedRestoreLoadGameMenu = UIManager:IsInPopupQueue(Controls.LoadGameMenu);
		Controls.Options:SetHide( true );
		Controls.SaveGameMenu:SetHide( true );
		Controls.LoadGameMenu:SetHide( true );

		-- Begin CivViAccess mod change: capture strings for both engine UI
		-- and screen-reader announce. Alt+F4 routes here via OnRequestClose,
		-- so this is also where the Alt+F4 confirmation gets its voice.
		local promptText = Locale.Lookup("LOC_GAME_MENU_QUIT_WARNING");
		local yesLabel   = Locale.Lookup("LOC_COMMON_DIALOG_YES_BUTTON_CAPTION");
		local noLabel    = Locale.Lookup("LOC_COMMON_DIALOG_NO_BUTTON_CAPTION");
		-- End CivViAccess mod change

		m_kPopupDialog:AddText(	  promptText);
		m_kPopupDialog:AddButton( yesLabel, OnExitGame, nil, nil, "PopupButtonInstanceRed" );
		m_kPopupDialog:AddButton( noLabel, OnCancelExit );
		m_kPopupDialog:Open();

		-- Begin CivViAccess mod change
		accessibleResetPopup();
		accessibleAddPopupButton(yesLabel, OnExitGame);
		accessibleAddPopupButton(noLabel, OnCancelExit);
		accessibleAnnouncePopupOpen(promptText);
		-- End CivViAccess mod change
	end
end

-- ===========================================================================
function OnMainMenu()
	ms_ExitToMain = true;
	if (not m_kPopupDialog:IsOpen()) then
		local promptText = Locale.Lookup("LOC_GAME_MENU_EXIT_WARNING");
		local yesLabel   = Locale.Lookup("LOC_COMMON_DIALOG_YES_BUTTON_CAPTION");
		local noLabel    = Locale.Lookup("LOC_COMMON_DIALOG_NO_BUTTON_CAPTION");
		m_kPopupDialog:AddText(	  promptText);
		m_kPopupDialog:AddButton( yesLabel, OnYes, nil, nil, "PopupButtonInstanceRed" );
		m_kPopupDialog:AddButton( noLabel, OnNo );
		m_kPopupDialog:Open();
		-- Begin CivViAccess mod change
		accessibleResetPopup();
		accessibleAddPopupButton(yesLabel, OnYes);
		accessibleAddPopupButton(noLabel, OnNo);
		accessibleAnnouncePopupOpen(promptText);
		-- End CivViAccess mod change
	end
end

-- ===========================================================================
function OnQuickSaveGame()
	if (CanLocalPlayerSaveGame()) then
		local gameFile = {};
		gameFile.Name = "quicksave";
		gameFile.Location = SaveLocations.LOCAL_STORAGE;
		gameFile.Type= Network.GetGameConfigurationSaveType();
		gameFile.IsAutosave = false;
		gameFile.IsQuicksave = true;

		Network.SaveGame(gameFile);
		UI.PlaySound("Confirm_Bed_Positive");
		-- Begin CivViAccess mod change: confirm quicksave audibly. The engine
		-- plays Confirm_Bed_Positive but a screen-reader user has no other
		-- signal that the save fired.
		OutputMessageToScreenReader("Quicksave");
		-- End CivViAccess mod change
	end
end

-- ===========================================================================
function OnOptions()
	Controls.PauseWindow:SetHide(true);
	UIManager:QueuePopup(Controls.Options, PopupPriority.Current);
end

-- ===========================================================================
function OnLoadGame()
	if (CanLocalPlayerLoadGame()) then
		Controls.PauseWindow:SetHide(true);
		LuaEvents.InGameTopOptionsMenu_SetLoadGameServerType(ServerType.SERVER_TYPE_NONE);
		UIManager:QueuePopup(Controls.LoadGameMenu, PopupPriority.Current);
	end
end

-- ===========================================================================
function OnSaveGame()
	if (CanLocalPlayerSaveGame()) then
		Controls.PauseWindow:SetHide(true);
		UIManager:QueuePopup(Controls.SaveGameMenu, PopupPriority.Current);
	end
end

-- ===========================================================================
function CloseImmediately()
	if UIManager:IsInPopupQueue( ContextPtr ) then
		LuaEvents.InGameTopOptionsMenu_Close();
		UIManager:DequeuePopup( ContextPtr );
		UI.SetSoundStateValue("Game_Views", "Normal_View");
	end
	m_isClosing = false;
end

-- ===========================================================================
function Close()
	if(m_isClosing) then
		print("Menu is already closing.");
		return;
	end

	m_isClosing = true;

	EffectsManager:ResumeAllEffects();	-- Resume any continous particle effects.

	if(Controls.AlphaIn:IsStopped()) then
		-- Animation is good for a nice clean animation out..
		Controls.AlphaIn:Reverse();
		Controls.SlideIn:Reverse();
		Controls.PauseWindowClose:SetToBeginning();
		Controls.PauseWindowClose:Play();
	else
		-- Animation is not in an expected state, just reset all...
		Controls.AlphaIn:SetToBeginning();
		Controls.SlideIn:SetToBeginning();
		Controls.PauseWindowClose:SetToBeginning();
		ShutdownAfterClose();
		UI.DataError("Forced closed() of the in game top options menu.  (Okay if someone was spamming ESC.)");
	end


	local playerChange =  ContextPtr:LookUpControl( "/InGame/PlayerChange" );
	if (not UIManager:IsInPopupQueue(playerChange)) then
		LuaEvents.InGameTopOptionsMenu_Close();
	end

	-- Begin ScreenReaderAccess mod change
	-- Audible confirmation that the pause menu has closed. Without this
	-- the user pressed "Return to Game", heard nothing, and was stuck not
	-- knowing what state the game was in (Noel 2026-05-24 test).
	if OutputMessageToScreenReader ~= nil then
		OutputMessageToScreenReader("Returned to game");
	end
	-- End ScreenReaderAccess mod change

	-- Only pop the context if what we expect is the current context.
	if(Input.GetActiveContext() == InputContext.GameOptions) then
		Input.PopContext();
	else
		print("Expected a different input active context...");
	end
end

-- ===========================================================================
function ShutdownAfterClose()
	m_isClosing = false;
	UIManager:DequeuePopup( ContextPtr );
	UI.SetSoundStateValue("Game_Views", "Normal_View");
	UI.PlaySound("UI_Pause_Menu_On");
end

-- ===========================================================================
--	UI callback
-- ===========================================================================
function OnReturn()
	if (not ContextPtr:IsHidden() and m_isClosing ~= true) then
		Close();
	end
end

-- ===========================================================================
--	LUA Event
--	Reduce the # of options in the menu (for tutorial purposes)
-- ===========================================================================
function OnSimpleInGameMenu( isSimpleMenu )

	-- For the demo, always keep it simple
	if UI.HasFeature("Demo") then
		isSimpleMenu = true;
	end

	if isSimpleMenu == nil then isSimpleMenu = true; end
	m_isSimpleMenu = isSimpleMenu;
end

-- ===========================================================================
function SetupButtons()

	local bIsObserver : boolean = false;
	local localPlayerID : number = Game.GetLocalPlayer();
	if(localPlayerID ~= PlayerTypes.NONE)then
		local localPlayerConfig = PlayerConfigurations[Game.GetLocalPlayer()];
		bIsObserver = not localPlayerConfig:IsAlive();
	end
	local bWorldBuilder : boolean = WorldBuilder and WorldBuilder:IsActive();
	local bIsAutomation : boolean = Automation.IsActive();
	local bIsMultiplayer: boolean = GameConfiguration.IsAnyMultiplayer();
	local bCanSave		: boolean = CanLocalPlayerSaveGame();
	local bCanLoad		: boolean = CanLocalPlayerLoadGame();
	local bCanRestart	: boolean = not GameConfiguration.IsAnyMultiplayer()
					-- TTP 34989 - Only allow restarts in hotseat if this is not a loaded save.
					-- The restart mechanic uses the game configuration prior to the very beginning of the game.
					-- This can be unexpected if the user changed the player types post launch.
					or (GameConfiguration.IsHotseat() and not GameConfiguration.IsSavedGame());

	-- Restarting in worldbuilder can cause a bunch of problems, disabling for now.
	bCanRestart = bCanRestart and not bWorldBuilder;

	local bIsLocalPlayersTurn : boolean = IsLocalPlayerTurnActive();

	if(bWorldBuilder) then
		Controls.ReturnButton:LocalizeAndSetText("{LOC_GAME_MENU_RETURN_TO_WORLDBUILDER:upper}");
		Controls.SaveGameButton:LocalizeAndSetText("{LOC_SAVE_MAP_BUTTON:upper}");
	else
		Controls.ReturnButton:LocalizeAndSetText("{LOC_GAME_MENU_RETURN_TO_GAME:upper}");
		Controls.SaveGameButton:LocalizeAndSetText("{LOC_GAME_MENU_SAVE:upper}");
	end

	Controls.QuickSaveButton:SetDisabled( not bCanSave );
	Controls.SaveGameButton:SetDisabled( not bCanSave );
	Controls.LoadGameButton:SetDisabled( not bCanLoad );
	Controls.RetireButton:SetDisabled( not bIsLocalPlayersTurn );

	Controls.QuickSaveButton:SetHide(m_isSimpleMenu or bIsAutomation or bWorldBuilder);
	Controls.SaveGameButton:SetHide(m_isSimpleMenu or bIsAutomation);
	Controls.LoadGameButton:SetHide(m_isSimpleMenu or bIsAutomation or bIsMultiplayer or bWorldBuilder);
	Controls.OptionsButton:SetHide(bIsAutomation or not CanLocalPlayerChangeOptions());

	if(bIsObserver)then
		Controls.QuickSaveButton:SetToolTipString(Locale.Lookup("LOC_SAVE_OBSERVER_MODE_TT"));
		Controls.SaveGameButton:SetToolTipString(Locale.Lookup("LOC_SAVE_OBSERVER_MODE_TT"));
	end

	-- Eventually remove this check.  Retiring after winning is perfectly fine
	-- so long as we update the tooltip to no longer state the player will be defeated.
	local bAlreadyWonOrLost = false;
	local me = Game.GetLocalPlayer();
	if(me) then
		local localPlayer = Players[me];
		if(localPlayer) then
			local winningTeam : number = Game.GetWinningTeam();
			local localPlayerTeam : number = localPlayer:GetTeam();
			if(winningTeam == localPlayerTeam or (winningTeam ~= nil and winningTeam ~= localPlayerTeam)) then
				bAlreadyWonOrLost = true;
			end
		end
	end

	if(GameConfiguration.IsPlayByCloud()) then
		if(Network.IsGameHost()) then
			Controls.PBCDeleteButton:SetHide(false);
		else
			Controls.PBCDeleteButton:SetHide(true);
		end
		Controls.PBCQuitButton:SetHide(false);
	else
		Controls.PBCDeleteButton:SetHide(true);
		Controls.PBCQuitButton:SetHide(true);
	end

	Controls.RetireButton:SetHide(m_isSimpleMenu or bIsAutomation or bIsMultiplayer or bAlreadyWonOrLost or bWorldBuilder);
	Controls.RestartButton:SetHide( not bCanRestart );

	Controls.ExitGameButton:SetHide(false);

	if (m_isSimpleMenu==false) then
		RefreshModsInUse();
	end
	RefreshIconData();

	Controls.MainStack:CalculateSize();
end

function RefreshIconData()

	-- Check for an invalid local player first!
	local eLocalPlayer :number = Game.GetLocalPlayer();
	if (eLocalPlayer < 0) then
		return;
	end

	m_pPlayer= Players[eLocalPlayer];

	m_primaryColor, m_secondaryColor  = UI.GetPlayerColors( m_pPlayer:GetID() );
	local darkerBackColor = UI.DarkenLightenColor(m_primaryColor,(-85),100);
	local brighterBackColor = UI.DarkenLightenColor(m_primaryColor,90,255);

	-- Icon colors
	Controls.CivBacking_Base:SetColor(m_primaryColor);
	Controls.CivBacking_Lighter:SetColor(brighterBackColor);
	Controls.CivBacking_Darker:SetColor(darkerBackColor);
	Controls.CivIcon:SetColor(m_secondaryColor);

	local pPlayerConfig:table = PlayerConfigurations[m_pPlayer:GetID()];

	local leaderTypeName:string = pPlayerConfig:GetLeaderTypeName();
	if leaderTypeName ~= nil then
		local leaderIconName = ICON_PREFIX..leaderTypeName;
		-- Set Leader Icon
		Controls.LeaderIcon:SetIcon(leaderIconName);
		local leaderTooltip = GameInfo.Leaders[leaderTypeName].Name;
		Controls.LeaderIcon:SetToolTipString(Locale.Lookup(leaderTooltip));
	else
		UI.DataError("Invalid type name returned by GetLeaderTypeName");
	end

	local civTypeName:string = pPlayerConfig:GetCivilizationTypeName();
	if civTypeName ~= nil then
		local civIconName = ICON_PREFIX..civTypeName;
		-- Set Civ Icon
		Controls.CivIcon:SetIcon(civIconName);
		civTooltip = GameInfo.Civilizations[civTypeName].Name;
		Controls.CivIcon:SetToolTipString(Locale.Lookup(civTooltip));
	else
		UI.DataError("Invalid type name returned by GetCivilizationTypeName");
	end

	-- Game difficulty
	local playerConfig:table = PlayerConfigurations[eLocalPlayer];
	local gameDifficultyTypeID = playerConfig:GetHandicapTypeID();
	local gameDifficultyType = GameInfo.Difficulties[gameDifficultyTypeID].DifficultyType;
	Controls.GameDifficulty:SetIcon(ICON_PREFIX..gameDifficultyType);
	local difficultyTooltip = Locale.Lookup("LOC_MULTIPLAYER_DIFFICULTY_HEADER")..":[NEWLINE]"..Locale.Lookup(GameInfo.Difficulties[gameDifficultyTypeID].Name);
	Controls.GameDifficulty:SetToolTipString(difficultyTooltip);

	local gameSpeedType = GameInfo.GameSpeeds[GameConfiguration.GetGameSpeedType()].GameSpeedType;
	Controls.GameSpeed:SetIcon(ICON_PREFIX..gameSpeedType);
	local speedTooltip = Locale.Lookup("LOC_AD_SETUP_GAME_SPEED")..":[NEWLINE]"..Locale.Lookup(GameInfo.GameSpeeds[GameConfiguration.GetGameSpeedType()].Name);
	Controls.GameSpeed:SetToolTipString(speedTooltip);
end

-- ===========================================================================
function OnYes( )

   	UIManager:SetUICursor( 1 );
	UITutorialManager:EnableOverlay( false );
	UITutorialManager:HideAll();

	-- make sure any reference map is cleared
	StrategicView_ClearReferenceMap();

	UIManager:Log("Shutting down via user exit on menu.");
	-- Begin CivViAccess mod change: Noel 2026-05-24 — exit-to-main-menu
	-- transition is silent and takes several seconds while the game
	-- shuts down and the main menu rebuilds. Speak so the user knows
	-- something is happening and isn't staring at silence wondering if
	-- the keypress registered.
	if OutputMessageToScreenReader ~= nil then
		if ms_ExitToMain then
			OutputMessageToScreenReader("Returning to main menu.");
		else
			OutputMessageToScreenReader("Exiting game.");
		end
	end
	-- End CivViAccess mod change
	if(ms_ExitToMain) then
		Events.ExitToMainMenu();
	else
		UI.ExitGame();
	end
end

-- ===========================================================================
function OnNo( )
	m_kPopupDialog:Close();
end

-- ===========================================================================
function KeyHandler( key:number )
	local bHandled:boolean = false;

	-- Begin CivViAccess mod change: arrow nav + Enter inside an open popup.
	-- These checks run BEFORE the engine's Esc handler so the user can walk
	-- between Yes/No and activate without ever needing the mouse. Civ V
	-- Access's popup-nav-standard sets the same idiom across the project.
	if m_kPopupDialog:IsOpen() then
		if key == Keys.VK_LEFT or key == Keys.VK_UP then
			accessiblePopupNav(-1);
			return true;
		end
		if key == Keys.VK_RIGHT or key == Keys.VK_DOWN then
			accessiblePopupNav(1);
			return true;
		end
		if key == Keys.VK_RETURN or key == Keys.VK_SPACE then
			if accessibleActivatePopup() then
				return true;
			end
		end
	end
	-- End CivViAccess mod change

	if key == Keys.VK_ESCAPE then
		if m_kPopupDialog:IsOpen() then
			m_kPopupDialog:Close();
			-- Begin CivViAccess mod change
			accessibleResetPopup();
			-- End CivViAccess mod change
		else
			if (not ContextPtr:IsHidden() ) then
				Close();
			end
		end
		bHandled = true;
	end
	return bHandled;
end

-- ===========================================================================
--	If this is receiving input (e.g., is visible) then do not let any input
--	fall past it.  Forge will send input to popups and children first before
--	this context gets a crack at it.
-- ===========================================================================
function OnInput( pInputStruct:table )
	local uiMsg:number = pInputStruct:GetMessageType();
	local key:number = pInputStruct:GetKey();

	if uiMsg == KeyEvents.KeyUp then
		return KeyHandler( pInputStruct:GetKey() );
	elseif uiMsg == KeyEvents.KeyDown and not (key == Keys.VK_ALT or key == Keys.VK_CONTROL or key == Keys.VK_SHIFT) then
		-- Don't consume Alt, Control, or Shift so those can be used for keybindings
		return true;
	end

	return false;
end

-- ===========================================================================
function RefreshModsInUse()
	local mods : table = Modding.GetActiveMods();

	g_ModListingsManager:ResetInstances();

	local modNames : table = {};
	for i,v in ipairs(mods) do
		modNames[i] = Locale.Lookup(v.Name);
	end

	table.sort(modNames, function(a,b) return Locale.Compare(a,b) == -1 end);

	if (GameConfiguration.GetEnabledGameModesMetaString ~= nil) then
		local enabledModesMetaData : string = GameConfiguration.GetEnabledGameModesMetaString();
		if (enabledModesMetaData ~= nil) then
			-- Use the modding system to break up the string
			local enabledGameModeNames : table = Modding.GetGameModesFromConfigurationString(enabledModesMetaData);
			table.sort(enabledGameModeNames, function(a,b) return Locale.Compare(a.Name,b.Name) == -1 end);
			for k,v in ipairs(enabledGameModeNames)do
				local instance : table = g_ModListingsManager:GetInstance();

				instance.ModTitle:SetText(v.Name);
			end
			local spacerInstance : table = g_ModListingsManager:GetInstance();
			spacerInstance.ModTitle:SetText(" ");
		end
	end

	for i,v in ipairs(modNames) do
		local instance : table = g_ModListingsManager:GetInstance();

		instance.ModTitle:SetText(v);
	end

	Controls.ModListingsStack:CalculateSize();
	Controls.ModListings:CalculateSize();
	Controls.ModsInUse:SetHide( (#mods == 0) or m_isSimpleMenu );
	Controls.MainStack:CalculateSize();
end

-- ===========================================================================
function OnOpenInGameOptionsMenu()
	-- Don't show pause menu if the player has retired (forfeit) from the game - fixes TTP 20129
	if not m_isRetired then
		UIManager:QueuePopup( ContextPtr, PopupPriority.InGameTopOptionsMenu, { AlwaysVisibleInQueue = true } );
	end
end

-- ===========================================================================
--	Raised (typically) from InGame since when this is hidden it will not
--	receive input from ForgeUI.
-- ===========================================================================
function OnShow()
	Log.info("InGameTopOptionsMenu.OnShow: called (m_isClosing=" .. tostring(m_isClosing) .. ")");

	if m_isClosing then
		print("Show was requested on menu that is in the midst of closing.");
		return;
	end

	-- Stop any particle effects from drawing on top of the menu.
	EffectsManager:PauseAllEffects();

	-- do not re-push the context if we're already in the GameOptions context
	-- (e.g. returning from a sub-screen)
	if Input.GetActiveContext() ~= InputContext.GameOptions then
		Input.PushActiveContext( InputContext.GameOptions );
	end

    LuaEvents.InGameTopOptionsMenu_Show();
	UI.PlaySound("UI_Pause_Menu_On");
	UI.SetSoundStateValue("Game_Views", "Paused");

	Controls.AlphaIn:SetToBeginning();
	Controls.AlphaIn:Play();
	Controls.SlideIn:SetToBeginning();
	Controls.SlideIn:Play();

	-- Reset interface mode... may want to re-evaluate this if there are
	-- common situation(s) where a player is in a difference interface mode
	-- and are bringing up this menu.
	if WorldBuilder:IsActive() then
		UI.SetInterfaceMode( InterfaceModeTypes.WB_SELECT_PLOT );
	else
		UI.SetInterfaceMode( InterfaceModeTypes.SELECTION );
	end

	SetupButtons();

	-- Do not deselect all as on-rails scenarios (e.g., tutorials) may get out of sync.
	Controls.PauseWindow:SetHide(false);

	if WorldBuilder and WorldBuilder:IsActive() then
		Controls.DetailsBox:SetHide(true);
	else
		Controls.DetailsBox:SetHide(false);
	end

end

-- ===========================================================================
function OnLoadGameViewStateDone()
	m_isLoadingDone = true;
	print("[CivViAccess][INFO ] InGameTopOptionsMenu: m_isLoadingDone=true via LoadGameViewStateDone");
end

-- ===========================================================================
-- Belt-and-suspenders: Events.LoadGameViewStateDone doesn't fire on all
-- Civ VI configurations (confirmed via Noel's 2026-05-24 Lua.log — that
-- event never appeared despite a complete in-game session). LoadScreen
-- Close fires reliably and signals roughly the same moment ("game is
-- now interactive"). Setting the flag from both means Alt+F4 in-game
-- triggers the exit-confirmation popup instead of silent exit, regardless
-- of which event the engine actually fires.
function OnLoadScreenCloseForReadyFlag()
	if not m_isLoadingDone then
		m_isLoadingDone = true;
		print("[CivViAccess][INFO ] InGameTopOptionsMenu: m_isLoadingDone=true via LoadScreenClose (fallback)");
	end
end

-- ===========================================================================
function OnCloudGameQuit( matchID, success )
	if(success) then
		-- On success, indicate success and exit to main menu.
		m_kPopupDialog:Close();
		local msg = Locale.Lookup("LOC_GAME_MENU_QUITING_GAME_SUCCESS");
		m_kPopupDialog:AddText(	  msg);
		m_kPopupDialog:Open();
		-- Begin CivViAccess mod change
		accessibleResetPopup();
		accessibleAnnouncePopupOpen(msg);
		-- End CivViAccess mod change

		ms_ExitToMain = true;
		OnYes( );
	else
		--Show error prompt.
		m_kPopupDialog:Close();
		local msg     = Locale.Lookup("LOC_GAME_MENU_QUITING_GAME_FAIL");
		local btnText = Locale.Lookup("LOC_GAME_MENU_QUITING_GAME_FAIL_ACCEPT");
		m_kPopupDialog:AddText(	  msg);
		m_kPopupDialog:AddButton( btnText );
		m_kPopupDialog:Open();
		-- Begin CivViAccess mod change
		accessibleResetPopup();
		accessibleAddPopupButton(btnText, nil);
		accessibleAnnouncePopupOpen(msg);
		-- End CivViAccess mod change
	end
end

-- ===========================================================================
function OnCloudGameKilled( matchID, success )
	if(success) then
		-- On success, indicate success and exit to main menu.
		m_kPopupDialog:Close();
		local msg = Locale.Lookup("LOC_GAME_MENU_DELETE_GAME_SUCCESS");
		m_kPopupDialog:AddText(	  msg);
		m_kPopupDialog:Open();
		-- Begin CivViAccess mod change
		accessibleResetPopup();
		accessibleAnnouncePopupOpen(msg);
		-- End CivViAccess mod change

		ms_ExitToMain = true;
		OnYes( );
	else
		--Show error prompt.
		m_kPopupDialog:Close();
		local msg     = Locale.Lookup("LOC_GAME_MENU_DELETE_GAME_FAIL");
		local btnText = Locale.Lookup("LOC_GAME_MENU_DELETE_GAME_FAIL_ACCEPT");
		m_kPopupDialog:AddText(	  msg);
		m_kPopupDialog:AddButton( btnText );
		m_kPopupDialog:Open();
		-- Begin CivViAccess mod change
		accessibleResetPopup();
		accessibleAddPopupButton(btnText, nil);
		accessibleAnnouncePopupOpen(msg);
		-- End CivViAccess mod change
	end
end

-- ===========================================================================
-- Generic handler for event that should trigger a refresh of the Setup Buttons.
function EventRefreshButtons()
	if (not ContextPtr:IsHidden()) then
		SetupButtons();
	end
end

-- ===========================================================================
function OnRequestClose()
	-- Diagnostic: Alt+F4 closes silently on Noel's machine (2026-05-24)
	-- when this handler should be routing through OnExitGameAskAreYouSure.
	-- Log each gate to identify which branch is causing the skip.
	print("[CivViAccess][INFO ] OnRequestClose: fired"
		.. " m_isEndGameOpen=" .. tostring(m_isEndGameOpen)
		.. " m_isLoadingDone=" .. tostring(m_isLoadingDone)
		.. " Benchmark.IsEnabled=" .. tostring(Benchmark.IsEnabled())
		.. " PopupQueueDisabled=" .. tostring(UIManager:IsPopupQueueDisabled())
		.. " ContextPtr:IsHidden=" .. tostring(ContextPtr:IsHidden()));
	-- End Game Screen handles this
	if m_isEndGameOpen then
		print("[CivViAccess][INFO ] OnRequestClose: m_isEndGameOpen=true, early return");
		return;
	end
	if m_isLoadingDone and (Benchmark.IsEnabled()==false) then
		-- Only handle the message if popup queuing is active (diplomacy is not up)
		if UIManager:IsPopupQueueDisabled()==false then
			if (ContextPtr:IsHidden() ) then
				-- Begin CivViAccess mod change: SET FLAG BEFORE QueuePopup.
				-- QueuePopup synchronously fires OnShow → BaseMenu.onActivate
				-- → suppressInitialAnnounce check. If we set the flag AFTER
				-- QueuePopup, the suppress check sees flag=false and speaks
				-- "Pause menu. Return to game." before the popup arrives.
				-- Confirmed via log lines 242-262 (no suppress) vs 280-298
				-- (suppress worked because flag leaked from prior attempt
				-- where Esc-dismiss bypassed OnCancelExit's reset). Bug #26b
				-- round 2 2026-05-24.
				m_isRaisedForExitConfirm = true;
				UIManager:QueuePopup( ContextPtr, PopupPriority.Utmost, { AlwaysVisibleInQueue = true } );
				-- End CivViAccess mod change
			end
			print("[CivViAccess][INFO ] OnRequestClose: calling OnExitGameAskAreYouSure");
			OnExitGameAskAreYouSure();
		else
			print("[CivViAccess][INFO ] OnRequestClose: PopupQueueDisabled=true, skipping confirmation");
		end
	else
		print("[CivViAccess][INFO ] OnRequestClose: m_isLoadingDone=false or benchmark, calling UserConfirmedClose (silent exit)");
		Events.UserConfirmedClose();
	end
end

-- ===========================================================================
--	Dervive off this in a MOD file for adding additional functionality
-- ===========================================================================
function LateInitialize()
end

-- ===========================================================================
function OnInit( isReload:boolean )
	LateInitialize();
	if isReload then
		if not ContextPtr:IsHidden() then
			OnShow();
		end
	end
end

-- Begin CivViAccess mod change: BaseMenu nav for the pause-menu buttons.
-- Items are rebuilt on every show so visibility changes (multiplayer hides
-- Restart, observer disables Save, etc.) flow through cleanly. Each Button
-- delegates to the engine's existing top-level callback so behavior is
-- exactly what mouse-click does.
-- Read the label from the actual engine button widget. The XML sets each
-- button's text via LocalizeAndSetText with the correct LOC key for the
-- current language and mode (Return swaps text in world-builder; Save
-- swaps to "Save Map" in world-builder; etc.). Reading from the widget
-- means we always speak exactly what sighted users see — no guessing at
-- LOC keys, no drift if Firaxis renames one.
local function labelFromControl(controlName)
    return function()
        local c = Controls[controlName];
        if c == nil or c.GetText == nil then return controlName; end
        return c:GetText();
    end;
end

local function buildPauseMenuItems()
    Log.info("buildPauseMenuItems: starting");
    local items = {};

    -- Visible-button gate: SetupButtons() flips :SetHide on conditional
    -- buttons (multiplayer hides Restart, observer disables Save, etc.).
    -- buildPauseMenuItems re-runs on each show, so the visibility set is
    -- always current.
    local function addIfVisible(controlName, activate)
        local c = Controls[controlName];
        if c == nil then
            Log.info("  buildPauseMenuItems: " .. controlName .. " = NIL (skipped)");
            return;
        end
        local hidden = c.IsHidden ~= nil and c:IsHidden();
        local textOk, text = pcall(function() return c.GetText and c:GetText() or "?"; end);
        if not textOk then text = "(GetText threw)"; end
        Log.info("  buildPauseMenuItems: " .. controlName
                .. " hidden=" .. tostring(hidden)
                .. " text='" .. tostring(text) .. "'");
        if hidden then return; end
        items[#items + 1] = BaseMenuItems.Button({
            controlName = controlName,
            labelFn     = labelFromControl(controlName),
            activate    = activate,
        });
    end

    -- Order mirrors the visual layout: Return first, exit-class actions last.
    addIfVisible("ReturnButton",     OnReturn);
    addIfVisible("QuickSaveButton",  OnQuickSaveGame);
    addIfVisible("SaveGameButton",   OnSaveGame);
    addIfVisible("LoadGameButton",   OnLoadGame);
    addIfVisible("OptionsButton",    OnOptions);
    addIfVisible("RestartButton",    OnRestartGame);
    addIfVisible("RetireButton",     OnRetireGame);
    addIfVisible("PBCDeleteButton",  OnPBCDeleteButton);
    addIfVisible("PBCQuitButton",    OnPBCQuitButton);
    addIfVisible("MainMenuButton",   OnMainMenu);
    addIfVisible("ExitGameButton",   OnExitGameAskAreYouSure);

    Log.info("buildPauseMenuItems: returning " .. #items .. " items");
    return items;
end

local PAUSE_MENU_HELP_ENTRIES = {
    { keyLabel = "Up/Down",  description = "Move between pause-menu items" },
    { keyLabel = "Enter",    description = "Activate focused item" },
    { keyLabel = "Escape",   description = "Close pause menu (or close open confirmation)" },
    { keyLabel = "Left/Right", description = "Move between Yes/No inside a confirmation popup" },
    { keyLabel = "Alt+F4",   description = "Open exit-game confirmation (same as Exit Game button)" },
};
-- End CivViAccess mod change

-- ===========================================================================
function Initialize()
	Log.info("InGameTopOptionsMenu.Initialize: starting");

	ContextPtr:SetInitHandler( OnInit );

	-- Begin CivViAccess mod change: route input + show through BaseMenu.install
	-- instead of installing the engine's OnInput / OnShow directly. BaseMenu's
	-- handlers chain to OnInput / OnShow via priorInput / priorShow so the
	-- engine's existing logic (KeyHandler, SetupButtons, animation play) runs
	-- exactly as before — BaseMenu just wraps it with arrow-key nav, announce,
	-- and HandlerStack registration for ? help.
	-- displayName: use a literal "Pause menu" since LOC_GAME_MENU_PAUSE_MENU
	-- isn't an established engine key. Translators will catch this when the
	-- LOC pass happens.
	local baseMenuHandler = BaseMenu.install(ContextPtr, {
		name = "InGameTopOptionsMenu",
		displayName = "Pause menu",
		items = buildPauseMenuItems,
		helpEntries = PAUSE_MENU_HELP_ENTRIES,
		priorInput = OnInput,
		priorShow = OnShow,
		-- When Alt+F4 raises the pause menu purely to host the exit
		-- confirmation popup, suppress the "Pause menu. Return to game."
		-- announce — otherwise user hears that chatter just before
		-- "Do you wish to exit?" and it's confusing (Noel 2026-05-24).
		suppressInitialAnnounce = function()
			return m_isRaisedForExitConfirm == true;
		end,
	});

	-- Begin CivViAccess mod change: route arrow / Enter to the exit-
	-- confirmation popup when it's open. Without this, Alt+F4 in-game
	-- opens BOTH the pause menu AND the confirmation popup; BaseMenu's
	-- nav captures arrows for pause-menu items so the user can't reach
	-- the popup's Yes / No buttons. Confirmed via Noel's 2026-05-24
	-- Lua.log — arrows walked through pause-menu list while Yes / No
	-- were unreachable.
	--
	-- BaseMenu exposes a _modalHandler escape hatch (see BaseMenu.lua
	-- line 873) that runs ahead of dispatchKey. We install one that
	-- lazily checks m_kPopupDialog:IsOpen() — when no popup is open,
	-- it returns false and BaseMenu's normal nav takes over.
	if baseMenuHandler ~= nil then
		baseMenuHandler._modalHandler = function(key, ctrlDown, altDown, shiftDown)
			if m_kPopupDialog == nil or not m_kPopupDialog:IsOpen() then
				return false;
			end
			if key == Keys.VK_LEFT or key == Keys.VK_UP then
				accessiblePopupNav(-1);
				return true;
			end
			if key == Keys.VK_RIGHT or key == Keys.VK_DOWN then
				accessiblePopupNav(1);
				return true;
			end
			if key == Keys.VK_RETURN or key == Keys.VK_SPACE then
				if accessibleActivatePopup() then
					return true;
				end
			end
			-- Esc not handled here so BaseMenu's normal Esc path runs,
			-- which routes through priorInput → KeyHandler, which closes
			-- the popup via m_kPopupDialog:Close() + accessibleResetPopup.
			return false;
		end;
	end
	-- End CivViAccess mod change

	Controls.ExitGameButton:RegisterCallback( Mouse.eLClick, OnExitGameAskAreYouSure );
	Controls.ExitGameButton:RegisterCallback( Mouse.eMouseEnter, function() UI.PlaySound("Main_Menu_Mouse_Over"); end);
	Controls.LoadGameButton:RegisterCallback( Mouse.eLClick, OnLoadGame );
	Controls.LoadGameButton:RegisterCallback( Mouse.eMouseEnter, function() UI.PlaySound("Main_Menu_Mouse_Over"); end);
	Controls.MainMenuButton:RegisterCallback( Mouse.eLClick, OnMainMenu );
	Controls.MainMenuButton:RegisterCallback( Mouse.eMouseEnter, function() UI.PlaySound("Main_Menu_Mouse_Over"); end);
	Controls.OptionsButton:RegisterCallback( Mouse.eLClick, OnOptions );
	Controls.OptionsButton:RegisterCallback( Mouse.eMouseEnter, function() UI.PlaySound("Main_Menu_Mouse_Over"); end);
	Controls.QuickSaveButton:RegisterCallback( Mouse.eLClick, OnQuickSaveGame );
	Controls.QuickSaveButton:RegisterCallback( Mouse.eMouseEnter, function() UI.PlaySound("Main_Menu_Mouse_Over"); end);
	Controls.RetireButton:RegisterCallback( Mouse.eLClick, OnRetireGame );
	Controls.RetireButton:RegisterCallback( Mouse.eMouseEnter, function() UI.PlaySound("Main_Menu_Mouse_Over"); end);
	Controls.RestartButton:RegisterCallback( Mouse.eLClick, OnRestartGame );
	Controls.RestartButton:RegisterCallback( Mouse.eMouseEnter, function() UI.PlaySound("Main_Menu_Mouse_Over"); end);
	Controls.PBCDeleteButton:RegisterCallback( Mouse.eLClick, OnPBCDeleteButton );
	Controls.PBCDeleteButton:RegisterCallback( Mouse.eMouseEnter, function() UI.PlaySound("Main_Menu_Mouse_Over"); end);
	Controls.PBCQuitButton:RegisterCallback( Mouse.eLClick, OnPBCQuitButton );
	Controls.PBCQuitButton:RegisterCallback( Mouse.eMouseEnter, function() UI.PlaySound("Main_Menu_Mouse_Over"); end);
	Controls.ReturnButton:RegisterCallback( Mouse.eLClick, OnReturn );
	Controls.ReturnButton:RegisterCallback( Mouse.eMouseEnter, function() UI.PlaySound("Main_Menu_Mouse_Over"); end);
	Controls.SaveGameButton:RegisterCallback( Mouse.eLClick, OnSaveGame );
	Controls.SaveGameButton:RegisterCallback( Mouse.eMouseEnter, function() UI.PlaySound("Main_Menu_Mouse_Over"); end);
	Controls.PauseWindowClose:RegisterEndCallback( ShutdownAfterClose );

	LuaEvents.InGame_OpenInGameOptionsMenu.Add( OnOpenInGameOptionsMenu );
	LuaEvents.PlayerChange_OpenInGameOptionsMenu.Add( OnOpenInGameOptionsMenu );
	LuaEvents.PausePanel_OpenInGameOptionsMenu.Add( OnOpenInGameOptionsMenu );

	LuaEvents.TutorialUIRoot_SimpleInGameMenu.Add( OnSimpleInGameMenu );
	LuaEvents.DiplomacyActionView_HideIngameUI.Add( CloseImmediately );

	LuaEvents.EndGameMenu_Shown.Add( function() m_isEndGameOpen = true; end );
	LuaEvents.EndGameMenu_OneMoreTurn.Add( function() m_isEndGameOpen = false; end );
	LuaEvents.EndGameMenu_Closed.Add( function() m_isEndGameOpen = false; end);

	Events.PlayerTurnActivated.Add( EventRefreshButtons );
	Events.PlayerTurnDeactivated.Add( EventRefreshButtons );
	Events.MultiplayerMatchHostMigrated.Add( EventRefreshButtons );
	Events.UserRequestClose.Add( OnRequestClose );
	Events.LoadGameViewStateDone.Add( OnLoadGameViewStateDone );
	if Events.LoadScreenClose ~= nil then
		Events.LoadScreenClose.Add( OnLoadScreenCloseForReadyFlag );
	end
	Events.CloudGameKilled.Add(OnCloudGameKilled);
	Events.CloudGameQuit.Add(OnCloudGameQuit);

	local gameSeed : string = "";
	local mapSeed : string = "";

	-- Convert to string so formatting isn't performed by locale when added to tooltip:
	if(GameConfiguration.GetValue("GAME_SYNC_RANDOM_SEED") ~= nil)then
		gameSeed = tostring( GameConfiguration.GetValue("GAME_SYNC_RANDOM_SEED") );
	end
	if(MapConfiguration.GetValue("RANDOM_SEED") ~= nil)then
		mapSeed	= tostring( MapConfiguration.GetValue("RANDOM_SEED") );
	end

	local version		:string = UI.GetAppVersion();
	local tooltipInfo	:string= --Locale.Lookup("LOC_PAUSEMENU_INFO_OVERVIEW_TOOLTIP");
		Locale.Lookup("LOC_PAUSEMENU_INFO_OVERVIEW_TOOLTIP") .. "[NEWLINE]" ..
		Locale.Lookup("LOC_PAUSEMENU_INFO_VERSION_TOOLTIP", version) .. "[NEWLINE]" ..
		Locale.Lookup("LOC_PAUSEMENU_INFO_MAP_SEED", mapSeed) .. "[NEWLINE]" ..
		Locale.Lookup("LOC_PAUSEMENU_INFO_GAME_SEED", gameSeed);

	Controls.VersionLabel:SetText( version );
	Controls.VersionLabel:SetToolTipString( tooltipInfo );

	-- Custom popup setup
	m_kPopupDialog = PopupDialog:new( "InGameTopOptionsMenu" );

	if UI.HasFeature("Demo") then
		m_isSimpleMenu = true;
	end

end
Initialize();
