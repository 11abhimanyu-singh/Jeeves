# Feature brief: Travel Mode (for scenario generation)

Single-user iOS day planner. User lives in Bengaluru (IST). Normal days get a
generated plan (gym, interview prep, meals, commutes, sleep 23:00–07:00,
first block 07:00).

Travel Mode: a Trip covers an inclusive date range. On covered days the
planner STANDS DOWN — no plan may exist or be generated (three generators:
planner button, chat plan_day/replan_today, overnight auto-planner; all must
refuse). Instead the day shows the trip's journeys with leave-by chains.

How trips are born:
- Google Calendar sync imports events; multi-day all-day events keep their
  span and location. A banner offers "Switch these N days" when an event
  looks like travel (multi-day + location is the strong rule).
- Accepting creates the Trip, one TripStay per distinct lodging event
  (overlapping stays resolve: later start truncates the earlier stay), and
  one DRIVE transition between consecutive different stays (arrive-by noon).
- Chat can also create trips (add_trip) and journeys (add_journey).

Journeys (TravelSegment): flight or drive.
- Flight: departAt read on the ORIGIN clock. Leave-by = departure − airline
  cut-off (default 180 min) − security (30) − door-to-airport journey −
  buffer (20). The To field is the DEPARTURE AIRPORT and is never prefilled.
  Journey times over 6 h by road are refused for flights.
- Drive: arriveBy read on the DESTINATION clock. Leave-by = arrival − buffer
  − driving − stops. Stops stepper covers fuel/meals (no overnight-halt
  concept — known limitation).
- Journey time is measured against live traffic (Google), auto-measured when
  both ends are known; manual override only after failure/refusal.
- Zones auto-fill by geocoding the places; chains render each row on the
  clock it happens in, with date tags when a chain crosses midnight.
- A journey renders on its LEAVE-BY day only. Being en route on intermediate
  days has no representation (known limitation).
- Saving/measuring/chat-adding a journey grows the trip window to cover the
  journey's leave-by..arrival days (absorb), then deletes any stored plans on
  newly covered days.
- One "Leave in 30 minutes" notification per journey (only when a journey
  time exists; cancelled if the segment or trip is deleted).

Trips: editable start/end dates; deleting a trip removes its stays, journeys,
and their notifications. A trip must always cover its stays and journeys
(launch repair enforces growth, never shrink). Trips merge ONLY via an
explicit user command (clean_travel_data), only on strict interior overlap —
back-to-back trips sharing a boundary day are never merged.

Known-good reference behaviors to probe around (the edges live here):
- multi-stay trips and their auto-transitions
- trip windows vs stays created before/after the trip existed
- same-day handovers (return from one trip, leave for the next hours later)
- chained back-to-back trips
- timezone seams (Bhutan +6:00, Nepal +5:45, Bali +8:00 vs IST +5:30)
- re-syncing calendar events that changed (externalID update-in-place)
- deleting segments/trips mid-flow
- journeys with no measured time yet
- data minted by older builds meeting current code
