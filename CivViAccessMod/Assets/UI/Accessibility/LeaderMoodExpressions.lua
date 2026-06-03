-- LeaderMoodExpressions.lua — evocative "expression" prose for a leader's mood /
-- approach, for the diplomacy first-meet announce. NOT YET WIRED: built
-- 2026-06-01 ahead of the diplomacy screen; the build will include + register it
-- and map the actual Civ VI approach/attitude enum onto these conceptual buckets.
--
-- WHY: the preamble should speak the leader's FACE, not a clinical label —
-- "Tokugawa watches you warily" instead of "Guarded" (Noel 2026-06-01). Each entry
-- is a bare verb-phrase so it reads after a pronoun OR a name:
--   "<He/She/They> " .. phrase   (preferred — preamble already said the name)
--   "<LeaderName> " .. phrase     (safe fallback when gender is unknown)
--
-- 5+ phrasings per mood so the same leader in the same mood doesn't read
-- identically every encounter. pick() varies by a caller-supplied seed (e.g.
-- leaderID + turn) so it's stable WITHIN an encounter but varies ACROSS them.

LeaderMoodExpressions = LeaderMoodExpressions or {};

LeaderMoodExpressions.phrases = {
    -- Allied / declared friend — the warmest read.
    allied = {
        "greets you like an old friend",
        "clasps your hand warmly",
        "welcomes you like family",
        "beams at the sight of you",
        "greets you with unguarded warmth",
    },
    friendly = {
        "smiles warmly",
        "greets you with an easy smile",
        "looks genuinely glad to see you",
        "gives you a warm, open nod",
        "brightens as you approach",
    },
    neutral = {
        "gives you a measured look",
        "regards you evenly",
        "studies you without expression",
        "greets you with a cool, polite nod",
        "meets your eyes, unreadable",
    },
    guarded = {
        "watches you warily",
        "eyes you with quiet caution",
        "keeps you at arm's length",
        "weighs every word before answering",
        "regards you carefully, giving nothing away",
    },
    unfriendly = {
        "frowns",
        "eyes you coldly",
        "greets you with a thin, joyless smile",
        "looks faintly disappointed in you",
        "barely bothers to hide their distaste",
    },
    hostile = {
        "glares at you",
        "scowls openly",
        "fixes you with a hard, furious stare",
        "looks ready to have you thrown out",
        "can barely contain their contempt",
    },
    afraid = {
        "eyes you nervously",
        "shifts uneasily as you speak",
        "can't quite hide their unease",
        "watches you the way one watches a circling wolf",
        "forces a smile that doesn't reach their eyes",
    },
    -- The sneaky one Noel asked for — words and face deliberately disagree.
    deceptive = {
        "smiles a little too smoothly",
        "grins slyly, as if at a private joke",
        "offers a smile that never reaches their eyes",
        "watches you with a sly, calculating warmth",
        "smiles — but something underneath it doesn't",
    },
    war = {
        "scowls, ready for a fight",
        "regards you like a problem to be solved",
        "meets you with cold, martial contempt",
        "looks at you with open, weary hatred",
        "squares up as if the war were already in the room",
    },
};

-- Pick one phrase for `mood`, varied by `seed` (stable within an encounter when
-- the caller passes a stable seed like leaderID + turn). Returns nil for an
-- unknown mood so the caller can fall back to the raw label.
function LeaderMoodExpressions.pick(mood, seed)
    local list = LeaderMoodExpressions.phrases[mood];
    if list == nil or #list == 0 then return nil; end
    local n = #list;
    local s = math.floor(math.abs(seed or 0));
    return list[(s % n) + 1];
end
