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

## Autonomous execution (no human)

The Tier 1 dialogues also run WITHOUT the device or a human typist:
`JeevesTests/TrajectoryTests` plays every dialogue against the real chat
model + the real tool executor (`ChatToolExecutor`) on an in-memory store,
asserts the deterministic invariants at end state, and exports a full
artifact (transcript + every tool call + end state + expectations) for
judging.

```bash
tools/run-trajectories.sh /path/to/.anthropic_key   # key from a user stash file, env-only
ANTHROPIC_API_KEY=... OPENAI_API_KEY=... \
  python3 tools/trajectory-judge.py <artifact>.json  # the judged half
```

`trajectory-judge.py` runs TWO independent judges — Claude (opus, not the
model that runs chat) and GPT — on the same artifact, blind to each other.
Strictest verdict wins: a scenario passes only if both score ≥ 8; one
zero-tolerance finding (fabrication or silent failure) from either judge
fails the whole suite; disagreements are escalated for human review, never
averaged. Real device logs are judged the same way — `tools/logs-to-artifact.py
<store> <out.json>` packages real sessions into the same artifact shape
(no scripted expectations; judges grade against the universal rubric).

## Acceptance criteria layer

`docs/acceptance-regression.md` (third-party authored) holds explicit pass
criteria per scenario plus meta-criteria — idempotent replay, audits green
after each scenario, honest incomplete state, relaunch survival — and five
additional suites (conversation safety, planner failure injection,
tasks/preferences, fitness/Watch sync, voice/library/resilience). Judges use
it as a rubric source; known-fails it exposes go to the backlog, never
silently dropped.

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
