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
SENSITIVE_KEY_RE = re.compile(r"(?i)(app.?secret|secret|authorization|access.?token|refresh.?token|account.?number|cano|acct.?no|계좌번호)")
STRATEGY_SECTION_RE = re.compile(r"(?i)(stage13l|strategy|decision|execution|performance)")
MARKET_SECTION_RE = re.compile(r"(?i)(market|regime|breadth|flow|index|kospi|kosdaq|volatility|trend)")
RISK_SECTION_RE = re.compile(r"(?i)(risk|gate|block|ready|authority|order|transport|nosend|safety|reconciliation)")
PROVENANCE_KEY_RE = re.compile(r"(?i)(generation|lineage|proof.?hash|source.?hash|strategy.?hash|version|captured.?at|kst.?timestamp)")
REASON_KEY_RE = re.compile(r"(?i)(reason|rationale|explanation|evidence|basis|근거|이유)")
ACTION_KEY_RE = re.compile(r"(?i)(execution.?action|strategy.?action|decision.?action|action)")
TIME_KEY_RE = re.compile(r"(?i)(kst.?timestamp|strategy.?time|decision.?time|captured.?at|created.?at|timestamp)")


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def file_hash(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def hash_json(value: Any) -> str:
    raw = json.dumps(value, ensure_ascii=False, sort_keys=True, default=str).encode("utf-8")
    return hashlib.sha256(raw).hexdigest().upper()


def atomic_write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2, default=str), encoding="utf-8-sig")
    os.replace(temporary, path)


def sanitize(value: Any, depth: int = 0) -> Any:
    if depth > 24:
        return "[DEPTH_LIMIT]"
    if isinstance(value, dict):
        result: dict[str, Any] = {}
        for key, item in value.items():
            key_text = str(key)
            result[key_text] = "[REDACTED]" if SENSITIVE_KEY_RE.search(key_text) else sanitize(item, depth + 1)
        return result
    if isinstance(value, list):
        return [sanitize(item, depth + 1) for item in value[:1000]]
    if isinstance(value, str):
        return value[:20000]
    return value


def walk(value: Any, path: str = "$") -> Iterable[tuple[str, str, Any]]:
    if isinstance(value, dict):
        for key, item in value.items():
            child = path + "." + str(key)
            yield child, str(key), item
            yield from walk(item, child)
    elif isinstance(value, list):
        for index, item in enumerate(value[:1000]):
            child = path + "[" + str(index) + "]"
            yield child, str(index), item
            yield from walk(item, child)


def collect_sections(snapshot: Any, pattern: re.Pattern[str], max_sections: int = 120) -> dict[str, Any]:
    result: dict[str, Any] = {}
    selected_paths: list[str] = []
    for path, key, value in walk(snapshot):
        if not pattern.search(key) or not isinstance(value, (dict, list)):
            continue
        if any(path.startswith(parent + ".") or path.startswith(parent + "[") for parent in selected_paths):
            continue
        result[path] = sanitize(value)
        selected_paths.append(path)
        if len(result) >= max_sections:
            break
    return result


def collect_scalars(snapshot: Any, pattern: re.Pattern[str], max_items: int) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for path, key, value in walk(snapshot):
        if pattern.search(key) and not isinstance(value, (dict, list)):
            result.append({"path": path, "value": sanitize(value)})
            if len(result) >= max_items:
                break
    return result


def collect_numeric_context(snapshot: Any, max_items: int = 2000) -> list[dict[str, Any]]:
    tokens = (
        "strategy", "stage13l", "market", "candidate", "risk", "gate", "score",
        "threshold", "price", "volume", "breadth", "flow", "volatility", "return",
        "momentum", "signal", "account", "cost", "spread", "liquidity",
    )
    result: list[dict[str, Any]] = []
    for path, _, value in walk(snapshot):
        if not any(token in path.lower() for token in tokens):
            continue
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            continue
        result.append({"path": path, "value": value})
        if len(result) >= max_items:
            break
    return result


def select_action(snapshot: Any) -> tuple[str | None, str | None]:
    candidates: list[tuple[int, str, str]] = []
    for path, key, value in walk(snapshot):
        if not ACTION_KEY_RE.search(key):
            continue
        text = str(value).strip().upper()
        if text not in VALID_ACTIONS:
            continue
        compact = re.sub(r"[^a-z0-9]", "", key.lower())
        score = 100 if "stage13l" in path.lower() else 0
        score += 50 if "executionaction" in compact else 0
        score += 20 if "strategy" in path.lower() or "decision" in path.lower() else 0
        candidates.append((score, path, text))
    if not candidates:
        return None, None
    candidates.sort(reverse=True)
    return candidates[0][1], candidates[0][2]


def select_timestamp(snapshot: Any) -> tuple[str | None, Any]:
    candidates: list[tuple[int, str, Any]] = []
    for path, key, value in walk(snapshot):
        if not TIME_KEY_RE.search(key) or isinstance(value, (dict, list)) or value in (None, ""):
            continue
        compact = re.sub(r"[^a-z0-9]", "", key.lower())
        score = 100 if any(token in path.lower() for token in ("stage13l", "strategy", "decision")) else 0
        score += 50 if "ksttimestamp" in compact else 0
        candidates.append((score, path, value))
    if not candidates:
        return None, None
    candidates.sort(key=lambda item: (item[0], item[1]), reverse=True)
    return candidates[0][1], candidates[0][2]


def select_candidate_context(snapshot: Any) -> tuple[str | None, Any]:
    if isinstance(snapshot, dict) and snapshot.get("candidates") is not None:
        return "$.candidates", sanitize(snapshot.get("candidates"))
    for path, key, value in walk(snapshot):
        if re.search(r"(?i)(candidate|ranking|top5|research)", key) and isinstance(value, (dict, list)):
            return path, sanitize(value)
    return None, None


def build_record(snapshot: dict[str, Any]) -> dict[str, Any]:
    captured_at = dt.datetime.now().astimezone().isoformat(timespec="seconds")
    action_path, action = select_action(snapshot)
    time_path, strategy_time = select_timestamp(snapshot)
    candidate_path, candidates = select_candidate_context(snapshot)
    reasons = collect_scalars(snapshot, REASON_KEY_RE, 1200)
    provenance = collect_scalars(snapshot, PROVENANCE_KEY_RE, 1200)
    strategy_sections = collect_sections(snapshot, STRATEGY_SECTION_RE)
    market_sections = collect_sections(snapshot, MARKET_SECTION_RE)
    risk_sections = collect_sections(snapshot, RISK_SECTION_RE)
    numeric_context = collect_numeric_context(snapshot)

    completeness = {
        "action": action is not None,
        "strategy_time": strategy_time is not None,
        "reason": len(reasons) > 0,
        "strategy_sections": len(strategy_sections) > 0,
        "market_context": len(market_sections) > 0,
        "risk_context": len(risk_sections) > 0,
        "candidate_context": candidates is not None,
        "numeric_context": len(numeric_context) > 0,
        "provenance": len(provenance) > 0,
    }
    event_payload = {
        "strategy_time": strategy_time,
        "action": action,
        "strategy_sections": strategy_sections,
        "market_context": market_sections,
        "risk_context": risk_sections,
        "candidate_context": candidates,
        "reasons": reasons,
        "numeric_context": numeric_context,
        "provenance": provenance,
    }

    return {
        "record_type": "AUTOTRADE_CLEAN_DETAILED_STRATEGY_RECORD_V10_1",
        "record_version": "10.1.0",
        "captured_at": captured_at,
        "source_snapshot": str(SNAPSHOT),
        "source_snapshot_hash": file_hash(SNAPSHOT),
        "event_id": hash_json(event_payload),
        "manual_value_input_used": False,
        "manual_override_allowed": False,
        "generic_summary_only": False,
        "broker_order_attempted": False,
        "database_direct_write_used": False,
        "action": action,
        "action_path": action_path,
        "strategy_time": sanitize(strategy_time),
        "strategy_time_path": time_path,
        "reason_candidates": reasons,
        "strategy_sections": strategy_sections,
        "market_context": market_sections,
        "risk_and_gate_context": risk_sections,
        "candidate_context_path": candidate_path,
        "candidate_context": candidates,
        "numeric_context": numeric_context,
        "provenance": provenance,
        "completeness": completeness,
        "detailed_ready": all(completeness.values()),
        "raw_snapshot_preserved": sanitize(snapshot),
    }


def load_index(path: Path) -> dict[str, Any]:
    if path.exists():
        try:
            value = load_json(path)
            if isinstance(value, dict):
                value.setdefault("event_ids", [])
                return value
        except Exception:
            pass
    return {"event_ids": [], "last_seen_at": None, "last_recorded_at": None}


def main() -> int:
    if not SNAPSHOT.exists():
        raise RuntimeError("CURRENT_SNAPSHOT_MISSING:" + str(SNAPSHOT))
    snapshot = load_json(SNAPSHOT)
    if not isinstance(snapshot, dict):
        raise RuntimeError("CURRENT_SNAPSHOT_ROOT_NOT_OBJECT")

    OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)
    record = build_record(snapshot)
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
            handle.write(json.dumps(record, ensure_ascii=False, separators=(",", ":"), default=str) + "\n")
        event_ids.append(record["event_id"])
        if len(event_ids) > 50000:
            event_ids = event_ids[-50000:]
        index["last_recorded_at"] = record["captured_at"]
        atomic_write_json(latest_path, record)

    index.update(
        {
            "event_ids": event_ids,
            "last_seen_at": record["captured_at"],
            "last_source_snapshot_hash": record["source_snapshot_hash"],
            "last_event_id": record["event_id"],
        }
    )
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
        "strategy_section_count": len(record["strategy_sections"]),
        "market_section_count": len(record["market_context"]),
        "risk_section_count": len(record["risk_and_gate_context"]),
        "manual_value_input_used": False,
        "generic_summary_only": False,
        "daily_file": str(daily_path),
        "latest_file": str(latest_path),
        "index_file": str(index_path),
    }
    atomic_write_json(health_path, health)

    print("FINAL_STATUS=PASS_DETAILED_STRATEGY_RECORDER_V10_1")
    print("EVENT_RECORDED=" + str(not duplicate).upper())
    print("DUPLICATE_EVENT=" + str(duplicate).upper())
    print("DETAILED_RECORD_READY=" + str(record["detailed_ready"]).upper())
    print("STRATEGY_ACTION=" + str(record.get("action") or "UNCONFIRMED"))
    print("REASON_CANDIDATE_COUNT=" + str(len(record["reason_candidates"])))
    print("NUMERIC_CONTEXT_COUNT=" + str(len(record["numeric_context"])))
    print("PROVENANCE_FIELD_COUNT=" + str(len(record["provenance"])))
    print("STRATEGY_SECTION_COUNT=" + str(len(record["strategy_sections"])))
    print("MARKET_SECTION_COUNT=" + str(len(record["market_context"])))
    print("RISK_SECTION_COUNT=" + str(len(record["risk_and_gate_context"])))
    print("MANUAL_VALUE_INPUT_USED=FALSE")
    print("GENERIC_SUMMARY_ONLY=FALSE")
    print("DAILY_RECORD_FILE=" + str(daily_path))
    print("LATEST_RECORD_FILE=" + str(latest_path))
    print("HEALTH_FILE=" + str(health_path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
