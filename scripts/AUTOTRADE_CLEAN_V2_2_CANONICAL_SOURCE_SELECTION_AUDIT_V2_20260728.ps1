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
$RunRoot = Join-Path $LabRoot ('source_selection_v2_' + $Stamp)
$Report = Join-Path $RunRoot 'CANONICAL_SOURCE_SELECTION_AUDIT_V2.txt'
$Contract = Join-Path $RunRoot 'OFFLINE_SOURCE_CONTRACT_V2.json'
$Helper = Join-Path $RunRoot 'canonical_source_selector_v2.py'
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
        $Text = $Value | ConvertTo-Json -Depth 30 -Compress
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
con = sqlite3.connect('file:' + path + '?mode=ro', uri=True)
try:
    print(int(con.execute('SELECT COUNT(*) FROM order_ledger').fetchone()[0]))
finally:
    con.close()
'@
    $Temporary = Join-Path $env:TEMP (
        'autotrade_source_select_v2_count_' +
        [guid]::NewGuid().ToString('N') +
        '.py'
    )
    [IO.File]::WriteAllText(
        $Temporary,
        $Code,
        (New-Object System.Text.ASCIIEncoding)
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

    $Files = @(
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

    $Builder = New-Object System.Text.StringBuilder
    foreach ($Target in $Targets) {
        if (Test-Path -LiteralPath $Target) {
            $Hash = (
                Get-FileHash -LiteralPath $Target -Algorithm SHA256
            ).Hash.ToUpperInvariant()
            [void]$Builder.AppendLine($Target + '|' + $Hash)
        }
    }
    foreach ($File in $Files) {
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
        count = $Targets.Count + $Files.Count
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
    'realized_net_pnl',
    'gross_trade_pnl',
    'fee',
    'tax',
    'loan_interest',
    'strategy_action',
    'strategy_reason',
    'strategy_time',
    'candidate_reason',
    'candidate_score',
    'generation',
]

POSITIVE = [
    (re.compile(r'(kis|broker|official|authority|verify|readback|latest|canonical)', re.I), 45),
    (re.compile(r'(daily|period|trade|profit|pnl|fill|settlement|account)', re.I), 20),
    (re.compile(r'(current|final|confirmed|captured|completed)', re.I), 12),
]

NEGATIVE = [
    (re.compile(r'(backup|archive|old|temp|work_|self.?test|synthetic|sample|fixture)', re.I), -45),
    (re.compile(r'(installer|report|audit|evidence|debug)', re.I), -18),
    (re.compile(r'(failed|rollback|error)', re.I), -25),
]

EXACT = {
    'realized_net_pnl': re.compile(
        r'(daily.?trading.?pnl|net.?realized|realized.?net|net.?pnl|net.?profit|rlzt.*pfls)',
        re.I,
    ),
    'gross_trade_pnl': re.compile(
        r'(gross.?pnl|gross.?profit|trade.?profit)',
        re.I,
    ),
    'fee': re.compile(r'(total.?fee|commission|fee.?amount|fee)', re.I),
    'tax': re.compile(r'(transaction.?tax|tax.?amount|tax)', re.I),
    'loan_interest': re.compile(r'(loan.?interest|interest.?amount|interest)', re.I),
    'strategy_action': re.compile(
        r'(strategy.*action|execution.*action|decision.*action|(^|\.)action$)',
        re.I,
    ),
    'strategy_reason': re.compile(
        r'(strategy.*reason|decision.*reason|rationale|(^|\.)reason$)',
        re.I,
    ),
    'strategy_time': re.compile(
        r'(strategy.*time|decision.*time|created.?at|captured.?at|timestamp)',
        re.I,
    ),
    'candidate_reason': re.compile(
        r'(candidate.*reason|selection.*reason|promotion.*evidence|ranking.*reason)',
        re.I,
    ),
    'candidate_score': re.compile(
        r'(candidate.*score|ranking.*score|(^|\.)score$)',
        re.I,
    ),
    'generation': re.compile(
        r'(account.?generation|generation|lineage|proof.?hash|source.?hash)',
        re.I,
    ),
}

NUMERIC_GROUPS = {
    'realized_net_pnl',
    'gross_trade_pnl',
    'fee',
    'tax',
    'loan_interest',
    'candidate_score',
}


def normalize_group(value: Any) -> str:
    return str(value or '').strip().lower()


def latest_manifest() -> Path:
    candidates = sorted(
        EVIDENCE_ROOT.glob('AUDIT_V2_*/READ_ONLY_EVIDENCE_AUDIT_V2.json'),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    if not candidates:
        raise RuntimeError('LATEST_AUDIT_MANIFEST_NOT_FOUND')
    return candidates[0]


def numeric_like(value: Any) -> bool:
    if isinstance(value, bool) or value is None:
        return False
    if isinstance(value, (int, float)):
        return True
    if isinstance(value, str):
        text = value.replace(',', '').replace('+', '').strip()
        return bool(re.fullmatch(r'-?\d+(?:\.\d+)?', text))
    return False


def nonempty(value: Any) -> bool:
    if value is None:
        return False
    text = str(value).strip()
    return bool(text and text.upper() != '[REDACTED]')


def score_item(item: dict[str, Any]) -> tuple[int, list[str]]:
    group = normalize_group(item.get('group'))
    file_path = str(item.get('file', ''))
    field_path = str(item.get('field', ''))
    combined = file_path + '|' + field_path
    value = item.get('value')
    score = 0
    reasons: list[str] = []

    for pattern, points in POSITIVE:
        if pattern.search(combined):
            score += points
            reasons.append('positive:' + str(points))

    for pattern, points in NEGATIVE:
        if pattern.search(combined):
            score += points
            reasons.append('negative:' + str(points))

    exact = EXACT.get(group)
    if exact is not None and exact.search(field_path):
        score += 45
        reasons.append('exact_field:45')

    if re.search(r'(?i)(latest\.json$|verify_latest\.json$|official.*latest)', file_path):
        score += 25
        reasons.append('latest_file:25')

    if group in NUMERIC_GROUPS:
        if numeric_like(value):
            score += 18
            reasons.append('numeric:18')
        else:
            score -= 40
            reasons.append('non_numeric:-40')
    elif nonempty(value):
        score += 10
        reasons.append('nonempty:10')
    else:
        score -= 40
        reasons.append('empty:-40')

    modified = item.get('modified')
    if isinstance(modified, str):
        try:
            when = dt.datetime.fromisoformat(modified)
            now = dt.datetime.now(when.tzinfo) if when.tzinfo else dt.datetime.now()
            age = now - when
            if age.days <= 1:
                score += 15
                reasons.append('recent_1d:15')
            elif age.days <= 7:
                score += 8
                reasons.append('recent_7d:8')
        except Exception:
            pass

    if str(value).strip().upper() == '[REDACTED]':
        score -= 100
        reasons.append('redacted:-100')

    return score, reasons


def ranked_unique(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    ranked: list[dict[str, Any]] = []
    seen: set[tuple[str, str, str, str]] = set()

    for raw in items:
        item = dict(raw)
        item['group'] = normalize_group(item.get('group'))
        score, reasons = score_item(item)
        key = (
            item['group'],
            str(item.get('file', '')),
            str(item.get('field', '')),
            json.dumps(item.get('value'), ensure_ascii=True, default=str),
        )
        if key in seen:
            continue
        seen.add(key)
        item['selection_score'] = score
        item['selection_reasons'] = reasons
        ranked.append(item)

    ranked.sort(
        key=lambda item: (
            int(item.get('selection_score', -9999)),
            str(item.get('modified', '')),
        ),
        reverse=True,
    )
    return ranked


def conflict_summary(ranked: list[dict[str, Any]]) -> dict[str, Any]:
    if not ranked:
        return {
            'top_score_band_count': 0,
            'unique_numeric_values': [],
            'conflict_detected': False,
        }

    top_score = int(ranked[0].get('selection_score', -9999))
    band = [
        item for item in ranked
        if int(item.get('selection_score', -9999)) >= top_score - 5
    ][:20]
    values = []
    for item in band:
        value = item.get('value')
        if numeric_like(value):
            values.append(str(value).replace(',', ''))
    unique = sorted(set(values))
    return {
        'top_score_band_count': len(band),
        'unique_numeric_values': unique[:20],
        'conflict_detected': len(unique) > 1,
    }


def main() -> int:
    manifest_path = latest_manifest()
    payload = json.loads(manifest_path.read_text(encoding='utf-8-sig'))
    evidence = payload.get('json_evidence', [])
    field_counts = payload.get('field_counts', {})

    if not isinstance(evidence, list):
        raise RuntimeError('INVALID_EVIDENCE_LIST')
    if not isinstance(field_counts, dict):
        raise RuntimeError('INVALID_FIELD_COUNTS')

    grouped: dict[str, list[dict[str, Any]]] = {group: [] for group in GROUPS}
    unknown_groups: dict[str, int] = {}

    for item in evidence:
        if not isinstance(item, dict):
            continue
        group = normalize_group(item.get('group'))
        if group in grouped:
            normalized = dict(item)
            normalized['group'] = group
            grouped[group].append(normalized)
        else:
            unknown_groups[group] = unknown_groups.get(group, 0) + 1

    for group in GROUPS:
        reported = int(field_counts.get(group, 0) or 0)
        captured = len(grouped[group])
        if reported > 0 and captured == 0:
            raise RuntimeError(
                'GROUP_NORMALIZATION_OR_TRUNCATION_FAILURE:' +
                group + ':reported=' + str(reported)
            )

    selections: dict[str, Any] = {}
    for group in GROUPS:
        ranked = ranked_unique(grouped[group])
        top = ranked[:30]
        canonical = top[0] if top else None
        eligible = bool(
            canonical and
            int(canonical.get('selection_score', -9999)) >= 50 and
            nonempty(canonical.get('value'))
        )
        selections[group] = {
            'manifest_reported_count': int(field_counts.get(group, 0) or 0),
            'captured_evidence_count': len(grouped[group]),
            'candidate_count': len(ranked),
            'top_candidates': top,
            'canonical_candidate': canonical,
            'eligible_for_offline_build': eligible,
            'conflict': conflict_summary(ranked),
        }

    required_financial = ['realized_net_pnl', 'fee', 'tax']
    required_strategy = ['strategy_action', 'strategy_reason', 'strategy_time']
    required_candidate = ['candidate_reason', 'candidate_score']

    financial_ready = all(
        selections[group]['eligible_for_offline_build']
        for group in required_financial
    )
    strategy_ready = all(
        selections[group]['eligible_for_offline_build']
        for group in required_strategy
    )
    candidate_ready = all(
        selections[group]['eligible_for_offline_build']
        for group in required_candidate
    )

    output = {
        'contract_type': 'AUTOTRADE_CLEAN_V2_2_OFFLINE_SOURCE_CONTRACT_V2',
        'created_at': dt.datetime.now().astimezone().isoformat(timespec='seconds'),
        'source_manifest': str(manifest_path),
        'group_normalization': 'LOWERCASE_CANONICAL',
        'read_only': True,
        'live_install_allowed': False,
        'manual_value_override_allowed': False,
        'zero_when_unconfirmed_allowed': False,
        'financial_sources_ready': financial_ready,
        'strategy_timeline_sources_ready': strategy_ready,
        'candidate_explanation_sources_ready': candidate_ready,
        'all_offline_build_inputs_ready': (
            financial_ready and strategy_ready and candidate_ready
        ),
        'unknown_groups': unknown_groups,
        'selections': selections,
    }

    OUTPUT.write_text(
        json.dumps(output, ensure_ascii=False, indent=2, default=str),
        encoding='utf-8-sig',
    )

    print('FINAL_STATUS=PASS_CANONICAL_SOURCE_SELECTION_AUDIT_V2')
    print('SOURCE_MANIFEST=' + str(manifest_path))
    print('GROUP_NORMALIZATION=PASS_LOWERCASE_CANONICAL')
    print('EVIDENCE_LIST_COUNT=' + str(len(evidence)))
    print('FINANCIAL_SOURCES_READY=' + str(financial_ready).upper())
    print('STRATEGY_TIMELINE_SOURCES_READY=' + str(strategy_ready).upper())
    print('CANDIDATE_EXPLANATION_SOURCES_READY=' + str(candidate_ready).upper())
    print(
        'ALL_OFFLINE_BUILD_INPUTS_READY=' +
        str(output['all_offline_build_inputs_ready']).upper()
    )

    for group in GROUPS:
        upper = group.upper()
        selected = selections[group]['canonical_candidate']
        print(
            'NORMALIZED_' + upper + '_COUNT=' +
            str(selections[group]['captured_evidence_count'])
        )
        if selected:
            print('TOP_' + upper + '_SCORE=' + str(selected['selection_score']))
            print('TOP_' + upper + '_FILE=' + str(selected.get('file', '')))
            print('TOP_' + upper + '_FIELD=' + str(selected.get('field', '')))
            print(
                'TOP_' + upper + '_CONFLICT=' +
                str(selections[group]['conflict']['conflict_detected']).upper()
            )
        else:
            print('TOP_' + upper + '_SCORE=NONE')
            print('TOP_' + upper + '_CONFLICT=FALSE')

    print('OFFLINE_SOURCE_CONTRACT=' + str(OUTPUT))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
'@

[IO.File]::WriteAllText(
    $Helper,
    $PythonSelector,
    (New-Object System.Text.ASCIIEncoding)
)

Add-Result 'FINAL_STATUS' 'RUNNING'
Add-Result 'EXECUTION_MODE' 'V2_2_CANONICAL_SOURCE_SELECTION_AUDIT_V2_READ_ONLY'
Add-Result 'GROUP_CASE_MISMATCH_FIXED' $true
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
    if (-not $SelectText.Contains('FINAL_STATUS=PASS_CANONICAL_SOURCE_SELECTION_AUDIT_V2')) {
        throw ('SELECTOR_PASS_MARKER_MISSING:' + $SelectText)
    }

    foreach ($Line in $SelectOutput) {
        $Text = [string]$Line
        if (
            $Text.StartsWith('SOURCE_MANIFEST=') -or
            $Text.StartsWith('GROUP_NORMALIZATION=') -or
            $Text.StartsWith('EVIDENCE_LIST_COUNT=') -or
            $Text.StartsWith('FINANCIAL_SOURCES_READY=') -or
            $Text.StartsWith('STRATEGY_TIMELINE_SOURCES_READY=') -or
            $Text.StartsWith('CANDIDATE_EXPLANATION_SOURCES_READY=') -or
            $Text.StartsWith('ALL_OFFLINE_BUILD_INPUTS_READY=') -or
            $Text.StartsWith('NORMALIZED_') -or
            $Text.StartsWith('TOP_') -or
            $Text.StartsWith('OFFLINE_SOURCE_CONTRACT=')
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
    Add-Result 'LIVE_DASHBOARD_MODIFIED' $false
    Add-Result 'AUTOTRADE_STRATEGY_MODIFIED' $false
    Add-Result 'ORDER_PATH_MODIFIED' $false
    Add-Result 'DATABASE_DIRECT_WRITE_USED' $false
    Add-Result 'BROKER_ORDER_ATTEMPTED' $false
    Add-Result 'ORDER_TRANSPORT_CALLS' 0
    Add-Result 'SCHEDULED_TASK_MODIFIED' $false
    Add-Result 'RUNTIME_RESTARTED' $false
    Add-Result 'V2_2_LIVE_INSTALL_ALLOWED' $false
    Add-Result 'NEXT_STAGE' 'OFFLINE_V2_2_BUILD_ONLY_AFTER_SOURCE_CONTRACT_REVIEW'
    Add-Result 'FINAL_STATUS' 'PASS_V2_2_CANONICAL_SOURCE_SELECTION_AUDIT_V2_NO_LIVE_MUTATION'
    $Success = $true
}
catch {
    Add-Result 'SELECTION_ERROR' $_.Exception.Message
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
    Add-Result 'FINAL_STATUS' 'FAIL_V2_2_CANONICAL_SOURCE_SELECTION_AUDIT_V2_NO_LIVE_MUTATION'
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
