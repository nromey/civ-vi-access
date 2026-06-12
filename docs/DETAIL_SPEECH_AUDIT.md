# Detail-speech audit (Ctrl+T / T / Shift+T readouts)

Started 2026-06-12 after the Craftsmanship misread: "Inspiration: Improve 3
tiles" was heard as *the civic improves 3 tiles* — conditional game text
spoken without making the if-then direction unmistakable. Noel: "I'd much
rather have improved three tiles and been boosted than study Craftsmanship in
double the time."

**Method (playthrough-driven, NOT preemptive rewording):** the engine's LOC
strings are usually complete sentences and rewording them on speculation
risks breaking good text. Each row below gets validated LIVE — press the
detail key on a few real items, listen for if-then ambiguity, fix what's
actually confusing. Mark rows as they're cleared.

## Status

- [x] **TechPickerAddin / CivicPickerAddin `composeLongForm` (Ctrl+T)** —
  FIXED 2026-06-12: boost triggers now phrase as conditions with the percent
  ("Inspiration boost, saves 40 percent — to earn it: Improve 3 tiles" /
  "Boost earned, 40 percent saved (...)").
- [x] **BuildImprovementPicker `lockReason`** — FIXED 2026-06-12: the two
  separate gates now read ", and needs <terrain> terrain" instead of a
  semicolon that speech ran together.
- [ ] **ProductionPickerAddin `composeLongForm` (Ctrl+T)** — speaks LOC
  description + the raw engine tooltip (ToolTipHelper.Get*ToolTip). VALIDATE:
  Ctrl+T a unit, a building, a district. Listen for: maintenance cost
  present? required district named? passive-voice condition/effect mixups?
- [ ] **ChoosePopupAccess T-detail** (pantheons, dedications, government
  types) — raw `opt.description`. VALIDATE at next pantheon/dedication:
  any condition spoken as an effect? Needs a "once per game" / exclusivity
  label anywhere?
- [ ] **PolicyWizard T/R card effect** — raw card description. VALIDATE while
  re-slotting: any card whose effect reads ambiguously? Slot-type
  restrictions audible?
- [ ] **HexCursor.DescribeVerbose (Shift+T tile mechanics)** — raw numbers
  into LOC templates (defense modifier, appeal). VALIDATE: negative defense
  modifier tile (marsh/floodplain) — does it sound like a penalty? Also
  consider: luxury vs strategic label on resources.

## Deferred ideas the audit surfaced (queue, don't preempt)

- Production detail: obsolescence ("replaced by X at tech Y") and
  district-gate lines if the engine tooltip turns out not to carry them.
- Pantheon/belief detail: exclusivity labels.
- Tile verbose: luxury/strategic resource class label.
