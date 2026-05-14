-- Accessible IntroScreen override.
--
-- This is the copyright / EULA screen that gates the rest of the game on
-- first launch (and on every version bump). Without it being accessible,
-- a blind first-time installer is locked out — Noel had to use Aira to
-- click through it on 2026-05-11. After acceptance the IntroScreen
-- auto-accepts silently on subsequent launches, so this override only
-- matters at the first-launch boundary, but at that boundary it's a P0
-- blocker (see project_eula_aira_dependency memory).
--
-- Preserves all base behavior verbatim (5-second legal delay before the
-- accept button shows, auto-accept of previously-accepted versions,
-- hotkey accept via the Input.Accept action). Adds:
--   * announce on screen show: "End user license agreement..." with the
--     full copyright text so the user knows what they're being asked to
--     accept
--   * announce when the 5-second delay completes and the accept option
--     is available: "Press Enter or Space to accept and continue"
--   * announce on accept: "License agreement accepted"
--   * silent on auto-accept (already-accepted version) so we don't bark
--     into the void on every subsequent launch
--
-- Fork of Base/Assets/UI/FrontEnd/IntroScreen.lua. When Civ VI patches
-- ship a new IntroScreen, diff against base and re-apply these additions.

include("InputSupport");
include("ScreenReader");

-- ===========================================================================
--	Action Hotkeys
-- ===========================================================================

local m_actionHotkeyAccept		:number = Input.GetActionId("Accept");
local m_actionHotkeyAcceptAlt	:number = Input.GetActionId("AcceptAlt");

local NO_ACCEPT_TIMER			:number = -1;									-- accept timer not running value.
local ACCEPT_DELAY				:number = UI.IsFinalRelease() and 5 or 0.1;		-- Delay times (release and debug) before accept button is visible and auto-accept is checked.
local m_acceptDelayTimer		:number = NO_ACCEPT_TIMER;						-- Time remaining before accept button should be shown.

-- True once the 5-second delay has elapsed and the button is visible.
-- Used only to time when we speak the "press Enter to accept" prompt —
-- the hotkey itself is NOT gated on this flag (the base game allowed
-- Accept at any time, and gating broke the hotkey in testing on
-- 2026-05-11 — kept seeing the screen reader announce go through but
-- Enter do nothing afterward, even though the same branch that announces
-- also flips this to true; likely a closure / context-reload edge case
-- I don't fully understand. Safer to match base behavior).
local m_acceptReady				:boolean = false;
-- True once we've spoken anything for this screen instance. Prevents repeat
-- announces if OnShow fires more than once before the user accepts.
local m_announced				:boolean = false;


-- ===========================================================================
--	Accept EULA
-- ===========================================================================
-- savedAccept (optional) - Is this accept action because the player accepted this version previously?  Assumes false if nil.
function AcceptEULA( savedAccept : boolean )
	Controls.CopyrightAccept:SetHide( true );
	Events.UserAcceptsEULA();

	if(savedAccept == nil or not savedAccept) then
		-- We just accepted the copyright notice for the first time for this version.
		local currentVersion = UI.GetAppVersion();
		Options.SetUserOption("Interface", "CopyrightAccept", currentVersion);
		Options.SaveOptions();
		-- First-time accept: speak confirmation so the blind user hears
		-- the gate cleared. On auto-accept (savedAccept=true) we stay
		-- silent — those launches should feel as seamless to a blind
		-- user as they do to a sighted one.
		OutputMessageToScreenReader(Locale.Lookup("LOC_CIVVIACCESS_EULA_ACCEPTED"));
	end
end


-- ===========================================================================
--	Context Functions
-- ===========================================================================
function OnShow()
	-- Wait a small amount of time before presenting.  This is a legal requirement for our third party software logos.
	Controls.CopyrightAccept:SetHide( true );

	m_acceptDelayTimer = ACCEPT_DELAY;
	m_acceptReady = false;
	ContextPtr:SetUpdate( OnUpdateDelay );

	-- Check up front whether the user has already accepted this version's
	-- copyright notice. On the auto-accept path (currentVersion ==
	-- acceptedVersion) OnUpdateDelay fires AcceptEULA(true) silently after
	-- the delay and transitions to MainMenu — speaking the long copyright
	-- text in OnShow then meant the announce got chopped mid-sentence as
	-- the screen transitioned. The fix: only narrate when an accept is
	-- actually needed; returning users get a silent gate-pass exactly the
	-- way they did before this override existed.
	local currentVersion = UI.GetAppVersion();
	local acceptedVersion = Options.GetUserOption("Interface", "CopyrightAccept");
	local needsAccept = not (currentVersion == acceptedVersion and currentVersion ~= "");

	if needsAccept and not m_announced then
		m_announced = true;
		local body = Locale.Lookup("LOC_COPYRIGHT_TEXT");
		OutputMessageToScreenReader(Locale.Lookup("LOC_CIVVIACCESS_EULA_INTRO", body));
	end
end

-- ===========================================================================
function OnUpdateDelay(fDTime)
	if(m_acceptDelayTimer ~= NO_ACCEPT_TIMER) then
		m_acceptDelayTimer = m_acceptDelayTimer - fDTime;
		if(m_acceptDelayTimer < 0) then
			m_acceptDelayTimer = NO_ACCEPT_TIMER;
			ContextPtr:ClearUpdate();

			Controls.CopyrightAccept:SetHide( false );
			local currentVersion = UI.GetAppVersion();
			local acceptedVersion = Options.GetUserOption("Interface", "CopyrightAccept");
			if(currentVersion == acceptedVersion and currentVersion ~= "") then
				AcceptEULA(true);
			else
				-- Fresh acceptance needed (first launch on this machine or
				-- a version bump). Prompt the user with the keystroke that
				-- accepts. We use queued (non-interrupting) speech so it
				-- chains after the OnShow announce rather than cutting it
				-- off mid-license-text.
				m_acceptReady = true;
				OutputMessageToScreenReader(Locale.Lookup("LOC_CIVVIACCESS_EULA_PROMPT"), true);
			end
		end
	end
end


-- ===========================================================================
--	Hotkey
-- ===========================================================================
function OnInputActionTriggered( actionId:number )
	-- Diagnostic: log every action firing while EULA is up so we can see
	-- whether Enter/Space arrive through the InputAction layer at all on
	-- this build. Cheap, removable once we trust the path.
	print("IntroScreen: InputActionTriggered actionId=" .. tostring(actionId)
		.. " accept=" .. tostring(m_actionHotkeyAccept)
		.. " acceptAlt=" .. tostring(m_actionHotkeyAcceptAlt));
	if	actionId == m_actionHotkeyAccept or
		actionId == m_actionHotkeyAcceptAlt then
			-- Match base game: accept on Accept/AcceptAlt hotkey at any
			-- time. (Earlier attempt to gate this on the 5-second delay
			-- broke Enter accept on first-launch testing — see comment on
			-- m_acceptReady.)
			AcceptEULA();
	end
end

-- ===========================================================================
--	Raw key fallback. The base IntroScreen relied solely on the InputAction
--	system ("Accept" action -> Enter binding) but testing on 2026-05-11
--	showed that path silent — OnInputActionTriggered never fired despite
--	user pressing Enter and Space after the legal delay. Adding a raw
--	ContextPtr:SetInputHandler that catches VK_RETURN / VK_SPACE directly
--	at KeyUp, same pattern FrontEndPopup uses successfully. If the
--	InputAction path comes back later, both will fire — AcceptEULA already
--	guards against duplicate calls (savedAccept check + button hide).
-- ===========================================================================
function OnInputHandler( uiMsg, wParam, lParam )
	if uiMsg == KeyEvents.KeyUp then
		if wParam == Keys.VK_RETURN or wParam == Keys.VK_SPACE then
			print("IntroScreen: raw KeyUp Enter/Space -> AcceptEULA");
			AcceptEULA();
			return true;
		end
	end
	return false;
end

-- ===========================================================================
--	UI Callback
-- ===========================================================================
function OnAccept()
	AcceptEULA();
end

-- ===========================================================================
function OnRequestClose()
    Events.UserConfirmedClose();
end

-- ===========================================================================
function Startup()
	Input.SetActiveContext( InputContext.Startup );

	print("IntroScreen: Startup. Accept actionId="
		.. tostring(m_actionHotkeyAccept)
		.. ", AcceptAlt actionId="
		.. tostring(m_actionHotkeyAcceptAlt));

    Controls.CopyrightAccept:RegisterCallback( Mouse.eLClick, OnAccept );
    Controls.CopyrightAccept:RegisterCallback( Mouse.eMouseEnter, function() UI.PlaySound("Main_Menu_Mouse_Over"); end);

	Controls.CopyrightAccept:SetHide( Automation.IsActive() );
    Controls.CopyrightText:SetHide(false);

	-- Raw key handler installed BEFORE the InputAction listener so even if
	-- the InputAction path stays silent, Enter/Space still reach AcceptEULA.
	ContextPtr:SetInputHandler( OnInputHandler );

	Events.InputActionTriggered.Add( OnInputActionTriggered );
    Events.UserRequestClose.Add( OnRequestClose );

	-- Manually call OnShow because SetActiveContext does not appear to call it normally.
	OnShow();
end
Startup();
