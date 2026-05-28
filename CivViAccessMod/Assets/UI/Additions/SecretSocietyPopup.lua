-- Copyright 2020, Firaxis Games
--
-- ScreenReaderAccess shadow: minimal additions over DLC/Ethiopia —
--   1. include("RevealPopupAccess") at top
--   2. ShowDiscovery / ShowJoined tails assemble title + event desc +
--      society desc and pass into Open() via m_sPendingAnnounce.
--   3. Close calls RevealPopupAccess.NotifyClose.
--   4. OnInputHandler routes through RevealPopupAccess.HandleKey first.
-- All other code is verbatim from DLC.

include("RevealPopupAccess");

-- ===========================================================================
--	CONSTANTS
-- ===========================================================================

local kDiscoveredImages:table = {};
kDiscoveredImages["SECRETSOCIETY_OWLS_OF_MINERVA"]	= "GovernorSelectedSTK_OwlsOfMinerva";
kDiscoveredImages["SECRETSOCIETY_HERMETIC_ORDER"]	= "GovernorSelectedSTK_HermeticOrder";
kDiscoveredImages["SECRETSOCIETY_VOIDSINGERS"]		= "GovernorSelectedSTK_VoidSingers";
kDiscoveredImages["SECRETSOCIETY_SANGUINE_PACT"]	= "GovernorSelectedSTK_SanguinePact";

-- begin ScreenReaderAccess mod change
local m_sPendingAnnounce:string = nil;
-- end ScreenReaderAccess mod change

-- ===========================================================================
function OnContinueButton()
	Close();
end

-- ===========================================================================
function OnOpenGovernorsButton()
	Close();
	LuaEvents.GovernorPanel_Open();
end

-- ===========================================================================
function Open()
	UIManager:QueuePopup(ContextPtr, PopupPriority.Low);

	-- begin ScreenReaderAccess mod change
	if m_sPendingAnnounce ~= nil and m_sPendingAnnounce ~= "" then
		local text = m_sPendingAnnounce;
		if stripIconTags ~= nil then
			text = stripIconTags(text);
		end
		RevealPopupAccess.NotifyShow({
			text    = text,
			onClose = function() Close() end,
			kind    = "critical",
		});
		m_sPendingAnnounce = nil;
	end
	-- end ScreenReaderAccess mod change
end

-- ===========================================================================
function Close()
	-- begin ScreenReaderAccess mod change
	RevealPopupAccess.NotifyClose();
	-- end ScreenReaderAccess mod change
	UIManager:DequeuePopup(ContextPtr);
end

-- ===========================================================================
function OnInputHandler( pInputStruct:table )
	-- begin ScreenReaderAccess mod change
	if RevealPopupAccess.HandleKey(pInputStruct) then return true; end
	-- end ScreenReaderAccess mod change
	local uiMsg :number = pInputStruct:GetMessageType();
	if uiMsg == KeyEvents.KeyUp and pInputStruct:GetKey() == Keys.VK_ESCAPE then
		Close();
		return true;
	end
	return false;
end

-- ===========================================================================
function OnInit(isReload:boolean)
	LateInitialize();
end

-- ===========================================================================
function OnSecretSocietyDiscovered( pNotification:table )
	if pNotification == nil then
		return;
	end

	local eType:number = pNotification:GetType();
	if eType ~= NotificationTypes.SECRETSOCIETY_DISCOVERED then
		return;
	end

	ShowDiscovery(pNotification);
end

-- ===========================================================================
function ShowDiscovery(pNotification:table)

	local ePlayer:number = pNotification:GetValue( "PARAM_DATA0" );
	if ePlayer ~= Game.GetLocalPlayer() then
		return;
	end
	local kPlayer:table = Players[ePlayer];
	if kPlayer == nil then
		return;
	end
	local kPlayerGovernors:table = kPlayer:GetGovernors();
	if kPlayerGovernors == nil then
		return;
	end

	local eSociety:number = pNotification:GetValue( "PARAM_DATA1" );
	local kSocietyDef:table = GameInfo.SecretSocieties[eSociety];
	if kSocietyDef == nil then
		return;
	end

	local bIsFirstDiscovery:boolean = pNotification:GetValue( "PARAM_DATA2" );

	local sTitle:string = Locale.ToUpper(Locale.Lookup("LOC_DISCOVERED_SOCIETY", kSocietyDef.Name));
	Controls.EventTitle:SetText(sTitle);

	local sEventDesc:string;
	if bIsFirstDiscovery then
		sEventDesc = Locale.Lookup("LOC_DISCOVERED_SOCIETY_FIRST_DESC", kSocietyDef.Name, kSocietyDef.IconString);
	else
		sEventDesc = Locale.Lookup("LOC_DISCOVERED_SOCIETY_SUBSEQUENT_DESC", kSocietyDef.Name, kSocietyDef.IconString);
	end
	Controls.EventDescription:SetText(sEventDesc);

	Controls.SocietyImage:SetTexture(kDiscoveredImages[kSocietyDef.SecretSocietyType]);
	local memberSocietyHash = kPlayerGovernors:GetSecretSociety();
	local kMemberSocietyDef:table = GameInfo.SecretSocieties[memberSocietyHash];
	local sSocietyDesc:string;
	if (kMemberSocietyDef ~= nil) then
		sSocietyDesc = Locale.Lookup("LOC_DISCOVERED_SOCIETY_WHILE_MEMBER_OF_ANOTHER", kSocietyDef.Name, kMemberSocietyDef.Name);
	else
		sSocietyDesc = Locale.Lookup(kSocietyDef.DiscoveryText);
	end
	Controls.SocietyDescription:SetText(sSocietyDesc);

	-- begin ScreenReaderAccess mod change
	m_sPendingAnnounce = sTitle .. ". " .. sEventDesc .. ". " .. sSocietyDesc;
	-- end ScreenReaderAccess mod change

	Open();

	--Dismiss the notification right away so that the notification manager does not see others as duplicates
	NotificationManager.Dismiss(pNotification:GetPlayerID(), pNotification:GetID());
end

-- ===========================================================================
function OnSecretSocietyJoined( pNotification:table )
	if pNotification == nil then
		return;
	end

	local eType:number = pNotification:GetType();
	if eType ~= NotificationTypes.SECRETSOCIETY_JOINED then
		return;
	end

	local ePlayer:number = pNotification:GetValue( "PARAM_DATA0" );
	local eSociety:number = pNotification:GetValue( "PARAM_DATA1" );

	ShowJoined(ePlayer, eSociety);
end

-- ===========================================================================
function ShowJoined(ePlayer:number, eSociety:number)

	if ePlayer ~= Game.GetLocalPlayer() then
		return;
	end

	local kSocietyDef:table = GameInfo.SecretSocieties[eSociety];
	if kSocietyDef == nil then
		return;
	end

	local sTitle:string = Locale.ToUpper(Locale.Lookup("LOC_JOINED_SOCIETY", kSocietyDef.Name));
	Controls.EventTitle:SetText(sTitle);
	local sEventDesc:string = Locale.Lookup("LOC_JOINED_SOCIETY_DESC", kSocietyDef.Name, kSocietyDef.IconString);
	Controls.EventDescription:SetText(sEventDesc);

	Controls.SocietyImage:SetTexture("SecretSocieties_EventsFG_Discover");
	local sSocietyDesc:string = Locale.Lookup(kSocietyDef.MembershipText);
	Controls.SocietyDescription:SetText(sSocietyDesc);

	-- begin ScreenReaderAccess mod change
	m_sPendingAnnounce = sTitle .. ". " .. sEventDesc .. ". " .. sSocietyDesc;
	-- end ScreenReaderAccess mod change

	Open();
end

-- ===========================================================================
function Subscribe()
	LuaEvents.NotificationPanel_SecretSocietyDiscovered.Add( OnSecretSocietyDiscovered );
	LuaEvents.NotificationPanel_SecretSocietyJoined.Add( OnSecretSocietyJoined );
end

-- ===========================================================================
function Unsubscribe()
	LuaEvents.NotificationPanel_SecretSocietyDiscovered.Remove( OnSecretSocietyDiscovered );
	LuaEvents.NotificationPanel_SecretSocietyJoined.Remove( OnSecretSocietyJoined );
end

-- ===========================================================================
function OnShutdown()
	Unsubscribe();
end

-- ===========================================================================
function LateInitialize()
	Subscribe();
end

-- ===========================================================================
function Initialize()
	ContextPtr:SetInitHandler( OnInit );
	ContextPtr:SetInputHandler( OnInputHandler, true );
	ContextPtr:SetShutdown( OnShutdown );

	Controls.OpenGovernorsButton:RegisterCallback( Mouse.eLClick, OnOpenGovernorsButton );
	Controls.ContinueButton:RegisterCallback( Mouse.eLClick, OnContinueButton );
end
Initialize();
