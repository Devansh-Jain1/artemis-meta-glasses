#!/usr/bin/env python3
"""Audit Artemis telemetry for live golden assistant evidence.

This reads the local SQLite log receiver output. It does not prove anything by
itself; it prevents us from upgrading weak evidence into "live assistant" claims.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
import time
from pathlib import Path
from typing import Any


REQUIRED_TURN_FIELDS = [
    "stt_source",
    "turn_finalization_reason",
    "brain_impl",
    "brain_model",
    "brain_runtime",
    "vision_source",
    "vision_model",
    "vision_prompt_mode",
    "vision_frame_id",
    "vision_timestamp_ms",
    "vision_age_ms_at_turn",
    "vision_freshness_state",
    "vision_direct_claim_allowed",
    "tts_engine",
    "first_response_ms",
    "end_to_end_ms",
    "fallback_triggered",
    "fallback_reason",
]

LIVE_DAT_MARKERS = {
    "vision_probe_started",
    "vision_probe_completed",
}

LIVE_ASSISTANT_MARKERS = {
    "golden_turn_started",
    "golden_turn_completed",
    "voice_stt_final",
    "voice_stt_stable_partial_finalized",
    "voice_turn_auto_finalized",
    "voice_turn_completed",
    "voice_tts_started",
    "voice_tts_finished",
}

SPOKEN_TURN_REQUIRED_EVENTS = {
    "voice_turn_completed",
    "golden_turn_started",
    "golden_turn_completed",
    "voice_tts_started",
    "voice_tts_finished",
}

SPOKEN_TURN_STT_EVENTS = {
    "voice_stt_final",
    "voice_turn_auto_finalized",
    "voice_stt_stable_partial_finalized",
}


def load_events(db_path: Path, since_minutes: float) -> list[dict[str, Any]]:
    cutoff = time.time() - since_minutes * 60
    with sqlite3.connect(db_path) as conn:
        rows = conn.execute(
            """
            SELECT id, received_at, source, level, message, app_time, raw
            FROM events
            WHERE received_at >= ?
            ORDER BY id ASC
            """,
            (cutoff,),
        ).fetchall()

    events: list[dict[str, Any]] = []
    for row in rows:
        try:
            raw = json.loads(row[6])
        except json.JSONDecodeError:
            raw = {}
        events.append(
            {
                "id": row[0],
                "received_at": row[1],
                "source": row[2],
                "level": row[3],
                "message": row[4],
                "app_time": row[5],
                "raw": raw,
            }
        )
    return events


def event_name(event: dict[str, Any]) -> str:
    raw = event["raw"]
    for key in ("event", "type", "name"):
        value = raw.get(key)
        if isinstance(value, str):
            return value
    message = event.get("message") or ""
    if message.startswith("agent_event:"):
        return message.split(":", 1)[1].strip()
    return message


def payload(event: dict[str, Any]) -> dict[str, Any]:
    raw = event["raw"]
    nested = raw.get("payload")
    if isinstance(nested, dict):
        merged = dict(nested)
        for key, value in raw.items():
            if key not in {"payload", "raw"}:
                merged.setdefault(key, value)
        return merged
    return raw


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default="artifacts/artemis-live/artemis_logs.sqlite3")
    parser.add_argument("--since-minutes", type=float, default=180)
    parser.add_argument("--require-live-assistant", action="store_true")
    args = parser.parse_args()

    db_path = Path(args.db).expanduser().resolve()
    if not db_path.exists():
        print(f"FAIL: telemetry DB not found: {db_path}", file=sys.stderr)
        return 2

    events = load_events(db_path, args.since_minutes)
    names = [event_name(event) for event in events]
    name_set = set(names)
    golden_completed = [
        event for event in events if event_name(event) == "golden_turn_completed"
    ]
    events_by_turn: dict[str, set[str]] = {}
    for event in events:
        body = payload(event)
        turn_id = body.get("turn_id")
        if isinstance(turn_id, str) and turn_id:
            events_by_turn.setdefault(turn_id, set()).add(event_name(event))

    complete_spoken_turns = [
        turn_id
        for turn_id, turn_events in events_by_turn.items()
        if SPOKEN_TURN_REQUIRED_EVENTS.issubset(turn_events)
        and bool(turn_events & SPOKEN_TURN_STT_EVENTS)
    ]
    dat_seen = bool(name_set & LIVE_DAT_MARKERS) or any(
        "Received Meta DAT frame" in (event.get("message") or "") for event in events
    )
    assistant_seen = bool(complete_spoken_turns)

    missing_by_turn: list[tuple[int, list[str]]] = []
    for event in golden_completed:
        body = payload(event)
        missing = [field for field in REQUIRED_TURN_FIELDS if field not in body]
        if missing:
            missing_by_turn.append((event["id"], missing))

    evidence_class = "component/no_live_evidence"
    if dat_seen:
        evidence_class = "live_dat"
    if assistant_seen and not missing_by_turn:
        evidence_class = "live_assistant"

    print(f"events_checked={len(events)}")
    print(f"evidence_class={evidence_class}")
    print(f"live_dat_seen={dat_seen}")
    print(f"golden_turn_completed={len(golden_completed)}")
    print(f"complete_spoken_turns={len(complete_spoken_turns)}")
    print(f"live_assistant_seen={assistant_seen}")

    if missing_by_turn:
        for event_id, missing in missing_by_turn:
            print(f"FAIL: event {event_id} missing fields: {', '.join(missing)}", file=sys.stderr)
        return 1

    if args.require_live_assistant and evidence_class != "live_assistant":
        print("FAIL: required live assistant evidence was not present.", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
