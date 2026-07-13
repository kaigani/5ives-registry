#!/usr/bin/env python3
"""Extend every official channel's signed looping schedule horizon."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import subprocess
from pathlib import Path

SECONDS_PER_DAY = 86_400


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def historical_rotation(root: Path, channel_id: str) -> list[str]:
    schedule_dir = root / "channels" / channel_id / "schedules"
    seen: set[str] = set()
    rotation: list[str] = []
    for path in sorted(schedule_dir.glob("*.json"), reverse=True):
        for slot in read_json(path).get("slots", []):
            asset_id = slot.get("asset_id")
            if (
                slot.get("type") == "fixed"
                and asset_id
                and asset_id not in seen
                and (root / "assets" / f"{asset_id}.json").exists()
            ):
                seen.add(asset_id)
                rotation.append(asset_id)
    return rotation


def build_manifest(
    root: Path, channel_id: str, day: dt.date, rotation: list[str], version: int
) -> dict:
    durations = {
        asset_id: int(read_json(root / "assets" / f"{asset_id}.json")["duration_seconds"])
        for asset_id in rotation
    }
    slots = []
    start = 0
    index = 0
    while start < SECONDS_PER_DAY:
        asset_id = rotation[index % len(rotation)]
        duration = durations[asset_id]
        if duration <= 0:
            raise ValueError(f"{asset_id} has an invalid duration: {duration}")
        slots.append(
            {
                "type": "fixed",
                "slot_id": f"{day.isoformat()}-{index:03d}",
                "start_time": start,
                "asset_id": asset_id,
                "duration_seconds": duration,
            }
        )
        start += duration
        index += 1

    tomorrow = day + dt.timedelta(days=1)
    return {
        "spec": 1,
        "channel_id": channel_id,
        "version": version,
        "valid_from": f"{day.isoformat()}T00:00:00Z",
        "valid_until": f"{tomorrow.isoformat()}T00:00:00Z",
        "slots": slots,
    }


def write_and_sign(path: Path, manifest: dict, secret_key: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    subprocess.run(
        [
            "minisign",
            "-S",
            "-W",
            "-s",
            str(secret_key),
            "-m",
            str(path),
            "-x",
            f"{path}.minisig",
        ],
        check=True,
    )


def refresh(root: Path, start: dt.date, days_ahead: int, secret_key: Path) -> int:
    index = read_json(root / "registry.json")
    written = 0
    for channel_id in index.get("channels", []):
        rotation = historical_rotation(root, channel_id)
        if not rotation:
            continue
        for offset in range(days_ahead + 1):
            day = start + dt.timedelta(days=offset)
            path = root / "channels" / channel_id / "schedules" / f"{day.isoformat()}.json"
            version = read_json(path).get("version", 0) + 1 if path.exists() else 1
            write_and_sign(
                path,
                build_manifest(root, channel_id, day, rotation, version),
                secret_key,
            )
            written += 1
    return written


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--secret-key", type=Path, required=True)
    parser.add_argument("--days", type=int, default=7)
    parser.add_argument("--from-date", type=dt.date.fromisoformat, default=dt.datetime.now(dt.UTC).date())
    args = parser.parse_args()
    if args.days < 1:
        parser.error("--days must be at least 1")
    count = refresh(args.root.resolve(), args.from_date, args.days, args.secret_key.resolve())
    print(f"Wrote and signed {count} schedules through {args.from_date + dt.timedelta(days=args.days)}")


if __name__ == "__main__":
    main()
