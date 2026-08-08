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
import plistlib
import subprocess
import sys
from pathlib import Path

ROOT = Path.home() / "Library/Developer/CoreSimulator/Devices"


def decode(path: Path) -> object:
    """Simulator plists are binary; plutil is the reliable decoder."""
    try:
        out = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(path)],
                             capture_output=True, text=True, check=True).stdout
        return json.loads(out)
    except Exception:                                  # noqa: BLE001
        try:
            return plistlib.loads(path.read_bytes())
        except Exception:                              # noqa: BLE001
            return None


def requests_in(blob: object, prefix: str) -> list[dict]:
    """Pull every request whose identifier starts with `prefix`.

    The store's shape is version-dependent, so walk it rather than assuming a
    path: find dicts that look like a notification request and keep ours.
    """
    found: list[dict] = []

    def walk(node: object) -> None:
        if isinstance(node, dict):
            ident = node.get("AppNotificationIdentifier") or node.get("identifier") or ""
            if isinstance(ident, str) and ident.startswith(prefix):
                found.append({
                    "id": ident,
                    "title": node.get("AppNotificationTitle") or node.get("title") or "",
                    "body": node.get("AppNotificationBody") or node.get("body") or "",
                    "date": str(node.get("TriggerDate") or node.get("date") or ""),
                })
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    walk(blob)
    # One entry per identifier; the store repeats them across indexes.
    seen, out = set(), []
    for item in found:
        if item["id"] in seen:
            continue
        seen.add(item["id"])
        out.append(item)
    return sorted(out, key=lambda r: r["id"])


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
                blob = decode(path)
                if blob is None:
                    continue
                result[kind] += requests_in(blob, "jeeves")
        if not result["pending"] and not result["delivered"]:
            result["note"] = "store present but no jeeves notifications in it"

    text = json.dumps(result, indent=2)
    if len(sys.argv) > 2:
        Path(sys.argv[2]).write_text(text)
    print(f'{len(result["pending"])} pending, {len(result["delivered"])} delivered'
          + (f' — {result["note"]}' if result["note"] else ""))


if __name__ == "__main__":
    main()
