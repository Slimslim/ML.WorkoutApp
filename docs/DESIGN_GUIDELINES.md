# Rx Lab design guidelines

The rules for how the app looks, reads and moves. Read this before designing or building
anything the athlete sees. Status: first version, 3 Nov 2026. Decisions marked **Open** are not
settled. The owner approves changes.

Live mockups: home page canvas (Round 3 is current) and the workout cards
(`docs/concepts/workout-cards.html`). The watch is covered by `docs/watch-design/`.

## 1. Principles

1. **Light and clean.** The phone should feel calm. If a screen feels busy, remove something.
2. **Simple first, depth on demand.** One number or one line up front; the detail is one tap away.
3. **Real data only.** Show what was measured. Never show an invented score, and never turn data
   into a judgement word such as "Hard".
4. **The plan comes first.** Home answers: what did I do, what is next, how is the week going.
5. **Measured, not fussed over.** As few taps as possible, usable with chalky hands.
6. **Apple around the edges, ours in the middle.** The footer and menus are standard iOS. The
   content is our flat style. Familiar patterns over clever gestures.
7. **Say it plainly.** Short sentences, the words used at the gym.

## 2. The watch stays

The current watch design is approved. Don't change the look or layout of a watch screen as a side
effect of other work. New watch items follow the existing style and the owner sees them first.
Watch rules: no scrolling, one signal per state, glanceable mid-set.

## 3. Phone look

### Layout

- White page, side margin 20. No shadows or gradients in the content.
- **Home is flat:** no cards and no rounded boxes. Separate things with space and thin lines.
- Workout cards (radius 16, 1 px border) are for card screens: Choose, the preview, Log, reports.
  On Home the same content appears as a flat block, and tapping it opens the full card.
- Straight edges for bars and lines. The Effort ring is the one circle in Home's content.
- **Navigation is Apple's.** The tab bar and menus use the standard SwiftUI components, so they
  get the system glass look on current iOS and the older frosted look on older versions. Don't
  draw our own, and don't restyle them. Rounded corners and glass are fine there, and only there.
- Touch targets are at least 44 pt.

### Colour

Neutrals plus one accent, and modality colours. Values come from the mockups and are not final
until they are in `Theme.swift`.

| Token | Value | Used for |
|---|---|---|
| Ink | `#1B1D21` | Main text, Effort arc |
| Ink 2 | `#5F6570` | Secondary text |
| Line | `#ECEEF1` | Thin dividers |
| Accent | `#D9692E` | Marks and the type tag |
| Accent text | `#B4501C` | Links and the +, on white |
| Good | `#2E8466` | Done ticks, better than last time |

**Open:** `Theme.accent` in the app is still the brighter orange (`#FF6B14`). Pick one.
**Open:** dark mode. The mockups are light only. The app follows the system setting today, so
every token needs a dark value before Home ships.

Secondary text must reach 4.5:1 on its background, so don't use lighter greys for text.

### Modalities

Each movement belongs to exactly one modality. Show only modalities that have data.

| Abbreviation | Modality | Colour | Examples |
|---|---|---|---|
| **OLY** | Oly lifting | `#E5B13A` yellow | Snatch, clean & jerk, variations |
| **STR** | Strength | `#D9692E` orange | Squats, deadlifts, presses, heavy KB and DB work |
| **GYM** | Gymnastics | `#3FA58A` green | Pull-ups, T2B, HSPU, push-ups, burpees, DU |
| **CRD** | Cardio | `#4F86E8` blue | Run, row, ski, bike |
| **CRY** | Carries | `#8E78C9` purple | Sled push and pull, farmers carry, sandbag lunges |

- A block's straight line uses these colours. A mixed block splits the line by its share.
- Colour never works alone: always pair it with the abbreviation or a label.
- **Open:** thrusters, wall balls and other in-between movements need one modality each.
- **Open:** whether percentages use time or Effort points. Time counts rest as work.
- The speed colours in `Theme.speedColors` are a separate scale, only for speed.

### Type

System font (SF). Weights 400 and 500 only on Home, so it stays light. Numbers are tabular.

| Role | Size / weight |
|---|---|
| Workout name | 20/500 on cards, 18/500 on Home, 16/500 in compact rows |
| Score | 26/500 on cards, 18/500 on Home |
| Effort label | 17/500 |
| Movement lines | 14/400 |
| Time domain, rep scheme | 14/500 |
| Cap | 13/400 |
| Meta, tags | 12/400, 10.5/500 |

## 4. Writing

- `lb` never `lbs`. Heights in `in`, runs in `m`, carries in `ft`, `Cal` before the movement.
- Time domain: `20 min AMRAP`, `Every 1:00 × 8`, `5 rounds`.
- Load with `@`: `7 Power Cleans @155 lb`. The load stays together on one line.
- Abbreviations: HSPU, T2B, C&J, DB, KB, DU, ALT.
- A "lower is better" difference is written with its sign: `−0:23 vs last time`.
- No coach notes, strategy or targets on a card. It records what was done.
- Empty states say what to do next. They never apologise.

The full card rules are in `docs/concepts/HEADER_STUDY.md`.

## 5. Numbers we show

### Effort

The top of Home shows **Effort**: heart rate load for the day, added across all sessions.

- Formula: minutes × zone, summed (Edwards TRIMP). Zones are 50–60 % of max heart rate = 1,
  60–70 % = 2, 70–80 % = 3, 80–90 % = 4, 90 %+ = 5. Count from start to finish.
- A day with no heart rate data shows a dash, not 0.
- Max heart rate: the highest the watch has recorded for now. **Open:** let the athlete set it.
- The ring fills against the athlete's hardest day so far.
- Show it with total time.
- Today before training shows `0` and yesterday's value. Future days show a dash. No estimates.

Effort does not capture heavy lifting well. **Open:** show weight lifted beside it once the app logs
the loads actually lifted. It is left out until then, because a partial total would be wrong.

### Honesty

- Mark example data as an example in every mockup.
- A wrist speed is not a calibrated bar speed. Say so where it is shown as an absolute number.
- No PR, trend or comparison claim unless the data proves it.
- Show one insight on Home, in one sentence, and link to its source.

## 6. Navigation

Footer: the standard iOS tab bar with **Today · Workouts · + · Log · Progress**, with the + centred in
its own glass circle. Each button answers one question: what's today, what's available, start now,
what did I do, am I improving.

The avatar at the top right of Today opens a standard iOS menu, not a full screen: watch status,
upload status, Settings, Sign out. A small dot on the avatar shows the watch status at a glance.

The + opens a standard iOS menu: Record a lift, Start a workout. Log a result joins it later.

### Where everything goes

| Today in the app | Moves to | Note |
|---|---|---|
| Live: newest workout overview | Today, then its report | Opens by itself after a workout |
| Live: newest lift, session list | Today, then the lift report | |
| Live: live rep count during a set | Current Live screen, opens by itself | |
| Live: phone stays awake | Today and Live | Must stay: transfers only arrive while the app runs |
| Lifts: choose lift and load, send | + › Record a lift | Keep "Log load" and the on-watch row |
| Workouts: Next workout bar, Choose | Workouts tab; Today's Send to watch | Keep the library, search, history, refresh and offline cache |
| Workouts: result list | Log | Merged with lifting history |
| Workout detail, share, Fix splits | Report, from Log or Today | Fix splits is a sheet, unchanged |
| History: sessions, lifts, delete | Log | Keep delete with confirmation |
| Debug: account section | Avatar menu and Settings | Sign out in the menu; Upload now and Delete account in Settings |
| Debug: recordings, files, config, connection | Settings › For testing › Debug tools | Keep in TestFlight builds |
| Sign in gate | Unchanged | |
| Watch status chip | Dot on the avatar, words in its menu | |

### New screens that do not exist yet

Home needs these before everything above works. Listed so nothing is assumed to exist.

- Today, the days strip and blocks (programs come from `workout_library`, with `program` and
  `scheduled_on`).
- Log (merged lifts and workouts).
- Progress: first version is Effort per day and per week. **Open:** what comes after that.
- Log a result: manual entry, not designed.
- Effort and modality calculations.
- Settings. Program, loads and units are new: the app has no unit setting and no followed program.
  "Buzz and sounds" in the mockup has no feature behind it yet.

## 7. Every screen needs these states

- Empty (new tester, no program, nothing posted, rest day).
- Loading, and offline with the last good data.
- Error, in plain words with a next step.
- Signed out.
- Watch not connected.
- Long content: long workout names, many movements, big numbers.

## 8. Tried and rejected

Don't bring these back without asking.

- Rounded cards on Home, heavy top cards.
- Judgement words at the top ("Hard day"), intensity estimates before training.
- Race countdowns.
- Press-and-slide radial + menu, + in the corner, menu at the top, Settings in the footer.
- Showing modalities with no data.
- Lime or rainbow colour schemes.
- Leaderboards, comments, gym billing.

## 9. Before you ship a screen

- [ ] Follows this page, and the owner approved the mockup.
- [ ] Works in the states in section 7.
- [ ] Readable from about 2 m if it is used on the bench.
- [ ] Nothing in the table in section 6 lost its way in.
- [ ] Example data is gone or labelled.
- [ ] Watch screens unchanged unless the owner agreed.
