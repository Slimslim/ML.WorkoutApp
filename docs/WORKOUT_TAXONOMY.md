# Workout taxonomy (spike, draft)

Status: **spike, docs + Python only.** Nothing runs on the watch or the phone. Code:
`tools/barpath/taxonomy.py` (pure classifier), `tools/taxonomy_corpus.py` (read-only corpus
coverage), tests in `tools/tests/test_taxonomy.py`. Every example in this document and in the
tests is invented.

## 1. What it is for

Every workout gets five labels: modality, shape, time domain, loading and scoring. They feed
history ("your medium couplets"), recommendations, the library's filters, and checks on the
import. Hyrox is classified the same way as any other workout. It is a long, mixed chipper; its
stations are only extra tags.

**Rule: derived, never stored.** The labels are computed from the workout's structure (RFC #55,
`docs/WORKOUT_MODEL_RFC.md` §3: piece, `timed` window, `repeat`, `part`, `rest`) and from the #138
round decisions (`docs/WORKOUT_SPEC.md` §5c). They are never saved as a second description of the
workout. If the structure changes, the labels change with it. Any cache must be keyed by the
structure hash (RFC §4 rule 11).

## 2. How it plugs in

```
v2 document (structure)  ─┐
today's flat definition  ─┼─ adapter ─► Workout (intermediate form) ─► 5 axes
import parse (drafts)    ─┘
```

- **`from_v2(doc)`** walks `structure.body`. It handles:
  - `part` becomes an element, with its movement, target and load (`value`/`unit` or `percent`/`basis`).
  - `repeat.times` gives the passes. `times: null` is an unbounded repeat, which only a clock ends.
  - `repeat.vary`:
    - numbers that rise or fall make a **ladder**;
    - a list of movement patches (Hyrox's 8 stations) makes per-round movements, which is a
      single pass and not a ladder.
  - `timed` at the top is the clock (AMRAP, cap). A `timed` inside a `repeat` is one interval
    window, and one window is one pass of the block (§5c Q3).
  - `rest.seconds` and `rest.ratio`.
  - Parts before or after the main repeat are the buy-in and cash-out.
  - `score.type`.
- **`from_v1(definition)`** reads today's flat rows: `format`, `segments`, `timeCapSeconds`,
  `intervalSeconds`, `roundSize`, and `rounds` (§5c). If a written-out list repeats by
  `roundSize`, it is folded back into one block and its passes, so Helen's 3 listed rounds read as
  3 rounds of a triplet.
- **`from_draft_piece(classification)`** reads one scale of a `workout_drafts` row as the import
  parsed it:
  - `format`, `flags` and `scoring`;
  - each piece's `kind`, `rounds` and `window_s`;
  - movements with `name`, `reps`, `load`, `distance`, `unit` and `time`.

  It takes only numbers from the piece header ("AMRAP 12", "every 3 min for 15 min") and keeps no
  text. A "movement" that is really an instruction line is skipped.

Every axis returns `{value, confidence, reasons}`:
- `confidence` is `high`, `medium` or `low`.
- `value: unknown` always has confidence `unknown`.
- `reasons` are short codes (`lexicon`, `cap_upper_bound`, `rx_standard`, …), never workout text.

## 3. The five axes

### 3.1 Modality: G / W / M + Hyrox stations

CrossFit's three modalities:
- **G**, gymnastics or bodyweight: pull-ups, push-ups, burpees, box jumps, handstand work, holds.
- **W**, weightlifting or any external load: barbell, dumbbell, kettlebell, wall ball, sandbag,
  sled, carries.
- **M**, monostructural: run, row, bike, ski, swim, jump rope.

Derivation, per element:
1. A known movement id uses the lexicon (`MOVEMENTS`).
2. A free-text name is matched to an id by keyword (`_NAME_RULES`). "Echo Bike" → `bike`,
   "Bent-over Row" → `barbellRow` (W, not the rower).
3. An unknown name falls back to keywords (a load word → W, an erg or distance word → M, a
   bar/ring/jump word → G). Failing that, it is unknown.
4. A G movement with a prescribed load counts as W (`loaded_bodyweight`, e.g. a weighted pull-up).

The workout's value is the set present, written in the order `G`, `W`, `M`: `G`, `GW`, `GWM`, …

**Hyrox stations** are tagged as they appear: SkiErg, sled push, sled pull, burpee broad jumps,
row, farmers carry, sandbag lunges, wall balls. Each station still has its own modality: SkiErg
and row are M, the sleds, carry, lunges and wall balls are W, and burpee broad jumps are G.

### 3.2 Shape

A primary shape plus modifiers. The primary shape is taken in this order:

| Shape | Rule |
|---|---|
| `multi_part` | More than one scored piece. |
| `strength_sets` | Sets scored by load (a single loaded movement with rest). |
| `intervals` | Windows inside a repeat (EMOM, "every X", Tabata), or a counted repeat with a fixed rest (work:rest). The reason says which. |
| `ladder` | A movement's target rises or falls across rounds (`vary`, or the import's ladder flags). The reason gives the direction: ascending, descending or open. |
| `chipper` | 4 or more movements, done once. A different movement every round (Hyrox) also counts as once. |
| `rounds` | 4 or more movements, repeated. |
| `single` / `couplet` / `triplet` | 1, 2 or 3 distinct work movements. |

- **Modifiers:** `buy_in`, `cash_out`, `partner`, `max_effort`, `ratio_rest`, and `ladder_*` when a
  ladder sits inside intervals (death-by).
- **Distinct movements:** counted by movement id. Rests and generic parts are ignored.

### 3.3 Time domain

The expected duration of the work, sorted into four buckets by named constants:

| Domain | Up to |
|---|---|
| short | `SHORT_MAX_S` = 8:00 |
| medium | `MEDIUM_MAX_S` = 15:00 |
| long | `LONG_MAX_S` = 30:00 |
| very long | beyond |

Sources, in order:
1. **A clock**: an AMRAP or timed piece, or windows × interval. That is the duration, with high
   confidence.
2. **A for-time cap.** This is only an upper bound. When the estimated work is shorter, the
   estimate is used (`estimated_under_cap`); otherwise the cap (`cap_upper_bound`, medium).
3. **Estimated work**, from named pace constants:
   - reps × `SECONDS_PER_REP` per modality;
   - run at `RUN_M_PER_S`;
   - ergs at `ERG_M_PER_S`;
   - calories at `SECONDS_PER_CAL`;
   - carries at `CARRY_M_PER_S`;
   - plus fixed rests, and `REST_BETWEEN_SETS_S` between strength sets.

   This is medium confidence, or low when some parts have no number.
4. **Unknown:** an unbounded repeat with no clock (until the athlete fails), or no numbers at all.

Hyrox Solo comes out at about 61 min, very long. Helen with its 16:00 cap comes out at about 11 min
(medium), not at the cap.

### 3.4 Loading, relative to the athlete

The heaviest loaded element decides, as light, moderate or heavy. The reference is chosen in this
order:
1. **The athlete's own max** for that movement, when known (the `athlete_max_kg` argument):
   % of max, high confidence.
2. **A stated percentage** ("75% 1RM", `load.percent`): that percentage, high confidence.
3. **The RX standard** for the movement (`MOVEMENTS`, public CrossFit/Hyrox standards for men and
   women): load ÷ RX, **medium** confidence, because RX is a proxy, not the athlete.
4. **Otherwise unknown:** no load, "pick a load", or no reference (for example a back squat with no
   percentage and no known max).

The thresholds are named constants:

| Reference | Light | Moderate | Heavy |
|---|---|---|---|
| Percent of a max | below `PCT_LIGHT_MAX` = 65 % | 65–80 % | from `PCT_HEAVY_MIN` = 80 % |
| Ratio to RX | below `RX_LIGHT_MAX` = 0.75 | 0.75–1.10 | from `RX_HEAVY_MIN` = 1.10 |

Gendered RX ("95/65 lb") takes the first value for men and the second for women, through the
`sex` argument. The default is the first.

### 3.5 Scoring

| Value | From |
|---|---|
| `time` | score `time`, `longestHold`; v1 `forTime` |
| `rounds_reps` | `roundsReps`; v1 `amrap` |
| `reps` | `totalReps`, `lowestReps` |
| `load` | `load` |
| `calories_distance` | `distance`, `calories`, `maxHeight` |
| `pass_fail` | `windowsCompleted`: an EMOM is done, or it isn't. v1 `emom` gets medium confidence. |
| `none` | `none` (practice, quality work) |

`perPiece` takes its piece metric (low confidence). An import label that names two scores ("time or
load") is unknown (`score_ambiguous`).

## 4. Edge cases

- **Hyrox:** a chipper (one pass, the station changes each round) with all 8 station tags. It is
  very long and scored by time. There is no special case in the code.
- **Death-by:** intervals with a `ladder_open` modifier. Its time domain is unknown, because it
  ends on failure.
- **Buy-in + AMRAP + cash-out:** the shape comes from the AMRAP's movements, with `buy_in` and
  `cash_out` added as modifiers.
- **A cap on a for-time workout** never sets the domain by itself when the work estimate is shorter.
- **Rest by ratio** (`rest.ratio`, rounds each timed): the `ratio_rest` modifier. The rest is left
  out of the time estimate, because it depends on the athlete.
- **Written-out rows** (today's AMRAPs, Helen) are folded back by `roundSize` before shape is
  decided, so a written-out triplet is still a triplet.
- **Bodyweight with a vest** counts as W.
- **Movement names the lexicon doesn't know** fall back to keywords. Otherwise that element is
  unknown, and the count shows in the modality reasons (`unknown_movements:n`).

## 5. Corpus coverage

`tools/taxonomy_corpus.py` reads `workout_drafts`, **read-only**, either from a JSON export or with
`PGURL` in a read-only transaction. It prints aggregates only:
- counts per axis value;
- the unknown rate per axis;
- confidence counts;
- the top reason codes for unknowns;
- the lexicon miss rate;
- the Hyrox station counts;
- checks for likely misclassifications. The import's own format is compared with the derived
  shape and scoring, and a timed format with no clock is flagged. The checks list draft ids only.

It never prints workout text, movement names, programs or gyms. Draft ids embed program slugs, so
only a `--ids 0` run may be committed. To run it:

```
python3 tools/taxonomy_corpus.py --pg --ids 0 > corpus_summary.md   # PGURL set, read-only
python3 tools/taxonomy_corpus.py --export drafts.json --ids 20        # id lists stay local
```

The Data chat runs it and cross-checks the misclassifications. Its `--ids 0` summary table goes
here:

> _Summary table: pending the Data chat's run._

For reference, the import's own format labels over the 3,038 pieces (labels only, counted
20 Nov): strength sets 518, quality 511, EMOM 482, rounds for time 396, for time 333, AMRAP rounds
167, rounds each timed 149, intervals for max reps 84, AMRAP reps 81, max-effort test 61, repeated
windows 54, station rotation 31, cycles continued 20, repeat efforts 40, buy-in windows ~50,
Tabata 10, death-by 3, multi-part ~22.

## 6. Open questions for the owner (at most 5)

1. **Time-domain thresholds.** Short up to 8:00, medium up to 15:00, long up to 30:00, very long
   beyond. Is that right? (CrossFit usage varies; some coaches put short under 5 min and long
   from 20.)
2. **Loading without the athlete's max.** Is RX an acceptable proxy, at medium confidence? Or
   should loading stay unknown until the app knows the athlete's maxes? And are the RX/percent
   thresholds (0.75 / 1.10 and 65 % / 80 %) right?
3. **Shape names.** 4+ movements repeated is `rounds`, and a chipper must be done once. Is that the
   naming you want? And should Hyrox's run + station × 8 be a chipper, or a shape of its own?
4. **Modality of borderline movements.** Double-unders count as M (CrossFit's usage), wall balls
   as W, and burpee broad jumps as G. Agree?
5. **EMOM scoring.** A completed EMOM counts as `pass_fail`. Should it be `none` when nothing is
   recorded, and `reps` when the last window is for max reps?
