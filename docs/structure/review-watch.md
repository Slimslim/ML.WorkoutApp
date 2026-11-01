# Review: watch side and phone↔watch sync (proposal v1)

Proposal v1 structures the iPhone. For the watch it has one wireframe and no sync model, yet most P1 risk before Anaheim sits on the watch.

## 1. Scenario walk (P1, watch or sync)

| ID | Verdict | Why |
|---|---|---|
| S-03 | Partial | Settings › Watch exists. No Today banner and no "watch app missing" state |
| S-04/S-92 | Fails | No units on the watch. The phone must push units, with a locale default before first sync |
| S-06/S-42 | Fails | Free workout exists only in phone + Add. Not on the watch home, and no "name it later" flow |
| S-09/S-10 | Partial | Send to watch has no delivery confirmation or retry |
| S-24 | Partial | Unclear whether the watch shows free-text segments |
| S-26/S-33 | Partial | The chosen Rx/scaled load and the %1RM load are not shown on the watch |
| S-28/S-29 | Fails | No partner or doubles model |
| S-30/S-31/S-32/S-38 | Works | The existing D+ screen. Keep it |
| S-35 | Fails | Lift session and WOD are separate starts. No chained blocks |
| S-39/S-78/S-82 | Partial | Calibration lives only in Insights. No indoor race path |
| S-40/S-52 | Works | Crown = next, back = undo. Needs a haptic on each advance |
| S-41 | Works | Needs a rule for what "today's" is (Q3) |
| S-43 | Partial | No way to choose the metric |
| S-46/S-77/S-79 | Fails | Targets live only in Insights. No ahead/behind on the wrist |
| S-47 | Works | Must save at End, before recovery starts |
| S-49/S-51 | Partial | No units or plate increments in the load stepper |
| S-54 | Fails | No auto-stop prompt and no trim-end tool |
| S-55 | Fails | No checkpoints and no "incomplete" result |
| S-56/S-57 | Fails | Results arrive only while the phone app is open. No status, pending count or Sync now |
| S-80 | Partial | No roxzone segment |
| S-86 | Fails | No HKWorkout writer and no activity-type mapping |
| S-97 | Partial | No one-tap diagnostics that include the watch log |
| S-07 | Partial | Results still queued on the watch during migration are ignored |

## 2. Top 10 findings

1. **Sync depends on the phone app being open** (S-55/56/57). *Rec:* the watch is the source of truth. Keep a local outbox with one file per result (UUID + device ID). Send with `transferFile` and keep each file until the phone acknowledges it. The phone imports in the background without opening the UI. Imports are idempotent, so retries never create duplicates (S-59/S-94).
2. **Sync state is invisible.** *Rec:* use the state model in §3. Show a pending count on the watch home, the done screen and a complication. Add a sync row and "Sync now" in Settings › Watch, and a placeholder Log row reading "Arriving from watch".
3. **No crash or battery resilience.** *Rec:* checkpoint to disk every 10 s and at each Crown advance. Use `HKWorkoutSession` recovery. On relaunch, offer Resume or Save as incomplete. The phone shows an "Incomplete" flag and "Complete manually".
4. **Free workout and Lift session are missing from the watch home.** *Rec:* see the fixed home list in §3. A free workout is timer + HR + Crown laps, saved as "Untitled · 32:10". On the phone, "Name it / apply definition" reuses the existing apply-definition fix.
5. **No ahead/behind.** This is P1 for the race. *Rec:* the workout payload carries `targets[]`, from target splits or the last attempt. D+ adds a green or red ± per segment and a cumulative delta under the total clock. Define the payload now; the editor can follow.
6. **Race day in a hall is unplanned.** *Rec:* add a HYROX race mode: indoor run (no GPS), calibrated pedometer pace, and Crown segments for run, roxzone, station and roxzone. On Always-On, show only segment + clock + delta at 1 Hz. Add "Race lock" so End needs a Crown confirm. Add Calibrate run to the watch home.
7. **Forgot to stop.** *Rec:* after 3 min with no motion and falling HR, show a haptic "Still going?" prompt on the last segment or in a free workout. Add "Trim end" to Fix splits.
8. **No Health or Apple Workout story.** *Rec:* only the watch's `HKWorkoutBuilder` writes, so there are no duplicates. Activity types: functionalStrengthTraining for WODs, traditionalStrengthTraining for lifts, running for runs, HIIT for EMOM/Tabata. A gym day is one HKWorkout with activity segments. Skip WorkoutKit scheduling, because it would bypass the Crown model. Use a Smart Stack card ("Today's WOD · Start") instead.
9. **A gym day doesn't exist on the watch** (S-35). *Rec:* a session holds blocks (lift block, metcon block), with [Next block] after each done screen. Run it as one workout session, send one result with several reports, and show one Log row.
10. **Wrist ergonomics and units.** *Rec:* the phone pushes settings (units, max HR, plate steps) via `updateApplicationContext`. The load stepper moves in 5 lb / 2.5 kg steps. Use distinct haptics for next, undo and done. Add double-tap and screen-tap as Crown alternatives for gloves or chalk. Add two complications: Today (tap to start) and Pending sync.

Also, decide on partner mode before the Saturday WODs. My suggestion is a per-segment "partner working" toggle that counts that time as rest and keeps the team score.

## 3. Watch page tree and sync model

```
Watch home (labelled vertical list)
├─ TODAY: name · format · [START]   ("Sent 7:42"; empty: "Nothing sent")
├─ Free workout [START]
├─ Lift session → lift → load (plate steps) → START
├─ Workouts → Recent sent · Favourites · Built-ins · HYROX race → preview → START
├─ Calibrate run
├─ Sync: "2 waiting · phone last seen 3h" → Retry
└─ Settings: metric, haptics, double-tap, race lock, Data mode, Screen demo

In session (D+): segment · timer · metric+HR · ±delta · progress border
├─ swipe: Pause · End · Switch workout (≤60 s, keeps clock) · Partner
├─ Always-On: segment, clock, ±delta
└─ Done: score · PR haptic · recovery [Skip] · "Saved ✓ · syncing" · [Next block]
```

| State | Watch | Phone |
|---|---|---|
| Recording | session UI | Today: "In progress on watch" |
| Queued | "1 waiting" + complication dot | Settings › Watch: "1 result on watch" |
| Transferring | "Sending…" | Log row "Arriving from watch" |
| Delivered (acked) | count clears | Report available; Health ✓ |
| Stale >24h | "Not synced · Retry" | Today banner: Sync now · Send diagnostics |
| Incomplete | Resume / Save | Report flagged "Incomplete" |

Phone → watch works the same way: "Send to watch" → "Sending…" → "On watch ✓", or "Will arrive when the watch connects" (`transferUserInfo`).

**Build order:** move findings 1, 2, 3, 5 and 6 and the watch home into "Before Anaheim". They matter more on race day than Library or Insights.
