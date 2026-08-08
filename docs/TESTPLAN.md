# Jeeves permanent test plan

Four layers, run in this order. A release is clean only when all four are.

Layers 1–3 ask whether the app is HEALTHY. Layer 4 asks whether it is COMPLETE,
which no other layer can: every judge in layers 2–3 grades an artifact Claude
wrote, so a requirement that was agreed and never built produces no artifact and
no finding. Layer 4 grades machine-captured evidence against a register
extracted from the user's own messages.

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

## 1b. Conformance — did we build what was agreed? (weekly)

```bash
tools/capture-evidence.sh                       # ~8 min, unattended, no key
python3 tools/spec-extract.py --days 7          # GPT reads the user's own messages
python3 tools/spec-diff.py                      # merge with docs/SPEC.claude.md
python3 tools/screen-judge.py evidence/<run>    # exits non-zero on a real gap
```

- **capture-evidence.sh** erases a simulator, walks the app under
  `JeevesUITests`, and records THREE channels: the accessibility hierarchy plus
  a PNG per screen, the unit suite's pass/fail lines, and the notification store.
  Three channels because most requirements cannot be seen in one — a rule is
  only visible in a test, a notification only in the daemon's store.
- **The register is written twice.** `SPEC.claude.md` by hand;
  `SPEC.gpt.md` by GPT from the transcripts; `spec-diff.py` merges them and
  marks every ONE-SIDED entry. On its first run that flag caught nine
  requirements the hand-written register had dropped.
- **A step never fails the walk.** An unreachable screen records
  `reachable:false` and the walk continues, because losing forty-five screens to
  one missing control is how you end up with no evidence at all.

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
