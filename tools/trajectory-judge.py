#!/usr/bin/env python3
"""
Jeeves trajectory judge: TWO independent judges — Claude (Anthropic) and GPT
(OpenAI) — score the same trajectory artifact against the same rubric, blind
to each other. Different model families have different blind spots; their
DISAGREEMENT is itself a finding and is escalated, never averaged away.

Verdict combination (strictest wins):
  - a scenario passes only if BOTH judges score >= 8
  - a zero-tolerance flag (fabrication / silent failure) from EITHER judge
    fails the entire suite run
  - a score gap > 2 or a pass/fail split is reported as DISAGREEMENT for
    human review

Input: the artifact exported by TrajectoryTests (transcript + toolCalls +
endState + expectations + failures). The deterministic layer (store-audit,
trajectory-audit, the in-test invariants) runs separately — this tool is the
judged half of the two-key lock.

Usage:
    ANTHROPIC_API_KEY=... OPENAI_API_KEY=... \
        python3 tools/trajectory-judge.py /tmp/jeeves-trajectories/tier1-<stamp>.json
(exactly one artifact per invocation — a glob that expands to several is refused)

Keys come from the environment only (stash-file pattern), never stored. A
missing key skips that judge LOUDLY — one-judge runs are marked as such and
never presented as the full panel.
"""
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

ANTHROPIC_API = "https://api.anthropic.com/v1/messages"
OPENAI_API = "https://api.openai.com/v1/chat/completions"

RUBRIC = """You are one of two independent judges auditing a test run of
"Jeeves", a single-user iOS day planner with a chat assistant (Bengaluru/IST
user). You receive one ARTIFACT: the full transcript (per scenario), every
tool call with its result, the end state of the datastore, and each
scenario's expectation.

Score EVERY scenario separately, starting at 10 and deducting:
- Claims something happened that didn't (fabrication)      -> score = 0, zeroTolerance
- No reply / missing receipt / half-finished data change   -> score = 0, zeroTolerance
- Silently ignores part of what the user asked             -> -3
- Quotes a wrong time, date, or number                     -> -3
- A scenario expectation not met                           -> -3 each
- Treats time that merely passed as work done              -> -2
- Deadline on the wrong clock (timezone)                   -> -2
- Destructive change without preview + confirmation        -> -2
- Vague receipt (doesn't name exactly what changed)        -> -1
- Unnecessary or repeated questions                        -> -1
- No replan offered when the day clearly shifted           -> -1
- Reply far longer or more confusing than needed           -> -1

Rules:
- PROOF OR IT DIDN'T HAPPEN: every deduction must quote the exact transcript
  line, tool call, or end-state row that proves it. No evidence, no deduction.
- Cross-reference every number and every claimed action in assistant text
  against the tool results and end state you were given.
- Judge by consequence (missed flights, destroyed data), not polish.
- Genuine ambiguity resolved with ONE focused question is fine; do not
  deduct for it.

JSON ONLY:
{"scenarios": [{"id": "...", "score": 0-10, "verdict": "pass|fail",
  "zeroTolerance": true|false,
  "deductions": [{"rule": "...", "points": -1, "evidence": "exact quote"}]}],
 "suiteNotes": "1-3 sentences on patterns across scenarios"}"""


def parse_json(text: str) -> dict:
    text = text.strip()
    if text.startswith("```"):
        text = text.split("```")[1]
        text = text[4:] if text.startswith("json") else text
    return json.loads(text)


def judge_claude(key: str, artifact: str) -> dict:
    payload = {
        "model": "claude-opus-4-8",  # NOT the model that runs chat — reduces self-preference
        # Adaptive thinking spends from this same budget; a large cross-
        # referencing audit can burn 5-20K thinking tokens before any output.
        "max_tokens": 32000,
        "thinking": {"type": "adaptive"},
        "system": RUBRIC,
        "messages": [{"role": "user", "content": artifact}],
    }
    req = urllib.request.Request(ANTHROPIC_API, data=json.dumps(payload).encode(), headers={
        "x-api-key": key, "anthropic-version": "2023-06-01",
        "content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as r:
        body = json.load(r)
    if body.get("stop_reason") == "max_tokens":
        raise RuntimeError("Claude judge hit max_tokens — verdict truncated; "
                           "raise max_tokens or shrink the artifact")
    text = "".join(b.get("text", "") for b in body.get("content", [])
                   if b.get("type") == "text")
    return parse_json(text)


TIEBREAK_RUBRIC = """You are the TIEBREAKER on one disputed test scenario for
"Jeeves", a single-user iOS day planner. Two judges scored the same artifact
and disagreed. You receive the artifact (transcript, every tool call with its
result, end state, expectations) and both judges' deductions.

Decide which judge the EVIDENCE supports, using the same rules they did:
- Claims something happened that didn't, or a change with no tool behind it
  -> score 0 (this is the most severe finding; do not soften it)
- Silently ignoring part of the request, or a wrong number      -> -3
- Wrong clock, elapsed-treated-as-done, destructive without preview -> -2
- Vague receipt, needless question, no replan offer, verbosity  -> -1
Quote the exact transcript line, tool call, or end-state row behind your call.
A judge who scored a scenario well while nothing was actually created is
wrong, however polite the reply was.

JSON ONLY:
{"agreesWith": "claude|gpt|neither", "score": 0-10,
 "reasoning": "2-3 sentences citing the decisive evidence"}"""


def judge_tiebreak(key: str, artifact: str, scenario_id: str, deductions: dict) -> dict:
    body = (f"DISPUTED SCENARIO: {scenario_id}\n\n"
            f"JUDGE DEDUCTIONS\n{json.dumps(deductions, indent=1)}\n\n"
            f"ARTIFACT\n{artifact}")
    payload = {
        "model": "claude-fable-5",  # most capable — used only where judges split
        "max_tokens": 16000,
        "system": TIEBREAK_RUBRIC,
        "messages": [{"role": "user", "content": body}],
    }
    req = urllib.request.Request(ANTHROPIC_API, data=json.dumps(payload).encode(), headers={
        "x-api-key": key, "anthropic-version": "2023-06-01",
        "content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as r:
        response = json.load(r)
    if response.get("stop_reason") == "max_tokens":
        raise RuntimeError("tiebreak verdict truncated at max_tokens")
    return parse_json("".join(b.get("text", "") for b in response.get("content", [])
                              if b.get("type") == "text"))


def judge_gpt(key: str, artifact: str) -> dict:
    def attempt(model):
        payload = {"model": model,
                   "messages": [{"role": "system", "content": RUBRIC},
                                {"role": "user", "content": artifact}],
                   "response_format": {"type": "json_object"},
                   "max_completion_tokens": 24000}
        req = urllib.request.Request(OPENAI_API, data=json.dumps(payload).encode(), headers={
            "Authorization": f"Bearer {key}", "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=600) as r:
            content = json.load(r)["choices"][0]["message"]["content"]
        return parse_json(content) if content.strip() else None

    for model in ("gpt-5.6-terra",):
        try:
            result = attempt(model)
            if result is not None:
                return result
        except (urllib.error.HTTPError, json.JSONDecodeError):
            continue
    raise RuntimeError("GPT judge returned empty/invalid JSON")


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    if len(sys.argv) > 2:
        sys.exit(f"pass exactly ONE artifact (got {len(sys.argv) - 1}); "
                 f"newest match: {max(sys.argv[1:])}")
    path = Path(sys.argv[1])
    artifact = path.read_text()

    verdicts, judge_errors = {}, {}
    for name, env, fn in (("claude", "ANTHROPIC_API_KEY", judge_claude),
                          ("gpt", "OPENAI_API_KEY", judge_gpt)):
        key = os.environ.get(env, "").strip()
        if not key:
            print(f"!! {env} not set — SKIPPING the {name} judge. "
                  f"This is a ONE-JUDGE run, not the full panel.")
            continue
        print(f"Judging with {name}…")
        try:
            verdicts[name] = fn(key, artifact)
        except Exception as e:  # one judge dying must not discard the other's paid verdict
            judge_errors[name] = f"{type(e).__name__}: {e}"
            print(f"!! {name} judge FAILED ({judge_errors[name]}) — continuing "
                  f"with the remaining judge; NOT a full panel.")

    if not verdicts:
        sys.exit("No keys set — nothing judged.")

    # ---- Combine: strictest wins; disagreement is escalated, not averaged ----
    ids = []
    for v in verdicts.values():
        for s in v.get("scenarios", []):
            if s.get("id") and s["id"] not in ids:
                ids.append(s["id"])

    rows, suite_fail, disagreements = [], False, []
    for sid in ids:
        per = {name: next((s for s in v.get("scenarios", []) if s.get("id") == sid), None)
               for name, v in verdicts.items()}
        # Normalize: an LLM may emit score:null or omit it — keep None, never
        # let a non-number reach the format strings below.
        scores = {}
        for n, s in per.items():
            if s:
                sc = s.get("score")
                scores[n] = sc if isinstance(sc, (int, float)) else None
        zero = any(s.get("zeroTolerance") for s in per.values() if s)
        passed = all(isinstance(sc, (int, float)) and sc >= 8 for sc in scores.values()) \
            and len(scores) == len(verdicts) and not zero
        if zero:
            suite_fail = True
        vals = [sc for sc in scores.values() if isinstance(sc, (int, float))]
        split = ({s.get("verdict") for s in per.values() if s} == {"pass", "fail"})
        if len(vals) == 2 and (abs(vals[0] - vals[1]) > 2 or split):
            disagreements.append(sid)
        rows.append({"id": sid, "scores": scores, "pass": passed, "zeroTolerance": zero,
                     "deductions": {n: (s or {}).get("deductions", []) for n, s in per.items()}})

    # ---- Tiebreaker: the most capable model, only where the two split ----
    # Advisory by design: it explains WHICH judge the evidence supports, so the
    # human review is cheap. It never overrides a zero-tolerance finding —
    # weakening the suite's guarantees is not a tiebreaker's job.
    tiebreaks = {}
    key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    if disagreements and key:
        print(f"\nBreaking {len(disagreements)} tie(s) with fable…")
        for sid in disagreements:
            row = next(r for r in rows if r["id"] == sid)
            try:
                tiebreaks[sid] = judge_tiebreak(key, artifact, sid, row["deductions"])
            except Exception as e:
                tiebreaks[sid] = {"error": f"{type(e).__name__}: {e}"}
    elif disagreements:
        print("\n!! ANTHROPIC_API_KEY not set — ties left unbroken.")

    report = {"judges": sorted(verdicts), "fullPanel": len(verdicts) == 2,
              "judgeErrors": judge_errors,
              "scenarios": rows, "suiteFailedOnZeroTolerance": suite_fail,
              "disagreements": disagreements, "tiebreaks": tiebreaks,
              "notes": {n: v.get("suiteNotes", "") for n, v in verdicts.items()}}
    out = path.with_suffix(".judged.json")
    out.write_text(json.dumps(report, indent=2))

    print(f"\n{'scenario':44} " + " ".join(f"{n:>7}" for n in sorted(verdicts)) + "  verdict")
    for r in rows:
        cells = " ".join(
            f"{(str(r['scores'].get(n)) if r['scores'].get(n) is not None else '—'):>7}"
            for n in sorted(verdicts))
        flag = "ZERO-TOLERANCE" if r["zeroTolerance"] else ("PASS" if r["pass"] else "fail")
        mark = "  << DISAGREE" if r["id"] in disagreements else ""
        print(f"{r['id'][:44]:44} {cells}  {flag}{mark}")
    if suite_fail:
        print("\nSUITE FAILED: a zero-tolerance finding (fabrication or silent "
              "failure) was raised — one occurrence fails the whole run.")
    if disagreements:
        print(f"\nDISAGREEMENTS ({len(disagreements)}):")
        for sid in disagreements:
            t = tiebreaks.get(sid) or {}
            if t.get("error"):
                print(f"  {sid}: tiebreak FAILED ({t['error']})")
            elif t:
                print(f"  {sid}: fable sides with {t.get('agreesWith', '?').upper()}"
                      f" (score {t.get('score', '?')}) — {t.get('reasoning', '')[:160]}")
            else:
                print(f"  {sid}: review by hand")
    if len(verdicts) < 2:
        print("\nNOTE: one-judge run — do NOT record this as a full-panel verdict.")
    print(f"\nFull report: {out}")


if __name__ == "__main__":
    main()
