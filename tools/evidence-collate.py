#!/usr/bin/env python3
"""
Collate an evidence run into something a judge can read.

`xcresulttool export attachments` flattens everything into one directory of
UUID-named files plus a manifest. The step order, and which PNG belongs to which
accessibility dump, live only in the attachment NAMES — which is why the
walkthrough encodes `NNN__label__kind` into them.

Input:  <run>/raw/            (from `xcresulttool export attachments`)
Output: <run>/steps/          renamed, human-ordered files
        <run>/walkthrough.json  the thing the judges actually read

Usage:
    python3 tools/evidence-collate.py <run-dir>
"""
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

# `NNN__label__kind_<repeat>_<uuid>.<ext>` — xcresulttool appends its own suffix.
NAME = re.compile(r"^(\d{3})__(.+?)__(a11y|screen|steps)(?:_\d+_[0-9A-F-]+)?\.(json|png)$", re.I)


def require_supported_xcresulttool() -> None:
    """Fail loudly on an unexpected toolchain rather than emitting nothing.

    The `get test-results` / `export attachments` family does not exist before
    Xcode 16, and `get object` now demands `--legacy`. A silent empty run would
    look exactly like an app with no screens.
    """
    try:
        out = subprocess.run(["xcrun", "xcresulttool", "version"],
                             capture_output=True, text=True, check=True).stdout
    except Exception as exc:                       # noqa: BLE001
        sys.exit(f"xcresulttool unavailable: {exc}")
    if "0.1.0" not in out:
        sys.exit(f"Unexpected xcresulttool schema — refusing to guess:\n{out.strip()}")


def summarise(node: dict) -> list[str]:
    """Flatten a hierarchy to `role|label|value` lines, on-screen first.

    The judge is asked "was this control built", so what matters is the presence
    and wording of leaves. Frames are dropped; the on/off-screen split is kept,
    because "scrolled away" and "does not exist" are different answers.
    """
    on, off = [], []

    def walk(n: dict) -> None:
        label = (n.get("label") or n.get("title") or "").strip()
        value = str(n.get("value") or "").strip()
        if label or value:
            line = f"{n.get('type','?')}|{label}" + (f"|{value}" if value else "")
            (on if n.get("onScreen") else off).append(line)
        for child in n.get("children", []):
            walk(child)

    walk(node)
    seen, ordered = set(), []
    for line in on + [f"(offscreen) {x}" for x in off]:
        if line not in seen:
            seen.add(line)
            ordered.append(line)
    return ordered


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit("Usage: evidence-collate.py <run-dir>")
    require_supported_xcresulttool()

    run = Path(sys.argv[1])
    raw, steps_dir = run / "raw", run / "steps"
    if not (raw / "manifest.json").exists():
        sys.exit(f"No manifest at {raw/'manifest.json'} — did the export run?")
    steps_dir.mkdir(parents=True, exist_ok=True)

    manifest = json.loads((raw / "manifest.json").read_text())
    records: dict[int, dict] = {}
    walk_steps: list[dict] = []

    for test in manifest:
        for att in test.get("attachments", []):
            pretty = att.get("suggestedHumanReadableName") or ""
            match = NAME.match(pretty)
            if not match:
                continue
            index, label, kind, _ext = int(match[1]), match[2], match[3].lower(), match[4]
            src = raw / att["exportedFileName"]
            if not src.exists():
                continue

            if kind == "steps":
                walk_steps = json.loads(src.read_text())
                continue

            ext = "png" if kind == "screen" else "json"
            dest = steps_dir / f"{index:03d}__{label}__{kind}.{ext}"
            shutil.copyfile(src, dest)

            rec = records.setdefault(index, {"index": index, "label": label})
            if kind == "screen":
                rec["screenshot"] = str(dest.relative_to(run))
            else:
                rec["a11y"] = str(dest.relative_to(run))
                rec["elements"] = summarise(json.loads(dest.read_text()))

    # The in-test manifest carries reachability, which the attachments cannot.
    by_index = {s["index"]: s for s in walk_steps}
    for index, rec in records.items():
        meta = by_index.get(index, {})
        rec["reachable"] = meta.get("reachable", True)
        rec["changed"] = meta.get("changed", True)
        rec["note"] = meta.get("note", "")

    ordered = [records[i] for i in sorted(records)]
    unreachable = [r["label"] for r in ordered if not r.get("reachable")]

    # Rules and notifications are evidence the screen cannot carry. Folding them
    # into the same file means the judge sees one corpus, not three.
    tests: list[str] = []
    tests_file = run / "tests.txt"
    if tests_file.exists():
        tests = [line for line in tests_file.read_text().splitlines() if line.strip()]

    notifications = {}
    notif_file = run / "notifications.json"
    if notif_file.exists():
        notifications = json.loads(notif_file.read_text())

    out = {
        "run": run.name,
        "steps": ordered,
        "unreachable": unreachable,
        "stepCount": len(ordered),
        "tests": tests,
        "testCount": len(tests),
        "testFailures": [t for t in tests if t.startswith("failed")],
        "notifications": notifications,
    }
    (run / "walkthrough.json").write_text(json.dumps(out, indent=2))

    print(f"{len(ordered)} steps, {len(tests)} tests, "
          f"{len(notifications.get('pending', []))}+{len(notifications.get('delivered', []))} notifications "
          f"→ {run/'walkthrough.json'}")
    if unreachable:
        # Never silent: an unreachable step is a finding, not a gap in the data.
        print(f"UNREACHABLE ({len(unreachable)}): {', '.join(unreachable)}")


if __name__ == "__main__":
    main()
