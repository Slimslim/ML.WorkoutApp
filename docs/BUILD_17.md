# Build 17 brief: design review, tester feedback, add a workout from a photo or text

Draft for the owner's approval (2026-11-11). Nothing here is built. No code starts until build 15
has been tested by the owner and merged, and until the owner has approved this brief and the
mockups it asks for. Story labels (R1, I1...) are provisional; they get W/N numbers in
`docs/USER_STORIES.md` when approved, so they cannot clash with other branches.

## Order of events

1. **Build 15** (frozen, PR 24): owner tests, fixes only, merge, TestFlight.
2. **Build 16**: tester stability (uploads without opening the app, the "heart rate is off"
   banner, Tabata timing, a battery line in every recording). Owner decision of 13 Nov; scope and
   dates are in `docs/RELEASES.md`, not here.
3. **Build 17** (this brief), three parts:
   - A. Design review of the phone screens, plus tester feedback (R1, R2).
   - B. Add a workout from a photo or text (I1-I6). The main piece.
   - C. The movement table that B needs, which also replaces three separate lists (M1).
4. **Not in build 17:** tips before a workout, voice input, payment, a coach view, turnover time
   for Olympic lifts, rest equal to the round, switching recording settings inside a session.

## Why

- Today the owner (through Claude) enters every tester's program by hand from screenshots. That
  cannot follow a second gym.
- A competing app (seen 2026-11-11) lets athletes add a workout by photo, voice or text. That part
  it does well. It does not measure anything; this app does. Import removes our weakest step
  without touching what makes the app different.
- Later this is a paid feature (everything that needs AI is paid; measuring and the basic report
  stay free). During the beta it is free for testers.

## A. Design review and feedback

**R1. A second pair of eyes on the phone screens.** As the owner, I want an independent UI/UX
review of Today, Workouts, Log, Progress, Settings and the workout report against
`docs/DESIGN_GUIDELINES.md`, so build 17 fixes what gets in a tester's way.
*Done when:* a written review exists with findings ranked by how much they block a tester, each
with the screen, what is wrong and a proposed change; the owner has marked each "do", "later" or
"no"; only the "do" items are built. The review uses real screenshots from the owner's phone
(light and dark), not only the code.

**R2. What testers told us.** As the owner, I want tester feedback from builds 15 and 16 collected in one
list, so decisions rest on what people hit.
*Done when:* TestFlight feedback, messages and the owner's notes are in one ranked list (problem,
who, how often, proposed fix), and the top five are either in build 17 or explicitly deferred.

## B. Add a workout from a photo or text

**I1. Add a workout by taking a picture.** As an athlete, I want to photograph the whiteboard or
a screenshot of my program and get it as a workout in the app, so I can track it without typing
it or waiting for someone to enter it.
*Done when:* from the + tab I choose "Add a workout", take or pick a photo, see "Reading your
workout" for at most about a minute, and get the workout as the same card the library shows
(name, format, rounds, movements, reps or distances, weights, time cap).

**I2. Add a workout by pasting or typing text.** Same as I1 from pasted or typed text.

**I3. Check it and fix it before saving.** As an athlete, I want to confirm the workout is right
and change what is not, so what the watch runs is what I am about to do.
*Done when:* on the card I can change a weight (in my unit), a rep count or distance, the time
cap and the name, remove or add a part, and choose the date; nothing is saved until I tap Save;
Cancel leaves nothing behind.

**I4. It shows up like any other workout.** *Done when:* a saved import appears under Workouts on
its date (Today if it is today), only for me, works offline afterwards, and "Send to watch" starts
it on the watch exactly like a library workout, with the right recording settings.

**I5. Tell me plainly when it cannot be set up.** As an athlete, I want a clear message when the
photo is unreadable or the workout is a kind the app cannot run yet, so I am not left guessing.
*Done when:* an unreadable photo says "Could not read this. Try a closer, sharper photo or paste
the text."; a workout that reads fine but uses something unsupported says which part ("This
workout has a rest equal to your round time. The app cannot run that yet.") and offers to save it
as a Free Workout with the text attached; no network says so and keeps the photo to retry;
nothing ever saves a half-understood workout silently.

**I6. We learn from every attempt.** As the owner, I want each import logged (what was sent, what
came back, what the athlete changed, whether it was saved, and why it failed), so I know which
workouts people bring and which ones the app gets wrong.
*Done when:* every attempt has one row I can query; a weekly look shows counts by outcome, the
unsupported features asked for most, and the movements that were not recognised.

### The flow

1. Phone: + tab, "Add a workout", then Photo or Text.
2. The phone sends the image (downscaled) or the text to a server function with the athlete's
   sign-in. "Reading your workout."
3. The server function asks the AI to read it into the app's workout structure, using the
   movement table for names. It checks the result and answers with the workout, a list of things
   it was unsure about, or a reason it could not be set up.
4. The phone shows the card. Uncertain items are marked ("Weight not found: add it?").
5. The athlete edits, then Save. The workout is stored as a personal library row (visible only to
   them) and cached on the phone.
6. Send to watch as today.

### What the app can run today, and what it cannot

The AI must produce only what `WorkoutDefinition` can express
(`BarPath/BarPathKit/Sources/BarPathKit/WorkoutDefinition.swift`).

| Can be set up | Cannot yet (say so, log it) |
|---|---|
| For time, with or without a time cap | Rest equal to the round just done (or any work-to-rest ratio) |
| AMRAP | Lifting pieces as sets x reps x weight inside a program |
| EMOM and "every N:00" intervals | Lifting complexes as one set |
| Rounds of the same parts; rep schemes like 21-15-9 written out as parts | Ladders that grow until failure |
| Timed rests | Choose-your-own or "pick 3 of 5" workouts |
| Runs, machines, stations with reps, meters, calories or seconds | Several separate pieces in one photo (offer to save each) |
| A weight per part, in lb or kg, single or a pair | Percentages of a max ("5 x 3 at 80%") without the athlete's number |
| Solo, doubles, team label | Who does what in a partner workout |

The right-hand column is expected to be common. The log (I6) decides which of them come next.

### How it is built

**Server function** (Supabase edge function, e.g. `import-workout`):
- Called only by a signed-in user; the user is taken from the sign-in token, never from the body.
- Input: text, or one image (JPEG, long side at most about 1,600 px, at most about 1.5 MB), plus
  the athlete's weight unit and today's date.
- Calls the Claude API. The API key and the model name are function secrets set in the Supabase
  dashboard: never in the app, never in the repository (CLAUDE.md: no model names in code).
- The AI is given the workout structure as a strict schema and the movement table (ids, names,
  aliases), and must answer with a workout, a list of uncertain fields, or a refusal with a reason
  from a fixed list (`unreadable`, `not_a_workout`, `unsupported:<feature>`, `several_workouts`).
- The function validates the answer before returning it: known format, at least one part, every
  movement id either in the table or flagged as new, sane numbers (reps 1-1000, weights
  1-500 kg, distances up to 50 km, cap up to 6 h), ids in the personal form
  `lib.<source>.<yyyymmdd>.<slug>.u<8 hex>` already used by `tools/library/make_row.py`.
- Limits: a few imports per athlete per day and per minute; a hard monthly spending cap on the API
  key; a timeout of about 45 s with one retry.
- The phone still does the final check: it decodes the workout with BarPathKit, the same code the
  watch uses. If that fails, the athlete sees I5's message and the failure is logged.

**Tables** (one migration, written but run only with the owner's go-ahead):
- `movements`: see part C.
- `workout_imports`: id, user, created at, source (`photo` / `text`), the text sent or the text
  the AI read from the photo, the AI's answer, outcome (`saved`, `edited_then_saved`, `cancelled`,
  `unreadable`, `unsupported`, `error`), unsupported features, unknown movement names, what the
  athlete changed, time taken, cost in tokens. Row-level security: an athlete can insert and read
  their own rows; the owner reads all with the service role.
- Saved workouts go into the existing `workout_library` as personal rows (`owner` = the athlete).
  The policies for that already exist (`20261110000000_gyms.sql`).

**Phone:** a new "Add a workout" flow under the + tab, an editable version of the existing
workout card, and the personal rows merged into Workouts (the library store already fetches them).
The library cache must be cleared when the signed-in user changes (known gap, now required).

**Watch:** no change. It receives a `WorkoutDefinition` as today.

### Mockups needed before code (owner approves)

1. + tab: "Add a workout" with Photo and Text.
2. "Reading your workout" (and what it looks like after 20 s).
3. The editable card, with an uncertain item marked.
4. The three failure messages of I5.
5. Where an imported workout sits in Workouts and how it is told apart from the gym's.

### Cost, abuse and privacy

- **Sign-up must be limited before this ships.** Today anyone can create an account with the
  public key. Once an account can trigger a paid AI call, that is a way to spend the owner's
  money. Turn off email sign-up (testers use Sign in with Apple) and keep the per-athlete limits.
- **Cost:** one image and a short answer per import; a small amount per workout. The monthly cap
  on the key is the safety net.
- **The photo is not kept.** It is sent to be read and then discarded; only the extracted text is
  stored in the log. A whiteboard photo can show faces and names.
- **Imports are private to the athlete.** A photographed program may be someone's paid
  programming, so an import never goes into a gym's or the public library.
- **`PRIVACY.md`** gains a line: photos and text of workouts you add are sent to an AI service
  (Anthropic) to be read, are not used to identify you, and the photo is not stored.
- **Text in a photo is data, not instructions.** The function tells the AI to read a workout and
  nothing else, and the validation step rejects anything that is not a workout.

## C. One movement table

**M1. One name for each movement.** As the owner, I want every movement to have one id however
it is written, so an athlete's history of a movement connects across workouts, imports and
recordings.
*Done when:* a `movements` table holds, for each movement: id, display name, aliases
("T2B", "TTB", "toes to bar", "toes-to-bar"; German and French names for the Swiss testers),
family (barbell, dumbbell, kettlebell, gymnastics, bodyweight, machine, run, carry, other),
pattern (push, pull, squat, hinge, overhead, run, jump, core), whether it is counted in reps or
measured in distance, calories or time, whether reps are countable from the wrist, and the
recording rate it needs. The import maps names through it; the recording-rate rule reads it in
place of its keyword list; display names come from it; label files use its ids.

- It ships inside the app as a bundled file (so the watch and an offline phone have it) and is
  refreshed from the database, like the workout library.
- Seeded from the movements already in `WorkoutDefinition.swift`, the library rows, the label
  files and the list agreed on 2026-11-11 (barbell, dumbbell and kettlebell, gymnastics, other).
- An import that meets an unknown movement keeps the athlete's wording, flags it, and logs it, so
  the table grows from what people really bring.
- The Python tools get the same table (one JSON file both sides read), with a parity test.

## Tests

- The server function's validation, on a fixed set of real whiteboard texts and photos collected
  during the beta (kept out of the repository if they show people or paid programming), each with
  the expected workout or the expected refusal. This set is also how a new AI model is checked
  before switching to it.
- Phone: decoding of every example answer with BarPathKit; the edit card's changes round-trip.
- Movement table: every alias maps to exactly one id; the recording-rate verdict of every current
  library workout is unchanged after the switch from keywords to the table.

## What "done" means for build 17

- A tester at a gym the owner has never seen adds their own workout from a photo, corrects one
  weight, sends it to the watch and tracks it, without help.
- At least 8 of 10 real workouts brought by testers are either set up correctly or refused with a
  reason the tester understands. No wrong workout is saved silently.
- The owner can list, for the week, what was imported, what failed and why.
- The design review's "do" items are in, and the top five tester problems are answered.

## Decisions the owner still has to make

1. Approve this brief, or change it.
2. Turn off email sign-up before import ships (recommended).
3. Photo not kept, only the text (recommended), or keep photos for a time to improve the reading.
4. The daily import limit per athlete during the beta (suggested: 10).
5. Whether "save as a Free Workout with the text attached" is the right fallback for unsupported
   workouts.
6. Which unsupported kinds, if any, must be supported in build 17 itself. Rest equal to the round
   is the owner's own example and is small.

## Areas and shared files

- Workouts area: the import flow, the editable card, the library store. Navigation area: the +
  tab entry and the design review's changes. Lifting area: untouched.
- Shared files touched: `iOS/BarPathApp.swift` (none expected), `project.yml` (build number only),
  `supabase/` (one migration and the function), `PRIVACY.md`. `Models.swift` is not touched; the
  movement table is its own file.
