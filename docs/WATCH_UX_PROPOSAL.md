# BarPath watch UX redesign: proposal

> **Status: proposal for discussion, not implemented.** Only the "phone opens the watch app" part (startWatchApp + tappable chip, without `prepare()`) is in the app as of 2026-10-27.

Scope: `BarPath/Watch/*`, the phone↔watch launch flow, and the parts of `BarPath/iOS` that touch it. Based on the current code: a scrolling `List` in StartView, a `ScrollView` in SessionView with Lift/Mark/End buttons, `.start`/`.success` haptics, and a WC status message. Status text is only coloured, never a filled screen.

## 1. Principles

- **The watch owns the session.** It holds the `HKWorkoutSession`, the sensors and the detector. The phone wakes it, mirrors it and displays results.
- **One signal per state, readable from 2 m away out of the corner of your eye.** Only READY fills the screen. Every other state is a black screen with text. "Bright vs dark" works for every type of colour vision.
- **No scrolling and no in-session navigation.** The Digital Crown adjusts load. Taps are only for Start and End.

## 2. End-to-end flows

**First launch / permissions (phone first).**
1. The phone shows a one-time card, "Set up Apple Watch". It asks for HealthKit on the phone (share workouts, read HR) and then calls `startWatchApp`.
2. On first appear, the watch asks for Motion & Fitness permission while the athlete is still at the bench, not at the bar. The watch's HealthKit request is approved on the phone through the existing `handleAuthorizationForExtension`.
3. Tell the athlete once: turn on *Settings › Haptics › Prominent*.

**Normal session.**
1. Open the phone app. If the phone has no mirrored session and the watch is paired and the app installed, it calls `HKHealthStore.startWatchApp(with:)` with a `.traditionalStrengthTraining` config.
2. The watch app launches into `handle(_ workoutConfiguration:)`, creates the session and calls `prepare()`. This keeps the app alive and frontmost and warms up the sensors. It shows **Setup**.
3. The phone chip reads "Watch ready".
4. The athlete taps **Start** on the watch, or uses Double Tap, or taps "Start" on the phone (a WC `sendMessage`; the watch is reachable while its app runs). Then `startActivity`, followed by `startMirroringToCompanionDevice()`.
5. Walk to bar → set up → READY (green + haptic) → lift → "✓ 3" → the lift appears on the phone. Repeat.
6. The phone's mirrored session gets live state over `sendToRemoteWorkoutSession(data:)`. Lift files stay on `transferFile`, which already works and is robust to queueing.

**Changing lift mid-session.**
- **Lift type means End** (as asked): End → Setup → Start takes about 4 s.
- **Load can change mid-session** with the Digital Crown on the session screen. It applies to the next lift.
- This is the one deliberate exception to "display only". Lifters change load every set, and ending a session per set would split the HealthKit workouts and the phone's session groups into dozens.
- *Later:* the phone can change the lift type mid-session over the mirroring channel. It applies to the next lift. A snatch → C&J day then stays one workout.

**Ending.**
1. End on the watch (tap End, then confirm), or End on the phone (mirrored session `end()`; verify, see §7).
2. Watch: `stopRecording` → `end` → `finishWorkout` → back to Setup with "Last: 7 lifts sent".
3. Phone: the session card shows "Session ended".

**Data-collection session.** Data mode is switched on from the phone's Debug tab and synced through `updateApplicationContext`. The watch Setup then shows a yellow **DATA** badge, and the session screen gets a debug strip and Mark (§5). The athlete flow is otherwise identical.

**Phone not reachable.**
- `startWatchApp` fails: the phone chip turns amber with "Can't reach watch". Tapping it retries and shows fix-it hints (§6).
- The watch works on its own. Setup shows a grey "Phone offline – lifts sync later" line. The saved state shows "Queued ↑N" instead of "Sent". `transferFile` already queues files and re-sends orphans.
- Mirroring dropping out is never fatal to recording.

## 3. Watch screens (46 mm ≈ 208×248 pt usable; also check 42 mm)

All text uses SF Rounded. Sizes below are in pt.

```
 SETUP                         LIFT PICKER (tap Lift tile; 3×3, no scroll)
┌──────────────────────┐      ┌──────────────────────┐
│ ● phone      DATA    │ 12   │ Snatch  Clean  Clean │
│┌────────────────────┐│      │         &Jerk        │
││ LIFT               ││ 12   │ Power   Hang   Power │ 15 semibold,
││ Snatch             ││ 24 b │ Snatch  Snatch Clean │ 2 lines, tiles
│└────────────────────┘│      │ Hang    Jerk   Other │ ≈62×64, selected
│┌────────────────────┐│      │ Clean                │ = filled + ✓
││ LOAD   ◉ crown     ││ 12   └──────────────────────┘
││ 135 lb             ││ 24 b  tap = select & return
│└────────────────────┘│
│ ┌──────────────────┐ │
│ │      START       │ │ 22 heavy, green, ≥60 pt tall; Double Tap = Start
│ └──────────────────┘ │
└──────────────────────┘
```

- On Setup, the Crown always drives load: 5 lb steps, with detents and haptics. A long-press on the Load tile switches load off or on, which shows "No load". There are no other screens.

```
 WALK TO BAR (black)    READY (full green)     LIFTING (black)     SAVED 3 s (black)
┌────────────────┐     ┌────────────────┐    ┌────────────────┐   ┌────────────────┐
│ Snatch · 135lb │17   │████████████████│    │                │   │       ✓        │
│                │     │██   ▬▬▬▬▬▬   ██│    │   ● LIFTING    │   │       3        │ 64 heavy
│  Walk to       │30b  │██   READY    ██│44  │                │28 │   lift saved   │ 17
│  the bar       │     │██            ██│hvy │                │   │  Sent ✓ / ↑2   │ 15
│ 3 lifts 12:40 ♥│15   │██ Snatch 135 ██│17  │ 3 lifts  12:41 │   │                │
│ [    End     ] │     │████████████████│    │                │   │                │
└────────────────┘     └────────────────┘    └────────────────┘   └────────────────┘
```

- **READY** fills the whole screen with `Color.green` (#30D158). Text is black, about 10:1 contrast, with a solid barbell glyph above "READY". Nothing on it is tappable. Turning the Crown changes load on any session screen and shows the value as a 1 s overlay.
- **Lifting** is shown in orange text only. The screen stays dark so the green → dark change reads as "it saw you move".
- **End** is a 44 pt full-width capsule in dark grey with red text, shown only in the Walk state. It opens a full-screen confirmation: "End session? 7 lifts" with [End] in red and [Keep going] in grey, and **Keep going is the default**. Double Tap does nothing in a session, because gripping the bar could trigger it.
- **Errors** use an amber full-width banner with a ⚠ icon and text, for example "Sensors stopped – tap to restart". Never red alone.
- **Always-on / wrist-down.** While a workout runs the app stays frontmost. Use `isLuminanceReduced`: READY stays a full fill but in a darker green (#1E7F3A) with white text, so it is still the only bright screen. Other states drop to white text, and the timer shows minutes only. HR and seconds are hidden.
- **Arming gets no screen wake.** There is no public API to wake the display, so the haptic is the primary signal. The green screen confirms it at a glance.

## 4. Haptic and colour language

| Event | Haptic | Colour | Shape / text |
|---|---|---|---|
| Ready (armed) | `.start`, keep the 2.5 s gap | full green fill | barbell glyph + READY |
| Lift started | none (don't distract mid-pull) | orange text | ● LIFTING |
| Lift ended / saved | `.success` (once, at end) | white on black | ✓ + number |
| Disarmed (moved) | none | back to black | Walk to the bar |
| Error | `.failure` | amber banner | ⚠ + words |
| Phone offline | none | grey | "↑N queued" |

- **Colour-blind safety.** No state relies on red vs green. Ready is identified by luminance (a full fill) plus a word and a glyph. The phone uses the same vocabulary: green "READY" pill, ✓ count.

## 5. Debug features (data mode only)

- **Full-session CSV toggle.** This moves to the phone's Debug tab and syncs through `updateApplicationContext`. Change the default to **off** once data collection ends; today `debugRecording.v1` defaults to on.
- **Debug strip.** In data mode the session screen gets a 12 pt monospaced strip at the bottom: `48.2k smp · CSV 3.1 MB · 2 mk · ↑1 · 100 Hz`. It replaces the End row until End is needed. A long-press on the strip shows End.
- **Mark.** In data mode, Double Tap (`.handGestureShortcut(.primaryAction)`, watchOS 11+) triggers Mark, with a click haptic and an "MK 3" flash. The bottom half of the screen also becomes a Mark tap target. Outside data mode, Mark doesn't exist.
- **Detector internals on the phone.** The detector state and HR text that the phone's status chip shows today move to the Debug tab only.

## 6. Phone-side changes

1. **`AppDelegate`.** Register `healthStore.workoutSessionMirroringStartHandler` in `didFinishLaunching`. It must be set before activation so a background relaunch catches it.
2. **Launch the watch.** On `scenePhase == .active`, call `startWatchApp` at most once per foreground, and skip it if a mirrored session exists.
3. **New `WatchSessionController` (phone side).** It holds the mirrored `HKWorkoutSession` and decodes the state messages. It exposes `.notRunning / .opening / .setup / .running(state, liftCount) / .ended / .failed(reason)`.
4. **Status chip.** The current "Watch idle / connected" chip gets these states: Opening on watch… / Watch ready / ● Recording / READY (green) / Not reachable (amber + retry).
   - **The chip is tappable.** It is a `Button`, ≥44 pt hit area. Tapping it runs the next sensible connect step for the current state, with inline feedback in the chip and a short popover under it:

```
 tap chip (top-right, Live tab)
 ┌───────────────────────────────┐
 │ ⌚ ◌ Connecting…               │  spinner; startWatchApp in flight (timeout 10 s)
 └───────────────────────────────┘
   ok  → ⌚ ● Watch ready            (green dot, becomes Start target)
   ok, session running → ⌚ ● Recording · 3 lifts
   fail → ⌚ ▲ Can't reach watch     (amber) + popover:
 ┌───────────────────────────────┐
 │ Can't open BarPath on watch   │
 │ • Put the watch on & unlock it│
 │ • Bluetooth on, watch nearby  │
 │ • Or open BarPath on watch    │
 │ [Try again]                   │
 └───────────────────────────────┘
```

   - **What a tap does in each state.**
     - Not reachable and no session: call `startWatchApp`.
     - A session is running on the watch but the mirror was lost: send a WC `sendMessage(["type":"remirror"])`. The watch calls `startMirroringToCompanionDevice()` again.
     - "Watch app missing": the popover says "Install BarPath from the Watch app › Available Apps". There is no public API to install it or deep-link to it, so this is text only.
     - "No watch paired": text only.
     - "Watch ready" or "Recording": the popover shows details (lift, load, lifts sent, queued transfers) and an End button.
   - **Mapping errors to hints.** Map the `startWatchApp` error (`HKError` code) to these hints where possible. Otherwise show the generic list. Use the same hints for the automatic attempt on launch, so tapping the chip is simply the manual retry.
5. **Live tab.** Add a session bar with Start (when in Setup), End, and later a lift-type menu.
6. **Message protocol.** Replace the WC `sendStatus` plain-text dump with a typed `Codable` message sent over the mirroring channel, with WC as the fallback.

## 7. Feasibility, uncertainties and effort

| Item | APIs / constraints | Effort |
|---|---|---|
| Full-screen READY + new states, no scroll | SwiftUI, `isLuminanceReduced`, existing `Status` enum | S (0.5–1 d) |
| Setup screen + 3×3 picker + Crown load | `digitalCrownRotation`, `handGestureShortcut` | S–M (1 d) |
| Debug strip, Double Tap Mark, phone-side debug toggle | `updateApplicationContext` | S (0.5 d) |
| Phone wakes watch | `startWatchApp(with:)` (iOS 10+) + `WKApplicationDelegateAdaptor` → `handle(_:HKWorkoutConfiguration)` → `prepare()` | M (1–2 d incl. device tests) |
| Mirroring + phone Start/End | `startMirroringToCompanionDevice` (watchOS 10) / `workoutSessionMirroringStartHandler`, `sendToRemoteWorkoutSession` (iOS 17) | M–L (3–4 d) |
| Phone lift-type change mid-session | over the mirroring channel; the recorder already takes `liftType` per lift | S after mirroring |

**Flags (verify on device, don't assume).**
- **startWatchApp.** The watch must be on the wrist, unlocked and nearby. The launched app must start or prepare a workout quickly or it gets suspended. How long `prepare()` keeps the app frontmost without `startActivity` is undocumented. Fallback: start the workout immediately on launch and keep the detector idle until Start.
- **Mirrored session on the phone.** It is unconfirmed whether the phone's mirrored session can call `end()` and whether ending it propagates to the watch. Check the iOS 27 headers.
- **Phone background mode.** It is unconfirmed whether the iOS app needs a workout-processing background mode for mirroring. It is also unconfirmed whether mirroring's background runtime makes `transferFile` arrive with the phone locked. If it does, the `isIdleTimerDisabled` requirement can be relaxed.
- **Payload size.** The size limit for `sendToRemoteWorkoutSession` is not documented to my knowledge, so keep files on WC.
- **AOD refresh.** How fast an always-on, state-driven green fill appears (expected ≤ 1 s for workout apps) needs measuring. The athlete has already held still for 1 s, so ~1 s extra is acceptable.
- **watchOS 27 / iOS 27.** I know of no changes to these APIs, and I haven't checked the watchOS 27 SDK diffs. Also check whether iOS 26+ iPhone-side workout sessions change the recommended pattern.
- **Hardware.** As far as I know, Series 12 has **no Action button** (Ultra only). If it is supported later, use a `StartWorkoutIntent`. Double Tap needs Series 9 or later and may misfire while gripping, which is why it is disabled during lifts except in data mode.

## 8. Priorities

**Do now**
1. Full-screen green READY plus the dark state screens, and removing the ScrollView from the session screen.
2. The no-scroll Setup screen with the 3×3 picker and Crown load.
3. Moving the debug controls into data mode and the phone, with Double Tap for Mark.
4. Phone-wakes-watch through `startWatchApp`, plus `prepare()` and the **tappable** chip (connect/retry with hints).

**Later**
5. Mirroring for live state and phone Start/End.
6. Changing lift type from the phone mid-session.
7. Typed status protocol.
8. Relaxing the phone keep-awake requirement if background delivery is confirmed.

**Skip**
- Water Lock: it conflicts with using the Crown for load.
- Haptic on lift start.
- HR on the main screens: a weightlifter's HR between attempts adds nothing.
- Complications and widgets: not needed while the phone launches the app.
