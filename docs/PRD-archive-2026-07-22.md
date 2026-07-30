# Jeeves — Product Requirements Document (as-built)

**A private, single-user iOS productivity companion that plans your day around a fixed routine, real commute traffic, and your priorities — and keeps the plan honest as the day unfolds.**

- **Platform:** iOS (SwiftUI + SwiftData), iPhone, portrait-first.
- **Bundle ID:** `abhimanyusingh.me.Jeeves`
- **Distribution:** personal device install via free Apple provisioning (7-day signing expiry; runs standalone on-device once installed).
- **Repository:** public — therefore **no secret may ever be hardcoded or committed** (see §10).
- **Status:** working build, installed on device; 107 offline tests green; ChatGPT-judged plan-quality eval at ~0.96–0.99.

> This is the **as-built** PRD — it describes the app as it actually exists in the repo today. It supersedes the original pre-build design brief, preserved at [`PRD-original-brief.md`](PRD-original-brief.md).
>
> Section numbers (§) are stable and referenced directly from source comments (e.g. `PRD §5.1`, `PRD §6`). Keep them in sync when editing.

---

## §1 — Overview & vision

Jeeves turns a set of standing intentions (interview prep, a reading habit, job applications, the gym, a photography hobby) plus the day's fixed commitments (events, appointments, travel) into a concrete, realistic, hour-by-hour schedule — and then behaves like a thoughtful assistant rather than a rigid packer:

- It **reasons like a human** — chaining adjacent trips, using on-site facilities, moving flexible activities, and never cramming.
- It **respects priorities** — Must-dos are protected, Important items are kept whole or dropped cleanly, Flexible items yield first.
- It is **grounded in reality** — real driving times with predicted traffic, and a live re-check as departure nears.
- It is **transparent** — it always says what it dropped or shortened, and why.

Guiding principle (unchanged from the brief): **use Claude's intelligence for judgment, not just arithmetic.** A deterministic engine exists only as an offline fallback.

The north star: the user should wake up, tap **Plan my day**, and trust the result enough to just follow it.

## §2 — User & context

**Primary (and only) user:** an individual preparing for product-management interviews while maintaining fitness, reading, a photography hobby, and a job search. New to Swift/iOS; relies on Jeeves running standalone on their phone.

Design implications:
- **One user, one device.** No accounts, no multi-tenant, no server. All state is local (SwiftData) or in the device Keychain.
- **Reliability over features.** The plan must persist across launches and work with no laptop/simulator attached.
- **Low-friction daily loop.** The core interaction is a single tap or a one-line chat message.

## §3 — Design & UX

- **Theme (current):** a hardcoded warm, **light** palette (`Color.bg`, `Color.surface`, `Color.accent`, …). The app is pinned to `.preferredColorScheme(.light)` because the palette is not yet dark-mode-safe.
- **Deferred — dark-warm editorial redesign:** the original brief specifies a dark-warm palette + NYT-style editorial serif (PT Serif + Inter) with a timeline-as-masthead layout. That full visual spec, palette hexes, typography, and the `darkwarm-nyt-mockup.{html,png}` mockups live in [`PRD-original-brief.md`](PRD-original-brief.md) §3 and remain the reference for that future work. Colors are kept in tokens so a theme swap stays low-effort.
- **Chrome:** one slim header per tab (no stacked global header); a bottom tab bar.
- **Forms:** themed via `jeevesFormChrome()` so modals match the palette rather than showing system defaults.
- **Day Planner dial:** a horizontally scrolling weighted date timeline — a ghosted "yesterday" anchor on the left, amber "today", a month eyebrow, jump-to-today; spans yesterday → +60 days.

## §4 — Information architecture

Six tabs (`ContentView`):

| Tab | Purpose |
|---|---|
| **Jeeves** | Conversational planning + Q&A chat (§5.8). |
| **Planner** | The Day Planner: date dial, gym/events input, Plan my day, persisted timeline (§5.2–§5.5). |
| **Check-in** | Daily fitness check-in (§5.7). |
| **Library** | Book library with camera scanning and reading logs (§5.6). |
| **Progress** | Aggregated views of habits/prep/fitness over time. |
| **History** | Past days' check-ins and records. |

## §5 — Functional requirements

### §5.1 — Baseline routine & priority tiers

The user's standing routine is a typed table (`Baseline.activities`) fed verbatim into the planning prompt. Each activity has a duration and a **priority tier**:

| Activity | Duration | Tier |
|---|---:|---|
| Interview prep — Reading | 90 min | **Must-do** (08:00 peak-focus slot) |
| Lunch | 30 min | **Must-do** (window: 12:30 earliest → 14:00 preferred finish → 14:30 hard latest start) |
| Job applications | 75 min | Important |
| Interview prep — practice | 120 min | Important (split Product Sense / Execution / Strategy / Behavioral, weighted to the most-neglected in the last 7 days: 45/35/25/15 by rank) |
| Reading habit | 90 min | Important |
| Chores | 40 min | Flexible |
| Chore buffer | 30 min | Flexible |
| Photography | 30 min | Flexible (discretionary-level; not pinned to any slot) |

> **Changed from the brief:** Lunch 45→**30 min**; Job applications 90→**75 min**; Photography is now Flexible/discretionary (was a fixed end-of-day block).

**Tiers** (`PriorityTier`): `Must-do` (never dropped) > `Important` > `Flexible` (dropped first).

**Fixed daily anchors** (above all tiers): the productive window **08:00–20:30**; **Sleep 23:00–07:00**; the gym routine and events with their real times.

### §5.2 — Planning engine

A single shared path produces every plan, so "Plan my day" behaves identically from the Planner tab and from chat.

- **`PlanCoordinator`** — the one entry point. Assembles inputs (gym, events, saved locations, prep history, plan date), fetches commute legs, calls Claude, validates, persists.
- **`PlanGenerationService`** — the Claude call. Model **`claude-opus-4-8`**, **adaptive thinking** (`thinking: {type: "adaptive"}`), `max_tokens: 16000`, 180 s timeout. Emits a strict JSON schedule (§6).
- **`PlanValidation`** — a pure, deterministic guardrail (no key, no cost). Classifies violations as **severe** or **quality**.
- **Repair retry** — if the Claude plan has any *severe* violation, the coordinator re-requests **once** with the specific violations appended, then keeps the cleaner of the two plans.
- **`DayPlanner`** — a deterministic "gym-pivot" packer used as the **offline fallback** when Claude is unreachable. Not event-aware (event-aware planning is Claude-only).

**Persistence:** the committed plan is stored as encoded JSON on that day's `DailyPlanState`, so it survives relaunches and shows on the Planner — not just in chat.

### §5.3 — Scheduling rules (transparency, drop order, and the rules that make a plan realistic)

The prompt, the validator, and the eval judge all encode the same rules:

1. **Never silently drop or shrink.** Every dropped/shortened item is reported to the user (`dropped`/`shrunk` + `summary`).
2. **Drop order:** Flexible first, then Important; **never** Must-do.
3. **Important-tier floor:** never shrink an Important item below 50%. If the day is too full, **drop one Important item entirely** (vary which, day to day) so the rest run full-length — one activity done fully beats two done at 20 minutes each.
4. **Events are fixed anchors you work around**, not walls that end the day. Fill before, between, and after returning home — up to 20:30. A midday event must not discard the afternoon.
5. **08:00 peak slot** holds Interview prep — Reading whenever the morning is free; if travel/an event blocks the morning, Reading moves to the first free slot afterward.
6. **Lunch window:** never before 12:30; aim to finish by 14:00; hard latest start 14:30.
7. **Gym routine is fixed and contiguous:** Mobility **20** / Weightlifting **70** / Cardio **35**, back-to-back with nothing wedged between. Never compressed. A late gym legitimately runs **past 20:30** — the boundary applies to *work*, not to a fixed personal commitment.
8. **Showers:** the main shower is at **home after returning** from the gym (not at the gym) unless chaining straight to an event; a **20-min morning shower** is added when the gym is in the second half of the day.
9. **Activity splitting:** an activity of **120 min or longer** may be split into **two** parts around an anchor (e.g. practice 90 → lunch → 30). Shorter activities are not split; the **gym is never split**.
10. **Evening:** no work after 20:30; a wind-down/personal block fills 20:30→23:00, then **Sleep 23:00–07:00**.
11. **Photography is flexible/discretionary** — placed in leftover time or dropped like any Flexible item; no fixed end-of-day slot.

> **Changed from the brief:** the original "event day boundary = departure time, nothing after the event" was replaced — events are now anchors worked *around*, and the day fills after returning home.

### §5.4 — Locations & commute

- **Saved locations** (`SavedLocation`): Home / Work / Gym, each with an address and declared **on-site facilities** (e.g. the gym has "shower", "weightlifting") — facilities are what let Jeeves reason about chaining ("shower at the gym before the event").
- **Real driving times:** the **Google Routes API** (`computeRoutes`), traffic-aware. Returns a single expected ETA (not a range); the app rounds to the nearest minute. No safety buffer is added.
- **Predictive traffic:** each leg is priced for its **scheduled departure** (Home→Gym = gym−50 min; Gym→Home = gym+105; event outbound = start−45; event return = event end) using `TRAFFIC_AWARE_OPTIMAL` + a future `departureTime`. A nil/past departure falls back to live "leave now" traffic.
- **Address resolution:** plain addresses, place names, `lat,lng`, and Plus Codes are geocoded by Routes directly. A **Google Maps short link** (`maps.app.goo.gl/…`) is not — so Jeeves follows the link and extracts coordinates (preferring the `!3d!4d` place pin over the `@` viewport centre) before routing.
- **Fallback:** any leg that can't be resolved (no key, bad address, network error) uses a flat **30-min** default, and the prompt tells Claude so.
- **Chaining intelligence:** gym→event routed directly when adjacent; on-site facilities used (shower at gym before an event); flexible activities relocated sensibly (eat near a venue around showtime).
- **Calendar import:** events can be pulled from **Google Calendar** (read-only OAuth) and reviewed before being added.

> **Changed from the brief:** commute moved from the legacy Distance Matrix API to the current **Routes API**, and gained **predictive (departure-time) traffic** and **Maps short-link resolution**.

### §5.5 — Notifications & live refresh

On-device **local** notifications only (`UNUserNotificationCenter`) — no server, no push certificate, no paid account. Foreground banners are enabled via a delegate.

- **Per-block reminders:** commute departures, gym, events, morning reading, sleep. **Events and sleep** fire **15 min early** ("In 15 min: …"); everything else at its start time.
- **Plan-ready notification:** fired when planning finishes **only if the app isn't in the foreground** — so if the user backgrounds the app while it plans, they're told it's ready.
- **Background execution during planning:** the generate flow is wrapped in a UIKit background-task assertion so a mid-request app switch doesn't tear the Claude call down (best-effort ~30 s+ window).
- **Live commute refresh:** as a commute's departure nears (within **90 min**), the leg is re-priced against fresh traffic; if the leave-by moves ≥3 min, the plan is rewritten, the reminder rescheduled, and the user pinged ("traffic's heavier — leave by 13:05, 10 min earlier"). Two triggers:
  - **Foreground (reliable):** on every app activation (`ContentView` scenePhase).
  - **Background (best-effort):** a `BGAppRefreshTask` scheduled ~90 min before the next event commute (`UIBackgroundModes: [fetch]`, `BGTaskSchedulerPermittedIdentifiers`). iOS controls the actual wake time; the foreground path is the dependable backstop.
- **Test reminder:** Settings has a "send me a test reminder (5 s)" button.

### §5.6 — Library

- **Book scanning:** point the camera at a bookshelf; Claude vision (`ClaudeVisionService`) extracts titles/authors and adds them.
- **De-duplication:** fuzzy matching (`LibraryLogic`) — drops subtitles after a colon, strips punctuation/diacritics, loose author match — so re-scanning the same shelf doesn't create duplicates.
- **Metadata/covers:** Open Library first, **Google Books** as a fallback for covers/ISBNs.
- **Reading logs** (`ReadingLog`): track status/progress per book; a book carries `LibraryStatus`, `ReadingStatus`, `BookRating`.

### §5.7 — Check-in, Progress, History

- **Check-in** (`CheckIn`, one per day): worked out?, weight training, stretching, mobility, cardio (+ type: Running / Inclined Walk, duration, incline). Feeds fitness history and informs gym scheduling. A smart banner nudges yesterday's/today's check-in.
- **Job applications** (`JobApplication`, one per day): applied today?, optional company/notes.
- **Prep sessions** (`PrepSession`): category (Product Sense / Execution / Strategy / Behavioral / Reading), duration, optional 1–5 self-rating — drives the neglect-weighted practice split.
- **Leisure logs** (`LeisureLog`) over `DiscretionaryActivity` (TV / Music / Photography / Extra interview prep) — the deterministic engine suggests the least-recently-logged discretionary activity.
- **Progress / History** tabs aggregate the above over time.

### §5.8 — Jeeves chat

- Conversational planning and Q&A (`JeevesChatService`, Claude text).
- **Anchor extraction** (`AnchorExtractionService`): "MLR at 7pm, plan my day" pulls out the event and plans in one step. Ticket screenshots can be parsed by Claude vision (`EventVisionService`).
- **Rolling 45-minute session:** shows recent turns and prunes old ones (`pruneOldTurns`); bottom-anchored scroll.
- Any plan generated in chat is **committed to today's Day Planner** so it persists and shows on the Planner tab.

## §6 — Data & API contracts

**Claude response contract** (`GeneratedPlan` / `GeneratedBlock`) — strict JSON, parsed by content/type, never by array position:

```json
{
  "blocks": [
    {"title": "Interview prep — Reading", "startTime": "08:00", "endTime": "09:30",
     "note": "peak focus", "isAnchor": true, "kind": "activity"}
  ],
  "dropped": ["Chores", "Photography"],
  "shrunk": ["Interview prep — practice 120→70"],
  "summary": "Plain-language explanation of the day and every trade-off.",
  "boundaryTime": "20:30"
}
```

- `kind` ∈ `activity | commute | gym | event | lunch | free | sleep`.
- Blocks are chronological and non-overlapping; anchors (gym sub-blocks, events, peak reading, sleep) set `isAnchor: true`.
- `summary` is required and user-facing; `dropped`/`shrunk` are surfaced verbatim (§5.3 rule 1).
- Malformed/partial responses fall back to the deterministic plan.

## §7 — Integrations & keys

| Integration | Use | Key storage |
|---|---|---|
| **Anthropic (Claude Opus 4.8)** | plan generation, chat, book & event vision, anchor extraction | Keychain |
| **Google Routes API** | traffic-aware commute times | Keychain (Google Maps key) |
| **Google Books** | cover/ISBN fallback | Keychain |
| **Open Library** | primary book metadata | none (public) |
| **Google Calendar** | read-only event import | OAuth (client ID in Keychain) |
| **OpenAI (`gpt-5-mini`)** | **eval only** — independent plan-quality judge; never generates plans | Keychain |

All keys are entered in **Settings** and stored **only** in the Keychain.

## §8 — AI evaluation strategy

Two complementary layers:

1. **Deterministic validation** (`PlanValidation`) — free, no key; runs as a runtime guardrail (severe → repair retry), an eval scorer, and unit tests. Checks: overlaps, out-of-bounds work, dropped Must-dos, lunch window, missing lunch, dropped events, wasted-afternoon, pinned gym durations, gym contiguity.
2. **LLM-as-judge** (`OpenAIJudgeService`, `PlanEval`) — an **independent** model family (ChatGPT `gpt-5-mini`) scores plans Claude produced on priorities / full-day use / chaining / coherence, avoiding self-grading bias. The harness pins a reference clock (07:00) to remove wall-clock artifacts and runs 8 scenarios (rest day; morning/evening/late gym; midday & evening events; two overnight-travel days). Current mean: **~0.96–0.99**. A soft gate fails below 0.6; a hard gate asserts the late-gym workout stays exactly 70 min.

Additionally, opt-in **live** tests assert the full commute chain end-to-end (leg → departure → Route → plan block length equals Maps-computed minutes), deterministically, without the judge.

## §9 — Architecture & data model

- **UI:** SwiftUI, six-tab `ContentView`.
- **Persistence:** SwiftData (`@Model`), lightweight migration by adding defaulted fields. Schema: `CheckIn`, `JobApplication`, `PrepSession`, `LeisureLog`, `DailyPlanState`, `Book`, `ReadingLog`, `SavedLocation`, `DailyEvent`, `ChatTurn`.
- **Concurrency:** app-wide `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; network/vision services are `async`.
- **Services:** thin, mostly `enum`-namespaced raw-REST integrations (Anthropic / Google / OpenAI) with best-effort failure → graceful fallback.
- **Info.plist:** generated (`GENERATE_INFOPLIST_FILE = YES`) merged with a small partial `Info.plist` at repo root that adds the background-refresh keys (kept outside the synchronized `Jeeves/` folder to avoid double-building).

## §10 — Non-functional requirements

- **Security:** public repo → **never** hardcode or commit API keys; Keychain only. Every commit is secret-scanned (`grep -rn "sk-ant|sk-proj|AIzaSy"`). Keys shared in chat are used only in a local/simulator context and the user is reminded to rotate them.
- **Privacy:** all personal data is on-device (SwiftData) or Keychain; nothing is sent anywhere except the named integrations, each for its stated purpose.
- **Reliability:** planning must persist and reminders must fire with **no laptop/simulator dependency** once installed.
- **Performance:** planning round-trips in seconds; commute lookups are a few API calls per plan; offline suite runs in <1 s.
- **Provisioning:** free Apple ID signing expires ~7 days after install; the app then needs a reinstall (reminders expire with it).

## §11 — Testing

- **Offline suite (107 tests):** `PlanValidationTests`, `DayPlannerTests`, `PlanCoordinatorTests`, `CommuteRefreshTests`, `NotificationServiceTests`, `LibraryLogicTests`, `ModelTests`. Pure, fast, no keys/network.
- **Opt-in live tests** (`LiveAITests`): real Claude/Maps round-trips; self-skip when a key is absent.
- **Plan eval** (`PlanEval`): ChatGPT-judged plan quality (needs both Anthropic + OpenAI keys).
- **Adversarial review:** substantial diffs are reviewed by a multi-agent workflow (find → adversarially verify) before shipping.

## §12 — Known limitations & roadmap

**Current limitations**
- Background commute refresh is **iOS-opportunistic** — "90 min before" is a target, not a guarantee; the foreground refresh is the reliable path (and Background App Refresh must be enabled).
- Commute time has **no safety buffer** and is Google's raw expected ETA.
- The deterministic offline planner is **not event-aware** (Claude-only for events).
- Theme is **light-only** until the §3 dark-warm redesign.
- Free-provisioning **7-day expiry** requires periodic reinstalls.

**Candidate roadmap**
- Optional commute **safety buffer** and an explicit "leave by HH:MM" on each commute block.
- **Geocoding-API fallback** for links/place names that don't expose coordinates.
- **§3 dark-warm redesign** handling both color schemes (spec in `PRD-original-brief.md` §3).
- Surface "estimate vs assumed" on commute blocks so real vs default is always visible.
- Widen live-refresh to gym legs and multi-event days.

---

*This PRD describes the app as built in the current repository. Update the relevant § when behavior changes so the source comments that cite these sections stay accurate.*
