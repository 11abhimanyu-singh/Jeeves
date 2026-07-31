# Jeeves — Permanent Chat + Travel Acceptance Regression

Run these scripted scenarios on a device before shipping any chat, planner, or
travel change. Pin the device's `now`, retain the chat transcript and tool trace,
then verify persisted SwiftData rows, rendered cards, and notifications. Relaunch
after every stateful scenario.

## Common pass criteria

- The receipt matches the persisted state exactly.
- Replaying the final request is idempotent: it creates no duplicate event, trip,
  stay, journey, plan, or notification.
- `store-audit.py` and `trajectory-audit.py` pass after each scenario.
- A failed measurement/geocode leaves an honest incomplete state; no invented
  time or travel notification is shown.

## Scenarios

1. **Create an event and destination through chat**
   - Create an event and set its destination in the same conversation.
   - Pass: exactly one event exists on the requested day, at the requested time,
     with the requested venue.

2. **Extend an event while at it**
   - During an in-progress event, extend its end time through chat.
   - Pass: the event updates in place; the remaining day replans without treating
     elapsed blocks as completed merely because time passed.

3. **Extend an event while commuting to it**
   - While travelling to an event, extend its duration through chat.
   - Pass: the event updates in place; a replan does not overlap the remaining
     commute or the extended event.

4. **Four-day international return trip**
   - Create a four-day trip in a different time zone through chat, with outbound
     and return flight details.
   - Pass: the inclusive trip range is correct; both leave-by chains appear on
     their relevant local clocks; no normal plan exists on covered days.

5. **Back-to-back international and IST trips**
   - Create an international trip followed by a Mysore trip starting on the day
     the return flight lands. Stay at Radisson Hotel Mysore for two days; then
     drive to CGH Earth Wayanad; then drive home, arriving at 18:00.
   - Pass: the trips stay distinct; both covering journeys render on the
     handover day; the final drive works backward from 18:00 using measured
     travel time; normal planning is blocked throughout both trip windows.

6. **Modify the above itinerary by one day**
   - Add one day, then remove one day, through chat.
   - Pass: the same trip/stay rows update in place; journey coverage and
     notifications refresh; no clone or orphan remains.

7. **Move the Wayanad stay to Ooty**
   - Replace the Wayanad stay with Western Valley Resort near Ooty.
   - Pass: the stay's location and zone update; adjacent journeys are refreshed
     and remeasured; the old location no longer appears in cards or notifications.

8. **Chat CRUD by date, location, and hotel name**
   - Add, edit, and delete travel records through chat using each matching form.
   - Pass: ambiguous destructive actions show a preview and require confirmation;
     the receipt names precisely the records changed.

## Full chatbot acceptance coverage

### Conversation safety and tool routing

1. Ask a general planning question, a data question, an action request, and an
   unsupported request in one conversation.
   - Pass: Jeeves chats normally, uses `fetch_app_data` for personal-data claims,
     takes only supported actions, and states limits before promising anything.
2. Use typos, shorthand, a correction, a bare consent ("yes"), and a change of
   mind ("no, cancel that") across multiple turns.
   - Pass: the intended referent is resolved from context; uncertainty triggers a
     single focused question; no destructive action runs without clear consent.
3. Repeat an add request, resend after a timeout, and issue two compatible adds
   in one message.
   - Pass: duplicate-safe actions remain idempotent; distinct requested actions
     both complete; the transcript records errors rather than leaving a silent gap.
4. Ask for an answer the app cannot know (a live fact, an unavailable integration,
   or a missing value).
   - Pass: Jeeves says what it can and cannot access; it never fabricates a fact,
     tool result, measurement, or capability.

### Daily planner and events

1. Plan a free day, an event-heavy day, a gym day, and a day with all three
   priority tiers.
   - Pass: no overlap; Must work is protected; Important work is preserved whole
     or dropped cleanly; Flexible work yields first; every drop/shrink has a reason.
2. Create, edit, and delete events by title, exact date, date range, all-day span,
   overlapping title, missing venue, and destination.
   - Pass: exact rows are selected; title-less range deletion previews before
     confirmation; multi-day events retain their span; no duplicate exists after
     a correction or calendar re-sync.
3. Replan before the day begins, while on time, after a late event, after a late
   commute, after an event cancellation, and when lunch has already passed.
   - Pass: only the valid remainder changes; elapsed is not automatically claimed
     as completed; surviving anchors stay fixed; no block is in the past.
4. Plan with a missing API key, rate limit, malformed response, slow response,
   missing Maps result, and offline network.
   - Pass: the displayed diagnosis identifies the true failure category; fallback
     respects events and hard constraints, or safely declines to plan.

### Tasks, reminders, data questions, and preferences

1. Add identical todos, recurring reminders, a past-time reminder, and multiple
   todos/reminders in one message.
   - Pass: title deduplication works; recurrence is correct; past same-day times
     roll to the next valid occurrence; every created record appears in Tasks.
2. Complete, edit, and delete items by partial title, ambiguous title, date, and
   context.
   - Pass: ambiguity is resolved before mutation; destructive actions require
     confirmation and produce an exact receipt.
3. Ask about events, workouts, PRs, tonnage, walks, runs, books, check-ins,
   reminders, and an earlier chat conversation.
   - Pass: answers come from fetched rows; multi-collection questions inspect all
     relevant collections; counts and dates are correct; absence is reported
     honestly.
4. Remember a standing preference, replace it, expire it, and forget it.
   - Pass: only active preferences influence later turns; replacement does not
     duplicate; expired preferences do not affect planning.

### Fitness, exercise, and Watch sync

1. Start and finish a Watch run, lift, and walk; repeat each from the phone and
   as a manual entry.
   - Pass: the unified history shows one workout per real activity with its
     correct type, source, state, duration, and date.
2. Send a Watch start, delayed heart-rate updates, an end summary, and a duplicate
   end summary; test end-before-start and start-without-end delivery orders.
   - Pass: live phone cards update with HR; a summary is claimed once only;
     out-of-order or incomplete records are narrated as anomalies rather than
     silently duplicated or destroyed.
3. Test Watch disconnection during a workout, phone app termination/relaunch,
   transfer retry, zero-HR/implausible-HR samples, and a sub-minute cancelled run.
   - Pass: valid completed data survives; no phantom completed workout appears;
     incomplete sessions are surfaced honestly under the agreed UX policy.
4. Log a lift with bodyweight, no weight, multiple sets, edits, a walk with incline,
   and a run-program session.
   - Pass: sets and metrics persist accurately; check-in derives from workouts;
     chat answers distinguish one-session tonnage from whole-day tonnage.

### Extended travel edge cases

1. Test flights that cross midnight, cross the International Date Line, change
   daylight-saving zone, depart before dawn, have no airport travel time, and are
   later edited to another origin/destination.
   - Pass: stored instants remain stable; every row renders in its local clock and
     date; missing measurement shows a tilde and schedules no nudge.
2. Test a short drive, a drive just under six hours, a drive over six hours, a
   drive with stops, an arrival-time correction, and an overnight drive.
   - Pass: over-six-hour automatic measurement is refused; stops move leave-by
     earlier; destination-clock arithmetic is correct; overnight dates are shown.
3. Test overlapping stays, same-title boundary stays, same-day handovers, a trip
   with no journeys, a journey that expands a trip, and deleting a journey/trip
   that covers existing plans.
   - Pass: later stays resolve overlaps; valid trip windows grow and sweep plans;
     journey-less overlaps use one quiet card; deletion cancels notifications and
     never leaves an orphan plan or nudge.
4. Test unclear trip names, twins with the same title, partial-title deletes,
   date-shaped deletes, and a user declining the confirmation.
   - Pass: candidates are previewed; only confirmed targets change; declining
     leaves every row and notification untouched.

### Voice, library, and resilience

1. Dictate noisy en-IN phrases containing names, venues, exercise names, dates,
   and corrections; include an unintelligible recording.
   - Pass: high-confidence content follows the same chat path as typing;
     low-confidence transcription is shown for correction, never silently acted on.
2. Scan the same book twice, a book with a bad ISBN, no ISBN, and ambiguous cover;
   add and edit reading logs.
   - Pass: metadata and ISBN coherence hold; duplicate scans do not create
     conflicting books; uncertainty is visible.
3. Force app relaunch during a chat tool call, a plan request, calendar sync,
   workout handoff, and travel measurement.
   - Pass: no partial mutation becomes a duplicate; the user receives a truthful
     result or recoverable error after relaunch.
