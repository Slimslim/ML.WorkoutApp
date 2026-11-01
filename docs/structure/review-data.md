# Review: data model, import, Insights (proposal v1)

The tabs are sound. The proposal names screens, not the records they show.

## 1. Scenario walk (P1/P2: logging, history, compare, insights, import, settings)

| ID | Verdict | Why |
|---|---|---|
| S-04 | Partial | Unit toggle only; no canonical storage rule |
| S-07 | Partial | Merge planned; no migration mapping |
| S-08 | Fails | No storage/iCloud story |
| S-09 | Partial | Schedule button, no Plan record |
| S-10 | Partial | Photo import is post-race; OCR on-device undecided |
| S-11 | Partial | Paste yes; no Share Sheet |
| S-12 | Works | Needs Rx/scaled loads per definition |
| S-15 | Partial | Target needs result linked to definition version |
| S-19 | Partial | Line flags good; no track choice |
| S-20 | Fails | One format per workout, no blocks |
| S-24 | Works | Flagged line = free-text movement |
| S-25 | Fails | No "save as my version" lineage |
| S-26 | Partial | Rx/scaled set on definition, not result |
| S-28, S-29 | Fails | No partner model |
| S-30 | Works | Score type must carry "capped" |
| S-33 | Fails | No stored 1RMs, no plate rounding |
| S-35 | Partial | Mock shows gym day; question 5 open |
| S-37 | Fails | No score-type taxonomy |
| S-58 | Fails | No Health import |
| S-59 | Fails | No delete/merge, no dedupe key |
| S-63 | Fails | + has no "Log a result" |
| S-64 | Fails | No notes/RPE |
| S-65 | Fails | Variant not editable on result; PR recompute undefined |
| S-66 | Fails | No time zone stored |
| S-67, S-71 | Partial | PR badge needs a comparability rule |
| S-69 | Partial | Type filters; no movement search |
| S-70 | Partial | Overlay needs stable segment IDs across versions |
| S-75 | Partial | Rx notes have no evidence links |
| S-76 | Partial | Resting HR has no source (Health read) |
| S-81 | Fails | No official-splits record |
| S-82 | Partial | Calibration is P1 but scheduled post-race |
| S-85 | Works | JSON/CSV exists |
| S-86 | Fails | Health write not in build order |
| S-88 | Fails | No share redaction |
| S-91 | Works | Max HR before Anaheim |
| S-92 | Partial | Conversion and plates unspecified |
| S-94–96 | Fails | No device ID, backup, export-all |
| S-97 | Partial | Debug moved; no scrubbed "Send diagnostics" |
| S-98 | Fails | No delete |
| S-100 | Fails | PRs are Rx-only |

Tally: 5 work, 18 partial, 19 fail. Most failures are missing entities, not missing screens.

## 2. Top 10 findings (ranked)

1. **Definition, result and session are conflated.** *Rec:* lock the model in section 3 before the tab work.
2. **The variant sits on the workout, not the result** (S-26, S-65, S-25, S-100). *Rec:* the result stores variant (Rx / Scaled / Custom / Variant-of), the choices picked and the actual loads. PRs compare by a **comparability key** (lineage + variant + score type). Scaled PRs are first-class.
3. **No partner model** (S-28, S-29, both P1). *Rec:* a result holds the team score plus its splits, each tagged me / partner / together. HR and effort insights use only "me".
4. **No manual results and no score types** (S-63, S-37). *Rec:* add "Log a result" to +. Add `source` (watch / manual / health / official) and a typed score (time, rounds+reps, reps, load, distance, cal, lowest/total) with a capped flag and sort direction.
5. **Edits overwrite meaning** (S-62, S-65, S-66). *Rec:* the raw recording is immutable. Edits (splits, variant, date, trim) are a restorable layer. PRs and Insights are always recomputed. Store UTC plus the local time zone.
6. **The import pipeline is flat** (S-11, S-19, S-20, S-24). *Rec:* source (text / photo / share) → **blocks** → per-line movement match with confidence → track pick → confirm. Keep the original on the device only. Ship the Share Sheet with TestFlight. Mapping an unknown movement later backfills old results.
7. **The Insights cold start is not credible as specced.** btwb's Fitness Level rests on population percentiles; with 3 users it would be invented. *Rec:* answer question 4 with "cards on Today first" and phase it as in section 4. Any 0–100 score cites published standards.
8. **Units are deferred but TestFlight needs them** (S-04, S-33, S-92). *Rec:* store kg, metres and seconds, plus the unit as entered, so 95 lb never shows as 43.09 kg. Add a plate-set setting for rounding and 1RMs per lift for % loads.
9. **Export and ingest are missing** (S-86, S-58, S-59, S-94). *Rec:* write an HKWorkout before Anaheim (activity type per format, HR samples). Give each result a UUID minted on the watch, so sync can't duplicate it and duplicates can be found. Strava via Health later. Export-all in P2.
10. **Privacy with a public repo.** The proposal embeds the owner's real HR results. *Rec:* use synthetic fixtures and keep no real health data in the repo. Scrub diagnostics and preview them before sending. Add a share toggle that hides HR and body weight. Settings › Data: on the device plus your iCloud only.

## 3. Proposed core data model

- **Movement**: dictionary with aliases (T2B, "alt db snatch") and a category.
- **WorkoutDefinition**: lineage ID with immutable **versions**. It holds its origin (benchmark, class, mine, variant-of a parent) and its source text or photo.
- **Block**: Strength / WOD / Finisher / Warm-up / Cool-down. Each has a format, cap, score type and planned **segments**: movement, reps or distance or cal, loads per track or as %1RM, and **choices** (A or B, alternate by round).
- **Plan**: a definition version on a date.
- **Session (gym day)**: one Log row with date, time zone and gym. It contains Results and LiftSets.
- **Result**: links to a definition version and a block. It holds source, device, variant, choices, actual loads, typed score, team score, notes, RPE and an incomplete flag.
- **Recording**: raw watch data, immutable, zero or one per Result.
- **Split**: a measured segment with an owner (me / partner / together), work or rest, excluded or not, and an edit layer.
- **LiftSet / Rep**: load, make or miss, bar-path metrics.
- **Profile**: max and resting HR, body weight, units, plate set, 1RMs, run calibration.
- **Derived** (recomputed, never edited): PRs per comparability key, trends, levels, and recommendations with evidence IDs.

## 4. Phased Insights plan

**1 workout:** report only. Score, HR zones, work vs rest, recovery at 1 and 3 minutes, and pacing inside the workout (first vs last round, run splits vs average). Label it "Baseline set".

**10 workouts:** deltas vs the last attempt on the same comparability key. PRs, scaled PRs included. A recovery trend only with 5 or more comparable efforts, tagged low confidence. A load-velocity line per lift once it has 3 or more loads. HYROX run pace vs station time. Rx notes cite their evidence ("vs your Sep 12 sim").

**50 workouts:** btwb-style category levels built from measured data. Estimated 1RM for the power lifts, velocity at load for the Olympic lifts, run pace and HR at pace for speed and endurance, and benchmark times against published standards for the metcon categories. Imbalance notes appear only when both categories have data from the last 90 days. Recommendations show confidence and link to their data. The Fitness Level is marked "estimate" and shows its method; empty categories are greyed out, not averaged.
