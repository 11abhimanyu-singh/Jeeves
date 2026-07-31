# Jeeves UI Audit

Measured against `UI_Design_Rules_Checklist.md` — Nielsen, Apple HIG, WCAG 2.2, Material, and the behavioural laws (Hick, Fitts, Jakob, Miller, Doherty, Peak-End).

**Date:** 31 July 2026 · **Commit:** `931bfc7` · **Scope:** all 18 SwiftUI view files, ~8,000 lines

## How this was done, and what it can't tell you

Every finding below is grounded in the source or in the production store — file paths, line numbers, counts, computed contrast ratios, real latency percentiles. Nothing here is impression.

That also bounds it. This is a **static audit**. I did not run VoiceOver, did not step through Dynamic Type sizes on a device, did not measure frame rates or launch time, and did not view a single screen. So:

- Findings about **what the code does or doesn't contain** (no Dynamic Type, no haptics, 6 accessibility labels) are facts.
- Findings about **how it feels** (hierarchy, delight, whether a flow reads well) are inference from code structure and deserve a device check.
- Three rubric categories — launch time, 60 FPS, layout shift — **could not be assessed at all**. They are scored on the parts I could see, and that limitation is carried into the score.

## Scorecard

| Category | Weight | Score | Verdict |
|---|---:|---:|---|
| Usability (Nielsen) | 25% | 16.0 | Solid status/error work; no undo, thin empty states, no help |
| Accessibility (WCAG 2.2) | 20% | **5.0** | The critical gap. Effectively unusable with assistive tech |
| Platform compliance (HIG) | 15% | 8.0 | Good SF Symbols and sheets; type and haptics off-guideline |
| Visual hierarchy & layout | 10% | 8.0 | The app's genuine strength |
| Interaction & navigation | 10% | 7.0 | 5 tabs is right; sheet-heavy; new shared menu is a real fix |
| Forms & inputs | 5% | 3.0 | Keyboard types good, everything else missing |
| Performance & feedback | 5% | **1.5** | A 400 ms target against a 535 s median |
| Error handling & recovery | 5% | 3.0 | Explains what happened, rarely what to do |
| Consistency & design system | 3% | 2.5 | One palette, one card idiom, applied throughout |
| Delight & micro-interactions | 2% | 0.5 | 9 animations, zero haptics |
| **Total** | | **54.5 / 100** | |

The headline: **this is a well-composed app that is close to unusable for anyone relying on assistive technology, and it asks users to wait minutes for its core action.** Those two things cost 30 of the 45.5 lost points. Almost everything else is in decent shape.

---

## P0 — Accessibility (scores 5/20)

### A1. Dynamic Type is not supported anywhere

**475 fixed font sizes. Zero scaling call sites.**

- 394 × `.font(.system(size:))` — [TravelViews.swift](Jeeves/TravelViews.swift) alone has 62
- 81 × `.serif()` / `.heading()`, which resolve to `Font.custom("Georgia", size:)` at [ContentView.swift:48](Jeeves/ContentView.swift:48) — the non-scaling initialiser
- 0 × `.font(.body)`, `.title`, `.caption` or any semantic style
- 0 × `ScaledMetric`, 0 × `dynamicTypeSize`

A user who raises text size in Settings sees **no change anywhere in Jeeves**. This fails HIG Typography and WCAG "Dynamic text" outright, and it is the single largest accessibility defect.

Worse, the sizes chosen are small. 110 of the 394 are **under 12 pt** — 26 at 10 pt, 21 at 10.5, 30 at 11. Apple's floor for legibility is 11 pt and body text defaults to 17 pt. Jeeves runs most of its interface at 12–14 pt with metadata at 10 pt.

**Fix:** change `serif()` to `Font.custom("Georgia", size: size, relativeTo: .title2)` — that one edit makes 81 call sites scale. Then convert the `.system(size:)` sites to semantic styles, largest text first. This is mechanical and can be done incrementally.

### A2. Six accessibility labels in the entire app

| File | Labels |
|---|---:|
| [AppNavigation.swift](Jeeves/AppNavigation.swift) | 3 |
| [DayPlannerView.swift](Jeeves/DayPlannerView.swift) | 1 |
| [JeevesChatView.swift](Jeeves/JeevesChatView.swift) | 1 |
| [PlanEditorView.swift](Jeeves/PlanEditorView.swift) | 1 |
| **Everything else — 14 view files** | **0** |

Icon-only controls with no label are announced by VoiceOver as "Button" or by their SF Symbol name. The delete buttons, the workout controls, the travel leg editors, the library actions — all unlabelled.

Notably, `AppNavigation.swift` (the newest file) is the only one that does this properly: labels *and* `.contentShape(Rectangle())`. That's the pattern to propagate.

### A3. Reduce Motion is never checked

Zero occurrences of `accessibilityReduceMotion`. There are only 9 animations, so the blast radius is small — but the setting is ignored, which is a WCAG Motion failure regardless of severity.

### A4. Touch targets below 44 × 44 pt

Fifteen fixed-size interactive controls sit under the minimum:

- 30 × 30 — hamburger [AppNavigation.swift:70](Jeeves/AppNavigation.swift:70), close button [:119](Jeeves/AppNavigation.swift:119), chat controls, library, workouts, [ContentView.swift:239](Jeeves/ContentView.swift:239)
- 28 × 28 — [TravelViews.swift:1107](Jeeves/TravelViews.swift:1107), [:1115](Jeeves/TravelViews.swift:1115)
- 32 × 32, 34 × 34, 38 × 38 — workouts, lifts, planner

Several correctly add `.contentShape(Rectangle())`, which fixes *hit detection* but not the **44 pt requirement** — the shape only expands to the frame it's given. The frames need to be 44.

The chat bubble at 56 × 56 ([AppNavigation.swift:86](Jeeves/AppNavigation.swift:86)) is the one control that gets this right.

### A5. Contrast failures in the palette

Computed to WCAG formula against the palette at [ContentView.swift:24-39](Jeeves/ContentView.swift:24). Failures at normal text size:

| Foreground | Background | Ratio | Status |
|---|---|---:|---|
| `accent` #C67139 | `surface` #EBDDC5 | **2.69** | ✗ Fails |
| `accent` | `surfaceDeep` #DCD3C4 | **2.43** | ✗ Fails |
| `accent` | `sageLight` #E1EECC | **2.97** | ✗ Fails |
| `sage` #7A8A5E | `surface` | **2.79** | ✗ Fails |
| `sage` | `surfaceDeep` | **2.52** | ✗ Fails |
| `textMuted` #6E6759 | `surface` | 4.18 | ⚠ Large text only |
| `textMuted` | `surfaceDeep` | 3.78 | ⚠ Large text only |
| `textSoft` #645C50 | `surfaceDeep` | 4.44 | ⚠ Just under 4.5 |

This matters most where it's used most: `textMuted` at 10–11.5 pt on `surface` cards is the standard metadata treatment across the app — 4.18:1 at 10 pt, which is small text failing the normal-text threshold. `accentDeep` (5.09:1) and `sageDeep` (4.82:1) already pass and are the drop-in replacements for `accent`/`sage` on cards.

**The good news:** `textPrimary` passes everywhere at 11–14:1. The base reading experience is fine; the failures are in secondary and accent text.

### A6. Dark mode is disabled by fiat

[JeevesApp.swift:103](Jeeves/JeevesApp.swift:103) — `.preferredColorScheme(.light)`.

I'll treat this as a deliberate identity choice, not a bug: the warm paper palette is the app's character and a naive inversion would wreck it. But it is a checklist failure (§22), it overrides a system-level user preference, and it's rough at night for an app you check before bed. Worth a decision, not necessarily a change.

---

## P0 — The Doherty Threshold catastrophe

The checklist asks for a response within **400 ms**. Measured from 74 real generations in the production store:

| Trigger | Runs | Fastest | Mean | Slowest |
|---|---:|---:|---:|---:|
| `planner` (user taps Plan my day) | 48 | 13 s | **535 s** | 19,794 s |
| `chat` | 11 | 34 s | 199 s | 575 s |
| `autoPlan` (overnight) | 15 | 0 s | 63 s | 160 s |

**The user-initiated path averages just under nine minutes.** The worst run was 5½ hours. Against a 400 ms guideline that is not a miss, it's a different category of experience — and it's the app's primary action.

What the interface offers during those nine minutes, [DayPlannerView.swift:367-371](Jeeves/DayPlannerView.swift:367):

```swift
ProgressView()
Text("Jeeves is planning your day…")
```

An indeterminate spinner and one static line. No progress, no elapsed time, no estimate, no cancel. The checklist explicitly calls for "an estimated time for longer operations" — nine minutes is exactly that case.

This is the highest-value fix in the document and it needs no redesign:

1. **Show elapsed time.** A ticking counter converts "frozen" into "working". One `TimelineView`.
2. **Set an expectation.** You have the data — "usually takes 1–3 minutes" beats silence, and the median matters more than the mean here given the 19,794 s outlier.
3. **Offer cancel.** A nine-minute operation with no way out fails Nielsen's "user control and freedom".
4. **Narrate the stages.** The pipeline already knows when it's fetching commutes vs. calling the model. "Checking traffic… / Thinking through your day…" is honest progress, not a fake bar.
5. **Investigate the tail.** A 5½-hour run isn't a slow response, it's a hang. The audit already flags it (`no successful plan generation over 15 minutes`) — worth treating as a bug rather than a UI problem.

Prompt caching (commit `f011451`) will shave the prefix cost but won't touch this materially — the time is thinking and commute lookups, not prefix upload.

---

## P1 — Usability gaps

### U1. No undo, anywhere

Zero undo affordances. Deletion is guarded by `role: .destructive` in only six places ([PlannerSetupView.swift:331](Jeeves/PlannerSetupView.swift:331), [SettingsView.swift:259](Jeeves/SettingsView.swift:259) and [:318](Jeeves/SettingsView.swift:318), [LibraryView.swift:1029](Jeeves/LibraryView.swift:1029), [TravelViews.swift:496](Jeeves/TravelViews.swift:496) and [:743](Jeeves/TravelViews.swift:743)) — and destructive styling is a *warning*, not a *recovery*.

Nielsen lists "user control and freedom" third for a reason. For a planner holding hand-entered trips, lifts and books, an accidental delete is unrecoverable. Even a 5-second "Deleted — Undo" toast would close this.

### U2. Empty states are bare text

Six empty states found; all are a single `Text`. None has an illustration; only [LibraryView.swift:371](Jeeves/LibraryView.swift:371) offers a next action ("Set one from Unread below").

[RemindersListView.swift:63](Jeeves/RemindersListView.swift:63) is representative: 13 pt `textMuted` on a card — the app's lowest-contrast treatment (4.18:1) used for the message shown to a *first-time user*, at the moment they most need direction.

The checklist wants illustration + explanation + call to action. `ContentUnavailableView` is the native component for this and is used zero times.

### U3. No help or documentation

No onboarding, no first-run guidance, no help affordance. Jeeves has genuinely non-obvious concepts — priority tiers, anchors, the 20:30 boundary, travel absorption — all of which are encoded in the planner prompt and invisible in the UI. A user cannot discover why an item was dropped except by reading the plan summary after the fact.

### U4. Loading states are inconsistent

`ProgressView` appears in 14 files but the treatment varies, and the biggest surfaces (library search, book metadata) share no pattern with the planner. One `LoadingState` component would fix this and improve consistency scoring at the same time.

---

## P1 — Feedback and delight (scores 1.5/5 and 0.5/2)

**Zero haptics.** No `UIImpactFeedbackGenerator`, no `.sensoryFeedback`. Completing a workout set, finishing a plan, checking off a todo, deleting a trip — all silent to the touch. On iOS this reads as unfinished; the checklist calls out haptics under both Feedback (§21) and Delight (§25).

**Nine animations across 8,000 lines.** For an app with a chat interface, a live workout timer and a generated timeline, state changes mostly just snap.

**Peak-End (§12):** the app's peak moment is a finished plan after minutes of waiting, and the ending is… the timeline appearing. No confirmation, no flourish, no haptic. The single highest-leverage delight fix in the app is a success moment when a plan lands.

`.refreshable` appears once, in [DailyDigestView.swift:50](Jeeves/DailyDigestView.swift:50). Pull-to-refresh is a Jakob's Law expectation on any list; the todo, reminder, workout and library lists don't have it.

---

## P2 — Forms, navigation, structure

**Forms (3/5).** `keyboardType` is set correctly in 9 places — numeric fields get numeric pads. But `submitLabel` appears once ([TodosListView.swift:81](Jeeves/TodosListView.swift:81)), `textContentType` never (no autofill for the API key or address fields), and there is no inline validation — errors surface after submission, not during.

**Navigation (7/10).** Five top-level tabs ([ContentView.swift:85](Jeeves/ContentView.swift:85)) sits correctly inside the 3–5 guideline. The shared hamburger in `931bfc7` fixed a real defect where Planner, Library and chat had no route to Stats or Settings.

The structure is **sheet-heavy**: 33 `.sheet` presentations. Sheets are correct for single tasks but they don't compose — a sheet from a sheet loses the swipe-back mental model, and "where did I come from" gets murky. Worth auditing the deepest chains (LibraryView has 7, WorkoutViews and DayPlannerView 5 each).

**Hick's Law:** five tabs plus a hamburger plus a floating chat bubble is three parallel navigation systems on one screen. Defensible — each serves a different job — but it's the ceiling; don't add a fourth.

---

## What's genuinely good

Being fair, because the score above is harsh and the app is not:

- **The design system is real and consistently applied.** One palette, one card idiom (`RoundedRectangle(cornerRadius: 14–16).fill(Color.surface)`), one section-header treatment. 18 files, no drift. That's the 2.5/3 on consistency and it's rarer than it sounds.
- **Visual hierarchy is strong.** The serif display face against the sans body, the uppercase kerned eyebrows, the severity-tinted dots in the digest — a reader knows what matters without being told.
- **`textPrimary` passes contrast everywhere**, 11–14:1. The core reading experience is solid.
- **Error copy is honest.** "Couldn't reach the planning service — showing an offline plan" ([DayPlannerView.swift:555](Jeeves/DayPlannerView.swift:555)) states what happened *and* what the app did about it. Most apps manage neither.
- **Graceful degradation is designed in**, not bolted on — the offline planner means a network failure produces a worse plan rather than no plan.
- **`AppNavigation.swift` is the accessibility exemplar.** Labels, `contentShape`, `buttonStyle(.plain)`. The newest code is the best code, which is the right direction.

---

## Recommended order

Sequenced by value per unit of work, not by severity.

| # | Change | Effort | Wins |
|---|---|---|---|
| 1 | Elapsed time + estimate + cancel on planning | S | Fixes the worst experience in the app |
| 2 | `relativeTo:` in `serif()` | XS | 81 call sites scale from one line |
| 3 | Swap `accent`→`accentDeep`, `sage`→`sageDeep` on cards | XS | Clears 5 contrast failures |
| 4 | Bump the 15 sub-44 pt frames to 44 | S | Closes the touch-target failure |
| 5 | Haptics on completion actions | S | Biggest delight-per-line in the app |
| 6 | Accessibility labels on icon-only controls | M | The 20% category is 5/20 today |
| 7 | Undo toast on destructive actions | M | Nielsen #3, real data-loss risk |
| 8 | `ContentUnavailableView` for the 6 empty states | S | Illustration + CTA, native component |
| 9 | Convert `.system(size:)` to semantic styles | L | Completes Dynamic Type |
| 10 | Decide on dark mode | — | A product call, not a bug |

Items 2, 3 and 5 are roughly an afternoon together and move three categories.

## Not assessed

Stated plainly so the score isn't over-read:

- **Launch time, frame rate, layout shift** (rubric §23) — needs Instruments on device
- **Actual VoiceOver behaviour** — the label count predicts it's poor, but the rotor experience and reading order are unverified
- **Dynamic Type layout breakage** — moot today since nothing scales, but it becomes the next question the moment item 2 ships
- **Landscape and iPad** — no size-class handling was found, but portrait-first is a legitimate choice for this app
- **Real-device contrast** — ratios are computed from source hex; display calibration and true-tone will shift perceived values
