-- PolicyWizard — accessible slot-by-slot government policy-card arranger.
--
-- The vanilla Government screen's POLICIES tab is a drag/drop grid: cards on the
-- left, military/economic/diplomatic/wildcard slots on the right. That's the one
-- interaction ChoosePopupAccess can't model (it's "one list, pick one/N"); here
-- it's N SLOTS, each with its OWN candidate-card list, all committed together.
-- So this is its own helper — a forward WIZARD that walks the slots in order.
--
-- Per the user's chosen idiom (2026-05-31):
--   Up / Down       previous / next candidate card for the CURRENT slot
--   Home / End      first / last candidate
--   T (or R)        re-read the current candidate's effect description
--   Space           STAGE the highlighted card into this slot, advance to next
--   Shift+Enter     KEEP this slot's current card unchanged, advance to next
--   Enter           APPLY everything staged so far (un-visited slots keep their
--                   current card); fires opts.onCommit(decisions)
--   Escape          CANCEL the whole thing, no changes (opts.onCancel)
--
-- WHY Shift+Enter for "keep": the card currently in a slot is ACTIVE, and the
-- engine's CanPolicyBeSlotted returns false for active cards, so a slot's current
-- card never appears in its own candidate list. Shift+Enter is therefore the only
-- way to retain it — it's not just a shortcut, it's load-bearing.
--
-- This helper is PURE INTERACTION: it never touches the Culture object. The
-- adopter (RevealListeners) supplies the slot list, a per-slot candidate builder,
-- and the commit/cancel callbacks — same split as ChoosePopupAccess + its
-- adopters. That keeps the engine I/O (RequestPolicyChanges) testable in one
-- place and lets a debug raiser feed synthetic slots so the INTERACTION can be
-- smoke-tested with no real game state.
--
-- Integration (in the shadow / intercepting addin):
--   include("PolicyWizard");
--   PolicyWizard.Open({
--       slots = { {index=0, label="Military slot 1", currentName="Discipline",
--                  currentHash=1234}, ... },     -- index = engine slot index
--       buildCandidates = function(slot, stagedHashes)   -- stagedHashes = set
--           return { {name=, description=, hash=}, ..., {name="Leave empty", empty=true} };
--       end,
--       onCommit = function(decisions) ApplyPolicyChanges(decisions); end,
--       onCancel = function() Close(); end,
--   });
--   -- in Close/hide:   PolicyWizard.NotifyClose();
--   -- in OnInputHandler:  if PolicyWizard.HandleKey(p) then return true; end
--
-- decisions handed to onCommit = array parallel to slots, each:
--   { index = <engine slot index>, action = "keep"|"set"|"empty", hash = <or nil> }

include("ScreenReader");
include("Log");

PolicyWizard = {};

-- ===========================================================================
--  Key constants (mirror ChoosePopupAccess — Keys.* enum, raw-VK fallback)
-- ===========================================================================
local KE_KEY_UP = (KeyEvents ~= nil and KeyEvents.KeyUp) or 1;

local function vk(name, fallback)
    if Keys ~= nil and Keys[name] ~= nil then return Keys[name]; end
    return fallback;
end

local VK_RETURN = vk("VK_RETURN", 0x0D);
local VK_SPACE  = vk("VK_SPACE",  0x20);
local VK_ESCAPE = vk("VK_ESCAPE", 0x1B);
local VK_UP     = vk("VK_UP",     0x26);
local VK_DOWN   = vk("VK_DOWN",   0x28);
local VK_HOME   = vk("VK_HOME",   0x24);
local VK_END    = vk("VK_END",    0x23);
-- Letters via Keys.<LETTER> (Keys.VK_<LETTER> is nil; the numeric fallback
-- collides with arrows — root-caused in RevealPopupAccess 2026-05-29).
local VK_T      = (Keys ~= nil and Keys.T) or 0x54;
local VK_R      = (Keys ~= nil and Keys.R) or 0x52;

-- ===========================================================================
--  State (one wizard open at a time per VM)
-- ===========================================================================
-- _state = {
--   slots,            -- array {index, label, currentName, currentHash}
--   si,               -- current slot (1-based); > #slots => "review done"
--   ci,               -- current candidate (1-based) within the current slot
--   cands,            -- candidate array for the current slot (lazy-built)
--   decisions,        -- decisions[si] = {index, action, hash}
--   stagedHashes,     -- set of hashes already staged (for cross-slot de-dup)
--   buildCandidates, onCommit, onCancel,
-- }
local _state = nil;

local function speak(text, kind)
    if text == nil or text == "" then return; end
    if Speech ~= nil and Speech.emit ~= nil then
        Speech.emit(text, kind or "selection");
    end
end

local function currentSlot()
    return _state and _state.slots[_state.si] or nil;
end

local function currentCand()
    if _state == nil or _state.cands == nil then return nil; end
    return _state.cands[_state.ci];
end

-- "Card name. [held.] N of M" for the highlighted candidate.
local function candAnnounce()
    local c = currentCand();
    if c == nil then return ""; end
    local parts = {};
    parts[#parts + 1] = c.name or "policy";
    parts[#parts + 1] = tostring(_state.ci) .. " of " .. tostring(#_state.cands);
    return table.concat(parts, ". ");
end

-- Build (lazily) the candidate list for the current slot, excluding any card
-- already staged into an earlier slot, and announce the slot.  firstSlot adds
-- the full key hint (terse on every later slot).
local function enterSlot(firstSlot)
    local slot = currentSlot();
    if slot == nil then return; end
    _state.cands = _state.buildCandidates(slot, _state.stagedHashes) or {};
    -- Always offer "leave empty" as a fallback so the list is never zero-length.
    if #_state.cands == 0 then
        _state.cands = { { name = "Leave empty", empty = true } };
    end
    _state.ci = 1;

    local parts = {};
    parts[#parts + 1] = slot.label or "Policy slot";
    parts[#parts + 1] = "currently " .. (slot.currentName or "empty");
    parts[#parts + 1] = candAnnounce();
    if firstSlot then
        parts[#parts + 1] = "Space to choose, Shift Enter to keep, Enter to apply, Escape to cancel";
    end
    speak(table.concat(parts, ". "), "critical");
end

-- Move to the next slot, or announce the review-complete prompt when past the
-- last one (si parks at #slots+1; Enter applies, Escape cancels).
local function advance()
    _state.si = _state.si + 1;
    if _state.si > #_state.slots then
        speak("All slots reviewed. Enter to apply, Escape to cancel.", "critical");
    else
        enterSlot(false);
    end
end

-- ===========================================================================
--  Public API
-- ===========================================================================

-- opts: slots, buildCandidates(slot, stagedHashes)->cands, onCommit(decisions),
-- onCancel, kind (open-announce Speech kind, default "critical").
function PolicyWizard.Open(opts)
    if opts == nil or opts.slots == nil or #opts.slots == 0 then
        Log.warn("PolicyWizard.Open: slots required");
        return false;
    end
    if opts.buildCandidates == nil then
        Log.warn("PolicyWizard.Open: buildCandidates required");
        return false;
    end
    _state = {
        slots           = opts.slots,
        si              = 1,
        ci              = 1,
        cands           = nil,
        decisions       = {},
        stagedHashes    = {},
        buildCandidates = opts.buildCandidates,
        onCommit        = opts.onCommit,
        onCancel        = opts.onCancel,
    };
    local lead = "Arrange policies. " .. tostring(#_state.slots) .. " slots.";
    speak(lead, opts.kind or "critical");
    enterSlot(true);
    return true;
end

function PolicyWizard.NotifyClose()
    if _state == nil then return; end
    _state = nil;
end

function PolicyWizard.IsOpen()
    return _state ~= nil;
end

-- Record a decision for the current slot, track staged hash for de-dup, advance.
local function decide(action, hash, spoken)
    local slot = currentSlot();
    if slot == nil then return; end
    _state.decisions[_state.si] = { index = slot.index, action = action, hash = hash };
    if hash ~= nil then _state.stagedHashes[hash] = true; end
    speak(spoken, "selection");
    advance();
end

-- Fill any slots not yet visited with "keep current", then commit.
local function applyAll()
    for i = 1, #_state.slots do
        if _state.decisions[i] == nil then
            local s = _state.slots[i];
            _state.decisions[i] = { index = s.index, action = "keep", hash = s.currentHash };
        end
    end
    local decisions = _state.decisions;
    local onCommit = _state.onCommit;
    speak("Applying policy changes.", "selection");
    _state = nil;   -- clear BEFORE commit so Close/NotifyClose can't double-clear
    if onCommit ~= nil then
        local ok, err = pcall(onCommit, decisions);
        if not ok then Log.warn("PolicyWizard commit failed: " .. tostring(err)); end
    end
end

local function cancelAll()
    local onCancel = _state.onCancel;
    speak("Cancelled. No policy changes.", "selection");
    _state = nil;
    if onCancel ~= nil then
        local ok, err = pcall(onCancel);
        if not ok then Log.warn("PolicyWizard cancel failed: " .. tostring(err)); end
    end
end

-- Returns true if the key was consumed.
function PolicyWizard.HandleKey(pInputStruct)
    if _state == nil then return false; end
    if pInputStruct == nil or pInputStruct.GetMessageType == nil then return false; end
    if pInputStruct:GetMessageType() ~= KE_KEY_UP then return false; end

    local key = pInputStruct:GetKey();
    local shift = (pInputStruct.IsShiftDown ~= nil) and pInputStruct:IsShiftDown() or false;
    local reviewing = (_state.si > #_state.slots);   -- past the last slot

    -- Enter: Shift+Enter keeps the current slot; plain Enter applies everything.
    if key == VK_RETURN then
        if shift and not reviewing then
            local slot = currentSlot();
            local kept = slot and slot.currentName or nil;
            decide("keep", slot and slot.currentHash or nil,
                   kept and ("Keeping " .. kept) or ("Leaving " .. (slot and slot.label or "slot") .. " empty"));
        else
            applyAll();
        end
        return true;
    end

    -- Escape always cancels the whole wizard.
    if key == VK_ESCAPE then
        cancelAll();
        return true;
    end

    -- Past the last slot only Enter/Escape act; re-prompt on anything else.
    if reviewing then
        speak("All slots reviewed. Enter to apply, Escape to cancel.", "selection");
        return true;
    end

    -- Space: stage the highlighted candidate into this slot, advance.
    if key == VK_SPACE then
        local c = currentCand();
        local slot = currentSlot();
        if c == nil then return true; end
        if c.empty then
            decide("empty", nil, "Leaving " .. (slot and slot.label or "slot") .. " empty");
        else
            decide("set", c.hash, "Chose " .. (c.name or "policy"));
        end
        return true;
    end

    -- Up / Down / Home / End: navigate the candidate list.
    if key == VK_UP then
        _state.ci = _state.ci - 1;
        if _state.ci < 1 then _state.ci = #_state.cands; end
        speak(candAnnounce(), "selection"); return true;
    elseif key == VK_DOWN then
        _state.ci = _state.ci + 1;
        if _state.ci > #_state.cands then _state.ci = 1; end
        speak(candAnnounce(), "selection"); return true;
    elseif key == VK_HOME then
        _state.ci = 1; speak(candAnnounce(), "selection"); return true;
    elseif key == VK_END then
        _state.ci = #_state.cands; speak(candAnnounce(), "selection"); return true;
    end

    -- T / R: read the highlighted candidate's effect description.
    if key == VK_T or key == VK_R then
        local c = currentCand();
        if c ~= nil then
            local parts = {};
            if c.name ~= nil and c.name ~= "" then parts[#parts + 1] = c.name; end
            if c.description ~= nil and c.description ~= "" then parts[#parts + 1] = c.description; end
            speak(table.concat(parts, ". "), "selection");
        end
        return true;
    end

    return false;
end

Log.info("PolicyWizard.lua: loaded");
