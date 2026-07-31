# Jeeves: what can move server-side, and what can't

**As of** `ded5c8e`, 31 July 2026. Jeeves has **no backend today** — every API call, every key, and every byte of state lives on the phone, with CloudKit mirroring SwiftData between phone and watch.

## The one decision everything else hangs off

Nearly every "can X move to the server?" question collapses into a different question:

> **Does the server have the day's data?**

Right now it doesn't. The store is SwiftData mirrored through CloudKit, which is Apple-private — a server of yours cannot read it. So a capability can only move if it is either **stateless** (send inputs, get an answer) or comes **after** you replicate state server-side.

That splits the work into two very different projects:

- **Tier 1 — stateless relays.** No data migration. Mostly a key-custody and caching win. Small, safe, useful on its own.
- **Tier 2 — server owns state.** A real backend with the planner's data model. Everything else becomes possible; it is also the point where you stop having a single-user local-first app and start operating a service.

The table marks which tier each row needs.

---

## Move to server

| Capability | Today | Tier | Why it moves | What you gain |
|---|---|---|---|---|
| **Plan generation** — Anthropic call | [PlanGenerationService.swift](Jeeves/PlanGenerationService.swift) | 1 | Pure request/response. Inputs are already assembled into one prompt | Key off-device; shared prompt cache; retries and model swaps without shipping an app build |
| **Ticket / event vision** | [EventVisionService](Jeeves/EventVisionService.swift), [ClaudeVisionService](Jeeves/ClaudeVisionService.swift), [AnchorExtractionService](Jeeves/AnchorExtractionService.swift) | 1 | Image in, structured JSON out | Same; also lets you swap models per image type |
| **Commute / traffic lookup** | [GoogleMapsService.swift](Jeeves/GoogleMapsService.swift) | 1 | Stateless geocode + directions | **Biggest cache win** — the same Home→Gym route is re-priced constantly. A server cache cuts quota hard |
| **Book search + metadata** | [BookSearchService](Jeeves/BookSearchService.swift), [BookMetadataService](Jeeves/BookMetadataService.swift) | 1 | ISBN/title lookup against public APIs | Cache; kills the silent `backfillMissingMetadata()` sweep on every Library visit |
| **Voice-note transcription** | [VoiceNotes.swift](Jeeves/VoiceNotes.swift) | 1 | Audio in, text out (recording stays local) | Better accuracy than on-device Speech, especially on accented input — the exact thing `voice-eval.py` measures |
| **Judged evals** | [OpenAIJudgeService](Jeeves/OpenAIJudgeService.swift), `tools/*-eval.py` | 1 | Already off-device on your Mac | A scheduled runner instead of a Mac that must be awake at 08:36 |
| **The whole eval + audit toolchain** | `tools/` + iCloud export | 1 | Reads a store snapshot | Removes the iCloud export hop entirely — the thing that silently failed for days |
| **Chat model call** | [JeevesChatService.swift](Jeeves/JeevesChatService.swift) | 1 (partial) | The *API call* is stateless | Key custody + shared cache. **But the tool loop is not** — see Split |
| **Overnight auto-plan** | [AutoPlanService.swift](Jeeves/AutoPlanService.swift) | 2 | A cron doesn't depend on the phone being charged, unlocked, or awake | Needs server-side state to plan against |
| **Leave-by notifications** | [TravelNotifier](Jeeves/Trip.swift), [ReminderScheduler](Jeeves/ReminderScheduler.swift) | 2 | Push instead of locally-scheduled notifications | Fires even if the app hasn't opened in weeks; fixes "a nudge for a leg that moved" centrally |
| **Google Calendar sync** | [GoogleCalendarService](Jeeves/GoogleCalendarService.swift), [GoogleOAuthService](Jeeves/GoogleOAuthService.swift) | 2 | Server-to-server sync with a refresh token | Continuous sync instead of on-open pulls; no raw OAuth client ID pasted into Settings |
| **Anomaly scan + product metrics** | [AnomalyScan](Jeeves/AnomalyScan.swift), [ProductMetrics](Jeeves/ProductMetrics.swift) | 2 | Pure functions over the store | Runs nightly without the app; history beyond one device |

### Portable already, whatever you decide

These are `import Foundation` only — no UIKit, no SwiftUI, no device APIs. They would compile on a Linux server today:

`DayPlanner.swift` · `PlanValidation.swift` · `PlanEditLogic.swift` · `TravelDetection.swift` · `StayWindow.swift` · `AdherenceEngine.swift` · `LibraryLogic.swift` · `CheckInAutoFill.swift`

A second group is pure logic wearing a SwiftData coat — `TravelGuard`, `TravelRepair`, `PlanCoordinator`, `ProductMetrics`, `AnomalyScan`. The *reasoning* ports; the data access needs rewriting. That's the honest cost of Tier 2, and it is not small.

---

## Must stay on the client

| Capability | Where | Why it can't move |
|---|---|---|
| **Heart rate during a workout** | [HealthKitService.swift](Jeeves/HealthKitService.swift) | HealthKit is device-only and cannot be read off-device. Not a preference — an OS boundary |
| **Watch handoff** | [WatchLink.swift](Jeeves/WatchLink.swift), watch target | WatchConnectivity is a phone↔watch link. No server sits in it |
| **Live run / stretch timers** | [RunView](Jeeves/RunView.swift), [StretchView](Jeeves/StretchView.swift) | A countdown and a 5-second transition cue must be local. A network round-trip per second is absurd, and the flow has to survive no signal |
| **Screen-wake, haptics, idle timer** | [ScreenAwake.swift](Jeeves/ScreenAwake.swift) | Hardware |
| **Audio capture, camera, photo picking** | [VoiceNotes](Jeeves/VoiceNotes.swift), ticket screenshots | Capture is local even when processing isn't |
| **The offline planner** | [DayPlanner.swift](Jeeves/DayPlanner.swift) | Its entire purpose is producing a plan when nothing is reachable. Moving it server-side deletes the feature |
| **All UI** | 18 view files | Obviously — but note the type system, contrast tokens and Dynamic Type work stay client problems forever |
| **Keychain / credential storage** | [KeychainService.swift](Jeeves/KeychainService.swift) | Even with a server, the device still holds *one* credential: its own session token |
| **Local notification presentation** | [NotificationService.swift](Jeeves/NotificationService.swift) | Even with push, the client decides how a notification renders and what tapping it opens |
| **Optimistic local state** | SwiftData store | Ticking off a to-do must not wait on a network. The local store stays the source of truth for interaction, whatever syncs behind it |

---

## Genuinely split

These are the interesting ones — the naive answer is wrong.

| Capability | Server half | Client half | The catch |
|---|---|---|---|
| **Agentic chat** | The model call, prompt caching, tool-schema definition | **Tool execution** — `add_event`, `plan_day`, `delete_range` all mutate SwiftData | At Tier 1 the loop stays client-side and only the HTTP call is proxied. Full server-side chat needs Tier 2, or the server must call *back* into the device to run tools — which is worse than either end |
| **Plan generation latency** | Where the ~9-min call happens | Where the user waits | **A server does not make it faster.** The time is model thinking, not upload. What it buys: the request survives the app being killed, and the result can arrive by push instead of requiring the app foregrounded |
| **Notifications** | Deciding *when* (needs the plan) | Presenting, and offline fallback | A hybrid is correct: schedule locally so it works offline, let the server correct/cancel via push when the plan changes |
| **Diagnostics export** | Would become the natural home | Producing the snapshot | Tier 1 alone removes the iCloud hop that broke for days — arguably the single best reliability win here |

---

## What a server actually buys you

Ranked by value for *this* app, single-user:

1. **Key custody.** Five API keys live in a phone's Keychain today, and the repo is public. This is the strongest argument by a distance — and it doesn't need Tier 2.
2. **Killing the iCloud export hop.** You spent days on a container that silently never synced. A `POST /snapshot` has none of that failure surface.
3. **Shared caches.** Commute lookups and book metadata are re-fetched constantly for the same inputs.
4. **Model changes without an app build.** Swapping models or prompts currently means Xcode, a cable, and a reinstall.
5. **Work that doesn't need the phone.** Overnight planning, nightly audits, calendar sync — Tier 2 only.

## What it costs

- **Tier 2 means operating a service**: uptime, migrations, backups, auth, and a second copy of the data model to keep in step with SwiftData's.
- **Every server dependency is a new offline failure mode.** The app currently degrades gracefully — network loss produces a worse plan, not no plan. Proxying the model call preserves that; moving the *data* does not, unless you keep local-first sync.
- **CloudKit already does the sync job for free**, correctly, for phone↔watch. Replacing it is a real regression risk.
- **Latency floor.** Every proxied call gains a hop. Irrelevant against a nine-minute plan, noticeable on a book lookup.

## Recommendation

**Do Tier 1. Stop there unless something forces Tier 2.**

A single small proxy — one endpoint per upstream, keys in server env, a response cache on commute and book lookups, and a `POST /snapshot` that replaces the iCloud export — captures the top three wins with no data migration, no new offline failure modes, and no service to operate beyond a process that restarts.

The phone keeps owning its data, which is the property that has made this app reliable.

Tier 2 earns its cost only when you want something the phone genuinely cannot do: planning that runs whether or not the phone is awake, notifications that fire after weeks of not opening the app, or a second client. None of those is true today.
