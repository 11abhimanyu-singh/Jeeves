# Requirement register — Claude's reading

Written from `docs/PRD.md`, the approved plan (`Rebuild what a day plan is`), and
the decisions taken in conversation. Deliberately kept as a SECOND opinion:
`tools/spec-extract.py` has GPT read the user's own messages independently, and
`tools/spec-diff.py` flags every requirement only one of us found.

That flag is the whole point. The −/+ duration control below was in an approved
plan and shipped missing; a register written only by the same author who dropped
it inherits the same blind spot.

## chat

- **CHAT-01** — The morning offer lands in Jeeves chat as a card, not a separate screen.
- **CHAT-02** — Each row can be ticked (doing it today) or unticked (not today).
- **CHAT-03** — Each row has a delete control that removes it from today's list entirely.
- **CHAT-04** — Each row's duration can be adjusted in 15-minute steps, for today only, without changing the routine's default.
- **CHAT-05** — The card shows a running total of what is picked against what is free.
- **CHAT-06** — Anything with a real time — the gym — is confirmed on the card before planning.
- **CHAT-07** — Jeeves plans only after the user confirms; nothing is planned on their behalf first.
- **CHAT-08** — A day already planned can be re-picked; the card is reachable again on demand.

## notifications

- **NOTIF-01** — A notification fires at 07:00 naming how many activities are due.
- **NOTIF-02** — Tapping it opens chat with the list already posted.
- **NOTIF-03** — A day with nothing due produces no notification at all.
- **NOTIF-04** — A day started after 07:00 still gets its offer, at most once.
- **NOTIF-05** — A day covered by a trip gets no offer.
- **NOTIF-06** — Nothing commits a plan the user did not choose; there is no overnight auto-planner.

## planner

- **PLAN-01** — No activity block is scheduled below the 30-minute floor; time is left open instead.
- **PLAN-02** — No invented filler: no "Breather", no "Slack" block.
- **PLAN-03** — Sleep renders as a real clock time, never past 24:00.
- **PLAN-04** — Work never runs more than 90 continuous minutes without a 10-minute break.
- **PLAN-05** — Lunch counts as the break; no extra break is inserted around it.
- **PLAN-06** — Planning part-way through a day plans the rest of it, not a fresh full day.
- **PLAN-07** — An offline plan is marked as offline, persistently, on the plan itself.
- **PLAN-08** — Shortened activities are reported as shortened, not silently trimmed.

## routine

- **ROUTINE-01** — Each activity can be set to specific weekdays.
- **ROUTINE-02** — An empty weekday set means every day.
- **ROUTINE-03** — An explicit per-day tick outranks the weekday cadence.
- **ROUTINE-04** — A switched-off activity is never offered, however it is ticked.
- **ROUTINE-05** — Each activity's default duration is editable.

## tasks

- **TASK-01** — Reminders support Once, Daily, Weekdays, Weekly and Every X days.
- **TASK-02** — Weekly asks which weekday rather than inferring it from creation time.
- **TASK-03** — A one-off reminder can be given any date, not only today.

## adherence

- **ADHERE-01** — Work skipped on a past day is offered as a task, a reminder, or dropped.
- **ADHERE-02** — A block the app never asked about is recorded as unknown, not skipped.
- **ADHERE-03** — Adherence is never shown as a rate without its denominator.
