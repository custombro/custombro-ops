from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Iterable

ROOT = Path(sys.argv[1])
CONTROL_ROOT = Path(sys.argv[2])
OUTPUT_ROOT = Path(sys.argv[3])
SNAPSHOT = ROOT / "state" / "current_snapshot_runtime.json"

VALID_ACTIONS = {"BUY", "HOLD", "SELL_ALL", "SWITCH", "WAIT"}
SENSITIVE_KEY_RE = re.compile(
    r"(?i)(app.?secret|secret|authorization|access.?token|refresh.?token|account.?number|cano|acct.?no|계좌번호)"
)
STRATEGY_SECTION_RE = re.compile(r"(?i)(stage13l|strategy|decision|execution|performance)")
MARKET_SECTION_RE = re.compile(r"(?i)(market|regime|breadth|flow|index|kospi|kosdaq|volatility|trend)")
RISK_SECTION_RE = re.compile(r"(?i)(risk|gate|block|ready|authority|order|transport|nosend|safety|reconciliation)")
PROVENANCE_KEY_RE = re.compile(r"(?i)(generation|lineage|proof.?hash|source.?hash|strategy.?hash|version|captured.?at|kst.?timestamp)")
REASON_KEY_RE = re.compile(r"(?i)(reason|rationale|explanation|evidence|basis|근거|이유)")
ACTION_KEY_RE = re.compile(r"(?i)(execution.?action|strategy.?action|decision.?action|action)")
TIME_KEY_RE = re.compile(r"(?i)(kst.?timestamp|strategy.?time|decision.?time|captured.?at|created.?at|timestamp)")


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def file_hash(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def atomic_write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, default=str),
        encoding="utf-8-sig",
    )
    os.replace(temporary, path)


def sanitize(value: Any, key_path: str = "$", depth: int = 0) -> Any:
    if depth > 20:
        return "[DEPTH_LIMIT]"
    if isinstance(value, dict):
        result: dict[str, Any] = {}
        for key, item in value.items():
            key_text = str(key)
            path = key_path + "." + key_text
            if SENSITIVE_KEY_RE.search(key_text):
                result[key_text] = "[REDACTED]"
            else:
                result[key_text] = sanitize(item, path, depth + 1)
        return result
    if isinstance(value, list):
        return [sanitize(item, key_path + "[]", depth + 1) for item in value[:500]]
    if isinstance(value, str):
        return value[:10000]
    return value


def walk(value: Any, path: str = "$") -> Iterable[tuple[str, str, Any]]:
    if isinstance(value, dict):
        for key, item in value.items():
            child = path + "." + str(key)
            yield child, str(key), item
            yield from walk(item, child)
    elif isinstance(value, list):
        for index, item in enumerate(value[:500]):
            child = path + "[" + str(index) + "]"
            yield child, str(index), item
            yield from walk(item, child)


def collect_sections(snapshot: dict[str, Any], pattern: re.Pattern[str]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in snapshot.items():
        if pattern.search(str(key)):
            result[str(key)] = sanitize(value, "$." + str(key))
    return result


def collect_matching_scalars(
    snapshot: Any,
    pattern: re.Pattern[str],
    max_items: int = 500,
) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for path, key, value in walk(snapshot):
        if not pattern.search(key):
            continue
        if isinstance(value, (dict, list)):
            continue
        result.append({"path": path, "value": sanitize(value, path)})
        if len(result) >= max_items:
            break
    return result


def collect_numeric_context(snapshot: Any, max_items: int = 1200) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for path, _, value in walk(snapshot):
        lower = path.lower()
        if not any(
            token in lower
            for token in (
                "strategy", "stage13l", "market", "candidate", "risk", "gate",
                "score", "threshold", "price", "volume", "breadth", "flow",
                "volatility", "return", "momentum", "signal", "account",
            )
        ):
            continue
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            continue
        result.append({"path": path, "value": value})
        if len(result) >= max_items:
            break
    return result


def first_scalar(snapshot: Any, pattern: re.Pattern[str], validator=None) -> tuple[str | None, Any]:
    for path, key, value in walk(snapshot):
        if not pattern.search(key):
            continue
        if isinstance(value, (dict, list)):
            continue
        if validator is not None and not validator(value):
            continue
        return path, value
    return None, None


def action_value(snapshot: Any) -> tuple[str | None, str | None]:
    candidates: list[tuple[int, str, str]] = []
    for path, key, value in walk(snapshot):
        if not ACTION_KEY_RE.search(key):
            continue
        text = str(value).strip().upper()
        if text not in VALID_ACTIONS:
            continue
        score = 0
        lower = path.lower()
        if "stage13l" in lower:
            score += 100
        if "executionaction" in re.sub(r"[^a-z0-9]", "", key.lower()):
            score += 50
        if "strategy" in lower or "decision" in lower:
            score += 20
        candidates.append((score, path, text))
    if not candidates:
        return None, None
    candidates.sort(reverse=True)
    _, path, text = candidates[0]
    return path, text


def timestamp_value(snapshot: Any) -> tuple[str | None, Any]:
    preferred = []
    for path, key, value in walk(snapshot):
        if not TIME_KEY_RE.search(key):
            continue
        if isinstance(value, (dict, list)) or value in (None, ""):
            continue
        score = 0
        lower = path.lower()
        if "stage13l" in lower or "strategy" in lower or "decision" in lower:
            score += 100
        if "ksttimestamp" in re.sub(r"[^a-z0-9]", "", key.lower()):
            score += 50
        preferred.append((score, path, value))
    if not preferred:
        return None, None
    preferred.sort(key=lambda item: (item[0], item[1]), reverse=True)
    _, path, value = preferred[0]
    return path, value


def candidate_payload(snapshot: dict[str, Any]) -> Any:
    value = snapshot.get("candidates")
    if value is not None:
        return sanitize(value, "$.candidates")
    for key, item in snapshot.items():
        if re.search(r"(?i)(candidate|ranking|top5|research)", str(key)):
            return sanitize(item, "$." + str(key))
    return None


def build_record(snapshot: dict[str, Any]) -> dict[str, Any]:
    captured_at = dt.datetime.now().astimezone().isoformat(timespec="seconds")
    source_hash = file_hash(SNAPSHOT)
    action_path, action = action_value(snapshot)
    time_path, strategy_time = timestamp_value(snapshot)
    reason_candidates = collect_matching_scalars(snapshot, REASON_KEY_RE, 800)
    provenance = collect_matching_scalars(snapshot, PROVENANCE_KEY_RE, 800)
    strategy_sections = collect_sections(snapshot, STRATEGY_SECTION_RE)
    market_sections = collect_sections(snapshot, MARKET_SECTION_RE)
    risk_sections = collect_sections(snapshot, RISK_SECTION_RE)
    candidates = candidate_payload(snapshot)
    numeric_context = collect_numeric_context(snapshot)

    completeness = {
        "action": action is not None,
        "strategy_time": strategy_time is not None,
        "reason": len(reason_candidates) > 0,
        "strategy_sections": len(strategy_sections) > 0,
        "market_context": len(market_sections) > 0,
        "risk_context": len(risk_sections) > 0,
        "candidate_context": candidates is not None,
        "numeric_context": len(numeric_context) > 0,
        "provenance": len(provenance) > 0,
    }
    detailed_ready = all(completeness.values())

    event_material = {
        "strategy_time": strategy_time,
        "action": action,
        "strategy_sections": strategy_sections,
        "reason_candidates": reason_candidates,
        "market_sections": market_sections,
        "risk_sections": risk_sections,
        "candidate_payload": candidates,
        "numeric_context": numeric_context,
        "provenance": provenance,
    }
    event_id = sha256_bytes(
        json.dumps(event_material, ensure_ascii=False, sort_keys=True, default=str).encode("utf-8")
    )

    return {
        "record_type": "AUTOTRADE_CLEAN_DETAILED_STRATEGY_RECORD_V10",
        "record_version": "10.0.0",
        "captured_at": captured_at,
        "source_snapshot": str(SNAPSHOT),
        "source_snapshot_hash": source_hash,
        "event_id": event_id,
        "manual_value_input_used": False,
        "manual_override_allowed": False,
        "broker_order_attempted": False,
        "database_direct_write_used": False,
        "action": action,
        "action_path": action_path,
        "strategy_time": sanitize(strategy_time, time_path or "$.timestamp"),
        "strategy_time_path": time_path,
        "reason_candidates": reason_candidates,
        "strategy_sections": strategy_sections,
        "market_context": market_sections,
        "risk_and_gate_context": risk_sections,
        "candidate_context": candidates,
        "numeric_context": numeric_context,
        "provenance": provenance,
        "completeness": completeness,
        "detailed_ready": detailed_ready,
        "generic_summary_only": False,
        "raw_snapshot_preserved": sanitize(snapshot),
    }


def load_index(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"event_ids": [], "last_seen_at": None, "last_recorded_at": None}
    try:
        payload = load_json(path)
        if isinstance(payload, dict):
            payload.setdefault("event_ids", [])
            return payload
    except Exception:
        pass
    return {"event_ids": [], "last_seen_at": None, "last_recorded_at": None}


def main() -> int:
    if not SNAPSHOT.exists():
        raise RuntimeError("CURRENT_SNAPSHOT_MISSING:" + str(SNAPSHOT))
    payload = load_json(SNAPSHOT)
    if not isinstance(payload, dict):
        raise RuntimeError("CURRENT_SNAPSHOT_ROOT_NOT_OBJECT")

    OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)
    record = build_record(payload)
    now = dt.datetime.now().astimezone()
    daily_path = OUTPUT_ROOT / ("strategy_records_" + now.strftime("%Y%m%d") + ".ndjson")
    latest_path = OUTPUT_ROOT / "DETAILED_STRATEGY_LATEST.json"
    health_path = OUTPUT_ROOT / "DETAILED_STRATEGY_RECORDER_HEALTH.json"
    index_path = OUTPUT_ROOT / "DETAILED_STRATEGY_EVENT_INDEX.json"

    index = load_index(index_path)
    event_ids = [str(item) for item in index.get("event_ids", [])]
    duplicate = record["event_id"] in set(event_ids)

    if not duplicate:
        with daily_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=False, separators=(",", ":"), default=str))
            handle.write("\n")
        event_ids.append(record["event_id"])
        if len(event_ids) > 50000:
            event_ids = event_ids[-50000:]
        index["last_recorded_at"] = record["captured_at"]
        atomic_write_json(latest_path, record)

    index["event_ids"] = event_ids
    index["last_seen_at"] = record["captured_at"]
    index["last_source_snapshot_hash"] = record["source_snapshot_hash"]
    index["last_event_id"] = record["event_id"]
    atomic_write_json(index_path, index)

    health = {
        "status": "PASS",
        "captured_at": record["captured_at"],
        "duplicate_event": duplicate,
        "event_id": record["event_id"],
        "source_snapshot_hash": record["source_snapshot_hash"],
        "detailed_ready": record["detailed_ready"],
        "completeness": record["completeness"],
        "reason_candidate_count": len(record["reason_candidates"]),
        "numeric_context_count": len(record["numeric_context"]),
        "provenance_count": len(record["provenance"]),
        "manual_value_input_used": False,
        "generic_summary_only": False,
        "daily_file": str(daily_path),
        "latest_file": str(latest_path),
        "index_file": str(index_path),
    }
    atomic_write_json(health_path, health)

    print("FINAL_STATUS=PASS_DETAILED_STRATEGY_RECORDER_V10")
    print("EVENT_RECORDED=" + str(not duplicate).upper())
    print("DUPLICATE_EVENT=" + str(duplicate).upper())
    print("DETAILED_RECORD_READY=" + str(record["detailed_ready"]).upper())
    print("STRATEGY_ACTION=" + str(record.get("action") or "UNCONFIRMED"))
    print("REASON_CANDIDATE_COUNT=" + str(len(record["reason_candidates"])))
    print("NUMERIC_CONTEXT_COUNT=" + str(len(record["numeric_context"])))
    print("PROVENANCE_FIELD_COUNT=" + str(len(record["provenance"])))
    print("MANUAL_VALUE_INPUT_USED=FALSE")
    print("GENERIC_SUMMARY_ONLY=FALSE")
    print("DAILY_RECORD_FILE=" + str(daily_path))
    print("LATEST_RECORD_FILE=" + str(latest_path))
    print("HEALTH_FILE=" + str(health_path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
