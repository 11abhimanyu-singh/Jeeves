# Jeeves — the complete test catalogue, in plain English

Every check that guards the app, grouped by module. Three layers:
**Swift tests** (404, run before every ship), **deterministic audits** (run
against the real phone store, all history, no AI), and **judged evals**
(GPT reads plans/chats/state and scores them; needs a key per run).
Updated 2026-07-30.

---

## 1 · The day planner

**Plan shape & rules** (DayPlanner, PlanValidation, PlanModels, RoutineCatalog)
- A rest day starts with interview reading at 8, places lunch before its deadline, treats photography as flexible, has no overlapping blocks, and always ends with sleep at 11.
- Gym days: an early gym gets only a post-gym shower; a later gym adds the morning one; no tiny orphan blocks squeezed around gym; lunch still lands on time whether gym is early or midday; weights anchor exactly at the entered time; no overlaps even for a very early gym.
- The practice split gives the *least* time to the category you've practised most.
- A valid plan raises no violations. Severe violations are each pinned: overlapping blocks; a dropped must-do; work scheduled past the 20:30 boundary; lunch late or missing (with the replan windows that legitimately excuse it); a dropped event; a midday event followed by an empty afternoon; compressed or split or missing weightlifting; a "shower" secretly extending work past the boundary. A late gym may run past the boundary; an event merely *named* "gym" never satisfies the gym rule.
- Time strings parse strictly (bad ones rejected); the baseline routine has the right tiers and window; a generated plan survives a round trip to storage and back.
- The routine catalogue: an empty or fully disabled routine falls back to the default; disabled activities are excluded; order, durations, and tiers carry through.

**Mid-day replans & edits** (PlanCoordinator, PlanEditLogic)
- Only fully elapsed blocks get locked by a replan (none early in the day).
- Commutes: home→gym leaves 50 minutes before weights; gym→home leaves after cardio; event commutes leave before the event and return at its end; legs without addresses or times get no departure; every leg gets its departure attached; future departures upgrade to predictive traffic; an event titled "Gym" is not mistaken for the gym anchor.
- Google Maps share-links: coordinates are extracted from pins, query params, or viewport (out-of-range rejected); place names decode correctly; plain addresses pass through untouched without network.
- Manual plan edits: movable blocks flow contiguously; anchors stay pinned; long blocks never overlap an anchor; reorder-then-retime works; a duration edit cascades downstream; titles/notes update cleanly.

**Fallback, parsing & the overnight planner** (PlanFallback, PlanGeneration, AnchorExtraction, AutoPlanService, PlanDiagnostics)
- Offline fallback carves timed events in as anchors, reports displaced blocks (never silently), ignores all-day events, and changes nothing on empty days.
- Claude's plan responses parse whether bare, code-fenced, or wrapped in prose; thinking blocks are skipped; tool-only replies, empty content, API errors, and garbage all safely produce nothing rather than a corrupt plan. Same hardening for anchor extraction and every other AI response parser.
- The overnight auto-planner fills exactly the empty days in its window — no more, no less — and its "run at 4:30am" scheduling rolls to tomorrow correctly.
- Plan diagnostics classify outcomes and compute success rates and percentiles correctly (abandoned runs excluded).

## 2 · Adherence (did the day actually happen)

- Reading counts as done only when a reading log exists that day; future blocks are never prematurely marked skipped; gym follows the check-in; job applications follow their log; photography follows leisure logs; unloggable blocks stay "unknown".
- The score ignores unknowns, is nil when nothing is assessable, and the weighted score punishes a missed must-do harder than a missed nice-to-have.
- History tallies per-activity across days, excludes anchors, and the "this keeps slipping" note fires only with enough samples, never for lunch, and never for something you've marked must-do.
- A manual "I did it" always beats the inference.

## 3 · Commute re-pricing

- A commute is due for a live re-check only inside its window, before departure, when it leads to a real event with a resolvable origin.
- A materially revised departure rewrites the commute and trims the previous block; tiny wobbles are ignored; unrelated blocks stay intact; the notification wording is pinned.

## 4 · Travel Mode

**Leave-by arithmetic** (TravelMode, TravelClock)
- The flight chain matches a hand-worked example; chains cross midnight backwards correctly; shorter domestic cut-offs leave later; drive chains include stops, and more stops mean an earlier departure; a journey without its time computes no chain at all.
- Time entered for another zone stores the right instant; opening and saving the editor never drifts a stored time; zone offsets (including Nepal's +5:45) compute exactly; a flight landing next day is flagged, same-day is not, and a westward flight can honestly land "before" it left; leave-by arithmetic is zone-independent.
- Prefills are law: a flight's To is never prefilled (outbound or return — the bug that shipped twice); a return drive heads Home; an outbound drive heads to the first stay; back-to-back trips chain stay-to-stay; a two-day drive belongs to the day you *leave*.

**Detection & itineraries** (TravelDetection, Itinerary)
- Short or long nearby events, unmeasured journeys, all-day events without locations, and empty days are never called travel; multi-day-with-location, genuinely long journeys, and day-eating round trips are; weak signals only suggest; consecutive days form one span, gaps don't, duplicates don't inflate it.
- Google's exclusive all-day end date is corrected; overlapping stays resolve in favour of the later start; the move day becomes a transition; swallowed stays are dropped; back-to-back stays are left alone; three stays chain into two moves; 10 September is verifiably a quiet Bali day.

**The guard — a trip owns its days** (TravelGuard, TravelEdgeCase)
- Travel-day detection follows trip coverage exactly (first day, middle, last, and not a day either side).
- The sweep deletes stored plans only on covered days; with no trips it touches nothing; the overnight planner skips travel days.
- Absorb grows a trip to cover a journey (idempotently), leaves already-covered journeys alone, and a calendar re-sync moves the stay and grows the trip — including healing legacy stays that predate id-stamping. Stays never shrink a trip. The >6-hour flight-journey refusal rule is pinned.
- Edge cases the judge picked: three chained back-to-back trips stay three trips with every day still guarded; a same-day handover (land from trip A at 11:00, leave for trip B at 17:35) shows both journeys on the right day and never merges the trips; a journey growing its trip to *touch* another still never causes a merge.

**Repairs & cleanup** (TravelRepair, DailyEventRepair)
- Launch-safe repairs: self-transitions ("Bali → Bali") and phantom arrivals die; healthy rows are untouched; launch *never* deletes orphans or merges trips (the CloudKit mid-sync lesson); windows grow to cover stays, never shrink, and a timeless or absurd segment can never drag a window (the year-1 catastrophe test).
- User-invoked cleanup: genuinely overlapping trips merge and adopt each other's rows; back-to-back *different* trips never merge; same-title boundary clones do; a return to the same hotel later in the trip survives; twin-UUID rows are left for the audit; clone stay-chains collapse against the running maximum (the "collapsed 1 should have been 3" bug, pinned with the real device rows); clone journeys collapse to the best-informed one; disjoint trips are untouched.
- Corrupted calendar rows (end before start) revert to all-day; backwards manual times get swapped; healthy rows untouched.

## 5 · Jeeves chat

- Date words resolve correctly: today, tomorrow, "day after tomorrow" (which must beat its "tomorrow" substring), ISO dates, and junk falls back safely.
- Range deletion: "everything from September 1 onwards" matches every event whose span touches the range — including one *starting* in August that runs into September; a title narrows it; a single-day range is exactly that day.
- Reminder times: a future time stays today, a past time rolls to tomorrow, malformed times never schedule a wrong hour.
- Matching: fuzzy title matching works; strict matching is deliberately one-directional; best-match keeps only the closest title but keeps multi-day same-title groups together.
- Standing preferences: unbounded ones are always active; bounded ones live through their expiry day; malformed expiries are treated as permanent; comparison ignores the expiry wording; pruning cuts at 30 days.
- Data answers: a manual run survives a logged walk; the same activity is never double-reported; the run-program summary serves all weeks.
- **Parity**: every tool advertised to the model is dispatched, every dispatched tool is advertised, and the roster hasn't silently shrunk — schema drift fails the build, not the user.

## 6 · Fitness & the watch

- Watch claiming: a live walk is claimed even after you saved its details; an evening run never lands on the morning run's record; distant unclaimed runs stay unclaimed; the run tool's workout is enriched by its own summary; manual entries are never claimed.
- Day grouping merges same-day sessions and splits around midnight; activity codes map to the right types and titles.
- Check-in auto-derive: a lift ticks weight training; a walk fills cardio with minutes and incline; a run beats a walk for cardio detail; a live (unfinished) workout contributes nothing; stretching follows its log; a workout alone qualifies without a manual check-in; a rest-day mark survives a stray walk but real training overrides it; manual and auto merge with auto detail winning; an empty day has no status.
- Gym math: tonnage is reps × load; bodyweight moves count body mass plus added weight; isometric holds add no tonnage; run distance sums pace over time; per-side moves count double time; Couch-to-5K is sixteen full weeks.
- Anomaly rules: a workout "live" for 34 hours is reported, one two hours old is not; four starts in one day is narrated with its times, two (pause-and-resume) is not; a start with no end is reported only after twelve hours; start-then-summary is clean; a check-in claiming a workout with no workout row is flagged.

## 7 · Library

- Recommendations: nothing while a book is being read or nothing is unread; alternates fiction↔non-fiction after a finish; falls back sensibly.
- Duplicate detection: exact, case/whitespace, subtitle, co-author, punctuation and diacritic variants are all still duplicates; same title with a different author is not; editing a book never matches itself; a rescan missing the author still matches on title.
- Book metadata and search parsers handle normal results, missing covers/ISBNs, ten-digit ISBN fallback, and junk payloads; camera book-scanning (vision) parses plain and fenced JSON, tolerates nulls, and yields empty on any malformed response.

## 8 · Integrations & plumbing

- Google Calendar parsing (timed, all-day, missing fields), Google Maps durations (rounded minutes, fractional, multi-route, errors→nil), Google OAuth token exchange (refresh quirks, error bodies, junk→nil).
- Claude text/vision/event-extraction parsers: every malformed-response shape yields nil/empty, never a crash or corrupt row. The OpenAI judge's verdicts parse fenced or bare, and junk yields nil.
- Keychain round-trips, key independence, overwrite; calendar-connected state follows the refresh token.
- Notifications: anchors and key kinds get reminders, fillers don't; events and sleep remind ten minutes early; body wording pinned; plan-ready distinguishes offline.
- Models: enums round-trip through raw storage, defaults hold, plans persist and decode on chat turns and day state.

## 9 · Live integration (network, run deliberately)

- Real end-to-end: chat round trip, event extraction with time and venue, plan generation coherence, Maps commutes (live and predictive), gym/event commute blocks matching Maps minutes, an event committing to the planner.
- The GPT plan-quality judge scores a real generated plan (key-gated).

---

## 10 · Deterministic store audits (the whole phone database, all history)

**Travel**: no sentinel dates; every trip covers its stays and its journeys; no overlapping trips (boundary days allowed); no duplicate stays; no self-transitions; no flight with a >6-hour road journey; flights whose To doesn't look like an airport (warn); no arrival at or before departure; no journey missing its time (warn); no plans stored under trips; no orphaned stays or journeys.
**Events & plans**: no events ending before they start; no duplicate calendar ids; no duplicate plan rows per day; no zero-length blocks inside stored plans; no same-title all-day events overlapping (warn).
**Fitness**: no lift sessions/sets/runs pointing at missing parents; no cloned workouts (warn); no impossible numbers; no workouts stuck "live" over a day; no cardio details on a no-cardio check-in; no zero-duration workouts that have logged sets (warn); no implausible bodyweight jumps within one workout (warn).
**Tasks, notes, books, chat**: no duplicate active reminders; no expired one-shots still active (warn); no duplicate open todos (warn); no zero-length or transcript-less voice notes; no duplicate audio files; no duplicate check-ins per day; no books read past their last page; ISBN coherence (warn); no null fiction flags; no empty chat turns; chat history within bounds (warn).
**Pipeline liveness** (the only checks allowed to look at "now"): plan generation ran recently; the overnight auto-planner is alive; no failure streak; no runs stuck "pending"; no successful generation over 15 minutes (warn).

## 11 · Trajectory audit (story vs state, every chat session)

- No duplicate journeys per trip/mode/day left behind by a conversation.
- Every clock time the assistant asserted appears in some tool result — no head-math.
- Claims of deletion/creation are checked against what the store actually contains.

## 12 · Judged evals (GPT, key per run)

- **Plan quality**: real stored plans scored against the day's true context; a routine plan on a travel day is automatically a failing find.
- **Chat quality**: real transcripts judged with the full store dump alongside — "does the story told match the state left behind?"
- **Voice**: word-error-rate against a reference model with a proper-noun bias.
- **UX walkthroughs**: faithful reconstructions of real flows, scored for friction and misleading defaults.
- **Whole-store coherence**: the judge reads *every row of every table* and hunts contradictions the checklists can't see — then **proposes new invariants**, which graduate into §10 and are enforced free forever.
- **Scenario & dialogue generation**: the judge writes the test matrix — including multi-turn user scripts with typos, corrections, and bare "Sure" consents — so coverage isn't limited to the paths the author thought of.
