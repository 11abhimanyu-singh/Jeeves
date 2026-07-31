#!/usr/bin/env python3
"""
Jeeves zero-touch diagnosis: the whole pipeline with NO cable.

The phone exports itself to iCloud Drive on every launch and plan generation
(SyncOutbox: heartbeat.json, state-latest.json, jeeves-diagnostics.json,
jeeves-anomalies.json, and backup/jeeves.store — a full-fidelity SQLite copy).
This reads that folder, so the daily run needs nothing from you.

Order matters:
  0. HEARTBEAT FIRST — how old is the export? A stale export must never be
     reported as a clean bill of health; "the phone hasn't synced" and "the
     app is healthy" look identical if you skip this.
  1. audit       store-audit.py over backup/jeeves.store (all invariants)
  2. trajectory  trajectory-audit.py (story vs state, every session)
  3. anomalies   read the phone's own scan + the three product metrics
  4. dump/coherence/plans — judged layers, only with OPENAI_API_KEY

Exit codes: 0 clean · 1 findings · 2 the export itself is stale/missing
(a channel failure, not an app failure — they need different fixes).

Usage:
    python3 tools/icloud-diagnose.py [--max-age-hours N] [--markdown out.md]
    OPENAI_API_KEY=... python3 tools/icloud-diagnose.py
"""
import json
import os
import subprocess
import sys
from datetime import datetime, timedelta
from pathlib import Path

ICLOUD = (Path.home() / "Library/Mobile Documents"
          / "iCloud~abhimanyusingh~me~Jeeves" / "Documents")
TOOLS = Path(__file__).parent
DEFAULT_MAX_AGE_HOURS = 36


def read_json(path):
    try:
        return json.loads(path.read_text())
    except Exception:
        return None


def parse_ist(stamp):
    """The app writes 'yyyy-MM-dd HH:mm:ss IST'."""
    if not stamp:
        return None
    try:
        return datetime.strptime(stamp.replace(" IST", ""), "%Y-%m-%d %H:%M:%S")
    except ValueError:
        try:
            return datetime.fromisoformat(stamp.replace("Z", ""))
        except ValueError:
            return None


def run(label, cmd, lines):
    lines.append(f"\n===== {label} =====")
    r = subprocess.run(cmd, capture_output=True, text=True)
    out = (r.stdout or "") + (r.stderr or "")
    lines.append(out.rstrip())
    lines.append(f"----- {label}: exit {r.returncode}")
    return r.returncode


def main() -> None:
    args = sys.argv[1:]
    max_age = DEFAULT_MAX_AGE_HOURS
    if "--max-age-hours" in args:
        max_age = int(args[args.index("--max-age-hours") + 1])
    md_out = Path(args[args.index("--markdown") + 1]) if "--markdown" in args else None

    lines = [f"# Jeeves zero-touch diagnosis — {datetime.now():%Y-%m-%d %H:%M}"]

    # ---- 0. Channel health, before anything else -----------------------
    if not ICLOUD.exists():
        lines.append("\n**EXPORT CHANNEL DOWN** — the iCloud folder doesn't exist on this Mac.\n"
                     "Nothing was diagnosed. Check: iCloud Drive enabled on the Mac and signed\n"
                     "into the same Apple ID, and the app launched at least once since the\n"
                     "export shipped.")
        print("\n".join(lines))
        if md_out:
            md_out.write_text("\n".join(lines))
        sys.exit(2)

    heartbeat = read_json(ICLOUD / "heartbeat.json")
    written = parse_ist((heartbeat or {}).get("writtenAt"))
    age_hours = (datetime.now() - written).total_seconds() / 3600 if written else None

    if heartbeat is None:
        lines.append("\n**EXPORT CHANNEL SILENT** — no heartbeat.json in the iCloud folder.\n"
                     "The phone has never completed an export (or iCloud hasn't delivered it).\n"
                     "Everything below would be guesswork, so nothing was run.")
        present = sorted(p.name for p in ICLOUD.iterdir())
        lines.append(f"Folder contains: {present or 'nothing'}")
        print("\n".join(lines))
        if md_out:
            md_out.write_text("\n".join(lines))
        sys.exit(2)

    lines.append(f"\nHeartbeat: written {heartbeat.get('writtenAt')} "
                 f"({age_hours:.1f} h ago)" if age_hours is not None
                 else "\nHeartbeat present but unparseable timestamp")
    for k in ("device", "appVersion", "build", "schemaVersion"):
        if heartbeat.get(k):
            lines.append(f"  {k}: {heartbeat[k]}")

    if age_hours is not None and age_hours > max_age:
        lines.append(f"\n**EXPORT STALE** — {age_hours:.0f} h old (limit {max_age} h). "
                     "Diagnosing this would describe the past, not today.\n"
                     "Most likely: the phone hasn't opened Jeeves, or iCloud is behind.")
        print("\n".join(lines))
        if md_out:
            md_out.write_text("\n".join(lines))
        sys.exit(2)

    # ---- 1-2. Deterministic layers over the exported store --------------
    store = ICLOUD / "backup" / "jeeves.store"
    results = {}
    if store.exists():
        results["audit"] = run("AUDIT (all invariants, all history)",
                               [sys.executable, str(TOOLS / "store-audit.py"), str(store)], lines)
        results["trajectory"] = run("TRAJECTORY (story vs state)",
                                    [sys.executable, str(TOOLS / "trajectory-audit.py"), str(store)], lines)
    else:
        lines.append("\n**No raw store in the export** (backup/jeeves.store missing) — the "
                     "deterministic audits need it. It refreshes on app launch; the state and "
                     "anomaly files below are still readable.")
        results["audit"] = 2

    # ---- 3. The phone's own scan + the product metrics -------------------
    digest = read_json(ICLOUD / "jeeves-anomalies.json")
    if digest:
        lines.append("\n===== ANOMALIES (phone's own scan) =====")
        lines.append(f"{digest.get('count', 0)} anomaly(ies) · {digest.get('eventCount', 0)} events logged")
        order = {"high": 0, "medium": 1, "low": 2}
        for a in sorted(digest.get("anomalies", []), key=lambda x: order.get(x.get("severity"), 3)):
            lines.append(f"  [{a.get('severity','?').upper():6}] {a.get('day','')} {a.get('title','')}")
            lines.append(f"           {a.get('detail','')}")
        if digest.get("count"):
            results["anomalies"] = 1

        m = digest.get("metrics")
        if m:
            lines.append(f"\n===== PRODUCT METRICS (trailing {m.get('windowDays', 30)} days) =====")
            def show(label, key, fmt):
                v = m.get(key) or {}
                val = v.get("value")
                shown = fmt(val) if val is not None else "—"
                flag = "" if v.get("sampleSize", 0) >= 5 else "  (small sample)"
                lines.append(f"  {label:22} {shown:>8}{flag}   {v.get('note','')}")
            show("Correction rate", "correctionRate", lambda v: f"{v*100:.0f}%")
            show("Replan acceptance", "replanAcceptance", lambda v: f"{v*100:.0f}%")
            show("Time to outcome", "timeToOutcomeMinutes", lambda v: f"{v:.0f} min")
            lines.append("  Direction: correction rate DOWN, acceptance UP, time to outcome DOWN.")
    else:
        lines.append("\nNo jeeves-anomalies.json yet — the phone's scan hasn't exported.")

    # ---- 4. Judged layers ------------------------------------------------
    key = os.environ.get("OPENAI_API_KEY", "").strip()
    if key and store.exists():
        dump = ICLOUD.parent / "jeeves-dump.json"
        results["dump"] = run("DUMP", [sys.executable, str(TOOLS / "store-dump.py"),
                                       str(store), str(dump)], lines)
        results["coherence"] = run("COHERENCE (third party)",
                                   [sys.executable, str(TOOLS / "coherence-eval.py"), str(dump)], lines)
    else:
        lines.append("\n===== JUDGED LAYERS: SKIPPED — no OPENAI_API_KEY =====")
        lines.append("Deterministic layers ran; judgment layers did NOT. Not a clean bill.")

    worst = max(results.values()) if results else 0
    lines.append(f"\n===== SUMMARY: {'findings present' if worst else 'clean'} =====")
    for k, v in results.items():
        lines.append(f"  {k:12} {'OK' if v == 0 else f'exit {v}'}")

    text = "\n".join(lines)
    print(text)
    if md_out:
        md_out.write_text(text)
    sys.exit(1 if worst else 0)


if __name__ == "__main__":
    main()
