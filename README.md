# AWS Region Select Tool

[English](README.md) | [简体中文](README.zh-CN.md)

[![CI](https://img.shields.io/github/actions/workflow/status/s-qin/aws-region-select-tool/test.yml?branch=main&style=flat&label=CI)](https://github.com/s-qin/aws-region-select-tool/actions/workflows/test.yml) [![Release](https://img.shields.io/github/v/release/s-qin/aws-region-select-tool)](https://github.com/s-qin/aws-region-select-tool/releases/latest) [![Windows](https://img.shields.io/badge/Windows-10_%7C_11-0078D4?style=flat&logo=windows11&logoColor=white)](https://www.microsoft.com/windows) [![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B_%7C_7.x-5391FE?style=flat&logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/) [![AWS Lightsail](https://img.shields.io/badge/AWS-Lightsail-FF9900?style=flat&logo=amazonwebservices&logoColor=white)](https://aws.amazon.com/lightsail/) [![License](https://img.shields.io/github/license/s-qin/aws-region-select-tool?style=flat&logo=opensourceinitiative&logoColor=white)](LICENSE)

A zero-dependency PowerShell tool for ranking deployable Amazon Lightsail Regions from your current network and validating a real AWS/Lightsail instance IPv4 after deployment.

Version 2.0.0 supports Windows PowerShell 5.1 and PowerShell 7.x. It does not require AWS CLI, an AWS account, credentials, or third-party modules, and it never creates or changes AWS resources.

## Why use it?

- Choose a Lightsail Region before creating an instance, using evidence from the computer and network that will actually use it.
- Compare one Region, a built-in geographic group, a custom set, or the complete controlled Lightsail catalog.
- Validate a real instance IP after deployment without confusing API-endpoint TCP/443 with instance TCP/22.
- Keep bounded aggregate baseline history while retaining full samples only in per-run JSON reports.

This is a point-in-time network diagnostic, not a benchmark of cost, throughput, capacity, availability zones, SLA, or application performance.

## V2.0.0 highlights

- Controlled catalog of 19 Lightsail Regions, sourced from AWS documentation and updated 2026-09-27.
- Interactive no-argument workflow plus stable automation-friendly CLI.
- Target Selector for a single Region, five built-in groups, and custom comma-separated sets.
- Adaptive `Auto` mode: Standard for 1–6 Regions; Quick screening plus Standard finalist validation for 7 or more.
- Separate `ScreeningRank`, `FinalistRank`, and `RecommendationRank` semantics.
- Per-Region Reachability discovery failure isolation; missing targets remain visible as `Unavailable`.
- Real IP Validation compatibility from v1.1, History 2.0 migration, and report JSON Schema 2.0.

## Requirements and zero dependency

- Windows 10 or 11.
- Windows PowerShell 5.1+ or PowerShell 7.x.
- Outbound ICMP where allowed, TCP/443 for Region probes, and the chosen instance TCP port for Real IP Validation.
- Internet access for online EC2 Reachability discovery and automatic AWS IP ownership detection.

Only built-in PowerShell and .NET APIs are used. AWS CLI and credentials are not used.

## Install or download

Download `aws-region-select-tool.ps1` from the latest GitHub Release and verify it against `SHA256SUMS.txt`, or clone the repository:

```powershell
git clone https://github.com/s-qin/aws-region-select-tool.git
cd aws-region-select-tool
```

PowerShell may require a process-scoped execution policy adjustment:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

## Quick Start

```powershell
# Interactive menu
.\aws-region-select-tool.ps1

# Global Lightsail scan
.\aws-region-select-tool.ps1 -Target global

# v1.x US three-Region replacement
.\aws-region-select-tool.ps1 -Target us-all -Mode Standard

# One Region or a custom set
.\aws-region-select-tool.ps1 -Target ap-southeast-1
.\aws-region-select-tool.ps1 -Target "ap-east-1,ap-southeast-1,ap-northeast-1"

# Validate a deployed instance with SSH as the stable probe
.\aws-region-select-tool.ps1 -TargetIp 203.0.113.10 -ProbePort 22
```

## Interactive workflow

No arguments opens one screen:

```text
[1] Global Lightsail Scan
[2] Targeted Region Scan
[3] Real IP Validation
[Q] Quit
```

Targeted Scan accepts `?` to show the catalog and groups. Invalid menu or target input can be retried; `Q` exits without network activity.

## Global Lightsail Scan

`-Target global -Mode Auto` uses two distinct evidence stages:

1. Quick screening of every catalog Region: 9 ICMP, 3 TCP, 2 TLS, no traceroute per Region.
2. Standard validation of at most five healthy/evidence-complete finalists: 36 ICMP, 8 TCP, 4 TLS, and one diagnostic traceroute per finalist.

The console shows the final Top 3 first, finalist validation second, and complete screening evidence last. A Region whose Reachability target cannot be confirmed remains in screening with `ProbeStatus=Unavailable` and a reason. Quick scores are never presented as a precise 1–19 final ranking.

## Targeted Scan, target grammar, and groups

Inputs are trimmed and case-insensitive, normalized to lowercase, deduplicated while preserving first occurrence, and validated completely before network activity.

| Target | Regions |
|---|---|
| `us-all` | `us-east-1`, `us-east-2`, `us-west-2` |
| `americas-all` | US three, `ca-central-1`, `sa-east-1` |
| `eu-all` | `eu-central-1`, `eu-north-1`, `eu-south-2`, `eu-west-1`, `eu-west-2`, `eu-west-3` |
| `apac-all` | `ap-east-1`, `ap-northeast-1`, `ap-northeast-2`, `ap-south-1`, `ap-southeast-1`, `ap-southeast-2`, `ap-southeast-3`, `ap-southeast-5` |
| `global` | All 19 Regions in the current controlled catalog |

Use `-ListTargets` to view codes, locations, geography, opt-in metadata, and exact group expansion. A single Region reports evidence without inventing a relative cross-Region rank.

## Real IP Validation

```powershell
# Automatic Region detection through the official AWS IPv4 range feed
.\aws-region-select-tool.ps1 -TargetIp 203.0.113.10 -ProbePort 22

# Offline/BYOIP recovery: explicitly provide a supported Lightsail Region
.\aws-region-select-tool.ps1 -TargetIp 203.0.113.10 -Region us-west-2 -ProbePort 22
```

The tool uses longest-prefix IPv4 CIDR matching against AWS `ip-ranges.json` and reports Region, network border group, service, prefix, and prefix length. It does not assume a `LIGHTSAIL` service value. Unknown, BYOIP, or unpublished addresses are never guessed.

Real validation measures multiple ICMP samples, repeated TCP connections to `-ProbePort` (default 22), traceroute, P50/P95/loss/jitter, TCP success rate, and TCP P50. It compares only ICMP metrics with the same-Region baseline. Regional AWS API TCP/443 is never directly compared with instance TCP/22.

If the instance blocks ICMP but TCP is healthy, the result is `RETEST / INCONCLUSIVE`, not Critical. Temporarily allow Ping (ICMP) in the Lightsail firewall when a complete RTT comparison is required.

Verdicts use multiple signals:

- `KEEP / GOOD`: healthy TCP plus complete, fresh comparison with conservative degradation.
- `RETEST / BORDERLINE`: moderate or mixed degradation.
- `RETEST / INCONCLUSIVE`: ICMP filtered, missing comparison, incomplete evidence, or conflicting rounds.
- `RETRY / POOR`: only after an initial poor result and one delayed shortened confirmation are both clearly poor.

## Auto, Quick, Standard, and Thorough

| Mode | Region behavior | ICMP / TCP / TLS per Region | Traceroute |
|---|---|---:|---|
| `Auto` | 1–6 Standard; 7+ Quick then up to 5 Standard finalists | Adaptive | Final validation only |
| `Quick` | Entire selected set | 9 / 3 / 2 | Unless skipped |
| `Standard` | Entire selected set | 36 / 8 / 4 | Once per Region |
| `Thorough` | Entire selected set | 45 / 10 / 5 | Once per Region |

Advanced count parameters override profile counts. All probes are serial, bounded, and rate-limited by `-RoundDelayMs`.

## Metrics, Region Score, Health, and Confidence

P50 represents typical latency; P95 exposes tail latency; packet loss records failed ICMP probes; jitter is population standard deviation. TCP/TLS combine success rate and handshake latency.

Region Score preserves the v1.1 weights:

- P50 30%, P95 20%, packet loss 20%, jitter 10%, TCP 15%, TLS 5%.

Absolute quality and relative quality within the same stage are blended. Health gates (`Good`, `Fair`, `Degraded`, `Critical`, `NoData`) take precedence over Score. Confidence considers evidence completeness, health, score margin, baseline quality, and—in Real mode—TCP/ICMP availability and baseline freshness.

Traceroute is diagnostic only and never contributes to Score.

## Reachability target discovery

The Lightsail Region Catalog and AWS-maintained EC2 Reachability targets are separate facts. At runtime the tool reads the declared Reachability source, validates IPv4 targets by selected Region, and uses only a verified built-in cache where one exists. A target or Region failure does not abort other Regions. The tool never fabricates an IP to make the catalog appear complete.

`-UseCachedTargets` is mainly a diagnostic/offline option. The bundled cache covers only targets previously verified by the project; other Regions can correctly appear unavailable.

## Reports and History

Unless `-NoJson` is supplied, every run writes a timestamped JSON report with `SchemaVersion: "2.0"`.

Region Probe reports can express:

- `Tool`, `Environment`, `Test`, `Catalog`, `Selection`, `TargetDiscovery`, and `ProbePlan`.
- `Screening`, `FinalValidation`, distinct rank fields, and `Recommendation`.
- `History`, complete per-run `RawSamples`, and `Warnings`.

Real reports use `Operation: "RealIpValidation"` and include `RealValidation`, Region detection, baseline reference/refresh, comparable deltas, metrics, verdict, confirmation, raw samples, and history status. Nonexistent stages are `null`; they are not fabricated.

Aggregate history is stored relative to the script at:

```text
$PSScriptRoot\.data\baseline-history.json
```

History Schema 2.0 stores timestamps, scope, selection, profile, stage, Region aggregates, health, Score, and bounded Real verdict aggregates—never complete raw samples. It keeps 30 days, at most 50 Baseline runs and 100 Real validations. History 1.0 is lazily normalized to 2.0. Writes use a validated same-directory temporary file and atomic replace/move; corrupt data is quarantined and rebuilt.

Real baseline status is Fresh (≤6h), Usable (>6h and ≤24h), Stale (>24h), or Missing. Stale, Missing, or Quick-only references trigger a bounded Standard refresh for only the target Region.

## CLI reference

| Parameter | Purpose |
|---|---|
| `-Target <value>` | Region, group, or comma-separated custom set |
| `-ListTargets` | List catalog and groups without probing |
| `-TargetIp <IPv4>` | Select Real IP Validation mode |
| `-ProbePort <1-65535>` | Real TCP port; default 22 |
| `-Region <code>` | Real-mode manual Region override |
| `-RetryDelaySeconds <1-60>` | Delay before the only RETRY confirmation; default 5 |
| `-Mode Auto\|Quick\|Standard\|Thorough` | Probe strategy; default Auto |
| `-IcmpSamplesPerRegion <0,3-60>` | Override ICMP count; 0 uses profile |
| `-TcpAttempts <1-15>` | Override TCP attempts; omit to use profile |
| `-TlsAttempts <1-8>` | Override TLS attempts; omit to use profile |
| `-PingTimeoutMs <250-5000>` | ICMP timeout |
| `-ConnectionTimeoutMs <500-10000>` | TCP/TLS timeout |
| `-RoundDelayMs <100-5000>` | Delay between ICMP rounds |
| `-MaxTargetsPerRegion <1-3>` | Per-Region target cap |
| `-OutputPath <path>` | JSON output path |
| `-NoJson` | Suppress JSON report |
| `-UseCachedTargets` | Skip online Reachability discovery |
| `-SkipTraceroute` | Skip diagnostic traceroute |

`-Target` and `-TargetIp` are mutually exclusive. `-Region` is valid only with `-TargetIp`. Usage conflicts are rejected before network operations.

## Exit codes

- `0`: completed with an actionable Region recommendation or Real verdict; listing/quit also succeeds.
- `2`: invalid parameters, routing conflict, detection failure, or runtime error.
- `3`: insufficient evidence for a safe recommendation/verdict.

## Public-target etiquette and safety

- Probes are serial with hard count, timeout, target, finalist, and confirmation limits.
- No throughput, flood, stress, port-range scanning, or infinite retries.
- One Region failure is isolated from the rest.
- Generated `.data`, reports, test outputs, and temporary files are ignored by Git.
- Reports contain diagnostics and local environment metadata; review them before sharing.
- No secrets, tokens, cookies, AWS credentials, or private keys are requested or stored.

## Troubleshooting

- **Region is Unavailable:** online discovery found no valid Reachability target and no verified cache exists. Retry later; do not substitute an arbitrary AWS IP.
- **All TLS attempts fail:** a proxy, TLS inspection, or local network policy may block Regional endpoints. Review TCP and error fields; the health gate prevents unsafe recommendations.
- **ICMP is 100% loss for a real instance:** confirm TCP reachability and optionally allow Lightsail Ping temporarily.
- **AWS IP cannot be recognized:** the address may be BYOIP or newer than the published feed; use a truthful `-Region` override only when known.
- **History warning:** the corrupt file is preserved as `.corrupt-*.json`; a fresh store is created automatically.

## Example output

```text
AWS Lightsail Region Selection
Selection: global (19 Regions)
Plan: TwoStage

Final Recommendation
RecommendationRank  Region          Score  Health
1                   ap-southeast-1  91.4   Good
2                   ap-east-1       87.2   Good
3                   ap-northeast-1  82.6   Good

Global Screening - All Selected Regions
...all selected Regions, including explicit Unavailable rows...
```

Results are examples only; actual outcomes depend on the current computer, route, network exit, and time.

## Development, tests, and CI

The deterministic suite performs no live public-target load and covers Catalog/groups/grammar, planner, per-Region failure isolation, rankings, JSON 2.0, History migration/retention/atomic recovery, CIDR detection, Real verdicts, confirmation, CLI conflicts, safety, docs, and license.

```powershell
pwsh.exe -NoProfile -File .\tests\run-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

GitHub Actions runs the same suite on Windows PowerShell 5.1 and PowerShell 7.x. Live smoke tests are bounded and run manually because instantaneous public-network results are not deterministic fixtures.

## v1.1 to v2.0 migration and breaking changes

- No arguments now opens the interactive menu instead of immediately running the US three-Region baseline.
- Use `.\aws-region-select-tool.ps1 -Target us-all -Mode Standard` for the v1.x baseline equivalent.
- Region Probe default `-Mode` is now `Auto`; explicit `Quick`, `Standard`, and `Thorough` keep their profiles.
- Report schema changes from 1.1 to 2.0. Consumers must route by `Operation` and read stage-specific fields.
- History 1.0 is read and lazily normalized; deleting `.data` remains a safe way to reset local history.
- Real IP parameters and core KEEP/RETEST/RETRY semantics remain compatible.

## Known limitations

- Catalog facts are controlled snapshots and require a project update when AWS changes Lightsail availability.
- Reachability targets are dynamic and may be absent even for a supported Lightsail Region.
- ICMP and traceroute can be filtered; TCP/TLS can be affected by proxies and endpoint policy.
- Atomic writes prevent partial JSON, but simultaneous processes use last-completed-writer-wins rather than a cross-process lock.
- Scores compare only candidates within the same probe stage; Quick and Standard evidence are deliberately not treated as equal precision.

## Security

Inspect downloaded scripts and verify release SHA-256 before execution. The tool performs only outbound diagnostics and local report/history writes. It does not call AWS management APIs or alter cloud resources.

## License

[MIT](LICENSE) — Copyright (c) 2026 sqin.
