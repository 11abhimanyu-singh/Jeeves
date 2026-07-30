#!/usr/bin/env python3
"""
Jeeves scenario eval: the JUDGE picks the scenarios, not the author.

The Bandipur transition bug survived two UX evals because the same person
wrote the code and chose the walkthrough scenarios — single-stay trips both
times, so the multi-stay branch was never shown to any judge. This tool
breaks that loop in two phases:

  generate  — GPT enumerates the scenario matrix for a feature: happy paths
              AND the edge cases where systems break (three back-to-back
              trips; landing from one trip 3 hours before the next starts;
              zone boundaries; sync-order races). Saved as scenarios.json.
  dialogues — GPT writes MULTI-TURN user scripts with personas: typos
              ("hime"), mid-flow corrections, bare "Sure" consents, repeated
              retries. These probe trajectory bugs — the class where one
              conversation minted three trips and six journeys — which
              single-shot scenarios cannot reach. Saved as dialogues.json.
  judge     — For each scenario, the author writes a FAITHFUL walkthrough of
              what the current build does (<scenarios-dir>/<id>.md); this
              phase has GPT verdict each one and writes a combined report
              covering EVERY scenario — including the ones with no
              walkthrough yet, which are reported as UNTESTED, never
              silently dropped.

Usage:
    OPENAI_API_KEY=... python3 tools/scenario-eval.py generate <feature-brief.md> <outdir>
    OPENAI_API_KEY=... python3 tools/scenario-eval.py judge <outdir>
"""
import json
import os
import sys
import urllib.request
from pathlib import Path

API = "https://api.openai.com/v1/chat/completions"

GENERATE_RUBRIC = """You design test scenarios for "Jeeves", a single-user iOS
day planner (Bengaluru/IST user). You are given a brief describing a feature
and what it is expected to do. The feature's AUTHOR will walk each scenario
through the real build — your job is to choose scenarios the author would not
have chosen, because authors test the paths they thought about.

Produce 8-14 scenarios: a few happy paths, and a MAJORITY of edge cases where
similar systems actually fail — boundary days, back-to-back and overlapping
instances, order-of-operations (created before/after related data existed),
timezone seams, zero/missing values, states left by older versions, actions
repeated twice, and deletions mid-flow. Prefer concrete Indian-context
examples (real cities, IST, plausible flight times).

JSON ONLY:
{"scenarios": [{"id":"kebab-case-slug","category":"happy|edge",
  "title":"...","setup":"exact starting state, step by step",
  "expected":"what a correct build must do","whyItBreaks":"the failure mode this probes"}]}"""

DIALOGUE_RUBRIC = """You design multi-turn TEST DIALOGUES for "Jeeves", a
single-user iOS day planner with a chat assistant (Bengaluru/IST user). You
receive a brief describing a feature. Real users iterate messily — and every
correction turn has historically been a chance for the assistant to create
duplicates, drop promised assumptions, or narrate numbers that differ from
what its tools stored.

Write 6-10 dialogues. Each is a SCRIPT of user turns only (the assistant's
replies are produced live when the dialogue is executed). Make them messy on
purpose: typos ("hime" for home), vague openers, mid-flow corrections
("actually leave at 9 instead"), bare consents ("Sure", "ok"), repeated
retries of the same request, topic switches mid-task, and requests phrased in
dates/ranges rather than titles.

For each dialogue also write the POST-CONDITIONS a correct system must
satisfy when the conversation ends — mechanical, store-checkable statements
("exactly one trip covers Aug 2", "exactly 2 journeys exist for that trip",
"every time quoted in the final summary appears in some tool result").

JSON ONLY:
{"dialogues": [{"id":"kebab-slug","persona":"one line",
  "turns":["user msg 1","user msg 2","..."],
  "postConditions":["...","..."]}]}"""

JUDGE_RUBRIC = """You are auditing one test scenario for "Jeeves", a personal
iOS planner. You get the scenario (setup + expected behavior) and a FAITHFUL
walkthrough of what the CURRENT build actually does — every field, default,
and outcome described really happens.

Verdict the scenario: does the build meet the expectation? Judge severity by
consequence (missed flights, destroyed data, wasted mornings), not polish.

JSON ONLY:
{"verdict":"pass|fail|partial","score":0-10,
 "gaps":[{"severity":"high|medium|low","issue":"...","fix":"..."}],
 "summary":"1-2 sentences"}"""


def call(key, system, user, max_tokens=24000):
    # Reasoning models spend from the same completion budget before emitting
    # content — an empty content string means the budget ran dry, not an
    # error, so treat it like a failure and fall back.
    def attempt(model):
        payload = {"model": model,
                   "messages": [{"role": "system", "content": system},
                                {"role": "user", "content": user}],
                   "response_format": {"type": "json_object"},
                   "max_completion_tokens": max_tokens}
        req = urllib.request.Request(API, data=json.dumps(payload).encode(), headers={
            "Authorization": f"Bearer {key}", "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=600) as r:
            content = json.load(r)["choices"][0]["message"]["content"]
        return json.loads(content) if content.strip() else None

    for model in ("gpt-5", "gpt-5-mini"):
        try:
            result = attempt(model)
            if result is not None:
                return result
        except (urllib.error.HTTPError, json.JSONDecodeError):
            continue
    sys.exit("Both models returned empty/invalid JSON — try again or raise max_tokens.")


def main() -> None:
    key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not key:
        sys.exit("Set OPENAI_API_KEY in the environment.")
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    mode = sys.argv[1]

    if mode == "dialogues":
        brief = Path(sys.argv[2]).read_text()
        outdir = Path(sys.argv[3])
        outdir.mkdir(parents=True, exist_ok=True)
        result = call(key, DIALOGUE_RUBRIC, brief)
        dialogues = result.get("dialogues", [])
        (outdir / "dialogues.json").write_text(json.dumps(result, indent=2))
        print(f"{len(dialogues)} dialogues → {outdir/'dialogues.json'}")
        for d in dialogues:
            print(f"  {d.get('id','')}: {len(d.get('turns',[]))} turns — {d.get('persona','')}")
        print("\nExecute each against the real chat (device or harness), export the"
              "\ntrajectory artifact, then run tools/trajectory-audit.py on it.")
        return

    if mode == "generate":
        brief = Path(sys.argv[2]).read_text()
        outdir = Path(sys.argv[3])
        outdir.mkdir(parents=True, exist_ok=True)
        result = call(key, GENERATE_RUBRIC, brief)
        scenarios = result.get("scenarios", [])
        (outdir / "scenarios.json").write_text(json.dumps(result, indent=2))
        print(f"{len(scenarios)} scenarios → {outdir/'scenarios.json'}")
        for s in scenarios:
            print(f"  [{s.get('category','?'):5}] {s.get('id','')}: {s.get('title','')}")
        print(f"\nNext: write a faithful walkthrough for each as {outdir}/<id>.md, "
              f"then run: scenario-eval.py judge {outdir}")
        return

    if mode == "judge":
        outdir = Path(sys.argv[2])
        scenarios = json.loads((outdir / "scenarios.json").read_text()).get("scenarios", [])
        report = {"results": [], "untested": []}
        for s in scenarios:
            walk = outdir / f"{s['id']}.md"
            if not walk.exists():
                report["untested"].append(s["id"])
                continue
            user = ("SCENARIO\n" + json.dumps(s, indent=1)
                    + "\n\nWALKTHROUGH OF THE CURRENT BUILD\n" + walk.read_text())
            verdict = call(key, JUDGE_RUBRIC, user, max_tokens=4000)
            report["results"].append({"id": s["id"], "category": s.get("category"),
                                      "title": s.get("title"), **verdict})
            print(f"[{verdict.get('verdict','?'):7}] {s['id']} — {verdict.get('score','?')}/10")
        (outdir / "report.json").write_text(json.dumps(report, indent=2))
        tested = report["results"]
        fails = [r for r in tested if r.get("verdict") == "fail"]
        partials = [r for r in tested if r.get("verdict") == "partial"]
        print(f"\n{len(tested)} judged: {len(tested)-len(fails)-len(partials)} pass, "
              f"{len(partials)} partial, {len(fails)} fail; "
              f"{len(report['untested'])} UNTESTED: {', '.join(report['untested']) or '-'}")
        print(f"Report: {outdir/'report.json'}")
        return

    sys.exit(f"Unknown mode '{mode}'")


if __name__ == "__main__":
    main()
