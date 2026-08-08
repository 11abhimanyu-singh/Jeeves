#!/usr/bin/env python3
"""
The pass that looks at the pixels.

WHY THIS EXISTS, AND WHY IT IS SPLIT IN TWO

Two classes of defect never reach the conformance judge, because an
accessibility tree cannot carry either of them: a button whose label has WRAPPED
looks identical in the tree to one that fits, and text at 4.18:1 looks identical
to text at 11:1. Both have shipped in this app and both were caught by eye.

The temptation is to hand the screenshots to a model and ask "any contrast
problems?". Don't. Contrast is a NUMBER — WCAG 2.2 defines it exactly — and a
model asked to eyeball it will produce confident guesses that are unfalsifiable
and often wrong. Guessing at contrast is how a grep-and-hope sweep of 60 call
sites gets justified.

So:

  MEASURED   every text/background pairing in the palette, computed from the
             source of truth in ContentView.swift. Arithmetic, not opinion.
             Says which pairings are unsafe and by how much.

  OBSERVED   sampled from the actual PNGs: the real foreground and background
             colours a screen used, and their real ratio. Says which unsafe
             pairings are ACTUALLY ON SCREEN, and where — which is the question
             a grep cannot answer, because in SwiftUI `.background(...)` comes
             after the content it decorates.

  JUDGED     a vision pass, asked ONLY for what vision is good at: wrapped
             labels, clipped text, cramped controls, overlap. Never for a ratio.

Usage:
    OPENAI_API_KEY=sk-... python3 tools/visual-judge.py <run-dir> [--no-model]
Writes <run-dir>/visual.json.
"""
import argparse
import base64
import io
import json
import os
import re
import subprocess
import sys
import urllib.request
from collections import Counter
from pathlib import Path

from PIL import Image

API = "https://api.openai.com/v1/chat/completions"
MODEL = "gpt-5.6-terra"
REPO = Path(__file__).resolve().parent.parent

# WCAG 2.2: 4.5:1 for body text, 3:1 for text at 18.66px+bold or 24px+.
AA_SMALL = 4.5
AA_LARGE = 3.0

RUBRIC = """You are looking at screenshots of an iOS app to find layout defects
a screen reader cannot detect.

Report ONLY what you can see in the image:
  - a control's label that has WRAPPED onto two lines when it plainly should not
    have, or is clipped/truncated mid-word
  - text running outside its container, overlapping another element, or cut off
    at an edge
  - anything visibly misaligned or overlapping

DO NOT report colour contrast, and DO NOT report the SIZE of anything. Both are
measured separately and exactly — from the palette and from the accessibility
frames. An eyeballed ratio or an eyeballed pixel count is worse than none, and
these images have been downscaled, so any size you infer from them is wrong.
DO NOT report taste — spacing you would have chosen differently, wording, or
visual hierarchy. Only defects.

DO NOT report SCROLL POSITION. These screens are photographs of a scrolling app
taken mid-scroll, and every one of them has content crossing a boundary as a
result. None of the following is a defect:
  - text meeting the TOP edge, sliced by the fixed header above it
  - text meeting the BOTTOM edge, sliced by the tab bar below it
  - a row or card that simply runs past the top or bottom of the screen
  - the round orange button in the bottom-right corner sitting over whatever
    happens to be scrolled beneath it — it floats over content by design
Scroll the screen in your mind: if one swipe would reveal the rest of that text
intact, it is scroll position and you must not report it.

A real clip is text cut off INSIDE its own row or card while that row still has
visible empty space, with NO ellipsis marking it.

Three more things that look like defects and are not. Each of these was reported
against this app and each was wrong:

  - AN ELLIPSIS IS NOT A CLIP. "245 min · Genuinely open — Product Sens…" is the
    app choosing one line and saying so, with the rest one tap away. A defect is
    text that stops mid-glyph having promised nothing. If you can see "…", it is
    not a finding.

  - WRAPPING AT A WORD BOUNDARY IS NOT A DEFECT. "Renew / passport" is a label
    that needed two lines and took them. Report a wrap only when a WORD is
    broken across the two lines — "Photograph / y" — which no correct layout
    ever produces.

  - A HORIZONTALLY SCROLLING STRIP MAY SHOW A PARTIAL ITEM AT ITS TRAILING EDGE.
    A ROW of similar items — chips, pills, date cells — running to the screen
    edge with one sliced in half is a strip you swipe, and the half-visible item
    is the cue that there are more. The app has several: chat's suggestion
    chips, the planner's date dial, the filter chips. Judge the PATTERN, not the
    list — this rule named only the chat chips once and the identical date dial
    was reported three times in one run.
    A single label cut at the right edge with no siblings beside it is different,
    and is still a finding.

The test for all of these is the same one: name what the user loses. If they lose
nothing — the text is marked, or complete on the next line, or one swipe away —
it is not a finding.
If a screen looks fine, say so and move on. An empty findings list is a valid
and common answer.

For each finding quote the exact text you can read in the image, so it can be
found again.

JSON ONLY:
{"findings":[{"step":"<the step label given with the image>",
              "kind":"wrapped|clipped|overlap|misaligned",
              "text":"the visible text, verbatim",
              "what":"one sentence"}]}"""


# ─── measured ────────────────────────────────────────────────────────────────

def luminance(rgb: tuple[int, int, int]) -> float:
    def channel(v: float) -> float:
        v /= 255
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (channel(c) for c in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def ratio(a: tuple[int, int, int], b: tuple[int, int, int]) -> float:
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return round((hi + 0.05) / (lo + 0.05), 2)


def palette() -> dict[str, tuple[int, int, int]]:
    """Read the app's own colour tokens rather than restating them here.

    A copy of the palette in this file would drift from the app's the first time
    someone darkened a token, and the tool would then be measuring a colour the
    app no longer uses.
    """
    src = (REPO / "Jeeves" / "ContentView.swift").read_text()
    out = {}
    for name, hexcode in re.findall(r'static let (\w+) = Color\(hex: "([0-9A-Fa-f]{6})"\)', src):
        out[name] = tuple(int(hexcode[i:i + 2], 16) for i in (0, 2, 4))
    return out


def palette_table(tokens: dict) -> list[dict]:
    """Every text token against every surface it could sit on."""
    backgrounds = [k for k in ("bg", "surface", "surfaceDeep", "sageLight") if k in tokens]
    foregrounds = [k for k in tokens if k not in backgrounds]
    rows = []
    for fg in foregrounds:
        for bg in backgrounds:
            r = ratio(tokens[fg], tokens[bg])
            rows.append({
                "text": fg, "on": bg, "ratio": r,
                "passesSmall": r >= AA_SMALL, "passesLarge": r >= AA_LARGE,
            })
    return sorted(rows, key=lambda x: x["ratio"])


# ─── observed ────────────────────────────────────────────────────────────────

def observed_pairs(path: Path, tokens: dict, tolerance: int = 12) -> list[dict]:
    """Which palette colours a screenshot actually rendered AS TEXT, on what.

    The first version of this counted co-occurrence — "this screen contains both
    `accent` and `surfaceDeep`, so flag the pairing" — and reported an unsafe
    pairing on 48 of 54 screens. Almost all of it was wrong: `accent` is a FILL
    here (the tab indicator, the primary button, the progress ring), not text.
    A tool that cries contrast on nearly every screen is worse than no tool,
    because the real finding is then indistinguishable from the noise.

    So distinguish strokes from fills by SHAPE. Glyphs are thin: nearly every
    pixel of a letter touches something that is not the letter. A filled button
    is a slab: almost none of its pixels do. `edgeRatio` is that fraction, and
    it separates the two cleanly without needing to segment or OCR anything.

    The background reported is the colour actually ADJACENT to those strokes —
    which is the question a grep cannot answer, because in SwiftUI
    `.background(...)` is written after the content it decorates.
    """
    import numpy as np

    with Image.open(path) as im:
        im = im.convert("RGB")
        # Big enough that 10pt text survives as strokes; small enough to be fast.
        im.thumbnail((520, 1200))
        arr = np.asarray(im, dtype=np.int16)

    backgrounds = {"bg", "surface", "surfaceDeep", "sageLight"}
    names = list(tokens)
    # index map: which token each pixel is (or -1)
    index = np.full(arr.shape[:2], -1, dtype=np.int8)
    for i, name in enumerate(names):
        rgb = np.array(tokens[name], dtype=np.int16)
        index[(np.abs(arr - rgb).max(axis=2) <= tolerance) & (index == -1)] = i

    def neighbours(mask):
        out = np.zeros_like(mask)
        out[1:, :] |= mask[:-1, :]; out[:-1, :] |= mask[1:, :]
        out[:, 1:] |= mask[:, :-1]; out[:, :-1] |= mask[:, 1:]
        return out

    total = index.size
    out = []
    for i, fg in enumerate(names):
        if fg in backgrounds:
            continue
        mask = index == i
        area = int(mask.sum())
        if area < total * 0.0004:            # a few hundred pixels: not on screen
            continue
        # Fraction of this colour's pixels that touch something else. Glyph
        # strokes are almost all edge; a filled control is almost all interior.
        edge = int((mask & ~(neighbours(mask) & mask)).sum()) if area else 0
        edge_ratio = round(edge / area, 3) if area else 0.0
        if edge_ratio < 0.55:                # a slab of colour — a fill, not text
            continue

        halo = neighbours(mask) & ~mask
        for j, bg in enumerate(names):
            if bg not in backgrounds:
                continue
            touching = int((halo & (index == j)).sum())
            if touching < edge * 0.25:       # not the dominant surface behind it
                continue
            r = ratio(tokens[fg], tokens[bg])
            if r < AA_SMALL:
                out.append({"text": fg, "on": bg, "ratio": r,
                            "edgeRatio": edge_ratio,
                            "strokePixels": area,
                            "touchingPixels": touching})
    return sorted(out, key=lambda x: x["ratio"])


# ─── measured: tap targets ───────────────────────────────────────────────────

def undersized_targets(run: Path, minimum: float = 44.0) -> list[dict]:
    """Every interactive element smaller than 44pt, from its REAL frame.

    The accessibility dump carries each element's frame in points, so this is
    arithmetic. The first version of this tool asked the vision model instead
    and got a confident "about 58px, far smaller than 132px" for a control that
    is nowhere near that — measured off an image the tool itself had downscaled,
    so the number was meaningless in either direction.

    `.contentShape(Rectangle())` makes a frame fully tappable and does not make
    it bigger; only the frame counts here.
    """
    interactive = {"button", "toggle", "switch", "slider", "stepper", "link"}
    found: dict[tuple, dict] = {}
    for dump in sorted((run / "steps").glob("*__a11y.json")):
        step = dump.name.split("__")[1]
        try:
            tree = json.loads(dump.read_text())
        except ValueError:
            continue

        def walk(node, inside_control=False):
            frame = node.get("frame") or [0, 0, 0, 0]
            w, h = frame[2], frame[3]
            is_control = node.get("type") in interactive
            # A control NESTED in another control is not the tap target — the
            # outer one is, and it may well be 44pt. Counting both is how a
            # measured list turns back into a guess.
            if (is_control and not inside_control and node.get("onScreen")
                    and w > 0 and h > 0 and (w < minimum or h < minimum)):
                label = (node.get("label") or node.get("title") or "").strip()
                key = (label, round(w), round(h))
                found.setdefault(key, {"label": label or "(unlabelled)",
                                       "width": round(w, 1), "height": round(h, 1),
                                       "steps": []})
                if step not in found[key]["steps"]:
                    found[key]["steps"].append(step)
            for child in node.get("children", []):
                walk(child, inside_control or is_control)

        walk(tree)
    return sorted(found.values(), key=lambda t: min(t["width"], t["height"]))


# ─── judged ──────────────────────────────────────────────────────────────────

def keychain(service: str) -> str:
    try:
        return subprocess.run(["security", "find-generic-password", "-s", service, "-w"],
                              capture_output=True, text=True, check=True).stdout.strip()
    except Exception:                                  # noqa: BLE001
        return ""


def encode(path: Path, max_side: int = 900) -> str:
    """Downscale before sending: a 3x screenshot is ~450 KB and the detail that
    matters — a wrapped label, a clipped word — survives the shrink."""
    with Image.open(path) as im:
        im = im.convert("RGB")
        im.thumbnail((max_side, max_side))
        buf = io.BytesIO()
        im.save(buf, format="JPEG", quality=80)
    return base64.b64encode(buf.getvalue()).decode()


def judge(key: str, batch: list[tuple[str, Path]]) -> list[dict]:
    content = [{"type": "text",
                "text": "Screens, in order: " + ", ".join(label for label, _ in batch)}]
    for label, path in batch:
        content += [
            {"type": "text", "text": f"--- step: {label}"},
            {"type": "image_url",
             "image_url": {"url": f"data:image/jpeg;base64,{encode(path)}"}},
        ]
    payload = {"model": MODEL,
               "messages": [{"role": "system", "content": RUBRIC},
                            {"role": "user", "content": content}],
               "response_format": {"type": "json_object"},
               "max_completion_tokens": 4000}
    req = urllib.request.Request(API, data=json.dumps(payload).encode(), headers={
        "Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as resp:
        body = json.loads(resp.read())
    return json.loads(body["choices"][0]["message"]["content"]).get("findings", [])


def only_screens_the_walk_actually_reached(run: Path, shots: list[Path]) -> tuple[list[Path], dict]:
    """Drop the steps the walk itself said were not what their label claims.

    EvidenceStep records two flags per step and, until this function existed,
    nothing on this side read either one. It cost real credibility: in run
    20260808-171059 the walk got stuck on the "Daily routine" sheet — which
    dismisses with a back chevron, not the Close/Done the walk knows — and
    photographed it for twelve consecutive steps under twelve different names,
    among them `chat`, `planner.travel` and `planner.activity_picker`. 54 steps
    yielded 37 distinct images. This judge then dutifully reported a layout
    finding against `tasks.add_todo` while looking at the morning chat card.

    A verdict against a screenshot of the wrong screen is worse than no verdict,
    so those steps are removed here rather than graded. The counts are printed —
    a harness that silently drops evidence reads as "all clear" when it is not.
    """
    manifest = run / "walkthrough.json"
    if not manifest.exists():
        return shots, {}
    try:
        steps = json.loads(manifest.read_text()).get("steps", [])
    except (json.JSONDecodeError, OSError):
        return shots, {}

    stale = {s["label"] for s in steps if s.get("changed") is False}
    missing = {s["label"] for s in steps if s.get("reachable") is False}
    dropped: dict[str, list[str]] = {}
    kept = []
    for shot in shots:
        label = shot.name.split("__")[1]
        if label in missing:
            dropped.setdefault("the walk never reached this screen", []).append(label)
        elif label in stale:
            dropped.setdefault("identical to the previous step — the walk did not "
                               "navigate, so this image is not this screen", []).append(label)
        else:
            kept.append(shot)
    return kept, dropped


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("run")
    parser.add_argument("--no-model", action="store_true",
                        help="measurement only — no vision pass, no key needed")
    parser.add_argument("--batch", type=int, default=6)
    args = parser.parse_args()

    run = Path(args.run)
    shots = sorted((run / "steps").glob("*__screen.png"))
    if not shots:
        sys.exit(f"No screenshots in {run/'steps'} — run tools/capture-evidence.sh first.")

    shots, dropped = only_screens_the_walk_actually_reached(run, shots)
    for reason, labels in dropped.items():
        print(f"  SKIPPED  {len(labels)} step(s) — {reason}: {', '.join(labels)}")
    if not shots:
        sys.exit("Every step was a duplicate or unreachable — nothing to judge. "
                 "Fix the walk before trusting any verdict from this run.")

    tokens = palette()
    print(f"palette: {len(tokens)} tokens from Jeeves/ContentView.swift")
    table = palette_table(tokens)
    unsafe = [r for r in table if not r["passesSmall"]]
    for r in unsafe:
        print(f"  MEASURED  {r['text']:14} on {r['on']:12} {r['ratio']:>6}:1"
              f"  {'(large text only)' if r['passesLarge'] else 'FAILS AT ANY SIZE'}")

    seen: dict[str, list] = {}
    for shot in shots:
        label = shot.name.split("__")[1]
        pairs = observed_pairs(shot, tokens)
        if pairs:
            seen[label] = pairs

    print(f"\nscreens using an unsafe pairing: {len(seen)} of {len(shots)}")
    for label, pairs in list(seen.items())[:12]:
        worst = pairs[0]
        print(f"  OBSERVED  {label:32} {worst['text']} on {worst['on']} = {worst['ratio']}:1")

    targets = undersized_targets(run)
    # Outermost controls only, so this is a list to act on rather than a
    # candidate count to argue about.
    print(f"\ntap targets under 44pt (outermost controls only): {len(targets)}")
    for t in targets[:12]:
        print(f"  MEASURED  {t['width']}x{t['height']}pt  {t['label'][:38]:40} "
              f"({len(t['steps'])} screen{'s' if len(t['steps']) != 1 else ''})")

    findings = []
    if not args.no_model:
        key = os.environ.get("OPENAI_API_KEY", "").strip() or keychain("jeeves-openai")
        if not key:
            sys.exit("Set OPENAI_API_KEY, or pass --no-model for the measured pass alone.")
        batches = [shots[i:i + args.batch] for i in range(0, len(shots), args.batch)]
        for index, batch in enumerate(batches, 1):
            pairs = [(s.name.split("__")[1], s) for s in batch]
            print(f"  looking at batch {index}/{len(batches)} ({len(batch)} screens)…", flush=True)
            try:
                findings += judge(key, pairs)
            except Exception as exc:                   # noqa: BLE001
                # Loud. A silently dropped batch is a screen nobody looked at,
                # reported as a screen with nothing wrong.
                print(f"  batch {index} FAILED: {exc}", file=sys.stderr)
                findings.append({"step": f"batch {index}", "kind": "not-examined",
                                 "text": "", "what": f"this batch was not looked at: {exc}"})

    # Never a rate that hides its denominator. "screensExamined" is the
    # POST-filter count, so on its own it reads as full coverage of a walk that
    # may have skipped a third of its steps — and "0 findings" out of 24 of 54
    # screens is not the same statement as "0 findings" out of 54.
    skipped = sorted(label for labels in dropped.values() for label in labels)
    out = {
        "run": run.name,
        "screensExamined": len(shots),
        "screensCaptured": len(shots) + len(skipped),
        "screensSkipped": skipped,
        "skippedReasons": {reason: labels for reason, labels in dropped.items()},
        "measured": table,
        "measuredUnsafe": unsafe,
        "observed": seen,
        "undersizedTargets": targets,
        "findings": findings,
    }
    (run / "visual.json").write_text(json.dumps(out, indent=2))

    print(f"\nlayout findings: {len(findings)}"
          f"  (across {len(shots)} of {len(shots) + len(skipped)} captured screens)")
    for f in findings[:20]:
        print(f"  {f.get('kind','?'):13} {f.get('step','?'):28} {f.get('text','')[:40]!r} — {f.get('what','')[:70]}")
    print(f"→ {run/'visual.json'}")
    sys.exit(1 if findings or seen or targets else 0)


if __name__ == "__main__":
    main()
