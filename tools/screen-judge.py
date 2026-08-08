#!/usr/bin/env python3
"""
Jeeves conformance judge: GPT grades the SHIPPED APP against the requirements.

WHY THIS IS DIFFERENT FROM ux-eval.py

`ux-eval.py` judges a walkthrough "reconstructed from the shipped code" — by
Claude. That can catch things built WRONG. It cannot catch things left OUT: a
screen nobody built produces no prose, so no judge ever sees a gap. Every eval
in this repo had that hole.

Here the evidence is the accessibility hierarchy captured off a running
simulator by tools/capture-evidence.sh. Nobody writes it. If a control was never
built it is simply not in the tree, and the judge is told in as many words that
absence IS the finding.

Usage:
    OPENAI_API_KEY=sk-... python3 tools/screen-judge.py <run-dir> [spec.md]
Writes <run-dir>/conformance.json and prints a table.
The key is read from the environment or the Keychain — never stored.
"""
import json
import os
import subprocess
import sys
import urllib.request
from pathlib import Path

API = "https://api.openai.com/v1/chat/completions"
MODEL = "gpt-5.6-terra"

RUBRIC = """You audit whether an iOS app ("Jeeves", a single-user personal
planner) actually contains what its owner asked for.

You are given (1) REQUIREMENTS, each with a stable id, and (2) EVIDENCE from a
running build, in THREE channels. Use whichever channel can actually carry the
requirement:

  SCREENS — an ordered walkthrough. Each step lists every accessibility element
    present as `role|label|value`. Elements rendered but scrolled out of view are
    prefixed `(offscreen)` and still EXIST. `reachable:false` means the
    walkthrough found nothing to tap for that step.

  TESTS — the app's unit suite, one line per test as `passed|failed
    Suite.testName`. Test names here are written as sentences describing the
    behaviour they pin. A PASSING test IS evidence that a rule is enforced, and
    for requirements about BEHAVIOUR rather than controls — "replanning accounts
    for elapsed time", "insert a break after 90 minutes" — it is the only
    evidence that can exist, because no screenshot can show a rule. Weigh it
    exactly as heavily as a visible control.

  NOTIFICATIONS — what the app actually scheduled and delivered on the device.
    A notification is not in the app's accessibility tree, so this channel is
    the ONLY way to see one. An entry here is proof it fires.

Rule that overrides your instinct to be generous:
THE EVIDENCE IS COMPLETE FOR WHAT IT COVERS. If a requirement describes a
control, and no element in ANY step plausibly corresponds to it, the verdict is
"absent". Do not assume it exists on a screen you were not shown. Do not credit
a requirement because the app "probably" has it somewhere.

Before answering "absent", check all three channels. A rule with a passing test
is present even if no screen shows it. A notification in the store is present
even though no screen contains it.

Only when a requirement concerns something NO channel covers should you answer
"unknown" — and then name the evidence you would need.

Verdicts:
  present  — a specific element (quote it) satisfies the requirement
  partial  — related elements exist but the requirement is not fully met; say what is missing
  absent   — nothing in the evidence corresponds to it
  unknown  — the relevant screen was never captured; name it

JSON ONLY:
{"verdicts": [{"id": "...", "verdict": "present|partial|absent|unknown",
               "evidenceSteps": ["step label", ...],
               "quote": "the element you matched, verbatim, or \\"\\"",
               "note": "one sentence"}],
 "summary": "2-3 sentences on what is missing overall"}"""


def keychain(service: str) -> str:
    try:
        return subprocess.run(["security", "find-generic-password", "-s", service, "-w"],
                              capture_output=True, text=True, check=True).stdout.strip()
    except Exception:                                  # noqa: BLE001
        return ""


def evidence_block(walk: dict, budget: int = 250_000) -> str:
    """Render the walkthrough for the judge.

    Two things this has to get right, both learned by getting them wrong:

    CHROME IS NOISE. "Menu", "Drag", the five tab buttons and the Jeeves title
    appear on all fifty-odd screens. Repeating them per step burned most of the
    budget on text that distinguishes nothing, so anything present on more than
    two-thirds of screens is listed ONCE up front.

    TRUNCATION IS A LIE IF IT IS SILENT — and it is nearly a lie even when it is
    not. At 60k the tail of a 54-step walk was dropped, and three requirements
    came back "unknown: the screen was omitted" for screens that had in fact been
    captured perfectly well. The budget is generous now, and anything still cut
    is named.
    """
    steps = walk["steps"]
    counts: dict[str, int] = {}
    for step in steps:
        for line in set(step.get("elements", [])):
            counts[line] = counts.get(line, 0) + 1
    threshold = max(2, int(len(steps) * 0.66))
    chrome = {line for line, n in counts.items() if n >= threshold}

    lines = []
    if chrome:
        lines.append("## CHROME — present on nearly every screen, listed once\n"
                     + "\n".join(sorted(chrome)) + "\n")

    used, dropped = 0, []
    for step in steps:
        head = (f'## step {step["index"]} — {step["label"]}'
                f'{" [UNREACHABLE]" if not step.get("reachable", True) else ""}'
                f'{" [screen did not change]" if not step.get("changed", True) else ""}')
        body = "\n".join(e for e in step.get("elements", []) if e not in chrome)
        chunk = f"{head}\n{body}\n"
        if used + len(chunk) > budget:
            dropped.append(step["label"])
            continue
        lines.append(chunk)
        used += len(chunk)
    if dropped:
        lines.append("## NOTE: these steps were omitted for length, treat their "
                     "screens as NOT CAPTURED: " + ", ".join(dropped))
    return "\n".join(lines)


def call_gpt(key: str, content: str) -> dict:
    payload = {
        "model": MODEL,
        "messages": [{"role": "system", "content": RUBRIC},
                     {"role": "user", "content": content}],
        "response_format": {"type": "json_object"},
        "max_completion_tokens": 16000,
    }
    req = urllib.request.Request(API, data=json.dumps(payload).encode(), headers={
        "Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as resp:
        body = json.loads(resp.read())
    return json.loads(body["choices"][0]["message"]["content"])


def main() -> None:
    key = os.environ.get("OPENAI_API_KEY", "").strip() or keychain("jeeves-openai")
    if not key:
        sys.exit("Set OPENAI_API_KEY, or store it in the Keychain as 'jeeves-openai'.")
    if len(sys.argv) < 2:
        sys.exit("Usage: screen-judge.py <run-dir> [spec.md]")

    run = Path(sys.argv[1])
    spec_path = Path(sys.argv[2]) if len(sys.argv) > 2 else run.parent.parent / "docs" / "SPEC.md"
    walk = json.loads((run / "walkthrough.json").read_text())
    if not spec_path.exists():
        sys.exit(f"No requirement register at {spec_path}")

    tests = walk.get("tests", [])
    notifications = walk.get("notifications", {})
    content = (
        f"# REQUIREMENTS\n\n{spec_path.read_text()}\n\n"
        f"# EVIDENCE — CHANNEL 1: SCREENS ({walk['stepCount']} steps)\n\n"
        f"{evidence_block(walk)}\n\n"
        f"# EVIDENCE — CHANNEL 2: TESTS ({len(tests)} in the suite)\n\n"
        + ("\n".join(tests) if tests else "(not captured)")
        + "\n\n# EVIDENCE — CHANNEL 3: NOTIFICATIONS scheduled/delivered on the device\n\n"
        + (json.dumps(notifications, indent=1) if notifications else "(not captured)"))

    verdict = call_gpt(key, content)
    (run / "conformance.json").write_text(json.dumps(verdict, indent=2))

    rows = verdict.get("verdicts", [])
    order = {"absent": 0, "partial": 1, "unknown": 2, "present": 3}
    rows.sort(key=lambda r: order.get(r.get("verdict"), 9))
    width = max((len(r.get("id", "")) for r in rows), default=4)
    for r in rows:
        print(f'{r.get("verdict","?"):8} {r.get("id",""):{width}}  {r.get("note","")[:88]}')
    counts = {v: sum(1 for r in rows if r.get("verdict") == v) for v in order}
    print(f"\n{counts}   → {run/'conformance.json'}")
    print(verdict.get("summary", ""))
    # Non-zero when something agreed is not in the app, so the daily pipeline
    # can treat it as a failure rather than a note.
    sys.exit(1 if counts.get("absent") or counts.get("partial") else 0)


if __name__ == "__main__":
    main()
