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
    -- NOTE: VK_OEM_2 (/ and ?) is NOT a bare scanner key. Bare `/` and Ctrl+`/`
    -- stay on their InputActions (CIVVIACCESS_UnitInfo = speak unit stats,
    -- CIVVIACCESS_RecenterOnUnit). Only Shift+`/` (`?`) forwards → cheat-sheet,
    -- registered as an exact combo below.
    addKey(Keys.S);         -- S = survey (consumed under any mod → frees S from the
                            --   old where-am-I InputAction; routed to ScannerSurvey)
end

-- Mod-specific combos to capture + forward. Unlike SCANNER_KEYS (consumed
-- under ANY modifier — that's the scanner's no-mod/Shift/Ctrl/Alt ladder),
-- a combo fires ONLY on its exact (key, mods) so a different modifier on the
-- same letter still reaches the engine. Shift+D = cycle direction vocabulary;
-- Alt+D stays the engine's cursor-east binding (Alt+QWEADZXC), bare D stays
-- free. Matched against InputRouter's mask (bit0 Shift / bit1 Ctrl / bit2 Alt).
local SCANNER_COMBOS = {};
local function addCombo(k, m) if k ~= nil then SCANNER_COMBOS[#SCANNER_COMBOS + 1] = { key = k, mods = m }; end end
if Keys ~= nil then
    -- Hex-cluster navigation (task #14): cursor on BARE Q/E/A/D/Z/C, unit move on
    -- SHIFT+cluster. Migrated off the flaky engine InputAction path onto the wrap so
    -- every press reliably reaches NavKeys.dispatch and SPEAKS (the unit-move was
    -- firing silently / not at all on the old path). Engine letter-actions stay on
    -- Alt (not captured here yet — "map some engine keys, not all").
    for _, navKey in ipairs({ Keys.Q, Keys.E, Keys.A, Keys.D, Keys.Z, Keys.C }) do
        if navKey ~= nil then
            addCombo(navKey, 0);                       -- bare = move cursor
            addCombo(navKey, InputRouter.MOD_SHIFT);   -- Shift = move unit
        end
    end
    -- D-family finalized: bare D = cursor east, Shift+D = unit east (both above),
    -- Ctrl+D = cycle direction vocabulary (moved off Shift+D to free the cluster).
    if Keys.D ~= nil then addCombo(Keys.D, InputRouter.MOD_CTRL); end
    -- Survey + zoom family (routed to ScannerSurvey in the addin VM; see
    -- HOTKEY_REFERENCE.md). Exact combos so other modifiers on these letters still
    -- reach the engine. (Bare S is captured above as a scanner key.)
    addCombo(Keys.W, 0);                       -- W = where am I
    addCombo(Keys.W, InputRouter.MOD_SHIFT);   -- Shift+W = rich locate
    addCombo(Keys.G, InputRouter.MOD_ALT);     -- Alt+G = survey category: all
    -- Bare G = open My Government (hub: announces current government, then
    -- G = change type, P = policy wizard). RECLAIM: the engine's bare G is the
    -- map grid toggle, sighted-only. Raised via the LaunchBar's own LuaEvent so
    -- it behaves exactly like clicking the Government button.
    addCombo(Keys.G, 0);
    addCombo(Keys.U, InputRouter.MOD_ALT);     -- Alt+U = survey category: units
    addCombo(Keys.R, InputRouter.MOD_ALT);     -- Alt+R = survey category: resources
    -- Shift+R = repeat last announce / walk BACK through the speech history;
    -- Ctrl+R = step FORWARD (SpeechHistory). Migrated from the legacy
    -- CIVVIACCESS_RepeatAnnounce InputAction; the wrap consuming it
    -- suppresses that action (kept as a dead fallback).
    addCombo(Keys.R, InputRouter.MOD_SHIFT);
    addCombo(Keys.R, InputRouter.MOD_CTRL);
    if Keys.VK_OEM_PLUS  ~= nil then addCombo(Keys.VK_OEM_PLUS,  InputRouter.MOD_ALT); end  -- Alt+= zoom in
    if Keys.VK_OEM_MINUS ~= nil then addCombo(Keys.VK_OEM_MINUS, InputRouter.MOD_ALT); end  -- Alt+- zoom out
    -- Alt+digit zoom jumps (0 resets). Civ VI's Keys enum form for digits isn't
    -- documented; capture whatever resolves (kept in sync with ScannerSurvey).
    for d = 0, 9 do
        local dk = Keys[tostring(d)] or Keys["NUMBER_" .. d] or Keys["VK_" .. d] or Keys["D" .. d];
        if dk ~= nil then addCombo(dk, InputRouter.MOD_ALT); end
    end
    -- Move-to (P2): M = move to cursor, Shift+M = preview, Ctrl+M = cancel move.
    -- Routed to UnitMovement in the addin VM; reclaims the engine's bare-M MoveTo.
    addCombo(Keys.M, 0);
    addCombo(Keys.M, InputRouter.MOD_SHIFT);
    addCombo(Keys.M, InputRouter.MOD_CTRL);
    -- Combat (P3): Ctrl+A = attack the hex cursor target (preview, then Ctrl+A again
    -- to confirm). NOT bare A (= cursor west) and NOT Shift+A (= move unit west) —
    -- Ctrl completes the A-family without stomping either. Ctrl chords pass through
    -- screen readers; only the exact Ctrl combo is captured.
    addCombo(Keys.A, InputRouter.MOD_CTRL);
    -- Shift+`/` (`?`) = scanner cheat-sheet. Bare `/` and Ctrl+`/` deliberately
    -- left to their InputActions (unit stats / recenter) — see SCANNER_KEYS note.
    addCombo(Keys.VK_OEM_2, InputRouter.MOD_SHIFT);
    -- Alt+`/` = select the own unit under the CURSOR (reverse of Ctrl+/) —
    -- completes the scanner->command loop: scan, Home, Alt+/, move.
    addCombo(Keys.VK_OEM_2, InputRouter.MOD_ALT);
    -- F1 = the SEARCHABLE help list (navigable, Ctrl+F filter, type-ahead) —
    -- the #16 two-tier split: quick context walk on Shift+/, searchable list
    -- here. RECLAIM: engine F1 = ToggleRankings, a visual screen.
    if Keys.F1 ~= nil then addCombo(Keys.F1, 0); end
    -- Shift+Enter = ACTIVATE the notification cycle's current entry (the
    -- keyboard form of the sighted left-click on a notification icon — opens
    -- the policy picker, tech chooser, etc.). Bare Enter stays the engine's
    -- end-turn/action key. Modal pickers that use Shift+Enter internally
    -- (PolicyWizard keep-slot) run behind a pushed input context, so this
    -- capture never sees their keys.
    addCombo(Keys.VK_RETURN, InputRouter.MOD_SHIFT);
end
local function matchCombo(key, mods)
    for _, c in ipairs(SCANNER_COMBOS) do
        if c.key == key and c.mods == mods then return true; end
    end
    return false;
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
            local mods = InputRouter.modifierMaskFromInputStruct(pInputStruct);
            -- Bare scanner keys (any modifier — the ladder) OR an exact combo.
            if SCANNER_KEYS[key] or matchCombo(key, mods) then
                if msg == KEYUP then
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
