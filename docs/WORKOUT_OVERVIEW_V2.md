# Workout overview, version 2

> **Status: design proposal (2026-10-28), not implemented.** Replaces the layout in
> `LIVE_WORKOUT_OVERVIEW.md` §2–3 (the "where it shows" rules in §1 of that file still apply).
> Interactive mockup with sample data: `overview-mockup.html` (shared separately).

## Why a second version

The first design was a stack of cards (tiles, bars, a table) that looked the same for every
workout. You told us what you actually want to see after a workout:

1. **How the work split up**: runs vs stations, movement by movement, round by round.
2. **Heart rate**, and how it **moved through the whole workout**.
3. **Round or set splits**, shown the way that format is scored.

So the new overview has **one shared picture** (heart rate over the whole workout) and then
**one "story" view that changes with the format** (HYROX, rounds for time, every N:00, AMRAP).

## Principles

- **Score first, story second, table last.** The score is readable in 2 seconds; the full
  split table is folded away at the bottom.
- **The shape of the chart follows the shape of the workout.** Rounds become a grid, sets
  become fixed 3:00 slots, an AMRAP sits on its 20:00 clock. No format gets a generic list.
- **Everything is linked.** Tap anything (a band on the timeline, a run dot, a grid cell, a
  set, a table row) and the same segment lights up everywhere, with its numbers in one chip.
- **Honest data.** Missing heart rate is drawn as a gap, never smoothed over. Wrist heart rate
  during stations (sleds, wall balls, pull-ups) can read low or late; we say so once, quietly.
  The bottom line says how many splits were automatic and what data is missing.
- **Compare only with yourself.** The only comparison is your previous attempt at the same
  workout. No made-up field rankings.
- **Different things get different scales.** Run pace and station times never share an axis.
- **Same look as the app.** Card style, run blue, station orange, heavy rounded numbers.

## The shared element: the workout timeline

One wide chart, in every workout, right under the score.

- **Horizontal axis:** time from start to finish (to scale).
- **Coloured bands behind the curve:** one per segment. Run = blue, station = orange,
  rest = grey. Bands get a short label when there is room ("R3", "Sled", "Rest").
- **Heart-rate line** on top, from a sample every 5 seconds.
- **Zone strip** under the curve: a thin bar coloured by heart-rate zone (Z1 light → Z5 dark
  red), so "how long was I in the red" reads without a second chart.
- **Gaps:** if the watch lost heart rate, the line breaks and the gap is hatched "no HR".
- **Tap or drag** across the chart: the segment under your finger highlights, a chip shows
  its name, time, average and max heart rate (and pace for runs), plus the heart rate at
  that exact moment.
- **Caveat line** (small, grey): "Wrist HR can lag during stations."

Heart-rate zones use your max HR from Settings. Without one, we use the highest HR seen in
your recent workouts and label the zones "estimated".

## The story view, per format

### HYROX and other runs + stations (HYROX Solo/Doubles/Half, Partner WOD 1)
- **Hero:** total time, change vs your previous attempt ("−1:29 vs Oct 21").
- **Split bar:** one full-width bar split into Runs | Stations, with times. Roxzone (walking
  from station to run mat) is **inside run time** for now, and the bar says so: "Runs include
  Roxzone". It becomes its own third part once the watch records transitions (Later).
- **Run pace strip:** 8 dots, one per run, pace on a vertical scale (faster = higher), with
  your previous attempt as hollow dots. Under it: **fade** (run 8 vs run 1), best vs worst.
  A flag appears when run 1 is more than 20 s/km faster than your last runs: "Went out fast:
  first run 0:35/km faster than the last three." Runs of different lengths compare by pace.
- **Stations:** their own list on their own scale: time bar, avg/max HR, and the change vs your
  previous attempt per station (bigger time loss is easy to spot).

### Rounds for time (Helen; any for-time workout with a repeating round)
- **Hero:** total time and time left under the cap ("4:34 under the 16:00 cap").
- **Rounds × movements grid:** rows are rounds, columns are movements plus a Round column.
  Each cell shows the time, with average HR in small text. The cell is tinted against that
  movement's own average across rounds: teal = faster than your average, plum = slower.
  (A tint, plus a "+0:09" text, so it never relies on colour alone.)
- **Round totals:** fastest and slowest marked, and **drift**: "Round 3 was 21 % slower than
  round 1". The pull-up column usually tells the story.

### Every N:00 (Row + Thrusters every 3:00 × 6)
- **Hero:** "6 / 6 sets" and average work time.
- **Set slots:** one row per set, each drawn as the full fixed 3:00 slot. Work fills the left
  part (row light orange, thrusters full orange), rest is the light remainder. A set that runs
  past 3:00 is flagged "no rest".
- **Heart rate per set:** HR when the set started, the peak, and how far it dropped in the
  rest ("−35 bpm"). If HR at the start of each set keeps climbing, you are not recovering:
  "Start HR rose 100 → 151 over 6 sets."
- **Fixed-rest intervals** (e.g. 5 × 3:00 work / 1:00 rest, Later) use the same slots: work
  band, rest band, **peak HR per interval** and **HR at the end of the rest**.

### AMRAP (Nightmare AMRAP 20)
- **Hero:** rounds + reps ("4 + 51") and where you stopped ("Double Unders, 0:36 in").
- **Rounds on the 20:00 clock:** each round is a bar placed where it happened on the 0–20:00
  axis, split into its movements. The last, unfinished round is drawn short with a dashed end.
- **Round pace drift:** "Round 4 took 25 % longer than round 1", plus average per movement
  ("Double Unders ×9: avg 0:45, best 0:38").

### Anything else (fallback, e.g. Partner WOD 2)
Timeline plus one bar per segment on its own scale, and the table. Same interactions.

## Below the story
- **Splits** (folded): "Show all 16 splits". Race order: #, segment, time, cumulative time,
  avg/max HR, pace. Tapping a row highlights it on the timeline and in the story.
- **Data note** (one grey line): "14 of 16 switches automatic · 1 undo · HR gap 0:30 in Sled
  Push · steps OK". Tells you how much to trust the splits.

## How it works when you touch it
| Action | Result |
|---|---|
| Tap/drag on the timeline | Segment under the finger highlights everywhere; chip shows its numbers and HR at that moment |
| Tap a run dot, station bar, grid cell, set slot, round bar | Same segment (or whole round/set) highlights on the timeline |
| Tap a Round / set label | The whole round is highlighted; chip shows round time, avg/max HR |
| Tap the same thing again | Clears the highlight |
| Show all splits | Opens the table; rows work the same way |

## Data we need to add (all optional, old files keep working)

1. **`heartRateSeries` on the result** (required for the timeline). One value per 5 s since
   start; `null` where the watch had no reading. Compact, about 1,000 numbers for a HYROX.
2. **`roundSize` on the definition** (e.g. Helen 3, AMRAP 4, Row + Thrusters 3 incl. rest).
   Old files without it: we detect the repeating pattern from the movement list.
3. **`heartRateMin` per segment** (lowest HR in that segment, useful for rest recovery).
4. **Max HR setting** on the phone (for zones).
5. Later: transition segments (Roxzone), and typed-in reps for the partial AMRAP round.

```json
{
  "version": 2,
  "definition": { "id": "wod.helen", "roundSize": 3, "...": "..." },
  "heartRateSeries": { "start": 1793196000.0, "interval": 5, "bpm": [92, 97, 104, null, 131] },
  "segments": [ { "index": 0, "kind": "run", "heartRateMin": 101, "...": "..." } ]
}
```
Version 1 files decode unchanged (all new fields are optional). Without `heartRateSeries` the
timeline draws each segment's average HR as a flat step with its max as a tick, labelled
"Detailed heart rate not recorded for this workout".

## Proposed BarPathKit API (pure, testable, no SwiftUI)

```swift
public struct WorkoutSummary {
    public let headline: Headline        // score text, context line, vs-previous delta
    public let timeline: Timeline        // bands, HR points, gaps, zone runs
    public let story: Story              // the format-specific view model
    public let rows: [SplitRow]          // race-order table
    public let dataNote: DataNote        // auto vs manual, undos, missing HR/steps

    public static func make(result: WorkoutResult, previous: WorkoutResult?,
                            maxHeartRate: Double?) -> WorkoutSummary
}

public enum Story {
    case runsAndStations(RunsAndStations)   // triad, run paces + fade, stations + deltas
    case roundGrid(RoundGrid)               // cells[round][movement], round totals, drift
    case intervalSlots(IntervalSlots)       // per set: work parts, rest, start/peak/drop HR
    case amrapClock(AmrapClock)             // rounds on cap axis, partial round, stop point
    case segments([SegmentBar])             // fallback
}

public struct Timeline {
    public let duration: Double
    public let bands: [Band]                // segmentIndex, kind, start, end, shortLabel
    public let heartRate: [Double?]         // 5 s means, nil = gap
    public let zones: [ZoneRun]             // (zone 1...5, start, end); estimated flag
    public func segment(at t: Double) -> Int?
    public func stats(from: Double, to: Double) -> (avg: Double?, max: Double?, min: Double?)
}
```
Story choice: `amrap` → amrapClock; `emom` or `intervalSeconds` → intervalSlots; for-time with
runs alternating with stations → runsAndStations; for-time with a round size → roundGrid;
otherwise segments. All maths (fade, drift, recovery drop, cell tint) lives here with unit tests.

## Build plan

**First build**
1. Watch: write `heartRateSeries` into the result file; add `roundSize` to the library.
2. BarPathKit: `WorkoutSummary` + tests on the 4 sample workouts and a version 1 file.
3. Phone: hero, workout timeline (with tap/drag), the four story views + fallback, folded
   split table, data note. Used on Live and on the Workouts detail screen.
4. Previous-attempt comparison (same workout id): hero delta, hollow dots, station deltas.

**Later**
- Roxzone as its own part (needs transition segments on the watch).
- Zoom (pinch) on the timeline; previous attempt overlaid as a faint second HR line.
- Time in each zone summary; max HR setting with a "test" helper.
- Typed-in reps for the unfinished AMRAP round; fixed-rest interval workouts.
- Share image of the overview.
