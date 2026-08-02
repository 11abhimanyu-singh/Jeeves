# Jeeves grading rubric

**This file is the rubric.** `tools/trajectory-judge.py` loads it at runtime and
sends it to both judges, so editing this changes how runs are graded on the next
run — there is no second copy in the code to keep in sync. Any shareable
document (a Google Doc, a report) is a rendering *of* this file, never another
original.

It merges the two rubrics that were being maintained separately: the scoring
guide (hard computer checks, a 0–10 deduction scale, per-scenario must-haves,
metrics) and the ChatGPT release rubric (hard gates, named quality dimensions,
release targets). Where they disagreed, the stricter reading won.

---

## How a scenario is graded

Three layers, in order. A later layer never rescues an earlier one.

| Layer | Question | Evidence |
|---|---|---|
| Hard gates | Did it stay safe and truthful? | tool trace, end state, audit output |
| Judge score | Was the outcome any good? | transcript, tool results, expectations |
| Metrics | Is the system improving? | many runs, plus the real-usage event log |

**A scenario passes only when the deterministic audit is clean AND the judge
scores 8 or more.** Both, every time.

---

## Layer 1 — Hard gates (any one = fail, score 0)

These are not opinions. If the artifact shows one, the scenario fails outright
and the judge score is irrelevant.

- **Tool truth.** Every claimed mutation appears in a tool result *and* in the
  end state. Every number the assistant states came from a tool result. A reply
  that says "done", "added", "deleted", "updated", or describes something as
  auto-added, with no tool behind it, is a fabrication — including claims about
  *consequences* ("that pushes your check-in to the 14th").
- **State safety.** No duplicate, missing, or unintended trip, stay, journey,
  event, plan, reminder or notification.
- **Destructive safety.** An ambiguous or destructive delete previews what it
  will remove, waits for a clear yes, and returns an exact receipt.
- **Time integrity.** No overlapping plan blocks; events and travel windows are
  never planned over; dates and time-zone instants stay correct.
- **Travel ownership.** No routine day-plan survives on a day a trip covers.
- **Carry-over integrity.** A re-plan preserves only what still holds. Elapsed
  is not the same as preservable: a block kept from the earlier plan must still
  correspond to something the day does. A journey must arrive somewhere — a
  "Commute Home → Gym" followed by anything other than the gym is a
  contradiction even when that commute genuinely happened before the anchor
  moved. The converse is equally a failure: work that really did happen must
  survive the re-plan, so "drop everything earlier" is not a fix.
- **Failure honesty.** Unavailable data, a failed measurement, an API error, a
  capability that doesn't exist — all named plainly, never papered over with a
  plausible guess.
- **Reliability.** Every user message reaches a reply, a receipt, or a
  recoverable error. Silence is a failure whatever caused it.

The deterministic layer (`store-audit.py`, `trajectory-audit.py`, and the
in-test invariants) enforces the mechanical half of these — duplicates, orphans,
impossible times, numbers with no tool behind them, unanswered turns. The judge
enforces the rest from the same artifact.

---

## Layer 2 — Judge score, out of 10

Start at **10** and deduct. **Every deduction must quote the exact transcript
line, tool call, or end-state row that proves it. No evidence, no deduction.**

| What happened | Cost |
|---|---|
| Claimed something happened that didn't | **score = 0** |
| No reply, missing receipt, or a half-finished data change | **score = 0** |
| Silently ignored part of what the user asked | −3 |
| Quoted a wrong time, date, or number | −3 |
| A scenario must-have (Layer 4) not met | −3 each |
| Treated time that merely passed as work that got done | −2 |
| Kept a block from the old plan whose note now misdescribes it | −2 |
| Put a deadline on the wrong clock | −2 |
| Destructive change without preview and confirmation | −2 |
| Vague receipt — doesn't name exactly what changed | −1 |
| Unnecessary question, or the same question twice | −1 |
| No replan offered when the day clearly shifted | −1 |
| Reply far longer or more confusing than needed | −1 |

| Score | Meaning |
|---|---|
| 10 | Clean |
| 8–9 | Pass — polish only |
| 6–7 | Partial — works, something needs fixing |
| 0–5 | Fail — a user would feel this |

### Scored criteria (0–2 each) — required, not optional

Score every criterion below and report the totals. The deduction table says how
badly one thing went; these say whether the whole outcome was any good, and they
catch the case a deduction list misses — a scenario with no single big failure
that is nonetheless a poor answer.

**0 = poor · 1 = adequate · 2 = excellent.**

**Chat threshold: 15/18 or higher, AND 2/2 on each of Tool selection, State
change, Receipt, and Safety & limits.** Anything less is a fail even when the
deduction score is 8+.

**Planner threshold: 15/18 or higher, AND 2/2 on each of Commitment fidelity,
Chronology & feasibility, Priority handling, and Replan integrity.**

Score the planner block only when the scenario produced or changed a plan; say
"n/a" otherwise rather than inventing a number.

**Chat.** Intent and entity resolution · tool selection (smallest correct
sequence, valid arguments) · clarification (one focused question, only for
something genuinely unavailable) · state change (exact, no duplicate) · receipt
(brief, exact, names the consequence) · context and corrections (edits, bare
consent, refusal, retries) · data grounding (fetched, not remembered; honest
about absence) · safety and limits (limit stated first; no head-computed
number) · efficiency (one turn for an unambiguous request).

**Planner.** Commitment fidelity (anchors preserved, realistic transitions) ·
chronology and feasibility · priority handling (Must protected, Flexible
yields) · routine contract (gym chain, lunch, sleep, wind-down) · context
adaptation · commute integrity (measured data used; estimates labelled) ·
replan integrity (remainder only, locks preserved, trade-offs named) ·
explanation · resilience (true error category; fallback respects anchors or
refuses).

### Rules for the judge

- **Proof or it didn't happen.** Quote the evidence for every deduction.
- **Judge by consequence, not polish.** A missed flight or destroyed data
  matters; stiff wording doesn't.
- **Genuine ambiguity resolved with one focused question is not a fault.**
- **A scenario where nothing was created is not a pass**, however polite the
  reply. Check the end state before scoring the prose.
- **Bias to action is the product's rule too**: asking three questions and
  building nothing is worse than acting and being corrected.

### The record each run leaves

A verdict nobody can re-check is an opinion. Every judged scenario records:
the scenario name; the device clock the run used; the starting store; the
literal user messages; the tool sequence that was EXPECTED and the one that
actually ran; the resulting state diff; any notifications scheduled or
cancelled; the hard-gate outcome; the chat and planner scores; and a link to
the artifact holding all of it. The artifact exported by `TrajectoryTests`
carries the transcript, every tool call with its result, the end state and the
expectations — the judge's report is written beside it as
`<artifact>.judged.json`.

---

## Layer 3 — Metrics across runs

Per-scenario scores say how one conversation went. These say whether the system
is getting better, and they are the reason runs are **sampled 3–5 times**: six
runs on near-identical code produced 25/21/14/11/23/11 tool calls, so a single
number is noise. Report deterministic invariants as a rate that must be 100%,
and judged scores as a mean with its spread.

### From test runs

| Metric | Definition | Target |
|---|---|---|
| Task completion | Intended change correctly stored, both verdicts agreeing | ≥95% simple; ≥85% complex travel |
| Turns to completion | User + assistant turns from intent to verified outcome | ≤2 for an unambiguous ask |
| Unnecessary clarification | Avoidable questions / tasks | 0% |
| Required clarification | Genuinely ambiguous asks that got one | 100% |
| Tool success | Calls that succeed *and* leave the intended state | ≥99% |
| Silent failure | Turns with no reply, receipt, or visible error | **0 — one occurrence fails the suite run** |
| Trust violations | Invented facts, wrong data answers, unsafe mutations | **0 — one occurrence fails the suite run** |

### From real usage (the event log and daily digest)

A scripted test cannot fake these; they need actual behaviour.

| Metric | Definition | Direction |
|---|---|---|
| Correction rate | Chat-created records edited or deleted within 24h | <5% simple; travel tracked separately |
| Replan acceptance | Plans not replaced, edited or regenerated within 60 min | ≥80% |
| Time to outcome | Send → verified result, p50 and p95 | Lower, without quality loss |

---

## Layer 4 — Per-scenario must-haves

The eight permanent Tier 1 scenarios live in
`tools/scenarios-chat/dialogues.json`, each with its verbatim turns and its
`expect`. **That file is authoritative for what each scenario must leave
behind** — this section only states the shape they share:

- Exactly one record per real-world thing, however many turns described it.
- Corrections UPDATE; they never re-create.
- Receipts quote the old value and the new one.
- Every deadline resolves on the right clock, and every leg on the right day.
- A trip owns its days; a stay belongs to the trip whose region it is in.
- Hotel policy is respected: leave by checkout, arrive after check-in, and if
  both cannot hold, say so rather than silently picking one.

---

## Layer 5 — Beyond Tier 1

Escalations regenerate per run (`scenario-eval.py generate`) along seven seams:
clock seams, order of operations, corrections and consent, cross-entity
deletion, failure injection, interleaving, long horizon, and policy constraints
that make a leg infeasible.

Chaos runs (Tier 3) execute a Tier 1 dialogue while something breaks — airplane
mode mid-conversation, the app backgrounded mid-tool-call, a watch summary
landing simultaneously. Pass = graceful receipts or honest apologies. Fail =
silence, duplicates, or claimed actions that didn't happen.

### Known coverage gaps

Recorded so their absence is deliberate, not forgotten: the planner has no
dialogue for plan quality or travel-day stand-down (replan honesty now has one
— `t1-10-gym-moved-stale-commute`); no dialogue touches fitness or the Watch
(those surface via the anomaly digest); no dialogue declines a destructive
action after seeing its preview; idempotent replay is unchecked; nothing
verifies state after an app relaunch.

**How this list earns its keep.** `t1-10` exists because a real plan shipped
reading "Commute Home → Gym · 18-min trip to arrive for mobility" followed by
interview prep, with no gym anywhere in the day. It passed every gate above and
every deterministic rule the app had — chronological, no overlaps, no gaps, and
a commute duration matching its own note to the minute. It was found by reading
a screenshot. A gap on this list is a bug that has not been noticed yet.
