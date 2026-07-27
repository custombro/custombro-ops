#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = 'C:\AUTOTRADE_CLEAN'
$ControlRoot = 'C:\Users\hjk86\AUTOTRADE_CONTROL'
$LabRoot = Join-Path $ControlRoot 'FACT_DASHBOARD_V2_2_LAB'
$EvidenceRoot = Join-Path $LabRoot 'evidence'
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$RunRoot = Join-Path $LabRoot ('source_selection_' + $Stamp)
$Report = Join-Path $RunRoot 'CANONICAL_SOURCE_SELECTION_AUDIT.txt'
$Contract = Join-Path $RunRoot 'OFFLINE_SOURCE_CONTRACT.json'
$Helper = Join-Path $RunRoot 'canonical_source_selector.py'
$Database = Join-Path $Root 'state\autotrade.db'

New-Item -ItemType Directory -Path $RunRoot -Force | Out-Null

$Results = New-Object System.Collections.Generic.List[string]

function Add-Result {
    param([string]$Key, [object]$Value)

    if ($Value -is [bool]) {
        $Text = $Value.ToString().ToUpperInvariant()
    }
    elseif ($Value -is [string]) {
        $Text = $Value
    }
    else {
        $Text = $Value | ConvertTo-Json -Depth 20 -Compress
    }

    [void]$Results.Add($Key + '=' + $Text)
}

function Get-PythonPath {
    $Known = 'C:\Program Files\Python312\python.exe'
    if (Test-Path -LiteralPath $Known) {
        return $Known
    }
    return (Get-Command python.exe -ErrorAction Stop).Source
}

function Get-RuntimeProcesses {
    return @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match '^pythonw?\.exe$' -and
            [string]$_.CommandLine -like '*C:\AUTOTRADE_CLEAN\app\stage12_runtime_bootstrap.py*' -and
            [string]$_.CommandLine -like '*--mode persistent*'
        }
    )
}

function Get-HttpProbe {
    param([string]$Path)

    $Watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $Response = Invoke-WebRequest `
            -Uri ('http://127.0.0.1:3100' + $Path) `
            -UseBasicParsing `
            -TimeoutSec 12
        $Watch.Stop()
        return [ordered]@{
            status = [int]$Response.StatusCode
            milliseconds = [int]$Watch.ElapsedMilliseconds
        }
    }
    catch {
        $Watch.Stop()
        return [ordered]@{
            status = 0
            milliseconds = [int]$Watch.ElapsedMilliseconds
        }
    }
}

function Get-OrderLedgerCount {
    $Python = Get-PythonPath
    $Code = @'
import sqlite3
import sys
path = sys.argv[1]
con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
try:
    print(int(con.execute("SELECT COUNT(*) FROM order_ledger").fetchone()[0]))
finally:
    con.close()
'@
    $Temporary = Join-Path $env:TEMP (
        'autotrade_source_select_order_count_' +
        [guid]::NewGuid().ToString('N') +
        '.py'
    )
    [IO.File]::WriteAllText(
        $Temporary,
        $Code,
        (New-Object System.Text.UTF8Encoding($false))
    )
    try {
        $Output = @(& $Python $Temporary $Database 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw ('ORDER_LEDGER_READ_FAILED:' + ($Output -join ' '))
        }
        return [int]([string]($Output | Select-Object -Last 1)).Trim()
    }
    finally {
        Remove-Item -LiteralPath $Temporary -Force -ErrorAction SilentlyContinue
    }
}

function Get-CriticalFingerprint {
    $Targets = @(
        (Join-Path $Root 'app\dashboard.py'),
        (Join-Path $Root 'web\index.html'),
        (Join-Path $Root 'app\stage12_runtime_bootstrap.py')
    )

    $Builder = New-Object System.Text.StringBuilder
    foreach ($Target in $Targets) {
        if (Test-Path -LiteralPath $Target) {
            $Hash = (
                Get-FileHash -LiteralPath $Target -Algorithm SHA256
            ).Hash.ToUpperInvariant()
            [void]$Builder.AppendLine($Target + '|' + $Hash)
        }
    }

    $StrategyFiles = @(
        Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $Name = $_.Name.ToLowerInvariant()
            $Name.Contains('strategy') -or
            $Name.Contains('stage13l') -or
            $Name.Contains('order_authority')
        } |
        Sort-Object FullName |
        Select-Object -First 500
    )

    foreach ($File in $StrategyFiles) {
        $Hash = (
            Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256
        ).Hash.ToUpperInvariant()
        [void]$Builder.AppendLine($File.FullName + '|' + $Hash)
    }

    $Bytes = [Text.Encoding]::UTF8.GetBytes($Builder.ToString())
    $Sha = [Security.Cryptography.SHA256]::Create()
    try {
        $Digest = $Sha.ComputeHash($Bytes)
    }
    finally {
        $Sha.Dispose()
    }

    return [ordered]@{
        count = $Targets.Count + $StrategyFiles.Count
        sha256 = ([BitConverter]::ToString($Digest)).Replace('-', '')
    }
}

$PythonSelector = @'
from __future__ import annotations

import datetime as dt
import json
import re
import sys
from pathlib import Path
from typing import Any

EVIDENCE_ROOT = Path(sys.argv[1])
OUTPUT = Path(sys.argv[2])

GROUPS = [
    "REALIZED_NET_PNL",
    "GROSS_TRADE_PNL",
    "FEE",
    "TAX",
    "LOAN_INTEREST",
    "STRATEGY_ACTION",
    "STRATEGY_REASON",
    "STRATEGY_TIME",
    "CANDIDATE_REASON",
    "CANDIDATE_SCORE",
    "GENERATION",
]

POSITIVE = [
    (re.compile(r"(?i)(kis|broker|official|authority|verify|readback|latest|canonical)"), 40),
    (re.compile(r"(?i)(daily|period|trade|profit|pnl|fill|settlement|account)"), 20),
    (re.compile(r"(?i)(current|final|confirmed|captured|completed)"), 12),
]

NEGATIVE = [
    (re.compile(r"(?i)(backup|archive|old|temp|work_|self.?test|synthetic|sample|fixture)"), -45),
    (re.compile(r"(?i)(installer|report|audit|evidence|candidate|debug)"), -18),
    (re.compile(r"(?i)(failed|rollback|error)"), -20),
]

EXACT_FIELD_BONUS = {
    "REALIZED_NET_PNL": [
        re.compile(r"(?i)(daily.?trading.?pnl|net.?realized|realized.?net|net.?pnl|rlzt.*pfls)"),
    ],
    "GROSS_TRADE_PNL": [
        re.compile(r"(?i)(gross.?pnl|trade.?profit|gross.?profit)"),
    ],
    "FEE": [
        re.compile(r"(?i)(total.?fee|commission|fee.?amount|fee)"),
    ],
    "TAX": [
        re.compile(r"(?i)(transaction.?tax|tax.?amount|tax)"),
    ],
    "LOAN_INTEREST": [
        re.compile(r"(?i)(loan.?interest|interest.?amount|interest)"),
    ],
    "STRATEGY_ACTION": [
        re.compile(r"(?i)(strategy.*action|execution.*action|decision.*action|action)"),
    ],
    "STRATEGY_REASON": [
        re.compile(r"(?i)(strategy.*reason|decision.*reason|rationale|reason)"),
    ],
    "STRATEGY_TIME": [
        re.compile(r"(?i)(strategy.*time|decision.*time|created.?at|captured.?at|timestamp)"),
    ],
    "CANDIDATE_REASON": [
        re.compile(r"(?i)(candidate.*reason|selection.*reason|promotion.*evidence|ranking.*reason)"),
    ],
    "CANDIDATE_SCORE": [
        re.compile(r"(?i)(candidate.*score|ranking.*score|score)"),
    ],
    "GENERATION": [
        re.compile(r"(?i)(account.?generation|generation|lineage|proof.?hash|source.?hash)"),
    ],
}


def latest_manifest() -> Path:
    candidates = sorted(
        EVIDENCE_ROOT.glob("AUDIT_V2_*/READ_ONLY_EVIDENCE_AUDIT_V2.json"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    if not candidates:
        raise RuntimeError("LATEST_AUDIT_MANIFEST_NOT_FOUND")
    return candidates[0]


def numeric_like(value: Any) -> bool:
    if isinstance(value, bool) or value is None:
        return False
    if isinstance(value, (int, float)):
        return True
    if isinstance(value, str):
        text = value.replace(",", "").replace("+", "").strip()
        return bool(re.fullmatch(r"-?\d+(?:\.\d+)?", text))
    return False


def score_item(item: dict[str, Any]) -> tuple[int, list[str]]:
    group = str(item.get("group", ""))
    file_path = str(item.get("file", ""))
    field_path = str(item.get("field", ""))
    combined = file_path + "|" + field_path
    value = item.get("value")
    score = 0
    reasons: list[str] = []

    for pattern, points in POSITIVE:
        if pattern.search(combined):
            score += points
            reasons.append(f"positive:{points}")

    for pattern, points in NEGATIVE:
        if pattern.search(combined):
            score += points
            reasons.append(f"negative:{points}")

    for pattern in EXACT_FIELD_BONUS.get(group, []):
        if pattern.search(field_path):
            score += 45
            reasons.append("exact_field:+45")
            break

    if group in {"REALIZED_NET_PNL", "GROSS_TRADE_PNL", "FEE", "TAX", "LOAN_INTEREST", "CANDIDATE_SCORE"}:
        if numeric_like(value):
            score += 18
            reasons.append("numeric:+18")
        else:
            score -= 25
            reasons.append("non_numeric:-25")

    modified = item.get("modified")
    if isinstance(modified, str):
        try:
            age = dt.datetime.now() - dt.datetime.fromisoformat(modified)
            if age.days <= 1:
                score += 15
                reasons.append("recent_1d:+15")
            elif age.days <= 7:
                score += 8
                reasons.append("recent_7d:+8")
        except Exception:
            pass

    if "[sensitive hidden]" in str(value).lower():
        score -= 100
        reasons.append("sensitive:-100")

    return score, reasons


def distinct_ranked(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    ranked = []
    seen = set()
    for item in items:
        score, reasons = score_item(item)
        key = (item.get("group"), item.get("file"), item.get("field"), json.dumps(item.get("value"), ensure_ascii=False, default=str))
        if key in seen:
            continue
        seen.add(key)
        enriched = dict(item)
        enriched["selection_score"] = score
        enriched["selection_reasons"] = reasons
        ranked.append(enriched)
    ranked.sort(key=lambda x: (x["selection_score"], str(x.get("modified", ""))), reverse=True)
    return ranked


def conflict_summary(ranked: list[dict[str, Any]]) -> dict[str, Any]:
    top = ranked[:12]
    values = []
    for item in top:
        value = item.get("value")
        if numeric_like(value):
            values.append(str(value).replace(",", ""))
    unique = sorted(set(values))
    return {
        "numeric_value_count": len(values),
        "unique_numeric_values": unique[:20],
        "conflict_detected": len(unique) > 1,
    }


def main() -> int:
    manifest_path = latest_manifest()
    payload = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
    evidence = payload.get("json_evidence", [])
    if not isinstance(evidence, list):
        raise RuntimeError("INVALID_EVIDENCE_LIST")

    grouped: dict[str, list[dict[str, Any]]] = {group: [] for group in GROUPS}
    for item in evidence:
        if not isinstance(item, dict):
            continue
        group = str(item.get("group", ""))
        if group in grouped:
            grouped[group].append(item)

    selections: dict[str, Any] = {}
    for group in GROUPS:
        ranked = distinct_ranked(grouped[group])
        top = ranked[:20]
        selections[group] = {
            "candidate_count": len(ranked),
            "top_candidates": top,
            "conflict": conflict_summary(ranked),
            "canonical_candidate": top[0] if top else None,
            "eligible_for_offline_build": bool(top and top[0]["selection_score"] >= 50),
        }

    required_financial = ["REALIZED_NET_PNL", "FEE", "TAX"]
    required_strategy = ["STRATEGY_ACTION", "STRATEGY_REASON", "STRATEGY_TIME"]
    required_candidate = ["CANDIDATE_REASON", "CANDIDATE_SCORE"]

    financial_ready = all(selections[g]["eligible_for_offline_build"] for g in required_financial)
    strategy_ready = all(selections[g]["eligible_for_offline_build"] for g in required_strategy)
    candidate_ready = all(selections[g]["eligible_for_offline_build"] for g in required_candidate)

    output = {
        "contract_type": "AUTOTRADE_CLEAN_V2_2_OFFLINE_SOURCE_CONTRACT",
        "created_at": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "source_manifest": str(manifest_path),
        "read_only": True,
        "live_install_allowed": False,
        "manual_value_override_allowed": False,
        "zero_when_unconfirmed_allowed": False,
        "financial_sources_ready": financial_ready,
        "strategy_timeline_sources_ready": strategy_ready,
        "candidate_explanation_sources_ready": candidate_ready,
        "all_offline_build_inputs_ready": financial_ready and strategy_ready and candidate_ready,
        "selections": selections,
    }

    OUTPUT.write_text(
        json.dumps(output, ensure_ascii=False, indent=2, default=str),
        encoding="utf-8-sig",
    )

    print("FINAL_STATUS=PASS_CANONICAL_SOURCE_SELECTION_AUDIT")
    print(f"SOURCE_MANIFEST={manifest_path}")
    print(f"FINANCIAL_SOURCES_READY={str(financial_ready).upper()}")
    print(f"STRATEGY_TIMELINE_SOURCES_READY={str(strategy_ready).upper()}")
    print(f"CANDIDATE_EXPLANATION_SOURCES_READY={str(candidate_ready).upper()}")
    print(f"ALL_OFFLINE_BUILD_INPUTS_READY={str(output['all_offline_build_inputs_ready']).upper()}")
    for group in GROUPS:
        selected = selections[group]["canonical_candidate"]
        if selected:
            print(f"TOP_{group}_SCORE={selected['selection_score']}")
            print(f"TOP_{group}_FILE={selected.get('file', '')}")
            print(f"TOP_{group}_FIELD={selected.get('field', '')}")
            print(f"TOP_{group}_CONFLICT={str(selections[group]['conflict']['conflict_detected']).upper()}")
        else:
            print(f"TOP_{group}_SCORE=NONE")
            print(f"TOP_{group}_CONFLICT=FALSE")
    print(f"OFFLINE_SOURCE_CONTRACT={OUTPUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
'@

[IO.File]::WriteAllText(
    $Helper,
    $PythonSelector,
    (New-Object System.Text.UTF8Encoding($false))
)

Add-Result 'FINAL_STATUS' 'RUNNING'
Add-Result 'EXECUTION_MODE' 'V2_2_CANONICAL_SOURCE_SELECTION_AUDIT_READ_ONLY'
Add-Result 'LIVE_DASHBOARD_MODIFIED' $false
Add-Result 'AUTOTRADE_STRATEGY_MODIFIED' $false
Add-Result 'ORDER_PATH_MODIFIED' $false
Add-Result 'DATABASE_DIRECT_WRITE_USED' $false
Add-Result 'BROKER_ORDER_ATTEMPTED' $false
Add-Result 'ORDER_TRANSPORT_CALLS' 0
Add-Result 'SCHEDULED_TASK_MODIFIED' $false
Add-Result 'RUNTIME_RESTARTED' $false
Add-Result 'V2_2_LIVE_INSTALL_ALLOWED' $false

$Success = $false

try {
    foreach ($Required in @($Root, $ControlRoot, $EvidenceRoot, $Database)) {
        if (-not (Test-Path -LiteralPath $Required)) {
            throw ('REQUIRED_PATH_MISSING:' + $Required)
        }
    }

    $RuntimeBefore = @(Get-RuntimeProcesses).Count
    $RootBefore = Get-HttpProbe '/'
    $HealthBefore = Get-HttpProbe '/api/v1/health'
    $SnapshotBefore = Get-HttpProbe '/api/v1/snapshot'
    $OrderBefore = Get-OrderLedgerCount
    $FingerprintBefore = Get-CriticalFingerprint

    Add-Result 'RUNTIME_PROCESS_COUNT_BEFORE' $RuntimeBefore
    Add-Result 'DASHBOARD_HTTP_ROOT_BEFORE' $RootBefore.status
    Add-Result 'DASHBOARD_LATENCY_MS_ROOT_BEFORE' $RootBefore.milliseconds
    Add-Result 'DASHBOARD_HTTP_HEALTH_BEFORE' $HealthBefore.status
    Add-Result 'DASHBOARD_LATENCY_MS_HEALTH_BEFORE' $HealthBefore.milliseconds
    Add-Result 'DASHBOARD_HTTP_SNAPSHOT_BEFORE' $SnapshotBefore.status
    Add-Result 'DASHBOARD_LATENCY_MS_SNAPSHOT_BEFORE' $SnapshotBefore.milliseconds
    Add-Result 'ORDER_LEDGER_COUNT_BEFORE' $OrderBefore
    Add-Result 'CRITICAL_FILE_COUNT_BEFORE' $FingerprintBefore.count
    Add-Result 'CRITICAL_FINGERPRINT_BEFORE' $FingerprintBefore.sha256

    if ($RuntimeBefore -ne 1) {
        throw 'RUNTIME_COUNT_NOT_ONE'
    }
    if ($OrderBefore -lt 0) {
        throw 'ORDER_LEDGER_UNREADABLE'
    }

    $Python = Get-PythonPath
    $CompileOutput = @(& $Python -m py_compile $Helper 2>&1)
    $CompileExit = $LASTEXITCODE
    Add-Result 'SELECTOR_COMPILE_EXIT_CODE' $CompileExit
    if ($CompileExit -ne 0) {
        throw ('SELECTOR_COMPILE_FAILED:' + ($CompileOutput -join ' '))
    }
    Add-Result 'SELECTOR_COMPILE' 'PASS'

    $SelectOutput = @(& $Python $Helper $EvidenceRoot $Contract 2>&1)
    $SelectExit = $LASTEXITCODE
    $SelectText = $SelectOutput -join [Environment]::NewLine
    Add-Result 'SELECTOR_EXIT_CODE' $SelectExit

    if ($SelectExit -ne 0) {
        throw ('SELECTOR_FAILED:' + $SelectText)
    }
    if (-not $SelectText.Contains('FINAL_STATUS=PASS_CANONICAL_SOURCE_SELECTION_AUDIT')) {
        throw ('SELECTOR_PASS_MARKER_MISSING:' + $SelectText)
    }

    foreach ($Line in $SelectOutput) {
        $Text = [string]$Line
        if (
            $Text.StartsWith('SOURCE_MANIFEST=') -or
            $Text.StartsWith('FINANCIAL_SOURCES_READY=') -or
            $Text.StartsWith('STRATEGY_TIMELINE_SOURCES_READY=') -or
            $Text.StartsWith('CANDIDATE_EXPLANATION_SOURCES_READY=') -or
            $Text.StartsWith('ALL_OFFLINE_BUILD_INPUTS_READY=') -or
            $Text.StartsWith('TOP_')
        ) {
            [void]$Results.Add($Text)
        }
    }

    $RuntimeAfter = @(Get-RuntimeProcesses).Count
    $RootAfter = Get-HttpProbe '/'
    $HealthAfter = Get-HttpProbe '/api/v1/health'
    $SnapshotAfter = Get-HttpProbe '/api/v1/snapshot'
    $OrderAfter = Get-OrderLedgerCount
    $FingerprintAfter = Get-CriticalFingerprint

    if ($RuntimeAfter -ne $RuntimeBefore) {
        throw 'RUNTIME_COUNT_CHANGED'
    }
    if ($OrderAfter -ne $OrderBefore) {
        throw 'ORDER_LEDGER_COUNT_CHANGED'
    }
    if ($FingerprintAfter.sha256 -ne $FingerprintBefore.sha256) {
        throw 'CRITICAL_FILE_FINGERPRINT_CHANGED'
    }

    Add-Result 'RUNTIME_PROCESS_COUNT_AFTER' $RuntimeAfter
    Add-Result 'DASHBOARD_HTTP_ROOT_AFTER' $RootAfter.status
    Add-Result 'DASHBOARD_LATENCY_MS_ROOT_AFTER' $RootAfter.milliseconds
    Add-Result 'DASHBOARD_HTTP_HEALTH_AFTER' $HealthAfter.status
    Add-Result 'DASHBOARD_LATENCY_MS_HEALTH_AFTER' $HealthAfter.milliseconds
    Add-Result 'DASHBOARD_HTTP_SNAPSHOT_AFTER' $SnapshotAfter.status
    Add-Result 'DASHBOARD_LATENCY_MS_SNAPSHOT_AFTER' $SnapshotAfter.milliseconds
    Add-Result 'ORDER_LEDGER_COUNT_AFTER' $OrderAfter
    Add-Result 'ORDER_LEDGER_COUNT_UNCHANGED' $true
    Add-Result 'CRITICAL_FILE_COUNT_AFTER' $FingerprintAfter.count
    Add-Result 'CRITICAL_FINGERPRINT_AFTER' $FingerprintAfter.sha256
    Add-Result 'CRITICAL_FILES_UNCHANGED' $true
    Add-Result 'OFFLINE_SOURCE_CONTRACT' $Contract
    Add-Result 'NEXT_STAGE' 'BUILD_OFFLINE_V2_2_PREVIEW_ONLY_IF_REQUIRED_SOURCES_READY'
    Add-Result 'FINAL_STATUS' 'PASS_V2_2_CANONICAL_SOURCE_SELECTION_AUDIT_NO_LIVE_MUTATION'
    $Success = $true
}
catch {
    Add-Result 'SOURCE_SELECTION_ERROR' $_.Exception.Message
    Add-Result 'FINAL_RUNTIME_PROCESS_COUNT' (@(Get-RuntimeProcesses).Count)
    try {
        Add-Result 'FINAL_ORDER_LEDGER_COUNT' (Get-OrderLedgerCount)
    }
    catch {
        Add-Result 'FINAL_ORDER_LEDGER_COUNT' 'READ_FAILED'
    }
    Add-Result 'LIVE_DASHBOARD_MODIFIED' $false
    Add-Result 'AUTOTRADE_STRATEGY_MODIFIED' $false
    Add-Result 'ORDER_PATH_MODIFIED' $false
    Add-Result 'DATABASE_DIRECT_WRITE_USED' $false
    Add-Result 'BROKER_ORDER_ATTEMPTED' $false
    Add-Result 'ORDER_TRANSPORT_CALLS' 0
    Add-Result 'SCHEDULED_TASK_MODIFIED' $false
    Add-Result 'RUNTIME_RESTARTED' $false
    Add-Result 'V2_2_LIVE_INSTALL_ALLOWED' $false
    Add-Result 'FINAL_STATUS' 'FAIL_V2_2_CANONICAL_SOURCE_SELECTION_AUDIT_NO_LIVE_MUTATION'
}

Add-Result 'REPORT' $Report

$CopyStatus = 'FAILED'
try {
    Set-Clipboard -Value ($Results -join [Environment]::NewLine)
    $CopyStatus = 'SUCCESS'
}
catch {
    $CopyStatus = 'FAILED'
}
Add-Result 'COPY_STATUS' $CopyStatus

$OutputText = ($Results -join [Environment]::NewLine) + [Environment]::NewLine
$Utf8Bom = New-Object System.Text.UTF8Encoding($true)
[IO.File]::WriteAllText($Report, $OutputText, $Utf8Bom)
Write-Output $OutputText

if ($Success) {
    exit 0
}
exit 1
