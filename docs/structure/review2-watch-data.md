# Review 2: watch/HealthKit + data/insights (proposal v2)

## Verdict
**Approve with fixes.** The code confirms C1 (outbox, delete on success, import by UUID), C3 (`finishWorkout` saves to Health), C4 (progress is saved but never read back, and there is no `handleActiveWorkoutRecovery`) and C13 (iOS 17 / watchOS 10). Two lifting claims are wrong: squat sets found by motion, and mirroring with no protocol. The sync table promises states the phone can't know. The Before Anaheim scope is right.

## Required fixes

1. **Motion detection can't find squat sets** (v2 §6, §7, §11 Mayhem walk, §12; decisions 1b).
   - `LiftType` is Olympic lifts plus `other`.
   - `OnlineLiftDetector` needs a hanging forearm and a pull from the floor. Each detection is one rep, and nothing groups reps into sets.
   - `LiftAnalyzer` bar path assumes a pull.

   *Fix:*
   - Sets come from **Set done** on the phone (or Next set on the watch), timestamped by the watch.
   - Motion per set is cut from the Data-mode session CSV, which is on by default.
   - Detected Olympic lifts are grouped under the current set.
   - Add a `movementId` string next to `LiftType`.
   - Squat bar path and rep counting: Later.

2. **The watch has no way to start a phone-controlled block** (C13). `WatchAppDelegate.handle(_:)` deliberately starts nothing, and strength = "open the Lifting page".

   *Fix:*
   - Send a `liftingBlock` payload (block ID, lifts, set plan, units, plate steps) by application context *before* `startWatchApp`.
   - `handle()` then starts `SessionModel`.
   - Block a metcon START while lifting runs: there are two `WorkoutManager`s but only one `HKWorkoutSession` at a time.

3. **Mirroring still needs a protocol and a reconnect** (1b "No home-made message protocol"). `sendToRemoteWorkoutSession` is a raw data pipe that fails while disconnected.

   *Fix:*
   - Define a versioned Codable `LiftControl` (nextLift, setDone, setLoad, snapshot) in BarPathKit, with tests.
   - The watch owns the event log and mints set IDs. The phone sends commands, and the watch sends a snapshot on every (re)connect.
   - Register `workoutSessionMirroringStartHandler` at phone launch. The watch re-calls `startMirroringToCompanionDevice()` after `didDisconnectFromRemoteDeviceWithError` when the phone is reachable.
   - The **first** Before TestFlight build is a spike: start, next, end, kill the phone app, reattach.

4. **Phone-entered loads** (§7). Loads and make/miss go in the Result/edit layer, keyed by the watch's set ID, never in the Recording. A re-sent block file can't erase them.

5. **New file types must be re-sendable.** `PhoneLink.metadata(forFileNamed:)` rebuilds metadata from the file-name prefix, so an unknown name is never re-sent.

   *Fix:*
   - Add a `lifting-<uuid>.json` prefix and import branch on both sides.
   - Add a test that every file the watch writes round-trips through it.

6. **Save at the finish *and* at End** (Before Anaheim). One UUID, two files. Out of order, the finish file overwrites the End file and its recovery tail. A re-send also overwrites a phone edit.

   *Fix:*
   - Add `revision` to `WorkoutResult`; the phone keeps the newest.
   - Cancel the queued finish transfer at End.
   - If `.original.json` exists, store the arrival as the original.

7. **Resume is under-specified** (§11 crash walk). The saved progress lacks `workoutId`, heart rate and pedometer samples, and UserDefaults may not flush before a crash.

   *Fix:*
   - Write progress + `workoutId` atomically to a file at each Crown turn.
   - Use `handleActiveWorkoutRecovery` → `recoverActiveWorkoutSession`, so the same Apple workout continues instead of a second one.
   - Backfill heart rate with a HealthKit query from start to crash.
   - Add a hidden "Simulate crash" button for testing before the freeze.

8. **Sync table** (§6). The phone isn't told about files still on the watch, so it can't show "1 result on watch", "Arriving…" or "Stuck > 24 h". And Health has the workout at End, not at delivery.

   *Fix:*
   - The watch publishes its outbox list (ID, type, created) via `updateApplicationContext`.
   - "Sync now" = a message asking the watch to re-send. When the watch isn't reachable, show "Open Rx Lab on your watch".
   - Move "Health ✓" to the Recording row.

9. **Grouping needs IDs** (§7 Session).
   - Payloads carry `sessionId` and `blockId`, and the watch echoes them back. Group by local date only for unplanned workouts.
   - Migration (S-07): an old lift session becomes a Session with one Lifting block, and an old result becomes one Metcon block. Old-format files must keep importing.

10. **Score definitions** (M-3).
    - Mayhem "3675 lbs" for 5×3 @ 245 is **Σ load×reps**, not a sum of loads. Fix mayhem-day.md too.
    - For a "heaviest weight" scheme, the PR is the best set, which feeds the rep-max store.
    - %1RM needs a base rule: the latest tested 1RM, otherwise the best estimate within 12 months, with the source shown. The 245×3 from 2024 beats the "recent" 3RM of 215.

11. **Roxzone vs target shape** (Q2/Q3). No sim has roxzone segments yet. If roxzone is on, the dress-rehearsal sim records it and becomes the shape.

12. **Privacy: real data is already in the repo.** `BarPathKit/Tests/.../Fixtures/workout-helen-2026-10-29.json` and `workout-amrap-…json` hold real heart rate, and the origin is GitHub.

    *Fix:*
    - Replace them with synthetic fixtures, or confirm the repo is private.
    - Keep Data-mode CSVs and heart rate out of diagnostics by default.
 

13. **Insights gates** (§9). Gate on results per comparability key (3 for a delta, 5 for a trend), not total workouts. Label pedometer pace "estimate" until calibration ships.

## Optional
- Add `heartRate` and `activeEnergyBurned` to the HealthKit share set (today it is `workoutType` only). Check calories on the Fitness card.
- No compiler: put the new logic in BarPathKit (pure Foundation, has tests) and run `swift test` on a Mac or in CI. Keep the app targets thin.
- Before TestFlight is too big for Dec–Jan. Order: mirroring spike → model v2 + migration → Log → lifting UI → import → tabs.
