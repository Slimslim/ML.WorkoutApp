# UX / IA review: proposal v1

Taps from app open. "Deferred" = build order puts it after Anaheim, so the P1 fails on timing.

## 1. Scenario walk

**P1 (all 56)**

| ID | Result | Why |
|---|---|---|
| S-01 | Fails | No onboarding page in the tree |
| S-02 | Fails | No just-in-time asks; Settings doesn't show what's missing |
| S-03 | Partial | Settings › Watch shows status (3 taps); no banner on Today |
| S-04 | Partial | Units only in Settings › Profile; no locale default |
| S-05 | Fails | No empty states anywhere |
| S-06 | Partial | Watch home has no Free workout; offline queue not shown |
| S-07 | Partial | "Merge histories" in build order; no migration notice |
| S-09 | Partial | + › Paste › Save › Schedule (4 taps); Schedule deferred |
| S-10 | Fails | Photo deferred; flow fine (3 taps) |
| S-11 | Partial | Paste ok; Share Sheet entry missing |
| S-12 | Works | Library › search › preview (3 taps) |
| S-13 | Partial | HYROX filed under "Benchmarks"; no division selector |
| S-19 | Partial | Flags exist; no track (Rx/Scaled/Foundations) picker |
| S-20 | Fails | Confirm screen has no blocks/parts |
| S-21 | Fails | Builder deferred |
| S-24 | Partial | Flagged; free-text fallback unspecified |
| S-26 | Partial | Only on confirm screen, not preview/report |
| S-28 | Fails | No partner mode anywhere |
| S-29 | Fails | Same |
| S-30 | Works | Watch existing; report shows score |
| S-31 | Works | Watch existing |
| S-32 | Works | Watch existing |
| S-33 | Partial | No place to store a 1RM; preview doesn't resolve % |
| S-35 | Partial | Log mock shows it; open question 5 unresolved |
| S-38 | Works | Watch existing |
| S-39 | Partial | Run segment/pace planned, not in IA |
| S-40 | Works | Watch existing |
| S-41 | Works | Watch home: today's workout first |
| S-42 | Partial | Free workout only on phone +; no "define afterwards" |
| S-43 | Works | Watch existing |
| S-46 | Fails | No ahead/behind; no target source |
| S-47 | Works | Watch existing |
| S-49 | Works | Log › session › lift report (3 taps) |
| S-51 | Partial | No "edit load" on lift report |
| S-52 | Works | Watch existing |
| S-54 | Partial | Fix splits exists; "trim end" not listed |
| S-55 | Partial | No "incomplete" state in Log/report |
| S-56 | Partial | No "waiting to sync" anywhere |
| S-57 | Partial | Settings › Watch (3 taps) lacks Sync now / pending count |
| S-59 | Fails | No delete/merge on Log row or report |
| S-62 | Works | Log › report › Fix splits (3 taps) |
| S-63 | Fails | + has no "Log a result" |
| S-65 | Fails | No variant edit on report |
| S-67 | Works | Today › Last result (1 tap) |
| S-68 | Works | Existing report |
| S-69 | Partial | Log has filters but no search, no calendar |
| S-77 | Fails | Targets only in deferred Insights; nowhere to set them |
| S-78 | Partial | Watch standalone race mode not in IA |
| S-79 | Fails | Depends on S-77/S-46 |
| S-80 | Partial | Roxzone only in Insights (deferred) |
| S-82 | Fails | Calibration in Insights › Running (deferred, wrong home) |
| S-85 | Works | Report › Share |
| S-86 | Partial | Health writing unspecified |
| S-91 | Works | Avatar › Profile (3 taps) |
| S-92 | Partial | Phone yes; watch and plate rounding not stated |
| S-97 | Partial | Advanced = raw Debug; no "Send diagnostics" |

**Tally:** 16 works · 25 partial · 15 fails (6 fail only on build-order timing).

**P2 sample**

| ID | Result | Why |
|---|---|---|
| S-14 | Works | Today as designed |
| S-15 | Works | Log › report › Do again (3 taps) |
| S-17 | Partial | Week strip only; no calendar |
| S-18 | Works | Preview › Favourite; Library › My workouts |
| S-22 | Fails | No inbound link/file entry |
| S-25 | Partial | Edit › Builder; no "Save as my version" |
| S-58 | Fails | No Health import |
| S-70 | Partial | "Compare" listed, no page |
| S-95/98 | Partial | Settings › Data, no restore/delete |
| S-99 | Fails | No glossary |

## 2. Top 10 findings (by severity)

1. **Build order breaks P1.** Photo, builder, schedule and Insights (targets, calibration, roxzone) come after the race; 9 P1 scenarios need them. *Rec:* order the build by the P1 list. Target splits go on the HYROX preview, calibration in Settings.
2. **Watch IA is one wireframe**, yet it carries most P1 weight. It has no Free workout, race mode, ahead/behind, pending-sync count or incomplete state. *Rec:* write a watch tree: Today's workout · Free workout · Lift session · Choose · Settings (sync), plus in-workout and done states.
3. **No first-run path.** *Rec:* a 3-screen skippable onboarding (units from locale, max HR, watch check), one-action empty states per tab, a watch-missing banner on Today and a migration notice.
4. **Reports can't edit the result** (variant, delete/merge, date, per-set load, trim). *Rec:* an "Edit result" sheet beside Fix splits on every report. PRs recalculate.
5. **+ misses no-watch actions.** *Rec:* Paste · Photo · Build · **Log a result** · Free workout / Lift session. Drop "From Library" (it loops to a tab). Add a Share Sheet extension into the confirm screen.
6. **Sync is hidden behind "Debug".** *Rec:* **Watch & sync** settings with pending count, last sync and Sync now; a chip on Today when results are pending; Advanced › Send diagnostics.
7. **Open model questions block the IA.** Gym day, partner/doubles and variant-on-result decide what a Log row is. *Rec:* decide before the Log. A row is a **Session** holding 1..n reports, with a partner flag and a variant per result.
8. **Tab model.** Insights is empty and deferred, a centre "+" tab is non-standard on iOS, and Settings sits only behind Today's avatar. *Rec:* v1 tabs **Today · Library · Log**, with + in the nav bar and the avatar on every tab. Insights becomes tab 4 later and starts as cards on Today (open question 4).
9. **Library mixes categories.** HYROX sits under "Benchmarks", Class workouts apart from My workouts, and the Lift page has 3 entry points. *Rec:* Library holds only startable things: Benchmarks · HYROX · Mine ("From gym" filter) · Lifts. One canonical Lift page. Add search to Log.
10. **Accessibility.** Flags are orange only, ahead/behind is colour only, charts have no text and the watch is Crown-only. *Rec:* icon plus text for flags, signed deltas (+0:12), a VoiceOver sentence per chart, Dynamic Type, and a double-tap alternative to the Crown.

## 3. Cut or defer for a solo-athlete v1

- **Readiness card and detail.** Extra permissions and a blank state; show last recovery instead.
- **Insights tab** (Recommendations, Engine, Running). Keep one Rx note per report.
- **Class workouts section** (make it a filter) and **"From Library" in +**.
- **Calendar.** "Schedule for tomorrow" covers S-09.
- **Estimated-max lift pages.** Keep the lift report and a best-lifts list.
