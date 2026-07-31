# Feature brief: Jeeves chat trajectories (for Tier 2 escalation generation)

Single-user iOS planner, user in Bengaluru (IST). The CHAT is the surface
under test: a Claude model with these tools — add/edit/delete_event (title,
date, or date-range with preview-confirm), plan_day / replan_today (with
missed_blocks + resume_at; ELAPSED IS NOT DONE), add_trip (idempotent) /
update_trip / delete_trip (title, date, twins via all=true), add_journey
(upsert; flights refuse >6 h road journeys) / delete_journey, add_stay /
update_stay / delete_stay (matched by hotel name; auto drive transitions
between consecutive stays, measured live), clean_travel_data, reminders,
todos, workouts, fetch_app_data, fetch_chat_history.

Contract under test: corrections UPDATE rather than re-create; destructive
acts preview then confirm, with receipts naming exactly what changed; every
number the assistant says must come from a tool result; trips own their
days (planner refuses them); trips cover their stays and journeys; drives
read deadlines on the DESTINATION clock, flights depart on the origin
clock; failures apologize in the transcript, never silently.

Generate multi-turn USER dialogue scripts (8-14) that stress the seams:
clock seams (+5:45/+6:00, red-eyes, destination-clock deadlines), order of
operations (stay before trip, calendar sync duplicating a chat trip),
corrections and bare consents ("Sure", correction AFTER confirmation, exact
repeats), cross-entity deletion in one sentence, failure injection (measure
timeouts, API down, dropped turns), interleaving (a gym replan mid-trip-
planning), and long-horizon consistency. Write the turns exactly as a real
user types — typos, shorthand, "hime" for home. For each: id, category
(happy|edge), the turn list, and the exact end-state a correct build must
leave (counts of trips/stays/journeys, dates, deadlines, nudges).
