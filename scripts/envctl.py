#!/usr/bin/env python3
"""envctl — tiny CLI behind Launchpad's self-service workflows.

  envctl.py validate               # schema + cross-file rules (CI on every PR)
  envctl.py new --name x --app y --team t --owner o [--ttl-days 3] [...]
  envctl.py reap [--today YYYY-MM-DD] # delete expired env files, print what went

Requires: pip install pyyaml jsonschema
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import pathlib
import sys

import yaml
from jsonschema import Draft202012Validator, FormatChecker

ROOT = pathlib.Path(__file__).resolve().parent.parent
ENV_DIR = ROOT / "environments"
SCHEMA = json.loads((ROOT / "schemas" / "environment.schema.json").read_text())


def load_all() -> dict[str, dict]:
    return {p.stem: (yaml.safe_load(p.read_text()) or {}) for p in sorted(ENV_DIR.glob("*.yaml"))}


def cmd_validate(_: argparse.Namespace) -> int:
    validator = Draft202012Validator(SCHEMA, format_checker=FormatChecker())
    envs, errors = load_all(), []
    for stem, data in envs.items():
        for err in validator.iter_errors(data):
            loc = "/".join(str(p) for p in err.absolute_path) or "(root)"
            errors.append(f"environments/{stem}.yaml: {loc}: {err.message}")
        if data.get("name") != stem:
            errors.append(f"environments/{stem}.yaml: name '{data.get('name')}' must equal the file name")
    primaries = [s for s, d in envs.items() if d.get("primary")]
    if len(primaries) > 1:
        errors.append(f"only one environment may be primary, found: {', '.join(primaries)}")

    for e in errors:
        print(f"::error::{e}")
    print(f"{len(envs)} environment file(s) checked, {len(errors)} error(s).")
    return 1 if errors else 0


def cmd_new(a: argparse.Namespace) -> int:
    path = ENV_DIR / f"{a.name}.yaml"
    if path.exists():
        print(f"::error::{path.name} already exists")
        return 1
    doc = {
        "name": a.name, "app": a.app, "team": a.team, "owner": a.owner,
        "image_tag": a.image_tag, "size": a.size, "database": a.database,
    }
    if a.database == "mysql":
        doc["worker"] = a.worker
    if a.ttl_days:
        doc["expires"] = (dt.date.today() + dt.timedelta(days=a.ttl_days)).isoformat()
    header = "# yaml-language-server: $schema=../schemas/environment.schema.json\n# Created by the 'Create environment' workflow.\n"
    path.write_text(header + yaml.safe_dump(doc, sort_keys=False))
    print(path.relative_to(ROOT))
    return cmd_validate(a)


def cmd_reap(a: argparse.Namespace) -> int:
    today = dt.date.fromisoformat(a.today) if a.today else dt.date.today()
    reaped = []
    for stem, data in load_all().items():
        exp = data.get("expires")
        if exp and dt.date.fromisoformat(str(exp)) < today:
            (ENV_DIR / f"{stem}.yaml").unlink()
            reaped.append(stem)
    print(json.dumps(reaped))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(prog="envctl")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("validate").set_defaults(fn=cmd_validate)

    n = sub.add_parser("new")
    n.add_argument("--name", required=True)
    n.add_argument("--app", required=True)
    n.add_argument("--team", required=True)
    n.add_argument("--owner", required=True)
    n.add_argument("--image-tag", default="bootstrap")
    n.add_argument("--size", choices=["small", "medium", "large"], default="small")
    n.add_argument("--database", choices=["sqlite", "mysql"], default="sqlite")
    n.add_argument("--worker", action="store_true")
    n.add_argument("--ttl-days", type=int, default=0)
    n.set_defaults(fn=cmd_new)

    r = sub.add_parser("reap")
    r.add_argument("--today")
    r.set_defaults(fn=cmd_reap)

    a = ap.parse_args()
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
