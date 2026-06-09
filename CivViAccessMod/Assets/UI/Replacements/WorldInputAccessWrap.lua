-- WorldInputAccessWrap.lua — the capture-all input host. Loaded IN-CONTEXT via
-- <ReplaceUIScript LuaContext="WorldInput"> (ruleset entry files include the
-- matching base/XP1/XP2 WorldInput impl, then this). PROVEN by the 2026-06-08
-- probe: consuming a key in WorldInput's OnInputHandler (return true) suppresses
-- the engine's InputAction, so this owns the map keyboard.
--
-- WHAT IT DOES (v1): captures the scanner keys (PageUp/Down/Home/End/Backspace —
-- which the engine uses only for sighted camera zoom + city cycle) and FORWARDS
-- them to the HexCursorAddin VM via LuaEvents.CivViAccess_ScannerInput(key, mods),
-- where the scanner runs next to the cursor. Everything else falls through to the
-- real WorldInput handler untouched — so the existing Alt+letter cursor nav, unit
-- commands (B=found city), Enter (end turn), Escape (menu), and the mouse all keep
-- working. This is the cross-VM bridge: raw input is owned here; the scanner +
-- cursor live together in the addin VM.
--
-- SIGHTED MODE: when _sighted is set (via LuaEvents.CivViAccess_SetSighted, the
-- per-turn / manual toggle — task 13), the wrap passes EVERYTHING through, handing
-- the whole keyboard to the engine for a sighted player. v1 defaults to blind.
--
-- The full migration (move the cursor nav itself into this wrap, Civ V's single-VM
-- model) is task 14; this bridge ships the scanner first without touching the
-- existing nav.

include("Log");
include("InputRouter");

if type(OnInputHandler) ~= "function" then
    Log.warn("WorldInputAccessWrap: OnInputHandler missing after include — WorldInput impl did not load. Wrap NOT installed.");
    return;
end

local BASE_OnInputHandler = OnInputHandler;
local KEYUP   = (KeyEvents ~= nil and KeyEvents.KeyUp)   or 257;
local KEYDOWN = (KeyEvents ~= nil and KeyEvents.KeyDown) or 256;

-- Scanner keys to capture + forward. Built from the engine's Keys.* constants
-- (Civ VI's enum, NOT raw VK — the probe confirmed GetKey returns these values).
local SCANNER_KEYS = {};
local function addKey(k) if k ~= nil then SCANNER_KEYS[k] = true; end end
if Keys ~= nil then
    addKey(Keys.VK_NEXT);   -- PageDown
    addKey(Keys.VK_PRIOR);  -- PageUp
    addKey(Keys.VK_HOME);
    addKey(Keys.VK_END);
    addKey(Keys.VK_BACK);   -- Backspace
    addKey(Keys.VK_OEM_2);  -- / and ? — scanner cheat-sheet (?) ; engine-free on the map
end

-- Sighted-mode flag (default blind). When on, pass the whole keyboard through.
local _sighted = false;
if LuaEvents ~= nil and LuaEvents.CivViAccess_SetSighted ~= nil then
    LuaEvents.CivViAccess_SetSighted.Add(function(on) _sighted = (on == true); end);
end

function OnInputHandler(pInputStruct)
    if not _sighted then
        local msg = pInputStruct:GetMessageType();
        if msg == KEYUP or msg == KEYDOWN then
            local key = pInputStruct:GetKey();
            if SCANNER_KEYS[key] then
                if msg == KEYUP then
                    local mods = InputRouter.modifierMaskFromInputStruct(pInputStruct);
                    Log.info("WorldInputAccessWrap: forwarding scanner key=" .. tostring(key)
                        .. " mods=" .. tostring(mods));
                    if LuaEvents ~= nil and LuaEvents.CivViAccess_ScannerInput ~= nil then
                        LuaEvents.CivViAccess_ScannerInput(key, mods);
                    end
                end
                return true;   -- consume down+up so the engine's camera/cycle action never fires
            end
        end
    end
    return BASE_OnInputHandler(pInputStruct);
end

ContextPtr:SetInputHandler(OnInputHandler, true);

Log.info("WorldInputAccessWrap: installed — owning WorldInput input, forwarding scanner keys "
    .. "(PageUp/Down/Home/End/Backspace) to the addin VM; everything else passes through.");
