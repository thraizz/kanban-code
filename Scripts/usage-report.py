#!/usr/bin/env python3
"""Usage report: what of Kanban Code is used, and what never is.

Reads the day files the app writes to ~/.kanban-code/usage/<yyyy-MM-dd>.json
and the CLI log ~/.kanban-code/usage/cli.jsonl, and compares them with the
features found in the source tree.

    Scripts/usage-report.py [--days N] [--home DIR]

Sections:
  - used, per kind, with counts and last use (actions split into user/system)
  - never used: reducer actions, card actions, shortcuts, settings tabs,
    views, detail tabs and CLI commands with no recorded use in the window
"""
import argparse
import datetime as dt
import json
import os
import re
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "Sources" / "KanbanCode"
CORE = ROOT / "Sources" / "KanbanCodeCore"


def load(home: Path, days: int | None):
    since = dt.date.today() - dt.timedelta(days=days - 1) if days else None
    counts: dict[str, dict] = {}
    day_files = sorted((home / "usage").glob("????-??-??.json"))
    used_days = []
    for path in day_files:
        day = dt.date.fromisoformat(path.stem)
        if since and day < since:
            continue
        used_days.append(day)
        for key, entry in json.loads(path.read_text()).items():
            c = counts.setdefault(key, {"count": 0, "last": ""})
            c["count"] += entry["count"]
            c["last"] = max(c["last"], entry["last"])
    cli = home / "usage" / "cli.jsonl"
    if cli.exists():
        for line in cli.read_text().splitlines():
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if since and dt.date.fromisoformat(row["date"][:10]) < since:
                continue
            key = f"cli.{'agent' if row.get('fromCard') else 'human'}:{row['command']}"
            c = counts.setdefault(key, {"count": 0, "last": ""})
            c["count"] += 1
            c["last"] = max(c["last"], row["date"])
    return counts, used_days


def block(text: str, start: str) -> str:
    """The text of the brace block that opens on the line matching `start`."""
    i = text.index(start)
    i = text.index("{", i)
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[i:j]
    return text[i:]


def inventory() -> dict[str, set[str]]:
    inv: dict[str, set[str]] = {}
    store = (CORE / "UseCases" / "BoardStore.swift").read_text()
    inv["action"] = set(re.findall(r"^    case (\w+)", block(store, "public enum Action"), re.M))

    app = {p.name: p.read_text() for p in APP.glob("*.swift")}
    inv["card-action"] = set(re.findall(r'CardActionItem\(\s*id: "([^"\\]+)"', app["CardActionCatalog.swift"]))
    inv["shortcut"] = set(re.findall(r'UsageLog\.record\("shortcut", "(\w+)"\)', app["ContentView.swift"]))
    inv["settings"] = set(re.findall(r'\.trackUsage\("settings", "([^"]+)"\)', app["SettingsView.swift"]))
    inv["view"] = {name for text in app.values() for name in re.findall(r'trackUsage\("view", "(\w+)"\)', text)}
    inv["tab"] = set(re.findall(r"case (.+)", block(app["CardDetailHelpers.swift"], "enum DetailTab"))[0].replace(" ", "").split(","))
    inv["menu"] = set(re.findall(r'UsageLog\.record\("menu", "([^"]+)"\)', app["App.swift"]))

    cli = (ROOT / "cli" / "src" / "kanban.ts").read_text()
    for path in (ROOT / "cli" / "src").glob("*.ts"):
        if not path.name.endswith(".test.ts") and path.name != "kanban.ts":
            cli += path.read_text()
    inv["cli"] = set(re.findall(r'\.command\("([a-z][a-z-]*)', cli))
    return inv


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--days", type=int, help="only the last N days (default: everything recorded)")
    parser.add_argument("--home", type=Path, default=Path(os.path.expanduser("~/.kanban-code")))
    args = parser.parse_args()

    counts, days = load(args.home, args.days)
    if not days and not counts:
        print("No usage recorded yet under", args.home / "usage")
        return
    span = f"{min(days)} .. {max(days)} ({len(days)} days with data)" if days else "CLI only"
    print(f"Usage {span}\n")

    by_kind: dict[str, list] = defaultdict(list)
    for key, entry in counts.items():
        kind, _, name = key.partition(":")
        by_kind[kind].append((entry["count"], name, entry["last"][:16].replace("T", " ")))

    for kind in sorted(by_kind):
        rows = sorted(by_kind[kind], reverse=True)
        print(f"== {kind} ({len(rows)} used, {sum(r[0] for r in rows)} total)")
        for count, name, last in rows:
            print(f"  {count:>7}  {name:<58} last {last}")
        print()

    seen: dict[str, set[str]] = defaultdict(set)
    for key in counts:
        kind, _, name = key.partition(":")
        if kind.startswith("action."):
            seen["action"].add(name)
        elif kind.startswith("cli."):
            seen["cli"].update(name.split(" "))
        elif kind == "card-action":
            seen[kind].add(name)
            seen[kind].add(name.split(".")[0])
        else:
            seen[kind].add(name)
    user_actions = {k.partition(":")[2] for k in counts if k.startswith("action.user:")}

    print("== NEVER USED")
    for kind, names in sorted(inventory().items()):
        unused = sorted(n for n in names if n not in seen[kind])
        print(f"-- {kind}: {len(unused)} of {len(names)} unused")
        for name in unused:
            print(f"  {name}")
    print()
    inv_actions = inventory()["action"]
    system_only = sorted(n for n in inv_actions if n in seen["action"] and n not in user_actions)
    print(f"-- action: {len(system_only)} only ever dispatched by the app itself, never by a click or key")
    for name in system_only:
        print(f"  {name}")


if __name__ == "__main__":
    main()
