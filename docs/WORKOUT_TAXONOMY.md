# Workout taxonomy (spike, draft)

Status: **spike, docs + Python only.** Nothing runs on the watch or the phone. Code:
`tools/barpath/taxonomy.py` (pure classifier), `tools/taxonomy_corpus.py` (read-only corpus
coverage), tests in `tools/tests/test_taxonomy.py`. Every example in this document and in the
tests is invented. Revised after the coach review of #154.

## 1. What it is for

Every workout gets six labels: **modality, movements, structure, time domain, loading and
scoring.** They feed history ("your medium couplets"), recommendations, the library's filters, and
checks on the import. Hyrox is classified the same way as any other workout: a very long chipper
with runs interleaved; its stations are only extra tags.

**Rule: derived, never stored.** The labels are computed from the workout's structure (RFC #55,
`docs/WORKOUT_MODEL_RFC.md` §3: piece, `timed` window, `repeat`, `group`, `part`, `rest`) and from
the #138 round decisions (`docs/WORKOUT_SPEC.md` §5c). They are never saved as a second description
of the workout. If the structure changes, the labels change with it. Any cache must be keyed by the
structure hash (RFC §4 rule 11).

## 2. How it plugs in

```
v2 document (structure)  ─┐
today's flat definition  ─┼─ adapter ─► Workout (intermediate form) ─► 6 axes
import parse (drafts)    ─┘
```

- **`from_v2(doc)`** walks `structure.body`:
  - `part` becomes an element: movement, target, load (`value`/`unit` or `percent`/`basis`), `who`.
  - `repeat.times` gives the passes; `times: null` is unbounded (only a clock or failure ends it).
  - `repeat.vary`:
    - a numeric list that rises, falls or peaks is a **rep scheme** (21-15-9, 1-to-10, pyramid);
    - a `{from, step}` climb in an unbounded repeat is an **open ladder**;
    - a list of movement patches (Hyrox's 8 stations) is per-round movements: one pass.
  - `timed` at the top is the clock (AMRAP) or a cap; inside a `repeat` it is one interval window.
  - `group` with `asStep` is a complex (one implement, one load on the group).
  - `rest.seconds` and `rest.ratio`.
  - Parts before or after the main repeat are the buy-in and cash-out.
  - `score.type`; a `perPiece` workout with several top-level pieces is classified per piece.
- **`from_v1(definition)`** reads today's flat rows (`format`, `segments`, `timeCapSeconds`,
  `intervalSeconds`, `roundSize`, `rounds`). A written-out list that repeats by `roundSize` is
  folded back into one block; targets that change by round become the rep scheme.
- **`from_draft_piece(classification)`** reads one scale of a `workout_drafts` row as the import
  parsed it (`format`, `flags`, `scoring`, each piece's `kind`, `rounds`, `window_s`, movements).
  It takes only numbers from the header ("AMRAP 12", "every 3 min for 15 min") and keeps no text.
  Instruction lines parsed as movements are skipped.

Every axis returns `{value, confidence, reasons}`:
- `confidence` is `high`, `medium` or `low`;
- `value: unknown` always has confidence `unknown`; `value: n/a` (does not apply) has `high`;
- `reasons` are short codes (`lexicon`, `vs_standard`, `cap_upper_bound`, …), never workout text.

## 3. The six axes

### 3.1 Modality: G / W / M, primary, Hyrox stations

- **G**, gymnastics or bodyweight: pull-ups, push-ups, burpees, box jumps, burpee broad jumps,
  handstand work, wall walks, holds.
- **W**, an external load: barbell, dumbbell, kettlebell, wall ball, thrusters, sandbag, sled,
  carries, odd objects.
- **M**, monostructural: run, row, bike, ski, swim, double-unders.

Per element: the lexicon (`MOVEMENTS`), else a free-text name matched by keyword (`_NAME_RULES`;
"Bent-over Row" is a barbell row, not the rower), else keyword fallbacks, else unknown.
**Weighted bodyweight stays G** (a vest, a weighted pull-up): the axis carries `loaded: true` and
the structure gets the `loaded_bodyweight` modifier; the load is a loading matter.

The value is the set present in the order `G`, `W`, `M`. **`primary`** is the modality with the
largest share of the estimated time (an 800 m run with a few thrusters is primary M).

**Hyrox stations** are tagged as they appear: SkiErg, sled push, sled pull, burpee broad jumps,
row, farmers carry, sandbag lunges, wall balls. Each keeps its own modality.

### 3.2 Movements

The number of distinct movements of the **main work**: `single`, `couplet`, `triplet`, `4plus`.
Counted by movement id; rests and generic parts are ignored, and **buy-in and cash-out are not
counted** (reason `buy_in_cash_out_excluded`).

### 3.3 Structure

One value plus modifiers. Taken in this order:

| Structure | Rule |
|---|---|
| `multi_part` | More than one scored piece. Each piece is classified on its own; `pieces` lists their structures. |
| `practice` | Nothing scored and no clock: skill, quality or accessory work. Time domain and loading are `n/a`. |
| `strength` | Detected from the structure, not the label: every main part loaded, one movement (or one complex), and low reps (`STRENGTH_MAX_REPS` = 6) in sets or windows, or a stated %RM in sets, or scored by load. Reasons: `low_reps_in_sets`, `percent_load`, `scored_by_load`, `complex`, `max_effort`. |
| `ladder` | An **open** ladder only: reps climb until the clock or failure (death-by, an ascending AMRAP ladder). |
| `intervals` | Windows inside a repeat (EMOM, "every X", Tabata), or a counted repeat with a fixed rest (work:rest). |
| `amrap` | An unbounded repeat ended by a clock. |
| `rounds` | A counted repeat of the same movements. |
| `chipper` | One pass of 4 or more movements, in order (a different movement each round, as in Hyrox, is one pass). |
| `for_time` | One pass of 1 to 3 movements. |

**Modifiers:**
- rep scheme: `reps_descending` (21-15-9), `reps_ascending` (1-to-10), `pyramid`;
- `buy_in`, `cash_out`, `ratio_rest`;
- `partner:<split>`: `split_as_needed` (shared reps), `you_go_i_go`, `synchro`, `stations_split`
  (a doubles race), `unknown` (only flagged);
- `complex`, `max_effort`, `interval_wrapper` (strength done on an EMOM clock);
- `run_interleaved` (four or more runs between Hyrox stations: a race or race simulation);
- `odd_object` (sandbag to shoulder, stone, yoke), `loaded_bodyweight`.

### 3.4 Time domain

The expected **work time per athlete**, in buckets set by named constants:

| Domain | Up to |
|---|---|
| short | `SHORT_MAX_S` = 8:00 |
| medium | `MEDIUM_MAX_S` = 15:00 |
| long | `LONG_MAX_S` = 30:00 |
| very long | beyond |

`n/a` for `strength` and `practice`: their length is rest between sets, not work.

Sources, in order:
1. **A clock** (AMRAP, windows × interval): that is the duration, high confidence.
2. **A for-time cap** is only an upper bound: the estimate is used when shorter
   (`estimated_under_cap`), else the cap (`cap_upper_bound`, medium).
3. **Estimated work** from named pace constants, medium confidence (low when some parts have no
   number):
   - per-movement seconds per rep (`SECONDS_PER_REP`): double-unders ~0.65, pull-ups ~1.75, wall
     balls and thrusters ~2.75, burpees ~4.5, muscle-ups ~5.5, rope climbs ~25; heavy barbell reps
     `SECONDS_PER_REP_HEAVY` = 6.5; a fallback per modality;
   - per-machine seconds per calorie (`SECONDS_PER_CAL`): air bike ~2.75, row and BikeErg ~3.75,
     ski ~4.5;
   - metres per second (`METERS_PER_SECOND`): run 3.3, row 4.0, ski ~3.6; sleds, sandbag lunges
     and burpee broad jumps 0.35–0.45;
   - fixed rests are added; **rest by ratio counts as work × (1 + ratio)**;
   - partner work: shared or alternating parts count half per athlete;
   - Hyrox race: plus a Roxzone transition allowance (`ROXZONE_S` = 25 s per change).
4. **Unknown:** an unbounded repeat with no clock (ends on failure), or no numbers at all.

Intervals also get **`work_bout`**: `short` up to 1:00, `medium` up to 3:00, `long` beyond, from the
work in one window.

Invented checks: a 3-round triplet of 400 m run, 21 swings and 12 pull-ups under a 20:00 cap comes
out at about 9 min (medium), not at the cap; a full Hyrox Open race comes out at about 75 min
(very long).

**Hyrox paces and loads are constants to check against the current Hyrox rulebook** before relying
on them (`METERS_PER_SECOND`, `ROXZONE_S`, `HYROX_DIVISIONS`).

### 3.5 Loading, relative to the athlete

`light`, `moderate`, `heavy`, or **`bodyweight`** when nothing is loaded (not unknown). The
heaviest loaded element decides. The reference, in order:
1. **A stated percentage** ("75% 1RM", `load.percent`): high confidence.
2. **The athlete's own max** for that movement (`athlete_max_kg`): high confidence.
3. **The standard for that movement, implement and sex** (`STANDARDS`): reason `vs_standard`,
   **medium** confidence, because a standard is a proxy, not the athlete. The implement is
   resolved first (barbell, single dumbbell, dumbbell pair, kettlebell, med ball, sandbag, stone),
   from the movement and its name: "DB thrusters" are compared with the dumbbell standard, not the
   barbell one; a goblet squat is a kettlebell. In a Hyrox workout, the stations are compared with
   the race divisions (`HYROX_DIVISIONS`: Open moderate, Pro heavy; check the current rulebook).
4. **Unknown:** loaded with no reference (`no_reference`, e.g. a sandbag clean, or a back squat by
   kg with no max), or "pick a load" (`pick_load`).

`n/a` for `practice`.

| Reference | Light | Moderate | Heavy |
|---|---|---|---|
| Percent of a max | below `PCT_LIGHT_MAX` = 65 % | 65–80 % | from `PCT_HEAVY_MIN` = 80 % |
| Ratio to the standard | below `RX_LIGHT_MAX` = 0.75 | 0.75–1.10 | from `RX_HEAVY_MIN` = 1.10 |

**Gendered loads** ("95/65 lb") keep both values; the `sex` argument picks one (default the first).

### 3.6 Scoring

| Value | From |
|---|---|
| `time` | score `time`, `longestHold`; v1 `forTime` |
| `rounds_reps` | `roundsReps`; v1 `amrap`; death-by (rounds completed) |
| `reps` | `totalReps`, `lowestReps`; a max-rep window |
| `load` | `load` |
| `calories_distance` | `distance`, `calories`, `maxHeight` |
| `pass_fail` | `windowsCompleted` only: a fail-out or "complete every window" |
| `none` | `none`; **an EMOM by default** |
| `per_piece` | a multi-part workout; each piece has its own |

An import label that names two scores ("time or load") is unknown (`score_ambiguous`).

## 4. Edge cases

- **Hyrox:** chipper + `run_interleaved`, `4plus`, GWM (primary M), all 8 station tags, very long,
  time. No special case in the code beyond the modifier and the division loads.
- **21-15-9 couplet:** `rounds` + `reps_descending`, not a ladder.
- **Death-by:** `ladder` (open), scored `rounds_reps`, time domain unknown (ends on failure).
- **A loaded EMOM of 2 cleans:** `strength` + `interval_wrapper`, time `n/a`.
- **Buy-in + AMRAP + cash-out:** structure `amrap` with `buy_in`/`cash_out`; the movement count is
  the AMRAP's.
- **A cap on a for-time workout** never sets the domain when the estimate is shorter.
- **Written-out rows** (today's AMRAPs, Helen-style rounds) are folded by `roundSize` first.
- **Unknown movement names** fall back to keywords, else stay unknown (`unknown_movements:n`).

## 5. Corpus coverage

`tools/taxonomy_corpus.py` reads `workout_drafts`, **read-only**, from a JSON export or with `PGURL`
in a read-only transaction. It prints aggregates only: counts per axis value, the unknown rate per
axis, confidence counts, the top reason codes for unknowns, the lexicon miss rate, the Hyrox
station counts, and checks for likely misclassifications (the import's format against the derived
structure and scoring; a timed format with no clock). The checks list draft ids only.

It never prints workout text, movement names, programs or gyms. Draft ids embed program slugs, so
only a `--ids 0` run may be committed:

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
   beyond, measured on work time. Right?
   - *Coach recommends:* keep 8 / 15 / 30 on work time (done); add a `sprint` bucket (under ~2 min)
     later if history needs it.
2. **Loading without the athlete's max.** Is a standard an acceptable proxy at medium confidence,
   or should loading stay unknown until the app knows the athlete's maxes? Are the cut-offs
   (0.75 / 1.10 and 65 % / 80 %) right?
   - *Coach recommends:* use the standard at medium confidence, labelled "vs standard" (done), on
     the actual scale, sex and implement (done); keep the cut-offs; consider a `max` level at
     ~90 % or for 1–3RM tests.
3. **Structure names.** Is `rounds` / `chipper` / `for_time` / `ladder` (open only) the naming you
   want, and is Hyrox a chipper with a modifier rather than a structure of its own?
   - *Coach recommends:* `rounds` works now that the movement count is its own axis; chipper = one
     pass of 4+ in order; Hyrox = chipper + `run_interleaved` (race simulation) (all done).
4. **Modality of borderline movements.** Double-unders M; wall balls, thrusters, kettlebells,
   carries, sleds and sandbags W; burpee broad jumps and box jumps G; weighted bodyweight G with a
   load flag. Agree?
   - *Coach recommends:* agree with all of these (done).
5. **EMOM scoring.** `none` by default; `pass_fail` only when the workout fails out or says
   "complete every window"; `reps` for max-rep windows; `load` when building to a heavy lift;
   death-by `rounds_reps`. Agree?
   - *Coach recommends:* exactly this (done).
