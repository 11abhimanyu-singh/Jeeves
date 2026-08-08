#!/usr/bin/env python3
"""
Dump what the app has actually scheduled and delivered on a simulator.

WHY THIS IS A SEPARATE EVIDENCE CHANNEL

A notification is invisible to an accessibility dump of the app: it is not in the
app's hierarchy, it is in the notification daemon's store. So the conformance
judge marked "the app sends a daily planning notification" ABSENT even though it
demonstrably fires — the evidence simply had no way to contain it.

This reads the store directly, which is exactly how the 07:00 offer was proved to
fire on the phone: `jeeves.morning.2026-08-07` sitting in DeliveredNotifications.

Usage:
    python3 tools/notification-dump.py <udid> [out.json]
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path.home() / "Library/Developer/CoreSimulator/Devices"


def entries(path: Path, prefix: str = "jeeves") -> list[dict]:
    """Pull our notification identifiers out of a store plist.

    Deliberately text-based. The first version modelled the store's structure —
    walking for dicts with an `AppNotificationIdentifier` key — and found
    NOTHING, while `plutil -p` on the same file printed the identifiers plainly.
    The store's shape is an implementation detail of the notification daemon and
    varies by iOS version; the identifiers we ourselves chose are not. So parse
    what plutil prints and stop pretending to know the schema.
    """
    try:
        text = subprocess.run(["plutil", "-p", str(path)],
                              capture_output=True, text=True, check=True).stdout
    except Exception:                                  # noqa: BLE001
        return []

    ids = sorted(set(re.findall(rf'"({re.escape(prefix)}[\w.:|\- ]*)"', text)))
    # Bodies live near their identifier but not at a predictable path; pair them
    # up by proximity, and say nothing rather than guess when there is no match.
    out = []
    for ident in ids:
        body = ""
        index = text.find(f'"{ident}"')
        if index != -1:
            window = text[max(0, index - 4000): index + 4000]
            hit = re.search(r'"AppNotificationBody" => "([^"]+)"', window)
            if hit:
                body = hit.group(1)
        out.append({"id": ident, "body": body})
    return out


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit("Usage: notification-dump.py <udid> [out.json]")
    udid = sys.argv[1]
    base = ROOT / udid / "data/Library/UserNotifications"
    result = {"pending": [], "delivered": [], "note": ""}

    if not base.exists():
        result["note"] = "no notification store on this simulator"
    else:
        for kind, filename in (("pending", "PendingNotifications.plist"),
                               ("delivered", "DeliveredNotifications.plist")):
            for path in base.rglob(filename):
                result[kind] += entries(path)
        for kind in ("pending", "delivered"):
            seen, unique = set(), []
            for item in result[kind]:
                if item["id"] in seen:
                    continue
                seen.add(item["id"])
                unique.append(item)
            result[kind] = unique
        if not result["pending"] and not result["delivered"]:
            result["note"] = "store present but no jeeves notifications in it"

    text = json.dumps(result, indent=2)
    if len(sys.argv) > 2:
        Path(sys.argv[2]).write_text(text)
    print(f'{len(result["pending"])} pending, {len(result["delivered"])} delivered'
          + (f' — {result["note"]}' if result["note"] else ""))


if __name__ == "__main__":
    main()
