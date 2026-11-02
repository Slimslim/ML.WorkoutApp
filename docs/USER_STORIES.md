# User stories

One list for the whole app, so every chat works from the same picture of what the athlete
needs. Each area keeps its own section; add stories to your area, don't edit another
area's stories (propose changes in your PR instead).

## How to write one

```
**<ID>. <Short title> (<Now | Later>)**
As a <who>, I want <what>, so that <why>.
*Done when:* <one or two checks we can actually test, in the gym or against video>.
```

- **IDs** are a prefix plus a number and never change or get reused. Lifting uses `S`
  (setup), `T` (technique), `L` (sets/logging) and `P` (progress). Workouts use `W`,
  navigation uses `N`. Pick the next free number in your prefix.
- **Now** = in the first version of that feature; **Later** = after that.
- Write from the athlete's side ("see how fast I get under the bar"), not the code's
  ("add turnover metric to LiftMetrics").
- "Done when" must be checkable: a number against video, a tap count, a time limit.
- When a story ships, add `— shipped in #<PR>` to its title line. Don't delete it.

## Lifting

Olympic lifting has two modes, and they answer different questions:

- **Technique** (singles, live): *how am I moving?* Bar path, pull speed and height, and how
  fast I get under the bar, shown rep by rep on the phone while I walk back to the bar.
- **Sets** (logging): *did I do the work?* Sets × reps × weight, rest timer, and one chart
  per set showing the bar going up and down over time. Includes touch-and-go sets and
  strength lifts like the deadlift.

Both feed **progress**: same lift, same weight, is the bar moving faster than before?

### Setup (both modes)

**S1. Pick my mode (Now)**
As a lifter, I want to choose Technique or Sets when I pick my lift, so the watch knows
whether I'm working on technique or logging work.
*Done when:* the watch setup shows Lift, Weight and Mode and starts with one tap; the last
mode used for each lift is remembered.

**S2. Change between blocks without ending my workout (Now)**
As a lifter, I want to switch from snatch technique to deadlift sets mid-session, so the
whole gym session stays one workout.
*Done when:* Change → pick → Continue takes 3 taps or fewer, and Apple Fitness shows one
workout.

### Technique mode (singles, live)

**T1. See each rep while I walk back (Now)**
As a lifter doing singles, I want the phone to show the rep I just did by the time I'm
back at the bar, so I can adjust the next one.
*Done when:* the rep appears on the phone within 5 s of dropping the bar, readable from
3 m.

**T2. Know how hard I pulled and how high (Now)**
As a lifter, I want peak bar speed and pull height for each rep, so I can tell a strong
pull from a weak one.
*Done when:* both numbers show in large type and match video within about 0.1 m/s and
5 cm.

**T3. See how fast I get under the bar (Now)**
As a lifter, I want a turnover time (top of the pull to the catch) and how far I dropped,
so "snap under the bar" becomes a number I can improve.
*Done when:* turnover shows in seconds and stays within about 0.08 s of video; if the catch
isn't found, it shows "—" rather than a wrong number.

**T4. Compare with my previous rep (Now)**
As a lifter, I want this rep next to the previous one, so I can see whether my change
worked.
*Done when:* the previous path shows as a faint ghost, with the difference for each number
(e.g. "▲ 0.08 m/s").

**T5. Show someone what "slow under the bar" means (Later)**
As a coach or training partner, I want to show a slow and a snappy rep side by side, so
the difference is obvious.
*Done when:* I can pick any 2 reps from the session and compare them.

### Sets mode (logging)

**L1. Count my touch-and-go reps (Now)**
As a lifter doing 5 × 3 touch-and-go, I want the watch to count the reps, so I don't have
to.
*Done when:* the count is right on filmed test sets, and the set saves itself a few seconds
after the bar goes down.

**L2. Time my rest (Now)**
As a lifter, I want a rest timer to start when the set ends, so I know when to go again.
*Done when:* the timer counts up by default; with a rest time set (e.g. 3:00) it counts
down and buzzes at zero.

**L3. Change the weight between sets in one move (Now)**
As a lifter, I want to adjust the weight during the rest, so each set is logged at the
right weight.
*Done when:* turning the Crown on the rest screen changes the weight for the next set, with
no menus.

**L4. Log my session (Now)**
As a lifter, I want the phone to keep my sets, reps and weights, so I have a training log
without writing anything.
*Done when:* the session shows rows like "Snatch · 5 × 3 · 135 lb · rest 2:40 avg".

**L5. See how a set went (Now)**
As a lifter, I want one chart per set showing the bar going up and down over time, with
the speed of each pull, so I can see whether I slowed down.
*Done when:* each rep's pull speed is labelled and coloured, and tapping a rep opens its
detail.

**L6. Follow a plan (Later)**
As a lifter, I want to send "5 × 3 @ 135 lb, rest 3:00" from the phone, so the watch guides
me: "Set 2 of 5", the rest countdown, then the next set.
*Done when:* the plan arrives on the watch and the set number moves on automatically.

### Progress (both modes)

**P1. See that I'm getting faster (Now, simple version)**
As a lifter, I want to compare today with the same lift and weight from weeks ago, so I
can see that "it feels lighter" in the data.
*Done when:* each lift and weight shows its average and best pull speed per session over
time.

### Decisions so far (lifting)

- The live view compares with the **previous rep** (a "best rep" option may come later as
  a setting).
- Speed colours are **absolute** (the same speed is always the same colour).
- First build: S1, T1–T4, L1–L5, P1. L1 needs a filmed touch-and-go recording session
  first; there is no touch-and-go data yet.

### What the data says (checked against video, 29 Oct 2026 recordings)

- Turnover time (top of pull → catch): within 0.08 s of video on 8 of 9 checkable lifts;
  drop under the bar within 1–8 cm. The catch wasn't found on 2 of 18 lifts.
- Set timeline: bar height drifts up to 65 cm over a set unless it's reset at the top of
  each rep; with the reset, rep depth matches video within about 0.3–6 cm and pull speed
  within ±0.05 m/s on 10 of 12 deadlift reps.
- Not checked yet: squats, touch-and-go Olympic sets, sticking points.

## Workouts (Hyrox / CrossFit)

*Owned by the Workouts chat. Add stories here with the `W` prefix.*

## Navigation and layout

*Owned by the Navigation UI/UX chat. Add stories here with the `N` prefix.*
