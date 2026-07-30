# Jeeves — Product Requirements Document (as-built)

**A private, single-user iOS companion that plans the day around a fixed routine, real traffic, and real priorities — stands down and computes leave-by chains when you travel — and instruments itself so its own logs catch its bugs before you do.**

- **Platform:** iOS (SwiftUI + SwiftData) + watchOS companion. iPhone portrait-first.
- **Bundle ID:** `abhimanyusingh.me.Jeeves` · CloudKit container `iCloud.abhimanyusingh.me.Jeeves`.
- **Distribution:** personal device install via free provisioning (7-day signing).
- **Repository:** public — **no secret may ever be hardcoded or committed** (§10).
- **Status:** working build on device and watch; **404 offline tests green**; five GPT-judged eval lenses plus three deterministic audit layers (§8).

> **As-built** PRD, updated 2026-07-30. Supersedes the 2026-07-22 as-built
> (archived at [`PRD-archive-2026-07-22.md`](PRD-archive-2026-07-22.md)) and the
> original brief ([`PRD-original-brief.md`](PRD-original-brief.md)).
> § numbers are stable and cited from source comments (`PRD §5.5`); keep them in sync.

---

## §1 — Overview, vision & earned principles

Jeeves turns standing intentions (interview prep, reading, job applications, the gym, photography) plus the day's fixed commitments (events, appointments, trips) into a realistic hour-by-hour schedule — then keeps that schedule honest as the day unfolds, and **stops planning entirely when you travel**, replacing routine with the one thing that matters away from home: when to leave.

The original guiding principle stands: **use Claude's intelligence for judgment, not arithmetic.** A deterministic engine exists only as an offline fallback; deadline chains (leave-by, cut-offs) are pure arithmetic and never delegated to a model.

Principles **earned in production** (each traces to a bug that shipped, was caught, and became doctrine):

1. **A trip owns its days.** No stored plan may exist under a trip; no generator (planner button, chat, overnight auto-planner) may create one. Enforced in one place (`TravelGuard`), asked by every surface.
2. **Measured, never typed.** Journey times come from live traffic; travel times shown to the user are labelled measured vs estimated vs missing ("Leave ~18:10 · no journey time yet"). Manual override unlocks only after measurement fails or is refused.
3. **Receipts, not optimism.** Every destructive or stateful chat action reports exactly what changed, from the tool result — never from the model's memory. Deleting events that back a trip *says* travel mode survives. The model may only quote numbers that appear in tool results.
4. **Narrate, don't heal.** Anomalies (stuck-live workouts, clone rows) are surfaced in the daily digest for the user to design fixes around — automatic repair is reserved for provably-safe operations.
5. **Blast radius decides where code runs.** Launch runs only repairs that are safe at any CloudKit sync state (content-keyed fixes, window *growth*). Anything destructive (merges, orphan deletion) is user-invoked with receipts.
6. **Corrections update, never duplicate.** Chat iteration upserts trips and journeys; identical clones and date-shaped bulk deletes have explicit, confirmed paths.
7. **The tool roster is the sole authority.** The model states limitations from its actual tools and never claims actions it has no tool for; the trajectory audit convicts violations.
8. **Every hardcoded default is a decision** — extracted to a pure, tested helper with the *why* pinned (the flight-To rule shipped wrong twice before this rule existed).

North star unchanged: wake up, tap **Plan my day** (or say it), and trust the result enough to just follow it — including the day it says "leave at 05:55."

## §2 — User & context

One user: a Bengaluru-based (IST) product-management candidate balancing interview prep, fitness (with an Apple Watch), reading, a job search, photography — and family travel. New to Swift; the app must run standalone on phone + watch with no laptop attached.

Implications: one user, one phone, one watch; state is local SwiftData mirrored to private CloudKit; reliability over features; the core loop is one tap or one sentence — typed or spoken (en-IN).

## §3 — Design & UX

- Warm, light editorial palette (cream `Color.bg`, serif display headers, terracotta accent). Travel surfaces use a distinct cooler ink (`Color.travelInk` teal) so travel mode reads as a different mode at a glance.
- One slim header per tab; bottom tab bar; themed form chrome; the Day Planner date dial spans yesterday → +60 days.
- Copy is honest by design: estimate tildes, "measured against live traffic", refusal messages that name the trip, quiet-day cards that never stack duplicates.
- The dark-warm NYT-style redesign remains deferred (tokens kept swappable; spec in the original brief).

## §4 — Information architecture

Six iPhone tabs (`ContentView`) + the watch app:

| Surface | Purpose |
|---|---|
| **Jeeves** | Conversational planning, Q&A, and 22 tools (§5.8) with voice input (§5.9). |
| **Planner** | Date dial, events, gym input, Plan my day, persisted timeline; travel cards on trip days (§5.2–§5.5). |
| **Tasks** | Todos and reminders (§5.10). |
| **Fitness** | Today feed (live watch cards, needs-detail, done), lift logger, walk detail, run tool, unified history, daily check-in (§5.7). |
| **Library** | Books via camera scan, reading logs (§5.6). |
| **Stats** | Aggregates across habits, prep, fitness. |
| **Watch — "Jeeves On The Go"** | Activity picker (Run / Lift / Walk) with confirmations; live HR to phone; guaranteed end-of-workout summary handoff (§5.7). |

## §5 — Functional requirements

### §5.1 Routine, priorities & the plan contract
- Priority tiers: **Must** (protected), **Important** (kept whole ≥50% or dropped cleanly, varied day to day), **Flexible** (yields first). Gym runs as one contiguous mobility → weights → cardio sequence, never split.
- The day starts at **07:00** (first block always; morning-routine filler if nothing claims it), productive window 08:00–20:30, wind-down to the fixed **23:00–07:00 sleep anchor**. Gym/events may run past 20:30; work may not.
- The planner always reports what it dropped or shrank, and why.

### §5.2 Plan my day / replan
- Claude generates; `PlanCoordinator` validates and stitches; every attempt (trigger: planner / chat / autoPlan) is logged to `PlanGenerationLog` and mirrored to iCloud Drive.
- Mid-day replans lock elapsed blocks and rebuild the remainder (**known gap:** elapsed is presumed done — wrong exactly when the replan is triggered by lateness; §12).
- The overnight auto-planner (BGProcessingTask + foreground backstop) fills a rolling window, skips travel days, and backs off on repeated failure.
- Adherence history feeds planning notes ("Job applications has slipped repeatedly") and drop decisions.

### §5.3 Events & Google Calendar
- Per-day sync, reviewed before import. Multi-day all-day events keep their **span** (exclusive-end corrected) and land as one row keyed by Google's event id — **re-syncs update in place** (title, span, venue; stale pins cleared) and, when the event backs a trip stay, move the stay and grow the trip (§5.5).
- Chat can add, edit, and delete events — deletion by title, by day, or by **date range** ("everything from September 1 onwards"); title-less range deletes are two-phase (preview list → confirmed) and receipts name any trip that keeps covered days in travel mode.
- Launch repairs: duplicate-externalID collapse; corrupted rows (end < start) restored.

### §5.4 Commutes
- Google Routes API with predicted traffic (TRAFFIC_AWARE_OPTIMAL); per-event outbound origin (Home/Work/Gym); background re-pricing as departure nears; return legs are always Event → Home.

### §5.5 Travel Mode
The flagship subsystem. A **Trip** covers an inclusive date range; on covered days the planner stands down and the day shows journeys instead.

- **Birth:** calendar detection (multi-day + location = strong; long journeys and round-trips offered, never auto-switched) → accept creates the trip, one **TripStay** per lodging (overlaps resolved: later start truncates the earlier stay), and one **drive** transition between consecutive stays (arrive-by noon, measured immediately). Chat parity via `add_trip` / `add_journey` (idempotent / upsert).
- **Journeys (TravelSegment):** flights work backward from departure (origin clock) through airline cut-off, security, the measured door-to-airport run, and buffer; drives work backward from a hard arrival read on the **destination clock**. Zones auto-fill by geocoding the places and re-fill when a place is edited; a zone arriving after render re-renders untouched pickers without moving the stored instant. Chains render each row on the clock it happens in, date-tagged when they cross midnight. A journey renders on its **leave-by day**.
- **Guards:** a flight's To is never prefilled and >6 h road measurements are refused on every surface (editor, card, chat, manual override). Journeys missing their time show "~" leave-bys and schedule **no** nudge.
- **Window integrity:** saving, measuring, or chat-adding a journey **absorbs** it — the trip grows to cover leave-by through arrival, then sweeps plans off newly covered days. Same-day handovers render every covering trip's journeys; journey-less covering trips share one quiet card (with a merge hint when they genuinely overlap).
- **Repairs:** launch = safe-only (phantom arrivals, self-transitions, window growth with timeless/implausible anchors excluded, orphan-nudge purge that fails closed). Destructive tidying = `clean_travel_data` (strict-interior merges; same-title boundary clones merge; stay clusters collapse against the running max; receipts). `delete_trip` handles partial titles, same-title twins (`all`), and date-shaped requests ("all trips on Sunday").
- **Notifications:** one "Leave in 30 minutes" per journey with a real journey time, on the journey's own clock, authorization-checked, cancelled with its segment or trip.

### §5.6 Library
Camera book scanning, metadata, reading logs, status; ISBN coherence is audited (§8).

### §5.7 Fitness & the watch
- Unified **Workout** model (lift/run/walk; states live → needsDetail → done; sources watch/phone/manual). The watch sends a start heads-up (live card with HR) and a guaranteed end-of-workout summary; claiming is a pure, tested matcher; **duplicate summary deliveries are detected and dropped**.
- Phone screens: one-save lift logger (sessions + sets, bodyweight modes), walk minutes + incline, run tool; check-ins **auto-derive** from the day's workouts; unified history.

### §5.8 Jeeves chat
- 22 tools spanning planning, events, calendar, commutes, todos/reminders (deduped), walks, blocks, chat history, standing preferences (with expiry), app data Q&A, and the full travel suite. Schema names and the dispatch switch are pinned to each other by a parity test.
- Conduct rules (prompted *and* mechanically encouraged): confirm-then-receipt for destructive actions; data questions answered via `fetch_app_data`, never memory; capability limits stated from the live tool roster; travel numbers quoted from tool results only.
- Every tool call is recorded to the event log (name, input digest, result digest) — each conversation is an auditable trajectory (§8).

### §5.9 Voice notes
On-device en-IN transcription with a proper-noun vocabulary drawn from the user's own exercises, venues, and saved places; audio synced via iCloud; a Whisper/gpt-4o-transcribe eval loop scores accuracy.

### §5.10 Tasks & notifications inventory
Todos (priority, due, context) and reminders (recurrence, dedup by title). Notification kinds: plan-block reminders, plan-ready, leave-by nudges, commute re-price alerts — all authorization-gated; travel nudges carry zone labels.

### §5.11 Anomaly pipeline & daily digest
- **AppEvent**: an append-only event log (workout lifecycle, trips, journeys, sweeps, refusals, calendar syncs, cleanups, every chat tool call). Rows are never mutated.
- **AnomalyScan** runs at every launch: structural rules over all history (stuck-live workouts, shells, check-in mismatches) plus behavioral rules over the event stream (many starts in a day — narrated with times; start-without-end; summary-without-start). It **narrates, never repairs**, and mirrors the digest to iCloud Drive.
- A daily **08:30 scheduled task** on the Mac renders the digest, drafts it into Gmail, and pushes a one-line headline. Within its first day the log caught a duplicate watch-summary delivery and reconstructed a multi-start gym evening.

## §6 — Data & API contracts

- **SwiftData models (24):** CheckIn, JobApplication, PrepSession, LeisureLog, DailyPlanState, Book, ReadingLog, SavedLocation, DailyEvent, ChatTurn, RoutineActivity, PlanGenerationLog, LiftSession, LiftSet, RunSession, StretchLog, Reminder, Todo, Workout, VoiceNote, Trip, TravelSegment, TripStay, **AppEvent**. All stored properties carry defaults (CloudKit); enums as raw strings; `saveOrLog()` is the sanctioned save.
- Plans persist as validated JSON on `DailyPlanState`; blocks carry kind/anchor/times; zero-length blocks are an audited defect.
- Diagnostics mirror to `iCloud~abhimanyusingh~me~Jeeves/Documents/` (`jeeves-diagnostics.json`, `jeeves-anomalies.json`) — the no-cable channel to the Mac.
- The store is pullable over USB/network (`devicectl … appDataContainer`) for the audit toolchain; Core Data epoch offset 978307200.

## §7 — Integrations & keys

| Integration | Use | Key handling |
|---|---|---|
| Claude API | Plan generation & chat | Keychain only |
| Google Routes / Geocoding / Time Zone | Journey measurement, zone auto-fill | Keychain only |
| Google Calendar (OAuth) | Event sync | iOS client id (public by design) |
| OpenAI (Mac-side only) | Eval judges (§8) | Env var per run, stashed file deleted after every run |

Every commit is secret-scanned (`grep -rn "sk-ant|sk-proj|AIzaSy"`); `build_device/` is gitignored.

## §8 — Quality & evaluation architecture

The distinctive subsystem: Jeeves assumes **author-written tests share the author's blind spots** and structures QA so something else finds them.

**Deterministic layers (free, exhaustive, no key):**
- `store-audit.py` — ~30 invariants over every table and all history (travel coverage, overlaps, clones, implausible flights, plans-under-trips, workout orphans and stuck-lives, plan-log liveness…). Invariants found by judges **graduate** here and are enforced forever.
- `trajectory-audit.py` — story-vs-state over every chat session: duplicate journeys per leg, times the assistant asserted that appear in no tool result (head-math detection), claim/state divergence.
- `AnomalyScan` on device (§5.11); Swift suite of **404 tests**, including reality-fixtures built from actual device corruption, tool-parity, and judge-picked edge cases.

**Judged layers (OpenAI, key per run):**
- Plan quality (real stored plans vs day context), chat quality (transcripts + full store dump, story-vs-state rubric), voice WER, UX walkthroughs, whole-store **coherence** (reads everything, proposes new invariants), and **scenario/dialogue generation** — the judge picks the test matrix, including multi-turn personas with typos, corrections, and bare consents; the author only writes faithful walkthroughs.
- `diagnose.py` = one command: pull → audit → dump → trajectory → coherence → plan quality; skipped layers are reported loudly.

**Process doctrine:** adversarial review before every ship (two review workflows on one day found 29 confirmed defects in this author's own diffs, including two launch-time data-destroyers); evidence-first debugging (pull logs, verify, then fix); every field report is reproduced from the store before code changes.

## §9 — Architecture notes

- Swift 5 mode with `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`; `nonisolated` for pure helpers; plain `Task {}` inherits MainActor.
- PBXFileSystemSynchronizedRootGroup — new files auto-compile. Watch link via WCSession (`sendMessage` live data, `transferUserInfo` guaranteed summaries).
- Launch order: notification config → BG task registration → watch link → workout migration → event repairs → travel repairs (safe-only) → sweep → orphan-nudge purge → anomaly scan + digest mirror.
- Time: the app runs on the device zone; travel crosses zones via two pure helpers (`TravelClock`), instants stored, wall-clocks rendered per-row; trip days are device-calendar normalized.

## §10 — Security & non-functional

- Public repo ⇒ Keychain-only secrets, secret-scan before every commit, keys shared in chat get rotated.
- Destructive operations: user-confirmed, receipted, and never run automatically at launch; deletion of trips/segments cancels their notifications; purges fail closed on fetch errors.
- Notification honesty: nothing is scheduled that authorization can't deliver; chains without journey times promise nothing.
- Resilience: offline plan fallback; measurement failure unlocks manual override with an explanation; auto-planner backs off on persistent failure.

## §11 — Testing

404 offline tests: planner logic, chat helpers (matching, fire-dates, ranges), travel arithmetic (clocks, chains, prefills, absorb, repairs — including fixtures cloned from real device rot), watch claiming, anomaly rules, tool parity, and judge-picked edge cases (back-to-back trips, same-day handovers). Suite green is a ship gate alongside the secret scan; device install follows every merge.

## §12 — Known limitations & roadmap

**Deliberate cuts (design pending, user decides from digest data):**
- Overnight halts / multi-day journey legs (stops stepper only).
- En-route days say "nothing to catch" (journeys render on leave-by day only).
- Trip-day itineraries — travel days show journeys, not activities; the Bali family-plan poster is the design brief for this.
- Date dial doesn't mark trip spans; day-view journey cards are read-only.
- Watch discarded-session leak (sub-minute cancels): root-caused; fix options documented in the digest, awaiting UX pick ("Close the Run?" nudge vs discard event vs auto-expiry).

**Open defects (tracked, not yet fixed):** replan treats elapsed as done; occasional dropped chat turn (now diagnosable via tool-call recording); recap self-dating slip; check-in cardio contradiction; lift-set bodyweight default; book ISBN/flag rows.

**Requested, buildable next:** daily 7 AM plan-summary notification with the actual day's blocks in the body; second-device/iPad support rides on CloudKit.

**Observation window:** planner reliability items (offline-fallback rate, plan-storm) under observation until ~2026-08-28 — measure before tuning.

**Explicit non-goals:** multi-user, accounts, servers, market distribution (a separate productization track exists if ever wanted — §2's constraints are features, not debts).
