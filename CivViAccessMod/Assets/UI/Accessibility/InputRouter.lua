-- Input dispatcher over HandlerStack. Walks the stack top-down on each
-- keypress; the first handler whose bindings table contains a (key, mods)
-- match has its fn invoked and dispatch returns true (key consumed). On
-- miss, returns false so the caller's wrapper can fall through to the
-- base ContextPtr input handler — engine behaviors (Esc opens game menu,
-- camera pan, mouse handling) keep working.
--
-- Modifier mask layout (bitmask):
--   bit 0 (1) = Shift
--   bit 1 (2) = Ctrl
--   bit 2 (4) = Alt
-- Matches Civ V Access's mask layout for cross-game muscle memory and
-- because the Windows VK side uses the same bit positions.
--
-- Engine-agnostic shape, but the modifier-read and the ContextPtr install
-- helpers reach into Civ VI's pInputStruct / KeyEvents API. The dispatch
-- logic itself ports as-is; only the two helpers need rewriting per game.

include("Log");
include("HandlerStack");

InputRouter = InputRouter or {};

InputRouter.MOD_NONE       = 0;
InputRouter.MOD_SHIFT      = 1;
InputRouter.MOD_CTRL       = 2;
InputRouter.MOD_CTRL_SHIFT = 3;
InputRouter.MOD_ALT        = 4;
InputRouter.MOD_ALT_SHIFT  = 5;
InputRouter.MOD_CTRL_ALT   = 6;
InputRouter.MOD_ALL        = 7;

local MOD_NONE  = InputRouter.MOD_NONE;
local MOD_SHIFT = InputRouter.MOD_SHIFT;
local MOD_CTRL  = InputRouter.MOD_CTRL;
local MOD_ALT   = InputRouter.MOD_ALT;

-- Read modifier state from a Civ VI input struct. The methods are present
-- on every pInputStruct delivered to ContextPtr:SetInputHandler callbacks.
-- pcall-guarded only for the rare Automation path where some methods can
-- return nil mid-frame; default to "no mods held" if the read fails.
function InputRouter.modifierMaskFromInputStruct(pInputStruct)
    if pInputStruct == nil then
        return MOD_NONE;
    end
    local mask = MOD_NONE;
    if pInputStruct.IsShiftDown   and pInputStruct:IsShiftDown()   then mask = mask + MOD_SHIFT; end
    if pInputStruct.IsControlDown and pInputStruct:IsControlDown() then mask = mask + MOD_CTRL;  end
    if pInputStruct.IsAltDown     and pInputStruct:IsAltDown()     then mask = mask + MOD_ALT;   end
    return mask;
end

-- Walk the stack top-down. For each handler, scan its bindings for a
-- (key, mods) match; first hit fires the fn (under Log.tryCall so a
-- broken binding doesn't crash the whole input pipeline) and returns true.
-- Stops at the first capturesAllInput handler (inclusive — that handler
-- still gets to dispatch; nothing below it is reachable).
function InputRouter.dispatch(key, mods)
    local m = mods or 0;
    local n = HandlerStack.count();
    for i = n, 1, -1 do
        local h = HandlerStack.at(i);
        if type(h.bindings) == "table" then
            for _, b in ipairs(h.bindings) do
                if b.key == key and (b.mods or 0) == m then
                    Log.tryCall(
                        "InputRouter binding '" .. tostring(h.name)
                        .. "' key=" .. tostring(key) .. " mods=" .. tostring(m),
                        b.fn
                    );
                    return true;
                end
            end
        end
        if h.capturesAllInput then
            return false;
        end
    end
    return false;
end

-- Install a wrapper input handler on a ContextPtr. The wrapper checks for
-- KeyDown events, reads the key + modifier mask, dispatches via the stack,
-- and consumes the key on a hit. On miss, returns false so the engine and
-- other Contexts can process the key normally.
--
-- ContextPtr:SetInputHandler is per-Context; each .lua file imported via
-- modinfo gets its own ContextPtr. This helper is called once per file
-- that owns a HandlerStack (typically the file that pushes the root
-- handler for that screen).
--
-- The second `true` arg to SetInputHandler enables "all events including
-- mouse" — we filter to KeyDown ourselves so mouse / touch flow through
-- to the engine untouched.
function InputRouter.installOnContextPtr(ctxPtr)
    if ctxPtr == nil or ctxPtr.SetInputHandler == nil then
        Log.warn("InputRouter.installOnContextPtr: nil or invalid ContextPtr");
        return false;
    end
    -- KeyUp matches BaseMenu's Civ VI convention. Civ VI's UI input pattern
    -- across our existing screens (BaseMenu, MainMenuAccess, OptionsAccess,
    -- LoadGameMenuAccess) all dispatch on KeyUp so the engine's KeyDown
    -- action handlers (CameraPanUp / NextUnit / etc.) keep working untouched.
    local KEY_UP_MSG = (KeyEvents ~= nil and KeyEvents.KeyUp) or 257;
    ctxPtr:SetInputHandler(function(pInputStruct)
        if pInputStruct == nil then return false; end
        local uiMsg = pInputStruct:GetMessageType();
        if uiMsg == KEY_UP_MSG then
            local key = pInputStruct:GetKey();
            local mods = InputRouter.modifierMaskFromInputStruct(pInputStruct);
            if InputRouter.dispatch(key, mods) then
                return true;
            end
        end
        return false;
    end, true);
    return true;
end
