# Jeeves permanent test plan

Three layers, run in this order. A release is clean only when all three are.

## 1. Deterministic (free, every run)

```bash
xcodebuild test -project Jeeves.xcodeproj -scheme Jeeves \
  -destination 'platform=iOS Simulator,name=iPhone 17'   # 400+ unit tests
python3 tools/diagnose.py <workdir> --pull               # store-audit + trajectory-audit
```

- **store-audit**: every invariant over every row, all history, no date
  limits. Failures block; warnings inform.
- **trajectory-audit**: story vs state over every chat session — duplicate
  legs/trips, numbers not traceable to tool results, claimed actions absent
  from the store, unanswered turns, self-date confusion.

## 2. Chat trajectories (`tools/scenarios-chat/dialogues.json`)

**Tier 1 — the regression floor.** Eight dialogues run VERBATIM on the
device (type each user turn into Jeeves chat). They cover: event creation +
destination, mid-event and mid-commute extension, a timezone trip with both
flight legs, the international→Mysore→Wayanad back-to-back chain with hotel
stays, trip date modification, rerouting a leg, and modification by date /
location / hotel name. Expected end-state per dialogue is in the JSON.

**Tier 2 — escalations, regenerated per run.** GPT generates variants along
the seven seam axes (clock seams, order of operations, corrections/consent,
cross-entity deletion, failure injection, interleaving, long horizon):

```bash
OPENAI_API_KEY=... python3 tools/scenario-eval.py generate \
  tools/briefs/chat-trajectories.md <outdir>
```

Never hand-pick the escalations — the judge chooses seams authors don't.

**Tier 3 — chaos.** A Tier 1 dialogue with injected failure: airplane mode
mid-conversation, app backgrounded mid-tool-call, simultaneous watch
delivery. Pass = receipts or honest apologies; fail = silence, duplicates,
or claims without store changes.

**Verdicting any run:** pull the store, then

```bash
python3 tools/trajectory-audit.py <store>          # deterministic
OPENAI_API_KEY=... python3 tools/scenario-eval.py judge <outdir>   # story vs state
```

A scenario passes only when BOTH agree.

## 3. Judged quality (needs OPENAI_API_KEY)

- `coherence-eval.py` over the full dump — hunts unknown unknowns, proposes
  new invariants; sound proposals graduate into store-audit.py.
- `plan-eval.py` over ALL stored plans; `ux-eval.py` over faithful
  walkthroughs; travel scenario matrix via `scenario-eval.py`.

## Standing rules

- Every hardcoded default gets a pure, tested helper (JourneyPrefill rule).
- Launch repairs are growth-only; destruction is user-invoked with receipts.
- Every tool call is event-logged; every anomaly is surfaced, never silently
  healed — the user designs fixes from what the digest shows.
- New invariants come from the third party; deterministic code enforces them
  forever.
