# Expansion-Specific Accessibility Backlog

Features that don't exist in base-game Civ VI and so don't gate the
foundational accessibility work, but need their own pass once the
0.5.x Playable Basics arc lands. Tracking here so we don't forget.

## Rise & Fall (RULESET_EXPANSION_1)

- **Loyalty system** — per-city loyalty pressure, free city flips
- **Governors** — recruit, assign, promote, abilities
- **Era Score & Golden / Dark Ages** — historic moments, dedications,
  era transitions
- **Emergencies** — multi-civ crisis response (city captured by rival,
  nuclear strike, etc.)
- **Timeline** — "My historic moments" log

## Gathering Storm (RULESET_EXPANSION_2)

GS includes all of R&F plus its own additions.

- **World Congress** — resolutions, voting, diplomatic favor
- **Climate Change** — CO2 emissions, climate phase, sea-level rise
- **Power** — coal/oil/uranium consumption per turn, renewable energy
  generation, power-required-by-city status
- **Strategic Resource accumulation** — no longer infinite stockpiles,
  resource economy is now a serious gameplay layer
- **Diplomatic Victory** — World Congress points, diplomatic vote
- **Future Tech tree** — repeatable end-game tech
- **Floods** — river overflow per turn, flood damage to tiles
- **Storms** — hurricanes, tornados, blizzards, dust storms,
  volcanic eruptions
- **Resilient / Erosion-prone tiles** — new tile attribute affecting
  flood / storm risk
- **Dams** — adjacency to rivers, flood mitigation

## GS Game Modes (stackable on any ruleset)

Optional rule overlays that can layer onto Vanilla, R&F, or GS:

- **Heroes & Legends** — recruit heroes, time-limited
- **Apocalypse** — disaster intensity dialed up, soothsayer units
- **Tech & Civic Shuffle** — randomized prerequisites
- **Secret Societies** — join one of four, ability progression
- **Dramatic Ages** — Golden / Dark Ages more impactful
- **Monopolies & Corporations** — luxury control, products
- **Barbarian Clans** — barbarian camps can level into city-states
- **Zombie Defense** — zombies replace barbs
- **Red Death** — separate battle-royale ruleset

Each mode adds its own UI surfaces and notifications that need
accessibility passes.

## Fog of war is NOT expansion-specific

Confirmed 2026-05-24: the three Civ VI visibility states
(unrevealed / revealed-but-foggy / visible) are identical across
vanilla, R&F, and GS. `HexCursor.AnnouncePlot`'s fog-of-war gate
([[project_fog_of_war_respect]]) works for all rulesets. Expansion
data (loyalty, climate, etc.) is per-plot extra info that should
appear ONLY when the plot is visible — same gate applies.

## Sequencing

These all defer to AFTER the 0.5.x Playable Basics arc closes
(see `docs/PLAYABLE_BASICS_PLAN.md` for in-progress work).
Don't pull any of this forward — foundational primitives first.

## How to apply

When designing a new in-game accessibility feature, check this list
to see if it overlaps with expansion content. If yes, gate the new
code on `Modding.IsModEnabled(EXPANSION_GUID)` or check the active
ruleset (`GameConfiguration.GetRuleSet()`) so vanilla games don't
trip on missing API.
