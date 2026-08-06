# Benchmark Anthropic vs OpenAI on real planning days

## Context

Two open questions converge on the same experiment.

1. **A fallback provider was requested** — "in case Anthropic doesn't respond." The
   diagnostics say that has never been observed: since real error reporting landed on
   1 Aug, 14 of 14 failures were client-side transport (`connection lost` ×10,
   `timed out` ×4), not one HTTP 401/429/529. A fallback is outage insurance, not a fix
   for the measured problem.
2. **The planner model changed today** without evaluation — `claude-opus-5` then
   `claude-fable-5` (commits `e27867e`, `96b119f`, both by the parallel session). Fable
   has thinking always on. The 53-second median I measured **predates the switch**, so
   nobody knows what the planner currently costs in latency.

Before writing any fallback, measure. The outcome decides both questions: whether OpenAI
is a viable second provider at all, and what Fable 5 is actually costing.

**Honest constraint, established up front:** `ZPLANGENERATIONLOG` stores only
`startedAt / durationMs / commuteMs / claudeMs / retryCount / outcome / errorClass /
trigger`. **No prompts, no request bodies, no responses.** The historical calls cannot be
replayed. This reconstructs equivalent requests from the stored day state, which is
better for comparison anyway — identical inputs to both providers, repeatable.

## Approach

A live eval test, following the existing `JeevesTests/PlanEval.swift` precedent
(`XCTSkipUnless(KeychainService.hasAPIKey)`, real network, not part of the normal suite).

For each of the **12 distinct days** that have a stored plan in the last 7 days:

1. Rebuild a `PlanRequest` from the store — events (`DailyEvent`), gym flag and minute
   (`DailyPlanState`), routine (`RoutineActivity` + per-day `activitySelection`), saved
   locations, prep sessions. Reuse `PlanCoordinator.buildRequest`, with commute
   estimates **stubbed to fixed values** so both providers see byte-identical prompts and
   Maps latency (measured at 0 s) stays out of the numbers.
2. Generate the prompt once per day via the existing provider-agnostic
   `PlanGenerationService.planningRules(hasEvents:)` and `.userPrompt(_:)`.
3. Send that same prompt to both providers, sequentially, timing each.
4. Decode both with the shared `PlanGenerationService.decodePlan(from:)`.
5. Score both with `PlanValidation.severe(_:request:)`.

### Measure validity, not just latency

Latency alone would mislead. 28–45% of Claude plans currently need a **repair
round-trip** — a second full generation because the first broke a rule. A provider that
answers in 20 s but fails validation costs two calls, so it is slower *and* worse. The
comparison must report, per provider:

- **wall-clock seconds** (median, min, max across the 12 days)
- **valid first time** — `PlanValidation.severe` empty
- **violation kinds** when not, reusing `PlanDiagnostics.violationKinds`
- **decode failures** — returned something that wasn't a plan at all

The decision metric is *effective latency*: median time × (1 + first-pass failure rate).

## Files

**New — `JeevesTests/ProviderBenchmark.swift`**
The whole benchmark. Modelled on `PlanEval.swift` (which already does live generation +
judging and is excluded from routine runs by its key guard).

**New — `Jeeves/OpenAIPlanService.swift`**
An OpenAI transport for the plan contract, structurally parallel to
`OpenAIJudgeService.swift` (`https://api.openai.com/v1/chat/completions`,
`Authorization: Bearer`, `response_format: {"type":"json_object"}`, request built inline).
Differences from the judge: model `gpt-5.6-terra` (the identifier already proven in
`tools/plan-eval.py:24`), and the system/user split takes `planningRules` and `userPrompt`
verbatim.

Keep the parse pure and separate, exactly as `OpenAIJudgeService.parse(_:)` is — envelope
unwrap (`choices[0].message.content`) then hand off to the shared
`PlanGenerationService.decodePlan(from:)`. Do **not** duplicate fence-stripping;
`extractJSONObject` already handles it.

**Modified — none in the app's live path.** This adds no fallback yet and changes no
behaviour. Whether to wire `OpenAIPlanService` into `PlanCoordinator`'s catch is a
*separate* decision, taken on the numbers.

## Reuse (already exists — do not rewrite)

- `PlanGenerationService.planningRules(hasEvents:)` and `.userPrompt(_:)` — plain text,
  no Anthropic structure, usable as-is for both providers
- `PlanGenerationService.decodePlan(from:)` / `extractJSONObject` — fully
  provider-agnostic, strips ```json fences
- `PlanValidation.severe(_:request:)` — provider-agnostic scoring
- `PlanDiagnostics.violationKinds(_:)` — the slug reducer added earlier today
- `OpenAIJudgeService.swift` — the request/parse shape to copy
- `PlanCoordinator.buildRequest(_:)` — request assembly
- `JeevesTests/PlanEval.swift` — the live-eval harness pattern and key guard

## Cost and prerequisites — read before approving

- **API keys must be in the simulator Keychain.** Neither is there now; that is why 11
  tests skip. Anthropic via Library → Settings, OpenAI via the existing OpenAI key row.
  I cannot enter these — they are yours to type.
- **~24 live generations** (12 days × 2 providers). At the observed ~53 s median that is
  roughly 20 minutes of wall clock, and real money on both accounts — Fable 5 is the
  most expensive Anthropic tier.
- **Single sample per day per provider.** Enough to see a large latency difference; not
  enough to rank two providers that land within ~20% of each other. If the result is
  close, it needs repeats before it means anything.

## Verification

1. `xcodebuild test -only-testing:JeevesTests/ProviderBenchmark` with both keys present.
2. Assert the harness itself is sound before trusting the numbers: both providers
   received the **same** prompt string (assert equality), and every timing is non-zero.
3. Output a table to the test log and write it to the scratchpad: day, provider, seconds,
   valid-first-time, violation kinds.
4. Sanity-check one Anthropic row against the device log's ~53 s median — if the
   benchmark says 8 s, the harness is measuring the wrong thing, not the API being fast.
5. The normal suite must still pass and still skip these without keys (764 tests).
